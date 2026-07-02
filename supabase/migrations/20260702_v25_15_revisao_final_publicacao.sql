-- NexLab v25.15.0 — Revisão Final e Acabamento para Publicação
-- Execute integralmente no Supabase SQL Editor após a v25.14.0.
-- Não exige alteração em Edge Functions, Secrets ou Cron.

begin;

-- -----------------------------------------------------------------------------
-- 1. Preserva o diagnóstico da v25.14 e instala um adaptador para a v25.15
-- -----------------------------------------------------------------------------

do $$
begin
  if to_regprocedure(
    'public.nexlab_get_production_readiness_v25_14(jsonb)'
  ) is null then
    if to_regprocedure(
      'public.nexlab_get_production_readiness(jsonb)'
    ) is null then
      raise exception 'A função de prontidão da v25.14 não foi encontrada.';
    end if;

    execute 'alter function public.nexlab_get_production_readiness(jsonb) rename to nexlab_get_production_readiness_v25_14';
  end if;
end
$$;

revoke all
on function public.nexlab_get_production_readiness_v25_14(jsonb)
from public;

create or replace function public.nexlab_get_production_readiness(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, cron
as $$
declare
  expected_version constant text := '25.15.0';
  base_result jsonb;
  patched_checks jsonb := '[]'::jsonb;
  database_version text;
  client_version text;
  required_checks integer := 0;
  passed_checks integer := 0;
  blocking_checks integer := 0;
  attention_checks integer := 0;
  score integer := 0;
  readiness_status text := 'attention';
begin
  if auth.uid() is null
     or not public.nexlab_is_admin()
  then
    raise exception 'Ação exclusiva de Administradores.'
      using errcode = '42501';
  end if;

  base_result :=
    public.nexlab_get_production_readiness_v25_14(
      coalesce(p_client_context, '{}'::jsonb)
    );

  database_version := coalesce(
    base_result->>'database_version',
    'não registrada'
  );

  client_version := coalesce(
    nullif(
      coalesce(p_client_context, '{}'::jsonb)
        ->>'client_app_version',
      ''
    ),
    'não informado'
  );

  select coalesce(
    jsonb_agg(
      case
        when item->>'id' = 'version' then
          item || jsonb_build_object(
            'status',
            case
              when database_version = expected_version
               and client_version = expected_version
                then 'pass'
              else 'fail'
            end,
            'message',
            format(
              'Banco: v%s • Aplicativo: v%s • Esperado: v%s',
              database_version,
              client_version,
              expected_version
            )
          )
        else item
      end
    ),
    '[]'::jsonb
  )
  into patched_checks
  from jsonb_array_elements(
    coalesce(base_result->'checks', '[]'::jsonb)
  ) item;

  select
    count(*) filter (
      where coalesce(
        (item->>'required')::boolean,
        false
      )
    ),
    count(*) filter (
      where coalesce(
        (item->>'required')::boolean,
        false
      )
      and item->>'status' = 'pass'
    ),
    count(*) filter (
      where coalesce(
        (item->>'required')::boolean,
        false
      )
      and item->>'status' = 'fail'
    ),
    count(*) filter (
      where item->>'status'
        in ('pending', 'warning')
    )
  into
    required_checks,
    passed_checks,
    blocking_checks,
    attention_checks
  from jsonb_array_elements(patched_checks) item;

  score := case
    when required_checks = 0 then 0
    else floor(
      (
        passed_checks::numeric
        / required_checks::numeric
      ) * 100
    )::integer
  end;

  readiness_status := case
    when blocking_checks > 0
      then 'blocked'
    when passed_checks = required_checks
      then 'ready'
    else 'attention'
  end;

  base_result := jsonb_set(
    base_result,
    '{expected_version}',
    to_jsonb(expected_version),
    true
  );

  base_result := jsonb_set(
    base_result,
    '{client_context}',
    coalesce(p_client_context, '{}'::jsonb),
    true
  );

  base_result := jsonb_set(
    base_result,
    '{checks}',
    patched_checks,
    true
  );

  base_result := jsonb_set(
    base_result,
    '{score}',
    to_jsonb(score),
    true
  );

  base_result := jsonb_set(
    base_result,
    '{status}',
    to_jsonb(readiness_status),
    true
  );

  base_result := jsonb_set(
    base_result,
    '{summary}',
    jsonb_build_object(
      'required_checks',
      required_checks,
      'passed_checks',
      passed_checks,
      'blocking_checks',
      blocking_checks,
      'attention_checks',
      attention_checks
    ),
    true
  );

  return base_result;
end;
$$;

revoke all
on function public.nexlab_get_production_readiness(jsonb)
from public;

grant execute
on function public.nexlab_get_production_readiness(jsonb)
to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Snapshot passa a usar o diagnóstico adaptado da v25.15
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_record_production_snapshot(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  readiness jsonb;
  snapshot_id uuid;
begin
  if auth.uid() is null
     or not public.nexlab_is_admin()
  then
    raise exception 'Ação exclusiva de Administradores.'
      using errcode = '42501';
  end if;

  readiness :=
    public.nexlab_get_production_readiness(
      coalesce(
        p_client_context,
        '{}'::jsonb
      )
    );

  insert into public.nexlab_production_snapshots (
    app_version,
    readiness_status,
    score,
    client_context,
    snapshot,
    created_by
  )
  values (
    coalesce(
      readiness->>'database_version',
      '25.15.0'
    ),
    readiness->>'status',
    coalesce(
      (readiness->>'score')::integer,
      0
    ),
    coalesce(
      p_client_context,
      '{}'::jsonb
    ),
    readiness,
    auth.uid()
  )
  returning id
  into snapshot_id;

  perform public.nexlab_record_system_event(
    'production_readiness_snapshot',
    case
      when readiness->>'status' = 'ready'
        then 'success'
      else 'warning'
    end,
    format(
      'Diagnóstico de prontidão v25.15 registrado com pontuação %s%%.',
      readiness->>'score'
    ),
    jsonb_build_object(
      'snapshot_id',
      snapshot_id,
      'status',
      readiness->>'status',
      'score',
      readiness->>'score',
      'app_version',
      readiness->>'database_version'
    )
  );

  return jsonb_build_object(
    'ok',
    true,
    'snapshot_id',
    snapshot_id,
    'readiness',
    readiness
  );
end;
$$;

revoke all
on function public.nexlab_record_production_snapshot(jsonb)
from public;

grant execute
on function public.nexlab_record_production_snapshot(jsonb)
to authenticated;

-- -----------------------------------------------------------------------------
-- 3. Checklist final ampliado
-- -----------------------------------------------------------------------------

insert into public.nexlab_production_checklist (
  check_key,
  label,
  description,
  required,
  sort_order,
  updated_at
)
values
  (
    'accessibility_review',
    'Acessibilidade e teclado revisados',
    'Executar a Revisão final e validar foco, rótulos e navegação por teclado.',
    true,
    110,
    now()
  ),
  (
    'responsive_overflow_review',
    'Responsividade e overflow revisados',
    'Validar telas principais, tabelas e modais no computador e no celular.',
    true,
    120,
    now()
  ),
  (
    'critical_actions_review',
    'Ações críticas revisadas',
    'Confirmar mensagens, motivos obrigatórios e proteções contra ações acidentais.',
    true,
    130,
    now()
  ),
  (
    'permissions_profiles_review',
    'Perfis e permissões revisados',
    'Repetir o teste de acesso com Administrador, Coordenador, Bolsista e Coworking Júnior.',
    true,
    140,
    now()
  ),
  (
    'final_logs_review',
    'Logs finais sem novos erros',
    'Confirmar que os testes finais não geraram novos erros no PostgreSQL ou nas Edge Functions.',
    true,
    150,
    now()
  )
on conflict (check_key) do update
set
  label = excluded.label,
  description = excluded.description,
  required = excluded.required,
  sort_order = excluded.sort_order,
  updated_at = now();

-- -----------------------------------------------------------------------------
-- 4. Registro da versão
-- -----------------------------------------------------------------------------

update public.nexlab_app_versions
set
  release_status = 'stable',
  notes = 'Versão testada e aprovada. Integridade e preparação para produção validadas.'
where version = '25.14.0';

insert into public.nexlab_app_versions (
  version,
  title,
  release_status,
  notes
)
values (
  '25.15.0',
  'Revisão Final e Acabamento para Publicação',
  'rc',
  'Auditoria local do frontend, acessibilidade, responsividade, conectividade, proteção contra cliques duplicados e checklist final ampliado.'
)
on conflict (version) do update
set
  title = excluded.title,
  release_status = excluded.release_status,
  notes = excluded.notes,
  installed_at = now(),
  installed_by = auth.uid();

notify pgrst, 'reload schema';

commit;
