-- NEXLAB v26.18.0 — R37
-- Etapa 3: correções 1 a 4 de Notificações
-- Já aplicado no projeto Supabase Nexlab. Arquivo consolidado para backup.

create or replace function public.nexlab_notification_preference_key_v26180(
  p_type text,
  p_preference_key text default null
)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when nullif(lower(btrim(coalesce(p_preference_key,''))), '') is not null
      then lower(btrim(p_preference_key))
    when lower(coalesce(p_type,'')) like 'project_%' then 'project_updates'
    when lower(coalesce(p_type,'')) in ('meeting_invited','meeting_updated','meeting_cancelled') then 'meetings'
    when lower(coalesce(p_type,''))='meeting_reminder' then 'meeting_reminder'
    else lower(coalesce(nullif(btrim(p_type),''),'system'))
  end
$$;

create or replace function public.nexlab_notification_policy_v26180(
  p_recipient_id uuid,
  p_type text,
  p_preference_key text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_key text := public.nexlab_notification_preference_key_v26180(p_type,p_preference_key);
  v_internal boolean := true;
  v_push boolean := false;
  v_muted boolean := false;
  v_muted_until timestamptz;
  v_match text := 'default';
begin
  select coalesce(pref.internal_enabled,true),coalesce(pref.push_enabled,false),
         coalesce(pref.muted,false),pref.muted_until,pref.notification_type
  into v_internal,v_push,v_muted,v_muted_until,v_match
  from public.notification_preferences pref
  where pref.user_id=p_recipient_id and pref.notification_type in (v_key,'*')
  order by case when pref.notification_type=v_key then 0 else 1 end
  limit 1;

  v_muted := coalesce(v_muted,false)
    or (v_muted_until is not null and v_muted_until > now());

  return jsonb_build_object(
    'preference_key',v_key,'matched_preference',coalesce(v_match,'default'),
    'internal_enabled',coalesce(v_internal,true),'push_enabled',coalesce(v_push,false),
    'external_muted',v_muted,'muted_until',v_muted_until
  );
end;
$$;

revoke execute on function public.nexlab_notification_policy_v26180(uuid,text,text)
from public,anon,authenticated;
grant execute on function public.nexlab_notification_policy_v26180(uuid,text,text) to service_role;

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type in (
  'profile_request','profile_updated',
  'reservation_created','reservation_decided','reservation_reminder',
  'meeting_invited','meeting_updated','meeting_cancelled','meeting_reminder',
  'feedback_created','feedback_updated','feedback_assigned','system',
  'project_assigned','project_updated','project_status_changed','project_deadline_changed',
  'project_team_changed','project_task_changed','project_link_changed'
));

insert into public.notification_preferences(
  user_id,notification_type,internal_enabled,email_enabled,push_enabled,muted
)
select profile.id,'meetings',true,false,false,false
from public.profiles profile
where profile.ativo is distinct from false
on conflict (user_id,notification_type) do nothing;

create or replace function public.nexlab_normalize_notification()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_type text;
  v_metadata_entity_type text;
  v_metadata_entity_id text;
  v_policy jsonb;
  v_internal_enabled boolean;
  v_push_enabled boolean;
  v_external_muted boolean;
  v_content_refreshed boolean := false;
begin
  new.metadata := coalesce(new.metadata,'{}'::jsonb);

  if coalesce(new.metadata->>'reminder','false')='true' then
    v_metadata_entity_type := lower(coalesce(nullif(btrim(new.entity_type),''),new.metadata->>'entity_type',''));
    v_metadata_entity_id := coalesce(new.entity_id::text,new.metadata->>'entity_id');
    if v_metadata_entity_type in ('reservation','meeting') then
      new.entity_type := v_metadata_entity_type;
      if new.entity_id is null and nullif(btrim(coalesce(v_metadata_entity_id,'')),'') is not null then
        begin new.entity_id := v_metadata_entity_id::uuid;
        exception when invalid_text_representation then new.entity_id := null;
        end;
      end if;
      if v_metadata_entity_type='meeting' then
        new.type := 'meeting_reminder'; new.preference_key := 'meeting_reminder'; new.category := 'reunioes';
      else
        new.type := 'reservation_reminder'; new.preference_key := 'reservation_reminder'; new.category := 'reservas';
      end if;
      new.target_tab := 'reserva';
    end if;
  end if;

  v_type := lower(coalesce(new.type::text,'system'));
  if new.category is null or btrim(new.category)='' or new.category='sistema' then
    new.category := case
      when v_type like 'reservation%' then 'reservas'
      when v_type like 'profile%' then 'usuarios'
      when v_type like 'feedback%' then 'feedback'
      when v_type like 'meeting%' then 'reunioes'
      when v_type like 'project%' then 'projetos'
      when v_type like 'event%' then 'eventos'
      else 'sistema' end;
  end if;

  if new.priority is null or btrim(new.priority)='' then new.priority := 'normal'; end if;
  if v_type in ('reservation_decided','profile_request','meeting_cancelled') and new.priority='normal'
    then new.priority := 'alta'; end if;

  new.preference_key := public.nexlab_notification_preference_key_v26180(v_type,new.preference_key);
  v_policy := public.nexlab_notification_policy_v26180(new.recipient_id,v_type,new.preference_key);
  v_internal_enabled := coalesce((v_policy->>'internal_enabled')::boolean,true);
  v_push_enabled := coalesce((v_policy->>'push_enabled')::boolean,false);
  v_external_muted := coalesce((v_policy->>'external_muted')::boolean,false);

  new.email_eligible := false;
  new.push_eligible := coalesce(new.push_eligible,true) and v_push_enabled and not v_external_muted;

  if tg_op='UPDATE' then
    v_content_refreshed := new.type is distinct from old.type
      or new.title is distinct from old.title or new.message is distinct from old.message
      or new.target_tab is distinct from old.target_tab or new.entity_type is distinct from old.entity_type
      or new.entity_id is distinct from old.entity_id or new.preference_key is distinct from old.preference_key
      or new.metadata is distinct from old.metadata;
  end if;

  if v_internal_enabled then
    if tg_op='INSERT' or v_content_refreshed then
      new.is_read := false; new.read_at := null; new.archived_at := null;
    end if;
  else
    new.is_read := true; new.read_at := coalesce(new.read_at,now()); new.archived_at := coalesce(new.archived_at,now());
  end if;

  new.metadata := new.metadata || jsonb_build_object(
    'notification_policy',jsonb_build_object(
      'preference_key',new.preference_key,'internal_enabled',v_internal_enabled,
      'push_enabled',v_push_enabled,'external_muted',v_external_muted,'evaluated_at',now()
    )
  );
  return new;
end;
$$;

drop trigger if exists notifications_normalize_before_write on public.notifications;
create trigger notifications_normalize_before_write
before insert or update of recipient_id,type,title,message,target_tab,entity_type,entity_id,
  preference_key,category,priority,metadata,email_eligible,push_eligible,is_read,read_at,archived_at
on public.notifications for each row execute function public.nexlab_normalize_notification();

create or replace function public.nexlab_ensure_notification_preferences()
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  standard_type text;
  standard_types text[] := array[
    '*','profile_request','profile_updated','reservation_created','reservation_decided',
    'reservation_reminder','meetings','meeting_reminder','feedback_created','feedback_updated',
    'feedback_assigned','project_updates','system'
  ];
begin
  if auth.uid() is null then raise exception 'Usuário não autenticado.' using errcode='42501'; end if;
  foreach standard_type in array standard_types loop
    insert into public.notification_preferences(user_id,notification_type,internal_enabled,email_enabled,push_enabled,muted)
    select profile.id,standard_type,true,false,false,false from public.profiles profile where profile.id=auth.uid()
    on conflict (user_id,notification_type) do nothing;
  end loop;
  return jsonb_build_object('ok',true,'types',standard_types);
end;
$$;

create or replace function public.nexlab_ensure_notification_user_settings()
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Usuário não autenticado.' using errcode='42501'; end if;
  insert into public.notification_user_settings(user_id)
  select profile.id from public.profiles profile where profile.id=auth.uid()
  on conflict (user_id) do nothing;
  insert into public.notification_preferences(user_id,notification_type,internal_enabled,email_enabled,push_enabled,muted)
  select profile.id,item.preference_key,true,false,false,false
  from public.profiles profile
  cross join (values ('reservation_reminder'),('meetings'),('meeting_reminder'),('project_updates')) item(preference_key)
  where profile.id=auth.uid()
  on conflict (user_id,notification_type) do nothing;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.nexlab_booking_participant_notify_v26150()
returns trigger language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare record_title text; owner_id uuid; entity_kind text; notification_type text;
begin
  if tg_table_name='reservation_participants' then
    select coalesce(titulo,'Reserva de sala'),usuario_id into record_title,owner_id
    from public.reservations where id=new.reservation_id;
    if new.user_id is not distinct from owner_id then return new; end if;
    entity_kind:='reservation'; notification_type:='reservation_created';
    perform public.nexlab_notify_selected_participant(new.user_id::text,notification_type,
      'Você foi incluído em uma reserva',format('Reserva: %s',record_title),entity_kind,
      new.reservation_id::text,format('reservation-participant:%s:%s',new.reservation_id,new.user_id));
  else
    select coalesce(titulo,'Reunião'),autor_id into record_title,owner_id
    from public.meetings where id=new.meeting_id;
    if new.user_id is not distinct from owner_id then return new; end if;
    entity_kind:='meeting'; notification_type:='meeting_invited';
    perform public.nexlab_notify_selected_participant(new.user_id::text,notification_type,
      'Você foi incluído em uma reunião',format('Reunião: %s',record_title),entity_kind,
      new.meeting_id::text,format('meeting-participant:%s:%s',new.meeting_id,new.user_id));
  end if;
  return new;
end;
$$;

create or replace function public.nexlab_meeting_change_notify_v26180()
returns trigger language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare participant record; notification_type text; notification_title text; notification_message text; source_prefix text;
begin
  if not (new.titulo is distinct from old.titulo or new.descricao is distinct from old.descricao
    or new.data is distinct from old.data or new.hora is distinct from old.hora
    or new.hora_fim is distinct from old.hora_fim or new.local is distinct from old.local
    or new.link is distinct from old.link or new.formato is distinct from old.formato
    or new.pauta is distinct from old.pauta or new.status is distinct from old.status
    or new.cancellation_reason is distinct from old.cancellation_reason) then return new; end if;

  if lower(coalesce(new.status,''))='cancelada' and lower(coalesce(old.status,'')) is distinct from 'cancelada' then
    notification_type:='meeting_cancelled'; notification_title:='Reunião cancelada';
    notification_message:=format('A reunião "%s" foi cancelada.%s',coalesce(nullif(btrim(new.titulo),''),'Reunião'),
      case when nullif(btrim(coalesce(new.cancellation_reason,'')),'') is not null then ' Motivo: '||btrim(new.cancellation_reason) else '' end);
  else
    notification_type:='meeting_updated'; notification_title:='Reunião atualizada';
    notification_message:=format('A reunião "%s" foi atualizada para %s às %s.',
      coalesce(nullif(btrim(new.titulo),''),'Reunião'),to_char(new.data,'DD/MM/YYYY'),
      coalesce(to_char(new.hora,'HH24:MI'),'horário não informado'));
  end if;

  source_prefix:=format('meeting-change:%s:%s:%s',new.id,notification_type,txid_current());
  for participant in
    select distinct mp.user_id from public.meeting_participants mp
    where mp.meeting_id=new.id and mp.user_id is distinct from auth.uid()
  loop
    perform public.nexlab_notify_selected_participant(participant.user_id::text,notification_type,
      notification_title,notification_message,'meeting',new.id::text,
      source_prefix||':'||participant.user_id::text);
  end loop;
  return new;
end;
$$;

revoke execute on function public.nexlab_meeting_change_notify_v26180() from public,anon,authenticated;
grant execute on function public.nexlab_meeting_change_notify_v26180() to service_role;

drop trigger if exists meetings_notify_changes_v26180 on public.meetings;
create trigger meetings_notify_changes_v26180
after update of titulo,descricao,data,hora,hora_fim,local,link,formato,pauta,status,cancellation_reason
on public.meetings for each row execute function public.nexlab_meeting_change_notify_v26180();

update public.notifications
set type='meeting_invited',preference_key='meetings',category='reunioes',target_tab='reserva',updated_at=now()
where type='system' and entity_type='meeting' and source_key like 'meeting-participant:%';

update public.notifications
set type='meeting_reminder',preference_key='meeting_reminder',category='reunioes',target_tab='reserva',updated_at=now()
where coalesce(metadata->>'reminder','false')='true'
  and coalesce(entity_type,metadata->>'entity_type')='meeting';

update public.notifications set metadata=metadata,updated_at=now()
where coalesce(metadata->>'reminder','false')='true';
