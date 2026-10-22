-- =============================================================================
-- Migration 008 — Full-kit check by buffer-priority allocation (D-046) and dependent demand in buffers (D-047)
--
--   private.full_kit_allocation(company)   allocates on-hand stock to open sales orders in buffer-priority order,
--                                          multi-level: the shortfall of a MAKE item is exploded through its active
--                                          BOM and competes for component stock in the same priority order
--   v_full_kit_lines                       one row per order line and per exploded requirement: required /
--                                          allocated / short, on order and next expected receipt
--   v_sales_order_buffer                   + kit_status (READY / BUILDABLE / SHORT) and priority_rank;
--                                          stock_covered now means kit_status = READY
--   v_buffer_status                        allocated now also counts dependent demand (component requirements of
--                                          orders whose buffer has started, plus spikes)
--   v_replenishment                        TO_ORDER need now includes dependent demand
--
-- No SAP B1 equivalent: B1 commits stock first-come (OITW.IsCommited) and has no priority allocation or full kit.
-- Closest ERPNext notion is the Work Order "material availability" check, single order, no competing demand.
-- No tables: everything is computed live (D-039). Built finished units are pooled, not held for the order they were
-- made for (owner's choice 2026-10-22): the highest-priority order takes them.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Allocation engine
-- -----------------------------------------------------------------------------

-- One requirement row. level 0 = the sales order line itself; level n = component requirement n BOM levels down.
create type private.kit_row as (
  seq                  integer,        -- creation order; ties inside one order are allocated in this order
  parent_seq           integer,        -- the requirement this one was exploded from (null at level 0)
  level                integer,
  sales_order_id       uuid,
  sales_order_line_id  uuid,
  priority_rank        integer,        -- 1 = most urgent order
  item_id              uuid,
  warehouse_id         uuid,
  required_qty         numeric,        -- base unit of the item
  allocated_qty        numeric,
  short_qty            numeric,
  exploded             boolean         -- short quantity was handed down to components (MAKE item with active BOM)
);

-- Priority: highest order-buffer penetration first, then earlier buffer start, then document number.
-- Penetration is not clamped here, so among orders whose buffer has not started the one starting soonest ranks first.
--
-- Algorithm (MRP low-level-code order, priority netting instead of date netting):
--   1. low-level code (LLC) of every item reachable from open order lines through MAKE items' active BOMs
--      = deepest level at which it occurs. A requirement for an item is only allocated once all its parents are
--      processed, so every demand for that item is known by then.
--   2. for LLC = 0, 1, 2 ...: allocate on hand per item + warehouse by running sum in priority order;
--      the short part of a MAKE item with an active BOM becomes component requirements (one level), whose warehouse
--      is BOM line issue warehouse -> item default warehouse -> company default (D-030).
-- All component lines count whatever their issue method: MANUAL components are still needed to build.
-- Non-inventory and service items need no stock and are skipped.
create or replace function private.full_kit_allocation(p_company_id uuid)
returns setof private.kit_row
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_today    date;
  v_llc      jsonb;
  v_max_llc  integer;
  v_pending  private.kit_row[];
  v_done     private.kit_row[] := '{}';
  v_batch    private.kit_row[];
  v_children private.kit_row[];
  v_seq      integer;
  lvl        integer;
begin
  -- Runs with owner rights so that users who may read orders (e.g. store users) get a correct result even without
  -- BOM read rights; it returns nothing for companies the caller is not assigned to. Cron (no user) sees all.
  if v_uid is not null and p_company_id not in (select private.user_company_ids()) then
    return;
  end if;
  v_today := private.company_today(p_company_id);

  -- level-0 requirements: open quantity of every open inventory line of an open order
  select coalesce(array_agg(x.r order by (x.r).seq), '{}'), coalesce(max((x.r).seq), 0)
  into v_pending, v_seq
  from (
    select row(row_number() over (order by o.rank, l.line_no)::integer, null::integer, 0,
               o.id, l.id, o.rank, l.item_id, l.warehouse_id,
               l.quantity_base - l.delivered_qty_base, 0::numeric, 0::numeric, false)::private.kit_row as r
    from (
      select so.id, so.doc_number,
             rank() over (order by (v_today - (so.due_date - so.time_buffer_days))::numeric / so.time_buffer_days desc,
                                   so.due_date - so.time_buffer_days, so.doc_number)::integer as rank
      from public.sales_orders so
      where so.company_id = p_company_id and so.status = 'OPEN'
    ) o
    join public.sales_order_lines l on l.sales_order_id = o.id
    join public.items i on i.id = l.item_id
    where l.line_status = 'OPEN' and l.delivered_qty_base < l.quantity_base and i.item_type = 'INVENTORY'
  ) x;

  if cardinality(v_pending) = 0 then
    return;
  end if;

  -- low-level codes (BOM cycles are rejected on entry, depth is capped like bom_explosion)
  with recursive t(item_id, depth) as (
    select distinct p.item_id, 0 from unnest(v_pending) p
    union
    select bl.component_item_id, t.depth + 1
    from t
    join public.items pi       on pi.id = t.item_id and pi.procurement_method = 'MAKE'
    join public.bom_headers h  on h.item_id = t.item_id and h.is_active
    join public.bom_lines bl   on bl.bom_id = h.id
    where t.depth < 20
  )
  select jsonb_object_agg(item_id, llc), max(llc) into v_llc, v_max_llc
  from (select item_id, max(depth) as llc from t group by item_id) m;

  for lvl in 0 .. v_max_llc loop
    select array_agg(p order by p.seq) into v_batch
    from unnest(v_pending) p where (v_llc ->> p.item_id::text)::integer = lvl;
    continue when v_batch is null;

    select coalesce(array_agg(p order by p.seq), '{}') into v_pending
    from unnest(v_pending) p where (v_llc ->> p.item_id::text)::integer <> lvl;

    -- allocate: each requirement gets what is left of on hand after all higher-priority requirements
    select array_agg(row(a.seq, a.parent_seq, a.level, a.sales_order_id, a.sales_order_line_id, a.priority_rank,
                         a.item_id, a.warehouse_id, a.required_qty, a.alloc, a.required_qty - a.alloc,
                         a.required_qty > a.alloc and a.can_make)::private.kit_row order by a.seq)
    into v_batch
    from (
      select b.*,
             least(b.required_qty, greatest(0, coalesce(s.on_hand, 0) - coalesce(sum(b.required_qty) over (
               partition by b.item_id, b.warehouse_id order by b.priority_rank, b.seq
               rows between unbounded preceding and 1 preceding), 0))) as alloc,
             (i.procurement_method = 'MAKE'
              and exists (select 1 from public.bom_headers h where h.item_id = b.item_id and h.is_active)) as can_make
      from unnest(v_batch) b
      join public.items i on i.id = b.item_id
      left join public.item_warehouse_stock s on s.item_id = b.item_id and s.warehouse_id = b.warehouse_id
    ) a;

    -- explode the short part of MAKE items one level down
    select coalesce(array_agg(x.c order by (x.c).seq), '{}') into v_children
    from (
      select row(v_seq + row_number() over (order by b.seq, bl.line_no)::integer, b.seq, b.level + 1,
                 b.sales_order_id, b.sales_order_line_id, b.priority_rank, bl.component_item_id,
                 coalesce(bl.issue_warehouse_id, private.default_warehouse(p_company_id, bl.component_item_id)),
                 round(b.short_qty * private.to_base_qty(ci.uom_group_id, bl.uom_id, bl.quantity)
                                   / private.to_base_qty(pi.uom_group_id, h.uom_id, h.base_quantity), 6),
                 0::numeric, 0::numeric, false)::private.kit_row as c
      from unnest(v_batch) b
      join public.items pi       on pi.id = b.item_id
      join public.bom_headers h  on h.item_id = b.item_id and h.is_active
      join public.bom_lines bl   on bl.bom_id = h.id
      join public.items ci       on ci.id = bl.component_item_id
      where b.exploded and ci.item_type = 'INVENTORY'
    ) x;

    v_seq := v_seq + cardinality(v_children);
    v_done := v_done || v_batch;
    v_pending := v_pending || v_children;
  end loop;

  return query select * from unnest(v_done);
end;
$$;
revoke all on function private.full_kit_allocation(uuid) from public;
grant execute on function private.full_kit_allocation(uuid) to authenticated, service_role;
comment on function private.full_kit_allocation(uuid) is
  'Full-kit allocation (D-046): open order demand allocated to on-hand stock in buffer-priority order, multi-level '
  'through MAKE items'' active BOMs. Computed live; nothing is reserved or stored.';

-- -----------------------------------------------------------------------------
-- 2. Views
-- -----------------------------------------------------------------------------

-- Every requirement of every open order. requirement_status:
--   COVERED  allocated in full from stock
--   BUILD    short, but the short part is to be made from components (see the rows with parent_seq = seq)
--   SHORT    short and cannot be made now: bought item, or MAKE item without an active BOM
create or replace view public.v_full_kit_lines
with (security_invoker = true) as
with k as (
  select c.id as company_id, k.*
  from public.companies c
  cross join lateral private.full_kit_allocation(c.id) k
), po as (
  select item_id, warehouse_id, min(expected_date) as next_expected_date
  from public.v_open_po_lines group by item_id, warehouse_id
)
select k.company_id, k.sales_order_id, so.doc_number, k.sales_order_line_id, sl.line_no, k.priority_rank,
       k.seq, k.parent_seq, k.level,
       k.item_id, i.item_code, i.name as item_name, i.procurement_method,
       k.warehouse_id, w.code as warehouse_code, u.code as base_uom,
       k.required_qty, k.allocated_qty, k.short_qty,
       case when k.short_qty = 0 then 'COVERED' when k.exploded then 'BUILD' else 'SHORT' end as requirement_status,
       coalesce(oo.on_order, 0) as on_order, po.next_expected_date
from k
join public.sales_orders so       on so.id = k.sales_order_id
join public.sales_order_lines sl  on sl.id = k.sales_order_line_id
join public.items i               on i.id = k.item_id
join public.warehouses w          on w.id = k.warehouse_id
join public.uom_groups g          on g.id = i.uom_group_id
join public.uoms u                on u.id = g.base_uom_id
left join public.v_on_order oo    on oo.item_id = k.item_id and oo.warehouse_id = k.warehouse_id
left join po                      on po.item_id = k.item_id and po.warehouse_id = k.warehouse_id;
comment on view public.v_full_kit_lines is
  'Full-kit requirements per open sales order (D-046): order lines (level 0) and the component requirements of '
  'their short MAKE quantities, allocated to on-hand stock in buffer-priority order.';

-- Order buffer board. Columns are appended (stock_covered keeps its position, now = kit_status READY):
--   kit_status  READY      every open inventory line is covered from stock on hand
--               BUILDABLE  everything missing can be made now from components on hand (any number of levels)
--               SHORT      something is missing that cannot be made now
--   priority_rank  1 = most urgent order (the allocation order)
create or replace view public.v_sales_order_buffer
with (security_invoker = true) as
with kit as (
  select k.sales_order_id, min(k.priority_rank) as priority_rank,
         case when bool_or(k.short_qty > 0 and not k.exploded) then 'SHORT'
              when bool_or(k.short_qty > 0) then 'BUILDABLE'
              else 'READY' end as kit_status
  from public.companies c
  cross join lateral private.full_kit_allocation(c.id) k
  group by k.sales_order_id
), lines as (
  select l.sales_order_id, count(*) as open_lines
  from public.sales_order_lines l
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
       coalesce(ln.open_lines, 0) as open_lines, coalesce(kit.kit_status, 'READY') = 'READY' as stock_covered,
       p.penetration, private.buffer_zone(p.company_id, p.penetration) as zone,
       p.due_date - p.today as days_to_due,
       coalesce(kit.kit_status, 'READY') as kit_status,
       kit.priority_rank
from p
join public.business_partners bp on bp.id = p.business_partner_id
left join lines ln on ln.sales_order_id = p.id
left join kit on kit.sales_order_id = p.id;

-- Stock buffers: allocated now = direct open order quantity (as before: lines whose order buffer has started, plus
-- spikes) + dependent demand, i.e. component requirements from the full-kit explosion under the same rule (order
-- buffer started, or the single requirement >= spike % of target). Dependent demand is already netted against
-- higher-level stock: finished units on hand create no component demand. New column dependent_allocated appended.
create or replace view public.v_buffer_status
with (security_invoker = true) as
with b as (
  select ib.*, s.spike_threshold_pct, private.company_today(ib.company_id) as today
  from public.item_buffers ib
  join public.company_settings s on s.company_id = ib.company_id
  where ib.is_active
), demand as (
  select o.item_id, o.warehouse_id, o.buffer_start, o.open_qty_base as qty, false as dependent
  from public.v_open_so_lines o
  union all
  select k.item_id, k.warehouse_id, so.due_date - so.time_buffer_days, k.required_qty, true
  from (select distinct company_id from b) c
  cross join lateral private.full_kit_allocation(c.company_id) k
  join public.sales_orders so on so.id = k.sales_order_id
  where k.level > 0
), alloc as (
  select b.id as item_buffer_id,
         coalesce(sum(d.qty) filter (
           where d.buffer_start <= b.today or d.qty * 100 >= b.target_qty * b.spike_threshold_pct), 0) as allocated,
         coalesce(sum(d.qty) filter (
           where d.buffer_start > b.today and d.qty * 100 >= b.target_qty * b.spike_threshold_pct), 0) as spike_qty,
         coalesce(sum(d.qty) filter (where not d.dependent), 0) as open_orders,
         coalesce(sum(d.qty) filter (
           where d.dependent and (d.buffer_start <= b.today or d.qty * 100 >= b.target_qty * b.spike_threshold_pct)), 0)
           as dependent_allocated
  from b
  left join demand d on d.item_id = b.item_id and d.warehouse_id = b.warehouse_id
  group by b.id
), q as (
  select b.id as item_buffer_id, b.company_id, b.item_id, b.warehouse_id, b.target_qty, b.last_changed_on, b.today,
         coalesce(st.on_hand, 0) as on_hand,
         coalesce(oo.on_order, 0) as on_order,
         a.allocated, a.spike_qty, a.open_orders, a.dependent_allocated
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
       p.last_changed_on,
       p.dependent_allocated
from p
join public.items i       on i.id = p.item_id
join public.warehouses w  on w.id = p.warehouse_id
join public.uom_groups g  on g.id = i.uom_group_id
join public.uoms u        on u.id = g.base_uom_id;

-- Replenishment proposal. BUFFER lines unchanged (they follow v_buffer_status, which now includes dependent demand).
-- TO_ORDER lines: demand = open order quantity of the item + its dependent demand from every open order (all
-- orders, as before for direct demand); need = demand − on hand − on order. Model-specific components of made-to-
-- order items now get proposals before the parent is built. "allocated" holds that demand for TO_ORDER lines.
create or replace view public.v_replenishment
with (security_invoker = true) as
with to_order_demand as (
  select x.company_id, x.item_id, x.warehouse_id, sum(x.qty) as demand
  from (
    select o.company_id, o.item_id, o.warehouse_id, o.open_qty_base as qty
    from public.v_open_so_lines o
    union all
    select c.company_id, k.item_id, k.warehouse_id, k.required_qty
    from (select distinct company_id from public.sales_orders where status = 'OPEN') c
    cross join lateral private.full_kit_allocation(c.company_id) k
    where k.level > 0
  ) x
  group by x.company_id, x.item_id, x.warehouse_id
), need as (
  select company_id, item_id, warehouse_id, 'BUFFER'::text as source, replenish_qty as need_base,
         net_flow_penetration as priority_pct, net_flow_zone as zone, target_qty, on_hand, on_order, allocated
  from public.v_buffer_status
  where replenish_qty > 0
  union all
  select d.company_id, d.item_id, d.warehouse_id, 'TO_ORDER',
         d.demand - coalesce(st.on_hand, 0) - coalesce(oo.on_order, 0),
         null, null, null, coalesce(st.on_hand, 0), coalesce(oo.on_order, 0), d.demand
  from to_order_demand d
  join public.items i on i.id = d.item_id and i.replenishment_policy = 'TO_ORDER'
  left join public.item_warehouse_stock st on st.item_id = d.item_id and st.warehouse_id = d.warehouse_id
  left join public.v_on_order oo          on oo.item_id = d.item_id and oo.warehouse_id = d.warehouse_id
  where d.demand > coalesce(st.on_hand, 0) + coalesce(oo.on_order, 0)
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

-- -----------------------------------------------------------------------------
-- 3. Grants and indexes
-- -----------------------------------------------------------------------------

revoke all on public.v_full_kit_lines from anon;

-- allocation reads the open lines of each order (active BOM by item is covered by bom_headers_one_active_ux)
create index sales_order_lines_open_ix on public.sales_order_lines (sales_order_id) where line_status = 'OPEN';
