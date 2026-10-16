-- =============================================================================
-- DEV/TEST SEED ONLY — never apply to production.
-- Two deliberately dissimilar companies, so every migration is tested for generality:
--   MAPLE  Maple Trading Co.     CAD  Canada  FY Jan  — resells packaged goods, no production
--   SPICE  Spice Foods Pvt Ltd   INR  India   FY Apr  — makes spice blends, 2-level BOM, pack-size variants
-- Test users (fixed UUIDs so tests can impersonate them):
--   admin    platform admin, superuser in both companies
--   buyer    MAPLE only, role BUYER   (items READ, UoM READ, nothing else)
--   planner  SPICE only, role PLANNER (UoM/items/BOM FULL, config READ)
--   viewer   both companies, role VIEWER (items/BOM READ)
--   usermgr  SPICE only, role USERADMIN (USERS FULL, not superuser)
-- =============================================================================

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@example.test'),
  ('00000000-0000-0000-0000-00000000000b', 'buyer@example.test'),
  ('00000000-0000-0000-0000-00000000000c', 'planner@example.test'),
  ('00000000-0000-0000-0000-00000000000d', 'viewer@example.test'),
  ('00000000-0000-0000-0000-00000000000e', 'usermgr@example.test');

update public.user_profiles set is_platform_admin = true
where user_id = '00000000-0000-0000-0000-00000000000a';

-- Act as admin for the rest of the seed (stamps, audit and create_company read auth.uid()).
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);

do $$
declare
  v_maple uuid;
  v_spice uuid;
  r_buyer uuid; r_planner uuid; r_viewer_m uuid; r_viewer_s uuid; r_usermgr uuid;
  -- MAPLE
  u_ea uuid; u_cs uuid; u_pal uuid; g_unit uuid;
  nr_item_m uuid; nr_so uuid; nr_po uuid;
  ig_hw uuid; ig_cl uuid;
  -- SPICE
  u_kg uuid; u_g uuid; u_pkt uuid; u_ctn uuid; g_wt uuid; g_pk uuid;
  nr_item_s uuid; nr_inv uuid;
  ig_raw uuid; ig_int uuid; ig_fg uuid; ig_pkg uuid;
  a_pack uuid; a_shelf uuid; o_100 uuid; o_500 uuid;
  i_cumin uuid; i_cori uuid; i_chilli uuid; i_blend uuid; i_tmpl uuid; i_gm100 uuid; i_gm500 uuid;
  i_pouch100 uuid; i_pouch500 uuid;
  b uuid;
begin
  -- ---------------------------------------------------------------- companies
  v_maple := public.create_company('MAPLE', 'Maple Trading Co.', 'CAD', 'CA', 'America/Toronto', 1::smallint);
  v_spice := public.create_company('SPICE', 'Spice Foods Pvt Ltd', 'INR', 'IN', 'Asia/Kolkata', 4::smallint);

  insert into public.company_registrations (company_id, registration_type, registration_number) values
    (v_maple, 'BN',    '123456789RT0001'),
    (v_spice, 'GSTIN', '03ABCDE1234F1Z5'),
    (v_spice, 'IEC',   'ABCDE1234F');

  insert into public.exchange_rates (company_id, currency_code, rate_date, rate) values
    (v_maple, 'USD', date '2026-10-15', 1.3750),
    (v_maple, 'INR', date '2026-10-15', 0.0164),
    (v_spice, 'USD', date '2026-10-15', 83.9000),
    (v_spice, 'CAD', date '2026-10-15', 61.0000);

  -- ---------------------------------------------------------------- roles & users
  insert into public.roles (company_id, code, name) values (v_maple, 'BUYER', 'Buyer') returning id into r_buyer;
  insert into public.role_permissions (company_id, role_id, auth_object, level) values
    (v_maple, r_buyer, 'ITEM_MASTER', 'READ'),
    (v_maple, r_buyer, 'UOM', 'READ');

  insert into public.roles (company_id, code, name) values (v_spice, 'PLANNER', 'Planner') returning id into r_planner;
  insert into public.role_permissions (company_id, role_id, auth_object, level) values
    (v_spice, r_planner, 'ITEM_MASTER', 'FULL'),
    (v_spice, r_planner, 'UOM', 'FULL'),
    (v_spice, r_planner, 'BOM', 'FULL'),
    (v_spice, r_planner, 'CONFIG', 'READ');

  insert into public.roles (company_id, code, name) values (v_maple, 'VIEWER', 'Viewer') returning id into r_viewer_m;
  insert into public.roles (company_id, code, name) values (v_spice, 'VIEWER', 'Viewer') returning id into r_viewer_s;
  insert into public.role_permissions (company_id, role_id, auth_object, level) values
    (v_maple, r_viewer_m, 'ITEM_MASTER', 'READ'), (v_maple, r_viewer_m, 'BOM', 'READ'),
    (v_spice, r_viewer_s, 'ITEM_MASTER', 'READ'), (v_spice, r_viewer_s, 'BOM', 'READ');

  insert into public.roles (company_id, code, name) values (v_spice, 'USERADMIN', 'User administrator') returning id into r_usermgr;
  insert into public.role_permissions (company_id, role_id, auth_object, level) values
    (v_spice, r_usermgr, 'USERS', 'FULL');

  insert into public.user_company_roles (company_id, user_id, role_id) values
    (v_maple, '00000000-0000-0000-0000-00000000000b', r_buyer),
    (v_spice, '00000000-0000-0000-0000-00000000000c', r_planner),
    (v_maple, '00000000-0000-0000-0000-00000000000d', r_viewer_m),
    (v_spice, '00000000-0000-0000-0000-00000000000d', r_viewer_s),
    (v_spice, '00000000-0000-0000-0000-00000000000e', r_usermgr);

  -- ---------------------------------------------------------------- config
  insert into public.number_ranges (company_id, code, name, pattern, reset_policy) values
    (v_maple, 'ITEM', 'Item codes per group', '{SCOPE}-{N:4}', 'NONE') returning id into nr_item_m;
  insert into public.number_ranges (company_id, code, name, pattern, reset_policy) values
    (v_maple, 'SO', 'Sales orders', 'SO-{YYYY}-{N:5}', 'CALENDAR_YEAR') returning id into nr_so;
  insert into public.number_ranges (company_id, code, name, pattern, reset_policy) values
    (v_maple, 'PO', 'Purchase orders', 'PO{N:6}', 'NONE') returning id into nr_po;
  insert into public.number_ranges (company_id, code, name, pattern, reset_policy) values
    (v_spice, 'ITEM', 'Item codes per group', '{SCOPE}{N:3}', 'NONE') returning id into nr_item_s;
  insert into public.number_ranges (company_id, code, name, pattern, reset_policy) values
    (v_spice, 'INV', 'Tax invoices', 'INV/{FY}/{N:5}', 'FISCAL_YEAR') returning id into nr_inv;

  insert into public.document_types (company_id, code, name, category, default_number_range_id) values
    (v_maple, 'SO',  'Sales order',    'SALES_ORDER',    nr_so),
    (v_maple, 'PO',  'Purchase order', 'PURCHASE_ORDER', nr_po),
    (v_spice, 'INV', 'Tax invoice',    'AR_INVOICE',     nr_inv);

  insert into public.status_definitions (company_id, category, code, name, system_status, sort_order, is_default) values
    (v_maple, 'SALES_ORDER', 'NEW',        'New',                'OPEN',      10, true),
    (v_maple, 'SALES_ORDER', 'AWAIT_PAY',  'Awaiting deposit',   'OPEN',      20, false),
    (v_maple, 'SALES_ORDER', 'DONE',       'Shipped',            'CLOSED',    30, false),
    (v_spice, 'PRODUCTION_ORDER', 'PLANNED',  'Planned',          'DRAFT',     10, true),
    (v_spice, 'PRODUCTION_ORDER', 'RELEASED', 'Released to floor','RELEASED',  20, false);

  insert into public.reason_codes (company_id, reason_type, code, name) values
    (v_maple, 'BUFFER_RED',   'SUPPLIER_LATE', 'Supplier late'),
    (v_maple, 'BUFFER_RED',   'DEMAND_SPIKE',  'Demand spike'),
    (v_spice, 'BUFFER_BLACK', 'QC_REJECT',     'Quality rejection'),
    (v_spice, 'NEGATIVE_STOCK_OVERRIDE', 'RECEIPT_PENDING', 'Receipt not yet posted');

  -- ---------------------------------------------------------------- MAPLE: UoM, groups, items (no BOMs)
  insert into public.uoms (company_id, code, name, decimals) values (v_maple, 'EA',  'Each',   0) returning id into u_ea;
  insert into public.uoms (company_id, code, name, decimals) values (v_maple, 'CS',  'Case',   0) returning id into u_cs;
  insert into public.uoms (company_id, code, name, decimals) values (v_maple, 'PAL', 'Pallet', 0) returning id into u_pal;
  insert into public.uom_groups (company_id, code, name, base_uom_id) values (v_maple, 'EA-CS-PAL', 'Each / case / pallet', u_ea) returning id into g_unit;
  insert into public.uom_group_conversions (company_id, uom_group_id, alt_uom_id, alt_qty, base_qty) values
    (v_maple, g_unit, u_cs, 1, 24),
    (v_maple, g_unit, u_pal, 1, 960);

  insert into public.item_groups (company_id, code, name, number_range_id, default_uom_group_id, default_replenishment_policy)
  values (v_maple, 'HW', 'Hardware', nr_item_m, g_unit, 'BUFFER') returning id into ig_hw;
  insert into public.item_groups (company_id, code, name, number_range_id, default_uom_group_id)
  values (v_maple, 'CL', 'Cleaning supplies', nr_item_m, g_unit) returning id into ig_cl;

  insert into public.items (company_id, name, item_group_id, purchase_uom_id, sales_uom_id) values
    (v_maple, 'Hex bolt M8 x 40',      ig_hw, u_pal, u_cs),
    (v_maple, 'Flat washer M8',        ig_hw, u_pal, u_cs),
    (v_maple, 'Degreaser spray 500ml', ig_cl, u_cs,  u_ea);

  -- ---------------------------------------------------------------- SPICE: UoM, attributes, items, 2-level BOM
  insert into public.uoms (company_id, code, name, decimals) values (v_spice, 'KG',  'Kilogram', 3) returning id into u_kg;
  insert into public.uoms (company_id, code, name, decimals) values (v_spice, 'G',   'Gram',     0) returning id into u_g;
  insert into public.uoms (company_id, code, name, decimals) values (v_spice, 'PKT', 'Packet',   0) returning id into u_pkt;
  insert into public.uoms (company_id, code, name, decimals) values (v_spice, 'CTN', 'Carton',   0) returning id into u_ctn;
  insert into public.uom_groups (company_id, code, name, base_uom_id) values (v_spice, 'WEIGHT', 'Weight (kg)', u_kg) returning id into g_wt;
  insert into public.uom_group_conversions (company_id, uom_group_id, alt_uom_id, alt_qty, base_qty) values
    (v_spice, g_wt, u_g, 1000, 1);                    -- 1000 G = 1 KG
  insert into public.uom_groups (company_id, code, name, base_uom_id) values (v_spice, 'PACK', 'Packets / cartons', u_pkt) returning id into g_pk;
  insert into public.uom_group_conversions (company_id, uom_group_id, alt_uom_id, alt_qty, base_qty) values
    (v_spice, g_pk, u_ctn, 1, 48);                    -- 1 CTN = 48 PKT

  insert into public.item_groups (company_id, code, name, number_range_id, default_uom_group_id, default_replenishment_policy)
  values (v_spice, 'RAW', 'Raw spices', nr_item_s, g_wt, 'BUFFER') returning id into ig_raw;
  insert into public.item_groups (company_id, code, name, number_range_id, default_uom_group_id, default_procurement_method)
  values (v_spice, 'INT', 'Intermediates', nr_item_s, g_wt, 'MAKE') returning id into ig_int;
  insert into public.item_groups (company_id, code, name, number_range_id, default_uom_group_id, default_procurement_method, default_replenishment_policy)
  values (v_spice, 'FG', 'Finished goods', nr_item_s, g_pk, 'MAKE', 'BUFFER') returning id into ig_fg;
  insert into public.item_groups (company_id, code, name, number_range_id, default_uom_group_id)
  values (v_spice, 'PKG', 'Packaging', nr_item_s, g_pk) returning id into ig_pkg;

  insert into public.attribute_definitions (company_id, code, name, data_type, is_variant_axis)
  values (v_spice, 'PACK_SIZE', 'Pack size', 'LIST', true) returning id into a_pack;
  insert into public.attribute_definitions (company_id, code, name, data_type)
  values (v_spice, 'SHELF_LIFE_DAYS', 'Shelf life (days)', 'NUMBER') returning id into a_shelf;
  insert into public.attribute_options (company_id, attribute_definition_id, code, name, sort_order)
  values (v_spice, a_pack, '100G', '100 g', 10) returning id into o_100;
  insert into public.attribute_options (company_id, attribute_definition_id, code, name, sort_order)
  values (v_spice, a_pack, '500G', '500 g', 20) returning id into o_500;

  insert into public.items (company_id, name, item_group_id) values (v_spice, 'Cumin seed',     ig_raw) returning id into i_cumin;
  insert into public.items (company_id, name, item_group_id) values (v_spice, 'Coriander seed', ig_raw) returning id into i_cori;
  insert into public.items (company_id, name, item_group_id) values (v_spice, 'Red chilli',     ig_raw) returning id into i_chilli;
  insert into public.items (company_id, name, item_group_id, is_sold) values (v_spice, 'Roasted base blend', ig_int, false) returning id into i_blend;
  insert into public.items (company_id, name, item_group_id, is_purchased) values (v_spice, 'Pouch 100 g', ig_pkg, true) returning id into i_pouch100;
  insert into public.items (company_id, name, item_group_id, is_purchased) values (v_spice, 'Pouch 500 g', ig_pkg, true) returning id into i_pouch500;

  -- template + two variants (explicit codes for variants)
  insert into public.items (company_id, item_code, name, item_group_id, is_template)
  values (v_spice, 'GM', 'Garam masala', ig_fg, true) returning id into i_tmpl;
  insert into public.items (company_id, item_code, name, item_group_id, template_item_id, sales_uom_id)
  values (v_spice, 'GM-100G', 'Garam masala 100 g', ig_fg, i_tmpl, u_ctn) returning id into i_gm100;
  insert into public.items (company_id, item_code, name, item_group_id, template_item_id, sales_uom_id)
  values (v_spice, 'GM-500G', 'Garam masala 500 g', ig_fg, i_tmpl, u_ctn) returning id into i_gm500;
  insert into public.item_attribute_values (company_id, item_id, attribute_definition_id, option_id) values
    (v_spice, i_gm100, a_pack, o_100),
    (v_spice, i_gm500, a_pack, o_500);
  insert into public.item_attribute_values (company_id, item_id, attribute_definition_id, number_value) values
    (v_spice, i_gm100, a_shelf, 365),
    (v_spice, i_gm500, a_shelf, 365);

  -- level 2: 10 KG blend = 4 KG cumin + 4 KG coriander + 2000 G chilli
  insert into public.bom_headers (company_id, item_id, base_quantity, uom_id) values (v_spice, i_blend, 10, u_kg) returning id into b;
  insert into public.bom_lines (company_id, bom_id, line_no, component_item_id, quantity, uom_id) values
    (v_spice, b, 10, i_cumin,  4,    u_kg),
    (v_spice, b, 20, i_cori,   4,    u_kg),
    (v_spice, b, 30, i_chilli, 2000, u_g);

  -- level 1: 1 PKT = 100 G blend + 1 pouch  /  1 PKT = 500 G blend + 1 pouch
  insert into public.bom_headers (company_id, item_id, base_quantity, uom_id) values (v_spice, i_gm100, 1, u_pkt) returning id into b;
  insert into public.bom_lines (company_id, bom_id, line_no, component_item_id, quantity, uom_id) values
    (v_spice, b, 10, i_blend,    100, u_g),
    (v_spice, b, 20, i_pouch100, 1,   u_pkt);
  insert into public.bom_headers (company_id, item_id, base_quantity, uom_id) values (v_spice, i_gm500, 1, u_pkt) returning id into b;
  insert into public.bom_lines (company_id, bom_id, line_no, component_item_id, quantity, uom_id) values
    (v_spice, b, 10, i_blend,    500, u_g),
    (v_spice, b, 20, i_pouch500, 1,   u_pkt);
end $$;

select set_config('request.jwt.claim.sub', '', false);
