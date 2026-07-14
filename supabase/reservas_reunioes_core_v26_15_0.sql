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
