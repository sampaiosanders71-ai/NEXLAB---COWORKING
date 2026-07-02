select
  version,
  title,
  release_status,
  installed_at
from public.nexlab_app_versions
where version = '25.12.1';

select
  p.oid::regprocedure as funcao,
  has_function_privilege(
    'authenticated',
    p.oid,
    'EXECUTE'
  ) as authenticated_pode_executar
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'nexlab_get_permission_matrix';

select
  count(*) as usuarios,
  count(*) filter (
    where cardinality(effective_permissions) = 0
  ) as sem_permissoes_calculadas
from public.profiles;

select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'project_tasks'
order by ordinal_position;
