-- NEXLAB v26.15.0 — RPCs transacionais de Reservas e Reuniões
-- As alterações já foram aplicadas no projeto Nexlab. Arquivo de backup.

create or replace function public.nexlab_replace_legacy_participants_v26150(p_kind text,p_record_id uuid,p_user_ids uuid[])
returns uuid[]
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare normalized_ids uuid[]:='{}'::uuid[];
begin
 if p_kind not in ('reservation','meeting') then raise exception 'Tipo de agendamento inválido.' using errcode='22023'; end if;
 select coalesce(array_agg(distinct p.id order by p.id),'{}'::uuid[]) into normalized_ids
 from public.profiles p where p.ativo is distinct from false and p.id=any(coalesce(p_user_ids,'{}'::uuid[]));
 if p_kind='reservation' then
  if not exists(select 1 from public.reservations where id=p_record_id) then raise exception 'Reserva não encontrada.' using errcode='P0002'; end if;
  delete from public.reservation_participants where reservation_id=p_record_id;
  insert into public.reservation_participants(reservation_id,user_id,created_by)
  select p_record_id,x,auth.uid() from unnest(normalized_ids) x on conflict do nothing;
 else
  if not exists(select 1 from public.meetings where id=p_record_id) then raise exception 'Reunião não encontrada.' using errcode='P0002'; end if;
  delete from public.meeting_participants where meeting_id=p_record_id;
  insert into public.meeting_participants(meeting_id,user_id,created_by)
  select p_record_id,x,auth.uid() from unnest(normalized_ids) x on conflict do nothing;
 end if;
 return normalized_ids;
end;
$$;
revoke all on function public.nexlab_replace_legacy_participants_v26150(text,uuid,uuid[]) from public,anon,authenticated;
grant execute on function public.nexlab_replace_legacy_participants_v26150(text,uuid,uuid[]) to service_role;

create or replace function public.nexlab_create_reservation_v26150(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
 uid uuid:=auth.uid(); title_text text:=nullif(btrim(p_payload->>'titulo'),'');
 purpose_text text:=nullif(btrim(p_payload->>'finalidade'),''); description_text text:=nullif(btrim(p_payload->>'descricao'),'');
 resources_text text:=nullif(btrim(p_payload->>'recursos'),''); booking_date date; start_time time; end_time time;
 participant_ids uuid[]:='{}'::uuid[]; saved public.reservations%rowtype; booking_uuid uuid;
begin
 if uid is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') then raise exception 'Você não possui acesso a Reservas e Reuniões.' using errcode='42501'; end if;
 if title_text is null or char_length(title_text)>150 then raise exception 'Informe um título com até 150 caracteres.' using errcode='22023'; end if;
 if purpose_text is null or char_length(purpose_text)>150 then raise exception 'Informe uma finalidade com até 150 caracteres.' using errcode='22023'; end if;
 if description_text is not null and char_length(description_text)>2000 then raise exception 'A descrição deve possuir no máximo 2.000 caracteres.' using errcode='22023'; end if;
 if resources_text is not null and char_length(resources_text)>500 then raise exception 'Os recursos devem possuir no máximo 500 caracteres.' using errcode='22023'; end if;
 begin booking_date:=(p_payload->>'data')::date; start_time:=(p_payload->>'hora_inicio')::time; end_time:=(p_payload->>'hora_fim')::time; exception when others then raise exception 'Data ou horário inválido.' using errcode='22007'; end;
 if booking_date<(now() at time zone 'America/Fortaleza')::date then raise exception 'Não é possível solicitar uma reserva no passado.' using errcode='22023'; end if;
 if end_time<=start_time then raise exception 'O horário final precisa ser posterior ao horário inicial.' using errcode='22007'; end if;
 begin select coalesce(array_agg(distinct x::uuid),'{}'::uuid[]) into participant_ids from jsonb_array_elements_text(coalesce(p_payload->'participant_ids','[]'::jsonb)) x; exception when others then raise exception 'A lista de participantes é inválida.' using errcode='22023'; end;
 participant_ids:=array(select distinct x from unnest(array_append(participant_ids,uid)) x where x is not null);
 insert into public.reservations(titulo,finalidade,data,hora_inicio,hora_fim,usuario_id,user_id,status,recursos,descricao,sala_nome)
 values(title_text,purpose_text,booking_date,start_time,end_time,uid,uid,'pendente',resources_text,description_text,coalesce(nullif(btrim(p_payload->>'sala_nome'),''),'Sala principal')) returning * into saved;
 participant_ids:=public.nexlab_replace_legacy_participants_v26150('reservation',saved.id,participant_ids);
 select id into booking_uuid from public.bookings where source_table='reservations' and legacy_id=saved.id;
 return jsonb_build_object('ok',true,'reservation',to_jsonb(saved),'participant_ids',to_jsonb(participant_ids),'booking_id',booking_uuid);
end;
$$;
revoke all on function public.nexlab_create_reservation_v26150(jsonb) from public,anon;
grant execute on function public.nexlab_create_reservation_v26150(jsonb) to authenticated,service_role;

create or replace function public.nexlab_update_reservation_v26150(p_reservation_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare uid uuid:=auth.uid(); current_row public.reservations%rowtype; saved public.reservations%rowtype; booking_date date; start_time time; end_time time;
begin
 if uid is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') then raise exception 'Você não possui acesso a Reservas e Reuniões.' using errcode='42501'; end if;
 select * into current_row from public.reservations where id=p_reservation_id for update;
 if not found then raise exception 'Reserva não encontrada.' using errcode='P0002'; end if;
 if not public.nexlab_is_gestor() and current_row.usuario_id<>uid then raise exception 'Você não pode editar esta reserva.' using errcode='42501'; end if;
 if not public.nexlab_is_gestor() and current_row.status<>'pendente' then raise exception 'Somente reservas pendentes podem ser editadas pelo solicitante.' using errcode='22023'; end if;
 begin booking_date:=coalesce((p_payload->>'data')::date,current_row.data); start_time:=coalesce((p_payload->>'hora_inicio')::time,current_row.hora_inicio); end_time:=coalesce((p_payload->>'hora_fim')::time,current_row.hora_fim); exception when others then raise exception 'Data ou horário inválido.' using errcode='22007'; end;
 if end_time<=start_time then raise exception 'O horário final precisa ser posterior ao horário inicial.' using errcode='22007'; end if;
 update public.reservations set titulo=coalesce(nullif(btrim(p_payload->>'titulo'),''),titulo),finalidade=coalesce(nullif(btrim(p_payload->>'finalidade'),''),finalidade),data=booking_date,hora_inicio=start_time,hora_fim=end_time,recursos=case when p_payload ? 'recursos' then nullif(btrim(p_payload->>'recursos'),'') else recursos end,descricao=case when p_payload ? 'descricao' then nullif(btrim(p_payload->>'descricao'),'') else descricao end,sala_nome=coalesce(nullif(btrim(p_payload->>'sala_nome'),''),sala_nome,'Sala principal') where id=p_reservation_id returning * into saved;
 return jsonb_build_object('ok',true,'reservation',to_jsonb(saved));
end;
$$;
revoke all on function public.nexlab_update_reservation_v26150(uuid,jsonb) from public,anon;
grant execute on function public.nexlab_update_reservation_v26150(uuid,jsonb) to authenticated,service_role;

create or replace function public.nexlab_cancel_reservation_v26150(p_reservation_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare uid uuid:=auth.uid(); current_row public.reservations%rowtype; saved public.reservations%rowtype; normalized_reason text:=nullif(btrim(coalesce(p_reason,'')),''); booking_uuid uuid;
begin
 if uid is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') then raise exception 'Você não possui acesso a Reservas e Reuniões.' using errcode='42501'; end if;
 select * into current_row from public.reservations where id=p_reservation_id for update;
 if not found then raise exception 'Reserva não encontrada.' using errcode='P0002'; end if;
 if not public.nexlab_is_gestor() and current_row.usuario_id<>uid then raise exception 'Você não pode cancelar esta reserva.' using errcode='42501'; end if;
 if current_row.status in ('cancelada','recusada') then raise exception 'A reserva já está encerrada.' using errcode='22023'; end if;
 if normalized_reason is not null and char_length(normalized_reason)>500 then raise exception 'O motivo deve possuir no máximo 500 caracteres.' using errcode='22023'; end if;
 perform set_config('nexlab.booking_cancel_reason',coalesce(normalized_reason,''),true); perform set_config('nexlab.booking_cancel_actor',uid::text,true); perform set_config('nexlab.booking_action_reason',coalesce(normalized_reason,'Reserva cancelada'),true);
 update public.reservations set status='cancelada' where id=p_reservation_id returning * into saved;
 update public.bookings set cancelled_by=uid,cancelled_at=now(),cancellation_reason=normalized_reason,updated_by=uid where source_table='reservations' and legacy_id=p_reservation_id returning id into booking_uuid;
 return jsonb_build_object('ok',true,'reservation',to_jsonb(saved),'booking_id',booking_uuid);
end;$$;
revoke all on function public.nexlab_cancel_reservation_v26150(uuid,text) from public,anon;
grant execute on function public.nexlab_cancel_reservation_v26150(uuid,text) to authenticated,service_role;

create or replace function public.nexlab_review_reservation_v26150(p_reservation_id uuid,p_decision text,p_reason text default null,p_expected_status text default 'pendente')
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
 if auth.uid() is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') then raise exception 'Você não possui acesso a Reservas e Reuniões.' using errcode='42501'; end if;
 return public.nexlab_review_reservation_v2690(p_reservation_id,p_decision,p_reason,p_expected_status);
end;$$;
revoke all on function public.nexlab_review_reservation_v26150(uuid,text,text,text) from public,anon;
grant execute on function public.nexlab_review_reservation_v26150(uuid,text,text,text) to authenticated,service_role;

create or replace function public.nexlab_create_meeting_v26150(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare uid uuid:=auth.uid(); title_text text:=nullif(btrim(p_payload->>'titulo'),''); description_text text:=nullif(btrim(p_payload->>'descricao'),''); local_text text:=nullif(btrim(p_payload->>'local'),''); link_text text:=nullif(btrim(p_payload->>'link'),''); meeting_date date; meeting_time time; participant_ids uuid[]:='{}'::uuid[]; saved public.meetings%rowtype; booking_uuid uuid;
begin
 if uid is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') or not public.nexlab_is_gestor() then raise exception 'Somente Administradores e Coordenadores podem criar reuniões.' using errcode='42501'; end if;
 if title_text is null or char_length(title_text)>150 then raise exception 'Informe um título com até 150 caracteres.' using errcode='22023'; end if;
 if description_text is not null and char_length(description_text)>2000 then raise exception 'A descrição deve possuir no máximo 2.000 caracteres.' using errcode='22023'; end if;
 if local_text is not null and char_length(local_text)>150 then raise exception 'O local deve possuir no máximo 150 caracteres.' using errcode='22023'; end if;
 if link_text is not null and (char_length(link_text)>1000 or link_text !~* '^https?://') then raise exception 'Informe um link iniciado por http:// ou https://.' using errcode='22023'; end if;
 begin meeting_date:=(p_payload->>'data')::date; meeting_time:=(p_payload->>'hora')::time; exception when others then raise exception 'Data ou horário inválido.' using errcode='22007'; end;
 if meeting_date<(now() at time zone 'America/Fortaleza')::date then raise exception 'Não é possível criar uma reunião no passado.' using errcode='22023'; end if;
 begin select coalesce(array_agg(distinct x::uuid),'{}'::uuid[]) into participant_ids from jsonb_array_elements_text(coalesce(p_payload->'participant_ids','[]'::jsonb)) x; exception when others then raise exception 'A lista de participantes é inválida.' using errcode='22023'; end;
 insert into public.meetings(titulo,descricao,data,hora,local,autor_id,status,cancelada_em,link,para_todos,alvo_roles,alvo_users) values(title_text,description_text,meeting_date,meeting_time,local_text,uid,'agendada',null,link_text,false,null,null) returning * into saved;
 participant_ids:=public.nexlab_replace_legacy_participants_v26150('meeting',saved.id,participant_ids);
 select id into booking_uuid from public.bookings where source_table='meetings' and legacy_id=saved.id;
 return jsonb_build_object('ok',true,'meeting',to_jsonb(saved),'participant_ids',to_jsonb(participant_ids),'booking_id',booking_uuid);
end;$$;
revoke all on function public.nexlab_create_meeting_v26150(jsonb) from public,anon;
grant execute on function public.nexlab_create_meeting_v26150(jsonb) to authenticated,service_role;

create or replace function public.nexlab_update_meeting_v26150(p_meeting_id uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare uid uuid:=auth.uid(); current_row public.meetings%rowtype; saved public.meetings%rowtype; meeting_date date; meeting_time time; participant_ids uuid[]:='{}'::uuid[]; booking_uuid uuid; link_text text;
begin
 if uid is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') or not public.nexlab_is_gestor() then raise exception 'Somente Administradores e Coordenadores podem editar reuniões.' using errcode='42501'; end if;
 select * into current_row from public.meetings where id=p_meeting_id for update; if not found then raise exception 'Reunião não encontrada.' using errcode='P0002'; end if;
 begin meeting_date:=coalesce((p_payload->>'data')::date,current_row.data); meeting_time:=coalesce((p_payload->>'hora')::time,current_row.hora); exception when others then raise exception 'Data ou horário inválido.' using errcode='22007'; end;
 if meeting_date<(now() at time zone 'America/Fortaleza')::date then raise exception 'Não é possível mover a reunião para o passado.' using errcode='22023'; end if;
 link_text:=case when p_payload ? 'link' then nullif(btrim(p_payload->>'link'),'') else current_row.link end;
 if link_text is not null and (char_length(link_text)>1000 or link_text !~* '^https?://') then raise exception 'Informe um link iniciado por http:// ou https://.' using errcode='22023'; end if;
 update public.meetings set titulo=coalesce(nullif(btrim(p_payload->>'titulo'),''),titulo),descricao=case when p_payload ? 'descricao' then nullif(btrim(p_payload->>'descricao'),'') else descricao end,data=meeting_date,hora=meeting_time,local=case when p_payload ? 'local' then nullif(btrim(p_payload->>'local'),'') else local end,link=link_text where id=p_meeting_id returning * into saved;
 if p_payload ? 'participant_ids' then begin select coalesce(array_agg(distinct x::uuid),'{}'::uuid[]) into participant_ids from jsonb_array_elements_text(coalesce(p_payload->'participant_ids','[]'::jsonb)) x; exception when others then raise exception 'A lista de participantes é inválida.' using errcode='22023'; end; participant_ids:=public.nexlab_replace_legacy_participants_v26150('meeting',saved.id,participant_ids); else select coalesce(array_agg(user_id),'{}'::uuid[]) into participant_ids from public.meeting_participants where meeting_id=saved.id; end if;
 select id into booking_uuid from public.bookings where source_table='meetings' and legacy_id=saved.id;
 return jsonb_build_object('ok',true,'meeting',to_jsonb(saved),'participant_ids',to_jsonb(participant_ids),'booking_id',booking_uuid);
end;$$;
revoke all on function public.nexlab_update_meeting_v26150(uuid,jsonb) from public,anon;
grant execute on function public.nexlab_update_meeting_v26150(uuid,jsonb) to authenticated,service_role;

create or replace function public.nexlab_cancel_meeting_v26150(p_meeting_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare uid uuid:=auth.uid(); current_row public.meetings%rowtype; saved public.meetings%rowtype; normalized_reason text:=nullif(btrim(coalesce(p_reason,'')),''); booking_uuid uuid;
begin
 if uid is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') or not public.nexlab_is_gestor() then raise exception 'Somente Administradores e Coordenadores podem cancelar reuniões.' using errcode='42501'; end if;
 select * into current_row from public.meetings where id=p_meeting_id for update; if not found then raise exception 'Reunião não encontrada.' using errcode='P0002'; end if;
 if current_row.status='cancelada' then raise exception 'A reunião já está cancelada.' using errcode='22023'; end if;
 if normalized_reason is not null and char_length(normalized_reason)>500 then raise exception 'O motivo deve possuir no máximo 500 caracteres.' using errcode='22023'; end if;
 perform set_config('nexlab.booking_cancel_reason',coalesce(normalized_reason,''),true); perform set_config('nexlab.booking_cancel_actor',uid::text,true); perform set_config('nexlab.booking_action_reason',coalesce(normalized_reason,'Reunião cancelada'),true);
 update public.meetings set status='cancelada',cancelada_em=now() where id=p_meeting_id returning * into saved;
 update public.bookings set cancelled_by=uid,cancelled_at=now(),cancellation_reason=normalized_reason,updated_by=uid where source_table='meetings' and legacy_id=p_meeting_id returning id into booking_uuid;
 return jsonb_build_object('ok',true,'meeting',to_jsonb(saved),'booking_id',booking_uuid);
end;$$;
revoke all on function public.nexlab_cancel_meeting_v26150(uuid,text) from public,anon;
grant execute on function public.nexlab_cancel_meeting_v26150(uuid,text) to authenticated,service_role;
