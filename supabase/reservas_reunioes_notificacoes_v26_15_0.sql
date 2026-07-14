-- NEXLAB v26.15.0 — Notificações transacionais de participantes
create or replace function public.nexlab_booking_participant_notify_v26150()
returns trigger
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare record_title text; owner_id uuid; entity_kind text; notification_type text;
begin
 if tg_table_name='reservation_participants' then
  select coalesce(titulo,'Reserva de sala'),usuario_id into record_title,owner_id from public.reservations where id=new.reservation_id;
  if new.user_id is not distinct from owner_id then return new; end if;
  entity_kind:='reservation'; notification_type:='reservation_created';
  perform public.nexlab_notify_selected_participant(new.user_id::text,notification_type,'Você foi incluído em uma reserva',format('Reserva: %s',record_title),entity_kind,new.reservation_id::text,format('reservation-participant:%s:%s',new.reservation_id,new.user_id));
 else
  select coalesce(titulo,'Reunião'),autor_id into record_title,owner_id from public.meetings where id=new.meeting_id;
  if new.user_id is not distinct from owner_id then return new; end if;
  entity_kind:='meeting'; notification_type:='system';
  perform public.nexlab_notify_selected_participant(new.user_id::text,notification_type,'Você foi incluído em uma reunião',format('Reunião: %s',record_title),entity_kind,new.meeting_id::text,format('meeting-participant:%s:%s',new.meeting_id,new.user_id));
 end if;
 return new;
end;
$$;
revoke all on function public.nexlab_booking_participant_notify_v26150() from public,anon,authenticated;
drop trigger if exists reservation_participants_notify_v26150 on public.reservation_participants;
create trigger reservation_participants_notify_v26150 after insert on public.reservation_participants for each row execute function public.nexlab_booking_participant_notify_v26150();
drop trigger if exists meeting_participants_notify_v26150 on public.meeting_participants;
create trigger meeting_participants_notify_v26150 after insert on public.meeting_participants for each row execute function public.nexlab_booking_participant_notify_v26150();
