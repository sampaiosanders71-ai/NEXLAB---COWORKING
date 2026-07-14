-- NEXLAB v26.10.0 — Patrimônio / Etapa 1
-- Correções 1 a 4:
-- 1. Permissões unificadas.
-- 2. Exportação obrigatoriamente registrada e auditada.
-- 3. Alterações patrimoniais somente por RPCs transacionais.
-- 4. Auditoria obrigatória na mesma transação da operação.

-- -----------------------------------------------------------------------------
-- 1) Catálogo e padrões de permissões
-- -----------------------------------------------------------------------------

insert into public.nexlab_permission_catalog (
  permission_key,
  label,
  description,
  category,
  module_id,
  core,
  admin_only,
  grantable,
  eligible_roles,
  sort_order,
  active,
  updated_at
)
values
  (
    'patrimonio_view',
    'Consultar patrimônio',
    'Permite visualizar os registros e indicadores do módulo de Patrimônio.',
    'Patrimônio',
    'patrimonio',
    false,
    false,
    true,
    array['admin','coordenador','bolsista','coworking_junior']::text[],
    131,
    true,
    now()
  ),
  (
    'patrimonio_manage',
    'Gerenciar patrimônio',
    'Permite cadastrar, editar e atualizar a condição dos itens patrimoniais.',
    'Patrimônio',
    'patrimonio',
    false,
    false,
    true,
    array['admin','coordenador','bolsista','coworking_junior']::text[],
    132,
    true,
    now()
  ),
  (
    'patrimonio_export',
    'Exportar patrimônio',
    'Permite gerar relatórios PDF ou XLSX do Patrimônio com registro obrigatório no histórico.',
    'Patrimônio',
    'patrimonio',
    false,
    false,
    true,
    array['admin','coordenador','bolsista','coworking_junior']::text[],
    133,
    true,
    now()
  ),
  (
    'patrimonio_delete',
    'Excluir patrimônio permanentemente',
    'Permissão protegida e exclusiva de Administradores para exclusão permanente.',
    'Patrimônio',
    'patrimonio',
    false,
    true,
    false,
    array['admin']::text[],
    134,
    true,
    now()
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

update public.nexlab_permission_catalog
set
  description = 'Acesso ao módulo de Patrimônio. As ações internas são controladas pelas permissões de consulta, gestão, exportação e exclusão.',
  updated_at = now()
where permission_key = 'module_patrimonio';

insert into public.nexlab_role_permission_defaults (
  role_key,
  permission_key,
  allowed,
  updated_by,
  updated_at
)
values
  ('admin', 'patrimonio_view', true, null, now()),
  ('admin', 'patrimonio_manage', true, null, now()),
  ('admin', 'patrimonio_export', true, null, now()),
  ('coordenador', 'patrimonio_view', true, null, now()),
  ('coordenador', 'patrimonio_manage', true, null, now()),
  ('coordenador', 'patrimonio_export', true, null, now()),
  ('bolsista', 'patrimonio_view', false, null, now()),
  ('bolsista', 'patrimonio_manage', false, null, now()),
  ('bolsista', 'patrimonio_export', false, null, now()),
  ('coworking_junior', 'patrimonio_view', false, null, now()),
  ('coworking_junior', 'patrimonio_manage', false, null, now()),
  ('coworking_junior', 'patrimonio_export', false, null, now())
on conflict (role_key, permission_key) do update
set
  allowed = excluded.allowed,
  updated_by = excluded.updated_by,
  updated_at = excluded.updated_at;

-- -----------------------------------------------------------------------------
-- 2) Validação central de permissão efetiva
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_has_permission_v26100(
  p_permission text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select
    auth.uid() is not null
    and nullif(btrim(coalesce(p_permission, '')), '') is not null
    and exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and p.ativo is distinct from false
        and coalesce(p.cadastro_completo, false)
        and coalesce(p.role_request_status, 'approved') = 'approved'
        and p_permission = any(coalesce(p.effective_permissions, '{}'::text[]))
    );
$function$;

revoke execute on function public.nexlab_has_permission_v26100(text)
from public, anon;
grant execute on function public.nexlab_has_permission_v26100(text)
to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3) RPC transacional para criação e edição
-- -----------------------------------------------------------------------------

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
  normalized_location text;
  normalized_description text;
  normalized_quantity integer;
  normalized_unit_value numeric(18,2);
  maintenance_quantity integer := 0;
  damaged_quantity integer := 0;
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
    raise exception 'Os dados do item patrimonial são inválidos.'
      using errcode = '22023';
  end if;

  normalized_name := btrim(coalesce(p_payload ->> 'nome', ''));
  normalized_category := btrim(coalesce(p_payload ->> 'categoria', ''));
  normalized_location := nullif(btrim(coalesce(p_payload ->> 'localizacao', '')), '');
  normalized_description := nullif(btrim(coalesce(p_payload ->> 'descricao', '')), '');

  if char_length(normalized_name) < 2 or char_length(normalized_name) > 160 then
    raise exception 'O nome deve possuir entre 2 e 160 caracteres.'
      using errcode = '22023';
  end if;

  if normalized_category not in ('Equipamento', 'Consumível', 'Mobiliário', 'Infraestrutura') then
    raise exception 'Categoria patrimonial inválida.'
      using errcode = '22023';
  end if;

  if normalized_location is not null and char_length(normalized_location) > 180 then
    raise exception 'A localização deve possuir no máximo 180 caracteres.'
      using errcode = '22023';
  end if;

  if normalized_description is not null and char_length(normalized_description) > 2000 then
    raise exception 'A descrição deve possuir no máximo 2.000 caracteres.'
      using errcode = '22023';
  end if;

  if coalesce(p_payload ->> 'quantidade', '') !~ '^[0-9]+$' then
    raise exception 'A quantidade deve ser um número inteiro positivo.'
      using errcode = '22023';
  end if;

  begin
    normalized_quantity := (p_payload ->> 'quantidade')::integer;
  exception
    when numeric_value_out_of_range then
      raise exception 'A quantidade excede o limite permitido.'
        using errcode = '22003';
  end;

  if normalized_quantity < 1 then
    raise exception 'A quantidade deve ser maior que zero.'
      using errcode = '22023';
  end if;

  if coalesce(p_payload ->> 'valor_unitario', '') !~ '^[0-9]+([.][0-9]{1,2})?$' then
    raise exception 'O valor unitário deve ser informado com no máximo duas casas decimais.'
      using errcode = '22023';
  end if;

  begin
    normalized_unit_value := round((p_payload ->> 'valor_unitario')::numeric, 2);
  exception
    when numeric_value_out_of_range then
      raise exception 'O valor unitário excede o limite permitido.'
        using errcode = '22003';
  end;

  if normalized_unit_value < 0 or normalized_unit_value > 9999999999999999.99 then
    raise exception 'O valor unitário está fora do limite permitido.'
      using errcode = '22023';
  end if;

  if p_asset_id is null then
    action_name := 'asset_created';

    insert into public.assets (
      nome,
      categoria,
      quantidade,
      valor_unitario,
      valor,
      localizacao,
      descricao,
      quantidade_manutencao,
      quantidade_danificada,
      qt_manutencao,
      qt_danificado,
      qt_disponivel,
      qt_uso
    )
    values (
      normalized_name,
      normalized_category,
      normalized_quantity,
      normalized_unit_value,
      normalized_quantity * normalized_unit_value,
      normalized_location,
      normalized_description,
      0,
      0,
      0,
      0,
      normalized_quantity,
      0
    )
    returning * into saved_asset;
  else
    action_name := 'asset_updated';

    select *
      into current_asset
    from public.assets a
    where a.id = p_asset_id
    for update;

    if current_asset.id is null then
      raise exception 'Item patrimonial não encontrado.'
        using errcode = 'P0002';
    end if;

    maintenance_quantity := greatest(coalesce(current_asset.quantidade_manutencao, 0), 0);
    damaged_quantity := greatest(coalesce(current_asset.quantidade_danificada, 0), 0);

    if maintenance_quantity + damaged_quantity > normalized_quantity then
      raise exception 'A quantidade total não pode ser menor que as unidades em manutenção e danificadas.'
        using errcode = '23514';
    end if;

    update public.assets a
    set
      nome = normalized_name,
      categoria = normalized_category,
      quantidade = normalized_quantity,
      valor_unitario = normalized_unit_value,
      valor = normalized_quantity * normalized_unit_value,
      localizacao = normalized_location,
      descricao = normalized_description,
      quantidade_manutencao = maintenance_quantity,
      quantidade_danificada = damaged_quantity,
      qt_manutencao = maintenance_quantity,
      qt_danificado = damaged_quantity,
      qt_disponivel = normalized_quantity - maintenance_quantity - damaged_quantity
    where a.id = p_asset_id
    returning * into saved_asset;
  end if;

  -- A auditoria faz parte da mesma transação. Qualquer erro reverte a gravação.
  perform public.record_security_audit(
    action_name,
    null::text,
    jsonb_build_object(
      'entity_id', saved_asset.id,
      'entity_name', saved_asset.nome,
      'module', 'patrimonio',
      'operation', case when p_asset_id is null then 'create' else 'update' end,
      'quantity', saved_asset.quantidade,
      'unit_value', saved_asset.valor_unitario,
      'total_value', saved_asset.valor
    )
  );

  return jsonb_build_object(
    'ok', true,
    'asset', to_jsonb(saved_asset)
  );
end;
$function$;

revoke execute on function public.nexlab_save_asset_v26100(uuid, jsonb)
from public, anon;
grant execute on function public.nexlab_save_asset_v26100(uuid, jsonb)
to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4) RPC transacional para atualização de condição
-- -----------------------------------------------------------------------------

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
    raise exception 'Usuário sem permissão para atualizar a condição do patrimônio.'
      using errcode = '42501';
  end if;

  if p_asset_id is null then
    raise exception 'Item patrimonial não informado.' using errcode = '22023';
  end if;

  if p_quantidade_manutencao is null
     or p_quantidade_danificada is null
     or p_quantidade_manutencao < 0
     or p_quantidade_danificada < 0 then
    raise exception 'As quantidades de manutenção e dano devem ser inteiros maiores ou iguais a zero.'
      using errcode = '22023';
  end if;

  select *
    into current_asset
  from public.assets a
  where a.id = p_asset_id
  for update;

  if current_asset.id is null then
    raise exception 'Item patrimonial não encontrado.' using errcode = 'P0002';
  end if;

  if p_quantidade_manutencao + p_quantidade_danificada > current_asset.quantidade then
    raise exception 'A soma das unidades em manutenção e danificadas não pode ultrapassar a quantidade total.'
      using errcode = '23514';
  end if;

  update public.assets a
  set
    quantidade_manutencao = p_quantidade_manutencao,
    quantidade_danificada = p_quantidade_danificada,
    qt_manutencao = p_quantidade_manutencao,
    qt_danificado = p_quantidade_danificada,
    qt_disponivel = current_asset.quantidade - p_quantidade_manutencao - p_quantidade_danificada
  where a.id = p_asset_id
  returning * into saved_asset;

  -- A auditoria é obrigatória e transacional.
  perform public.record_security_audit(
    'asset_condition_updated',
    null::text,
    jsonb_build_object(
      'entity_id', saved_asset.id,
      'entity_name', saved_asset.nome,
      'module', 'patrimonio',
      'previous_maintenance', coalesce(current_asset.quantidade_manutencao, 0),
      'previous_damaged', coalesce(current_asset.quantidade_danificada, 0),
      'maintenance', saved_asset.quantidade_manutencao,
      'damaged', saved_asset.quantidade_danificada,
      'available', saved_asset.quantidade - saved_asset.quantidade_manutencao - saved_asset.quantidade_danificada
    )
  );

  return jsonb_build_object(
    'ok', true,
    'asset', to_jsonb(saved_asset)
  );
end;
$function$;

revoke execute on function public.nexlab_update_asset_condition_v26100(uuid, integer, integer)
from public, anon;
grant execute on function public.nexlab_update_asset_condition_v26100(uuid, integer, integer)
to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5) RPC transacional para exclusão permanente
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_delete_asset_v26100(
  p_asset_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  current_asset public.assets%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Autenticação obrigatória.' using errcode = '42501';
  end if;

  if not public.nexlab_has_permission_v26100('module_patrimonio')
     or not public.nexlab_has_permission_v26100('patrimonio_delete') then
    raise exception 'Somente Administradores autorizados podem excluir itens patrimoniais permanentemente.'
      using errcode = '42501';
  end if;

  if p_asset_id is null then
    raise exception 'Item patrimonial não informado.' using errcode = '22023';
  end if;

  select *
    into current_asset
  from public.assets a
  where a.id = p_asset_id
  for update;

  if current_asset.id is null then
    raise exception 'Item patrimonial não encontrado.' using errcode = 'P0002';
  end if;

  delete from public.assets a
  where a.id = p_asset_id;

  -- A exclusão somente é confirmada se a auditoria também for gravada.
  perform public.record_security_audit(
    'asset_deleted',
    null::text,
    jsonb_build_object(
      'entity_id', current_asset.id,
      'entity_name', current_asset.nome,
      'module', 'patrimonio',
      'quantity', current_asset.quantidade,
      'total_value', current_asset.valor
    )
  );

  return jsonb_build_object(
    'ok', true,
    'deleted', true,
    'asset_id', current_asset.id,
    'asset_name', current_asset.nome
  );
end;
$function$;

revoke execute on function public.nexlab_delete_asset_v26100(uuid)
from public, anon;
grant execute on function public.nexlab_delete_asset_v26100(uuid)
to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6) Exportação autorizada, registrada e auditada antes de gerar o arquivo
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_record_patrimonio_export_v26100(
  p_file_type text,
  p_record_count integer default 0,
  p_filters jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  normalized_type text;
  normalized_filters jsonb;
  export_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Autenticação obrigatória.' using errcode = '42501';
  end if;

  if not public.nexlab_has_permission_v26100('module_patrimonio')
     or not public.nexlab_has_permission_v26100('patrimonio_export') then
    raise exception 'Usuário sem permissão para exportar o patrimônio.'
      using errcode = '42501';
  end if;

  normalized_type := lower(btrim(coalesce(p_file_type, '')));
  if normalized_type = 'excel' then
    normalized_type := 'xlsx';
  end if;

  if normalized_type not in ('pdf', 'xlsx') then
    raise exception 'Formato de exportação inválido.' using errcode = '22023';
  end if;

  if coalesce(p_record_count, 0) < 0 then
    raise exception 'A quantidade de registros não pode ser negativa.'
      using errcode = '22023';
  end if;

  if p_filters is null then
    normalized_filters := '{}'::jsonb;
  elsif jsonb_typeof(p_filters) <> 'object' then
    raise exception 'Os filtros da exportação são inválidos.'
      using errcode = '22023';
  else
    normalized_filters := p_filters;
  end if;

  insert into public.nexlab_report_exports (
    user_id,
    scope,
    file_type,
    record_count,
    confidential,
    filters
  )
  values (
    auth.uid(),
    'patrimonio',
    normalized_type,
    coalesce(p_record_count, 0),
    false,
    normalized_filters
  )
  returning id into export_id;

  -- O histórico e a auditoria fazem parte da mesma transação.
  perform public.record_security_audit(
    'report_export_recorded',
    null::text,
    jsonb_build_object(
      'export_id', export_id,
      'scope', 'patrimonio',
      'file_type', normalized_type,
      'record_count', coalesce(p_record_count, 0),
      'confidential', false,
      'filters', normalized_filters
    )
  );

  return jsonb_build_object(
    'ok', true,
    'export_id', export_id,
    'scope', 'patrimonio',
    'file_type', normalized_type,
    'record_count', coalesce(p_record_count, 0)
  );
end;
$function$;

revoke execute on function public.nexlab_record_patrimonio_export_v26100(text, integer, jsonb)
from public, anon;
grant execute on function public.nexlab_record_patrimonio_export_v26100(text, integer, jsonb)
to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7) RLS: leitura pela permissão exata e nenhuma alteração direta pelo cliente
-- -----------------------------------------------------------------------------

alter table public.assets enable row level security;

drop policy if exists "gerencia patrimonio" on public.assets;
drop policy if exists "nexlab_approved_account_gate" on public.assets;
drop policy if exists "todos veem patrimonio" on public.assets;
drop policy if exists "nexlab_assets_select_v26100" on public.assets;

create policy "nexlab_assets_select_v26100"
on public.assets
for select
to authenticated
using (
  public.nexlab_has_permission_v26100('module_patrimonio')
  and public.nexlab_has_permission_v26100('patrimonio_view')
);

revoke all on table public.assets from public, anon;
revoke insert, update, delete on table public.assets from authenticated;
grant select on table public.assets to authenticated;

-- -----------------------------------------------------------------------------
-- 8) Recalcula as permissões efetivas de todos os perfis
-- -----------------------------------------------------------------------------

do $block$
declare
  profile_row record;
begin
  for profile_row in
    select p.id::text as id_text
    from public.profiles p
  loop
    perform public.nexlab_recalculate_profile_permissions(profile_row.id_text);
  end loop;
end;
$block$;
