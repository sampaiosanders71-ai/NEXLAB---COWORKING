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
