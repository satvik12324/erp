-- DEV/TEST SEED ONLY — sales orders and TOC buffers (pairs with migrations 005 and 006)
-- SPICE (INR, food): stock buffers on raw spices and the 500 g finished good; one open sales order.
-- MAPLE (CAD, trading): buffer on bolts in MAIN, one customer, one open sales order.
-- Roles: PLANNER gets SALES + BUFFERS FULL (no sales prices); USERADMIN gets SALES_PRICES; VIEWER reads.
-- No deliveries here: stock levels stay as earlier seeds left them so earlier test files are unaffected.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);

do $$
declare
  v_spice uuid := (select id from public.companies where code = 'SPICE');
  v_maple uuid := (select id from public.companies where code = 'MAPLE');
  b_cust_m uuid;
  so uuid;
  l uuid;
  nr uuid;
  c uuid;
begin
  insert into public.business_partners (company_id, code, name, bp_type)
  values (v_maple, 'C-HARDWARE', 'Northside Hardware Ltd', 'CUSTOMER') returning id into b_cust_m;
  update public.business_partners set bp_type = 'BOTH' where company_id = v_maple and code = 'S-BOLT';

  -- series + document types: sales order and delivery, in both companies
  -- MAPLE already has an SO type and series from the platform seed (SO-{YYYY}-{N:5})
  insert into public.number_ranges (company_id, code, name, pattern, reset_policy)
  values (v_spice, 'SO', 'Sales orders', 'SO/{FY}/{N:4}', 'FISCAL_YEAR') returning id into nr;
  insert into public.document_types (company_id, code, name, category, default_number_range_id)
  values (v_spice, 'SO', 'Sales order', 'SALES_ORDER', nr);

  foreach c in array array[v_spice, v_maple] loop
    insert into public.number_ranges (company_id, code, name, pattern, reset_policy)
    values (c, 'DLV', 'Deliveries', case when c = v_spice then 'DL/{FY}/{N:4}' else 'DL-{N:5}' end,
            case when c = v_spice then 'FISCAL_YEAR' else 'NONE' end) returning id into nr;
    insert into public.document_types (company_id, code, name, category, default_number_range_id)
    values (c, 'DLV', 'Delivery', 'DELIVERY', nr);

    insert into public.reason_codes (company_id, reason_type, code, name) values
      (c, 'SO_CLOSE',     'CUST_CANCEL',  'Customer cancelled the rest'),
      (c, 'BUFFER_RED',   'SUPPLIER_LATE','Supplier late'),
      (c, 'BUFFER_RED',   'DEMAND_SPIKE', 'Demand spike'),
      (c, 'BUFFER_BLACK', 'SUPPLIER_LATE','Supplier late'),
      (c, 'BUFFER_BLACK', 'DEMAND_SPIKE', 'Demand spike'),
      (c, 'BUFFER_CHANGE','DBM',          'Dynamic buffer management')
    on conflict (company_id, reason_type, code) do nothing;
  end loop;

  -- authorizations
  insert into public.role_permissions (company_id, role_id, auth_object, level)
  select company_id, id, x.obj, 'FULL' from public.roles r, (values ('SALES'), ('BUFFERS')) as x(obj)
  where r.code = 'PLANNER';
  insert into public.role_permissions (company_id, role_id, auth_object, level)
  select company_id, id, x.obj, 'FULL' from public.roles r, (values ('SALES'), ('SALES_PRICES')) as x(obj)
  where r.code = 'USERADMIN';
  insert into public.role_permissions (company_id, role_id, auth_object, level)
  select company_id, id, x.obj, 'READ' from public.roles r, (values ('SALES'), ('BUFFERS')) as x(obj)
  where r.code = 'VIEWER';

  -- stock buffers (targets in base unit: KG for spices, PKT for finished goods, EA for bolts)
  insert into public.item_buffers (company_id, item_id, warehouse_id, target_qty)
  select v_spice, i.id, w.id, x.target
  from (values ('RAW001', 'RM', 80), ('RAW002', 'RM', 60), ('RAW003', 'RM', 30), ('GM-500G', 'FG', 96)) as x(code, wh, target)
  join public.items i on i.company_id = v_spice and i.item_code = x.code
  join public.warehouses w on w.company_id = v_spice and w.code = x.wh;
  insert into public.item_buffers (company_id, item_id, warehouse_id, target_qty)
  select v_maple, i.id, w.id, 1920
  from public.items i join public.warehouses w on w.company_id = v_maple and w.code = 'MAIN'
  where i.company_id = v_maple and i.item_code = 'HW-0001';

  -- SPICE: open SO, 1 CTN garam masala 500 g, due in 20 days (buffer 14 days: not yet started)
  insert into public.sales_orders (company_id, document_type_id, business_partner_id, due_date, customer_reference)
  values (v_spice, (select id from public.document_types where company_id = v_spice and code = 'SO'),
          (select id from public.business_partners where company_id = v_spice and code = 'C-RETAIL'),
          current_date + 20, 'PO-RET-118') returning id into so;
  insert into public.sales_order_lines (company_id, sales_order_id, line_no, item_id, quantity)
  values (v_spice, so, 10, (select id from public.items where company_id = v_spice and item_code = 'GM-500G'), 1) returning id into l;
  insert into public.sales_order_line_prices (company_id, sales_order_line_id, unit_price) values (v_spice, l, 4800);
  perform public.release_sales_order(so);

  -- MAPLE: open SO, 10 cases of bolts, due in 5 days with a 10-day buffer (half consumed)
  insert into public.sales_orders (company_id, document_type_id, business_partner_id, due_date, time_buffer_days)
  values (v_maple, (select id from public.document_types where company_id = v_maple and code = 'SO'), b_cust_m,
          current_date + 5, 10) returning id into so;
  insert into public.sales_order_lines (company_id, sales_order_id, line_no, item_id, quantity)
  values (v_maple, so, 10, (select id from public.items where company_id = v_maple and item_code = 'HW-0001'), 10) returning id into l;
  insert into public.sales_order_line_prices (company_id, sales_order_line_id, unit_price) values (v_maple, l, 38.50);
  perform public.release_sales_order(so);
end $$;

select set_config('request.jwt.claim.sub', '', false);
