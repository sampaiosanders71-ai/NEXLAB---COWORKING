-- NEXLAB v26.24.0 — Etapa 5, correções 4 a 6
-- Projeto: eahldhabwulnwhuwrhvc
-- Já aplicado no projeto atual. Não executar novamente no mesmo banco.

-- ============================================================
-- CORREÇÃO 4 — REALTIME E LEITURAS TÉCNICAS ALINHADAS
-- ============================================================

grant select on table public.notification_reminders to authenticated;
grant select on table public.nexlab_client_errors to authenticated;
grant select on table public.nexlab_production_snapshots to authenticated;

drop policy if exists notification_reminders_select_own
on public.notification_reminders;

create policy notification_reminders_read_v26240
on public.notification_reminders
for select
to authenticated
using (
  public.nexlab_has_approved_access()
  and (
    recipient_id = auth.uid()
    or public.nexlab_is_admin()
  )
);

drop policy if exists nexlab_client_errors_admin_select
on public.nexlab_client_errors;

create policy nexlab_client_errors_admin_read_v26240
on public.nexlab_client_errors
for select
to authenticated
using (
  public.nexlab_has_approved_access()
  and public.nexlab_is_admin()
);

-- ============================================================
-- CORREÇÃO 5 — CONSOLIDAÇÃO FINAL DE RLS E POLÍTICAS INATIVAS
-- ============================================================

drop policy if exists nexlab_approved_account_gate
on public.nexlab_app_versions;
drop policy if exists nexlab_app_versions_authenticated_select
on public.nexlab_app_versions;

create policy nexlab_app_versions_read_v26240
on public.nexlab_app_versions
for select
to authenticated
using (public.nexlab_has_approved_access());

drop policy if exists nexlab_approved_account_gate
on public.nexlab_system_events;
drop policy if exists nexlab_system_events_admin_select
on public.nexlab_system_events;

create policy nexlab_system_events_admin_read_v26240
on public.nexlab_system_events
for select
to authenticated
using (
  public.nexlab_has_approved_access()
  and public.nexlab_is_admin()
);

drop policy if exists nexlab_approved_account_gate
on public.nexlab_production_snapshots;
drop policy if exists nexlab_production_snapshots_admin_select
on public.nexlab_production_snapshots;

create policy nexlab_production_snapshots_admin_read_v26240
on public.nexlab_production_snapshots
for select
to authenticated
using (
  public.nexlab_has_approved_access()
  and public.nexlab_is_admin()
);

drop policy if exists nexlab_approved_account_gate
on public.nexlab_system_settings;
drop policy if exists nexlab_system_settings_admin_select
on public.nexlab_system_settings;
drop policy if exists nexlab_system_settings_admin_insert
on public.nexlab_system_settings;
drop policy if exists nexlab_system_settings_admin_update
on public.nexlab_system_settings;

create policy nexlab_system_settings_admin_read_v26240
on public.nexlab_system_settings
for select
to authenticated
using (
  public.nexlab_has_approved_access()
  and public.nexlab_is_admin()
);

create policy nexlab_system_settings_admin_insert_v26240
on public.nexlab_system_settings
for insert
to authenticated
with check (
  public.nexlab_has_approved_access()
  and public.nexlab_is_admin()
);

create policy nexlab_system_settings_admin_update_v26240
on public.nexlab_system_settings
for update
to authenticated
using (
  public.nexlab_has_approved_access()
  and public.nexlab_is_admin()
)
with check (
  public.nexlab_has_approved_access()
  and public.nexlab_is_admin()
);

drop policy if exists notification_preferences_delete_own
on public.notification_preferences;
drop policy if exists notifications_delete_own
on public.notifications;
drop policy if exists push_subscriptions_select_own
on public.push_subscriptions;
drop policy if exists push_subscriptions_insert_own
on public.push_subscriptions;
drop policy if exists push_subscriptions_update_own
on public.push_subscriptions;
drop policy if exists push_subscriptions_delete_own
on public.push_subscriptions;

drop function if exists public.nexlab_v2674_is_admin();

-- ============================================================
-- CORREÇÃO 6 — VERSÃO E PRONTIDÃO DA LIMPEZA FINAL
-- ============================================================

insert into public.nexlab_app_versions(
  version,title,release_status,notes,installed_at,installed_by
) values (
  '26.24.0',
  'Limpeza Estrutural Final',
  'stable',
  'Realtime técnico alinhado, RLS final consolidada e pacote de publicação normalizado.',
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
      'diagnostic_version','26.24.0',
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
from public, anon;
grant execute on function public.nexlab_get_production_readiness(jsonb)
to authenticated;
