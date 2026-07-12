-- NEXLAB v26.9.0 — Projetos Kanban (etapa 1)
-- Pontos 1, 2 e 3: quadro Kanban, cards arrastáveis e persistência de status/posição.

begin;

alter table public.projects
  add column if not exists kanban_order integer,
  add column if not exists updated_at timestamptz not null default now();

with ordered_projects as (
  select
    p.id,
    row_number() over (
      partition by p.status
      order by
        coalesce(p.kanban_order, 2147483647),
        p.created_at,
        p.id
    ) * 1000 as next_order
  from public.projects p
)
update public.projects p
set kanban_order = ordered_projects.next_order
from ordered_projects
where p.id = ordered_projects.id
  and p.kanban_order is distinct from ordered_projects.next_order;

alter table public.projects
  alter column kanban_order set default 0;

update public.projects
set kanban_order = 1000
where kanban_order is null;

alter table public.projects
  alter column kanban_order set not null;

alter table public.projects
  drop constraint if exists projects_kanban_order_check;

alter table public.projects
  add constraint projects_kanban_order_check
  check (kanban_order >= 0);

create index if not exists projects_status_kanban_order_idx
  on public.projects(status, kanban_order, created_at, id);

create or replace function public.nexlab_projects_set_kanban_defaults_v2690()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();

  if tg_op = 'INSERT'
     and coalesce(new.kanban_order, 0) <= 0
  then
    select coalesce(max(p.kanban_order), 0) + 1000
      into new.kanban_order
    from public.projects p
    where p.status = new.status;
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_projects_kanban_defaults_v2690
  on public.projects;

create trigger nexlab_projects_kanban_defaults_v2690
before insert or update on public.projects
for each row
execute function public.nexlab_projects_set_kanban_defaults_v2690();

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

  select p.*
    into current_project
  from public.projects p
  where p.id = p_project_id
  for update;

  if current_project.id is null then
    raise exception 'Projeto não encontrado.'
      using errcode = 'P0002';
  end if;

  if not (
    public.is_coord_or_admin()
    or current_project.autor_id = auth.uid()
  ) then
    raise exception 'Você não possui permissão para movimentar este projeto.'
      using errcode = '42501';
  end if;

  source_status := current_project.status;

  perform 1
  from public.projects p
  where p.status in (source_status, target_status)
  order by p.status, p.kanban_order, p.created_at, p.id
  for update;

  if source_status = target_status then
    select coalesce(
      array_agg(p.id order by p.kanban_order, p.created_at, p.id),
      '{}'::uuid[]
    )
      into target_ids
    from public.projects p
    where p.status = target_status
      and p.id <> p_project_id;

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
  else
    select coalesce(
      array_agg(p.id order by p.kanban_order, p.created_at, p.id),
      '{}'::uuid[]
    )
      into source_ids
    from public.projects p
    where p.status = source_status
      and p.id <> p_project_id;

    item_position := 0;
    foreach item_id in array source_ids
    loop
      item_position := item_position + 1;
      update public.projects
      set kanban_order = item_position * 1000
      where id = item_id;
    end loop;

    select coalesce(
      array_agg(p.id order by p.kanban_order, p.created_at, p.id),
      '{}'::uuid[]
    )
      into target_ids
    from public.projects p
    where p.status = target_status
      and p.id <> p_project_id;

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

  select to_jsonb(p)
    into project_snapshot
  from public.projects p
  where p.id = p_project_id;

  select coalesce(
    jsonb_agg(to_jsonb(p) order by p.status, p.kanban_order, p.created_at, p.id),
    '[]'::jsonb
  )
    into affected_projects
  from public.projects p
  where p.status in (source_status, target_status);

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

alter table public.security_audit_logs
  drop constraint if exists security_audit_logs_action_check;

alter table public.security_audit_logs
  add constraint security_audit_logs_action_check
  check (
    action = any (
      array[
        'user_access_updated',
        'user_deactivated',
        'user_reactivated',
        'user_deleted',
        'detailed_user_report_pdf',
        'detailed_user_report_excel',
        'event_created',
        'event_updated',
        'event_deleted',
        'project_created',
        'project_updated',
        'project_status_updated',
        'project_kanban_moved',
        'project_deleted',
        'team_created',
        'team_updated',
        'team_archived',
        'team_restored',
        'team_deleted',
        'team_member_added',
        'team_member_removed',
        'team_member_role_updated',
        'team_responsibility_transferred',
        'team_link_created',
        'team_link_removed',
        'meeting_created',
        'meeting_updated',
        'meeting_cancelled',
        'meeting_deleted',
        'meeting_participants_replaced',
        'reservation_cancelled',
        'reservation_deleted',
        'reservation_participants_replaced',
        'marketing_created',
        'marketing_updated',
        'marketing_status_updated',
        'marketing_deleted',
        'feedback_status_updated',
        'asset_created',
        'asset_updated',
        'asset_condition_updated',
        'asset_deleted',
        'post_created',
        'post_updated',
        'post_deleted',
        'privacy_documents_accepted',
        'optional_consent_granted',
        'optional_consent_revoked',
        'privacy_request_created',
        'privacy_request_status_updated',
        'profile_avatar_updated',
        'profile_avatar_removed',
        'own_profile_updated',
        'own_sensitive_profile_updated',
        'profile_admin_managed',
        'profile_registration_submitted',
        'profile_request_cancelled',
        'profile_request_resubmitted',
        'profile_request_approved',
        'profile_request_rejected',
        'report_export_recorded',
        'role_permissions_updated',
        'user_permissions_updated',
        'security_retention_applied',
        'sensitive_user_report_accessed',
        'activity_logs_bulk_deleted'
      ]::text[]
    )
  );

comment on column public.projects.kanban_order
is 'Posição persistida do card dentro da coluna de status no quadro Kanban.';

comment on function public.nexlab_move_project_v2690(uuid, text, integer)
is 'Move e reordena um projeto no quadro Kanban, normalizando as posições das colunas afetadas.';

commit;
