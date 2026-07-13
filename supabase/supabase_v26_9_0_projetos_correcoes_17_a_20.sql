-- NEXLAB v26.9.0 — Estabilização do módulo Projetos
-- Correções 17 a 20:
-- 17. rollback concorrente limitado ao projeto/colunas afetadas no frontend;
-- 18. notificações de projetos excluídos são neutralizadas e arquivadas;
-- 19. exclusão segura limpa anexos e exige confirmação da remoção no Storage;
-- 20. preferências completas e deduplicação semântica de notificações.

begin;

-- ---------------------------------------------------------------------------
-- Correção 20 — preferências internas, e-mail, push e silêncio por categoria.
-- ---------------------------------------------------------------------------

alter table public.notification_preferences
  add column if not exists internal_enabled boolean not null default true;

comment on column public.notification_preferences.internal_enabled
is 'Controla se a categoria aparece na caixa interna de notificações. E-mail e push permanecem independentes.';

create or replace function public.nexlab_ensure_notification_preferences()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  standard_type text;
  standard_types text[] := array[
    '*',
    'profile_request',
    'profile_updated',
    'reservation_created',
    'reservation_decided',
    'reservation_reminder',
    'meeting_reminder',
    'feedback_created',
    'feedback_updated',
    'feedback_assigned',
    'project_updates',
    'system'
  ];
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.'
      using errcode = '42501';
  end if;

  foreach standard_type in array standard_types
  loop
    insert into public.notification_preferences (
      user_id,
      notification_type,
      internal_enabled,
      email_enabled,
      push_enabled,
      muted
    )
    select
      p.id,
      standard_type,
      true,
      false,
      false,
      false
    from public.profiles p
    where p.id = auth.uid()
    on conflict (user_id, notification_type) do nothing;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'types', standard_types
  );
end;
$$;

revoke all on function public.nexlab_ensure_notification_preferences()
from public, anon;

grant execute on function public.nexlab_ensure_notification_preferences()
to authenticated;

create or replace function public.nexlab_ensure_notification_user_settings()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.'
      using errcode = '42501';
  end if;

  insert into public.notification_user_settings (user_id)
  select p.id
  from public.profiles p
  where p.id = auth.uid()
  on conflict (user_id) do nothing;

  insert into public.notification_preferences (
    user_id,
    notification_type,
    internal_enabled,
    email_enabled,
    push_enabled,
    muted
  )
  select
    p.id,
    item.preference_key,
    true,
    false,
    false,
    false
  from public.profiles p
  cross join (
    values
      ('reservation_reminder'),
      ('meeting_reminder'),
      ('project_updates')
  ) as item(preference_key)
  where p.id = auth.uid()
  on conflict (user_id, notification_type) do nothing;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.nexlab_ensure_notification_user_settings()
from public, anon;

grant execute on function public.nexlab_ensure_notification_user_settings()
to authenticated;

insert into public.notification_preferences (
  user_id,
  notification_type,
  internal_enabled,
  email_enabled,
  push_enabled,
  muted
)
select
  p.id,
  'project_updates',
  true,
  false,
  false,
  false
from public.profiles p
where p.ativo is distinct from false
on conflict (user_id, notification_type) do nothing;

create or replace function public.nexlab_project_notification_v2690(
  p_recipient_id uuid,
  p_type text,
  p_title text,
  p_message text,
  p_project_id uuid,
  p_priority text default 'normal',
  p_metadata jsonb default '{}'::jsonb,
  p_source_suffix text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  normalized_type text := lower(btrim(coalesce(p_type, 'project_updated')));
  normalized_priority text := lower(btrim(coalesce(p_priority, 'normal')));
  normalized_title text := left(btrim(coalesce(p_title, 'Atualização de projeto')), 180);
  normalized_message text := left(btrim(coalesce(p_message, 'O projeto foi atualizado.')), 600);
  normalized_suffix text := coalesce(nullif(btrim(p_source_suffix), ''), 'change');
  semantic_bucket bigint := floor(extract(epoch from clock_timestamp()) / 300)::bigint;
  semantic_hash text;
  source_value text;
  preference_internal boolean := true;
  preference_muted boolean := false;
  preference_muted_until timestamptz := null;
  internal_visible boolean := true;
begin
  if p_recipient_id is null
     or p_project_id is null
     or p_recipient_id = auth.uid()
  then
    return;
  end if;

  if normalized_type not in (
    'project_assigned',
    'project_updated',
    'project_status_changed',
    'project_deadline_changed',
    'project_team_changed',
    'project_task_changed',
    'project_link_changed'
  ) then
    normalized_type := 'project_updated';
  end if;

  if normalized_priority not in ('baixa', 'normal', 'alta', 'urgente') then
    normalized_priority := 'normal';
  end if;

  insert into public.notification_preferences (
    user_id,
    notification_type,
    internal_enabled,
    email_enabled,
    push_enabled,
    muted
  )
  select
    profile_record.id,
    'project_updates',
    true,
    false,
    false,
    false
  from public.profiles profile_record
  where profile_record.id = p_recipient_id
    and profile_record.ativo is distinct from false
  on conflict (user_id, notification_type) do nothing;

  select
    coalesce(pref.internal_enabled, true),
    coalesce(pref.muted, false),
    pref.muted_until
  into
    preference_internal,
    preference_muted,
    preference_muted_until
  from public.notification_preferences pref
  where pref.user_id = p_recipient_id
    and pref.notification_type in ('project_updates', '*')
  order by case when pref.notification_type = 'project_updates' then 0 else 1 end
  limit 1;

  internal_visible :=
    coalesce(preference_internal, true)
    and not coalesce(preference_muted, false)
    and not (
      preference_muted_until is not null
      and preference_muted_until > now()
    );

  semantic_hash := encode(
    digest(
      concat_ws(
        '|',
        p_project_id::text,
        normalized_type,
        p_recipient_id::text,
        normalized_suffix,
        normalized_title,
        normalized_message
      ),
      'sha256'
    ),
    'hex'
  );

  source_value := format(
    'project:%s:%s:%s:%s:%s',
    p_project_id,
    normalized_type,
    p_recipient_id,
    semantic_bucket,
    left(semantic_hash, 20)
  );

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
    is_read,
    read_at,
    archived_at,
    created_at,
    updated_at,
    preference_key
  )
  select
    profile_record.id,
    normalized_type,
    normalized_title,
    normalized_message,
    'projetos',
    'project',
    p_project_id,
    source_value,
    'projetos',
    normalized_priority,
    coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'project_id', p_project_id,
        'semantic_bucket', semantic_bucket,
        'semantic_hash', left(semantic_hash, 20)
      ),
    true,
    true,
    not internal_visible,
    case when internal_visible then null else now() end,
    case when internal_visible then null else now() end,
    now(),
    now(),
    'project_updates'
  from public.profiles profile_record
  where profile_record.id = p_recipient_id
    and profile_record.ativo is distinct from false
  on conflict (recipient_id, source_key) do update
  set
    type = excluded.type,
    title = excluded.title,
    message = excluded.message,
    target_tab = excluded.target_tab,
    entity_type = excluded.entity_type,
    entity_id = excluded.entity_id,
    category = excluded.category,
    priority = excluded.priority,
    metadata = excluded.metadata,
    email_eligible = excluded.email_eligible,
    push_eligible = excluded.push_eligible,
    is_read = excluded.is_read,
    read_at = excluded.read_at,
    archived_at = excluded.archived_at,
    updated_at = now(),
    preference_key = excluded.preference_key;
end;
$$;

revoke all on function public.nexlab_project_notification_v2690(
  uuid, text, text, text, uuid, text, jsonb, text
)
from public, anon, authenticated;

comment on function public.nexlab_project_notification_v2690(
  uuid, text, text, text, uuid, text, jsonb, text
)
is 'Cria notificações de projetos respeitando canal interno e deduplicando eventos semanticamente iguais em janelas de cinco minutos.';

-- ---------------------------------------------------------------------------
-- Correções 18 e 19 — exclusão segura, anexos, Storage e notificações órfãs.
-- ---------------------------------------------------------------------------

create or replace function public.nexlab_is_project_delete_admin_v2690()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and p.ativo is distinct from false
        and lower(coalesce(p.role::text, '')) in ('admin', 'administrador')
    );
$$;

revoke all on function public.nexlab_is_project_delete_admin_v2690()
from public, anon;

grant execute on function public.nexlab_is_project_delete_admin_v2690()
to authenticated;

create or replace function public.nexlab_prepare_project_delete_v2690(
  p_project_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  project_record public.projects%rowtype;
  attachment_count integer := 0;
  storage_paths text[] := '{}'::text[];
begin
  if not public.nexlab_is_project_delete_admin_v2690() then
    raise exception 'Somente administradores podem excluir projetos permanentemente.'
      using errcode = '42501';
  end if;

  select pr.*
  into project_record
  from public.projects pr
  where pr.id = p_project_id;

  if project_record.id is null then
    raise exception 'Projeto não encontrado.'
      using errcode = 'P0002';
  end if;

  select
    count(*)::integer,
    coalesce(
      array_agg(distinct btrim(att.storage_path))
        filter (
          where nullif(btrim(coalesce(att.storage_path, '')), '') is not null
        ),
      '{}'::text[]
    )
  into attachment_count, storage_paths
  from public.attachments att
  where lower(btrim(att.modulo)) in ('projetos', 'projects', 'project')
    and att.record_id = p_project_id;

  return jsonb_build_object(
    'ok', true,
    'project_id', project_record.id,
    'project_name', project_record.nome,
    'attachment_count', attachment_count,
    'storage_paths', to_jsonb(storage_paths),
    'storage_bucket', 'anexos'
  );
end;
$$;

revoke all on function public.nexlab_prepare_project_delete_v2690(uuid)
from public, anon;

grant execute on function public.nexlab_prepare_project_delete_v2690(uuid)
to authenticated;

create or replace function public.nexlab_project_delete_guard_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if current_setting('nexlab.project_delete_authorized', true) is distinct from 'on' then
    raise exception 'Use a exclusão segura de projetos para remover anexos, notificações e arquivos associados.'
      using errcode = '42501';
  end if;

  if not public.nexlab_is_project_delete_admin_v2690() then
    raise exception 'Somente administradores podem excluir projetos permanentemente.'
      using errcode = '42501';
  end if;

  return old;
end;
$$;

revoke all on function public.nexlab_project_delete_guard_v2690()
from public, anon, authenticated;

drop trigger if exists nexlab_project_delete_guard_v2690
on public.projects;

create trigger nexlab_project_delete_guard_v2690
before delete on public.projects
for each row
execute function public.nexlab_project_delete_guard_v2690();

create or replace function public.nexlab_delete_project_v2690(
  p_project_id uuid,
  p_cleaned_storage_paths text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  project_record public.projects%rowtype;
  expected_paths text[] := '{}'::text[];
  cleaned_paths text[] := '{}'::text[];
  attachment_count integer := 0;
  deleted_attachments integer := 0;
  neutralized_notifications integer := 0;
  skipped_deliveries integer := 0;
  deleted_projects integer := 0;
begin
  if not public.nexlab_is_project_delete_admin_v2690() then
    raise exception 'Somente administradores podem excluir projetos permanentemente.'
      using errcode = '42501';
  end if;

  select pr.*
  into project_record
  from public.projects pr
  where pr.id = p_project_id
  for update;

  if project_record.id is null then
    raise exception 'Projeto não encontrado.'
      using errcode = 'P0002';
  end if;

  select
    count(*)::integer,
    coalesce(
      array_agg(distinct btrim(att.storage_path))
        filter (
          where nullif(btrim(coalesce(att.storage_path, '')), '') is not null
        ),
      '{}'::text[]
    )
  into attachment_count, expected_paths
  from public.attachments att
  where lower(btrim(att.modulo)) in ('projetos', 'projects', 'project')
    and att.record_id = p_project_id;

  select coalesce(
    array_agg(distinct btrim(path_value))
      filter (where nullif(btrim(coalesce(path_value, '')), '') is not null),
    '{}'::text[]
  )
  into cleaned_paths
  from unnest(coalesce(p_cleaned_storage_paths, '{}'::text[])) path_value;

  if exists (
    select 1
    from unnest(expected_paths) expected_path
    where not (expected_path = any(cleaned_paths))
  ) then
    raise exception 'Existem arquivos do projeto que ainda não foram removidos do Storage.'
      using errcode = '23514';
  end if;

  with target_notifications as (
    select n.id
    from public.notifications n
    where n.entity_type = 'project'
      and n.entity_id = p_project_id
  )
  update public.notification_deliveries delivery
  set
    status = 'skipped',
    claimed_at = null,
    next_attempt_at = now(),
    last_error = 'Projeto excluído antes da entrega externa.',
    updated_at = now()
  from target_notifications target
  where delivery.notification_id = target.id
    and delivery.status in ('pending', 'processing');

  get diagnostics skipped_deliveries = row_count;

  update public.notifications notification
  set
    target_tab = null,
    entity_type = 'deleted_project',
    entity_id = null,
    is_read = true,
    read_at = coalesce(notification.read_at, now()),
    archived_at = coalesce(notification.archived_at, now()),
    metadata = coalesce(notification.metadata, '{}'::jsonb)
      || jsonb_build_object(
        'deleted_project_id', p_project_id,
        'deleted_project_name', project_record.nome,
        'project_deleted_at', now()
      ),
    updated_at = now()
  where notification.entity_type = 'project'
    and notification.entity_id = p_project_id;

  get diagnostics neutralized_notifications = row_count;

  delete from public.attachments attachment
  where lower(btrim(attachment.modulo)) in ('projetos', 'projects', 'project')
    and attachment.record_id = p_project_id;

  get diagnostics deleted_attachments = row_count;

  perform set_config('nexlab.project_delete_authorized', 'on', true);

  delete from public.projects project_record_to_delete
  where project_record_to_delete.id = p_project_id;

  get diagnostics deleted_projects = row_count;

  perform set_config('nexlab.project_delete_authorized', 'off', true);

  if deleted_projects <> 1 then
    raise exception 'O projeto não pôde ser excluído.'
      using errcode = 'P0002';
  end if;

  begin
    perform public.record_security_audit(
      'project_deleted',
      null::text,
      jsonb_build_object(
        'entity_id', p_project_id,
        'entity_name', project_record.nome,
        'module', 'projetos',
        'attachments_deleted', deleted_attachments,
        'storage_paths_confirmed', cardinality(cleaned_paths),
        'notifications_neutralized', neutralized_notifications,
        'deliveries_skipped', skipped_deliveries
      )
    );
  exception
    when undefined_function then null;
    when others then null;
  end;

  return jsonb_build_object(
    'ok', true,
    'deleted', true,
    'project_id', p_project_id,
    'project_name', project_record.nome,
    'attachments_deleted', deleted_attachments,
    'expected_storage_paths', to_jsonb(expected_paths),
    'storage_paths_confirmed', cardinality(cleaned_paths),
    'notifications_neutralized', neutralized_notifications,
    'deliveries_skipped', skipped_deliveries
  );
end;
$$;

revoke all on function public.nexlab_delete_project_v2690(uuid, text[])
from public, anon;

grant execute on function public.nexlab_delete_project_v2690(uuid, text[])
to authenticated;

comment on function public.nexlab_prepare_project_delete_v2690(uuid)
is 'Retorna o plano de exclusão do projeto, incluindo caminhos que o frontend deve remover do bucket anexos.';

comment on function public.nexlab_delete_project_v2690(uuid, text[])
is 'Exclui um projeto somente após confirmação da limpeza do Storage, remove anexos e neutraliza notificações sem destino.';

-- Mantém compatibilidade com clientes antigos, mas encaminha Projetos para o
-- fluxo seguro. Projetos com arquivos no Storage exigirão o cliente atualizado.
create or replace function public.admin_delete_operational_record(
  p_entity_type text,
  p_entity_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  requester_role text;
  requester_active boolean;
  affected_rows integer := 0;
  project_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Autenticação obrigatória.'
      using errcode = '42501';
  end if;

  select role::text, ativo is distinct from false
  into requester_role, requester_active
  from public.profiles
  where id = auth.uid();

  if requester_role is null or not requester_active then
    raise exception 'Perfil não autorizado.'
      using errcode = '42501';
  end if;

  if lower(coalesce(requester_role, '')) not in ('admin', 'administrador') then
    raise exception 'Somente administradores podem excluir registros permanentemente.'
      using errcode = '42501';
  end if;

  case p_entity_type
    when 'event' then
      delete from public.events target where target.id = p_entity_id;
    when 'project' then
      project_result := public.nexlab_delete_project_v2690(
        p_entity_id,
        '{}'::text[]
      );
      return coalesce((project_result->>'deleted')::boolean, false);
    when 'team' then
      delete from public.teams target where target.id = p_entity_id;
    when 'meeting' then
      delete from public.meetings target where target.id = p_entity_id;
    when 'reservation' then
      delete from public.reservations target where target.id = p_entity_id;
    when 'marketing' then
      delete from public.marketing target where target.id = p_entity_id;
    when 'asset' then
      delete from public.assets target where target.id = p_entity_id;
    when 'board_post' then
      delete from public.board_posts target where target.id = p_entity_id;
    else
      raise exception 'Tipo de registro inválido para exclusão.'
        using errcode = '22023';
  end case;

  get diagnostics affected_rows = row_count;
  return affected_rows > 0;
end;
$$;

revoke all on function public.admin_delete_operational_record(text, uuid)
from public, anon;

grant execute on function public.admin_delete_operational_record(text, uuid)
to authenticated;

commit;
