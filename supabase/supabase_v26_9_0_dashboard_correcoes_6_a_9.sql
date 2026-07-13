-- NEXLAB v26.9.0 — Dashboard, correções 6 a 9
-- 6. Meus Projetos conforme autoria, responsabilidade, equipe, tarefa e acesso global.
-- 7. Indicadores de Equipes calculados no Supabase com escopo explícito.
-- 8. Última atividade consolidada por projeto.
-- 9. A atualização Realtime é implementada no frontend; esta RPC fornece o refresh consolidado.

begin;

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
  team_metrics_result jsonb := '{}'::jsonb;
  global_project_scope boolean := false;
  global_team_scope boolean := false;
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

  global_team_scope := public.nexlab_can_view_all_teams_v2680();

  with visible_projects as (
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
      public.nexlab_can_view_project_full_v2690(p.id) as full_access,
      p.autor_id = current_user_id as is_author,
      p.responsavel_id = current_user_id as is_responsible,
      exists (
        select 1
        from public.team_members tm
        where tm.team_id = p.equipe_id
          and tm.user_id = current_user_id
      ) as is_team_member,
      exists (
        select 1
        from public.project_tasks task_access
        where task_access.project_id = p.id
          and task_access.responsavel_id = current_user_id
      ) as has_assigned_task,
      coalesce((
        select count(*)
        from public.project_tasks own_task
        where own_task.project_id = p.id
          and own_task.responsavel_id = current_user_id
      ), 0)::integer as assigned_task_count,
      coalesce((
        select count(*)
        from public.project_tasks own_task
        where own_task.project_id = p.id
          and own_task.responsavel_id = current_user_id
          and own_task.done is not true
      ), 0)::integer as assigned_pending_task_count,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', own_task.id,
            'title', own_task.titulo,
            'done', own_task.done,
            'created_at', own_task.created_at
          )
          order by own_task.done, own_task.created_at, own_task.id
        )
        from public.project_tasks own_task
        where own_task.project_id = p.id
          and own_task.responsavel_id = current_user_id
      ), '[]'::jsonb) as assigned_tasks,
      greatest(
        coalesce(p.updated_at, p.created_at),
        coalesce((
          select max(history.created_at)
          from public.project_history history
          where history.project_id = p.id
        ), p.created_at),
        coalesce((
          select max(task_activity.created_at)
          from public.project_tasks task_activity
          where task_activity.project_id = p.id
        ), p.created_at),
        coalesce((
          select max(coalesce(link_activity.updated_at, link_activity.created_at))
          from public.project_links link_activity
          where link_activity.project_id = p.id
        ), p.created_at)
      ) as last_activity_at
    from public.projects p
    where public.nexlab_can_view_project_v2690(p.id)
  ), classified_projects as (
    select
      visible_projects.*,
      array_remove(array[
        case when is_author then 'author' end,
        case when is_responsible then 'responsible' end,
        case when is_team_member then 'team' end,
        case when has_assigned_task then 'task' end,
        case when global_project_scope then 'global' end
      ], null)::text[] as access_reasons,
      case
        when is_responsible then 'Responsável'
        when is_author then 'Autor'
        when is_team_member then 'Minha equipe'
        when has_assigned_task then 'Tarefa atribuída'
        when global_project_scope then 'Acesso global'
        else 'Projeto visível'
      end as access_label
    from visible_projects
  )
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
          'last_activity_at', project_row.last_activity_at,
          'access_scope', case when project_row.full_access then 'full' else 'task_only' end,
          'access_reasons', to_jsonb(project_row.access_reasons),
          'access_label', project_row.access_label,
          'assigned_task_count', project_row.assigned_task_count,
          'assigned_pending_task_count', project_row.assigned_pending_task_count,
          'assigned_tasks', project_row.assigned_tasks
        )
      )
      order by project_row.last_activity_at desc nulls last,
               project_row.created_at desc,
               project_row.id
    ),
    '[]'::jsonb
  )
  into projects_result
  from classified_projects project_row;

  with visible_teams as (
    select t.*
    from public.teams t
    where public.nexlab_can_view_team_v2680(t.id)
  )
  select jsonb_build_object(
    'scope', case when global_team_scope then 'global' else 'visible' end,
    'total_count', count(*),
    'active_count', count(*) filter (where team.archived_at is null),
    'archived_count', count(*) filter (where team.archived_at is not null),
    'unique_member_count', (
      select count(distinct member.user_id)
      from public.team_members member
      join visible_teams member_team on member_team.id = member.team_id
    ),
    'without_projects_count', count(*) filter (
      where team.archived_at is null
        and not exists (
          select 1
          from public.projects linked_project
          where linked_project.equipe_id = team.id
        )
        and not exists (
          select 1
          from public.team_links linked_record
          where linked_record.team_id = team.id
            and linked_record.entity_type = 'project'
        )
    )
  )
  into team_metrics_result
  from visible_teams team;

  return jsonb_build_object(
    'ok', true,
    'scope', case when global_project_scope then 'global' else 'visible' end,
    'projects', projects_result,
    'project_count', jsonb_array_length(projects_result),
    'team_metrics', team_metrics_result,
    'generated_at', now()
  );
end;
$$;

revoke all on function public.nexlab_get_dashboard_summary_v2690()
from public, anon;

grant execute on function public.nexlab_get_dashboard_summary_v2690()
to authenticated;

comment on function public.nexlab_get_dashboard_summary_v2690()
is 'Resumo seguro e consolidado do Dashboard: projetos por origem de acesso, atividade recente e métricas de equipes por escopo.';

commit;
