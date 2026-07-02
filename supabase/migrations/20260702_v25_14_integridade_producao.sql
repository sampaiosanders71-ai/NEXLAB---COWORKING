-- NexLab v25.14.0 — Integridade e Preparação para Produção
-- Execute integralmente no Supabase SQL Editor após a v25.13.0.
-- Não exige alteração em Edge Functions, Secrets ou Cron.

begin;

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1. Estruturas de checklist, diagnósticos registrados e limpeza controlada
-- -----------------------------------------------------------------------------

do $$
declare
  profile_id_type text;
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.nexlab_app_versions') is null
     or to_regclass('public.nexlab_system_events') is null
  then
    raise exception 'Execute primeiro as migrations anteriores do NexLab.';
  end if;

  select format_type(a.atttypid, a.atttypmod)
    into profile_id_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'id'
    and a.attnum > 0
    and not a.attisdropped;

  if profile_id_type is null then
    raise exception 'Não foi possível identificar o tipo de profiles.id.';
  end if;

  if to_regclass('public.nexlab_production_checklist') is null then
    execute format(
      'create table public.nexlab_production_checklist (
         check_key text primary key,
         label text not null,
         description text not null default '''',
         required boolean not null default true,
         sort_order integer not null default 100,
         completed boolean not null default false,
         completed_at timestamptz null,
         completed_by %s null references public.profiles(id) on delete set null,
         notes text null,
         updated_at timestamptz not null default now()
       )',
      profile_id_type
    );
  end if;

  if to_regclass('public.nexlab_production_snapshots') is null then
    execute format(
      'create table public.nexlab_production_snapshots (
         id uuid primary key default gen_random_uuid(),
         app_version text not null,
         readiness_status text not null,
         score integer not null,
         client_context jsonb not null default ''{}''::jsonb,
         snapshot jsonb not null,
         created_by %s null references public.profiles(id) on delete set null,
         created_at timestamptz not null default now(),
         constraint nexlab_production_snapshots_status_check
           check (readiness_status in (''ready'', ''attention'', ''blocked'')),
         constraint nexlab_production_snapshots_score_check
           check (score between 0 and 100)
       )',
      profile_id_type
    );
  end if;

  if to_regclass('public.nexlab_test_cleanup_runs') is null then
    execute format(
      'create table public.nexlab_test_cleanup_runs (
         id uuid primary key default gen_random_uuid(),
         action text not null default ''quarantine'',
         requested_profile_ids jsonb not null default ''[]''::jsonb,
         affected_profiles integer not null default 0,
         removed_push_subscriptions integer not null default 0,
         removed_pending_deliveries integer not null default 0,
         removed_pending_reminders integer not null default 0,
         removed_permission_overrides integer not null default 0,
         skipped jsonb not null default ''[]''::jsonb,
         reason text not null,
         created_by %s null references public.profiles(id) on delete set null,
         created_at timestamptz not null default now(),
         constraint nexlab_test_cleanup_runs_action_check
           check (action in (''quarantine''))
       )',
      profile_id_type
    );
  end if;
end
$$;

create index if not exists nexlab_production_snapshots_created_idx
  on public.nexlab_production_snapshots (created_at desc);

create index if not exists nexlab_test_cleanup_runs_created_idx
  on public.nexlab_test_cleanup_runs (created_at desc);

insert into public.nexlab_production_checklist (
  check_key,
  label,
  description,
  required,
  sort_order
)
values
  ('backup_database', 'Backup conferido', 'Confirmar que existe um backup recente do banco antes da publicação.', true, 10),
  ('rollback_files', 'Arquivos de reversão guardados', 'Confirmar que HTML, ZIP, SQL e rollback das versões estáveis foram arquivados.', true, 20),
  ('admin_access', 'Acesso administrativo validado', 'Confirmar login, permissões e recuperação de acesso de pelo menos um Administrador.', true, 30),
  ('desktop_review', 'Teste no computador concluído', 'Validar os fluxos principais em navegador de computador.', true, 40),
  ('mobile_review', 'Teste no celular concluído', 'Validar navegação, modais, rolagem e formulários no celular.', true, 50),
  ('email_review', 'E-mail transacional validado', 'Confirmar uma entrega real de e-mail pelo worker de notificações.', true, 60),
  ('https_domain', 'Domínio HTTPS validado', 'Confirmar domínio final, certificado HTTPS e URL pública do NexLab.', true, 70),
  ('push_review', 'Web Push validado em HTTPS', 'Confirmar inscrição e recebimento real de Web Push após a publicação.', true, 80),
  ('privacy_review', 'Privacidade e dados revisados', 'Confirmar que contas e registros de teste não serão levados indevidamente à produção.', true, 90),
  ('release_approval', 'Publicação aprovada', 'Registrar a decisão final de publicar a versão validada.', true, 100)
on conflict (check_key) do update
set
  label = excluded.label,
  description = excluded.description,
  required = excluded.required,
  sort_order = excluded.sort_order,
  updated_at = now();

-- -----------------------------------------------------------------------------
-- 2. RLS e privilégios
-- -----------------------------------------------------------------------------

alter table public.nexlab_production_checklist enable row level security;
alter table public.nexlab_production_snapshots enable row level security;
alter table public.nexlab_test_cleanup_runs enable row level security;

revoke all on public.nexlab_production_checklist from anon;
revoke all on public.nexlab_production_snapshots from anon;
revoke all on public.nexlab_test_cleanup_runs from anon;

revoke insert, update, delete on public.nexlab_production_checklist from authenticated;
revoke insert, update, delete on public.nexlab_production_snapshots from authenticated;
revoke insert, update, delete on public.nexlab_test_cleanup_runs from authenticated;

grant select on public.nexlab_production_checklist to authenticated;
grant select on public.nexlab_production_snapshots to authenticated;
grant select on public.nexlab_test_cleanup_runs to authenticated;

drop policy if exists nexlab_production_checklist_admin_select
on public.nexlab_production_checklist;

create policy nexlab_production_checklist_admin_select
on public.nexlab_production_checklist
for select
to authenticated
using (public.nexlab_is_admin());

drop policy if exists nexlab_production_snapshots_admin_select
on public.nexlab_production_snapshots;

create policy nexlab_production_snapshots_admin_select
on public.nexlab_production_snapshots
for select
to authenticated
using (public.nexlab_is_admin());

drop policy if exists nexlab_test_cleanup_runs_admin_select
on public.nexlab_test_cleanup_runs;

create policy nexlab_test_cleanup_runs_admin_select
on public.nexlab_test_cleanup_runs
for select
to authenticated
using (public.nexlab_is_admin());

-- -----------------------------------------------------------------------------
-- 3. Atualização manual do checklist final
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_update_production_check(
  p_check_key text,
  p_completed boolean,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  result_row public.nexlab_production_checklist%rowtype;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.'
      using errcode = '42501';
  end if;

  update public.nexlab_production_checklist
  set
    completed = coalesce(p_completed, false),
    completed_at = case when coalesce(p_completed, false) then now() else null end,
    completed_by = case when coalesce(p_completed, false) then auth.uid() else null end,
    notes = nullif(btrim(coalesce(p_notes, '')), ''),
    updated_at = now()
  where check_key = btrim(coalesce(p_check_key, ''))
  returning * into result_row;

  if result_row.check_key is null then
    raise exception 'Item do checklist não encontrado.'
      using errcode = 'P0002';
  end if;

  perform public.nexlab_record_system_event(
    'production_checklist_updated',
    'info',
    format('Checklist de produção atualizado: %s.', result_row.label),
    jsonb_build_object(
      'check_key', result_row.check_key,
      'completed', result_row.completed,
      'notes', result_row.notes
    )
  );

  return to_jsonb(result_row);
end;
$$;

revoke all
on function public.nexlab_update_production_check(text, boolean, text)
from public;

grant execute
on function public.nexlab_update_production_check(text, boolean, text)
to authenticated;

-- -----------------------------------------------------------------------------
-- 4. Diagnóstico consolidado de integridade e prontidão
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_get_production_readiness(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, cron
as $$
declare
  expected_version constant text := '25.14.0';
  current_version text;
  current_release_status text;
  total_profiles integer := 0;
  incomplete_profiles integer := 0;
  inactive_profiles integer := 0;
  pending_profiles integer := 0;
  invalid_roles integer := 0;
  missing_email integer := 0;
  missing_core_permissions integer := 0;
  duplicate_emails integer := 0;
  duplicate_matriculas integer := 0;
  auth_without_profile integer := 0;
  profile_without_auth integer := 0;
  orphan_notifications integer := 0;
  orphan_deliveries integer := 0;
  orphan_reminders integer := 0;
  orphan_exports integer := 0;
  orphan_overrides integer := 0;
  orphan_total integer := 0;
  missing_rls integer := 0;
  missing_functions integer := 0;
  missing_triggers integer := 0;
  missing_or_inactive_cron integer := 0;
  manual_required integer := 0;
  manual_completed integer := 0;
  cleanup_candidates jsonb := '[]'::jsonb;
  rls_details jsonb := '[]'::jsonb;
  function_details jsonb := '[]'::jsonb;
  trigger_details jsonb := '[]'::jsonb;
  cron_details jsonb := '[]'::jsonb;
  manual_checklist jsonb := '[]'::jsonb;
  checks jsonb := '[]'::jsonb;
  score integer := 0;
  required_checks integer := 0;
  passed_checks integer := 0;
  blocking_checks integer := 0;
  attention_checks integer := 0;
  readiness_status text := 'attention';
  protocol_value text := coalesce(p_client_context->>'protocol', '');
  hostname_value text := coalesce(p_client_context->>'hostname', '');
  client_app_version text := coalesce(p_client_context->>'client_app_version', '');
  https_ok boolean := false;
  production_host boolean := false;
  app_url_configured boolean := coalesce((p_client_context->>'app_url_configured')::boolean, false);
  edge_ok boolean := coalesce((p_client_context->>'edge_function_ok')::boolean, false);
  email_configured boolean := coalesce((p_client_context->>'email_configured')::boolean, false);
  push_configured boolean := coalesce((p_client_context->>'push_configured')::boolean, false);
  service_worker_supported boolean := coalesce((p_client_context->>'service_worker_supported')::boolean, false);
  notification_permission text := coalesce(p_client_context->>'notification_permission', 'default');
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.'
      using errcode = '42501';
  end if;

  select v.version, v.release_status
    into current_version, current_release_status
  from public.nexlab_app_versions v
  order by string_to_array(v.version, '.')::int[] desc
  limit 1;

  select
    count(*),
    count(*) filter (where not coalesce(p.cadastro_completo, false)),
    count(*) filter (where not coalesce(p.ativo, true)),
    count(*) filter (where p.role_request_status = 'pending'),
    count(*) filter (
      where lower(coalesce(p.role::text, '')) not in (
        'admin', 'administrador', 'coordenador', 'bolsista', 'coworking_junior'
      )
    ),
    count(*) filter (where nullif(btrim(coalesce(p.email, '')), '') is null),
    count(*) filter (
      where coalesce(p.cadastro_completo, false)
        and coalesce(p.ativo, true)
        and not ('module_perfil' = any(coalesce(p.effective_permissions, '{}'::text[])))
    )
  into
    total_profiles,
    incomplete_profiles,
    inactive_profiles,
    pending_profiles,
    invalid_roles,
    missing_email,
    missing_core_permissions
  from public.profiles p;

  select count(*) into duplicate_emails
  from (
    select lower(btrim(email))
    from public.profiles
    where nullif(btrim(coalesce(email, '')), '') is not null
    group by lower(btrim(email))
    having count(*) > 1
  ) duplicate_groups;

  select count(*) into duplicate_matriculas
  from (
    select lower(btrim(matricula))
    from public.profiles
    where nullif(btrim(coalesce(matricula, '')), '') is not null
    group by lower(btrim(matricula))
    having count(*) > 1
  ) duplicate_groups;

  begin
    select count(*) into auth_without_profile
    from auth.users u
    left join public.profiles p
      on p.id::text = u.id::text
    where p.id is null;

    select count(*) into profile_without_auth
    from public.profiles p
    left join auth.users u
      on u.id::text = p.id::text
    where u.id is null;
  exception
    when insufficient_privilege then
      auth_without_profile := 0;
      profile_without_auth := 0;
  end;

  if to_regclass('public.notifications') is not null then
    execute 'select count(*) from public.notifications n left join public.profiles p on p.id::text = n.recipient_id::text where p.id is null'
      into orphan_notifications;
  end if;

  if to_regclass('public.notification_deliveries') is not null then
    execute 'select count(*) from public.notification_deliveries d left join public.profiles p on p.id::text = d.recipient_id::text where p.id is null'
      into orphan_deliveries;
  end if;

  if to_regclass('public.notification_reminders') is not null then
    execute 'select count(*) from public.notification_reminders r left join public.profiles p on p.id::text = r.recipient_id::text where p.id is null'
      into orphan_reminders;
  end if;

  if to_regclass('public.nexlab_report_exports') is not null then
    execute 'select count(*) from public.nexlab_report_exports e left join public.profiles p on p.id::text = e.user_id::text where p.id is null'
      into orphan_exports;
  end if;

  if to_regclass('public.nexlab_user_permission_overrides') is not null then
    execute 'select count(*) from public.nexlab_user_permission_overrides o left join public.profiles p on p.id::text = o.user_id::text where p.id is null'
      into orphan_overrides;
  end if;

  orphan_total := auth_without_profile
    + profile_without_auth
    + orphan_notifications
    + orphan_deliveries
    + orphan_reminders
    + orphan_exports
    + orphan_overrides;

  with expected(table_name) as (
    values
      ('profiles'),
      ('notifications'),
      ('notification_deliveries'),
      ('notification_reminders'),
      ('push_subscriptions'),
      ('profile_role_requests'),
      ('profile_management_history'),
      ('nexlab_permission_catalog'),
      ('nexlab_role_permission_defaults'),
      ('nexlab_user_permission_overrides'),
      ('nexlab_permission_history'),
      ('nexlab_report_exports'),
      ('nexlab_system_settings'),
      ('nexlab_system_events'),
      ('nexlab_app_versions'),
      ('nexlab_production_checklist'),
      ('nexlab_production_snapshots'),
      ('nexlab_test_cleanup_runs')
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'table', e.table_name,
        'exists', c.oid is not null,
        'rls_enabled', coalesce(c.relrowsecurity, false),
        'policy_count', coalesce((
          select count(*)
          from pg_policies policy
          where policy.schemaname = 'public'
            and policy.tablename = e.table_name
        ), 0)
      ) order by e.table_name
    ), '[]'::jsonb),
    count(*) filter (where c.oid is null or not coalesce(c.relrowsecurity, false))
  into rls_details, missing_rls
  from expected e
  left join pg_class c
    on c.oid = to_regclass(format('public.%I', e.table_name));

  with expected(label, signature) as (
    values
      ('Saúde do sistema', 'public.get_system_health_snapshot()'),
      ('Matriz de permissões', 'public.nexlab_get_permission_matrix()'),
      ('Registro de exportação', 'public.nexlab_record_report_export(text,text,integer,boolean,jsonb)'),
      ('Histórico de exportações', 'public.nexlab_get_report_export_history(integer)'),
      ('Conclusão de cadastro', 'public.nexlab_complete_profile_registration(text,text,text,text,text)'),
      ('Revisão de perfil', 'public.nexlab_review_profile_request(text,boolean,text)'),
      ('Gestão administrativa de perfil', 'public.nexlab_admin_manage_profile(text,text,boolean,jsonb,text,text,text,text,boolean)'),
      ('Limpeza técnica', 'public.admin_cleanup_system_data(boolean)'),
      ('Processamento de lembretes', 'public.nexlab_process_due_reminders(integer)')
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'label', e.label,
        'signature', e.signature,
        'exists', to_regprocedure(e.signature) is not null
      ) order by e.label
    ), '[]'::jsonb),
    count(*) filter (where to_regprocedure(e.signature) is null)
  into function_details, missing_functions
  from expected e;

  with expected(trigger_name) as (
    values
      ('nexlab_guard_profile_role_fields_trigger'),
      ('nexlab_after_profile_registration_trigger'),
      ('nexlab_prevent_last_active_admin_trigger'),
      ('nexlab_capture_profile_management_history_trigger'),
      ('nexlab_recalculate_permissions_after_role_change_trigger'),
      ('nexlab_guard_effective_permissions_trigger')
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'trigger', e.trigger_name,
        'exists', t.oid is not null,
        'enabled', coalesce(t.tgenabled in ('O', 'A'), false),
        'table', case when t.oid is not null then t.tgrelid::regclass::text else null end
      ) order by e.trigger_name
    ), '[]'::jsonb),
    count(*) filter (where t.oid is null or t.tgenabled not in ('O', 'A'))
  into trigger_details, missing_triggers
  from expected e
  left join pg_trigger t
    on t.tgname = e.trigger_name
   and not t.tgisinternal;

  if to_regclass('cron.job') is not null then
    execute $cron$
      with expected(jobname) as (
        values
          ('nexlab-process-notification-deliveries'),
          ('nexlab-process-due-reminders')
      )
      select
        coalesce(jsonb_agg(
          jsonb_build_object(
            'jobname', e.jobname,
            'exists', j.jobid is not null,
            'active', coalesce(j.active, false),
            'schedule', j.schedule
          ) order by e.jobname
        ), '[]'::jsonb),
        count(*) filter (where j.jobid is null or not coalesce(j.active, false))
      from expected e
      left join cron.job j on j.jobname = e.jobname
    $cron$ into cron_details, missing_or_inactive_cron;
  else
    cron_details := jsonb_build_array(
      jsonb_build_object('jobname', 'nexlab-process-notification-deliveries', 'exists', false, 'active', false),
      jsonb_build_object('jobname', 'nexlab-process-due-reminders', 'exists', false, 'active', false)
    );
    missing_or_inactive_cron := 2;
  end if;

  select
    coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order), '[]'::jsonb),
    count(*) filter (where c.required),
    count(*) filter (where c.required and c.completed)
  into manual_checklist, manual_required, manual_completed
  from public.nexlab_production_checklist c;

  select coalesce(jsonb_agg(to_jsonb(candidate) order by candidate.created_at), '[]'::jsonb)
  into cleanup_candidates
  from (
    select
      p.id,
      p.nome,
      p.email,
      p.matricula,
      p.role::text as role,
      p.ativo,
      p.cadastro_completo,
      p.created_at,
      array_remove(array[
        case when lower(coalesce(p.nome, '')) ~ '(teste|test|demo|dummy|sandbox|homolog)' then 'nome de teste' end,
        case when lower(coalesce(p.email, '')) ~ '(teste|test|demo|dummy|sandbox|homolog)' then 'e-mail de teste' end,
        case when lower(coalesce(p.matricula, '')) ~ '(teste|test|demo|dummy|sandbox|homolog)' then 'matrícula de teste' end,
        case when not coalesce(p.cadastro_completo, false) and p.created_at < now() - interval '30 days' then 'cadastro incompleto antigo' end,
        case when not coalesce(p.ativo, true) and p.created_at < now() - interval '30 days' then 'conta inativa antiga' end
      ]::text[], null) as reasons
    from public.profiles p
    where p.id::text <> auth.uid()::text
      and lower(coalesce(p.role::text, '')) not in ('admin', 'administrador')
      and (
        lower(coalesce(p.nome, '')) ~ '(teste|test|demo|dummy|sandbox|homolog)'
        or lower(coalesce(p.email, '')) ~ '(teste|test|demo|dummy|sandbox|homolog)'
        or lower(coalesce(p.matricula, '')) ~ '(teste|test|demo|dummy|sandbox|homolog)'
        or (not coalesce(p.cadastro_completo, false) and p.created_at < now() - interval '30 days')
        or (not coalesce(p.ativo, true) and p.created_at < now() - interval '30 days')
      )
    order by p.created_at
    limit 100
  ) candidate;

  https_ok := protocol_value = 'https:';
  production_host := https_ok
    and hostname_value not in ('', 'localhost', '127.0.0.1', '::1')
    and hostname_value !~ '^192\\.168\\.';

  checks := jsonb_build_array(
    jsonb_build_object('id', 'version', 'label', 'Versão do banco e do aplicativo', 'required', true,
      'status', case when current_version = expected_version and client_app_version = expected_version then 'pass' else 'fail' end,
      'message', format('Banco: v%s • Aplicativo: v%s • Esperado: v%s', coalesce(current_version, 'não registrada'), coalesce(nullif(client_app_version, ''), 'não informado'), expected_version)),
    jsonb_build_object('id', 'rls', 'label', 'Políticas RLS das tabelas críticas', 'required', true,
      'status', case when missing_rls = 0 then 'pass' else 'fail' end,
      'message', case when missing_rls = 0 then 'Todas as tabelas críticas existem e possuem RLS.' else format('%s tabela(s) ausente(s) ou sem RLS.', missing_rls) end),
    jsonb_build_object('id', 'functions', 'label', 'RPCs e funções essenciais', 'required', true,
      'status', case when missing_functions = 0 then 'pass' else 'fail' end,
      'message', case when missing_functions = 0 then 'Todas as funções essenciais foram encontradas.' else format('%s função(ões) essencial(is) ausente(s).', missing_functions) end),
    jsonb_build_object('id', 'triggers', 'label', 'Triggers de proteção', 'required', true,
      'status', case when missing_triggers = 0 then 'pass' else 'fail' end,
      'message', case when missing_triggers = 0 then 'Todos os triggers de proteção estão ativos.' else format('%s trigger(s) ausente(s) ou inativo(s).', missing_triggers) end),
    jsonb_build_object('id', 'cron', 'label', 'Agendamentos automáticos', 'required', true,
      'status', case when missing_or_inactive_cron = 0 then 'pass' else 'fail' end,
      'message', case when missing_or_inactive_cron = 0 then 'Os jobs automáticos obrigatórios estão ativos.' else format('%s job(s) ausente(s) ou inativo(s).', missing_or_inactive_cron) end),
    jsonb_build_object('id', 'integrity', 'label', 'Integridade de perfis e vínculos', 'required', true,
      'status', case when invalid_roles = 0 and missing_core_permissions = 0 and duplicate_emails = 0 and duplicate_matriculas = 0 then 'pass' else 'fail' end,
      'message', format('Perfis inválidos: %s • Sem permissão essencial: %s • E-mails duplicados: %s • Matrículas duplicadas: %s', invalid_roles, missing_core_permissions, duplicate_emails, duplicate_matriculas)),
    jsonb_build_object('id', 'orphans', 'label', 'Registros órfãos', 'required', true,
      'status', case when orphan_total = 0 then 'pass' else 'fail' end,
      'message', case when orphan_total = 0 then 'Nenhum registro órfão foi identificado.' else format('%s possível(is) registro(s) órfão(s) identificado(s).', orphan_total) end),
    jsonb_build_object('id', 'edge', 'label', 'Edge Function de notificações', 'required', true,
      'status', case when edge_ok then 'pass' else 'fail' end,
      'message', case when edge_ok then 'A Edge Function respondeu ao diagnóstico.' else 'A Edge Function não respondeu ou não foi autenticada.' end),
    jsonb_build_object('id', 'email', 'label', 'Canal de e-mail configurado', 'required', true,
      'status', case when email_configured then 'pass' else 'fail' end,
      'message', case when email_configured then 'O provedor de e-mail está configurado.' else 'A configuração do provedor de e-mail não foi confirmada.' end),
    jsonb_build_object('id', 'https', 'label', 'Hospedagem pública com HTTPS', 'required', true,
      'status', case when production_host then 'pass' else 'pending' end,
      'message', case when production_host then format('Ambiente seguro detectado em %s.', hostname_value) else 'Pendente até o NexLab ser publicado em domínio HTTPS.' end),
    jsonb_build_object('id', 'app_url', 'label', 'URL pública configurada', 'required', true,
      'status', case when app_url_configured then 'pass' else 'pending' end,
      'message', case when app_url_configured then 'VITE_APP_URL está configurada.' else 'A URL pública será definida na publicação.' end),
    jsonb_build_object('id', 'push', 'label', 'Web Push pronto para teste', 'required', true,
      'status', case when production_host and push_configured and service_worker_supported and notification_permission = 'granted' then 'pass' else 'pending' end,
      'message', case when production_host and push_configured and service_worker_supported and notification_permission = 'granted' then 'Web Push disponível neste navegador.' else 'O teste final de Web Push depende de HTTPS e permissão do navegador.' end),
    jsonb_build_object('id', 'manual', 'label', 'Checklist manual de publicação', 'required', true,
      'status', case when manual_required > 0 and manual_completed = manual_required then 'pass' else 'pending' end,
      'message', format('%s de %s itens obrigatórios concluídos.', manual_completed, manual_required)),
    jsonb_build_object('id', 'accounts', 'label', 'Contas que exigem revisão', 'required', false,
      'status', case when incomplete_profiles = 0 and pending_profiles = 0 then 'pass' else 'warning' end,
      'message', format('Incompletas: %s • Pendentes: %s • Inativas: %s • Sem e-mail: %s', incomplete_profiles, pending_profiles, inactive_profiles, missing_email)),
    jsonb_build_object('id', 'cleanup', 'label', 'Candidatos de teste para quarentena', 'required', false,
      'status', case when jsonb_array_length(cleanup_candidates) = 0 then 'pass' else 'warning' end,
      'message', format('%s conta(s) candidata(s) à revisão controlada.', jsonb_array_length(cleanup_candidates)))
  );

  select
    count(*) filter (where coalesce((item->>'required')::boolean, false)),
    count(*) filter (where coalesce((item->>'required')::boolean, false) and item->>'status' = 'pass'),
    count(*) filter (where coalesce((item->>'required')::boolean, false) and item->>'status' = 'fail'),
    count(*) filter (where item->>'status' in ('pending', 'warning'))
  into required_checks, passed_checks, blocking_checks, attention_checks
  from jsonb_array_elements(checks) item;

  score := case
    when required_checks = 0 then 0
    else floor((passed_checks::numeric / required_checks::numeric) * 100)::integer
  end;

  readiness_status := case
    when blocking_checks > 0 then 'blocked'
    when passed_checks = required_checks then 'ready'
    else 'attention'
  end;

  return jsonb_build_object(
    'checked_at', now(),
    'expected_version', expected_version,
    'database_version', current_version,
    'database_release_status', current_release_status,
    'client_context', coalesce(p_client_context, '{}'::jsonb),
    'status', readiness_status,
    'score', score,
    'summary', jsonb_build_object(
      'required_checks', required_checks,
      'passed_checks', passed_checks,
      'blocking_checks', blocking_checks,
      'attention_checks', attention_checks
    ),
    'checks', checks,
    'integrity', jsonb_build_object(
      'profiles', jsonb_build_object(
        'total', total_profiles,
        'incomplete', incomplete_profiles,
        'inactive', inactive_profiles,
        'pending', pending_profiles,
        'invalid_roles', invalid_roles,
        'missing_email', missing_email,
        'missing_core_permissions', missing_core_permissions,
        'duplicate_emails', duplicate_emails,
        'duplicate_matriculas', duplicate_matriculas
      ),
      'orphans', jsonb_build_object(
        'auth_without_profile', auth_without_profile,
        'profile_without_auth', profile_without_auth,
        'notifications', orphan_notifications,
        'deliveries', orphan_deliveries,
        'reminders', orphan_reminders,
        'report_exports', orphan_exports,
        'permission_overrides', orphan_overrides,
        'total', orphan_total
      )
    ),
    'security', jsonb_build_object(
      'rls', rls_details,
      'missing_rls', missing_rls,
      'functions', function_details,
      'missing_functions', missing_functions,
      'triggers', trigger_details,
      'missing_triggers', missing_triggers,
      'cron', cron_details,
      'missing_or_inactive_cron', missing_or_inactive_cron
    ),
    'environment', jsonb_build_object(
      'protocol', protocol_value,
      'hostname', hostname_value,
      'https', https_ok,
      'production_host', production_host,
      'app_url_configured', app_url_configured,
      'edge_function_ok', edge_ok,
      'email_configured', email_configured,
      'push_configured', push_configured,
      'service_worker_supported', service_worker_supported,
      'notification_permission', notification_permission
    ),
    'manual_checklist', manual_checklist,
    'cleanup', jsonb_build_object(
      'candidate_count', jsonb_array_length(cleanup_candidates),
      'candidates', cleanup_candidates,
      'mode', 'quarantine_only',
      'permanent_deletion_enabled', false
    )
  );
end;
$$;

revoke all
on function public.nexlab_get_production_readiness(jsonb)
from public;

grant execute
on function public.nexlab_get_production_readiness(jsonb)
to authenticated;

-- -----------------------------------------------------------------------------
-- 5. Registro auditável de um diagnóstico
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_record_production_snapshot(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  readiness jsonb;
  snapshot_id uuid;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.'
      using errcode = '42501';
  end if;

  readiness := public.nexlab_get_production_readiness(
    coalesce(p_client_context, '{}'::jsonb)
  );

  insert into public.nexlab_production_snapshots (
    app_version,
    readiness_status,
    score,
    client_context,
    snapshot,
    created_by
  )
  values (
    coalesce(readiness->>'database_version', '25.14.0'),
    readiness->>'status',
    coalesce((readiness->>'score')::integer, 0),
    coalesce(p_client_context, '{}'::jsonb),
    readiness,
    auth.uid()
  )
  returning id into snapshot_id;

  perform public.nexlab_record_system_event(
    'production_readiness_snapshot',
    case when readiness->>'status' = 'ready' then 'success' else 'warning' end,
    format('Diagnóstico de prontidão registrado com pontuação %s%%.', readiness->>'score'),
    jsonb_build_object(
      'snapshot_id', snapshot_id,
      'status', readiness->>'status',
      'score', readiness->>'score'
    )
  );

  return jsonb_build_object(
    'ok', true,
    'snapshot_id', snapshot_id,
    'readiness', readiness
  );
end;
$$;

revoke all
on function public.nexlab_record_production_snapshot(jsonb)
from public;

grant execute
on function public.nexlab_record_production_snapshot(jsonb)
to authenticated;

-- -----------------------------------------------------------------------------
-- 6. Quarentena controlada de contas de teste
--    Não exclui auth.users, perfis, históricos ou dados operacionais concluídos.
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_quarantine_test_profiles(
  p_user_ids text[],
  p_confirmation text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  target_id text;
  target_profile record;
  affected_profiles integer := 0;
  removed_push integer := 0;
  removed_deliveries integer := 0;
  removed_reminders integer := 0;
  removed_overrides integer := 0;
  row_count_value integer := 0;
  skipped jsonb := '[]'::jsonb;
  cleanup_id uuid;
  safe_candidate boolean;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.'
      using errcode = '42501';
  end if;

  if btrim(coalesce(p_confirmation, '')) <> 'DESATIVAR CONTAS DE TESTE' then
    raise exception 'Digite exatamente DESATIVAR CONTAS DE TESTE para confirmar.'
      using errcode = '22023';
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Informe o motivo da quarentena.'
      using errcode = '22023';
  end if;

  if coalesce(array_length(p_user_ids, 1), 0) = 0 then
    raise exception 'Selecione pelo menos uma conta candidata.'
      using errcode = '22023';
  end if;

  foreach target_id in array p_user_ids
  loop
    select
      p.id,
      p.nome,
      p.email,
      p.matricula,
      p.role::text as role,
      p.ativo,
      p.cadastro_completo,
      p.created_at
    into target_profile
    from public.profiles p
    where p.id::text = target_id
    for update;

    if target_profile.id is null then
      skipped := skipped || jsonb_build_array(
        jsonb_build_object('user_id', target_id, 'reason', 'Usuário não encontrado')
      );
      continue;
    end if;

    if target_id = auth.uid()::text then
      skipped := skipped || jsonb_build_array(
        jsonb_build_object('user_id', target_id, 'reason', 'O Administrador atual não pode ser colocado em quarentena')
      );
      continue;
    end if;

    if lower(coalesce(target_profile.role, '')) in ('admin', 'administrador') then
      skipped := skipped || jsonb_build_array(
        jsonb_build_object('user_id', target_id, 'reason', 'Contas administrativas são protegidas')
      );
      continue;
    end if;

    safe_candidate :=
      lower(coalesce(target_profile.nome, '')) ~ '(teste|test|demo|dummy|sandbox|homolog)'
      or lower(coalesce(target_profile.email, '')) ~ '(teste|test|demo|dummy|sandbox|homolog)'
      or lower(coalesce(target_profile.matricula, '')) ~ '(teste|test|demo|dummy|sandbox|homolog)'
      or (not coalesce(target_profile.cadastro_completo, false) and target_profile.created_at < now() - interval '30 days')
      or (not coalesce(target_profile.ativo, true) and target_profile.created_at < now() - interval '30 days');

    if not safe_candidate then
      skipped := skipped || jsonb_build_array(
        jsonb_build_object('user_id', target_id, 'reason', 'A conta não atende aos critérios seguros de teste ou inatividade antiga')
      );
      continue;
    end if;

    update public.profiles
    set
      ativo = false,
      account_status_reason = btrim(p_reason),
      account_status_changed_at = now(),
      account_status_changed_by = auth.uid()
    where id::text = target_id;

    affected_profiles := affected_profiles + 1;

    if to_regclass('public.push_subscriptions') is not null then
      execute 'delete from public.push_subscriptions where user_id::text = $1'
      using target_id;
      get diagnostics row_count_value = row_count;
      removed_push := removed_push + row_count_value;
    end if;

    if to_regclass('public.notification_deliveries') is not null then
      execute 'delete from public.notification_deliveries where recipient_id::text = $1 and status in (''pending'', ''processing'', ''failed'')'
      using target_id;
      get diagnostics row_count_value = row_count;
      removed_deliveries := removed_deliveries + row_count_value;
    end if;

    if to_regclass('public.notification_reminders') is not null then
      execute 'delete from public.notification_reminders where recipient_id::text = $1 and status in (''pending'', ''failed'')'
      using target_id;
      get diagnostics row_count_value = row_count;
      removed_reminders := removed_reminders + row_count_value;
    end if;

    if to_regclass('public.nexlab_user_permission_overrides') is not null then
      execute 'delete from public.nexlab_user_permission_overrides where user_id::text = $1'
      using target_id;
      get diagnostics row_count_value = row_count;
      removed_overrides := removed_overrides + row_count_value;
    end if;
  end loop;

  insert into public.nexlab_test_cleanup_runs (
    action,
    requested_profile_ids,
    affected_profiles,
    removed_push_subscriptions,
    removed_pending_deliveries,
    removed_pending_reminders,
    removed_permission_overrides,
    skipped,
    reason,
    created_by
  )
  values (
    'quarantine',
    to_jsonb(p_user_ids),
    affected_profiles,
    removed_push,
    removed_deliveries,
    removed_reminders,
    removed_overrides,
    skipped,
    btrim(p_reason),
    auth.uid()
  )
  returning id into cleanup_id;

  perform public.nexlab_record_system_event(
    'test_profiles_quarantined',
    case when affected_profiles > 0 then 'success' else 'warning' end,
    format('%s conta(s) de teste foram colocadas em quarentena.', affected_profiles),
    jsonb_build_object(
      'cleanup_id', cleanup_id,
      'affected_profiles', affected_profiles,
      'removed_push_subscriptions', removed_push,
      'removed_pending_deliveries', removed_deliveries,
      'removed_pending_reminders', removed_reminders,
      'removed_permission_overrides', removed_overrides,
      'skipped', skipped,
      'reason', btrim(p_reason)
    )
  );

  return jsonb_build_object(
    'ok', true,
    'cleanup_id', cleanup_id,
    'affected_profiles', affected_profiles,
    'removed_push_subscriptions', removed_push,
    'removed_pending_deliveries', removed_deliveries,
    'removed_pending_reminders', removed_reminders,
    'removed_permission_overrides', removed_overrides,
    'skipped', skipped,
    'permanent_deletion', false
  );
end;
$$;

revoke all
on function public.nexlab_quarantine_test_profiles(text[], text, text)
from public;

grant execute
on function public.nexlab_quarantine_test_profiles(text[], text, text)
to authenticated;

-- -----------------------------------------------------------------------------
-- 7. Registro da versão e recarga do schema
-- -----------------------------------------------------------------------------

update public.nexlab_app_versions
set
  release_status = 'stable',
  notes = 'Versão testada e aprovada. Governança e histórico de exportações validados.'
where version = '25.13.0';

insert into public.nexlab_app_versions (
  version,
  title,
  release_status,
  notes
)
values (
  '25.14.0',
  'Integridade e Preparação para Produção',
  'rc',
  'Diagnóstico de integridade, verificação de RLS/RPCs/triggers/Cron, checklist final, registro de ambiente e quarentena controlada de contas de teste.'
)
on conflict (version) do update
set
  title = excluded.title,
  release_status = excluded.release_status,
  notes = excluded.notes,
  installed_at = now(),
  installed_by = auth.uid();

notify pgrst, 'reload schema';

commit;
