-- =============================================================================
-- Migration 007 — Scheduled buffer snapshots (D-044)
-- Runs take_buffer_snapshot() for every active company every hour at :05 through pg_cron.
-- The snapshot is idempotent per company-local day, so hourly runs keep today's zones fresh and make
-- sure every company gets its day recorded whatever its time zone. Boards also refresh on open.
-- Where pg_cron is not available (local test cluster) the schedule is skipped with a notice.
-- =============================================================================

create or replace function private.take_all_buffer_snapshots()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  c uuid;
  n integer := 0;
begin
  for c in select id from public.companies where is_active loop
    perform public.take_buffer_snapshot(c);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function private.take_all_buffer_snapshots() from public;
comment on function private.take_all_buffer_snapshots() is 'Called by pg_cron job erp-buffer-snapshots; not exposed to API users.';

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule('erp-buffer-snapshots', '5 * * * *', 'select private.take_all_buffer_snapshots()');
  else
    raise notice 'pg_cron not available: buffer snapshots run only when the boards are opened';
  end if;
end $$;
