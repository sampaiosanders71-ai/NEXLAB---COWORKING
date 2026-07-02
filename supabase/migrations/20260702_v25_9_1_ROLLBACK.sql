-- NexLab v25.9.1 — Reversão apenas das policies adicionais desta versão.
-- Atenção: a reversão volta a depender das policies anteriores existentes.

begin;

do $$
begin
  if to_regclass('public.logs') is not null then
    execute 'drop policy if exists nexlab_logs_admin_select on public.logs';
    execute 'drop policy if exists nexlab_logs_admin_select_restrictive on public.logs';
  end if;

  if to_regclass('public.security_audit_logs') is not null then
    execute 'drop policy if exists nexlab_security_audit_admin_select on public.security_audit_logs';
    execute 'drop policy if exists nexlab_security_audit_admin_select_restrictive on public.security_audit_logs';
  end if;

  if to_regclass('public.notification_deliveries') is not null then
    execute 'drop policy if exists nexlab_notification_deliveries_admin_select on public.notification_deliveries';
    execute 'drop policy if exists nexlab_notification_deliveries_admin_select_restrictive on public.notification_deliveries';
  end if;

  if to_regclass('public.notification_reminders') is not null then
    execute 'drop policy if exists nexlab_notification_reminders_admin_select on public.notification_reminders';
    execute 'drop policy if exists nexlab_notification_reminders_admin_select_restrictive on public.notification_reminders';
  end if;

  if to_regclass('public.notification_templates') is not null then
    execute 'drop policy if exists nexlab_notification_templates_admin_select on public.notification_templates';
    execute 'drop policy if exists nexlab_notification_templates_admin_select_restrictive on public.notification_templates';
  end if;
end
$$;

delete from public.nexlab_app_versions where version = '25.9.1';

commit;
