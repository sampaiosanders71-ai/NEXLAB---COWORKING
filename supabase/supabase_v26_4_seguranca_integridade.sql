-- NEXLAB v26.4 — Segurança, RLS, RPCs, integridade e índices
-- Execute no Supabase Dashboard:
-- SQL Editor > New query > cole todo este conteúdo > Run.
--
-- A migration é idempotente:
-- - pode ser executada novamente;
-- - não apaga registros;
-- - não substitui policies existentes;
-- - habilita RLS somente em tabelas que já possuem pelo menos uma policy;
-- - cria índices somente quando tabelas e colunas existem;
-- - cria índices únicos somente quando não existem duplicidades.

begin;

-- -------------------------------------------------------------------
-- 1. Verificação administrativa central
-- -------------------------------------------------------------------
create or replace function public.nexlab_current_user_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
  select exists (
    select 1
      from public.profiles p
     where p.id = auth.uid()
       and lower(coalesce(p.role, '')) in ('admin', 'administrador')
       and coalesce(p.ativo, true)
  );
$$;

revoke all on function public.nexlab_current_user_is_admin() from public;
revoke all on function public.nexlab_current_user_is_admin() from anon;
grant execute on function public.nexlab_current_user_is_admin() to authenticated;

-- -------------------------------------------------------------------
-- 2. Endurecimento do search_path das RPCs SECURITY DEFINER usadas
--    pelo NEXLAB. Evita resolução insegura de objetos por search_path.
-- -------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and p.proname = any (array[
         'admin_cleanup_system_data',
         'admin_create_channel_test',
         'admin_delete_activity_logs',
         'admin_delete_operational_record',
         'admin_requeue_notification_queue',
         'admin_run_due_reminders',
         'cancel_reservation_secure',
         'create_test_notification',
         'delete_user_notifications',
         'disable_push_subscription',
         'get_notification_metrics',
         'get_system_health_snapshot',
         'mark_all_notifications_read',
         'mark_notification_read',
         'nexlab_accept_required_documents',
         'nexlab_admin_manage_profile',
         'nexlab_admin_restore_user_permissions',
         'nexlab_admin_save_role_permissions',
         'nexlab_admin_save_user_permissions',
         'nexlab_cancel_own_profile_request',
         'nexlab_complete_profile_registration',
         'nexlab_ensure_notification_preferences',
         'nexlab_ensure_notification_user_settings',
         'nexlab_export_sensitive_user_report',
         'nexlab_get_permission_matrix',
         'nexlab_get_privacy_status',
         'nexlab_get_production_readiness',
         'nexlab_get_report_export_history',
         'nexlab_list_data_requests',
         'nexlab_manage_data_request',
         'nexlab_quarantine_test_profiles',
         'nexlab_record_production_snapshot',
         'nexlab_record_report_export',
         'nexlab_resubmit_own_profile_request',
         'nexlab_review_profile_request',
         'nexlab_set_optional_consent',
         'nexlab_submit_data_request',
         'nexlab_update_own_profile',
         'nexlab_update_production_check',
         'nexlab_update_profile_avatar',
         'nexlab_upsert_own_sensitive_profile',
         'notification_bulk_action',
         'record_security_audit',
         'replace_meeting_participants',
         'replace_reservation_participants',
         'retry_notification_delivery',
         'save_push_subscription',
         'nexlab_current_user_is_admin'
       ])
  loop
    execute format(
      'alter function %s set search_path = public, auth, extensions, pg_temp',
      r.signature
    );
  end loop;
end
$$;

-- -------------------------------------------------------------------
-- 3. RPCs sensíveis não podem ser executadas por visitante anônimo.
--    A autorização administrativa continua sendo validada dentro das
--    próprias funções.
-- -------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (
         p.proname like 'admin\_%' escape '\'
         or p.proname like 'nexlab\_admin\_%' escape '\'
         or p.proname = any (array[
           'nexlab_export_sensitive_user_report',
           'nexlab_manage_data_request',
           'nexlab_quarantine_test_profiles',
           'nexlab_record_production_snapshot',
           'nexlab_update_production_check',
           'get_system_health_snapshot',
           'get_notification_metrics',
           'retry_notification_delivery'
         ])
       )
  loop
    execute format('revoke execute on function %s from public', r.signature);
    execute format('revoke execute on function %s from anon', r.signature);
    execute format('grant execute on function %s to authenticated', r.signature);
  end loop;
end
$$;

-- -------------------------------------------------------------------
-- 4. Perfis: impedir elevação de privilégio por DML direto.
--    O app já usa RPCs controladas para cadastro, perfil e aprovação.
-- -------------------------------------------------------------------
do $$
begin
  if to_regclass('public.profiles') is not null then
    revoke insert, update, delete on table public.profiles from anon;
    revoke insert, update, delete on table public.profiles from authenticated;
  end if;
end
$$;

-- Visitantes não autenticados não precisam acessar tabelas técnicas.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'logs',
    'security_audit_logs',
    'nexlab_system_events',
    'nexlab_system_settings',
    'nexlab_app_versions',
    'notification_deliveries',
    'notification_templates'
  ]
  loop
    if to_regclass(format('public.%I', v_table)) is not null then
      execute format('revoke all on table public.%I from anon', v_table);
    end if;
  end loop;
end
$$;

-- -------------------------------------------------------------------
-- 5. Habilitar RLS quando policies já existem, mas a tabela está com
--    RLS desligado. Tabelas sem policy não são alteradas automaticamente.
-- -------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select c.oid::regclass as relation_name
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
       and not c.relrowsecurity
       and exists (
         select 1
           from pg_policy pol
          where pol.polrelid = c.oid
       )
  loop
    execute format('alter table %s enable row level security', r.relation_name);
  end loop;
end
$$;

-- -------------------------------------------------------------------
-- 6. Índices de uso frequente.
--    Cada índice só é criado quando a tabela e todas as colunas existem.
-- -------------------------------------------------------------------
do $$
declare
  r record;
  v_missing boolean;
  v_column text;
begin
  for r in
    select *
      from (
        values
          ('idx_nexlab_notifications_recipient_created', 'notifications',
            array['recipient_id','created_at']::text[], 'recipient_id, created_at desc', null),
          ('idx_nexlab_notifications_recipient_state', 'notifications',
            array['recipient_id','is_read','archived_at','created_at']::text[],
            'recipient_id, is_read, archived_at, created_at desc', null),
          ('idx_nexlab_notification_deliveries_notification', 'notification_deliveries',
            array['notification_id']::text[], 'notification_id', null),
          ('idx_nexlab_notification_deliveries_queue', 'notification_deliveries',
            array['channel','status','next_attempt_at','created_at']::text[],
            'channel, status, next_attempt_at, created_at', null),
          ('idx_nexlab_profiles_role_active', 'profiles',
            array['role','ativo']::text[], 'role, ativo', null),
          ('idx_nexlab_profiles_request_status', 'profiles',
            array['role_request_status','role_request_created_at']::text[],
            'role_request_status, role_request_created_at desc', null),
          ('idx_nexlab_projects_status_created', 'projects',
            array['status','created_at']::text[], 'status, created_at desc', null),
          ('idx_nexlab_projects_responsavel_created', 'projects',
            array['responsavel_id','created_at']::text[], 'responsavel_id, created_at desc', null),
          ('idx_nexlab_project_tasks_project_created', 'project_tasks',
            array['project_id','created_at']::text[], 'project_id, created_at', null),
          ('idx_nexlab_reservations_date_status', 'reservations',
            array['data','status']::text[], 'data, status', null),
          ('idx_nexlab_reservations_user_date', 'reservations',
            array['usuario_id','data']::text[], 'usuario_id, data desc', null),
          ('idx_nexlab_meetings_date_status', 'meetings',
            array['data','status']::text[], 'data, status', null),
          ('idx_nexlab_events_date', 'events',
            array['data']::text[], 'data', null),
          ('idx_nexlab_marketing_date_status', 'marketing',
            array['data','status']::text[], 'data, status', null),
          ('idx_nexlab_marketing_responsavel_created', 'marketing',
            array['responsavel_id','created_at']::text[], 'responsavel_id, created_at desc', null),
          ('idx_nexlab_marketing_dates_date', 'marketing_dates',
            array['data']::text[], 'data', null),
          ('idx_nexlab_board_posts_fixed_created', 'board_posts',
            array['fixado','created_at']::text[], 'fixado desc, created_at desc', null),
          ('idx_nexlab_feedback_status_created', 'feedback',
            array['status','created_at']::text[], 'status, created_at desc', null),
          ('idx_nexlab_teams_leader_created', 'teams',
            array['lider_id','created_at']::text[], 'lider_id, created_at desc', null),
          ('idx_nexlab_logs_created', 'logs',
            array['created_at']::text[], 'created_at desc', null),
          ('idx_nexlab_security_logs_created', 'security_audit_logs',
            array['created_at']::text[], 'created_at desc', null),
          ('idx_nexlab_security_logs_actor', 'security_audit_logs',
            array['actor_user_id','created_at']::text[], 'actor_user_id, created_at desc', null),
          ('idx_nexlab_security_logs_target', 'security_audit_logs',
            array['target_user_id','created_at']::text[], 'target_user_id, created_at desc', null)
      ) as indexes(index_name, table_name, required_columns, definition, predicate)
  loop
    if to_regclass(format('public.%I', r.table_name)) is null then
      continue;
    end if;

    v_missing := false;
    foreach v_column in array r.required_columns
    loop
      if not exists (
        select 1
          from information_schema.columns c
         where c.table_schema = 'public'
           and c.table_name = r.table_name
           and c.column_name = v_column
      ) then
        v_missing := true;
        exit;
      end if;
    end loop;

    if not v_missing then
      execute format(
        'create index if not exists %I on public.%I (%s)%s',
        r.index_name,
        r.table_name,
        r.definition,
        case
          when r.predicate is null then ''
          else format(' where %s', r.predicate)
        end
      );
    end if;
  end loop;
end
$$;

-- -------------------------------------------------------------------
-- 7. Proteções contra registros duplicados.
--    O índice único é criado somente se os dados atuais não possuem
--    duplicidades.
-- -------------------------------------------------------------------
do $$
declare
  r record;
  v_missing boolean;
  v_column text;
  v_has_duplicates boolean;
begin
  for r in
    select *
      from (
        values
          ('uq_nexlab_team_members_pair', 'team_members',
            array['team_id','user_id']::text[], 'team_id, user_id'),
          ('uq_nexlab_meeting_participants_pair', 'meeting_participants',
            array['meeting_id','user_id']::text[], 'meeting_id, user_id'),
          ('uq_nexlab_reservation_participants_pair', 'reservation_participants',
            array['reservation_id','user_id']::text[], 'reservation_id, user_id'),
          ('uq_nexlab_notification_preferences_pair', 'notification_preferences',
            array['user_id','notification_type']::text[], 'user_id, notification_type'),
          ('uq_nexlab_notification_user_settings_user', 'notification_user_settings',
            array['user_id']::text[], 'user_id')
      ) as unique_indexes(index_name, table_name, required_columns, definition)
  loop
    if to_regclass(format('public.%I', r.table_name)) is null then
      continue;
    end if;

    v_missing := false;
    foreach v_column in array r.required_columns
    loop
      if not exists (
        select 1
          from information_schema.columns c
         where c.table_schema = 'public'
           and c.table_name = r.table_name
           and c.column_name = v_column
      ) then
        v_missing := true;
        exit;
      end if;
    end loop;

    if v_missing then
      continue;
    end if;

    execute format(
      'select exists (
         select 1
           from public.%I
          group by %s
         having count(*) > 1
       )',
      r.table_name,
      r.definition
    )
    into v_has_duplicates;

    if not v_has_duplicates then
      execute format(
        'create unique index if not exists %I on public.%I (%s)',
        r.index_name,
        r.table_name,
        r.definition
      );
    end if;
  end loop;
end
$$;

-- -------------------------------------------------------------------
-- 8. Diagnóstico de segurança usado pela Saúde do Sistema.
-- -------------------------------------------------------------------
create or replace function public.nexlab_security_audit_v26_4()
returns table (
  category text,
  object_name text,
  status text,
  severity text,
  details jsonb
)
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  v_table text;
  v_oid oid;
  v_rls boolean;
  v_policy_count integer;
  v_anon_select boolean;
  v_sensitive_tables constant text[] := array[
    'logs',
    'security_audit_logs',
    'nexlab_system_events',
    'nexlab_system_settings',
    'nexlab_app_versions',
    'notification_deliveries',
    'notification_templates'
  ];
  v_index text;
  v_duplicate_count bigint;
  r record;
begin
  if not public.nexlab_current_user_is_admin() then
    raise exception 'Acesso restrito ao Administrador do NEXLAB.'
      using errcode = '42501';
  end if;

  foreach v_table in array array[
    'profiles',
    'projects',
    'project_tasks',
    'teams',
    'team_members',
    'assets',
    'reservations',
    'meetings',
    'meeting_participants',
    'reservation_participants',
    'events',
    'marketing',
    'marketing_dates',
    'board_posts',
    'feedback',
    'notifications',
    'notification_deliveries',
    'notification_preferences',
    'notification_user_settings',
    'logs',
    'security_audit_logs',
    'nexlab_system_settings',
    'nexlab_system_events',
    'nexlab_app_versions'
  ]
  loop
    select c.oid, c.relrowsecurity
      into v_oid, v_rls
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname = v_table
       and c.relkind in ('r', 'p');

    if v_oid is null then
      category := 'RLS';
      object_name := v_table;
      status := 'not_applicable';
      severity := 'info';
      details := jsonb_build_object('message', 'Tabela não existe neste ambiente.');
      return next;
      continue;
    end if;

    select count(*)
      into v_policy_count
      from pg_policy p
     where p.polrelid = v_oid;

    category := 'RLS';
    object_name := v_table;
    status := case
      when v_rls and v_policy_count > 0 then 'pass'
      when v_rls and v_policy_count = 0 then 'critical'
      when not v_rls and v_policy_count > 0 then 'critical'
      else 'critical'
    end;
    severity := case when status = 'pass' then 'info' else 'critical' end;
    details := jsonb_build_object(
      'rls_enabled', v_rls,
      'policy_count', v_policy_count,
      'message', case
        when v_rls and v_policy_count > 0 then 'RLS habilitado e com policies.'
        when v_rls and v_policy_count = 0 then 'RLS habilitado, mas nenhuma policy foi encontrada.'
        when not v_rls and v_policy_count > 0 then 'Existem policies, mas o RLS está desligado.'
        else 'Tabela sem RLS e sem policies.'
      end
    );
    return next;

    if v_table = any(v_sensitive_tables) then
      v_anon_select := has_table_privilege('anon', v_oid, 'SELECT');

      category := 'Anonymous access';
      object_name := v_table;
      status := case when v_anon_select then 'warning' else 'pass' end;
      severity := case when v_anon_select then 'warning' else 'info' end;
      details := jsonb_build_object(
        'anon_select', v_anon_select,
        'message', case
          when v_anon_select then 'A role anon possui SELECT direto nesta tabela técnica.'
          else 'A role anon não possui SELECT direto.'
        end
      );
      return next;
    end if;

    v_oid := null;
  end loop;

  foreach v_index in array array[
    'idx_nexlab_notifications_recipient_created',
    'idx_nexlab_notifications_recipient_state',
    'idx_nexlab_notification_deliveries_notification',
    'idx_nexlab_notification_deliveries_queue',
    'idx_nexlab_profiles_role_active',
    'idx_nexlab_profiles_request_status',
    'idx_nexlab_projects_status_created',
    'idx_nexlab_projects_responsavel_created',
    'idx_nexlab_project_tasks_project_created',
    'idx_nexlab_reservations_date_status',
    'idx_nexlab_reservations_user_date',
    'idx_nexlab_meetings_date_status',
    'idx_nexlab_events_date',
    'idx_nexlab_marketing_date_status',
    'idx_nexlab_marketing_responsavel_created',
    'idx_nexlab_marketing_dates_date',
    'idx_nexlab_board_posts_fixed_created',
    'idx_nexlab_feedback_status_created',
    'idx_nexlab_teams_leader_created',
    'idx_nexlab_logs_created',
    'idx_nexlab_security_logs_created'
  ]
  loop
    category := 'Index';
    object_name := v_index;
    status := case when to_regclass(format('public.%I', v_index)) is null then 'warning' else 'pass' end;
    severity := case when status = 'pass' then 'info' else 'warning' end;
    details := jsonb_build_object(
      'exists', to_regclass(format('public.%I', v_index)) is not null
    );
    return next;
  end loop;

  for r in
    select p.oid,
           p.oid::regprocedure::text as signature,
           p.proname,
           p.prosecdef,
           array_to_string(p.proconfig, ',') as configuration
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
  loop
    category := 'SECURITY DEFINER';
    object_name := r.signature;
    status := case
      when coalesce(r.configuration, '') ilike '%search_path=public, auth, extensions, pg_temp%'
        or coalesce(r.configuration, '') ilike '%search_path=public,auth,extensions,pg_temp%'
      then 'pass'
      else 'warning'
    end;
    severity := case when status = 'pass' then 'info' else 'warning' end;
    details := jsonb_build_object(
      'search_path', r.configuration,
      'message', case
        when status = 'pass' then 'search_path fixado.'
        else 'Função SECURITY DEFINER sem o search_path esperado pela v26.4.'
      end
    );
    return next;
  end loop;

  for r in
    select p.oid,
           p.oid::regprocedure::text as signature
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (
         p.proname like 'admin\_%' escape '\'
         or p.proname like 'nexlab\_admin\_%' escape '\'
         or p.proname = any (array[
           'nexlab_export_sensitive_user_report',
           'nexlab_manage_data_request',
           'nexlab_quarantine_test_profiles',
           'nexlab_record_production_snapshot',
           'nexlab_update_production_check',
           'get_system_health_snapshot',
           'get_notification_metrics',
           'retry_notification_delivery'
         ])
       )
  loop
    category := 'RPC permission';
    object_name := r.signature;
    status := case
      when has_function_privilege('anon', r.oid, 'EXECUTE') then 'critical'
      else 'pass'
    end;
    severity := case when status = 'pass' then 'info' else 'critical' end;
    details := jsonb_build_object(
      'anon_execute', has_function_privilege('anon', r.oid, 'EXECUTE')
    );
    return next;
  end loop;

  if to_regclass('public.team_members') is not null then
    execute '
      select count(*)
        from (
          select team_id, user_id
            from public.team_members
           group by team_id, user_id
          having count(*) > 1
        ) d'
      into v_duplicate_count;

    category := 'Integrity';
    object_name := 'team_members(team_id,user_id)';
    status := case when v_duplicate_count = 0 then 'pass' else 'critical' end;
    severity := case when v_duplicate_count = 0 then 'info' else 'critical' end;
    details := jsonb_build_object('duplicate_groups', v_duplicate_count);
    return next;
  end if;

  if to_regclass('public.meeting_participants') is not null then
    execute '
      select count(*)
        from (
          select meeting_id, user_id
            from public.meeting_participants
           group by meeting_id, user_id
          having count(*) > 1
        ) d'
      into v_duplicate_count;

    category := 'Integrity';
    object_name := 'meeting_participants(meeting_id,user_id)';
    status := case when v_duplicate_count = 0 then 'pass' else 'critical' end;
    severity := case when v_duplicate_count = 0 then 'info' else 'critical' end;
    details := jsonb_build_object('duplicate_groups', v_duplicate_count);
    return next;
  end if;

  if to_regclass('public.reservation_participants') is not null then
    execute '
      select count(*)
        from (
          select reservation_id, user_id
            from public.reservation_participants
           group by reservation_id, user_id
          having count(*) > 1
        ) d'
      into v_duplicate_count;

    category := 'Integrity';
    object_name := 'reservation_participants(reservation_id,user_id)';
    status := case when v_duplicate_count = 0 then 'pass' else 'critical' end;
    severity := case when v_duplicate_count = 0 then 'info' else 'critical' end;
    details := jsonb_build_object('duplicate_groups', v_duplicate_count);
    return next;
  end if;

  for r in
    select format('%I.%I', n.nspname, c.relname) as table_name,
           con.conname
      from pg_constraint con
      join pg_class c on c.oid = con.conrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and con.contype in ('f', 'c')
       and not con.convalidated
  loop
    category := 'Constraint';
    object_name := r.table_name || '.' || r.conname;
    status := 'warning';
    severity := 'warning';
    details := jsonb_build_object(
      'message', 'Constraint existente ainda não foi validada para todos os registros antigos.'
    );
    return next;
  end loop;
end;
$$;

revoke all on function public.nexlab_security_audit_v26_4() from public;
revoke all on function public.nexlab_security_audit_v26_4() from anon;
grant execute on function public.nexlab_security_audit_v26_4() to authenticated;

-- -------------------------------------------------------------------
-- 9. Registro da versão, quando a tabela de versões estiver disponível.
-- -------------------------------------------------------------------
do $$
begin
  if to_regclass('public.nexlab_app_versions') is not null
     and exists (
       select 1 from information_schema.columns
        where table_schema = 'public'
          and table_name = 'nexlab_app_versions'
          and column_name = 'version'
     )
     and exists (
       select 1 from information_schema.columns
        where table_schema = 'public'
          and table_name = 'nexlab_app_versions'
          and column_name = 'title'
     )
  then
    insert into public.nexlab_app_versions (
      version,
      title,
      release_status,
      notes,
      installed_at
    )
    select
      '26.4',
      'Segurança, RLS e Integridade',
      'stable',
      'Endurecimento de RPCs, diagnóstico RLS, índices e proteções contra duplicidade.',
      now()
    where not exists (
      select 1
        from public.nexlab_app_versions
       where version = '26.4'
    );
  end if;
end
$$;

commit;
