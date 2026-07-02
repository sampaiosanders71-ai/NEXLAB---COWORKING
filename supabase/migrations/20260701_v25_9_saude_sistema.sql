-- NexLab v25.9 — Saúde do Sistema e Configurações Administrativas
-- Pré-requisitos: migrations v25.6.1, v25.7 e v25.8 aplicadas.
-- Execute integralmente no SQL Editor do Supabase.

begin;

create extension if not exists pgcrypto;

do $$
begin
  if to_regclass('public.notification_deliveries') is null
     or to_regclass('public.notification_reminders') is null
     or to_regclass('public.notifications') is null
     or to_regclass('public.profiles') is null
  then
    raise exception 'Execute primeiro as migrations até a NexLab v25.8.';
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- 1. Configurações, versões e eventos técnicos
-- -----------------------------------------------------------------------------

create table if not exists public.nexlab_system_settings (
  setting_key text primary key,
  setting_value jsonb not null,
  description text null,
  updated_at timestamptz not null default now(),
  updated_by uuid null default auth.uid()
);

create table if not exists public.nexlab_app_versions (
  version text primary key,
  title text not null,
  release_status text not null default 'stable',
  notes text null,
  installed_at timestamptz not null default now(),
  installed_by uuid null default auth.uid(),
  constraint nexlab_app_versions_status_check
    check (release_status in ('rc', 'stable', 'deprecated'))
);

create table if not exists public.nexlab_system_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  severity text not null default 'info',
  message text not null,
  details jsonb not null default '{}'::jsonb,
  actor_id uuid null default auth.uid(),
  created_at timestamptz not null default now(),
  constraint nexlab_system_events_severity_check
    check (severity in ('info', 'warning', 'error', 'success'))
);

create index if not exists nexlab_system_events_created_idx
  on public.nexlab_system_events (created_at desc);

create index if not exists nexlab_system_events_severity_idx
  on public.nexlab_system_events (severity, created_at desc);

insert into public.nexlab_system_settings (setting_key, setting_value, description)
values
  ('queue_stale_minutes', '10'::jsonb, 'Minutos para considerar uma entrega travada em processamento.'),
  ('max_delivery_attempts', '5'::jsonb, 'Quantidade máxima de tentativas de entrega externa.'),
  ('notification_worker_batch_size', '50'::jsonb, 'Quantidade máxima de entregas processadas por execução do worker.'),
  ('delivery_retention_days', '90'::jsonb, 'Dias de retenção para entregas concluídas ou com falha.'),
  ('reminder_retention_days', '90'::jsonb, 'Dias de retenção para lembretes processados.'),
  ('archived_notification_retention_days', '180'::jsonb, 'Dias de retenção para notificações internas arquivadas.')
on conflict (setting_key) do nothing;

insert into public.nexlab_app_versions (version, title, release_status, notes)
values
  ('25.8.0', 'Preferências e Automação de Notificações', 'stable', 'Versão estável anterior.'),
  ('25.9.0', 'Saúde do Sistema e Configurações Administrativas', 'rc', 'Painel administrativo de diagnóstico e manutenção.')
on conflict (version) do update
set title = excluded.title,
    release_status = excluded.release_status,
    notes = excluded.notes;

-- -----------------------------------------------------------------------------
-- 2. RLS e permissões
-- -----------------------------------------------------------------------------

alter table public.nexlab_system_settings enable row level security;
alter table public.nexlab_app_versions enable row level security;
alter table public.nexlab_system_events enable row level security;

grant select, insert, update on public.nexlab_system_settings to authenticated;
grant select on public.nexlab_app_versions to authenticated;
grant select on public.nexlab_system_events to authenticated;

drop policy if exists nexlab_system_settings_admin_select on public.nexlab_system_settings;
create policy nexlab_system_settings_admin_select
on public.nexlab_system_settings
for select
to authenticated
using (public.nexlab_is_admin());

drop policy if exists nexlab_system_settings_admin_insert on public.nexlab_system_settings;
create policy nexlab_system_settings_admin_insert
on public.nexlab_system_settings
for insert
to authenticated
with check (public.nexlab_is_admin());

drop policy if exists nexlab_system_settings_admin_update on public.nexlab_system_settings;
create policy nexlab_system_settings_admin_update
on public.nexlab_system_settings
for update
to authenticated
using (public.nexlab_is_admin())
with check (public.nexlab_is_admin());

drop policy if exists nexlab_app_versions_authenticated_select on public.nexlab_app_versions;
create policy nexlab_app_versions_authenticated_select
on public.nexlab_app_versions
for select
to authenticated
using (true);

drop policy if exists nexlab_system_events_admin_select on public.nexlab_system_events;
create policy nexlab_system_events_admin_select
on public.nexlab_system_events
for select
to authenticated
using (public.nexlab_is_admin());

-- -----------------------------------------------------------------------------
-- 3. updated_at
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_system_set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

drop trigger if exists nexlab_system_settings_set_updated_at
on public.nexlab_system_settings;

create trigger nexlab_system_settings_set_updated_at
before update on public.nexlab_system_settings
for each row
execute function public.nexlab_system_set_updated_at();

-- -----------------------------------------------------------------------------
-- 4. Helpers internos
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_system_setting_int(
  p_key text,
  p_default integer,
  p_min integer default 1,
  p_max integer default 100000
)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  raw_value text;
  parsed_value integer;
begin
  select trim(both '"' from setting_value::text)
  into raw_value
  from public.nexlab_system_settings
  where setting_key = p_key
  limit 1;

  begin
    parsed_value := coalesce(nullif(raw_value, '')::integer, p_default);
  exception
    when others then
      parsed_value := p_default;
  end;

  return greatest(p_min, least(parsed_value, p_max));
end;
$$;

revoke all on function public.nexlab_system_setting_int(text, integer, integer, integer) from public;

create or replace function public.nexlab_record_system_event(
  p_event_type text,
  p_severity text,
  p_message text,
  p_details jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  inserted_id uuid;
begin
  insert into public.nexlab_system_events (
    event_type,
    severity,
    message,
    details,
    actor_id
  )
  values (
    coalesce(nullif(trim(p_event_type), ''), 'system'),
    case when p_severity in ('info', 'warning', 'error', 'success') then p_severity else 'info' end,
    coalesce(nullif(trim(p_message), ''), 'Evento técnico registrado.'),
    coalesce(p_details, '{}'::jsonb),
    auth.uid()
  )
  returning id into inserted_id;

  return inserted_id;
end;
$$;

revoke all on function public.nexlab_record_system_event(text, text, text, jsonb) from public;

-- -----------------------------------------------------------------------------
-- 5. Snapshot de saúde
-- -----------------------------------------------------------------------------

create or replace function public.get_system_health_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, cron
as $$
declare
  current_version jsonb := '{}'::jsonb;
  queue_data jsonb := '{}'::jsonb;
  cron_data jsonb := '[]'::jsonb;
  alerts jsonb := '[]'::jsonb;
  pending_count integer := 0;
  processing_count integer := 0;
  failed_count integer := 0;
  stale_count integer := 0;
  reminder_pending integer := 0;
  reminder_failed integer := 0;
  active_push integer := 0;
  stale_minutes integer := 10;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Apenas o Administrador pode consultar a saúde do sistema.'
      using errcode = '42501';
  end if;

  stale_minutes := public.nexlab_system_setting_int('queue_stale_minutes', 10, 1, 1440);

  select coalesce(to_jsonb(v), '{}'::jsonb)
  into current_version
  from (
    select version, title, release_status, installed_at
    from public.nexlab_app_versions
    order by string_to_array(version, '.')::int[] desc
    limit 1
  ) v;

  select
    count(*) filter (where status = 'pending'),
    count(*) filter (where status = 'processing'),
    count(*) filter (where status = 'failed'),
    count(*) filter (
      where status = 'processing'
        and claimed_at < now() - make_interval(mins => stale_minutes)
    )
  into pending_count, processing_count, failed_count, stale_count
  from public.notification_deliveries;

  select
    count(*) filter (where status = 'pending'),
    count(*) filter (where status = 'failed')
  into reminder_pending, reminder_failed
  from public.notification_reminders;

  if to_regclass('public.push_subscriptions') is not null then
    select count(*) into active_push
    from public.push_subscriptions
    where active;
  end if;

  queue_data := jsonb_build_object(
    'pending_deliveries', pending_count,
    'processing_deliveries', processing_count,
    'failed_deliveries', failed_count,
    'stale_processing', stale_count,
    'pending_reminders', reminder_pending,
    'failed_reminders', reminder_failed,
    'active_push_subscriptions', active_push
  );

  if to_regclass('cron.job') is not null then
    if to_regclass('cron.job_run_details') is not null then
      execute $cron_query$
        select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.jobname), '[]'::jsonb)
        from (
          select
            j.jobid,
            j.jobname,
            j.schedule,
            j.active,
            d.status as last_status,
            d.start_time as last_start,
            d.end_time as last_end,
            left(coalesce(d.return_message, ''), 500) as last_message
          from cron.job j
          left join lateral (
            select status, start_time, end_time, return_message
            from cron.job_run_details detail
            where detail.jobid = j.jobid
            order by detail.start_time desc
            limit 1
          ) d on true
          where j.jobname like 'nexlab-%'
        ) row_data
      $cron_query$ into cron_data;
    else
      execute $cron_query$
        select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.jobname), '[]'::jsonb)
        from (
          select jobid, jobname, schedule, active,
                 null::text as last_status,
                 null::timestamptz as last_start,
                 null::timestamptz as last_end,
                 null::text as last_message
          from cron.job
          where jobname like 'nexlab-%'
        ) row_data
      $cron_query$ into cron_data;
    end if;
  end if;

  if failed_count > 0 then
    alerts := alerts || jsonb_build_array(jsonb_build_object(
      'level', 'error',
      'title', 'Entregas com falha',
      'message', format('%s entrega(s) externa(s) estão com falha.', failed_count)
    ));
  end if;

  if stale_count > 0 then
    alerts := alerts || jsonb_build_array(jsonb_build_object(
      'level', 'warning',
      'title', 'Fila travada',
      'message', format('%s entrega(s) permanecem em processamento além do limite.', stale_count)
    ));
  end if;

  if reminder_failed > 0 then
    alerts := alerts || jsonb_build_array(jsonb_build_object(
      'level', 'warning',
      'title', 'Lembretes com falha',
      'message', format('%s lembrete(s) falharam durante o processamento.', reminder_failed)
    ));
  end if;

  if jsonb_array_length(cron_data) = 0 then
    alerts := alerts || jsonb_build_array(jsonb_build_object(
      'level', 'warning',
      'title', 'Cron não identificado',
      'message', 'Nenhum job do NexLab foi encontrado no pg_cron.'
    ));
  end if;

  return jsonb_build_object(
    'checked_at', now(),
    'database', jsonb_build_object('ok', true, 'server_time', now()),
    'version', current_version,
    'queues', queue_data,
    'cron', jsonb_build_object(
      'available', to_regclass('cron.job') is not null,
      'jobs', cron_data
    ),
    'alerts', alerts
  );
end;
$$;

revoke all on function public.get_system_health_snapshot() from public;
grant execute on function public.get_system_health_snapshot() to authenticated;

-- -----------------------------------------------------------------------------
-- 6. Reprocessamento e execução manual
-- -----------------------------------------------------------------------------

create or replace function public.admin_requeue_notification_queue(
  p_include_failed boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  stale_minutes integer;
  stale_requeued integer := 0;
  failed_requeued integer := 0;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Apenas o Administrador pode reprocessar a fila.'
      using errcode = '42501';
  end if;

  stale_minutes := public.nexlab_system_setting_int('queue_stale_minutes', 10, 1, 1440);

  update public.notification_deliveries
  set status = 'pending',
      claimed_at = null,
      next_attempt_at = now(),
      last_error = coalesce(last_error, 'Reenfileirada após processamento travado.')
  where status = 'processing'
    and claimed_at < now() - make_interval(mins => stale_minutes);

  get diagnostics stale_requeued = row_count;

  if coalesce(p_include_failed, false) then
    update public.notification_deliveries
    set status = 'pending',
        attempts = 0,
        claimed_at = null,
        sent_at = null,
        provider_message_id = null,
        next_attempt_at = now(),
        last_error = null
    where status = 'failed';

    get diagnostics failed_requeued = row_count;
  end if;

  perform public.nexlab_record_system_event(
    'queue_requeued',
    'success',
    'Fila de notificações reprocessada manualmente.',
    jsonb_build_object(
      'stale_requeued', stale_requeued,
      'failed_requeued', failed_requeued,
      'include_failed', coalesce(p_include_failed, false)
    )
  );

  return jsonb_build_object(
    'stale_requeued', stale_requeued,
    'failed_requeued', failed_requeued
  );
end;
$$;

revoke all on function public.admin_requeue_notification_queue(boolean) from public;
grant execute on function public.admin_requeue_notification_queue(boolean) to authenticated;

create or replace function public.admin_run_due_reminders(
  p_limit integer default 250
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  result jsonb;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Apenas o Administrador pode executar lembretes manualmente.'
      using errcode = '42501';
  end if;

  result := public.nexlab_process_due_reminders(
    greatest(1, least(coalesce(p_limit, 250), 1000))
  );

  perform public.nexlab_record_system_event(
    'reminders_processed',
    'success',
    'Processamento manual de lembretes executado.',
    result
  );

  return result;
end;
$$;

revoke all on function public.admin_run_due_reminders(integer) from public;
grant execute on function public.admin_run_due_reminders(integer) to authenticated;

-- -----------------------------------------------------------------------------
-- 7. Teste direto de canais
-- -----------------------------------------------------------------------------

create or replace function public.admin_create_channel_test(
  p_channel text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  normalized_channel text := lower(coalesce(p_channel, ''));
  notification_id_text text;
  delivery_id uuid;
  source_value text;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Apenas o Administrador pode testar canais externos.'
      using errcode = '42501';
  end if;

  if normalized_channel not in ('email', 'push') then
    raise exception 'Canal inválido. Use email ou push.'
      using errcode = '22023';
  end if;

  source_value := format(
    'system-health-test:%s:%s:%s',
    auth.uid(),
    normalized_channel,
    gen_random_uuid()
  );

  insert into public.notifications (
    recipient_id,
    type,
    preference_key,
    title,
    message,
    target_tab,
    source_key,
    category,
    priority,
    email_eligible,
    push_eligible,
    metadata
  )
  select
    p.id,
    'system',
    'system',
    format('Teste de %s do NexLab', case when normalized_channel = 'email' then 'e-mail' else 'Push' end),
    'Mensagem técnica criada pelo painel Saúde do Sistema.',
    'saude-sistema',
    source_value,
    'sistema',
    'normal',
    normalized_channel = 'email',
    normalized_channel = 'push',
    jsonb_build_object(
      'system_health_test', true,
      'channel', normalized_channel,
      'email_subject', '[NexLab] Teste técnico de notificações'
    )
  from public.profiles p
  where p.id::text = auth.uid()::text
  returning id::text into notification_id_text;

  if notification_id_text is null then
    raise exception 'Perfil do Administrador não encontrado.';
  end if;

  insert into public.notification_deliveries (
    notification_id,
    recipient_id,
    channel,
    status,
    attempts,
    next_attempt_at,
    payload
  )
  select
    n.id,
    n.recipient_id,
    normalized_channel,
    'pending',
    0,
    now(),
    jsonb_build_object(
      'notification_id', n.id::text,
      'type', n.type::text,
      'title', n.title,
      'message', n.message,
      'target_tab', n.target_tab,
      'category', n.category,
      'priority', n.priority,
      'email_subject', coalesce(n.metadata ->> 'email_subject', '[NexLab] Teste técnico')
    )
  from public.notifications n
  where n.id::text = notification_id_text
  on conflict (notification_id, channel) do update
    set status = 'pending',
        attempts = 0,
        next_attempt_at = now(),
        claimed_at = null,
        sent_at = null,
        provider_message_id = null,
        last_error = null
  returning id into delivery_id;

  perform public.nexlab_record_system_event(
    'channel_test_created',
    'info',
    format('Teste do canal %s criado.', normalized_channel),
    jsonb_build_object(
      'channel', normalized_channel,
      'notification_id', notification_id_text,
      'delivery_id', delivery_id
    )
  );

  return jsonb_build_object(
    'channel', normalized_channel,
    'notification_id', notification_id_text,
    'delivery_id', delivery_id,
    'status', 'pending'
  );
end;
$$;

revoke all on function public.admin_create_channel_test(text) from public;
grant execute on function public.admin_create_channel_test(text) to authenticated;

-- -----------------------------------------------------------------------------
-- 8. Limpeza segura com prévia
-- -----------------------------------------------------------------------------

create or replace function public.admin_cleanup_system_data(
  p_execute boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  delivery_days integer;
  reminder_days integer;
  notification_days integer;
  delivery_count integer := 0;
  reminder_count integer := 0;
  notification_count integer := 0;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Apenas o Administrador pode limpar dados técnicos.'
      using errcode = '42501';
  end if;

  delivery_days := public.nexlab_system_setting_int('delivery_retention_days', 90, 7, 3650);
  reminder_days := public.nexlab_system_setting_int('reminder_retention_days', 90, 7, 3650);
  notification_days := public.nexlab_system_setting_int('archived_notification_retention_days', 180, 7, 3650);

  select count(*) into delivery_count
  from public.notification_deliveries
  where status in ('sent', 'failed', 'skipped')
    and created_at < now() - make_interval(days => delivery_days);

  select count(*) into reminder_count
  from public.notification_reminders
  where status in ('sent', 'failed', 'skipped')
    and created_at < now() - make_interval(days => reminder_days);

  select count(*) into notification_count
  from public.notifications
  where archived_at is not null
    and archived_at < now() - make_interval(days => notification_days);

  if coalesce(p_execute, false) then
    delete from public.notification_deliveries
    where status in ('sent', 'failed', 'skipped')
      and created_at < now() - make_interval(days => delivery_days);

    delete from public.notification_reminders
    where status in ('sent', 'failed', 'skipped')
      and created_at < now() - make_interval(days => reminder_days);

    delete from public.notifications
    where archived_at is not null
      and archived_at < now() - make_interval(days => notification_days);

    perform public.nexlab_record_system_event(
      'system_cleanup',
      'success',
      'Limpeza técnica executada.',
      jsonb_build_object(
        'deliveries', delivery_count,
        'reminders', reminder_count,
        'notifications', notification_count,
        'delivery_days', delivery_days,
        'reminder_days', reminder_days,
        'notification_days', notification_days
      )
    );
  end if;

  return jsonb_build_object(
    'execute', coalesce(p_execute, false),
    'deliveries', delivery_count,
    'reminders', reminder_count,
    'notifications', notification_count,
    'total', delivery_count + reminder_count + notification_count,
    'retention', jsonb_build_object(
      'delivery_days', delivery_days,
      'reminder_days', reminder_days,
      'notification_days', notification_days
    )
  );
end;
$$;

revoke all on function public.admin_cleanup_system_data(boolean) from public;
grant execute on function public.admin_cleanup_system_data(boolean) to authenticated;

-- -----------------------------------------------------------------------------
-- 9. Realtime
-- -----------------------------------------------------------------------------

do $$
begin
  begin
    alter publication supabase_realtime add table public.nexlab_system_events;
  exception when duplicate_object then null;
  end;
end
$$;

commit;

-- Validação rápida:
-- select public.get_system_health_snapshot();
-- select public.admin_cleanup_system_data(false);
