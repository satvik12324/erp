-- =============================================================================
-- Tests for migration 003 (inventory). Run after dev seeds. LOCAL/TEST ONLY.
-- Uses helpers from 001_002_platform_items.test.sql (tests.try_as, tests.val_as, tests.ok, tests.co).
-- =============================================================================
\set ON_ERROR_STOP 1
\set admin   '''00000000-0000-0000-0000-00000000000a'''
\set buyer   '''00000000-0000-0000-0000-00000000000b'''
\set planner '''00000000-0000-0000-0000-00000000000c'''
\set viewer  '''00000000-0000-0000-0000-00000000000d'''

-- Helpers: on-hand of item in warehouse (base UoM) and a new draft document
create or replace function tests.oh(p_item text, p_wh text) returns numeric language sql as $$
  select coalesce((select s.on_hand from public.item_warehouse_stock s
                   join public.items i on i.id = s.item_id join public.warehouses w on w.id = s.warehouse_id
                   where i.item_code = p_item and w.code = p_wh), 0) $$;

create or replace function tests.new_doc(p_company text, p_type text) returns uuid language sql as $$
  insert into public.inventory_documents (company_id, document_type_id)
  select c.id, dt.id from public.companies c join public.document_types dt on dt.company_id = c.id
  where c.code = p_company and dt.code = p_type
  returning id $$;

create or replace function tests.add_line(p_doc uuid, p_no int, p_item text, p_qty numeric, p_uom text,
                                          p_wh text default null, p_to_wh text default null) returns void language sql as $$
  insert into public.inventory_document_lines (company_id, document_id, line_no, item_id, quantity, uom_id, warehouse_id, to_warehouse_id)
  select d.company_id, d.id, p_no, i.id, p_qty, u.id,
         (select id from public.warehouses where company_id = d.company_id and code = p_wh),
         (select id from public.warehouses where company_id = d.company_id and code = p_to_wh)
  from public.inventory_documents d
  join public.items i on i.company_id = d.company_id and i.item_code = p_item
  join public.uoms u on u.company_id = d.company_id and u.code = p_uom
  where d.id = p_doc $$;

-- ------------------------------------------------------------------ opening stock from seed
select tests.ok(tests.oh('RAW001','RM') = 50,  'opening stock: 50 KG cumin in RM (main)');
select tests.ok(tests.oh('RAW003','RM') = 20,  'opening stock entered as 20000 G is held as 20 KG');
select tests.ok(tests.oh('PKG001','RM') = 96,  'opening stock 2 CTN pouches = 96 PKT');
select tests.ok((select doc_number from public.inventory_documents where remarks = 'Opening stock') = 'GR/26-27/0001',
  'posted receipt numbered from the FY series');
select tests.ok((select bool_and(s.on_hand = m.total) from public.item_warehouse_stock s
                 join (select item_id, warehouse_id, sum(quantity_base) total from public.stock_movements group by 1,2) m
                   using (item_id, warehouse_id)), 'on-hand equals sum of ledger');

-- ------------------------------------------------------------------ goods issue / negative stock
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_doc('SPICE', 'GI') as gi \gset
select tests.add_line(:'gi', 10, 'RAW001', 60, 'KG');
select tests.ok(tests.try_as(:planner, format('select public.post_inventory_document(%L)', :'gi')) like '23514: Insufficient stock: item RAW001 in warehouse RM would go to -10%',
  'issue beyond on-hand is refused with item, warehouse and shortfall');
select tests.ok(tests.oh('RAW001','RM') = 50, 'refused posting leaves stock unchanged');
select tests.ok((select status from public.inventory_documents where id = :'gi') = 'DRAFT', 'refused posting leaves draft');
select tests.ok(tests.try_as(:planner, format('select public.post_inventory_document(%L, (select id from public.reason_codes where code = ''RECEIPT_PENDING''))', :'gi')) like '42501%',
  'planner without STOCK_OVERRIDE cannot override');
select tests.ok(tests.try_as(:admin, format('select public.post_inventory_document(%L, (select id from public.reason_codes where code = ''DAMAGE''))', :'gi')) like '23514: Override reason must be%',
  'override needs a NEGATIVE_STOCK_OVERRIDE reason');
select tests.ok(tests.try_as(:admin, format('select public.post_inventory_document(%L, (select id from public.reason_codes where code = ''RECEIPT_PENDING''))', :'gi')) is null,
  'superuser overrides with reason');
select tests.ok(tests.oh('RAW001','RM') = -10, 'override posts negative stock');
select tests.ok((select r.code from public.stock_movements m join public.reason_codes r on r.id = m.override_reason_code_id
                 where m.document_id = :'gi') = 'RECEIPT_PENDING', 'override reason stored on the movement');
rollback;

-- ------------------------------------------------------------------ transfer
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_doc('SPICE', 'TR') as tr \gset
select tests.add_line(:'tr', 10, 'PKG002', 30, 'PKT', 'RM', 'FG');
select tests.ok(tests.try_as(:planner, format('select public.post_inventory_document(%L)', :'tr')) is null, 'transfer posts');
select tests.ok(tests.oh('PKG002','RM') = 70 and tests.oh('PKG002','FG') = 30, 'transfer moves 30 PKT RM -> FG');
select tests.ok((select sum(quantity_base) from public.stock_movements where document_id = :'tr') = 0, 'transfer nets to zero');
select tests.ok(tests.try_as(:planner, format($q$
  insert into public.inventory_document_lines (company_id, document_id, line_no, item_id, quantity, uom_id, warehouse_id)
  select company_id, %L, 99, (select id from public.items where item_code='PKG002'), 1,
         (select id from public.uoms where code='PKT' and company_id = tests.co('SPICE')),
         (select id from public.warehouses where code='RM')
  from public.inventory_documents where id = %L$q$, :'tr', :'tr')) like '23514%',
  'posted document lines are frozen');
rollback;

begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_doc('SPICE', 'TR') as tr \gset
select tests.ok(tests.try_as(:planner, format($q$select tests.add_line(%L, 10, 'PKG002', 5, 'PKT', 'RM')$q$, :'tr')) like '23514: A target warehouse is required%',
  'transfer line needs a target warehouse');
rollback;

-- ------------------------------------------------------------------ line validation
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_doc('SPICE', 'GR') as gr \gset
select tests.ok(tests.try_as(:planner, format($q$select tests.add_line(%L, 10, 'PKG001', 1.5, 'PKT')$q$, :'gr')) like '23514: Quantity 1.5%',
  'quantity decimals follow the UoM (no half packets)');
select tests.ok(tests.try_as(:planner, format($q$select tests.add_line(%L, 10, 'GM', 1, 'PKT')$q$, :'gr')) like '23514: Template item%',
  'template items cannot be moved');
select tests.ok(tests.try_as(:planner, format($q$select tests.add_line(%L, 10, 'RAW001', 1, 'PKT')$q$, :'gr')) like '23514: UoM is not in the UoM group%',
  'line UoM must fit the item');
select tests.ok(tests.try_as(:planner, format('select public.post_inventory_document(%L)', :'gr')) like '23514: Document has no lines%',
  'empty document cannot be posted');
rollback;

-- ------------------------------------------------------------------ receipt from production (2 levels)
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);

-- level 2: 20 KG blend -> issues 8 KG cumin, 8 KG coriander, 4000 G chilli from RM
select tests.new_doc('SPICE', 'RFP') as p1 \gset
select tests.ok(tests.val_as(:planner, format($q$select public.fill_production_receipt(%L,
  (select id from public.items where item_code='INT001'), 20)$q$, :'p1'))::int = 4,
  'fill: 1 product line + 3 backflush lines');
select tests.ok((select quantity from public.inventory_document_lines l join public.items i on i.id=l.item_id
                 where l.document_id = :'p1' and i.item_code='RAW003') = 4000,
  'component quantity in the BOM line UoM (4000 G)');
select tests.ok(tests.try_as(:planner, format('select public.post_inventory_document(%L)', :'p1')) is null, 'blend receipt posts');
select tests.ok(tests.oh('INT001','RM') = 20 and tests.oh('RAW001','RM') = 42 and tests.oh('RAW003','RM') = 16,
  'blend +20 KG; cumin 50-8=42; chilli 20-4=16 KG');

-- level 1: 10 PKT of 500 g -> 5 KG blend, 10 pouches; product to FG (item default), components from RM
select tests.new_doc('SPICE', 'RFP') as p2 \gset
select public.fill_production_receipt(:'p2', (select id from public.items where item_code='GM-500G'), 10);
select tests.ok((select w.code from public.inventory_document_lines l join public.warehouses w on w.id=l.warehouse_id
                 where l.document_id = :'p2' and l.direction = 1) = 'FG', 'product goes to its default warehouse (FG)');
select tests.ok(tests.try_as(:planner, format('select public.post_inventory_document(%L)', :'p2')) is null, 'finished goods receipt posts');
select tests.ok(tests.oh('GM-500G','FG') = 10 and tests.oh('INT001','RM') = 15 and tests.oh('PKG002','RM') = 90,
  'GM-500G +10 in FG; blend 20-5=15 KG; pouches 100-10=90');

-- cancel the finished goods receipt -> reversal restores everything
select tests.ok(tests.val_as(:planner, format($q$select public.cancel_inventory_document(%L,
  (select id from public.reason_codes where code='ENTRY_ERROR' and company_id = tests.co('SPICE')))$q$, :'p2')) like 'PR/%',
  'cancellation posts a reversing document');
select tests.ok(tests.oh('GM-500G','FG') = 0 and tests.oh('INT001','RM') = 15 + 5 and tests.oh('PKG002','RM') = 100,
  'reversal restores product and components');
select tests.ok((select status from public.inventory_documents where id = :'p2') = 'CANCELLED', 'original marked CANCELLED');
select tests.ok(tests.try_as(:planner, format($q$select public.cancel_inventory_document(%L,
  (select id from public.reason_codes where code='ENTRY_ERROR' and company_id = tests.co('SPICE')))$q$, :'p2')) like '23514%',
  'cannot cancel twice');
select tests.ok(tests.try_as(:planner, format('delete from public.inventory_documents where id = %L', :'p1')) like '23514: Posted document%',
  'posted documents cannot be deleted');
rollback;

-- BOM line issue warehouse overrides the component default
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
update public.bom_lines set issue_warehouse_id = (select id from public.warehouses where code = 'FG')
where component_item_id = (select id from public.items where item_code = 'PKG002');
select tests.new_doc('SPICE', 'RFP') as p3 \gset
select public.fill_production_receipt(:'p3', (select id from public.items where item_code='GM-500G'), 1);
select tests.ok((select w.code from public.inventory_document_lines l join public.warehouses w on w.id = l.warehouse_id
                 join public.items i on i.id = l.item_id where l.document_id = :'p3' and i.item_code = 'PKG002') = 'FG',
  'component issued from the BOM line warehouse');
rollback;

-- ------------------------------------------------------------------ security
begin;
select tests.ok(tests.val_as(:buyer, 'select count(*) from public.item_warehouse_stock') = '0', 'buyer (no INVENTORY) sees no stock');
select tests.ok(tests.val_as(:viewer, $q$select count(*) > 0 from public.v_stock_on_hand where company_id = tests.co('SPICE')$q$)::boolean,
  'viewer (INVENTORY=READ) sees stock through the view');
select tests.ok(tests.val_as(:buyer, 'select count(*) from public.warehouses') = '2',
  'any company user reads its warehouses (buyer sees MAPLE MAIN + OVF only)');
select tests.ok(tests.try_as(:planner, $q$insert into public.stock_movements (company_id, item_id, warehouse_id, posting_date, quantity_base,
  balance_after, category, document_id, document_line_id) select company_id, item_id, warehouse_id, current_date, 1, 1, 'GOODS_RECEIPT',
  document_id, id from public.inventory_document_lines limit 1$q$) like '42501%', 'ledger cannot be written directly');
select tests.ok(tests.try_as(:planner, 'update public.item_warehouse_stock set on_hand = 999') like '42501%', 'on-hand cannot be edited');
select tests.ok(tests.try_as(:admin, 'delete from public.stock_movements') like '42501%', 'ledger cannot be deleted through the API');
select tests.ok(tests.try_as(null, 'update public.stock_movements set quantity_base = 1') like '23514: The stock ledger is append-only%'
             or tests.try_as(null, 'update public.stock_movements set quantity_base = 1') like '42501%',
  'ledger is append-only');
rollback;

-- viewer cannot post (only READ)
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_doc('SPICE', 'GR') as v \gset
select tests.add_line(:'v', 10, 'RAW001', 1, 'KG');
select tests.ok(tests.try_as(:viewer, format('select public.post_inventory_document(%L)', :'v')) like '42501%',
  'viewer (INVENTORY=READ) cannot post');
rollback;

-- table owner cannot rewrite the ledger either (trigger, not just grants)
begin;
select tests.ok((select count(*) from public.stock_movements) > 0, 'ledger has rows');
do $$ begin
  update public.stock_movements set quantity_base = 1;
  raise exception 'should not reach';
exception when sqlstate '23514' then raise notice 'PASS: ledger append-only even for the owner';
end $$;
rollback;

\echo 'ALL INVENTORY TESTS PASSED'
