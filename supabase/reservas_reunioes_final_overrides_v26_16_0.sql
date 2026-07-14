-- NEXLAB v26.16.0 — Ajustes finais para evitar duplicidade de histórico
create or replace function public.nexlab_cancel_reservation_v26160(p_reservation_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare uid uuid:=auth.uid(); row_data public.reservations%rowtype; saved public.reservations%rowtype; reason_text text:=nullif(btrim(coalesce(p_reason,'')),''); booking_uuid uuid;
begin
 if uid is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') then raise exception 'Você não possui acesso a Reservas e Reuniões.' using errcode='42501'; end if;
 select * into row_data from public.reservations where id=p_reservation_id for update;
 if not found then raise exception 'Reserva não encontrada.' using errcode='P0002'; end if;
 if not public.nexlab_is_gestor() and row_data.usuario_id is distinct from uid then raise exception 'Você não pode cancelar esta reserva.' using errcode='42501'; end if;
 if row_data.status in('cancelada','recusada') or row_data.archived_at is not null then raise exception 'A reserva já está encerrada.' using errcode='22023'; end if;
 if public.nexlab_is_gestor() and row_data.usuario_id is distinct from uid and (reason_text is null or char_length(reason_text)<5) then raise exception 'Informe o motivo do cancelamento com pelo menos 5 caracteres.' using errcode='22023'; end if;
 if reason_text is not null and char_length(reason_text)>500 then raise exception 'O motivo deve possuir no máximo 500 caracteres.' using errcode='22023'; end if;
 perform set_config('nexlab.booking_cancel_reason',coalesce(reason_text,''),true);
 perform set_config('nexlab.booking_action_reason',coalesce(reason_text,'Reserva cancelada'),true);
 update public.reservations set status='cancelada',cancelled_by=uid,cancelled_at=now(),cancellation_reason=reason_text where id=p_reservation_id returning * into saved;
 select id into booking_uuid from public.bookings where source_table='reservations' and legacy_id=p_reservation_id;
 return jsonb_build_object('ok',true,'reservation',to_jsonb(saved),'booking_id',booking_uuid);
end;$$;

create or replace function public.nexlab_cancel_meeting_v26160(p_meeting_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare uid uuid:=auth.uid(); row_data public.meetings%rowtype; saved public.meetings%rowtype; reason_text text:=nullif(btrim(coalesce(p_reason,'')),''); booking_uuid uuid;
begin
 if uid is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') or not public.nexlab_is_gestor() then raise exception 'Somente Administradores e Coordenadores podem cancelar reuniões.' using errcode='42501'; end if;
 select * into row_data from public.meetings where id=p_meeting_id for update;
 if not found then raise exception 'Reunião não encontrada.' using errcode='P0002'; end if;
 if row_data.status='cancelada' or row_data.archived_at is not null then raise exception 'A reunião já está encerrada.' using errcode='22023'; end if;
 if reason_text is null or char_length(reason_text)<5 then raise exception 'Informe o motivo do cancelamento com pelo menos 5 caracteres.' using errcode='22023'; end if;
 if char_length(reason_text)>500 then raise exception 'O motivo deve possuir no máximo 500 caracteres.' using errcode='22023'; end if;
 perform set_config('nexlab.booking_cancel_reason',reason_text,true);
 perform set_config('nexlab.booking_action_reason',reason_text,true);
 update public.meetings set status='cancelada',cancelada_em=now(),cancelled_by=uid,cancellation_reason=reason_text where id=p_meeting_id returning * into saved;
 select id into booking_uuid from public.bookings where source_table='meetings' and legacy_id=p_meeting_id;
 return jsonb_build_object('ok',true,'meeting',to_jsonb(saved),'booking_id',booking_uuid);
end;$$;

create or replace function public.nexlab_archive_reservation_v26160(p_reservation_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare reason_text text:=nullif(btrim(coalesce(p_reason,'')),''); saved public.reservations%rowtype; booking_uuid uuid;
begin
 if auth.uid() is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') or not public.nexlab_is_gestor() then raise exception 'Somente a gestão pode arquivar reservas.' using errcode='42501'; end if;
 if reason_text is null or char_length(reason_text)<5 then raise exception 'Informe o motivo do arquivamento com pelo menos 5 caracteres.' using errcode='22023'; end if;
 if char_length(reason_text)>500 then raise exception 'O motivo deve possuir no máximo 500 caracteres.' using errcode='22023'; end if;
 perform set_config('nexlab.booking_action_reason',reason_text,true);
 update public.reservations set status='cancelada',archived_by=auth.uid(),archived_at=now() where id=p_reservation_id returning * into saved;
 if not found then raise exception 'Reserva não encontrada.' using errcode='P0002'; end if;
 select id into booking_uuid from public.bookings where source_table='reservations' and legacy_id=p_reservation_id;
 return jsonb_build_object('ok',true,'reservation',to_jsonb(saved),'booking_id',booking_uuid);
end;$$;

create or replace function public.nexlab_archive_meeting_v26160(p_meeting_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare reason_text text:=nullif(btrim(coalesce(p_reason,'')),''); saved public.meetings%rowtype; booking_uuid uuid;
begin
 if auth.uid() is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') or not public.nexlab_is_gestor() then raise exception 'Somente a gestão pode arquivar reuniões.' using errcode='42501'; end if;
 if reason_text is null or char_length(reason_text)<5 then raise exception 'Informe o motivo do arquivamento com pelo menos 5 caracteres.' using errcode='22023'; end if;
 if char_length(reason_text)>500 then raise exception 'O motivo deve possuir no máximo 500 caracteres.' using errcode='22023'; end if;
 perform set_config('nexlab.booking_action_reason',reason_text,true);
 update public.meetings set status='cancelada',cancelada_em=coalesce(cancelada_em,now()),archived_by=auth.uid(),archived_at=now() where id=p_meeting_id returning * into saved;
 if not found then raise exception 'Reunião não encontrada.' using errcode='P0002'; end if;
 select id into booking_uuid from public.bookings where source_table='meetings' and legacy_id=p_meeting_id;
 return jsonb_build_object('ok',true,'meeting',to_jsonb(saved),'booking_id',booking_uuid);
end;$$;

create or replace function public.notifications_reservation_trigger()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare owner_id uuid; owner_name text; reservation_label text; decision_label text;
begin
 owner_id:=new.usuario_id;
 reservation_label:=public.get_notification_record_label(to_jsonb(new),'Reserva de sala');
 if tg_op='INSERT' and coalesce(new.status,'pendente')='pendente' then
  select nome into owner_name from public.profiles where id=owner_id;
  perform public.notify_active_managers('reservation_created','Nova solicitação de reserva',coalesce(owner_name,'Um usuário')||' solicitou: '||reservation_label||'.','pendencias','reservation',new.id,'reservation:pending:'||new.id::text,false,owner_id);
 end if;
 if tg_op='UPDATE' then
  if new.archived_at is distinct from old.archived_at and new.archived_at is not null then return new; end if;
  if new.status is distinct from old.status and owner_id is not null then
   decision_label:=case new.status when 'aprovada' then 'aprovada' when 'recusada' then 'recusada' when 'cancelada' then 'cancelada' else coalesce(new.status,'atualizada') end;
   perform public.upsert_internal_notification(owner_id,'reservation_decided','Reserva '||decision_label,'A solicitação "'||reservation_label||'" foi '||decision_label||'.','reserva','reservation',new.id,'reservation:status:'||new.id::text||':'||coalesce(new.status,'atualizada'));
  end if;
 end if;
 return new;
end;$$;

revoke all on function public.nexlab_cancel_reservation_v26160(uuid,text) from public,anon;
grant execute on function public.nexlab_cancel_reservation_v26160(uuid,text) to authenticated,service_role;
revoke all on function public.nexlab_cancel_meeting_v26160(uuid,text) from public,anon;
grant execute on function public.nexlab_cancel_meeting_v26160(uuid,text) to authenticated,service_role;
revoke all on function public.nexlab_archive_reservation_v26160(uuid,text) from public,anon;
grant execute on function public.nexlab_archive_reservation_v26160(uuid,text) to authenticated,service_role;
revoke all on function public.nexlab_archive_meeting_v26160(uuid,text) from public,anon;
grant execute on function public.nexlab_archive_meeting_v26160(uuid,text) to authenticated,service_role;
revoke all on function public.notifications_reservation_trigger() from public,anon,authenticated;
