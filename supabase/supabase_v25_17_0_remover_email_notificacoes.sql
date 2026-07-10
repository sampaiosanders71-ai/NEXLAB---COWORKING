-- NEXLAB v25.17.0 — Remoção do canal de notificações por e-mail
-- Execute no Supabase SQL Editor se a base ainda tiver tabelas/colunas das versões de notificações externas.
-- Este script mantém login por e-mail intacto. Remove/desativa apenas notificações por e-mail.

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'notification_preferences'
      and column_name = 'email_enabled'
  ) then
    execute 'update public.notification_preferences set email_enabled = false where coalesce(email_enabled, false) = true';
  end if;
end $$;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'notification_templates'
      and column_name = 'email_subject_template'
  ) then
    execute 'update public.notification_templates set email_subject_template = null where email_subject_template is not null';
  end if;
end $$;

do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public'
      and table_name = 'notification_deliveries'
  ) then
    execute $q$
      update public.notification_deliveries
         set status = case
           when status in ('pending','processing','queued','failed') then 'skipped'
           else status
         end,
         last_error = coalesce(last_error, 'Canal de notificações por e-mail removido na v25.17.0'),
         updated_at = now()
       where channel = 'email'
         and status in ('pending','processing','queued','failed')
    $q$;
  end if;
end $$;
