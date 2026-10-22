-- Rollback of migration 008 — full-kit allocation and dependent demand.
-- Restores v_sales_order_buffer (005), v_buffer_status and v_replenishment (006) exactly as they were.
-- Views are dropped and recreated because 008 appended columns, which create or replace cannot remove.

begin;
drop view if exists public.v_full_kit_lines;
drop view if exists public.v_replenishment;
drop view if exists public.v_buffer_status;
drop view if exists public.v_sales_order_buffer;
drop index if exists public.sales_order_lines_open_ix;
drop function if exists private.full_kit_allocation(uuid);
drop type if exists private.kit_row;

create or replace view public.v_sales_order_buffer
with (security_invoker = true) as
with lines as (
  select l.sales_order_id, count(*) as open_lines,
         bool_and(coalesce(s.on_hand, 0) >= l.quantity_base - l.delivered_qty_base) as stock_covered
  from public.sales_order_lines l
  left join public.item_warehouse_stock s on s.item_id = l.item_id and s.warehouse_id = l.warehouse_id
  where l.line_status = 'OPEN' and l.delivered_qty_base < l.quantity_base
  group by l.sales_order_id
), o as (
  select so.*, private.company_today(so.company_id) as today
  from public.sales_orders so
  where so.status = 'OPEN'
), p as (
  select o.*, round(greatest(0, o.today - (o.due_date - o.time_buffer_days))::numeric * 100 / o.time_buffer_days, 0) as penetration
  from o
)
select p.company_id, p.id as sales_order_id, p.doc_number, p.doc_date, p.due_date, p.time_buffer_days,
       p.due_date - p.time_buffer_days as buffer_start,
       p.business_partner_id, bp.code as customer_code, bp.name as customer_name, p.customer_reference,
       coalesce(ln.open_lines, 0) as open_lines, coalesce(ln.stock_covered, true) as stock_covered,
       p.penetration, private.buffer_zone(p.company_id, p.penetration) as zone,
       p.due_date - p.today as days_to_due
from p
join public.business_partners bp on bp.id = p.business_partner_id
left join lines ln on ln.sales_order_id = p.id;

create or replace view public.v_buffer_status
with (security_invoker = true) as
with b as (
  select ib.*, s.spike_threshold_pct, private.company_today(ib.company_id) as today
  from public.item_buffers ib
  join public.company_settings s on s.company_id = ib.company_id
  where ib.is_active
), alloc as (
  select b.id as item_buffer_id,
         coalesce(sum(o.open_qty_base) filter (
           where o.buffer_start <= b.today or o.open_qty_base * 100 >= b.target_qty * b.spike_threshold_pct), 0) as allocated,
         coalesce(sum(o.open_qty_base) filter (
           where o.buffer_start > b.today and o.open_qty_base * 100 >= b.target_qty * b.spike_threshold_pct), 0) as spike_qty,
         coalesce(sum(o.open_qty_base), 0) as open_orders
  from b
  left join public.v_open_so_lines o on o.item_id = b.item_id and o.warehouse_id = b.warehouse_id
  group by b.id
), q as (
  select b.id as item_buffer_id, b.company_id, b.item_id, b.warehouse_id, b.target_qty, b.last_changed_on, b.today,
         coalesce(st.on_hand, 0) as on_hand,
         coalesce(oo.on_order, 0) as on_order,
         a.allocated, a.spike_qty, a.open_orders
  from b
  join alloc a on a.item_buffer_id = b.id
  left join public.item_warehouse_stock st on st.item_id = b.item_id and st.warehouse_id = b.warehouse_id
  left join public.v_on_order oo          on oo.item_id = b.item_id and oo.warehouse_id = b.warehouse_id
), p as (
  select q.*, q.on_hand - q.allocated as available, q.on_hand + q.on_order - q.allocated as net_flow,
         round(greatest(0, q.target_qty - (q.on_hand - q.allocated)) * 100 / q.target_qty, 0) as penetration,
         round(greatest(0, q.target_qty - (q.on_hand + q.on_order - q.allocated)) * 100 / q.target_qty, 0) as net_flow_penetration
  from q
)
select p.company_id, p.item_buffer_id, p.item_id, i.item_code, i.name as item_name, i.procurement_method,
       p.warehouse_id, w.code as warehouse_code, u.code as base_uom,
       p.target_qty, p.on_hand, p.on_order, p.allocated, p.spike_qty, p.open_orders,
       p.available, p.net_flow, p.penetration,
       case when p.available <= 0 then 'BLACK' else private.buffer_zone(p.company_id, least(p.penetration, 100)) end as zone,
       p.net_flow_penetration,
       case when p.net_flow <= 0 then 'BLACK' else private.buffer_zone(p.company_id, least(p.net_flow_penetration, 100)) end as net_flow_zone,
       greatest(0, p.target_qty - p.net_flow) as replenish_qty,
       p.last_changed_on
from p
join public.items i       on i.id = p.item_id
join public.warehouses w  on w.id = p.warehouse_id
join public.uom_groups g  on g.id = i.uom_group_id
join public.uoms u        on u.id = g.base_uom_id;

create or replace view public.v_replenishment
with (security_invoker = true) as
with need as (
  select company_id, item_id, warehouse_id, 'BUFFER'::text as source, replenish_qty as need_base,
         net_flow_penetration as priority_pct, net_flow_zone as zone, target_qty, on_hand, on_order, allocated
  from public.v_buffer_status
  where replenish_qty > 0
  union all
  select ps.company_id, ps.item_id, ps.warehouse_id, 'TO_ORDER', -ps.projected,
         null, null, null, ps.on_hand, ps.on_order, ps.reserved
  from public.v_projected_stock ps
  join public.items i on i.id = ps.item_id
  where ps.projected < 0 and i.replenishment_policy = 'TO_ORDER'
), sup as (
  select n.*, i.item_code, i.name as item_name, i.procurement_method, i.uom_group_id,
         isup.business_partner_id, bp.code as supplier_code, bp.name as supplier_name,
         coalesce(isup.purchase_uom_id, i.purchase_uom_id) as purchase_uom_id,
         isup.min_order_qty, isup.order_multiple,
         coalesce(isup.lead_time_days, bp.default_lead_time_days) as lead_time_days
  from need n
  join public.items i on i.id = n.item_id
  left join public.item_suppliers isup on isup.item_id = n.item_id and isup.is_preferred and isup.is_active
  left join public.business_partners bp on bp.id = isup.business_partner_id
), conv as (
  select sup.*, private.to_base_qty(sup.uom_group_id, sup.purchase_uom_id, 1) as base_per_purchase_unit
  from sup
), r as (
  select conv.*, ceil(conv.need_base / conv.base_per_purchase_unit) as raw_purchase_qty from conv
)
select r.company_id, r.item_id, r.item_code, r.item_name, r.procurement_method, r.warehouse_id, w.code as warehouse_code,
       r.source, r.zone, r.priority_pct, r.target_qty, r.on_hand, r.on_order, r.allocated,
       r.need_base, bu.code as base_uom,
       r.business_partner_id, r.supplier_code, r.supplier_name, r.lead_time_days,
       r.purchase_uom_id, pu.code as purchase_uom,
       greatest(coalesce(r.min_order_qty, 0),
                ceil(r.raw_purchase_qty / coalesce(r.order_multiple, 1)) * coalesce(r.order_multiple, 1)) as suggested_purchase_qty
from r
join public.warehouses w  on w.id = r.warehouse_id
join public.uom_groups g  on g.id = r.uom_group_id
join public.uoms bu       on bu.id = g.base_uom_id
join public.uoms pu       on pu.id = r.purchase_uom_id;

revoke all on public.v_sales_order_buffer, public.v_buffer_status, public.v_replenishment from anon;
commit;
