-- NexLab v25.7 — Agendamento do worker de notificações externas
-- Execute SOMENTE depois de:
-- 1) publicar a Edge Function process-notification-deliveries;
-- 2) definir o mesmo NEXLAB_WORKER_SECRET nos secrets da Edge Function;
-- 3) substituir o marcador abaixo pelo segredo real.

create extension if not exists pg_cron;
create extension if not exists pg_net;
create extension if not exists supabase_vault;

-- Cria ou atualiza o segredo usado pelo Cron.
do $$
declare
  existing_secret_id uuid;
begin
  select id into existing_secret_id
  from vault.decrypted_secrets
  where name = 'nexlab_worker_secret'
  limit 1;

  if existing_secret_id is null then
    perform vault.create_secret(
      'SUBSTITUA_PELO_MESMO_NEXLAB_WORKER_SECRET_DA_EDGE_FUNCTION',
      'nexlab_worker_secret',
      'Segredo usado pelo cron do NexLab para processar notificações externas.'
    );
  else
    perform vault.update_secret(
      existing_secret_id,
      'SUBSTITUA_PELO_MESMO_NEXLAB_WORKER_SECRET_DA_EDGE_FUNCTION',
      'nexlab_worker_secret',
      'Segredo usado pelo cron do NexLab para processar notificações externas.'
    );
  end if;
end
$$;

-- Remove agendamento anterior para evitar duplicidade.
do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job
  from cron.job
  where jobname = 'nexlab-process-notification-deliveries'
  limit 1;

  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;
end
$$;

select cron.schedule(
  'nexlab-process-notification-deliveries',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://eahldhabwulnwhuwrhvc.supabase.co/functions/v1/process-notification-deliveries',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-nexlab-worker-secret', (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'nexlab_worker_secret'
        limit 1
      )
    ),
    body := '{"action":"process","source":"cron"}'::jsonb
  );
  $$
);

-- Validação:
-- select jobid, jobname, schedule, active from cron.job
-- where jobname = 'nexlab-process-notification-deliveries';
