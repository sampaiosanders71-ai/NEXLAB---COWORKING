-- NexLab v25.12.0 — Matriz de Permissões e Acessos
-- Execute integralmente no Supabase SQL Editor após a v25.11.1.
-- Não exige alteração em Edge Functions, Secrets ou Cron.

begin;

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 0. Compatibilidade com a proteção de acessos das versões anteriores
-- -----------------------------------------------------------------------------

create or replace function public.guard_acessos()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  actor_is_admin boolean := false;
  trusted_flow boolean :=
    coalesce(current_setting('nexlab.permission_flow', true), '') = 'trusted'
    or coalesce(current_setting('nexlab.profile_flow', true), '') = 'trusted';
begin
  if new.acessos is not distinct from old.acessos then
    return new;
  end if;

  -- Permite sincronizações internas controladas, migrations executadas pelo
  -- SQL Editor e alterações feitas por um Administrador autenticado.
  if trusted_flow or auth.uid() is null then
    return new;
  end if;

  begin
    actor_is_admin := public.nexlab_is_admin();
  exception
    when others then
      actor_is_admin := false;
  end;

  if actor_is_admin then
    return new;
  end if;

  raise exception 'Apenas administradores podem alterar os acessos especiais.'
    using errcode = '42501';
end;
$$;

revoke all on function public.guard_acessos() from public;

-- -----------------------------------------------------------------------------
-- 1. Catálogo, padrões por perfil, exceções por usuário e histórico
-- -----------------------------------------------------------------------------

do $$
declare
  profile_id_type text;
begin
  if to_regclass('public.profiles') is null then
    raise exception 'A tabela public.profiles não existe. Execute primeiro as versões anteriores do NexLab.';
  end if;

  select format_type(a.atttypid, a.atttypmod)
    into profile_id_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'id'
    and a.attnum > 0
    and not a.attisdropped;

  if profile_id_type is null then
    raise exception 'Não foi possível identificar o tipo de profiles.id.';
  end if;

  alter table public.profiles
    add column if not exists effective_permissions text[] not null default '{}'::text[];

  create table if not exists public.nexlab_permission_catalog (
    permission_key text primary key,
    label text not null,
    description text not null default '',
    category text not null,
    module_id text not null,
    core boolean not null default false,
    admin_only boolean not null default false,
    grantable boolean not null default true,
    eligible_roles text[] not null default array['admin','coordenador','bolsista','coworking_junior']::text[],
    sort_order integer not null default 100,
    active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
  );

  if to_regclass('public.nexlab_role_permission_defaults') is null then
    execute format(
      'create table public.nexlab_role_permission_defaults (
         role_key text not null,
         permission_key text not null references public.nexlab_permission_catalog(permission_key) on delete cascade,
         allowed boolean not null default false,
         updated_by %s null references public.profiles(id) on delete set null,
         updated_at timestamptz not null default now(),
         primary key (role_key, permission_key),
         constraint nexlab_role_permission_defaults_role_check
           check (role_key in (''admin'',''coordenador'',''bolsista'',''coworking_junior''))
       )',
      profile_id_type
    );
  end if;

  if to_regclass('public.nexlab_user_permission_overrides') is null then
    execute format(
      'create table public.nexlab_user_permission_overrides (
         user_id %s not null references public.profiles(id) on delete cascade,
         permission_key text not null references public.nexlab_permission_catalog(permission_key) on delete cascade,
         effect text not null,
         reason text not null,
         updated_by %s null references public.profiles(id) on delete set null,
         updated_at timestamptz not null default now(),
         primary key (user_id, permission_key),
         constraint nexlab_user_permission_overrides_effect_check
           check (effect in (''allow'',''deny''))
       )',
      profile_id_type,
      profile_id_type
    );
  end if;

  if to_regclass('public.nexlab_permission_history') is null then
    execute format(
      'create table public.nexlab_permission_history (
         id uuid primary key default gen_random_uuid(),
         scope text not null,
         role_key text null,
         user_id %s null references public.profiles(id) on delete cascade,
         permission_key text null references public.nexlab_permission_catalog(permission_key) on delete set null,
         previous_value text null,
         next_value text null,
         reason text not null,
         actor_id %s null references public.profiles(id) on delete set null,
         metadata jsonb not null default ''{}''::jsonb,
         created_at timestamptz not null default now(),
         constraint nexlab_permission_history_scope_check
           check (scope in (''role_default'',''user_override'',''restore_defaults'',''migration''))
       )',
      profile_id_type,
      profile_id_type
    );
  end if;
end
$$;


-- Protege a coluna calculada contra alterações diretas no perfil.
create or replace function public.nexlab_guard_effective_permissions()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  actor_is_admin boolean := false;
  trusted_flow boolean :=
    coalesce(current_setting('nexlab.permission_flow', true), '') = 'trusted'
    or coalesce(current_setting('nexlab.profile_flow', true), '') = 'trusted';
begin
  if new.effective_permissions is not distinct from old.effective_permissions then
    return new;
  end if;

  if trusted_flow or auth.uid() is null then
    return new;
  end if;

  begin
    actor_is_admin := public.nexlab_is_admin();
  exception
    when others then
      actor_is_admin := false;
  end;

  if actor_is_admin then
    return new;
  end if;

  raise exception 'As permissões efetivas só podem ser recalculadas pelo fluxo seguro do NexLab.'
    using errcode = '42501';
end;
$$;

revoke all on function public.nexlab_guard_effective_permissions() from public;

drop trigger if exists nexlab_guard_effective_permissions_trigger
on public.profiles;

create trigger nexlab_guard_effective_permissions_trigger
before update of effective_permissions on public.profiles
for each row
execute function public.nexlab_guard_effective_permissions();

create index if not exists nexlab_role_permission_defaults_role_idx
  on public.nexlab_role_permission_defaults (role_key, allowed);

create index if not exists nexlab_user_permission_overrides_user_idx
  on public.nexlab_user_permission_overrides (user_id, effect);

create index if not exists nexlab_permission_history_created_idx
  on public.nexlab_permission_history (created_at desc);

create index if not exists nexlab_permission_history_user_created_idx
  on public.nexlab_permission_history (user_id, created_at desc);

-- -----------------------------------------------------------------------------
-- 2. Catálogo oficial de permissões da v25.12
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
  ('module_dashboard', 'Dashboard', 'Visão inicial e indicadores permitidos ao perfil.', 'Essenciais', 'dashboard', true, false, false, array['admin','coordenador','bolsista','coworking_junior'], 10, true, now()),
  ('module_pendencias', 'Pendências', 'Central pessoal de solicitações e itens que exigem atenção.', 'Essenciais', 'pendencias', true, false, false, array['admin','coordenador','bolsista','coworking_junior'], 20, true, now()),
  ('module_agenda', 'Agenda', 'Agenda consolidada do NexLab.', 'Essenciais', 'agenda', true, false, false, array['admin','coordenador','bolsista','coworking_junior'], 30, true, now()),
  ('module_notificacoes', 'Notificações', 'Caixa de entrada e preferências pessoais de notificação.', 'Essenciais', 'notificacoes', true, false, false, array['admin','coordenador','bolsista','coworking_junior'], 40, true, now()),
  ('module_perfil', 'Meu Perfil', 'Consulta do perfil atual e situação do vínculo.', 'Essenciais', 'perfil', true, false, false, array['admin','coordenador','bolsista','coworking_junior'], 50, true, now()),
  ('module_equipes', 'Equipes', 'Consulta e operação do módulo de equipes.', 'Gestão', 'equipes', false, false, true, array['admin','coordenador','bolsista','coworking_junior'], 110, true, now()),
  ('module_projetos', 'Projetos', 'Consulta e operação do módulo de projetos.', 'Operação', 'projetos', false, false, true, array['admin','coordenador','bolsista','coworking_junior'], 120, true, now()),
  ('module_patrimonio', 'Patrimônio', 'Consulta e gestão patrimonial conforme as regras internas do módulo.', 'Operação', 'patrimonio', false, false, true, array['admin','coordenador','bolsista','coworking_junior'], 130, true, now()),
  ('module_reserva', 'Reserva de Sala', 'Solicitações de reserva e reuniões.', 'Operação', 'reserva', false, false, true, array['admin','coordenador','bolsista','coworking_junior'], 140, true, now()),
  ('module_marketing', 'Marketing', 'Calendário e campanhas de marketing.', 'Comunicação', 'marketing', false, false, true, array['admin','coordenador','bolsista','coworking_junior'], 210, true, now()),
  ('module_eventos', 'Eventos', 'Consulta e operação do módulo de eventos no escopo atual.', 'Comunicação', 'eventos', false, false, true, array['admin','coordenador','bolsista','coworking_junior'], 220, true, now()),
  ('module_mural', 'Mural Interno', 'Feed interno exclusivo dos perfis operacionais definidos no projeto.', 'Comunicação', 'mural', false, false, true, array['bolsista','coworking_junior'], 230, true, now()),
  ('module_feedback', 'Feedback', 'Envio e acompanhamento de feedbacks e sugestões.', 'Comunicação', 'feedback', false, false, true, array['admin','coordenador','bolsista','coworking_junior'], 240, true, now()),
  ('module_relatorios', 'Relatórios', 'Acesso ao módulo de relatórios conforme a proteção de cada relatório.', 'Sistema', 'relatorios', false, false, true, array['admin','coordenador','bolsista','coworking_junior'], 310, true, now()),
  ('module_participantes', 'Usuários e vínculos', 'Gestão administrativa de usuários, vínculos e situação das contas.', 'Administração', 'participantes', false, true, false, array['admin'], 410, true, now()),
  ('module_permissoes', 'Matriz de Permissões', 'Configuração dos padrões por perfil e exceções individuais.', 'Administração', 'permissoes', false, true, false, array['admin'], 420, true, now()),
  ('module_saude-sistema', 'Saúde do Sistema', 'Diagnóstico técnico e configurações administrativas.', 'Administração', 'saude-sistema', false, true, false, array['admin'], 430, true, now()),
  ('module_logs', 'Central de Atividades', 'Logs operacionais e auditoria protegida.', 'Administração', 'logs', false, true, false, array['admin'], 440, true, now())
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

-- Cria uma linha padrão para cada combinação perfil/permissão sem sobrescrever
-- decisões administrativas existentes caso a migration seja executada novamente.
insert into public.nexlab_role_permission_defaults (
  role_key,
  permission_key,
  allowed,
  updated_at
)
select
  role_data.role_key,
  permission_data.permission_key,
  case
    when permission_data.core then true
    when permission_data.admin_only then role_data.role_key = 'admin'
    when role_data.role_key = 'admin' then permission_data.permission_key <> 'module_mural'
    when role_data.role_key = 'coordenador' then permission_data.permission_key in (
      'module_equipes','module_projetos','module_patrimonio','module_reserva',
      'module_marketing','module_eventos','module_feedback','module_relatorios'
    )
    when role_data.role_key in ('bolsista','coworking_junior') then permission_data.permission_key in (
      'module_equipes','module_projetos','module_reserva','module_eventos',
      'module_mural','module_feedback'
    )
    else false
  end,
  now()
from (
  values ('admin'), ('coordenador'), ('bolsista'), ('coworking_junior')
) as role_data(role_key)
cross join public.nexlab_permission_catalog permission_data
on conflict (role_key, permission_key) do nothing;

-- -----------------------------------------------------------------------------
-- 3. RLS: leitura e escrita técnica exclusivamente administrativa
-- -----------------------------------------------------------------------------

alter table public.nexlab_permission_catalog enable row level security;
alter table public.nexlab_role_permission_defaults enable row level security;
alter table public.nexlab_user_permission_overrides enable row level security;
alter table public.nexlab_permission_history enable row level security;

revoke all on public.nexlab_permission_catalog from anon;
revoke all on public.nexlab_role_permission_defaults from anon;
revoke all on public.nexlab_user_permission_overrides from anon;
revoke all on public.nexlab_permission_history from anon;

revoke insert, update, delete on public.nexlab_permission_catalog from authenticated;
revoke insert, update, delete on public.nexlab_role_permission_defaults from authenticated;
revoke insert, update, delete on public.nexlab_user_permission_overrides from authenticated;
revoke insert, update, delete on public.nexlab_permission_history from authenticated;

grant select on public.nexlab_permission_catalog to authenticated;
grant select on public.nexlab_role_permission_defaults to authenticated;
grant select on public.nexlab_user_permission_overrides to authenticated;
grant select on public.nexlab_permission_history to authenticated;

drop policy if exists nexlab_permission_catalog_admin_select on public.nexlab_permission_catalog;
create policy nexlab_permission_catalog_admin_select
on public.nexlab_permission_catalog
for select
to authenticated
using (public.nexlab_is_admin());

drop policy if exists nexlab_role_permission_defaults_admin_select on public.nexlab_role_permission_defaults;
create policy nexlab_role_permission_defaults_admin_select
on public.nexlab_role_permission_defaults
for select
to authenticated
using (public.nexlab_is_admin());

drop policy if exists nexlab_user_permission_overrides_admin_select on public.nexlab_user_permission_overrides;
create policy nexlab_user_permission_overrides_admin_select
on public.nexlab_user_permission_overrides
for select
to authenticated
using (public.nexlab_is_admin());

drop policy if exists nexlab_permission_history_admin_select on public.nexlab_permission_history;
create policy nexlab_permission_history_admin_select
on public.nexlab_permission_history
for select
to authenticated
using (public.nexlab_is_admin());

-- -----------------------------------------------------------------------------
-- 4. Cálculo centralizado das permissões efetivas
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_recalculate_profile_permissions(
  p_target_user_id text
)
returns text[]
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  target_role text;
  permissions_result text[] := '{}'::text[];
  legacy_tokens text[] := '{}'::text[];
  accesses_type text;
begin
  select case
           when lower(coalesce(p.role::text, '')) = 'administrador' then 'admin'
           else lower(coalesce(p.role::text, ''))
         end
    into target_role
  from public.profiles p
  where p.id::text = p_target_user_id
  for update;

  if target_role is null then
    raise exception 'Usuário não encontrado.' using errcode = 'P0002';
  end if;

  select coalesce(array_agg(c.permission_key order by c.sort_order), '{}'::text[])
    into permissions_result
  from public.nexlab_permission_catalog c
  left join public.nexlab_role_permission_defaults d
    on d.role_key = target_role
   and d.permission_key = c.permission_key
  left join public.nexlab_user_permission_overrides o
    on o.user_id::text = p_target_user_id
   and o.permission_key = c.permission_key
  where c.active
    and target_role = any(c.eligible_roles)
    and (
      c.core
      or (c.admin_only and target_role = 'admin')
      or (
        not c.admin_only
        and case
          when o.effect = 'allow' then true
          when o.effect = 'deny' then false
          else coalesce(d.allowed, false)
        end
      )
    );

  -- Autoriza apenas esta sincronização interna das colunas calculadas.
  perform set_config('nexlab.permission_flow', 'trusted', true);

  update public.profiles
  set effective_permissions = permissions_result
  where id::text = p_target_user_id;

  legacy_tokens := array_remove(array[
    case when 'module_patrimonio' = any(permissions_result) then 'patr' end,
    case when 'module_marketing' = any(permissions_result) then 'mkt' end,
    case when 'module_relatorios' = any(permissions_result) then 'usr_report' end
  ]::text[], null);

  select format_type(a.atttypid, a.atttypmod)
    into accesses_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'acessos'
    and a.attnum > 0
    and not a.attisdropped;

  if accesses_type = 'text[]' then
    execute $sql$
      update public.profiles
      set acessos = array(
        select distinct token
        from unnest(
          array_remove(
            array_remove(
              array_remove(coalesce(acessos, '{}'::text[]), 'patr'),
              'mkt'
            ),
            'usr_report'
          ) || $1
        ) as token
        where token is not null and token <> ''
        order by token
      )
      where id::text = $2
    $sql$
    using legacy_tokens, p_target_user_id;
  elsif accesses_type = 'jsonb' then
    execute $sql$
      update public.profiles
      set acessos = (
        select coalesce(jsonb_agg(token order by token), '[]'::jsonb)
        from (
          select distinct value as token
          from jsonb_array_elements_text(coalesce(acessos, '[]'::jsonb))
          where value not in ('patr','mkt','usr_report')
          union
          select unnest($1::text[])
        ) values_set
        where token is not null and token <> ''
      )
      where id::text = $2
    $sql$
    using legacy_tokens, p_target_user_id;
  elsif accesses_type = 'json' then
    execute $sql$
      update public.profiles
      set acessos = (
        select coalesce(jsonb_agg(token order by token), '[]'::jsonb)::json
        from (
          select distinct value as token
          from jsonb_array_elements_text(coalesce(acessos::jsonb, '[]'::jsonb))
          where value not in ('patr','mkt','usr_report')
          union
          select unnest($1::text[])
        ) values_set
        where token is not null and token <> ''
      )
      where id::text = $2
    $sql$
    using legacy_tokens, p_target_user_id;
  end if;

  perform set_config('nexlab.permission_flow', '', true);

  return permissions_result;
end;
$$;

revoke all on function public.nexlab_recalculate_profile_permissions(text) from public;

create or replace function public.nexlab_recalculate_all_permissions()
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  profile_row record;
  processed integer := 0;
begin
  for profile_row in
    select p.id::text as id_text
    from public.profiles p
  loop
    perform public.nexlab_recalculate_profile_permissions(profile_row.id_text);
    processed := processed + 1;
  end loop;

  return processed;
end;
$$;

revoke all on function public.nexlab_recalculate_all_permissions() from public;

create or replace function public.nexlab_recalculate_permissions_after_role_change()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if tg_op = 'INSERT' or new.role is distinct from old.role then
    perform public.nexlab_recalculate_profile_permissions(new.id::text);
  end if;
  return new;
end;
$$;

drop trigger if exists nexlab_recalculate_permissions_after_profile_insert_trigger
on public.profiles;

drop trigger if exists nexlab_recalculate_permissions_after_role_change_trigger
on public.profiles;

create trigger nexlab_recalculate_permissions_after_profile_insert_trigger
after insert on public.profiles
for each row
execute function public.nexlab_recalculate_permissions_after_role_change();

create trigger nexlab_recalculate_permissions_after_role_change_trigger
after update of role on public.profiles
for each row
execute function public.nexlab_recalculate_permissions_after_role_change();

-- -----------------------------------------------------------------------------
-- 5. Leitura consolidada da matriz
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_get_permission_matrix()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'catalog', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.category, c.sort_order)
      from public.nexlab_permission_catalog c
      where c.active
    ), '[]'::jsonb),
    'defaults', coalesce((
      select jsonb_agg(to_jsonb(d) order by d.role_key, c.sort_order)
      from public.nexlab_role_permission_defaults d
      join public.nexlab_permission_catalog c
        on c.permission_key = d.permission_key
      where c.active
    ), '[]'::jsonb),
    'users', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'nome', p.nome,
          'email', p.email,
          'role', p.role::text,
          'ativo', p.ativo,
          'cadastro_completo', p.cadastro_completo,
          'effective_permissions', p.effective_permissions
        )
        order by p.nome nulls last, p.email nulls last
      )
      from public.profiles p
    ), '[]'::jsonb),
    'overrides', coalesce((
      select jsonb_agg(to_jsonb(o) order by o.user_id, c.sort_order)
      from public.nexlab_user_permission_overrides o
      join public.nexlab_permission_catalog c
        on c.permission_key = o.permission_key
    ), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(to_jsonb(h) order by h.created_at desc)
      from (
        select *
        from public.nexlab_permission_history
        order by created_at desc
        limit 80
      ) h
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.nexlab_get_permission_matrix() from public;
grant execute on function public.nexlab_get_permission_matrix() to authenticated;

-- -----------------------------------------------------------------------------
-- 6. Salvar padrões por perfil
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_admin_save_role_permissions(
  p_role text,
  p_permissions jsonb,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  permission_entry record;
  catalog_row public.nexlab_permission_catalog%rowtype;
  normalized_role text;
  old_allowed boolean;
  new_allowed boolean;
  changed_count integer := 0;
  profile_row record;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode = '42501';
  end if;

  normalized_role := lower(btrim(coalesce(p_role, '')));
  if normalized_role = 'administrador' then
    normalized_role := 'admin';
  end if;
  if normalized_role not in ('admin','coordenador','bolsista','coworking_junior') then
    raise exception 'Perfil inválido.' using errcode = '22023';
  end if;

  if jsonb_typeof(p_permissions) <> 'object' then
    raise exception 'A matriz de permissões deve ser um objeto JSON.' using errcode = '22023';
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Informe o motivo da alteração.' using errcode = '22023';
  end if;

  for permission_entry in
    select key as permission_key, value
    from jsonb_each(p_permissions)
  loop
    select *
      into catalog_row
    from public.nexlab_permission_catalog c
    where c.permission_key = permission_entry.permission_key
      and c.active;

    if catalog_row.permission_key is null then
      raise exception 'Permissão desconhecida: %', permission_entry.permission_key using errcode = '22023';
    end if;

    if catalog_row.core or catalog_row.admin_only or not catalog_row.grantable then
      raise exception 'A permissão % é protegida e não pode ser alterada.', catalog_row.label using errcode = '42501';
    end if;

    if jsonb_typeof(permission_entry.value) <> 'boolean' then
      raise exception 'O valor de % deve ser booleano.', catalog_row.label using errcode = '22023';
    end if;

    new_allowed := permission_entry.value = 'true'::jsonb;

    if new_allowed and not normalized_role = any(catalog_row.eligible_roles) then
      raise exception 'A permissão % não é compatível com o perfil %.', catalog_row.label, normalized_role using errcode = '23514';
    end if;

    select d.allowed
      into old_allowed
    from public.nexlab_role_permission_defaults d
    where d.role_key = normalized_role
      and d.permission_key = catalog_row.permission_key;

    old_allowed := coalesce(old_allowed, false);

    if old_allowed is distinct from new_allowed then
      insert into public.nexlab_role_permission_defaults (
        role_key, permission_key, allowed, updated_by, updated_at
      )
      values (
        normalized_role, catalog_row.permission_key, new_allowed, auth.uid(), now()
      )
      on conflict (role_key, permission_key) do update
      set
        allowed = excluded.allowed,
        updated_by = excluded.updated_by,
        updated_at = excluded.updated_at;

      insert into public.nexlab_permission_history (
        scope, role_key, permission_key, previous_value, next_value,
        reason, actor_id, metadata
      )
      values (
        'role_default', normalized_role, catalog_row.permission_key,
        old_allowed::text, new_allowed::text,
        btrim(p_reason), auth.uid(),
        jsonb_build_object('label', catalog_row.label)
      );

      changed_count := changed_count + 1;
    end if;
  end loop;

  for profile_row in
    select p.id::text as id_text
    from public.profiles p
    where lower(p.role::text) = normalized_role
  loop
    perform public.nexlab_recalculate_profile_permissions(profile_row.id_text);
  end loop;

  begin
    perform public.record_security_audit(
      'role_permissions_updated',
      normalized_role,
      jsonb_build_object(
        'changed_count', changed_count,
        'reason', btrim(p_reason)
      )
    );
  exception
    when undefined_function then null;
    when others then null;
  end;

  return jsonb_build_object(
    'ok', true,
    'role', normalized_role,
    'changed_count', changed_count
  );
end;
$$;

revoke all on function public.nexlab_admin_save_role_permissions(text, jsonb, text) from public;
grant execute on function public.nexlab_admin_save_role_permissions(text, jsonb, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 7. Salvar exceções individuais e restaurar padrões
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_admin_save_user_permissions(
  p_target_user_id text,
  p_overrides jsonb,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  target_profile record;
  permission_entry record;
  catalog_row public.nexlab_permission_catalog%rowtype;
  old_effect text;
  new_effect text;
  changed_count integer := 0;
  effective_result text[];
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode = '42501';
  end if;

  if nullif(btrim(coalesce(p_target_user_id, '')), '') is null then
    raise exception 'Usuário alvo não informado.' using errcode = '22023';
  end if;

  if jsonb_typeof(p_overrides) <> 'object' then
    raise exception 'As exceções devem ser um objeto JSON.' using errcode = '22023';
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Informe o motivo da alteração.' using errcode = '22023';
  end if;

  select
    p.id,
    p.nome,
    case when lower(p.role::text) = 'administrador' then 'admin' else lower(p.role::text) end as role_key
  into target_profile
  from public.profiles p
  where p.id::text = p_target_user_id
  for update;

  if target_profile.id is null then
    raise exception 'Usuário não encontrado.' using errcode = 'P0002';
  end if;

  for permission_entry in
    select key as permission_key, value
    from jsonb_each(p_overrides)
  loop
    select *
      into catalog_row
    from public.nexlab_permission_catalog c
    where c.permission_key = permission_entry.permission_key
      and c.active;

    if catalog_row.permission_key is null then
      raise exception 'Permissão desconhecida: %', permission_entry.permission_key using errcode = '22023';
    end if;

    if catalog_row.core or catalog_row.admin_only or not catalog_row.grantable then
      raise exception 'A permissão % é protegida e não aceita exceções individuais.', catalog_row.label using errcode = '42501';
    end if;

    new_effect := case
      when permission_entry.value is null or permission_entry.value = 'null'::jsonb then null
      else lower(trim(both '"' from permission_entry.value::text))
    end;

    if new_effect = 'default' then
      new_effect := null;
    end if;

    if new_effect is not null and new_effect not in ('allow','deny') then
      raise exception 'Exceção inválida para %.', catalog_row.label using errcode = '22023';
    end if;

    if new_effect = 'allow' and not target_profile.role_key = any(catalog_row.eligible_roles) then
      raise exception 'A permissão % não é compatível com o perfil atual do usuário.', catalog_row.label using errcode = '23514';
    end if;

    select o.effect
      into old_effect
    from public.nexlab_user_permission_overrides o
    where o.user_id::text = p_target_user_id
      and o.permission_key = catalog_row.permission_key;

    if old_effect is distinct from new_effect then
      if new_effect is null then
        delete from public.nexlab_user_permission_overrides
        where user_id::text = p_target_user_id
          and permission_key = catalog_row.permission_key;
      else
        insert into public.nexlab_user_permission_overrides (
          user_id, permission_key, effect, reason, updated_by, updated_at
        )
        values (
          target_profile.id, catalog_row.permission_key, new_effect,
          btrim(p_reason), auth.uid(), now()
        )
        on conflict (user_id, permission_key) do update
        set
          effect = excluded.effect,
          reason = excluded.reason,
          updated_by = excluded.updated_by,
          updated_at = excluded.updated_at;
      end if;

      insert into public.nexlab_permission_history (
        scope, user_id, permission_key, previous_value, next_value,
        reason, actor_id, metadata
      )
      values (
        'user_override', target_profile.id, catalog_row.permission_key,
        old_effect, coalesce(new_effect, 'default'),
        btrim(p_reason), auth.uid(),
        jsonb_build_object(
          'label', catalog_row.label,
          'role', target_profile.role_key
        )
      );

      changed_count := changed_count + 1;
    end if;
  end loop;

  effective_result := public.nexlab_recalculate_profile_permissions(p_target_user_id);

  if changed_count > 0 then
    begin
      perform public.nexlab_profile_flow_notification(
        p_target_user_id,
        'Acessos do NexLab atualizados',
        format(
          'Um Administrador atualizou seus acessos no NexLab. Foram registradas %s alteração(ões).',
          changed_count
        ),
        'perfil',
        format(
          'permission-update:%s:%s',
          p_target_user_id,
          extract(epoch from clock_timestamp())::bigint
        ),
        'normal',
        jsonb_build_object(
          'changed_count', changed_count,
          'effective_permissions', effective_result,
          'reason', btrim(p_reason)
        )
      );
    exception
      when undefined_function then null;
      when others then null;
    end;
  end if;

  begin
    perform public.record_security_audit(
      'user_permissions_updated',
      p_target_user_id,
      jsonb_build_object(
        'changed_count', changed_count,
        'reason', btrim(p_reason),
        'effective_permissions', effective_result
      )
    );
  exception
    when undefined_function then null;
    when others then null;
  end;

  return jsonb_build_object(
    'ok', true,
    'user_id', p_target_user_id,
    'changed_count', changed_count,
    'effective_permissions', effective_result
  );
end;
$$;

revoke all on function public.nexlab_admin_save_user_permissions(text, jsonb, text) from public;
grant execute on function public.nexlab_admin_save_user_permissions(text, jsonb, text) to authenticated;

create or replace function public.nexlab_admin_restore_user_permissions(
  p_target_user_id text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  target_profile record;
  deleted_count integer := 0;
  effective_result text[];
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode = '42501';
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Informe o motivo da restauração.' using errcode = '22023';
  end if;

  select p.id, p.nome,
         case when lower(p.role::text) = 'administrador' then 'admin' else lower(p.role::text) end as role_key
    into target_profile
  from public.profiles p
  where p.id::text = p_target_user_id
  for update;

  if target_profile.id is null then
    raise exception 'Usuário não encontrado.' using errcode = 'P0002';
  end if;

  select count(*)
    into deleted_count
  from public.nexlab_user_permission_overrides o
  where o.user_id::text = p_target_user_id;

  delete from public.nexlab_user_permission_overrides
  where user_id::text = p_target_user_id;

  insert into public.nexlab_permission_history (
    scope, user_id, previous_value, next_value, reason, actor_id, metadata
  )
  values (
    'restore_defaults', target_profile.id,
    deleted_count::text, '0', btrim(p_reason), auth.uid(),
    jsonb_build_object('role', target_profile.role_key)
  );

  effective_result := public.nexlab_recalculate_profile_permissions(p_target_user_id);

  begin
    perform public.nexlab_profile_flow_notification(
      p_target_user_id,
      'Permissões restauradas',
      'Suas permissões personalizadas foram removidas e os acessos padrão do seu perfil foram restaurados.',
      'perfil',
      format(
        'permission-restore:%s:%s',
        p_target_user_id,
        extract(epoch from clock_timestamp())::bigint
      ),
      'normal',
      jsonb_build_object(
        'removed_overrides', deleted_count,
        'effective_permissions', effective_result,
        'reason', btrim(p_reason)
      )
    );
  exception
    when undefined_function then null;
    when others then null;
  end;

  return jsonb_build_object(
    'ok', true,
    'user_id', p_target_user_id,
    'removed_overrides', deleted_count,
    'effective_permissions', effective_result
  );
end;
$$;

revoke all on function public.nexlab_admin_restore_user_permissions(text, text) from public;
grant execute on function public.nexlab_admin_restore_user_permissions(text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 8. Preservação dos acessos personalizados antigos e cálculo inicial
-- -----------------------------------------------------------------------------

do $$
declare
  accesses_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
    into accesses_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'acessos'
    and a.attnum > 0
    and not a.attisdropped;

  if accesses_type = 'text[]' then
    insert into public.nexlab_user_permission_overrides (
      user_id, permission_key, effect, reason, updated_at
    )
    select p.id, mapping.permission_key, 'allow', 'Migração dos acessos personalizados anteriores à v25.12.', now()
    from public.profiles p
    cross join lateral (
      values
        ('patr', 'module_patrimonio'),
        ('mkt', 'module_marketing'),
        ('usr_report', 'module_relatorios')
    ) mapping(legacy_key, permission_key)
    where mapping.legacy_key = any(coalesce(p.acessos, '{}'::text[]))
    on conflict (user_id, permission_key) do nothing;
  elsif accesses_type in ('jsonb','json') then
    execute $sql$
      insert into public.nexlab_user_permission_overrides (
        user_id, permission_key, effect, reason, updated_at
      )
      select p.id, mapping.permission_key, 'allow',
             'Migração dos acessos personalizados anteriores à v25.12.', now()
      from public.profiles p
      cross join lateral (
        values
          ('patr', 'module_patrimonio'),
          ('mkt', 'module_marketing'),
          ('usr_report', 'module_relatorios')
      ) mapping(legacy_key, permission_key)
      where exists (
        select 1
        from jsonb_array_elements_text(coalesce(p.acessos::jsonb, '[]'::jsonb)) value
        where value = mapping.legacy_key
      )
      on conflict (user_id, permission_key) do nothing
    $sql$;
  end if;
end;
$$;

select public.nexlab_recalculate_all_permissions();

-- -----------------------------------------------------------------------------
-- 9. Realtime e registro de versões
-- -----------------------------------------------------------------------------

do $$
begin
  begin
    alter publication supabase_realtime
      add table public.nexlab_role_permission_defaults;
  exception when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime
      add table public.nexlab_user_permission_overrides;
  exception when duplicate_object then null;
  end;
end
$$;

update public.nexlab_app_versions
set
  release_status = 'stable',
  notes = 'Versão testada e aprovada. Gestão de usuários e vínculos validada.'
where version = '25.11.0';

insert into public.nexlab_app_versions (
  version, title, release_status, notes
)
values (
  '25.11.1',
  'Gestão de Usuários e Rolagem Segura',
  'stable',
  'Correção visual testada e aprovada. Modais e cartões sobrepostos possuem rolagem segura no computador e no celular.'
)
on conflict (version) do update
set
  title = excluded.title,
  release_status = excluded.release_status,
  notes = excluded.notes,
  installed_at = now(),
  installed_by = auth.uid();

insert into public.nexlab_app_versions (
  version, title, release_status, notes
)
values (
  '25.12.0',
  'Matriz de Permissões e Acessos',
  'rc',
  'Padrões por perfil, exceções individuais, permissões efetivas, restauração de padrões, histórico e bloqueio de combinações inválidas.'
)
on conflict (version) do update
set
  title = excluded.title,
  release_status = excluded.release_status,
  notes = excluded.notes,
  installed_at = now(),
  installed_by = auth.uid();

commit;
