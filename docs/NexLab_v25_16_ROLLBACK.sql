-- NexLab v25.16.0 — Reversão conservadora
-- Mantém as colunas, o bucket e as fotos para evitar perda de dados.

begin;

drop function if exists public.nexlab_get_production_readiness(jsonb);

alter function public.nexlab_get_production_readiness_v25_15(jsonb)
  rename to nexlab_get_production_readiness;

grant execute
on function public.nexlab_get_production_readiness(jsonb)
to authenticated;

drop function if exists public.nexlab_update_profile_avatar(text, text);

delete from public.nexlab_app_versions
where version = '25.16.0';

update public.nexlab_app_versions
set release_status = 'stable'
where version = '25.15.0';

notify pgrst, 'reload schema';

commit;
