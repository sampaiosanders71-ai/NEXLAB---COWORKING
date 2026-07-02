-- NexLab v25.15.0 — Rollback controlado
-- Use somente se a v25.15 precisar ser removida antes da publicação.

begin;

-- Remove os itens adicionais do checklist.
delete from public.nexlab_production_checklist
where check_key in (
  'accessibility_review',
  'responsive_overflow_review',
  'critical_actions_review',
  'permissions_profiles_review',
  'final_logs_review'
);

-- Remove o registro da versão RC.
delete from public.nexlab_app_versions
where version = '25.15.0';

-- Restaura o diagnóstico original da v25.14.
drop function if exists
  public.nexlab_get_production_readiness(jsonb);

alter function
  public.nexlab_get_production_readiness_v25_14(jsonb)
  rename to nexlab_get_production_readiness;

grant execute
on function public.nexlab_get_production_readiness(jsonb)
to authenticated;

update public.nexlab_app_versions
set
  release_status = 'stable',
  notes = 'Versão estável restaurada após reversão da v25.15.'
where version = '25.14.0';

notify pgrst, 'reload schema';

commit;

-- Após este rollback, reexecute o SQL original da v25.14 para restaurar
-- integralmente nexlab_record_production_snapshot, caso ele tenha sido usado.
