-- NEXLAB v26.9.0 — Estabilização completa do módulo Equipes
-- Correções consolidadas 1 a 8.

begin;

-- Correções 6 e 7: índices de apoio e remoção de redundância.
create index if not exists team_members_user_team_idx
  on public.team_members(user_id, team_id);

create index if not exists team_members_added_by_idx
  on public.team_members(adicionado_por)
  where adicionado_por is not null;

create index if not exists teams_archived_by_idx
  on public.teams(archived_by)
  where archived_by is not null;

create index if not exists meetings_team_id_idx
  on public.meetings(team_id)
  where team_id is not null;

drop index if exists public.uq_nexlab_team_members_pair;

-- Correção 8: remove políticas permissivas genéricas que anulavam as regras
-- específicas e recria as políticas com chamadas estáveis inicializadas uma vez.
drop policy if exists nexlab_approved_account_gate on public.teams;
drop policy if exists nexlab_approved_account_gate on public.team_members;

drop policy if exists teams_v2680_select on public.teams;
create policy teams_v2680_select
on public.teams
for select
to authenticated
using (
  (select public.nexlab_has_approved_access())
  and (select public.nexlab_has_effective_permission_v2680('module_equipes'))
  and (
    (select public.nexlab_can_view_all_teams_v2680())
    or lider_id = (select auth.uid())
    or public.nexlab_user_is_team_member_v2680(id, (select auth.uid()))
  )
);

drop policy if exists teams_v2680_insert on public.teams;
create policy teams_v2680_insert
on public.teams
for insert
to authenticated
with check (
  (select public.nexlab_has_approved_access())
  and (select public.nexlab_can_create_team_v2680())
  and archived_at is null
  and (
    (select public.nexlab_is_admin_v2680())
    or lider_id = (select auth.uid())
  )
);

drop policy if exists teams_v2680_update on public.teams;
create policy teams_v2680_update
on public.teams
for update
to authenticated
using (public.nexlab_can_manage_team_v2680(id))
with check (
  (select public.nexlab_has_approved_access())
  and (
    (select public.nexlab_is_admin_v2680())
    or lider_id = (select auth.uid())
  )
);

drop policy if exists teams_v2680_delete on public.teams;
create policy teams_v2680_delete
on public.teams
for delete
to authenticated
using (
  (select public.nexlab_has_approved_access())
  and (select public.nexlab_is_admin_v2680())
);

drop policy if exists team_members_v2680_select on public.team_members;
create policy team_members_v2680_select
on public.team_members
for select
to authenticated
using (
  (select public.nexlab_has_approved_access())
  and (select public.nexlab_has_effective_permission_v2680('module_equipes'))
  and (
    (select public.nexlab_can_view_all_teams_v2680())
    or user_id = (select auth.uid())
    or public.nexlab_user_is_team_member_v2680(team_id, (select auth.uid()))
  )
);

drop policy if exists team_members_v2680_insert on public.team_members;
create policy team_members_v2680_insert
on public.team_members
for insert
to authenticated
with check (
  (select public.nexlab_has_approved_access())
  and public.nexlab_can_manage_team_v2680(team_id)
);

drop policy if exists team_members_v2680_update on public.team_members;
create policy team_members_v2680_update
on public.team_members
for update
to authenticated
using (public.nexlab_can_manage_team_v2680(team_id))
with check (
  (select public.nexlab_has_approved_access())
  and public.nexlab_can_manage_team_v2680(team_id)
);

drop policy if exists team_members_v2680_delete on public.team_members;
create policy team_members_v2680_delete
on public.team_members
for delete
to authenticated
using (
  (select public.nexlab_has_approved_access())
  and public.nexlab_can_manage_team_v2680(team_id)
);

drop policy if exists team_links_v2680_select on public.team_links;
create policy team_links_v2680_select
on public.team_links
for select
to authenticated
using (
  (select public.nexlab_has_approved_access())
  and public.nexlab_can_view_team_v2680(team_id)
);

-- Correção 2: o catálogo de vínculos é calculado no servidor. Assim, um
-- evento ligado a outra equipe não é oferecido mesmo quando o vínculo alheio
-- não está visível ao usuário pelas políticas RLS.
create or replace function public.nexlab_get_team_workspace_v2680(
  p_team_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  history_result jsonb;
  links_result jsonb;
  available_result jsonb := '[]'::jsonb;
  can_manage_value boolean;
begin
  if not public.nexlab_can_view_team_v2680(p_team_id) then
    raise exception
      'Você não possui acesso aos detalhes desta equipe.'
      using errcode = '42501';
  end if;

  can_manage_value := public.nexlab_can_manage_team_v2680(p_team_id);

  select coalesce(
    jsonb_agg(
      to_jsonb(history_row)
      order by history_row.created_at desc
    ),
    '[]'::jsonb
  ) into history_result
  from (
    select
      h.id,
      h.action,
      h.description,
      h.actor_id,
      h.actor_name,
      h.metadata,
      h.created_at
    from public.team_history h
    where h.team_id = p_team_id
    order by h.created_at desc
    limit 100
  ) history_row;

  select coalesce(
    jsonb_agg(
      to_jsonb(link_row)
      order by link_row.entity_type, link_row.label
    ),
    '[]'::jsonb
  ) into links_result
  from (
    select
      tl.id,
      tl.entity_type,
      tl.entity_id,
      public.nexlab_team_entity_label_v2680(
        tl.entity_type,
        tl.entity_id
      ) as label,
      case tl.entity_type
        when 'project' then (
          select concat_ws(
            ' • ',
            nullif(p.status, ''),
            case when p.prazo is not null then to_char(p.prazo, 'DD/MM/YYYY') end
          )
          from public.projects p
          where p.id = tl.entity_id
        )
        when 'event' then (
          select concat_ws(
            ' • ',
            to_char(e.data, 'DD/MM/YYYY'),
            nullif(e.local, '')
          )
          from public.events e
          where e.id = tl.entity_id
        )
        when 'meeting' then (
          select concat_ws(
            ' • ',
            to_char(m.data, 'DD/MM/YYYY'),
            nullif(m.status, '')
          )
          from public.meetings m
          where m.id = tl.entity_id
        )
      end as subtitle,
      tl.created_by,
      tl.created_at,
      tl.updated_at
    from public.team_links tl
    where tl.team_id = p_team_id
  ) link_row;

  if can_manage_value then
    select coalesce(jsonb_agg(candidate.entity_key order by candidate.entity_key), '[]'::jsonb)
      into available_result
    from (
      select 'project:' || p.id::text as entity_key
      from public.projects p
      where (p.equipe_id is null or p.equipe_id = p_team_id)
        and not exists (
          select 1
          from public.team_links tl
          where tl.entity_type = 'project'
            and tl.entity_id = p.id
            and tl.team_id <> p_team_id
        )

      union all

      select 'event:' || e.id::text as entity_key
      from public.events e
      where not exists (
        select 1
        from public.team_links tl
        where tl.entity_type = 'event'
          and tl.entity_id = e.id
          and tl.team_id <> p_team_id
      )

      union all

      select 'meeting:' || m.id::text as entity_key
      from public.meetings m
      where (m.team_id is null or m.team_id = p_team_id)
        and not exists (
          select 1
          from public.team_links tl
          where tl.entity_type = 'meeting'
            and tl.entity_id = m.id
            and tl.team_id <> p_team_id
        )
    ) candidate;
  end if;

  return jsonb_build_object(
    'team_id', p_team_id,
    'history', history_result,
    'links', links_result,
    'available_entity_keys', available_result,
    'can_manage', can_manage_value,
    'loaded_at', now()
  );
end;
$$;

revoke all on function public.nexlab_get_team_workspace_v2680(uuid)
from public, anon;
grant execute on function public.nexlab_get_team_workspace_v2680(uuid)
to authenticated;

comment on function public.nexlab_get_team_workspace_v2680(uuid)
is 'Retorna histórico, vínculos e catálogo seguro de registros disponíveis para a equipe.';

commit;
