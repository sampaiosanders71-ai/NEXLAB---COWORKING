-- NexLab v25.12.0 — Rollback técnico
-- Execute somente se for necessário retornar à v25.11.1.

begin;

drop trigger if exists nexlab_recalculate_permissions_after_profile_insert_trigger on public.profiles;
drop trigger if exists nexlab_recalculate_permissions_after_role_change_trigger on public.profiles;

drop function if exists public.nexlab_recalculate_permissions_after_role_change();
drop function if exists public.nexlab_admin_restore_user_permissions(text, text);
drop function if exists public.nexlab_admin_save_user_permissions(text, jsonb, text);
drop function if exists public.nexlab_admin_save_role_permissions(text, jsonb, text);
drop function if exists public.nexlab_get_permission_matrix();
drop function if exists public.nexlab_recalculate_all_permissions();
drop function if exists public.nexlab_recalculate_profile_permissions(text);

drop table if exists public.nexlab_permission_history;
drop table if exists public.nexlab_user_permission_overrides;
drop table if exists public.nexlab_role_permission_defaults;
drop table if exists public.nexlab_permission_catalog;

alter table public.profiles drop column if exists effective_permissions;

delete from public.nexlab_app_versions where version = '25.12.0';

update public.nexlab_app_versions
set release_status = 'stable'
where version = '25.11.1';

commit;
