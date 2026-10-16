-- Rollback for 20261015000001_platform.sql
-- Drops everything migration 001 created, in reverse dependency order.

drop function if exists public.create_company(text, text, char, char, text, smallint);

drop trigger if exists on_auth_user_created on auth.users;

drop table if exists public.reason_codes;
drop table if exists public.status_definitions;
drop table if exists public.document_types;
drop table if exists public.number_range_counters;
drop table if exists public.number_ranges;
drop table if exists public.audit_log;
drop policy if exists rls_select on public.user_profiles;  -- references user_company_roles
drop table if exists public.user_company_roles;
drop table if exists public.role_permissions;
drop table if exists public.roles;
drop table if exists public.user_profiles;
drop table if exists public.exchange_rates;
drop table if exists public.company_settings;
drop table if exists public.company_registrations;
drop table if exists public.companies;
drop table if exists public.auth_objects;
drop table if exists public.reason_types;
drop table if exists public.system_statuses;
drop table if exists public.document_categories;
drop table if exists public.currencies;

drop schema if exists private cascade;
