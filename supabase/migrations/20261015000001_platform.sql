-- =============================================================================
-- Migration 001 — Platform
-- Companies, users, authorizations, RLS helpers, configuration tables,
-- numbering series, audit trail.
--
-- SAP Business One mapping (see DECISIONS.md):
--   companies              ~ company database (OADM)
--   roles/role_permissions ~ authorization groups / General Authorizations
--   document_categories    ~ B1 object types (17 = Sales Order, 22 = PO, ...)
--   document_types         ~ numbering-series names per object type
--   number_ranges          ~ numbering series (NNM1)
--   status_definitions     ~ user-defined statuses mapped to system status
--   audit_log              ~ change log
-- Deviation: one database for all companies, isolated by company_id + RLS.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Private schema for helper functions (not exposed through the API)
-- -----------------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

comment on schema private is
  'Helper functions used by RLS policies and triggers. Not exposed through PostgREST.';

-- -----------------------------------------------------------------------------
-- 1. Generic trigger functions: row stamps and audit
-- -----------------------------------------------------------------------------

-- Fills created_* on insert and updated_* on every write.
-- created_* can never be changed after insert.
create or replace function private.set_row_stamps()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.created_by := (select auth.uid());
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
  end if;
  new.updated_at := now();
  new.updated_by := (select auth.uid());
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Global reference tables (fixed behaviour layer; changed by migration only)
-- -----------------------------------------------------------------------------

create table public.currencies (
  code         char(3)     not null,
  name         text        not null,
  minor_units  smallint    not null default 2,
  is_active    boolean     not null default true,
  constraint currencies_pk primary key (code),
  constraint currencies_code_format_ck check (code ~ '^[A-Z]{3}$'),
  constraint currencies_minor_units_ck check (minor_units between 0 and 4)
);
comment on table public.currencies is 'ISO 4217 currencies. Global reference data.';

create table public.document_categories (
  code             text     not null,
  name             text     not null,
  b1_object_type   integer,
  sort_order       smallint not null default 0,
  constraint document_categories_pk primary key (code)
);
comment on table public.document_categories is
  'Fixed document behaviour classes (= SAP B1 object types). Application logic keys off these codes; '
  'companies configure their own document_types on top. Changed only by migration.';

create table public.system_statuses (
  code        text     not null,
  name        text     not null,
  is_final    boolean  not null default false,
  sort_order  smallint not null default 0,
  constraint system_statuses_pk primary key (code)
);
comment on table public.system_statuses is
  'Fixed lifecycle statuses that logic filters on. User statuses map onto these.';

create table public.reason_types (
  code  text not null,
  name  text not null,
  constraint reason_types_pk primary key (code)
);
comment on table public.reason_types is
  'Fixed groups of reason codes (e.g. BUFFER_RED). Companies define the reasons inside each group.';

create table public.auth_objects (
  code         text     not null,
  name         text     not null,
  description  text,
  sort_order   smallint not null default 0,
  constraint auth_objects_pk primary key (code)
);
comment on table public.auth_objects is
  'Authorization objects (= B1 General Authorizations tree). Each later migration adds its own.';

-- -----------------------------------------------------------------------------
-- 3. Companies
-- -----------------------------------------------------------------------------

create table public.companies (
  id                       uuid        not null default gen_random_uuid(),
  code                     text        not null,
  name                     text        not null,
  legal_name               text,
  base_currency            char(3)     not null,
  country_code             char(2)     not null,
  timezone                 text        not null default 'UTC',
  fiscal_year_start_month  smallint    not null default 1,
  address_line1            text,
  address_line2            text,
  city                     text,
  region                   text,
  postal_code              text,
  phone                    text,
  email                    text,
  logo_storage_path        text,
  document_footer          text,
  is_active                boolean     not null default true,
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  constraint companies_pk primary key (id),
  constraint companies_code_uk unique (code),
  constraint companies_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint companies_country_format_ck check (country_code ~ '^[A-Z]{2}$'),
  constraint companies_fy_month_ck check (fiscal_year_start_month between 1 and 12),
  constraint companies_base_currency_fk foreign key (base_currency) references public.currencies (code)
);
comment on table public.companies is
  'One row per legal entity (= B1 company database / SAP company code). '
  'Created only through public.create_company().';
comment on column public.companies.fiscal_year_start_month is
  'Used to label fiscal years for number-range resets (e.g. 4 -> "26-27"). No posting periods: this is not a GL.';

-- Reject unknown time zones (AT TIME ZONE raises on an invalid name).
create or replace function private.validate_company()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform now() at time zone new.timezone;
  return new;
end;
$$;

create trigger companies_validate
  before insert or update of timezone on public.companies
  for each row execute function private.validate_company();

create table public.company_registrations (
  id                   uuid        not null default gen_random_uuid(),
  company_id           uuid        not null,
  registration_type    text        not null,
  registration_number  text        not null,
  print_on_documents   boolean     not null default true,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  updated_by           uuid,
  constraint company_registrations_pk primary key (id),
  constraint company_registrations_type_uk unique (company_id, registration_type),
  constraint company_registrations_company_fk foreign key (company_id)
    references public.companies (id) on delete cascade
);
comment on table public.company_registrations is
  'Tax and trade registration numbers as data (GSTIN, BN, IEC, VAT...) instead of country-specific columns.';

create table public.company_settings (
  company_id            uuid        not null,
  yellow_from_pct       smallint    not null default 34,
  red_from_pct          smallint    not null default 67,
  allow_negative_stock  boolean     not null default false,
  created_at            timestamptz not null default now(),
  created_by            uuid,
  updated_at            timestamptz not null default now(),
  updated_by            uuid,
  constraint company_settings_pk primary key (company_id),
  constraint company_settings_company_fk foreign key (company_id)
    references public.companies (id) on delete cascade,
  constraint company_settings_zones_ck check (0 < yellow_from_pct and yellow_from_pct < red_from_pct and red_from_pct <= 100)
);
comment on table public.company_settings is 'One row per company; created automatically with the company.';
comment on column public.company_settings.yellow_from_pct is
  'Buffer penetration % at which a buffer turns yellow (zone applies from this value upward). Black is > 100%.';
comment on column public.company_settings.red_from_pct is
  'Buffer penetration % at which a buffer turns red.';
comment on column public.company_settings.allow_negative_stock is
  'B1 "block negative inventory" inverted. False = postings below zero are rejected unless overridden with a reason.';

create or replace function private.create_company_settings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.company_settings (company_id) values (new.id);
  return new;
end;
$$;

create trigger companies_create_settings
  after insert on public.companies
  for each row execute function private.create_company_settings();

-- Company-local exchange rates (B1 model): 1 unit of currency_code = rate units of the company base currency.
create table public.exchange_rates (
  id             uuid           not null default gen_random_uuid(),
  company_id     uuid           not null,
  currency_code  char(3)        not null,
  rate_date      date           not null,
  rate           numeric(20,10) not null,
  created_at     timestamptz    not null default now(),
  created_by     uuid,
  updated_at     timestamptz    not null default now(),
  updated_by     uuid,
  constraint exchange_rates_pk primary key (id),
  constraint exchange_rates_uk unique (company_id, currency_code, rate_date),
  constraint exchange_rates_rate_ck check (rate > 0),
  constraint exchange_rates_company_fk foreign key (company_id)
    references public.companies (id) on delete cascade,
  constraint exchange_rates_currency_fk foreign key (currency_code)
    references public.currencies (code)
);
comment on table public.exchange_rates is
  'Direct quotation per company, as in B1: 1 currency_code = rate x company base currency. Entered manually.';

create or replace function private.validate_exchange_rate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from public.companies c
             where c.id = new.company_id and c.base_currency = new.currency_code) then
    raise exception 'Exchange rate for % is not needed: it is the company base currency', new.currency_code
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger exchange_rates_validate
  before insert or update on public.exchange_rates
  for each row execute function private.validate_exchange_rate();

-- Rate to convert p_currency into the company base currency on p_date.
-- Returns 1 for the base currency and NULL when no rate exists for that exact date
-- (B1 refuses to add a foreign-currency document without a rate for its date).
create or replace function private.exchange_rate(p_company_id uuid, p_currency char(3), p_date date)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when c.base_currency = p_currency then 1::numeric
    else (select r.rate from public.exchange_rates r
          where r.company_id = p_company_id and r.currency_code = p_currency and r.rate_date = p_date)
  end
  from public.companies c
  where c.id = p_company_id
$$;

-- -----------------------------------------------------------------------------
-- 4. Users and authorizations
-- -----------------------------------------------------------------------------

create table public.user_profiles (
  user_id             uuid        not null,
  display_name        text,
  default_company_id  uuid,
  is_platform_admin   boolean     not null default false,
  is_active           boolean     not null default true,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  constraint user_profiles_pk primary key (user_id),
  constraint user_profiles_user_fk foreign key (user_id) references auth.users (id) on delete cascade,
  constraint user_profiles_default_company_fk foreign key (default_company_id)
    references public.companies (id) on delete set null
);
comment on table public.user_profiles is 'Application profile for each Supabase Auth user. Created automatically on sign-up.';
comment on column public.user_profiles.is_platform_admin is
  'May create new companies. Cannot be changed by users through the API; set via SQL by the owner.';

create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.user_profiles (user_id, display_name)
  values (new.id, split_part(coalesce(new.email, ''), '@', 1))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_auth_user();

create table public.roles (
  id          uuid        not null default gen_random_uuid(),
  company_id  uuid        not null,
  code        text        not null,
  name        text        not null,
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint roles_pk primary key (id),
  constraint roles_company_id_uk unique (company_id, id),
  constraint roles_code_uk unique (company_id, code),
  constraint roles_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint roles_company_fk foreign key (company_id) references public.companies (id) on delete cascade
);
comment on table public.roles is 'Authorization groups per company (= B1 authorization templates).';

create table public.role_permissions (
  id           uuid        not null default gen_random_uuid(),
  company_id   uuid        not null,
  role_id      uuid        not null,
  auth_object  text        not null,
  level        text        not null,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint role_permissions_pk primary key (id),
  constraint role_permissions_uk unique (role_id, auth_object),
  constraint role_permissions_level_ck check (level in ('FULL', 'READ', 'NONE')),
  constraint role_permissions_role_fk foreign key (company_id, role_id)
    references public.roles (company_id, id) on delete cascade,
  constraint role_permissions_object_fk foreign key (auth_object) references public.auth_objects (code)
);
comment on table public.role_permissions is 'B1 General Authorizations: Full / Read-only / No Authorization per object.';

create table public.user_company_roles (
  id            uuid        not null default gen_random_uuid(),
  company_id    uuid        not null,
  user_id       uuid        not null,
  role_id       uuid,
  is_superuser  boolean     not null default false,
  is_active     boolean     not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  constraint user_company_roles_pk primary key (id),
  constraint user_company_roles_uk unique (company_id, user_id),
  constraint user_company_roles_role_or_super_ck check (role_id is not null or is_superuser),
  constraint user_company_roles_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint user_company_roles_user_fk foreign key (user_id) references public.user_profiles (user_id) on delete cascade,
  constraint user_company_roles_role_fk foreign key (company_id, role_id) references public.roles (company_id, id)
);
comment on table public.user_company_roles is
  'Assigns a user to a company with one role. is_superuser = full authorization in that company (B1 superuser).';

-- Only an existing superuser of the company (or a platform admin, or the service role)
-- may grant superuser. Prevents a user with USERS=FULL escalating to superuser.
create or replace function private.guard_superuser_grant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    return new;  -- migrations / service role
  end if;
  if new.is_superuser and (tg_op = 'INSERT' or not old.is_superuser) then
    if not exists (select 1 from public.user_company_roles u
                   where u.user_id = v_uid and u.company_id = new.company_id
                     and u.is_superuser and u.is_active)
       and not exists (select 1 from public.user_profiles p
                       where p.user_id = v_uid and p.is_platform_admin and p.is_active) then
      raise exception 'Only a superuser of this company can grant superuser rights'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

create trigger user_company_roles_guard_superuser
  before insert or update on public.user_company_roles
  for each row execute function private.guard_superuser_grant();

-- -----------------------------------------------------------------------------
-- 5. RLS helper functions
-- -----------------------------------------------------------------------------

-- Companies the current user is assigned to (any role).
create or replace function private.user_company_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.company_id
  from public.user_company_roles u
  join public.user_profiles p on p.user_id = u.user_id
  where u.user_id = (select auth.uid())
    and u.is_active
    and p.is_active
$$;

-- Companies where the current user has at least p_min_level ('READ' or 'FULL')
-- on authorization object p_object. Superusers have FULL on everything.
-- Used in policies as: company_id in (select private.companies_with_access('ITEMS','READ'))
-- The (select ...) wrapper lets Postgres evaluate it once per statement.
create or replace function private.companies_with_access(p_object text, p_min_level text)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.company_id
  from public.user_company_roles u
  join public.user_profiles p on p.user_id = u.user_id
  where u.user_id = (select auth.uid())
    and u.is_active
    and p.is_active
    and (
      u.is_superuser
      or exists (
        select 1
        from public.role_permissions rp
        join public.roles r on r.id = rp.role_id and r.is_active
        where rp.role_id = u.role_id
          and rp.auth_object = p_object
          and (rp.level = 'FULL' or (p_min_level = 'READ' and rp.level = 'READ'))
      )
    )
$$;

revoke all on function private.user_company_ids() from public;
revoke all on function private.companies_with_access(text, text) from public;
grant execute on function private.user_company_ids() to authenticated, service_role;
grant execute on function private.companies_with_access(text, text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6. Audit trail
-- -----------------------------------------------------------------------------

create table public.audit_log (
  id               bigint      generated always as identity,
  company_id       uuid,
  table_name       text        not null,
  record_id        text        not null,
  action           char(1)     not null,
  changed_columns  text[],
  old_row          jsonb,
  new_row          jsonb,
  changed_by       uuid,
  changed_at       timestamptz not null default now(),
  txid             bigint      not null default txid_current(),
  constraint audit_log_pk primary key (id),
  constraint audit_log_action_ck check (action in ('I', 'U', 'D'))
);
create index audit_log_record_ix on public.audit_log (company_id, table_name, record_id);
create index audit_log_changed_at_ix on public.audit_log (company_id, changed_at desc);
comment on table public.audit_log is
  'Append-only change log for every audited table. Written only by private.audit_row(). No update/delete grants.';

create or replace function private.audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_changed text[];
begin
  if tg_op = 'UPDATE' then
    select array_agg(k order by k) into v_changed
    from jsonb_object_keys(v_new) k
    where k not in ('updated_at', 'updated_by')
      and v_new -> k is distinct from v_old -> k;
    if v_changed is null then
      return null;  -- nothing but stamps changed
    end if;
  end if;

  insert into public.audit_log
    (company_id, table_name, record_id, action, changed_columns, old_row, new_row, changed_by)
  values (
    case when tg_table_name = 'companies' then (v_row ->> 'id')::uuid
         else (v_row ->> 'company_id')::uuid end,
    tg_table_name,
    coalesce(v_row ->> 'id', v_row ->> 'user_id', v_row ->> 'company_id'),
    left(tg_op, 1),
    v_changed,
    v_old,
    v_new,
    (select auth.uid())
  );
  return null;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Table setup helpers (used by this and later migrations)
-- -----------------------------------------------------------------------------

-- Adds the stamp trigger and the audit trigger to a table.
create or replace function private.attach_standard_triggers(p_table regclass, p_with_stamps boolean default true)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_name text := (select relname from pg_class where oid = p_table);
begin
  if p_with_stamps then
    execute format('create trigger %I before insert or update on %s for each row execute function private.set_row_stamps()',
                   v_name || '_stamps', p_table);
  end if;
  execute format('create trigger %I after insert or update or delete on %s for each row execute function private.audit_row()',
                 v_name || '_audit', p_table);
end;
$$;

-- Standard company-scoped RLS: read needs READ on p_auth_object, writes need FULL.
-- Generates four policies named rls_select / rls_insert / rls_update / rls_delete.
create or replace function private.enable_company_rls(p_table regclass, p_auth_object text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.auth_objects where code = p_auth_object) then
    raise exception 'Unknown authorization object %', p_auth_object;
  end if;
  execute format('alter table %s enable row level security', p_table);
  execute format('revoke all on %s from anon', p_table);
  execute format($p$create policy rls_select on %s for select to authenticated
                    using (company_id in (select private.companies_with_access(%L, 'READ')))$p$, p_table, p_auth_object);
  execute format($p$create policy rls_insert on %s for insert to authenticated
                    with check (company_id in (select private.companies_with_access(%L, 'FULL')))$p$, p_table, p_auth_object);
  execute format($p$create policy rls_update on %s for update to authenticated
                    using (company_id in (select private.companies_with_access(%L, 'FULL')))
                    with check (company_id in (select private.companies_with_access(%L, 'FULL')))$p$,
                 p_table, p_auth_object, p_auth_object);
  execute format($p$create policy rls_delete on %s for delete to authenticated
                    using (company_id in (select private.companies_with_access(%L, 'FULL')))$p$, p_table, p_auth_object);
end;
$$;

-- Global reference table: everyone signed in can read, nobody can write through the API.
create or replace function private.enable_reference_rls(p_table regclass)
returns void
language plpgsql
set search_path = ''
as $$
begin
  execute format('alter table %s enable row level security', p_table);
  execute format('revoke all on %s from anon', p_table);
  execute format('revoke insert, update, delete, truncate on %s from authenticated', p_table);
  execute format('create policy rls_select on %s for select to authenticated using (true)', p_table);
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Configuration tables
-- -----------------------------------------------------------------------------

create table public.number_ranges (
  id             uuid        not null default gen_random_uuid(),
  company_id     uuid        not null,
  code           text        not null,
  name           text        not null,
  pattern        text        not null,
  reset_policy   text        not null default 'NONE',
  start_number   bigint      not null default 1,
  is_active      boolean     not null default true,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  constraint number_ranges_pk primary key (id),
  constraint number_ranges_company_id_uk unique (company_id, id),
  constraint number_ranges_code_uk unique (company_id, code),
  constraint number_ranges_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint number_ranges_reset_ck check (reset_policy in ('NONE', 'FISCAL_YEAR', 'CALENDAR_YEAR')),
  constraint number_ranges_start_ck check (start_number >= 0),
  -- exactly one {N} or {N:width} token
  constraint number_ranges_pattern_ck check (
    array_length(regexp_split_to_array(pattern, '\{N(:[1-9])?\}'), 1) = 2
  ),
  constraint number_ranges_company_fk foreign key (company_id) references public.companies (id) on delete cascade
);
comment on table public.number_ranges is
  'Numbering series (= B1 NNM1). Pattern tokens: {N} or {N:width} (counter, required once), '
  '{FY} fiscal-year label, {YYYY} calendar year, {SCOPE} scope key. Example: ''INV/{FY}/{N:5}''.';

create table public.number_range_counters (
  id               uuid   not null default gen_random_uuid(),
  company_id       uuid   not null,
  number_range_id  uuid   not null,
  scope_key        text   not null default '',
  period_key       text   not null default '',
  next_number      bigint not null,
  constraint number_range_counters_pk primary key (id),
  constraint number_range_counters_uk unique (number_range_id, scope_key, period_key),
  constraint number_range_counters_range_fk foreign key (company_id, number_range_id)
    references public.number_ranges (company_id, id) on delete cascade
);
comment on table public.number_range_counters is
  'Next number per series, per scope key (e.g. per item group) and per period (fiscal or calendar year). '
  'Written only by private.next_number().';

-- Fiscal-year label: start month 1 -> '2026'; start month 4, date 2026-05-01 -> '26-27'.
create or replace function private.fiscal_year_label(p_start_month smallint, p_date date)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_start_month = 1 then to_char(p_date, 'YYYY')
    else lpad((s.y % 100)::text, 2, '0') || '-' || lpad(((s.y + 1) % 100)::text, 2, '0')
  end
  from (select case when extract(month from p_date) >= p_start_month
                    then extract(year from p_date)::int
                    else extract(year from p_date)::int - 1 end as y) s
$$;

-- Issues the next number of a series. Gapless: the counter row is locked FOR UPDATE
-- until the calling transaction ends, and a rollback restores it, so no number is
-- consumed by a failed document. Concurrent callers on the same counter queue.
create or replace function private.next_number(p_number_range_id uuid, p_scope_key text default '', p_date date default current_date)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  r          public.number_ranges%rowtype;
  v_fy_start smallint;
  v_period   text;
  v_n        bigint;
  v_width    int;
  v_text     text;
begin
  select nr.* into r from public.number_ranges nr where nr.id = p_number_range_id;
  if not found then
    raise exception 'Number range % not found', p_number_range_id;
  end if;
  if not r.is_active then
    raise exception 'Number range % is inactive', r.code;
  end if;

  select c.fiscal_year_start_month into v_fy_start from public.companies c where c.id = r.company_id;

  v_period := case r.reset_policy
                when 'FISCAL_YEAR'   then private.fiscal_year_label(v_fy_start, p_date)
                when 'CALENDAR_YEAR' then to_char(p_date, 'YYYY')
                else '' end;

  insert into public.number_range_counters (company_id, number_range_id, scope_key, period_key, next_number)
  values (r.company_id, r.id, coalesce(p_scope_key, ''), v_period, r.start_number)
  on conflict (number_range_id, scope_key, period_key) do nothing;

  select c.next_number into v_n
  from public.number_range_counters c
  where c.number_range_id = r.id and c.scope_key = coalesce(p_scope_key, '') and c.period_key = v_period
  for update;

  update public.number_range_counters c
  set next_number = v_n + 1
  where c.number_range_id = r.id and c.scope_key = coalesce(p_scope_key, '') and c.period_key = v_period;

  v_width := coalesce((substring(r.pattern from '\{N:([1-9])\}'))::int, 0);
  v_text  := r.pattern;
  v_text  := replace(v_text, '{FY}',    private.fiscal_year_label(v_fy_start, p_date));
  v_text  := replace(v_text, '{YYYY}',  to_char(p_date, 'YYYY'));
  v_text  := replace(v_text, '{SCOPE}', coalesce(p_scope_key, ''));
  v_text  := regexp_replace(v_text, '\{N(:[1-9])?\}', lpad(v_n::text, greatest(v_width, length(v_n::text)), '0'));
  return v_text;
end;
$$;

revoke all on function private.next_number(uuid, text, date) from public;
grant execute on function private.next_number(uuid, text, date) to service_role;

create table public.document_types (
  id                       uuid        not null default gen_random_uuid(),
  company_id               uuid        not null,
  code                     text        not null,
  name                     text        not null,
  category                 text        not null,
  default_number_range_id  uuid,
  is_active                boolean     not null default true,
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  constraint document_types_pk primary key (id),
  constraint document_types_company_id_uk unique (company_id, id),
  constraint document_types_code_uk unique (company_id, code),
  constraint document_types_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint document_types_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint document_types_category_fk foreign key (category) references public.document_categories (code),
  constraint document_types_range_fk foreign key (company_id, default_number_range_id)
    references public.number_ranges (company_id, id)
);
comment on table public.document_types is
  'Company-defined document types (e.g. "Export order", "Domestic order"), each mapped to a fixed category '
  'that decides its behaviour, and to a default numbering series.';

create table public.status_definitions (
  id             uuid        not null default gen_random_uuid(),
  company_id     uuid        not null,
  category       text        not null,
  code           text        not null,
  name           text        not null,
  system_status  text        not null,
  sort_order     smallint    not null default 0,
  is_default     boolean     not null default false,
  is_active      boolean     not null default true,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  constraint status_definitions_pk primary key (id),
  constraint status_definitions_company_id_uk unique (company_id, id),
  constraint status_definitions_code_uk unique (company_id, category, code),
  constraint status_definitions_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint status_definitions_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint status_definitions_category_fk foreign key (category) references public.document_categories (code),
  constraint status_definitions_system_status_fk foreign key (system_status) references public.system_statuses (code)
);
create unique index status_definitions_one_default_ux
  on public.status_definitions (company_id, category) where is_default;
comment on table public.status_definitions is
  'User statuses per document category (e.g. "Awaiting LC"), each mapped to a fixed system status that logic reads.';

create table public.reason_codes (
  id           uuid        not null default gen_random_uuid(),
  company_id   uuid        not null,
  reason_type  text        not null,
  code         text        not null,
  name         text        not null,
  is_active    boolean     not null default true,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint reason_codes_pk primary key (id),
  constraint reason_codes_company_id_uk unique (company_id, id),
  constraint reason_codes_code_uk unique (company_id, reason_type, code),
  constraint reason_codes_code_format_ck check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint reason_codes_company_fk foreign key (company_id) references public.companies (id) on delete cascade,
  constraint reason_codes_type_fk foreign key (reason_type) references public.reason_types (code)
);
comment on table public.reason_codes is
  'Company-defined reasons inside each fixed reason type (e.g. BUFFER_RED -> "Supplier late").';

-- -----------------------------------------------------------------------------
-- 9. Company creation (the only way to insert into companies)
-- -----------------------------------------------------------------------------

create or replace function public.create_company(
  p_code                     text,
  p_name                     text,
  p_base_currency            char(3),
  p_country_code             char(2),
  p_timezone                 text,
  p_fiscal_year_start_month  smallint default 1
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_id  uuid;
begin
  if not exists (select 1 from public.user_profiles p
                 where p.user_id = v_uid and p.is_platform_admin and p.is_active) then
    raise exception 'Only a platform admin can create companies' using errcode = '42501';
  end if;

  insert into public.companies (code, name, base_currency, country_code, timezone, fiscal_year_start_month)
  values (p_code, p_name, p_base_currency, p_country_code, p_timezone, p_fiscal_year_start_month)
  returning id into v_id;

  insert into public.user_company_roles (company_id, user_id, is_superuser)
  values (v_id, v_uid, true);

  return v_id;
end;
$$;
comment on function public.create_company is
  'Creates a company with default settings and makes the caller its superuser. Platform admins only.';

revoke all on function public.create_company(text, text, char, char, text, smallint) from public, anon;
grant execute on function public.create_company(text, text, char, char, text, smallint) to authenticated;

-- -----------------------------------------------------------------------------
-- 10. Reference data (part of the schema, applied in every environment)
-- -----------------------------------------------------------------------------

insert into public.currencies (code, name, minor_units) values
  ('AED', 'UAE Dirham', 2), ('AUD', 'Australian Dollar', 2), ('BDT', 'Bangladeshi Taka', 2),
  ('CAD', 'Canadian Dollar', 2), ('CHF', 'Swiss Franc', 2), ('CNY', 'Chinese Yuan', 2),
  ('EUR', 'Euro', 2), ('GBP', 'Pound Sterling', 2), ('HKD', 'Hong Kong Dollar', 2),
  ('INR', 'Indian Rupee', 2), ('JPY', 'Japanese Yen', 0), ('KES', 'Kenyan Shilling', 2),
  ('LKR', 'Sri Lankan Rupee', 2), ('MXN', 'Mexican Peso', 2), ('MYR', 'Malaysian Ringgit', 2),
  ('NGN', 'Nigerian Naira', 2), ('NPR', 'Nepalese Rupee', 2), ('NZD', 'New Zealand Dollar', 2),
  ('SAR', 'Saudi Riyal', 2), ('SGD', 'Singapore Dollar', 2), ('THB', 'Thai Baht', 2),
  ('TZS', 'Tanzanian Shilling', 2), ('UGX', 'Ugandan Shilling', 0), ('USD', 'US Dollar', 2),
  ('VND', 'Vietnamese Dong', 0), ('ZAR', 'South African Rand', 2);

insert into public.document_categories (code, name, b1_object_type, sort_order) values
  ('SALES_QUOTATION',         'Sales Quotation',          23,  10),
  ('SALES_ORDER',             'Sales Order',              17,  20),
  ('DELIVERY',                'Delivery',                 15,  30),
  ('SALES_RETURN',            'Return',                   16,  40),
  ('AR_INVOICE',              'A/R Invoice',              13,  50),
  ('AR_CREDIT_MEMO',          'A/R Credit Memo',          14,  60),
  ('INCOMING_PAYMENT',        'Incoming Payment',         24,  70),
  ('PURCHASE_ORDER',          'Purchase Order',           22, 110),
  ('GOODS_RECEIPT_PO',        'Goods Receipt PO',         20, 120),
  ('GOODS_RETURN',            'Goods Return',             21, 130),
  ('AP_INVOICE',              'A/P Invoice',              18, 140),
  ('AP_CREDIT_MEMO',          'A/P Credit Memo',          19, 150),
  ('OUTGOING_PAYMENT',        'Outgoing Payment',         46, 160),
  ('PRODUCTION_ORDER',        'Production Order',        202, 210),
  ('RECEIPT_FROM_PRODUCTION', 'Receipt from Production',  59, 220),
  ('ISSUE_FOR_PRODUCTION',    'Issue for Production',     60, 230),
  ('GOODS_RECEIPT',           'Goods Receipt (inventory)', 59, 310),
  ('GOODS_ISSUE',             'Goods Issue (inventory)',  60, 320),
  ('INVENTORY_TRANSFER',      'Inventory Transfer',       67, 330),
  ('INVENTORY_COUNTING',      'Inventory Counting', 1470000065, 340),
  ('PROJECT',                 'Project',                null, 410);

insert into public.system_statuses (code, name, is_final, sort_order) values
  ('DRAFT',     'Draft',     false, 10),
  ('OPEN',      'Open',      false, 20),
  ('RELEASED',  'Released',  false, 30),
  ('PARTIAL',   'Partially completed', false, 40),
  ('COMPLETED', 'Completed', false, 50),
  ('CLOSED',    'Closed',    true,  60),
  ('CANCELLED', 'Cancelled', true,  70);

insert into public.reason_types (code, name) values
  ('BUFFER_RED',              'Buffer entered red'),
  ('BUFFER_BLACK',            'Buffer entered black / late'),
  ('BUFFER_CHANGE',           'Buffer size change (DBM)'),
  ('CANCELLATION',            'Document cancellation'),
  ('STOCK_ADJUSTMENT',        'Stock adjustment'),
  ('NEGATIVE_STOCK_OVERRIDE', 'Negative stock override');

insert into public.auth_objects (code, name, description, sort_order) values
  ('COMPANY_SETUP',  'Company setup',  'Company details, registrations, settings', 10),
  ('USERS',          'Users and roles', 'Roles, permissions, user assignments', 20),
  ('CONFIG',         'Configuration',  'Document types, number ranges, statuses, reason codes', 30),
  ('EXCHANGE_RATES', 'Exchange rates', 'Exchange rate table', 40),
  ('AUDIT',          'Audit log',      'Read the change log', 50);

-- -----------------------------------------------------------------------------
-- 11. RLS, grants and triggers
-- -----------------------------------------------------------------------------

-- Reference tables
select private.enable_reference_rls('public.currencies');
select private.enable_reference_rls('public.document_categories');
select private.enable_reference_rls('public.system_statuses');
select private.enable_reference_rls('public.reason_types');
select private.enable_reference_rls('public.auth_objects');

-- companies: read if assigned; update needs COMPANY_SETUP=FULL; insert only via create_company(); never deleted.
alter table public.companies enable row level security;
revoke all on public.companies from anon;
revoke insert, delete, truncate on public.companies from authenticated;
create policy rls_select on public.companies for select to authenticated
  using (id in (select private.user_company_ids()));
create policy rls_update on public.companies for update to authenticated
  using (id in (select private.companies_with_access('COMPANY_SETUP', 'FULL')))
  with check (id in (select private.companies_with_access('COMPANY_SETUP', 'FULL')));

-- company_settings: one row per company, created by trigger; users may read/update only.
alter table public.company_settings enable row level security;
revoke all on public.company_settings from anon;
revoke insert, delete, truncate on public.company_settings from authenticated;
create policy rls_select on public.company_settings for select to authenticated
  using (company_id in (select private.user_company_ids()));
create policy rls_update on public.company_settings for update to authenticated
  using (company_id in (select private.companies_with_access('COMPANY_SETUP', 'FULL')))
  with check (company_id in (select private.companies_with_access('COMPANY_SETUP', 'FULL')));

select private.enable_company_rls('public.company_registrations', 'COMPANY_SETUP');
select private.enable_company_rls('public.exchange_rates',        'EXCHANGE_RATES');
select private.enable_company_rls('public.roles',                 'USERS');
select private.enable_company_rls('public.role_permissions',      'USERS');
select private.enable_company_rls('public.number_ranges',         'CONFIG');
select private.enable_company_rls('public.document_types',        'CONFIG');
select private.enable_company_rls('public.status_definitions',    'CONFIG');
select private.enable_company_rls('public.reason_codes',          'CONFIG');

-- user_company_roles: users always see their own assignments; managing needs USERS=FULL.
select private.enable_company_rls('public.user_company_roles', 'USERS');
drop policy rls_select on public.user_company_roles;
create policy rls_select on public.user_company_roles for select to authenticated
  using (user_id = (select auth.uid())
         or company_id in (select private.companies_with_access('USERS', 'READ')));

-- user_profiles: see your own profile and profiles of users in companies where you can read USERS.
-- Users may change only display_name and default_company_id (column grants).
alter table public.user_profiles enable row level security;
revoke all on public.user_profiles from anon;
revoke insert, update, delete, truncate on public.user_profiles from authenticated;
grant update (display_name, default_company_id) on public.user_profiles to authenticated;
create policy rls_select on public.user_profiles for select to authenticated
  using (user_id = (select auth.uid())
         or user_id in (select u.user_id from public.user_company_roles u
                        where u.company_id in (select private.companies_with_access('USERS', 'READ'))));
create policy rls_update on public.user_profiles for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- number_range_counters: readable with CONFIG=READ; written only by private.next_number().
alter table public.number_range_counters enable row level security;
revoke all on public.number_range_counters from anon;
revoke insert, update, delete, truncate on public.number_range_counters from authenticated;
create policy rls_select on public.number_range_counters for select to authenticated
  using (company_id in (select private.companies_with_access('CONFIG', 'READ')));

-- audit_log: read with AUDIT=READ; append-only.
alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon;
revoke insert, update, delete, truncate on public.audit_log from authenticated;
create policy rls_select on public.audit_log for select to authenticated
  using (company_id in (select private.companies_with_access('AUDIT', 'READ')));

-- Stamps + audit on every non-reference table
select private.attach_standard_triggers('public.companies');
select private.attach_standard_triggers('public.company_registrations');
select private.attach_standard_triggers('public.company_settings');
select private.attach_standard_triggers('public.exchange_rates');
select private.attach_standard_triggers('public.user_profiles');
select private.attach_standard_triggers('public.roles');
select private.attach_standard_triggers('public.role_permissions');
select private.attach_standard_triggers('public.user_company_roles');
select private.attach_standard_triggers('public.number_ranges');
select private.attach_standard_triggers('public.document_types');
select private.attach_standard_triggers('public.status_definitions');
select private.attach_standard_triggers('public.reason_codes');

-- Indexes on foreign keys used by RLS helpers and joins
create index user_company_roles_user_ix   on public.user_company_roles (user_id);
create index user_company_roles_role_ix   on public.user_company_roles (role_id);
create index role_permissions_company_ix  on public.role_permissions (company_id);
create index exchange_rates_currency_ix   on public.exchange_rates (currency_code);
create index document_types_category_ix   on public.document_types (category);
create index document_types_range_ix      on public.document_types (company_id, default_number_range_id);
create index status_definitions_status_ix on public.status_definitions (system_status);
create index reason_codes_type_ix         on public.reason_codes (reason_type);
create index number_range_counters_company_ix on public.number_range_counters (company_id);
create index user_profiles_default_company_ix on public.user_profiles (default_company_id);
create index role_permissions_object_ix   on public.role_permissions (auth_object);
create index companies_base_currency_ix   on public.companies (base_currency);
