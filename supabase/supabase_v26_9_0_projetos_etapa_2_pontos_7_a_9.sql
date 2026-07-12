-- NEXLAB v26.9.0 — Projetos, segunda etapa (pontos 7, 8 e 9)
-- Painel de detalhes, histórico completo e permissões específicas.

begin;

-- 1. Permissões específicas do módulo Projetos
insert into public.nexlab_permission_catalog (
  permission_key,
  label,
  description,
  category,
  module_id,
  core,
  admin_only,
  grantable,
  eligible_roles,
  sort_order,
  active,
  created_at,
  updated_at
)
values
(
  'projects_view_all',
  'Visualizar todos os projetos',
  'Permite consultar projetos além daqueles criados pelo usuário, sob sua responsabilidade ou vinculados à sua equipe.',
  'Operação',
  'projetos',
  false,
  false,
  true,
  array['admin','coordenador','bolsista','coworking_junior']::text[],
  121,
  true,
  now(),
  now()
),
(
  'projects_manage_own',
  'Gerenciar projetos próprios',
  'Permite criar projetos e gerenciar projetos criados pelo usuário ou sob sua responsabilidade.',
  'Operação',
  'projetos',
  false,
  false,
  true,
  array['admin','coordenador','bolsista','coworking_junior']::text[],
  122,
  true,
  now(),
  now()
),
(
  'projects_manage_all',
  'Gerenciar todos os projetos',
  'Permite editar, movimentar e administrar qualquer projeto do laboratório.',
  'Operação',
  'projetos',
  false,
  false,
  true,
  array['admin','coordenador']::text[],
  123,
  true,
  now(),
  now()
)
on conflict (permission_key) do update
set
  label = excluded.label,
  description = excluded.description,
  category = excluded.category,
  module_id = excluded.module_id,
  core = excluded.core,
  admin_only = excluded.admin_only,
  grantable = excluded.grantable,
  eligible_roles = excluded.eligible_roles,
  sort_order = excluded.sort_order,
  active = excluded.active,
  updated_at = now();

insert into public.nexlab_role_permission_defaults (
  role_key,
  permission_key,
  allowed,
  updated_at
)
values
  ('admin', 'projects_view_all', true, now()),
  ('coordenador', 'projects_view_all', true, now()),
  ('bolsista', 'projects_view_all', true, now()),
  ('coworking_junior', 'projects_view_all', false, now()),
  ('admin', 'projects_manage_own', true, now()),
  ('coordenador', 'projects_manage_own', true, now()),
  ('bolsista', 'projects_manage_own', true, now()),
  ('coworking_junior', 'projects_manage_own', false, now()),
  ('admin', 'projects_manage_all', true, now()),
  ('coordenador', 'projects_manage_all', true, now())
on conflict (role_key, permission_key) do update
set
  allowed = excluded.allowed,
  updated_at = now();

create or replace function public.nexlab_has_project_permission_v2690(
  p_permission text
)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.ativo is distinct from false
      and p_permission = any(coalesce(p.effective_permissions, '{}'::text[]))
  );
$$;

create or replace function public.nexlab_can_create_project_v2690()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select
    public.nexlab_has_approved_access()
    and public.nexlab_has_project_permission_v2690('module_projetos')
    and (
      public.nexlab_has_project_permission_v2690('projects_manage_all')
      or public.nexlab_has_project_permission_v2690('projects_manage_own')
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

create or replace function public.nexlab_can_manage_project_v2690(
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
          public.nexlab_has_project_permission_v2690('projects_manage_all')
          or (
            public.nexlab_has_project_permission_v2690('projects_manage_own')
            and (
              pr.autor_id = auth.uid()
              or pr.responsavel_id = auth.uid()
            )
          )
        )
    );
$$;

create or replace function public.nexlab_can_delete_project_v2690(
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
    and exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and lower(coalesce(p.role::text, '')) in ('admin','administrador')
        and exists (
          select 1 from public.projects pr where pr.id = p_project_id
        )
    );
$$;

revoke all on function public.nexlab_has_project_permission_v2690(text)
  from public, anon;
revoke all on function public.nexlab_can_create_project_v2690()
  from public, anon;
revoke all on function public.nexlab_can_view_project_v2690(uuid)
  from public, anon;
revoke all on function public.nexlab_can_manage_project_v2690(uuid)
  from public, anon;
revoke all on function public.nexlab_can_delete_project_v2690(uuid)
  from public, anon;

grant execute on function public.nexlab_has_project_permission_v2690(text)
  to authenticated;
grant execute on function public.nexlab_can_create_project_v2690()
  to authenticated;
grant execute on function public.nexlab_can_view_project_v2690(uuid)
  to authenticated;
grant execute on function public.nexlab_can_manage_project_v2690(uuid)
  to authenticated;
grant execute on function public.nexlab_can_delete_project_v2690(uuid)
  to authenticated;

-- 2. Histórico dos projetos
create table if not exists public.project_history (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  actor_name text,
  action text not null,
  description text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.project_history
  drop constraint if exists project_history_action_check;

alter table public.project_history
  add constraint project_history_action_check
  check (
    action = any (
      array[
        'project_created',
        'project_updated',
        'project_status_changed',
        'project_reordered',
        'project_priority_changed',
        'project_responsible_changed',
        'project_deadline_changed',
        'project_team_changed',
        'task_created',
        'task_updated',
        'task_completed',
        'task_reopened',
        'task_deleted'
      ]::text[]
    )
  );

create index if not exists project_history_project_created_idx
  on public.project_history(project_id, created_at desc);

create index if not exists project_history_actor_created_idx
  on public.project_history(actor_id, created_at desc)
  where actor_id is not null;

alter table public.project_history enable row level security;

drop policy if exists project_history_v2690_select
  on public.project_history;

create policy project_history_v2690_select
on public.project_history
for select
to authenticated
using (
  public.nexlab_can_view_project_v2690(project_id)
);

create or replace function public.nexlab_project_status_label_v2690(
  p_status text
)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case lower(coalesce(p_status, ''))
    when 'ideia' then 'Ideia'
    when 'analise' then 'Em análise'
    when 'planejamento' then 'Planejamento'
    when 'aprovacao' then 'Aprovado'
    when 'execucao' then 'Em execução'
    when 'finalizado' then 'Finalizado'
    when 'arquivado' then 'Arquivado'
    else coalesce(nullif(btrim(p_status), ''), 'Não definido')
  end;
$$;

create or replace function public.nexlab_project_priority_label_v2690(
  p_priority text
)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case lower(coalesce(p_priority, ''))
    when 'alta' then 'Alta'
    when 'media' then 'Média'
    when 'baixa' then 'Baixa'
    else coalesce(nullif(btrim(p_priority), ''), 'Não definida')
  end;
$$;

create or replace function public.nexlab_add_project_history_v2690(
  p_project_id uuid,
  p_action text,
  p_description text,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  history_id uuid;
  current_actor uuid := auth.uid();
  current_actor_name text;
begin
  if p_project_id is null
     or nullif(btrim(coalesce(p_description, '')), '') is null
  then
    return null;
  end if;

  select p.nome
    into current_actor_name
  from public.profiles p
  where p.id = current_actor;

  insert into public.project_history (
    project_id,
    actor_id,
    actor_name,
    action,
    description,
    metadata,
    created_at
  )
  values (
    p_project_id,
    current_actor,
    coalesce(current_actor_name, 'Sistema'),
    p_action,
    left(btrim(p_description), 500),
    coalesce(p_metadata, '{}'::jsonb),
    now()
  )
  returning id into history_id;

  return history_id;
end;
$$;

revoke all on function public.nexlab_add_project_history_v2690(
  uuid,
  text,
  text,
  jsonb
) from public, anon, authenticated;

create or replace function public.nexlab_project_history_trigger_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  previous_name text;
  next_name text;
begin
  if tg_op = 'INSERT' then
    perform public.nexlab_add_project_history_v2690(
      new.id,
      'project_created',
      format('Projeto criado na etapa %s.', public.nexlab_project_status_label_v2690(new.status)),
      jsonb_build_object(
        'status', new.status,
        'priority', new.prioridade,
        'responsible_id', new.responsavel_id,
        'team_id', new.equipe_id,
        'deadline', new.prazo
      )
    );
    return new;
  end if;

  if new.status is distinct from old.status then
    perform public.nexlab_add_project_history_v2690(
      new.id,
      'project_status_changed',
      format(
        'Etapa alterada de %s para %s.',
        public.nexlab_project_status_label_v2690(old.status),
        public.nexlab_project_status_label_v2690(new.status)
      ),
      jsonb_build_object('previous_status', old.status, 'new_status', new.status)
    );
  end if;

  if new.prioridade is distinct from old.prioridade then
    perform public.nexlab_add_project_history_v2690(
      new.id,
      'project_priority_changed',
      format(
        'Prioridade alterada de %s para %s.',
        public.nexlab_project_priority_label_v2690(old.prioridade),
        public.nexlab_project_priority_label_v2690(new.prioridade)
      ),
      jsonb_build_object('previous_priority', old.prioridade, 'new_priority', new.prioridade)
    );
  end if;

  if new.responsavel_id is distinct from old.responsavel_id then
    select p.nome into previous_name
    from public.profiles p where p.id = old.responsavel_id;

    select p.nome into next_name
    from public.profiles p where p.id = new.responsavel_id;

    perform public.nexlab_add_project_history_v2690(
      new.id,
      'project_responsible_changed',
      format(
        'Responsável alterado de %s para %s.',
        coalesce(previous_name, 'Não definido'),
        coalesce(next_name, 'Não definido')
      ),
      jsonb_build_object(
        'previous_responsible_id', old.responsavel_id,
        'new_responsible_id', new.responsavel_id,
        'previous_responsible_name', previous_name,
        'new_responsible_name', next_name
      )
    );
  end if;

  if new.prazo is distinct from old.prazo then
    perform public.nexlab_add_project_history_v2690(
      new.id,
      'project_deadline_changed',
      format(
        'Prazo alterado de %s para %s.',
        coalesce(to_char(old.prazo, 'DD/MM/YYYY'), 'Não definido'),
        coalesce(to_char(new.prazo, 'DD/MM/YYYY'), 'Não definido')
      ),
      jsonb_build_object('previous_deadline', old.prazo, 'new_deadline', new.prazo)
    );
  end if;

  if new.equipe_id is distinct from old.equipe_id then
    select t.nome into previous_name
    from public.teams t where t.id = old.equipe_id;

    select t.nome into next_name
    from public.teams t where t.id = new.equipe_id;

    perform public.nexlab_add_project_history_v2690(
      new.id,
      'project_team_changed',
      format(
        'Equipe vinculada alterada de %s para %s.',
        coalesce(previous_name, 'Nenhuma'),
        coalesce(next_name, 'Nenhuma')
      ),
      jsonb_build_object(
        'previous_team_id', old.equipe_id,
        'new_team_id', new.equipe_id,
        'previous_team_name', previous_name,
        'new_team_name', next_name
      )
    );
  end if;

  if new.nome is distinct from old.nome
     or new.descricao is distinct from old.descricao
  then
    perform public.nexlab_add_project_history_v2690(
      new.id,
      'project_updated',
      'Informações gerais do projeto foram atualizadas.',
      jsonb_build_object(
        'previous_name', old.nome,
        'new_name', new.nome,
        'description_changed', new.descricao is distinct from old.descricao
      )
    );
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_project_history_v2690
  on public.projects;

create trigger nexlab_project_history_v2690
after insert or update on public.projects
for each row
execute function public.nexlab_project_history_trigger_v2690();

create or replace function public.nexlab_project_task_history_trigger_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    perform public.nexlab_add_project_history_v2690(
      new.project_id,
      'task_created',
      format('Tarefa adicionada: %s.', new.titulo),
      jsonb_build_object(
        'task_id', new.id,
        'task_title', new.titulo,
        'responsible_id', new.responsavel_id,
        'done', new.done
      )
    );
    return new;
  end if;

  if tg_op = 'DELETE' then
    perform public.nexlab_add_project_history_v2690(
      old.project_id,
      'task_deleted',
      format('Tarefa removida: %s.', old.titulo),
      jsonb_build_object(
        'task_id', old.id,
        'task_title', old.titulo,
        'responsible_id', old.responsavel_id,
        'done', old.done
      )
    );
    return old;
  end if;

  if new.done is distinct from old.done then
    perform public.nexlab_add_project_history_v2690(
      new.project_id,
      case when new.done then 'task_completed' else 'task_reopened' end,
      format(
        'Tarefa %s: %s.',
        case when new.done then 'concluída' else 'reaberta' end,
        new.titulo
      ),
      jsonb_build_object(
        'task_id', new.id,
        'task_title', new.titulo,
        'previous_done', old.done,
        'new_done', new.done
      )
    );
  elsif new.titulo is distinct from old.titulo
        or new.responsavel_id is distinct from old.responsavel_id
  then
    perform public.nexlab_add_project_history_v2690(
      new.project_id,
      'task_updated',
      format('Tarefa atualizada: %s.', new.titulo),
      jsonb_build_object(
        'task_id', new.id,
        'previous_title', old.titulo,
        'new_title', new.titulo,
        'previous_responsible_id', old.responsavel_id,
        'new_responsible_id', new.responsavel_id
      )
    );
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_project_task_history_v2690
  on public.project_tasks;

create trigger nexlab_project_task_history_v2690
after insert or update or delete on public.project_tasks
for each row
execute function public.nexlab_project_task_history_trigger_v2690();

insert into public.project_history (
  project_id,
  actor_id,
  actor_name,
  action,
  description,
  metadata,
  created_at
)
select
  pr.id,
  pr.autor_id,
  coalesce(author_profile.nome, 'Sistema'),
  'project_created',
  format(
    'Projeto criado na etapa %s.',
    public.nexlab_project_status_label_v2690(pr.status)
  ),
  jsonb_build_object(
    'status', pr.status,
    'priority', pr.prioridade,
    'responsible_id', pr.responsavel_id,
    'team_id', pr.equipe_id,
    'deadline', pr.prazo,
    'backfilled', true
  ),
  pr.created_at
from public.projects pr
left join public.profiles author_profile
  on author_profile.id = pr.autor_id
where not exists (
  select 1
  from public.project_history ph
  where ph.project_id = pr.id
);

-- Evita alterar a data de atualização de todos os cards durante uma simples normalização de posição.
create or replace function public.nexlab_projects_set_kanban_defaults_v2690()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    new.updated_at := coalesce(new.updated_at, now());

    if coalesce(new.kanban_order, 0) <= 0 then
      select coalesce(max(p.kanban_order), 0) + 1000
        into new.kanban_order
      from public.projects p
      where p.status = new.status;
    end if;

    return new;
  end if;

  if new.nome is distinct from old.nome
     or new.descricao is distinct from old.descricao
     or new.status is distinct from old.status
     or new.prazo is distinct from old.prazo
     or new.responsavel_id is distinct from old.responsavel_id
     or new.equipe_id is distinct from old.equipe_id
     or new.prioridade is distinct from old.prioridade
  then
    new.updated_at := now();
  else
    new.updated_at := old.updated_at;
  end if;

  return new;
end;
$$;

-- 3. RLS alinhada às permissões específicas
alter table public.projects enable row level security;
alter table public.project_tasks enable row level security;

drop policy if exists "todos veem projetos" on public.projects;
drop policy if exists "todos criam projetos" on public.projects;
drop policy if exists "edita projetos" on public.projects;
drop policy if exists "exclui projetos" on public.projects;
drop policy if exists projects_v2690_select on public.projects;
drop policy if exists projects_v2690_insert on public.projects;
drop policy if exists projects_v2690_update on public.projects;
drop policy if exists projects_v2690_delete on public.projects;

create policy projects_v2690_select
on public.projects
for select
to authenticated
using (
  public.nexlab_can_view_project_v2690(id)
);

create policy projects_v2690_insert
on public.projects
for insert
to authenticated
with check (
  public.nexlab_can_create_project_v2690()
  and (
    public.nexlab_has_project_permission_v2690('projects_manage_all')
    or autor_id = auth.uid()
  )
);

create policy projects_v2690_update
on public.projects
for update
to authenticated
using (
  public.nexlab_can_manage_project_v2690(id)
)
with check (
  public.nexlab_has_project_permission_v2690('projects_manage_all')
  or (
    public.nexlab_has_project_permission_v2690('projects_manage_own')
    and (
      autor_id = auth.uid()
      or responsavel_id = auth.uid()
    )
  )
);

create policy projects_v2690_delete
on public.projects
for delete
to authenticated
using (
  public.nexlab_can_delete_project_v2690(id)
);

drop policy if exists "todos veem tarefas" on public.project_tasks;
drop policy if exists "coord cria tarefas" on public.project_tasks;
drop policy if exists "atualiza tarefas" on public.project_tasks;
drop policy if exists "coord exclui tarefas" on public.project_tasks;
drop policy if exists project_tasks_v2690_select on public.project_tasks;
drop policy if exists project_tasks_v2690_insert on public.project_tasks;
drop policy if exists project_tasks_v2690_update on public.project_tasks;
drop policy if exists project_tasks_v2690_delete on public.project_tasks;

create policy project_tasks_v2690_select
on public.project_tasks
for select
to authenticated
using (
  public.nexlab_can_view_project_v2690(project_id)
);

create policy project_tasks_v2690_insert
on public.project_tasks
for insert
to authenticated
with check (
  public.nexlab_can_manage_project_v2690(project_id)
);

create policy project_tasks_v2690_update
on public.project_tasks
for update
to authenticated
using (
  public.nexlab_can_manage_project_v2690(project_id)
  or responsavel_id = auth.uid()
)
with check (
  public.nexlab_can_manage_project_v2690(project_id)
  or responsavel_id = auth.uid()
);

create policy project_tasks_v2690_delete
on public.project_tasks
for delete
to authenticated
using (
  public.nexlab_can_manage_project_v2690(project_id)
);

-- 4. Workspace consolidado do painel de detalhes
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
begin
  if auth.uid() is null
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

  select to_jsonb(pr)
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
        'created_at', task.created_at
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

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'type', link.entity_type,
        'id', link.entity_id,
        'title', case link.entity_type
          when 'event' then event_record.titulo
          when 'meeting' then meeting_record.titulo
          else null
        end,
        'date', case link.entity_type
          when 'event' then event_record.data
          when 'meeting' then meeting_record.data
          else null
        end,
        'time', case link.entity_type
          when 'event' then event_record.hora::text
          when 'meeting' then meeting_record.hora::text
          else null
        end,
        'location', case link.entity_type
          when 'event' then event_record.local
          when 'meeting' then meeting_record.local
          else null
        end
      )
      order by
        case link.entity_type
          when 'event' then event_record.data
          when 'meeting' then meeting_record.data
          else null
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
    and link.entity_type in ('event','meeting');

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
  where attachment.modulo in ('projetos','projects','project')
    and attachment.record_id = p_project_id;

  return jsonb_build_object(
    'ok', true,
    'project', project_data,
    'tasks', tasks_data,
    'history', history_data,
    'team', team_data,
    'participants', participants_data,
    'agenda', agenda_data,
    'attachments', attachments_data,
    'permissions', jsonb_build_object(
      'can_view', true,
      'can_manage', public.nexlab_can_manage_project_v2690(p_project_id),
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

-- 5. Movimentação Kanban alinhada às novas permissões e ao histórico
create or replace function public.nexlab_move_project_v2690(
  p_project_id uuid,
  p_target_status text,
  p_target_index integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  current_project public.projects%rowtype;
  source_status text;
  target_status text := lower(btrim(coalesce(p_target_status, '')));
  target_index integer;
  source_ids uuid[] := '{}'::uuid[];
  target_ids uuid[] := '{}'::uuid[];
  merged_ids uuid[] := '{}'::uuid[];
  item_id uuid;
  item_position integer;
  project_snapshot jsonb;
  affected_projects jsonb;
begin
  if auth.uid() is null
     or not public.nexlab_has_approved_access()
  then
    raise exception 'Usuário não autenticado ou sem acesso aprovado.'
      using errcode = '42501';
  end if;

  if target_status not in (
    'ideia',
    'analise',
    'planejamento',
    'aprovacao',
    'execucao',
    'finalizado',
    'arquivado'
  ) then
    raise exception 'Status de projeto inválido.'
      using errcode = '22023';
  end if;

  select pr.*
    into current_project
  from public.projects pr
  where pr.id = p_project_id
  for update;

  if current_project.id is null then
    raise exception 'Projeto não encontrado.'
      using errcode = 'P0002';
  end if;

  if not public.nexlab_can_manage_project_v2690(p_project_id) then
    raise exception 'Você não possui permissão para movimentar este projeto.'
      using errcode = '42501';
  end if;

  source_status := current_project.status;

  perform 1
  from public.projects pr
  where pr.status in (source_status, target_status)
  order by pr.status, pr.kanban_order, pr.created_at, pr.id
  for update;

  if source_status = target_status then
    select coalesce(
      array_agg(pr.id order by pr.kanban_order, pr.created_at, pr.id),
      '{}'::uuid[]
    )
    into target_ids
    from public.projects pr
    where pr.status = target_status
      and pr.id <> p_project_id;

    target_index := greatest(
      0,
      least(
        coalesce(p_target_index, cardinality(target_ids)),
        cardinality(target_ids)
      )
    );

    merged_ids :=
      coalesce(target_ids[1:target_index], '{}'::uuid[])
      || array[p_project_id]
      || coalesce(
        target_ids[(target_index + 1):cardinality(target_ids)],
        '{}'::uuid[]
      );

    item_position := 0;
    foreach item_id in array merged_ids
    loop
      item_position := item_position + 1;
      update public.projects
      set kanban_order = item_position * 1000
      where id = item_id;
    end loop;

    perform public.nexlab_add_project_history_v2690(
      p_project_id,
      'project_reordered',
      format('Posição atualizada dentro da etapa %s.', public.nexlab_project_status_label_v2690(target_status)),
      jsonb_build_object(
        'status', target_status,
        'target_index', target_index,
        'previous_order', current_project.kanban_order
      )
    );
  else
    select coalesce(
      array_agg(pr.id order by pr.kanban_order, pr.created_at, pr.id),
      '{}'::uuid[]
    )
    into source_ids
    from public.projects pr
    where pr.status = source_status
      and pr.id <> p_project_id;

    item_position := 0;
    foreach item_id in array source_ids
    loop
      item_position := item_position + 1;
      update public.projects
      set kanban_order = item_position * 1000
      where id = item_id;
    end loop;

    select coalesce(
      array_agg(pr.id order by pr.kanban_order, pr.created_at, pr.id),
      '{}'::uuid[]
    )
    into target_ids
    from public.projects pr
    where pr.status = target_status
      and pr.id <> p_project_id;

    target_index := greatest(
      0,
      least(
        coalesce(p_target_index, cardinality(target_ids)),
        cardinality(target_ids)
      )
    );

    merged_ids :=
      coalesce(target_ids[1:target_index], '{}'::uuid[])
      || array[p_project_id]
      || coalesce(
        target_ids[(target_index + 1):cardinality(target_ids)],
        '{}'::uuid[]
      );

    item_position := 0;
    foreach item_id in array merged_ids
    loop
      item_position := item_position + 1;
      update public.projects
      set
        status = target_status,
        kanban_order = item_position * 1000
      where id = item_id;
    end loop;
  end if;

  select to_jsonb(pr)
    into project_snapshot
  from public.projects pr
  where pr.id = p_project_id;

  select coalesce(
    jsonb_agg(to_jsonb(pr) order by pr.status, pr.kanban_order, pr.created_at, pr.id),
    '[]'::jsonb
  )
  into affected_projects
  from public.projects pr
  where pr.status in (source_status, target_status);

  begin
    perform public.record_security_audit(
      'project_kanban_moved',
      current_project.responsavel_id::text,
      jsonb_build_object(
        'entity_id', current_project.id,
        'entity_name', current_project.nome,
        'previous_status', source_status,
        'new_status', target_status,
        'target_index', target_index,
        'kanban_order', project_snapshot->>'kanban_order',
        'module', 'projetos'
      )
    );
  exception
    when undefined_function then null;
    when others then null;
  end;

  return jsonb_build_object(
    'ok', true,
    'project', project_snapshot,
    'projects', affected_projects,
    'previous_status', source_status,
    'new_status', target_status,
    'target_index', target_index
  );
end;
$$;

revoke all on function public.nexlab_move_project_v2690(uuid, text, integer)
  from public, anon;
grant execute on function public.nexlab_move_project_v2690(uuid, text, integer)
  to authenticated;

-- 6. Realtime e sincronização das permissões
DO $$
begin
  if exists (
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'project_history'
  ) then
    alter publication supabase_realtime add table public.project_history;
  end if;
end;
$$;

DO $$
begin
  perform public.nexlab_recalculate_all_permissions();
exception
  when undefined_function then null;
end;
$$;

comment on table public.project_history
is 'Linha do tempo funcional dos projetos e respectivas tarefas.';

comment on function public.nexlab_get_project_workspace_v2690(uuid)
is 'Retorna detalhes consolidados, tarefas, participantes, agenda da equipe, anexos, histórico e permissões do projeto.';

comment on function public.nexlab_can_manage_project_v2690(uuid)
is 'Verifica a permissão efetiva para editar e movimentar um projeto específico.';

commit;
