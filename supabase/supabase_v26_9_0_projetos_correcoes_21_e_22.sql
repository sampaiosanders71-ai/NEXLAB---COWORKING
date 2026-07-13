-- NEXLAB v26.9.0 — Estabilização final do módulo Projetos
-- Correções 21 e 22:
-- 21. padronização da estrutura de equipes e deduplicação visual da Central de Atividades;
-- 22. rollback concorrente endurecido, privacidade por escopo, RLS, índices e ajustes finais.

begin;

-- ---------------------------------------------------------------------------
-- Escopo completo versus acesso restrito por tarefa atribuída.
-- ---------------------------------------------------------------------------
create or replace function public.nexlab_can_view_project_full_v2690(
  p_project_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select
    public.nexlab_has_approved_access()
    and public.nexlab_has_project_permission_v2690('module_projetos')
    and exists (
      select 1
      from public.projects pr
      where pr.id = p_project_id
        and (
          public.nexlab_has_project_permission_v2690('projects_view_all')
          or public.nexlab_has_project_permission_v2690('projects_manage_all')
          or pr.autor_id = auth.uid()
          or pr.responsavel_id = auth.uid()
          or exists (
            select 1
            from public.team_members tm
            where tm.team_id = pr.equipe_id
              and tm.user_id = auth.uid()
          )
        )
    );
$$;

create or replace function public.nexlab_can_view_project_v2690(
  p_project_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select
    public.nexlab_can_view_project_full_v2690(p_project_id)
    or (
      public.nexlab_has_approved_access()
      and public.nexlab_has_project_permission_v2690('module_projetos')
      and exists (
        select 1
        from public.project_tasks task
        where task.project_id = p_project_id
          and task.responsavel_id = auth.uid()
      )
    );
$$;

revoke all on function public.nexlab_can_view_project_full_v2690(uuid)
from public, anon;
grant execute on function public.nexlab_can_view_project_full_v2690(uuid)
to authenticated;

revoke all on function public.nexlab_can_view_project_v2690(uuid)
from public, anon;
grant execute on function public.nexlab_can_view_project_v2690(uuid)
to authenticated;

-- ---------------------------------------------------------------------------
-- RLS de menor privilégio.
-- ---------------------------------------------------------------------------
alter table public.projects enable row level security;
alter table public.project_tasks enable row level security;
alter table public.project_history enable row level security;
alter table public.project_links enable row level security;

drop policy if exists project_tasks_v2690_select on public.project_tasks;
create policy project_tasks_v2690_select
on public.project_tasks
for select
to authenticated
using (
  public.nexlab_can_view_project_full_v2690(project_id)
  or responsavel_id = auth.uid()
);

drop policy if exists project_history_v2690_select on public.project_history;
create policy project_history_v2690_select
on public.project_history
for select
to authenticated
using (public.nexlab_can_view_project_full_v2690(project_id));

drop policy if exists project_links_v2690_select on public.project_links;
create policy project_links_v2690_select
on public.project_links
for select
to authenticated
using (public.nexlab_can_view_project_full_v2690(project_id));

-- ---------------------------------------------------------------------------
-- Índices dos caminhos usados por RLS, workspace e Central de Atividades.
-- ---------------------------------------------------------------------------
create index if not exists projects_author_id_idx
  on public.projects(autor_id)
  where autor_id is not null;

create index if not exists projects_responsible_id_idx
  on public.projects(responsavel_id)
  where responsavel_id is not null;

create index if not exists projects_team_id_idx
  on public.projects(equipe_id)
  where equipe_id is not null;

create index if not exists projects_deadline_status_idx
  on public.projects(prazo, status)
  where prazo is not null;

create index if not exists project_tasks_responsible_project_idx
  on public.project_tasks(responsavel_id, project_id)
  where responsavel_id is not null;

create index if not exists project_tasks_project_done_created_idx
  on public.project_tasks(project_id, done, created_at, id);

create index if not exists team_members_user_team_idx
  on public.team_members(user_id, team_id);

create index if not exists project_links_project_entity_idx
  on public.project_links(project_id, entity_type, entity_id);

create index if not exists logs_created_at_idx
  on public.logs(created_at desc);

create index if not exists security_audit_logs_created_at_idx
  on public.security_audit_logs(created_at desc);

-- ---------------------------------------------------------------------------
-- Workspace protegido e status das reuniões.
-- ---------------------------------------------------------------------------
create or replace function public.nexlab_get_project_workspace_v2690(
  p_project_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  current_project public.projects%rowtype;
  project_data jsonb;
  tasks_data jsonb;
  history_data jsonb;
  team_data jsonb;
  participants_data jsonb;
  agenda_data jsonb;
  attachments_data jsonb;
  links_data jsonb;
  available_events_data jsonb;
  available_meetings_data jsonb;
  can_manage_value boolean;
  full_access_value boolean;
  task_only_access boolean;
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null
     or not public.nexlab_can_view_project_v2690(p_project_id)
  then
    raise exception 'Você não possui acesso a este projeto.'
      using errcode = '42501';
  end if;

  select pr.*
    into current_project
  from public.projects pr
  where pr.id = p_project_id;

  if current_project.id is null then
    raise exception 'Projeto não encontrado.'
      using errcode = 'P0002';
  end if;

  can_manage_value :=
    public.nexlab_can_manage_project_v2690(p_project_id);

  full_access_value :=
    public.nexlab_can_view_project_full_v2690(p_project_id);

  task_only_access := not full_access_value;

  select
    (
      case
        when full_access_value then to_jsonb(pr)
        else jsonb_build_object(
          'id', pr.id,
          'nome', pr.nome,
          'descricao', pr.descricao,
          'status', pr.status,
          'prioridade', pr.prioridade,
          'prazo', pr.prazo,
          'responsavel_id', pr.responsavel_id,
          'equipe_id', pr.equipe_id,
          'created_at', pr.created_at,
          'updated_at', pr.updated_at
        )
      end
    )
    || jsonb_build_object(
      'responsible_name', responsible_profile.nome,
      'author_name', case when full_access_value then author_profile.nome else null end,
      'team_name', team_record.nome,
      'team_area', case when full_access_value then team_record.area else null end
    )
    into project_data
  from public.projects pr
  left join public.profiles responsible_profile
    on responsible_profile.id = pr.responsavel_id
  left join public.profiles author_profile
    on author_profile.id = pr.autor_id
  left join public.teams team_record
    on team_record.id = pr.equipe_id
  where pr.id = p_project_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', task.id,
        'title', task.titulo,
        'done', task.done,
        'responsible_id', task.responsavel_id,
        'responsible_name', task_responsible.nome,
        'created_at', task.created_at,
        'can_toggle', can_manage_value or task.responsavel_id = current_user_id,
        'can_edit', can_manage_value,
        'can_delete', can_manage_value
      )
      order by task.done, task.created_at, task.id
    ),
    '[]'::jsonb
  )
    into tasks_data
  from public.project_tasks task
  left join public.profiles task_responsible
    on task_responsible.id = task.responsavel_id
  where task.project_id = p_project_id
    and (full_access_value or task.responsavel_id = current_user_id);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', history.id,
        'action', history.action,
        'description', history.description,
        'actor_id', history.actor_id,
        'actor_name', history.actor_name,
        'metadata', history.metadata,
        'created_at', history.created_at
      )
      order by history.created_at desc, history.id desc
    ),
    '[]'::jsonb
  )
    into history_data
  from (
    select ph.*
    from public.project_history ph
    where ph.project_id = p_project_id
      and full_access_value
    order by ph.created_at desc, ph.id desc
    limit 100
  ) history;

  select case
    when team_record.id is null then null
    else jsonb_build_object(
      'id', team_record.id,
      'name', team_record.nome,
      'area', team_record.area,
      'leader_id', team_record.lider_id,
      'archived_at', team_record.archived_at
    )
  end
    into team_data
  from (select 1) anchor
  left join public.teams team_record
    on full_access_value
   and team_record.id = current_project.equipe_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id', tm.user_id,
        'name', member_profile.nome,
        'role', tm.funcao,
        'joined_at', tm.created_at
      )
      order by
        case tm.funcao
          when 'responsavel' then 1
          when 'vice_responsavel' then 2
          when 'organizador' then 3
          else 4
        end,
        lower(coalesce(member_profile.nome, ''))
    ),
    '[]'::jsonb
  )
    into participants_data
  from public.team_members tm
  left join public.profiles member_profile
    on member_profile.id = tm.user_id
  where full_access_value
    and tm.team_id = current_project.equipe_id;

  -- Itens já vinculados diretamente ao projeto são excluídos da agenda da equipe.
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'type', link.entity_type,
        'id', link.entity_id,
        'title', case link.entity_type
          when 'event' then event_record.titulo
          when 'meeting' then meeting_record.titulo
        end,
        'date', case link.entity_type
          when 'event' then event_record.data
          when 'meeting' then meeting_record.data
        end,
        'time', case link.entity_type
          when 'event' then event_record.hora::text
          when 'meeting' then meeting_record.hora::text
        end,
        'location', case link.entity_type
          when 'event' then event_record.local
          when 'meeting' then meeting_record.local
        end,
        'status', case link.entity_type
          when 'meeting' then meeting_record.status
          else null
        end,
        'source', 'team'
      )
      order by
        case link.entity_type
          when 'event' then event_record.data
          when 'meeting' then meeting_record.data
        end nulls last,
        link.created_at
    ),
    '[]'::jsonb
  )
    into agenda_data
  from public.team_links link
  left join public.events event_record
    on link.entity_type = 'event'
   and event_record.id = link.entity_id
  left join public.meetings meeting_record
    on link.entity_type = 'meeting'
   and meeting_record.id = link.entity_id
  where full_access_value
    and link.team_id = current_project.equipe_id
    and link.entity_type in ('event', 'meeting')
    and not exists (
      select 1
      from public.project_links direct_link
      where direct_link.project_id = p_project_id
        and direct_link.entity_type = link.entity_type
        and direct_link.entity_id = link.entity_id
    );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', attachment.id,
        'title', attachment.titulo,
        'url', attachment.url,
        'type', attachment.tipo,
        'created_at', attachment.created_at
      )
      order by attachment.created_at desc, attachment.id desc
    ),
    '[]'::jsonb
  )
    into attachments_data
  from public.attachments attachment
  where full_access_value
    and attachment.modulo in ('projetos', 'projects', 'project')
    and attachment.record_id = p_project_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'link_id', pl.id,
        'type', pl.entity_type,
        'id', pl.entity_id,
        'title', case pl.entity_type
          when 'event' then ev.titulo
          when 'meeting' then mt.titulo
        end,
        'date', case pl.entity_type
          when 'event' then ev.data
          when 'meeting' then mt.data
        end,
        'time', case pl.entity_type
          when 'event' then ev.hora::text
          when 'meeting' then mt.hora::text
        end,
        'location', case pl.entity_type
          when 'event' then ev.local
          when 'meeting' then mt.local
        end,
        'status', case pl.entity_type
          when 'meeting' then mt.status
          else null
        end,
        'created_at', pl.created_at,
        'source', 'project'
      )
      order by
        pl.entity_type,
        case pl.entity_type
          when 'event' then ev.data
          when 'meeting' then mt.data
        end nulls last,
        pl.created_at
    ),
    '[]'::jsonb
  )
    into links_data
  from public.project_links pl
  left join public.events ev
    on pl.entity_type = 'event'
   and ev.id = pl.entity_id
  left join public.meetings mt
    on pl.entity_type = 'meeting'
   and mt.id = pl.entity_id
  where full_access_value
    and pl.project_id = p_project_id;

  if can_manage_value then
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', ev.id,
          'title', ev.titulo,
          'date', ev.data,
          'time', ev.hora::text,
          'location', ev.local
        )
        order by ev.data asc, ev.hora asc nulls last, ev.titulo
      ),
      '[]'::jsonb
    )
      into available_events_data
    from public.events ev
    where ev.data >= current_date
      and not exists (
        select 1
        from public.project_links pl
        where pl.entity_type = 'event'
          and pl.entity_id = ev.id
      );

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', mt.id,
          'title', mt.titulo,
          'date', mt.data,
          'time', mt.hora::text,
          'location', mt.local,
          'status', mt.status
        )
        order by mt.data asc, mt.hora asc nulls last, mt.titulo
      ),
      '[]'::jsonb
    )
      into available_meetings_data
    from public.meetings mt
    where mt.data >= current_date
      and lower(btrim(coalesce(mt.status, ''))) = 'agendada'
      and mt.cancelada_em is null
      and not exists (
        select 1
        from public.project_links pl
        where pl.entity_type = 'meeting'
          and pl.entity_id = mt.id
      );
  else
    available_events_data := '[]'::jsonb;
    available_meetings_data := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'ok', true,
    'project', project_data,
    'tasks', tasks_data,
    'history', history_data,
    'team', team_data,
    'participants', participants_data,
    'agenda', agenda_data,
    'attachments', attachments_data,
    'links', links_data,
    'available_events', available_events_data,
    'available_meetings', available_meetings_data,
    'access_scope', case when task_only_access then 'task_only' else 'full' end,
    'privacy_limited', task_only_access,
    'permissions', jsonb_build_object(
      'can_view', true,
      'can_view_full', full_access_value,
      'can_manage', can_manage_value,
      'can_delete', public.nexlab_can_delete_project_v2690(p_project_id),
      'can_create', public.nexlab_can_create_project_v2690()
    ),
    'deduplicated_agenda', true,
    'generated_at', now()
  );
end;
$$;

revoke all on function public.nexlab_get_project_workspace_v2690(uuid)
from public, anon;
grant execute on function public.nexlab_get_project_workspace_v2690(uuid)
to authenticated;

comment on function public.nexlab_can_view_project_full_v2690(uuid)
is 'Distingue acesso completo ao projeto do acesso concedido apenas por tarefa atribuída.';

comment on function public.nexlab_get_project_workspace_v2690(uuid)
is 'Retorna workspace completo para usuários autorizados e uma visão mínima somente com tarefas próprias para responsáveis por tarefa.';

commit;
