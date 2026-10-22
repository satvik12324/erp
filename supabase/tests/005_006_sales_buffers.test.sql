-- =============================================================================
-- Tests for migrations 005 (sales orders, deliveries, order buffers) and 006 (stock buffers, DBM, replenishment).
-- LOCAL/TEST ONLY. Uses helpers from earlier test files. Every block rolls back.
-- Seed state: SPICE SO/26-27/0001 (1 CTN GM-500G, due +20), MAPLE SO-2026-00001 (10 CS HW-0001, due +5, buffer 10).
-- =============================================================================
\set ON_ERROR_STOP 1
\set admin   '''00000000-0000-0000-0000-00000000000a'''
\set planner '''00000000-0000-0000-0000-00000000000c'''
\set viewer  '''00000000-0000-0000-0000-00000000000d'''
\set pricer  '''00000000-0000-0000-0000-00000000000e'''

create or replace function tests.new_so(p_bp text, p_due date default current_date + 30, p_buffer int default null) returns uuid language sql as $$
  insert into public.sales_orders (company_id, document_type_id, business_partner_id, due_date, time_buffer_days)
  select b.company_id, dt.id, b.id, p_due, p_buffer
  from public.business_partners b join public.document_types dt on dt.company_id = b.company_id and dt.code = 'SO'
  where b.code = p_bp returning id $$;

create or replace function tests.add_so_line(p_so uuid, p_no int, p_item text, p_qty numeric, p_uom text default null) returns uuid language sql as $$
  insert into public.sales_order_lines (company_id, sales_order_id, line_no, item_id, quantity, uom_id)
  select so.company_id, so.id, p_no, i.id, p_qty, (select id from public.uoms where company_id = so.company_id and code = p_uom)
  from public.sales_orders so join public.items i on i.company_id = so.company_id and i.item_code = p_item
  where so.id = p_so returning id $$;

create or replace function tests.new_dlv(p_bp text) returns uuid language sql as $$
  insert into public.inventory_documents (company_id, document_type_id, business_partner_id)
  select b.company_id, dt.id, b.id
  from public.business_partners b join public.document_types dt on dt.company_id = b.company_id and dt.code = 'DLV'
  where b.code = p_bp returning id $$;

create or replace function tests.reason(p_company text, p_type text, p_code text) returns uuid language sql as $$
  select r.id from public.reason_codes r join public.companies c on c.id = r.company_id
  where c.code = p_company and r.reason_type = p_type and r.code = p_code $$;

create or replace function tests.buf(p_item text) returns public.v_buffer_status language sql as $$
  select b.* from public.v_buffer_status b where b.item_code = p_item $$;

create or replace function tests.receive(p_item text, p_qty numeric, p_uom text, p_wh text) returns void language plpgsql as $$
declare d uuid;
begin
  d := tests.new_doc('SPICE', 'GR');
  update public.inventory_documents set reason_code_id = tests.reason('SPICE', 'OPENING_STOCK', 'OPENING') where id = d;
  perform tests.add_line(d, 10, p_item, p_qty, p_uom, p_wh);
  perform public.post_inventory_document(d);
end $$;

-- ------------------------------------------------------------------ SO draft rules
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.ok(tests.try_as(:planner, $q$select tests.new_so('S-TRADER')$q$) like '23514: Business partner S-TRADER is not a customer%',
  'a supplier cannot be an SO customer');
select tests.new_so('C-RETAIL') as so \gset
select tests.add_so_line(:'so', 10, 'GM-500G', 2) as l \gset
select tests.ok((select currency_code from public.sales_orders where id = :'so') = 'INR', 'SO currency defaults to company base');
select tests.ok((select u.code || ' ' || l.quantity_base || ' ' || w.code from public.sales_order_lines l
                 join public.uoms u on u.id = l.uom_id join public.warehouses w on w.id = l.warehouse_id where l.id = :'l') = 'CTN 96.000000 FG',
  'line defaults: item sales unit (CTN), 2 CTN = 96 PKT base, item default warehouse FG');
select tests.ok(tests.try_as(:planner, format($q$select tests.add_so_line(%L, 20, 'GM', 1)$q$, :'so')) like '23514: Template item GM cannot be sold%',
  'template item cannot be sold');
select tests.ok(tests.try_as(:planner, format($q$select tests.add_so_line(%L, 20, 'INT001', 1)$q$, :'so')) like '23514: Item INT001 is not marked as sold%',
  'item not marked as sold is refused');
select tests.ok(tests.try_as(:planner, format($q$select tests.add_so_line(%L, 20, 'GM-500G', 1.5)$q$, :'so')) like '23514: Quantity 1.5% has more than 0 decimals%',
  'quantity decimals follow the unit');
select tests.ok(tests.try_as(:viewer, format($q$insert into public.sales_order_lines (company_id, sales_order_id, line_no, item_id, quantity)
  values (tests.co('SPICE'), %L, 30, (select id from public.items where item_code = 'GM-100G'), 1)$q$, :'so')) like '42501%',
  'viewer (SALES READ) cannot add lines');
rollback;

-- ------------------------------------------------------------------ release, prices, reservation, order buffer
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.new_so('C-RETAIL', null) as so \gset
select tests.ok(tests.try_as(:planner, format('select public.release_sales_order(%L)', :'so')) like '23514: SO has no lines%', 'empty SO cannot be released');
select tests.add_so_line(:'so', 10, 'GM-500G', 2) as l \gset
select tests.ok(tests.try_as(:planner, format('select public.release_sales_order(%L)', :'so')) like '23514: Enter the due date%', 'SO needs a due date to release');
update public.sales_orders set due_date = current_date + 10 where id = :'so';
select tests.ok(tests.try_as(:viewer, format('select public.release_sales_order(%L)', :'so')) like '42501%', 'viewer cannot release');
select tests.ok(tests.val_as(:planner, format('select public.release_sales_order(%L)', :'so')) = 'SO/26-27/0002', 'release numbers the SO from its FY series');
select tests.ok((select status || ' ' || exchange_rate || ' ' || time_buffer_days from public.sales_orders where id = :'so') = 'OPEN 1.0000000000 14',
  'released SO is OPEN, rate 1, time buffer from company default (14 days)');
select tests.ok(tests.try_as(:planner, format($q$update public.sales_orders set business_partner_id = (select id from public.business_partners where code = 'S-TRADER') where id = %L$q$, :'so'))
  like '23514: SO SO/26-27/0002 is OPEN%', 'customer of a released SO cannot change');
select tests.ok(tests.try_as(:planner, format($q$update public.sales_orders set due_date = current_date + 12 where id = %L$q$, :'so')) is null,
  'due date of an open SO can be rescheduled');
select tests.ok(tests.try_as(:planner, format('delete from public.sales_orders where id = %L', :'so')) like '23514: SO SO/26-27/0002 is OPEN and cannot be deleted%',
  'released SO cannot be deleted');

select tests.ok(tests.try_as(:planner, format($q$insert into public.sales_order_line_prices (company_id, sales_order_line_id, unit_price) values (tests.co('SPICE'), %L, 4700)$q$, :'l')) like '42501%',
  'planner without SALES_PRICES cannot price');
select tests.ok(tests.try_as(:pricer, format($q$insert into public.sales_order_line_prices (company_id, sales_order_line_id, unit_price) values (tests.co('SPICE'), %L, 4700)$q$, :'l')) is null,
  'user with SALES_PRICES sets the price');
select tests.ok(tests.val_as(:planner, format('select count(*) from public.sales_order_line_prices where sales_order_line_id = %L', :'l')) = '0', 'planner cannot see prices');
select tests.ok(tests.val_as(:planner, format('select count(*) from public.sales_order_lines where id = %L', :'l')) = '1', 'planner sees the line');

select tests.ok((select reserved from public.v_reserved r join public.items i on i.id = r.item_id where i.item_code = 'GM-500G') = 144,
  'reserved = open SO quantity: seed 48 + 96 PKT');
select tests.ok((select projected from public.v_projected_stock p join public.items i on i.id = p.item_id where i.item_code = 'GM-500G') = -144,
  'projected = on hand 0 + on order 0 - reserved 144');

-- order buffer: due in 12 days with a 14-day buffer = 2 of 14 days consumed = 14% GREEN
select tests.ok((select penetration || ' ' || zone from public.v_sales_order_buffer where sales_order_id = :'so') = '14 GREEN', 'order buffer 2/14 days = 14% GREEN');
update public.sales_orders set due_date = current_date + 4 where id = :'so';
select tests.ok((select penetration || ' ' || zone from public.v_sales_order_buffer where sales_order_id = :'so') = '71 RED', 'due in 4 days: 10/14 = 71% RED');
update public.sales_orders set due_date = current_date + 6 where id = :'so';
select tests.ok((select zone from public.v_sales_order_buffer where sales_order_id = :'so') = 'YELLOW', 'due in 6 days: 8/14 = 57% YELLOW');
select set_config('erp.posting', 'on', true);
update public.sales_orders set doc_date = current_date - 5, due_date = current_date - 1 where id = :'so';
select set_config('erp.posting', 'off', true);
select tests.ok((select penetration || ' ' || zone || ' ' || days_to_due from public.v_sales_order_buffer where sales_order_id = :'so') = '107 BLACK -1',
  'past due: 15/14 = 107% BLACK');
select tests.ok((select stock_covered from public.v_sales_order_buffer where sales_order_id = :'so') = false, 'no stock: order not covered');
select tests.ok(tests.val_as(:viewer, 'select count(*) from public.v_sales_order_buffer where company_id = tests.co(''SPICE'')') = '2',
  'viewer (SALES READ) sees the order board');
select tests.ok(tests.val_as(:planner, 'select count(*) from public.sales_orders where company_id = tests.co(''MAPLE'')') = '0',
  'planner (SPICE only) sees no MAPLE orders');
rollback;

-- ------------------------------------------------------------------ delivery against SO
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.receive('GM-500G', 200, 'PKT', 'FG');
select tests.new_so('C-RETAIL') as so \gset
select tests.add_so_line(:'so', 10, 'GM-500G', 2) as l \gset
select tests.add_so_line(:'so', 20, 'PKG001', 1) as l2 \gset
select public.release_sales_order(:'so');

select tests.ok((select stock_covered from public.v_sales_order_buffer where sales_order_id = :'so') = true, 'stock on hand covers the order');
select tests.ok(tests.try_as(:planner, $q$insert into public.inventory_documents (company_id, document_type_id)
  values (tests.co('SPICE'), (select id from public.document_types where code = 'DLV' and company_id = tests.co('SPICE')))$q$) like '23514: A business partner is required%',
  'delivery needs a customer');
select tests.ok(tests.try_as(:planner, $q$select tests.new_dlv('S-TRADER')$q$) like '23514: Business partner is not a customer%',
  'delivery to a supplier is refused');

select tests.new_dlv('C-RETAIL') as d \gset
select tests.ok(tests.val_as(:planner, format('select public.fill_delivery_from_so(%L, %L)', :'d', :'so')) = '2', 'copy from SO adds both open lines');
update public.inventory_document_lines set quantity = 1 where document_id = :'d' and sales_order_line_id = :'l';
delete from public.inventory_document_lines where document_id = :'d' and sales_order_line_id = :'l2';
select tests.ok(tests.try_as(:planner, format('select public.post_inventory_document(%L)', :'d')) is null, 'partial delivery (1 of 2 CTN) posts');
select tests.ok(tests.oh('GM-500G', 'FG') = 152, 'stock reduced by 48 PKT');
select tests.ok((select delivered_qty_base from public.sales_order_lines where id = :'l') = 48, 'SO line delivered 48 PKT');
select tests.ok((select status from public.sales_orders where id = :'so') = 'OPEN', 'SO stays open after partial delivery');

select tests.new_dlv('C-RETAIL') as d2 \gset
select public.fill_delivery_from_so(:'d2', :'so');
select tests.ok((select string_agg(quantity::text, ',' order by line_no) from public.inventory_document_lines where document_id = :'d2') = '1.000000,1.000000',
  'second copy brings only remaining quantities');
select tests.ok(tests.try_as(:planner, format('select public.post_inventory_document(%L)', :'d2')) is null, 'final delivery posts');
select tests.ok((select status || ' ' || close_type from public.sales_orders where id = :'so') = 'CLOSED DELIVERED', 'fully delivered SO closes itself');
select tests.ok(not exists (select 1 from public.v_open_so_lines where sales_order_id = :'so'), 'nothing reserved after full delivery');

select tests.ok(tests.try_as(:planner, format('select public.cancel_inventory_document(%L, %L)', :'d2', tests.reason('SPICE', 'CANCELLATION', 'ENTRY_ERROR'))) is null,
  'final delivery cancelled');
select tests.ok((select status from public.sales_orders where id = :'so') = 'OPEN', 'cancelling the delivery reopens the SO');
select tests.ok((select delivered_qty_base from public.sales_order_lines where id = :'l') = 48, 'delivered back to 48');
select tests.ok(tests.oh('GM-500G', 'FG') = 152, 'stock returned by the reversal');

-- over-delivery
select tests.new_dlv('C-RETAIL') as d3 \gset
select tests.add_line(:'d3', 10, 'GM-500G', 2, 'CTN', 'FG');
update public.inventory_document_lines set sales_order_line_id = :'l' where document_id = :'d3';
select tests.ok(tests.try_as(:planner, format('select public.post_inventory_document(%L)', :'d3')) like '23514: Over-delivery on SO SO/26-27/0002 line 10%',
  'delivering 144 of 96 refused with 0% tolerance');
select tests.ok(tests.oh('GM-500G', 'FG') = 152, 'refused delivery leaves stock unchanged');

-- link rules
select tests.new_doc('SPICE', 'GI') as gi \gset
select tests.ok(tests.try_as(:planner, format($q$insert into public.inventory_document_lines (company_id, document_id, line_no, item_id, quantity, sales_order_line_id)
  values (tests.co('SPICE'), %L, 10, (select id from public.items where item_code = 'GM-500G'), 1, %L)$q$, :'gi', :'l')) like '23514: Only delivery lines can refer to an SO line%',
  'goods issue cannot refer to an SO line');
select tests.ok(tests.try_as(:planner, format($q$insert into public.inventory_document_lines (company_id, document_id, line_no, item_id, quantity, sales_order_line_id)
  values (tests.co('SPICE'), %L, 20, (select id from public.items where item_code = 'PKG001'), 1, %L)$q$, :'d3', :'l')) like '23514: Item differs from SO%',
  'delivery line item must match the SO line');

-- close / cancel
select tests.ok(tests.try_as(:planner, format('select public.cancel_sales_order(%L, %L)', :'so', tests.reason('SPICE', 'CANCELLATION', 'ENTRY_ERROR'))) like '23514: SO has deliveries%',
  'SO with deliveries cannot be cancelled');
select tests.ok(tests.try_as(:planner, format('select public.close_sales_order(%L, %L)', :'so', tests.reason('SPICE', 'CANCELLATION', 'ENTRY_ERROR'))) like '23514: An SO_CLOSE reason%',
  'closing needs an SO_CLOSE reason');
select tests.ok(tests.try_as(:planner, format('select public.close_sales_order(%L, %L)', :'so', tests.reason('SPICE', 'SO_CLOSE', 'CUST_CANCEL'))) is null, 'SO closed short with reason');
select tests.ok((select status || ' ' || close_type from public.sales_orders where id = :'so') = 'CLOSED MANUAL', 'closed manually');
select tests.ok(not exists (select 1 from public.v_open_so_lines where sales_order_id = :'so'), 'closed SO no longer reserves stock');

select tests.new_so('C-RETAIL') as so2 \gset
select tests.add_so_line(:'so2', 10, 'GM-100G', 1);
select public.release_sales_order(:'so2');
select tests.ok(tests.try_as(:planner, format('select public.cancel_sales_order(%L, %L)', :'so2', tests.reason('SPICE', 'CANCELLATION', 'ENTRY_ERROR'))) is null, 'SO without deliveries cancelled');
select tests.ok(tests.try_as(:planner, format($q$update public.sales_order_lines set quantity = 3 where sales_order_id = %L$q$, :'so2')) like '23514: SO SO/26-27/0003 is CANCELLED%',
  'cancelled SO cannot change');
rollback;

-- ------------------------------------------------------------------ stock buffers
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.ok(tests.try_as(:planner, $q$insert into public.item_buffers (company_id, item_id, warehouse_id, target_qty)
  values (tests.co('SPICE'), (select id from public.items where item_code = 'PKG001'), (select id from public.warehouses where code = 'RM'), 10)$q$)
  like '23514: Item PKG001 must be an inventory item with replenishment policy BUFFER%', 'buffer only for BUFFER items');
select tests.ok(tests.try_as(:viewer, format($q$update public.item_buffers set target_qty = 50 where id = %L$q$, (tests.buf('RAW001')).item_buffer_id)) is null
  and (tests.buf('RAW001')).target_qty = 80, 'viewer cannot change a target (RLS filters the update)');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);

select tests.ok((select penetration || ' ' || zone || ' ' || replenish_qty from tests.buf('RAW001')) = '38 YELLOW 30.000000',
  'RAW001: target 80, on hand 50 -> 38% YELLOW, replenish 30');
select tests.new_po('S-TRADER') as po \gset
select tests.add_po_line(:'po', 10, 'RAW001', 30);
select public.release_purchase_order(:'po');
select tests.ok((select zone = 'YELLOW' and net_flow = 80 and replenish_qty = 0 from tests.buf('RAW001')),
  'after a PO for 30: net flow 80, nothing more to order, zone still by on hand');
select tests.ok(not exists (select 1 from public.v_replenishment where item_code = 'RAW001'), 'RAW001 leaves the replenishment proposal');

-- order demand: an SO due within its buffer allocates buffer stock; a far-off small order does not; a spike does
select tests.ok((select allocated || ' ' || spike_qty from tests.buf('GM-500G')) = '48.000000 48.000000',
  'seed order (48 of target 96 = 50% = spike threshold) is allocated early as a spike');
select tests.new_so('C-RETAIL', current_date + 40) as so \gset
select tests.add_so_line(:'so', 10, 'RAW001', 5, 'KG');
select public.release_sales_order(:'so');
select tests.ok((tests.buf('RAW001')).allocated = 0, 'small order due in 40 days (buffer not started) is not allocated');
update public.sales_orders set due_date = current_date + 10 where id = :'so';
select tests.ok((select allocated || ' ' || available || ' ' || replenish_qty from tests.buf('RAW001')) = '5.000000 45.000000 5.000000',
  'order inside its time buffer allocates 5: available 45, replenish 5');

-- TO_ORDER shortage: 3 CTN pouches sold = 144 PKT vs 96 on hand
select tests.new_so('C-RETAIL') as so2 \gset
select tests.add_so_line(:'so2', 10, 'PKG001', 3, 'CTN');
select public.release_sales_order(:'so2');
select tests.ok((select source || ' ' || need_base || ' ' || supplier_code || ' ' || suggested_purchase_qty || ' ' || purchase_uom from public.v_replenishment where item_code = 'PKG001')
  = 'TO_ORDER 48.000000 S-PACK 1 CTN', 'to-order shortage of 48 PKT proposed as 1 CTN from the preferred supplier');
select tests.ok(tests.val_as(:viewer, 'select count(*) from public.v_buffer_status where company_id = tests.co(''SPICE'')') = '4', 'viewer sees the buffer board');
rollback;

-- ------------------------------------------------------------------ snapshots, red/black events, reasons
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select tests.ok(tests.try_as(:planner, 'select public.take_buffer_snapshot(tests.co(''MAPLE''))') like '42501%', 'cannot snapshot a company without access');
select tests.ok(tests.val_as(:planner, 'select public.take_buffer_snapshot(tests.co(''SPICE''))') = '4', 'snapshot writes 4 stock buffers');
select tests.ok((select count(*) from public.buffer_snapshots where company_id = tests.co('SPICE') and buffer_kind = 'ORDER') = 1, 'and 1 open order');
select tests.ok((select count(*) from public.buffer_events where company_id = tests.co('SPICE')) = 1, 'GM-500G (no stock) entered BLACK');
select tests.val_as(:planner, 'select public.take_buffer_snapshot(tests.co(''SPICE''))');
select tests.ok((select count(*) from public.buffer_snapshots where company_id = tests.co('SPICE')) = 5 and (select count(*) from public.buffer_events) = 1,
  'second run the same day changes nothing');

select id as ev from public.buffer_events where company_id = tests.co('SPICE') \gset
select tests.ok(tests.try_as(:planner, format('select public.set_buffer_event_reason(%L, %L)', :'ev', tests.reason('SPICE', 'BUFFER_RED', 'SUPPLIER_LATE'))) like '23514: A BUFFER_BLACK reason%',
  'a black event needs a BUFFER_BLACK reason');
select tests.ok(tests.try_as(:viewer, format('select public.set_buffer_event_reason(%L, %L)', :'ev', tests.reason('SPICE', 'BUFFER_BLACK', 'DEMAND_SPIKE'))) like '42501%',
  'viewer cannot record reasons');
select tests.ok(tests.try_as(:planner, format('select public.set_buffer_event_reason(%L, %L, %L)', :'ev', tests.reason('SPICE', 'BUFFER_BLACK', 'DEMAND_SPIKE'), 'Festival order')) is null,
  'planner records the cause');
select tests.ok((select reason_name || ' ' || events from public.v_buffer_reason_pareto where company_id = tests.co('SPICE')) = 'Demand spike 1', 'Pareto counts the cause');
select tests.ok(tests.try_as(:planner, $q$delete from public.buffer_events$q$) like '42501%', 'events cannot be deleted through the API');
select tests.ok(tests.try_as(:planner, $q$insert into public.buffer_snapshots (company_id, snapshot_date, buffer_kind, item_buffer_id, penetration, zone)
  select company_id, current_date - 1, 'STOCK', id, 0, 'GREEN' from public.item_buffers limit 1$q$) like '42501%', 'snapshots are written by the function only');

-- RAW001 RED -> RED does not create a second event; RED -> BLACK does
update public.item_buffers set target_qty = 200 where item_id = (select id from public.items where item_code = 'RAW001');
select public.take_buffer_snapshot(tests.co('SPICE'));
select tests.ok((select count(*) from public.buffer_events e join public.item_buffers b on b.id = e.item_buffer_id
                 join public.items i on i.id = b.item_id where i.item_code = 'RAW001' and e.zone = 'RED') = 1, 'RAW001 entered RED (75%)');
rollback;

-- ------------------------------------------------------------------ dynamic buffer management
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
-- RAW001 red for 7 days: target 200 (on hand 50 = 75%), history of 6 red days, target unchanged for 30 days
update public.item_buffers set target_qty = 200 where item_id = (select id from public.items where item_code = 'RAW001');
update public.item_buffers set last_changed_on = current_date - 30;
insert into public.buffer_snapshots (company_id, snapshot_date, buffer_kind, item_buffer_id, penetration, zone)
select b.company_id, current_date - g, 'STOCK', b.id, 80, 'RED'
from public.item_buffers b join public.items i on i.id = b.item_id, generate_series(1, 6) g where i.item_code = 'RAW001';
-- RAW002 green for 30 days (target 60, on hand 50 = 17%)
insert into public.buffer_snapshots (company_id, snapshot_date, buffer_kind, item_buffer_id, penetration, zone)
select b.company_id, current_date - g, 'STOCK', b.id, 17, 'GREEN'
from public.item_buffers b join public.items i on i.id = b.item_id, generate_series(1, 29) g where i.item_code = 'RAW002';
-- RAW003 green for only 10 days: no proposal
insert into public.buffer_snapshots (company_id, snapshot_date, buffer_kind, item_buffer_id, penetration, zone)
select b.company_id, current_date - g, 'STOCK', b.id, 0, 'GREEN'
from public.item_buffers b join public.items i on i.id = b.item_id, generate_series(1, 9) g where i.item_code = 'RAW003';

select public.take_buffer_snapshot(tests.co('SPICE'));
select tests.ok((select string_agg(i.item_code || ' ' || p.direction || ' ' || p.current_target::numeric(10,0) || '->' || p.proposed_target::numeric(10,0), ', ' order by i.item_code)
                 from public.buffer_change_proposals p join public.item_buffers b on b.id = p.item_buffer_id join public.items i on i.id = b.item_id)
  = 'RAW001 INCREASE 200->266, RAW002 DECREASE 60->40', 'DBM proposes +33% after 7 red days and -33% after 30 green days, nothing for RAW003');
select tests.ok((tests.buf('RAW001')).target_qty = 200, 'targets do not change without approval');

select p.id as up from public.buffer_change_proposals p where direction = 'INCREASE' \gset
select p.id as down from public.buffer_change_proposals p where direction = 'DECREASE' \gset
select tests.ok(tests.try_as(:viewer, format('select public.decide_buffer_change(%L, true)', :'up')) like '42501%', 'viewer cannot approve');
select tests.ok(tests.try_as(:planner, format('select public.decide_buffer_change(%L, true, 240)', :'up')) is null, 'planner approves with an adjusted target');
select tests.ok((select b.target_qty || ' ' || ib.last_changed_on from tests.buf('RAW001') b join public.item_buffers ib on ib.id = b.item_buffer_id)
  = '240.000000 ' || current_date, 'target set to 240, change date today');
select tests.ok((select status || ' ' || approved_target from public.buffer_change_proposals where id = :'up') = 'APPROVED 240.000000', 'proposal recorded as approved');
select tests.ok(tests.try_as(:planner, format('select public.decide_buffer_change(%L, false)', :'up')) like '23514: Proposal is already APPROVED%', 'decided once only');
select tests.ok(tests.try_as(:planner, format('select public.decide_buffer_change(%L, false, null, %L)', :'down', 'Season starting')) is null, 'planner rejects the decrease');

select public.take_buffer_snapshot(tests.co('SPICE'));
select tests.ok((select count(*) from public.buffer_change_proposals) = 2, 'no new proposals: RAW001 just changed, RAW002 decrease was rejected');
select tests.ok((select count(*) from public.audit_log where table_name = 'item_buffers' and action = 'U') >= 1, 'target change is in the audit trail');
rollback;

\echo 'ALL SALES AND BUFFER TESTS PASSED'
