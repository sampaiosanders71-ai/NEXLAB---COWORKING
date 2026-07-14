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
