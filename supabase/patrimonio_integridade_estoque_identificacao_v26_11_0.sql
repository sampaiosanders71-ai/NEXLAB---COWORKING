-- NEXLAB v26.11.0 — Patrimônio / Integridade, Estoque e Identificação Individual
-- Etapa 1: correções 5 e 6
--   5. Não corrigir dados inválidos silenciosamente.
--   6. Constraints e saneamento explícito dos registros existentes.
-- Etapa 2: correções 1 e 2
--   1. Separar Patrimônio de Estoque/Consumíveis.
--   2. Identificar individualmente cada bem durável.

-- =============================================================================
-- 1) Permissões do novo módulo Estoque
-- =============================================================================

insert into public.nexlab_permission_catalog (
  permission_key, label, description, category, module_id,
  core, admin_only, grantable, eligible_roles, sort_order, active, updated_at
)
values
  (
    'module_estoque', 'Estoque',
    'Acesso ao módulo separado de estoque e consumíveis.',
    'Operação', 'estoque', false, false, true,
    array['admin','coordenador','bolsista','coworking_junior']::text[],
    135, true, now()
  ),
  (
    'estoque_view', 'Consultar estoque',
    'Permite visualizar itens, saldos e alertas do estoque.',
    'Estoque', 'estoque', false, false, true,
    array['admin','coordenador','bolsista','coworking_junior']::text[],
    136, true, now()
  ),
  (
    'estoque_manage', 'Gerenciar estoque',
    'Permite cadastrar e atualizar itens e saldos do estoque.',
    'Estoque', 'estoque', false, false, true,
    array['admin','coordenador','bolsista','coworking_junior']::text[],
    137, true, now()
  )
on conflict (permission_key) do update
set
  label = excluded.label,
  description = excluded.description,
  category = excluded.category,
  module_id = excluded.module_id,
  core = excluded.core,
  admin_only = excluded.admin_only,
  grantable = excluded.grantable,
  eligible_roles = excluded.eligible_roles,
  sort_order = excluded.sort_order,
  active = excluded.active,
  updated_at = now();

insert into public.nexlab_role_permission_defaults (
  role_key, permission_key, allowed, updated_by, updated_at
)
values
  ('admin', 'module_estoque', true, null, now()),
  ('admin', 'estoque_view', true, null, now()),
  ('admin', 'estoque_manage', true, null, now()),
  ('coordenador', 'module_estoque', true, null, now()),
  ('coordenador', 'estoque_view', true, null, now()),
  ('coordenador', 'estoque_manage', true, null, now()),
  ('bolsista', 'module_estoque', false, null, now()),
  ('bolsista', 'estoque_view', false, null, now()),
  ('bolsista', 'estoque_manage', false, null, now()),
  ('coworking_junior', 'module_estoque', false, null, now()),
  ('coworking_junior', 'estoque_view', false, null, now()),
  ('coworking_junior', 'estoque_manage', false, null, now())
on conflict (role_key, permission_key) do update
set
  allowed = excluded.allowed,
  updated_by = excluded.updated_by,
  updated_at = excluded.updated_at;

-- =============================================================================
-- 2) Tabelas de estoque e rastreio do saneamento
-- =============================================================================

create table if not exists public.stock_items (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  descricao text,
  categoria text not null default 'Consumível',
  quantidade integer not null default 0,
  unidade_medida text not null default 'unidade',
  estoque_minimo integer not null default 0,
  localizacao text,
  valor_unitario numeric(18,2) not null default 0,
  source_asset_id uuid unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint stock_items_nome_length_check
    check (char_length(btrim(nome)) between 2 and 160),
  constraint stock_items_descricao_length_check
    check (descricao is null or char_length(descricao) <= 2000),
  constraint stock_items_localizacao_length_check
    check (localizacao is null or char_length(localizacao) <= 180),
  constraint stock_items_unidade_length_check
    check (char_length(btrim(unidade_medida)) between 1 and 40),
  constraint stock_items_quantidade_check check (quantidade >= 0),
  constraint stock_items_estoque_minimo_check check (estoque_minimo >= 0),
  constraint stock_items_valor_unitario_check check (valor_unitario >= 0)
);

create index if not exists stock_items_nome_idx
  on public.stock_items (lower(nome));
create index if not exists stock_items_alerta_idx
  on public.stock_items (quantidade, estoque_minimo);

create table if not exists public.nexlab_asset_sanitation_log (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid,
  issue text not null,
  action_taken text not null,
  before_data jsonb not null default '{}'::jsonb,
  after_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.stock_items enable row level security;
alter table public.nexlab_asset_sanitation_log enable row level security;

-- =============================================================================
-- 3) Novos campos patrimoniais e sequência de código individual
-- =============================================================================

create sequence if not exists public.nexlab_asset_code_seq start 1;

alter table public.assets
  add column if not exists codigo_patrimonial text,
  add column if not exists tombamento text,
  add column if not exists inconsistente boolean not null default false,
  add column if not exists inconsistencia_motivo text,
  add column if not exists updated_at timestamptz not null default now();

create or replace function public.nexlab_next_asset_code_v26110()
returns text
language sql
volatile
security definer
set search_path = ''
as $function$
  select 'NXL-PAT-' || lpad(nextval('public.nexlab_asset_code_seq')::text, 6, '0');
$function$;

revoke execute on function public.nexlab_next_asset_code_v26110()
from public, anon, authenticated;
grant execute on function public.nexlab_next_asset_code_v26110()
to service_role;

-- =============================================================================
-- 4) Saneamento explícito e separação de consumíveis
-- =============================================================================

-- Registra previamente todos os casos que exigem transformação.
insert into public.nexlab_asset_sanitation_log (
  asset_id, issue, action_taken, before_data
)
select
  a.id,
  concat_ws('; ',
    case when lower(btrim(coalesce(a.categoria,''))) in ('consumível','consumivel')
      then 'Consumível misturado ao patrimônio' end,
    case when coalesce(a.quantidade,0) <> 1
      then 'Bem durável agrupado ou quantidade inválida' end,
    case when coalesce(a.quantidade_manutencao,0) < 0
          or coalesce(a.quantidade_danificada,0) < 0
          or coalesce(a.quantidade_manutencao,0) + coalesce(a.quantidade_danificada,0) > greatest(coalesce(a.quantidade,0),0)
      then 'Condição quantitativa inconsistente' end,
    case when coalesce(a.valor_unitario,0) < 0
      then 'Valor unitário negativo' end,
    case when nullif(btrim(coalesce(a.nome,'')),'') is null
      then 'Nome ausente' end
  ),
  case
    when lower(btrim(coalesce(a.categoria,''))) in ('consumível','consumivel')
      then 'Migrado para stock_items e removido de assets'
    when coalesce(a.quantidade,0) <> 1
      then 'Individualizado em registros unitários com códigos próprios'
    else 'Normalizado pela migration antes das constraints'
  end,
  to_jsonb(a)
from public.assets a
where
  lower(btrim(coalesce(a.categoria,''))) in ('consumível','consumivel')
  or coalesce(a.quantidade,0) <> 1
  or coalesce(a.quantidade_manutencao,0) < 0
  or coalesce(a.quantidade_danificada,0) < 0
  or coalesce(a.quantidade_manutencao,0) + coalesce(a.quantidade_danificada,0) > greatest(coalesce(a.quantidade,0),0)
  or coalesce(a.valor_unitario,0) < 0
  or nullif(btrim(coalesce(a.nome,'')),'') is null;

-- Move consumíveis para o novo módulo de estoque. Saldo zero é permitido.
insert into public.stock_items (
  nome, descricao, categoria, quantidade, unidade_medida,
  estoque_minimo, localizacao, valor_unitario, source_asset_id,
  created_at, updated_at
)
select
  case
    when nullif(btrim(coalesce(a.nome,'')),'') is null then 'Consumível sem nome (legado)'
    else left(btrim(a.nome),160)
  end,
  left(a.descricao,2000),
  'Consumível',
  greatest(coalesce(a.quantidade,0),0),
  'unidade',
  0,
  left(a.localizacao,180),
  greatest(coalesce(a.valor_unitario,0),0),
  a.id,
  a.created_at,
  now()
from public.assets a
where lower(btrim(coalesce(a.categoria,''))) in ('consumível','consumivel')
on conflict (source_asset_id) do nothing;

delete from public.assets a
where lower(btrim(coalesce(a.categoria,''))) in ('consumível','consumivel');

-- Individualiza bens duráveis agrupados. A condição é distribuída entre as unidades.
do $block$
declare
  asset_row public.assets%rowtype;
  unit_index integer;
  unit_id uuid;
  damaged_units integer;
  maintenance_units integer;
  unit_damaged integer;
  unit_maintenance integer;
  legacy_base text;
begin
  for asset_row in
    select * from public.assets
    where coalesce(quantidade,0) > 1
    order by created_at, id
    for update
  loop
    damaged_units := least(greatest(coalesce(asset_row.quantidade_danificada,0),0), asset_row.quantidade);
    maintenance_units := least(
      greatest(coalesce(asset_row.quantidade_manutencao,0),0),
      asset_row.quantidade - damaged_units
    );
    legacy_base := upper(substr(replace(asset_row.id::text,'-',''),1,10));

    for unit_index in 2..asset_row.quantidade loop
      unit_id := gen_random_uuid();
      unit_damaged := case when unit_index <= damaged_units then 1 else 0 end;
      unit_maintenance := case
        when unit_damaged = 0 and unit_index <= damaged_units + maintenance_units then 1
        else 0
      end;

      insert into public.assets (
        id, nome, descricao, numero_serie, data_aquisicao, valor,
        localizacao, estado, created_at, categoria, quantidade,
        valor_unitario, qt_uso, qt_disponivel, qt_manutencao,
        qt_danificado, vida_util_anos, quantidade_manutencao,
        quantidade_danificada, codigo_patrimonial, tombamento,
        inconsistente, inconsistencia_motivo, updated_at
      ) values (
        unit_id,
        left(coalesce(nullif(btrim(asset_row.nome),''),'Bem patrimonial legado'),160),
        left(asset_row.descricao,2000),
        asset_row.numero_serie,
        asset_row.data_aquisicao,
        greatest(coalesce(asset_row.valor_unitario,0),0),
        left(asset_row.localizacao,180),
        case when unit_damaged=1 then 'danificado' when unit_maintenance=1 then 'manutencao' else 'bom' end,
        asset_row.created_at,
        case when asset_row.categoria in ('Equipamento','Mobiliário','Infraestrutura') then asset_row.categoria else 'Equipamento' end,
        1,
        greatest(coalesce(asset_row.valor_unitario,0),0),
        0,
        case when unit_damaged + unit_maintenance = 0 then 1 else 0 end,
        unit_maintenance,
        unit_damaged,
        asset_row.vida_util_anos,
        unit_maintenance,
        unit_damaged,
        public.nexlab_next_asset_code_v26110(),
        'LEGACY-' || legacy_base || '-' || lpad(unit_index::text,3,'0'),
        false,
        null,
        now()
      );
    end loop;

    unit_damaged := case when damaged_units >= 1 then 1 else 0 end;
    unit_maintenance := case
      when unit_damaged = 0 and maintenance_units >= 1 then 1
      else 0
    end;

    update public.assets
    set
      nome = left(coalesce(nullif(btrim(nome),''),'Bem patrimonial legado'),160),
      descricao = left(descricao,2000),
      localizacao = left(localizacao,180),
      categoria = case when categoria in ('Equipamento','Mobiliário','Infraestrutura') then categoria else 'Equipamento' end,
      quantidade = 1,
      valor_unitario = greatest(coalesce(valor_unitario,0),0),
      valor = greatest(coalesce(valor_unitario,0),0),
      quantidade_manutencao = unit_maintenance,
      quantidade_danificada = unit_damaged,
      qt_manutencao = unit_maintenance,
      qt_danificado = unit_damaged,
      qt_disponivel = case when unit_damaged + unit_maintenance = 0 then 1 else 0 end,
      qt_uso = 0,
      estado = case when unit_damaged=1 then 'danificado' when unit_maintenance=1 then 'manutencao' else 'bom' end,
      codigo_patrimonial = coalesce(nullif(btrim(codigo_patrimonial),''), public.nexlab_next_asset_code_v26110()),
      tombamento = coalesce(nullif(upper(btrim(tombamento)),''), 'LEGACY-' || legacy_base || '-001'),
      inconsistente = false,
      inconsistencia_motivo = null,
      updated_at = now()
    where id = asset_row.id;
  end loop;
end;
$block$;

-- Normaliza registros unitários legados e preenche identificação individual.
update public.assets a
set
  nome = left(coalesce(nullif(btrim(a.nome),''),'Bem patrimonial legado'),160),
  descricao = left(a.descricao,2000),
  localizacao = left(a.localizacao,180),
  categoria = case when a.categoria in ('Equipamento','Mobiliário','Infraestrutura') then a.categoria else 'Equipamento' end,
  quantidade = 1,
  valor_unitario = greatest(coalesce(a.valor_unitario,0),0),
  valor = greatest(coalesce(a.valor_unitario,0),0),
  quantidade_danificada = case when coalesce(a.quantidade_danificada,0) > 0 then 1 else 0 end,
  quantidade_manutencao = case
    when coalesce(a.quantidade_danificada,0) > 0 then 0
    when coalesce(a.quantidade_manutencao,0) > 0 then 1
    else 0
  end,
  qt_danificado = case when coalesce(a.quantidade_danificada,0) > 0 then 1 else 0 end,
  qt_manutencao = case
    when coalesce(a.quantidade_danificada,0) > 0 then 0
    when coalesce(a.quantidade_manutencao,0) > 0 then 1
    else 0
  end,
  qt_disponivel = case
    when coalesce(a.quantidade_danificada,0) > 0 or coalesce(a.quantidade_manutencao,0) > 0 then 0
    else 1
  end,
  qt_uso = 0,
  estado = case
    when coalesce(a.quantidade_danificada,0) > 0 then 'danificado'
    when coalesce(a.quantidade_manutencao,0) > 0 then 'manutencao'
    else 'bom'
  end,
  codigo_patrimonial = coalesce(nullif(btrim(a.codigo_patrimonial),''), public.nexlab_next_asset_code_v26110()),
  tombamento = coalesce(
    nullif(upper(btrim(a.tombamento)),''),
    'LEGACY-' || upper(substr(replace(a.id::text,'-',''),1,10))
  ),
  inconsistente = false,
  inconsistencia_motivo = null,
  updated_at = now();

-- Completa o resultado do saneamento no log.
update public.nexlab_asset_sanitation_log l
set after_data = coalesce(
  (select to_jsonb(a) from public.assets a where a.id = l.asset_id),
  (select to_jsonb(s) from public.stock_items s where s.source_asset_id = l.asset_id),
  '{}'::jsonb
)
where l.after_data = '{}'::jsonb;

-- =============================================================================
-- 5) Constraints rígidas: patrimônio somente durável e individual
-- =============================================================================

alter table public.assets
  alter column codigo_patrimonial set not null,
  alter column tombamento set not null,
  alter column categoria set not null,
  alter column valor_unitario set not null;

alter table public.assets drop constraint if exists assets_quantidade_danificada_check;
alter table public.assets drop constraint if exists assets_quantidade_manutencao_check;
alter table public.assets drop constraint if exists assets_quantidades_condicao_total_check;
alter table public.assets drop constraint if exists assets_individual_quantity_check;
alter table public.assets drop constraint if exists assets_durable_category_check;
alter table public.assets drop constraint if exists assets_condition_individual_check;
alter table public.assets drop constraint if exists assets_value_nonnegative_check;
alter table public.assets drop constraint if exists assets_name_length_check;
alter table public.assets drop constraint if exists assets_location_length_check;
alter table public.assets drop constraint if exists assets_description_length_check;
alter table public.assets drop constraint if exists assets_tombamento_length_check;
alter table public.assets drop constraint if exists assets_code_length_check;
alter table public.assets drop constraint if exists assets_consistency_fields_check;

alter table public.assets
  add constraint assets_individual_quantity_check
    check (quantidade = 1),
  add constraint assets_durable_category_check
    check (categoria in ('Equipamento','Mobiliário','Infraestrutura')),
  add constraint assets_condition_individual_check
    check (
      quantidade_manutencao in (0,1)
      and quantidade_danificada in (0,1)
      and quantidade_manutencao + quantidade_danificada <= 1
    ),
  add constraint assets_value_nonnegative_check
    check (valor_unitario >= 0 and coalesce(valor,0) >= 0),
  add constraint assets_name_length_check
    check (char_length(btrim(nome)) between 2 and 160),
  add constraint assets_location_length_check
    check (localizacao is null or char_length(localizacao) <= 180),
  add constraint assets_description_length_check
    check (descricao is null or char_length(descricao) <= 2000),
  add constraint assets_tombamento_length_check
    check (char_length(btrim(tombamento)) between 2 and 80),
  add constraint assets_code_length_check
    check (char_length(btrim(codigo_patrimonial)) between 8 and 40),
  add constraint assets_consistency_fields_check
    check (
      (inconsistente = false and inconsistencia_motivo is null)
      or (inconsistente = true and nullif(btrim(coalesce(inconsistencia_motivo,'')),'') is not null)
    );

create unique index if not exists assets_codigo_patrimonial_unique_idx
  on public.assets (lower(codigo_patrimonial));
create unique index if not exists assets_tombamento_unique_idx
  on public.assets (lower(tombamento));

-- Rejeita valores inválidos e apenas deriva campos redundantes já existentes.
create or replace function public.nexlab_guard_asset_integrity_v26110()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  if new.quantidade <> 1 then
    raise exception 'Cada bem patrimonial deve possuir um registro individual com quantidade igual a 1.'
      using errcode = '23514';
  end if;

  if new.categoria not in ('Equipamento','Mobiliário','Infraestrutura') then
    raise exception 'Consumíveis devem ser cadastrados no módulo Estoque.'
      using errcode = '23514';
  end if;

  if new.quantidade_manutencao not in (0,1)
     or new.quantidade_danificada not in (0,1)
     or new.quantidade_manutencao + new.quantidade_danificada > 1 then
    raise exception 'A condição individual do bem é inválida.'
      using errcode = '23514';
  end if;

  if new.valor_unitario is null or new.valor_unitario < 0 then
    raise exception 'O valor unitário não pode ser negativo.'
      using errcode = '23514';
  end if;

  new.nome := btrim(new.nome);
  new.categoria := btrim(new.categoria);
  new.codigo_patrimonial := upper(btrim(new.codigo_patrimonial));
  new.tombamento := upper(btrim(new.tombamento));
  new.localizacao := nullif(btrim(coalesce(new.localizacao,'')), '');
  new.descricao := nullif(btrim(coalesce(new.descricao,'')), '');
  new.valor := round(new.valor_unitario,2);
  new.qt_manutencao := new.quantidade_manutencao;
  new.qt_danificado := new.quantidade_danificada;
  new.qt_uso := 0;
  new.qt_disponivel := case
    when new.quantidade_manutencao + new.quantidade_danificada = 0 then 1 else 0
  end;
  new.estado := case
    when new.quantidade_danificada = 1 then 'danificado'
    when new.quantidade_manutencao = 1 then 'manutencao'
    else 'bom'
  end;
  new.inconsistente := false;
  new.inconsistencia_motivo := null;
  new.updated_at := now();
  return new;
end;
$function$;

revoke execute on function public.nexlab_guard_asset_integrity_v26110()
from public, anon, authenticated;

drop trigger if exists nexlab_guard_asset_integrity_v26110 on public.assets;
create trigger nexlab_guard_asset_integrity_v26110
before insert or update on public.assets
for each row execute function public.nexlab_guard_asset_integrity_v26110();

-- =============================================================================
-- 6) RPC patrimonial atualizada: tombamento obrigatório e quantidade individual
-- =============================================================================

create or replace function public.nexlab_save_asset_v26100(
  p_asset_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  current_asset public.assets%rowtype;
  saved_asset public.assets%rowtype;
  normalized_name text;
  normalized_category text;
  normalized_tombamento text;
  normalized_location text;
  normalized_description text;
  normalized_unit_value numeric(18,2);
  generated_code text;
  action_name text;
begin
  if auth.uid() is null then
    raise exception 'Autenticação obrigatória.' using errcode = '42501';
  end if;

  if not public.nexlab_has_permission_v26100('module_patrimonio')
     or not public.nexlab_has_permission_v26100('patrimonio_manage') then
    raise exception 'Usuário sem permissão para gerenciar o patrimônio.'
      using errcode = '42501';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Os dados do bem patrimonial são inválidos.'
      using errcode = '22023';
  end if;

  normalized_name := btrim(coalesce(p_payload ->> 'nome',''));
  normalized_category := btrim(coalesce(p_payload ->> 'categoria',''));
  normalized_tombamento := upper(btrim(coalesce(p_payload ->> 'tombamento','')));
  normalized_location := nullif(btrim(coalesce(p_payload ->> 'localizacao','')), '');
  normalized_description := nullif(btrim(coalesce(p_payload ->> 'descricao','')), '');

  if char_length(normalized_name) not between 2 and 160 then
    raise exception 'O nome deve possuir entre 2 e 160 caracteres.' using errcode = '22023';
  end if;
  if normalized_category not in ('Equipamento','Mobiliário','Infraestrutura') then
    raise exception 'Categoria inválida. Consumíveis devem ser cadastrados no Estoque.' using errcode = '22023';
  end if;
  if char_length(normalized_tombamento) not between 2 and 80 then
    raise exception 'Informe um tombamento entre 2 e 80 caracteres.' using errcode = '22023';
  end if;
  if normalized_location is not null and char_length(normalized_location) > 180 then
    raise exception 'A localização deve possuir no máximo 180 caracteres.' using errcode = '22023';
  end if;
  if normalized_description is not null and char_length(normalized_description) > 2000 then
    raise exception 'A descrição deve possuir no máximo 2.000 caracteres.' using errcode = '22023';
  end if;

  if replace(coalesce(p_payload ->> 'valor_unitario',''), ',', '.') !~ '^[0-9]+([.][0-9]{1,2})?$' then
    raise exception 'Informe um valor unitário válido, com no máximo duas casas decimais.' using errcode = '22023';
  end if;
  normalized_unit_value := round(replace(p_payload ->> 'valor_unitario', ',', '.')::numeric,2);

  if exists (
    select 1 from public.assets a
    where lower(a.tombamento) = lower(normalized_tombamento)
      and (p_asset_id is null or a.id <> p_asset_id)
  ) then
    raise exception 'Já existe um bem com esse tombamento.' using errcode = '23505';
  end if;

  if p_asset_id is null then
    action_name := 'asset_created';
    generated_code := public.nexlab_next_asset_code_v26110();

    insert into public.assets (
      nome, categoria, quantidade, valor_unitario, valor,
      localizacao, descricao, quantidade_manutencao,
      quantidade_danificada, qt_manutencao, qt_danificado,
      qt_disponivel, qt_uso, codigo_patrimonial, tombamento,
      inconsistente, inconsistencia_motivo, updated_at
    ) values (
      normalized_name, normalized_category, 1, normalized_unit_value,
      normalized_unit_value, normalized_location, normalized_description,
      0, 0, 0, 0, 1, 0, generated_code, normalized_tombamento,
      false, null, now()
    ) returning * into saved_asset;
  else
    action_name := 'asset_updated';
    select * into current_asset
    from public.assets a where a.id = p_asset_id for update;

    if current_asset.id is null then
      raise exception 'Bem patrimonial não encontrado.' using errcode = 'P0002';
    end if;

    update public.assets a
    set
      nome = normalized_name,
      categoria = normalized_category,
      quantidade = 1,
      valor_unitario = normalized_unit_value,
      valor = normalized_unit_value,
      localizacao = normalized_location,
      descricao = normalized_description,
      tombamento = normalized_tombamento,
      codigo_patrimonial = current_asset.codigo_patrimonial,
      inconsistente = false,
      inconsistencia_motivo = null,
      updated_at = now()
    where a.id = p_asset_id
    returning * into saved_asset;
  end if;

  perform public.record_security_audit(
    action_name,
    null::text,
    jsonb_build_object(
      'entity_id', saved_asset.id,
      'entity_name', saved_asset.nome,
      'module', 'patrimonio',
      'codigo_patrimonial', saved_asset.codigo_patrimonial,
      'tombamento', saved_asset.tombamento,
      'operation', case when p_asset_id is null then 'create' else 'update' end,
      'unit_value', saved_asset.valor_unitario
    )
  );

  return jsonb_build_object('ok',true,'asset',to_jsonb(saved_asset));
exception
  when unique_violation then
    raise exception 'Código patrimonial ou tombamento já cadastrado.' using errcode = '23505';
end;
$function$;

revoke execute on function public.nexlab_save_asset_v26100(uuid,jsonb)
from public, anon;
grant execute on function public.nexlab_save_asset_v26100(uuid,jsonb)
to authenticated, service_role;

create or replace function public.nexlab_update_asset_condition_v26100(
  p_asset_id uuid,
  p_quantidade_manutencao integer,
  p_quantidade_danificada integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  current_asset public.assets%rowtype;
  saved_asset public.assets%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Autenticação obrigatória.' using errcode = '42501';
  end if;
  if not public.nexlab_has_permission_v26100('module_patrimonio')
     or not public.nexlab_has_permission_v26100('patrimonio_manage') then
    raise exception 'Usuário sem permissão para atualizar a condição.' using errcode = '42501';
  end if;
  if p_quantidade_manutencao not in (0,1)
     or p_quantidade_danificada not in (0,1)
     or p_quantidade_manutencao + p_quantidade_danificada > 1 then
    raise exception 'Selecione uma condição individual válida.' using errcode = '22023';
  end if;

  select * into current_asset
  from public.assets a where a.id = p_asset_id for update;
  if current_asset.id is null then
    raise exception 'Bem patrimonial não encontrado.' using errcode = 'P0002';
  end if;

  update public.assets a
  set
    quantidade_manutencao = p_quantidade_manutencao,
    quantidade_danificada = p_quantidade_danificada,
    inconsistente = false,
    inconsistencia_motivo = null,
    updated_at = now()
  where a.id = p_asset_id
  returning * into saved_asset;

  perform public.record_security_audit(
    'asset_condition_updated', null::text,
    jsonb_build_object(
      'entity_id', saved_asset.id,
      'entity_name', saved_asset.nome,
      'module', 'patrimonio',
      'codigo_patrimonial', saved_asset.codigo_patrimonial,
      'previous_maintenance', current_asset.quantidade_manutencao,
      'previous_damaged', current_asset.quantidade_danificada,
      'maintenance', saved_asset.quantidade_manutencao,
      'damaged', saved_asset.quantidade_danificada
    )
  );

  return jsonb_build_object('ok',true,'asset',to_jsonb(saved_asset));
end;
$function$;

revoke execute on function public.nexlab_update_asset_condition_v26100(uuid,integer,integer)
from public, anon;
grant execute on function public.nexlab_update_asset_condition_v26100(uuid,integer,integer)
to authenticated, service_role;

-- =============================================================================
-- 7) RPCs do Estoque (sem gravação direta)
-- =============================================================================

create or replace function public.nexlab_save_stock_item_v26110(
  p_item_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  current_item public.stock_items%rowtype;
  saved_item public.stock_items%rowtype;
  normalized_name text;
  normalized_description text;
  normalized_location text;
  normalized_unit text;
  normalized_quantity integer;
  normalized_minimum integer;
  normalized_value numeric(18,2);
  audit_action text;
begin
  if auth.uid() is null then
    raise exception 'Autenticação obrigatória.' using errcode = '42501';
  end if;
  if not public.nexlab_has_permission_v26100('module_estoque')
     or not public.nexlab_has_permission_v26100('estoque_manage') then
    raise exception 'Usuário sem permissão para gerenciar o estoque.' using errcode = '42501';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Dados do item de estoque inválidos.' using errcode = '22023';
  end if;

  normalized_name := btrim(coalesce(p_payload->>'nome',''));
  normalized_description := nullif(btrim(coalesce(p_payload->>'descricao','')), '');
  normalized_location := nullif(btrim(coalesce(p_payload->>'localizacao','')), '');
  normalized_unit := lower(btrim(coalesce(p_payload->>'unidade_medida','unidade')));

  if char_length(normalized_name) not between 2 and 160 then
    raise exception 'O nome deve possuir entre 2 e 160 caracteres.' using errcode = '22023';
  end if;
  if char_length(normalized_unit) not between 1 and 40 then
    raise exception 'Unidade de medida inválida.' using errcode = '22023';
  end if;
  if normalized_description is not null and char_length(normalized_description)>2000 then
    raise exception 'A descrição deve possuir no máximo 2.000 caracteres.' using errcode = '22023';
  end if;
  if normalized_location is not null and char_length(normalized_location)>180 then
    raise exception 'A localização deve possuir no máximo 180 caracteres.' using errcode = '22023';
  end if;
  if coalesce(p_payload->>'quantidade','') !~ '^[0-9]+$'
     or coalesce(p_payload->>'estoque_minimo','') !~ '^[0-9]+$' then
    raise exception 'Quantidade e estoque mínimo devem ser inteiros maiores ou iguais a zero.' using errcode = '22023';
  end if;
  normalized_quantity := (p_payload->>'quantidade')::integer;
  normalized_minimum := (p_payload->>'estoque_minimo')::integer;
  if replace(coalesce(p_payload->>'valor_unitario','0'),',','.') !~ '^[0-9]+([.][0-9]{1,2})?$' then
    raise exception 'Valor unitário inválido.' using errcode = '22023';
  end if;
  normalized_value := round(replace(coalesce(p_payload->>'valor_unitario','0'),',','.')::numeric,2);

  if p_item_id is null then
    audit_action := 'stock_item_created';
    insert into public.stock_items (
      nome, descricao, categoria, quantidade, unidade_medida,
      estoque_minimo, localizacao, valor_unitario, updated_at
    ) values (
      normalized_name, normalized_description, 'Consumível', normalized_quantity,
      normalized_unit, normalized_minimum, normalized_location, normalized_value, now()
    ) returning * into saved_item;
  else
    audit_action := 'stock_item_updated';
    select * into current_item
    from public.stock_items s where s.id=p_item_id for update;
    if current_item.id is null then
      raise exception 'Item de estoque não encontrado.' using errcode = 'P0002';
    end if;
    update public.stock_items s
    set
      nome=normalized_name,
      descricao=normalized_description,
      categoria='Consumível',
      quantidade=normalized_quantity,
      unidade_medida=normalized_unit,
      estoque_minimo=normalized_minimum,
      localizacao=normalized_location,
      valor_unitario=normalized_value,
      updated_at=now()
    where s.id=p_item_id
    returning * into saved_item;
  end if;

  perform public.record_security_audit(
    audit_action, null::text,
    jsonb_build_object(
      'entity_id',saved_item.id,
      'entity_name',saved_item.nome,
      'module','estoque',
      'quantity',saved_item.quantidade,
      'minimum',saved_item.estoque_minimo,
      'unit',saved_item.unidade_medida
    )
  );
  return jsonb_build_object('ok',true,'item',to_jsonb(saved_item));
end;
$function$;

revoke execute on function public.nexlab_save_stock_item_v26110(uuid,jsonb)
from public, anon;
grant execute on function public.nexlab_save_stock_item_v26110(uuid,jsonb)
to authenticated, service_role;

create or replace function public.nexlab_delete_stock_item_v26110(p_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  current_item public.stock_items%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Autenticação obrigatória.' using errcode = '42501';
  end if;
  if not public.nexlab_is_admin() then
    raise exception 'Somente Administradores podem excluir itens de estoque permanentemente.' using errcode = '42501';
  end if;
  select * into current_item
  from public.stock_items s where s.id=p_item_id for update;
  if current_item.id is null then
    raise exception 'Item de estoque não encontrado.' using errcode = 'P0002';
  end if;
  delete from public.stock_items where id=p_item_id;
  perform public.record_security_audit(
    'stock_item_deleted', null::text,
    jsonb_build_object(
      'entity_id',current_item.id,
      'entity_name',current_item.nome,
      'module','estoque',
      'quantity',current_item.quantidade
    )
  );
  return jsonb_build_object('ok',true,'deleted',true,'item_id',current_item.id);
end;
$function$;

revoke execute on function public.nexlab_delete_stock_item_v26110(uuid)
from public, anon;
grant execute on function public.nexlab_delete_stock_item_v26110(uuid)
to authenticated, service_role;

-- =============================================================================
-- 8) Auditoria e RLS
-- =============================================================================

alter table public.security_audit_logs
  drop constraint if exists security_audit_logs_action_check;

alter table public.security_audit_logs
  add constraint security_audit_logs_action_check
  check (action = any(array[
    'user_access_updated','user_deactivated','user_reactivated','user_deleted',
    'detailed_user_report_pdf','detailed_user_report_excel',
    'event_created','event_updated','event_deleted',
    'project_created','project_updated','project_status_updated','project_kanban_moved','project_deleted',
    'team_created','team_updated','team_archived','team_restored','team_deleted',
    'team_member_added','team_member_removed','team_member_role_updated','team_responsibility_transferred',
    'team_link_created','team_link_removed',
    'meeting_created','meeting_updated','meeting_cancelled','meeting_deleted','meeting_participants_replaced',
    'reservation_approved','reservation_rejected','reservation_cancelled','reservation_deleted','reservation_participants_replaced',
    'marketing_created','marketing_updated','marketing_status_updated','marketing_deleted',
    'feedback_status_updated',
    'asset_created','asset_updated','asset_condition_updated','asset_deleted',
    'stock_item_created','stock_item_updated','stock_item_deleted',
    'post_created','post_updated','post_deleted',
    'privacy_documents_accepted','optional_consent_granted','optional_consent_revoked',
    'privacy_request_created','privacy_request_status_updated',
    'profile_avatar_updated','profile_avatar_removed','own_profile_updated','own_sensitive_profile_updated',
    'profile_admin_managed','profile_registration_submitted','profile_request_cancelled',
    'profile_request_resubmitted','profile_request_approved','profile_request_rejected',
    'report_export_recorded','role_permissions_updated','user_permissions_updated',
    'security_retention_applied','sensitive_user_report_accessed','activity_logs_bulk_deleted'
  ]::text[]));

-- Estoque: leitura conforme permissão; gravação apenas pelas RPCs.
drop policy if exists nexlab_stock_items_select_v26110 on public.stock_items;
create policy nexlab_stock_items_select_v26110
on public.stock_items for select to authenticated
using (
  public.nexlab_has_permission_v26100('module_estoque')
  and public.nexlab_has_permission_v26100('estoque_view')
);

revoke all on table public.stock_items from public, anon;
revoke insert,update,delete on table public.stock_items from authenticated;
grant select on table public.stock_items to authenticated;

-- Log de saneamento: visível apenas para Administrador.
drop policy if exists nexlab_asset_sanitation_admin_select_v26110
on public.nexlab_asset_sanitation_log;
create policy nexlab_asset_sanitation_admin_select_v26110
on public.nexlab_asset_sanitation_log for select to authenticated
using (public.nexlab_is_admin());

revoke all on table public.nexlab_asset_sanitation_log from public,anon,authenticated;
grant select on table public.nexlab_asset_sanitation_log to authenticated;

-- =============================================================================
-- 9) Recalcula permissões efetivas
-- =============================================================================

do $block$
declare
  profile_row record;
begin
  for profile_row in select p.id::text as id_text from public.profiles p loop
    perform public.nexlab_recalculate_profile_permissions(profile_row.id_text);
  end loop;
end;
$block$;
