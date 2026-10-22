-- =============================================================================
-- Tests for migration 004 (business partners + purchasing). LOCAL/TEST ONLY.
-- Uses helpers from earlier test files (tests.try_as, tests.val_as, tests.ok, tests.co, tests.oh, tests.add_line).
-- =============================================================================
\set ON_ERROR_STOP 1
\set admin   '''00000000-0000-0000-0000-00000000000a'''
\set buyer   '''00000000-0000-0000-0000-00000000000b'''
\set planner '''00000000-0000-0000-0000-00000000000c'''
\set viewer  '''00000000-0000-0000-0000-00000000000d'''
\set pricer  '''00000000-0000-0000-0000-00000000000e'''

create or replace function tests.new_po(p_bp text, p_date date default date '2026-10-15') returns uuid language sql as $$
  insert into public.purchase_orders (company_id, document_type_id, business_partner_id, doc_date)
  select b.company_id, dt.id, b.id, p_date
  from public.business_partners b join public.document_types dt on dt.company_id = b.company_id and dt.code = 'PO'
  where b.code = p_bp returning id $$;

create or replace function tests.add_po_line(p_po uuid, p_no int, p_item text, p_qty numeric, p_uom text default null) returns uuid language sql as $$
  insert into public.purchase_order_lines (company_id, purchase_order_id, line_no, item_id, quantity, uom_id)
  select po.company_id, po.id, p_no, i.id, p_qty, (select id from public.uoms where company_id = po.company_id and code = p_uom)
  from public.purchase_orders po join public.items i on i.company_id = po.company_id and i.item_code = p_item
  where po.id = p_po returning id $$;

create or replace function tests.new_grpo(p_bp text, p_date date default date '2026-10-20') returns uuid language sql as $$
  insert into public.inventory_documents (company_id, document_type_id, business_partner_id, doc_date)
  select b.company_id, dt.id, b.id, p_date
  from public.business_partners b join public.document_types dt on dt.company_id = b.company_id and dt.code = 'GRPO'
  where b.code = p_bp returning id $$;

create or replace function tests.on_order(p_item text) returns numeric language sql as $$
  select coalesce(sum(o.on_order), 0) from public.v_on_order o join public.items i on i.id = o.item_id where i.item_code = p_item $$;

-- ------------------------------------------------------------------ draft defaults
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_po('S-TRADER') as po \gset
select tests.add_po_line(:'po', 10, 'RAW001', 100) as l1 \gset
select tests.ok((select currency_code from public.purchase_orders where id = :'po') = 'INR', 'PO currency defaults to company base when supplier has none');
select tests.ok((select supplier_item_code from public.purchase_order_lines where id = :'l1') = 'KB-RAW001', 'supplier item code copied from item-supplier data');
select tests.ok((select expected_date from public.purchase_order_lines where id = :'l1') = date '2026-10-20', 'expected date = PO date + item-supplier lead time (5 days)');
select tests.ok((select u.code from public.purchase_order_lines l join public.uoms u on u.id = l.uom_id where l.id = :'l1') = 'KG', 'unit defaults to item purchase unit');

select tests.new_po('S-PACK') as po2 \gset
select tests.add_po_line(:'po2', 10, 'PKG001', 5) as l2 \gset
select tests.ok((select currency_code from public.purchase_orders where id = :'po2') = 'USD', 'PO currency from supplier default (USD)');
select tests.ok((select u.code || ' ' || quantity_base from public.purchase_order_lines l join public.uoms u on u.id = l.uom_id where l.id = :'l2') = 'CTN 240.000000',
  '5 CTN ordered in the supplier purchase unit = 240 PKT base');
select tests.ok(tests.try_as(:planner, $q$insert into public.purchase_orders (company_id, document_type_id, business_partner_id)
  select company_id, (select id from public.document_types where code = 'PO' and company_id = tests.co('SPICE')), id
  from public.business_partners where code = 'C-RETAIL'$q$) like '23514: Business partner C-RETAIL is not a supplier%',
  'a customer cannot be a PO supplier');
rollback;

-- ------------------------------------------------------------------ release
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_po('S-TRADER') as po \gset
select tests.ok(tests.try_as(:planner, format('select public.release_purchase_order(%L)', :'po')) like '23514: PO has no lines%', 'empty PO cannot be released');
select tests.add_po_line(:'po', 10, 'RAW001', 100);
select tests.ok(tests.val_as(:planner, format('select public.release_purchase_order(%L)', :'po')) = 'PO/26-27/0001', 'release numbers the PO from its FY series');
select tests.ok((select status || ' ' || exchange_rate from public.purchase_orders where id = :'po') = 'OPEN 1.0000000000', 'released PO is OPEN with rate 1 for base currency');
select tests.ok(tests.on_order('RAW001') = 100, 'released PO counts as on order');
select tests.ok(tests.try_as(:planner, format($q$update public.purchase_orders set business_partner_id =
  (select id from public.business_partners where code = 'S-PACK') where id = %L$q$, :'po')) like '23514: PO PO/26-27/0001 is OPEN%',
  'supplier of a released PO cannot change');
select tests.ok(tests.try_as(:planner, format($q$update public.purchase_order_lines set quantity = 120 where purchase_order_id = %L$q$, :'po')) is null,
  'quantity of an open line can be raised');
select tests.ok(tests.on_order('RAW001') = 120, 'on order follows the raised quantity');
select tests.ok(tests.try_as(:planner, format('delete from public.purchase_orders where id = %L', :'po')) like '23514: PO PO/26-27/0001 is OPEN and cannot be deleted%',
  'released PO cannot be deleted');

select tests.new_po('S-PACK', date '2026-10-16') as usd \gset
select tests.add_po_line(:'usd', 10, 'PKG001', 1);
select tests.ok(tests.try_as(:planner, format('select public.release_purchase_order(%L)', :'usd')) like '23514: No exchange rate for USD on 2026-10-16%',
  'foreign-currency PO needs a rate for its date');
update public.purchase_orders set doc_date = date '2026-10-15' where id = :'usd';
select tests.ok(tests.try_as(:planner, format('select public.release_purchase_order(%L)', :'usd')) is null, 'USD PO released');
select tests.ok((select exchange_rate from public.purchase_orders where id = :'usd') = 83.9, 'USD PO carries the rate of its date (83.9)');
rollback;

-- ------------------------------------------------------------------ prices are separate
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_po('S-TRADER') as po \gset
select tests.add_po_line(:'po', 10, 'RAW001', 100) as l1 \gset
select tests.ok(tests.try_as(:planner, format('insert into public.purchase_order_line_prices (company_id, purchase_order_line_id, unit_price) values (tests.co(%L), %L, 250)', 'SPICE', :'l1')) like '42501%',
  'planner without PURCHASE_PRICES cannot set a price');
select tests.ok(tests.try_as(:pricer, format('insert into public.purchase_order_line_prices (company_id, purchase_order_line_id, unit_price) values (tests.co(%L), %L, 250)', 'SPICE', :'l1')) is null,
  'user with PURCHASE_PRICES sets the price');
select tests.ok(tests.val_as(:planner, 'select count(*) from public.purchase_order_line_prices') = '0', 'planner cannot see prices');
select tests.ok(tests.val_as(:planner, format('select count(*) from public.purchase_order_lines where id = %L', :'l1')) = '1', 'planner still sees the PO line');
rollback;

-- ------------------------------------------------------------------ receiving: partial, full, reversal, lead time
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_po('S-TRADER') as po \gset
select tests.add_po_line(:'po', 10, 'RAW001', 100) as l1 \gset
select public.release_purchase_order(:'po');

select tests.new_grpo('S-TRADER') as g1 \gset
select tests.ok(tests.val_as(:planner, format('select public.fill_receipt_from_po(%L, %L)', :'g1', :'po'))::int = 1, 'copy from PO adds the open line');
update public.inventory_document_lines set quantity = 60 where document_id = :'g1';
select tests.ok(tests.val_as(:planner, format('select public.post_inventory_document(%L)', :'g1')) = 'GRN/26-27/0001', 'partial receipt posts');
select tests.ok((select received_qty_base from public.purchase_order_lines where id = :'l1') = 60, 'PO line received 60');
select tests.ok((select status from public.purchase_orders where id = :'po') = 'OPEN', 'PO stays open after partial receipt');
select tests.ok(tests.on_order('RAW001') = 40 and tests.oh('RAW001', 'RM') = 110, 'on order 40, on hand 50+60 = 110');
select tests.ok((select lead_time_days || '/' || days_late from public.v_purchase_lead_times where receipt_id = :'g1') = '5/0',
  'lead time recorded: 5 days, on time');

select tests.new_grpo('S-TRADER', date '2026-10-24') as g2 \gset
select public.fill_receipt_from_po(:'g2', :'po');
select tests.ok((select quantity from public.inventory_document_lines where document_id = :'g2') = 40, 'second copy brings only the remaining 40');
select tests.ok(tests.val_as(:planner, format('select public.post_inventory_document(%L)', :'g2')) is not null, 'final receipt posts');
select tests.ok((select status || ' ' || close_type from public.purchase_orders where id = :'po') = 'CLOSED RECEIVED', 'fully received PO closes itself');
select tests.ok(tests.on_order('RAW001') = 0, 'nothing on order after full receipt');
select tests.ok((select receipts || ' ' || avg_days || ' ' || on_time_pct from public.v_item_supplier_lead_time v
                 join public.items i on i.id = v.item_id where i.item_code = 'RAW001') = '2 7.0 50',
  'lead-time stats: 2 receipts, avg 7 days, 50% on time');

select tests.ok(tests.val_as(:planner, format($q$select public.cancel_inventory_document(%L,
  (select id from public.reason_codes where code = 'ENTRY_ERROR' and company_id = tests.co('SPICE')))$q$, :'g2')) is not null,
  'second receipt cancelled');
select tests.ok((select status from public.purchase_orders where id = :'po') = 'OPEN'
  and (select received_qty_base from public.purchase_order_lines where id = :'l1') = 60, 'reversal reopens the PO and reduces received to 60');
select tests.ok(tests.on_order('RAW001') = 40, 'on order back to 40');
select tests.ok((select count(*) from public.v_purchase_lead_times where purchase_order_id = :'po') = 1, 'cancelled receipt excluded from lead times');
rollback;

-- ------------------------------------------------------------------ over-receipt tolerance
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_po('S-TRADER') as po \gset
select tests.add_po_line(:'po', 10, 'RAW001', 100);
select public.release_purchase_order(:'po');
select tests.new_grpo('S-TRADER') as g \gset
select public.fill_receipt_from_po(:'g', :'po');
update public.inventory_document_lines set quantity = 110 where document_id = :'g';
select tests.ok(tests.try_as(:planner, format('select public.post_inventory_document(%L)', :'g')) like '23514: Over-receipt on PO PO/26-27/0001 line 10: ordered 100%',
  'receiving 110 of 100 refused with 0% tolerance');
select tests.ok(tests.oh('RAW001','RM') = 50, 'refused over-receipt leaves stock unchanged');
update public.company_settings set over_receipt_pct = 10 where company_id = tests.co('SPICE');
select tests.ok(tests.try_as(:planner, format('select public.post_inventory_document(%L)', :'g')) is null, '110 of 100 accepted with 10% tolerance');
rollback;

begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_po('S-TRADER') as po \gset
select tests.add_po_line(:'po', 10, 'RAW001', 100);
select public.release_purchase_order(:'po');
select tests.new_grpo('S-TRADER') as g \gset
select public.fill_receipt_from_po(:'g', :'po');
update public.inventory_document_lines set quantity = 150 where document_id = :'g';
select tests.ok(tests.try_as(:admin, format('select public.post_inventory_document(%L)', :'g')) is null, 'superuser (OVER_RECEIPT) may exceed tolerance');
rollback;

-- ------------------------------------------------------------------ link validation
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_po('S-PACK') as po \gset
select tests.add_po_line(:'po', 10, 'PKG001', 1) as l \gset
update public.purchase_orders set doc_date = date '2026-10-15' where id = :'po';
select public.release_purchase_order(:'po');
select tests.new_grpo('S-TRADER') as g \gset
select tests.ok(tests.try_as(:planner, format($q$insert into public.inventory_document_lines (company_id, document_id, line_no, item_id, quantity, purchase_order_line_id)
  values (tests.co('SPICE'), %L, 10, (select id from public.items where item_code = 'PKG001'), 1, %L)$q$, :'g', :'l')) like '23514: PO PO/26-27/0001 belongs to another supplier%',
  'cannot receive another supplier''s PO line');
select tests.ok(tests.try_as(:planner, $q$insert into public.inventory_documents (company_id, document_type_id)
  values (tests.co('SPICE'), (select id from public.document_types where code = 'GRPO' and company_id = tests.co('SPICE')))$q$) like '23514: A supplier is required%',
  'goods receipt PO needs a supplier');
select tests.ok(tests.try_as(:planner, $q$insert into public.inventory_documents (company_id, document_type_id, business_partner_id)
  values (tests.co('SPICE'), (select id from public.document_types where code = 'GR' and company_id = tests.co('SPICE')),
          (select id from public.business_partners where code = 'S-TRADER'))$q$) like '23514: A supplier is required on goods receipt PO documents and only there%',
  'plain goods receipt takes no supplier');
rollback;

-- ------------------------------------------------------------------ close and cancel
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_po('S-TRADER') as po \gset
select tests.add_po_line(:'po', 10, 'RAW001', 100) as l1 \gset
select tests.add_po_line(:'po', 20, 'RAW002', 50) as l2 \gset
select public.release_purchase_order(:'po');

-- close one line short
select tests.ok(tests.try_as(:planner, format($q$select public.close_purchase_order(%L,
  (select id from public.reason_codes where code = 'SUPPLIER_SHORT'), %L)$q$, :'po', :'l2')) is null, 'single line closed short');
select tests.ok(tests.on_order('RAW002') = 0 and tests.on_order('RAW001') = 100, 'closed line no longer on order; other line still is');
select tests.ok((select status from public.purchase_orders where id = :'po') = 'OPEN', 'PO stays open while a line is open');

-- receive the remaining line fully -> PO closes
select tests.new_grpo('S-TRADER') as g \gset
select public.fill_receipt_from_po(:'g', :'po');
select tests.ok((select count(*) from public.inventory_document_lines where document_id = :'g') = 1, 'copy skips the closed line');
select public.post_inventory_document(:'g');
select tests.ok((select status from public.purchase_orders where id = :'po') = 'CLOSED', 'PO closes when remaining lines are received');
select tests.ok(tests.try_as(:planner, format($q$select public.cancel_purchase_order(%L,
  (select id from public.reason_codes where code = 'ENTRY_ERROR' and company_id = tests.co('SPICE')))$q$, :'po')) like '23514: Only an open PO%',
  'closed PO cannot be cancelled');
rollback;

begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_po('S-TRADER') as po \gset
select tests.add_po_line(:'po', 10, 'RAW001', 100);
select public.release_purchase_order(:'po');
select tests.ok(tests.try_as(:planner, format($q$select public.cancel_purchase_order(%L,
  (select id from public.reason_codes where code = 'ENTRY_ERROR' and company_id = tests.co('SPICE')))$q$, :'po')) is null,
  'PO without receipts can be cancelled');
select tests.ok((select status from public.purchase_orders where id = :'po') = 'CANCELLED' and tests.on_order('RAW001') = 0,
  'cancelled PO: status CANCELLED, nothing left on order');
select tests.ok(tests.try_as(:planner, format('update public.purchase_order_lines set quantity = 5 where purchase_order_id = %L', :'po')) like '23514%',
  'cancelled PO is frozen');

select tests.new_po('S-TRADER') as po2 \gset
select tests.add_po_line(:'po2', 10, 'RAW001', 10);
select public.release_purchase_order(:'po2');
select tests.new_grpo('S-TRADER') as g \gset
select public.fill_receipt_from_po(:'g', :'po2');
update public.inventory_document_lines set quantity = 4 where document_id = :'g';
select public.post_inventory_document(:'g');
select tests.ok(tests.try_as(:planner, format($q$select public.cancel_purchase_order(%L,
  (select id from public.reason_codes where code = 'ENTRY_ERROR' and company_id = tests.co('SPICE')))$q$, :'po2')) like '23514: PO has receipts%',
  'PO with receipts cannot be cancelled');
select tests.ok(tests.try_as(:planner, format('delete from public.purchase_order_lines where purchase_order_id = %L', :'po2')) like '23514: Line 10 has receipts%',
  'received line cannot be deleted');
select tests.ok(tests.try_as(:planner, format('update public.purchase_order_lines set quantity = 3 where purchase_order_id = %L', :'po2')) like '23514: Ordered quantity cannot be lower than already received%',
  'ordered quantity cannot go below received');
rollback;

-- ------------------------------------------------------------------ visibility
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_po('S-TRADER') as po \gset
select tests.add_po_line(:'po', 10, 'RAW001', 100);
select public.release_purchase_order(:'po');
select tests.ok(tests.val_as(:viewer, $q$select count(*) from public.v_open_po_lines where company_id = tests.co('SPICE')$q$) = '1',
  'store user (INVENTORY=READ) sees open PO lines to receive');
select tests.ok(tests.val_as(:buyer, 'select count(*) from public.v_open_po_lines') = '0', 'other company sees none');
select tests.ok(tests.val_as(:buyer, 'select count(*) from public.business_partners') = '0', 'MAPLE buyer without BP rights sees no partners');
select tests.ok((select projected from public.v_projected_stock p join public.items i on i.id = p.item_id where i.item_code = 'RAW001') = 150,
  'projected = on hand 50 + on order 100');
rollback;

-- ------------------------------------------------------------------ my_access helper
select tests.ok(tests.val_as(:planner, $q$select level from public.my_access(tests.co('SPICE')) where auth_object = 'PURCHASE_PRICES'$q$) = 'NONE',
  'my_access: planner has no price access');
select tests.ok(tests.val_as(:planner, $q$select level from public.my_access(tests.co('SPICE')) where auth_object = 'PURCHASING'$q$) = 'FULL',
  'my_access: planner has full purchasing');
select tests.ok(tests.val_as(:admin, $q$select bool_and(level = 'FULL') from public.my_access(tests.co('SPICE'))$q$)::boolean,
  'my_access: superuser has FULL everywhere');

\echo 'ALL PURCHASING TESTS PASSED'
