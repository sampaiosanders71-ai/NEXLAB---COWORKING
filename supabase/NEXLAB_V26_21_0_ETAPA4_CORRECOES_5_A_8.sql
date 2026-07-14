-- NEXLAB v26.21.0 — Etapa 4, correções 5 a 8
-- Já aplicado no projeto eahldhabwulnwhuwrhvc.
-- Não executar novamente no projeto atual.

-- 1. Registro oficial das versões.
insert into public.nexlab_app_versions(
  version,title,release_status,notes,installed_at,installed_by
) values
  ('26.17.1','Segurança de Notificações e Saúde','stable','Privilégios mínimos, cadeia de auditoria e políticas técnicas consolidadas.',now(),null),
  ('26.17.3','Canal de E-mail Suspenso','stable','Canal de e-mail retirado da operação e dos critérios técnicos.',now(),null),
  ('26.17.4','Fila Push, Telemetria e Alertas','stable','Estado terminal da fila, telemetria persistente e alertas operacionais.',now(),null),
  ('26.18.0','Preferências e Tipos de Reunião','stable','Política interna, silenciamento Push e tipos específicos de reunião.',now(),null),
  ('26.19.0','Central e Navegação de Notificações','stable','Navegação exata, destinatários completos, paginação e contadores.',now(),null),
  ('26.20.0','Saúde e Observabilidade','stable','Carregamento resiliente, auditoria e incidentes do frontend.',now(),null),
  ('26.21.0','Prontidão Operacional Atualizada','stable','Prontidão baseada no estado técnico real e snapshots versionados com validade.',now(),null)
on conflict (version) do update
set title=excluded.title,
    release_status=excluded.release_status,
    notes=excluded.notes,
    installed_at=excluded.installed_at;

-- 2. Prontidão reconstruída conforme a arquitetura atual.
create or replace function public.nexlab_get_production_readiness(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, cron, pg_temp
as $$
declare
  v_expected_version text;
  v_release_status text;
  v_client_version text := coalesce(nullif(p_client_context->>'client_app_version',''),'não informado');
  v_protocol text := coalesce(p_client_context->>'protocol','');
  v_hostname text := coalesce(p_client_context->>'hostname','');
  v_href text := coalesce(p_client_context->>'href','');
  v_production_host boolean := false;
  v_app_url_ok boolean := false;
  v_checks jsonb := '[]'::jsonb;
  v_required integer := 0;
  v_passed integer := 0;
  v_blocking integer := 0;
  v_attention integer := 0;
  v_score integer := 0;
  v_status text := 'attention';
  v_missing_rls integer := 0;
  v_missing_functions integer := 0;
  v_missing_triggers integer := 0;
  v_missing_cron integer := 0;
  v_rls_details jsonb := '[]'::jsonb;
  v_function_details jsonb := '[]'::jsonb;
  v_trigger_details jsonb := '[]'::jsonb;
  v_cron_details jsonb := '[]'::jsonb;
  v_total_profiles integer := 0;
  v_incomplete_profiles integer := 0;
  v_inactive_profiles integer := 0;
  v_pending_profiles integer := 0;
  v_invalid_roles integer := 0;
  v_missing_core_permissions integer := 0;
  v_duplicate_emails integer := 0;
  v_duplicate_matriculas integer := 0;
  v_orphan_notifications integer := 0;
  v_orphan_deliveries integer := 0;
  v_orphan_reminders integer := 0;
  v_orphan_total integer := 0;
  v_audit jsonb := '{}'::jsonb;
  v_push_valid boolean := false;
  v_push_operational boolean := false;
  v_push_status text := 'unknown';
  v_push_reason text;
  v_latest_worker timestamptz;
  v_latest_worker_status text;
  v_latest_worker_http integer;
  v_active_critical integer := 0;
  v_active_errors integer := 0;
  v_cleanup_candidates jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;

  select version,release_status
  into v_expected_version,v_release_status
  from public.nexlab_app_versions
  order by string_to_array(version,'.')::integer[] desc
  limit 1;

  v_production_host := v_protocol='https:'
    and v_hostname not in ('','localhost','127.0.0.1','::1')
    and v_hostname !~ '^192\.168\.';
  v_app_url_ok := v_production_host and v_href like 'https://%';

  select
    count(*),
    count(*) filter(where not coalesce(profile.cadastro_completo,false)),
    count(*) filter(where not coalesce(profile.ativo,true)),
    count(*) filter(where profile.role_request_status='pending'),
    count(*) filter(where lower(coalesce(profile.role::text,'')) not in (
      'admin','administrador','coordenador','bolsista','coworking_junior'
    )),
    count(*) filter(
      where coalesce(profile.cadastro_completo,false)
        and coalesce(profile.ativo,true)
        and not ('module_perfil'=any(coalesce(profile.effective_permissions,'{}'::text[])))
    )
  into v_total_profiles,v_incomplete_profiles,v_inactive_profiles,
       v_pending_profiles,v_invalid_roles,v_missing_core_permissions
  from public.profiles profile;

  select count(*) into v_duplicate_emails
  from (
    select lower(btrim(email))
    from public.profiles
    where nullif(btrim(coalesce(email,'')),'') is not null
    group by lower(btrim(email))
    having count(*)>1
  ) duplicated;

  select count(*) into v_duplicate_matriculas
  from (
    select lower(btrim(matricula))
    from public.profiles
    where nullif(btrim(coalesce(matricula,'')),'') is not null
    group by lower(btrim(matricula))
    having count(*)>1
  ) duplicated;

  select count(*) into v_orphan_notifications
  from public.notifications notification
  left join public.profiles profile on profile.id=notification.recipient_id
  where profile.id is null;

  select count(*) into v_orphan_deliveries
  from public.notification_deliveries delivery
  left join public.profiles profile on profile.id=delivery.recipient_id
  where profile.id is null;

  select count(*) into v_orphan_reminders
  from public.notification_reminders reminder
  left join public.profiles profile on profile.id=reminder.recipient_id
  where profile.id is null;

  v_orphan_total := v_orphan_notifications+v_orphan_deliveries+v_orphan_reminders;

  with expected(table_name) as (
    values
      ('profiles'),('notifications'),('notification_deliveries'),
      ('notification_reminders'),('push_subscriptions'),
      ('nexlab_notification_provider_health'),('nexlab_notification_worker_runs'),
      ('security_audit_logs'),('nexlab_client_errors'),
      ('nexlab_client_error_incidents'),('nexlab_app_versions'),
      ('nexlab_production_snapshots'),('nexlab_system_events'),
      ('nexlab_system_settings')
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'table',expected.table_name,
      'exists',relation.oid is not null,
      'rls_enabled',coalesce(relation.relrowsecurity,false),
      'policy_count',coalesce((
        select count(*) from pg_policies policy
        where policy.schemaname='public' and policy.tablename=expected.table_name
      ),0)
    ) order by expected.table_name),'[]'::jsonb),
    count(*) filter(where relation.oid is null or not coalesce(relation.relrowsecurity,false))
  into v_rls_details,v_missing_rls
  from expected
  left join pg_class relation
    on relation.oid=to_regclass(format('public.%I',expected.table_name));

  with expected(label,signature) as (
    values
      ('Saúde do sistema','public.get_system_health_snapshot()'),
      ('Prontidão atual','public.nexlab_get_production_readiness(jsonb)'),
      ('Observabilidade','public.nexlab_get_health_observability_v26200(integer,text)'),
      ('Cadeia de auditoria','public.nexlab_verify_security_audit_chain(integer)'),
      ('Central de notificações','public.nexlab_list_notifications_v26190(text,text,text,integer,integer)'),
      ('Resumo de notificações','public.nexlab_notification_summary_v26190(integer)'),
      ('Processamento de lembretes','public.nexlab_process_due_reminders(integer)'),
      ('Registro de snapshot','public.nexlab_record_production_snapshot(jsonb)')
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'label',expected.label,
      'signature',expected.signature,
      'exists',to_regprocedure(expected.signature) is not null
    ) order by expected.label),'[]'::jsonb),
    count(*) filter(where to_regprocedure(expected.signature) is null)
  into v_function_details,v_missing_functions
  from expected;

  with expected(trigger_name) as (
    values
      ('notifications_normalize_before_write'),
      ('notifications_exact_target_v26190'),
      ('notifications_enqueue_external_delivery'),
      ('nexlab_client_errors_sync_incident_v26200'),
      ('meetings_notify_changes_v26180'),
      ('meetings_notify_audience_v26190'),
      ('nexlab_block_security_audit_mutation')
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'trigger',expected.trigger_name,
      'exists',trigger.oid is not null,
      'enabled',coalesce(trigger.tgenabled in ('O','A'),false),
      'table',case when trigger.oid is not null then trigger.tgrelid::regclass::text end
    ) order by expected.trigger_name),'[]'::jsonb),
    count(*) filter(where trigger.oid is null or trigger.tgenabled not in ('O','A'))
  into v_trigger_details,v_missing_triggers
  from expected
  left join pg_trigger trigger
    on trigger.tgname=expected.trigger_name and not trigger.tgisinternal;

  with expected(jobname) as (
    values
      ('nexlab-process-notification-deliveries'),
      ('nexlab-observability-retention-v26-7-5')
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'jobname',expected.jobname,
      'exists',job.jobid is not null,
      'active',coalesce(job.active,false),
      'schedule',job.schedule
    ) order by expected.jobname),'[]'::jsonb),
    count(*) filter(where job.jobid is null or not coalesce(job.active,false))
  into v_cron_details,v_missing_cron
  from expected
  left join cron.job job on job.jobname=expected.jobname;

  v_audit := public.nexlab_verify_security_audit_chain(10000);

  select coalesce(provider.valid,false),coalesce(provider.operational,false),
         coalesce(provider.status,'unknown'),provider.details->>'reason'
  into v_push_valid,v_push_operational,v_push_status,v_push_reason
  from public.nexlab_notification_provider_health provider
  where provider.channel='push';

  select worker.finished_at,worker.status,worker.http_status
  into v_latest_worker,v_latest_worker_status,v_latest_worker_http
  from public.nexlab_notification_worker_runs worker
  order by worker.started_at desc
  limit 1;

  select
    count(*) filter(where incident.status in ('open','acknowledged') and incident.severity='critical'),
    count(*) filter(where incident.status in ('open','acknowledged') and incident.severity='error')
  into v_active_critical,v_active_errors
  from public.nexlab_client_error_incidents incident;

  select coalesce(jsonb_agg(to_jsonb(candidate) order by candidate.created_at),'[]'::jsonb)
  into v_cleanup_candidates
  from (
    select profile.id,profile.nome,profile.email,profile.matricula,
           profile.role::text as role,profile.ativo,profile.cadastro_completo,
           profile.created_at
    from public.profiles profile
    where profile.id<>auth.uid()
      and lower(coalesce(profile.role::text,'')) not in ('admin','administrador')
      and (
        lower(coalesce(profile.nome,'')) ~ '(teste|test|demo|dummy|sandbox|homolog)'
        or lower(coalesce(profile.email,'')) ~ '(teste|test|demo|dummy|sandbox|homolog)'
        or lower(coalesce(profile.matricula,'')) ~ '(teste|test|demo|dummy|sandbox|homolog)'
      )
    order by profile.created_at
    limit 100
  ) candidate;

  v_checks := jsonb_build_array(
    jsonb_build_object('id','version','label','Versão oficial do banco e do aplicativo','required',true,'status',case when v_client_version=v_expected_version then 'pass' else 'fail' end,'message',format('Banco: v%s • Aplicativo: v%s.',coalesce(v_expected_version,'não registrada'),v_client_version)),
    jsonb_build_object('id','rls','label','RLS das tabelas críticas','required',true,'status',case when v_missing_rls=0 then 'pass' else 'fail' end,'message',case when v_missing_rls=0 then 'Todas as tabelas críticas possuem RLS.' else format('%s tabela(s) ausente(s) ou sem RLS.',v_missing_rls) end),
    jsonb_build_object('id','functions','label','RPCs essenciais atuais','required',true,'status',case when v_missing_functions=0 then 'pass' else 'fail' end,'message',case when v_missing_functions=0 then 'Todas as RPCs essenciais foram encontradas.' else format('%s RPC(s) essencial(is) ausente(s).',v_missing_functions) end),
    jsonb_build_object('id','triggers','label','Triggers operacionais e de segurança','required',true,'status',case when v_missing_triggers=0 then 'pass' else 'fail' end,'message',case when v_missing_triggers=0 then 'Todos os triggers atuais estão ativos.' else format('%s trigger(s) ausente(s) ou inativo(s).',v_missing_triggers) end),
    jsonb_build_object('id','cron','label','Agendamentos automáticos atuais','required',true,'status',case when v_missing_cron=0 then 'pass' else 'fail' end,'message',case when v_missing_cron=0 then 'Os jobs atuais estão ativos.' else format('%s job(s) atual(is) ausente(s) ou inativo(s).',v_missing_cron) end),
    jsonb_build_object('id','integrity','label','Integridade de perfis e vínculos','required',true,'status',case when v_invalid_roles=0 and v_missing_core_permissions=0 and v_duplicate_emails=0 and v_duplicate_matriculas=0 then 'pass' else 'fail' end,'message',format('Perfis inválidos: %s • Sem permissão essencial: %s • E-mails duplicados: %s • Matrículas duplicadas: %s.',v_invalid_roles,v_missing_core_permissions,v_duplicate_emails,v_duplicate_matriculas)),
    jsonb_build_object('id','orphans','label','Registros órfãos','required',true,'status',case when v_orphan_total=0 then 'pass' else 'fail' end,'message',case when v_orphan_total=0 then 'Nenhum registro órfão foi identificado.' else format('%s registro(s) órfão(s) identificado(s).',v_orphan_total) end),
    jsonb_build_object('id','audit','label','Cadeia criptográfica da auditoria','required',true,'status',case when coalesce((v_audit->>'valid')::boolean,false) then 'pass' else 'fail' end,'message',format('%s registro(s) verificado(s); %s inválido(s).',coalesce(v_audit->>'checked','0'),coalesce(v_audit->>'invalid','0'))),
    jsonb_build_object('id','worker','label','Worker de notificações','required',true,'status',case when v_latest_worker>=now()-interval '3 minutes' and v_latest_worker_http=200 then 'pass' else 'fail' end,'message',case when v_latest_worker is null then 'Nenhuma execução do worker foi registrada.' else format('Última execução: %s • Estado: %s • HTTP: %s.',to_char(v_latest_worker,'DD/MM/YYYY HH24:MI:SS'),coalesce(v_latest_worker_status,'desconhecido'),coalesce(v_latest_worker_http::text,'sem resposta')) end),
    jsonb_build_object('id','push','label','Web Push operacional','required',true,'status',case when v_push_valid and v_push_operational then 'pass' else 'fail' end,'message',case when v_push_valid and v_push_operational then 'O provedor Web Push possui configuração válida e entrega confirmada.' else coalesce(v_push_reason,format('Estado do provedor: %s.',v_push_status)) end),
    jsonb_build_object('id','https','label','Hospedagem pública com HTTPS','required',true,'status',case when v_production_host then 'pass' else 'fail' end,'message',case when v_production_host then format('Ambiente seguro detectado em %s.',v_hostname) else 'O aplicativo não está sendo executado em um endereço público HTTPS.' end),
    jsonb_build_object('id','app_url','label','URL pública do aplicativo','required',true,'status',case when v_app_url_ok then 'pass' else 'fail' end,'message',case when v_app_url_ok then v_href else 'A URL pública não foi identificada no contexto do aplicativo.' end),
    jsonb_build_object('id','incidents','label','Incidentes críticos do frontend','required',true,'status',case when v_active_critical=0 then 'pass' else 'fail' end,'message',format('Críticos ativos: %s • Erros ativos: %s.',v_active_critical,v_active_errors)),
    jsonb_build_object('id','accounts','label','Contas que exigem revisão','required',false,'status',case when v_incomplete_profiles=0 and v_pending_profiles=0 then 'pass' else 'warning' end,'message',format('Incompletas: %s • Pendentes: %s • Inativas: %s.',v_incomplete_profiles,v_pending_profiles,v_inactive_profiles)),
    jsonb_build_object('id','cleanup','label','Contas possivelmente temporárias','required',false,'status',case when jsonb_array_length(v_cleanup_candidates)=0 then 'pass' else 'warning' end,'message',format('%s conta(s) candidata(s) à revisão.',jsonb_array_length(v_cleanup_candidates)))
  );

  select
    count(*) filter(where coalesce((item->>'required')::boolean,false)),
    count(*) filter(where coalesce((item->>'required')::boolean,false) and item->>'status'='pass'),
    count(*) filter(where coalesce((item->>'required')::boolean,false) and item->>'status'='fail'),
    count(*) filter(where item->>'status' in ('pending','warning'))
  into v_required,v_passed,v_blocking,v_attention
  from jsonb_array_elements(v_checks) item;

  v_score := case when v_required=0 then 0 else floor((v_passed::numeric/v_required::numeric)*100)::integer end;
  v_status := case when v_blocking>0 then 'blocked' when v_passed=v_required then 'ready' else 'attention' end;

  return jsonb_build_object(
    'checked_at',now(),'diagnostic_version','26.21.0',
    'expected_version',v_expected_version,'database_version',v_expected_version,
    'database_release_status',v_release_status,'client_context',coalesce(p_client_context,'{}'::jsonb),
    'status',v_status,'score',v_score,
    'summary',jsonb_build_object('required_checks',v_required,'passed_checks',v_passed,'blocking_checks',v_blocking,'attention_checks',v_attention),
    'checks',v_checks,
    'integrity',jsonb_build_object(
      'profiles',jsonb_build_object('total',v_total_profiles,'incomplete',v_incomplete_profiles,'inactive',v_inactive_profiles,'pending',v_pending_profiles,'invalid_roles',v_invalid_roles,'missing_core_permissions',v_missing_core_permissions,'duplicate_emails',v_duplicate_emails,'duplicate_matriculas',v_duplicate_matriculas),
      'orphans',jsonb_build_object('notifications',v_orphan_notifications,'deliveries',v_orphan_deliveries,'reminders',v_orphan_reminders,'total',v_orphan_total)
    ),
    'security',jsonb_build_object('rls',v_rls_details,'missing_rls',v_missing_rls,'functions',v_function_details,'missing_functions',v_missing_functions,'triggers',v_trigger_details,'missing_triggers',v_missing_triggers,'cron',v_cron_details,'missing_or_inactive_cron',v_missing_cron,'audit_chain',v_audit),
    'environment',jsonb_build_object('protocol',v_protocol,'hostname',v_hostname,'href',v_href,'https',v_protocol='https:','production_host',v_production_host,'app_url_configured',v_app_url_ok,'edge_function_ok',v_latest_worker>=now()-interval '3 minutes' and v_latest_worker_http=200,'email_mode','suspended','email_required',false,'push_valid',v_push_valid,'push_operational',v_push_operational,'push_status',v_push_status,'service_worker_supported',coalesce((p_client_context->>'service_worker_supported')::boolean,false),'notification_permission',coalesce(p_client_context->>'notification_permission','default')),
    'cleanup',jsonb_build_object('candidate_count',jsonb_array_length(v_cleanup_candidates),'candidates',v_cleanup_candidates,'mode','review_only','permanent_deletion_enabled',false)
  );
end;
$$;

revoke execute on function public.nexlab_get_production_readiness(jsonb) from public,anon;
grant execute on function public.nexlab_get_production_readiness(jsonb) to authenticated;

-- 3. Remoção da antiga estrutura manual.
drop function if exists public.nexlab_update_production_check(text,boolean,text);
drop function if exists public.nexlab_get_production_readiness_v25_14(jsonb);

with cleaned as (
  select snapshot_row.id,
    jsonb_set(
      (snapshot_row.snapshot - 'manual_checklist') || jsonb_build_object(
        'checks',coalesce((
          select jsonb_agg(check_item order by ordinality)
          from jsonb_array_elements(coalesce(snapshot_row.snapshot->'checks','[]'::jsonb))
               with ordinality as listed(check_item,ordinality)
          where check_item->>'id'<>'manual'
        ),'[]'::jsonb)
      ),
      '{security,rls}',
      coalesce((
        select jsonb_agg(item order by ordinality)
        from jsonb_array_elements(coalesce(snapshot_row.snapshot->'security'->'rls','[]'::jsonb))
             with ordinality as listed(item,ordinality)
        where item->>'table'<>'nexlab_production_checklist'
      ),'[]'::jsonb),
      true
    ) as cleaned_snapshot
  from public.nexlab_production_snapshots snapshot_row
)
update public.nexlab_production_snapshots target
set snapshot=cleaned.cleaned_snapshot
from cleaned
where target.id=cleaned.id;

delete from public.nexlab_system_events
where lower(coalesce(event_type,'')) like '%checklist%'
   or lower(coalesce(message,'')) like '%checklist%'
   or lower(coalesce(details::text,'')) like '%checklist%';

drop table if exists public.nexlab_production_checklist;

-- 4. Snapshots versionados, expiráveis e invalidáveis.
alter table public.nexlab_production_snapshots
  add column if not exists diagnostic_version text,
  add column if not exists valid_until timestamptz,
  add column if not exists invalidated_at timestamptz,
  add column if not exists invalidation_reason text,
  add column if not exists configuration_hash text;

update public.nexlab_production_snapshots
set diagnostic_version=coalesce(nullif(snapshot->>'diagnostic_version',''),'legacy'),
    valid_until=coalesce(valid_until,created_at),
    invalidated_at=coalesce(invalidated_at,now()),
    invalidation_reason=coalesce(invalidation_reason,'Snapshot criado por uma versão anterior do diagnóstico.')
where diagnostic_version is null or valid_until is null or invalidated_at is null;

alter table public.nexlab_production_snapshots
  alter column diagnostic_version set default '26.21.0',
  alter column diagnostic_version set not null;

create index if not exists idx_nexlab_production_snapshots_validity_v26210
  on public.nexlab_production_snapshots(app_version,diagnostic_version,valid_until desc)
  where invalidated_at is null;

insert into public.nexlab_system_settings(setting_key,setting_value,description,updated_at)
values ('production_snapshot_valid_hours','24','Prazo máximo de validade de um snapshot de prontidão.',now())
on conflict (setting_key) do update
set setting_value=excluded.setting_value,description=excluded.description,updated_at=now();

create or replace function public.nexlab_record_production_snapshot(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  v_readiness jsonb;
  v_snapshot_id uuid;
  v_version text;
  v_valid_hours integer;
  v_valid_until timestamptz;
  v_configuration_hash text;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;
  v_readiness := public.nexlab_get_production_readiness(coalesce(p_client_context,'{}'::jsonb));
  v_version := coalesce(v_readiness->>'database_version','26.21.0');
  v_valid_hours := public.nexlab_system_setting_int('production_snapshot_valid_hours',24,1,720);
  v_valid_until := now()+make_interval(hours=>v_valid_hours);
  v_configuration_hash := encode(extensions.digest(concat_ws('|',v_version,coalesce(v_readiness->>'diagnostic_version','26.21.0'),coalesce(v_readiness->'checks','[]'::jsonb)::text,coalesce(v_readiness->'environment','{}'::jsonb)::text),'sha256'),'hex');
  update public.nexlab_production_snapshots
  set invalidated_at=coalesce(invalidated_at,now()),invalidation_reason=coalesce(invalidation_reason,'Substituído por um snapshot mais recente.')
  where invalidated_at is null;
  insert into public.nexlab_production_snapshots(app_version,readiness_status,score,client_context,snapshot,created_by,diagnostic_version,valid_until,invalidated_at,invalidation_reason,configuration_hash)
  values (v_version,v_readiness->>'status',coalesce((v_readiness->>'score')::integer,0),coalesce(p_client_context,'{}'::jsonb),v_readiness,auth.uid(),coalesce(v_readiness->>'diagnostic_version','26.21.0'),v_valid_until,null,null,v_configuration_hash)
  returning id into v_snapshot_id;
  insert into public.nexlab_system_events(event_type,severity,message,details,actor_id,created_at)
  values ('production_readiness_snapshot',case when v_readiness->>'status'='ready' then 'success' else 'warning' end,format('Diagnóstico de prontidão v%s registrado com pontuação %s%%.',v_version,v_readiness->>'score'),jsonb_build_object('snapshot_id',v_snapshot_id,'status',v_readiness->>'status','score',v_readiness->>'score','app_version',v_version,'diagnostic_version',v_readiness->>'diagnostic_version','valid_until',v_valid_until,'configuration_hash',v_configuration_hash),auth.uid(),now());
  return jsonb_build_object('ok',true,'snapshot_id',v_snapshot_id,'valid_until',v_valid_until,'configuration_hash',v_configuration_hash,'readiness',v_readiness);
end;
$$;

create or replace function public.nexlab_get_production_snapshots_v26210(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_limit integer := greatest(1,least(coalesce(p_limit,20),100));
  v_current_version text;
  v_rows jsonb;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;
  select version into v_current_version from public.nexlab_app_versions order by string_to_array(version,'.')::integer[] desc limit 1;
  select coalesce(jsonb_agg(to_jsonb(result) order by result.created_at desc),'[]'::jsonb)
  into v_rows
  from (
    select snapshot_row.*,
      (snapshot_row.app_version=v_current_version and snapshot_row.diagnostic_version='26.21.0' and snapshot_row.invalidated_at is null and snapshot_row.valid_until>now()) as is_current,
      case when snapshot_row.invalidated_at is not null then 'invalidated' when snapshot_row.valid_until<=now() then 'expired' when snapshot_row.app_version<>v_current_version then 'version_mismatch' when snapshot_row.diagnostic_version<>'26.21.0' then 'diagnostic_mismatch' else 'current' end as validity_status
    from public.nexlab_production_snapshots snapshot_row
    order by snapshot_row.created_at desc limit v_limit
  ) result;
  return jsonb_build_object('current_version',v_current_version,'diagnostic_version','26.21.0','rows',v_rows,'current_count',(select count(*) from public.nexlab_production_snapshots snapshot_row where snapshot_row.app_version=v_current_version and snapshot_row.diagnostic_version='26.21.0' and snapshot_row.invalidated_at is null and snapshot_row.valid_until>now()));
end;
$$;

create or replace function public.nexlab_invalidate_readiness_snapshots_v26210()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.nexlab_production_snapshots
  set invalidated_at=coalesce(invalidated_at,now()),
      invalidation_reason=coalesce(invalidation_reason,format('Invalidado pelo registro da versão v%s.',new.version))
  where invalidated_at is null and app_version<>new.version;
  return new;
end;
$$;

drop trigger if exists nexlab_app_version_invalidate_snapshots_v26210 on public.nexlab_app_versions;
create trigger nexlab_app_version_invalidate_snapshots_v26210
after insert or update of release_status on public.nexlab_app_versions
for each row execute function public.nexlab_invalidate_readiness_snapshots_v26210();

revoke execute on function public.nexlab_record_production_snapshot(jsonb) from public,anon;
grant execute on function public.nexlab_record_production_snapshot(jsonb) to authenticated;
revoke execute on function public.nexlab_get_production_snapshots_v26210(integer) from public,anon;
grant execute on function public.nexlab_get_production_snapshots_v26210(integer) to authenticated;
revoke execute on function public.nexlab_invalidate_readiness_snapshots_v26210() from public,anon,authenticated;
grant execute on function public.nexlab_invalidate_readiness_snapshots_v26210() to service_role;

-- Alinhamento do nome do trigger de imutabilidade da auditoria.
alter trigger nexlab_security_audit_immutable_trigger
on public.security_audit_logs
rename to nexlab_block_security_audit_mutation;
