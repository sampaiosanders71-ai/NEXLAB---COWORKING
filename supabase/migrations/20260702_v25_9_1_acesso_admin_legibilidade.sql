-- NexLab v25.9.1 — Acesso Administrativo e Legibilidade
-- Execute integralmente no Supabase SQL Editor após as migrations até v25.9.

begin;

-- -----------------------------------------------------------------------------
-- 1. Central de Atividades: leitura exclusiva de Administradores
-- -----------------------------------------------------------------------------

do $$
begin
  if to_regclass('public.logs') is not null then
    execute 'alter table public.logs enable row level security';

    execute 'drop policy if exists nexlab_logs_admin_select on public.logs';
    execute 'drop policy if exists nexlab_logs_admin_select_restrictive on public.logs';

    execute $policy$
      create policy nexlab_logs_admin_select
      on public.logs
      for select
      to authenticated
      using (public.nexlab_is_admin())
    $policy$;

    execute $policy$
      create policy nexlab_logs_admin_select_restrictive
      on public.logs
      as restrictive
      for select
      to authenticated
      using (public.nexlab_is_admin())
    $policy$;
  end if;

  if to_regclass('public.security_audit_logs') is not null then
    execute 'alter table public.security_audit_logs enable row level security';

    execute 'drop policy if exists nexlab_security_audit_admin_select on public.security_audit_logs';
    execute 'drop policy if exists nexlab_security_audit_admin_select_restrictive on public.security_audit_logs';

    execute $policy$
      create policy nexlab_security_audit_admin_select
      on public.security_audit_logs
      for select
      to authenticated
      using (public.nexlab_is_admin())
    $policy$;

    execute $policy$
      create policy nexlab_security_audit_admin_select_restrictive
      on public.security_audit_logs
      as restrictive
      for select
      to authenticated
      using (public.nexlab_is_admin())
    $policy$;

    revoke delete on public.security_audit_logs from anon, authenticated;
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- 2. Dados técnicos de notificações: exclusivos de Administradores
--    A Caixa de Entrada e as preferências pessoais permanecem disponíveis.
-- -----------------------------------------------------------------------------

do $$
begin
  if to_regclass('public.notification_deliveries') is not null then
    execute 'alter table public.notification_deliveries enable row level security';

    execute 'drop policy if exists nexlab_notification_deliveries_admin_select on public.notification_deliveries';
    execute 'drop policy if exists nexlab_notification_deliveries_admin_select_restrictive on public.notification_deliveries';

    execute $policy$
      create policy nexlab_notification_deliveries_admin_select
      on public.notification_deliveries
      for select
      to authenticated
      using (public.nexlab_is_admin())
    $policy$;

    execute $policy$
      create policy nexlab_notification_deliveries_admin_select_restrictive
      on public.notification_deliveries
      as restrictive
      for select
      to authenticated
      using (public.nexlab_is_admin())
    $policy$;
  end if;

  if to_regclass('public.notification_reminders') is not null then
    execute 'alter table public.notification_reminders enable row level security';

    execute 'drop policy if exists nexlab_notification_reminders_admin_select on public.notification_reminders';
    execute 'drop policy if exists nexlab_notification_reminders_admin_select_restrictive on public.notification_reminders';

    execute $policy$
      create policy nexlab_notification_reminders_admin_select
      on public.notification_reminders
      for select
      to authenticated
      using (public.nexlab_is_admin())
    $policy$;

    execute $policy$
      create policy nexlab_notification_reminders_admin_select_restrictive
      on public.notification_reminders
      as restrictive
      for select
      to authenticated
      using (public.nexlab_is_admin())
    $policy$;
  end if;

  if to_regclass('public.notification_templates') is not null then
    execute 'alter table public.notification_templates enable row level security';

    execute 'drop policy if exists nexlab_notification_templates_admin_select on public.notification_templates';
    execute 'drop policy if exists nexlab_notification_templates_admin_select_restrictive on public.notification_templates';

    execute $policy$
      create policy nexlab_notification_templates_admin_select
      on public.notification_templates
      for select
      to authenticated
      using (public.nexlab_is_admin())
    $policy$;

    execute $policy$
      create policy nexlab_notification_templates_admin_select_restrictive
      on public.notification_templates
      as restrictive
      for select
      to authenticated
      using (public.nexlab_is_admin())
    $policy$;
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- 3. Registro da versão instalada
-- -----------------------------------------------------------------------------

insert into public.nexlab_app_versions (
  version,
  title,
  release_status,
  notes
)
values (
  '25.9.1',
  'Acesso Administrativo e Legibilidade',
  'rc',
  'Restringe módulos técnicos e recursos avançados de notificações aos Administradores e redesenha a Central de Atividades.'
)
on conflict (version) do update
set
  title = excluded.title,
  release_status = excluded.release_status,
  notes = excluded.notes,
  installed_at = now(),
  installed_by = auth.uid();

commit;

-- Validação opcional:
--
-- select policyname, permissive, cmd
-- from pg_policies
-- where schemaname = 'public'
--   and tablename in (
--     'logs',
--     'security_audit_logs',
--     'notification_deliveries',
--     'notification_reminders',
--     'notification_templates'
--   )
-- order by tablename, policyname;
