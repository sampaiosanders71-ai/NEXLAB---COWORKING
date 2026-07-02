-- NexLab v25.12.0 — Validação pós-migration

select version, title, release_status, installed_at
from public.nexlab_app_versions
where version in ('25.11.0','25.11.1','25.12.0')
order by version;

select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in (
    'nexlab_permission_catalog',
    'nexlab_role_permission_defaults',
    'nexlab_user_permission_overrides',
    'nexlab_permission_history'
  )
order by table_name;

select routine_name
from information_schema.routines
where routine_schema = 'public'
  and routine_name in (
    'nexlab_recalculate_profile_permissions',
    'nexlab_recalculate_all_permissions',
    'nexlab_get_permission_matrix',
    'nexlab_admin_save_role_permissions',
    'nexlab_admin_save_user_permissions',
    'nexlab_admin_restore_user_permissions'
  )
order by routine_name;

select tgname as trigger, tgrelid::regclass as tabela, tgenabled as ativo
from pg_trigger
where not tgisinternal
  and tgname in (
    'nexlab_recalculate_permissions_after_profile_insert_trigger',
    'nexlab_recalculate_permissions_after_role_change_trigger'
  )
order by tgname;

select role_key,
       count(*) filter (where allowed) as permitidas,
       count(*) filter (where not allowed) as bloqueadas
from public.nexlab_role_permission_defaults
group by role_key
order by role_key;

select
  count(*) as usuarios,
  count(*) filter (where cardinality(effective_permissions) = 0) as sem_permissoes_calculadas,
  count(*) filter (where 'module_perfil' = any(effective_permissions)) as com_perfil_essencial
from public.profiles;

select nome, role::text as perfil, effective_permissions
from public.profiles
order by nome nulls last;
