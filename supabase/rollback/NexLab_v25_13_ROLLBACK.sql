-- ROLLBACK opcional — NexLab v25.13.0
-- ATENÇÃO: remove também o histórico de exportações registrado nesta versão.

begin;

drop function if exists public.nexlab_get_report_export_history(integer);
drop function if exists public.nexlab_record_report_export(text, text, integer, boolean, jsonb);
drop function if exists public.nexlab_can_access_reports();
drop table if exists public.nexlab_report_exports;

delete from public.nexlab_app_versions
where version = '25.13.0';

notify pgrst, 'reload schema';

commit;
