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
