-- NexLab v25.8 — Preferências e Automação de Notificações
-- Pré-requisito: migrations v25.6.1 e v25.7 aplicadas.
-- Executar integralmente no SQL Editor do Supabase.

begin;

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1. Evolução das estruturas existentes
-- -----------------------------------------------------------------------------

do $$
begin
  if to_regclass('public.notifications') is null
    or to_regclass('public.notification_preferences') is null
    or to_regclass('public.notification_deliveries') is null
  then
    raise exception 'Execute primeiro a migration da NexLab v25.7.';
  end if;
end
$$;

alter table public.notifications
  add column if not exists preference_key text null;

alter table public.notification_preferences
  add column if not exists muted boolean not null default false,
  add column if not exists muted_until timestamptz null;

create index if not exists notifications_preference_key_idx
  on public.notifications (recipient_id, preference_key, created_at desc);

-- -----------------------------------------------------------------------------
-- 2. Configurações pessoais, modelos e lembretes
-- -----------------------------------------------------------------------------

do $$
declare
  profile_id_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
    into profile_id_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'id'
    and a.attnum > 0
    and not a.attisdropped;

  if profile_id_type is null then
    raise exception 'Não foi possível identificar o tipo de profiles.id.';
  end if;

  if to_regclass('public.notification_user_settings') is null then
    execute format(
      'create table public.notification_user_settings (
         user_id %s primary key references public.profiles(id) on delete cascade,
         quiet_hours_enabled boolean not null default false,
         quiet_start time not null default ''22:00'',
         quiet_end time not null default ''07:00'',
         timezone text not null default ''America/Fortaleza'',
         reservation_reminder_minutes integer[] not null default array[60]::integer[],
         meeting_reminder_minutes integer[] not null default array[30]::integer[],
         created_at timestamptz not null default now(),
         updated_at timestamptz not null default now()
       )',
      profile_id_type
    );
  end if;

  if to_regclass('public.notification_reminders') is null then
    execute format(
      'create table public.notification_reminders (
         id uuid primary key default gen_random_uuid(),
         entity_type text not null,
         entity_id text not null,
         recipient_id %s not null references public.profiles(id) on delete cascade,
         preference_key text not null,
         offset_minutes integer not null,
         scheduled_for timestamptz not null,
         status text not null default ''pending'',
         source_key text not null unique,
         notification_id_text text null,
         payload jsonb not null default ''{}''::jsonb,
         last_error text null,
         processed_at timestamptz null,
         created_at timestamptz not null default now(),
         updated_at timestamptz not null default now(),
         constraint notification_reminders_entity_check
           check (entity_type in (''reservation'', ''meeting'')),
         constraint notification_reminders_status_check
           check (status in (''pending'', ''sent'', ''skipped'', ''failed'')),
         constraint notification_reminders_offset_check
           check (offset_minutes between 5 and 10080)
       )',
      profile_id_type
    );
  end if;
end
$$;

create table if not exists public.notification_templates (
  id uuid primary key default gen_random_uuid(),
  template_key text not null unique,
  label text not null,
  notification_type text not null default 'system',
  title_template text not null,
  body_template text not null,
  email_subject_template text null,
  variables jsonb not null default '[]'::jsonb,
  active boolean not null default true,
  updated_by uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists notification_reminders_due_idx
  on public.notification_reminders (status, scheduled_for)
  where status = 'pending';

create index if not exists notification_reminders_recipient_idx
  on public.notification_reminders (recipient_id, created_at desc);

create index if not exists notification_templates_active_idx
  on public.notification_templates (active, template_key);

-- -----------------------------------------------------------------------------
-- 3. Modelos padrão
-- -----------------------------------------------------------------------------

insert into public.notification_templates (
  template_key,
  label,
  notification_type,
  title_template,
  body_template,
  email_subject_template,
  variables,
  active
)
values
  (
    'reservation_reminder',
    'Lembrete de reserva',
    'system',
    'Reserva em {minutes_label}',
    'A reserva "{title}" está marcada para {date} às {time}.',
    '[NexLab] Reserva em {minutes_label}: {title}',
    '["title","date","time","minutes","minutes_label"]'::jsonb,
    true
  ),
  (
    'meeting_reminder',
    'Lembrete de reunião',
    'system',
    'Reunião em {minutes_label}',
    'A reunião "{title}" está marcada para {date} às {time}.',
    '[NexLab] Reunião em {minutes_label}: {title}',
    '["title","date","time","minutes","minutes_label"]'::jsonb,
    true
  )
on conflict (template_key) do nothing;

-- Cria configurações padrão também para usuários existentes. Assim, os
-- lembretes internos não dependem de o usuário abrir primeiro esta tela.
insert into public.notification_user_settings (user_id)
select p.id
from public.profiles p
where coalesce(p.ativo, true)
on conflict (user_id) do nothing;

insert into public.notification_preferences (
  user_id,
  notification_type,
  email_enabled,
  push_enabled,
  muted
)
select
  p.id,
  item.preference_key,
  false,
  false,
  false
from public.profiles p
cross join (
  values
    ('reservation_reminder'),
    ('meeting_reminder')
) as item(preference_key)
where coalesce(p.ativo, true)
on conflict (user_id, notification_type) do nothing;

-- -----------------------------------------------------------------------------
-- 4. RLS e grants
-- -----------------------------------------------------------------------------

alter table public.notification_user_settings enable row level security;
alter table public.notification_reminders enable row level security;
alter table public.notification_templates enable row level security;

grant select, insert, update
on public.notification_user_settings
to authenticated;

grant select
on public.notification_reminders
to authenticated;

grant select
on public.notification_templates
to authenticated;

grant update
on public.notification_templates
to authenticated;

drop policy if exists notification_user_settings_select_own
on public.notification_user_settings;

create policy notification_user_settings_select_own
on public.notification_user_settings
for select
to authenticated
using (
  user_id::text = auth.uid()::text
  or public.nexlab_is_admin()
);

drop policy if exists notification_user_settings_insert_own
on public.notification_user_settings;

create policy notification_user_settings_insert_own
on public.notification_user_settings
for insert
to authenticated
with check (user_id::text = auth.uid()::text);

drop policy if exists notification_user_settings_update_own
on public.notification_user_settings;

create policy notification_user_settings_update_own
on public.notification_user_settings
for update
to authenticated
using (user_id::text = auth.uid()::text)
with check (user_id::text = auth.uid()::text);

drop policy if exists notification_reminders_select_own
on public.notification_reminders;

create policy notification_reminders_select_own
on public.notification_reminders
for select
to authenticated
using (
  recipient_id::text = auth.uid()::text
  or public.nexlab_is_admin()
);

drop policy if exists notification_templates_select_authenticated
on public.notification_templates;

create policy notification_templates_select_authenticated
on public.notification_templates
for select
to authenticated
using (true);

drop policy if exists notification_templates_update_admin
on public.notification_templates;

create policy notification_templates_update_admin
on public.notification_templates
for update
to authenticated
using (public.nexlab_is_admin())
with check (public.nexlab_is_admin());

-- -----------------------------------------------------------------------------
-- 5. updated_at
-- -----------------------------------------------------------------------------

drop trigger if exists notification_user_settings_set_updated_at
on public.notification_user_settings;

create trigger notification_user_settings_set_updated_at
before update on public.notification_user_settings
for each row
execute function public.nexlab_set_updated_at();

drop trigger if exists notification_reminders_set_updated_at
on public.notification_reminders;

create trigger notification_reminders_set_updated_at
before update on public.notification_reminders
for each row
execute function public.nexlab_set_updated_at();

drop trigger if exists notification_templates_set_updated_at
on public.notification_templates;

create trigger notification_templates_set_updated_at
before update on public.notification_templates
for each row
execute function public.nexlab_set_updated_at();

-- -----------------------------------------------------------------------------
-- 6. Configurações padrão por usuário
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_ensure_notification_user_settings()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.'
      using errcode = '42501';
  end if;

  insert into public.notification_user_settings (user_id)
  select p.id
  from public.profiles p
  where p.id::text = auth.uid()::text
  on conflict (user_id) do nothing;

  insert into public.notification_preferences (
    user_id,
    notification_type,
    email_enabled,
    push_enabled,
    muted
  )
  select
    p.id,
    item.preference_key,
    false,
    false,
    false
  from public.profiles p
  cross join (
    values
      ('reservation_reminder'),
      ('meeting_reminder')
  ) as item(preference_key)
  where p.id::text = auth.uid()::text
  on conflict (user_id, notification_type) do nothing;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all
on function public.nexlab_ensure_notification_user_settings()
from public;

grant execute
on function public.nexlab_ensure_notification_user_settings()
to authenticated;

-- -----------------------------------------------------------------------------
-- 7. Horário permitido para entrega externa (Não perturbe)
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_next_delivery_time(
  p_user_id text,
  p_reference timestamptz default now()
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  settings_row record;
  local_reference timestamp;
  local_time time;
  next_local timestamp;
begin
  select
    s.quiet_hours_enabled,
    s.quiet_start,
    s.quiet_end,
    coalesce(nullif(s.timezone, ''), 'America/Fortaleza') as timezone
  into settings_row
  from public.notification_user_settings s
  where s.user_id::text = p_user_id
  limit 1;

  if not found or not coalesce(settings_row.quiet_hours_enabled, false) then
    return p_reference;
  end if;

  if settings_row.quiet_start = settings_row.quiet_end then
    return p_reference;
  end if;

  local_reference := p_reference at time zone settings_row.timezone;
  local_time := local_reference::time;

  if settings_row.quiet_start < settings_row.quiet_end then
    if local_time >= settings_row.quiet_start
      and local_time < settings_row.quiet_end
    then
      next_local := local_reference::date + settings_row.quiet_end;
      return next_local at time zone settings_row.timezone;
    end if;
  else
    if local_time >= settings_row.quiet_start then
      next_local := (local_reference::date + 1) + settings_row.quiet_end;
      return next_local at time zone settings_row.timezone;
    elsif local_time < settings_row.quiet_end then
      next_local := local_reference::date + settings_row.quiet_end;
      return next_local at time zone settings_row.timezone;
    end if;
  end if;

  return p_reference;
end;
$$;

revoke all
on function public.nexlab_next_delivery_time(text, timestamptz)
from public;

-- -----------------------------------------------------------------------------
-- 8. Fila externa com silenciamento e Não perturbe
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_enqueue_external_delivery()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  preference_email boolean := false;
  preference_push boolean := false;
  preference_muted boolean := false;
  preference_muted_until timestamptz := null;
  notification_preference_key text := lower(
    coalesce(
      nullif(new.preference_key, ''),
      new.type::text,
      'system'
    )
  );
  delivery_time timestamptz;
begin
  select
    coalesce(pref.email_enabled, false),
    coalesce(pref.push_enabled, false),
    coalesce(pref.muted, false),
    pref.muted_until
  into
    preference_email,
    preference_push,
    preference_muted,
    preference_muted_until
  from public.notification_preferences pref
  where pref.user_id = new.recipient_id
    and pref.notification_type in (
      notification_preference_key,
      '*'
    )
  order by
    case
      when pref.notification_type = notification_preference_key then 0
      else 1
    end
  limit 1;

  if preference_muted
    or (
      preference_muted_until is not null
      and preference_muted_until > now()
    )
  then
    return new;
  end if;

  delivery_time := public.nexlab_next_delivery_time(
    new.recipient_id::text,
    now()
  );

  if coalesce(preference_email, false)
    and coalesce(new.email_eligible, true)
  then
    insert into public.notification_deliveries (
      notification_id,
      recipient_id,
      channel,
      next_attempt_at,
      payload
    )
    values (
      new.id,
      new.recipient_id,
      'email',
      delivery_time,
      jsonb_build_object(
        'notification_id', new.id::text,
        'type', new.type::text,
        'preference_key', notification_preference_key,
        'title', new.title,
        'message', new.message,
        'target_tab', new.target_tab,
        'entity_type', new.entity_type::text,
        'entity_id', new.entity_id::text,
        'category', new.category,
        'priority', new.priority,
        'email_subject', coalesce(
          new.metadata ->> 'email_subject',
          '[NexLab] ' || coalesce(new.title, 'Notificação')
        ),
        'metadata', coalesce(new.metadata, '{}'::jsonb),
        'created_at', new.created_at
      )
    )
    on conflict (notification_id, channel) do nothing;
  end if;

  if coalesce(preference_push, false)
    and coalesce(new.push_eligible, true)
    and exists (
      select 1
      from public.push_subscriptions subscription
      where subscription.user_id = new.recipient_id
        and subscription.active
    )
  then
    insert into public.notification_deliveries (
      notification_id,
      recipient_id,
      channel,
      next_attempt_at,
      payload
    )
    values (
      new.id,
      new.recipient_id,
      'push',
      delivery_time,
      jsonb_build_object(
        'notification_id', new.id::text,
        'type', new.type::text,
        'preference_key', notification_preference_key,
        'title', new.title,
        'message', new.message,
        'target_tab', new.target_tab,
        'entity_type', new.entity_type::text,
        'entity_id', new.entity_id::text,
        'category', new.category,
        'priority', new.priority,
        'email_subject', coalesce(
          new.metadata ->> 'email_subject',
          '[NexLab] ' || coalesce(new.title, 'Notificação')
        ),
        'metadata', coalesce(new.metadata, '{}'::jsonb),
        'created_at', new.created_at
      )
    )
    on conflict (notification_id, channel) do nothing;
  end if;

  return new;
end;
$$;

-- O trigger criado na v25.7 continuará apontando para esta função substituída.

-- -----------------------------------------------------------------------------
-- 9. Renderização segura dos modelos
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_render_notification_template(
  p_template text,
  p_values jsonb
)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  rendered text := coalesce(p_template, '');
  item record;
begin
  for item in
    select key, value
    from jsonb_each_text(coalesce(p_values, '{}'::jsonb))
  loop
    rendered := replace(
      rendered,
      '{' || item.key || '}',
      coalesce(item.value, '')
    );
  end loop;

  return rendered;
end;
$$;

-- -----------------------------------------------------------------------------
-- 10. Geração e disparo dos lembretes internos
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_process_due_reminders(
  p_limit integer default 250
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  scheduled_reservations integer := 0;
  scheduled_meetings integer := 0;
  processed_count integer := 0;
  skipped_count integer := 0;
  failed_count integer := 0;
  reminder record;
  template_row record;
  event_status text;
  event_title text;
  event_date date;
  event_time time;
  values_json jsonb;
  rendered_title text;
  rendered_body text;
  inserted_notification_id text;
  minutes_label text;
  expected_source_key text;
begin
  -- Reserva: cria uma linha por participante e por antecedência escolhida.
  insert into public.notification_reminders (
    entity_type,
    entity_id,
    recipient_id,
    preference_key,
    offset_minutes,
    scheduled_for,
    source_key,
    payload
  )
  select
    'reservation',
    r.id::text,
    rp.user_id,
    'reservation_reminder',
    offsets.minutes,
    ((r.data::date + r.hora_inicio::time) at time zone coalesce(s.timezone, 'America/Fortaleza'))
      - make_interval(mins => offsets.minutes),
    format(
      'reservation-reminder:%s:%s:%s:%s%s',
      r.id::text,
      rp.user_id::text,
      offsets.minutes,
      to_char(r.data::date, 'YYYYMMDD'),
      to_char(r.hora_inicio::time, 'HH24MI')
    ),
    jsonb_build_object(
      'title', coalesce(r.titulo, 'Reserva de sala'),
      'date', to_char(r.data::date, 'DD/MM/YYYY'),
      'time', to_char(r.hora_inicio::time, 'HH24:MI'),
      'event_start_at', (
        (r.data::date + r.hora_inicio::time)
        at time zone coalesce(s.timezone, 'America/Fortaleza')
      )
    )
  from public.reservations r
  join public.reservation_participants rp
    on rp.reservation_id = r.id
  join public.notification_user_settings s
    on s.user_id = rp.user_id
  cross join lateral unnest(s.reservation_reminder_minutes) as offsets(minutes)
  where lower(coalesce(r.status::text, '')) not in ('cancelada', 'recusada')
    and ((r.data::date + r.hora_inicio::time) at time zone coalesce(s.timezone, 'America/Fortaleza')) > now()
    and ((r.data::date + r.hora_inicio::time) at time zone coalesce(s.timezone, 'America/Fortaleza')) <= now() + interval '30 days'
    and offsets.minutes between 5 and 10080
  on conflict (source_key) do nothing;

  get diagnostics scheduled_reservations = row_count;

  -- Reunião: cria uma linha por participante e por antecedência escolhida.
  insert into public.notification_reminders (
    entity_type,
    entity_id,
    recipient_id,
    preference_key,
    offset_minutes,
    scheduled_for,
    source_key,
    payload
  )
  select
    'meeting',
    m.id::text,
    mp.user_id,
    'meeting_reminder',
    offsets.minutes,
    ((m.data::date + m.horario::time) at time zone coalesce(s.timezone, 'America/Fortaleza'))
      - make_interval(mins => offsets.minutes),
    format(
      'meeting-reminder:%s:%s:%s:%s%s',
      m.id::text,
      mp.user_id::text,
      offsets.minutes,
      to_char(m.data::date, 'YYYYMMDD'),
      to_char(m.horario::time, 'HH24MI')
    ),
    jsonb_build_object(
      'title', coalesce(m.titulo, 'Reunião'),
      'date', to_char(m.data::date, 'DD/MM/YYYY'),
      'time', to_char(m.horario::time, 'HH24:MI'),
      'event_start_at', (
        (m.data::date + m.horario::time)
        at time zone coalesce(s.timezone, 'America/Fortaleza')
      )
    )
  from public.meetings m
  join public.meeting_participants mp
    on mp.meeting_id = m.id
  join public.notification_user_settings s
    on s.user_id = mp.user_id
  cross join lateral unnest(s.meeting_reminder_minutes) as offsets(minutes)
  where lower(coalesce(m.status::text, 'agendada')) <> 'cancelada'
    and ((m.data::date + m.horario::time) at time zone coalesce(s.timezone, 'America/Fortaleza')) > now()
    and ((m.data::date + m.horario::time) at time zone coalesce(s.timezone, 'America/Fortaleza')) <= now() + interval '30 days'
    and offsets.minutes between 5 and 10080
  on conflict (source_key) do nothing;

  get diagnostics scheduled_meetings = row_count;

  for reminder in
    select r.*
    from public.notification_reminders r
    where r.status = 'pending'
      and r.scheduled_for <= now()
    order by r.scheduled_for
    limit greatest(1, least(coalesce(p_limit, 250), 1000))
    for update skip locked
  loop
    begin
      event_status := null;
      event_title := null;
      event_date := null;
      event_time := null;

      if reminder.entity_type = 'reservation' then
        select
          lower(coalesce(r.status::text, '')),
          coalesce(r.titulo, 'Reserva de sala'),
          r.data::date,
          r.hora_inicio::time
        into
          event_status,
          event_title,
          event_date,
          event_time
        from public.reservations r
        where r.id::text = reminder.entity_id;

        if event_status is null
          or event_status in ('cancelada', 'recusada')
        then
          update public.notification_reminders
             set status = 'skipped',
                 processed_at = now(),
                 last_error = 'Reserva inexistente, cancelada ou recusada.'
           where id = reminder.id;
          skipped_count := skipped_count + 1;
          continue;
        end if;
      else
        select
          lower(coalesce(m.status::text, 'agendada')),
          coalesce(m.titulo, 'Reunião'),
          m.data::date,
          m.horario::time
        into
          event_status,
          event_title,
          event_date,
          event_time
        from public.meetings m
        where m.id::text = reminder.entity_id;

        if event_status is null or event_status = 'cancelada' then
          update public.notification_reminders
             set status = 'skipped',
                 processed_at = now(),
                 last_error = 'Reunião inexistente ou cancelada.'
           where id = reminder.id;
          skipped_count := skipped_count + 1;
          continue;
        end if;
      end if;

      -- Uma alteração de data/horário gera uma nova chave. A linha antiga é
      -- ignorada, evitando lembrete no horário anterior.
      expected_source_key := format(
        '%s-reminder:%s:%s:%s:%s%s',
        reminder.entity_type,
        reminder.entity_id,
        reminder.recipient_id::text,
        reminder.offset_minutes,
        to_char(event_date, 'YYYYMMDD'),
        to_char(event_time, 'HH24MI')
      );

      if reminder.source_key <> expected_source_key then
        update public.notification_reminders
           set status = 'skipped',
               processed_at = now(),
               last_error = 'Lembrete substituído após alteração de data ou horário.'
         where id = reminder.id;
        skipped_count := skipped_count + 1;
        continue;
      end if;

      if reminder.entity_type = 'reservation' then
        if not exists (
          select 1
          from public.reservation_participants rp
          where rp.reservation_id::text = reminder.entity_id
            and rp.user_id = reminder.recipient_id
        ) then
          update public.notification_reminders
             set status = 'skipped',
                 processed_at = now(),
                 last_error = 'Usuário não participa mais da reserva.'
           where id = reminder.id;
          skipped_count := skipped_count + 1;
          continue;
        end if;

        if not exists (
          select 1
          from public.notification_user_settings us
          where us.user_id = reminder.recipient_id
            and reminder.offset_minutes = any(us.reservation_reminder_minutes)
        ) then
          update public.notification_reminders
             set status = 'skipped',
                 processed_at = now(),
                 last_error = 'Antecedência removida das preferências do usuário.'
           where id = reminder.id;
          skipped_count := skipped_count + 1;
          continue;
        end if;
      else
        if not exists (
          select 1
          from public.meeting_participants mp
          where mp.meeting_id::text = reminder.entity_id
            and mp.user_id = reminder.recipient_id
        ) then
          update public.notification_reminders
             set status = 'skipped',
                 processed_at = now(),
                 last_error = 'Usuário não participa mais da reunião.'
           where id = reminder.id;
          skipped_count := skipped_count + 1;
          continue;
        end if;

        if not exists (
          select 1
          from public.notification_user_settings us
          where us.user_id = reminder.recipient_id
            and reminder.offset_minutes = any(us.meeting_reminder_minutes)
        ) then
          update public.notification_reminders
             set status = 'skipped',
                 processed_at = now(),
                 last_error = 'Antecedência removida das preferências do usuário.'
           where id = reminder.id;
          skipped_count := skipped_count + 1;
          continue;
        end if;
      end if;

      select t.*
      into template_row
      from public.notification_templates t
      where t.template_key = reminder.preference_key
        and t.active
      limit 1;

      if not found then
        update public.notification_reminders
           set status = 'skipped',
               processed_at = now(),
               last_error = 'Modelo de notificação desativado ou inexistente.'
         where id = reminder.id;
        skipped_count := skipped_count + 1;
        continue;
      end if;

      minutes_label := case
        when reminder.offset_minutes % 1440 = 0 then
          (reminder.offset_minutes / 1440)::text ||
          case when reminder.offset_minutes = 1440 then ' dia' else ' dias' end
        when reminder.offset_minutes % 60 = 0 then
          (reminder.offset_minutes / 60)::text ||
          case when reminder.offset_minutes = 60 then ' hora' else ' horas' end
        else
          reminder.offset_minutes::text || ' minutos'
      end;

      values_json := jsonb_build_object(
        'title', event_title,
        'date', to_char(event_date, 'DD/MM/YYYY'),
        'time', to_char(event_time, 'HH24:MI'),
        'minutes', reminder.offset_minutes,
        'minutes_label', minutes_label
      );

      rendered_title := public.nexlab_render_notification_template(
        template_row.title_template,
        values_json
      );

      rendered_body := public.nexlab_render_notification_template(
        template_row.body_template,
        values_json
      );

      insert into public.notifications (
        recipient_id,
        type,
        preference_key,
        title,
        message,
        target_tab,
        source_key,
        category,
        priority,
        metadata
      )
      select
        p.id,
        'system',
        reminder.preference_key,
        rendered_title,
        rendered_body,
        case
          when reminder.entity_type = 'reservation' then 'reserva'
          else 'agenda'
        end,
        reminder.source_key,
        case
          when reminder.entity_type = 'reservation' then 'reservas'
          else 'reunioes'
        end,
        case
          when reminder.offset_minutes <= 30 then 'alta'
          else 'normal'
        end,
        jsonb_build_object(
          'reminder', true,
          'entity_type', reminder.entity_type,
          'entity_id', reminder.entity_id,
          'offset_minutes', reminder.offset_minutes,
          'scheduled_for', reminder.scheduled_for,
          'email_subject', public.nexlab_render_notification_template(
            coalesce(template_row.email_subject_template, template_row.title_template),
            values_json
          )
        )
      from public.profiles p
      where p.id = reminder.recipient_id
        and coalesce(p.ativo, true)
        and not exists (
          select 1
          from public.notifications n
          where n.source_key = reminder.source_key
        )
      returning id::text into inserted_notification_id;

      if inserted_notification_id is null then
        select n.id::text
          into inserted_notification_id
        from public.notifications n
        where n.source_key = reminder.source_key
        limit 1;
      end if;

      if inserted_notification_id is null then
        update public.notification_reminders
           set status = 'skipped',
               processed_at = now(),
               last_error = 'Destinatário inativo ou notificação não criada.'
         where id = reminder.id;
        skipped_count := skipped_count + 1;
        continue;
      end if;

      update public.notification_reminders
         set status = 'sent',
             processed_at = now(),
             notification_id_text = inserted_notification_id,
             payload = coalesce(payload, '{}'::jsonb) || values_json,
             last_error = null
       where id = reminder.id;

      processed_count := processed_count + 1;
    exception
      when others then
        update public.notification_reminders
           set status = 'failed',
               processed_at = now(),
               last_error = left(sqlerrm, 1800)
         where id = reminder.id;
        failed_count := failed_count + 1;
    end;
  end loop;

  return jsonb_build_object(
    'scheduled_reservations', scheduled_reservations,
    'scheduled_meetings', scheduled_meetings,
    'processed', processed_count,
    'skipped', skipped_count,
    'failed', failed_count
  );
end;
$$;

revoke all
on function public.nexlab_process_due_reminders(integer)
from public;

-- -----------------------------------------------------------------------------
-- 11. Reenvio manual de entregas externas
-- -----------------------------------------------------------------------------

create or replace function public.retry_notification_delivery(
  p_delivery_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  delivery_row record;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.'
      using errcode = '42501';
  end if;

  select d.*
  into delivery_row
  from public.notification_deliveries d
  where d.id::text = p_delivery_id
  limit 1;

  if not found then
    raise exception 'Entrega não encontrada.'
      using errcode = 'P0002';
  end if;

  if delivery_row.recipient_id::text <> auth.uid()::text
    and not public.nexlab_is_admin()
  then
    raise exception 'Sem permissão para reenviar esta entrega.'
      using errcode = '42501';
  end if;

  if delivery_row.status not in ('failed', 'skipped') then
    raise exception 'Somente entregas com falha ou ignoradas podem ser reenviadas.'
      using errcode = '22023';
  end if;

  update public.notification_deliveries
     set status = 'pending',
         attempts = 0,
         next_attempt_at = public.nexlab_next_delivery_time(
           delivery_row.recipient_id::text,
           now()
         ),
         claimed_at = null,
         sent_at = null,
         provider_message_id = null,
         last_error = null
   where id = delivery_row.id;

  return jsonb_build_object(
    'id', delivery_row.id,
    'status', 'pending'
  );
end;
$$;

revoke all
on function public.retry_notification_delivery(text)
from public;

grant execute
on function public.retry_notification_delivery(text)
to authenticated;

-- -----------------------------------------------------------------------------
-- 12. Métricas simples para o Administrador
-- -----------------------------------------------------------------------------

create or replace function public.get_notification_metrics(
  p_days integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  days_count integer := greatest(1, least(coalesce(p_days, 30), 365));
  result jsonb;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Apenas o Administrador pode consultar métricas gerais.'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
    'days', days_count,
    'total', count(*),
    'sent', count(*) filter (where status = 'sent'),
    'failed', count(*) filter (where status = 'failed'),
    'pending', count(*) filter (where status = 'pending'),
    'processing', count(*) filter (where status = 'processing'),
    'skipped', count(*) filter (where status = 'skipped'),
    'email', count(*) filter (where channel = 'email'),
    'push', count(*) filter (where channel = 'push'),
    'success_rate', case
      when count(*) filter (where status in ('sent', 'failed')) = 0 then 0
      else round(
        100.0 * count(*) filter (where status = 'sent') /
        count(*) filter (where status in ('sent', 'failed')),
        1
      )
    end
  )
  into result
  from public.notification_deliveries
  where created_at >= now() - make_interval(days => days_count);

  return coalesce(result, '{}'::jsonb);
end;
$$;

revoke all
on function public.get_notification_metrics(integer)
from public;

grant execute
on function public.get_notification_metrics(integer)
to authenticated;

-- -----------------------------------------------------------------------------
-- 13. Realtime
-- -----------------------------------------------------------------------------

do $$
begin
  begin
    alter publication supabase_realtime
      add table public.notification_reminders;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime
      add table public.notification_user_settings;
  exception
    when duplicate_object then null;
  end;
end
$$;

commit;

-- Validação rápida após execução:
-- select public.nexlab_ensure_notification_user_settings();
-- select public.nexlab_process_due_reminders(50);
-- select * from public.notification_templates order by template_key;
-- select * from public.notification_user_settings limit 5;
