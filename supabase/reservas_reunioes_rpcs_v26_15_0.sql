-- NEXLAB v26.15.0 — RPCs transacionais para Reservas e Reuniões

create or replace function public.nexlab_replace_legacy_participants_v26150(
  p_kind text,
  p_record_id uuid,
  p_user_ids uuid[],
  p_notify boolean default true
)
returns uuid[]
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  normalized_ids uuid[] := '{}'::uuid[];
  participant_id uuid;
  record_title text;
begin
  if p_kind not in ('reservation','meeting') then
    raise exception 'Tipo de agendamento inválido.' using errcode='22023';
  end if;

  select coalesce(array_agg(distinct p.id order by p.id), '{}'::uuid[])
    into normalized_ids
  from public.profiles p
  where p.ativo is distinct from false
    and p.id = any(coalesce(p_user_ids, '{}'::uuid[]));

  if p_kind = 'reservation' then
    select coalesce(r.titulo, 'Reserva de sala') into record_title
    from public.reservations r where r.id = p_record_id;
    if record_title is null then raise exception 'Reserva não encontrada.' using errcode='P0002'; end if;
    delete from public.reservation_participants where reservation_id = p_record_id;
    insert into public.reservation_participants(reservation_id,user_id,created_by)
    select p_record_id, unnest(normalized_ids), auth.uid()
    on conflict do nothing;
  else
    select coalesce(m.titulo, 'Reunião') into record_title
    from public.meetings m where m.id = p_record_id;
    if record_title is null then raise exception 'Reunião não encontrada.' using errcode='P0002'; end if;
    delete from public.meeting_participants where meeting_id = p_record_id;
    insert into public.meeting_participants(meeting_id,user_id,created_by)
    select p_record_id, unnest(normalized_ids), auth.uid()
    on conflict do nothing;
  end if;

  if p_notify then
    foreach participant_id in array normalized_ids loop
      if participant_id is distinct from auth.uid() then
        perform public.nexlab_notify_selected_participant(
          participant_id::text,
          case when p_kind='reservation' then 'reservation_created' else 'system' end,
          case when p_kind='reservation' then 'Você foi incluído em uma reserva' else 'Você foi incluído em uma reunião' end,
          format('%s: %s', case when p_kind='reservation' then 'Reserva' else 'Reunião' end, record_title),
          case when p_kind='reservation' then 'reservation' else 'meeting' end,
          p_record_id::text,
          format('%s-participant:%s:%s', p_kind, p_record_id, participant_id)
        );
      end if;
    end loop;
  end if;

  return normalized_ids;
end;
$$;
revoke all on function public.nexlab_replace_legacy_participants_v26150(text,uuid,uuid[],boolean) from public, anon, authenticated;
grant execute on function public.nexlab_replace_legacy_participants_v26150(text,uuid,uuid[],boolean) to service_role;
