-- NEXLAB v26.19.0 — Etapa 3, correções 5 a 8
-- Navegação exata, destinatários de reuniões, Central paginada e resumo Realtime.
-- Migrações já aplicadas no projeto Nexlab. Arquivo consolidado para backup.

create or replace function public.nexlab_normalize_notification_target_v26190()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  candidate_id text;
  normalized_type text := lower(coalesce(new.type::text,'system'));
begin
  new.metadata := coalesce(new.metadata,'{}'::jsonb);

  if new.entity_type is null or btrim(new.entity_type)='' then
    new.entity_type := case
      when normalized_type like 'meeting_%' then 'meeting'
      when normalized_type like 'reservation_%' then 'reservation'
      when normalized_type like 'project_%' then 'project'
      when normalized_type like 'feedback_%' then 'feedback'
      when normalized_type like 'profile_%' then 'profile'
      when new.target_tab='equipes' then 'team'
      when new.target_tab='eventos' then 'event'
      else null
    end;
  end if;

  if new.entity_id is null then
    candidate_id := coalesce(
      nullif(new.metadata->>'entity_id',''),
      nullif(new.metadata->>'record_id',''),
      nullif(new.metadata->>'user_id',''),
      nullif(new.metadata->>'target_user_id',''),
      nullif(new.metadata->>'profile_id',''),
      nullif(new.metadata->>'project_id',''),
      nullif(new.metadata->>'team_id',''),
      nullif(new.metadata->>'meeting_id',''),
      nullif(new.metadata->>'reservation_id',''),
      nullif(new.metadata->>'feedback_id',''),
      nullif(new.metadata->>'event_id','')
    );

    if candidate_id is null
       and new.entity_type='profile'
       and new.target_tab='perfil'
    then
      candidate_id := new.recipient_id::text;
    end if;

    if candidate_id is not null then
      begin
        new.entity_id := candidate_id::uuid;
      exception when invalid_text_representation then
        new.entity_id := null;
      end;
    end if;
  end if;

  if new.entity_type in ('reservation','meeting') then
    new.target_tab := 'reserva';
  elsif new.entity_type='project' and new.target_tab is null then
    new.target_tab := 'projetos';
  elsif new.entity_type='team' and new.target_tab is null then
    new.target_tab := 'equipes';
  elsif new.entity_type='event' and new.target_tab is null then
    new.target_tab := 'eventos';
  elsif new.entity_type='feedback' and new.target_tab is null then
    new.target_tab := 'feedback';
  elsif new.entity_type='profile' and new.target_tab is null then
    new.target_tab := 'perfil';
  end if;

  return new;
end;
$$;

revoke execute on function public.nexlab_normalize_notification_target_v26190()
from public,anon,authenticated;
grant execute on function public.nexlab_normalize_notification_target_v26190()
to service_role;

drop trigger if exists notifications_exact_target_v26190 on public.notifications;
create trigger notifications_exact_target_v26190
before insert or update of recipient_id,type,target_tab,entity_type,entity_id,metadata
on public.notifications
for each row execute function public.nexlab_normalize_notification_target_v26190();

create or replace function public.nexlab_resolve_notification_target_v26190(
  p_notification_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  notification_row public.notifications%rowtype;
  target_exists boolean := true;
  target_tab text;
  target_kind text;
  target_label text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.' using errcode='42501';
  end if;

  select * into notification_row
  from public.notifications
  where id=p_notification_id
    and recipient_id=auth.uid();

  if not found then
    raise exception 'Notificação não encontrada.' using errcode='P0002';
  end if;

  target_tab := coalesce(notification_row.target_tab,'notificacoes');
  target_kind := lower(coalesce(notification_row.entity_type,''));

  if notification_row.entity_id is not null then
    target_exists := case target_kind
      when 'reservation' then exists(select 1 from public.reservations item where item.id=notification_row.entity_id)
      when 'meeting' then exists(select 1 from public.meetings item where item.id=notification_row.entity_id)
      when 'project' then exists(select 1 from public.projects item where item.id=notification_row.entity_id)
      when 'team' then exists(select 1 from public.teams item where item.id=notification_row.entity_id)
      when 'event' then exists(select 1 from public.events item where item.id=notification_row.entity_id)
      when 'feedback' then exists(select 1 from public.feedback item where item.id=notification_row.entity_id)
      when 'profile' then exists(select 1 from public.profiles item where item.id=notification_row.entity_id)
      else true
    end;
  end if;

  target_label := case target_kind
    when 'reservation' then 'Reserva'
    when 'meeting' then 'Reunião'
    when 'project' then 'Projeto'
    when 'team' then 'Equipe'
    when 'event' then 'Evento'
    when 'feedback' then 'Feedback'
    when 'profile' then 'Perfil'
    else 'Registro'
  end;

  return jsonb_build_object(
    'ok',true,
    'notification_id',notification_row.id,
    'tab_id',target_tab,
    'entity_type',nullif(target_kind,''),
    'entity_id',notification_row.entity_id,
    'record_exists',target_exists,
    'group_label',target_label,
    'title',notification_row.title,
    'booking_kind',case
      when target_kind='meeting' then 'meeting'
      when target_kind='reservation' then 'reservation'
      else null
    end
  );
end;
$$;

revoke execute on function public.nexlab_resolve_notification_target_v26190(uuid)
from public,anon;
grant execute on function public.nexlab_resolve_notification_target_v26190(uuid)
to authenticated;

create or replace function public.nexlab_meeting_recipients_v26190(
  p_meeting_id uuid
)
returns table(user_id uuid)
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  with meeting_record as (
    select * from public.meetings where id=p_meeting_id
  ),
  candidates as (
    select participant.user_id
    from public.meeting_participants participant
    where participant.meeting_id=p_meeting_id

    union

    select profile.id
    from meeting_record meeting
    join public.profiles profile
      on profile.id=any(coalesce(meeting.alvo_users,'{}'::uuid[]))

    union

    select profile.id
    from meeting_record meeting
    join public.profiles profile
      on exists(
        select 1
        from unnest(coalesce(meeting.alvo_roles,'{}'::text[])) selected_role
        where lower(btrim(selected_role))=lower(profile.role::text)
      )

    union

    select member.user_id
    from meeting_record meeting
    join public.team_members member on member.team_id=meeting.team_id

    union

    select profile.id
    from meeting_record meeting
    join public.profiles profile on meeting.para_todos
  )
  select distinct candidate.user_id
  from candidates candidate
  join public.profiles profile on profile.id=candidate.user_id
  cross join meeting_record meeting
  where profile.ativo is distinct from false
    and coalesce(profile.cadastro_completo,true)
    and candidate.user_id is distinct from meeting.autor_id
$$;

revoke execute on function public.nexlab_meeting_recipients_v26190(uuid)
from public,anon,authenticated;
grant execute on function public.nexlab_meeting_recipients_v26190(uuid)
to service_role;

create or replace function public.nexlab_booking_participant_notify_v26150()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  record_title text;
  owner_id uuid;
  entity_kind text;
  notification_type text;
  source_value text;
begin
  if tg_table_name='reservation_participants' then
    select coalesce(titulo,'Reserva de sala'),usuario_id
    into record_title,owner_id
    from public.reservations where id=new.reservation_id;

    if new.user_id is not distinct from owner_id then return new; end if;
    entity_kind := 'reservation';
    notification_type := 'reservation_created';
    source_value := format('reservation-participant:%s:%s',new.reservation_id,new.user_id);

    perform public.nexlab_notify_selected_participant(
      new.user_id::text,notification_type,
      'Você foi incluído em uma reserva',format('Reserva: %s',record_title),
      entity_kind,new.reservation_id::text,source_value
    );
  else
    select coalesce(titulo,'Reunião'),autor_id
    into record_title,owner_id
    from public.meetings where id=new.meeting_id;

    if new.user_id is not distinct from owner_id then return new; end if;
    entity_kind := 'meeting';
    notification_type := 'meeting_invited';
    source_value := format('meeting-invited:%s:%s',new.meeting_id,new.user_id);

    perform public.nexlab_notify_selected_participant(
      new.user_id::text,notification_type,
      'Você foi incluído em uma reunião',format('Reunião: %s',record_title),
      entity_kind,new.meeting_id::text,source_value
    );
  end if;

  return new;
end;
$$;

create or replace function public.nexlab_meeting_audience_notify_v26190()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  recipient record;
  source_prefix text;
  notification_title text;
  notification_message text;
begin
  if tg_op='UPDATE' and not (
    new.para_todos is distinct from old.para_todos
    or new.alvo_roles is distinct from old.alvo_roles
    or new.alvo_users is distinct from old.alvo_users
    or new.team_id is distinct from old.team_id
  ) then
    return new;
  end if;

  if tg_op='INSERT' then
    source_prefix := format('meeting-invited:%s',new.id);
    notification_title := 'Você foi incluído em uma reunião';
    notification_message := format('Reunião: %s',coalesce(nullif(btrim(new.titulo),''),'Reunião'));
  else
    source_prefix := format('meeting-updated:%s:%s',new.id,txid_current());
    notification_title := 'Público da reunião atualizado';
    notification_message := format(
      'Os participantes da reunião "%s" foram atualizados.',
      coalesce(nullif(btrim(new.titulo),''),'Reunião')
    );
  end if;

  for recipient in
    select resolved.user_id
    from public.nexlab_meeting_recipients_v26190(new.id) resolved
  loop
    perform public.nexlab_notify_selected_participant(
      recipient.user_id::text,
      case when tg_op='INSERT' then 'meeting_invited' else 'meeting_updated' end,
      notification_title,
      notification_message,
      'meeting',
      new.id::text,
      source_prefix||':'||recipient.user_id::text
    );
  end loop;

  return new;
end;
$$;

revoke execute on function public.nexlab_meeting_audience_notify_v26190()
from public,anon,authenticated;
grant execute on function public.nexlab_meeting_audience_notify_v26190()
to service_role;

drop trigger if exists meetings_notify_audience_v26190 on public.meetings;
create trigger meetings_notify_audience_v26190
after insert or update of para_todos,alvo_roles,alvo_users,team_id
on public.meetings
for each row execute function public.nexlab_meeting_audience_notify_v26190();

create or replace function public.nexlab_meeting_change_notify_v26180()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  recipient record;
  notification_type text;
  notification_title text;
  notification_message text;
  source_prefix text;
begin
  if not (
    new.titulo is distinct from old.titulo
    or new.descricao is distinct from old.descricao
    or new.data is distinct from old.data
    or new.hora is distinct from old.hora
    or new.hora_fim is distinct from old.hora_fim
    or new.local is distinct from old.local
    or new.link is distinct from old.link
    or new.formato is distinct from old.formato
    or new.pauta is distinct from old.pauta
    or new.status is distinct from old.status
    or new.cancellation_reason is distinct from old.cancellation_reason
  ) then
    return new;
  end if;

  if lower(coalesce(new.status,''))='cancelada'
     and lower(coalesce(old.status,'')) is distinct from 'cancelada'
  then
    notification_type := 'meeting_cancelled';
    notification_title := 'Reunião cancelada';
    notification_message := format(
      'A reunião "%s" foi cancelada.%s',
      coalesce(nullif(btrim(new.titulo),''),'Reunião'),
      case
        when nullif(btrim(coalesce(new.cancellation_reason,'')),'') is not null
          then ' Motivo: '||btrim(new.cancellation_reason)
        else ''
      end
    );
    source_prefix := format('meeting-cancelled:%s:%s',new.id,txid_current());
  else
    notification_type := 'meeting_updated';
    notification_title := 'Reunião atualizada';
    notification_message := format(
      'A reunião "%s" foi atualizada para %s às %s.',
      coalesce(nullif(btrim(new.titulo),''),'Reunião'),
      to_char(new.data,'DD/MM/YYYY'),
      coalesce(to_char(new.hora,'HH24:MI'),'horário não informado')
    );
    source_prefix := format('meeting-updated:%s:%s',new.id,txid_current());
  end if;

  for recipient in
    select resolved.user_id
    from public.nexlab_meeting_recipients_v26190(new.id) resolved
  loop
    perform public.nexlab_notify_selected_participant(
      recipient.user_id::text,
      notification_type,
      notification_title,
      notification_message,
      'meeting',
      new.id::text,
      source_prefix||':'||recipient.user_id::text
    );
  end loop;

  return new;
end;
$$;

create extension if not exists pg_trgm with schema extensions;

create index if not exists notifications_title_trgm_v26190
  on public.notifications using gin (lower(title) extensions.gin_trgm_ops);
create index if not exists notifications_message_trgm_v26190
  on public.notifications using gin (lower(message) extensions.gin_trgm_ops);
create index if not exists notifications_recipient_preference_state_v26190
  on public.notifications(recipient_id,preference_key,archived_at,is_read,created_at desc);

create or replace function public.nexlab_list_notifications_v26190(
  p_status text default 'inbox',
  p_type text default null,
  p_search text default null,
  p_page integer default 0,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  normalized_status text := lower(btrim(coalesce(p_status,'inbox')));
  normalized_type text := nullif(lower(btrim(coalesce(p_type,''))),'');
  normalized_search text := nullif(lower(btrim(coalesce(p_search,''))),'');
  page_number integer := greatest(0,coalesce(p_page,0));
  page_size integer := greatest(5,least(coalesce(p_page_size,20),100));
  result jsonb;
begin
  if user_id is null then
    raise exception 'Usuário não autenticado.' using errcode='42501';
  end if;
  if normalized_status not in ('all','inbox','unread','archived') then normalized_status := 'inbox'; end if;

  with filtered as (
    select notification.*
    from public.notifications notification
    where notification.recipient_id=user_id
      and (
        normalized_status='all'
        or (normalized_status='inbox' and notification.archived_at is null)
        or (normalized_status='unread' and notification.archived_at is null and not notification.is_read)
        or (normalized_status='archived' and notification.archived_at is not null)
      )
      and (
        normalized_type is null
        or (normalized_type in ('reservation_reminder','meeting_reminder','meetings','project_updates') and notification.preference_key=normalized_type)
        or (normalized_type not in ('reservation_reminder','meeting_reminder','meetings','project_updates') and notification.type=normalized_type)
      )
      and (
        normalized_search is null
        or lower(notification.title) like '%'||normalized_search||'%'
        or lower(notification.message) like '%'||normalized_search||'%'
        or lower(coalesce(notification.category,'')) like '%'||normalized_search||'%'
      )
  ),
  page_rows as (
    select filtered.* from filtered
    order by filtered.created_at desc,filtered.id desc
    offset page_number*page_size limit page_size
  ),
  page_json as (
    select coalesce(jsonb_agg(to_jsonb(page_rows) order by page_rows.created_at desc,page_rows.id desc),'[]'::jsonb) rows
    from page_rows
  ),
  delivery_json as (
    select coalesce(jsonb_object_agg(page_rows.id::text,coalesce(deliveries.items,'[]'::jsonb)),'{}'::jsonb) delivery_map
    from page_rows
    left join lateral (
      select jsonb_agg(jsonb_build_object(
        'id',delivery.id,'notification_id',delivery.notification_id,'channel',delivery.channel,
        'status',delivery.status,'attempts',delivery.attempts,'next_attempt_at',delivery.next_attempt_at,
        'last_error',delivery.last_error,'sent_at',delivery.sent_at,
        'last_provider_status',delivery.last_provider_status,
        'last_attempt_outcome',delivery.last_attempt_outcome,'created_at',delivery.created_at
      ) order by delivery.created_at desc) items
      from public.notification_deliveries delivery
      where delivery.notification_id=page_rows.id and delivery.channel='push'
    ) deliveries on true
  ),
  filtered_count as (select count(*)::integer total from filtered),
  totals as (
    select
      count(*) filter(where notification.archived_at is null)::integer inbox_total,
      count(*) filter(where notification.archived_at is null and not notification.is_read)::integer unread_total,
      count(*) filter(where notification.archived_at is not null)::integer archived_total,
      count(*)::integer all_total
    from public.notifications notification where notification.recipient_id=user_id
  )
  select jsonb_build_object(
    'rows',page_json.rows,'total',filtered_count.total,'delivery_map',delivery_json.delivery_map,
    'counts',jsonb_build_object('inbox',totals.inbox_total,'unread',totals.unread_total,'archived',totals.archived_total,'all',totals.all_total),
    'page',page_number,'page_size',page_size,
    'page_count',case when filtered_count.total=0 then 1 else ceil(filtered_count.total::numeric/page_size::numeric)::integer end
  ) into result
  from page_json,delivery_json,filtered_count,totals;
  return result;
end;
$$;

revoke execute on function public.nexlab_list_notifications_v26190(text,text,text,integer,integer)
from public,anon;
grant execute on function public.nexlab_list_notifications_v26190(text,text,text,integer,integer)
to authenticated;

create or replace function public.nexlab_notification_summary_v26190(
  p_limit integer default 40
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  user_id uuid := auth.uid();
  row_limit integer := greatest(5,least(coalesce(p_limit,40),100));
  result jsonb;
begin
  if user_id is null then
    raise exception 'Usuário não autenticado.' using errcode='42501';
  end if;

  with recent_items as (
    select notification.*
    from public.notifications notification
    where notification.recipient_id=user_id and notification.archived_at is null
    order by notification.created_at desc,notification.id desc
    limit row_limit
  ),
  totals as (
    select
      count(*) filter(where notification.archived_at is null)::integer inbox_total,
      count(*) filter(where notification.archived_at is null and not notification.is_read)::integer unread_total,
      count(*) filter(where notification.archived_at is not null)::integer archived_total
    from public.notifications notification
    where notification.recipient_id=user_id
  )
  select jsonb_build_object(
    'items',coalesce((select jsonb_agg(to_jsonb(recent_items) order by recent_items.created_at desc,recent_items.id desc) from recent_items),'[]'::jsonb),
    'inbox_total',totals.inbox_total,
    'unread_total',totals.unread_total,
    'archived_total',totals.archived_total,
    'limit',row_limit,
    'checked_at',now()
  ) into result from totals;
  return result;
end;
$$;

revoke execute on function public.nexlab_notification_summary_v26190(integer)
from public,anon;
grant execute on function public.nexlab_notification_summary_v26190(integer)
to authenticated;

update public.notifications
set metadata=metadata,
    updated_at=now();
