-- NEXLAB v26.15.0 — SQL consolidado das quatro primeiras correções de Reservas e Reuniões
-- ATENÇÃO: este conteúdo já foi aplicado ao projeto Supabase Nexlab em 13/07/2026.
-- Não execute novamente no projeto atual. Use apenas como backup ou em um projeto novo compatível.

-- NEXLAB v26.15.0 — Núcleo unificado de Reservas e Reuniões
-- Aplicar no projeto Supabase Nexlab. Esta migration é compatível com as tabelas legadas.

create table if not exists public.spaces (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  codigo text,
  localizacao text,
  capacidade integer,
  ativo boolean not null default true,
  exige_aprovacao boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint spaces_nome_length_check check (char_length(btrim(nome)) between 2 and 150),
  constraint spaces_codigo_length_check check (codigo is null or char_length(btrim(codigo)) between 1 and 50),
  constraint spaces_capacidade_check check (capacidade is null or capacidade > 0)
);

create unique index if not exists spaces_nome_normalized_uq
  on public.spaces (lower(btrim(nome)));
create unique index if not exists spaces_codigo_normalized_uq
  on public.spaces (lower(btrim(codigo)))
  where nullif(btrim(codigo), '') is not null;

insert into public.spaces (nome, codigo, localizacao, ativo, exige_aprovacao)
select 'Sala principal', 'SALA-PRINCIPAL', 'Coworking Space UEMA Timon', true, true
where not exists (
  select 1 from public.spaces where lower(btrim(nome)) = lower('Sala principal')
);

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  tipo text not null,
  titulo text not null,
  descricao text,
  finalidade text,
  pauta text,
  inicio timestamptz not null,
  fim timestamptz not null,
  formato text not null default 'presencial',
  espaco_id uuid references public.spaces(id) on delete set null,
  espaco_nome_snapshot text,
  responsavel_id uuid references public.profiles(id) on delete set null,
  responsavel_nome_snapshot text not null,
  responsavel_perfil_snapshot text,
  equipe_id uuid references public.teams(id) on delete set null,
  link_online text,
  recursos text,
  status text not null,
  exige_aprovacao boolean not null default false,
  source_table text,
  legacy_id uuid,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  review_note text,
  cancelled_by uuid references public.profiles(id) on delete set null,
  cancelled_at timestamptz,
  cancellation_reason text,
  archived_by uuid references public.profiles(id) on delete set null,
  archived_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  constraint bookings_type_check check (tipo in ('reserva', 'reuniao')),
  constraint bookings_status_check check (status in ('pendente','aprovada','recusada','agendada','cancelada','concluida','arquivada')),
  constraint bookings_format_check check (formato in ('presencial','online','hibrido')),
  constraint bookings_source_check check (source_table is null or source_table in ('reservations','meetings')),
  constraint bookings_time_check check (fim > inicio),
  constraint bookings_title_length_check check (char_length(btrim(titulo)) between 2 and 150),
  constraint bookings_description_length_check check (descricao is null or char_length(descricao) <= 2000),
  constraint bookings_purpose_length_check check (finalidade is null or char_length(finalidade) <= 150),
  constraint bookings_agenda_length_check check (pauta is null or char_length(pauta) <= 2000),
  constraint bookings_resources_length_check check (recursos is null or char_length(recursos) <= 500),
  constraint bookings_review_note_length_check check (review_note is null or char_length(review_note) <= 500),
  constraint bookings_cancel_reason_length_check check (cancellation_reason is null or char_length(cancellation_reason) <= 500),
  constraint bookings_link_check check (link_online is null or btrim(link_online) = '' or link_online ~* '^https?://'),
  constraint bookings_legacy_pair_check check ((source_table is null and legacy_id is null) or (source_table is not null and legacy_id is not null))
);

create unique index if not exists bookings_legacy_pair_uq
  on public.bookings (source_table, legacy_id)
  where source_table is not null and legacy_id is not null;
create index if not exists bookings_start_status_idx on public.bookings (inicio, status);
create index if not exists bookings_space_start_idx on public.bookings (espaco_id, inicio, fim) where espaco_id is not null;
create index if not exists bookings_owner_start_idx on public.bookings (responsavel_id, inicio desc);
create index if not exists bookings_type_start_idx on public.bookings (tipo, inicio);

create table if not exists public.booking_participants (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  user_name_snapshot text not null,
  user_role_snapshot text,
  status text not null default 'convidado',
  created_by uuid references public.profiles(id) on delete set null,
  responded_at timestamptz,
  response_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint booking_participants_status_check check (status in ('convidado','confirmado','recusado')),
  constraint booking_participants_name_length_check check (char_length(btrim(user_name_snapshot)) between 1 and 200),
  constraint booking_participants_response_note_length_check check (response_note is null or char_length(response_note) <= 500)
);
create unique index if not exists booking_participants_pair_uq
  on public.booking_participants (booking_id, user_id)
  where user_id is not null;
create index if not exists booking_participants_user_idx on public.booking_participants (user_id) where user_id is not null;

create table if not exists public.booking_resources (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  resource_name text not null,
  quantity integer not null default 1,
  notes text,
  created_at timestamptz not null default now(),
  constraint booking_resources_name_length_check check (char_length(btrim(resource_name)) between 1 and 150),
  constraint booking_resources_quantity_check check (quantity > 0),
  constraint booking_resources_notes_length_check check (notes is null or char_length(notes) <= 500)
);
create unique index if not exists booking_resources_pair_uq
  on public.booking_resources (booking_id, lower(btrim(resource_name)));

create table if not exists public.booking_history (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  action text not null,
  actor_id uuid references public.profiles(id) on delete set null,
  actor_name_snapshot text,
  reason text,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now(),
  constraint booking_history_action_length_check check (char_length(btrim(action)) between 2 and 80),
  constraint booking_history_reason_length_check check (reason is null or char_length(reason) <= 500)
);
create index if not exists booking_history_booking_created_idx on public.booking_history (booking_id, created_at desc);
create index if not exists booking_history_actor_idx on public.booking_history (actor_id) where actor_id is not null;

create or replace function public.nexlab_touch_booking_updated_at_v26150()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  if tg_table_name = 'bookings' then
    new.version := coalesce(old.version, 0) + 1;
    new.updated_by := coalesce(auth.uid(), new.updated_by, old.updated_by);
  end if;
  return new;
end;
$$;

revoke all on function public.nexlab_touch_booking_updated_at_v26150() from public, anon, authenticated;

drop trigger if exists spaces_touch_updated_at_v26150 on public.spaces;
create trigger spaces_touch_updated_at_v26150
before update on public.spaces
for each row execute function public.nexlab_touch_booking_updated_at_v26150();

drop trigger if exists bookings_touch_updated_at_v26150 on public.bookings;
create trigger bookings_touch_updated_at_v26150
before update on public.bookings
for each row execute function public.nexlab_touch_booking_updated_at_v26150();

drop trigger if exists booking_participants_touch_updated_at_v26150 on public.booking_participants;
create trigger booking_participants_touch_updated_at_v26150
before update on public.booking_participants
for each row execute function public.nexlab_touch_booking_updated_at_v26150();

alter table public.spaces enable row level security;
alter table public.bookings enable row level security;
alter table public.booking_participants enable row level security;
alter table public.booking_resources enable row level security;
alter table public.booking_history enable row level security;
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
-- NEXLAB v26.15.0 — RLS e privilégios de Reservas e Reuniões
-- Já aplicado ao projeto Nexlab. Não executar novamente no mesmo projeto.

alter table public.reservations enable row level security;
alter table public.meetings enable row level security;
alter table public.reservation_participants enable row level security;
alter table public.meeting_participants enable row level security;

drop policy if exists "edita reservas" on public.reservations;
drop policy if exists "exclui reservas" on public.reservations;
drop policy if exists "todos criam reservas" on public.reservations;
drop policy if exists "todos veem reservas" on public.reservations;
drop policy if exists reservations_pending_center_insert on public.reservations;
drop policy if exists reservations_pending_center_select on public.reservations;
drop policy if exists reservations_pending_center_update on public.reservations;
drop policy if exists nexlab_approved_account_gate on public.reservations;
drop policy if exists reservations_v26150_approved_gate on public.reservations;
drop policy if exists reservations_v26150_select on public.reservations;
create policy reservations_v26150_approved_gate on public.reservations as restrictive for all to authenticated using (public.nexlab_has_approved_access()) with check (public.nexlab_has_approved_access());
create policy reservations_v26150_select on public.reservations for select to authenticated using (public.nexlab_has_effective_permission_v2680('module_reserva'));

drop policy if exists "cria avisos" on public.meetings;
drop policy if exists "edita avisos" on public.meetings;
drop policy if exists "exclui avisos" on public.meetings;
drop policy if exists meetings_v256_insert on public.meetings;
drop policy if exists meetings_v256_update on public.meetings;
drop policy if exists "ve avisos" on public.meetings;
drop policy if exists nexlab_approved_account_gate on public.meetings;
drop policy if exists meetings_v26150_approved_gate on public.meetings;
drop policy if exists meetings_v26150_select on public.meetings;
create policy meetings_v26150_approved_gate on public.meetings as restrictive for all to authenticated using (public.nexlab_has_approved_access()) with check (public.nexlab_has_approved_access());
create policy meetings_v26150_select on public.meetings for select to authenticated using (public.nexlab_can_view_meeting_v2690(id));

drop policy if exists reservation_participants_select on public.reservation_participants;
drop policy if exists reservation_participants_insert on public.reservation_participants;
drop policy if exists reservation_participants_delete on public.reservation_participants;
drop policy if exists nexlab_approved_account_gate on public.reservation_participants;
drop policy if exists reservation_participants_v26150_gate on public.reservation_participants;
drop policy if exists reservation_participants_v26150_select on public.reservation_participants;
create policy reservation_participants_v26150_gate on public.reservation_participants as restrictive for all to authenticated using (public.nexlab_has_approved_access()) with check (public.nexlab_has_approved_access());
create policy reservation_participants_v26150_select on public.reservation_participants for select to authenticated using (public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or user_id=auth.uid() or exists(select 1 from public.reservations r where r.id=reservation_id and r.usuario_id=auth.uid())));

drop policy if exists meeting_participants_select on public.meeting_participants;
drop policy if exists meeting_participants_insert on public.meeting_participants;
drop policy if exists meeting_participants_delete on public.meeting_participants;
drop policy if exists nexlab_approved_account_gate on public.meeting_participants;
drop policy if exists meeting_participants_v26150_gate on public.meeting_participants;
drop policy if exists meeting_participants_v26150_select on public.meeting_participants;
create policy meeting_participants_v26150_gate on public.meeting_participants as restrictive for all to authenticated using (public.nexlab_has_approved_access()) with check (public.nexlab_has_approved_access());
create policy meeting_participants_v26150_select on public.meeting_participants for select to authenticated using (public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or user_id=auth.uid() or exists(select 1 from public.meetings m where m.id=meeting_id and m.autor_id=auth.uid())));

-- Tabelas do núcleo unificado.
drop policy if exists spaces_v26150_select on public.spaces;
create policy spaces_v26150_select on public.spaces for select to authenticated using (public.nexlab_has_approved_access() and public.nexlab_has_effective_permission_v2680('module_reserva'));
drop policy if exists bookings_v26150_select on public.bookings;
create policy bookings_v26150_select on public.bookings for select to authenticated using (public.nexlab_has_approved_access() and public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or responsavel_id=auth.uid()));
drop policy if exists booking_participants_v26150_select on public.booking_participants;
create policy booking_participants_v26150_select on public.booking_participants for select to authenticated using (public.nexlab_has_approved_access() and public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or user_id=auth.uid() or exists(select 1 from public.bookings b where b.id=booking_id and b.responsavel_id=auth.uid())));
drop policy if exists booking_resources_v26150_select on public.booking_resources;
create policy booking_resources_v26150_select on public.booking_resources for select to authenticated using (exists(select 1 from public.bookings b where b.id=booking_id and public.nexlab_has_approved_access() and public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or b.responsavel_id=auth.uid())));
drop policy if exists booking_history_v26150_select on public.booking_history;
create policy booking_history_v26150_select on public.booking_history for select to authenticated using (exists(select 1 from public.bookings b where b.id=booking_id and public.nexlab_has_approved_access() and public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or b.responsavel_id=auth.uid())));

revoke all on public.reservations,public.meetings,public.reservation_participants,public.meeting_participants from anon;
revoke insert,update,delete,truncate,references,trigger on public.reservations,public.meetings,public.reservation_participants,public.meeting_participants from authenticated;
grant select on public.reservations,public.meetings,public.reservation_participants,public.meeting_participants to authenticated;

revoke all on public.spaces,public.bookings,public.booking_participants,public.booking_resources,public.booking_history from anon;
revoke insert,update,delete,truncate,references,trigger on public.spaces,public.bookings,public.booking_participants,public.booking_resources,public.booking_history from authenticated;
grant select on public.spaces,public.bookings,public.booking_participants,public.booking_resources,public.booking_history to authenticated;

revoke all on function public.replace_reservation_participants(text,text[]) from public,anon,authenticated;
revoke all on function public.replace_meeting_participants(text,text[]) from public,anon,authenticated;
revoke all on function public.cancel_reservation_secure(uuid) from public,anon,authenticated;
revoke all on function public.nexlab_review_reservation_v2690(uuid,text,text,text) from public,anon,authenticated;
revoke all on function public.notifications_reservation_trigger() from public,anon,authenticated;
revoke all on function public.prevent_reservation_time_conflict() from public,anon,authenticated;
revoke all on function public.nexlab_sync_reservation_owner_v2690() from public,anon,authenticated;
grant execute on function public.cancel_reservation_secure(uuid) to service_role;
grant execute on function public.nexlab_review_reservation_v2690(uuid,text,text,text) to service_role;
