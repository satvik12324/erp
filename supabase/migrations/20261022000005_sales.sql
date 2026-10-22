-- =============================================================================
-- Migration 005 — Sales orders, deliveries, order time buffers
--
--   sales_orders / _lines        ~ B1 ORDR / RDR1             ~ ERPNext Sales Order (Item)
--   sales_order_line_prices      price kept apart from quantities (D-008, like PO prices)
--   Delivery                     ~ B1 ODLN / DLN1, inventory document category DELIVERY with customer and SO line link
--   v_reserved                   ~ B1 OITW.IsCommited, ERPNext Bin.reserved_qty
--   v_sales_order_buffer         TOC time buffer per open order: buffer start = due date − buffer days,
--                                penetration = elapsed / buffer length; zone from company cut-points (D-012)
-- Deviation: TOC time buffer on every sales order (Rule 4), not in B1 or ERPNext.
-- =============================================================================

insert into public.auth_objects (code, name, description, sort_order) values
  ('SALES',        'Sales',        'Sales orders, delivery against SO, order board', 410),
  ('SALES_PRICES', 'Sales prices', 'See and change prices on sales orders', 420);

insert into public.reason_types (code, name) values ('SO_CLOSE', 'Sales order closed short')
on conflict (code) do nothing;

alter table public.company_settings add column default_time_buffer_days integer not null default 14;
alter table public.company_settings add constraint company_settings_time_buffer_ck check (default_time_buffer_days > 0);
comment on column public.company_settings.default_time_buffer_days is
  'Time buffer (days) given to a sales order when none is entered: the order''s buffer starts this many days before its due date.';
comment on column public.company_settings.over_receipt_pct is
  'Tolerance in % for receiving more than ordered on a PO line and delivering more than ordered on an SO line '
  '(ERPNext over_delivery_receipt_allowance). Users with OVER_RECEIPT=FULL may exceed it.';

-- Today in the company's own time zone (buffers age by local calendar days, not UTC days).
create or replace function private.company_today(p_company_id uuid)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select (now() at time zone c.timezone)::date from public.companies c where c.id = p_company_id
$$;
grant execute on function private.company_today(uuid) to authenticated;

-- Zone of a penetration % with the company cut-points (D-012): GREEN < yellow <= YELLOW < red <= RED <= 100 < BLACK.
create or replace function private.buffer_zone(p_company_id uuid, p_penetration numeric)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_penetration is null then null
    when p_penetration > 100 then 'BLACK'
    when p_penetration >= s.red_from_pct then 'RED'
    when p_penetration >= s.yellow_from_pct then 'YELLOW'
    else 'GREEN' end
  from public.company_settings s where s.company_id = p_company_id
$$;
grant execute on function private.buffer_zone(uuid, numeric) to authenticated;

-- -----------------------------------------------------------------------------
-- 1. Sales orders
-- -----------------------------------------------------------------------------

create table public.sales_orders (
  id                   uuid           not null default gen_random_uuid(),
  company_id           uuid           not null,
  document_type_id     uuid           not null,
  doc_number           text,
  doc_date             date           not null default current_date,
  business_partner_id  uuid           not null,
  currency_code        char(3),
  exchange_rate        numeric(20,10),
  due_date             date,
  time_buffer_days     integer,
  status               text           not null default 'DRAFT',
  close_type           text,
  close_reason_id      uuid,
  customer_reference   text,
  remarks              text,
  released_at          timestamptz,
  released_by          uuid,
  created_at           timestamptz    not null default now(),
  created_by           uuid,
  updated_at           timestamptz    not null default now(),
  updated_by           uuid,
  constraint sales_orders_pk primary key (id),
  constraint sales_orders_company_id_uk unique (company_id, id),
  constraint sales_orders_number_uk unique (company_id, document_type_id, doc_number),
  constraint sales_orders_status_ck check (status in ('DRAFT', 'OPEN', 'CLOSED', 'CANCELLED')),
  constraint sales_orders_close_type_ck check (
    (status = 'CLOSED') = (close_type is not null) and close_type in ('DELIVERED', 'MANUAL')),
  constraint sales_orders_released_ck check (
    (status = 'DRAFT') = (doc_number is null)
    and (status = 'DRAFT' or (exchange_rate is not null and due_date is not null and time_buffer_days is not null))),
  constraint sales_orders_rate_ck check (exchange_rate > 0),
  constraint sales_orders_buffer_ck check (time_buffer_days > 0),
  constraint sales_orders_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint sales_orders_type_fk foreign key (company_id, document_type_id) references public.document_types (company_id, id),
  constraint sales_orders_bp_fk foreign key (company_id, business_partner_id) references public.business_partners (company_id, id),
  constraint sales_orders_currency_fk foreign key (currency_code) references public.currencies (code),
  constraint sales_orders_close_reason_fk foreign key (company_id, close_reason_id) references public.reason_codes (company_id, id)
);
comment on table public.sales_orders is
  'Sales order header (= B1 ORDR). release_sales_order() numbers it, freezes currency rate (D-010) and fixes the time '
  'buffer: buffer starts time_buffer_days before due_date. Closes itself when fully delivered (DELIVERED) or manually.';
comment on column public.sales_orders.due_date is 'Date promised to the customer. Required to release.';
comment on column public.sales_orders.time_buffer_days is 'TOC time buffer length. NULL on a draft = company default at release.';

create table public.sales_order_lines (
  id                  uuid          not null default gen_random_uuid(),
  company_id          uuid          not null,
  sales_order_id      uuid          not null,
  line_no             integer       not null,
  item_id             uuid          not null,
  quantity            numeric(18,6) not null,
  uom_id              uuid          not null,
  quantity_base       numeric(18,6) not null,
  delivered_qty_base  numeric(18,6) not null default 0,
  warehouse_id        uuid          not null,
  line_status         text          not null default 'OPEN',
  remarks             text,
  created_at          timestamptz   not null default now(),
  created_by          uuid,
  updated_at          timestamptz   not null default now(),
  updated_by          uuid,
  constraint sales_order_lines_pk primary key (id),
  constraint sales_order_lines_company_id_uk unique (company_id, id),
  constraint sales_order_lines_line_uk unique (sales_order_id, line_no),
  constraint sales_order_lines_qty_ck check (quantity > 0 and quantity_base > 0 and delivered_qty_base >= 0),
  constraint sales_order_lines_status_ck check (line_status in ('OPEN', 'CLOSED')),
  constraint sales_order_lines_so_fk foreign key (company_id, sales_order_id) references public.sales_orders (company_id, id) on delete cascade,
  constraint sales_order_lines_item_fk foreign key (company_id, item_id) references public.items (company_id, id),
  constraint sales_order_lines_uom_fk foreign key (company_id, uom_id) references public.uoms (company_id, id),
  constraint sales_order_lines_wh_fk foreign key (company_id, warehouse_id) references public.warehouses (company_id, id)
);
comment on table public.sales_order_lines is
  'SO lines (= B1 RDR1). delivered_qty_base is maintained by deliveries only. Open quantity is reserved (committed) stock.';

create table public.sales_order_line_prices (
  id                    uuid          not null default gen_random_uuid(),
  sales_order_line_id   uuid          not null,
  company_id            uuid          not null,
  unit_price            numeric(18,6) not null,
  discount_pct          numeric(6,2)  not null default 0,
  created_at            timestamptz   not null default now(),
  created_by            uuid,
  updated_at            timestamptz   not null default now(),
  updated_by            uuid,
  constraint sales_order_line_prices_pk primary key (id),
  constraint sales_order_line_prices_line_uk unique (sales_order_line_id),
  constraint sales_order_line_prices_price_ck check (unit_price >= 0 and discount_pct between 0 and 100),
  constraint sales_order_line_prices_line_fk foreign key (company_id, sales_order_line_id)
    references public.sales_order_lines (company_id, id) on delete cascade
);
comment on table public.sales_order_line_prices is
  'Price per SO line in SO currency and SO line unit, guarded by SALES_PRICES (store users deliver without seeing prices).';

create or replace function private.prepare_sales_order()
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
    if v_category is distinct from 'SALES_ORDER' then
      raise exception 'Document type must be an active sales order type of this company' using errcode = '23514';
    end if;
    new.status := 'DRAFT';
    new.doc_number := null;
    new.exchange_rate := null;
    new.released_at := null;
    new.released_by := null;
    new.close_type := null;
  else
    if new.document_type_id <> old.document_type_id then
      raise exception 'The document type of an SO cannot be changed' using errcode = '23514';
    end if;
    if old.status <> 'DRAFT' and not v_system then
      if new.business_partner_id <> old.business_partner_id or new.currency_code is distinct from old.currency_code
         or new.doc_date <> old.doc_date or new.exchange_rate is distinct from old.exchange_rate
         or new.doc_number is distinct from old.doc_number or new.status <> old.status
         or new.close_type is distinct from old.close_type then
        raise exception 'SO % is %: customer, date, currency, rate, number and status can only change through the SO functions',
          old.doc_number, old.status using errcode = '23514';
      end if;
      if old.status <> 'OPEN' and (new.due_date is distinct from old.due_date or new.time_buffer_days is distinct from old.time_buffer_days) then
        raise exception 'SO % is %', old.doc_number, old.status using errcode = '23514';
      end if;
      if new.due_date is null or new.time_buffer_days is null then
        raise exception 'An open SO needs a due date and a time buffer' using errcode = '23514';
      end if;
    end if;
  end if;

  select * into v_bp from public.business_partners where id = new.business_partner_id;
  if v_bp.bp_type not in ('CUSTOMER', 'BOTH') then
    raise exception 'Business partner % is not a customer', v_bp.code using errcode = '23514';
  end if;
  if new.status = 'DRAFT' then
    new.currency_code := coalesce(new.currency_code, v_bp.currency_code,
                                  (select base_currency from public.companies where id = new.company_id));
  end if;
  return new;
end;
$$;

create trigger sales_orders_prepare
  before insert or update on public.sales_orders
  for each row execute function private.prepare_sales_order();

create or replace function private.block_released_so_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status <> 'DRAFT' then
    raise exception 'SO % is % and cannot be deleted; cancel or close it instead', old.doc_number, old.status using errcode = '23514';
  end if;
  return old;
end;
$$;

create trigger sales_orders_block_delete
  before delete on public.sales_orders
  for each row execute function private.block_released_so_delete();

create or replace function private.prepare_sales_order_line()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  so public.sales_orders%rowtype;
  i  public.items%rowtype;
  v_system boolean := current_setting('erp.posting', true) = 'on';
  v_decimals smallint;
begin
  select * into so from public.sales_orders where id = coalesce(new.sales_order_id, old.sales_order_id);

  if tg_op = 'DELETE' then
    if so.status is null then
      return old;
    end if;
    if so.status in ('CLOSED', 'CANCELLED') and not v_system then
      raise exception 'Lines of a % SO cannot be removed', so.status using errcode = '23514';
    end if;
    if old.delivered_qty_base > 0 then
      raise exception 'Line % has deliveries and cannot be removed; close it instead', old.line_no using errcode = '23514';
    end if;
    return old;
  end if;

  if so.status in ('CLOSED', 'CANCELLED') and not v_system then
    raise exception 'SO % is % and cannot be changed', so.doc_number, so.status using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' then
    if new.delivered_qty_base <> old.delivered_qty_base and not v_system then
      raise exception 'Delivered quantity is maintained by deliveries' using errcode = '23514';
    end if;
    if old.delivered_qty_base > 0 and (new.item_id <> old.item_id or new.uom_id <> old.uom_id or new.warehouse_id <> old.warehouse_id) then
      raise exception 'Item, unit and warehouse of a line with deliveries cannot change' using errcode = '23514';
    end if;
    if new.item_id <> old.item_id and so.status <> 'DRAFT' then
      raise exception 'The item of a released SO line cannot change; add a new line' using errcode = '23514';
    end if;
  else
    new.delivered_qty_base := 0;
    new.line_status := 'OPEN';
  end if;

  select * into i from public.items where id = new.item_id;
  if i.is_template then
    raise exception 'Template item % cannot be sold; use a variant', i.item_code using errcode = '23514';
  end if;
  if not i.is_sold then
    raise exception 'Item % is not marked as sold', i.item_code using errcode = '23514';
  end if;

  new.uom_id := coalesce(new.uom_id, i.sales_uom_id);
  new.warehouse_id := coalesce(new.warehouse_id, private.default_warehouse(new.company_id, new.item_id));
  if new.warehouse_id is null then
    raise exception 'No warehouse given and company has no main warehouse' using errcode = '23502';
  end if;

  select u.decimals into v_decimals from public.uoms u where u.id = new.uom_id;
  if new.quantity <> round(new.quantity, v_decimals) then
    raise exception 'Quantity % has more than % decimals allowed for this UoM', new.quantity, v_decimals using errcode = '23514';
  end if;
  new.quantity_base := private.to_base_qty(i.uom_group_id, new.uom_id, new.quantity);
  if new.quantity_base is null then
    raise exception 'UoM is not in the UoM group of item %', i.item_code using errcode = '23514';
  end if;
  if new.quantity_base < new.delivered_qty_base and new.line_status = 'OPEN' and not v_system then
    raise exception 'Ordered quantity cannot be lower than already delivered' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger sales_order_lines_prepare
  before insert or update or delete on public.sales_order_lines
  for each row execute function private.prepare_sales_order_line();

create or replace function private.guard_so_price()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  select so.status into v_status
  from public.sales_order_lines l join public.sales_orders so on so.id = l.sales_order_id
  where l.id = coalesce(new.sales_order_line_id, old.sales_order_line_id);
  if v_status in ('CLOSED', 'CANCELLED') then
    raise exception 'Prices of a % SO cannot be changed', v_status using errcode = '23514';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger sales_order_line_prices_guard
  before insert or update or delete on public.sales_order_line_prices
  for each row execute function private.guard_so_price();

create or replace function private.refresh_so_status(p_so_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  so public.sales_orders%rowtype;
  v_open boolean;
begin
  select * into so from public.sales_orders where id = p_so_id for update;
  select exists (select 1 from public.sales_order_lines l
                 where l.sales_order_id = p_so_id and l.line_status = 'OPEN' and l.delivered_qty_base < l.quantity_base)
  into v_open;
  perform set_config('erp.posting', 'on', true);
  if so.status = 'OPEN' and not v_open then
    update public.sales_orders set status = 'CLOSED', close_type = 'DELIVERED' where id = p_so_id;
  elsif so.status = 'CLOSED' and so.close_type = 'DELIVERED' and v_open then
    update public.sales_orders set status = 'OPEN', close_type = null where id = p_so_id;
  end if;
  perform set_config('erp.posting', 'off', true);
end;
$$;

create or replace function public.release_sales_order(p_so_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  so public.sales_orders%rowtype;
  v_uid uuid := (select auth.uid());
  v_range uuid;
  v_rate numeric;
  v_buffer integer;
  v_number text;
begin
  select * into so from public.sales_orders where id = p_so_id for update;
  if not found then
    raise exception 'SO not found' using errcode = 'P0002';
  end if;
  if v_uid is not null and so.company_id not in (select private.companies_with_access('SALES', 'FULL')) then
    raise exception 'Not authorized to release sales orders in this company' using errcode = '42501';
  end if;
  if so.status <> 'DRAFT' then
    raise exception 'SO % is already %', so.doc_number, so.status using errcode = '23514';
  end if;
  if not exists (select 1 from public.sales_order_lines where sales_order_id = so.id) then
    raise exception 'SO has no lines' using errcode = '23514';
  end if;
  if so.due_date is null then
    raise exception 'Enter the due date promised to the customer before releasing' using errcode = '23514';
  end if;
  if so.due_date < so.doc_date then
    raise exception 'Due date is before the order date' using errcode = '23514';
  end if;
  v_rate := private.exchange_rate(so.company_id, so.currency_code, so.doc_date);
  if v_rate is null then
    raise exception 'No exchange rate for % on %. Enter it in Exchange rates first.', so.currency_code, so.doc_date using errcode = '23514';
  end if;
  v_buffer := coalesce(so.time_buffer_days,
                       (select default_time_buffer_days from public.company_settings where company_id = so.company_id));

  select default_number_range_id into v_range from public.document_types where id = so.document_type_id;
  if v_range is null then
    raise exception 'Document type has no numbering series' using errcode = '23502';
  end if;
  v_number := private.next_number(v_range, '', so.doc_date);

  perform set_config('erp.posting', 'on', true);
  update public.sales_orders
  set status = 'OPEN', doc_number = v_number, exchange_rate = v_rate, time_buffer_days = v_buffer,
      released_at = now(), released_by = v_uid
  where id = so.id;
  perform set_config('erp.posting', 'off', true);
  return v_number;
end;
$$;

create or replace function public.close_sales_order(p_so_id uuid, p_reason_id uuid, p_line_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  so public.sales_orders%rowtype;
  v_uid uuid := (select auth.uid());
begin
  select * into so from public.sales_orders where id = p_so_id for update;
  if not found then
    raise exception 'SO not found' using errcode = 'P0002';
  end if;
  if v_uid is not null and so.company_id not in (select private.companies_with_access('SALES', 'FULL')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if so.status <> 'OPEN' then
    raise exception 'Only an open SO can be closed' using errcode = '23514';
  end if;
  if not exists (select 1 from public.reason_codes r where r.id = p_reason_id and r.company_id = so.company_id
                 and r.reason_type = 'SO_CLOSE' and r.is_active) then
    raise exception 'An SO_CLOSE reason of this company is required' using errcode = '23514';
  end if;
  perform set_config('erp.posting', 'on', true);
  update public.sales_order_lines set line_status = 'CLOSED'
  where sales_order_id = so.id and (p_line_id is null or id = p_line_id);
  if p_line_id is null then
    update public.sales_orders set status = 'CLOSED', close_type = 'MANUAL', close_reason_id = p_reason_id where id = so.id;
  else
    update public.sales_orders set close_reason_id = p_reason_id where id = so.id;
  end if;
  perform set_config('erp.posting', 'off', true);
  perform private.refresh_so_status(so.id);
end;
$$;

create or replace function public.cancel_sales_order(p_so_id uuid, p_reason_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  so public.sales_orders%rowtype;
  v_uid uuid := (select auth.uid());
begin
  select * into so from public.sales_orders where id = p_so_id for update;
  if not found then
    raise exception 'SO not found' using errcode = 'P0002';
  end if;
  if v_uid is not null and so.company_id not in (select private.companies_with_access('SALES', 'FULL')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if so.status <> 'OPEN' then
    raise exception 'Only an open SO can be cancelled (delete a draft instead)' using errcode = '23514';
  end if;
  if exists (select 1 from public.sales_order_lines where sales_order_id = so.id and delivered_qty_base > 0) then
    raise exception 'SO has deliveries and cannot be cancelled; close it instead' using errcode = '23514';
  end if;
  if not exists (select 1 from public.reason_codes r where r.id = p_reason_id and r.company_id = so.company_id
                 and r.reason_type = 'CANCELLATION' and r.is_active) then
    raise exception 'A CANCELLATION reason of this company is required' using errcode = '23514';
  end if;
  perform set_config('erp.posting', 'on', true);
  update public.sales_orders set status = 'CANCELLED', close_reason_id = p_reason_id where id = so.id;
  perform set_config('erp.posting', 'off', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Delivery: inventory document category with customer and SO line link
-- -----------------------------------------------------------------------------

alter table public.inventory_documents drop constraint inventory_documents_category_ck;
alter table public.inventory_documents add constraint inventory_documents_category_ck check (
  category in ('GOODS_RECEIPT', 'GOODS_ISSUE', 'INVENTORY_TRANSFER', 'RECEIPT_FROM_PRODUCTION', 'GOODS_RECEIPT_PO', 'DELIVERY'));
comment on column public.inventory_documents.business_partner_id is
  'Supplier on a goods receipt PO (= B1 OPDN.CardCode); customer on a delivery (= ODLN.CardCode).';

alter table public.inventory_document_lines add column sales_order_line_id uuid;
alter table public.inventory_document_lines add constraint inventory_document_lines_so_line_fk
  foreign key (company_id, sales_order_line_id) references public.sales_order_lines (company_id, id);
comment on column public.inventory_document_lines.sales_order_line_id is
  'Base SO line of a delivery line (= B1 BaseType 17). Posting updates its delivered quantity.';

create or replace function private.prepare_inventory_document()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_category text;
  v_needs_bp boolean;
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
       and exists (select 1 from public.inventory_document_lines
                   where document_id = new.id and (purchase_order_line_id is not null or sales_order_line_id is not null)) then
      raise exception 'Remove the order lines before changing the business partner' using errcode = '23514';
    end if;
  end if;

  v_needs_bp := new.category in ('GOODS_RECEIPT_PO', 'DELIVERY');
  if v_needs_bp <> (new.business_partner_id is not null) then
    raise exception 'A business partner is required on goods receipt PO and delivery documents and only there'
      using errcode = '23514';
  end if;
  if new.category = 'GOODS_RECEIPT_PO' and not exists (
       select 1 from public.business_partners b where b.id = new.business_partner_id and b.bp_type in ('SUPPLIER', 'BOTH')) then
    raise exception 'Business partner is not a supplier' using errcode = '23514';
  end if;
  if new.category = 'DELIVERY' and not exists (
       select 1 from public.business_partners b where b.id = new.business_partner_id and b.bp_type in ('CUSTOMER', 'BOTH')) then
    raise exception 'Business partner is not a customer' using errcode = '23514';
  end if;
  return new;
end;
$$;

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
  sl public.sales_order_lines%rowtype;
  v_so public.sales_orders%rowtype;
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

  if new.purchase_order_line_id is not null and new.sales_order_line_id is not null then
    raise exception 'A line refers to a PO line or an SO line, not both' using errcode = '23514';
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

  -- SO link (delivery only)
  if new.sales_order_line_id is not null then
    if d.category <> 'DELIVERY' then
      raise exception 'Only delivery lines can refer to an SO line' using errcode = '23514';
    end if;
    select * into sl from public.sales_order_lines where id = new.sales_order_line_id;
    select * into v_so from public.sales_orders where id = sl.sales_order_id;
    if v_so.business_partner_id <> d.business_partner_id then
      raise exception 'SO % belongs to another customer', v_so.doc_number using errcode = '23514';
    end if;
    if sl.item_id <> new.item_id then
      raise exception 'Item differs from SO % line %', v_so.doc_number, sl.line_no using errcode = '23514';
    end if;
    if d.reverses_document_id is null and (v_so.status <> 'OPEN' or sl.line_status <> 'OPEN') then
      raise exception 'SO % line % is not open', v_so.doc_number, sl.line_no using errcode = '23514';
    end if;
    new.uom_id := coalesce(new.uom_id, sl.uom_id);
    new.warehouse_id := coalesce(new.warehouse_id, sl.warehouse_id);
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
                       when 'DELIVERY' then -1
                       when 'INVENTORY_TRANSFER' then -1
                     end;
  end if;
  if new.direction is null then
    raise exception 'Direction is required on receipt-from-production lines (+1 product, -1 component)' using errcode = '23502';
  end if;

  if d.category in ('GOODS_RECEIPT', 'GOODS_RECEIPT_PO')
       and new.direction <> (case when d.reverses_document_id is null then 1 else -1 end)
  or d.category in ('GOODS_ISSUE', 'DELIVERY')
       and new.direction <> (case when d.reverses_document_id is null then -1 else 1 end) then
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

-- Delivery movements update the SO line's delivered quantity (mirror of apply_po_receipt).
create or replace function private.apply_so_delivery()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_line_id uuid;
  sl public.sales_order_lines%rowtype;
  v_so public.sales_orders%rowtype;
  v_pct numeric;
  v_new numeric;
  v_uid uuid := (select auth.uid());
begin
  if new.category <> 'DELIVERY' then
    return null;
  end if;
  select sales_order_line_id into v_line_id from public.inventory_document_lines where id = new.document_line_id;
  if v_line_id is null then
    return null;
  end if;

  select * into sl from public.sales_order_lines where id = v_line_id for update;
  select * into v_so from public.sales_orders where id = sl.sales_order_id;
  v_new := sl.delivered_qty_base - new.quantity_base;  -- delivery movements are negative

  if new.quantity_base < 0 then
    select s.over_receipt_pct into v_pct from public.company_settings s where s.company_id = new.company_id;
    if v_new > sl.quantity_base * (1 + v_pct / 100)
       and v_uid is not null
       and new.company_id not in (select private.companies_with_access('OVER_RECEIPT', 'FULL')) then
      raise exception 'Over-delivery on SO % line %: ordered %, would be delivered % (tolerance % %%)',
        v_so.doc_number, sl.line_no, sl.quantity_base, v_new, v_pct
        using errcode = '23514', hint = 'Reduce the quantity, or a user with OVER_RECEIPT rights must post it';
    end if;
  end if;
  if v_new < 0 then
    raise exception 'SO % line % would have negative delivered quantity', v_so.doc_number, sl.line_no using errcode = '23514';
  end if;

  perform set_config('erp.posting', 'on', true);
  update public.sales_order_lines set delivered_qty_base = v_new where id = sl.id;
  perform set_config('erp.posting', 'off', true);
  perform private.refresh_so_status(sl.sales_order_id);
  return null;
end;
$$;

create trigger stock_movements_apply_so_delivery
  after insert on public.stock_movements
  for each row execute function private.apply_so_delivery();

-- Cancellation now also carries SO line links.
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
     purchase_order_line_id, sales_order_line_id)
  select company_id, v_rev_id, line_no, item_id, -direction, quantity, uom_id, warehouse_id, to_warehouse_id, remarks,
         purchase_order_line_id, sales_order_line_id
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

-- Fills a draft delivery with the open quantities of an SO (= B1 Copy From Sales Order).
create or replace function public.fill_delivery_from_so(p_document_id uuid, p_so_id uuid)
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
  if not found or d.category <> 'DELIVERY' or d.status <> 'DRAFT' then
    raise exception 'Expected a draft delivery' using errcode = '23514';
  end if;
  select coalesce(max(line_no), 0) into v_next from public.inventory_document_lines where document_id = d.id;

  insert into public.inventory_document_lines
    (company_id, document_id, line_no, item_id, direction, quantity, uom_id, warehouse_id, sales_order_line_id)
  select d.company_id, d.id, v_next + 10 * row_number() over (order by l.line_no),
         l.item_id, -1,
         trunc((l.quantity_base - l.delivered_qty_base) * l.quantity / l.quantity_base, u.decimals),
         l.uom_id, l.warehouse_id, l.id
  from public.sales_order_lines l
  join public.sales_orders so on so.id = l.sales_order_id
  join public.uoms u on u.id = l.uom_id
  join public.items i on i.id = l.item_id
  where l.sales_order_id = p_so_id
    and so.business_partner_id = d.business_partner_id
    and so.status = 'OPEN' and l.line_status = 'OPEN'
    and i.item_type = 'INVENTORY'
    and trunc((l.quantity_base - l.delivered_qty_base) * l.quantity / l.quantity_base, u.decimals) > 0
    and not exists (select 1 from public.inventory_document_lines x where x.document_id = d.id and x.sales_order_line_id = l.id);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Views: open SO lines, reserved, projected stock, order time buffers
-- -----------------------------------------------------------------------------

create or replace view public.v_open_so_lines
with (security_invoker = true) as
select l.company_id, so.id as sales_order_id, so.doc_number, so.doc_date, so.due_date, so.time_buffer_days,
       so.due_date - so.time_buffer_days as buffer_start,
       so.business_partner_id, bp.code as customer_code, bp.name as customer_name,
       l.id as sales_order_line_id, l.line_no, l.item_id, i.item_code, i.name as item_name, i.replenishment_policy,
       l.warehouse_id, w.code as warehouse_code, l.quantity_base, l.delivered_qty_base,
       l.quantity_base - l.delivered_qty_base as open_qty_base, u.code as base_uom
from public.sales_order_lines l
join public.sales_orders so       on so.id = l.sales_order_id
join public.business_partners bp  on bp.id = so.business_partner_id
join public.items i               on i.id = l.item_id
join public.warehouses w          on w.id = l.warehouse_id
join public.uom_groups g          on g.id = i.uom_group_id
join public.uoms u                on u.id = g.base_uom_id
where so.status = 'OPEN' and l.line_status = 'OPEN' and l.delivered_qty_base < l.quantity_base;

-- Reserved (committed) per item and warehouse (= B1 OITW.IsCommited, ERPNext Bin.reserved_qty).
create or replace view public.v_reserved
with (security_invoker = true) as
select company_id, item_id, warehouse_id, sum(open_qty_base) as reserved
from public.v_open_so_lines
group by company_id, item_id, warehouse_id;

-- On hand + on order − reserved (= ERPNext projected_qty; B1 "Available"). Recreated: a column is added mid-list.
drop view public.v_projected_stock;
create view public.v_projected_stock
with (security_invoker = true) as
with keys as (
  select company_id, item_id, warehouse_id from public.item_warehouse_stock
  union select company_id, item_id, warehouse_id from public.v_on_order
  union select company_id, item_id, warehouse_id from public.v_reserved
)
select k.company_id, k.item_id, k.warehouse_id,
       coalesce(s.on_hand, 0) as on_hand,
       coalesce(o.on_order, 0) as on_order,
       coalesce(r.reserved, 0) as reserved,
       coalesce(s.on_hand, 0) + coalesce(o.on_order, 0) - coalesce(r.reserved, 0) as projected
from keys k
left join public.item_warehouse_stock s on s.item_id = k.item_id and s.warehouse_id = k.warehouse_id
left join public.v_on_order o           on o.item_id = k.item_id and o.warehouse_id = k.warehouse_id
left join public.v_reserved r           on r.item_id = k.item_id and r.warehouse_id = k.warehouse_id;

-- TOC time buffer per open sales order. Penetration = days elapsed since buffer start / buffer length.
-- Before the buffer starts the order is not yet urgent (penetration < 0 shown as 0, zone GREEN).
-- stock_covered: every open line's quantity is on hand in its warehouse right now (ignores competing orders).
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

-- -----------------------------------------------------------------------------
-- 4. RLS, grants, triggers, indexes
-- -----------------------------------------------------------------------------

select private.enable_company_rls('public.sales_orders',            'SALES');
select private.enable_company_rls('public.sales_order_lines',       'SALES');
select private.enable_company_rls('public.sales_order_line_prices', 'SALES_PRICES');

-- Store users deliver: they see open SOs; partner names are already readable with INVENTORY (migration 004).
drop policy rls_select on public.sales_orders;
create policy rls_select on public.sales_orders for select to authenticated
  using (company_id in (select private.companies_with_access('SALES', 'READ'))
         or company_id in (select private.companies_with_access('INVENTORY', 'READ')));
drop policy rls_select on public.sales_order_lines;
create policy rls_select on public.sales_order_lines for select to authenticated
  using (company_id in (select private.companies_with_access('SALES', 'READ'))
         or company_id in (select private.companies_with_access('INVENTORY', 'READ')));
-- Sales users must read customers.
drop policy rls_select on public.business_partners;
create policy rls_select on public.business_partners for select to authenticated
  using (company_id in (select private.companies_with_access('BUSINESS_PARTNERS', 'READ'))
         or company_id in (select private.companies_with_access('INVENTORY', 'READ'))
         or company_id in (select private.companies_with_access('SALES', 'READ')));

revoke all on public.v_open_so_lines, public.v_reserved, public.v_projected_stock, public.v_sales_order_buffer from anon;

revoke all on function public.release_sales_order(uuid) from public, anon;
revoke all on function public.close_sales_order(uuid, uuid, uuid) from public, anon;
revoke all on function public.cancel_sales_order(uuid, uuid) from public, anon;
revoke all on function public.fill_delivery_from_so(uuid, uuid) from public, anon;
grant execute on function public.release_sales_order(uuid) to authenticated;
grant execute on function public.close_sales_order(uuid, uuid, uuid) to authenticated;
grant execute on function public.cancel_sales_order(uuid, uuid) to authenticated;
grant execute on function public.fill_delivery_from_so(uuid, uuid) to authenticated;

select private.attach_standard_triggers('public.sales_orders');
select private.attach_standard_triggers('public.sales_order_lines');
select private.attach_standard_triggers('public.sales_order_line_prices');

create index sales_orders_type_ix           on public.sales_orders (company_id, document_type_id);
create index sales_orders_bp_ix             on public.sales_orders (company_id, business_partner_id);
create index sales_orders_currency_ix       on public.sales_orders (currency_code);
create index sales_orders_close_reason_ix   on public.sales_orders (company_id, close_reason_id);
create index sales_orders_status_ix         on public.sales_orders (company_id, status, due_date);
create index sales_order_lines_so_ix        on public.sales_order_lines (company_id, sales_order_id);
create index sales_order_lines_item_ix      on public.sales_order_lines (company_id, item_id);
create index sales_order_lines_uom_ix       on public.sales_order_lines (company_id, uom_id);
create index sales_order_lines_wh_ix        on public.sales_order_lines (company_id, warehouse_id);
create index sales_order_line_prices_co_ix  on public.sales_order_line_prices (company_id, sales_order_line_id);
create index inventory_document_lines_so_line_ix on public.inventory_document_lines (company_id, sales_order_line_id);
