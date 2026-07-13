-- NEXLAB v26.9.0 — Dashboard, correção crítica 5
-- Remove políticas genéricas permissivas de Projetos e cria um resumo
-- seguro para o Dashboard, sem consultas diretas às tabelas brutas.

begin;

alter table public.projects enable row level security;
alter table public.project_tasks enable row level security;

-- Estas políticas ALL eram permissivas e, por serem combinadas com OR,
-- podiam enfraquecer as políticas específicas do módulo Projetos.
drop policy if exists nexlab_approved_account_gate on public.projects;
drop policy if exists nexlab_approved_account_gate on public.project_tasks;

-- Recria as políticas específicas com validação explícita da conta aprovada.
drop policy if exists projects_v2690_select on public.projects;
create policy projects_v2690_select
on public.projects
for select
to authenticated
using (
  (select public.nexlab_has_approved_access())
  and public.nexlab_can_view_project_v2690(id)
);

drop policy if exists projects_v2690_insert on public.projects;
create policy projects_v2690_insert
on public.projects
for insert
to authenticated
with check (
  (select public.nexlab_has_approved_access())
  and public.nexlab_can_create_project_v2690()
  and (
    public.nexlab_has_project_permission_v2690('projects_manage_all')
    or autor_id = (select auth.uid())
  )
);

drop policy if exists projects_v2690_update on public.projects;
create policy projects_v2690_update
on public.projects
for update
to authenticated
using (
  (select public.nexlab_has_approved_access())
  and public.nexlab_can_manage_project_v2690(id)
)
with check (
  (select public.nexlab_has_approved_access())
  and public.nexlab_can_manage_project_v2690(id)
);

drop policy if exists projects_v2690_delete on public.projects;
create policy projects_v2690_delete
on public.projects
for delete
to authenticated
using (
  (select public.nexlab_has_approved_access())
  and public.nexlab_can_delete_project_v2690(id)
);

drop policy if exists project_tasks_v2690_select on public.project_tasks;
create policy project_tasks_v2690_select
on public.project_tasks
for select
to authenticated
using (
  (select public.nexlab_has_approved_access())
  and (
    public.nexlab_can_view_project_full_v2690(project_id)
    or responsavel_id = (select auth.uid())
  )
);

drop policy if exists project_tasks_v2690_insert on public.project_tasks;
create policy project_tasks_v2690_insert
on public.project_tasks
for insert
to authenticated
with check (
  (select public.nexlab_has_approved_access())
  and public.nexlab_can_manage_project_v2690(project_id)
);

drop policy if exists project_tasks_v2690_update on public.project_tasks;
create policy project_tasks_v2690_update
on public.project_tasks
for update
to authenticated
using (
  (select public.nexlab_has_approved_access())
  and (
    public.nexlab_can_manage_project_v2690(project_id)
    or responsavel_id = (select auth.uid())
  )
)
with check (
  (select public.nexlab_has_approved_access())
  and (
    public.nexlab_can_manage_project_v2690(project_id)
    or responsavel_id = (select auth.uid())
  )
);

drop policy if exists project_tasks_v2690_delete on public.project_tasks;
create policy project_tasks_v2690_delete
on public.project_tasks
for delete
to authenticated
using (
  (select public.nexlab_has_approved_access())
  and public.nexlab_can_manage_project_v2690(project_id)
);

create or replace function public.nexlab_get_dashboard_summary_v2690()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  current_user_id uuid := auth.uid();
  projects_result jsonb := '[]'::jsonb;
  global_project_scope boolean := false;
begin
  if current_user_id is null
     or not public.nexlab_has_approved_access()
     or not public.nexlab_has_effective_permission_v2680('module_dashboard')
  then
    raise exception 'Você não possui acesso ao Dashboard.'
      using errcode = '42501';
  end if;

  global_project_scope :=
    public.nexlab_has_project_permission_v2690('projects_view_all')
    or public.nexlab_has_project_permission_v2690('projects_manage_all');

  select coalesce(
    jsonb_agg(
      jsonb_strip_nulls(
        jsonb_build_object(
          'id', project_row.id,
          'nome', project_row.nome,
          'descricao', case when project_row.full_access then project_row.descricao else null end,
          'status', project_row.status,
          'prioridade', project_row.prioridade,
          'prazo', project_row.prazo,
          'responsavel_id', case when project_row.full_access then project_row.responsavel_id else null end,
          'equipe_id', case when project_row.full_access then project_row.equipe_id else null end,
          'autor_id', case when project_row.full_access then project_row.autor_id else null end,
          'created_at', project_row.created_at,
          'updated_at', project_row.updated_at,
          'access_scope', case when project_row.full_access then 'full' else 'task_only' end
        )
      )
      order by project_row.updated_at desc nulls last,
               project_row.created_at desc,
               project_row.id
    ),
    '[]'::jsonb
  )
  into projects_result
  from (
    select
      p.id,
      p.nome,
      p.descricao,
      p.status,
      p.prioridade,
      p.prazo,
      p.responsavel_id,
      p.equipe_id,
      p.autor_id,
      p.created_at,
      p.updated_at,
      public.nexlab_can_view_project_full_v2690(p.id) as full_access
    from public.projects p
    where public.nexlab_can_view_project_v2690(p.id)
  ) project_row;

  return jsonb_build_object(
    'ok', true,
    'scope', case when global_project_scope then 'global' else 'visible' end,
    'projects', projects_result,
    'project_count', jsonb_array_length(projects_result),
    'generated_at', now()
  );
end;
$$;

revoke all on function public.nexlab_get_dashboard_summary_v2690()
from public, anon;

grant execute on function public.nexlab_get_dashboard_summary_v2690()
to authenticated;

comment on function public.nexlab_get_dashboard_summary_v2690()
is 'Retorna ao Dashboard somente projetos visíveis ao usuário, reduzindo campos no acesso concedido apenas por tarefa.';

commit;
