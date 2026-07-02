-- NexLab v25.8 — Reversão para a estrutura da v25.7
-- Use somente se for necessário desfazer a v25.8.
-- Execute integralmente no SQL Editor do Supabase.

begin;

-- 1. Remove o Cron de lembretes da v25.8.
do $$
declare
  existing_job bigint;
begin
  select jobid
    into existing_job
  from cron.job
  where jobname = 'nexlab-process-due-reminders'
  limit 1;

  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;
exception
  when undefined_table or invalid_schema_name then
    null;
end
$$;

-- 2. Restaura a fila externa usada na v25.7 antes de remover as estruturas v25.8.
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
  order by
    case
      when pref.notification_type = notification_type_text then 0
      else 1
    end
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
    )
  then
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

-- 3. Remove funções exclusivas da v25.8.
drop function if exists public.get_notification_metrics(integer);
drop function if exists public.retry_notification_delivery(text);
drop function if exists public.nexlab_process_due_reminders(integer);
drop function if exists public.nexlab_render_notification_template(text, jsonb);
drop function if exists public.nexlab_next_delivery_time(text, timestamptz);
drop function if exists public.nexlab_ensure_notification_user_settings();

-- 4. Remove tabelas e dados exclusivos da v25.8.
drop table if exists public.notification_reminders cascade;
drop table if exists public.notification_templates cascade;
drop table if exists public.notification_user_settings cascade;

-- 5. Remove as colunas adicionadas pela v25.8.
alter table public.notification_preferences
  drop column if exists muted_until,
  drop column if exists muted;

alter table public.notifications
  drop column if exists preference_key;

commit;
