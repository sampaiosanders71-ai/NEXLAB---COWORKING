-- NEXLAB v26.9.0 — Pendências e Agenda, correções 5 a 8
-- 5. Agenda passa a consumir uma RPC segura e consolidada.
-- 6. Projetos acessados somente por tarefa não expõem descrição ou responsáveis.
-- 7. Aprovação/recusa de reservas passa a ser transacional e concorrente-segura.
-- 8. Recusa exige motivo e a decisão fica registrada com responsável e auditoria.

begin;

create or replace function public.nexlab_get_agenda_summary_v2690()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  current_user_id uuid := auth.uid();
  current_role text;
  can_events boolean := false;
  can_projects boolean := false;
  can_reservations boolean := false;
  can_marketing boolean := false;
  events_result jsonb := '[]'::jsonb;
  meetings_result jsonb := '[]'::jsonb;
  reservations_result jsonb := '[]'::jsonb;
  projects_result jsonb := '[]'::jsonb;
  marketing_result jsonb := '[]'::jsonb;
  marketing_dates_result jsonb := '[]'::jsonb;
begin
  if current_user_id is null
     or not public.nexlab_has_approved_access()
     or not public.nexlab_has_effective_permission_v2680('module_agenda')
  then
    raise exception 'Você não possui acesso à Agenda.'
      using errcode = '42501';
  end if;

  select lower(p.role::text)
    into current_role
  from public.profiles p
  where p.id = current_user_id
    and p.ativo is distinct from false;

  can_events := public.nexlab_has_effective_permission_v2680('module_eventos');
  can_projects := public.nexlab_has_effective_permission_v2680('module_projetos');
  can_reservations := public.nexlab_has_effective_permission_v2680('module_reserva');
  can_marketing := public.nexlab_has_effective_permission_v2680('module_marketing');

  if can_events then
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', e.id,
          'titulo', e.titulo,
          'data', e.data,
          'hora', e.hora,
          'horario', e.hora,
          'local', e.local,
          'vagas_limite', e.vagas_limite,
          'descricao', e.descricao,
          'organizador_id', e.responsavel_id,
          'created_at', e.created_at
        )
        order by e.data, e.hora nulls last, e.id
      ),
      '[]'::jsonb
    ) into events_result
    from public.events e;
  end if;

  if can_reservations then
    select coalesce(
      jsonb_agg(
        jsonb_strip_nulls(
          jsonb_build_object(
            'id', m.id,
            'titulo', m.titulo,
            'data', m.data,
            'hora', m.hora,
            'horario', m.hora,
            'local', m.local,
            'descricao', m.descricao,
            'link', m.link,
            'status', m.status,
            'cancelada_em', m.cancelada_em,
            'team_id', m.team_id,
            'autor_id', m.autor_id,
            'created_at', m.created_at
          )
        )
        order by m.data, m.hora nulls last, m.id
      ),
      '[]'::jsonb
    ) into meetings_result
    from public.meetings m
    where
      public.nexlab_is_gestor()
      or m.autor_id = current_user_id
      or m.para_todos = true
      or (
        m.alvo_roles is not null
        and current_role = any(m.alvo_roles)
      )
      or (
        m.alvo_users is not null
        and current_user_id = any(m.alvo_users)
      )
      or (
        m.team_id is not null
        and exists (
          select 1
          from public.team_members tm
          where tm.team_id = m.team_id
            and tm.user_id = current_user_id
        )
      )
      or exists (
        select 1
        from public.meeting_participants mp
        where mp.meeting_id = m.id
          and mp.user_id = current_user_id
      );

    -- A Agenda compartilhada recebe apenas campos públicos da reserva.
    select coalesce(
      jsonb_agg(
        jsonb_strip_nulls(
          jsonb_build_object(
            'id', r.id,
            'titulo', r.titulo,
            'finalidade', r.finalidade,
            'data', r.data,
            'hora_inicio', r.hora_inicio,
            'hora_fim', r.hora_fim,
            'status', r.status,
            'descricao', r.descricao,
            'sala_nome', r.sala_nome,
            'recursos', r.recursos,
            'created_at', r.created_at
          )
        )
        order by r.data, r.hora_inicio, r.id
      ),
      '[]'::jsonb
    ) into reservations_result
    from public.reservations r;
  end if;

  if can_projects then
    with visible_projects as (
      select
        p.id,
        p.nome,
        p.descricao,
        p.status,
        p.prioridade,
        p.responsavel_id,
        p.prazo,
        p.created_at,
        public.nexlab_can_view_project_full_v2690(p.id) as full_access
      from public.projects p
      where p.prazo is not null
        and public.nexlab_can_view_project_v2690(p.id)
    )
    select coalesce(
      jsonb_agg(
        jsonb_strip_nulls(
          jsonb_build_object(
            'id', vp.id,
            'nome', vp.nome,
            'descricao', case when vp.full_access then vp.descricao else null end,
            'status', vp.status,
            'prioridade', vp.prioridade,
            'responsavel_id', case when vp.full_access then vp.responsavel_id else null end,
            'prazo', vp.prazo,
            'created_at', vp.created_at,
            'access_scope', case when vp.full_access then 'full' else 'task_only' end
          )
        )
        order by vp.prazo, vp.id
      ),
      '[]'::jsonb
    ) into projects_result
    from visible_projects vp;
  end if;

  if can_marketing then
    select coalesce(
      jsonb_agg(
        jsonb_strip_nulls(
          jsonb_build_object(
            'id', mk.id,
            'titulo', mk.titulo,
            'descricao', mk.descricao,
            'tipo', mk.tipo,
            'canal', mk.canal,
            'status', mk.status,
            'data', mk.data,
            'link', mk.link,
            'responsavel_id', mk.responsavel_id,
            'created_at', mk.created_at
          )
        )
        order by mk.data nulls last, mk.id
      ),
      '[]'::jsonb
    ) into marketing_result
    from public.marketing mk
    where mk.data is not null;

    select coalesce(
      jsonb_agg(
        jsonb_strip_nulls(
          jsonb_build_object(
            'id', md.id,
            'titulo', md.titulo,
            'data', md.data,
            'tipo', md.tipo,
            'descricao', md.descricao,
            'autor_id', md.autor_id,
            'created_at', md.created_at
          )
        )
        order by md.data, md.id
      ),
      '[]'::jsonb
    ) into marketing_dates_result
    from public.marketing_dates md;
  end if;

  return jsonb_build_object(
    'ok', true,
    'events', events_result,
    'meetings', meetings_result,
    'reservations', reservations_result,
    'projects', projects_result,
    'marketing_campaigns', marketing_result,
    'marketing_dates', marketing_dates_result,
    'source_access', jsonb_build_object(
      'events', can_events,
      'projects', can_projects,
      'reservations', can_reservations,
      'marketing', can_marketing
    ),
    'generated_at', now()
  );
end;
$$;

revoke all on function public.nexlab_get_agenda_summary_v2690()
from public, anon;

grant execute on function public.nexlab_get_agenda_summary_v2690()
to authenticated;

comment on function public.nexlab_get_agenda_summary_v2690()
is 'Retorna uma Agenda consolidada com campos mínimos e mascara projetos acessados somente por tarefa.';

create or replace function public.nexlab_review_reservation_v2690(
  p_reservation_id uuid,
  p_decision text,
  p_reason text default null,
  p_expected_status text default 'pendente'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  reservation_row public.reservations%rowtype;
  normalized_decision text := lower(btrim(coalesce(p_decision, '')));
  normalized_expected text := lower(btrim(coalesce(p_expected_status, 'pendente')));
  normalized_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  local_now timestamp without time zone := now() at time zone 'America/Fortaleza';
  decision_action text;
begin
  if auth.uid() is null
     or not public.nexlab_has_approved_access()
     or not public.can_manage_operational_pending()
  then
    raise exception 'Somente Administradores e Coordenadores podem revisar reservas.'
      using errcode = '42501';
  end if;

  if normalized_decision not in ('aprovada', 'recusada') then
    raise exception 'A decisão deve ser aprovada ou recusada.'
      using errcode = '22023';
  end if;

  if normalized_expected <> 'pendente' then
    raise exception 'A revisão somente pode partir do status pendente.'
      using errcode = '22023';
  end if;

  if normalized_decision = 'recusada' then
    if normalized_reason is null or char_length(normalized_reason) < 5 then
      raise exception 'Informe um motivo de recusa com pelo menos 5 caracteres.'
        using errcode = '22023';
    end if;

    if char_length(normalized_reason) > 500 then
      raise exception 'O motivo da recusa deve possuir no máximo 500 caracteres.'
        using errcode = '22023';
    end if;
  end if;

  select r.*
    into reservation_row
  from public.reservations r
  where r.id = p_reservation_id
  for update;

  if not found then
    raise exception 'Reserva não encontrada.'
      using errcode = 'P0002';
  end if;

  if lower(coalesce(reservation_row.status, '')) <> normalized_expected then
    raise exception
      'Esta reserva já foi revisada ou alterada por outro usuário. Status atual: %.',
      coalesce(reservation_row.status, 'não informado')
      using errcode = '40001';
  end if;

  if normalized_decision = 'aprovada' and (
    reservation_row.data < local_now::date
    or (
      reservation_row.data = local_now::date
      and reservation_row.hora_fim <= local_now::time
    )
  ) then
    raise exception 'Não é possível aprovar uma reserva cujo período já terminou.'
      using errcode = '22023';
  end if;

  update public.reservations r
  set
    status = normalized_decision,
    reviewed_by = auth.uid(),
    reviewed_at = now(),
    review_note = case
      when normalized_decision = 'recusada' then normalized_reason
      else null
    end
  where r.id = reservation_row.id;

  decision_action := case
    when normalized_decision = 'aprovada' then 'reservation_approved'
    else 'reservation_rejected'
  end;

  begin
    perform public.record_security_audit(
      decision_action,
      reservation_row.usuario_id::text,
      jsonb_build_object(
        'reservation_id', reservation_row.id,
        'previous_status', reservation_row.status,
        'new_status', normalized_decision,
        'review_reason', normalized_reason,
        'reviewed_by', auth.uid(),
        'reservation_owner_id', reservation_row.usuario_id,
        'reservation_date', reservation_row.data,
        'start_time', reservation_row.hora_inicio,
        'end_time', reservation_row.hora_fim,
        'module', 'pendencias'
      )
    );
  exception
    when undefined_function then null;
  end;

  return jsonb_build_object(
    'ok', true,
    'reservation_id', reservation_row.id,
    'previous_status', reservation_row.status,
    'status', normalized_decision,
    'review_note', case
      when normalized_decision = 'recusada' then normalized_reason
      else null
    end,
    'reviewed_by', auth.uid(),
    'reviewed_at', now()
  );
end;
$$;

revoke all on function public.nexlab_review_reservation_v2690(uuid, text, text, text)
from public, anon;

grant execute on function public.nexlab_review_reservation_v2690(uuid, text, text, text)
to authenticated;

comment on function public.nexlab_review_reservation_v2690(uuid, text, text, text)
is 'Decide uma reserva pendente sob bloqueio de linha, exige motivo na recusa e registra auditoria.';


-- Amplia o catálogo de auditoria para as novas decisões de reserva.
alter table public.security_audit_logs
  drop constraint if exists security_audit_logs_action_check;

alter table public.security_audit_logs
  add constraint security_audit_logs_action_check
  check (
    action = any (array[
      'user_access_updated','user_deactivated','user_reactivated','user_deleted',
      'detailed_user_report_pdf','detailed_user_report_excel',
      'event_created','event_updated','event_deleted',
      'project_created','project_updated','project_status_updated','project_kanban_moved','project_deleted',
      'team_created','team_updated','team_archived','team_restored','team_deleted',
      'team_member_added','team_member_removed','team_member_role_updated','team_responsibility_transferred',
      'team_link_created','team_link_removed',
      'meeting_created','meeting_updated','meeting_cancelled','meeting_deleted','meeting_participants_replaced',
      'reservation_approved','reservation_rejected','reservation_cancelled','reservation_deleted','reservation_participants_replaced',
      'marketing_created','marketing_updated','marketing_status_updated','marketing_deleted',
      'feedback_status_updated',
      'asset_created','asset_updated','asset_condition_updated','asset_deleted',
      'post_created','post_updated','post_deleted',
      'privacy_documents_accepted','optional_consent_granted','optional_consent_revoked',
      'privacy_request_created','privacy_request_status_updated',
      'profile_avatar_updated','profile_avatar_removed','own_profile_updated','own_sensitive_profile_updated',
      'profile_admin_managed','profile_registration_submitted','profile_request_cancelled',
      'profile_request_resubmitted','profile_request_approved','profile_request_rejected',
      'report_export_recorded','role_permissions_updated','user_permissions_updated',
      'security_retention_applied','sensitive_user_report_accessed','activity_logs_bulk_deleted'
    ]::text[])
  );

commit;
