-- =============================================================================
-- Migration 003 — Inventory (quantities only)
-- Warehouses, inventory documents (goods receipt / goods issue / transfer /
-- receipt from production with backflush), stock ledger and on-hand.
--
-- SAP Business One mapping:
--   warehouses                ~ OWHS
--   items.default_warehouse   ~ OITM.DfltWH
--   bom_lines.issue_warehouse ~ ITT1.Warehouse
--   inventory_documents/lines ~ OIGN/IGN1, OIGE/IGE1, OWTR/WTR1 (one structure, behaviour by category)
--   stock_movements           ~ OINM (inventory audit / ledger)
--   item_warehouse_stock      ~ OITW.OnHand
-- Deviations:
--   * Quantities only, no valuation (no GL, D-029).
--   * Receipt from production is posted without a production order (D-017);
--     production orders come with the production/DBR module.
--   * Cancellation creates a reversing document, like B1 "Cancel", for every type.
-- =============================================================================

insert into public.auth_objects (code, name, description, sort_order) values
  ('WAREHOUSES',     'Warehouses',            'Warehouse master data', 210),
  ('INVENTORY',      'Inventory documents',   'Create and post goods receipts, issues, transfers, receipts from production; read stock', 220),
  ('STOCK_OVERRIDE', 'Negative stock override','Post a document that takes stock below zero, with a reason', 230);

insert into public.reason_types (code, name) values ('OPENING_STOCK', 'Opening stock')
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- 0. Indexes flagged by the Supabase performance advisor after migration 001
-- -----------------------------------------------------------------------------
create index number_range_counters_range_ix   on public.number_range_counters (company_id, number_range_id);
create index role_permissions_role_ix         on public.role_permissions (company_id, role_id);
create index status_definitions_category_ix   on public.status_definitions (category);
create index user_company_roles_company_role_ix on public.user_company_roles (company_id, role_id);

-- -----------------------------------------------------------------------------
-- 1. Warehouses
-- -----------------------------------------------------------------------------

create table public.warehouses (
  id          uuid        not null default gen_random_uuid(),
  company_id  uuid        not null,
  code        text        not null,
  name        text        not null,
  is_default  boolean     not null default false,
  address     text,
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint warehouses_pk primary key (id),
  constraint warehouses_company_id_uk unique (company_id, id),
  constraint warehouses_code_uk unique (company_id, code),
  constraint warehouses_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint warehouses_default_active_ck check (not is_default or is_active),
  constraint warehouses_company_fk foreign key (company_id) references public.companies (id) on delete cascade
);
create unique index warehouses_one_default_ux on public.warehouses (company_id) where is_default;
comment on table public.warehouses is
  'Stock locations (= B1 OWHS). Exactly one default (main) warehouse per company is used when an item or BOM line names none.';

alter table public.items add column default_warehouse_id uuid;
alter table public.items add constraint items_default_warehouse_fk
  foreign key (company_id, default_warehouse_id) references public.warehouses (company_id, id);
comment on column public.items.default_warehouse_id is
  'Warehouse used for this item when a document line names none (= B1 default warehouse). NULL = company main warehouse.';

alter table public.bom_lines add column issue_warehouse_id uuid;
alter table public.bom_lines add constraint bom_lines_issue_warehouse_fk
  foreign key (company_id, issue_warehouse_id) references public.warehouses (company_id, id);
comment on column public.bom_lines.issue_warehouse_id is
  'Warehouse the component is backflushed from (= B1 ITT1 warehouse). NULL = component default, then company main.';

-- Default warehouse for an item: item default, else company main warehouse.
create or replace function private.default_warehouse(p_company_id uuid, p_item_id uuid default null)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select i.default_warehouse_id from public.items i where i.id = p_item_id),
    (select w.id from public.warehouses w where w.company_id = p_company_id and w.is_default)
  )
$$;

-- -----------------------------------------------------------------------------
-- 2. Inventory documents
-- -----------------------------------------------------------------------------

create table public.inventory_documents (
  id                       uuid        not null default gen_random_uuid(),
  company_id               uuid        not null,
  document_type_id         uuid        not null,
  category                 text        not null,
  doc_number               text,
  doc_date                 date        not null default current_date,
  status                   text        not null default 'DRAFT',
  reason_code_id           uuid,
  reference                text,
  remarks                  text,
  reverses_document_id     uuid,
  cancelled_by_document_id uuid,
  posted_at                timestamptz,
  posted_by                uuid,
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  constraint inventory_documents_pk primary key (id),
  constraint inventory_documents_company_id_uk unique (company_id, id),
  constraint inventory_documents_number_uk unique (company_id, document_type_id, doc_number),
  constraint inventory_documents_status_ck check (status in ('DRAFT', 'POSTED', 'CANCELLED')),
  constraint inventory_documents_category_ck check (
    category in ('GOODS_RECEIPT', 'GOODS_ISSUE', 'INVENTORY_TRANSFER', 'RECEIPT_FROM_PRODUCTION')),
  constraint inventory_documents_posted_ck check (
    (status = 'DRAFT') = (doc_number is null and posted_at is null)),
  constraint inventory_documents_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint inventory_documents_type_fk foreign key (company_id, document_type_id)
    references public.document_types (company_id, id),
  constraint inventory_documents_category_fk foreign key (category) references public.document_categories (code),
  constraint inventory_documents_reason_fk foreign key (company_id, reason_code_id)
    references public.reason_codes (company_id, id),
  constraint inventory_documents_reverses_fk foreign key (company_id, reverses_document_id)
    references public.inventory_documents (company_id, id),
  constraint inventory_documents_cancelled_by_fk foreign key (company_id, cancelled_by_document_id)
    references public.inventory_documents (company_id, id)
);
comment on table public.inventory_documents is
  'Header of every stock-moving document without a business partner: goods receipt, goods issue, inventory transfer, '
  'receipt from production (= B1 OIGN / OIGE / OWTR). DRAFT can be edited or deleted; POSTED is immutable and is '
  'cancelled only by a reversing document.';
comment on column public.inventory_documents.category is 'Copied from the document type; decides posting behaviour.';

create table public.inventory_document_lines (
  id               uuid          not null default gen_random_uuid(),
  company_id       uuid          not null,
  document_id      uuid          not null,
  line_no          integer       not null,
  item_id          uuid          not null,
  direction        smallint      not null,
  quantity         numeric(18,6) not null,
  uom_id           uuid          not null,
  quantity_base    numeric(18,6) not null,
  warehouse_id     uuid          not null,
  to_warehouse_id  uuid,
  remarks          text,
  created_at       timestamptz   not null default now(),
  created_by       uuid,
  updated_at       timestamptz   not null default now(),
  updated_by       uuid,
  constraint inventory_document_lines_pk primary key (id),
  constraint inventory_document_lines_line_uk unique (document_id, line_no),
  constraint inventory_document_lines_qty_ck check (quantity > 0 and quantity_base > 0),
  constraint inventory_document_lines_direction_ck check (direction in (-1, 1)),
  constraint inventory_document_lines_transfer_ck check (to_warehouse_id is distinct from warehouse_id),
  constraint inventory_document_lines_doc_fk foreign key (company_id, document_id)
    references public.inventory_documents (company_id, id) on delete cascade,
  constraint inventory_document_lines_item_fk foreign key (company_id, item_id) references public.items (company_id, id),
  constraint inventory_document_lines_uom_fk foreign key (company_id, uom_id) references public.uoms (company_id, id),
  constraint inventory_document_lines_wh_fk foreign key (company_id, warehouse_id) references public.warehouses (company_id, id),
  constraint inventory_document_lines_to_wh_fk foreign key (company_id, to_warehouse_id) references public.warehouses (company_id, id)
);
comment on table public.inventory_document_lines is
  'Document lines. direction +1 = into warehouse_id, -1 = out of warehouse_id. Transfers move from warehouse_id '
  'to to_warehouse_id. quantity_base is the quantity in the item''s base UoM, filled by trigger.';

-- Header: category from document type; posted documents are immutable apart from the cancellation link.
create or replace function private.prepare_inventory_document()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_category text;
begin
  if tg_op = 'INSERT' then
    select dt.category into v_category from public.document_types dt
    where dt.id = new.document_type_id and dt.company_id = new.company_id and dt.is_active;
    if v_category is null then
      raise exception 'Document type is unknown or inactive in this company' using errcode = '23503';
    end if;
    new.category := v_category;
    new.status := 'DRAFT';
    new.doc_number := null;
    new.posted_at := null;
    new.posted_by := null;
    new.cancelled_by_document_id := null;
    return new;
  end if;

  -- UPDATE
  if new.category <> old.category or new.document_type_id <> old.document_type_id then
    raise exception 'The document type of a document cannot be changed' using errcode = '23514';
  end if;

  if old.status <> 'DRAFT'
     and current_setting('erp.posting', true) is distinct from 'on' then
    raise exception 'Document % is % and cannot be changed', old.doc_number, old.status using errcode = '23514';
  end if;
  if old.status = 'DRAFT' and new.status <> 'DRAFT'
     and current_setting('erp.posting', true) is distinct from 'on' then
    raise exception 'Use public.post_inventory_document() to post' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger inventory_documents_prepare
  before insert or update on public.inventory_documents
  for each row execute function private.prepare_inventory_document();

-- Posted documents cannot be deleted.
create or replace function private.block_posted_document_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status <> 'DRAFT' then
    raise exception 'Posted document % cannot be deleted; cancel it instead', old.doc_number using errcode = '23514';
  end if;
  return old;
end;
$$;

create trigger inventory_documents_block_delete
  before delete on public.inventory_documents
  for each row execute function private.block_posted_document_delete();

-- Lines: only on drafts; defaults for direction and warehouse; base quantity; UoM and decimals check.
create or replace function private.prepare_inventory_line()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  d  public.inventory_documents%rowtype;
  i  public.items%rowtype;
  v_decimals smallint;
begin
  select * into d from public.inventory_documents
  where id = coalesce(new.document_id, old.document_id);

  if d.status <> 'DRAFT' and current_setting('erp.posting', true) is distinct from 'on' then
    raise exception 'Lines of posted document % cannot be changed', d.doc_number using errcode = '23514';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  select * into i from public.items where id = new.item_id;
  if i.is_template then
    raise exception 'Template item % cannot be moved; use a variant', i.item_code using errcode = '23514';
  end if;
  if i.item_type <> 'INVENTORY' then
    raise exception 'Item % is not an inventory item', i.item_code using errcode = '23514';
  end if;

  new.uom_id := coalesce(new.uom_id, i.inventory_uom_id);
  new.warehouse_id := coalesce(new.warehouse_id, private.default_warehouse(new.company_id, new.item_id));
  if new.warehouse_id is null then
    raise exception 'No warehouse given and company has no main warehouse' using errcode = '23502';
  end if;

  if new.direction is null then
    new.direction := case d.category
                       when 'GOODS_RECEIPT' then 1
                       when 'GOODS_ISSUE' then -1
                       when 'INVENTORY_TRANSFER' then -1
                     end;
  end if;
  if new.direction is null then
    raise exception 'Direction is required on receipt-from-production lines (+1 product, -1 component)' using errcode = '23502';
  end if;

  -- Category rules (reversing documents invert the direction)
  if d.category = 'GOODS_RECEIPT' and new.direction <> (case when d.reverses_document_id is null then 1 else -1 end)
  or d.category = 'GOODS_ISSUE'   and new.direction <> (case when d.reverses_document_id is null then -1 else 1 end) then
    raise exception 'Line direction does not match a % document', d.category using errcode = '23514';
  end if;
  if (d.category = 'INVENTORY_TRANSFER') <> (new.to_warehouse_id is not null) then
    raise exception 'A target warehouse is required on transfers and only on transfers' using errcode = '23514';
  end if;

  select u.decimals into v_decimals from public.uoms u where u.id = new.uom_id;
  if new.quantity <> round(new.quantity, v_decimals) then
    raise exception 'Quantity % has more than % decimals allowed for this UoM', new.quantity, v_decimals using errcode = '23514';
  end if;

  new.quantity_base := private.to_base_qty(i.uom_group_id, new.uom_id, new.quantity);
  if new.quantity_base is null then
    raise exception 'UoM is not in the UoM group of item %', i.item_code using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger inventory_document_lines_prepare
  before insert or update or delete on public.inventory_document_lines
  for each row execute function private.prepare_inventory_line();

-- -----------------------------------------------------------------------------
-- 3. Stock ledger and on-hand
-- -----------------------------------------------------------------------------

create table public.stock_movements (
  id                       bigint        generated always as identity,
  company_id               uuid          not null,
  item_id                  uuid          not null,
  warehouse_id             uuid          not null,
  posting_date             date          not null,
  quantity_base            numeric(18,6) not null,
  balance_after            numeric(18,6) not null,
  category                 text          not null,
  document_id              uuid          not null,
  document_line_id         uuid          not null,
  override_reason_code_id  uuid,
  created_at               timestamptz   not null default now(),
  created_by               uuid,
  constraint stock_movements_pk primary key (id),
  constraint stock_movements_qty_ck check (quantity_base <> 0),
  constraint stock_movements_item_fk foreign key (company_id, item_id) references public.items (company_id, id),
  constraint stock_movements_wh_fk foreign key (company_id, warehouse_id) references public.warehouses (company_id, id),
  constraint stock_movements_doc_fk foreign key (company_id, document_id) references public.inventory_documents (company_id, id),
  constraint stock_movements_line_fk foreign key (document_line_id) references public.inventory_document_lines (id),
  constraint stock_movements_reason_fk foreign key (company_id, override_reason_code_id) references public.reason_codes (company_id, id)
);
comment on table public.stock_movements is
  'Stock ledger (= B1 OINM): one signed row per item, warehouse and posting, in base UoM. Append-only; written only '
  'by public.post_inventory_document(). On-hand at any date = sum of quantity_base up to that date.';

create table public.item_warehouse_stock (
  company_id        uuid          not null,
  item_id           uuid          not null,
  warehouse_id      uuid          not null,
  on_hand           numeric(18,6) not null default 0,
  last_movement_at  timestamptz,
  constraint item_warehouse_stock_pk primary key (item_id, warehouse_id),
  constraint item_warehouse_stock_item_fk foreign key (company_id, item_id) references public.items (company_id, id),
  constraint item_warehouse_stock_wh_fk foreign key (company_id, warehouse_id) references public.warehouses (company_id, id)
);
comment on table public.item_warehouse_stock is
  'Current on-hand per item and warehouse in base UoM (= B1 OITW.OnHand). Maintained only by posting; '
  'always equals the sum of stock_movements (checked in tests).';

-- Ledger rows can never be changed or removed, even by the table owner through the API.
create or replace function private.block_ledger_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'The stock ledger is append-only' using errcode = '23514';
end;
$$;

create trigger stock_movements_append_only
  before update or delete on public.stock_movements
  for each row execute function private.block_ledger_change();

-- -----------------------------------------------------------------------------
-- 4. Posting
-- -----------------------------------------------------------------------------

-- Posts a draft: assigns the number, writes the ledger, updates on-hand.
-- Negative stock is refused unless the company allows it or the caller has STOCK_OVERRIDE=FULL
-- and supplies a NEGATIVE_STOCK_OVERRIDE reason, which is stored on the affected movements.
-- Stock rows are locked in a fixed order (item, warehouse) so concurrent postings queue instead of deadlocking.
create or replace function public.post_inventory_document(
  p_document_id        uuid,
  p_override_reason_id uuid default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  d            public.inventory_documents%rowtype;
  v_range_id   uuid;
  v_number     text;
  v_allow_neg  boolean;
  v_uid        uuid := (select auth.uid());
  m            record;
  v_balance    numeric;
  v_plus       int;
  v_lines      int;
begin
  select * into d from public.inventory_documents where id = p_document_id for update;
  if not found then
    raise exception 'Document not found' using errcode = 'P0002';
  end if;

  -- Authorization (function bypasses RLS, so check explicitly)
  if v_uid is not null and d.company_id not in (select private.companies_with_access('INVENTORY', 'FULL')) then
    raise exception 'Not authorized to post inventory documents in this company' using errcode = '42501';
  end if;
  if d.status <> 'DRAFT' then
    raise exception 'Document % is already %', d.doc_number, d.status using errcode = '23514';
  end if;

  select count(*), count(*) filter (where direction = 1) into v_lines, v_plus
  from public.inventory_document_lines where document_id = d.id;
  if v_lines = 0 then
    raise exception 'Document has no lines' using errcode = '23514';
  end if;
  if d.category = 'RECEIPT_FROM_PRODUCTION' and d.reverses_document_id is null and v_plus <> 1 then
    raise exception 'A receipt from production needs exactly one product line (+1)' using errcode = '23514';
  end if;

  if p_override_reason_id is not null then
    if v_uid is not null and d.company_id not in (select private.companies_with_access('STOCK_OVERRIDE', 'FULL')) then
      raise exception 'Not authorized to override negative stock' using errcode = '42501';
    end if;
    if not exists (select 1 from public.reason_codes r
                   where r.id = p_override_reason_id and r.company_id = d.company_id
                     and r.reason_type = 'NEGATIVE_STOCK_OVERRIDE' and r.is_active) then
      raise exception 'Override reason must be an active NEGATIVE_STOCK_OVERRIDE reason of this company' using errcode = '23514';
    end if;
  end if;

  select s.allow_negative_stock into v_allow_neg from public.company_settings s where s.company_id = d.company_id;

  -- Number
  select dt.default_number_range_id into v_range_id from public.document_types dt where dt.id = d.document_type_id;
  if v_range_id is null then
    raise exception 'Document type has no numbering series' using errcode = '23502';
  end if;
  v_number := private.next_number(v_range_id, '', d.doc_date);

  -- Make sure every stock row exists, then lock them all in a fixed order
  insert into public.item_warehouse_stock (company_id, item_id, warehouse_id)
  select distinct d.company_id, x.item_id, x.warehouse_id
  from (
    select l.item_id, l.warehouse_id from public.inventory_document_lines l where l.document_id = d.id
    union
    select l.item_id, l.to_warehouse_id from public.inventory_document_lines l
    where l.document_id = d.id and l.to_warehouse_id is not null
  ) x
  on conflict (item_id, warehouse_id) do nothing;

  perform 1
  from public.item_warehouse_stock s
  where (s.item_id, s.warehouse_id) in (
    select l.item_id, l.warehouse_id from public.inventory_document_lines l where l.document_id = d.id
    union
    select l.item_id, l.to_warehouse_id from public.inventory_document_lines l
    where l.document_id = d.id and l.to_warehouse_id is not null)
  order by s.item_id, s.warehouse_id
  for update;

  -- Apply movements: outgoing first, so a transfer within one document cannot hide a shortage
  for m in
    select l.id as line_id, l.line_no, l.item_id, l.warehouse_id as wh, l.direction * l.quantity_base as qty
    from public.inventory_document_lines l where l.document_id = d.id
    union all
    select l.id, l.line_no, l.item_id, l.to_warehouse_id, -l.direction * l.quantity_base
    from public.inventory_document_lines l where l.document_id = d.id and l.to_warehouse_id is not null
    order by qty, line_no
  loop
    update public.item_warehouse_stock s
    set on_hand = s.on_hand + m.qty, last_movement_at = now()
    where s.item_id = m.item_id and s.warehouse_id = m.wh
    returning s.on_hand into v_balance;

    if v_balance < 0 and not v_allow_neg and p_override_reason_id is null then
      raise exception 'Insufficient stock: item % in warehouse % would go to % (line %)',
        (select item_code from public.items where id = m.item_id),
        (select code from public.warehouses where id = m.wh),
        v_balance, m.line_no
        using errcode = '23514', hint = 'Post the missing receipt first, or override with a NEGATIVE_STOCK_OVERRIDE reason';
    end if;

    insert into public.stock_movements
      (company_id, item_id, warehouse_id, posting_date, quantity_base, balance_after, category,
       document_id, document_line_id, override_reason_code_id, created_by)
    values
      (d.company_id, m.item_id, m.wh, d.doc_date, m.qty, v_balance, d.category,
       d.id, m.line_id, case when v_balance < 0 then p_override_reason_id end, v_uid);
  end loop;

  perform set_config('erp.posting', 'on', true);
  update public.inventory_documents
  set status = 'POSTED', doc_number = v_number, posted_at = now(), posted_by = v_uid
  where id = d.id;
  perform set_config('erp.posting', 'off', true);

  return v_number;
end;
$$;
comment on function public.post_inventory_document(uuid, uuid) is
  'Posts a draft inventory document: number, ledger rows, on-hand. Refuses negative stock unless overridden with a reason.';

-- Cancels a posted document by creating and posting a reversing document of the same type (B1 "Cancel").
create or replace function public.cancel_inventory_document(
  p_document_id        uuid,
  p_reason_code_id     uuid,
  p_override_reason_id uuid default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  d        public.inventory_documents%rowtype;
  v_uid    uuid := (select auth.uid());
  v_rev_id uuid;
  v_number text;
begin
  select * into d from public.inventory_documents where id = p_document_id for update;
  if not found then
    raise exception 'Document not found' using errcode = 'P0002';
  end if;
  if v_uid is not null and d.company_id not in (select private.companies_with_access('INVENTORY', 'FULL')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if d.status <> 'POSTED' or d.reverses_document_id is not null then
    raise exception 'Only a posted original document can be cancelled' using errcode = '23514';
  end if;
  if not exists (select 1 from public.reason_codes r
                 where r.id = p_reason_code_id and r.company_id = d.company_id
                   and r.reason_type = 'CANCELLATION' and r.is_active) then
    raise exception 'A CANCELLATION reason of this company is required' using errcode = '23514';
  end if;

  insert into public.inventory_documents
    (company_id, document_type_id, doc_date, reason_code_id, reference, remarks, reverses_document_id)
  values
    (d.company_id, d.document_type_id, current_date, p_reason_code_id, d.doc_number,
     'Cancellation of ' || d.doc_number, d.id)
  returning id into v_rev_id;

  insert into public.inventory_document_lines
    (company_id, document_id, line_no, item_id, direction, quantity, uom_id, warehouse_id, to_warehouse_id, remarks)
  select company_id, v_rev_id, line_no, item_id, -direction, quantity, uom_id, warehouse_id, to_warehouse_id, remarks
  from public.inventory_document_lines where document_id = d.id;

  v_number := public.post_inventory_document(v_rev_id, p_override_reason_id);

  perform set_config('erp.posting', 'on', true);
  update public.inventory_documents
  set status = 'CANCELLED', cancelled_by_document_id = v_rev_id
  where id = d.id;
  perform set_config('erp.posting', 'off', true);

  return v_number;
end;
$$;
comment on function public.cancel_inventory_document(uuid, uuid, uuid) is
  'Cancels a posted document by posting a reversing document (same type, inverted lines) and marking the original CANCELLED.';

-- Fills a draft receipt from production: one product line (+1) and one line per BACKFLUSH component (-1)
-- of the item's active BOM, single level, quantities scaled through UoM conversions.
-- Warehouses: product -> p_warehouse_id / item default / main; components -> BOM line issue warehouse /
-- component default / main. Lines stay editable until posting. Runs with the caller's rights (RLS applies).
create or replace function public.fill_production_receipt(
  p_document_id   uuid,
  p_item_id       uuid,
  p_quantity      numeric,
  p_uom_id        uuid default null,
  p_warehouse_id  uuid default null
)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  d       public.inventory_documents%rowtype;
  i       public.items%rowtype;
  h       public.bom_headers%rowtype;
  v_uom   uuid;
  v_factor numeric;
  v_count integer;
begin
  select * into d from public.inventory_documents where id = p_document_id;
  if not found or d.category <> 'RECEIPT_FROM_PRODUCTION' or d.status <> 'DRAFT' then
    raise exception 'Expected a draft receipt from production' using errcode = '23514';
  end if;

  select * into i from public.items where id = p_item_id and company_id = d.company_id;
  select * into h from public.bom_headers where item_id = p_item_id and is_active;
  if h.id is null then
    raise exception 'Item % has no active BOM', i.item_code using errcode = '23514';
  end if;
  v_uom := coalesce(p_uom_id, i.inventory_uom_id);

  -- parent quantity expressed in multiples of the BOM base quantity
  v_factor := private.to_base_qty(i.uom_group_id, v_uom, p_quantity)
            / private.to_base_qty(i.uom_group_id, h.uom_id, h.base_quantity);

  delete from public.inventory_document_lines where document_id = d.id;

  insert into public.inventory_document_lines
    (company_id, document_id, line_no, item_id, direction, quantity, uom_id, warehouse_id)
  values
    (d.company_id, d.id, 10, p_item_id, 1, p_quantity, v_uom,
     coalesce(p_warehouse_id, private.default_warehouse(d.company_id, p_item_id)));

  insert into public.inventory_document_lines
    (company_id, document_id, line_no, item_id, direction, quantity, uom_id, warehouse_id)
  select d.company_id, d.id, 10 + l.line_no, l.component_item_id, -1, l.quantity * v_factor, l.uom_id,
         coalesce(l.issue_warehouse_id, private.default_warehouse(d.company_id, l.component_item_id))
  from public.bom_lines l
  where l.bom_id = h.id and l.issue_method = 'BACKFLUSH';

  get diagnostics v_count = row_count;
  return v_count + 1;
end;
$$;
comment on function public.fill_production_receipt(uuid, uuid, numeric, uuid, uuid) is
  'Fills a draft receipt from production from the active BOM (BACKFLUSH lines, single level). Returns number of lines.';

-- Current stock per item and warehouse in base UoM, with codes for display. Respects RLS.
create or replace view public.v_stock_on_hand
with (security_invoker = true) as
select s.company_id, s.item_id, i.item_code, i.name as item_name,
       s.warehouse_id, w.code as warehouse_code,
       s.on_hand, u.code as base_uom, s.last_movement_at
from public.item_warehouse_stock s
join public.items i      on i.id = s.item_id
join public.warehouses w on w.id = s.warehouse_id
join public.uom_groups g on g.id = i.uom_group_id
join public.uoms u       on u.id = g.base_uom_id;

-- -----------------------------------------------------------------------------
-- 5. RLS, grants, triggers, indexes
-- -----------------------------------------------------------------------------

select private.enable_company_rls('public.warehouses',               'WAREHOUSES');

-- Warehouses and units of measure are basic reference data: every user assigned to the company may
-- read them (otherwise stock and document screens cannot show codes). Changing them still needs FULL.
drop policy rls_select on public.warehouses;
create policy rls_select on public.warehouses for select to authenticated
  using (company_id in (select private.user_company_ids()));
drop policy rls_select on public.uoms;
create policy rls_select on public.uoms for select to authenticated
  using (company_id in (select private.user_company_ids()));
drop policy rls_select on public.uom_groups;
create policy rls_select on public.uom_groups for select to authenticated
  using (company_id in (select private.user_company_ids()));
drop policy rls_select on public.uom_group_conversions;
create policy rls_select on public.uom_group_conversions for select to authenticated
  using (company_id in (select private.user_company_ids()));
select private.enable_company_rls('public.inventory_documents',      'INVENTORY');
select private.enable_company_rls('public.inventory_document_lines', 'INVENTORY');

-- Ledger and on-hand: read with INVENTORY=READ, never written through the API.
alter table public.stock_movements enable row level security;
revoke all on public.stock_movements from anon;
revoke insert, update, delete, truncate on public.stock_movements from authenticated;
create policy rls_select on public.stock_movements for select to authenticated
  using (company_id in (select private.companies_with_access('INVENTORY', 'READ')));

alter table public.item_warehouse_stock enable row level security;
revoke all on public.item_warehouse_stock from anon;
revoke insert, update, delete, truncate on public.item_warehouse_stock from authenticated;
create policy rls_select on public.item_warehouse_stock for select to authenticated
  using (company_id in (select private.companies_with_access('INVENTORY', 'READ')));

revoke all on public.v_stock_on_hand from anon;

revoke all on function public.post_inventory_document(uuid, uuid) from public, anon;
revoke all on function public.cancel_inventory_document(uuid, uuid, uuid) from public, anon;
revoke all on function public.fill_production_receipt(uuid, uuid, numeric, uuid, uuid) from public, anon;
grant execute on function public.post_inventory_document(uuid, uuid) to authenticated;
grant execute on function public.cancel_inventory_document(uuid, uuid, uuid) to authenticated;
grant execute on function public.fill_production_receipt(uuid, uuid, numeric, uuid, uuid) to authenticated;
grant execute on function private.default_warehouse(uuid, uuid) to authenticated;

select private.attach_standard_triggers('public.warehouses');
select private.attach_standard_triggers('public.inventory_documents');
select private.attach_standard_triggers('public.inventory_document_lines');

create index items_default_warehouse_ix            on public.items (company_id, default_warehouse_id);
create index bom_lines_issue_warehouse_ix          on public.bom_lines (company_id, issue_warehouse_id);
create index inventory_documents_type_ix           on public.inventory_documents (company_id, document_type_id);
create index inventory_documents_category_ix       on public.inventory_documents (category);
create index inventory_documents_reason_ix         on public.inventory_documents (company_id, reason_code_id);
create index inventory_documents_reverses_ix       on public.inventory_documents (company_id, reverses_document_id);
create index inventory_documents_cancelled_by_ix   on public.inventory_documents (company_id, cancelled_by_document_id);
create index inventory_documents_date_ix           on public.inventory_documents (company_id, doc_date desc);
create index inventory_document_lines_doc_ix       on public.inventory_document_lines (company_id, document_id);
create index inventory_document_lines_item_ix      on public.inventory_document_lines (company_id, item_id);
create index inventory_document_lines_uom_ix       on public.inventory_document_lines (company_id, uom_id);
create index inventory_document_lines_wh_ix        on public.inventory_document_lines (company_id, warehouse_id);
create index inventory_document_lines_to_wh_ix     on public.inventory_document_lines (company_id, to_warehouse_id);
create index stock_movements_item_ix               on public.stock_movements (company_id, item_id, warehouse_id, posting_date);
create index stock_movements_wh_ix                 on public.stock_movements (company_id, warehouse_id);
create index stock_movements_doc_ix                on public.stock_movements (company_id, document_id);
create index stock_movements_line_ix               on public.stock_movements (document_line_id);
create index stock_movements_reason_ix             on public.stock_movements (company_id, override_reason_code_id);
create index item_warehouse_stock_company_item_ix  on public.item_warehouse_stock (company_id, item_id);
create index item_warehouse_stock_wh_ix            on public.item_warehouse_stock (company_id, warehouse_id);
