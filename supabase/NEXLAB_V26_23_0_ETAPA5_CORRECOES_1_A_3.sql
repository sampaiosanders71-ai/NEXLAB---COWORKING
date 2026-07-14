-- NEXLAB v26.23.0 — Etapa 5, correções 1 a 3
-- Projeto: eahldhabwulnwhuwrhvc
-- Já aplicado no projeto atual. Não executar novamente no mesmo banco.

-- ============================================================
-- CORREÇÃO 1 — REMOÇÃO DE ÍNDICES REDUNDANTES
-- ============================================================

drop index if exists public.logs_created_at_idx;

drop index if exists public.nexlab_data_requests_status_idx;
drop index if exists public.nexlab_data_requests_user_created_idx;

drop index if exists public.uq_nexlab_notification_preferences_pair;
drop index if exists public.notification_preferences_user_idx;

drop index if exists public.uq_nexlab_notification_user_settings_user;

drop index if exists public.notifications_recipient_created_idx;

drop index if exists public.security_audit_logs_actor_created_idx;
drop index if exists public.security_audit_logs_actor_idx;
drop index if exists public.security_audit_logs_created_at_idx;
drop index if exists public.security_audit_logs_created_idx;
drop index if exists public.security_audit_logs_target_idx;

-- ============================================================
-- CORREÇÃO 2 — CONSOLIDAÇÃO DAS POLÍTICAS RLS DE LOGS
-- ============================================================

revoke all privileges on table public.logs from authenticated;
grant select on table public.logs to authenticated;

drop policy if exists nexlab_approved_account_gate on public.logs;
drop policy if exists nexlab_logs_admin_select on public.logs;
drop policy if exists nexlab_logs_admin_select_restrictive on public.logs;
drop policy if exists "ve logs" on public.logs;

create policy nexlab_logs_admin_read_v26230
on public.logs
for select
to authenticated
using (
  public.nexlab_has_approved_access()
  and public.nexlab_is_admin()
);

revoke all privileges on table public.security_audit_logs from authenticated;
grant select on table public.security_audit_logs to authenticated;

drop policy if exists nexlab_approved_account_gate on public.security_audit_logs;
drop policy if exists nexlab_security_audit_admin_select on public.security_audit_logs;

create policy nexlab_security_audit_admin_read_v26230
on public.security_audit_logs
for select
to authenticated
using (
  public.nexlab_has_approved_access()
  and public.nexlab_is_admin()
);

-- ============================================================
-- CORREÇÃO 3 — RETIRADA DE OBJETOS LEGADOS E DEPENDÊNCIAS ATUAIS
-- ============================================================

insert into public.nexlab_app_versions(
  version,title,release_status,notes,installed_at,installed_by
) values (
  '26.23.0',
  'Limpeza Estrutural Inicial',
  'stable',
  'Índices redundantes removidos, políticas RLS consolidadas e objetos legados aposentados.',
  now(),
  null
)
on conflict (version) do update
set title=excluded.title,
    release_status=excluded.release_status,
    notes=excluded.notes,
    installed_at=excluded.installed_at;

create or replace function public.nexlab_get_production_readiness(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  v_base jsonb;
  v_checks jsonb;
  v_function_rows jsonb;
  v_missing_functions integer := 0;
  v_required integer;
  v_passed integer;
  v_blocking integer;
  v_attention integer;
  v_score integer;
  v_status text;
  v_current_critical integer;
  v_current_error integer;
  v_historical_open integer;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;

  v_base := public.nexlab_get_production_readiness_v26210_base(
    coalesce(p_client_context,'{}'::jsonb)
  );

  select coalesce(jsonb_agg(
    case
      when item->>'label'='Observabilidade' then
        jsonb_build_object(
          'label','Observabilidade',
          'signature','public.nexlab_get_health_observability_v26220(integer,text)',
          'exists',to_regprocedure('public.nexlab_get_health_observability_v26220(integer,text)') is not null
        )
      else item
    end
    order by ordinality
  ),'[]'::jsonb)
  into v_function_rows
  from jsonb_array_elements(coalesce(v_base->'security'->'functions','[]'::jsonb))
       with ordinality as listed(item,ordinality);

  select count(*) into v_missing_functions
  from jsonb_array_elements(v_function_rows) item
  where not coalesce((item->>'exists')::boolean,false);

  v_base := jsonb_set(v_base,'{security,functions}',v_function_rows,true);
  v_base := jsonb_set(v_base,'{security,missing_functions}',to_jsonb(v_missing_functions),true);

  select
    count(*) filter(
      where incident.status in ('open','acknowledged')
        and incident.release_scope='current'
        and incident.severity='critical'
    ),
    count(*) filter(
      where incident.status in ('open','acknowledged')
        and incident.release_scope='current'
        and incident.severity='error'
    ),
    count(*) filter(
      where incident.status in ('open','acknowledged')
        and incident.release_scope='previous'
    )
  into v_current_critical,v_current_error,v_historical_open
  from public.nexlab_client_error_incidents incident;

  select coalesce(jsonb_agg(
    case
      when item->>'id'='functions' then
        item || jsonb_build_object(
          'status',case when v_missing_functions=0 then 'pass' else 'fail' end,
          'message',case
            when v_missing_functions=0 then 'Todas as RPCs essenciais atuais foram encontradas.'
            else format('%s RPC(s) essencial(is) atual(is) ausente(s).',v_missing_functions)
          end
        )
      when item->>'id'='incidents' then
        item || jsonb_build_object(
          'label','Incidentes críticos da versão atual',
          'status',case when v_current_critical=0 then 'pass' else 'fail' end,
          'message',format(
            'Críticos na versão atual: %s • Erros na versão atual: %s • Incidentes históricos abertos: %s.',
            v_current_critical,v_current_error,v_historical_open
          )
        )
      else item
    end
    order by ordinality
  ),'[]'::jsonb)
  into v_checks
  from jsonb_array_elements(coalesce(v_base->'checks','[]'::jsonb))
       with ordinality as listed(item,ordinality);

  select
    count(*) filter(where coalesce((item->>'required')::boolean,false)),
    count(*) filter(where coalesce((item->>'required')::boolean,false) and item->>'status'='pass'),
    count(*) filter(where coalesce((item->>'required')::boolean,false) and item->>'status'='fail'),
    count(*) filter(where item->>'status' in ('pending','warning'))
  into v_required,v_passed,v_blocking,v_attention
  from jsonb_array_elements(v_checks) item;

  v_score := case
    when v_required=0 then 0
    else floor((v_passed::numeric/v_required::numeric)*100)::integer
  end;

  v_status := case
    when v_blocking>0 then 'blocked'
    when v_passed=v_required then 'ready'
    else 'attention'
  end;

  return v_base
    || jsonb_build_object(
      'diagnostic_version','26.23.0',
      'checks',v_checks,
      'score',v_score,
      'status',v_status,
      'summary',jsonb_build_object(
        'required_checks',v_required,
        'passed_checks',v_passed,
        'blocking_checks',v_blocking,
        'attention_checks',v_attention
      ),
      'incident_scope',jsonb_build_object(
        'current_critical',v_current_critical,
        'current_error',v_current_error,
        'historical_open',v_historical_open
      )
    );
end;
$$;

revoke execute on function public.nexlab_get_production_readiness(jsonb)
from public,anon;
grant execute on function public.nexlab_get_production_readiness(jsonb)
to authenticated;

create or replace function public.nexlab_get_production_snapshots_v26210(
  p_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_limit integer := greatest(1,least(coalesce(p_limit,20),100));
  v_current_version text;
  v_diagnostic_version text;
  v_rows jsonb;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;

  select version into v_current_version
  from public.nexlab_app_versions
  order by string_to_array(version,'.')::integer[] desc
  limit 1;

  v_diagnostic_version := v_current_version;

  select coalesce(jsonb_agg(to_jsonb(result) order by result.created_at desc),'[]'::jsonb)
  into v_rows
  from (
    select snapshot_row.*,
      (
        snapshot_row.app_version=v_current_version
        and snapshot_row.diagnostic_version=v_diagnostic_version
        and snapshot_row.invalidated_at is null
        and snapshot_row.valid_until>now()
      ) as is_current,
      case
        when snapshot_row.invalidated_at is not null then 'invalidated'
        when snapshot_row.valid_until<=now() then 'expired'
        when snapshot_row.app_version<>v_current_version then 'version_mismatch'
        when snapshot_row.diagnostic_version<>v_diagnostic_version then 'diagnostic_mismatch'
        else 'current'
      end as validity_status
    from public.nexlab_production_snapshots snapshot_row
    order by snapshot_row.created_at desc
    limit v_limit
  ) result;

  return jsonb_build_object(
    'current_version',v_current_version,
    'diagnostic_version',v_diagnostic_version,
    'rows',v_rows,
    'current_count',(
      select count(*)
      from public.nexlab_production_snapshots snapshot_row
      where snapshot_row.app_version=v_current_version
        and snapshot_row.diagnostic_version=v_diagnostic_version
        and snapshot_row.invalidated_at is null
        and snapshot_row.valid_until>now()
    )
  );
end;
$$;

-- Wrappers e diagnósticos antigos sem uso no bundle, Cron ou arquitetura atual.
drop function if exists public.nexlab_observability_readiness_v26_7_4();
drop function if exists public.nexlab_observability_readiness_v26_7();

drop function if exists public.nexlab_get_observability_summary_v26_7(integer);
drop function if exists public.nexlab_get_observability_summary_v26_7_4(integer,text);

drop function if exists public.nexlab_cleanup_client_errors_v26_7(integer);
drop function if exists public.nexlab_cleanup_client_errors_v26_7_4(integer);

drop function if exists public.nexlab_observability_retention_status_v26_7_5();
drop function if exists public.nexlab_v267_is_admin();

drop function if exists public.nexlab_get_health_observability_v26200(integer,text);

-- Preservado intencionalmente, pois é chamado pelo pg_cron:
-- public.nexlab_cleanup_client_errors_automatic_v26_7_5()
