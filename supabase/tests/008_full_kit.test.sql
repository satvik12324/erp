-- =============================================================================
-- Tests for migration 008: full-kit allocation (D-046) and dependent demand in buffers / replenishment (D-047).
-- LOCAL/TEST ONLY. Uses helpers from earlier test files. Every block rolls back.
-- SPICE BOM: GM-500G (1 PKT) = 500 G INT001 blend + 1 PKT PKG002 pouch;
--            INT001 (10 KG)  = 4 KG RAW001 cumin + 4 KG RAW002 coriander + 2000 G RAW003 chilli.
-- Seed stock: RAW001 50 KG, RAW002 50 KG, RAW003 20 KG, PKG001 96 PKT, PKG002 100 PKT (all RM); no INT001, no GM.
-- Seed order: SO/26-27/0001, 1 CTN (48 PKT) GM-500G, due +20, buffer 14 (not started).
-- =============================================================================
\set ON_ERROR_STOP 1
set timezone = 'Asia/Kolkata';   -- SPICE's local date, see 005_006 tests
\set planner '''00000000-0000-0000-0000-00000000000c'''

-- requirement of an order for an item: 'required/allocated/short status' (quantities trimmed)
create or replace function tests.req(p_so uuid, p_item text) returns text language sql as $$
  select string_agg(trim_scale(required_qty) || '/' || trim_scale(allocated_qty) || '/' || trim_scale(short_qty)
                    || ' ' || requirement_status, ', ' order by seq)
  from public.v_full_kit_lines where sales_order_id = p_so and item_code = p_item $$;
create or replace function tests.kit(p_so uuid) returns text language sql as $$
  select kit_status || ' #' || priority_rank from public.v_sales_order_buffer where sales_order_id = p_so $$;

-- ------------------------------------------------------------------ seed: multi-level explosion
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select id as seed from public.sales_orders where doc_number = 'SO/26-27/0001' \gset

select tests.ok(tests.req(:'seed', 'GM-500G') = '48/0/48 BUILD', 'no finished stock: 48 PKT to build');
select tests.ok(tests.req(:'seed', 'INT001')  = '24/0/24 BUILD', 'level 1: 48 x 500 G = 24 KG blend, none on hand, to build');
select tests.ok(tests.req(:'seed', 'RAW001')  = '9.6/9.6/0 COVERED', 'level 2: 24 KG blend x 0.4 = 9.6 KG cumin, covered');
select tests.ok(tests.req(:'seed', 'RAW003')  = '4.8/4.8/0 COVERED', 'level 2: chilli in G on the BOM converted to 4.8 KG');
select tests.ok(tests.req(:'seed', 'PKG002')  = '48/48/0 COVERED', 'level 1: 48 pouches, covered');
select tests.ok((select string_agg(distinct level::text, ',') from public.v_full_kit_lines where sales_order_id = :'seed') = '0,1,2',
  'three levels returned');
select tests.ok(tests.kit(:'seed') = 'BUILDABLE #1', 'seed order is buildable from components on hand');
select tests.ok((select stock_covered from public.v_sales_order_buffer where sales_order_id = :'seed') = false,
  'stock_covered keeps its meaning (finished stock on hand) = kit READY');
select tests.ok(tests.val_as('00000000-0000-0000-0000-00000000000a', 'select kit_status from public.v_sales_order_buffer where company_id = tests.co(''MAPLE'')') = 'SHORT',
  'MAPLE: bought item with no stock is SHORT');
select tests.ok(tests.val_as(:planner, 'select count(*) from public.v_full_kit_lines where company_id = tests.co(''MAPLE'')') = '0',
  'planner (SPICE only) gets no MAPLE requirements');
rollback;

-- ------------------------------------------------------------------ priority allocation across competing orders
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select id as seed from public.sales_orders where doc_number = 'SO/26-27/0001' \gset
select tests.receive('GM-500G', 30, 'PKT', 'FG');
-- 11/14 = 79% RED
select tests.new_so('C-RETAIL', current_date + 3) as a \gset
select tests.add_so_line(:'a', 10, 'GM-500G', 40, 'PKT');
select public.release_sales_order(:'a');
-- 4/14 = 29% GREEN, started
select tests.new_so('C-RETAIL', current_date + 10) as b \gset
select tests.add_so_line(:'b', 10, 'GM-500G', 150, 'PKT');
select public.release_sales_order(:'b');

select tests.ok(tests.kit(:'a') || ' | ' || tests.kit(:'b') || ' | ' || tests.kit(:'seed') = 'BUILDABLE #1 | SHORT #2 | SHORT #3',
  'ranked by penetration: A (RED) buildable, B and seed short');
select tests.ok(tests.req(:'a', 'GM-500G') = '40/30/10 BUILD' and tests.req(:'b', 'GM-500G') = '150/0/150 BUILD',
  'the 30 finished units go to the most urgent order A, none to B');
select tests.ok(tests.req(:'b', 'PKG002') = '150/90/60 SHORT', 'pouches: A takes 10, B gets the remaining 90 of 100, short 60');
select tests.ok(tests.req(:'seed', 'RAW003') = '4.8/4/0.8 SHORT',
  'chilli: A 1 + B 15 come first, the not-started seed order gets the last 4 of 20 KG');
select tests.ok((select next_expected_date is null and on_order = 0 from public.v_full_kit_lines where sales_order_id = :'b' and item_code = 'PKG002'),
  'shortage line shows nothing on order');

-- a PO for pouches shows on the shortage line
select tests.new_po('S-TRADER') as po \gset
select tests.add_po_line(:'po', 10, 'PKG002', 100);
select public.release_purchase_order(:'po');
select tests.ok((select on_order > 0 and next_expected_date is not null from public.v_full_kit_lines where sales_order_id = :'b' and item_code = 'PKG002'),
  'shortage line shows the open PO and its expected date');

-- reschedule: the seed order becomes the most urgent and takes the finished stock
update public.sales_orders set due_date = current_date + 1 where id = :'seed';   -- 13/14 = 93% RED
select tests.ok(tests.kit(:'seed') = 'BUILDABLE #1' and tests.req(:'seed', 'GM-500G') = '48/30/18 BUILD',
  'after rescheduling, the seed order ranks first and takes the 30 finished units');
select tests.ok(tests.req(:'a', 'GM-500G') = '40/0/40 BUILD', 'order A now gets no finished units');
select tests.ok(tests.req(:'b', 'RAW003') = '15/14.2/0.8 SHORT', 'chilli shortage moves to the least urgent order needing it (B)');

-- stocked sub-assembly is used before its components
select tests.receive('INT001', 10, 'KG', 'RM');
select tests.ok(tests.req(:'seed', 'INT001') = '9/9/0 COVERED' and tests.req(:'seed', 'RAW001') is null,
  'built blend on hand covers the seed order: no cumin demand for it');
select tests.ok(tests.req(:'a', 'INT001') = '20/1/19 BUILD', 'A gets the last 1 KG blend and builds 19 KG');

-- delivered quantity no longer needs a kit
select tests.receive('GM-500G', 18, 'PKT', 'FG');
select tests.ok(tests.kit(:'seed') = 'READY #1', 'with 48 finished units on hand the seed order is READY');
select tests.ok((select stock_covered from public.v_sales_order_buffer where sales_order_id = :'seed'), 'and stock_covered is true');
rollback;

-- ------------------------------------------------------------------ dependent demand in stock buffers and replenishment
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
-- RAW003 chilli: buffer target 30 KG, 20 on hand; seed order needs 4.8 KG through the BOM
select id as seed from public.sales_orders where doc_number = 'SO/26-27/0001' \gset
select tests.ok((select trim_scale(dependent_allocated) || ' ' || trim_scale(allocated) || ' ' || zone from tests.buf('RAW003')) = '0 0 GREEN',
  'order buffer not started and 4.8 < spike (15 KG): no dependent demand allocated');
update public.sales_orders set due_date = current_date + 5 where id = :'seed';
select tests.ok((select trim_scale(dependent_allocated) || ' ' || trim_scale(allocated) || ' ' || trim_scale(available) || ' ' || zone from tests.buf('RAW003'))
  = '4.8 4.8 15.2 YELLOW', 'order buffer started: 4.8 KG allocated, available 15.2 of 30 = 49% YELLOW (was 33% GREEN)');

-- finished stock nets dependent demand away
select tests.receive('GM-500G', 48, 'PKT', 'FG');
select tests.ok((tests.buf('RAW003')).dependent_allocated = 0, 'finished units on hand: no component demand');
rollback;

begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
-- a far-off order big enough to be a spike: 2000 PKT -> 1000 KG blend -> 200 KG chilli (>= 50% of 30)
select tests.new_so('C-RETAIL', current_date + 60) as big \gset
select tests.add_so_line(:'big', 10, 'GM-500G', 2000, 'PKT');
select public.release_sales_order(:'big');
select tests.ok((select trim_scale(dependent_allocated) || ' ' || zone from tests.buf('RAW003')) = '200 BLACK',
  'dependent spike is allocated before its order buffer starts');

-- TO_ORDER components get proposals from dependent demand: pouches 48 (seed) + 2000 vs 100 on hand
select tests.ok((select source || ' ' || trim_scale(need_base) || ' ' || trim_scale(allocated) from public.v_replenishment where item_code = 'PKG002')
  = 'TO_ORDER 1948 2048', 'model-specific pouch proposed: demand 2048 - on hand 100');
select tests.ok((select procurement_method || ' ' || trim_scale(need_base) from public.v_replenishment where item_code = 'INT001')
  = 'MAKE 1024', 'blend (MAKE, to order) listed: 24 + 1000 KG to make');
select tests.ok(not exists (select 1 from public.v_replenishment where item_code = 'PKG001'), 'unrelated pouch not proposed');
rollback;

\echo 'ALL FULL-KIT TESTS PASSED'
