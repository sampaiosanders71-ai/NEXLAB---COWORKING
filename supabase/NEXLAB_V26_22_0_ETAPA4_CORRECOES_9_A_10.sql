-- NEXLAB v26.22.0 — Etapa 4, correções 9 e 10
-- Já aplicado no projeto eahldhabwulnwhuwrhvc.
-- Não executar novamente no projeto atual.

-- CORREÇÃO 9 — Incidentes classificados pela versão ativa.
insert into public.nexlab_app_versions(
  version,title,release_status,notes,installed_at,installed_by
) values (
  '26.22.0',
  'Saúde por Versão e Snapshot Automático',
  'stable',
  'Incidentes classificados por versão ativa e manutenção automática do snapshot operacional.',
  now(),
  null
)
on conflict (version) do update
set title=excluded.title,
    release_status=excluded.release_status,
    notes=excluded.notes,
    installed_at=excluded.installed_at;

alter table public.nexlab_client_error_incidents
  add column if not exists release_scope text not null default 'unknown'
    check (release_scope in ('current','previous','unknown')),
  add column if not exists classified_release text,
  add column if not exists classified_at timestamptz;

create index if not exists idx_nexlab_client_incidents_release_scope_v26220
  on public.nexlab_client_error_incidents(
    release_scope,status,severity,last_seen_at desc
  );

with current_release as (
  select version
  from public.nexlab_app_versions
  order by string_to_array(version,'.')::integer[] desc
  limit 1
)
update public.nexlab_client_error_incidents incident
set release_scope=case
      when nullif(btrim(coalesce(incident.latest_version,'')),'') is null
        then 'unknown'
      when incident.latest_version=current_release.version
        then 'current'
      else 'previous'
    end,
    classified_release=current_release.version,
    classified_at=now(),
    updated_at=now()
from current_release;

create or replace function public.nexlab_sync_client_error_incident_v26200()
returns trigger
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  v_key text;
  v_existing public.nexlab_client_error_incidents%rowtype;
  v_severity text;
  v_reopen boolean := false;
  v_current_release text;
  v_release_scope text;
begin
  select version into v_current_release
  from public.nexlab_app_versions
  order by string_to_array(version,'.')::integer[] desc
  limit 1;

  v_release_scope := case
    when nullif(btrim(coalesce(new.app_version,'')),'') is null then 'unknown'
    when new.app_version=v_current_release then 'current'
    else 'previous'
  end;

  v_key := public.nexlab_client_error_incident_key_v26200(
    new.environment,new.fingerprint,new.source,new.module,new.message
  );

  select * into v_existing
  from public.nexlab_client_error_incidents
  where incident_key=v_key
  for update;

  if found then
    v_severity := case
      when new.severity='critical' or v_existing.severity='critical' then 'critical'
      when new.severity='error' or v_existing.severity='error' then 'error'
      else 'warning'
    end;

    v_reopen := v_existing.status='resolved'
      and new.occurred_at > coalesce(v_existing.resolved_at,'epoch'::timestamptz);

    update public.nexlab_client_error_incidents
    set fingerprint=coalesce(new.fingerprint,fingerprint),
        module=coalesce(new.module,module),
        source=coalesce(new.source,source),
        severity=v_severity,
        message_sample=left(new.message,1200),
        latest_version=new.app_version,
        last_seen_at=greatest(last_seen_at,new.occurred_at),
        occurrence_count=occurrence_count+1,
        last_error_id=new.id,
        release_scope=v_release_scope,
        classified_release=v_current_release,
        classified_at=now(),
        status=case when v_reopen then 'open' else status end,
        resolved_at=case when v_reopen then null else resolved_at end,
        resolved_by=case when v_reopen then null else resolved_by end,
        resolution_note=case when v_reopen then null else resolution_note end,
        release_fixed=case when v_reopen then null else release_fixed end,
        updated_at=now()
    where incident_key=v_key;
  else
    insert into public.nexlab_client_error_incidents(
      incident_key,fingerprint,environment,module,source,severity,status,
      message_sample,first_version,latest_version,first_seen_at,last_seen_at,
      occurrence_count,last_error_id,release_scope,classified_release,
      classified_at,created_at,updated_at
    ) values (
      v_key,new.fingerprint,new.environment,new.module,new.source,
      new.severity,'open',left(new.message,1200),new.app_version,
      new.app_version,new.occurred_at,new.occurred_at,1,new.id,
      v_release_scope,v_current_release,now(),now(),now()
    );
  end if;

  return new;
end;
$$;

create or replace function public.nexlab_get_health_observability_v26220(
  p_limit integer default 30,
  p_client_version text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  v_limit integer := greatest(5,least(coalesce(p_limit,30),100));
  v_current_release text;
  v_client_version text;
  v_audit jsonb;
  v_result jsonb;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;

  select version into v_current_release
  from public.nexlab_app_versions
  order by string_to_array(version,'.')::integer[] desc
  limit 1;

  v_client_version := coalesce(
    nullif(btrim(coalesce(p_client_version,'')),''),
    v_current_release
  );
  v_audit := public.nexlab_verify_security_audit_chain(10000);

  with incident_rows as (
    select incident.*
    from public.nexlab_client_error_incidents incident
    order by
      case incident.release_scope when 'current' then 0 when 'unknown' then 1 else 2 end,
      case incident.status when 'open' then 0 when 'acknowledged' then 1 when 'resolved' then 2 else 3 end,
      case incident.severity when 'critical' then 0 when 'error' then 1 else 2 end,
      incident.last_seen_at desc
    limit v_limit
  ),
  recent_errors as (
    select error.id,error.user_id,error.app_version,error.environment,
           error.source,error.severity,error.message,error.module,error.page,
           error.url_path,error.fingerprint,error.occurred_at,error.created_at,
           case
             when error.app_version=v_current_release then 'current'
             when nullif(btrim(coalesce(error.app_version,'')),'') is null then 'unknown'
             else 'previous'
           end as release_scope
    from public.nexlab_client_errors error
    order by error.occurred_at desc,error.id desc
    limit least(v_limit,40)
  ),
  module_groups as (
    select coalesce(error.module,'não informado') as module,
           count(*)::integer as total,
           count(*) filter(
             where error.occurred_at>=now()-interval '24 hours'
           )::integer as last_24h,
           count(*) filter(where error.severity='critical')::integer as critical
    from public.nexlab_client_errors error
    where error.app_version=v_current_release
    group by coalesce(error.module,'não informado')
    order by total desc,module
    limit 12
  ),
  incident_summary as (
    select
      count(*)::integer as total,
      count(*) filter(where incident.status='open')::integer as open_count,
      count(*) filter(where incident.status='acknowledged')::integer as acknowledged_count,
      count(*) filter(where incident.status='resolved')::integer as resolved_count,
      count(*) filter(where incident.status='ignored')::integer as ignored_count,
      count(*) filter(
        where incident.status in ('open','acknowledged')
          and incident.release_scope='current'
          and incident.severity='critical'
      )::integer as active_critical,
      count(*) filter(
        where incident.status in ('open','acknowledged')
          and incident.release_scope='current'
          and incident.severity='error'
      )::integer as active_error,
      count(*) filter(
        where incident.status in ('open','acknowledged')
          and incident.release_scope='current'
      )::integer as current_release_open,
      count(*) filter(
        where incident.status in ('open','acknowledged')
          and incident.release_scope='previous'
      )::integer as historical_open,
      count(*) filter(
        where incident.status in ('open','acknowledged')
          and incident.release_scope='unknown'
      )::integer as unknown_release_open,
      max(incident.last_seen_at) as latest_seen_at
    from public.nexlab_client_error_incidents incident
  ),
  error_summary as (
    select
      count(*)::integer as total,
      count(*) filter(
        where error.occurred_at>=now()-interval '24 hours'
      )::integer as last_24h,
      count(*) filter(
        where error.occurred_at>=now()-interval '7 days'
      )::integer as last_7d,
      count(*) filter(where error.severity='critical')::integer as critical_total,
      count(*) filter(where error.app_version=v_current_release)::integer as current_version,
      count(*) filter(
        where error.app_version=v_current_release
          and error.severity='critical'
      )::integer as current_version_critical,
      count(*) filter(
        where error.app_version=v_current_release
          and error.severity='error'
      )::integer as current_version_error,
      count(distinct error.fingerprint) filter(
        where error.fingerprint is not null
      )::integer as fingerprints
    from public.nexlab_client_errors error
  )
  select jsonb_build_object(
    'checked_at',now(),
    'current_release',v_current_release,
    'client_version',v_client_version,
    'audit_chain',v_audit,
    'incident_summary',to_jsonb(incident_summary),
    'error_summary',to_jsonb(error_summary),
    'incidents',coalesce(
      (select jsonb_agg(to_jsonb(incident_rows) order by
        case incident_rows.release_scope when 'current' then 0 when 'unknown' then 1 else 2 end,
        case incident_rows.status when 'open' then 0 when 'acknowledged' then 1 when 'resolved' then 2 else 3 end,
        case incident_rows.severity when 'critical' then 0 when 'error' then 1 else 2 end,
        incident_rows.last_seen_at desc
      ) from incident_rows),
      '[]'::jsonb
    ),
    'recent_errors',coalesce(
      (select jsonb_agg(to_jsonb(recent_errors)
        order by recent_errors.occurred_at desc,recent_errors.id desc)
       from recent_errors),
      '[]'::jsonb
    ),
    'modules',coalesce(
      (select jsonb_agg(to_jsonb(module_groups)
        order by module_groups.total desc,module_groups.module)
       from module_groups),
      '[]'::jsonb
    )
  )
  into v_result
  from incident_summary,error_summary;

  return v_result;
end;
$$;

revoke execute on function
  public.nexlab_get_health_observability_v26220(integer,text)
from public,anon;
grant execute on function
  public.nexlab_get_health_observability_v26220(integer,text)
to authenticated;

alter function public.nexlab_get_production_readiness(jsonb)
rename to nexlab_get_production_readiness_v26210_base;

revoke execute on function
  public.nexlab_get_production_readiness_v26210_base(jsonb)
from public,anon,authenticated;
grant execute on function
  public.nexlab_get_production_readiness_v26210_base(jsonb)
to service_role;

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
    count(*) filter(
      where coalesce((item->>'required')::boolean,false)
        and item->>'status'='pass'
    ),
    count(*) filter(
      where coalesce((item->>'required')::boolean,false)
        and item->>'status'='fail'
    ),
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

  return v_base || jsonb_build_object(
    'diagnostic_version','26.22.0',
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

-- CORREÇÃO 10 — Snapshot automático, estável e sem duplicidade.
create or replace function public.nexlab_readiness_configuration_hash_v26220(
  p_readiness jsonb
)
returns text
language plpgsql
immutable
set search_path = public, extensions, pg_temp
as $$
declare
  v_check_states jsonb;
  v_environment jsonb;
begin
  select coalesce(
    jsonb_object_agg(item->>'id',item->>'status' order by item->>'id'),
    '{}'::jsonb
  )
  into v_check_states
  from jsonb_array_elements(coalesce(p_readiness->'checks','[]'::jsonb)) item;

  v_environment := jsonb_build_object(
    'production_host',coalesce(
      (p_readiness->'environment'->>'production_host')::boolean,false
    ),
    'app_url_configured',coalesce(
      (p_readiness->'environment'->>'app_url_configured')::boolean,false
    ),
    'edge_function_ok',coalesce(
      (p_readiness->'environment'->>'edge_function_ok')::boolean,false
    ),
    'email_mode',coalesce(
      p_readiness->'environment'->>'email_mode','suspended'
    ),
    'push_valid',coalesce(
      (p_readiness->'environment'->>'push_valid')::boolean,false
    ),
    'push_operational',coalesce(
      (p_readiness->'environment'->>'push_operational')::boolean,false
    )
  );

  return encode(
    extensions.digest(
      concat_ws('|',
        coalesce(p_readiness->>'database_version',''),
        coalesce(p_readiness->>'diagnostic_version',''),
        coalesce(p_readiness->>'status',''),
        coalesce(p_readiness->>'score','0'),
        v_check_states::text,
        v_environment::text
      ),
      'sha256'
    ),
    'hex'
  );
end;
$$;

revoke execute on function
  public.nexlab_readiness_configuration_hash_v26220(jsonb)
from public,anon,authenticated;
grant execute on function
  public.nexlab_readiness_configuration_hash_v26220(jsonb)
to service_role;

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
  v_diagnostic_version text;
  v_valid_hours integer;
  v_valid_until timestamptz;
  v_configuration_hash text;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;

  v_readiness := public.nexlab_get_production_readiness(
    coalesce(p_client_context,'{}'::jsonb)
  );
  v_version := coalesce(v_readiness->>'database_version','26.22.0');
  v_diagnostic_version := coalesce(
    v_readiness->>'diagnostic_version','26.22.0'
  );
  v_valid_hours := public.nexlab_system_setting_int(
    'production_snapshot_valid_hours',24,1,720
  );
  v_valid_until := now()+make_interval(hours=>v_valid_hours);
  v_configuration_hash :=
    public.nexlab_readiness_configuration_hash_v26220(v_readiness);

  update public.nexlab_production_snapshots
  set invalidated_at=coalesce(invalidated_at,now()),
      invalidation_reason=coalesce(
        invalidation_reason,
        'Substituído por um snapshot operacional mais recente.'
      )
  where invalidated_at is null;

  insert into public.nexlab_production_snapshots(
    app_version,readiness_status,score,client_context,snapshot,created_by,
    diagnostic_version,valid_until,invalidated_at,invalidation_reason,
    configuration_hash
  ) values (
    v_version,v_readiness->>'status',
    coalesce((v_readiness->>'score')::integer,0),
    coalesce(p_client_context,'{}'::jsonb),v_readiness,auth.uid(),
    v_diagnostic_version,v_valid_until,null,null,v_configuration_hash
  ) returning id into v_snapshot_id;

  insert into public.nexlab_system_events(
    event_type,severity,message,details,actor_id,created_at
  ) values (
    'production_readiness_snapshot',
    case when v_readiness->>'status'='ready' then 'success' else 'warning' end,
    format(
      'Snapshot operacional v%s registrado com pontuação %s%%.',
      v_version,v_readiness->>'score'
    ),
    jsonb_build_object(
      'snapshot_id',v_snapshot_id,
      'status',v_readiness->>'status',
      'score',v_readiness->>'score',
      'app_version',v_version,
      'diagnostic_version',v_diagnostic_version,
      'valid_until',v_valid_until,
      'configuration_hash',v_configuration_hash,
      'automatic',false
    ),
    auth.uid(),now()
  );

  return jsonb_build_object(
    'ok',true,'created',true,'automatic',false,
    'snapshot_id',v_snapshot_id,'valid_until',v_valid_until,
    'configuration_hash',v_configuration_hash,'readiness',v_readiness
  );
end;
$$;

create or replace function public.nexlab_ensure_production_snapshot_v26220(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  v_readiness jsonb;
  v_version text;
  v_diagnostic_version text;
  v_configuration_hash text;
  v_existing_id uuid;
  v_existing_valid_until timestamptz;
  v_created jsonb;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;

  v_readiness := public.nexlab_get_production_readiness(
    coalesce(p_client_context,'{}'::jsonb)
  );
  v_version := coalesce(v_readiness->>'database_version','26.22.0');
  v_diagnostic_version := coalesce(
    v_readiness->>'diagnostic_version','26.22.0'
  );
  v_configuration_hash :=
    public.nexlab_readiness_configuration_hash_v26220(v_readiness);

  select snapshot_row.id,snapshot_row.valid_until
  into v_existing_id,v_existing_valid_until
  from public.nexlab_production_snapshots snapshot_row
  where snapshot_row.app_version=v_version
    and snapshot_row.diagnostic_version=v_diagnostic_version
    and snapshot_row.configuration_hash=v_configuration_hash
    and snapshot_row.invalidated_at is null
    and snapshot_row.valid_until>now()+interval '1 hour'
  order by snapshot_row.created_at desc
  limit 1;

  if v_existing_id is not null then
    return jsonb_build_object(
      'ok',true,'created',false,'automatic',true,
      'snapshot_id',v_existing_id,
      'valid_until',v_existing_valid_until,
      'configuration_hash',v_configuration_hash,
      'readiness',v_readiness
    );
  end if;

  v_created := public.nexlab_record_production_snapshot(
    coalesce(p_client_context,'{}'::jsonb)
  );

  update public.nexlab_system_events
  set details=coalesce(details,'{}'::jsonb)
    ||jsonb_build_object('automatic',true)
  where event_type='production_readiness_snapshot'
    and details->>'snapshot_id'=v_created->>'snapshot_id';

  return v_created || jsonb_build_object('automatic',true);
end;
$$;

revoke execute on function
  public.nexlab_ensure_production_snapshot_v26220(jsonb)
from public,anon;
grant execute on function
  public.nexlab_ensure_production_snapshot_v26220(jsonb)
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
  v_diagnostic_version text := '26.22.0';
  v_rows jsonb;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;

  select version into v_current_version
  from public.nexlab_app_versions
  order by string_to_array(version,'.')::integer[] desc
  limit 1;

  select coalesce(
    jsonb_agg(to_jsonb(result) order by result.created_at desc),
    '[]'::jsonb
  )
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
        when snapshot_row.diagnostic_version<>v_diagnostic_version
          then 'diagnostic_mismatch'
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
