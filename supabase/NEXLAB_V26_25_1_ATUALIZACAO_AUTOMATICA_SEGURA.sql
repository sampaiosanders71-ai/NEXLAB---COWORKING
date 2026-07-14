-- NEXLAB v26.25.1 — R45
-- Sistema de Atualização Automática Segura
-- Projeto: eahldhabwulnwhuwrhvc
-- JÁ APLICADO NO PROJETO ATUAL. NÃO EXECUTAR NOVAMENTE NO MESMO BANCO.

insert into public.nexlab_app_versions(
  version,
  title,
  release_status,
  notes,
  installed_at,
  installed_by
) values (
  '26.25.1',
  'Atualização Automática Segura',
  'stable',
  'Service Worker com instalação atômica, atualização automática quando o app está ocioso, proteção de formulários e coordenação entre abas.',
  now(),
  null
)
on conflict (version) do update
set title = excluded.title,
    release_status = excluded.release_status,
    notes = excluded.notes,
    installed_at = excluded.installed_at;

create or replace function public.nexlab_get_production_readiness(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language sql
security definer
set search_path = public, auth, pg_temp
as $$
  select public.nexlab_get_production_readiness_v26240_base(
    coalesce(p_client_context, '{}'::jsonb)
  ) || jsonb_build_object(
    'diagnostic_version',
    '26.25.1'
  )
$$;

revoke execute
on function public.nexlab_get_production_readiness(jsonb)
from public, anon;

grant execute
on function public.nexlab_get_production_readiness(jsonb)
to authenticated;
