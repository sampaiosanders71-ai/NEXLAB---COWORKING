-- NEXLAB v26.13.0 — Patrimônio / Etapa 3 (correções 2 a 5)
--
-- Correção 2: histórico de movimentações e localização preservado e
--             integrado ao canal Realtime dedicado.
-- Correção 3: links externos preservados no cadastro, manutenção e movimentação.
-- Correção 4: Realtime dedicado para assets, asset_maintenance e asset_movements.
-- Correção 5: paginação, ordenação e busca executadas no servidor pela Data API
--             do Supabase, com RLS, count exato, order e range.
--
-- Este arquivo é idempotente e serve para backup/reinstalação. No projeto Nexlab,
-- as alterações desta versão já foram executadas em blocos SQL menores e validadas.

-- =============================================================================
-- 1) Índices usados pelos filtros, ordenação e históricos
-- =============================================================================

create index if not exists assets_updated_at_desc_idx
  on public.assets (updated_at desc, id);

create index if not exists assets_name_lower_idx
  on public.assets (lower(nome), id);

create index if not exists assets_category_idx
  on public.assets (categoria, id);

create index if not exists assets_acquisition_date_desc_idx
  on public.assets (data_aquisicao desc nulls last, id);

create index if not exists assets_acquisition_value_desc_idx
  on public.assets (valor_aquisicao desc, id);

create index if not exists assets_responsavel_idx
  on public.assets (responsavel_id, id);

create index if not exists assets_condition_idx
  on public.assets (
    inconsistente,
    quantidade_manutencao,
    quantidade_danificada,
    id
  );

-- O índice asset_maintenance_asset_date_idx já existia com a mesma estrutura.
-- Remove uma possível duplicata criada durante a implementação iterativa.
drop index if exists public.asset_maintenance_asset_created_idx;

create index if not exists asset_maintenance_responsavel_idx
  on public.asset_maintenance (responsavel_id, id);

create index if not exists asset_movements_actor_idx
  on public.asset_movements (actor_id, id);

create index if not exists asset_movements_origem_responsavel_idx
  on public.asset_movements (origem_responsavel_id, id);

create index if not exists asset_movements_destino_responsavel_idx
  on public.asset_movements (destino_responsavel_id, id);

create index if not exists asset_movements_asset_date_idx
  on public.asset_movements (
    asset_id,
    data_movimentacao desc,
    created_at desc
  );

-- =============================================================================
-- 2) Resumo global independente da página atual
-- =============================================================================

create or replace function public.nexlab_get_asset_summary_v26130()
returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select case
    when auth.uid() is null
      or not public.nexlab_has_permission_v26100('module_patrimonio')
      or not public.nexlab_has_permission_v26100('patrimonio_view')
    then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'total', count(*),
      'available', count(*) filter (
        where not inconsistente
          and quantidade_manutencao = 0
          and quantidade_danificada = 0
      ),
      'maintenance', count(*) filter (
        where not inconsistente
          and quantidade_manutencao = 1
      ),
      'damaged', count(*) filter (
        where not inconsistente
          and quantidade_danificada = 1
      ),
      'inconsistent', count(*) filter (where inconsistente),
      'value', coalesce(sum(valor_aquisicao), 0)
    )
  end
  from public.assets;
$function$;

revoke execute on function public.nexlab_get_asset_summary_v26130()
from public, anon;

grant execute on function public.nexlab_get_asset_summary_v26130()
to authenticated, service_role;

-- =============================================================================
-- 3) Verificação de duplicidade em todo o catálogo, não apenas na página aberta
-- =============================================================================

create or replace function public.nexlab_check_asset_duplicates_v26130(
  p_asset_id uuid,
  p_tombamento text,
  p_numero_serie text,
  p_nome text,
  p_marca text,
  p_modelo text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select case
    when auth.uid() is null
      or not public.nexlab_has_permission_v26100('module_patrimonio')
      or not public.nexlab_has_permission_v26100('patrimonio_manage')
    then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'exact', coalesce((
        select jsonb_build_object(
          'id', a.id,
          'nome', a.nome,
          'codigo_patrimonial', a.codigo_patrimonial
        )
        from public.assets a
        where (p_asset_id is null or a.id <> p_asset_id)
          and (
            lower(btrim(a.tombamento)) =
              lower(btrim(coalesce(p_tombamento, '')))
            or (
              nullif(btrim(coalesce(p_numero_serie, '')), '') is not null
              and lower(btrim(coalesce(a.numero_serie, ''))) =
                  lower(btrim(p_numero_serie))
            )
          )
        order by a.created_at
        limit 1
      ), 'null'::jsonb),
      'probable_count', (
        select count(*)
        from public.assets a
        where (p_asset_id is null or a.id <> p_asset_id)
          and lower(btrim(a.nome)) =
              lower(btrim(coalesce(p_nome, '')))
          and lower(btrim(coalesce(a.marca, ''))) =
              lower(btrim(coalesce(p_marca, '')))
          and lower(btrim(coalesce(a.modelo, ''))) =
              lower(btrim(coalesce(p_modelo, '')))
      )
    )
  end;
$function$;

revoke execute on function public.nexlab_check_asset_duplicates_v26130(
  uuid,
  text,
  text,
  text,
  text,
  text
)
from public, anon;

grant execute on function public.nexlab_check_asset_duplicates_v26130(
  uuid,
  text,
  text,
  text,
  text,
  text
)
to authenticated, service_role;

-- =============================================================================
-- 4) Realtime dedicado
-- =============================================================================
-- As políticas SELECT criadas na v26.12.0 continuam controlando quais usuários
-- podem receber alterações. Nenhuma permissão de INSERT/UPDATE/DELETE direta é
-- concedida às tabelas de histórico.

do $block$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'assets'
  ) then
    alter publication supabase_realtime add table public.assets;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'asset_maintenance'
  ) then
    alter publication supabase_realtime
      add table public.asset_maintenance;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'asset_movements'
  ) then
    alter publication supabase_realtime
      add table public.asset_movements;
  end if;
end;
$block$;
