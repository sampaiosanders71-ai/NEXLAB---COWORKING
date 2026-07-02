-- NexLab v25.10.0 — Reversão técnica
-- Use apenas se for necessário voltar ao HTML v25.9.1.
-- Os cargos que já foram aprovados não são revertidos automaticamente.

begin;

drop trigger if exists nexlab_after_profile_registration_trigger on public.profiles;
drop trigger if exists nexlab_guard_profile_role_fields_trigger on public.profiles;

drop function if exists public.nexlab_after_profile_registration();
drop function if exists public.nexlab_guard_profile_role_fields();
drop function if exists public.nexlab_review_profile_request(text, boolean, text);
drop function if exists public.nexlab_complete_profile_registration(text, text, text, text, text);
drop function if exists public.nexlab_profile_flow_notification(text, text, text, text, text, text, jsonb);
drop function if exists public.nexlab_profile_role_label(text);

drop table if exists public.profile_role_requests cascade;

alter table public.profiles
  drop constraint if exists profiles_role_request_status_check,
  drop column if exists role_request_status,
  drop column if exists role_request_reason,
  drop column if exists role_request_created_at,
  drop column if exists role_request_reviewed_at,
  drop column if exists role_request_reviewed_by;

delete from public.nexlab_app_versions where version = '25.10.0';

commit;
