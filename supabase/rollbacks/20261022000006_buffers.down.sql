-- Rollback for 20261022000006_buffers.sql (buffer history and targets are dropped with it).

drop view if exists public.v_buffer_reason_pareto;
drop view if exists public.v_replenishment;

drop function if exists public.take_buffer_snapshot(uuid);
drop function if exists private.dbm_candidates(uuid, date);
drop function if exists public.decide_buffer_change(uuid, boolean, numeric, text);
drop function if exists public.set_buffer_event_reason(uuid, uuid, text);

drop table if exists public.buffer_change_proposals;
drop table if exists public.buffer_events;
drop table if exists public.buffer_snapshots;

drop view if exists public.v_buffer_status;
drop table if exists public.item_buffers;
drop function if exists private.prepare_item_buffer();

alter table public.company_settings drop constraint if exists company_settings_dbm_ck;
alter table public.company_settings
  drop column if exists spike_threshold_pct,
  drop column if exists dbm_red_days,
  drop column if exists dbm_green_days,
  drop column if exists dbm_step_pct;

delete from public.role_permissions where auth_object = 'BUFFERS';
delete from public.auth_objects where code = 'BUFFERS';
