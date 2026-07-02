-- NexLab v25.14.0 — Validação estrutural

select
  version,
  title,
  release_status,
  installed_at
from public.nexlab_app_versions
where version in ('25.13.0', '25.14.0')
order by version;

select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in (
    'nexlab_production_checklist',
    'nexlab_production_snapshots',
    'nexlab_test_cleanup_runs'
  )
order by table_name;

select
  p.oid::regprocedure as function_signature,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'nexlab_get_production_readiness',
    'nexlab_record_production_snapshot',
    'nexlab_update_production_check',
    'nexlab_quarantine_test_profiles'
  )
order by p.proname;

select
  count(*) as checklist_items,
  count(*) filter (where required) as required_items,
  count(*) filter (where required and completed) as required_completed
from public.nexlab_production_checklist;

select
  tablename,
  policyname,
  cmd
from pg_policies
where schemaname = 'public'
  and tablename in (
    'nexlab_production_checklist',
    'nexlab_production_snapshots',
    'nexlab_test_cleanup_runs'
  )
order by tablename, policyname;
