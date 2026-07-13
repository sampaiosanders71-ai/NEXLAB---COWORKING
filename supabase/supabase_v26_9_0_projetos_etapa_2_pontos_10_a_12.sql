-- NEXLAB v26.9.0 — Projetos, segunda etapa (pontos 10, 11 e 12)
-- Notificações, vínculos operacionais e indicadores/relatórios.

begin;

-- 1. Vínculos diretos entre projetos, eventos e reuniões
create table if not exists public.project_links (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.project_links
  drop constraint if exists project_links_entity_type_check;

alter table public.project_links
  add constraint project_links_entity_type_check
  check (entity_type in ('event','meeting'));

create unique index if not exists project_links_entity_unique_idx
  on public.project_links(entity_type, entity_id);

create index if not exists project_links_project_created_idx
  on public.project_links(project_id, created_at desc);

alter table public.project_links enable row level security;

drop policy if exists project_links_v2690_select on public.project_links;
drop policy if exists project_links_v2690_insert on public.project_links;
drop policy if exists project_links_v2690_delete on public.project_links;

create policy project_links_v2690_select
on public.project_links
for select
to authenticated
using (public.nexlab_can_view_project_v2690(project_id));

create policy project_links_v2690_insert
on public.project_links
for insert
to authenticated
with check (
  public.nexlab_can_manage_project_v2690(project_id)
  and created_by = auth.uid()
);

create policy project_links_v2690_delete
on public.project_links
for delete
to authenticated
using (public.nexlab_can_manage_project_v2690(project_id));

-- 2. Ampliação do histórico para vínculos
alter table public.project_history
  drop constraint if exists project_history_action_check;

alter table public.project_history
  add constraint project_history_action_check
  check (
    action = any (
      array[
        'project_created','project_updated','project_status_changed','project_reordered',
        'project_priority_changed','project_responsible_changed','project_deadline_changed',
        'project_team_changed','project_link_created','project_link_removed',
        'task_created','task_updated','task_completed','task_reopened','task_deleted'
      ]::text[]
    )
  );

-- 3. Tipos de notificação de projetos
alter table public.notifications
  drop constraint if exists notifications_type_check;

alter table public.notifications
  add constraint notifications_type_check
  check (
    type = any (
      array[
        'profile_request','profile_updated','reservation_created','reservation_decided',
        'feedback_created','feedback_updated','feedback_assigned','system',
        'project_assigned','project_updated','project_status_changed',
        'project_deadline_changed','project_team_changed','project_task_changed',
        'project_link_changed'
      ]::text[]
    )
  );

create or replace function public.nexlab_project_notification_v2690(
  p_recipient_id uuid,
  p_type text,
  p_title text,
  p_message text,
  p_project_id uuid,
  p_priority text default 'normal',
  p_metadata jsonb default '{}'::jsonb,
  p_source_suffix text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  source_value text;
  normalized_type text := lower(btrim(coalesce(p_type, 'project_updated')));
  normalized_priority text := lower(btrim(coalesce(p_priority, 'normal')));
begin
  if p_recipient_id is null
     or p_project_id is null
     or p_recipient_id = auth.uid()
  then
    return;
  end if;

  if normalized_type not in (
    'project_assigned','project_updated','project_status_changed',
    'project_deadline_changed','project_team_changed','project_task_changed',
    'project_link_changed'
  ) then
    normalized_type := 'project_updated';
  end if;

  if normalized_priority not in ('baixa','normal','alta','urgente') then
    normalized_priority := 'normal';
  end if;

  source_value := format(
    'project:%s:%s:%s:%s:%s',
    p_project_id,
    normalized_type,
    p_recipient_id,
    txid_current(),
    coalesce(nullif(btrim(p_source_suffix), ''), 'change')
  );

  insert into public.notifications (
    recipient_id,type,title,message,target_tab,entity_type,entity_id,source_key,
    category,priority,metadata,email_eligible,push_eligible,is_read,read_at,
    created_at,updated_at,preference_key
  )
  select
    profile_record.id,
    normalized_type,
    left(btrim(p_title), 180),
    left(btrim(p_message), 600),
    'projetos',
    'project',
    p_project_id,
    source_value,
    'projetos',
    normalized_priority,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('project_id', p_project_id),
    true,
    true,
    false,
    null,
    now(),
    now(),
    'project_updates'
  from public.profiles profile_record
  where profile_record.id = p_recipient_id
    and profile_record.ativo is distinct from false
  on conflict (recipient_id, source_key) do update
  set
    type = excluded.type,
    title = excluded.title,
    message = excluded.message,
    target_tab = excluded.target_tab,
    entity_type = excluded.entity_type,
    entity_id = excluded.entity_id,
    category = excluded.category,
    priority = excluded.priority,
    metadata = excluded.metadata,
    is_read = false,
    read_at = null,
    archived_at = null,
    updated_at = now();
end;
$$;

revoke all on function public.nexlab_project_notification_v2690(
  uuid,text,text,text,uuid,text,jsonb,text
) from public, anon, authenticated;

-- 4. Notificações automáticas em projetos
create or replace function public.nexlab_project_notifications_trigger_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  project_name text := coalesce(new.nome, old.nome, 'Projeto');
  recipient_id uuid;
  previous_name text;
  next_name text;
begin
  if tg_op = 'INSERT' then
    perform public.nexlab_project_notification_v2690(
      new.responsavel_id,
      'project_assigned',
      'Novo projeto sob sua responsabilidade',
      format('Você foi definido como responsável pelo projeto "%s".', project_name),
      new.id,
      'alta',
      jsonb_build_object('status', new.status, 'deadline', new.prazo),
      'created'
    );
    return new;
  end if;

  if new.responsavel_id is distinct from old.responsavel_id then
    select p.nome into previous_name from public.profiles p where p.id = old.responsavel_id;
    select p.nome into next_name from public.profiles p where p.id = new.responsavel_id;

    perform public.nexlab_project_notification_v2690(
      new.responsavel_id,
      'project_assigned',
      'Responsabilidade de projeto atribuída',
      format('Você agora é responsável pelo projeto "%s".', project_name),
      new.id,
      'alta',
      jsonb_build_object(
        'previous_responsible_id', old.responsavel_id,
        'previous_responsible_name', previous_name,
        'new_responsible_name', next_name
      ),
      'responsible-new'
    );

    perform public.nexlab_project_notification_v2690(
      old.responsavel_id,
      'project_updated',
      'Responsabilidade de projeto transferida',
      format('A responsabilidade pelo projeto "%s" foi transferida para %s.', project_name, coalesce(next_name, 'outro usuário')),
      new.id,
      'normal',
      jsonb_build_object('new_responsible_id', new.responsavel_id, 'new_responsible_name', next_name),
      'responsible-old'
    );
  end if;

  if new.status is distinct from old.status then
    for recipient_id in
      select distinct value_id
      from unnest(array[new.responsavel_id, new.autor_id]) as value_id
      where value_id is not null
    loop
      perform public.nexlab_project_notification_v2690(
        recipient_id,
        'project_status_changed',
        'Etapa do projeto atualizada',
        format(
          'O projeto "%s" avançou de %s para %s.',
          project_name,
          public.nexlab_project_status_label_v2690(old.status),
          public.nexlab_project_status_label_v2690(new.status)
        ),
        new.id,
        case when new.status in ('finalizado','arquivado') then 'alta' else 'normal' end,
        jsonb_build_object('previous_status', old.status, 'new_status', new.status),
        'status'
      );
    end loop;
  end if;

  if new.prazo is distinct from old.prazo then
    for recipient_id in
      select distinct value_id
      from unnest(array[new.responsavel_id, new.autor_id]) as value_id
      where value_id is not null
    loop
      perform public.nexlab_project_notification_v2690(
        recipient_id,
        'project_deadline_changed',
        'Prazo do projeto atualizado',
        format(
          'O prazo do projeto "%s" foi alterado para %s.',
          project_name,
          coalesce(to_char(new.prazo, 'DD/MM/YYYY'), 'não definido')
        ),
        new.id,
        case when new.prazo is not null and new.prazo <= current_date + 7 then 'alta' else 'normal' end,
        jsonb_build_object('previous_deadline', old.prazo, 'new_deadline', new.prazo),
        'deadline'
      );
    end loop;
  end if;

  if new.equipe_id is distinct from old.equipe_id then
    select t.nome into previous_name from public.teams t where t.id = old.equipe_id;
    select t.nome into next_name from public.teams t where t.id = new.equipe_id;

    for recipient_id in
      select distinct value_id
      from (
        select new.responsavel_id as value_id
        union all select new.autor_id
        union all select t.lider_id from public.teams t where t.id = new.equipe_id
      ) recipients
      where value_id is not null
    loop
      perform public.nexlab_project_notification_v2690(
        recipient_id,
        'project_team_changed',
        'Equipe vinculada ao projeto atualizada',
        format('O projeto "%s" foi vinculado à equipe %s.', project_name, coalesce(next_name, 'não definida')),
        new.id,
        'normal',
        jsonb_build_object(
          'previous_team_id', old.equipe_id,
          'previous_team_name', previous_name,
          'new_team_id', new.equipe_id,
          'new_team_name', next_name
        ),
        'team'
      );
    end loop;
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_project_notifications_v2690 on public.projects;
create trigger nexlab_project_notifications_v2690
after insert or update on public.projects
for each row
execute function public.nexlab_project_notifications_trigger_v2690();

-- 5. Notificações de tarefas
create or replace function public.nexlab_project_task_notifications_trigger_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  project_record public.projects%rowtype;
  task_title text := coalesce(new.titulo, old.titulo, 'Tarefa');
  recipient_id uuid;
begin
  select pr.* into project_record
  from public.projects pr
  where pr.id = coalesce(new.project_id, old.project_id);

  if project_record.id is null then
    return coalesce(new, old);
  end if;

  if tg_op = 'INSERT' then
    perform public.nexlab_project_notification_v2690(
      new.responsavel_id,
      'project_task_changed',
      'Nova tarefa atribuída',
      format('A tarefa "%s" foi atribuída a você no projeto "%s".', task_title, project_record.nome),
      project_record.id,
      'normal',
      jsonb_build_object('task_id', new.id, 'task_title', task_title, 'done', new.done),
      format('task-created-%s', new.id)
    );
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.responsavel_id is distinct from old.responsavel_id then
      perform public.nexlab_project_notification_v2690(
        new.responsavel_id,
        'project_task_changed',
        'Tarefa de projeto atribuída',
        format('A tarefa "%s" foi atribuída a você no projeto "%s".', task_title, project_record.nome),
        project_record.id,
        'normal',
        jsonb_build_object('task_id', new.id, 'previous_responsible_id', old.responsavel_id),
        format('task-assigned-%s', new.id)
      );
    end if;

    if new.done is distinct from old.done then
      for recipient_id in
        select distinct value_id
        from unnest(array[project_record.responsavel_id, new.responsavel_id, project_record.autor_id]) as value_id
        where value_id is not null
      loop
        perform public.nexlab_project_notification_v2690(
          recipient_id,
          'project_task_changed',
          case when new.done then 'Tarefa concluída' else 'Tarefa reaberta' end,
          format(
            'A tarefa "%s" do projeto "%s" foi %s.',
            task_title,
            project_record.nome,
            case when new.done then 'concluída' else 'reaberta' end
          ),
          project_record.id,
          'normal',
          jsonb_build_object('task_id', new.id, 'done', new.done),
          format('task-status-%s', new.id)
        );
      end loop;
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists nexlab_project_task_notifications_v2690 on public.project_tasks;
create trigger nexlab_project_task_notifications_v2690
after insert or update on public.project_tasks
for each row
execute function public.nexlab_project_task_notifications_trigger_v2690();

-- 6. Histórico e notificações de vínculos
create or replace function public.nexlab_project_link_activity_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  project_record public.projects%rowtype;
  entity_label text;
  action_label text;
  recipient_id uuid;
  current_row public.project_links%rowtype;
begin
  current_row := case when tg_op = 'DELETE' then old else new end;

  select pr.* into project_record
  from public.projects pr
  where pr.id = current_row.project_id;

  if current_row.entity_type = 'event' then
    select ev.titulo into entity_label from public.events ev where ev.id = current_row.entity_id;
  else
    select mt.titulo into entity_label from public.meetings mt where mt.id = current_row.entity_id;
  end if;

  entity_label := coalesce(entity_label, 'Registro vinculado');
  action_label := case when tg_op = 'DELETE' then 'removido' else 'adicionado' end;

  perform public.nexlab_add_project_history_v2690(
    current_row.project_id,
    case when tg_op = 'DELETE' then 'project_link_removed' else 'project_link_created' end,
    format(
      '%s %s: %s.',
      case current_row.entity_type when 'event' then 'Evento' else 'Reunião' end,
      action_label,
      entity_label
    ),
    jsonb_build_object(
      'entity_type', current_row.entity_type,
      'entity_id', current_row.entity_id,
      'entity_label', entity_label,
      'operation', lower(tg_op)
    )
  );

  for recipient_id in
    select distinct value_id
    from unnest(array[project_record.responsavel_id, project_record.autor_id]) as value_id
    where value_id is not null
  loop
    perform public.nexlab_project_notification_v2690(
      recipient_id,
      'project_link_changed',
      'Vínculos do projeto atualizados',
      format(
        '%s "%s" foi %s ao projeto "%s".',
        case current_row.entity_type when 'event' then 'O evento' else 'A reunião' end,
        entity_label,
        case when tg_op = 'DELETE' then 'removido' else 'adicionado' end,
        project_record.nome
      ),
      current_row.project_id,
      'normal',
      jsonb_build_object(
        'entity_type', current_row.entity_type,
        'entity_id', current_row.entity_id,
        'entity_label', entity_label,
        'operation', lower(tg_op)
      ),
      format('link-%s-%s', lower(tg_op), current_row.entity_id)
    );
  end loop;

  return current_row;
end;
$$;

drop trigger if exists nexlab_project_link_activity_v2690 on public.project_links;
create trigger nexlab_project_link_activity_v2690
after insert or delete on public.project_links
for each row
execute function public.nexlab_project_link_activity_v2690();

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

  if normalized_type not in ('event','meeting') then
    raise exception 'Tipo de vínculo inválido.' using errcode = '22023';
  end if;

  if normalized_action not in ('add','remove') then
    raise exception 'Ação de vínculo inválida.' using errcode = '22023';
  end if;

  if normalized_type = 'event'
     and not exists (select 1 from public.events ev where ev.id = p_entity_id)
  then
    raise exception 'Evento não encontrado.' using errcode = 'P0002';
  end if;

  if normalized_type = 'meeting'
     and not exists (select 1 from public.meetings mt where mt.id = p_entity_id)
  then
    raise exception 'Reunião não encontrada.' using errcode = 'P0002';
  end if;

  if normalized_action = 'remove' then
    delete from public.project_links
    where project_id = p_project_id
      and entity_type = normalized_type
      and entity_id = p_entity_id;

    get diagnostics affected = row_count;
  else
    select pl.project_id into linked_project_id
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
      project_id,entity_type,entity_id,created_by,created_at,updated_at
    )
    values (
      p_project_id,normalized_type,p_entity_id,auth.uid(),now(),now()
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
    'changed', affected > 0
  );
end;
$$;

revoke all on function public.nexlab_manage_project_link_v2690(uuid,text,uuid,text)
  from public, anon;
grant execute on function public.nexlab_manage_project_link_v2690(uuid,text,uuid,text)
  to authenticated;

-- 7. Workspace ampliado com vínculos diretos e opções disponíveis
create or replace function public.nexlab_get_project_workspace_v2690(p_project_id uuid)
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
begin
  if auth.uid() is null
     or not public.nexlab_can_view_project_v2690(p_project_id)
  then
    raise exception 'Você não possui acesso a este projeto.' using errcode = '42501';
  end if;

  select pr.* into current_project
  from public.projects pr
  where pr.id = p_project_id;

  if current_project.id is null then
    raise exception 'Projeto não encontrado.' using errcode = 'P0002';
  end if;

  can_manage_value := public.nexlab_can_manage_project_v2690(p_project_id);

  select to_jsonb(pr) || jsonb_build_object(
    'responsible_name', responsible_profile.nome,
    'author_name', author_profile.nome,
    'team_name', team_record.nome,
    'team_area', team_record.area
  )
  into project_data
  from public.projects pr
  left join public.profiles responsible_profile on responsible_profile.id = pr.responsavel_id
  left join public.profiles author_profile on author_profile.id = pr.autor_id
  left join public.teams team_record on team_record.id = pr.equipe_id
  where pr.id = p_project_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', task.id,'title', task.titulo,'done', task.done,
    'responsible_id', task.responsavel_id,'responsible_name', task_responsible.nome,
    'created_at', task.created_at
  ) order by task.done, task.created_at, task.id), '[]'::jsonb)
  into tasks_data
  from public.project_tasks task
  left join public.profiles task_responsible on task_responsible.id = task.responsavel_id
  where task.project_id = p_project_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', history.id,'action', history.action,'description', history.description,
    'actor_id', history.actor_id,'actor_name', history.actor_name,
    'metadata', history.metadata,'created_at', history.created_at
  ) order by history.created_at desc, history.id desc), '[]'::jsonb)
  into history_data
  from (
    select ph.* from public.project_history ph
    where ph.project_id = p_project_id
    order by ph.created_at desc, ph.id desc
    limit 100
  ) history;

  select case when team_record.id is null then null else jsonb_build_object(
    'id', team_record.id,'name', team_record.nome,'area', team_record.area,
    'leader_id', team_record.lider_id,'archived_at', team_record.archived_at
  ) end
  into team_data
  from (select 1) anchor
  left join public.teams team_record on team_record.id = current_project.equipe_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', tm.user_id,'name', member_profile.nome,'role', tm.funcao,
    'joined_at', tm.created_at
  ) order by case tm.funcao when 'responsavel' then 1 when 'vice_responsavel' then 2 when 'organizador' then 3 else 4 end,
  lower(coalesce(member_profile.nome, ''))), '[]'::jsonb)
  into participants_data
  from public.team_members tm
  left join public.profiles member_profile on member_profile.id = tm.user_id
  where tm.team_id = current_project.equipe_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'type', link.entity_type,'id', link.entity_id,
    'title', case link.entity_type when 'event' then event_record.titulo when 'meeting' then meeting_record.titulo end,
    'date', case link.entity_type when 'event' then event_record.data when 'meeting' then meeting_record.data end,
    'time', case link.entity_type when 'event' then event_record.hora::text when 'meeting' then meeting_record.hora::text end,
    'location', case link.entity_type when 'event' then event_record.local when 'meeting' then meeting_record.local end
  ) order by case link.entity_type when 'event' then event_record.data when 'meeting' then meeting_record.data end nulls last,
  link.created_at), '[]'::jsonb)
  into agenda_data
  from public.team_links link
  left join public.events event_record on link.entity_type = 'event' and event_record.id = link.entity_id
  left join public.meetings meeting_record on link.entity_type = 'meeting' and meeting_record.id = link.entity_id
  where link.team_id = current_project.equipe_id
    and link.entity_type in ('event','meeting');

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', attachment.id,'title', attachment.titulo,'url', attachment.url,
    'type', attachment.tipo,'created_at', attachment.created_at
  ) order by attachment.created_at desc, attachment.id desc), '[]'::jsonb)
  into attachments_data
  from public.attachments attachment
  where attachment.modulo in ('projetos','projects','project')
    and attachment.record_id = p_project_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'link_id', pl.id,'type', pl.entity_type,'id', pl.entity_id,
    'title', case pl.entity_type when 'event' then ev.titulo when 'meeting' then mt.titulo end,
    'date', case pl.entity_type when 'event' then ev.data when 'meeting' then mt.data end,
    'time', case pl.entity_type when 'event' then ev.hora::text when 'meeting' then mt.hora::text end,
    'location', case pl.entity_type when 'event' then ev.local when 'meeting' then mt.local end,
    'created_at', pl.created_at
  ) order by pl.entity_type,
  case pl.entity_type when 'event' then ev.data when 'meeting' then mt.data end nulls last,
  pl.created_at), '[]'::jsonb)
  into links_data
  from public.project_links pl
  left join public.events ev on pl.entity_type = 'event' and ev.id = pl.entity_id
  left join public.meetings mt on pl.entity_type = 'meeting' and mt.id = pl.entity_id
  where pl.project_id = p_project_id;

  if can_manage_value then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', ev.id,'title', ev.titulo,'date', ev.data,'time', ev.hora::text,
      'location', ev.local
    ) order by ev.data desc, ev.titulo), '[]'::jsonb)
    into available_events_data
    from public.events ev
    where not exists (
      select 1 from public.project_links pl
      where pl.entity_type = 'event' and pl.entity_id = ev.id
    );

    select coalesce(jsonb_agg(jsonb_build_object(
      'id', mt.id,'title', mt.titulo,'date', mt.data,'time', mt.hora::text,
      'location', mt.local,'status', mt.status
    ) order by mt.data desc, mt.titulo), '[]'::jsonb)
    into available_meetings_data
    from public.meetings mt
    where not exists (
      select 1 from public.project_links pl
      where pl.entity_type = 'meeting' and pl.entity_id = mt.id
    );
  else
    available_events_data := '[]'::jsonb;
    available_meetings_data := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'ok', true,'project', project_data,'tasks', tasks_data,'history', history_data,
    'team', team_data,'participants', participants_data,'agenda', agenda_data,
    'attachments', attachments_data,'links', links_data,
    'available_events', available_events_data,
    'available_meetings', available_meetings_data,
    'permissions', jsonb_build_object(
      'can_view', true,'can_manage', can_manage_value,
      'can_delete', public.nexlab_can_delete_project_v2690(p_project_id),
      'can_create', public.nexlab_can_create_project_v2690()
    ),
    'generated_at', now()
  );
end;
$$;

revoke all on function public.nexlab_get_project_workspace_v2690(uuid)
  from public, anon;
grant execute on function public.nexlab_get_project_workspace_v2690(uuid)
  to authenticated;

-- 8. Relatório consolidado de projetos
create or replace function public.nexlab_get_projects_report_v2690()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  summary_data jsonb;
  projects_data jsonb;
begin
  if auth.uid() is null
     or not public.nexlab_can_access_reports()
     or not public.nexlab_has_project_permission_v2690('module_projetos')
     or not (
       public.nexlab_has_project_permission_v2690('projects_view_all')
       or public.nexlab_has_project_permission_v2690('projects_manage_all')
     )
  then
    raise exception 'Seu perfil não possui acesso ao relatório consolidado de projetos.'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
    'total', count(*),
    'active', count(*) filter (where pr.status not in ('finalizado','arquivado')),
    'finished', count(*) filter (where pr.status = 'finalizado'),
    'archived', count(*) filter (where pr.status = 'arquivado'),
    'overdue', count(*) filter (where pr.prazo < current_date and pr.status not in ('finalizado','arquivado')),
    'due_soon', count(*) filter (where pr.prazo between current_date and current_date + 7 and pr.status not in ('finalizado','arquivado')),
    'high_priority', count(*) filter (where pr.prioridade = 'alta'),
    'without_responsible', count(*) filter (where pr.responsavel_id is null),
    'without_team', count(*) filter (where pr.equipe_id is null),
    'tasks_total', (select count(*) from public.project_tasks),
    'tasks_completed', (select count(*) from public.project_tasks where done),
    'event_links', (select count(*) from public.project_links where entity_type = 'event'),
    'meeting_links', (select count(*) from public.project_links where entity_type = 'meeting')
  )
  into summary_data
  from public.projects pr;

  select coalesce(jsonb_agg(project_row order by lower(project_row->>'name')), '[]'::jsonb)
  into projects_data
  from (
    select jsonb_build_object(
      'id', pr.id,
      'name', pr.nome,
      'description', pr.descricao,
      'status', pr.status,
      'status_label', public.nexlab_project_status_label_v2690(pr.status),
      'priority', pr.prioridade,
      'priority_label', public.nexlab_project_priority_label_v2690(pr.prioridade),
      'deadline', pr.prazo,
      'responsible_id', pr.responsavel_id,
      'responsible_name', coalesce(responsible_profile.nome, 'Não definido'),
      'author_name', coalesce(author_profile.nome, 'Não identificado'),
      'team_id', pr.equipe_id,
      'team_name', coalesce(team_record.nome, 'Sem equipe'),
      'team_area', coalesce(team_record.area, 'Sem área'),
      'tasks_total', coalesce(task_data.tasks_total, 0),
      'tasks_completed', coalesce(task_data.tasks_completed, 0),
      'progress', case when coalesce(task_data.tasks_total, 0) = 0 then 0
        else round((task_data.tasks_completed::numeric / task_data.tasks_total::numeric) * 100)::integer end,
      'event_links', coalesce(link_data.event_links, 0),
      'meeting_links', coalesce(link_data.meeting_links, 0),
      'last_activity', history_data.last_activity,
      'created_at', pr.created_at,
      'updated_at', pr.updated_at
    ) as project_row
    from public.projects pr
    left join public.profiles responsible_profile on responsible_profile.id = pr.responsavel_id
    left join public.profiles author_profile on author_profile.id = pr.autor_id
    left join public.teams team_record on team_record.id = pr.equipe_id
    left join lateral (
      select count(*)::integer as tasks_total,
             count(*) filter (where task.done)::integer as tasks_completed
      from public.project_tasks task where task.project_id = pr.id
    ) task_data on true
    left join lateral (
      select count(*) filter (where pl.entity_type = 'event')::integer as event_links,
             count(*) filter (where pl.entity_type = 'meeting')::integer as meeting_links
      from public.project_links pl where pl.project_id = pr.id
    ) link_data on true
    left join lateral (
      select max(ph.created_at) as last_activity
      from public.project_history ph where ph.project_id = pr.id
    ) history_data on true
  ) rows_data;

  return jsonb_build_object(
    'summary', coalesce(summary_data, '{}'::jsonb),
    'projects', coalesce(projects_data, '[]'::jsonb),
    'generated_at', now()
  );
end;
$$;

revoke all on function public.nexlab_get_projects_report_v2690()
  from public, anon;
grant execute on function public.nexlab_get_projects_report_v2690()
  to authenticated;

-- 9. Realtime
DO $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'project_links'
     )
  then
    alter publication supabase_realtime add table public.project_links;
  end if;
end;
$$;

comment on table public.project_links
is 'Vínculos diretos de projetos com eventos e reuniões.';

comment on function public.nexlab_manage_project_link_v2690(uuid,text,uuid,text)
is 'Adiciona ou remove vínculos diretos de um projeto com evento ou reunião.';

comment on function public.nexlab_get_projects_report_v2690()
is 'Retorna indicadores e dados consolidados de projetos para relatórios gerenciais.';

commit;
