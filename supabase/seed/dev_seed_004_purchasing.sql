-- DEV/TEST SEED ONLY — business partners and purchasing (pairs with migration 004)
-- SPICE buys spices in INR from a local trader and pouches in USD from an importer.
-- Roles: PLANNER gets PURCHASING FULL but no prices; new BUYER role in SPICE (user usermgr) gets prices.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);

do $$
declare
  v_spice uuid := (select id from public.companies where code = 'SPICE');
  v_maple uuid := (select id from public.companies where code = 'MAPLE');
  b_trader uuid; b_pack uuid; b_cust uuid;
  nr uuid;
begin
  insert into public.business_partners (company_id, code, name, bp_type, currency_code, default_lead_time_days, payment_terms)
  values (v_spice, 'S-TRADER', 'Khari Baoli Spice Traders', 'SUPPLIER', null, 7, '30 days') returning id into b_trader;
  insert into public.business_partners (company_id, code, name, bp_type, currency_code, default_lead_time_days)
  values (v_spice, 'S-PACK', 'FlexiPack Imports', 'SUPPLIER', 'USD', 30) returning id into b_pack;
  insert into public.business_partners (company_id, code, name, bp_type)
  values (v_spice, 'C-RETAIL', 'Retail customer', 'CUSTOMER') returning id into b_cust;
  insert into public.business_partners (company_id, code, name, bp_type)
  values (v_maple, 'S-BOLT', 'Bolt Supply Inc', 'SUPPLIER');

  insert into public.bp_registrations (company_id, business_partner_id, registration_type, registration_number)
  values (v_spice, b_trader, 'GSTIN', '07AAACK1234A1Z5');
  insert into public.bp_addresses (company_id, business_partner_id, address_type, label, line1, city, country_code, is_default)
  values (v_spice, b_trader, 'BILL_TO', 'Head office', 'Khari Baoli', 'Delhi', 'IN', true);
  insert into public.bp_contacts (company_id, business_partner_id, name, role, phone, is_primary)
  values (v_spice, b_trader, 'R. Kumar', 'Sales', '+91 98100 00000', true);

  insert into public.item_suppliers (company_id, item_id, business_partner_id, supplier_item_code, lead_time_days, is_preferred)
  select v_spice, i.id, b_trader, 'KB-' || i.item_code, 5, true
  from public.items i where i.company_id = v_spice and i.item_code in ('RAW001', 'RAW002', 'RAW003');
  insert into public.item_suppliers (company_id, item_id, business_partner_id, supplier_item_code, purchase_uom_id, lead_time_days, is_preferred)
  select v_spice, i.id, b_pack, 'FP-' || i.item_code, (select id from public.uoms where company_id = v_spice and code = 'CTN'), 25, true
  from public.items i where i.company_id = v_spice and i.item_code in ('PKG001', 'PKG002');

  -- series + document types
  insert into public.number_ranges (company_id, code, name, pattern, reset_policy)
  values (v_spice, 'PO', 'Purchase orders', 'PO/{FY}/{N:4}', 'FISCAL_YEAR') returning id into nr;
  insert into public.document_types (company_id, code, name, category, default_number_range_id)
  values (v_spice, 'PO', 'Purchase order', 'PURCHASE_ORDER', nr);
  insert into public.number_ranges (company_id, code, name, pattern, reset_policy)
  values (v_spice, 'GRPO', 'Goods receipts PO', 'GRN/{FY}/{N:4}', 'FISCAL_YEAR') returning id into nr;
  insert into public.document_types (company_id, code, name, category, default_number_range_id)
  values (v_spice, 'GRPO', 'Goods receipt PO', 'GOODS_RECEIPT_PO', nr);

  insert into public.reason_codes (company_id, reason_type, code, name)
  values (v_spice, 'PO_CLOSE', 'SUPPLIER_SHORT', 'Supplier cannot supply the rest');

  -- authorizations
  insert into public.role_permissions (company_id, role_id, auth_object, level)
  select company_id, id, x.obj, x.lvl from public.roles r,
         (values ('PURCHASING', 'FULL'), ('BUSINESS_PARTNERS', 'READ')) as x(obj, lvl)
  where r.code = 'PLANNER';
  insert into public.role_permissions (company_id, role_id, auth_object, level)
  select company_id, id, x.obj, 'FULL' from public.roles r,
         (values ('PURCHASING'), ('PURCHASE_PRICES'), ('BUSINESS_PARTNERS')) as x(obj)
  where r.code = 'USERADMIN';
end $$;

select set_config('request.jwt.claim.sub', '', false);
