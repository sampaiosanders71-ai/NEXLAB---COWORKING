-- NEXLAB v26.15.0 — Sincronização das tabelas legadas com o núcleo unificado

create or replace function public.nexlab_booking_profile_snapshot_v26150(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select jsonb_build_object(
    'id', p.id,
    'name', coalesce(nullif(btrim(p.nome), ''), 'Usuário removido'),
    'role', lower(coalesce(p.role::text, ''))
  )
  from public.profiles p
  where p.id = p_user_id
  limit 1;
$$;
revoke all on function public.nexlab_booking_profile_snapshot_v26150(uuid) from public, anon, authenticated;
grant execute on function public.nexlab_booking_profile_snapshot_v26150(uuid) to service_role;

create or replace function public.nexlab_sync_reservation_booking_v26150()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  profile_data jsonb;
  default_space public.spaces%rowtype;
  booking_row public.bookings%rowtype;
  start_at timestamptz;
  end_at timestamptz;
  actor_id uuid := auth.uid();
  cancel_reason text := nullif(current_setting('nexlab.booking_cancel_reason', true), '');
  cancellation_actor uuid;
begin
  if tg_op = 'DELETE' then
    update public.bookings b
       set status = 'arquivada',
           archived_at = now(),
           archived_by = actor_id,
           updated_by = actor_id
     where b.source_table = 'reservations'
       and b.legacy_id = old.id;
    return old;
  end if;

  select * into default_space
  from public.spaces s
  where lower(btrim(s.nome)) = lower(btrim(coalesce(new.sala_nome, 'Sala principal')))
  order by s.ativo desc, s.created_at
  limit 1;

  if default_space.id is null then
    select * into default_space
    from public.spaces s
    where lower(btrim(s.nome)) = lower('Sala principal')
    limit 1;
  end if;

  profile_data := public.nexlab_booking_profile_snapshot_v26150(new.usuario_id);
  start_at := ((new.data::text || ' ' || new.hora_inicio::text)::timestamp at time zone 'America/Fortaleza');
  end_at := ((new.data::text || ' ' || new.hora_fim::text)::timestamp at time zone 'America/Fortaleza');

  if lower(coalesce(new.status, '')) = 'cancelada' then
    begin
      cancellation_actor := nullif(current_setting('nexlab.booking_cancel_actor', true), '')::uuid;
    exception when others then
      cancellation_actor := actor_id;
    end;
  end if;

  insert into public.bookings (
    tipo, titulo, descricao, finalidade, inicio, fim, formato,
    espaco_id, espaco_nome_snapshot, responsavel_id,
    responsavel_nome_snapshot, responsavel_perfil_snapshot,
    recursos, status, exige_aprovacao, source_table, legacy_id,
    reviewed_by, reviewed_at, review_note,
    cancelled_by, cancelled_at, cancellation_reason,
    created_by, updated_by, created_at
  ) values (
    'reserva',
    coalesce(nullif(btrim(new.titulo), ''), 'Reserva de sala'),
    nullif(btrim(new.descricao), ''),
    nullif(btrim(new.finalidade), ''),
    start_at, end_at, 'presencial',
    default_space.id,
    coalesce(nullif(btrim(new.sala_nome), ''), default_space.nome, 'Sala principal'),
    new.usuario_id,
    coalesce(profile_data->>'name', 'Usuário removido'),
    nullif(profile_data->>'role', ''),
    nullif(btrim(new.recursos), ''),
    lower(coalesce(new.status, 'pendente')),
    true,
    'reservations', new.id,
    new.reviewed_by, new.reviewed_at, new.review_note,
    case when lower(coalesce(new.status, '')) = 'cancelada' then coalesce(cancellation_actor, actor_id) else null end,
    case when lower(coalesce(new.status, '')) = 'cancelada' then coalesce(new.reviewed_at, now()) else null end,
    case when lower(coalesce(new.status, '')) = 'cancelada' then cancel_reason else null end,
    coalesce(new.usuario_id, actor_id), actor_id, new.created_at
  )
  on conflict (source_table, legacy_id) where source_table is not null and legacy_id is not null
  do update set
    titulo = excluded.titulo,
    descricao = excluded.descricao,
    finalidade = excluded.finalidade,
    inicio = excluded.inicio,
    fim = excluded.fim,
    formato = excluded.formato,
    espaco_id = excluded.espaco_id,
    espaco_nome_snapshot = excluded.espaco_nome_snapshot,
    responsavel_id = excluded.responsavel_id,
    responsavel_nome_snapshot = excluded.responsavel_nome_snapshot,
    responsavel_perfil_snapshot = excluded.responsavel_perfil_snapshot,
    recursos = excluded.recursos,
    status = excluded.status,
    reviewed_by = excluded.reviewed_by,
    reviewed_at = excluded.reviewed_at,
    review_note = excluded.review_note,
    cancelled_by = case when excluded.status = 'cancelada' then coalesce(excluded.cancelled_by, public.bookings.cancelled_by) else public.bookings.cancelled_by end,
    cancelled_at = case when excluded.status = 'cancelada' then coalesce(excluded.cancelled_at, public.bookings.cancelled_at, now()) else public.bookings.cancelled_at end,
    cancellation_reason = case when excluded.status = 'cancelada' then coalesce(excluded.cancellation_reason, public.bookings.cancellation_reason) else public.bookings.cancellation_reason end,
    updated_by = actor_id
  returning * into booking_row;

  return new;
end;
$$;
revoke all on function public.nexlab_sync_reservation_booking_v26150() from public, anon, authenticated;

drop trigger if exists reservations_sync_booking_v26150 on public.reservations;
create trigger reservations_sync_booking_v26150
after insert or update or delete on public.reservations
for each row execute function public.nexlab_sync_reservation_booking_v26150();

create or replace function public.nexlab_sync_meeting_booking_v26150()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  profile_data jsonb;
  matched_space public.spaces%rowtype;
  booking_row public.bookings%rowtype;
  start_at timestamptz;
  end_at timestamptz;
  meeting_format text;
  actor_id uuid := auth.uid();
  cancel_reason text := nullif(current_setting('nexlab.booking_cancel_reason', true), '');
  cancellation_actor uuid;
begin
  if tg_op = 'DELETE' then
    update public.bookings b
       set status = 'arquivada', archived_at = now(), archived_by = actor_id, updated_by = actor_id
     where b.source_table = 'meetings' and b.legacy_id = old.id;
    return old;
  end if;

  if nullif(btrim(new.local), '') is not null then
    select * into matched_space
    from public.spaces s
    where lower(btrim(s.nome)) = lower(btrim(new.local))
    order by s.ativo desc, s.created_at
    limit 1;
  end if;

  profile_data := public.nexlab_booking_profile_snapshot_v26150(new.autor_id);
  start_at := ((new.data::text || ' ' || coalesce(new.hora, time '00:00')::text)::timestamp at time zone 'America/Fortaleza');
  end_at := start_at + interval '60 minutes';
  meeting_format := case
    when nullif(btrim(new.link), '') is not null and nullif(btrim(new.local), '') is not null then 'hibrido'
    when nullif(btrim(new.link), '') is not null then 'online'
    else 'presencial'
  end;

  if lower(coalesce(new.status, '')) = 'cancelada' then
    begin
      cancellation_actor := nullif(current_setting('nexlab.booking_cancel_actor', true), '')::uuid;
    exception when others then
      cancellation_actor := actor_id;
    end;
  end if;

  insert into public.bookings (
    tipo, titulo, descricao, pauta, inicio, fim, formato,
    espaco_id, espaco_nome_snapshot, responsavel_id,
    responsavel_nome_snapshot, responsavel_perfil_snapshot,
    equipe_id, link_online, status, exige_aprovacao,
    source_table, legacy_id, cancelled_by, cancelled_at,
    cancellation_reason, created_by, updated_by, created_at
  ) values (
    'reuniao',
    coalesce(nullif(btrim(new.titulo), ''), 'Reunião'),
    nullif(btrim(new.descricao), ''),
    nullif(btrim(new.descricao), ''),
    start_at, end_at, meeting_format,
    matched_space.id,
    nullif(btrim(new.local), ''),
    new.autor_id,
    coalesce(profile_data->>'name', 'Usuário removido'),
    nullif(profile_data->>'role', ''),
    new.team_id,
    nullif(btrim(new.link), ''),
    lower(coalesce(new.status, 'agendada')),
    false,
    'meetings', new.id,
    case when lower(coalesce(new.status, '')) = 'cancelada' then coalesce(cancellation_actor, actor_id) else null end,
    case when lower(coalesce(new.status, '')) = 'cancelada' then coalesce(new.cancelada_em, now()) else null end,
    case when lower(coalesce(new.status, '')) = 'cancelada' then cancel_reason else null end,
    coalesce(new.autor_id, actor_id), actor_id, new.created_at
  )
  on conflict (source_table, legacy_id) where source_table is not null and legacy_id is not null
  do update set
    titulo = excluded.titulo,
    descricao = excluded.descricao,
    pauta = excluded.pauta,
    inicio = excluded.inicio,
    fim = excluded.fim,
    formato = excluded.formato,
    espaco_id = excluded.espaco_id,
    espaco_nome_snapshot = excluded.espaco_nome_snapshot,
    responsavel_id = excluded.responsavel_id,
    responsavel_nome_snapshot = excluded.responsavel_nome_snapshot,
    responsavel_perfil_snapshot = excluded.responsavel_perfil_snapshot,
    equipe_id = excluded.equipe_id,
    link_online = excluded.link_online,
    status = excluded.status,
    cancelled_by = case when excluded.status = 'cancelada' then coalesce(excluded.cancelled_by, public.bookings.cancelled_by) else public.bookings.cancelled_by end,
    cancelled_at = case when excluded.status = 'cancelada' then coalesce(excluded.cancelled_at, public.bookings.cancelled_at, now()) else public.bookings.cancelled_at end,
    cancellation_reason = case when excluded.status = 'cancelada' then coalesce(excluded.cancellation_reason, public.bookings.cancellation_reason) else public.bookings.cancellation_reason end,
    updated_by = actor_id
  returning * into booking_row;

  return new;
end;
$$;
revoke all on function public.nexlab_sync_meeting_booking_v26150() from public, anon, authenticated;

drop trigger if exists meetings_sync_booking_v26150 on public.meetings;
create trigger meetings_sync_booking_v26150
after insert or update or delete on public.meetings
for each row execute function public.nexlab_sync_meeting_booking_v26150();

create or replace function public.nexlab_sync_legacy_booking_participant_v26150()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  source_name text;
  source_id uuid;
  participant_id uuid;
  booking_uuid uuid;
  profile_data jsonb;
begin
  if tg_table_name = 'reservation_participants' then
    source_name := 'reservations';
    source_id := coalesce(new.reservation_id, old.reservation_id);
  else
    source_name := 'meetings';
    source_id := coalesce(new.meeting_id, old.meeting_id);
  end if;
  participant_id := coalesce(new.user_id, old.user_id);

  select b.id into booking_uuid
  from public.bookings b
  where b.source_table = source_name and b.legacy_id = source_id;

  if booking_uuid is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;

  if tg_op = 'DELETE' then
    delete from public.booking_participants bp
    where bp.booking_id = booking_uuid and bp.user_id = participant_id;
    return old;
  end if;

  profile_data := public.nexlab_booking_profile_snapshot_v26150(participant_id);
  insert into public.booking_participants (
    booking_id, user_id, user_name_snapshot, user_role_snapshot, status, created_by
  ) values (
    booking_uuid, participant_id,
    coalesce(profile_data->>'name', 'Usuário removido'),
    nullif(profile_data->>'role', ''),
    'convidado',
    coalesce(auth.uid(), new.created_by)
  )
  on conflict (booking_id, user_id) where user_id is not null
  do update set
    user_name_snapshot = excluded.user_name_snapshot,
    user_role_snapshot = excluded.user_role_snapshot,
    updated_at = now();

  return new;
end;
$$;
revoke all on function public.nexlab_sync_legacy_booking_participant_v26150() from public, anon, authenticated;

drop trigger if exists reservation_participants_sync_booking_v26150 on public.reservation_participants;
create trigger reservation_participants_sync_booking_v26150
after insert or update or delete on public.reservation_participants
for each row execute function public.nexlab_sync_legacy_booking_participant_v26150();

drop trigger if exists meeting_participants_sync_booking_v26150 on public.meeting_participants;
create trigger meeting_participants_sync_booking_v26150
after insert or update or delete on public.meeting_participants
for each row execute function public.nexlab_sync_legacy_booking_participant_v26150();

create or replace function public.nexlab_booking_history_trigger_v26150()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  actor uuid := coalesce(auth.uid(), new.updated_by, new.created_by);
  actor_data jsonb;
  action_name text;
  reason_text text := nullif(current_setting('nexlab.booking_action_reason', true), '');
begin
  actor_data := public.nexlab_booking_profile_snapshot_v26150(actor);
  if tg_op = 'INSERT' then
    action_name := 'created';
  elsif old.status is distinct from new.status then
    action_name := 'status_' || new.status;
  elsif old.inicio is distinct from new.inicio or old.fim is distinct from new.fim or old.espaco_id is distinct from new.espaco_id then
    action_name := 'schedule_updated';
  else
    action_name := 'updated';
  end if;

  insert into public.booking_history (
    booking_id, action, actor_id, actor_name_snapshot, reason, old_data, new_data
  ) values (
    new.id, action_name, actor,
    coalesce(actor_data->>'name', 'Sistema'),
    reason_text,
    case when tg_op = 'UPDATE' then to_jsonb(old) else null end,
    to_jsonb(new)
  );
  return new;
end;
$$;
revoke all on function public.nexlab_booking_history_trigger_v26150() from public, anon, authenticated;

drop trigger if exists bookings_history_v26150 on public.bookings;
create trigger bookings_history_v26150
after insert or update on public.bookings
for each row execute function public.nexlab_booking_history_trigger_v26150();

-- Backfill seguro das estruturas existentes.
insert into public.bookings (
  tipo, titulo, descricao, finalidade, inicio, fim, formato,
  espaco_id, espaco_nome_snapshot, responsavel_id,
  responsavel_nome_snapshot, responsavel_perfil_snapshot,
  recursos, status, exige_aprovacao, source_table, legacy_id,
  reviewed_by, reviewed_at, review_note, created_by, created_at
)
select
  'reserva', coalesce(nullif(btrim(r.titulo), ''), 'Reserva de sala'),
  nullif(btrim(r.descricao), ''), nullif(btrim(r.finalidade), ''),
  ((r.data::text || ' ' || r.hora_inicio::text)::timestamp at time zone 'America/Fortaleza'),
  ((r.data::text || ' ' || r.hora_fim::text)::timestamp at time zone 'America/Fortaleza'),
  'presencial', s.id, coalesce(nullif(btrim(r.sala_nome), ''), s.nome, 'Sala principal'),
  r.usuario_id, coalesce(nullif(btrim(p.nome), ''), 'Usuário removido'), lower(coalesce(p.role::text, '')),
  nullif(btrim(r.recursos), ''), lower(coalesce(r.status, 'pendente')), true,
  'reservations', r.id, r.reviewed_by, r.reviewed_at, r.review_note,
  r.usuario_id, r.created_at
from public.reservations r
left join public.profiles p on p.id = r.usuario_id
left join public.spaces s on lower(btrim(s.nome)) = lower(btrim(coalesce(r.sala_nome, 'Sala principal')))
on conflict (source_table, legacy_id) where source_table is not null and legacy_id is not null do nothing;

insert into public.bookings (
  tipo, titulo, descricao, pauta, inicio, fim, formato,
  espaco_id, espaco_nome_snapshot, responsavel_id,
  responsavel_nome_snapshot, responsavel_perfil_snapshot,
  equipe_id, link_online, status, exige_aprovacao,
  source_table, legacy_id, created_by, created_at
)
select
  'reuniao', coalesce(nullif(btrim(m.titulo), ''), 'Reunião'),
  nullif(btrim(m.descricao), ''), nullif(btrim(m.descricao), ''),
  ((m.data::text || ' ' || coalesce(m.hora, time '00:00')::text)::timestamp at time zone 'America/Fortaleza'),
  ((m.data::text || ' ' || coalesce(m.hora, time '00:00')::text)::timestamp at time zone 'America/Fortaleza') + interval '60 minutes',
  case when nullif(btrim(m.link), '') is not null and nullif(btrim(m.local), '') is not null then 'hibrido'
       when nullif(btrim(m.link), '') is not null then 'online' else 'presencial' end,
  s.id, nullif(btrim(m.local), ''), m.autor_id,
  coalesce(nullif(btrim(p.nome), ''), 'Usuário removido'), lower(coalesce(p.role::text, '')),
  m.team_id, nullif(btrim(m.link), ''), lower(coalesce(m.status, 'agendada')), false,
  'meetings', m.id, m.autor_id, m.created_at
from public.meetings m
left join public.profiles p on p.id = m.autor_id
left join public.spaces s on lower(btrim(s.nome)) = lower(btrim(m.local))
on conflict (source_table, legacy_id) where source_table is not null and legacy_id is not null do nothing;

insert into public.booking_participants (booking_id, user_id, user_name_snapshot, user_role_snapshot, created_by, created_at)
select b.id, rp.user_id, coalesce(nullif(btrim(p.nome), ''), 'Usuário removido'), lower(coalesce(p.role::text, '')), rp.created_by, rp.created_at
from public.reservation_participants rp
join public.bookings b on b.source_table = 'reservations' and b.legacy_id = rp.reservation_id
left join public.profiles p on p.id = rp.user_id
on conflict (booking_id, user_id) where user_id is not null do nothing;

insert into public.booking_participants (booking_id, user_id, user_name_snapshot, user_role_snapshot, created_by, created_at)
select b.id, mp.user_id, coalesce(nullif(btrim(p.nome), ''), 'Usuário removido'), lower(coalesce(p.role::text, '')), mp.created_by, mp.created_at
from public.meeting_participants mp
join public.bookings b on b.source_table = 'meetings' and b.legacy_id = mp.meeting_id
left join public.profiles p on p.id = mp.user_id
on conflict (booking_id, user_id) where user_id is not null do nothing;
