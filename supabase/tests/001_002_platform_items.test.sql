-- =============================================================================
-- Tests for migrations 001 + 002. Run after the dev seed. LOCAL/TEST ONLY.
-- Each block raises on failure; the script prints PASS lines as it goes.
-- =============================================================================
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create schema if not exists tests;

-- Runs p_sql as p_user (role authenticated) and returns the error SQLSTATE, or NULL on success.
create or replace function tests.try_as(p_user uuid, p_sql text) returns text
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_user::text, ''), true);
  execute 'set local role authenticated';
  begin
    execute p_sql;
  exception when others then
    execute 'reset role';
    return sqlstate || ': ' || sqlerrm;
  end;
  execute 'reset role';
  return null;
end $$;

-- Scalar query as p_user
create or replace function tests.val_as(p_user uuid, p_sql text) returns text
language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_user::text, ''), true);
  execute 'set local role authenticated';
  execute p_sql into v;
  execute 'reset role';
  return v;
end $$;

create or replace function tests.ok(p_cond boolean, p_name text) returns void
language plpgsql as $$
begin
  if p_cond is distinct from true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

-- Company id by code (security definer so it works while impersonating a user).
create or replace function tests.co(p_code text) returns uuid language sql security definer as
$$ select id from public.companies where code = p_code $$;
grant usage on schema tests to authenticated;
grant execute on function tests.co(text) to authenticated;

\set admin   '''00000000-0000-0000-0000-00000000000a'''
\set buyer   '''00000000-0000-0000-0000-00000000000b'''
\set planner '''00000000-0000-0000-0000-00000000000c'''
\set viewer  '''00000000-0000-0000-0000-00000000000d'''
\set usermgr '''00000000-0000-0000-0000-00000000000e'''

-- ------------------------------------------------------------------ RLS isolation
begin;
select tests.ok(tests.val_as(:buyer, 'select count(*) from public.companies') = '1',
  'buyer sees only MAPLE');
select tests.ok(tests.val_as(:buyer, $q$select count(*) from public.items where company_id = tests.co('SPICE')$q$) = '0',
  'buyer cannot read SPICE items');
select tests.ok(tests.val_as(:buyer, $q$select count(*) from public.items$q$) = '3',
  'buyer reads MAPLE items (ITEM_MASTER=READ)');
select tests.ok(tests.val_as(:viewer, 'select count(*) from public.companies') = '2',
  'viewer assigned to both companies sees both');
select tests.ok(tests.val_as(:viewer, 'select count(*) from public.items') = '12',
  'viewer reads items of both companies');
select tests.ok(tests.val_as(:buyer, 'select count(*) from public.number_ranges') = '0',
  'buyer without CONFIG cannot read number ranges');
select tests.ok(tests.val_as(:buyer, 'select count(*) from public.audit_log') = '0',
  'buyer without AUDIT cannot read audit log');
select tests.ok(tests.val_as(:admin, 'select count(*) > 0 from public.audit_log')::boolean,
  'superuser reads audit log');
select tests.ok(tests.val_as(null, 'select count(*) from public.items') = '0',
  'no JWT -> no rows');
rollback;

-- ------------------------------------------------------------------ write authorizations
begin;
select tests.ok(tests.try_as(:buyer, $q$
  insert into public.items (company_id, name, item_group_id)
  select company_id, 'x', id from public.item_groups where code = 'HW'$q$) like '42501%',
  'buyer (READ) cannot create items');

select tests.ok(tests.try_as(:planner, $q$
  insert into public.items (company_id, name, item_group_id)
  values (tests.co('SPICE'), 'Black pepper', (select id from public.item_groups where code='RAW'))$q$) is null,
  'planner (FULL) creates SPICE item');

select tests.ok((select item_code from public.items where name = 'Black pepper') = 'RAW004',
  'item code generated from group series per scope (RAW004)');

select tests.ok(tests.try_as(:planner, $q$
  insert into public.uoms (company_id, code, name) values (tests.co('MAPLE'), 'X', 'x')$q$) like '42501%',
  'planner cannot write into MAPLE');

select tests.ok(tests.try_as(:planner, $q$
  update public.items set name = 'hacked' where company_id = tests.co('MAPLE')$q$) is null
  and (select count(*) from public.items where name = 'hacked') = 0,
  'planner update on MAPLE rows affects nothing');
rollback;

-- ------------------------------------------------------------------ privilege escalation
begin;
select tests.ok(tests.try_as(:usermgr, $q$
  update public.user_company_roles set is_superuser = true
  where user_id = '00000000-0000-0000-0000-00000000000e'$q$) like '42501%',
  'user admin (USERS=FULL) cannot make himself superuser');

select tests.ok(tests.try_as(:planner, $q$
  update public.user_profiles set is_platform_admin = true
  where user_id = '00000000-0000-0000-0000-00000000000c'$q$) like '42501%',
  'user cannot set own is_platform_admin');

select tests.ok(tests.try_as(:planner, $q$
  update public.user_profiles set display_name = 'Planner P'
  where user_id = '00000000-0000-0000-0000-00000000000c'$q$) is null,
  'user can change own display name');

select tests.ok(tests.try_as(:planner, $q$
  select public.create_company('X','X','CAD','CA','UTC',1::smallint)$q$) like '42501%',
  'non platform admin cannot create a company');

select tests.ok(tests.try_as(:planner, $q$
  insert into public.audit_log (table_name, record_id, action) values ('x','x','I')$q$) like '42501%',
  'audit log is not writable by users');

select tests.ok(tests.try_as(:admin, $q$delete from public.audit_log$q$) like '42501%',
  'audit log is not deletable even by superuser');

select tests.ok(tests.try_as(:planner, $q$
  insert into public.currencies (code, name) values ('XXX','x')$q$) like '42501%',
  'reference tables are read-only');
rollback;

-- ------------------------------------------------------------------ numbering
begin;
select tests.ok(private.fiscal_year_label(4::smallint, date '2026-05-01') = '26-27', 'FY label Apr start, May date');
select tests.ok(private.fiscal_year_label(4::smallint, date '2027-03-31') = '26-27', 'FY label Apr start, Mar date');
select tests.ok(private.fiscal_year_label(1::smallint, date '2026-05-01') = '2026',  'FY label Jan start');

select tests.ok(private.next_number((select id from public.number_ranges where code='INV'), '', date '2026-05-01') = 'INV/26-27/00001', 'INV first number');
select tests.ok(private.next_number((select id from public.number_ranges where code='INV'), '', date '2027-03-31') = 'INV/26-27/00002', 'INV same FY continues');
select tests.ok(private.next_number((select id from public.number_ranges where code='INV'), '', date '2027-04-01') = 'INV/27-28/00001', 'INV resets in new FY');
select tests.ok(private.next_number((select id from public.number_ranges where code='SO' and company_id = tests.co('MAPLE')), '', date '2025-12-31') = 'SO-2025-00001', 'SO calendar year');
rollback;

-- gapless: a rolled-back number is reissued
begin;
select private.next_number((select id from public.number_ranges where code='PO' and company_id = tests.co('MAPLE')));
rollback;
begin;
select tests.ok(private.next_number((select id from public.number_ranges where code='PO' and company_id = tests.co('MAPLE'))) = 'PO000001',
  'rolled-back number is reused (gapless)');
rollback;

-- ------------------------------------------------------------------ audit
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
update public.items set name = 'Cumin seed (whole)' where item_code = 'RAW001';
select tests.ok((select changed_columns = array['name'] and changed_by = '00000000-0000-0000-0000-00000000000c'
                        and old_row->>'name' = 'Cumin seed' and new_row->>'name' = 'Cumin seed (whole)'
                 from public.audit_log where table_name = 'items' order by id desc limit 1),
  'audit captures changed column, old/new values and user');
select tests.ok((select updated_by = '00000000-0000-0000-0000-00000000000c' from public.items where item_code='RAW001'),
  'stamps record updating user');
update public.items set updated_at = now() where item_code = 'RAW001';
select tests.ok((select count(*) from public.audit_log where table_name='items' and action='U'
                  and record_id = (select id::text from public.items where item_code='RAW001')) = 1,
  'stamp-only update is not audited');
rollback;

-- ------------------------------------------------------------------ master data rules
begin;
select tests.ok(tests.try_as(:admin, $q$
  insert into public.exchange_rates (company_id, currency_code, rate_date, rate)
  values (tests.co('SPICE'), 'INR', current_date, 1)$q$) like '23514%',
  'no exchange rate for base currency');

select tests.ok(private.exchange_rate(tests.co('SPICE'), 'INR', current_date) = 1, 'base currency rate = 1');
select tests.ok(private.exchange_rate(tests.co('SPICE'), 'USD', date '2026-10-15') = 83.9, 'rate for exact date');
select tests.ok(private.exchange_rate(tests.co('SPICE'), 'USD', date '2026-10-16') is null, 'missing rate -> NULL');

select tests.ok(tests.try_as(:planner, $q$
  insert into public.items (company_id, name, item_group_id, sales_uom_id)
  values (tests.co('SPICE'), 'Bad', (select id from public.item_groups where code='RAW'),
          (select id from public.uoms where code='PKT'))$q$) like '23514%',
  'sales UoM outside the item''s UoM group is rejected');

select tests.ok(tests.try_as(:planner, $q$
  insert into public.items (company_id, name, item_group_id, item_type, replenishment_policy)
  values (tests.co('SPICE'), 'Lab test', (select id from public.item_groups where code='RAW'), 'SERVICE', 'BUFFER')$q$) like '23514%',
  'service item cannot be buffered');

select tests.ok(tests.try_as(:planner, $q$
  update public.uom_group_conversions set base_qty = 2
  where alt_uom_id = (select id from public.uoms where code='KG')$q$) like '23514%',
  'base UoM line must stay 1:1');

select tests.ok(tests.try_as(:planner, $q$
  insert into public.uoms (company_id, code, name) values (tests.co('SPICE'), 'kg', 'lower')$q$) like '23514%',
  'codes must be upper case');

select tests.ok(tests.try_as(:admin, $q$
  delete from public.uoms where code = 'KG'$q$) like '23503%',
  'UoM in use cannot be deleted (RESTRICT)');
rollback;

-- ------------------------------------------------------------------ variants
begin;
select tests.ok(tests.try_as(:planner, $q$
  with v as (
    insert into public.items (company_id, item_code, name, item_group_id, template_item_id)
    values (tests.co('SPICE'), 'GM-100G-B', 'Duplicate', (select id from public.item_groups where code='FG'),
            (select id from public.items where item_code='GM'))
    returning id, company_id)
  insert into public.item_attribute_values (company_id, item_id, attribute_definition_id, option_id)
  select v.company_id, v.id, d.id, o.id from v
  join public.attribute_definitions d on d.code='PACK_SIZE'
  join public.attribute_options o on o.attribute_definition_id = d.id and o.code='100G';
  set constraints all immediate$q$) like '23505%',
  'duplicate variant combination rejected');
rollback;

begin;
select tests.ok(tests.try_as(:planner, $q$
  insert into public.item_attribute_values (company_id, item_id, attribute_definition_id, text_value)
  values (tests.co('SPICE'), (select id from public.items where item_code='RAW001'),
          (select id from public.attribute_definitions where code='SHELF_LIFE_DAYS'), 'one year')$q$) like '23514%',
  'attribute value must match data type');

select tests.ok(tests.try_as(:planner, $q$
  update public.items set is_template = false where item_code = 'GM'$q$) like '23514%',
  'template with variants cannot be un-templated');

select tests.ok(tests.try_as(:planner, $q$
  insert into public.bom_headers (company_id, item_id, uom_id)
  values (tests.co('SPICE'), (select id from public.items where item_code='GM'),
          (select id from public.uoms where code='PKT'))$q$) like '23514%',
  'template item cannot have a BOM');
rollback;

-- ------------------------------------------------------------------ BOM
begin;
select tests.ok(tests.try_as(:planner, $q$
  with h as (
    insert into public.bom_headers (company_id, item_id, uom_id)
    values (tests.co('SPICE'), (select id from public.items where item_code='RAW001'),
            (select id from public.uoms where code='KG'))
    returning id, company_id)
  insert into public.bom_lines (company_id, bom_id, line_no, component_item_id, quantity, uom_id)
  select h.company_id, h.id, 10, (select id from public.items where item_code='GM-100G'), 1,
         (select id from public.uoms where code='PKT') from h$q$) like '23514%',
  'indirect BOM cycle (RAW001 -> GM-100G -> INT001 -> RAW001) rejected');

select tests.ok(tests.try_as(:planner, $q$
  insert into public.bom_lines (company_id, bom_id, line_no, component_item_id, quantity, uom_id)
  select h.company_id, h.id, 40, (select id from public.items where item_code='RAW001'), 1,
         (select id from public.uoms where code='PKT')
  from public.bom_headers h join public.items i on i.id = h.item_id where i.item_code='INT001'$q$) like '23514%',
  'BOM line UoM must fit the component');

select tests.ok(tests.try_as(:planner, $q$
  insert into public.bom_headers (company_id, item_id, uom_id)
  values (tests.co('SPICE'), (select id from public.items where item_code='INT001'),
          (select id from public.uoms where code='KG'))$q$) like '23505%',
  'only one active BOM per item');

select tests.ok(tests.val_as(:planner, $q$
  select qty_per_parent from public.bom_explosion((select id from public.items where item_code='GM-500G'))
  where item_code = 'RAW003'$q$)::numeric = 0.1,
  'explosion: 1 PKT of 500 g needs 0.1 KG chilli (G->KG and 2 levels)');

select tests.ok(tests.val_as(:buyer, $q$
  select count(*) from public.bom_explosion((select id from public.items where item_code='GM-500G'))$q$) = '0',
  'explosion respects RLS (buyer sees nothing of SPICE)');
rollback;

\echo 'ALL TESTS PASSED'
