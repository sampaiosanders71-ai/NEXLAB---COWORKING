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
-- NEXLAB v26.17.0 — interface final de Reservas e Reuniões

alter table public.meetings add column if not exists pauta text;

alter table public.meetings drop constraint if exists meetings_pauta_length_v26170;
alter table public.meetings add constraint meetings_pauta_length_v26170
  check (pauta is null or char_length(pauta) <= 2000);

create index if not exists bookings_visible_day_idx_v26170
  on public.bookings (((inicio at time zone 'America/Fortaleza')::date), inicio, id)
  where archived_at is null;

create index if not exists bookings_responsavel_day_idx_v26170
  on public.bookings (responsavel_id, inicio desc, id)
  where archived_at is null;

create index if not exists bookings_status_day_idx_v26170
  on public.bookings (status, inicio, id)
  where archived_at is null;

create or replace function public.nexlab_list_bookings_v26170(
  p_scope text default 'upcoming',
  p_type text default 'all',
  p_status text default 'all',
  p_search text default null,
  p_date_from date default null,
  p_date_to date default null,
  p_page integer default 1,
  p_page_size integer default 6
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  uid uuid:=auth.uid();
  scope_name text:=lower(btrim(coalesce(p_scope,'upcoming')));
  type_name text:=lower(btrim(coalesce(p_type,'all')));
  status_name text:=lower(btrim(coalesce(p_status,'all')));
  search_text text:=nullif(lower(btrim(coalesce(p_search,''))),'');
  page_no integer:=greatest(coalesce(p_page,1),1);
  page_size integer:=least(greatest(coalesce(p_page_size,6),1),12);
  manager boolean:=false;
  result_groups jsonb:='[]'::jsonb;
  result_spaces jsonb:='[]'::jsonb;
  total_days integer:=0;
  total_items integer:=0;
  metrics jsonb:='{}'::jsonb;
begin
  if uid is null or not public.nexlab_has_approved_access()
     or not public.nexlab_has_effective_permission_v2680('module_reserva') then
    raise exception 'Você não possui acesso a Reservas e Reuniões.' using errcode='42501';
  end if;

  if scope_name not in ('upcoming','mine','pending','history') then
    raise exception 'Escopo de consulta inválido.' using errcode='22023';
  end if;
  if type_name not in ('all','reserva','reuniao') then
    raise exception 'Tipo de agendamento inválido.' using errcode='22023';
  end if;

  manager:=public.nexlab_is_gestor();

  with visible as (
    select b.*,
           (b.inicio at time zone 'America/Fortaleza')::date as day_key,
           exists(select 1 from public.booking_participants bp where bp.booking_id=b.id and bp.user_id=uid) as is_participant
    from public.bookings b
    where b.tipo='reserva' or manager or b.responsavel_id=uid
       or exists(select 1 from public.booking_participants bp where bp.booking_id=b.id and bp.user_id=uid)
       or (b.tipo='reuniao' and b.legacy_id is not null and public.nexlab_can_view_meeting_v2690(b.legacy_id))
  ), filtered as (
    select v.*
    from visible v
    where
      case scope_name
        when 'upcoming' then v.archived_at is null and v.fim >= now()
          and lower(v.status) not in ('cancelada','recusada','arquivada','concluida','concluído','concluída')
        when 'mine' then v.responsavel_id=uid and v.archived_at is null
        when 'pending' then lower(v.status)='pendente' and v.archived_at is null and (manager or v.responsavel_id=uid)
        when 'history' then v.archived_at is not null or v.fim < now()
          or lower(v.status) in ('cancelada','recusada','arquivada','concluida','concluído','concluída')
      end
      and (type_name='all' or v.tipo=type_name)
      and (status_name='all' or lower(v.status)=status_name)
      and (p_date_from is null or v.day_key>=p_date_from)
      and (p_date_to is null or v.day_key<=p_date_to)
      and (
        search_text is null
        or lower(v.titulo) like '%'||search_text||'%'
        or lower(coalesce(v.descricao,'')) like '%'||search_text||'%'
        or lower(coalesce(v.finalidade,'')) like '%'||search_text||'%'
        or lower(coalesce(v.pauta,'')) like '%'||search_text||'%'
        or lower(coalesce(v.espaco_nome_snapshot,'')) like '%'||search_text||'%'
        or lower(coalesce(v.responsavel_nome_snapshot,'')) like '%'||search_text||'%'
        or lower(coalesce(v.recursos,'')) like '%'||search_text||'%'
      )
  ), day_list as (
    select distinct day_key from filtered
  ), page_days as (
    select day_key
    from day_list
    order by
      case when scope_name='history' then day_key end desc,
      case when scope_name<>'history' then day_key end asc
    offset (page_no-1)*page_size limit page_size
  )
  select
    (select count(*)::integer from day_list),
    (select count(*)::integer from filtered),
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'date',pd.day_key,
          'count',(select count(*) from filtered f where f.day_key=pd.day_key),
          'items',(
            select coalesce(jsonb_agg(
              jsonb_strip_nulls(jsonb_build_object(
                'booking_id',f.id,
                'legacy_id',f.legacy_id,
                'source_table',f.source_table,
                'type',f.tipo,
                'title',f.titulo,
                'description',f.descricao,
                'purpose',f.finalidade,
                'agenda',f.pauta,
                'start_at',f.inicio,
                'end_at',f.fim,
                'format',f.formato,
                'space_id',f.espaco_id,
                'space_name',f.espaco_nome_snapshot,
                'owner_id',f.responsavel_id,
                'owner_name',f.responsavel_nome_snapshot,
                'owner_role',f.responsavel_perfil_snapshot,
                'team_id',f.equipe_id,
                'online_link',f.link_online,
                'resources',f.recursos,
                'status',f.status,
                'requires_approval',f.exige_aprovacao,
                'review_note',case when manager or f.responsavel_id=uid then f.review_note else null end,
                'cancel_reason',case when manager or f.responsavel_id=uid then f.cancellation_reason else null end,
                'archived_at',f.archived_at,
                'created_at',f.created_at,
                'is_owner',f.responsavel_id=uid,
                'can_manage',manager,
                'participant_count',(select count(*) from public.booking_participants bp where bp.booking_id=f.id),
                'participant_names',(
                  select coalesce(jsonb_agg(bp.user_name_snapshot order by bp.user_name_snapshot),'[]'::jsonb)
                  from public.booking_participants bp where bp.booking_id=f.id
                )
              )) order by f.inicio,f.id
            ),'[]'::jsonb)
            from filtered f where f.day_key=pd.day_key
          )
        ) order by
          case when scope_name='history' then pd.day_key end desc,
          case when scope_name<>'history' then pd.day_key end asc
      ) from page_days pd
    ),'[]'::jsonb)
  into total_days,total_items,result_groups;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',s.id,'name',s.nome,'code',s.codigo,'location',s.localizacao,
    'capacity',s.capacidade,'requires_approval',s.exige_aprovacao
  ) order by s.nome),'[]'::jsonb)
  into result_spaces
  from public.spaces s where s.ativo is true;

  with visible as (
    select b.* from public.bookings b
    where b.tipo='reserva' or manager or b.responsavel_id=uid
       or exists(select 1 from public.booking_participants bp where bp.booking_id=b.id and bp.user_id=uid)
       or (b.tipo='reuniao' and b.legacy_id is not null and public.nexlab_can_view_meeting_v2690(b.legacy_id))
  )
  select jsonb_build_object(
    'upcoming',count(*) filter(where archived_at is null and fim>=now() and lower(status) not in ('cancelada','recusada','arquivada','concluida','concluído','concluída')),
    'mine',count(*) filter(where responsavel_id=uid and archived_at is null),
    'pending',count(*) filter(where lower(status)='pendente' and archived_at is null and (manager or responsavel_id=uid)),
    'history',count(*) filter(where archived_at is not null or fim<now() or lower(status) in ('cancelada','recusada','arquivada','concluida','concluído','concluída'))
  ) into metrics from visible;

  return jsonb_build_object(
    'ok',true,
    'scope',scope_name,
    'groups',result_groups,
    'spaces',result_spaces,
    'metrics',metrics,
    'pagination',jsonb_build_object(
      'page',page_no,'page_size',page_size,'total_days',total_days,
      'total_items',total_items,'has_more',page_no*page_size<total_days
    ),
    'generated_at',now()
  );
end;
$$;

revoke all on function public.nexlab_list_bookings_v26170(text,text,text,text,date,date,integer,integer) from public,anon;
grant execute on function public.nexlab_list_bookings_v26170(text,text,text,text,date,date,integer,integer) to authenticated,service_role;

create or replace function public.nexlab_resolve_booking_target_v26170(p_kind text,p_legacy_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare uid uuid:=auth.uid(); row_data public.bookings%rowtype; manager boolean:=false;
begin
  if uid is null or not public.nexlab_has_approved_access()
     or not public.nexlab_has_effective_permission_v2680('module_reserva') then
    raise exception 'Você não possui acesso a Reservas e Reuniões.' using errcode='42501';
  end if;
  manager:=public.nexlab_is_gestor();
  select * into row_data from public.bookings b
  where b.legacy_id=p_legacy_id
    and b.source_table=case lower(btrim(coalesce(p_kind,''))) when 'meeting' then 'meetings' else 'reservations' end
    and (b.tipo='reserva' or manager or b.responsavel_id=uid
      or exists(select 1 from public.booking_participants bp where bp.booking_id=b.id and bp.user_id=uid)
      or (b.tipo='reuniao' and b.legacy_id is not null and public.nexlab_can_view_meeting_v2690(b.legacy_id)));
  if not found then return jsonb_build_object('ok',false); end if;
  return jsonb_build_object(
    'ok',true,'booking_id',row_data.id,'legacy_id',row_data.legacy_id,
    'type',row_data.tipo,'date',(row_data.inicio at time zone 'America/Fortaleza')::date,
    'scope',case when row_data.archived_at is not null or row_data.fim<now()
      or lower(row_data.status) in ('cancelada','recusada','arquivada','concluida','concluído','concluída') then 'history'
      when lower(row_data.status)='pendente' then 'pending' else 'upcoming' end
  );
end;
$$;
revoke all on function public.nexlab_resolve_booking_target_v26170(text,uuid) from public,anon;
grant execute on function public.nexlab_resolve_booking_target_v26170(text,uuid) to authenticated,service_role;

create or replace function public.nexlab_save_booking_v26170(p_booking_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  uid uuid:=auth.uid();
  payload jsonb:=coalesce(p_payload,'{}'::jsonb);
  kind text:=lower(btrim(coalesce(payload->>'type','')));
  current_booking public.bookings%rowtype;
  legacy_result jsonb;
  legacy_record jsonb;
  legacy_uuid uuid;
  booking_uuid uuid;
  meeting_payload jsonb;
  reservation_payload jsonb;
  format_name text:=lower(btrim(coalesce(payload->>'format','presencial')));
  space_name text:=nullif(btrim(payload->>'space_name'),'');
  meeting_description text;
begin
  if uid is null or not public.nexlab_has_approved_access()
     or not public.nexlab_has_effective_permission_v2680('module_reserva') then
    raise exception 'Você não possui acesso a Reservas e Reuniões.' using errcode='42501';
  end if;

  if p_booking_id is not null then
    select * into current_booking from public.bookings where id=p_booking_id for update;
    if not found then raise exception 'Agendamento não encontrado.' using errcode='P0002'; end if;
    kind:=current_booking.tipo;
  end if;
  if kind not in ('reserva','reuniao') then raise exception 'Escolha Reserva de sala ou Reunião.' using errcode='22023'; end if;

  if kind='reserva' then
    reservation_payload:=jsonb_build_object(
      'titulo',payload->>'title','finalidade',payload->>'purpose','descricao',payload->>'description',
      'data',payload->>'date','hora_inicio',payload->>'start_time','hora_fim',payload->>'end_time',
      'recursos',payload->>'resources','sala_nome',coalesce(space_name,'Sala principal'),
      'participant_ids',coalesce(payload->'participant_ids','[]'::jsonb)
    );
    if p_booking_id is null then
      legacy_result:=public.nexlab_create_reservation_v26160(reservation_payload);
    else
      if current_booking.source_table<>'reservations' or current_booking.legacy_id is null then
        raise exception 'A reserva não possui vínculo legado válido.' using errcode='P0001';
      end if;
      legacy_result:=public.nexlab_update_reservation_v26160(current_booking.legacy_id,reservation_payload);
      if payload ? 'participant_ids' then
        perform public.nexlab_replace_legacy_participants_v26150(
          'reservation',current_booking.legacy_id,
          coalesce((select array_agg(distinct value::uuid) from jsonb_array_elements_text(payload->'participant_ids')),'{}'::uuid[])
        );
      end if;
    end if;
    legacy_record:=legacy_result->'reservation';
    legacy_uuid:=(legacy_record->>'id')::uuid;
    select id into booking_uuid from public.bookings where source_table='reservations' and legacy_id=legacy_uuid;
  else
    if not public.nexlab_is_gestor() then
      raise exception 'Somente Administradores e Coordenadores podem salvar reuniões.' using errcode='42501';
    end if;
    if format_name not in ('presencial','online','hibrido') then raise exception 'Formato da reunião inválido.' using errcode='22023'; end if;
    if format_name in ('online','hibrido') and nullif(btrim(payload->>'online_link'),'') is null then
      raise exception 'Informe o link da reunião online.' using errcode='22023';
    end if;
    if format_name in ('presencial','hibrido') and space_name is null then
      raise exception 'Escolha o espaço da reunião.' using errcode='22023';
    end if;
    meeting_description:=coalesce(nullif(btrim(payload->>'description'),''),nullif(btrim(payload->>'agenda'),''));
    meeting_payload:=jsonb_build_object(
      'titulo',payload->>'title','descricao',meeting_description,'data',payload->>'date',
      'hora',payload->>'start_time','hora_fim',payload->>'end_time',
      'local',case when format_name='online' then null else space_name end,
      'link',case when format_name='presencial' then null else payload->>'online_link' end,
      'participant_ids',coalesce(payload->'participant_ids','[]'::jsonb)
    );
    if p_booking_id is null then
      legacy_result:=public.nexlab_create_meeting_v26160(meeting_payload);
    else
      if current_booking.source_table<>'meetings' or current_booking.legacy_id is null then
        raise exception 'A reunião não possui vínculo legado válido.' using errcode='P0001';
      end if;
      legacy_result:=public.nexlab_update_meeting_v26160(current_booking.legacy_id,meeting_payload);
    end if;
    legacy_record:=legacy_result->'meeting';
    legacy_uuid:=(legacy_record->>'id')::uuid;
    update public.meetings set pauta=nullif(btrim(payload->>'agenda'),'') where id=legacy_uuid;
    update public.bookings set pauta=nullif(btrim(payload->>'agenda'),''),formato=format_name,
      link_online=case when format_name='presencial' then null else nullif(btrim(payload->>'online_link'),'') end,
      updated_by=uid where source_table='meetings' and legacy_id=legacy_uuid returning id into booking_uuid;
  end if;

  return jsonb_build_object(
    'ok',true,'booking_id',booking_uuid,'legacy_id',legacy_uuid,'type',kind,
    'record',legacy_record,
    'details',public.nexlab_get_booking_details_v26160(kind,legacy_uuid)
  );
exception when exclusion_violation then
  raise exception 'Este espaço já possui uma reserva ou reunião no período informado.' using errcode='23P01';
end;
$$;
revoke all on function public.nexlab_save_booking_v26170(uuid,jsonb) from public,anon;
grant execute on function public.nexlab_save_booking_v26170(uuid,jsonb) to authenticated,service_role;

update public.notifications
set target_tab='reserva', updated_at=now()
where entity_type in ('reservation','meeting') and target_tab is distinct from 'reserva';


-- Limpeza do contexto temporário da expiração para não contaminar o próximo histórico.
create or replace function public.nexlab_expire_pending_bookings_v26160()
returns integer
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare affected integer:=0;
begin
  perform set_config('nexlab.booking_cancel_reason','Solicitação expirada automaticamente.',true);
  perform set_config('nexlab.booking_action_reason','Solicitação expirada automaticamente.',true);
  update public.reservations r
  set status='cancelada',cancelled_at=coalesce(r.cancelled_at,now()),
      cancellation_reason=coalesce(r.cancellation_reason,'Solicitação expirada automaticamente.')
  where r.id in(
    select b.legacy_id from public.bookings b
    where b.source_table='reservations' and b.status='pendente'
      and b.hold_expires_at is not null and b.hold_expires_at<=now() and b.legacy_id is not null
  );
  get diagnostics affected=row_count;
  perform set_config('nexlab.booking_cancel_reason','',true);
  perform set_config('nexlab.booking_action_reason','',true);
  return affected;
exception when others then
  perform set_config('nexlab.booking_cancel_reason','',true);
  perform set_config('nexlab.booking_action_reason','',true);
  raise;
end;
$$;
revoke all on function public.nexlab_expire_pending_bookings_v26160() from public,anon,authenticated;
grant execute on function public.nexlab_expire_pending_bookings_v26160() to service_role;

-- A Agenda geral passa a receber o horário final real das reuniões.
do $do$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='nexlab_get_agenda_range_v2690';
  d:=replace(d,
    $q$'horario', m.hora,
              'duracao_minutos', 60,$q$,
    $q$'horario', m.hora,
              'hora_fim', m.hora_fim,
              'duracao_minutos', greatest(1,coalesce(round(extract(epoch from (m.hora_fim-m.hora))/60)::integer,60)),$q$
  );
  execute d;
end;
$do$;
