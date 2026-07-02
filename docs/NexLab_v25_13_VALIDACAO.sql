-- Validação — NexLab v25.13.0

select
  version,
  title,
  release_status,
  installed_at
from public.nexlab_app_versions
where version in ('25.12.0', '25.12.1', '25.13.0')
order by version;

select
  table_name
from information_schema.tables
where table_schema = 'public'
  and table_name = 'nexlab_report_exports';

select
  routine_name
from information_schema.routines
where routine_schema = 'public'
  and routine_name in (
    'nexlab_can_access_reports',
    'nexlab_record_report_export',
    'nexlab_get_report_export_history'
  )
order by routine_name;

select
  policyname,
  cmd,
  roles
from pg_policies
where schemaname = 'public'
  and tablename = 'nexlab_report_exports';

select
  count(*) as exportacoes_registradas,
  count(*) filter (where confidential) as confidenciais,
  count(*) filter (where file_type = 'pdf') as pdf,
  count(*) filter (where file_type = 'xlsx') as xlsx
from public.nexlab_report_exports;
