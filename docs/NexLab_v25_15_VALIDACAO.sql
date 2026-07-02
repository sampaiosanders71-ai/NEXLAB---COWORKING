-- NexLab v25.15.0 — Validação estrutural

select
  version,
  title,
  release_status,
  installed_at
from public.nexlab_app_versions
where version in (
  '25.14.0',
  '25.15.0'
)
order by version;

select
  p.oid::regprocedure as function_signature,
  has_function_privilege(
    'authenticated',
    p.oid,
    'EXECUTE'
  ) as authenticated_can_execute
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'nexlab_get_production_readiness',
    'nexlab_get_production_readiness_v25_14',
    'nexlab_record_production_snapshot'
  )
order by p.proname;

select
  count(*) as checklist_items,
  count(*) filter (
    where required
  ) as required_items,
  count(*) filter (
    where required
      and completed
  ) as required_completed
from public.nexlab_production_checklist;

select
  check_key,
  label,
  required,
  completed,
  sort_order
from public.nexlab_production_checklist
where check_key in (
  'accessibility_review',
  'responsive_overflow_review',
  'critical_actions_review',
  'permissions_profiles_review',
  'final_logs_review'
)
order by sort_order;

select
  to_regprocedure(
    'public.nexlab_get_production_readiness(jsonb)'
  ) is not null as readiness_v25_15,
  to_regprocedure(
    'public.nexlab_get_production_readiness_v25_14(jsonb)'
  ) is not null as readiness_base_preservada,
  to_regprocedure(
    'public.nexlab_record_production_snapshot(jsonb)'
  ) is not null as snapshot_atualizado;
