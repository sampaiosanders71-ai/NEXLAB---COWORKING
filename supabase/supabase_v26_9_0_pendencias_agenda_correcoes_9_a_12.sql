-- NEXLAB v26.9.0 — Pendências e Agenda, correções 9 a 12
-- 9. Gestão transacional de feedbacks.
-- 10. Reuniões futuras deixam de integrar a fila de Pendências (frontend).
-- 11. Tarefas atribuídas passam a integrar Pendências com retorno mínimo seguro.
-- 12. Indicadores passam a separar decisões, alertas e tarefas (frontend).

begin;

create or replace function public.nexlab_manage_feedback_v2690(
  p_feedback_id uuid,
  p_action text,
  p_responsible_id uuid default null,
  p_expected_status text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  feedback_row public.feedback%rowtype;
  normalized_action text := lower(btrim(coalesce(p_action, '')));
  normalized_expected text := nullif(lower(btrim(coalesce(p_expected_status, ''))), '');
  next_status text;
  next_responsible uuid;
  next_resolved_at timestamptz;
  owner_id uuid;
begin
  if auth.uid() is null
     or not public.nexlab_has_approved_access()
     or not public.can_manage_operational_pending()
  then
    raise exception 'Somente Administradores e Coordenadores podem gerenciar feedbacks.'
      using errcode = '42501';
  end if;

  if normalized_action not in ('assign', 'unassign', 'resolve', 'archive') then
    raise exception 'Ação de feedback inválida.'
      using errcode = '22023';
  end if;

  if normalized_expected is null then
    raise exception 'O status esperado do feedback precisa ser informado.'
      using errcode = '22023';
  end if;

  select f.*
    into feedback_row
  from public.feedback f
  where f.id = p_feedback_id
  for update;

  if not found then
    raise exception 'Feedback não encontrado.'
      using errcode = 'P0002';
  end if;

  if lower(coalesce(feedback_row.status, '')) <> normalized_expected then
    raise exception
      'Este feedback já foi alterado por outro usuário. Status atual: %.',
      coalesce(feedback_row.status, 'não informado')
      using errcode = '40001';
  end if;

  if normalized_action = 'assign' then
    if p_responsible_id is null then
      raise exception 'Selecione um responsável para o feedback.'
        using errcode = '22023';
    end if;

    if not exists (
      select 1
      from public.profiles p
      where p.id = p_responsible_id
        and p.ativo is distinct from false
        and lower(p.role::text) in ('admin', 'administrador', 'coordenador')
    ) then
      raise exception 'O responsável precisa ser um Administrador ou Coordenador ativo.'
        using errcode = '23503';
    end if;

    next_status := 'em_analise';
    next_responsible := p_responsible_id;
    next_resolved_at := null;
  elsif normalized_action = 'unassign' then
    next_status := 'novo';
    next_responsible := null;
    next_resolved_at := null;
  elsif normalized_action = 'resolve' then
    if feedback_row.status not in ('novo', 'em_analise') then
      raise exception 'Somente feedbacks novos ou em análise podem ser resolvidos.'
        using errcode = '22023';
    end if;

    next_status := 'resolvido';
    next_responsible := feedback_row.responsavel_id;
    next_resolved_at := now();
  else
    if feedback_row.status not in ('novo', 'em_analise') then
      raise exception 'Somente feedbacks novos ou em análise podem ser arquivados.'
        using errcode = '22023';
    end if;

    next_status := 'arquivado';
    next_responsible := feedback_row.responsavel_id;
    next_resolved_at := now();
  end if;

  update public.feedback f
  set
    status = next_status,
    responsavel_id = next_responsible,
    resolved_at = next_resolved_at
  where f.id = feedback_row.id;

  owner_id := coalesce(feedback_row.usuario_id, feedback_row.autor_id);

  begin
    perform public.record_security_audit(
      'feedback_status_updated',
      owner_id::text,
      jsonb_build_object(
        'feedback_id', feedback_row.id,
        'operation', normalized_action,
        'previous_status', feedback_row.status,
        'new_status', next_status,
        'previous_responsible_id', feedback_row.responsavel_id,
        'new_responsible_id', next_responsible,
        'feedback_owner_id', owner_id,
        'module', 'pendencias'
      )
    );
  exception
    when undefined_function then null;
  end;

  return jsonb_build_object(
    'ok', true,
    'feedback_id', feedback_row.id,
    'action', normalized_action,
    'previous_status', feedback_row.status,
    'status', next_status,
    'responsible_id', next_responsible,
    'resolved_at', next_resolved_at
  );
end;
$$;

revoke all on function public.nexlab_manage_feedback_v2690(uuid, text, uuid, text)
from public, anon;

grant execute on function public.nexlab_manage_feedback_v2690(uuid, text, uuid, text)
to authenticated;

comment on function public.nexlab_manage_feedback_v2690(uuid, text, uuid, text)
is 'Atribui, remove responsável, resolve ou arquiva feedback sob bloqueio de linha e validação de status esperado.';

create or replace function public.nexlab_get_my_pending_tasks_v2690()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  current_user_id uuid := auth.uid();
  result jsonb := '[]'::jsonb;
begin
  if current_user_id is null
     or not public.nexlab_has_approved_access()
     or not public.nexlab_has_effective_permission_v2680('module_pendencias')
  then
    raise exception 'Você não possui acesso às Pendências.'
      using errcode = '42501';
  end if;

  if not public.nexlab_has_effective_permission_v2680('module_projetos') then
    return result;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', task.id,
        'project_id', task.project_id,
        'title', task.titulo,
        'done', task.done,
        'responsible_id', task.responsavel_id,
        'created_at', task.created_at,
        'project_name', project_record.nome,
        'project_status', project_record.status,
        'project_deadline', project_record.prazo
      )
      order by project_record.prazo nulls last, task.created_at, task.id
    ),
    '[]'::jsonb
  )
  into result
  from public.project_tasks task
  join public.projects project_record
    on project_record.id = task.project_id
  where task.responsavel_id = current_user_id
    and task.done is not true
    and project_record.status not in ('finalizado', 'arquivado')
    and public.nexlab_can_view_project_v2690(project_record.id);

  return result;
end;
$$;

revoke all on function public.nexlab_get_my_pending_tasks_v2690()
from public, anon;

grant execute on function public.nexlab_get_my_pending_tasks_v2690()
to authenticated;

comment on function public.nexlab_get_my_pending_tasks_v2690()
is 'Retorna somente tarefas abertas atribuídas ao usuário atual, com dados mínimos do projeto para a Central de Pendências.';

commit;
