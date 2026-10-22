-- =============================================================================
-- Migration 006 — TOC stock buffers, buffer history, red/black reasons, DBM, replenishment proposal
--
--   item_buffers               target level per item and warehouse (TOC stock buffer; ~ B1 OITW MinStock/MaxStock
--                              used as one target, ERPNext Item Reorder) for items held to availability
--   v_buffer_status            buffer penetration and replenishment quantity per buffer, computed live
--   buffer_snapshots           one row per buffer (stock or sales order) per day: the history DBM and reasons work on
--   buffer_events              every entry into RED or BLACK; the user records the cause (reason code) for Pareto
--   buffer_change_proposals    Dynamic Buffer Management suggestions; changed only after user approval
--   v_replenishment            replenishment proposal: target − (on hand + on order − allocated), plus order-driven
--                              shortages of TO_ORDER items; the user converts lines into purchase orders
-- No SAP B1 equivalent for buffers and DBM (B1 MRP is forecast-driven). This is the intentional TOC core (Rule 4).
-- =============================================================================

insert into public.auth_objects (code, name, description, sort_order) values
  ('BUFFERS', 'Buffers', 'Stock buffer targets, buffer board, red/black reasons, buffer change approvals', 510);

alter table public.company_settings
  add column spike_threshold_pct smallint not null default 50,
  add column dbm_red_days        smallint not null default 7,
  add column dbm_green_days      smallint not null default 30,
  add column dbm_step_pct        smallint not null default 33;
alter table public.company_settings add constraint company_settings_dbm_ck check (
  spike_threshold_pct between 1 and 1000 and dbm_red_days > 0 and dbm_green_days > 0 and dbm_step_pct between 1 and 100);
comment on column public.company_settings.spike_threshold_pct is
  'An open sales order line counts against a stock buffer before its order buffer starts when its open quantity is '
  'at least this % of the buffer target (order spike, DDMRP qualified spike).';
comment on column public.company_settings.dbm_red_days is
  'DBM: a buffer in red or black on this many consecutive daily snapshots gets an increase proposal.';
comment on column public.company_settings.dbm_green_days is
  'DBM: a buffer in green on this many consecutive daily snapshots gets a decrease proposal.';
comment on column public.company_settings.dbm_step_pct is 'DBM: size of a proposed increase or decrease, % of the current target.';

-- -----------------------------------------------------------------------------
-- 1. Stock buffers
-- -----------------------------------------------------------------------------

create table public.item_buffers (
  id               uuid          not null default gen_random_uuid(),
  company_id       uuid          not null,
  item_id          uuid          not null,
  warehouse_id     uuid          not null,
  target_qty       numeric(18,6) not null,
  is_active        boolean       not null default true,
  last_changed_on  date          not null default current_date,
  remarks          text,
  created_at       timestamptz   not null default now(),
  created_by       uuid,
  updated_at       timestamptz   not null default now(),
  updated_by       uuid,
  constraint item_buffers_pk primary key (id),
  constraint item_buffers_company_id_uk unique (company_id, id),
  constraint item_buffers_uk unique (item_id, warehouse_id),
  constraint item_buffers_target_ck check (target_qty > 0),
  constraint item_buffers_item_fk foreign key (company_id, item_id) references public.items (company_id, id) on delete cascade,
  constraint item_buffers_wh_fk foreign key (company_id, warehouse_id) references public.warehouses (company_id, id)
);
comment on table public.item_buffers is
  'TOC stock buffer: target quantity (item base unit) held in a warehouse for an item replenished to availability '
  '(items.replenishment_policy = BUFFER). Changed by the user directly or by approving a DBM proposal.';
comment on column public.item_buffers.last_changed_on is
  'Date the target last changed. DBM waits a full observation window after a change before proposing again.';

create or replace function private.prepare_item_buffer()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  i public.items%rowtype;
begin
  select * into i from public.items where id = new.item_id;
  if i.is_template then
    raise exception 'Template item % cannot have a buffer; set it on the variants', i.item_code using errcode = '23514';
  end if;
  if i.item_type <> 'INVENTORY' or i.replenishment_policy <> 'BUFFER' then
    raise exception 'Item % must be an inventory item with replenishment policy BUFFER', i.item_code using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and (new.item_id <> old.item_id or new.warehouse_id <> old.warehouse_id) then
    raise exception 'Item and warehouse of a buffer cannot change' using errcode = '23514';
  end if;
  if tg_op = 'INSERT' or new.target_qty <> old.target_qty then
    new.last_changed_on := private.company_today(new.company_id);
  end if;
  return new;
end;
$$;

create trigger item_buffers_prepare
  before insert or update on public.item_buffers
  for each row execute function private.prepare_item_buffer();

-- -----------------------------------------------------------------------------
-- 2. Live buffer status
-- -----------------------------------------------------------------------------

-- Allocated = open sales order quantity that already "belongs" to customers: lines whose order time buffer has
-- started (buffer_start <= today) plus spikes (open qty >= spike % of target) whatever their date.
-- available = on hand − allocated; penetration = (target − available) / target; BLACK when nothing is available.
-- net_flow = on hand + on order − allocated; replenish_qty = target − net_flow (never below 0).
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

-- -----------------------------------------------------------------------------
-- 3. History: daily snapshots, red/black events with reasons
-- -----------------------------------------------------------------------------

create table public.buffer_snapshots (
  id                uuid          not null default gen_random_uuid(),
  company_id        uuid          not null,
  snapshot_date     date          not null,
  buffer_kind       text          not null,
  item_buffer_id    uuid,
  sales_order_id    uuid,
  penetration       numeric(8,0)  not null,
  zone              text          not null,
  target_qty        numeric(18,6),
  on_hand           numeric(18,6),
  available         numeric(18,6),
  created_at        timestamptz   not null default now(),
  constraint buffer_snapshots_pk primary key (id),
  constraint buffer_snapshots_kind_ck check (
    buffer_kind = 'STOCK' and item_buffer_id is not null and sales_order_id is null
    or buffer_kind = 'ORDER' and sales_order_id is not null and item_buffer_id is null),
  constraint buffer_snapshots_zone_ck check (zone in ('GREEN', 'YELLOW', 'RED', 'BLACK')),
  constraint buffer_snapshots_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint buffer_snapshots_buffer_fk foreign key (company_id, item_buffer_id) references public.item_buffers (company_id, id) on delete cascade,
  constraint buffer_snapshots_so_fk foreign key (company_id, sales_order_id) references public.sales_orders (company_id, id) on delete cascade
);
create unique index buffer_snapshots_stock_ux on public.buffer_snapshots (item_buffer_id, snapshot_date) where buffer_kind = 'STOCK';
create unique index buffer_snapshots_order_ux on public.buffer_snapshots (sales_order_id, snapshot_date) where buffer_kind = 'ORDER';
comment on table public.buffer_snapshots is
  'Buffer zone of every active stock buffer and open sales order, one row per day, written only by '
  'take_buffer_snapshot(). Basis for DBM (days in red / green) and for red/black events.';

create table public.buffer_events (
  id                uuid        not null default gen_random_uuid(),
  company_id        uuid        not null,
  buffer_kind       text        not null,
  item_buffer_id    uuid,
  sales_order_id    uuid,
  zone              text        not null,
  entered_on        date        not null,
  penetration       numeric(8,0) not null,
  reason_code_id    uuid,
  reason_note       text,
  reason_by         uuid,
  reason_at         timestamptz,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint buffer_events_pk primary key (id),
  constraint buffer_events_company_id_uk unique (company_id, id),
  constraint buffer_events_kind_ck check (
    buffer_kind = 'STOCK' and item_buffer_id is not null and sales_order_id is null
    or buffer_kind = 'ORDER' and sales_order_id is not null and item_buffer_id is null),
  constraint buffer_events_zone_ck check (zone in ('RED', 'BLACK')),
  constraint buffer_events_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint buffer_events_buffer_fk foreign key (company_id, item_buffer_id) references public.item_buffers (company_id, id) on delete cascade,
  constraint buffer_events_so_fk foreign key (company_id, sales_order_id) references public.sales_orders (company_id, id) on delete cascade,
  constraint buffer_events_reason_fk foreign key (company_id, reason_code_id) references public.reason_codes (company_id, id)
);
create unique index buffer_events_stock_ux on public.buffer_events (item_buffer_id, zone, entered_on) where buffer_kind = 'STOCK';
create unique index buffer_events_order_ux on public.buffer_events (sales_order_id, zone, entered_on) where buffer_kind = 'ORDER';
comment on table public.buffer_events is
  'One row each time a buffer enters RED or BLACK (from a better zone). The user records the cause with '
  'set_buffer_event_reason() (reason types BUFFER_RED / BUFFER_BLACK); v_buffer_reason_pareto ranks the causes.';

create or replace function public.set_buffer_event_reason(p_event_id uuid, p_reason_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.buffer_events%rowtype;
  v_uid uuid := (select auth.uid());
begin
  select * into e from public.buffer_events where id = p_event_id for update;
  if not found then
    raise exception 'Buffer event not found' using errcode = 'P0002';
  end if;
  -- Whoever works the order or the buffer may explain it: BUFFERS, SALES or INVENTORY with FULL.
  if v_uid is not null
     and e.company_id not in (select private.companies_with_access('BUFFERS', 'FULL'))
     and e.company_id not in (select private.companies_with_access('SALES', 'FULL'))
     and e.company_id not in (select private.companies_with_access('INVENTORY', 'FULL')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not exists (select 1 from public.reason_codes r where r.id = p_reason_id and r.company_id = e.company_id and r.is_active
                 and r.reason_type = case e.zone when 'RED' then 'BUFFER_RED' else 'BUFFER_BLACK' end) then
    raise exception 'A % reason of this company is required', case e.zone when 'RED' then 'BUFFER_RED' else 'BUFFER_BLACK' end
      using errcode = '23514';
  end if;
  update public.buffer_events
  set reason_code_id = p_reason_id, reason_note = nullif(trim(p_note), ''), reason_by = v_uid, reason_at = now()
  where id = e.id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Dynamic Buffer Management proposals
-- -----------------------------------------------------------------------------

create table public.buffer_change_proposals (
  id                uuid          not null default gen_random_uuid(),
  company_id        uuid          not null,
  item_buffer_id    uuid          not null,
  proposed_on       date          not null,
  direction         text          not null,
  current_target    numeric(18,6) not null,
  proposed_target   numeric(18,6) not null,
  basis             text          not null,
  status            text          not null default 'PENDING',
  approved_target   numeric(18,6),
  decided_by        uuid,
  decided_at        timestamptz,
  decision_note     text,
  created_at        timestamptz   not null default now(),
  created_by        uuid,
  updated_at        timestamptz   not null default now(),
  updated_by        uuid,
  constraint buffer_change_proposals_pk primary key (id),
  constraint buffer_change_proposals_direction_ck check (direction in ('INCREASE', 'DECREASE')),
  constraint buffer_change_proposals_status_ck check (status in ('PENDING', 'APPROVED', 'REJECTED', 'EXPIRED')),
  constraint buffer_change_proposals_qty_ck check (current_target > 0 and proposed_target > 0 and coalesce(approved_target, 1) > 0),
  constraint buffer_change_proposals_decided_ck check ((status in ('APPROVED', 'REJECTED')) = (decided_at is not null)),
  constraint buffer_change_proposals_buffer_fk foreign key (company_id, item_buffer_id)
    references public.item_buffers (company_id, id) on delete cascade
);
create unique index buffer_change_proposals_pending_ux on public.buffer_change_proposals (item_buffer_id) where status = 'PENDING';
comment on table public.buffer_change_proposals is
  'DBM suggestions: increase after dbm_red_days consecutive days in red/black, decrease after dbm_green_days in green. '
  'Targets change only through decide_buffer_change() (user approval). A pending proposal whose condition no longer '
  'holds is marked EXPIRED by the next snapshot.';

create or replace function public.decide_buffer_change(
  p_proposal_id uuid, p_approve boolean, p_target numeric default null, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  pr public.buffer_change_proposals%rowtype;
  v_uid uuid := (select auth.uid());
  v_target numeric := coalesce(p_target, 0);
begin
  select * into pr from public.buffer_change_proposals where id = p_proposal_id for update;
  if not found then
    raise exception 'Proposal not found' using errcode = 'P0002';
  end if;
  if v_uid is not null and pr.company_id not in (select private.companies_with_access('BUFFERS', 'FULL')) then
    raise exception 'Not authorized to change buffers' using errcode = '42501';
  end if;
  if pr.status <> 'PENDING' then
    raise exception 'Proposal is already %', pr.status using errcode = '23514';
  end if;
  v_target := coalesce(p_target, pr.proposed_target);
  if p_approve and v_target <= 0 then
    raise exception 'Target must be above zero' using errcode = '23514';
  end if;

  update public.buffer_change_proposals
  set status = case when p_approve then 'APPROVED' else 'REJECTED' end,
      approved_target = case when p_approve then v_target end,
      decided_by = v_uid, decided_at = now(), decision_note = nullif(trim(p_note), '')
  where id = pr.id;
  if p_approve then
    update public.item_buffers set target_qty = v_target where id = pr.item_buffer_id;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Daily snapshot: zones, red/black events, DBM proposals
-- -----------------------------------------------------------------------------

-- DBM condition per active stock buffer: all of the last dbm_red_days snapshots red/black -> INCREASE;
-- all of the last dbm_green_days snapshots green -> DECREASE; only if the target did not change inside that window.
create or replace function private.dbm_candidates(p_company_id uuid, p_today date)
returns table (item_buffer_id uuid, target_qty numeric, direction text, red_days bigint, green_days bigint)
language sql
stable
security definer
set search_path = ''
as $$
  with s as (select * from public.company_settings where company_id = p_company_id),
  w as (
    select ib.id, ib.target_qty, ib.last_changed_on,
           count(*) filter (where sn.snapshot_date > p_today - s.dbm_red_days and sn.zone in ('RED', 'BLACK')) as red_days,
           count(*) filter (where sn.snapshot_date > p_today - s.dbm_green_days and sn.zone = 'GREEN') as green_days
    from public.item_buffers ib
    cross join s
    join public.buffer_snapshots sn on sn.item_buffer_id = ib.id and sn.buffer_kind = 'STOCK' and sn.snapshot_date <= p_today
    where ib.company_id = p_company_id and ib.is_active
    group by ib.id, ib.target_qty, ib.last_changed_on
  )
  select w.id, w.target_qty,
         case when w.red_days >= s.dbm_red_days and w.last_changed_on <= p_today - s.dbm_red_days then 'INCREASE'
              when w.green_days >= s.dbm_green_days and w.last_changed_on <= p_today - s.dbm_green_days then 'DECREASE'
         end,
         w.red_days, w.green_days
  from w cross join s
$$;

-- Idempotent for a day: re-running replaces today's zones; events and proposals are not duplicated.
-- Called by a daily schedule (pg_cron) and when the buffer board opens, so a missed run heals itself.
create or replace function public.take_buffer_snapshot(p_company_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_today date := private.company_today(p_company_id);
  s public.company_settings%rowtype;
  v_rows integer;
begin
  if v_uid is not null and p_company_id not in (select private.user_company_ids()) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into s from public.company_settings where company_id = p_company_id;

  insert into public.buffer_snapshots
    (company_id, snapshot_date, buffer_kind, item_buffer_id, penetration, zone, target_qty, on_hand, available)
  select company_id, v_today, 'STOCK', item_buffer_id, penetration, zone, target_qty, on_hand, available
  from public.v_buffer_status where company_id = p_company_id
  on conflict (item_buffer_id, snapshot_date) where buffer_kind = 'STOCK'
  do update set penetration = excluded.penetration, zone = excluded.zone, target_qty = excluded.target_qty,
                on_hand = excluded.on_hand, available = excluded.available, created_at = now();
  get diagnostics v_rows = row_count;

  insert into public.buffer_snapshots (company_id, snapshot_date, buffer_kind, sales_order_id, penetration, zone)
  select company_id, v_today, 'ORDER', sales_order_id, penetration, zone
  from public.v_sales_order_buffer where company_id = p_company_id
  on conflict (sales_order_id, snapshot_date) where buffer_kind = 'ORDER'
  do update set penetration = excluded.penetration, zone = excluded.zone, created_at = now();

  -- Entries into RED or BLACK: today's zone is RED/BLACK and the latest earlier snapshot was better (or none).
  insert into public.buffer_events
    (company_id, buffer_kind, item_buffer_id, sales_order_id, zone, entered_on, penetration)
  select t.company_id, t.buffer_kind, t.item_buffer_id, t.sales_order_id, t.zone, v_today, t.penetration
  from public.buffer_snapshots t
  left join lateral (
    select p.zone from public.buffer_snapshots p
    where p.buffer_kind = t.buffer_kind and p.snapshot_date < v_today
      and (p.item_buffer_id = t.item_buffer_id or p.sales_order_id = t.sales_order_id)
    order by p.snapshot_date desc limit 1
  ) prev on true
  where t.company_id = p_company_id and t.snapshot_date = v_today and t.zone in ('RED', 'BLACK')
    and (prev.zone is null or prev.zone in ('GREEN', 'YELLOW') or (prev.zone = 'RED' and t.zone = 'BLACK'))
  on conflict do nothing;

  -- DBM: expire pending proposals whose condition no longer holds, then propose where it holds and none is pending.
  update public.buffer_change_proposals pr set status = 'EXPIRED'
  from private.dbm_candidates(p_company_id, v_today) c
  where pr.item_buffer_id = c.item_buffer_id and pr.status = 'PENDING' and pr.direction is distinct from c.direction;

  insert into public.buffer_change_proposals
    (company_id, item_buffer_id, proposed_on, direction, current_target, proposed_target, basis)
  select p_company_id, c.item_buffer_id, v_today, c.direction, c.target_qty,
         case c.direction
           when 'INCREASE' then ceil(c.target_qty * (100 + s.dbm_step_pct) / 100)
           else greatest(1, floor(c.target_qty * (100 - s.dbm_step_pct) / 100)) end,
         case c.direction
           when 'INCREASE' then format('Red or black on each of the last %s days', c.red_days)
           else format('Green on each of the last %s days', c.green_days) end
  from private.dbm_candidates(p_company_id, v_today) c
  where c.direction is not null
    and not exists (select 1 from public.buffer_change_proposals x where x.item_buffer_id = c.item_buffer_id and x.status = 'PENDING')
    -- a rejected proposal is not repeated until a full new observation window has passed
    and not exists (select 1 from public.buffer_change_proposals x
                    where x.item_buffer_id = c.item_buffer_id and x.status = 'REJECTED' and x.direction = c.direction
                      and x.proposed_on > v_today - case c.direction when 'INCREASE' then s.dbm_red_days else s.dbm_green_days end);

  return v_rows;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Replenishment proposal and reason Pareto
-- -----------------------------------------------------------------------------

-- One line per item and warehouse needing supply, highest urgency first:
--   BUFFER    stock buffers with net flow below target: replenish to target
--   TO_ORDER  items made/bought to order whose open sales orders exceed on hand + on order
-- suggested_purchase_qty: in the preferred supplier's unit, rounded up to its minimum and multiple.
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

create or replace view public.v_buffer_reason_pareto
with (security_invoker = true) as
select e.company_id, e.zone, e.buffer_kind, e.reason_code_id, r.code as reason_code, coalesce(r.name, 'No reason given') as reason_name,
       count(*) as events, min(e.entered_on) as first_on, max(e.entered_on) as last_on
from public.buffer_events e
left join public.reason_codes r on r.id = e.reason_code_id
group by e.company_id, e.zone, e.buffer_kind, e.reason_code_id, r.code, r.name;

-- -----------------------------------------------------------------------------
-- 7. RLS, grants, triggers, indexes
-- -----------------------------------------------------------------------------

select private.enable_company_rls('public.item_buffers', 'BUFFERS');
select private.enable_company_rls('public.buffer_snapshots', 'BUFFERS');
select private.enable_company_rls('public.buffer_events', 'BUFFERS');
select private.enable_company_rls('public.buffer_change_proposals', 'BUFFERS');

-- Buffers are the shared priority system: everyone who sells, buys or moves stock reads them.
drop policy rls_select on public.item_buffers;
create policy rls_select on public.item_buffers for select to authenticated
  using (company_id in (select private.companies_with_access('BUFFERS', 'READ'))
         or company_id in (select private.companies_with_access('INVENTORY', 'READ'))
         or company_id in (select private.companies_with_access('SALES', 'READ'))
         or company_id in (select private.companies_with_access('PURCHASING', 'READ')));
drop policy rls_select on public.buffer_events;
create policy rls_select on public.buffer_events for select to authenticated
  using (company_id in (select private.companies_with_access('BUFFERS', 'READ'))
         or company_id in (select private.companies_with_access('INVENTORY', 'READ'))
         or company_id in (select private.companies_with_access('SALES', 'READ')));

-- History and proposals are written by functions only.
revoke insert, update, delete on public.buffer_snapshots, public.buffer_events, public.buffer_change_proposals from authenticated;

revoke all on public.v_buffer_status, public.v_replenishment, public.v_buffer_reason_pareto from anon;

revoke all on function public.set_buffer_event_reason(uuid, uuid, text) from public, anon;
revoke all on function public.decide_buffer_change(uuid, boolean, numeric, text) from public, anon;
revoke all on function public.take_buffer_snapshot(uuid) from public, anon;
grant execute on function public.set_buffer_event_reason(uuid, uuid, text) to authenticated;
grant execute on function public.decide_buffer_change(uuid, boolean, numeric, text) to authenticated;
grant execute on function public.take_buffer_snapshot(uuid) to authenticated, service_role;

select private.attach_standard_triggers('public.item_buffers');
select private.attach_standard_triggers('public.buffer_events');
select private.attach_standard_triggers('public.buffer_change_proposals');

create index item_buffers_co_item_ix          on public.item_buffers (company_id, item_id);
create index item_buffers_wh_ix               on public.item_buffers (company_id, warehouse_id);
create index buffer_snapshots_co_date_ix      on public.buffer_snapshots (company_id, snapshot_date);
create index buffer_snapshots_buffer_ix       on public.buffer_snapshots (company_id, item_buffer_id);
create index buffer_snapshots_so_ix           on public.buffer_snapshots (company_id, sales_order_id);
create index buffer_events_co_ix              on public.buffer_events (company_id, entered_on);
create index buffer_events_buffer_ix          on public.buffer_events (company_id, item_buffer_id);
create index buffer_events_so_ix              on public.buffer_events (company_id, sales_order_id);
create index buffer_events_reason_ix          on public.buffer_events (company_id, reason_code_id);
create index buffer_change_proposals_buf_ix   on public.buffer_change_proposals (company_id, item_buffer_id);
