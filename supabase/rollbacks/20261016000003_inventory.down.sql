-- Rollback for 20261016000003_inventory.sql

drop view if exists public.v_stock_on_hand;
drop function if exists public.fill_production_receipt(uuid, uuid, numeric, uuid, uuid);
drop function if exists public.cancel_inventory_document(uuid, uuid, uuid);
drop function if exists public.post_inventory_document(uuid, uuid);

drop table if exists public.item_warehouse_stock;
drop table if exists public.stock_movements;
drop table if exists public.inventory_document_lines;
drop table if exists public.inventory_documents;

alter table public.bom_lines drop column if exists issue_warehouse_id;
alter table public.items drop column if exists default_warehouse_id;
drop table if exists public.warehouses;

-- restore UoM read policies from migration 002 (UOM=READ required)
drop policy if exists rls_select on public.uoms;
drop policy if exists rls_select on public.uom_groups;
drop policy if exists rls_select on public.uom_group_conversions;
create policy rls_select on public.uoms for select to authenticated
  using (company_id in (select private.companies_with_access('UOM', 'READ')));
create policy rls_select on public.uom_groups for select to authenticated
  using (company_id in (select private.companies_with_access('UOM', 'READ')));
create policy rls_select on public.uom_group_conversions for select to authenticated
  using (company_id in (select private.companies_with_access('UOM', 'READ')));

drop function if exists private.block_ledger_change();
drop function if exists private.prepare_inventory_line();
drop function if exists private.block_posted_document_delete();
drop function if exists private.prepare_inventory_document();
drop function if exists private.default_warehouse(uuid, uuid);

drop index if exists public.number_range_counters_range_ix;
drop index if exists public.role_permissions_role_ix;
drop index if exists public.status_definitions_category_ix;
drop index if exists public.user_company_roles_company_role_ix;

delete from public.reason_codes where reason_type = 'OPENING_STOCK';
delete from public.reason_types where code = 'OPENING_STOCK';
delete from public.role_permissions where auth_object in ('WAREHOUSES', 'INVENTORY', 'STOCK_OVERRIDE');
delete from public.auth_objects where code in ('WAREHOUSES', 'INVENTORY', 'STOCK_OVERRIDE');
