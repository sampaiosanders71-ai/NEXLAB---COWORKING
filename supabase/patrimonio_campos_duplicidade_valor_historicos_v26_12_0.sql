-- NEXLAB v26.12.0 — Patrimônio / Etapa 2 (3–5) e Etapa 3 (1)
-- 1. Campos patrimoniais estruturados e links externos.
-- 2. Prevenção de duplicidade por tombamento, número de série e verificação provável.
-- 3. Valor de aquisição canônico, com campos legados derivados pelo servidor.
-- 4. Histórico estruturado de manutenções e movimentações.

-- =============================================================================
-- 1) Campos estruturados e valor canônico
-- =============================================================================

alter table public.assets
  add column if not exists marca text,
  add column if not exists modelo text,
  add column if not exists responsavel_id uuid references public.profiles(id) on delete set null,
  add column if not exists fornecedor text,
  add column if not exists numero_nota_fiscal text,
  add column if not exists garantia_ate date,
  add column if not exists link_nota_fiscal text,
  add column if not exists link_garantia text,
  add column if not exists link_manual text,
  add column if not exists link_referencia text,
  add column if not exists valor_aquisicao numeric(18,2);

update public.assets
set valor_aquisicao = greatest(coalesce(valor_aquisicao, valor_unitario, valor, 0), 0)
where valor_aquisicao is null;

alter table public.assets
  alter column valor_aquisicao set default 0,
  alter column valor_aquisicao set not null;

alter table public.assets drop constraint if exists assets_brand_length_check;
alter table public.assets drop constraint if exists assets_model_length_check;
alter table public.assets drop constraint if exists assets_serial_length_check;
alter table public.assets drop constraint if exists assets_supplier_length_check;
alter table public.assets drop constraint if exists assets_invoice_number_length_check;
alter table public.assets drop constraint if exists assets_acquisition_value_check;
alter table public.assets drop constraint if exists assets_external_links_check;

alter table public.assets
  add constraint assets_brand_length_check
    check (marca is null or char_length(marca) <= 100),
  add constraint assets_model_length_check
    check (modelo is null or char_length(modelo) <= 120),
  add constraint assets_serial_length_check
    check (numero_serie is null or char_length(numero_serie) <= 160),
  add constraint assets_supplier_length_check
    check (fornecedor is null or char_length(fornecedor) <= 160),
  add constraint assets_invoice_number_length_check
    check (numero_nota_fiscal is null or char_length(numero_nota_fiscal) <= 80),
  add constraint assets_acquisition_value_check
    check (valor_aquisicao >= 0),
  add constraint assets_external_links_check
    check (
      (link_nota_fiscal is null or (char_length(link_nota_fiscal) <= 1000 and link_nota_fiscal ~* '^https?://'))
      and (link_garantia is null or (char_length(link_garantia) <= 1000 and link_garantia ~* '^https?://'))
      and (link_manual is null or (char_length(link_manual) <= 1000 and link_manual ~* '^https?://'))
      and (link_referencia is null or (char_length(link_referencia) <= 1000 and link_referencia ~* '^https?://'))
    );

create unique index if not exists assets_numero_serie_unique_idx
  on public.assets (lower(btrim(numero_serie)))
  where nullif(btrim(numero_serie), '') is not null;

create index if not exists assets_probable_duplicate_idx
  on public.assets (
    lower(btrim(nome)),
    lower(btrim(coalesce(marca, ''))),
    lower(btrim(coalesce(modelo, '')))
  );

create index if not exists assets_responsavel_idx
  on public.assets (responsavel_id);

-- =============================================================================
-- 2) Histórico estruturado
-- =============================================================================

alter table public.asset_maintenance
  add column if not exists status text not null default 'aberta',
  add column if not exists fornecedor text,
  add column if not exists custo numeric(18,2) not null default 0,
  add column if not exists link_externo text,
  add column if not exists updated_at timestamptz not null default now();

update public.asset_maintenance
set
  status = case when data_retorno is null then 'aberta' else 'concluida' end,
  custo = greatest(coalesce(custo,0),0),
  updated_at = coalesce(updated_at,created_at,now());

alter table public.asset_maintenance drop constraint if exists asset_maintenance_status_check;
alter table public.asset_maintenance drop constraint if exists asset_maintenance_cost_check;
alter table public.asset_maintenance drop constraint if exists asset_maintenance_dates_check;
alter table public.asset_maintenance drop constraint if exists asset_maintenance_text_lengths_check;
alter table public.asset_maintenance drop constraint if exists asset_maintenance_link_check;

alter table public.asset_maintenance
  add constraint asset_maintenance_status_check
    check (status in ('aberta','concluida','cancelada')),
  add constraint asset_maintenance_cost_check
    check (custo >= 0),
  add constraint asset_maintenance_dates_check
    check (data_retorno is null or data_envio is null or data_retorno >= data_envio),
  add constraint asset_maintenance_text_lengths_check
    check (
      (motivo is null or char_length(motivo) <= 200)
      and (descricao_problema is null or char_length(descricao_problema) <= 2000)
      and (descricao_solucao is null or char_length(descricao_solucao) <= 2000)
      and (observacoes is null or char_length(observacoes) <= 2000)
      and (fornecedor is null or char_length(fornecedor) <= 160)
    ),
  add constraint asset_maintenance_link_check
    check (link_externo is null or (char_length(link_externo) <= 1000 and link_externo ~* '^https?://'));

create index if not exists asset_maintenance_asset_date_idx
  on public.asset_maintenance (asset_id, created_at desc);
create index if not exists asset_maintenance_open_idx
  on public.asset_maintenance (asset_id, status)
  where status = 'aberta';

create table if not exists public.asset_movements (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id) on delete cascade,
  tipo text not null default 'transferencia',
  origem_localizacao text,
  destino_localizacao text,
  origem_responsavel_id uuid references public.profiles(id) on delete set null,
  destino_responsavel_id uuid references public.profiles(id) on delete set null,
  motivo text not null,
  link_externo text,
  data_movimentacao date not null default current_date,
  actor_id uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  constraint asset_movements_type_check
    check (tipo in ('cadastro_inicial','transferencia','devolucao','ajuste_cadastro')),
  constraint asset_movements_locations_length_check
    check (
      (origem_localizacao is null or char_length(origem_localizacao) <= 180)
      and (destino_localizacao is null or char_length(destino_localizacao) <= 180)
    ),
  constraint asset_movements_reason_check
    check (char_length(btrim(motivo)) between 3 and 1000),
  constraint asset_movements_link_check
    check (link_externo is null or (char_length(link_externo) <= 1000 and link_externo ~* '^https?://')),
  constraint asset_movements_real_change_check
    check (
      origem_localizacao is distinct from destino_localizacao
      or origem_responsavel_id is distinct from destino_responsavel_id
      or tipo = 'cadastro_inicial'
    )
);

create index if not exists asset_movements_asset_date_idx
  on public.asset_movements (asset_id, data_movimentacao desc, created_at desc);

alter table public.asset_maintenance enable row level security;
alter table public.asset_movements enable row level security;
alter table public.asset_changes enable row level security;

-- Remove canais legados de escrita direta.
drop policy if exists "gerencia manutencoes" on public.asset_maintenance;
drop policy if exists "ve manutencoes" on public.asset_maintenance;
drop policy if exists "cria asset_changes" on public.asset_changes;
drop policy if exists "ve asset_changes" on public.asset_changes;

drop policy if exists nexlab_asset_maintenance_select_v26120 on public.asset_maintenance;
create policy nexlab_asset_maintenance_select_v26120
on public.asset_maintenance for select to authenticated
using (
  (select public.nexlab_has_permission_v26100('module_patrimonio'))
  and (select public.nexlab_has_permission_v26100('patrimonio_view'))
);

drop policy if exists nexlab_asset_movements_select_v26120 on public.asset_movements;
create policy nexlab_asset_movements_select_v26120
on public.asset_movements for select to authenticated
using (
  (select public.nexlab_has_permission_v26100('module_patrimonio'))
  and (select public.nexlab_has_permission_v26100('patrimonio_view'))
);

drop policy if exists nexlab_asset_changes_select_v26120 on public.asset_changes;
create policy nexlab_asset_changes_select_v26120
on public.asset_changes for select to authenticated
using (
  (select public.nexlab_has_permission_v26100('module_patrimonio'))
  and (select public.nexlab_has_permission_v26100('patrimonio_view'))
);

revoke all on table public.asset_maintenance from public,anon;
revoke all on table public.asset_movements from public,anon;
revoke all on table public.asset_changes from public,anon;
revoke insert,update,delete on table public.asset_maintenance from authenticated;
revoke insert,update,delete on table public.asset_movements from authenticated;
revoke insert,update,delete on table public.asset_changes from authenticated;
grant select on table public.asset_maintenance to authenticated;
grant select on table public.asset_movements to authenticated;
grant select on table public.asset_changes to authenticated;

-- =============================================================================
-- 3) Helpers de validação
-- =============================================================================


-- =============================================================================
-- 4) Normalização, valor canônico e integridade
-- =============================================================================

create or replace function public.nexlab_normalize_asset_url_v26120(p_value text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $function$
declare
  normalized text := nullif(btrim(coalesce(p_value,'')), '');
begin
  if normalized is null then
    return null;
  end if;

  if char_length(normalized) > 1000 or normalized !~* '^https?://' then
    raise exception 'Informe apenas links externos iniciados por http:// ou https://.'
      using errcode = '22023';
  end if;

  return normalized;
end;
$function$;

revoke execute on function public.nexlab_normalize_asset_url_v26120(text)
from public, anon;
grant execute on function public.nexlab_normalize_asset_url_v26120(text)
to authenticated, service_role;

create or replace function public.nexlab_guard_asset_integrity_v26110()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  if new.quantidade <> 1 then
    raise exception 'Cada bem patrimonial deve possuir quantidade igual a 1.'
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

  -- Compatibilidade com a RPC v26.10: o valor legado recebido passa a alimentar
  -- o valor canônico de aquisição.
  if tg_op = 'INSERT'
     and coalesce(new.valor_aquisicao,0) = 0
     and coalesce(new.valor_unitario,0) > 0 then
    new.valor_aquisicao := new.valor_unitario;
  end if;

  if tg_op = 'UPDATE'
     and new.valor_unitario is distinct from old.valor_unitario
     and new.valor_aquisicao is not distinct from old.valor_aquisicao then
    new.valor_aquisicao := new.valor_unitario;
  end if;

  if new.valor_aquisicao is null or new.valor_aquisicao < 0 then
    raise exception 'O valor de aquisição não pode ser negativo.'
      using errcode = '23514';
  end if;

  new.nome := btrim(new.nome);
  new.categoria := btrim(new.categoria);
  new.codigo_patrimonial := upper(btrim(new.codigo_patrimonial));
  new.tombamento := upper(btrim(new.tombamento));
  new.marca := nullif(btrim(coalesce(new.marca,'')), '');
  new.modelo := nullif(btrim(coalesce(new.modelo,'')), '');
  new.numero_serie := nullif(upper(btrim(coalesce(new.numero_serie,''))), '');
  new.fornecedor := nullif(btrim(coalesce(new.fornecedor,'')), '');
  new.numero_nota_fiscal := nullif(upper(btrim(coalesce(new.numero_nota_fiscal,''))), '');
  new.localizacao := nullif(btrim(coalesce(new.localizacao,'')), '');
  new.descricao := nullif(btrim(coalesce(new.descricao,'')), '');
  new.link_nota_fiscal := public.nexlab_normalize_asset_url_v26120(new.link_nota_fiscal);
  new.link_garantia := public.nexlab_normalize_asset_url_v26120(new.link_garantia);
  new.link_manual := public.nexlab_normalize_asset_url_v26120(new.link_manual);
  new.link_referencia := public.nexlab_normalize_asset_url_v26120(new.link_referencia);

  -- valor_aquisicao é a única origem; os campos antigos permanecem derivados.
  new.valor_aquisicao := round(new.valor_aquisicao,2);
  new.valor_unitario := new.valor_aquisicao;
  new.valor := new.valor_aquisicao;

  new.qt_manutencao := new.quantidade_manutencao;
  new.qt_danificado := new.quantidade_danificada;
  new.qt_uso := 0;
  new.qt_disponivel := case
    when new.quantidade_manutencao + new.quantidade_danificada = 0 then 1
    else 0
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

-- =============================================================================
-- 5) Cadastro estruturado transacional
-- =============================================================================

create or replace function public.nexlab_set_asset_details_v26120(
  p_asset_id uuid,
  p_payload jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
with updated as (
  update public.assets a
  set
    marca = nullif(btrim(coalesce(p_payload->>'marca','')), ''),
    modelo = nullif(btrim(coalesce(p_payload->>'modelo','')), ''),
    numero_serie = nullif(upper(btrim(coalesce(p_payload->>'numero_serie',''))), ''),
    responsavel_id = nullif(btrim(coalesce(p_payload->>'responsavel_id','')), '')::uuid,
    fornecedor = nullif(btrim(coalesce(p_payload->>'fornecedor','')), ''),
    numero_nota_fiscal = nullif(upper(btrim(coalesce(p_payload->>'numero_nota_fiscal',''))), ''),
    data_aquisicao = nullif(btrim(coalesce(p_payload->>'data_aquisicao','')), '')::date,
    garantia_ate = nullif(btrim(coalesce(p_payload->>'garantia_ate','')), '')::date,
    valor_aquisicao = round(replace(coalesce(p_payload->>'valor_aquisicao','0'), ',', '.')::numeric,2),
    link_nota_fiscal = public.nexlab_normalize_asset_url_v26120(p_payload->>'link_nota_fiscal'),
    link_garantia = public.nexlab_normalize_asset_url_v26120(p_payload->>'link_garantia'),
    link_manual = public.nexlab_normalize_asset_url_v26120(p_payload->>'link_manual'),
    link_referencia = public.nexlab_normalize_asset_url_v26120(p_payload->>'link_referencia')
  where a.id = p_asset_id
    and public.nexlab_has_permission_v26100('module_patrimonio')
    and public.nexlab_has_permission_v26100('patrimonio_manage')
  returning a.*
)
select coalesce(
  (select jsonb_build_object('ok',true,'asset',to_jsonb(updated)) from updated),
  jsonb_build_object('ok',false)
);
$function$;

-- Função interna: não é endpoint direto do aplicativo.
revoke execute on function public.nexlab_set_asset_details_v26120(uuid,jsonb)
from public, anon, authenticated;
grant execute on function public.nexlab_set_asset_details_v26120(uuid,jsonb)
to service_role;

create or replace function public.nexlab_save_asset_v26120(
  p_asset_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  core_result jsonb;
  detail_result jsonb;
  saved_id uuid;
begin
  -- Reutiliza a RPC transacional/auditada da v26.10 para o núcleo do registro.
  core_result := public.nexlab_save_asset_v26100(
    p_asset_id,
    coalesce(p_payload,'{}'::jsonb)
      || jsonb_build_object(
        'valor_unitario',coalesce(p_payload->>'valor_aquisicao','0')
      )
  );

  saved_id := (core_result->'asset'->>'id')::uuid;
  if saved_id is null then
    raise exception 'O bem patrimonial não foi salvo.';
  end if;

  detail_result := public.nexlab_set_asset_details_v26120(saved_id,p_payload);
  if coalesce((detail_result->>'ok')::boolean,false) = false then
    raise exception 'Os detalhes patrimoniais não foram salvos.';
  end if;

  return detail_result;
end;
$function$;

revoke execute on function public.nexlab_save_asset_v26120(uuid,jsonb)
from public, anon;
grant execute on function public.nexlab_save_asset_v26120(uuid,jsonb)
to authenticated, service_role;

-- =============================================================================
-- 6) Histórico automático de localização e responsável
-- =============================================================================

create or replace function public.nexlab_capture_asset_movement_v26120()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_type text := coalesce(
    nullif(current_setting('nexlab.asset_movement_type',true),''),
    'ajuste_cadastro'
  );
  v_reason text := coalesce(
    nullif(current_setting('nexlab.asset_movement_reason',true),''),
    'Localização ou responsável atualizado no cadastro.'
  );
  v_link text := nullif(current_setting('nexlab.asset_movement_link',true),'');
  v_date date := coalesce(
    nullif(current_setting('nexlab.asset_movement_date',true),'')::date,
    current_date
  );
begin
  -- O INSERT é concluído pela RPC principal e depois recebe os campos
  -- estruturados. O primeiro UPDATE correspondente gera uma única linha inicial.
  if tg_op = 'INSERT' then
    return new;
  end if;

  if not exists (
       select 1 from public.asset_movements m where m.asset_id = new.id
     )
     and (new.localizacao is not null or new.responsavel_id is not null) then
    insert into public.asset_movements (
      asset_id,tipo,destino_localizacao,destino_responsavel_id,
      motivo,data_movimentacao,actor_id
    ) values (
      new.id,'cadastro_inicial',new.localizacao,new.responsavel_id,
      'Cadastro inicial do bem patrimonial.',
      coalesce(new.data_aquisicao,current_date),auth.uid()
    );
  elsif old.localizacao is distinct from new.localizacao
     or old.responsavel_id is distinct from new.responsavel_id then
    if v_type not in ('transferencia','devolucao','ajuste_cadastro') then
      v_type := 'ajuste_cadastro';
    end if;

    insert into public.asset_movements (
      asset_id,tipo,origem_localizacao,destino_localizacao,
      origem_responsavel_id,destino_responsavel_id,motivo,
      link_externo,data_movimentacao,actor_id
    ) values (
      new.id,v_type,old.localizacao,new.localizacao,
      old.responsavel_id,new.responsavel_id,v_reason,
      public.nexlab_normalize_asset_url_v26120(v_link),v_date,auth.uid()
    );
  end if;

  return new;
end;
$function$;

revoke execute on function public.nexlab_capture_asset_movement_v26120()
from public, anon, authenticated;

drop trigger if exists nexlab_capture_asset_movement_v26120 on public.assets;
create trigger nexlab_capture_asset_movement_v26120
after insert or update of localizacao,responsavel_id on public.assets
for each row execute function public.nexlab_capture_asset_movement_v26120();

-- =============================================================================
-- 7) Consultas do histórico e responsáveis
-- =============================================================================

create or replace function public.nexlab_list_asset_responsibles_v26120()
returns jsonb
language sql
security definer
set search_path = ''
as $function$
select case
  when public.nexlab_has_permission_v26100('module_patrimonio')
   and public.nexlab_has_permission_v26100('patrimonio_view')
  then coalesce((
    select jsonb_agg(
      jsonb_build_object('id',p.id,'nome',p.nome)
      order by p.nome
    )
    from public.profiles p
    where p.ativo is distinct from false
      and coalesce(p.role_request_status,'approved') = 'approved'
  ),'[]'::jsonb)
  else '[]'::jsonb
end;
$function$;

revoke execute on function public.nexlab_list_asset_responsibles_v26120()
from public, anon;
grant execute on function public.nexlab_list_asset_responsibles_v26120()
to authenticated, service_role;

create or replace function public.nexlab_get_asset_history_v26120(p_asset_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
select jsonb_build_object(
  'maintenance',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',m.id,
      'status',m.status,
      'data_envio',m.data_envio,
      'data_retorno',m.data_retorno,
      'descricao_problema',m.descricao_problema,
      'descricao_solucao',m.descricao_solucao,
      'observacoes',m.observacoes,
      'fornecedor',m.fornecedor,
      'custo',m.custo,
      'link_externo',m.link_externo,
      'responsavel_nome',p.nome,
      'created_at',m.created_at
    ) order by m.created_at desc)
    from public.asset_maintenance m
    left join public.profiles p on p.id = m.responsavel_id
    where m.asset_id = p_asset_id
  ),'[]'::jsonb),
  'movements',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',mv.id,
      'tipo',mv.tipo,
      'origem_localizacao',mv.origem_localizacao,
      'destino_localizacao',mv.destino_localizacao,
      'origem_responsavel_nome',po.nome,
      'destino_responsavel_nome',pd.nome,
      'motivo',mv.motivo,
      'link_externo',mv.link_externo,
      'data_movimentacao',mv.data_movimentacao,
      'actor_nome',pa.nome,
      'created_at',mv.created_at
    ) order by mv.data_movimentacao desc,mv.created_at desc)
    from public.asset_movements mv
    left join public.profiles po on po.id = mv.origem_responsavel_id
    left join public.profiles pd on pd.id = mv.destino_responsavel_id
    left join public.profiles pa on pa.id = mv.actor_id
    where mv.asset_id = p_asset_id
  ),'[]'::jsonb)
)
where public.nexlab_has_permission_v26100('module_patrimonio')
  and public.nexlab_has_permission_v26100('patrimonio_view')
  and exists(select 1 from public.assets a where a.id = p_asset_id);
$function$;

revoke execute on function public.nexlab_get_asset_history_v26120(uuid)
from public, anon;
grant execute on function public.nexlab_get_asset_history_v26120(uuid)
to authenticated, service_role;

-- =============================================================================
-- 8) Manutenções transacionais
-- =============================================================================

create or replace function public.nexlab_insert_asset_maintenance_v26120(
  p_asset_id uuid,
  p_payload jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
with inserted as (
  insert into public.asset_maintenance (
    asset_id,motivo,data_envio,descricao_problema,observacoes,quantidade,
    responsavel_id,status,fornecedor,custo,link_externo,updated_at
  )
  select
    p_asset_id,
    'Manutenção patrimonial',
    coalesce(
      nullif(btrim(coalesce(p_payload->>'data_envio','')),'')::date,
      current_date
    ),
    btrim(p_payload->>'descricao_problema'),
    nullif(btrim(coalesce(p_payload->>'observacoes','')),''),
    1,
    auth.uid(),
    'aberta',
    nullif(btrim(coalesce(p_payload->>'fornecedor','')),''),
    round(replace(coalesce(p_payload->>'custo','0'),',','.')::numeric,2),
    public.nexlab_normalize_asset_url_v26120(p_payload->>'link_externo'),
    now()
  where public.nexlab_has_permission_v26100('module_patrimonio')
    and public.nexlab_has_permission_v26100('patrimonio_manage')
    and exists(select 1 from public.assets a where a.id = p_asset_id)
    and not exists(
      select 1 from public.asset_maintenance m
      where m.asset_id = p_asset_id and m.status = 'aberta'
    )
  returning *
)
select coalesce(
  (select jsonb_build_object('ok',true,'maintenance',to_jsonb(inserted)) from inserted),
  jsonb_build_object('ok',false)
);
$function$;

-- Função interna: a interface chama somente a RPC de abertura completa.
revoke execute on function public.nexlab_insert_asset_maintenance_v26120(uuid,jsonb)
from public, anon, authenticated;
grant execute on function public.nexlab_insert_asset_maintenance_v26120(uuid,jsonb)
to service_role;

create or replace function public.nexlab_start_asset_maintenance_v26120(
  p_asset_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  maintenance_result jsonb;
  condition_result jsonb;
begin
  maintenance_result := public.nexlab_insert_asset_maintenance_v26120(
    p_asset_id,p_payload
  );

  if coalesce((maintenance_result->>'ok')::boolean,false) = false then
    raise exception 'Não foi possível abrir a manutenção.';
  end if;

  condition_result := public.nexlab_update_asset_condition_v26100(
    p_asset_id,1,0
  );

  return jsonb_build_object(
    'ok',true,
    'maintenance',maintenance_result->'maintenance',
    'asset',condition_result->'asset'
  );
end;
$function$;

revoke execute on function public.nexlab_start_asset_maintenance_v26120(uuid,jsonb)
from public, anon;
grant execute on function public.nexlab_start_asset_maintenance_v26120(uuid,jsonb)
to authenticated, service_role;

create or replace function public.nexlab_finish_asset_maintenance_v26120(
  p_maintenance_id uuid,
  p_payload jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
with finished as (
  update public.asset_maintenance m
  set
    status = 'concluida',
    data_retorno = coalesce(
      nullif(btrim(coalesce(p_payload->>'data_retorno','')),'')::date,
      current_date
    ),
    descricao_solucao = btrim(p_payload->>'descricao_solucao'),
    observacoes = coalesce(
      nullif(btrim(coalesce(p_payload->>'observacoes','')),''),
      m.observacoes
    ),
    custo = round(
      replace(coalesce(p_payload->>'custo',m.custo::text,'0'),',','.')::numeric,
      2
    ),
    link_externo = coalesce(
      public.nexlab_normalize_asset_url_v26120(p_payload->>'link_externo'),
      m.link_externo
    ),
    updated_at = now()
  where m.id = p_maintenance_id
    and m.status = 'aberta'
    and char_length(btrim(coalesce(p_payload->>'descricao_solucao','')))
      between 3 and 2000
    and public.nexlab_has_permission_v26100('module_patrimonio')
    and public.nexlab_has_permission_v26100('patrimonio_manage')
  returning m.*
), asset_updated as (
  update public.assets a
  set quantidade_manutencao = 0,
      quantidade_danificada = 0
  from finished f
  where a.id = f.asset_id
  returning a.*
), audit_row as (
  select public.record_security_audit(
    'asset_condition_updated',
    null::text,
    jsonb_build_object(
      'entity_id',a.id,
      'entity_name',a.nome,
      'module','patrimonio',
      'maintenance_id',f.id,
      'maintenance_status','concluida'
    )
  ) as audit_id
  from asset_updated a
  cross join finished f
)
select coalesce((
  select jsonb_build_object(
    'ok',true,
    'maintenance',to_jsonb(f),
    'asset',to_jsonb(a),
    'audit_id',ar.audit_id
  )
  from finished f
  cross join asset_updated a
  cross join audit_row ar
),jsonb_build_object('ok',false));
$function$;

revoke execute on function public.nexlab_finish_asset_maintenance_v26120(uuid,jsonb)
from public, anon;
grant execute on function public.nexlab_finish_asset_maintenance_v26120(uuid,jsonb)
to authenticated, service_role;

-- =============================================================================
-- 9) Movimentação transacional
-- =============================================================================

create or replace function public.nexlab_move_asset_v26120(
  p_asset_id uuid,
  p_payload jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
with settings as (
  select
    set_config(
      'nexlab.asset_movement_type',
      case when p_payload->>'tipo' = 'devolucao'
        then 'devolucao' else 'transferencia' end,
      true
    ),
    set_config(
      'nexlab.asset_movement_reason',
      coalesce(nullif(btrim(p_payload->>'motivo'),''),'Movimentação patrimonial.'),
      true
    ),
    set_config(
      'nexlab.asset_movement_link',
      coalesce(p_payload->>'link_externo',''),
      true
    ),
    set_config(
      'nexlab.asset_movement_date',
      coalesce(nullif(p_payload->>'data_movimentacao',''),current_date::text),
      true
    )
), previous as (
  select a.* from public.assets a where a.id = p_asset_id
), updated as (
  update public.assets a
  set
    localizacao = nullif(
      btrim(coalesce(p_payload->>'destino_localizacao','')),
      ''
    ),
    responsavel_id = nullif(
      btrim(coalesce(p_payload->>'destino_responsavel_id','')),
      ''
    )::uuid
  from previous p, settings s
  where a.id = p.id
    and (
      a.localizacao is distinct from nullif(
        btrim(coalesce(p_payload->>'destino_localizacao','')),
        ''
      )
      or a.responsavel_id is distinct from nullif(
        btrim(coalesce(p_payload->>'destino_responsavel_id','')),
        ''
      )::uuid
    )
    and public.nexlab_has_permission_v26100('module_patrimonio')
    and public.nexlab_has_permission_v26100('patrimonio_manage')
  returning a.*
), movement_updated as (
  -- A linha é criada pelo trigger da atualização acima. Este CTE apenas devolve
  -- o evento solicitado; o histórico consultado pelo app é a fonte definitiva.
  select m.*
  from public.asset_movements m
  join updated u on u.id = m.asset_id
  order by m.created_at desc,m.id desc
  limit 1
), audit_row as (
  select public.record_security_audit(
    'asset_updated',
    null::text,
    jsonb_build_object(
      'entity_id',u.id,
      'entity_name',u.nome,
      'module','patrimonio',
      'operation','movement',
      'from_location',p.localizacao,
      'to_location',u.localizacao,
      'from_responsible',p.responsavel_id,
      'to_responsible',u.responsavel_id
    )
  ) as audit_id
  from updated u
  cross join previous p
)
select coalesce((
  select jsonb_build_object(
    'ok',true,
    'asset',to_jsonb(u),
    'movement',to_jsonb(m),
    'audit_id',a.audit_id
  )
  from updated u
  cross join movement_updated m
  cross join audit_row a
),jsonb_build_object('ok',false));
$function$;

revoke execute on function public.nexlab_move_asset_v26120(uuid,jsonb)
from public, anon;
grant execute on function public.nexlab_move_asset_v26120(uuid,jsonb)
to authenticated, service_role;

-- Remove auxiliares temporários que não fazem parte da API pública.
drop function if exists public.nexlab_create_asset_v26120(jsonb);
drop function if exists public.nexlab_finish_asset_maintenance_row_v26120(uuid,jsonb);
