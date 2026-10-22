-- Rollback for 20261022000005_sales.sql
-- Restores the migration-004 versions of the inventory functions and v_projected_stock this migration replaced.

-- The stock ledger is append-only: refuse to roll back once deliveries exist.
do $$
begin
  if exists (select 1 from public.inventory_documents where category = 'DELIVERY') then
    raise exception 'Cannot roll back: delivery documents exist';
  end if;
end $$;

drop trigger if exists stock_movements_apply_so_delivery on public.stock_movements;

drop view if exists public.v_sales_order_buffer;
drop view if exists public.v_projected_stock;
drop view if exists public.v_reserved;
drop view if exists public.v_open_so_lines;

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
revoke all on public.v_projected_stock from anon;

drop function if exists public.fill_delivery_from_so(uuid, uuid);
drop function if exists private.apply_so_delivery();
drop function if exists public.cancel_sales_order(uuid, uuid);
drop function if exists public.close_sales_order(uuid, uuid, uuid);
drop function if exists public.release_sales_order(uuid);
drop function if exists private.refresh_so_status(uuid);

-- Restore business partner read policy of migration 004 (without SALES).
drop policy rls_select on public.business_partners;
create policy rls_select on public.business_partners for select to authenticated
  using (company_id in (select private.companies_with_access('BUSINESS_PARTNERS', 'READ'))
         or company_id in (select private.companies_with_access('INVENTORY', 'READ')));

alter table public.inventory_document_lines drop column if exists sales_order_line_id;
alter table public.inventory_documents drop constraint inventory_documents_category_ck;
alter table public.inventory_documents add constraint inventory_documents_category_ck check (
  category in ('GOODS_RECEIPT', 'GOODS_ISSUE', 'INVENTORY_TRANSFER', 'RECEIPT_FROM_PRODUCTION', 'GOODS_RECEIPT_PO'));

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

drop table if exists public.sales_order_line_prices;
drop table if exists public.sales_order_lines;
drop table if exists public.sales_orders;
drop function if exists private.guard_so_price();
drop function if exists private.prepare_sales_order_line();
drop function if exists private.block_released_so_delete();
drop function if exists private.prepare_sales_order();
drop function if exists private.buffer_zone(uuid, numeric);
drop function if exists private.company_today(uuid);

alter table public.company_settings drop constraint if exists company_settings_time_buffer_ck;
alter table public.company_settings drop column if exists default_time_buffer_days;

delete from public.role_permissions where auth_object in ('SALES', 'SALES_PRICES');
delete from public.reason_codes where reason_type = 'SO_CLOSE';
delete from public.reason_types where code = 'SO_CLOSE';
delete from public.auth_objects where code in ('SALES', 'SALES_PRICES');
