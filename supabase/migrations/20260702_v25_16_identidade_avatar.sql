-- NexLab v25.16.0 — Identidade Visual e Foto de Perfil
-- Execute integralmente no Supabase SQL Editor após a v25.15.0.
-- Cria o bucket público de fotos de perfil, protege upload por usuário,
-- mantém o nome completo no banco e atualiza o diagnóstico para a v25.16.

begin;

-- -----------------------------------------------------------------------------
-- 1. Campos de foto de perfil
-- -----------------------------------------------------------------------------

alter table public.profiles
  add column if not exists avatar_url text null,
  add column if not exists avatar_path text null,
  add column if not exists avatar_updated_at timestamptz null;

alter table public.profiles
  drop constraint if exists profiles_avatar_pair_check;

alter table public.profiles
  add constraint profiles_avatar_pair_check
  check (
    (avatar_url is null and avatar_path is null)
    or
    (avatar_url is not null and avatar_path is not null)
  );

-- -----------------------------------------------------------------------------
-- 2. Bucket oficial para fotos de perfil
-- -----------------------------------------------------------------------------

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'profile-photos',
  'profile-photos',
  true,
  5242880,
  array[
    'image/jpeg',
    'image/png',
    'image/webp'
  ]::text[]
)
on conflict (id) do update
set
  name = excluded.name,
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Leitura autenticada dos objetos do bucket.
drop policy if exists nexlab_profile_photos_select
on storage.objects;

create policy nexlab_profile_photos_select
on storage.objects
for select
to authenticated
using (
  bucket_id = 'profile-photos'
);

-- Cada usuário envia somente para sua própria pasta: <auth.uid()>/arquivo.ext
drop policy if exists nexlab_profile_photos_insert_own
on storage.objects;

create policy nexlab_profile_photos_insert_own
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'profile-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- Permite substituir metadados somente dentro da própria pasta.
drop policy if exists nexlab_profile_photos_update_own
on storage.objects;

create policy nexlab_profile_photos_update_own
on storage.objects
for update
to authenticated
using (
  bucket_id = 'profile-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'profile-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- Permite remover somente arquivos da própria pasta.
drop policy if exists nexlab_profile_photos_delete_own
on storage.objects;

create policy nexlab_profile_photos_delete_own
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'profile-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- -----------------------------------------------------------------------------
-- 3. RPC segura para registrar ou remover a foto do próprio perfil
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_update_profile_avatar(
  p_avatar_url text default null,
  p_avatar_path text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, storage
as $$
declare
  normalized_url text := nullif(btrim(coalesce(p_avatar_url, '')), '');
  normalized_path text := nullif(btrim(coalesce(p_avatar_path, '')), '');
  updated_profile public.profiles%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.'
      using errcode = '42501';
  end if;

  if (normalized_url is null) <> (normalized_path is null) then
    raise exception 'URL e caminho da foto devem ser informados juntos.'
      using errcode = '22023';
  end if;

  if normalized_url is not null then
    if length(normalized_url) > 2048 then
      raise exception 'A URL da foto é muito longa.'
        using errcode = '22023';
    end if;

    if length(normalized_path) > 512 then
      raise exception 'O caminho da foto é muito longo.'
        using errcode = '22023';
    end if;

    if normalized_path not like auth.uid()::text || '/%' then
      raise exception 'A foto precisa estar na pasta do próprio usuário.'
        using errcode = '42501';
    end if;

    if normalized_path like '%..%' then
      raise exception 'Caminho de foto inválido.'
        using errcode = '22023';
    end if;

    if not exists (
      select 1
      from storage.objects object_row
      where object_row.bucket_id = 'profile-photos'
        and object_row.name = normalized_path
    ) then
      raise exception 'O arquivo enviado não foi encontrado no Storage.'
        using errcode = 'P0002';
    end if;
  end if;

  update public.profiles
  set
    avatar_url = normalized_url,
    avatar_path = normalized_path,
    avatar_updated_at = case
      when normalized_url is null then null
      else now()
    end
  where id::text = auth.uid()::text
  returning * into updated_profile;

  if updated_profile.id is null then
    raise exception 'Perfil do NexLab não encontrado.'
      using errcode = 'P0002';
  end if;

  begin
    perform public.record_security_audit(
      case
        when normalized_url is null then 'profile_avatar_removed'
        else 'profile_avatar_updated'
      end,
      auth.uid()::text,
      jsonb_build_object(
        'avatar_path', normalized_path,
        'updated_at', updated_profile.avatar_updated_at
      )
    );
  exception
    when undefined_function then null;
    when others then null;
  end;

  return to_jsonb(updated_profile);
end;
$$;

revoke all
on function public.nexlab_update_profile_avatar(text, text)
from public;

grant execute
on function public.nexlab_update_profile_avatar(text, text)
to authenticated;

-- -----------------------------------------------------------------------------
-- 4. Diagnóstico de prontidão atualizado para a v25.16
-- -----------------------------------------------------------------------------

do $$
begin
  if to_regprocedure(
    'public.nexlab_get_production_readiness_v25_15(jsonb)'
  ) is null then
    if to_regprocedure(
      'public.nexlab_get_production_readiness(jsonb)'
    ) is null then
      raise exception 'A função de prontidão da v25.15 não foi encontrada.';
    end if;

    execute 'alter function public.nexlab_get_production_readiness(jsonb) rename to nexlab_get_production_readiness_v25_15';
  end if;
end
$$;

revoke all
on function public.nexlab_get_production_readiness_v25_15(jsonb)
from public;

create or replace function public.nexlab_get_production_readiness(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, cron
as $$
declare
  expected_version constant text := '25.16.0';
  base_result jsonb;
  patched_checks jsonb := '[]'::jsonb;
  database_version text;
  client_version text;
  required_checks integer := 0;
  passed_checks integer := 0;
  blocking_checks integer := 0;
  attention_checks integer := 0;
  score integer := 0;
  readiness_status text := 'attention';
begin
  if auth.uid() is null
     or not public.nexlab_is_admin()
  then
    raise exception 'Ação exclusiva de Administradores.'
      using errcode = '42501';
  end if;

  base_result :=
    public.nexlab_get_production_readiness_v25_15(
      coalesce(p_client_context, '{}'::jsonb)
    );

  database_version := coalesce(
    base_result->>'database_version',
    'não registrada'
  );

  client_version := coalesce(
    nullif(
      coalesce(p_client_context, '{}'::jsonb)
        ->>'client_app_version',
      ''
    ),
    'não informado'
  );

  select coalesce(
    jsonb_agg(
      case
        when item->>'id' = 'version' then
          item || jsonb_build_object(
            'status',
            case
              when database_version = expected_version
               and client_version = expected_version
                then 'pass'
              else 'fail'
            end,
            'message',
            format(
              'Banco: v%s • Aplicativo: v%s • Esperado: v%s',
              database_version,
              client_version,
              expected_version
            )
          )
        else item
      end
    ),
    '[]'::jsonb
  )
  into patched_checks
  from jsonb_array_elements(
    coalesce(base_result->'checks', '[]'::jsonb)
  ) item;

  select
    count(*) filter (
      where coalesce((item->>'required')::boolean, false)
    ),
    count(*) filter (
      where coalesce((item->>'required')::boolean, false)
        and item->>'status' = 'pass'
    ),
    count(*) filter (
      where coalesce((item->>'required')::boolean, false)
        and item->>'status' = 'fail'
    ),
    count(*) filter (
      where item->>'status' in ('pending', 'warning')
    )
  into
    required_checks,
    passed_checks,
    blocking_checks,
    attention_checks
  from jsonb_array_elements(patched_checks) item;

  score := case
    when required_checks = 0 then 0
    else floor(
      (passed_checks::numeric / required_checks::numeric) * 100
    )::integer
  end;

  readiness_status := case
    when blocking_checks > 0 then 'blocked'
    when passed_checks = required_checks then 'ready'
    else 'attention'
  end;

  base_result := jsonb_set(
    base_result,
    '{expected_version}',
    to_jsonb(expected_version),
    true
  );

  base_result := jsonb_set(
    base_result,
    '{client_context}',
    coalesce(p_client_context, '{}'::jsonb),
    true
  );

  base_result := jsonb_set(
    base_result,
    '{checks}',
    patched_checks,
    true
  );

  base_result := jsonb_set(
    base_result,
    '{score}',
    to_jsonb(score),
    true
  );

  base_result := jsonb_set(
    base_result,
    '{status}',
    to_jsonb(readiness_status),
    true
  );

  base_result := jsonb_set(
    base_result,
    '{summary}',
    jsonb_build_object(
      'required_checks', required_checks,
      'passed_checks', passed_checks,
      'blocking_checks', blocking_checks,
      'attention_checks', attention_checks
    ),
    true
  );

  return base_result;
end;
$$;

revoke all
on function public.nexlab_get_production_readiness(jsonb)
from public;

grant execute
on function public.nexlab_get_production_readiness(jsonb)
to authenticated;

create or replace function public.nexlab_record_production_snapshot(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  readiness jsonb;
  snapshot_id uuid;
begin
  if auth.uid() is null
     or not public.nexlab_is_admin()
  then
    raise exception 'Ação exclusiva de Administradores.'
      using errcode = '42501';
  end if;

  readiness := public.nexlab_get_production_readiness(
    coalesce(p_client_context, '{}'::jsonb)
  );

  insert into public.nexlab_production_snapshots (
    app_version,
    readiness_status,
    score,
    client_context,
    snapshot,
    created_by
  )
  values (
    coalesce(readiness->>'database_version', '25.16.0'),
    readiness->>'status',
    coalesce((readiness->>'score')::integer, 0),
    coalesce(p_client_context, '{}'::jsonb),
    readiness,
    auth.uid()
  )
  returning id into snapshot_id;

  perform public.nexlab_record_system_event(
    'production_readiness_snapshot',
    case
      when readiness->>'status' = 'ready' then 'success'
      else 'warning'
    end,
    format(
      'Diagnóstico de prontidão v25.16 registrado com pontuação %s%%.',
      readiness->>'score'
    ),
    jsonb_build_object(
      'snapshot_id', snapshot_id,
      'status', readiness->>'status',
      'score', readiness->>'score',
      'app_version', readiness->>'database_version'
    )
  );

  return jsonb_build_object(
    'ok', true,
    'snapshot_id', snapshot_id,
    'readiness', readiness
  );
end;
$$;

revoke all
on function public.nexlab_record_production_snapshot(jsonb)
from public;

grant execute
on function public.nexlab_record_production_snapshot(jsonb)
to authenticated;

-- -----------------------------------------------------------------------------
-- 5. Registro da versão
-- -----------------------------------------------------------------------------

update public.nexlab_app_versions
set
  release_status = 'stable',
  notes = 'Versão testada e aprovada. Revisão final e acabamento para publicação validados.'
where version = '25.15.0';

insert into public.nexlab_app_versions (
  version,
  title,
  release_status,
  notes
)
values (
  '25.16.0',
  'Identidade Visual e Foto de Perfil',
  'rc',
  'Aplica a marca oficial do NexLab, adiciona foto de perfil segura e exibe apenas o primeiro nome nas áreas pessoais da interface, preservando o nome completo em relatórios e áreas administrativas.'
)
on conflict (version) do update
set
  title = excluded.title,
  release_status = excluded.release_status,
  notes = excluded.notes,
  installed_at = now(),
  installed_by = auth.uid();

notify pgrst, 'reload schema';

commit;
