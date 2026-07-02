-- NexLab v25.12.1 — Correções da Matriz e Relatórios
-- Execute no Supabase SQL Editor após a migration corrigida da v25.12.0.
-- Não exige alteração em Edge Functions, Secrets ou Cron.

begin;

do $$
begin
  if to_regclass('public.nexlab_permission_catalog') is null
     or to_regclass('public.nexlab_role_permission_defaults') is null
     or to_regclass('public.nexlab_user_permission_overrides') is null
     or to_regclass('public.nexlab_permission_history') is null
  then
    raise exception 'A estrutura da v25.12.0 ainda não está instalada. Execute primeiro o SQL corrigido da v25.12.0.';
  end if;
end
$$;

create or replace function public.nexlab_get_permission_matrix()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null
     or not public.nexlab_is_admin()
  then
    raise exception 'Ação exclusiva de Administradores.'
      using errcode = '42501';
  end if;

  return jsonb_build_object(
    'catalog',
    coalesce((
      select jsonb_agg(
        to_jsonb(c)
        order by c.category, c.sort_order
      )
      from public.nexlab_permission_catalog c
      where c.active
    ), '[]'::jsonb),

    'defaults',
    coalesce((
      select jsonb_agg(
        to_jsonb(d)
        order by d.role_key, c.sort_order
      )
      from public.nexlab_role_permission_defaults d
      join public.nexlab_permission_catalog c
        on c.permission_key = d.permission_key
      where c.active
    ), '[]'::jsonb),

    'users',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'nome', p.nome,
          'email', p.email,
          'role', p.role::text,
          'ativo', p.ativo,
          'cadastro_completo', p.cadastro_completo,
          'effective_permissions', p.effective_permissions
        )
        order by p.nome nulls last, p.email nulls last
      )
      from public.profiles p
    ), '[]'::jsonb),

    'overrides',
    coalesce((
      select jsonb_agg(
        to_jsonb(o)
        order by o.user_id, c.sort_order
      )
      from public.nexlab_user_permission_overrides o
      join public.nexlab_permission_catalog c
        on c.permission_key = o.permission_key
    ), '[]'::jsonb),

    'history',
    coalesce((
      select jsonb_agg(
        to_jsonb(h)
        order by h.created_at desc
      )
      from (
        select *
        from public.nexlab_permission_history
        order by created_at desc
        limit 80
      ) h
    ), '[]'::jsonb)
  );
end;
$$;

revoke all
on function public.nexlab_get_permission_matrix()
from public;

grant usage on schema public to authenticated;

grant execute
on function public.nexlab_get_permission_matrix()
to authenticated;

-- Recalcula as permissões se a função da v25.12 já estiver disponível.
do $$
begin
  if to_regprocedure('public.nexlab_recalculate_all_permissions()') is not null then
    perform public.nexlab_recalculate_all_permissions();
  end if;
end
$$;

insert into public.nexlab_app_versions (
  version,
  title,
  release_status,
  notes
)
values (
  '25.12.1',
  'Correções da Matriz e Relatórios',
  'rc',
  'Recria a RPC da matriz, força recarga do schema da API e corrige a consulta de tarefas no módulo Relatórios.'
)
on conflict (version) do update
set
  title = excluded.title,
  release_status = excluded.release_status,
  notes = excluded.notes,
  installed_at = now(),
  installed_by = auth.uid();

-- Solicita ao PostgREST/Supabase a atualização imediata do cache de funções.
notify pgrst, 'reload schema';

commit;
