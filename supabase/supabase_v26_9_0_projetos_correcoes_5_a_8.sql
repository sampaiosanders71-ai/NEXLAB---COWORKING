-- NEXLAB v26.9.0 — Estabilização do módulo Projetos
-- Correções 5 a 8:
-- 5. valida vínculos diretos e impede project_links órfãos;
-- 6. normaliza e protege a estrutura da tabela projects;
-- 7. protege a ordenação Kanban contra concorrência e escritas diretas;
-- 8. alinha interface, RPC e RLS para edição, movimentação e transferências.

begin;

-- Correção 5: validação obrigatória de vínculos, inclusive em INSERT direto.
create or replace function public.nexlab_validate_project_link_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  new.entity_type := lower(btrim(coalesce(new.entity_type, '')));

  if new.entity_type not in ('event', 'meeting') then
    raise exception 'Tipo de vínculo inválido.' using errcode = '22023';
  end if;

  if new.entity_type = 'event'
     and not exists (select 1 from public.events e where e.id = new.entity_id)
  then
    raise exception 'O evento informado não existe.' using errcode = '23503';
  end if;

  if new.entity_type = 'meeting'
     and not exists (select 1 from public.meetings m where m.id = new.entity_id)
  then
    raise exception 'A reunião informada não existe.' using errcode = '23503';
  end if;

  new.created_by := coalesce(new.created_by, auth.uid());
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists nexlab_validate_project_link_v2690 on public.project_links;
create trigger nexlab_validate_project_link_v2690
before insert or update of entity_type, entity_id, project_id
on public.project_links
for each row
execute function public.nexlab_validate_project_link_v2690();

revoke all on function public.nexlab_validate_project_link_v2690()
from public, anon, authenticated;

-- Correção 6: normalização dos dados existentes antes das restrições.
update public.projects
set
  nome = btrim(nome),
  descricao = nullif(btrim(coalesce(descricao, '')), ''),
  status = lower(btrim(status)),
  prioridade = lower(btrim(prioridade)),
  updated_at = greatest(updated_at, created_at)
where
  nome is distinct from btrim(nome)
  or descricao is distinct from nullif(btrim(coalesce(descricao, '')), '')
  or status is distinct from lower(btrim(status))
  or prioridade is distinct from lower(btrim(prioridade))
  or updated_at < created_at;

create or replace function public.nexlab_projects_integrity_guard_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  new.nome := btrim(coalesce(new.nome, ''));
  new.descricao := nullif(btrim(coalesce(new.descricao, '')), '');
  new.status := lower(btrim(coalesce(new.status, '')));
  new.prioridade := lower(btrim(coalesce(new.prioridade, '')));

  if new.nome = '' then
    raise exception 'O nome do projeto é obrigatório.' using errcode = '23514';
  end if;

  if new.status not in (
    'ideia','analise','planejamento','aprovacao','execucao','finalizado','arquivado'
  ) then
    raise exception 'Status de projeto inválido.' using errcode = '23514';
  end if;

  if new.prioridade not in ('baixa','media','alta') then
    raise exception 'Prioridade de projeto inválida.' using errcode = '23514';
  end if;

  new.updated_at := greatest(coalesce(new.updated_at, now()), new.created_at);
  return new;
end;
$$;

drop trigger if exists nexlab_projects_integrity_guard_v2690 on public.projects;
create trigger nexlab_projects_integrity_guard_v2690
before insert or update on public.projects
for each row
execute function public.nexlab_projects_integrity_guard_v2690();

alter table public.projects drop constraint if exists projects_name_not_blank_check;
alter table public.projects add constraint projects_name_not_blank_check
check (btrim(nome) <> '');

alter table public.projects drop constraint if exists projects_status_check;
alter table public.projects add constraint projects_status_check
check (status in ('ideia','analise','planejamento','aprovacao','execucao','finalizado','arquivado'));

alter table public.projects drop constraint if exists projects_priority_check;
alter table public.projects add constraint projects_priority_check
check (prioridade in ('baixa','media','alta'));

alter table public.projects drop constraint if exists projects_updated_at_check;
alter table public.projects add constraint projects_updated_at_check
check (updated_at >= created_at);

-- Normaliza posições existentes antes da restrição única.
with ranked as (
  select
    id,
    row_number() over (
      partition by status
      order by kanban_order, created_at, id
    ) * 1000 as normalized_order
  from public.projects
)
update public.projects p
set kanban_order = ranked.normalized_order
from ranked
where p.id = ranked.id
  and p.kanban_order is distinct from ranked.normalized_order;

alter table public.projects drop constraint if exists projects_kanban_order_check;
alter table public.projects add constraint projects_kanban_order_check
check (kanban_order > 0);

revoke all on function public.nexlab_projects_integrity_guard_v2690()
from public, anon, authenticated;

-- Correção 8: permissões granulares para transferência e equipe.
create or replace function public.nexlab_can_transfer_project_v2690(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select public.nexlab_has_approved_access()
    and public.nexlab_has_project_permission_v2690('module_projetos')
    and exists (
      select 1
      from public.projects p
      where p.id = p_project_id
        and (
          public.nexlab_has_project_permission_v2690('projects_manage_all')
          or (
            public.nexlab_has_project_permission_v2690('projects_manage_own')
            and p.autor_id = auth.uid()
          )
        )
    );
$$;

create or replace function public.nexlab_can_change_project_team_v2690(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select public.nexlab_can_transfer_project_v2690(p_project_id);
$$;

revoke all on function public.nexlab_can_transfer_project_v2690(uuid)
from public, anon;
revoke all on function public.nexlab_can_change_project_team_v2690(uuid)
from public, anon;
grant execute on function public.nexlab_can_transfer_project_v2690(uuid)
to authenticated;
grant execute on function public.nexlab_can_change_project_team_v2690(uuid)
to authenticated;

create or replace function public.nexlab_project_update_guard_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  manage_all boolean;
  manage_own boolean;
begin
  if actor_id is null then
    return new;
  end if;

  if coalesce(current_setting('nexlab.kanban_rpc', true), '') = 'on' then
    if new.id is distinct from old.id
       or new.nome is distinct from old.nome
       or new.descricao is distinct from old.descricao
       or new.prazo is distinct from old.prazo
       or new.responsavel_id is distinct from old.responsavel_id
       or new.equipe_id is distinct from old.equipe_id
       or new.created_at is distinct from old.created_at
       or new.prioridade is distinct from old.prioridade
       or new.autor_id is distinct from old.autor_id
    then
      raise exception 'A movimentação Kanban não pode alterar dados estruturais do projeto.'
        using errcode = '42501';
    end if;

    return new;
  end if;

  manage_all := public.nexlab_has_project_permission_v2690('projects_manage_all');
  manage_own := public.nexlab_has_project_permission_v2690('projects_manage_own');

  if not manage_all
     and not (
       manage_own
       and (old.autor_id = actor_id or old.responsavel_id = actor_id)
     )
  then
    raise exception 'Você não possui permissão para atualizar este projeto.'
      using errcode = '42501';
  end if;

  if new.autor_id is distinct from old.autor_id then
    raise exception 'O autor original do projeto não pode ser alterado.'
      using errcode = '42501';
  end if;

  if (new.status is distinct from old.status
      or new.kanban_order is distinct from old.kanban_order)
     and coalesce(current_setting('nexlab.kanban_rpc', true), '') <> 'on'
  then
    raise exception 'Mudanças de etapa ou posição devem usar a movimentação segura do Kanban.'
      using errcode = '42501';
  end if;

  if not manage_all and old.autor_id is distinct from actor_id then
    if new.responsavel_id is distinct from old.responsavel_id then
      raise exception 'Somente o autor do projeto ou um gestor global pode transferir a responsabilidade.'
        using errcode = '42501';
    end if;

    if new.equipe_id is distinct from old.equipe_id then
      raise exception 'Somente o autor do projeto ou um gestor global pode alterar a equipe vinculada.'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_project_update_guard_v2690 on public.projects;
create trigger nexlab_project_update_guard_v2690
before update on public.projects
for each row
execute function public.nexlab_project_update_guard_v2690();

revoke all on function public.nexlab_project_update_guard_v2690()
from public, anon, authenticated;

-- Correção 7: o trigger de criação sempre posiciona no fim da coluna e usa lock transacional.
create or replace function public.nexlab_projects_set_kanban_defaults_v2690()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  first_status text;
  second_status text;
begin
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(
      hashtext('nexlab-project-kanban:' || new.status)::bigint
    );

    select coalesce(max(p.kanban_order), 0) + 1000
      into new.kanban_order
    from public.projects p
    where p.status = new.status;

    new.updated_at := coalesce(new.updated_at, now());
    return new;
  end if;

  if new.status is distinct from old.status
     or new.kanban_order is distinct from old.kanban_order
  then
    first_status := least(old.status, new.status);
    second_status := greatest(old.status, new.status);

    perform pg_advisory_xact_lock(
      hashtext('nexlab-project-kanban:' || first_status)::bigint
    );

    if second_status is distinct from first_status then
      perform pg_advisory_xact_lock(
        hashtext('nexlab-project-kanban:' || second_status)::bigint
      );
    end if;
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

alter table public.projects
  drop constraint if exists projects_status_kanban_order_unique;

alter table public.projects
  add constraint projects_status_kanban_order_unique
  unique (status, kanban_order)
  deferrable initially deferred;

-- RPC segura de atualização. Edição e movimentação ficam na mesma transação.
create or replace function public.nexlab_update_project_v2690(
  p_project_id uuid,
  p_nome text,
  p_descricao text,
  p_status text,
  p_prioridade text,
  p_responsavel_id uuid,
  p_equipe_id uuid,
  p_prazo date
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  current_project public.projects%rowtype;
  updated_project public.projects%rowtype;
  move_result jsonb;
  target_status text := lower(btrim(coalesce(p_status, '')));
  can_transfer boolean;
  can_change_team boolean;
begin
  if auth.uid() is null
     or not public.nexlab_can_manage_project_v2690(p_project_id)
  then
    raise exception 'Você não possui permissão para editar este projeto.'
      using errcode = '42501';
  end if;

  select p.* into current_project
  from public.projects p
  where p.id = p_project_id
  for update;

  if current_project.id is null then
    raise exception 'Projeto não encontrado.' using errcode = 'P0002';
  end if;

  can_transfer := public.nexlab_can_transfer_project_v2690(p_project_id);
  can_change_team := public.nexlab_can_change_project_team_v2690(p_project_id);

  if p_responsavel_id is distinct from current_project.responsavel_id
     and not can_transfer
  then
    raise exception 'Somente o autor do projeto ou um gestor global pode transferir a responsabilidade.'
      using errcode = '42501';
  end if;

  if p_equipe_id is distinct from current_project.equipe_id
     and not can_change_team
  then
    raise exception 'Somente o autor do projeto ou um gestor global pode alterar a equipe vinculada.'
      using errcode = '42501';
  end if;

  perform set_config('nexlab.project_update_rpc', 'on', true);

  update public.projects
  set
    nome = p_nome,
    descricao = p_descricao,
    prioridade = p_prioridade,
    responsavel_id = p_responsavel_id,
    equipe_id = p_equipe_id,
    prazo = p_prazo
  where id = p_project_id
  returning * into updated_project;

  if target_status is distinct from current_project.status then
    move_result := public.nexlab_move_project_v2690(
      p_project_id,
      target_status,
      null
    );

    select p.* into updated_project
    from public.projects p
    where p.id = p_project_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'project', to_jsonb(updated_project),
    'move', move_result,
    'permissions', jsonb_build_object(
      'can_manage', true,
      'can_move', true,
      'can_transfer_responsible', can_transfer,
      'can_change_team', can_change_team,
      'can_delete', public.nexlab_can_delete_project_v2690(p_project_id)
    )
  );
end;
$$;

revoke all on function public.nexlab_update_project_v2690(
  uuid,text,text,text,text,uuid,uuid,date
) from public, anon;
grant execute on function public.nexlab_update_project_v2690(
  uuid,text,text,text,text,uuid,uuid,date
) to authenticated;

-- RPC do Kanban com locks por coluna, flag interna e resposta filtrada.
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
  first_status text;
  second_status text;
begin
  if auth.uid() is null or not public.nexlab_has_approved_access() then
    raise exception 'Usuário não autenticado ou sem acesso aprovado.' using errcode = '42501';
  end if;

  if target_status not in ('ideia','analise','planejamento','aprovacao','execucao','finalizado','arquivado') then
    raise exception 'Status de projeto inválido.' using errcode = '22023';
  end if;

  select pr.* into current_project
  from public.projects pr
  where pr.id = p_project_id
  for update;

  if current_project.id is null then
    raise exception 'Projeto não encontrado.' using errcode = 'P0002';
  end if;

  if not public.nexlab_can_manage_project_v2690(p_project_id) then
    raise exception 'Você não possui permissão para movimentar este projeto.' using errcode = '42501';
  end if;

  source_status := current_project.status;
  first_status := least(source_status, target_status);
  second_status := greatest(source_status, target_status);

  perform pg_advisory_xact_lock(
    hashtext('nexlab-project-kanban:' || first_status)::bigint
  );
  if second_status is distinct from first_status then
    perform pg_advisory_xact_lock(
      hashtext('nexlab-project-kanban:' || second_status)::bigint
    );
  end if;

  perform set_config('nexlab.kanban_rpc', 'on', true);
  set constraints projects_status_kanban_order_unique deferred;

  perform 1
  from public.projects pr
  where pr.status in (source_status, target_status)
  order by pr.status, pr.kanban_order, pr.created_at, pr.id
  for update;

  if source_status = target_status then
    select coalesce(array_agg(pr.id order by pr.kanban_order, pr.created_at, pr.id), '{}'::uuid[])
      into target_ids
    from public.projects pr
    where pr.status = target_status
      and pr.id <> p_project_id;

    target_index := greatest(0, least(coalesce(p_target_index, cardinality(target_ids)), cardinality(target_ids)));
    merged_ids := coalesce(target_ids[1:target_index], '{}'::uuid[])
      || array[p_project_id]
      || coalesce(target_ids[(target_index + 1):cardinality(target_ids)], '{}'::uuid[]);

    item_position := 0;
    foreach item_id in array merged_ids loop
      item_position := item_position + 1;
      update public.projects
      set kanban_order = item_position * 1000
      where id = item_id;
    end loop;

    perform public.nexlab_add_project_history_v2690(
      p_project_id,
      'project_reordered',
      format('Posição atualizada dentro da etapa %s.', public.nexlab_project_status_label_v2690(target_status)),
      jsonb_build_object('status', target_status, 'target_index', target_index, 'previous_order', current_project.kanban_order)
    );
  else
    select coalesce(array_agg(pr.id order by pr.kanban_order, pr.created_at, pr.id), '{}'::uuid[])
      into source_ids
    from public.projects pr
    where pr.status = source_status
      and pr.id <> p_project_id;

    item_position := 0;
    foreach item_id in array source_ids loop
      item_position := item_position + 1;
      update public.projects
      set kanban_order = item_position * 1000
      where id = item_id;
    end loop;

    select coalesce(array_agg(pr.id order by pr.kanban_order, pr.created_at, pr.id), '{}'::uuid[])
      into target_ids
    from public.projects pr
    where pr.status = target_status
      and pr.id <> p_project_id;

    target_index := greatest(0, least(coalesce(p_target_index, cardinality(target_ids)), cardinality(target_ids)));
    merged_ids := coalesce(target_ids[1:target_index], '{}'::uuid[])
      || array[p_project_id]
      || coalesce(target_ids[(target_index + 1):cardinality(target_ids)], '{}'::uuid[]);

    item_position := 0;
    foreach item_id in array merged_ids loop
      item_position := item_position + 1;
      update public.projects
      set status = target_status,
          kanban_order = item_position * 1000
      where id = item_id;
    end loop;
  end if;

  set constraints projects_status_kanban_order_unique immediate;

  select to_jsonb(pr) into project_snapshot
  from public.projects pr
  where pr.id = p_project_id;

  select coalesce(
    jsonb_agg(to_jsonb(pr) order by pr.status, pr.kanban_order, pr.created_at, pr.id),
    '[]'::jsonb
  ) into affected_projects
  from public.projects pr
  where pr.status in (source_status, target_status)
    and public.nexlab_can_view_project_v2690(pr.id);

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
  exception when undefined_function then null; when others then null;
  end;

  perform set_config('nexlab.kanban_rpc', 'off', true);

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

revoke all on function public.nexlab_move_project_v2690(uuid,text,integer)
from public, anon;
grant execute on function public.nexlab_move_project_v2690(uuid,text,integer)
to authenticated;

-- Ajuste da RLS: a seleção e a autorização por registro permanecem,
-- enquanto as mudanças de campo são fiscalizadas pelo trigger de guarda.
drop policy if exists projects_v2690_update on public.projects;
create policy projects_v2690_update
on public.projects
for update
to authenticated
using (public.nexlab_can_manage_project_v2690(id))
with check (public.nexlab_can_manage_project_v2690(id));

comment on function public.nexlab_validate_project_link_v2690()
is 'Impede vínculos diretos de projetos com eventos ou reuniões inexistentes.';
comment on function public.nexlab_project_update_guard_v2690()
is 'Alinha edição de projetos: responsáveis operam o projeto, mas somente autor ou gestor global transferem responsável e equipe.';
comment on function public.nexlab_update_project_v2690(uuid,text,text,text,text,uuid,uuid,date)
is 'Atualiza o projeto e movimenta sua etapa de forma transacional, respeitando permissões granulares.';
comment on constraint projects_status_kanban_order_unique on public.projects
is 'Garante posição única por coluna do Kanban; a constraint é diferida para permitir reordenação transacional.';

commit;
