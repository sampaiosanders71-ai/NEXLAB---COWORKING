-- NexLab v25.6 — Ações e Exclusões Seguras — Correção de Validação
-- Execute este arquivo completo no SQL Editor do Supabase.
-- Ele é idempotente: pode ser executado novamente para atualizar funções e policies.

begin;

-- -----------------------------------------------------------------------------
-- 1. Funções auxiliares de autorização
-- -----------------------------------------------------------------------------
create or replace function public.nexlab_current_role()
returns text
language sql
stable
security definer
set search_path = public, auth
as $$
  select lower(coalesce(p.role, ''))
  from public.profiles p
  where p.id::text = auth.uid()::text
  limit 1;
$$;

revoke all on function public.nexlab_current_role() from public;
grant execute on function public.nexlab_current_role() to authenticated;

create or replace function public.nexlab_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select public.nexlab_current_role() = 'admin';
$$;

create or replace function public.nexlab_is_gestor()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select public.nexlab_current_role() in ('admin', 'coordenador');
$$;

revoke all on function public.nexlab_is_admin() from public;
revoke all on function public.nexlab_is_gestor() from public;
grant execute on function public.nexlab_is_admin() to authenticated;
grant execute on function public.nexlab_is_gestor() to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Tabelas relacionais de participantes
--    Os tipos das chaves são copiados das tabelas existentes para evitar
--    incompatibilidade entre UUID, bigint ou outro tipo já usado no projeto.
-- -----------------------------------------------------------------------------
do $$
declare
  reservation_id_type text;
  meeting_id_type text;
  profile_id_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
    into reservation_id_type
  from pg_attribute a
  where a.attrelid = 'public.reservations'::regclass
    and a.attname = 'id'
    and a.attnum > 0
    and not a.attisdropped;

  select format_type(a.atttypid, a.atttypmod)
    into meeting_id_type
  from pg_attribute a
  where a.attrelid = 'public.meetings'::regclass
    and a.attname = 'id'
    and a.attnum > 0
    and not a.attisdropped;

  select format_type(a.atttypid, a.atttypmod)
    into profile_id_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'id'
    and a.attnum > 0
    and not a.attisdropped;

  if reservation_id_type is null or meeting_id_type is null or profile_id_type is null then
    raise exception 'Não foi possível identificar os tipos de ID de reservations, meetings ou profiles.';
  end if;

  if to_regclass('public.reservation_participants') is null then
    execute format(
      'create table public.reservation_participants (
         reservation_id %s not null references public.reservations(id) on delete cascade,
         user_id %s not null references public.profiles(id) on delete cascade,
         created_at timestamptz not null default now(),
         created_by uuid null default auth.uid(),
         primary key (reservation_id, user_id)
       )',
      reservation_id_type,
      profile_id_type
    );
  end if;

  if to_regclass('public.meeting_participants') is null then
    execute format(
      'create table public.meeting_participants (
         meeting_id %s not null references public.meetings(id) on delete cascade,
         user_id %s not null references public.profiles(id) on delete cascade,
         created_at timestamptz not null default now(),
         created_by uuid null default auth.uid(),
         primary key (meeting_id, user_id)
       )',
      meeting_id_type,
      profile_id_type
    );
  end if;
end
$$;

create index if not exists reservation_participants_user_id_idx
  on public.reservation_participants (user_id);
create index if not exists meeting_participants_user_id_idx
  on public.meeting_participants (user_id);

alter table public.reservation_participants enable row level security;
alter table public.meeting_participants enable row level security;

grant select, insert, delete on public.reservation_participants to authenticated;
grant select, insert, delete on public.meeting_participants to authenticated;

-- -----------------------------------------------------------------------------
-- 3. RLS dos participantes
-- -----------------------------------------------------------------------------
drop policy if exists reservation_participants_select on public.reservation_participants;
create policy reservation_participants_select
on public.reservation_participants
for select
to authenticated
using (
  public.nexlab_is_gestor()
  or user_id::text = auth.uid()::text
  or exists (
    select 1
    from public.reservations r
    where r.id = reservation_participants.reservation_id
      and r.usuario_id::text = auth.uid()::text
  )
);

drop policy if exists reservation_participants_insert on public.reservation_participants;
create policy reservation_participants_insert
on public.reservation_participants
for insert
to authenticated
with check (
  public.nexlab_is_gestor()
  or exists (
    select 1
    from public.reservations r
    where r.id = reservation_participants.reservation_id
      and r.usuario_id::text = auth.uid()::text
  )
);

drop policy if exists reservation_participants_delete on public.reservation_participants;
create policy reservation_participants_delete
on public.reservation_participants
for delete
to authenticated
using (
  public.nexlab_is_gestor()
  or exists (
    select 1
    from public.reservations r
    where r.id = reservation_participants.reservation_id
      and r.usuario_id::text = auth.uid()::text
  )
);

drop policy if exists meeting_participants_select on public.meeting_participants;
create policy meeting_participants_select
on public.meeting_participants
for select
to authenticated
using (
  public.nexlab_is_gestor()
  or user_id::text = auth.uid()::text
);

drop policy if exists meeting_participants_insert on public.meeting_participants;
create policy meeting_participants_insert
on public.meeting_participants
for insert
to authenticated
with check (public.nexlab_is_gestor());

drop policy if exists meeting_participants_delete on public.meeting_participants;
create policy meeting_participants_delete
on public.meeting_participants
for delete
to authenticated
using (public.nexlab_is_gestor());

-- -----------------------------------------------------------------------------
-- 4. Notificação interna para os participantes selecionados
-- -----------------------------------------------------------------------------
create or replace function public.nexlab_notify_selected_participant(
  p_user_id text,
  p_type text,
  p_title text,
  p_message text,
  p_entity_type text,
  p_entity_id text,
  p_source_key text
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if to_regclass('public.notifications') is null then
    return;
  end if;

  execute $notification$
    insert into public.notifications (
      recipient_id,
      type,
      title,
      message,
      target_tab,
      entity_type,
      source_key
    )
    select
      p.id,
      $2,
      $3,
      $4,
      'reserva',
      $5,
      $6
    from public.profiles p
    where p.id::text = $1
      and coalesce(p.ativo, true)
      and not exists (
        select 1
        from public.notifications n
        where n.source_key = $6
          and n.recipient_id::text = $1
      )
  $notification$
  using p_user_id, p_type, p_title, p_message, p_entity_type, p_source_key;
end;
$$;

revoke all on function public.nexlab_notify_selected_participant(text, text, text, text, text, text, text) from public;

-- -----------------------------------------------------------------------------
-- 5. Substituição atômica dos participantes de uma reserva
-- -----------------------------------------------------------------------------
create or replace function public.replace_reservation_participants(
  p_reservation_id text,
  p_user_ids text[] default array[]::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  reservation_owner text;
  reservation_title text;
  user_id_text text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.' using errcode = '42501';
  end if;

  execute
    'select usuario_id::text, coalesce(titulo, ''Reserva de sala'') from public.reservations where id::text = $1'
    into reservation_owner, reservation_title
    using p_reservation_id;

  if reservation_owner is null then
    raise exception 'Reserva não encontrada.' using errcode = 'P0002';
  end if;

  if not public.nexlab_is_gestor() and reservation_owner <> auth.uid()::text then
    raise exception 'Sem permissão para alterar os participantes desta reserva.' using errcode = '42501';
  end if;

  execute 'delete from public.reservation_participants where reservation_id::text = $1'
    using p_reservation_id;

  foreach user_id_text in array coalesce(p_user_ids, array[]::text[])
  loop
    execute $insert_participant$
      insert into public.reservation_participants (reservation_id, user_id, created_by)
      select r.id, p.id, auth.uid()
      from public.reservations r
      join public.profiles p on p.id::text = $2
      where r.id::text = $1
        and coalesce(p.ativo, true)
      on conflict do nothing
    $insert_participant$
    using p_reservation_id, user_id_text;


    perform public.nexlab_notify_selected_participant(
      user_id_text,
      'reservation_created',
      'Você foi incluído em uma reserva',
      format('Reserva: %s', reservation_title),
      'reservation',
      p_reservation_id,
      format('reservation-participant:%s:%s', p_reservation_id, user_id_text)
    );
  end loop;

  begin
    perform public.record_security_audit(
      'reservation_participants_replaced',
      null,
      jsonb_build_object(
        'reservation_id', p_reservation_id,
        'participant_ids', coalesce(p_user_ids, array[]::text[]),
        'participant_count', coalesce(array_length(p_user_ids, 1), 0),
        'module', 'reserva'
      )
    );
  exception when undefined_function then
    null;
  end;

  return jsonb_build_object(
    'reservation_id', p_reservation_id,
    'participant_ids', coalesce(p_user_ids, array[]::text[]),
    'participant_count', coalesce(array_length(p_user_ids, 1), 0)
  );
end;
$$;

revoke all on function public.replace_reservation_participants(text, text[]) from public;
grant execute on function public.replace_reservation_participants(text, text[]) to authenticated;

-- -----------------------------------------------------------------------------
-- 6. Substituição atômica dos participantes de uma reunião
-- -----------------------------------------------------------------------------
create or replace function public.replace_meeting_participants(
  p_meeting_id text,
  p_user_ids text[] default array[]::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  meeting_title text;
  user_id_text text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.' using errcode = '42501';
  end if;

  if not public.nexlab_is_gestor() then
    raise exception 'Apenas Administradores e Coordenadores podem alterar participantes de reuniões.' using errcode = '42501';
  end if;

  execute
    'select coalesce(titulo, ''Reunião'') from public.meetings where id::text = $1'
    into meeting_title
    using p_meeting_id;

  if meeting_title is null then
    raise exception 'Reunião não encontrada.' using errcode = 'P0002';
  end if;

  execute 'delete from public.meeting_participants where meeting_id::text = $1'
    using p_meeting_id;

  foreach user_id_text in array coalesce(p_user_ids, array[]::text[])
  loop
    execute $insert_participant$
      insert into public.meeting_participants (meeting_id, user_id, created_by)
      select m.id, p.id, auth.uid()
      from public.meetings m
      join public.profiles p on p.id::text = $2
      where m.id::text = $1
        and coalesce(p.ativo, true)
      on conflict do nothing
    $insert_participant$
    using p_meeting_id, user_id_text;

    perform public.nexlab_notify_selected_participant(
      user_id_text,
      'system',
      'Você foi incluído em uma reunião',
      format('Reunião: %s', meeting_title),
      'meeting',
      p_meeting_id,
      format('meeting-participant:%s:%s', p_meeting_id, user_id_text)
    );
  end loop;

  begin
    perform public.record_security_audit(
      'meeting_participants_replaced',
      null,
      jsonb_build_object(
        'meeting_id', p_meeting_id,
        'participant_ids', coalesce(p_user_ids, array[]::text[]),
        'participant_count', coalesce(array_length(p_user_ids, 1), 0),
        'module', 'reserva'
      )
    );
  exception when undefined_function then
    null;
  end;

  return jsonb_build_object(
    'meeting_id', p_meeting_id,
    'participant_ids', coalesce(p_user_ids, array[]::text[]),
    'participant_count', coalesce(array_length(p_user_ids, 1), 0)
  );
end;
$$;

revoke all on function public.replace_meeting_participants(text, text[]) from public;
grant execute on function public.replace_meeting_participants(text, text[]) to authenticated;

-- -----------------------------------------------------------------------------
-- 7. Exclusão permanente em lote somente para logs operacionais
-- -----------------------------------------------------------------------------
create or replace function public.admin_delete_activity_logs(
  p_ids text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  deleted_ids jsonb := '[]'::jsonb;
  requested_count integer := coalesce(array_length(p_ids, 1), 0);
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Apenas o Administrador pode excluir logs operacionais.' using errcode = '42501';
  end if;

  if requested_count = 0 then
    return jsonb_build_object('requested_count', 0, 'deleted_count', 0, 'deleted_ids', '[]'::jsonb);
  end if;

  execute $delete_logs$
    with deleted as (
      delete from public.logs
      where id::text = any($1)
      returning id::text as id
    )
    select coalesce(jsonb_agg(id), '[]'::jsonb)
    from deleted
  $delete_logs$
  into deleted_ids
  using p_ids;

  begin
    perform public.record_security_audit(
      'activity_logs_bulk_deleted',
      null,
      jsonb_build_object(
        'requested_ids', p_ids,
        'deleted_ids', deleted_ids,
        'deleted_count', jsonb_array_length(deleted_ids),
        'module', 'logs'
      )
    );
  exception when undefined_function then
    null;
  end;

  return jsonb_build_object(
    'requested_count', requested_count,
    'deleted_count', jsonb_array_length(deleted_ids),
    'deleted_ids', deleted_ids
  );
end;
$$;

revoke all on function public.admin_delete_activity_logs(text[]) from public;
grant execute on function public.admin_delete_activity_logs(text[]) to authenticated;

-- O frontend nunca recebe DELETE direto em security_audit_logs.
revoke delete on public.security_audit_logs from anon, authenticated;

-- -----------------------------------------------------------------------------
-- 8. Proteção de conflito de horário no banco
-- -----------------------------------------------------------------------------
create or replace function public.prevent_reservation_time_conflict()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  conflicting_title text;
  conflicting_start text;
  conflicting_end text;
begin
  if coalesce(new.status, '') in ('cancelada', 'recusada') then
    return new;
  end if;

  if new.hora_fim::time <= new.hora_inicio::time then
    raise exception 'O horário final precisa ser posterior ao horário inicial.' using errcode = '22007';
  end if;

  select
    coalesce(r.titulo, 'Reserva existente'),
    r.hora_inicio::text,
    r.hora_fim::text
  into conflicting_title, conflicting_start, conflicting_end
  from public.reservations r
  where r.data::date = new.data::date
    and r.id::text <> coalesce(new.id::text, '')
    and coalesce(r.status, '') not in ('cancelada', 'recusada')
    and new.hora_inicio::time < r.hora_fim::time
    and new.hora_fim::time > r.hora_inicio::time
  order by r.hora_inicio::time
  limit 1;

  if conflicting_title is not null then
    raise exception 'Conflito com "%" (% - %).', conflicting_title, conflicting_start, conflicting_end
      using errcode = '23P01';
  end if;

  return new;
end;
$$;

drop trigger if exists reservations_prevent_time_conflict on public.reservations;
create trigger reservations_prevent_time_conflict
before insert or update of data, hora_inicio, hora_fim, status
on public.reservations
for each row
execute function public.prevent_reservation_time_conflict();

commit;

-- =============================================================================
-- VALIDAÇÃO APÓS EXECUTAR
-- =============================================================================
-- 1. Confirme as tabelas:
--    select * from public.reservation_participants limit 5;
--    select * from public.meeting_participants limit 5;
-- 2. Confirme as funções:
--    select proname from pg_proc where proname in (
--      'replace_reservation_participants',
--      'replace_meeting_participants',
--      'admin_delete_activity_logs',
--      'prevent_reservation_time_conflict'
--    );
-- 3. Entre no app como Administrador e teste a Central de Atividades.
-- 4. Crie duas reservas sobrepostas: a segunda deve ser rejeitada.
-- 5. Crie reserva/reunião com participantes e confira notifications.
--
-- REVERSÃO (use somente se necessário):
-- drop trigger if exists reservations_prevent_time_conflict on public.reservations;
-- drop function if exists public.prevent_reservation_time_conflict();
-- drop function if exists public.admin_delete_activity_logs(text[]);
-- drop function if exists public.replace_meeting_participants(text, text[]);
-- drop function if exists public.replace_reservation_participants(text, text[]);
-- drop function if exists public.nexlab_notify_selected_participant(text, text, text, text, text, text, text);
-- drop table if exists public.meeting_participants;
-- drop table if exists public.reservation_participants;
-- drop function if exists public.nexlab_is_gestor();
-- drop function if exists public.nexlab_is_admin();
-- drop function if exists public.nexlab_current_role();
