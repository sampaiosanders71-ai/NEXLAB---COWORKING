-- NexLab v25.8 — Cron dos lembretes
-- Execute no SQL Editor após a migration principal da v25.8.

create extension if not exists pg_cron;

do $$
declare
  existing_job bigint;
begin
  select jobid
    into existing_job
  from cron.job
  where jobname = 'nexlab-process-due-reminders'
  limit 1;

  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;
end
$$;

select cron.schedule(
  'nexlab-process-due-reminders',
  '*/5 * * * *',
  $$select public.nexlab_process_due_reminders(500);$$
);

-- Conferência:
-- select jobid, jobname, schedule, active
-- from cron.job
-- where jobname = 'nexlab-process-due-reminders';
