-- NEXLAB v26.30.12 — R55.5.2
-- Correção 4: separa solicitações de perfil e responsáveis na Central de Pendências.
-- Executar no Supabase SQL Editor do projeto NEXLAB.

create or replace function public.nexlab_get_pending_center_v2690(
  p_page integer default 1,
  p_page_size integer default 8
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $function$
declare
  uid uuid := auth.uid();
  role_name text;
  is_admin boolean := false;
  is_manager boolean := false;
  page_no integer := greatest(coalesce(p_page, 1), 1);
  page_size integer := least(greatest(coalesce(p_page_size, 8), 1), 25);
  page_offset integer;

  profile_requests_data jsonb := '[]'::jsonb;
  responsibles_data jsonb := '[]'::jsonb;
  reservations_data jsonb := '[]'::jsonb;
  feedback_data jsonb := '[]'::jsonb;
  projects_data jsonb := '[]'::jsonb;
  assets_data jsonb := '[]'::jsonb;
  tasks_data jsonb := '[]'::jsonb;

  warnings jsonb := '[]'::jsonb;
  source_status jsonb := '{}'::jsonb;

  profile_count integer := 0;
  reservation_count integer := 0;
  feedback_count integer := 0;
  project_count integer := 0;
  asset_count integer := 0;
  task_count integer := 0;
  urgent_count integer := 0;
  source_urgent integer := 0;
begin
  if uid is null
     or not public.nexlab_has_approved_access()
     or not public.nexlab_has_effective_permission_v2680('module_pendencias')
  then
    raise exception 'Você não possui acesso às Pendências.' using errcode = '42501';
  end if;

  select lower(trim(p.role::text))
    into role_name
  from public.profiles p
  where p.id = uid
    and p.ativo is distinct from false;

  if role_name is null then
    raise exception 'Perfil ativo não encontrado.' using errcode = '42501';
  end if;

  is_admin := role_name in ('admin', 'administrador');
  is_manager := public.can_manage_operational_pending();
  page_offset := (page_no - 1) * page_size;

  -- Solicitações de perfil: somente solicitações realmente pendentes.
  if is_admin and public.nexlab_has_effective_permission_v2680('module_participantes') then
    begin
      select count(*)::integer,
             count(*) filter (
               where lower(trim(coalesce(vinculo_solicitado, ''))) in ('admin', 'administrador', 'coordenador')
             )::integer
        into profile_count, source_urgent
      from public.profiles
      where ativo is distinct from false
        and cadastro_completo is true
        and lower(trim(coalesce(role_request_status, ''))) = 'pending'
        and nullif(trim(coalesce(vinculo_solicitado, '')), '') is not null;

      urgent_count := urgent_count + source_urgent;
      source_urgent := 0;

      select coalesce(jsonb_agg(to_jsonb(q) order by q.requested_at, q.nome, q.id), '[]'::jsonb)
        into profile_requests_data
      from (
        select id,
               nome,
               lower(trim(role::text)) as role,
               ativo,
               created_at,
               lower(trim(vinculo_solicitado)) as vinculo_solicitado,
               cadastro_completo,
               lower(trim(role_request_status)) as role_request_status,
               role_request_created_at,
               coalesce(role_request_created_at, created_at) as requested_at
        from public.profiles
        where ativo is distinct from false
          and cadastro_completo is true
          and lower(trim(coalesce(role_request_status, ''))) = 'pending'
          and nullif(trim(coalesce(vinculo_solicitado, '')), '') is not null
        order by coalesce(role_request_created_at, created_at), id
        offset page_offset
        limit page_size
      ) q;

      source_status := source_status || jsonb_build_object('perfis', 'ok');
    exception when others then
      warnings := warnings || jsonb_build_array('perfis');
      source_status := source_status || jsonb_build_object('perfis', 'error');
    end;
  else
    source_status := source_status || jsonb_build_object('perfis', 'skipped');
  end if;

  -- Responsáveis são uma coleção auxiliar e nunca entram em profiles/profile_requests.
  if is_manager then
    begin
      select coalesce(jsonb_agg(to_jsonb(q) order by q.nome, q.id), '[]'::jsonb)
        into responsibles_data
      from (
        select id,
               nome,
               lower(trim(role::text)) as role,
               ativo
        from public.profiles
        where ativo is distinct from false
          and lower(trim(role::text)) in ('admin', 'administrador', 'coordenador')
        order by nome, id
      ) q;

      source_status := source_status || jsonb_build_object('responsaveis', 'ok');
    exception when others then
      warnings := warnings || jsonb_build_array('responsaveis');
      source_status := source_status || jsonb_build_object('responsaveis', 'error');
    end;
  else
    source_status := source_status || jsonb_build_object('responsaveis', 'skipped');
  end if;

  if public.nexlab_has_effective_permission_v2680('module_reserva') then
    begin
      select count(*)::integer
        into reservation_count
      from public.reservations r
      where lower(trim(coalesce(r.status, ''))) = 'pendente'
        and (is_manager or coalesce(r.usuario_id, r.user_id) = uid);

      urgent_count := urgent_count + reservation_count;

      select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at, q.id), '[]'::jsonb)
        into reservations_data
      from (
        select r.id,
               r.titulo,
               r.finalidade,
               r.data,
               r.hora_inicio,
               r.hora_fim,
               r.usuario_id,
               r.user_id,
               lower(trim(r.status)) as status,
               r.created_at,
               p.nome as owner_name
        from public.reservations r
        left join public.profiles p on p.id = coalesce(r.usuario_id, r.user_id)
        where lower(trim(coalesce(r.status, ''))) = 'pendente'
          and (is_manager or coalesce(r.usuario_id, r.user_id) = uid)
        order by r.created_at, r.id
        offset page_offset
        limit page_size
      ) q;

      source_status := source_status || jsonb_build_object('reservas', 'ok');
    exception when others then
      warnings := warnings || jsonb_build_array('reservas');
      source_status := source_status || jsonb_build_object('reservas', 'error');
    end;
  else
    source_status := source_status || jsonb_build_object('reservas', 'skipped');
  end if;

  if public.nexlab_has_effective_permission_v2680('module_feedback') then
    begin
      select count(*)::integer,
             count(*) filter (
               where lower(trim(coalesce(prioridade, ''))) = 'alta'
                  or lower(trim(coalesce(tipo, ''))) = 'bug'
             )::integer
        into feedback_count, source_urgent
      from public.feedback f
      where lower(trim(coalesce(f.status, ''))) not in ('resolvido', 'arquivado')
        and (is_manager or coalesce(f.usuario_id, f.autor_id) = uid);

      urgent_count := urgent_count + source_urgent;
      source_urgent := 0;

      select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at, q.id), '[]'::jsonb)
        into feedback_data
      from (
        select f.id,
               f.titulo,
               f.descricao,
               lower(trim(f.status)) as status,
               lower(trim(f.prioridade)) as prioridade,
               f.tipo,
               f.usuario_id,
               f.autor_id,
               f.responsavel_id,
               f.created_at,
               p.nome as owner_name
        from public.feedback f
        left join public.profiles p on p.id = coalesce(f.usuario_id, f.autor_id)
        where lower(trim(coalesce(f.status, ''))) not in ('resolvido', 'arquivado')
          and (is_manager or coalesce(f.usuario_id, f.autor_id) = uid)
        order by f.created_at, f.id
        offset page_offset
        limit page_size
      ) q;

      source_status := source_status || jsonb_build_object('feedbacks', 'ok');
    exception when others then
      warnings := warnings || jsonb_build_array('feedbacks');
      source_status := source_status || jsonb_build_object('feedbacks', 'error');
    end;
  else
    source_status := source_status || jsonb_build_object('feedbacks', 'skipped');
  end if;

  if public.nexlab_has_effective_permission_v2680('module_projetos') then
    begin
      select count(*)::integer,
             count(*) filter (where current_date - p.prazo >= 7)::integer
        into project_count, source_urgent
      from public.projects p
      where p.prazo is not null
        and p.prazo < current_date
        and lower(trim(coalesce(p.status, ''))) not in ('finalizado', 'arquivado')
        and public.nexlab_can_view_project_v2690(p.id)
        and (is_manager or p.responsavel_id = uid);

      urgent_count := urgent_count + source_urgent;
      source_urgent := 0;

      select coalesce(jsonb_agg(to_jsonb(q) order by q.prazo, q.id), '[]'::jsonb)
        into projects_data
      from (
        select p.id,
               p.nome,
               lower(trim(p.status)) as status,
               lower(trim(p.prioridade)) as prioridade,
               p.responsavel_id,
               p.prazo,
               p.created_at,
               owner.nome as owner_name
        from public.projects p
        left join public.profiles owner on owner.id = p.responsavel_id
        where p.prazo is not null
          and p.prazo < current_date
          and lower(trim(coalesce(p.status, ''))) not in ('finalizado', 'arquivado')
          and public.nexlab_can_view_project_v2690(p.id)
          and (is_manager or p.responsavel_id = uid)
        order by p.prazo, p.id
        offset page_offset
        limit page_size
      ) q;

      source_status := source_status || jsonb_build_object('projetos', 'ok');
    exception when others then
      warnings := warnings || jsonb_build_array('projetos');
      source_status := source_status || jsonb_build_object('projetos', 'error');
    end;

    begin
      select count(*)::integer,
             count(*) filter (where p.prazo is not null and p.prazo < current_date)::integer
        into task_count, source_urgent
      from public.project_tasks t
      join public.projects p on p.id = t.project_id
      where t.responsavel_id = uid
        and coalesce(t.done, false) is false
        and lower(trim(coalesce(p.status, ''))) not in ('finalizado', 'arquivado')
        and public.nexlab_can_view_project_v2690(p.id);

      urgent_count := urgent_count + source_urgent;
      source_urgent := 0;

      select coalesce(jsonb_agg(to_jsonb(q) order by q.project_deadline nulls last, q.created_at, q.id), '[]'::jsonb)
        into tasks_data
      from (
        select t.id,
               t.project_id,
               t.titulo as title,
               coalesce(t.done, false) as done,
               t.responsavel_id,
               t.created_at,
               p.nome as project_name,
               lower(trim(p.status)) as project_status,
               p.prazo as project_deadline
        from public.project_tasks t
        join public.projects p on p.id = t.project_id
        where t.responsavel_id = uid
          and coalesce(t.done, false) is false
          and lower(trim(coalesce(p.status, ''))) not in ('finalizado', 'arquivado')
          and public.nexlab_can_view_project_v2690(p.id)
        order by p.prazo nulls last, t.created_at, t.id
        offset page_offset
        limit page_size
      ) q;

      source_status := source_status || jsonb_build_object('tarefas', 'ok');
    exception when others then
      warnings := warnings || jsonb_build_array('tarefas');
      source_status := source_status || jsonb_build_object('tarefas', 'error');
    end;
  else
    source_status := source_status || jsonb_build_object('projetos', 'skipped', 'tarefas', 'skipped');
  end if;

  if is_manager and public.nexlab_has_effective_permission_v2680('module_patrimonio') then
    begin
      select count(*)::integer,
             count(*) filter (where coalesce(quantidade_danificada, 0) > 0)::integer
        into asset_count, source_urgent
      from public.assets
      where coalesce(quantidade_manutencao, 0) + coalesce(quantidade_danificada, 0) > 0;

      urgent_count := urgent_count + source_urgent;
      source_urgent := 0;

      select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at, q.id), '[]'::jsonb)
        into assets_data
      from (
        select id,
               nome,
               created_at,
               quantidade_manutencao,
               quantidade_danificada
        from public.assets
        where coalesce(quantidade_manutencao, 0) + coalesce(quantidade_danificada, 0) > 0
        order by created_at, id
        offset page_offset
        limit page_size
      ) q;

      source_status := source_status || jsonb_build_object('patrimonio', 'ok');
    exception when others then
      warnings := warnings || jsonb_build_array('patrimonio');
      source_status := source_status || jsonb_build_object('patrimonio', 'error');
    end;
  else
    source_status := source_status || jsonb_build_object('patrimonio', 'skipped');
  end if;

  return jsonb_build_object(
    'ok', true,
    -- Compatibilidade: profiles agora contém somente solicitações reais.
    'profiles', profile_requests_data,
    'profile_requests', profile_requests_data,
    'responsibles', responsibles_data,
    'reservations', reservations_data,
    'feedback', feedback_data,
    'projects', projects_data,
    'assets', assets_data,
    'tasks', tasks_data,
    'warnings', warnings,
    'partial', jsonb_array_length(warnings) > 0,
    'source_status', source_status,
    'metrics', jsonb_build_object(
      'total', profile_count + reservation_count + feedback_count + project_count + asset_count + task_count,
      'decisions', profile_count + reservation_count + feedback_count,
      'alerts', project_count + asset_count,
      'tasks', task_count,
      'urgent', urgent_count
    ),
    'pagination', jsonb_build_object(
      'page', page_no,
      'page_size', page_size,
      'total', profile_count + reservation_count + feedback_count + project_count + asset_count + task_count,
      'has_more', profile_count > page_no * page_size
        or reservation_count > page_no * page_size
        or feedback_count > page_no * page_size
        or project_count > page_no * page_size
        or asset_count > page_no * page_size
        or task_count > page_no * page_size
    ),
    'generated_at', now()
  );
end;
$function$;

revoke all on function public.nexlab_get_pending_center_v2690(integer, integer) from public, anon;
grant execute on function public.nexlab_get_pending_center_v2690(integer, integer) to authenticated, service_role;
