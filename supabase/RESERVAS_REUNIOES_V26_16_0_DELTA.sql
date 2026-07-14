-- NEXLAB v26.16.0 — Correções 5, 6, 7 e 8 de Reservas e Reuniões
-- Alterações já aplicadas ao Supabase Nexlab. Não execute novamente no projeto atual.

-- NEXLAB v26.16.0 — Histórico, cancelamento, arquivamento e preservação legada
alter table public.reservations
  add column if not exists requester_name_snapshot text,
  add column if not exists requester_role_snapshot text,
  add column if not exists cancelled_by uuid references public.profiles(id) on delete set null,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancellation_reason text,
  add column if not exists archived_by uuid references public.profiles(id) on delete set null,
  add column if not exists archived_at timestamptz;

alter table public.meetings
  add column if not exists author_name_snapshot text,
  add column if not exists author_role_snapshot text,
  add column if not exists cancelled_by uuid references public.profiles(id) on delete set null,
  add column if not exists cancellation_reason text,
  add column if not exists archived_by uuid references public.profiles(id) on delete set null,
  add column if not exists archived_at timestamptz;

alter table public.reservations drop constraint if exists reservations_cancellation_reason_length_v26160;
alter table public.reservations add constraint reservations_cancellation_reason_length_v26160
  check (cancellation_reason is null or char_length(cancellation_reason) <= 500);
alter table public.meetings drop constraint if exists meetings_cancellation_reason_length_v26160;
alter table public.meetings add constraint meetings_cancellation_reason_length_v26160
  check (cancellation_reason is null or char_length(cancellation_reason) <= 500);

-- O campo usuario_id permanece canônico; user_id fica apenas como espelho temporário.
alter table public.reservations alter column usuario_id drop not null;
alter table public.reservations drop constraint if exists reservations_user_id_fkey;
alter table public.reservations add constraint reservations_user_id_fkey
  foreign key (user_id) references public.profiles(id) on delete set null;
alter table public.reservations drop constraint if exists reservations_usuario_id_fkey;
alter table public.reservations add constraint reservations_usuario_id_fkey
  foreign key (usuario_id) references public.profiles(id) on delete set null;

alter table public.meetings drop constraint if exists meetings_team_id_fkey;
alter table public.meetings add constraint meetings_team_id_fkey
  foreign key (team_id) references public.teams(id) on delete set null;

alter table public.booking_history drop constraint if exists booking_history_booking_id_fkey;
alter table public.booking_history add constraint booking_history_booking_id_fkey
  foreign key (booking_id) references public.bookings(id) on delete restrict;

update public.reservations r
set requester_name_snapshot = coalesce(r.requester_name_snapshot, nullif(btrim(p.nome), ''), 'Usuário removido'),
    requester_role_snapshot = coalesce(r.requester_role_snapshot, lower(p.role::text))
from public.profiles p
where p.id = coalesce(r.usuario_id,r.user_id);

update public.meetings m
set author_name_snapshot = coalesce(m.author_name_snapshot, nullif(btrim(p.nome), ''), 'Usuário removido'),
    author_role_snapshot = coalesce(m.author_role_snapshot, lower(p.role::text))
from public.profiles p
where p.id = m.autor_id;

update public.reservations
set requester_name_snapshot = coalesce(requester_name_snapshot,'Usuário removido')
where requester_name_snapshot is null;
update public.meetings
set author_name_snapshot = coalesce(author_name_snapshot,'Usuário removido')
where author_name_snapshot is null;

create index if not exists reservations_archived_at_idx on public.reservations (archived_at) where archived_at is not null;
create index if not exists meetings_archived_at_idx on public.meetings (archived_at) where archived_at is not null;
create index if not exists reservations_cancelled_at_idx on public.reservations (cancelled_at) where cancelled_at is not null;
create index if not exists meetings_cancelled_at_idx on public.meetings (cancelada_em) where cancelada_em is not null;

create or replace function public.nexlab_booking_child_history_v26160()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  target_booking uuid;
  actor uuid := auth.uid();
  actor_data jsonb;
  action_name text;
  reason_text text := nullif(current_setting('nexlab.booking_action_reason',true),'');
begin
  target_booking := coalesce(new.booking_id, old.booking_id);
  actor_data := public.nexlab_booking_profile_snapshot_v26150(actor);
  action_name := case
    when tg_table_name='booking_participants' and tg_op='INSERT' then 'participant_added'
    when tg_table_name='booking_participants' and tg_op='DELETE' then 'participant_removed'
    when tg_table_name='booking_participants' then 'participant_updated'
    when tg_table_name='booking_resources' and tg_op='INSERT' then 'resource_added'
    when tg_table_name='booking_resources' and tg_op='DELETE' then 'resource_removed'
    else 'resource_updated'
  end;
  insert into public.booking_history(booking_id,action,actor_id,actor_name_snapshot,reason,old_data,new_data)
  values(target_booking,action_name,actor,coalesce(actor_data->>'name','Sistema'),reason_text,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.nexlab_booking_child_history_v26160() from public, anon, authenticated;

drop trigger if exists booking_participants_history_v26160 on public.booking_participants;
create trigger booking_participants_history_v26160
after insert or update or delete on public.booking_participants
for each row execute function public.nexlab_booking_child_history_v26160();

drop trigger if exists booking_resources_history_v26160 on public.booking_resources;
create trigger booking_resources_history_v26160
after insert or update or delete on public.booking_resources
for each row execute function public.nexlab_booking_child_history_v26160();

create or replace function public.nexlab_get_booking_details_v26160(p_kind text, p_legacy_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  normalized_kind text := lower(btrim(coalesce(p_kind,'')));
  source_name text;
  result jsonb;
begin
  if auth.uid() is null or not public.nexlab_has_approved_access()
     or not public.nexlab_has_effective_permission_v2680('module_reserva') then
    raise exception 'Você não possui acesso a Reservas e Reuniões.' using errcode='42501';
  end if;
  source_name := case normalized_kind when 'reserva' then 'reservations' when 'reuniao' then 'meetings' else null end;
  if source_name is null then raise exception 'Tipo de agendamento inválido.' using errcode='22023'; end if;

  select jsonb_build_object(
    'ok',true,
    'booking',to_jsonb(b),
    'participants',coalesce((select jsonb_agg(to_jsonb(bp) order by bp.created_at,bp.id) from public.booking_participants bp where bp.booking_id=b.id),'[]'::jsonb),
    'resources',coalesce((select jsonb_agg(to_jsonb(br) order by br.resource_name,br.id) from public.booking_resources br where br.booking_id=b.id),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(to_jsonb(bh) order by bh.created_at desc,bh.id desc) from public.booking_history bh where bh.booking_id=b.id),'[]'::jsonb)
  ) into result
  from public.bookings b
  where b.source_table=source_name and b.legacy_id=p_legacy_id
    and (public.nexlab_is_gestor() or b.responsavel_id=auth.uid() or exists(
      select 1 from public.booking_participants bp where bp.booking_id=b.id and bp.user_id=auth.uid()
    ));
  if result is null then raise exception 'Agendamento não encontrado ou sem acesso.' using errcode='P0002'; end if;
  return result;
end;
$$;
revoke all on function public.nexlab_get_booking_details_v26160(text,uuid) from public, anon;
grant execute on function public.nexlab_get_booking_details_v26160(text,uuid) to authenticated, service_role;

-- NEXLAB v26.16.0 — Disponibilidade e conflitos unificados
create extension if not exists btree_gist with schema extensions;

alter table public.bookings
  add column if not exists hold_expires_at timestamptz,
  add column if not exists completed_at timestamptz;

create index if not exists bookings_hold_expiry_idx
  on public.bookings (hold_expires_at)
  where status = 'pendente' and hold_expires_at is not null;

-- Removida se existir para permitir reaplicação idempotente em projeto novo.
alter table public.bookings drop constraint if exists bookings_space_time_excl_v26160;
alter table public.bookings
  add constraint bookings_space_time_excl_v26160
  exclude using gist (
    espaco_id with =,
    tstzrange(inicio, fim, '[)') with &&
  )
  where (
    espaco_id is not null
    and formato in ('presencial','hibrido')
    and status in ('pendente','aprovada','agendada')
  );

alter table public.meetings
  add column if not exists hora_fim time,
  add column if not exists formato text,
  add column if not exists espaco_id uuid references public.spaces(id) on delete set null;

update public.meetings
set hora_fim = coalesce(hora_fim, hora + interval '60 minutes'),
    formato = coalesce(formato,
      case
        when nullif(btrim(link),'') is not null and nullif(btrim(local),'') is not null then 'hibrido'
        when nullif(btrim(link),'') is not null then 'online'
        else 'presencial'
      end),
    espaco_id = coalesce(espaco_id, (
      select s.id from public.spaces s
      where lower(btrim(s.nome)) = lower(btrim(meetings.local))
      limit 1
    ));

alter table public.meetings
  alter column hora_fim set default null;

alter table public.meetings drop constraint if exists meetings_time_range_check_v26160;
alter table public.meetings add constraint meetings_time_range_check_v26160
  check (hora_fim is null or hora is null or hora_fim > hora);
alter table public.meetings drop constraint if exists meetings_format_check_v26160;
alter table public.meetings add constraint meetings_format_check_v26160
  check (formato is null or formato in ('presencial','online','hibrido'));

create index if not exists meetings_space_date_time_idx
  on public.meetings (espaco_id, data, hora, hora_fim)
  where espaco_id is not null and status = 'agendada';

create or replace function public.nexlab_expire_pending_bookings_v26160()
returns integer
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  affected integer := 0;
begin
  perform set_config('nexlab.booking_cancel_reason','Solicitação expirada automaticamente.',true);
  perform set_config('nexlab.booking_action_reason','Solicitação expirada automaticamente.',true);

  update public.reservations r
  set status = 'cancelada',
      cancelled_at = coalesce(r.cancelled_at, now()),
      cancellation_reason = coalesce(r.cancellation_reason, 'Solicitação expirada automaticamente.')
  where r.id in (
    select b.legacy_id
    from public.bookings b
    where b.source_table = 'reservations'
      and b.status = 'pendente'
      and b.hold_expires_at is not null
      and b.hold_expires_at <= now()
      and b.legacy_id is not null
  );
  get diagnostics affected = row_count;
  return affected;
end;
$$;
revoke all on function public.nexlab_expire_pending_bookings_v26160() from public, anon, authenticated;
grant execute on function public.nexlab_expire_pending_bookings_v26160() to service_role;

create or replace function public.nexlab_get_space_availability_v26160(p_space_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  uid uuid := auth.uid();
  selected_space public.spaces%rowtype;
  current_booking public.bookings%rowtype;
  next_booking public.bookings%rowtype;
begin
  if uid is null
     or not public.nexlab_has_approved_access()
     or not public.nexlab_has_effective_permission_v2680('module_reserva') then
    raise exception 'Você não possui acesso a Reservas e Reuniões.' using errcode='42501';
  end if;

  select * into selected_space
  from public.spaces s
  where s.ativo
    and (s.id = p_space_id or (p_space_id is null and lower(btrim(s.nome)) = lower('Sala principal')))
  order by case when s.id = p_space_id then 0 else 1 end, s.created_at
  limit 1;

  if selected_space.id is null then
    return jsonb_build_object('ok',true,'available',false,'status','space_not_found');
  end if;

  select * into current_booking
  from public.bookings b
  where b.espaco_id = selected_space.id
    and b.formato in ('presencial','hibrido')
    and b.status in ('pendente','aprovada','agendada')
    and (b.status <> 'pendente' or b.hold_expires_at is null or b.hold_expires_at > now())
    and now() >= b.inicio and now() < b.fim
  order by b.inicio, b.id
  limit 1;

  select * into next_booking
  from public.bookings b
  where b.espaco_id = selected_space.id
    and b.formato in ('presencial','hibrido')
    and b.status in ('pendente','aprovada','agendada')
    and (b.status <> 'pendente' or b.hold_expires_at is null or b.hold_expires_at > now())
    and b.inicio >= now()
  order by b.inicio, b.id
  limit 1;

  return jsonb_build_object(
    'ok', true,
    'space', jsonb_build_object('id',selected_space.id,'name',selected_space.nome,'location',selected_space.localizacao),
    'available', current_booking.id is null,
    'status', case when current_booking.id is null then 'available' else 'occupied' end,
    'current', case when current_booking.id is null then null else jsonb_build_object(
      'id',current_booking.id,'type',current_booking.tipo,'title',current_booking.titulo,
      'start',current_booking.inicio,'end',current_booking.fim,'status',current_booking.status
    ) end,
    'next', case when next_booking.id is null then null else jsonb_build_object(
      'id',next_booking.id,'type',next_booking.tipo,'title',next_booking.titulo,
      'start',next_booking.inicio,'end',next_booking.fim,'status',next_booking.status
    ) end,
    'generated_at', now()
  );
end;
$$;
revoke all on function public.nexlab_get_space_availability_v26160(uuid) from public, anon;
grant execute on function public.nexlab_get_space_availability_v26160(uuid) to authenticated, service_role;

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

-- NEXLAB v26.16.0 — Realtime dedicado ao núcleo unificado
alter table public.spaces replica identity full;
alter table public.bookings replica identity full;
alter table public.booking_participants replica identity full;
alter table public.booking_resources replica identity full;
alter table public.booking_history replica identity full;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='spaces') then
    alter publication supabase_realtime add table public.spaces;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='bookings') then
    alter publication supabase_realtime add table public.bookings;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='booking_participants') then
    alter publication supabase_realtime add table public.booking_participants;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='booking_resources') then
    alter publication supabase_realtime add table public.booking_resources;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='booking_history') then
    alter publication supabase_realtime add table public.booking_history;
  end if;
end $$;

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

-- NEXLAB v26.16.0 — Índices de apoio para cancelamento e arquivamento
create index if not exists reservations_cancelled_by_idx on public.reservations(cancelled_by) where cancelled_by is not null;
create index if not exists reservations_archived_by_idx on public.reservations(archived_by) where archived_by is not null;
create index if not exists meetings_cancelled_by_idx on public.meetings(cancelled_by) where cancelled_by is not null;
create index if not exists meetings_archived_by_idx on public.meetings(archived_by) where archived_by is not null;
