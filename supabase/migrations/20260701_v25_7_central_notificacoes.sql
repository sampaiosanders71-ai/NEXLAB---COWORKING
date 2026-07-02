-- NexLab v25.7 — Central de Notificações Internas e Externas
-- Execute no SQL Editor do Supabase após a migration da v25.6.1.

begin;

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1. Evolução da tabela de notificações internas
-- -----------------------------------------------------------------------------

do $$
begin
  if to_regclass('public.notifications') is null then
    raise exception 'A tabela public.notifications não existe. Execute primeiro as migrations anteriores do NexLab.';
  end if;
end
$$;

alter table public.notifications
  add column if not exists archived_at timestamptz null,
  add column if not exists category text not null default 'sistema',
  add column if not exists priority text not null default 'normal',
  add column if not exists metadata jsonb not null default '{}'::jsonb,
  add column if not exists email_eligible boolean not null default true,
  add column if not exists push_eligible boolean not null default true,
  add column if not exists updated_at timestamptz not null default now();

alter table public.notifications
  drop constraint if exists notifications_priority_check;

alter table public.notifications
  add constraint notifications_priority_check
  check (priority in ('baixa', 'normal', 'alta', 'urgente'));

create index if not exists notifications_recipient_created_idx
  on public.notifications (recipient_id, created_at desc);

create index if not exists notifications_recipient_unread_idx
  on public.notifications (recipient_id, is_read, created_at desc)
  where archived_at is null;

create index if not exists notifications_recipient_archived_idx
  on public.notifications (recipient_id, archived_at desc)
  where archived_at is not null;

-- -----------------------------------------------------------------------------
-- 2. Tabelas auxiliares com os mesmos tipos de ID do esquema existente
-- -----------------------------------------------------------------------------

do $$
declare
  profile_id_type text;
  notification_id_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
    into profile_id_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'id'
    and a.attnum > 0
    and not a.attisdropped;

  select format_type(a.atttypid, a.atttypmod)
    into notification_id_type
  from pg_attribute a
  where a.attrelid = 'public.notifications'::regclass
    and a.attname = 'id'
    and a.attnum > 0
    and not a.attisdropped;

  if profile_id_type is null or notification_id_type is null then
    raise exception 'Não foi possível identificar os tipos de ID de profiles ou notifications.';
  end if;

  if to_regclass('public.notification_preferences') is null then
    execute format(
      'create table public.notification_preferences (
         id uuid primary key default gen_random_uuid(),
         user_id %s not null references public.profiles(id) on delete cascade,
         notification_type text not null default ''*'',
         email_enabled boolean not null default false,
         push_enabled boolean not null default false,
         created_at timestamptz not null default now(),
         updated_at timestamptz not null default now(),
         unique (user_id, notification_type)
       )',
      profile_id_type
    );
  end if;

  if to_regclass('public.push_subscriptions') is null then
    execute format(
      'create table public.push_subscriptions (
         id uuid primary key default gen_random_uuid(),
         user_id %s not null references public.profiles(id) on delete cascade,
         endpoint text not null unique,
         p256dh text not null,
         auth text not null,
         expiration_time bigint null,
         user_agent text null,
         platform text null,
         active boolean not null default true,
         last_seen_at timestamptz not null default now(),
         created_at timestamptz not null default now(),
         updated_at timestamptz not null default now()
       )',
      profile_id_type
    );
  end if;

  if to_regclass('public.notification_deliveries') is null then
    execute format(
      'create table public.notification_deliveries (
         id uuid primary key default gen_random_uuid(),
         notification_id %s not null references public.notifications(id) on delete cascade,
         recipient_id %s not null references public.profiles(id) on delete cascade,
         channel text not null,
         status text not null default ''pending'',
         attempts integer not null default 0,
         next_attempt_at timestamptz not null default now(),
         claimed_at timestamptz null,
         sent_at timestamptz null,
         provider_message_id text null,
         last_error text null,
         payload jsonb not null default ''{}''::jsonb,
         created_at timestamptz not null default now(),
         updated_at timestamptz not null default now(),
         unique (notification_id, channel),
         constraint notification_deliveries_channel_check
           check (channel in (''email'', ''push'')),
         constraint notification_deliveries_status_check
           check (status in (''pending'', ''processing'', ''sent'', ''failed'', ''skipped'')),
         constraint notification_deliveries_attempts_check
           check (attempts >= 0 and attempts <= 20)
       )',
      notification_id_type,
      profile_id_type
    );
  end if;
end
$$;

create index if not exists notification_preferences_user_idx
  on public.notification_preferences (user_id, notification_type);

create index if not exists push_subscriptions_user_active_idx
  on public.push_subscriptions (user_id, active);

create index if not exists notification_deliveries_queue_idx
  on public.notification_deliveries (status, next_attempt_at, created_at)
  where status = 'pending';

create index if not exists notification_deliveries_recipient_idx
  on public.notification_deliveries (recipient_id, created_at desc);

-- -----------------------------------------------------------------------------
-- 3. RLS e grants
-- -----------------------------------------------------------------------------

alter table public.notification_preferences enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.notification_deliveries enable row level security;

grant select, insert, update, delete
on public.notification_preferences
to authenticated;

grant select, insert, update, delete
on public.push_subscriptions
to authenticated;

grant select
on public.notification_deliveries
to authenticated;

drop policy if exists notification_preferences_select_own
on public.notification_preferences;
create policy notification_preferences_select_own
on public.notification_preferences
for select
to authenticated
using (user_id::text = auth.uid()::text);

drop policy if exists notification_preferences_insert_own
on public.notification_preferences;
create policy notification_preferences_insert_own
on public.notification_preferences
for insert
to authenticated
with check (user_id::text = auth.uid()::text);

drop policy if exists notification_preferences_update_own
on public.notification_preferences;
create policy notification_preferences_update_own
on public.notification_preferences
for update
to authenticated
using (user_id::text = auth.uid()::text)
with check (user_id::text = auth.uid()::text);

drop policy if exists notification_preferences_delete_own
on public.notification_preferences;
create policy notification_preferences_delete_own
on public.notification_preferences
for delete
to authenticated
using (user_id::text = auth.uid()::text);

drop policy if exists push_subscriptions_select_own
on public.push_subscriptions;
create policy push_subscriptions_select_own
on public.push_subscriptions
for select
to authenticated
using (user_id::text = auth.uid()::text);

drop policy if exists push_subscriptions_insert_own
on public.push_subscriptions;
create policy push_subscriptions_insert_own
on public.push_subscriptions
for insert
to authenticated
with check (user_id::text = auth.uid()::text);

drop policy if exists push_subscriptions_update_own
on public.push_subscriptions;
create policy push_subscriptions_update_own
on public.push_subscriptions
for update
to authenticated
using (user_id::text = auth.uid()::text)
with check (user_id::text = auth.uid()::text);

drop policy if exists push_subscriptions_delete_own
on public.push_subscriptions;
create policy push_subscriptions_delete_own
on public.push_subscriptions
for delete
to authenticated
using (user_id::text = auth.uid()::text);

drop policy if exists notification_deliveries_select_own
on public.notification_deliveries;
create policy notification_deliveries_select_own
on public.notification_deliveries
for select
to authenticated
using (
  recipient_id::text = auth.uid()::text
  or public.nexlab_is_admin()
);

-- -----------------------------------------------------------------------------
-- 4. Atualização automática de updated_at
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists notifications_set_updated_at
on public.notifications;
create trigger notifications_set_updated_at
before update on public.notifications
for each row execute function public.nexlab_set_updated_at();

drop trigger if exists notification_preferences_set_updated_at
on public.notification_preferences;
create trigger notification_preferences_set_updated_at
before update on public.notification_preferences
for each row execute function public.nexlab_set_updated_at();

drop trigger if exists push_subscriptions_set_updated_at
on public.push_subscriptions;
create trigger push_subscriptions_set_updated_at
before update on public.push_subscriptions
for each row execute function public.nexlab_set_updated_at();

drop trigger if exists notification_deliveries_set_updated_at
on public.notification_deliveries;
create trigger notification_deliveries_set_updated_at
before update on public.notification_deliveries
for each row execute function public.nexlab_set_updated_at();

-- -----------------------------------------------------------------------------
-- 5. Normalização de categoria e prioridade
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_normalize_notification()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  type_text text := lower(coalesce(new.type::text, 'system'));
begin
  if new.category is null or btrim(new.category) = '' or new.category = 'sistema' then
    new.category := case
      when type_text like 'reservation%' then 'reservas'
      when type_text like 'profile%' then 'usuarios'
      when type_text like 'feedback%' then 'feedback'
      when type_text like 'meeting%' then 'reunioes'
      when type_text like 'project%' then 'projetos'
      when type_text like 'event%' then 'eventos'
      else 'sistema'
    end;
  end if;

  if new.priority is null or btrim(new.priority) = '' then
    new.priority := 'normal';
  end if;

  if type_text in ('reservation_decided', 'profile_request')
     and new.priority = 'normal' then
    new.priority := 'alta';
  end if;

  new.metadata := coalesce(new.metadata, '{}'::jsonb);
  return new;
end;
$$;

drop trigger if exists notifications_normalize_before_write
on public.notifications;
create trigger notifications_normalize_before_write
before insert or update of type, category, priority, metadata
on public.notifications
for each row execute function public.nexlab_normalize_notification();

-- -----------------------------------------------------------------------------
-- 6. Preferências padrão
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_ensure_notification_preferences()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  standard_type text;
  standard_types text[] := array[
    '*',
    'profile_request',
    'profile_updated',
    'reservation_created',
    'reservation_decided',
    'feedback_created',
    'feedback_updated',
    'feedback_assigned',
    'system'
  ];
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.' using errcode = '42501';
  end if;

  foreach standard_type in array standard_types
  loop
    insert into public.notification_preferences (
      user_id,
      notification_type,
      email_enabled,
      push_enabled
    )
    select
      p.id,
      standard_type,
      false,
      false
    from public.profiles p
    where p.id::text = auth.uid()::text
    on conflict (user_id, notification_type) do nothing;
  end loop;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.nexlab_ensure_notification_preferences()
from public;
grant execute on function public.nexlab_ensure_notification_preferences()
to authenticated;

-- -----------------------------------------------------------------------------
-- 7. Ações individuais e em lote na Central de Notificações
-- -----------------------------------------------------------------------------

create or replace function public.notification_bulk_action(
  p_ids text[],
  p_action text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  affected integer := 0;
  action_text text := lower(coalesce(p_action, ''));
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.' using errcode = '42501';
  end if;

  if coalesce(array_length(p_ids, 1), 0) = 0 then
    return jsonb_build_object('affected', 0, 'action', action_text);
  end if;

  if action_text = 'read' then
    update public.notifications
       set is_read = true,
           read_at = coalesce(read_at, now())
     where recipient_id::text = auth.uid()::text
       and id::text = any(p_ids);
  elsif action_text = 'unread' then
    update public.notifications
       set is_read = false,
           read_at = null
     where recipient_id::text = auth.uid()::text
       and id::text = any(p_ids);
  elsif action_text = 'archive' then
    update public.notifications
       set archived_at = coalesce(archived_at, now())
     where recipient_id::text = auth.uid()::text
       and id::text = any(p_ids);
  elsif action_text = 'restore' then
    update public.notifications
       set archived_at = null
     where recipient_id::text = auth.uid()::text
       and id::text = any(p_ids);
  else
    raise exception 'Ação de notificação inválida: %', p_action
      using errcode = '22023';
  end if;

  get diagnostics affected = row_count;

  return jsonb_build_object(
    'affected', affected,
    'action', action_text
  );
end;
$$;

revoke all on function public.notification_bulk_action(text[], text)
from public;
grant execute on function public.notification_bulk_action(text[], text)
to authenticated;

-- -----------------------------------------------------------------------------
-- 8. Registro e desativação de inscrições Web Push
-- -----------------------------------------------------------------------------

create or replace function public.save_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_expiration_time bigint default null,
  p_user_agent text default null,
  p_platform text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  saved_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.' using errcode = '42501';
  end if;

  if nullif(btrim(p_endpoint), '') is null
     or nullif(btrim(p_p256dh), '') is null
     or nullif(btrim(p_auth), '') is null then
    raise exception 'Inscrição push incompleta.' using errcode = '22023';
  end if;

  insert into public.push_subscriptions (
    user_id,
    endpoint,
    p256dh,
    auth,
    expiration_time,
    user_agent,
    platform,
    active,
    last_seen_at
  )
  select
    p.id,
    p_endpoint,
    p_p256dh,
    p_auth,
    p_expiration_time,
    nullif(p_user_agent, ''),
    nullif(p_platform, ''),
    true,
    now()
  from public.profiles p
  where p.id::text = auth.uid()::text
  on conflict (endpoint) do update
    set user_id = excluded.user_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        expiration_time = excluded.expiration_time,
        user_agent = excluded.user_agent,
        platform = excluded.platform,
        active = true,
        last_seen_at = now(),
        updated_at = now()
  returning id into saved_id;

  return jsonb_build_object('id', saved_id, 'active', true);
end;
$$;

revoke all on function public.save_push_subscription(text, text, text, bigint, text, text)
from public;
grant execute on function public.save_push_subscription(text, text, text, bigint, text, text)
to authenticated;

create or replace function public.disable_push_subscription(
  p_endpoint text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  affected integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.' using errcode = '42501';
  end if;

  update public.push_subscriptions
     set active = false,
         updated_at = now()
   where endpoint = p_endpoint
     and user_id::text = auth.uid()::text;

  get diagnostics affected = row_count;
  return jsonb_build_object('affected', affected);
end;
$$;

revoke all on function public.disable_push_subscription(text)
from public;
grant execute on function public.disable_push_subscription(text)
to authenticated;

-- -----------------------------------------------------------------------------
-- 9. Fila automática para e-mail e push
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
  notification_type_text text := lower(coalesce(new.type::text, 'system'));
begin
  select
    coalesce(pref.email_enabled, false),
    coalesce(pref.push_enabled, false)
  into
    preference_email,
    preference_push
  from public.notification_preferences pref
  where pref.user_id = new.recipient_id
    and pref.notification_type in (notification_type_text, '*')
  order by case when pref.notification_type = notification_type_text then 0 else 1 end
  limit 1;

  preference_email := coalesce(preference_email, false);
  preference_push := coalesce(preference_push, false);

  if preference_email and coalesce(new.email_eligible, true) then
    insert into public.notification_deliveries (
      notification_id,
      recipient_id,
      channel,
      payload
    )
    values (
      new.id,
      new.recipient_id,
      'email',
      jsonb_build_object(
        'notification_id', new.id::text,
        'type', new.type::text,
        'title', new.title,
        'message', new.message,
        'target_tab', new.target_tab,
        'entity_type', new.entity_type::text,
        'entity_id', new.entity_id::text,
        'category', new.category,
        'priority', new.priority,
        'created_at', new.created_at
      )
    )
    on conflict (notification_id, channel) do nothing;
  end if;

  if preference_push
     and coalesce(new.push_eligible, true)
     and exists (
       select 1
       from public.push_subscriptions subscription
       where subscription.user_id = new.recipient_id
         and subscription.active
     ) then
    insert into public.notification_deliveries (
      notification_id,
      recipient_id,
      channel,
      payload
    )
    values (
      new.id,
      new.recipient_id,
      'push',
      jsonb_build_object(
        'notification_id', new.id::text,
        'type', new.type::text,
        'title', new.title,
        'message', new.message,
        'target_tab', new.target_tab,
        'entity_type', new.entity_type::text,
        'entity_id', new.entity_id::text,
        'category', new.category,
        'priority', new.priority,
        'created_at', new.created_at
      )
    )
    on conflict (notification_id, channel) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists notifications_enqueue_external_delivery
on public.notifications;
create trigger notifications_enqueue_external_delivery
after insert on public.notifications
for each row execute function public.nexlab_enqueue_external_delivery();

-- -----------------------------------------------------------------------------
-- 10. Notificação de teste do próprio usuário
-- -----------------------------------------------------------------------------

create or replace function public.create_test_notification()
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  inserted_id text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.' using errcode = '42501';
  end if;

  insert into public.notifications (
    recipient_id,
    type,
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
    'Teste de notificações do NexLab',
    'Se este aviso apareceu, a notificação interna está funcionando. Os canais externos serão processados conforme suas preferências.',
    'notificacoes',
    format('notification-test:%s:%s', auth.uid(), gen_random_uuid()),
    'sistema',
    'normal',
    jsonb_build_object('test', true, 'requested_at', now())
  from public.profiles p
  where p.id::text = auth.uid()::text
  returning id::text into inserted_id;

  return inserted_id;
end;
$$;

revoke all on function public.create_test_notification()
from public;
grant execute on function public.create_test_notification()
to authenticated;

-- -----------------------------------------------------------------------------
-- 11. Realtime para as novas tabelas, sem falhar se já estiverem publicadas
-- -----------------------------------------------------------------------------

do $$
begin
  begin
    alter publication supabase_realtime add table public.notification_deliveries;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.push_subscriptions;
  exception
    when duplicate_object then null;
  end;
end
$$;

commit;

-- Validação rápida:
-- select * from public.notification_preferences where user_id::text = auth.uid()::text;
-- select * from public.push_subscriptions where user_id::text = auth.uid()::text;
-- select * from public.notification_deliveries order by created_at desc limit 20;
