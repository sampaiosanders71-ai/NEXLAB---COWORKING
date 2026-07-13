-- NEXLAB v26.9.0 — Estabilização do módulo Projetos
-- Correções 9 a 12:
-- 9. filtro funcional para projetos sem equipe;
-- 10. bloqueio de equipes arquivadas em novos vínculos;
-- 11. estrutura completa e uniforme das equipes no frontend;
-- 12. catálogo de vínculos limitado a eventos e reuniões válidos.

begin;

-- Correção 10: preserva projetos historicamente ligados a equipes arquivadas,
-- mas impede criar ou trocar um vínculo para uma equipe já arquivada.
create or replace function public.nexlab_validate_project_team_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  selected_team public.teams%rowtype;
begin
  if new.equipe_id is null then
    return new;
  end if;

  select t.*
    into selected_team
  from public.teams t
  where t.id = new.equipe_id;

  if selected_team.id is null then
    raise exception 'A equipe informada não existe.'
      using errcode = '23503';
  end if;

  if selected_team.archived_at is not null then
    if tg_op = 'INSERT'
       or new.equipe_id is distinct from old.equipe_id
    then
      raise exception 'Equipes arquivadas não podem receber novos projetos.'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_validate_project_team_v2690
on public.projects;

create trigger nexlab_validate_project_team_v2690
before insert or update of equipe_id on public.projects
for each row
execute function public.nexlab_validate_project_team_v2690();

revoke all on function public.nexlab_validate_project_team_v2690()
from public, anon, authenticated;

-- Correção 12: além de validar existência, novos vínculos precisam ser
-- operacionalmente válidos. Vínculos antigos permanecem no histórico.
create or replace function public.nexlab_validate_project_link_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  event_record public.events%rowtype;
  meeting_record public.meetings%rowtype;
begin
  new.entity_type := lower(btrim(coalesce(new.entity_type, '')));

  if new.entity_type not in ('event', 'meeting') then
    raise exception 'Tipo de vínculo inválido.' using errcode = '22023';
  end if;

  if new.entity_type = 'event' then
    select e.* into event_record
    from public.events e
    where e.id = new.entity_id;

    if event_record.id is null then
      raise exception 'O evento informado não existe.' using errcode = '23503';
    end if;

    if event_record.data < current_date then
      raise exception 'Eventos já encerrados não podem receber novos vínculos de projeto.'
        using errcode = '23514';
    end if;
  else
    select m.* into meeting_record
    from public.meetings m
    where m.id = new.entity_id;

    if meeting_record.id is null then
      raise exception 'A reunião informada não existe.' using errcode = '23503';
    end if;

    if meeting_record.data < current_date
       or lower(btrim(coalesce(meeting_record.status, ''))) <> 'agendada'
       or meeting_record.cancelada_em is not null
    then
      raise exception 'Somente reuniões futuras e agendadas podem receber novos vínculos de projeto.'
        using errcode = '23514';
    end if;
  end if;

  new.created_by := coalesce(new.created_by, auth.uid());
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.nexlab_validate_project_link_v2690()
from public, anon, authenticated;

-- Correção 12: o workspace oferece somente candidatos válidos,
-- enquanto os vínculos já existentes continuam visíveis para histórico.
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
    ) order by ev.data asc, ev.hora asc nulls last, ev.titulo), '[]'::jsonb)
    into available_events_data
    from public.events ev
    where ev.data >= current_date
      and not exists (
        select 1 from public.project_links pl
        where pl.entity_type = 'event' and pl.entity_id = ev.id
      );

    select coalesce(jsonb_agg(jsonb_build_object(
      'id', mt.id,'title', mt.titulo,'date', mt.data,'time', mt.hora::text,
      'location', mt.local,'status', mt.status
    ) order by mt.data asc, mt.hora asc nulls last, mt.titulo), '[]'::jsonb)
    into available_meetings_data
    from public.meetings mt
    where mt.data >= current_date
      and lower(btrim(coalesce(mt.status, ''))) = 'agendada'
      and mt.cancelada_em is null
      and not exists (
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

comment on function public.nexlab_validate_project_team_v2690()
is 'Impede novos vínculos de projetos com equipes arquivadas, preservando relações históricas já existentes.';

comment on function public.nexlab_validate_project_link_v2690()
is 'Valida existência e vigência operacional de eventos e reuniões vinculados a projetos.';

comment on function public.nexlab_get_project_workspace_v2690(uuid)
is 'Retorna o workspace do projeto e oferece somente eventos futuros e reuniões futuras agendadas como novos vínculos.';

commit;
