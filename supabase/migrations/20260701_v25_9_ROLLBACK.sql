-- NexLab v25.9 — Reversão para v25.8
-- Use somente se precisar remover o módulo Saúde do Sistema.

begin;

drop function if exists public.admin_cleanup_system_data(boolean);
drop function if exists public.admin_create_channel_test(text);
drop function if exists public.admin_run_due_reminders(integer);
drop function if exists public.admin_requeue_notification_queue(boolean);
drop function if exists public.get_system_health_snapshot();
drop function if exists public.nexlab_record_system_event(text, text, text, jsonb);
drop function if exists public.nexlab_system_setting_int(text, integer, integer, integer);
drop function if exists public.nexlab_system_set_updated_at();

drop table if exists public.nexlab_system_events;
drop table if exists public.nexlab_system_settings;

delete from public.nexlab_app_versions where version = '25.9.0';
drop table if exists public.nexlab_app_versions;

commit;

-- Depois, republique a Edge Function da v25.8 e use o HTML/ZIP da v25.8.
