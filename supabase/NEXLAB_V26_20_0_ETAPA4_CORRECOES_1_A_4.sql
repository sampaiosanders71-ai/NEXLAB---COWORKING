-- NEXLAB v26.20.0 — Etapa 4, correções 1 a 4
-- Saúde do Sistema: carregamento resiliente, atualização automática,
-- integridade da auditoria e observabilidade de erros do frontend.
-- Esta migração já foi aplicada no projeto de produção.

create table if not exists public.nexlab_client_error_incidents (
  id uuid primary key default gen_random_uuid(),
  incident_key text not null unique,
  fingerprint text,
  environment text not null default 'production',
  module text,
  source text,
  severity text not null default 'error',
  status text not null default 'open'
    check (status in ('open','acknowledged','resolved','ignored')),
  message_sample text not null,
  first_version text,
  latest_version text,
  first_seen_at timestamptz not null,
  last_seen_at timestamptz not null,
  occurrence_count bigint not null default 1 check (occurrence_count > 0),
  last_error_id uuid references public.nexlab_client_errors(id) on delete set null,
  acknowledged_at timestamptz,
  acknowledged_by uuid references public.profiles(id) on delete set null,
  resolved_at timestamptz,
  resolved_by uuid references public.profiles(id) on delete set null,
  resolution_note text,
  release_fixed text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_nexlab_client_incidents_status_seen
  on public.nexlab_client_error_incidents(status,last_seen_at desc);
create index if not exists idx_nexlab_client_incidents_severity_seen
  on public.nexlab_client_error_incidents(severity,last_seen_at desc);
create index if not exists idx_nexlab_client_incidents_module_seen
  on public.nexlab_client_error_incidents(module,last_seen_at desc);

alter table public.nexlab_client_error_incidents enable row level security;
drop policy if exists nexlab_client_error_incidents_admin_select
  on public.nexlab_client_error_incidents;
create policy nexlab_client_error_incidents_admin_select
  on public.nexlab_client_error_incidents
  for select to authenticated
  using (public.nexlab_is_admin());

revoke all privileges on table public.nexlab_client_error_incidents
from public,anon,authenticated;
grant select on table public.nexlab_client_error_incidents to authenticated;
grant all privileges on table public.nexlab_client_error_incidents to service_role;

create or replace function public.nexlab_client_error_incident_key_v26200(
  p_environment text,
  p_fingerprint text,
  p_source text,
  p_module text,
  p_message text
)
returns text
language sql
immutable
set search_path = public, extensions, pg_temp
as $$
  select encode(
    extensions.digest(
      concat_ws('|',
        lower(coalesce(nullif(btrim(p_environment),''),'production')),
        lower(coalesce(nullif(btrim(p_fingerprint),''),nullif(btrim(p_source),''),'unknown-source')),
        lower(coalesce(nullif(btrim(p_module),''),'unknown-module')),
        lower(left(regexp_replace(coalesce(p_message,''),'\s+',' ','g'),500))
      ),
      'sha256'
    ),
    'hex'
  )
$$;

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
begin
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
      occurrence_count,last_error_id,created_at,updated_at
    ) values (
      v_key,new.fingerprint,new.environment,new.module,new.source,new.severity,'open',
      left(new.message,1200),new.app_version,new.app_version,new.occurred_at,new.occurred_at,
      1,new.id,now(),now()
    );
  end if;

  return new;
end;
$$;

revoke execute on function public.nexlab_sync_client_error_incident_v26200()
from public,anon,authenticated;
grant execute on function public.nexlab_sync_client_error_incident_v26200()
to service_role;

drop trigger if exists nexlab_client_errors_sync_incident_v26200
on public.nexlab_client_errors;
create trigger nexlab_client_errors_sync_incident_v26200
after insert on public.nexlab_client_errors
for each row execute function public.nexlab_sync_client_error_incident_v26200();

insert into public.nexlab_client_error_incidents(
  incident_key,fingerprint,environment,module,source,severity,status,
  message_sample,first_version,latest_version,first_seen_at,last_seen_at,
  occurrence_count,last_error_id,created_at,updated_at
)
select
  grouped.incident_key,grouped.fingerprint,grouped.environment,grouped.module,
  grouped.source,grouped.severity,'open',grouped.message_sample,
  grouped.first_version,grouped.latest_version,grouped.first_seen_at,
  grouped.last_seen_at,grouped.occurrence_count,grouped.last_error_id,now(),now()
from (
  select
    public.nexlab_client_error_incident_key_v26200(
      error.environment,error.fingerprint,error.source,error.module,error.message
    ) as incident_key,
    max(error.fingerprint) as fingerprint,
    max(error.environment) as environment,
    max(error.module) as module,
    max(error.source) as source,
    case max(case error.severity when 'critical' then 3 when 'error' then 2 else 1 end)
      when 3 then 'critical' when 2 then 'error' else 'warning'
    end as severity,
    (array_agg(left(error.message,1200) order by error.occurred_at desc,error.id desc))[1] as message_sample,
    (array_agg(error.app_version order by error.occurred_at asc,error.id asc))[1] as first_version,
    (array_agg(error.app_version order by error.occurred_at desc,error.id desc))[1] as latest_version,
    min(error.occurred_at) as first_seen_at,
    max(error.occurred_at) as last_seen_at,
    count(*)::bigint as occurrence_count,
    (array_agg(error.id order by error.occurred_at desc,error.id desc))[1] as last_error_id
  from public.nexlab_client_errors error
  group by public.nexlab_client_error_incident_key_v26200(
    error.environment,error.fingerprint,error.source,error.module,error.message
  )
) grouped
on conflict (incident_key) do nothing;

create or replace function public.nexlab_get_health_observability_v26200(
  p_limit integer default 30,
  p_client_version text default '26.20.0'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  v_limit integer := greatest(5,least(coalesce(p_limit,30),100));
  v_audit jsonb;
  v_result jsonb;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;

  v_audit := public.nexlab_verify_security_audit_chain(10000);

  with incident_rows as (
    select incident.*
    from public.nexlab_client_error_incidents incident
    order by
      case incident.status when 'open' then 0 when 'acknowledged' then 1 when 'resolved' then 2 else 3 end,
      case incident.severity when 'critical' then 0 when 'error' then 1 else 2 end,
      incident.last_seen_at desc
    limit v_limit
  ),
  recent_errors as (
    select error.id,error.user_id,error.app_version,error.environment,error.source,
           error.severity,error.message,error.module,error.page,error.url_path,
           error.fingerprint,error.occurred_at,error.created_at
    from public.nexlab_client_errors error
    order by error.occurred_at desc,error.id desc
    limit least(v_limit,40)
  ),
  module_groups as (
    select coalesce(error.module,'não informado') as module,
           count(*)::integer as total,
           count(*) filter(where error.occurred_at>=now()-interval '24 hours')::integer as last_24h,
           count(*) filter(where error.severity='critical')::integer as critical
    from public.nexlab_client_errors error
    where error.occurred_at>=now()-interval '7 days'
    group by coalesce(error.module,'não informado')
    order by total desc,module
    limit 12
  ),
  incident_summary as (
    select count(*)::integer as total,
      count(*) filter(where status='open')::integer as open_count,
      count(*) filter(where status='acknowledged')::integer as acknowledged_count,
      count(*) filter(where status='resolved')::integer as resolved_count,
      count(*) filter(where status='ignored')::integer as ignored_count,
      count(*) filter(where status in ('open','acknowledged') and severity='critical')::integer as active_critical,
      count(*) filter(where status in ('open','acknowledged') and severity='error')::integer as active_error,
      max(last_seen_at) as latest_seen_at
    from public.nexlab_client_error_incidents
  ),
  error_summary as (
    select count(*)::integer as total,
      count(*) filter(where occurred_at>=now()-interval '24 hours')::integer as last_24h,
      count(*) filter(where occurred_at>=now()-interval '7 days')::integer as last_7d,
      count(*) filter(where severity='critical')::integer as critical_total,
      count(*) filter(where app_version=p_client_version)::integer as current_version,
      count(distinct fingerprint) filter(where fingerprint is not null)::integer as fingerprints
    from public.nexlab_client_errors
  )
  select jsonb_build_object(
    'checked_at',now(),'client_version',p_client_version,'audit_chain',v_audit,
    'incident_summary',to_jsonb(incident_summary),'error_summary',to_jsonb(error_summary),
    'incidents',coalesce((select jsonb_agg(to_jsonb(incident_rows)) from incident_rows),'[]'::jsonb),
    'recent_errors',coalesce((select jsonb_agg(to_jsonb(recent_errors) order by occurred_at desc,id desc) from recent_errors),'[]'::jsonb),
    'modules',coalesce((select jsonb_agg(to_jsonb(module_groups) order by total desc,module) from module_groups),'[]'::jsonb)
  ) into v_result
  from incident_summary,error_summary;

  return v_result;
end;
$$;

revoke execute on function public.nexlab_get_health_observability_v26200(integer,text)
from public,anon;
grant execute on function public.nexlab_get_health_observability_v26200(integer,text)
to authenticated;

create or replace function public.nexlab_update_client_incident_v26200(
  p_incident_id uuid,
  p_action text,
  p_note text default null,
  p_release_fixed text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_action text := lower(btrim(coalesce(p_action,'')));
  v_row public.nexlab_client_error_incidents%rowtype;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;
  if v_action not in ('acknowledge','resolve','reopen','ignore') then
    raise exception 'Ação de incidente inválida.' using errcode='22023';
  end if;

  update public.nexlab_client_error_incidents incident
  set status=case v_action
        when 'acknowledge' then 'acknowledged'
        when 'resolve' then 'resolved'
        when 'reopen' then 'open'
        when 'ignore' then 'ignored'
      end,
      acknowledged_at=case when v_action='acknowledge' then now() when v_action='reopen' then null else acknowledged_at end,
      acknowledged_by=case when v_action='acknowledge' then auth.uid() when v_action='reopen' then null else acknowledged_by end,
      resolved_at=case when v_action='resolve' then now() when v_action='reopen' then null else resolved_at end,
      resolved_by=case when v_action='resolve' then auth.uid() when v_action='reopen' then null else resolved_by end,
      resolution_note=case when v_action in ('resolve','ignore') then nullif(btrim(coalesce(p_note,'')),'') when v_action='reopen' then null else resolution_note end,
      release_fixed=case when v_action='resolve' then nullif(btrim(coalesce(p_release_fixed,'')),'') when v_action='reopen' then null else release_fixed end,
      updated_at=now()
  where incident.id=p_incident_id
  returning * into v_row;

  if not found then
    raise exception 'Incidente não encontrado.' using errcode='P0002';
  end if;

  insert into public.nexlab_system_events(event_type,severity,message,details,actor_id,created_at)
  values (
    'client_error_incident_updated',
    case when v_action='reopen' then 'warning' else 'info' end,
    format('Incidente do frontend atualizado: %s.',v_action),
    jsonb_build_object(
      'incident_id',v_row.id,'incident_key',v_row.incident_key,'action',v_action,
      'status',v_row.status,'note',p_note,'release_fixed',p_release_fixed,
      'module',v_row.module,'severity',v_row.severity
    ),
    auth.uid(),now()
  );

  return jsonb_build_object('ok',true,'incident',to_jsonb(v_row));
end;
$$;

revoke execute on function public.nexlab_update_client_incident_v26200(uuid,text,text,text)
from public,anon;
grant execute on function public.nexlab_update_client_incident_v26200(uuid,text,text,text)
to authenticated;
