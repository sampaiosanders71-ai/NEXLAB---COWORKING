-- NEXLAB v26.8.0 — Equipes, etapa 3 (pontos 9, 10 e 11)
-- Histórico operacional, notificações e vínculos com projetos, eventos e reuniões.

begin;

create table if not exists public.team_history (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  actor_id uuid,
  actor_name text,
  action text not null,
  description text not null,
  metadata jsonb not null default '{}'::jsonb,
  source_audit_id uuid unique,
  created_at timestamptz not null default now()
);

create index if not exists team_history_team_created_idx
  on public.team_history(team_id, created_at desc);

create table if not exists public.team_links (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint team_links_entity_type_check
    check (entity_type in ('project','event','meeting')),
  constraint team_links_entity_unique
    unique (entity_type, entity_id)
);

create index if not exists team_links_team_idx
  on public.team_links(team_id, entity_type, created_at desc);

create or replace function public.nexlab_can_view_team_v2680(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select
    auth.uid() is not null
    and public.nexlab_has_approved_access()
    and public.nexlab_has_effective_permission_v2680('module_equipes')
    and exists (
      select 1
      from public.teams t
      where t.id = p_team_id
        and (
          public.nexlab_can_view_all_teams_v2680()
          or t.lider_id = auth.uid()
          or exists (
            select 1
            from public.team_members tm
            where tm.team_id = t.id
              and tm.user_id = auth.uid()
          )
        )
    );
$$;

revoke all on function public.nexlab_can_view_team_v2680(uuid) from public, anon;
grant execute on function public.nexlab_can_view_team_v2680(uuid) to authenticated;

create or replace function public.nexlab_record_team_history_v2680(
  p_team_id uuid,
  p_action text,
  p_description text,
  p_metadata jsonb default '{}'::jsonb,
  p_actor_id uuid default auth.uid(),
  p_source_audit_id uuid default null,
  p_created_at timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  history_id uuid;
  actor_label text;
begin
  if p_team_id is null
     or nullif(btrim(coalesce(p_action, '')), '') is null
     or nullif(btrim(coalesce(p_description, '')), '') is null
  then
    return null;
  end if;

  select coalesce(p.nome, p.email, 'Usuário do NEXLAB')
    into actor_label
  from public.profiles p
  where p.id = p_actor_id;

  actor_label := coalesce(actor_label, 'Sistema NEXLAB');

  insert into public.team_history (
    team_id,
    actor_id,
    actor_name,
    action,
    description,
    metadata,
    source_audit_id,
    created_at
  ) values (
    p_team_id,
    p_actor_id,
    actor_label,
    left(btrim(p_action), 80),
    left(btrim(p_description), 500),
    coalesce(p_metadata, '{}'::jsonb),
    p_source_audit_id,
    coalesce(p_created_at, now())
  )
  on conflict (source_audit_id) do nothing
  returning id into history_id;

  return history_id;
end;
$$;

revoke all on function public.nexlab_record_team_history_v2680(uuid,text,text,jsonb,uuid,uuid,timestamptz)
  from public, anon, authenticated;

create or replace function public.nexlab_notify_team_user_v2680(
  p_recipient_id uuid,
  p_team_id uuid,
  p_title text,
  p_message text,
  p_source_key text,
  p_priority text default 'normal',
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if p_recipient_id is null
     or p_team_id is null
     or nullif(btrim(coalesce(p_source_key, '')), '') is null
  then
    return;
  end if;

  insert into public.notifications (
    recipient_id,
    type,
    title,
    message,
    target_tab,
    entity_type,
    entity_id,
    source_key,
    category,
    priority,
    metadata,
    email_eligible,
    push_eligible,
    updated_at
  )
  select
    p.id,
    'system',
    left(btrim(p_title), 180),
    left(btrim(p_message), 1000),
    'equipes',
    'team',
    p_team_id,
    left(btrim(p_source_key), 240),
    'equipes',
    case
      when p_priority in ('baixa','normal','alta','urgente') then p_priority
      else 'normal'
    end,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('team_id', p_team_id),
    true,
    true,
    now()
  from public.profiles p
  where p.id = p_recipient_id
    and p.ativo is distinct from false
  on conflict (recipient_id, source_key) do update
  set
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

revoke all on function public.nexlab_notify_team_user_v2680(uuid,uuid,text,text,text,text,jsonb)
  from public, anon, authenticated;

create or replace function public.nexlab_team_entity_label_v2680(
  p_entity_type text,
  p_entity_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  result_label text;
begin
  case p_entity_type
    when 'project' then
      select p.nome into result_label
      from public.projects p where p.id = p_entity_id;
    when 'event' then
      select e.titulo into result_label
      from public.events e where e.id = p_entity_id;
    when 'meeting' then
      select m.titulo into result_label
      from public.meetings m where m.id = p_entity_id;
    else
      result_label := null;
  end case;

  return coalesce(result_label, 'Registro removido');
end;
$$;

revoke all on function public.nexlab_team_entity_label_v2680(text,uuid)
  from public, anon, authenticated;

alter table public.team_history enable row level security;
alter table public.team_links enable row level security;

drop policy if exists team_history_v2680_select on public.team_history;
create policy team_history_v2680_select
on public.team_history
for select
to authenticated
using (public.nexlab_can_view_team_v2680(team_id));

drop policy if exists team_links_v2680_select on public.team_links;
create policy team_links_v2680_select
on public.team_links
for select
to authenticated
using (public.nexlab_can_view_team_v2680(team_id));

grant select on public.team_history to authenticated;
grant select on public.team_links to authenticated;

-- Histórico e notificações automáticas para alterações em equipes.
create or replace function public.nexlab_team_change_history_trigger_v2680()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  history_id uuid;
  member_row record;
  changed_fields text[] := '{}'::text[];
begin
  if tg_op = 'INSERT' then
    history_id := public.nexlab_record_team_history_v2680(
      new.id,
      'team_created',
      format('Equipe "%s" criada.', new.nome),
      jsonb_build_object(
        'team_name', new.nome,
        'area', new.area,
        'leader_id', new.lider_id
      )
    );

    if new.lider_id is not null
       and new.lider_id is distinct from auth.uid()
    then
      perform public.nexlab_notify_team_user_v2680(
        new.lider_id,
        new.id,
        'Você é responsável por uma nova equipe',
        format('Você foi definido como responsável pela equipe %s.', new.nome),
        format('team-created:%s:%s', new.id, history_id),
        'alta',
        jsonb_build_object('action', 'team_created')
      );
    end if;

    return new;
  end if;

  if old.nome is distinct from new.nome then
    changed_fields := array_append(changed_fields, 'nome');
  end if;
  if old.descricao is distinct from new.descricao then
    changed_fields := array_append(changed_fields, 'descricao');
  end if;
  if old.area is distinct from new.area then
    changed_fields := array_append(changed_fields, 'area');
  end if;

  if array_length(changed_fields, 1) is not null then
    perform public.nexlab_record_team_history_v2680(
      new.id,
      'team_updated',
      format('Informações da equipe "%s" atualizadas.', new.nome),
      jsonb_build_object(
        'changed_fields', changed_fields,
        'previous_name', old.nome,
        'next_name', new.nome,
        'previous_area', old.area,
        'next_area', new.area
      )
    );
  end if;

  if old.lider_id is distinct from new.lider_id then
    history_id := public.nexlab_record_team_history_v2680(
      new.id,
      'team_responsibility_transferred',
      format('Responsabilidade da equipe "%s" transferida.', new.nome),
      jsonb_build_object(
        'previous_leader_id', old.lider_id,
        'next_leader_id', new.lider_id
      )
    );

    if new.lider_id is not null then
      perform public.nexlab_notify_team_user_v2680(
        new.lider_id,
        new.id,
        'Você assumiu a responsabilidade de uma equipe',
        format('Agora você é responsável pela equipe %s.', new.nome),
        format('team-leader-new:%s:%s', new.id, history_id),
        'alta',
        jsonb_build_object(
          'action', 'team_responsibility_transferred',
          'previous_leader_id', old.lider_id
        )
      );
    end if;

    if old.lider_id is not null
       and old.lider_id is distinct from auth.uid()
    then
      perform public.nexlab_notify_team_user_v2680(
        old.lider_id,
        new.id,
        'Responsabilidade da equipe transferida',
        format('A responsabilidade da equipe %s foi transferida para outro integrante.', new.nome),
        format('team-leader-previous:%s:%s', new.id, history_id),
        'normal',
        jsonb_build_object(
          'action', 'team_responsibility_transferred',
          'next_leader_id', new.lider_id
        )
      );
    end if;
  end if;

  if old.archived_at is null and new.archived_at is not null then
    history_id := public.nexlab_record_team_history_v2680(
      new.id,
      'team_archived',
      format('Equipe "%s" arquivada.', new.nome),
      jsonb_build_object(
        'reason', new.archive_reason,
        'archived_by', new.archived_by
      )
    );

    for member_row in
      select tm.user_id
      from public.team_members tm
      where tm.team_id = new.id
        and tm.user_id is distinct from auth.uid()
    loop
      perform public.nexlab_notify_team_user_v2680(
        member_row.user_id,
        new.id,
        'Equipe arquivada',
        format('A equipe %s foi arquivada. Motivo: %s', new.nome, coalesce(new.archive_reason, 'não informado')),
        format('team-archived:%s:%s:%s', new.id, history_id, member_row.user_id),
        'normal',
        jsonb_build_object('action', 'team_archived', 'reason', new.archive_reason)
      );
    end loop;
  elsif old.archived_at is not null and new.archived_at is null then
    history_id := public.nexlab_record_team_history_v2680(
      new.id,
      'team_restored',
      format('Equipe "%s" restaurada.', new.nome),
      jsonb_build_object('previous_archive_reason', old.archive_reason)
    );

    for member_row in
      select tm.user_id
      from public.team_members tm
      where tm.team_id = new.id
        and tm.user_id is distinct from auth.uid()
    loop
      perform public.nexlab_notify_team_user_v2680(
        member_row.user_id,
        new.id,
        'Equipe restaurada',
        format('A equipe %s voltou a ficar ativa.', new.nome),
        format('team-restored:%s:%s:%s', new.id, history_id, member_row.user_id),
        'normal',
        jsonb_build_object('action', 'team_restored')
      );
    end loop;
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_team_change_history_v2680 on public.teams;
create trigger nexlab_team_change_history_v2680
after insert or update on public.teams
for each row execute function public.nexlab_team_change_history_trigger_v2680();

create or replace function public.nexlab_team_member_history_trigger_v2680()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  team_row public.teams%rowtype;
  history_id uuid;
  role_label text;
  previous_label text;
  affected_team_id uuid;
begin
  affected_team_id := case when tg_op = 'DELETE' then old.team_id else new.team_id end;

  select * into team_row
  from public.teams t
  where t.id = affected_team_id;

  if team_row.id is null then
    return null;
  end if;

  if tg_op = 'INSERT' then
    role_label := case new.funcao
      when 'responsavel' then 'Responsável'
      when 'vice_responsavel' then 'Vice-responsável'
      when 'organizador' then 'Organizador'
      else 'Membro'
    end;

    history_id := public.nexlab_record_team_history_v2680(
      new.team_id,
      'team_member_added',
      format('Integrante adicionado como %s.', role_label),
      jsonb_build_object('user_id', new.user_id, 'role', new.funcao)
    );

    if new.funcao <> 'responsavel'
       and new.user_id is distinct from auth.uid()
    then
      perform public.nexlab_notify_team_user_v2680(
        new.user_id,
        new.team_id,
        'Você foi adicionado a uma equipe',
        format('Você foi incluído na equipe %s com a função %s.', team_row.nome, role_label),
        format('team-member-added:%s:%s', new.team_id, history_id),
        'normal',
        jsonb_build_object('action', 'team_member_added', 'role', new.funcao)
      );
    end if;

    return new;
  end if;

  if tg_op = 'DELETE' then
    previous_label := case old.funcao
      when 'responsavel' then 'Responsável'
      when 'vice_responsavel' then 'Vice-responsável'
      when 'organizador' then 'Organizador'
      else 'Membro'
    end;

    history_id := public.nexlab_record_team_history_v2680(
      old.team_id,
      'team_member_removed',
      'Integrante removido da equipe.',
      jsonb_build_object('user_id', old.user_id, 'previous_role', old.funcao)
    );

    if old.user_id is distinct from auth.uid() then
      perform public.nexlab_notify_team_user_v2680(
        old.user_id,
        old.team_id,
        'Você foi removido de uma equipe',
        format('Você não faz mais parte da equipe %s.', team_row.nome),
        format('team-member-removed:%s:%s', old.team_id, history_id),
        'normal',
        jsonb_build_object('action', 'team_member_removed', 'previous_role', old.funcao)
      );
    end if;

    return old;
  end if;

  if old.funcao is distinct from new.funcao
     and old.funcao <> 'responsavel'
     and new.funcao <> 'responsavel'
  then
    previous_label := case old.funcao
      when 'vice_responsavel' then 'Vice-responsável'
      when 'organizador' then 'Organizador'
      else 'Membro'
    end;
    role_label := case new.funcao
      when 'vice_responsavel' then 'Vice-responsável'
      when 'organizador' then 'Organizador'
      else 'Membro'
    end;

    history_id := public.nexlab_record_team_history_v2680(
      new.team_id,
      'team_member_role_updated',
      format('Função de integrante alterada de %s para %s.', previous_label, role_label),
      jsonb_build_object(
        'user_id', new.user_id,
        'previous_role', old.funcao,
        'next_role', new.funcao
      )
    );

    if new.user_id is distinct from auth.uid() then
      perform public.nexlab_notify_team_user_v2680(
        new.user_id,
        new.team_id,
        'Sua função na equipe foi alterada',
        format('Sua função na equipe %s agora é %s.', team_row.nome, role_label),
        format('team-member-role:%s:%s', new.team_id, history_id),
        'normal',
        jsonb_build_object(
          'action', 'team_member_role_updated',
          'previous_role', old.funcao,
          'next_role', new.funcao
        )
      );
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_team_member_history_v2680 on public.team_members;
create trigger nexlab_team_member_history_v2680
after insert or update or delete on public.team_members
for each row execute function public.nexlab_team_member_history_trigger_v2680();

-- Histórico de vínculos.
create or replace function public.nexlab_team_link_history_trigger_v2680()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  entity_label text;
  type_label text;
begin
  if tg_op = 'UPDATE' and old.team_id is not distinct from new.team_id then
    return new;
  end if;

  if tg_op in ('DELETE','UPDATE')
     and exists (select 1 from public.teams t where t.id = old.team_id)
  then
    entity_label := public.nexlab_team_entity_label_v2680(old.entity_type, old.entity_id);
    type_label := case old.entity_type
      when 'project' then 'Projeto'
      when 'event' then 'Evento'
      else 'Reunião'
    end;

    perform public.nexlab_record_team_history_v2680(
      old.team_id,
      'team_link_removed',
      format('%s "%s" desvinculado da equipe.', type_label, entity_label),
      jsonb_build_object(
        'entity_type', old.entity_type,
        'entity_id', old.entity_id,
        'entity_label', entity_label
      )
    );
  end if;

  if tg_op in ('INSERT','UPDATE')
     and exists (select 1 from public.teams t where t.id = new.team_id)
  then
    entity_label := public.nexlab_team_entity_label_v2680(new.entity_type, new.entity_id);
    type_label := case new.entity_type
      when 'project' then 'Projeto'
      when 'event' then 'Evento'
      else 'Reunião'
    end;

    perform public.nexlab_record_team_history_v2680(
      new.team_id,
      'team_link_added',
      format('%s "%s" vinculado à equipe.', type_label, entity_label),
      jsonb_build_object(
        'entity_type', new.entity_type,
        'entity_id', new.entity_id,
        'entity_label', entity_label
      )
    );
  end if;

  return null;
end;
$$;

drop trigger if exists nexlab_team_link_history_v2680 on public.team_links;
create trigger nexlab_team_link_history_v2680
after insert or update or delete on public.team_links
for each row execute function public.nexlab_team_link_history_trigger_v2680();

-- Sincroniza os campos legados de projetos e reuniões com team_links.
create or replace function public.nexlab_sync_project_team_link_v2680()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.team_links
    where entity_type = 'project'
      and entity_id = old.id;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.equipe_id is not distinct from new.equipe_id then
    return new;
  end if;

  if new.equipe_id is null then
    delete from public.team_links
    where entity_type = 'project'
      and entity_id = new.id;
  else
    insert into public.team_links (
      team_id, entity_type, entity_id, created_by, created_at, updated_at
    ) values (
      new.equipe_id, 'project', new.id, auth.uid(), now(), now()
    )
    on conflict (entity_type, entity_id) do update
    set
      team_id = excluded.team_id,
      created_by = coalesce(excluded.created_by, public.team_links.created_by),
      updated_at = now()
    where public.team_links.team_id is distinct from excluded.team_id;
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_sync_project_team_link_v2680 on public.projects;
create trigger nexlab_sync_project_team_link_v2680
after insert or update of equipe_id or delete on public.projects
for each row execute function public.nexlab_sync_project_team_link_v2680();

create or replace function public.nexlab_sync_meeting_team_link_v2680()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.team_links
    where entity_type = 'meeting'
      and entity_id = old.id;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.team_id is not distinct from new.team_id then
    return new;
  end if;

  if new.team_id is null then
    delete from public.team_links
    where entity_type = 'meeting'
      and entity_id = new.id;
  else
    insert into public.team_links (
      team_id, entity_type, entity_id, created_by, created_at, updated_at
    ) values (
      new.team_id, 'meeting', new.id, auth.uid(), now(), now()
    )
    on conflict (entity_type, entity_id) do update
    set
      team_id = excluded.team_id,
      created_by = coalesce(excluded.created_by, public.team_links.created_by),
      updated_at = now()
    where public.team_links.team_id is distinct from excluded.team_id;
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_sync_meeting_team_link_v2680 on public.meetings;
create trigger nexlab_sync_meeting_team_link_v2680
after insert or update of team_id or delete on public.meetings
for each row execute function public.nexlab_sync_meeting_team_link_v2680();

create or replace function public.nexlab_manage_team_link_v2680(
  p_team_id uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_action text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  normalized_type text := lower(btrim(coalesce(p_entity_type, '')));
  normalized_action text := lower(btrim(coalesce(p_action, 'link')));
  team_row public.teams%rowtype;
  existing_link public.team_links%rowtype;
  affected integer := 0;
begin
  if auth.uid() is null
     or not public.nexlab_has_approved_access()
  then
    raise exception 'Usuário não autenticado ou sem acesso aprovado.' using errcode = '42501';
  end if;

  select * into team_row
  from public.teams t
  where t.id = p_team_id
  for update;

  if team_row.id is null then
    raise exception 'Equipe não encontrada.' using errcode = 'P0002';
  end if;

  if team_row.archived_at is not null then
    raise exception 'Restaure a equipe antes de alterar seus vínculos.' using errcode = '42501';
  end if;

  if not public.nexlab_can_manage_team_v2680(p_team_id) then
    raise exception 'Você não pode gerenciar os vínculos desta equipe.' using errcode = '42501';
  end if;

  if normalized_type not in ('project','event','meeting') then
    raise exception 'Tipo de vínculo inválido.' using errcode = '22023';
  end if;

  if normalized_action not in ('link','unlink') then
    raise exception 'Ação de vínculo inválida.' using errcode = '22023';
  end if;

  if p_entity_id is null then
    raise exception 'Selecione um registro para vincular.' using errcode = '22023';
  end if;

  if normalized_type = 'project' and not exists (
    select 1 from public.projects p where p.id = p_entity_id
  ) then
    raise exception 'Projeto não encontrado.' using errcode = 'P0002';
  elsif normalized_type = 'event' and not exists (
    select 1 from public.events e where e.id = p_entity_id
  ) then
    raise exception 'Evento não encontrado.' using errcode = 'P0002';
  elsif normalized_type = 'meeting' and not exists (
    select 1 from public.meetings m where m.id = p_entity_id
  ) then
    raise exception 'Reunião não encontrada.' using errcode = 'P0002';
  end if;

  select * into existing_link
  from public.team_links tl
  where tl.entity_type = normalized_type
    and tl.entity_id = p_entity_id
  for update;

  if normalized_action = 'link' then
    if existing_link.id is not null
       and existing_link.team_id <> p_team_id
    then
      raise exception 'Este registro já está vinculado a outra equipe.' using errcode = '23505';
    end if;

    insert into public.team_links (
      team_id, entity_type, entity_id, created_by, created_at, updated_at
    ) values (
      p_team_id, normalized_type, p_entity_id, auth.uid(), now(), now()
    )
    on conflict (entity_type, entity_id) do nothing;

    if normalized_type = 'project' then
      update public.projects set equipe_id = p_team_id where id = p_entity_id;
    elsif normalized_type = 'meeting' then
      update public.meetings set team_id = p_team_id where id = p_entity_id;
    end if;

    begin
      perform public.record_security_audit(
        'team_link_added',
        team_row.lider_id::text,
        jsonb_build_object(
          'team_id', p_team_id,
          'entity_type', normalized_type,
          'entity_id', p_entity_id,
          'module', 'equipes'
        )
      );
    exception when others then
      null;
    end;
  else
    delete from public.team_links
    where team_id = p_team_id
      and entity_type = normalized_type
      and entity_id = p_entity_id;

    get diagnostics affected = row_count;

    if affected = 0 then
      raise exception 'O vínculo não foi encontrado nesta equipe.' using errcode = 'P0002';
    end if;

    if normalized_type = 'project' then
      update public.projects
      set equipe_id = null
      where id = p_entity_id
        and equipe_id = p_team_id;
    elsif normalized_type = 'meeting' then
      update public.meetings
      set team_id = null
      where id = p_entity_id
        and team_id = p_team_id;
    end if;

    begin
      perform public.record_security_audit(
        'team_link_removed',
        team_row.lider_id::text,
        jsonb_build_object(
          'team_id', p_team_id,
          'entity_type', normalized_type,
          'entity_id', p_entity_id,
          'module', 'equipes'
        )
      );
    exception when others then
      null;
    end;
  end if;

  return jsonb_build_object(
    'ok', true,
    'team_id', p_team_id,
    'entity_type', normalized_type,
    'entity_id', p_entity_id,
    'linked', normalized_action = 'link'
  );
end;
$$;

revoke all on function public.nexlab_manage_team_link_v2680(uuid,text,uuid,text)
  from public, anon;
grant execute on function public.nexlab_manage_team_link_v2680(uuid,text,uuid,text)
  to authenticated;

create or replace function public.nexlab_get_team_workspace_v2680(p_team_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  history_result jsonb;
  links_result jsonb;
begin
  if not public.nexlab_can_view_team_v2680(p_team_id) then
    raise exception 'Você não possui acesso aos detalhes desta equipe.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(history_row) order by history_row.created_at desc), '[]'::jsonb)
    into history_result
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

  select coalesce(jsonb_agg(to_jsonb(link_row) order by link_row.entity_type, link_row.label), '[]'::jsonb)
    into links_result
  from (
    select
      tl.id,
      tl.entity_type,
      tl.entity_id,
      public.nexlab_team_entity_label_v2680(tl.entity_type, tl.entity_id) as label,
      case tl.entity_type
        when 'project' then (
          select concat_ws(' • ', nullif(p.status, ''), case when p.prazo is not null then to_char(p.prazo, 'DD/MM/YYYY') end)
          from public.projects p where p.id = tl.entity_id
        )
        when 'event' then (
          select concat_ws(' • ', to_char(e.data, 'DD/MM/YYYY'), nullif(e.local, ''))
          from public.events e where e.id = tl.entity_id
        )
        when 'meeting' then (
          select concat_ws(' • ', to_char(m.data, 'DD/MM/YYYY'), nullif(m.status, ''))
          from public.meetings m where m.id = tl.entity_id
        )
      end as subtitle,
      tl.created_by,
      tl.created_at,
      tl.updated_at
    from public.team_links tl
    where tl.team_id = p_team_id
  ) link_row;

  return jsonb_build_object(
    'team_id', p_team_id,
    'history', history_result,
    'links', links_result,
    'loaded_at', now()
  );
end;
$$;

revoke all on function public.nexlab_get_team_workspace_v2680(uuid)
  from public, anon;
grant execute on function public.nexlab_get_team_workspace_v2680(uuid)
  to authenticated;

-- Backfill dos vínculos legados.
insert into public.team_links (
  team_id, entity_type, entity_id, created_by, created_at, updated_at
)
select
  p.equipe_id,
  'project',
  p.id,
  p.autor_id,
  p.created_at,
  now()
from public.projects p
where p.equipe_id is not null
on conflict (entity_type, entity_id) do update
set team_id = excluded.team_id,
    updated_at = now()
where public.team_links.team_id is distinct from excluded.team_id;

insert into public.team_links (
  team_id, entity_type, entity_id, created_by, created_at, updated_at
)
select
  m.team_id,
  'meeting',
  m.id,
  m.autor_id,
  m.created_at,
  now()
from public.meetings m
where m.team_id is not null
on conflict (entity_type, entity_id) do update
set team_id = excluded.team_id,
    updated_at = now()
where public.team_links.team_id is distinct from excluded.team_id;

-- Importa auditorias históricas já existentes para equipes que continuam cadastradas.
insert into public.team_history (
  team_id,
  actor_id,
  actor_name,
  action,
  description,
  metadata,
  source_audit_id,
  created_at
)
select
  t.id,
  a.actor_user_id,
  coalesce(a.details ->> 'actor_name', p.nome, p.email, 'Sistema NEXLAB'),
  a.action,
  case a.action
    when 'team_created' then format('Equipe "%s" criada.', t.nome)
    when 'team_updated' then format('Informações da equipe "%s" atualizadas.', t.nome)
    when 'team_archived' then format('Equipe "%s" arquivada.', t.nome)
    when 'team_restored' then format('Equipe "%s" restaurada.', t.nome)
    when 'team_member_added' then 'Integrante adicionado à equipe.'
    when 'team_member_removed' then 'Integrante removido da equipe.'
    when 'team_member_role_updated' then 'Função de integrante atualizada.'
    when 'team_responsibility_transferred' then 'Responsabilidade da equipe transferida.'
    else 'Alteração registrada na equipe.'
  end,
  a.details,
  a.id,
  a.created_at
from public.security_audit_logs a
join public.teams t
  on t.id::text = coalesce(a.details ->> 'team_id', a.details ->> 'entity_id')
left join public.profiles p on p.id = a.actor_user_id
where a.action like 'team_%'
  and a.action <> 'team_deleted'
on conflict (source_audit_id) do nothing;

insert into public.team_history (
  team_id,
  actor_id,
  actor_name,
  action,
  description,
  metadata,
  created_at
)
select
  t.id,
  null,
  'Sistema NEXLAB',
  'team_created',
  format('Equipe "%s" registrada no NEXLAB.', t.nome),
  jsonb_build_object('backfill', true, 'leader_id', t.lider_id),
  t.created_at
from public.teams t
where not exists (
  select 1 from public.team_history h where h.team_id = t.id
);

alter table public.security_audit_logs
  drop constraint if exists security_audit_logs_action_check;

alter table public.security_audit_logs
  add constraint security_audit_logs_action_check
  check (
    action = any (array[
      'user_access_updated','user_deactivated','user_reactivated','user_deleted',
      'detailed_user_report_pdf','detailed_user_report_excel',
      'event_created','event_updated','event_deleted',
      'project_created','project_updated','project_status_updated','project_deleted',
      'team_created','team_updated','team_archived','team_restored','team_deleted',
      'team_member_added','team_member_removed','team_member_role_updated',
      'team_responsibility_transferred','team_link_added','team_link_removed',
      'meeting_created','meeting_updated','meeting_cancelled','meeting_deleted',
      'meeting_participants_replaced','reservation_cancelled','reservation_deleted',
      'reservation_participants_replaced','marketing_created','marketing_updated',
      'marketing_status_updated','marketing_deleted','feedback_status_updated',
      'asset_created','asset_updated','asset_condition_updated','asset_deleted',
      'post_created','post_updated','post_deleted','privacy_documents_accepted',
      'optional_consent_granted','optional_consent_revoked','privacy_request_created',
      'privacy_request_status_updated','profile_avatar_updated','profile_avatar_removed',
      'own_profile_updated','own_sensitive_profile_updated','profile_admin_managed',
      'profile_registration_submitted','profile_request_cancelled',
      'profile_request_resubmitted','profile_request_approved','profile_request_rejected',
      'report_export_recorded','role_permissions_updated','user_permissions_updated',
      'security_retention_applied','sensitive_user_report_accessed',
      'activity_logs_bulk_deleted'
    ]::text[])
  );

-- Realtime para atualizar os detalhes abertos sem recarregar toda a aplicação.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'team_history'
  ) then
    alter publication supabase_realtime add table public.team_history;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'team_links'
  ) then
    alter publication supabase_realtime add table public.team_links;
  end if;
end;
$$;

comment on table public.team_history is
  'Linha do tempo funcional das equipes do NEXLAB, com autor e metadados de cada alteração.';

comment on table public.team_links is
  'Vínculos entre equipes e projetos, eventos ou reuniões.';

comment on function public.nexlab_get_team_workspace_v2680(uuid) is
  'Retorna histórico e vínculos de uma equipe que o usuário pode visualizar.';

comment on function public.nexlab_manage_team_link_v2680(uuid,text,uuid,text) is
  'Adiciona ou remove vínculos de projetos, eventos e reuniões em equipes ativas.';

commit;
