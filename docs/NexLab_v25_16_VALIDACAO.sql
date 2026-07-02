-- NexLab v25.16.0 — Validação estrutural

select
  version,
  title,
  release_status,
  installed_at
from public.nexlab_app_versions
where version in ('25.15.0', '25.16.0')
order by version;

select
  column_name,
  data_type
from information_schema.columns
where table_schema = 'public'
  and table_name = 'profiles'
  and column_name in (
    'avatar_url',
    'avatar_path',
    'avatar_updated_at'
  )
order by column_name;

select
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
from storage.buckets
where id = 'profile-photos';

select
  policyname,
  cmd,
  roles
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
  and policyname like 'nexlab_profile_photos_%'
order by policyname;

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
    'nexlab_update_profile_avatar',
    'nexlab_get_production_readiness',
    'nexlab_get_production_readiness_v25_15',
    'nexlab_record_production_snapshot'
  )
order by p.proname;

select
  count(*) as perfis,
  count(*) filter (
    where avatar_url is not null
      and avatar_path is not null
  ) as perfis_com_foto,
  count(*) filter (
    where (avatar_url is null) <> (avatar_path is null)
  ) as pares_inconsistentes
from public.profiles;
