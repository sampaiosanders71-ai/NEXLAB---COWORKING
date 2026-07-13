-- NEXLAB v26.9.0 — Estabilização do módulo Projetos
-- Correções 1 a 4:
-- 1. restringe o retorno da RPC do Kanban aos projetos visíveis;
-- 2. a unificação das exportações é aplicada no frontend usando a RPC consolidada
--    e o registro oficial nexlab_record_report_export;
-- 3. limita responsáveis por tarefas à alteração do campo done;
-- 4. revoga execução externa das funções exclusivas de triggers.

begin;

-- Correção 1: a movimentação continua normalizando as duas colunas,
-- mas a resposta contém somente projetos que o usuário pode visualizar.
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
    'ideia','analise','planejamento','aprovacao',
    'execucao','finalizado','arquivado'
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
      format(
        'Posição atualizada dentro da etapa %s.',
        public.nexlab_project_status_label_v2690(target_status)
      ),
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
    jsonb_agg(
      to_jsonb(pr)
      order by pr.status, pr.kanban_order, pr.created_at, pr.id
    ),
    '[]'::jsonb
  )
    into affected_projects
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

-- Correção 3: gestores do projeto continuam podendo editar a tarefa completa.
-- O responsável da tarefa, sem gestão do projeto, pode somente concluir/reabrir.
create or replace function public.nexlab_project_task_update_guard_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  current_user_id uuid := auth.uid();
  can_manage_old_project boolean;
begin
  if current_user_id is null then
    raise exception 'Autenticação obrigatória para atualizar tarefas.'
      using errcode = '42501';
  end if;

  can_manage_old_project :=
    public.nexlab_can_manage_project_v2690(old.project_id);

  if can_manage_old_project then
    return new;
  end if;

  if old.responsavel_id is distinct from current_user_id then
    raise exception 'Você não possui permissão para atualizar esta tarefa.'
      using errcode = '42501';
  end if;

  if new.id is distinct from old.id
     or new.project_id is distinct from old.project_id
     or new.titulo is distinct from old.titulo
     or new.responsavel_id is distinct from old.responsavel_id
     or new.created_at is distinct from old.created_at
  then
    raise exception 'O responsável da tarefa pode somente concluir ou reabrir a própria tarefa.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_project_task_update_guard_v2690
  on public.project_tasks;

create trigger nexlab_project_task_update_guard_v2690
before update on public.project_tasks
for each row
execute function public.nexlab_project_task_update_guard_v2690();

-- Correção 4: funções de trigger não ficam expostas como RPCs.
revoke all on function public.nexlab_project_history_trigger_v2690()
  from public, anon, authenticated;
revoke all on function public.nexlab_project_link_activity_v2690()
  from public, anon, authenticated;
revoke all on function public.nexlab_project_notifications_trigger_v2690()
  from public, anon, authenticated;
revoke all on function public.nexlab_project_task_history_trigger_v2690()
  from public, anon, authenticated;
revoke all on function public.nexlab_project_task_notifications_trigger_v2690()
  from public, anon, authenticated;
revoke all on function public.nexlab_project_task_update_guard_v2690()
  from public, anon, authenticated;

comment on function public.nexlab_move_project_v2690(uuid, text, integer)
is 'Move e reordena projetos sem expor na resposta registros fora da permissão de visualização do usuário.';

comment on function public.nexlab_project_task_update_guard_v2690()
is 'Permite ao responsável da tarefa alterar somente o estado de conclusão; alterações estruturais exigem gestão do projeto.';

commit;
