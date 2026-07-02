-- NexLab v25.14.0 — Rollback
-- Use somente se for necessário remover a versão antes de ela ser usada em produção.

begin;

drop function if exists public.nexlab_quarantine_test_profiles(text[], text, text);
drop function if exists public.nexlab_record_production_snapshot(jsonb);
drop function if exists public.nexlab_get_production_readiness(jsonb);
drop function if exists public.nexlab_update_production_check(text, boolean, text);

drop table if exists public.nexlab_test_cleanup_runs;
drop table if exists public.nexlab_production_snapshots;
drop table if exists public.nexlab_production_checklist;

delete from public.nexlab_app_versions
where version = '25.14.0';

update public.nexlab_app_versions
set
  release_status = 'stable',
  notes = 'Versão testada e aprovada. Governança e histórico de exportações validados.'
where version = '25.13.0';

notify pgrst, 'reload schema';

commit;
