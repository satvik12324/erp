-- Rollback for 20261022000007_buffer_schedule.sql (leaves the pg_cron extension installed).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $q$select cron.unschedule(jobid) from cron.job where jobname = 'erp-buffer-snapshots'$q$;
  end if;
end $$;
drop function if exists private.take_all_buffer_snapshots();
