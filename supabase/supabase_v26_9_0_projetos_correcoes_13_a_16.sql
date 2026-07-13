-- NEXLAB v26.9.0 — Estabilização do módulo Projetos
-- Correções 13 a 16:
-- 13. deduplicação entre vínculos diretos e agenda da equipe;
-- 14. gestão completa das tarefas;
-- 15. redução de recarregamentos repetidos do painel;
-- 16. simplificação da cadeia de atualização dos vínculos.

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

  select
    to_jsonb(pr)
    || jsonb_build_object(
      'responsible_name', responsible_profile.nome,
      'author_name', author_profile.nome,
      'team_name', team_record.nome,
      'team_area', team_record.area
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
  where task.project_id = p_project_id;

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
    on team_record.id = current_project.equipe_id;

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
  where tm.team_id = current_project.equipe_id;

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
  where link.team_id = current_project.equipe_id
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
  where attachment.modulo in ('projetos', 'projects', 'project')
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
  where pl.project_id = p_project_id;

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
    'permissions', jsonb_build_object(
      'can_view', true,
      'can_manage', can_manage_value,
      'can_delete', public.nexlab_can_delete_project_v2690(p_project_id),
      'can_create', public.nexlab_can_create_project_v2690()
    ),
    'deduplicated_agenda', true,
    'generated_at', now()
  );
end;
$$;

revoke all
on function public.nexlab_get_project_workspace_v2690(uuid)
from public, anon;

grant execute
on function public.nexlab_get_project_workspace_v2690(uuid)
to authenticated;

create or replace function public.nexlab_manage_project_task_v2690(
  p_project_id uuid,
  p_action text,
  p_task_id uuid default null,
  p_title text default null,
  p_responsible_id uuid default null,
  p_done boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  normalized_action text := lower(btrim(coalesce(p_action, '')));
  normalized_title text := nullif(btrim(coalesce(p_title, '')), '');
  task_record public.project_tasks%rowtype;
  changed_task jsonb := null;
  affected integer := 0;
  can_manage_value boolean;
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null
     or not public.nexlab_can_view_project_v2690(p_project_id)
  then
    raise exception 'Você não possui acesso a este projeto.'
      using errcode = '42501';
  end if;

  if normalized_action not in ('create', 'update', 'toggle', 'delete') then
    raise exception 'Ação de tarefa inválida.'
      using errcode = '22023';
  end if;

  can_manage_value :=
    public.nexlab_can_manage_project_v2690(p_project_id);

  if normalized_action = 'create' then
    if not can_manage_value then
      raise exception 'Você não possui permissão para criar tarefas neste projeto.'
        using errcode = '42501';
    end if;

    if normalized_title is null then
      raise exception 'Informe o título da tarefa.'
        using errcode = '22023';
    end if;

    if length(normalized_title) > 180 then
      raise exception 'O título da tarefa deve possuir no máximo 180 caracteres.'
        using errcode = '22023';
    end if;

    if p_responsible_id is not null
       and not exists (
         select 1
         from public.profiles profile_record
         where profile_record.id = p_responsible_id
           and profile_record.ativo is distinct from false
       )
    then
      raise exception 'O responsável informado não possui perfil ativo.'
        using errcode = '23503';
    end if;

    insert into public.project_tasks (
      project_id,
      titulo,
      responsavel_id,
      done,
      created_at
    )
    values (
      p_project_id,
      normalized_title,
      p_responsible_id,
      coalesce(p_done, false),
      now()
    )
    returning * into task_record;

    affected := 1;
  else
    if p_task_id is null then
      raise exception 'A tarefa não foi informada.'
        using errcode = '22023';
    end if;

    select task.*
      into task_record
    from public.project_tasks task
    where task.id = p_task_id
      and task.project_id = p_project_id
    for update;

    if task_record.id is null then
      raise exception 'Tarefa não encontrada neste projeto.'
        using errcode = 'P0002';
    end if;

    if normalized_action = 'toggle' then
      if not can_manage_value
         and task_record.responsavel_id is distinct from current_user_id
      then
        raise exception 'Somente o gestor do projeto ou o responsável pode concluir esta tarefa.'
          using errcode = '42501';
      end if;

      update public.project_tasks
      set done = coalesce(p_done, not task_record.done)
      where id = task_record.id
      returning * into task_record;

      affected := 1;
    elsif normalized_action = 'update' then
      if not can_manage_value then
        raise exception 'Você não possui permissão para editar esta tarefa.'
          using errcode = '42501';
      end if;

      if normalized_title is null then
        raise exception 'Informe o título da tarefa.'
          using errcode = '22023';
      end if;

      if length(normalized_title) > 180 then
        raise exception 'O título da tarefa deve possuir no máximo 180 caracteres.'
          using errcode = '22023';
      end if;

      if p_responsible_id is not null
         and not exists (
           select 1
           from public.profiles profile_record
           where profile_record.id = p_responsible_id
             and profile_record.ativo is distinct from false
         )
      then
        raise exception 'O responsável informado não possui perfil ativo.'
          using errcode = '23503';
      end if;

      update public.project_tasks
      set
        titulo = normalized_title,
        responsavel_id = p_responsible_id
      where id = task_record.id
      returning * into task_record;

      affected := 1;
    else
      if not can_manage_value then
        raise exception 'Você não possui permissão para excluir esta tarefa.'
          using errcode = '42501';
      end if;

      delete from public.project_tasks
      where id = task_record.id;

      get diagnostics affected = row_count;
      task_record := null;
    end if;
  end if;

  if task_record.id is not null then
    select jsonb_build_object(
      'id', task_record.id,
      'project_id', task_record.project_id,
      'title', task_record.titulo,
      'responsible_id', task_record.responsavel_id,
      'done', task_record.done,
      'created_at', task_record.created_at
    )
      into changed_task;
  end if;

  return jsonb_build_object(
    'ok', true,
    'action', normalized_action,
    'changed', affected > 0,
    'task', changed_task,
    'workspace', public.nexlab_get_project_workspace_v2690(p_project_id)
  );
end;
$$;

revoke all
on function public.nexlab_manage_project_task_v2690(
  uuid, text, uuid, text, uuid, boolean
)
from public, anon;

grant execute
on function public.nexlab_manage_project_task_v2690(
  uuid, text, uuid, text, uuid, boolean
)
to authenticated;

create or replace function public.nexlab_manage_project_link_v2690(
  p_project_id uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_action text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  normalized_type text := lower(btrim(coalesce(p_entity_type, '')));
  normalized_action text := lower(btrim(coalesce(p_action, 'add')));
  affected integer := 0;
  linked_project_id uuid;
begin
  if auth.uid() is null
     or not public.nexlab_can_manage_project_v2690(p_project_id)
  then
    raise exception 'Você não possui permissão para gerenciar os vínculos deste projeto.'
      using errcode = '42501';
  end if;

  if normalized_type not in ('event', 'meeting') then
    raise exception 'Tipo de vínculo inválido.'
      using errcode = '22023';
  end if;

  if normalized_action not in ('add', 'remove') then
    raise exception 'Ação de vínculo inválida.'
      using errcode = '22023';
  end if;

  if normalized_action = 'remove' then
    delete from public.project_links
    where project_id = p_project_id
      and entity_type = normalized_type
      and entity_id = p_entity_id;

    get diagnostics affected = row_count;
  else
    select pl.project_id
      into linked_project_id
    from public.project_links pl
    where pl.entity_type = normalized_type
      and pl.entity_id = p_entity_id
    limit 1;

    if linked_project_id is not null
       and linked_project_id <> p_project_id
    then
      raise exception 'Este registro já está vinculado a outro projeto.'
        using errcode = '23505';
    end if;

    insert into public.project_links (
      project_id,
      entity_type,
      entity_id,
      created_by,
      created_at,
      updated_at
    )
    values (
      p_project_id,
      normalized_type,
      p_entity_id,
      auth.uid(),
      now(),
      now()
    )
    on conflict (entity_type, entity_id) do nothing;

    get diagnostics affected = row_count;
  end if;

  return jsonb_build_object(
    'ok', true,
    'project_id', p_project_id,
    'entity_type', normalized_type,
    'entity_id', p_entity_id,
    'action', normalized_action,
    'changed', affected > 0,
    'workspace', public.nexlab_get_project_workspace_v2690(p_project_id)
  );
end;
$$;

revoke all
on function public.nexlab_manage_project_link_v2690(
  uuid, text, uuid, text
)
from public, anon;

grant execute
on function public.nexlab_manage_project_link_v2690(
  uuid, text, uuid, text
)
to authenticated;

comment on function public.nexlab_get_project_workspace_v2690(uuid)
is 'Retorna detalhes do projeto com permissões de tarefas e agenda da equipe deduplicada em relação aos vínculos diretos.';

comment on function public.nexlab_manage_project_task_v2690(uuid,text,uuid,text,uuid,boolean)
is 'Cria, edita, conclui, reabre ou exclui tarefas e devolve o workspace atualizado em uma única transação.';

comment on function public.nexlab_manage_project_link_v2690(uuid,text,uuid,text)
is 'Adiciona ou remove vínculo e devolve o workspace atualizado, evitando uma segunda consulta do frontend.';

DO $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'projects'
    ) then
      alter publication supabase_realtime add table public.projects;
    end if;

    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'project_tasks'
    ) then
      alter publication supabase_realtime add table public.project_tasks;
    end if;
  end if;
end;
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
          or exists (
            select 1
            from public.project_tasks task
            where task.project_id = pr.id
              and task.responsavel_id = auth.uid()
          )
        )
    );
$$;

revoke all
on function public.nexlab_can_view_project_v2690(uuid)
from public, anon;

grant execute
on function public.nexlab_can_view_project_v2690(uuid)
to authenticated;

comment on function public.nexlab_can_view_project_v2690(uuid)
is 'Permite visualizar o projeto por acesso global, autoria, responsabilidade geral, equipe ou tarefa atribuída, sem ampliar a gestão estrutural.';
