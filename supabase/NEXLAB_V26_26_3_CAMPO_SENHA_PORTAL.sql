-- NEXLAB v26.26.3 — R49
-- Campo de senha administrativa fora da árvore do React.
-- Já aplicado no projeto eahldhabwulnwhuwrhvc.
-- Não executar novamente no mesmo banco.

insert into public.nexlab_app_versions(
  version,title,release_status,notes,installed_at,installed_by
) values (
  '26.26.3',
  'Permissões — Campo de Senha em Portal',
  'stable',
  'Campo de senha administrativa movido para fora da árvore do React e modal redundante adicionado ao salvamento sensível.',
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
language sql
security definer
set search_path = public, auth, pg_temp
as $$
  select public.nexlab_get_production_readiness_v26240_base(
    coalesce(p_client_context,'{}'::jsonb)
  ) || jsonb_build_object('diagnostic_version','26.26.3')
$$;

revoke execute on function public.nexlab_get_production_readiness(jsonb)
from public, anon;

grant execute on function public.nexlab_get_production_readiness(jsonb)
to authenticated;
