-- NEXLAB v26.17.4 — R36
-- Etapa 2 final: fila terminal, telemetria, alertas e recuperação protegida de Web Push.
-- JÁ APLICADO ao projeto Supabase Nexlab (eahldhabwulnwhuwrhvc).
-- NÃO EXECUTE novamente no projeto atual. Arquivo de backup e referência.

begin;

alter table public.notification_deliveries
  add column if not exists last_attempt_at timestamptz,
  add column if not exists terminal_at timestamptz,
  add column if not exists terminal_reason text,
  add column if not exists last_provider_status integer,
  add column if not exists last_attempt_outcome text,
  add column if not exists last_worker_run_id uuid;

create table if not exists public.nexlab_notification_worker_runs (
  id uuid primary key default gen_random_uuid(),
  source text not null default 'cron',
  action text not null default 'process',
  runtime_version text,
  edge_version integer,
  status text not null default 'running'
    check (status in ('running','success','degraded','failed')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  http_status integer,
  selected_count integer not null default 0,
  sent_count integer not null default 0,
  skipped_count integer not null default 0,
  retry_count integer not null default 0,
  terminal_count integer not null default 0,
  overdue_count integer not null default 0,
  queue_before jsonb not null default '{}'::jsonb,
  queue_after jsonb not null default '{}'::jsonb,
  provider_snapshot jsonb not null default '{}'::jsonb,
  error_message text,
  created_at timestamptz not null default now()
);

create table if not exists public.notification_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  delivery_id uuid references public.notification_deliveries(id) on delete set null,
  worker_run_id uuid references public.nexlab_notification_worker_runs(id) on delete set null,
  attempt_number integer not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  outcome text not null default 'processing'
    check (outcome in ('processing','sent','skipped','retry','terminal')),
  provider text not null default 'web-push',
  provider_http_status integer,
  provider_message_id text,
  error_code text,
  error_message text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.notification_deliveries
  drop constraint if exists notification_deliveries_last_attempt_outcome_check;
alter table public.notification_deliveries
  add constraint notification_deliveries_last_attempt_outcome_check
  check (last_attempt_outcome is null or last_attempt_outcome in ('sent','skipped','retry','terminal'));

alter table public.notification_deliveries
  drop constraint if exists notification_deliveries_attempts_nonnegative_check;
alter table public.notification_deliveries
  add constraint notification_deliveries_attempts_nonnegative_check check (attempts >= 0);

create index if not exists idx_notification_deliveries_terminal
  on public.notification_deliveries(channel, terminal_at desc) where terminal_at is not null;
create index if not exists idx_notification_deliveries_worker_run
  on public.notification_deliveries(last_worker_run_id);
create index if not exists idx_notification_worker_runs_started
  on public.nexlab_notification_worker_runs(started_at desc);
create index if not exists idx_notification_worker_runs_status
  on public.nexlab_notification_worker_runs(status, started_at desc);
create index if not exists idx_notification_attempts_delivery
  on public.notification_delivery_attempts(delivery_id, attempt_number desc);
create index if not exists idx_notification_attempts_run
  on public.notification_delivery_attempts(worker_run_id, started_at desc);

alter table public.nexlab_notification_worker_runs enable row level security;
alter table public.notification_delivery_attempts enable row level security;

drop policy if exists nexlab_notification_worker_runs_admin_select
  on public.nexlab_notification_worker_runs;
create policy nexlab_notification_worker_runs_admin_select
  on public.nexlab_notification_worker_runs for select to authenticated
  using (public.nexlab_is_admin());

drop policy if exists notification_delivery_attempts_admin_select
  on public.notification_delivery_attempts;
create policy notification_delivery_attempts_admin_select
  on public.notification_delivery_attempts for select to authenticated
  using (public.nexlab_is_admin());

revoke all privileges on table public.nexlab_notification_worker_runs from public, anon, authenticated;
revoke all privileges on table public.notification_delivery_attempts from public, anon, authenticated;
grant select on table public.nexlab_notification_worker_runs to authenticated;
grant select on table public.notification_delivery_attempts to authenticated;
grant all privileges on table public.nexlab_notification_worker_runs to service_role;
grant all privileges on table public.notification_delivery_attempts to service_role;

insert into public.nexlab_system_settings(setting_key,setting_value,description,updated_at)
values
  ('max_delivery_attempts','5','Quantidade máxima definitiva de tentativas por entrega Push.',now()),
  ('notification_retry_base_minutes','2','Intervalo base do recuo exponencial da fila Push.',now()),
  ('notification_retry_max_minutes','60','Intervalo máximo entre tentativas da fila Push.',now()),
  ('notification_no_progress_minutes','10','Prazo sem envio ou finalização que gera alerta de ausência de progresso.',now()),
  ('notification_worker_stale_minutes','3','Prazo sem execução concluída do worker que gera alerta.',now())
on conflict (setting_key) do update
set setting_value=excluded.setting_value,
    description=excluded.description,
    updated_at=now();

create or replace function public.nexlab_requeue_preserved_push_v26174()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  provider_record record;
  requeued_count integer := 0;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;

  select configured, valid, operational, status, details
  into provider_record
  from public.nexlab_notification_provider_health
  where channel='push';

  if provider_record is null
     or not coalesce(provider_record.configured,false)
     or not coalesce(provider_record.valid,false)
     or coalesce(provider_record.status,'') not in ('configured','operational')
  then
    raise exception 'O Web Push ainda não possui um par VAPID válido.' using errcode='55000';
  end if;

  update public.notification_deliveries
  set status='pending', attempts=0, next_attempt_at=now(), claimed_at=null,
      sent_at=null, provider_message_id=null, last_error=null,
      overdue_detected_at=null, last_attempt_at=null, terminal_at=null,
      terminal_reason=null, last_provider_status=null,
      last_attempt_outcome=null, last_worker_run_id=null, updated_at=now()
  where channel='push'
    and status in ('pending','failed')
    and (
      last_error ilike '%chave privada%'
      or last_error ilike '%VAPID%'
      or terminal_reason ilike '%VAPID%'
      or terminal_reason ilike '%chave privada%'
      or next_attempt_at > now() + interval '2 hours'
    );

  get diagnostics requeued_count = row_count;

  insert into public.nexlab_system_events(event_type,severity,message,details,actor_id,created_at)
  values (
    'push_deliveries_requeued',
    case when requeued_count > 0 then 'success' else 'info' end,
    'Entregas Push preservadas foram liberadas para novo processamento.',
    jsonb_build_object('requeued',requeued_count,'provider_status',provider_record.status,'provider_valid',provider_record.valid),
    auth.uid(),now()
  );

  return jsonb_build_object('ok',true,'requeued',requeued_count,
    'provider_status',provider_record.status,'provider_valid',provider_record.valid);
end;
$$;
revoke execute on function public.nexlab_requeue_preserved_push_v26174() from public, anon;
grant execute on function public.nexlab_requeue_preserved_push_v26174() to authenticated;

create or replace function public.admin_requeue_notification_queue(p_include_failed boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  stale_minutes integer;
  stale_requeued integer := 0;
  failed_requeued integer := 0;
  provider_valid boolean := false;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Apenas o Administrador pode reprocessar a fila.' using errcode='42501';
  end if;

  stale_minutes := public.nexlab_system_setting_int('queue_stale_minutes',10,1,1440);
  update public.notification_deliveries
  set status='pending',claimed_at=null,next_attempt_at=now(),
      last_error=coalesce(last_error,'Reenfileirada após processamento travado.'),updated_at=now()
  where channel='push' and status='processing'
    and claimed_at < now() - make_interval(mins => stale_minutes);
  get diagnostics stale_requeued = row_count;

  if coalesce(p_include_failed,false) then
    select coalesce(valid,false) and status in ('configured','operational')
    into provider_valid
    from public.nexlab_notification_provider_health where channel='push';
    if not coalesce(provider_valid,false) then
      raise exception 'Falhas Push não podem ser reenfileiradas enquanto o provedor estiver inválido.' using errcode='55000';
    end if;

    update public.notification_deliveries
    set status='pending',attempts=0,claimed_at=null,sent_at=null,
        provider_message_id=null,next_attempt_at=now(),last_error=null,
        terminal_at=null,terminal_reason=null,last_provider_status=null,
        last_attempt_outcome=null,last_worker_run_id=null,updated_at=now()
    where channel='push' and status='failed';
    get diagnostics failed_requeued = row_count;
  end if;

  insert into public.nexlab_system_events(event_type,severity,message,details,actor_id,created_at)
  values ('queue_requeued','success','Fila Push reprocessada manualmente.',
    jsonb_build_object('stale_requeued',stale_requeued,'failed_requeued',failed_requeued,'include_failed',coalesce(p_include_failed,false)),
    auth.uid(),now());

  return jsonb_build_object('stale_requeued',stale_requeued,'failed_requeued',failed_requeued);
end;
$$;

create or replace function public.get_system_health_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  v_current_version jsonb := '{}'::jsonb;
  v_cron_data jsonb := '[]'::jsonb;
  v_alerts jsonb := '[]'::jsonb;
  v_provider_data jsonb := '[]'::jsonb;
  v_latest_run jsonb := '{}'::jsonb;
  v_pending_count integer := 0;
  v_due_pending_count integer := 0;
  v_overdue_count integer := 0;
  v_processing_count integer := 0;
  v_terminal_failed_count integer := 0;
  v_reminder_pending integer := 0;
  v_reminder_failed integer := 0;
  v_active_push integer := 0;
  v_oldest_pending timestamptz;
  v_last_run_finished timestamptz;
  v_last_progress_at timestamptz;
  v_provider_valid boolean := false;
  v_provider_operational boolean := false;
  v_provider_status text := 'unknown';
  v_provider_reason text;
  v_worker_stale_minutes integer := 3;
  v_no_progress_minutes integer := 10;
  v_overdue_minutes integer := 15;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Apenas o Administrador pode consultar a saúde do sistema.' using errcode='42501';
  end if;

  v_worker_stale_minutes := public.nexlab_system_setting_int('notification_worker_stale_minutes',3,1,120);
  v_no_progress_minutes := public.nexlab_system_setting_int('notification_no_progress_minutes',10,1,1440);
  v_overdue_minutes := public.nexlab_system_setting_int('notification_pending_overdue_minutes',15,1,10080);

  select coalesce(to_jsonb(version_row),'{}'::jsonb)
  into v_current_version
  from (
    select version,title,release_status,installed_at
    from public.nexlab_app_versions
    order by string_to_array(version,'.')::integer[] desc
    limit 1
  ) version_row;

  select
    count(*) filter (where delivery.status='pending'),
    count(*) filter (where delivery.status='pending' and delivery.next_attempt_at <= now()),
    count(*) filter (
      where delivery.status='pending'
        and delivery.next_attempt_at <= now()
        and delivery.created_at < now() - make_interval(mins => v_overdue_minutes)
    ),
    count(*) filter (where delivery.status='processing'),
    count(*) filter (where delivery.status='failed' and delivery.terminal_at is not null),
    min(delivery.created_at) filter (where delivery.status='pending')
  into v_pending_count,v_due_pending_count,v_overdue_count,v_processing_count,v_terminal_failed_count,v_oldest_pending
  from public.notification_deliveries delivery
  where delivery.channel='push';

  select count(*) filter (where reminder.status='pending'),
         count(*) filter (where reminder.status='failed')
  into v_reminder_pending,v_reminder_failed
  from public.notification_reminders reminder;

  select count(*) into v_active_push
  from public.push_subscriptions subscription
  where subscription.active;

  select coalesce(health.valid,false),coalesce(health.operational,false),
         coalesce(health.status,'unknown'),health.details->>'reason'
  into v_provider_valid,v_provider_operational,v_provider_status,v_provider_reason
  from public.nexlab_notification_provider_health health
  where health.channel='push';

  select coalesce(jsonb_agg(to_jsonb(health) order by health.channel),'[]'::jsonb)
  into v_provider_data
  from public.nexlab_notification_provider_health health;

  select coalesce(to_jsonb(run_row),'{}'::jsonb),run_row.finished_at
  into v_latest_run,v_last_run_finished
  from (
    select worker.id,worker.source,worker.action,worker.runtime_version,worker.edge_version,
           worker.status,worker.started_at,worker.finished_at,worker.http_status,
           worker.selected_count,worker.sent_count,worker.skipped_count,
           worker.retry_count,worker.terminal_count,worker.overdue_count,
           worker.queue_before,worker.queue_after,worker.provider_snapshot,worker.error_message
    from public.nexlab_notification_worker_runs worker
    order by worker.started_at desc
    limit 1
  ) run_row;

  select max(worker.finished_at)
  into v_last_progress_at
  from public.nexlab_notification_worker_runs worker
  where worker.status in ('success','degraded')
    and (worker.sent_count + worker.skipped_count + worker.terminal_count) > 0;

  if to_regclass('cron.job') is not null then
    if to_regclass('cron.job_run_details') is not null then
      execute $cron_query$
        select coalesce(jsonb_agg(to_jsonb(item) order by item.jobname),'[]'::jsonb)
        from (
          select job.jobid,job.jobname,job.schedule,job.active,
                 details.status as last_status,details.start_time as last_start,
                 details.end_time as last_end,left(coalesce(details.return_message,''),500) as last_message
          from cron.job job
          left join lateral (
            select run.status,run.start_time,run.end_time,run.return_message
            from cron.job_run_details run
            where run.jobid=job.jobid
            order by run.start_time desc limit 1
          ) details on true
          where job.jobname like 'nexlab-%'
        ) item
      $cron_query$ into v_cron_data;
    end if;
  end if;

  if not coalesce(v_provider_valid,false) then
    v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
      'level','error','code','push_provider_invalid','title','Web Push indisponível',
      'message',coalesce(v_provider_reason,'O provedor Web Push não passou na validação.'),
      'action','Substituir a chave privada VAPID antes de reenfileirar as entregas.'
    ));
  elsif not coalesce(v_provider_operational,false) then
    v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
      'level','warning','code','push_not_confirmed','title','Web Push ainda não confirmado',
      'message','A configuração é válida, mas nenhuma entrega recente foi aceita pelo provedor.'
    ));
  end if;

  if v_overdue_count > 0 then
    v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
      'level','warning','code','push_overdue','title','Entregas Push vencidas',
      'message',format('%s entrega(s) estão disponíveis para processamento além do prazo de %s minutos.',v_overdue_count,v_overdue_minutes)
    ));
  end if;

  if v_terminal_failed_count > 0 then
    v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
      'level','error','code','push_terminal_failures','title','Entregas encerradas com falha',
      'message',format('%s entrega(s) atingiram o limite definitivo de tentativas.',v_terminal_failed_count)
    ));
  end if;

  if v_last_run_finished is null or v_last_run_finished < now() - make_interval(mins => v_worker_stale_minutes) then
    v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
      'level','error','code','worker_stale','title','Worker sem execução recente',
      'message',format('Nenhuma execução concluída foi registrada nos últimos %s minutos.',v_worker_stale_minutes)
    ));
  end if;

  if v_due_pending_count > 0
     and (v_last_progress_at is null or v_last_progress_at < now() - make_interval(mins => v_no_progress_minutes))
  then
    v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
      'level','warning','code','queue_no_progress','title','Fila sem progresso',
      'message',format('Há %s entrega(s) prontas, mas nenhuma conclusão foi registrada nos últimos %s minutos.',v_due_pending_count,v_no_progress_minutes)
    ));
  end if;

  if v_reminder_failed > 0 then
    v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
      'level','warning','code','reminder_failures','title','Lembretes com falha',
      'message',format('%s lembrete(s) falharam durante o processamento.',v_reminder_failed)
    ));
  end if;

  if jsonb_array_length(v_cron_data)=0 then
    v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
      'level','error','code','cron_missing','title','Cron não identificado',
      'message','Nenhum job do NEXLAB foi encontrado no pg_cron.'
    ));
  end if;

  return jsonb_build_object(
    'checked_at',now(),
    'database',jsonb_build_object('ok',true,'server_time',now()),
    'version',v_current_version,
    'providers',v_provider_data,
    'worker',jsonb_build_object(
      'latest_run',v_latest_run,
      'last_progress_at',v_last_progress_at,
      'stale_after_minutes',v_worker_stale_minutes,
      'no_progress_after_minutes',v_no_progress_minutes
    ),
    'queues',jsonb_build_object(
      'pending_deliveries',v_pending_count,
      'due_pending_deliveries',v_due_pending_count,
      'overdue_deliveries',v_overdue_count,
      'processing_deliveries',v_processing_count,
      'terminal_failed_deliveries',v_terminal_failed_count,
      'oldest_pending_at',v_oldest_pending,
      'pending_reminders',v_reminder_pending,
      'failed_reminders',v_reminder_failed,
      'active_push_subscriptions',v_active_push,
      'email_mode','suspended'
    ),
    'cron',jsonb_build_object('available',to_regclass('cron.job') is not null,'jobs',v_cron_data),
    'alerts',v_alerts
  );
end;
$$;


-- Limpeza de estrutura intermediária que não foi utilizada.
drop table if exists public.nexlab_worker_http_log;

commit;

-- Edge Function implantada separadamente:
-- process-notification-deliveries, deployment 16, runtime 26.17.4.
-- Arquivos no pacote: index.ts, telemetry.ts, worker.ts e vapid.ts.
