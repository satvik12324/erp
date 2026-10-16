-- DEV/TEST SEED ONLY — inventory module (pairs with migration 003)
-- MAPLE: MAIN (default) + OVERFLOW.  SPICE: RM (default, raw & packing) + FG (finished goods).
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);

do $$
declare
  v_maple uuid := (select id from public.companies where code = 'MAPLE');
  v_spice uuid := (select id from public.companies where code = 'SPICE');
  w_fg uuid;
  r uuid;
  d uuid;
begin
  insert into public.warehouses (company_id, code, name, is_default) values
    (v_maple, 'MAIN', 'Main warehouse', true),
    (v_maple, 'OVF',  'Overflow storage', false),
    (v_spice, 'RM',   'Raw material store', true);
  insert into public.warehouses (company_id, code, name) values (v_spice, 'FG', 'Finished goods store') returning id into w_fg;

  -- finished goods live in FG by default
  update public.items set default_warehouse_id = w_fg where company_id = v_spice and item_code like 'GM-%';

  -- numbering series + document types for inventory
  insert into public.number_ranges (company_id, code, name, pattern, reset_policy) values
    (v_maple, 'GR', 'Goods receipts',  'GR-{N:5}', 'NONE'),
    (v_maple, 'GI', 'Goods issues',    'GI-{N:5}', 'NONE'),
    (v_maple, 'TR', 'Transfers',       'TR-{N:5}', 'NONE'),
    (v_spice, 'GR', 'Goods receipts',  'GR/{FY}/{N:4}', 'FISCAL_YEAR'),
    (v_spice, 'GI', 'Goods issues',    'GI/{FY}/{N:4}', 'FISCAL_YEAR'),
    (v_spice, 'TR', 'Transfers',       'TR/{FY}/{N:4}', 'FISCAL_YEAR'),
    (v_spice, 'RFP', 'Production receipts', 'PR/{FY}/{N:4}', 'FISCAL_YEAR');

  insert into public.document_types (company_id, code, name, category, default_number_range_id)
  select nr.company_id, nr.code, nr.name,
         case nr.code when 'GR' then 'GOODS_RECEIPT' when 'GI' then 'GOODS_ISSUE'
                      when 'TR' then 'INVENTORY_TRANSFER' when 'RFP' then 'RECEIPT_FROM_PRODUCTION' end,
         nr.id
  from public.number_ranges nr
  where nr.code in ('GR', 'GI', 'TR', 'RFP') and nr.company_id in (v_maple, v_spice);

  insert into public.reason_codes (company_id, reason_type, code, name) values
    (v_maple, 'OPENING_STOCK', 'OPENING', 'Opening balance'),
    (v_spice, 'OPENING_STOCK', 'OPENING', 'Opening balance'),
    (v_maple, 'CANCELLATION',  'ENTRY_ERROR', 'Entry error'),
    (v_spice, 'CANCELLATION',  'ENTRY_ERROR', 'Entry error'),
    (v_spice, 'STOCK_ADJUSTMENT', 'DAMAGE', 'Damaged in store');

  -- authorizations for the test roles
  insert into public.role_permissions (company_id, role_id, auth_object, level)
  select company_id, id, 'INVENTORY', 'FULL' from public.roles where code = 'PLANNER';
  insert into public.role_permissions (company_id, role_id, auth_object, level)
  select company_id, id, 'WAREHOUSES', 'READ' from public.roles where code = 'PLANNER';
  insert into public.role_permissions (company_id, role_id, auth_object, level)
  select company_id, id, 'INVENTORY', 'READ' from public.roles where code = 'VIEWER';

  -- SPICE opening stock (posted)
  insert into public.inventory_documents (company_id, document_type_id, doc_date, reason_code_id, remarks)
  values (v_spice, (select id from public.document_types where company_id = v_spice and code = 'GR'),
          date '2026-10-01',
          (select id from public.reason_codes where company_id = v_spice and code = 'OPENING'),
          'Opening stock')
  returning id into d;

  insert into public.inventory_document_lines (company_id, document_id, line_no, item_id, quantity, uom_id)
  select v_spice, d, x.n, i.id, x.qty, u.id
  from (values (10, 'RAW001', 50, 'KG'), (20, 'RAW002', 50, 'KG'), (30, 'RAW003', 20000, 'G'),
               (40, 'PKG001', 2, 'CTN'), (50, 'PKG002', 100, 'PKT')) as x(n, code, qty, uom)
  join public.items i on i.company_id = v_spice and i.item_code = x.code
  join public.uoms u on u.company_id = v_spice and u.code = x.uom;

  perform public.post_inventory_document(d);
end $$;

select set_config('request.jwt.claim.sub', '', false);
