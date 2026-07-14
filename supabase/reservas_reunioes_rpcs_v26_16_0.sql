-- NEXLAB v26.16.0 — RPCs com disponibilidade, cancelamento e arquivamento

create or replace function public.nexlab_sync_reservation_owner_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare p public.profiles%rowtype;
begin
  new.usuario_id := coalesce(new.usuario_id,new.user_id,auth.uid());
  if new.usuario_id is null and nullif(btrim(coalesce(new.requester_name_snapshot,'')),'') is null then
    raise exception 'A reserva precisa possuir um solicitante.' using errcode='23502';
  end if;
  new.user_id := new.usuario_id;
  if new.usuario_id is not null then
    select * into p from public.profiles where id=new.usuario_id;
    new.requester_name_snapshot := coalesce(nullif(btrim(new.requester_name_snapshot),''),nullif(btrim(p.nome),''),'Usuário removido');
    new.requester_role_snapshot := coalesce(nullif(btrim(new.requester_role_snapshot),''),lower(p.role::text));
  else
    new.requester_name_snapshot := coalesce(nullif(btrim(new.requester_name_snapshot),''),'Usuário removido');
  end if;
  return new;
end;
$$;
revoke all on function public.nexlab_sync_reservation_owner_v2690() from public,anon,authenticated;

create or replace function public.nexlab_sync_reservation_booking_v26150()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  profile_data jsonb;
  default_space public.spaces%rowtype;
  start_at timestamptz;
  end_at timestamptz;
  actor_id uuid := auth.uid();
  cancel_reason text := coalesce(nullif(current_setting('nexlab.booking_cancel_reason',true),''),new.cancellation_reason);
  cancellation_actor uuid := coalesce(new.cancelled_by,actor_id);
  hold_until timestamptz;
begin
  if tg_op='DELETE' then
    update public.bookings set status='arquivada',archived_at=now(),archived_by=actor_id,updated_by=actor_id
    where source_table='reservations' and legacy_id=old.id;
    return old;
  end if;
  select * into default_space from public.spaces s
  where lower(btrim(s.nome))=lower(btrim(coalesce(new.sala_nome,'Sala principal')))
  order by s.ativo desc,s.created_at limit 1;
  if default_space.id is null then select * into default_space from public.spaces where lower(btrim(nome))=lower('Sala principal') limit 1; end if;
  profile_data:=public.nexlab_booking_profile_snapshot_v26150(new.usuario_id);
  start_at:=((new.data::text||' '||new.hora_inicio::text)::timestamp at time zone 'America/Fortaleza');
  end_at:=((new.data::text||' '||new.hora_fim::text)::timestamp at time zone 'America/Fortaleza');
  hold_until:=case when lower(coalesce(new.status,'pendente'))='pendente' then least(start_at,new.created_at+interval '24 hours') else null end;
  insert into public.bookings(
    tipo,titulo,descricao,finalidade,inicio,fim,formato,espaco_id,espaco_nome_snapshot,
    responsavel_id,responsavel_nome_snapshot,responsavel_perfil_snapshot,recursos,status,exige_aprovacao,
    source_table,legacy_id,reviewed_by,reviewed_at,review_note,cancelled_by,cancelled_at,cancellation_reason,
    archived_by,archived_at,hold_expires_at,created_by,updated_by,created_at
  ) values(
    'reserva',coalesce(nullif(btrim(new.titulo),''),'Reserva de sala'),nullif(btrim(new.descricao),''),nullif(btrim(new.finalidade),''),
    start_at,end_at,'presencial',default_space.id,coalesce(nullif(btrim(new.sala_nome),''),default_space.nome,'Sala principal'),
    new.usuario_id,coalesce(nullif(btrim(new.requester_name_snapshot),''),profile_data->>'name','Usuário removido'),
    coalesce(nullif(btrim(new.requester_role_snapshot),''),nullif(profile_data->>'role','')),nullif(btrim(new.recursos),''),
    case when new.archived_at is not null then 'arquivada' else lower(coalesce(new.status,'pendente')) end,true,
    'reservations',new.id,new.reviewed_by,new.reviewed_at,new.review_note,
    case when lower(coalesce(new.status,''))='cancelada' then cancellation_actor else new.cancelled_by end,
    case when lower(coalesce(new.status,''))='cancelada' then coalesce(new.cancelled_at,now()) else new.cancelled_at end,
    case when lower(coalesce(new.status,''))='cancelada' then cancel_reason else new.cancellation_reason end,
    new.archived_by,new.archived_at,hold_until,coalesce(new.usuario_id,actor_id),actor_id,new.created_at
  )
  on conflict(source_table,legacy_id) where source_table is not null and legacy_id is not null
  do update set
    titulo=excluded.titulo,descricao=excluded.descricao,finalidade=excluded.finalidade,inicio=excluded.inicio,fim=excluded.fim,
    formato=excluded.formato,espaco_id=excluded.espaco_id,espaco_nome_snapshot=excluded.espaco_nome_snapshot,
    responsavel_id=excluded.responsavel_id,responsavel_nome_snapshot=excluded.responsavel_nome_snapshot,
    responsavel_perfil_snapshot=excluded.responsavel_perfil_snapshot,recursos=excluded.recursos,status=excluded.status,
    reviewed_by=excluded.reviewed_by,reviewed_at=excluded.reviewed_at,review_note=excluded.review_note,
    cancelled_by=coalesce(excluded.cancelled_by,bookings.cancelled_by),cancelled_at=coalesce(excluded.cancelled_at,bookings.cancelled_at),
    cancellation_reason=coalesce(excluded.cancellation_reason,bookings.cancellation_reason),
    archived_by=coalesce(excluded.archived_by,bookings.archived_by),archived_at=coalesce(excluded.archived_at,bookings.archived_at),
    hold_expires_at=excluded.hold_expires_at,updated_by=actor_id;
  return new;
end;
$$;
revoke all on function public.nexlab_sync_reservation_booking_v26150() from public,anon,authenticated;

create or replace function public.nexlab_sync_meeting_booking_v26150()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  p jsonb; sid uuid; sname text; started timestamptz; ended timestamptz;
  actor uuid:=auth.uid(); fmt text; normalized_status text;
begin
  if tg_op='DELETE' then
    update public.bookings set status='arquivada',archived_at=now(),archived_by=actor,updated_by=actor
    where source_table='meetings' and legacy_id=old.id;
    return old;
  end if;
  sid:=new.espaco_id;
  if sid is null and nullif(btrim(new.local),'') is not null then
    select id,nome into sid,sname from public.spaces where lower(btrim(nome))=lower(btrim(new.local)) limit 1;
  else select nome into sname from public.spaces where id=sid; end if;
  p:=public.nexlab_booking_profile_snapshot_v26150(new.autor_id);
  started:=((new.data::text||' '||coalesce(new.hora,time '00:00')::text)::timestamp at time zone 'America/Fortaleza');
  ended:=((new.data::text||' '||coalesce(new.hora_fim,new.hora+interval '60 minutes')::text)::timestamp at time zone 'America/Fortaleza');
  fmt:=coalesce(new.formato,case when nullif(btrim(new.link),'') is not null and nullif(btrim(new.local),'') is not null then 'hibrido' when nullif(btrim(new.link),'') is not null then 'online' else 'presencial' end);
  normalized_status:=case when new.archived_at is not null then 'arquivada' else lower(coalesce(new.status,'agendada')) end;
  insert into public.bookings(
    tipo,titulo,descricao,pauta,inicio,fim,formato,espaco_id,espaco_nome_snapshot,responsavel_id,
    responsavel_nome_snapshot,responsavel_perfil_snapshot,equipe_id,link_online,status,exige_aprovacao,
    source_table,legacy_id,cancelled_by,cancelled_at,cancellation_reason,archived_by,archived_at,created_by,updated_by,created_at
  ) values(
    'reuniao',coalesce(nullif(btrim(new.titulo),''),'Reunião'),nullif(btrim(new.descricao),''),nullif(btrim(new.descricao),''),
    started,ended,fmt,sid,coalesce(sname,nullif(btrim(new.local),'')),new.autor_id,
    coalesce(nullif(btrim(new.author_name_snapshot),''),p->>'name','Usuário removido'),
    coalesce(nullif(btrim(new.author_role_snapshot),''),nullif(p->>'role','')),new.team_id,nullif(btrim(new.link),''),
    normalized_status,false,'meetings',new.id,new.cancelled_by,coalesce(new.cancelada_em,case when normalized_status='cancelada' then now() end),
    new.cancellation_reason,new.archived_by,new.archived_at,coalesce(new.autor_id,actor),actor,new.created_at
  )
  on conflict(source_table,legacy_id) where source_table is not null and legacy_id is not null
  do update set titulo=excluded.titulo,descricao=excluded.descricao,pauta=excluded.pauta,inicio=excluded.inicio,fim=excluded.fim,
    formato=excluded.formato,espaco_id=excluded.espaco_id,espaco_nome_snapshot=excluded.espaco_nome_snapshot,
    responsavel_id=excluded.responsavel_id,responsavel_nome_snapshot=excluded.responsavel_nome_snapshot,
    responsavel_perfil_snapshot=excluded.responsavel_perfil_snapshot,equipe_id=excluded.equipe_id,link_online=excluded.link_online,
    status=excluded.status,cancelled_by=coalesce(excluded.cancelled_by,bookings.cancelled_by),
    cancelled_at=coalesce(excluded.cancelled_at,bookings.cancelled_at),cancellation_reason=coalesce(excluded.cancellation_reason,bookings.cancellation_reason),
    archived_by=coalesce(excluded.archived_by,bookings.archived_by),archived_at=coalesce(excluded.archived_at,bookings.archived_at),updated_by=actor;
  return new;
end;
$$;
revoke all on function public.nexlab_sync_meeting_booking_v26150() from public,anon,authenticated;

create or replace function public.nexlab_create_reservation_v26160(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare result jsonb;
begin
  perform public.nexlab_expire_pending_bookings_v26160();
  perform pg_advisory_xact_lock(hashtextextended(coalesce(p_payload->>'sala_nome','Sala principal')||':'||coalesce(p_payload->>'data',''),0));
  result:=public.nexlab_create_reservation_v26150(p_payload);
  return result;
exception when exclusion_violation then
  raise exception 'Este espaço já possui uma reserva ou reunião no período informado.' using errcode='23P01';
end;
$$;
revoke all on function public.nexlab_create_reservation_v26160(jsonb) from public,anon;
grant execute on function public.nexlab_create_reservation_v26160(jsonb) to authenticated,service_role;
revoke execute on function public.nexlab_create_reservation_v26150(jsonb) from authenticated;

create or replace function public.nexlab_update_reservation_v26160(p_reservation_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
begin
  perform public.nexlab_expire_pending_bookings_v26160();
  perform pg_advisory_xact_lock(hashtextextended(coalesce(p_payload->>'sala_nome','Sala principal')||':'||coalesce(p_payload->>'data',''),0));
  return public.nexlab_update_reservation_v26150(p_reservation_id,p_payload);
exception when exclusion_violation then
  raise exception 'Este espaço já possui uma reserva ou reunião no período informado.' using errcode='23P01';
end;
$$;
revoke all on function public.nexlab_update_reservation_v26160(uuid,jsonb) from public,anon;
grant execute on function public.nexlab_update_reservation_v26160(uuid,jsonb) to authenticated,service_role;
revoke execute on function public.nexlab_update_reservation_v26150(uuid,jsonb) from authenticated;

create or replace function public.nexlab_create_meeting_v26160(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare normalized jsonb:=coalesce(p_payload,'{}'::jsonb); start_time time; end_time time; result jsonb; meeting_id uuid;
begin
  perform public.nexlab_expire_pending_bookings_v26160();
  begin start_time:=(normalized->>'hora')::time; end_time:=coalesce((normalized->>'hora_fim')::time,start_time+interval '60 minutes');
  exception when others then raise exception 'Data ou horário inválido.' using errcode='22007'; end;
  normalized:=jsonb_set(normalized,'{hora_fim}',to_jsonb(end_time::text),true);
  perform pg_advisory_xact_lock(hashtextextended(coalesce(normalized->>'local','online')||':'||coalesce(normalized->>'data',''),0));
  result:=public.nexlab_create_meeting_v26150(normalized);
  meeting_id:=(result->'meeting'->>'id')::uuid;
  update public.meetings set hora_fim=end_time,
    formato=case when nullif(btrim(normalized->>'link'),'') is not null and nullif(btrim(normalized->>'local'),'') is not null then 'hibrido' when nullif(btrim(normalized->>'link'),'') is not null then 'online' else 'presencial' end,
    espaco_id=(select id from public.spaces where lower(btrim(nome))=lower(btrim(normalized->>'local')) limit 1)
  where id=meeting_id;
  select jsonb_set(result,'{meeting}',to_jsonb(m),true) into result from public.meetings m where m.id=meeting_id;
  return result;
exception when exclusion_violation then
  raise exception 'Este espaço já possui uma reserva ou reunião no período informado.' using errcode='23P01';
end;
$$;
revoke all on function public.nexlab_create_meeting_v26160(jsonb) from public,anon;
grant execute on function public.nexlab_create_meeting_v26160(jsonb) to authenticated,service_role;
revoke execute on function public.nexlab_create_meeting_v26150(jsonb) from authenticated;

create or replace function public.nexlab_update_meeting_v26160(p_meeting_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare normalized jsonb:=coalesce(p_payload,'{}'::jsonb); current_row public.meetings%rowtype; start_time time; end_time time; result jsonb;
begin
  perform public.nexlab_expire_pending_bookings_v26160();
  select * into current_row from public.meetings where id=p_meeting_id;
  if not found then raise exception 'Reunião não encontrada.' using errcode='P0002'; end if;
  start_time:=coalesce((normalized->>'hora')::time,current_row.hora);
  end_time:=coalesce((normalized->>'hora_fim')::time,current_row.hora_fim,start_time+interval '60 minutes');
  if end_time<=start_time then raise exception 'O horário final precisa ser posterior ao horário inicial.' using errcode='22007'; end if;
  normalized:=jsonb_set(normalized,'{hora_fim}',to_jsonb(end_time::text),true);
  perform pg_advisory_xact_lock(hashtextextended(coalesce(normalized->>'local',current_row.local,'online')||':'||coalesce(normalized->>'data',current_row.data::text),0));
  result:=public.nexlab_update_meeting_v26150(p_meeting_id,normalized);
  update public.meetings set hora_fim=end_time,
    formato=case when nullif(btrim(coalesce(normalized->>'link',link)),'') is not null and nullif(btrim(coalesce(normalized->>'local',local)),'') is not null then 'hibrido' when nullif(btrim(coalesce(normalized->>'link',link)),'') is not null then 'online' else 'presencial' end,
    espaco_id=(select id from public.spaces where lower(btrim(nome))=lower(btrim(coalesce(normalized->>'local',local))) limit 1)
  where id=p_meeting_id;
  select jsonb_set(result,'{meeting}',to_jsonb(m),true) into result from public.meetings m where m.id=p_meeting_id;
  return result;
exception when exclusion_violation then
  raise exception 'Este espaço já possui uma reserva ou reunião no período informado.' using errcode='23P01';
end;
$$;
revoke all on function public.nexlab_update_meeting_v26160(uuid,jsonb) from public,anon;
grant execute on function public.nexlab_update_meeting_v26160(uuid,jsonb) to authenticated,service_role;
revoke execute on function public.nexlab_update_meeting_v26150(uuid,jsonb) from authenticated;

create or replace function public.nexlab_cancel_reservation_v26160(p_reservation_id uuid,p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare uid uuid:=auth.uid(); row_data public.reservations%rowtype; reason_text text:=nullif(btrim(coalesce(p_reason,'')),''); result jsonb;
begin
  select * into row_data from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'Reserva não encontrada.' using errcode='P0002'; end if;
  if public.nexlab_is_gestor() and row_data.usuario_id is distinct from uid and (reason_text is null or char_length(reason_text)<5) then
    raise exception 'Informe o motivo do cancelamento com pelo menos 5 caracteres.' using errcode='22023';
  end if;
  result:=public.nexlab_cancel_reservation_v26150(p_reservation_id,reason_text);
  update public.reservations set cancelled_by=uid,cancelled_at=now(),cancellation_reason=reason_text where id=p_reservation_id;
  return result;
end;
$$;
revoke all on function public.nexlab_cancel_reservation_v26160(uuid,text) from public,anon;
grant execute on function public.nexlab_cancel_reservation_v26160(uuid,text) to authenticated,service_role;
revoke execute on function public.nexlab_cancel_reservation_v26150(uuid,text) from authenticated;

create or replace function public.nexlab_cancel_meeting_v26160(p_meeting_id uuid,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare reason_text text:=nullif(btrim(coalesce(p_reason,'')),''); result jsonb;
begin
  if reason_text is null or char_length(reason_text)<5 then raise exception 'Informe o motivo do cancelamento com pelo menos 5 caracteres.' using errcode='22023'; end if;
  result:=public.nexlab_cancel_meeting_v26150(p_meeting_id,reason_text);
  update public.meetings set cancelled_by=auth.uid(),cancellation_reason=reason_text where id=p_meeting_id;
  return result;
end;
$$;
revoke all on function public.nexlab_cancel_meeting_v26160(uuid,text) from public,anon;
grant execute on function public.nexlab_cancel_meeting_v26160(uuid,text) to authenticated,service_role;
revoke execute on function public.nexlab_cancel_meeting_v26150(uuid,text) from authenticated;

create or replace function public.nexlab_review_reservation_v26160(p_reservation_id uuid,p_decision text,p_reason text default null,p_expected_status text default 'pendente')
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare r public.reservations%rowtype; local_now timestamp:=now() at time zone 'America/Fortaleza'; result jsonb;
begin
  select * into r from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'Reserva não encontrada.' using errcode='P0002'; end if;
  if lower(btrim(coalesce(p_decision,'')))='aprovada' and (r.data<local_now::date or (r.data=local_now::date and r.hora_inicio<=local_now::time)) then
    raise exception 'Não é possível aprovar uma reserva que já começou.' using errcode='22023';
  end if;
  result:=public.nexlab_review_reservation_v26150(p_reservation_id,p_decision,p_reason,p_expected_status);
  return result;
end;
$$;
revoke all on function public.nexlab_review_reservation_v26160(uuid,text,text,text) from public,anon;
grant execute on function public.nexlab_review_reservation_v26160(uuid,text,text,text) to authenticated,service_role;
revoke execute on function public.nexlab_review_reservation_v26150(uuid,text,text,text) from authenticated;

create or replace function public.nexlab_archive_reservation_v26160(p_reservation_id uuid,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare reason_text text:=nullif(btrim(coalesce(p_reason,'')),''); b_id uuid;
begin
  if auth.uid() is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') or not public.nexlab_is_gestor() then raise exception 'Somente a gestão pode arquivar reservas.' using errcode='42501'; end if;
  if reason_text is null or char_length(reason_text)<5 then raise exception 'Informe o motivo do arquivamento com pelo menos 5 caracteres.' using errcode='22023'; end if;
  perform set_config('nexlab.booking_action_reason',reason_text,true);
  update public.reservations set archived_by=auth.uid(),archived_at=now() where id=p_reservation_id;
  if not found then raise exception 'Reserva não encontrada.' using errcode='P0002'; end if;
  update public.bookings set status='arquivada',archived_by=auth.uid(),archived_at=now(),updated_by=auth.uid() where source_table='reservations' and legacy_id=p_reservation_id returning id into b_id;
  return jsonb_build_object('ok',true,'reservation_id',p_reservation_id,'booking_id',b_id,'archived_at',now());
end;
$$;
revoke all on function public.nexlab_archive_reservation_v26160(uuid,text) from public,anon;
grant execute on function public.nexlab_archive_reservation_v26160(uuid,text) to authenticated,service_role;

create or replace function public.nexlab_archive_meeting_v26160(p_meeting_id uuid,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare reason_text text:=nullif(btrim(coalesce(p_reason,'')),''); b_id uuid;
begin
  if auth.uid() is null or not public.nexlab_has_approved_access() or not public.nexlab_has_effective_permission_v2680('module_reserva') or not public.nexlab_is_gestor() then raise exception 'Somente a gestão pode arquivar reuniões.' using errcode='42501'; end if;
  if reason_text is null or char_length(reason_text)<5 then raise exception 'Informe o motivo do arquivamento com pelo menos 5 caracteres.' using errcode='22023'; end if;
  perform set_config('nexlab.booking_action_reason',reason_text,true);
  update public.meetings set archived_by=auth.uid(),archived_at=now() where id=p_meeting_id;
  if not found then raise exception 'Reunião não encontrada.' using errcode='P0002'; end if;
  update public.bookings set status='arquivada',archived_by=auth.uid(),archived_at=now(),updated_by=auth.uid() where source_table='meetings' and legacy_id=p_meeting_id returning id into b_id;
  return jsonb_build_object('ok',true,'meeting_id',p_meeting_id,'booking_id',b_id,'archived_at',now());
end;
$$;
revoke all on function public.nexlab_archive_meeting_v26160(uuid,text) from public,anon;
grant execute on function public.nexlab_archive_meeting_v26160(uuid,text) to authenticated,service_role;
