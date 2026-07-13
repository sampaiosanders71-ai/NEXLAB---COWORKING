-- NEXLAB v26.9.0 — Pendências e Agenda, correções 1 a 4
-- 1. Feedback usa titulo/descricao de forma canônica.
-- 2. Reservas preservam recursos/descricao/sala e usam usuario_id como proprietário canônico.
-- 3. Reuniões usam hora e passam a armazenar link online.
-- 4. Participantes selecionados passam a visualizar a reunião correspondente.

begin;

-- ---------------------------------------------------------------------------
-- 1. Feedback: estrutura canônica e integridade mínima
-- ---------------------------------------------------------------------------

update public.feedback
set titulo = 'Feedback sem título'
where btrim(coalesce(titulo, '')) = '';

update public.feedback
set descricao = 'Sem descrição informada.'
where btrim(coalesce(descricao, '')) = '';

alter table public.feedback
  alter column descricao set not null;

alter table public.feedback
  drop constraint if exists feedback_titulo_not_blank_check;

alter table public.feedback
  add constraint feedback_titulo_not_blank_check
  check (btrim(titulo) <> '');

alter table public.feedback
  drop constraint if exists feedback_descricao_not_blank_check;

alter table public.feedback
  add constraint feedback_descricao_not_blank_check
  check (btrim(descricao) <> '');

comment on column public.feedback.titulo
is 'Título canônico do feedback. Substitui o nome antigo assunto no frontend.';

comment on column public.feedback.descricao
is 'Mensagem canônica do feedback. Substitui o nome antigo mensagem no frontend.';

-- ---------------------------------------------------------------------------
-- 2. Reservas: campos usados pela interface e proprietário canônico
-- ---------------------------------------------------------------------------

alter table public.reservations
  add column if not exists recursos text,
  add column if not exists descricao text,
  add column if not exists sala_nome text;

update public.reservations
set usuario_id = coalesce(usuario_id, user_id),
    user_id = coalesce(usuario_id, user_id)
where usuario_id is null
   or user_id is null
   or usuario_id is distinct from user_id;

alter table public.reservations
  alter column usuario_id set default auth.uid();

-- O projeto atual não possui reservas sem proprietário. A validação impede que
-- novos registros voltem a depender apenas do campo legado user_id.
alter table public.reservations
  alter column usuario_id set not null;

create or replace function public.nexlab_sync_reservation_owner_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  new.usuario_id := coalesce(new.usuario_id, new.user_id, auth.uid());

  if new.usuario_id is null then
    raise exception 'A reserva precisa possuir um solicitante.'
      using errcode = '23502';
  end if;

  -- user_id permanece somente como espelho temporário para compatibilidade com
  -- versões antigas. Todas as regras novas usam usuario_id.
  new.user_id := new.usuario_id;
  return new;
end;
$$;

revoke all on function public.nexlab_sync_reservation_owner_v2690()
from public, anon, authenticated;

drop trigger if exists reservations_sync_owner_v2690
on public.reservations;

create trigger reservations_sync_owner_v2690
before insert or update of usuario_id, user_id
on public.reservations
for each row
execute function public.nexlab_sync_reservation_owner_v2690();

comment on column public.reservations.usuario_id
is 'Proprietário canônico da reserva.';

comment on column public.reservations.user_id
is 'Campo legado mantido como espelho de usuario_id para compatibilidade temporária.';

comment on column public.reservations.recursos
is 'Recursos solicitados para a reserva, em texto.';

comment on column public.reservations.descricao
is 'Descrição complementar da reserva.';

comment on column public.reservations.sala_nome
is 'Nome público da sala ou espaço reservado.';

-- Políticas que ainda utilizavam user_id passam a usar o proprietário canônico.
drop policy if exists "edita reservas" on public.reservations;
create policy "edita reservas"
on public.reservations
for update
to public
using (public.is_coord_or_admin())
with check (public.is_coord_or_admin());

-- O proprietário cancela pela RPC cancel_reservation_secure. Exclusão direta
-- continua restrita ao proprietário ou à gestão, usando usuario_id.
drop policy if exists "exclui reservas" on public.reservations;
create policy "exclui reservas"
on public.reservations
for delete
to public
using (
  public.is_coord_or_admin()
  or usuario_id = auth.uid()
);

drop policy if exists "todos criam reservas" on public.reservations;
create policy "todos criam reservas"
on public.reservations
for insert
to public
with check (usuario_id = auth.uid());

drop policy if exists reservations_pending_center_insert on public.reservations;
create policy reservations_pending_center_insert
on public.reservations
for insert
to authenticated
with check (
  usuario_id = (select auth.uid())
  or public.can_manage_operational_pending()
);

drop policy if exists reservations_pending_center_select on public.reservations;
create policy reservations_pending_center_select
on public.reservations
for select
to authenticated
using (
  usuario_id = (select auth.uid())
  or public.can_manage_operational_pending()
);

drop policy if exists reservations_pending_center_update on public.reservations;
create policy reservations_pending_center_update
on public.reservations
for update
to authenticated
using (public.can_manage_operational_pending())
with check (public.can_manage_operational_pending());

-- ---------------------------------------------------------------------------
-- 3. Reuniões: hora canônica e link online persistente
-- ---------------------------------------------------------------------------

alter table public.meetings
  add column if not exists link text;

alter table public.meetings
  drop constraint if exists meetings_link_http_check;

alter table public.meetings
  add constraint meetings_link_http_check
  check (
    link is null
    or btrim(link) = ''
    or link ~* '^https?://'
  );

comment on column public.meetings.hora
is 'Horário canônico da reunião. O frontend pode expor o alias horario.';

comment on column public.meetings.link
is 'Link opcional da reunião online, limitado a HTTP ou HTTPS.';

create index if not exists meetings_data_hora_status_idx
  on public.meetings(data, hora, status);

-- ---------------------------------------------------------------------------
-- 4. Participantes selecionados conseguem visualizar a reunião
-- ---------------------------------------------------------------------------

drop policy if exists "ve avisos" on public.meetings;

create policy "ve avisos"
on public.meetings
for select
to public
using (
  public.is_coord_or_admin()
  or autor_id = auth.uid()
  or para_todos = true
  or (
    alvo_roles is not null
    and (
      select p.role::text
      from public.profiles p
      where p.id = auth.uid()
    ) = any(alvo_roles)
  )
  or (
    alvo_users is not null
    and auth.uid() = any(alvo_users)
  )
  or (
    team_id is not null
    and exists (
      select 1
      from public.team_members tm
      where tm.team_id = meetings.team_id
        and tm.user_id = auth.uid()
    )
  )
  or exists (
    select 1
    from public.meeting_participants mp
    where mp.meeting_id = meetings.id
      and mp.user_id = auth.uid()
  )
);

commit;
