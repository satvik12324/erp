-- =============================================================================
-- Migration 004 — Business partners and purchasing
--
-- Reference designs: SAP Business One (primary) and ERPNext (secondary, D-034).
--   business_partners            ~ B1 OCRD (card type S/C/L)          ~ ERPNext Supplier/Customer
--   bp_addresses / bp_contacts   ~ B1 CRD1 / OCPR                       ~ ERPNext Address / Contact
--   item_suppliers               ~ B1 OSCN catalog numbers + lead time  ~ ERPNext Item Supplier
--   purchase_orders / _lines     ~ B1 OPOR / POR1                       ~ ERPNext Purchase Order (Item)
--   purchase_order_line_prices   price kept apart from quantities (D-008: store users receive without seeing prices)
--   Goods receipt PO             ~ B1 OPDN / PDN1, implemented as an inventory document category with a supplier
--                                  and a link from each line to its PO line (ERPNext Purchase Receipt Item.purchase_order_item)
--   v_on_order / v_projected_stock ~ B1 OITW.OnOrder, ERPNext Bin.ordered_qty / projected_qty
--   over_receipt_pct + OVER_RECEIPT ~ ERPNext Stock Settings over_delivery_receipt_allowance + role allowed to exceed
-- Deviations:
--   * Two dates per PO line, as in ERPNext: required_date (when we need it) and expected_date (supplier promise).
--   * Lead-time statistics per item and supplier are derived from receipts (not in B1 or ERPNext).
-- =============================================================================

insert into public.auth_objects (code, name, description, sort_order) values
  ('BUSINESS_PARTNERS', 'Business partners',   'Suppliers and customers, addresses, contacts', 310),
  ('PURCHASING',        'Purchasing',          'Purchase orders, item-supplier data, receipt against PO', 320),
  ('PURCHASE_PRICES',   'Purchase prices',     'See and change prices on purchase orders', 330),
  ('OVER_RECEIPT',      'Over-receipt',        'Receive more than ordered beyond the company tolerance', 340);

insert into public.reason_types (code, name) values ('PO_CLOSE', 'Purchase order closed short')
on conflict (code) do nothing;

alter table public.company_settings add column over_receipt_pct numeric(6,2) not null default 0;
alter table public.company_settings add constraint company_settings_over_receipt_ck check (over_receipt_pct between 0 and 1000);
comment on column public.company_settings.over_receipt_pct is
  'How much more than ordered may be received against a PO line, in % (ERPNext over_delivery_receipt_allowance). '
  'Users with OVER_RECEIPT=FULL may exceed it.';

-- -----------------------------------------------------------------------------
-- 1. Business partners
-- -----------------------------------------------------------------------------

create table public.business_partners (
  id                      uuid        not null default gen_random_uuid(),
  company_id              uuid        not null,
  code                    text        not null,
  name                    text        not null,
  bp_type                 text        not null,
  currency_code           char(3),
  payment_terms           text,
  default_lead_time_days  integer,
  phone                   text,
  email                   text,
  notes                   text,
  is_active               boolean     not null default true,
  created_at              timestamptz not null default now(),
  created_by              uuid,
  updated_at              timestamptz not null default now(),
  updated_by              uuid,
  constraint business_partners_pk primary key (id),
  constraint business_partners_company_id_uk unique (company_id, id),
  constraint business_partners_code_uk unique (company_id, code),
  constraint business_partners_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint business_partners_type_ck check (bp_type in ('SUPPLIER', 'CUSTOMER', 'BOTH')),
  constraint business_partners_lead_time_ck check (default_lead_time_days >= 0),
  constraint business_partners_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint business_partners_currency_fk foreign key (currency_code) references public.currencies (code)
);
comment on table public.business_partners is
  'Suppliers and customers (= B1 OCRD; BOTH = B1 "Lead/both" usage). currency_code is the default document currency; '
  'NULL means the company base currency.';

create table public.bp_addresses (
  id                   uuid        not null default gen_random_uuid(),
  company_id           uuid        not null,
  business_partner_id  uuid        not null,
  address_type         text        not null,
  label                text        not null,
  line1                text,
  line2                text,
  city                 text,
  region               text,
  postal_code          text,
  country_code         char(2),
  is_default           boolean     not null default false,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  updated_by           uuid,
  constraint bp_addresses_pk primary key (id),
  constraint bp_addresses_type_ck check (address_type in ('BILL_TO', 'SHIP_TO')),
  constraint bp_addresses_country_ck check (country_code ~ '^[A-Z]{2}$'),
  constraint bp_addresses_bp_fk foreign key (company_id, business_partner_id)
    references public.business_partners (company_id, id) on delete cascade
);
create unique index bp_addresses_one_default_ux on public.bp_addresses (business_partner_id, address_type) where is_default;
comment on table public.bp_addresses is 'Bill-to and ship-to addresses of a business partner (= B1 CRD1).';

create table public.bp_contacts (
  id                   uuid        not null default gen_random_uuid(),
  company_id           uuid        not null,
  business_partner_id  uuid        not null,
  name                 text        not null,
  role                 text,
  phone                text,
  email                text,
  is_primary           boolean     not null default false,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  updated_by           uuid,
  constraint bp_contacts_pk primary key (id),
  constraint bp_contacts_bp_fk foreign key (company_id, business_partner_id)
    references public.business_partners (company_id, id) on delete cascade
);
create unique index bp_contacts_one_primary_ux on public.bp_contacts (business_partner_id) where is_primary;
comment on table public.bp_contacts is 'Contact persons of a business partner (= B1 OCPR).';

create table public.bp_registrations (
  id                   uuid        not null default gen_random_uuid(),
  company_id           uuid        not null,
  business_partner_id  uuid        not null,
  registration_type    text        not null,
  registration_number  text        not null,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  updated_by           uuid,
  constraint bp_registrations_pk primary key (id),
  constraint bp_registrations_uk unique (business_partner_id, registration_type),
  constraint bp_registrations_bp_fk foreign key (company_id, business_partner_id)
    references public.business_partners (company_id, id) on delete cascade
);
comment on table public.bp_registrations is 'Tax and trade IDs of a business partner as data (GSTIN, IEC, BN, VAT...).';

-- -----------------------------------------------------------------------------
-- 2. Item-supplier data
-- -----------------------------------------------------------------------------

create table public.item_suppliers (
  id                   uuid          not null default gen_random_uuid(),
  company_id           uuid          not null,
  item_id              uuid          not null,
  business_partner_id  uuid          not null,
  supplier_item_code   text,
  purchase_uom_id      uuid,
  min_order_qty        numeric(18,6),
  order_multiple       numeric(18,6),
  lead_time_days       integer,
  is_preferred         boolean       not null default false,
  is_active            boolean       not null default true,
  created_at           timestamptz   not null default now(),
  created_by           uuid,
  updated_at           timestamptz   not null default now(),
  updated_by           uuid,
  constraint item_suppliers_pk primary key (id),
  constraint item_suppliers_uk unique (item_id, business_partner_id),
  constraint item_suppliers_qty_ck check (coalesce(min_order_qty, 1) > 0 and coalesce(order_multiple, 1) > 0),
  constraint item_suppliers_lead_time_ck check (lead_time_days >= 0),
  constraint item_suppliers_item_fk foreign key (company_id, item_id) references public.items (company_id, id) on delete cascade,
  constraint item_suppliers_bp_fk foreign key (company_id, business_partner_id) references public.business_partners (company_id, id),
  constraint item_suppliers_uom_fk foreign key (company_id, purchase_uom_id) references public.uoms (company_id, id)
);
create unique index item_suppliers_one_preferred_ux on public.item_suppliers (item_id) where is_preferred;
comment on table public.item_suppliers is
  'Which supplier sells which item, under which code, in which unit, with planned lead time (days). '
  'Actual lead times come from receipts (v_item_supplier_lead_time). min_order_qty / order_multiple are in purchase_uom.';

create or replace function private.validate_item_supplier()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_type text;
  v_group uuid;
begin
  select bp_type into v_type from public.business_partners where id = new.business_partner_id;
  if v_type not in ('SUPPLIER', 'BOTH') then
    raise exception 'Business partner is not a supplier' using errcode = '23514';
  end if;
  if new.purchase_uom_id is not null then
    select uom_group_id into v_group from public.items where id = new.item_id;
    if not exists (select 1 from public.uom_group_conversions c where c.uom_group_id = v_group and c.alt_uom_id = new.purchase_uom_id) then
      raise exception 'Purchase UoM must belong to the item''s UoM group' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

create trigger item_suppliers_validate
  before insert or update on public.item_suppliers
  for each row execute function private.validate_item_supplier();

-- -----------------------------------------------------------------------------
-- 3. Purchase orders
-- -----------------------------------------------------------------------------

create table public.purchase_orders (
  id                   uuid           not null default gen_random_uuid(),
  company_id           uuid           not null,
  document_type_id     uuid           not null,
  doc_number           text,
  doc_date             date           not null default current_date,
  business_partner_id  uuid           not null,
  currency_code        char(3),
  exchange_rate        numeric(20,10),
  required_date        date,
  status               text           not null default 'DRAFT',
  close_type           text,
  close_reason_id      uuid,
  supplier_reference   text,
  remarks              text,
  released_at          timestamptz,
  released_by          uuid,
  created_at           timestamptz    not null default now(),
  created_by           uuid,
  updated_at           timestamptz    not null default now(),
  updated_by           uuid,
  constraint purchase_orders_pk primary key (id),
  constraint purchase_orders_company_id_uk unique (company_id, id),
  constraint purchase_orders_number_uk unique (company_id, document_type_id, doc_number),
  constraint purchase_orders_status_ck check (status in ('DRAFT', 'OPEN', 'CLOSED', 'CANCELLED')),
  constraint purchase_orders_close_type_ck check (
    (status = 'CLOSED') = (close_type is not null) and close_type in ('RECEIVED', 'MANUAL')),
  constraint purchase_orders_released_ck check (
    (status = 'DRAFT') = (doc_number is null) and (status = 'DRAFT' or exchange_rate is not null)),
  constraint purchase_orders_rate_ck check (exchange_rate > 0),
  constraint purchase_orders_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint purchase_orders_type_fk foreign key (company_id, document_type_id) references public.document_types (company_id, id),
  constraint purchase_orders_bp_fk foreign key (company_id, business_partner_id) references public.business_partners (company_id, id),
  constraint purchase_orders_currency_fk foreign key (currency_code) references public.currencies (code),
  constraint purchase_orders_close_reason_fk foreign key (company_id, close_reason_id) references public.reason_codes (company_id, id)
);
comment on table public.purchase_orders is
  'Purchase order header (= B1 OPOR). DRAFT is freely editable; release_purchase_order() assigns the number, '
  'freezes currency and exchange rate (D-010) and opens it. Closes automatically when fully received (close_type RECEIVED) '
  'or manually (MANUAL). CANCELLED only while nothing has been received.';
comment on column public.purchase_orders.exchange_rate is '1 unit of currency_code = rate x company base currency, frozen at release (doc_date).';

create table public.purchase_order_lines (
  id                  uuid          not null default gen_random_uuid(),
  company_id          uuid          not null,
  purchase_order_id   uuid          not null,
  line_no             integer       not null,
  item_id             uuid          not null,
  supplier_item_code  text,
  quantity            numeric(18,6) not null,
  uom_id              uuid          not null,
  quantity_base       numeric(18,6) not null,
  received_qty_base   numeric(18,6) not null default 0,
  warehouse_id        uuid          not null,
  required_date       date,
  expected_date       date,
  line_status         text          not null default 'OPEN',
  remarks             text,
  created_at          timestamptz   not null default now(),
  created_by          uuid,
  updated_at          timestamptz   not null default now(),
  updated_by          uuid,
  constraint purchase_order_lines_pk primary key (id),
  constraint purchase_order_lines_company_id_uk unique (company_id, id),
  constraint purchase_order_lines_line_uk unique (purchase_order_id, line_no),
  constraint purchase_order_lines_qty_ck check (quantity > 0 and quantity_base > 0 and received_qty_base >= 0),
  constraint purchase_order_lines_status_ck check (line_status in ('OPEN', 'CLOSED')),
  constraint purchase_order_lines_po_fk foreign key (company_id, purchase_order_id)
    references public.purchase_orders (company_id, id) on delete cascade,
  constraint purchase_order_lines_item_fk foreign key (company_id, item_id) references public.items (company_id, id),
  constraint purchase_order_lines_uom_fk foreign key (company_id, uom_id) references public.uoms (company_id, id),
  constraint purchase_order_lines_wh_fk foreign key (company_id, warehouse_id) references public.warehouses (company_id, id)
);
comment on table public.purchase_order_lines is
  'PO lines (= B1 POR1). received_qty_base is maintained by goods receipts only. line_status CLOSED = short-closed: '
  'the remainder no longer counts as on order. required_date = when we need it; expected_date = supplier promise.';

create table public.purchase_order_line_prices (
  id                      uuid          not null default gen_random_uuid(),
  purchase_order_line_id  uuid          not null,
  company_id              uuid          not null,
  unit_price              numeric(18,6) not null,
  discount_pct            numeric(6,2)  not null default 0,
  created_at              timestamptz   not null default now(),
  created_by              uuid,
  updated_at              timestamptz   not null default now(),
  updated_by              uuid,
  constraint purchase_order_line_prices_pk primary key (id),
  constraint purchase_order_line_prices_line_uk unique (purchase_order_line_id),
  constraint purchase_order_line_prices_price_ck check (unit_price >= 0 and discount_pct between 0 and 100),
  constraint purchase_order_line_prices_line_fk foreign key (company_id, purchase_order_line_id)
    references public.purchase_order_lines (company_id, id) on delete cascade
);
comment on table public.purchase_order_line_prices is
  'Price per PO line in the PO currency and per PO line UoM, kept apart from quantities so that users without '
  'PURCHASE_PRICES can see and receive POs without seeing prices (D-008).';

-- PO header rules
create or replace function private.prepare_purchase_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_category text;
  v_bp public.business_partners%rowtype;
  v_system boolean := current_setting('erp.posting', true) = 'on';
begin
  if tg_op = 'INSERT' then
    select dt.category into v_category from public.document_types dt
    where dt.id = new.document_type_id and dt.company_id = new.company_id and dt.is_active;
    if v_category is distinct from 'PURCHASE_ORDER' then
      raise exception 'Document type must be an active purchase order type of this company' using errcode = '23514';
    end if;
    new.status := 'DRAFT';
    new.doc_number := null;
    new.exchange_rate := null;
    new.released_at := null;
    new.released_by := null;
    new.close_type := null;
  else
    if new.document_type_id <> old.document_type_id then
      raise exception 'The document type of a PO cannot be changed' using errcode = '23514';
    end if;
    if old.status <> 'DRAFT' and not v_system then
      if new.business_partner_id <> old.business_partner_id or new.currency_code is distinct from old.currency_code
         or new.doc_date <> old.doc_date or new.exchange_rate is distinct from old.exchange_rate
         or new.doc_number is distinct from old.doc_number or new.status <> old.status
         or new.close_type is distinct from old.close_type then
        raise exception 'PO % is %: supplier, date, currency, rate, number and status can only change through the PO functions',
          old.doc_number, old.status using errcode = '23514';
      end if;
    end if;
  end if;

  select * into v_bp from public.business_partners where id = new.business_partner_id;
  if v_bp.bp_type not in ('SUPPLIER', 'BOTH') then
    raise exception 'Business partner % is not a supplier', v_bp.code using errcode = '23514';
  end if;
  if new.status = 'DRAFT' then
    new.currency_code := coalesce(new.currency_code, v_bp.currency_code,
                                  (select base_currency from public.companies where id = new.company_id));
  end if;
  return new;
end;
$$;

create trigger purchase_orders_prepare
  before insert or update on public.purchase_orders
  for each row execute function private.prepare_purchase_order();

create or replace function private.block_released_po_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status <> 'DRAFT' then
    raise exception 'PO % is % and cannot be deleted; cancel or close it instead', old.doc_number, old.status using errcode = '23514';
  end if;
  return old;
end;
$$;

create trigger purchase_orders_block_delete
  before delete on public.purchase_orders
  for each row execute function private.block_released_po_delete();

-- PO line rules: defaults, base quantity, what may change once the PO is open.
create or replace function private.prepare_purchase_order_line()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  po public.purchase_orders%rowtype;
  i  public.items%rowtype;
  s  public.item_suppliers%rowtype;
  v_system boolean := current_setting('erp.posting', true) = 'on';
  v_decimals smallint;
  v_lead integer;
begin
  select * into po from public.purchase_orders where id = coalesce(new.purchase_order_id, old.purchase_order_id);

  if tg_op = 'DELETE' then
    if po.status is null then
      return old; -- cascade from a deleted draft header
    end if;
    if po.status in ('CLOSED', 'CANCELLED') and not v_system then
      raise exception 'Lines of a % PO cannot be removed', po.status using errcode = '23514';
    end if;
    if old.received_qty_base > 0 then
      raise exception 'Line % has receipts and cannot be removed; close it instead', old.line_no using errcode = '23514';
    end if;
    return old;
  end if;

  if po.status in ('CLOSED', 'CANCELLED') and not v_system then
    raise exception 'PO % is % and cannot be changed', po.doc_number, po.status using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' then
    if new.received_qty_base <> old.received_qty_base and not v_system then
      raise exception 'Received quantity is maintained by goods receipts' using errcode = '23514';
    end if;
    if old.received_qty_base > 0 and (new.item_id <> old.item_id or new.uom_id <> old.uom_id or new.warehouse_id <> old.warehouse_id) then
      raise exception 'Item, unit and warehouse of a line with receipts cannot change' using errcode = '23514';
    end if;
    if new.item_id <> old.item_id and po.status <> 'DRAFT' then
      raise exception 'The item of a released PO line cannot change; add a new line' using errcode = '23514';
    end if;
  else
    new.received_qty_base := 0;
    new.line_status := 'OPEN';
  end if;

  select * into i from public.items where id = new.item_id;
  if i.is_template then
    raise exception 'Template item % cannot be ordered; use a variant', i.item_code using errcode = '23514';
  end if;

  select * into s from public.item_suppliers
  where item_id = new.item_id and business_partner_id = po.business_partner_id and is_active;

  new.uom_id := coalesce(new.uom_id, s.purchase_uom_id, i.purchase_uom_id);
  new.supplier_item_code := coalesce(new.supplier_item_code, s.supplier_item_code);
  new.warehouse_id := coalesce(new.warehouse_id, private.default_warehouse(new.company_id, new.item_id));
  if new.warehouse_id is null then
    raise exception 'No warehouse given and company has no main warehouse' using errcode = '23502';
  end if;
  new.required_date := coalesce(new.required_date, po.required_date);
  if new.expected_date is null then
    v_lead := coalesce(s.lead_time_days, (select default_lead_time_days from public.business_partners where id = po.business_partner_id));
    if v_lead is not null then
      new.expected_date := po.doc_date + v_lead;
    end if;
  end if;

  select u.decimals into v_decimals from public.uoms u where u.id = new.uom_id;
  if new.quantity <> round(new.quantity, v_decimals) then
    raise exception 'Quantity % has more than % decimals allowed for this UoM', new.quantity, v_decimals using errcode = '23514';
  end if;
  new.quantity_base := private.to_base_qty(i.uom_group_id, new.uom_id, new.quantity);
  if new.quantity_base is null then
    raise exception 'UoM is not in the UoM group of item %', i.item_code using errcode = '23514';
  end if;
  if new.quantity_base < new.received_qty_base and new.line_status = 'OPEN' and not v_system then
    raise exception 'Ordered quantity cannot be lower than already received' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger purchase_order_lines_prepare
  before insert or update or delete on public.purchase_order_lines
  for each row execute function private.prepare_purchase_order_line();

-- Prices only on DRAFT/OPEN POs
create or replace function private.guard_po_price()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  select po.status into v_status
  from public.purchase_order_lines l join public.purchase_orders po on po.id = l.purchase_order_id
  where l.id = coalesce(new.purchase_order_line_id, old.purchase_order_line_id);
  if v_status in ('CLOSED', 'CANCELLED') then
    raise exception 'Prices of a % PO cannot be changed', v_status using errcode = '23514';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger purchase_order_line_prices_guard
  before insert or update or delete on public.purchase_order_line_prices
  for each row execute function private.guard_po_price();

-- Re-evaluates a PO after receipts or line closures: closes it when nothing is left open, reopens an
-- automatically closed PO when a receipt is reversed.
create or replace function private.refresh_po_status(p_po_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  po public.purchase_orders%rowtype;
  v_open boolean;
begin
  select * into po from public.purchase_orders where id = p_po_id for update;
  select exists (select 1 from public.purchase_order_lines l
                 where l.purchase_order_id = p_po_id and l.line_status = 'OPEN' and l.received_qty_base < l.quantity_base)
  into v_open;

  perform set_config('erp.posting', 'on', true);
  if po.status = 'OPEN' and not v_open then
    update public.purchase_orders set status = 'CLOSED', close_type = 'RECEIVED' where id = p_po_id;
  elsif po.status = 'CLOSED' and po.close_type = 'RECEIVED' and v_open then
    update public.purchase_orders set status = 'OPEN', close_type = null where id = p_po_id;
  end if;
  perform set_config('erp.posting', 'off', true);
end;
$$;

-- Releases a draft PO: number from its series, currency rate at doc_date, status OPEN (= B1 "Add").
create or replace function public.release_purchase_order(p_po_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  po public.purchase_orders%rowtype;
  v_uid uuid := (select auth.uid());
  v_range uuid;
  v_rate numeric;
  v_number text;
begin
  select * into po from public.purchase_orders where id = p_po_id for update;
  if not found then
    raise exception 'PO not found' using errcode = 'P0002';
  end if;
  if v_uid is not null and po.company_id not in (select private.companies_with_access('PURCHASING', 'FULL')) then
    raise exception 'Not authorized to release purchase orders in this company' using errcode = '42501';
  end if;
  if po.status <> 'DRAFT' then
    raise exception 'PO % is already %', po.doc_number, po.status using errcode = '23514';
  end if;
  if not exists (select 1 from public.purchase_order_lines where purchase_order_id = po.id) then
    raise exception 'PO has no lines' using errcode = '23514';
  end if;
  if exists (select 1 from public.business_partners where id = po.business_partner_id and not is_active) then
    raise exception 'Supplier is inactive' using errcode = '23514';
  end if;

  v_rate := private.exchange_rate(po.company_id, po.currency_code, po.doc_date);
  if v_rate is null then
    raise exception 'No exchange rate for % on %. Enter it in Exchange rates first.', po.currency_code, po.doc_date
      using errcode = '23514';
  end if;

  select default_number_range_id into v_range from public.document_types where id = po.document_type_id;
  if v_range is null then
    raise exception 'Document type has no numbering series' using errcode = '23502';
  end if;
  v_number := private.next_number(v_range, '', po.doc_date);

  perform set_config('erp.posting', 'on', true);
  update public.purchase_orders
  set status = 'OPEN', doc_number = v_number, exchange_rate = v_rate, released_at = now(), released_by = v_uid
  where id = po.id;
  perform set_config('erp.posting', 'off', true);
  return v_number;
end;
$$;

-- Closes an open PO (or a single line) for the rest: remaining quantities stop counting as on order.
create or replace function public.close_purchase_order(p_po_id uuid, p_reason_id uuid, p_line_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  po public.purchase_orders%rowtype;
  v_uid uuid := (select auth.uid());
begin
  select * into po from public.purchase_orders where id = p_po_id for update;
  if not found then
    raise exception 'PO not found' using errcode = 'P0002';
  end if;
  if v_uid is not null and po.company_id not in (select private.companies_with_access('PURCHASING', 'FULL')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if po.status <> 'OPEN' then
    raise exception 'Only an open PO can be closed' using errcode = '23514';
  end if;
  if not exists (select 1 from public.reason_codes r where r.id = p_reason_id and r.company_id = po.company_id
                 and r.reason_type = 'PO_CLOSE' and r.is_active) then
    raise exception 'A PO_CLOSE reason of this company is required' using errcode = '23514';
  end if;

  perform set_config('erp.posting', 'on', true);
  update public.purchase_order_lines set line_status = 'CLOSED'
  where purchase_order_id = po.id and (p_line_id is null or id = p_line_id);
  if p_line_id is null then
    update public.purchase_orders set status = 'CLOSED', close_type = 'MANUAL', close_reason_id = p_reason_id where id = po.id;
  else
    update public.purchase_orders set close_reason_id = p_reason_id where id = po.id;
  end if;
  perform set_config('erp.posting', 'off', true);

  perform private.refresh_po_status(po.id);
end;
$$;

-- Cancels a PO that has no receipts (= B1 Cancel).
create or replace function public.cancel_purchase_order(p_po_id uuid, p_reason_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  po public.purchase_orders%rowtype;
  v_uid uuid := (select auth.uid());
begin
  select * into po from public.purchase_orders where id = p_po_id for update;
  if not found then
    raise exception 'PO not found' using errcode = 'P0002';
  end if;
  if v_uid is not null and po.company_id not in (select private.companies_with_access('PURCHASING', 'FULL')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if po.status <> 'OPEN' then
    raise exception 'Only an open PO can be cancelled (delete a draft instead)' using errcode = '23514';
  end if;
  if exists (select 1 from public.purchase_order_lines where purchase_order_id = po.id and received_qty_base > 0) then
    raise exception 'PO has receipts and cannot be cancelled; close it instead' using errcode = '23514';
  end if;
  if not exists (select 1 from public.reason_codes r where r.id = p_reason_id and r.company_id = po.company_id
                 and r.reason_type = 'CANCELLATION' and r.is_active) then
    raise exception 'A CANCELLATION reason of this company is required' using errcode = '23514';
  end if;
  perform set_config('erp.posting', 'on', true);
  update public.purchase_orders set status = 'CANCELLED', close_reason_id = p_reason_id where id = po.id;
  perform set_config('erp.posting', 'off', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Goods receipt PO: inventory document category with supplier and PO line link
-- -----------------------------------------------------------------------------

alter table public.inventory_documents drop constraint inventory_documents_category_ck;
alter table public.inventory_documents add constraint inventory_documents_category_ck check (
  category in ('GOODS_RECEIPT', 'GOODS_ISSUE', 'INVENTORY_TRANSFER', 'RECEIPT_FROM_PRODUCTION', 'GOODS_RECEIPT_PO'));
alter table public.inventory_documents add column business_partner_id uuid;
alter table public.inventory_documents add constraint inventory_documents_bp_fk
  foreign key (company_id, business_partner_id) references public.business_partners (company_id, id);
comment on column public.inventory_documents.business_partner_id is 'Supplier on a goods receipt PO (= B1 OPDN.CardCode).';

alter table public.inventory_document_lines add column purchase_order_line_id uuid;
alter table public.inventory_document_lines add constraint inventory_document_lines_po_line_fk
  foreign key (company_id, purchase_order_line_id) references public.purchase_order_lines (company_id, id);
comment on column public.inventory_document_lines.purchase_order_line_id is
  'Base PO line of a goods receipt PO line (= B1 BaseType 22 / BaseLine). Posting updates its received quantity.';

-- Header: as migration 003, plus supplier rules for GOODS_RECEIPT_PO.
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
  else
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
    if new.business_partner_id is distinct from old.business_partner_id
       and exists (select 1 from public.inventory_document_lines where document_id = new.id and purchase_order_line_id is not null) then
      raise exception 'Remove the PO lines before changing the supplier' using errcode = '23514';
    end if;
  end if;

  if (new.category = 'GOODS_RECEIPT_PO') <> (new.business_partner_id is not null) then
    raise exception 'A supplier is required on goods receipt PO documents and only there' using errcode = '23514';
  end if;
  if new.business_partner_id is not null and not exists (
       select 1 from public.business_partners b where b.id = new.business_partner_id and b.bp_type in ('SUPPLIER', 'BOTH')) then
    raise exception 'Business partner is not a supplier' using errcode = '23514';
  end if;
  return new;
end;
$$;

-- Lines: as migration 003, plus GOODS_RECEIPT_PO direction rules and PO line validation.
create or replace function private.prepare_inventory_line()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  d  public.inventory_documents%rowtype;
  i  public.items%rowtype;
  pl public.purchase_order_lines%rowtype;
  v_po public.purchase_orders%rowtype;
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

  -- PO link (goods receipt PO only)
  if new.purchase_order_line_id is not null then
    if d.category <> 'GOODS_RECEIPT_PO' then
      raise exception 'Only goods receipt PO lines can refer to a PO line' using errcode = '23514';
    end if;
    select * into pl from public.purchase_order_lines where id = new.purchase_order_line_id;
    select * into v_po from public.purchase_orders where id = pl.purchase_order_id;
    if v_po.business_partner_id <> d.business_partner_id then
      raise exception 'PO % belongs to another supplier', v_po.doc_number using errcode = '23514';
    end if;
    if pl.item_id <> new.item_id then
      raise exception 'Item differs from PO % line %', v_po.doc_number, pl.line_no using errcode = '23514';
    end if;
    if d.reverses_document_id is null and (v_po.status <> 'OPEN' or pl.line_status <> 'OPEN') then
      raise exception 'PO % line % is not open', v_po.doc_number, pl.line_no using errcode = '23514';
    end if;
    new.uom_id := coalesce(new.uom_id, pl.uom_id);
    new.warehouse_id := coalesce(new.warehouse_id, pl.warehouse_id);
  end if;

  new.uom_id := coalesce(new.uom_id, i.inventory_uom_id);
  new.warehouse_id := coalesce(new.warehouse_id, private.default_warehouse(new.company_id, new.item_id));
  if new.warehouse_id is null then
    raise exception 'No warehouse given and company has no main warehouse' using errcode = '23502';
  end if;

  if new.direction is null then
    new.direction := case d.category
                       when 'GOODS_RECEIPT' then 1
                       when 'GOODS_RECEIPT_PO' then 1
                       when 'GOODS_ISSUE' then -1
                       when 'INVENTORY_TRANSFER' then -1
                     end;
  end if;
  if new.direction is null then
    raise exception 'Direction is required on receipt-from-production lines (+1 product, -1 component)' using errcode = '23502';
  end if;

  if d.category in ('GOODS_RECEIPT', 'GOODS_RECEIPT_PO')
       and new.direction <> (case when d.reverses_document_id is null then 1 else -1 end)
  or d.category = 'GOODS_ISSUE' and new.direction <> (case when d.reverses_document_id is null then -1 else 1 end) then
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

-- When a goods receipt PO movement is written, update the PO line's received quantity.
-- Over-receipt beyond the company tolerance needs OVER_RECEIPT=FULL. Runs inside the posting transaction,
-- so a refusal rolls back the whole posting. PO lines are locked, so concurrent receipts queue.
create or replace function private.apply_po_receipt()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_line_id uuid;
  pl public.purchase_order_lines%rowtype;
  v_po public.purchase_orders%rowtype;
  v_pct numeric;
  v_new numeric;
  v_uid uuid := (select auth.uid());
begin
  if new.category <> 'GOODS_RECEIPT_PO' then
    return null;
  end if;
  select purchase_order_line_id into v_line_id from public.inventory_document_lines where id = new.document_line_id;
  if v_line_id is null then
    return null; -- receipt from a supplier without PO
  end if;

  select * into pl from public.purchase_order_lines where id = v_line_id for update;
  select * into v_po from public.purchase_orders where id = pl.purchase_order_id;
  v_new := pl.received_qty_base + new.quantity_base;

  if new.quantity_base > 0 then
    select s.over_receipt_pct into v_pct from public.company_settings s where s.company_id = new.company_id;
    if v_new > pl.quantity_base * (1 + v_pct / 100)
       and v_uid is not null
       and new.company_id not in (select private.companies_with_access('OVER_RECEIPT', 'FULL')) then
      raise exception 'Over-receipt on PO % line %: ordered %, would be received % (tolerance % %%)',
        v_po.doc_number, pl.line_no, pl.quantity_base, v_new, v_pct
        using errcode = '23514', hint = 'Reduce the quantity, or a user with OVER_RECEIPT rights must post it';
    end if;
  end if;
  if v_new < 0 then
    raise exception 'PO % line % would have negative received quantity', v_po.doc_number, pl.line_no using errcode = '23514';
  end if;

  perform set_config('erp.posting', 'on', true);
  update public.purchase_order_lines set received_qty_base = v_new where id = pl.id;
  perform set_config('erp.posting', 'off', true);
  perform private.refresh_po_status(pl.purchase_order_id);
  return null;
end;
$$;

create trigger stock_movements_apply_po_receipt
  after insert on public.stock_movements
  for each row execute function private.apply_po_receipt();

-- Cancellation (as migration 003) now also carries the supplier and the PO line links to the reversing
-- document, so cancelling a goods receipt PO reduces the PO's received quantity again.
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
    (company_id, document_type_id, doc_date, reason_code_id, reference, remarks, reverses_document_id, business_partner_id)
  values
    (d.company_id, d.document_type_id, current_date, p_reason_code_id, d.doc_number,
     'Cancellation of ' || d.doc_number, d.id, d.business_partner_id)
  returning id into v_rev_id;

  insert into public.inventory_document_lines
    (company_id, document_id, line_no, item_id, direction, quantity, uom_id, warehouse_id, to_warehouse_id, remarks,
     purchase_order_line_id)
  select company_id, v_rev_id, line_no, item_id, -direction, quantity, uom_id, warehouse_id, to_warehouse_id, remarks,
         purchase_order_line_id
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

-- Fills a draft goods receipt PO with the open quantities of a PO (= B1 "Copy From" Purchase Order).
create or replace function public.fill_receipt_from_po(p_document_id uuid, p_po_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  d public.inventory_documents%rowtype;
  v_next integer;
  v_count integer;
begin
  select * into d from public.inventory_documents where id = p_document_id;
  if not found or d.category <> 'GOODS_RECEIPT_PO' or d.status <> 'DRAFT' then
    raise exception 'Expected a draft goods receipt PO' using errcode = '23514';
  end if;
  select coalesce(max(line_no), 0) into v_next from public.inventory_document_lines where document_id = d.id;

  insert into public.inventory_document_lines
    (company_id, document_id, line_no, item_id, direction, quantity, uom_id, warehouse_id, purchase_order_line_id)
  select d.company_id, d.id, v_next + 10 * row_number() over (order by l.line_no),
         l.item_id, 1,
         -- open quantity back in the PO line unit, rounded down to the unit's decimals
         trunc((l.quantity_base - l.received_qty_base) * l.quantity / l.quantity_base, u.decimals),
         l.uom_id, l.warehouse_id, l.id
  from public.purchase_order_lines l
  join public.purchase_orders po on po.id = l.purchase_order_id
  join public.uoms u on u.id = l.uom_id
  join public.items i on i.id = l.item_id
  where l.purchase_order_id = p_po_id
    and po.business_partner_id = d.business_partner_id
    and po.status = 'OPEN' and l.line_status = 'OPEN'
    and i.item_type = 'INVENTORY'
    and trunc((l.quantity_base - l.received_qty_base) * l.quantity / l.quantity_base, u.decimals) > 0
    and not exists (select 1 from public.inventory_document_lines x where x.document_id = d.id and x.purchase_order_line_id = l.id);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Views: open POs, on order, projected stock, lead times
-- -----------------------------------------------------------------------------

-- Open PO lines with what is still to come (in base UoM).
create or replace view public.v_open_po_lines
with (security_invoker = true) as
select l.company_id, po.id as purchase_order_id, po.doc_number, po.doc_date, po.business_partner_id, bp.code as supplier_code,
       bp.name as supplier_name, l.id as purchase_order_line_id, l.line_no, l.item_id, i.item_code, i.name as item_name,
       l.warehouse_id, w.code as warehouse_code, l.quantity_base, l.received_qty_base,
       l.quantity_base - l.received_qty_base as open_qty_base, u.code as base_uom,
       l.required_date, l.expected_date,
       case when l.expected_date < current_date then current_date - l.expected_date else 0 end as days_overdue
from public.purchase_order_lines l
join public.purchase_orders po    on po.id = l.purchase_order_id
join public.business_partners bp  on bp.id = po.business_partner_id
join public.items i               on i.id = l.item_id
join public.warehouses w          on w.id = l.warehouse_id
join public.uom_groups g          on g.id = i.uom_group_id
join public.uoms u                on u.id = g.base_uom_id
where po.status = 'OPEN' and l.line_status = 'OPEN' and l.received_qty_base < l.quantity_base;

-- On order per item and warehouse (= B1 OITW.OnOrder, ERPNext Bin.ordered_qty).
create or replace view public.v_on_order
with (security_invoker = true) as
select company_id, item_id, warehouse_id, sum(open_qty_base) as on_order
from public.v_open_po_lines
group by company_id, item_id, warehouse_id;

-- On hand + on order per item and warehouse. Reserved (sales orders) is added with the sales module;
-- this becomes the TOC net-flow position.
create or replace view public.v_projected_stock
with (security_invoker = true) as
select coalesce(s.company_id, o.company_id) as company_id,
       coalesce(s.item_id, o.item_id) as item_id,
       coalesce(s.warehouse_id, o.warehouse_id) as warehouse_id,
       coalesce(s.on_hand, 0) as on_hand,
       coalesce(o.on_order, 0) as on_order,
       coalesce(s.on_hand, 0) + coalesce(o.on_order, 0) as projected
from public.item_warehouse_stock s
full join public.v_on_order o on o.item_id = s.item_id and o.warehouse_id = s.warehouse_id;

-- One row per posted receipt line against a PO: actual lead time and lateness. Cancelled receipts excluded.
create or replace view public.v_purchase_lead_times
with (security_invoker = true) as
select d.company_id, po.business_partner_id, l.item_id, po.id as purchase_order_id, po.doc_number as po_number,
       d.id as receipt_id, d.doc_number as receipt_number,
       po.doc_date as ordered_on, d.doc_date as received_on, pl.expected_date, pl.required_date,
       d.doc_date - po.doc_date as lead_time_days,
       d.doc_date - pl.expected_date as days_late,
       l.quantity_base
from public.inventory_document_lines l
join public.inventory_documents d   on d.id = l.document_id
join public.purchase_order_lines pl on pl.id = l.purchase_order_line_id
join public.purchase_orders po      on po.id = pl.purchase_order_id
where d.category = 'GOODS_RECEIPT_PO' and d.status = 'POSTED' and d.reverses_document_id is null;

-- Lead-time statistics per item and supplier, next to the planned lead time.
create or replace view public.v_item_supplier_lead_time
with (security_invoker = true) as
select t.company_id, t.item_id, t.business_partner_id,
       count(*) as receipts,
       round(avg(t.lead_time_days), 1) as avg_days,
       percentile_cont(0.8) within group (order by t.lead_time_days) as p80_days,
       max(t.lead_time_days) as max_days,
       round(100.0 * count(*) filter (where t.days_late <= 0) / nullif(count(*) filter (where t.days_late is not null), 0), 0) as on_time_pct,
       max(t.received_on) as last_received_on,
       (select s.lead_time_days from public.item_suppliers s
        where s.item_id = t.item_id and s.business_partner_id = t.business_partner_id) as planned_days
from public.v_purchase_lead_times t
group by t.company_id, t.item_id, t.business_partner_id;

-- The current user's authorization level per object in a company, so screens can hide what the
-- database would refuse anyway (e.g. price columns, post buttons). Not a security boundary.
create or replace function public.my_access(p_company_id uuid)
returns table (auth_object text, level text)
language sql
stable
security definer
set search_path = ''
as $$
  select o.code,
         case when p_company_id in (select private.companies_with_access(o.code, 'FULL')) then 'FULL'
              when p_company_id in (select private.companies_with_access(o.code, 'READ')) then 'READ'
              else 'NONE' end
  from public.auth_objects o
$$;
revoke all on function public.my_access(uuid) from public, anon;
grant execute on function public.my_access(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 6. RLS, grants, triggers, indexes
-- -----------------------------------------------------------------------------

select private.enable_company_rls('public.business_partners',          'BUSINESS_PARTNERS');
select private.enable_company_rls('public.bp_addresses',               'BUSINESS_PARTNERS');
select private.enable_company_rls('public.bp_contacts',                'BUSINESS_PARTNERS');
select private.enable_company_rls('public.bp_registrations',           'BUSINESS_PARTNERS');
select private.enable_company_rls('public.item_suppliers',             'PURCHASING');
select private.enable_company_rls('public.purchase_orders',            'PURCHASING');
select private.enable_company_rls('public.purchase_order_lines',       'PURCHASING');
select private.enable_company_rls('public.purchase_order_line_prices', 'PURCHASE_PRICES');

-- Users who receive goods (INVENTORY) must see supplier names and open PO lines without PURCHASING rights.
drop policy rls_select on public.business_partners;
create policy rls_select on public.business_partners for select to authenticated
  using (company_id in (select private.companies_with_access('BUSINESS_PARTNERS', 'READ'))
         or company_id in (select private.companies_with_access('INVENTORY', 'READ')));
drop policy rls_select on public.purchase_orders;
create policy rls_select on public.purchase_orders for select to authenticated
  using (company_id in (select private.companies_with_access('PURCHASING', 'READ'))
         or company_id in (select private.companies_with_access('INVENTORY', 'READ')));
drop policy rls_select on public.purchase_order_lines;
create policy rls_select on public.purchase_order_lines for select to authenticated
  using (company_id in (select private.companies_with_access('PURCHASING', 'READ'))
         or company_id in (select private.companies_with_access('INVENTORY', 'READ')));

revoke all on public.v_open_po_lines, public.v_on_order, public.v_projected_stock,
              public.v_purchase_lead_times, public.v_item_supplier_lead_time from anon;

revoke all on function public.release_purchase_order(uuid) from public, anon;
revoke all on function public.close_purchase_order(uuid, uuid, uuid) from public, anon;
revoke all on function public.cancel_purchase_order(uuid, uuid) from public, anon;
revoke all on function public.fill_receipt_from_po(uuid, uuid) from public, anon;
grant execute on function public.release_purchase_order(uuid) to authenticated;
grant execute on function public.close_purchase_order(uuid, uuid, uuid) to authenticated;
grant execute on function public.cancel_purchase_order(uuid, uuid) to authenticated;
grant execute on function public.fill_receipt_from_po(uuid, uuid) to authenticated;

select private.attach_standard_triggers('public.business_partners');
select private.attach_standard_triggers('public.bp_addresses');
select private.attach_standard_triggers('public.bp_contacts');
select private.attach_standard_triggers('public.bp_registrations');
select private.attach_standard_triggers('public.item_suppliers');
select private.attach_standard_triggers('public.purchase_orders');
select private.attach_standard_triggers('public.purchase_order_lines');
select private.attach_standard_triggers('public.purchase_order_line_prices');

create index business_partners_currency_ix        on public.business_partners (currency_code);
create index business_partners_name_ix            on public.business_partners (company_id, lower(name));
create index bp_addresses_bp_ix                   on public.bp_addresses (company_id, business_partner_id);
create index bp_contacts_bp_ix                    on public.bp_contacts (company_id, business_partner_id);
create index bp_registrations_bp_ix               on public.bp_registrations (company_id, business_partner_id);
create index item_suppliers_item_ix               on public.item_suppliers (company_id, item_id);
create index item_suppliers_bp_ix                 on public.item_suppliers (company_id, business_partner_id);
create index item_suppliers_uom_ix                on public.item_suppliers (company_id, purchase_uom_id);
create index purchase_orders_type_ix              on public.purchase_orders (company_id, document_type_id);
create index purchase_orders_bp_ix                on public.purchase_orders (company_id, business_partner_id);
create index purchase_orders_currency_ix          on public.purchase_orders (currency_code);
create index purchase_orders_close_reason_ix      on public.purchase_orders (company_id, close_reason_id);
create index purchase_orders_status_ix            on public.purchase_orders (company_id, status, doc_date desc);
create index purchase_order_lines_po_ix           on public.purchase_order_lines (company_id, purchase_order_id);
create index purchase_order_lines_item_ix         on public.purchase_order_lines (company_id, item_id);
create index purchase_order_lines_uom_ix          on public.purchase_order_lines (company_id, uom_id);
create index purchase_order_lines_wh_ix           on public.purchase_order_lines (company_id, warehouse_id);
create index purchase_order_line_prices_co_ix     on public.purchase_order_line_prices (company_id, purchase_order_line_id);
create index inventory_documents_bp_ix            on public.inventory_documents (company_id, business_partner_id);
create index inventory_document_lines_po_line_ix  on public.inventory_document_lines (company_id, purchase_order_line_id);
