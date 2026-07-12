-- NEXLAB v26.8.0 — Equipes, etapa 2 (pontos 5, 6, 7 e 8)
-- Supabase Dashboard > SQL Editor > New query > cole tudo > Run.
-- Adiciona funções dos integrantes, responsável obrigatório, arquivamento
-- controlado e permissões específicas do módulo Equipes.

begin;

-- 1. Estrutura das equipes e integrantes
alter table public.teams
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists archived_by uuid,
  add column if not exists archive_reason text;

alter table public.team_members
  add column if not exists funcao text not null default 'membro',
  add column if not exists adicionado_por uuid,
  add column if not exists updated_at timestamptz not null default now();

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.teams'::regclass
      and conname = 'teams_archived_by_fkey'
  ) then
    alter table public.teams
      add constraint teams_archived_by_fkey
      foreign key (archived_by)
      references public.profiles(id)
      on delete set null;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.team_members'::regclass
      and conname = 'team_members_adicionado_por_fkey'
  ) then
    alter table public.team_members
      add constraint team_members_adicionado_por_fkey
      foreign key (adicionado_por)
      references public.profiles(id)
      on delete set null;
  end if;
end;
$$;

alter table public.team_members
  drop constraint if exists team_members_funcao_check;

alter table public.team_members
  add constraint team_members_funcao_check
  check (funcao in ('responsavel','vice_responsavel','organizador','membro'));

alter table public.teams
  drop constraint if exists teams_archive_reason_check;

alter table public.teams
  add constraint teams_archive_reason_check
  check (
    archive_reason is null
    or char_length(btrim(archive_reason)) between 5 and 300
  );

-- O responsável cadastrado na equipe também deve constar entre os integrantes.
insert into public.team_members (
  team_id,
  user_id,
  funcao,
  adicionado_por,
  updated_at
)
select
  t.id,
  t.lider_id,
  'responsavel',
  t.lider_id,
  now()
from public.teams t
where t.lider_id is not null
on conflict (team_id, user_id) do update
set funcao = 'responsavel',
    updated_at = now();

-- Garante uma única função Responsável por equipe.
create unique index if not exists team_members_one_responsible_idx
  on public.team_members(team_id)
  where funcao = 'responsavel';

-- A constraint NOT VALID protege todos os novos registros imediatamente.
-- Se não existirem equipes antigas sem responsável, ela também é validada.
alter table public.teams
  drop constraint if exists teams_active_requires_leader;

alter table public.teams
  add constraint teams_active_requires_leader
  check (archived_at is not null or lider_id is not null)
  not valid;

do $$
begin
  if not exists (
    select 1
    from public.teams
    where archived_at is null
      and lider_id is null
  ) then
    alter table public.teams
      validate constraint teams_active_requires_leader;
  end if;
end;
$$;

create or replace function public.nexlab_touch_team_updated_at_v2680()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists nexlab_teams_touch_updated_at_v2680 on public.teams;
create trigger nexlab_teams_touch_updated_at_v2680
before update on public.teams
for each row execute function public.nexlab_touch_team_updated_at_v2680();

drop trigger if exists nexlab_team_members_touch_updated_at_v2680 on public.team_members;
create trigger nexlab_team_members_touch_updated_at_v2680
before update on public.team_members
for each row execute function public.nexlab_touch_team_updated_at_v2680();

-- 2. Permissões específicas do módulo Equipes
insert into public.nexlab_permission_catalog (
  permission_key, label, description, category, module_id,
  core, admin_only, grantable, eligible_roles, sort_order, active,
  created_at, updated_at
)
values
  (
    'teams_view_all',
    'Visualizar todas as equipes',
    'Permite consultar equipes e integrantes além das equipes das quais o usuário participa.',
    'Gestão', 'equipes', false, false, true,
    array['admin','coordenador','bolsista','coworking_junior']::text[],
    111, true, now(), now()
  ),
  (
    'teams_manage_own',
    'Gerenciar equipes sob responsabilidade',
    'Permite criar equipes e administrar somente equipes em que o usuário é o responsável.',
    'Gestão', 'equipes', false, false, true,
    array['admin','coordenador','bolsista']::text[],
    112, true, now(), now()
  ),
  (
    'teams_manage_all',
    'Gerenciar todas as equipes',
    'Permissão administrativa protegida para editar, arquivar e restaurar qualquer equipe.',
    'Gestão', 'equipes', false, true, false,
    array['admin']::text[],
    113, true, now(), now()
  )
on conflict (permission_key) do update
set label = excluded.label,
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
  role_key, permission_key, allowed, updated_at
)
values
  ('admin', 'teams_view_all', true, now()),
  ('coordenador', 'teams_view_all', true, now()),
  ('bolsista', 'teams_view_all', true, now()),
  ('coworking_junior', 'teams_view_all', false, now()),
  ('admin', 'teams_manage_own', true, now()),
  ('coordenador', 'teams_manage_own', true, now()),
  ('bolsista', 'teams_manage_own', false, now())
on conflict (role_key, permission_key) do update
set allowed = excluded.allowed,
    updated_at = now();

create or replace function public.nexlab_has_effective_permission_v2680(
  p_permission text
)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.ativo is distinct from false
      and p_permission = any(coalesce(p.effective_permissions, '{}'::text[]))
  );
$$;

create or replace function public.nexlab_is_admin_v2680()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.ativo is distinct from false
      and lower(p.role::text) in ('admin','administrador')
  );
$$;

create or replace function public.nexlab_can_view_all_teams_v2680()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select public.nexlab_is_admin_v2680()
      or public.nexlab_has_effective_permission_v2680('teams_view_all');
$$;

create or replace function public.nexlab_can_create_team_v2680()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select public.nexlab_is_admin_v2680()
      or public.nexlab_has_effective_permission_v2680('teams_manage_own');
$$;

create or replace function public.nexlab_can_manage_team_v2680(
  p_team_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select public.nexlab_is_admin_v2680()
      or (
        public.nexlab_has_effective_permission_v2680('teams_manage_own')
        and exists (
          select 1
          from public.teams t
          where t.id = p_team_id
            and t.lider_id = auth.uid()
        )
      );
$$;

create or replace function public.nexlab_user_is_team_member_v2680(
  p_team_id uuid,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists (
    select 1
    from public.team_members tm
    where tm.team_id = p_team_id
      and tm.user_id = p_user_id
  );
$$;

revoke all on function public.nexlab_has_effective_permission_v2680(text) from public, anon;
revoke all on function public.nexlab_is_admin_v2680() from public, anon;
revoke all on function public.nexlab_can_view_all_teams_v2680() from public, anon;
revoke all on function public.nexlab_can_create_team_v2680() from public, anon;
revoke all on function public.nexlab_can_manage_team_v2680(uuid) from public, anon;
revoke all on function public.nexlab_user_is_team_member_v2680(uuid, uuid) from public, anon;

grant execute on function public.nexlab_has_effective_permission_v2680(text) to authenticated;
grant execute on function public.nexlab_is_admin_v2680() to authenticated;
grant execute on function public.nexlab_can_view_all_teams_v2680() to authenticated;
grant execute on function public.nexlab_can_create_team_v2680() to authenticated;
grant execute on function public.nexlab_can_manage_team_v2680(uuid) to authenticated;
grant execute on function public.nexlab_user_is_team_member_v2680(uuid, uuid) to authenticated;

-- 3. Políticas de leitura e gestão
alter table public.teams enable row level security;
alter table public.team_members enable row level security;

drop policy if exists "coord gerencia equipes" on public.teams;
drop policy if exists "todos veem equipes" on public.teams;
drop policy if exists teams_v256_insert on public.teams;
drop policy if exists teams_v256_update on public.teams;
drop policy if exists teams_v2680_select on public.teams;
drop policy if exists teams_v2680_insert on public.teams;
drop policy if exists teams_v2680_update on public.teams;
drop policy if exists teams_v2680_delete on public.teams;

create policy teams_v2680_select
on public.teams
for select
to authenticated
using (
  public.nexlab_has_approved_access()
  and public.nexlab_has_effective_permission_v2680('module_equipes')
  and (
    public.nexlab_can_view_all_teams_v2680()
    or lider_id = auth.uid()
    or public.nexlab_user_is_team_member_v2680(id, auth.uid())
  )
);

-- Compatibilidade com clientes anteriores: as RPCs abaixo são o caminho recomendado.
create policy teams_v2680_insert
on public.teams
for insert
to authenticated
with check (
  public.nexlab_can_create_team_v2680()
  and archived_at is null
  and (
    public.nexlab_is_admin_v2680()
    or lider_id = auth.uid()
  )
);

create policy teams_v2680_update
on public.teams
for update
to authenticated
using (public.nexlab_can_manage_team_v2680(id))
with check (
  public.nexlab_is_admin_v2680()
  or lider_id = auth.uid()
);

create policy teams_v2680_delete
on public.teams
for delete
to authenticated
using (public.nexlab_is_admin_v2680());

drop policy if exists "coord gerencia membros" on public.team_members;
drop policy if exists "todos veem membros" on public.team_members;
drop policy if exists team_members_v2680_select on public.team_members;
drop policy if exists team_members_v2680_insert on public.team_members;
drop policy if exists team_members_v2680_update on public.team_members;
drop policy if exists team_members_v2680_delete on public.team_members;

create policy team_members_v2680_select
on public.team_members
for select
to authenticated
using (
  public.nexlab_has_approved_access()
  and public.nexlab_has_effective_permission_v2680('module_equipes')
  and (
    public.nexlab_can_view_all_teams_v2680()
    or user_id = auth.uid()
    or public.nexlab_user_is_team_member_v2680(team_id, auth.uid())
  )
);

create policy team_members_v2680_insert
on public.team_members
for insert
to authenticated
with check (public.nexlab_can_manage_team_v2680(team_id));

create policy team_members_v2680_update
on public.team_members
for update
to authenticated
using (public.nexlab_can_manage_team_v2680(team_id))
with check (public.nexlab_can_manage_team_v2680(team_id));

create policy team_members_v2680_delete
on public.team_members
for delete
to authenticated
using (public.nexlab_can_manage_team_v2680(team_id));

-- 4. RPC para criar e editar equipes
create or replace function public.nexlab_save_team_v2680(
  p_team_id uuid,
  p_nome text,
  p_descricao text,
  p_area text,
  p_lider_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  normalized_name text := left(btrim(coalesce(p_nome, '')), 160);
  normalized_description text := nullif(left(btrim(coalesce(p_descricao, '')), 1000), '');
  normalized_area text := nullif(left(btrim(coalesce(p_area, '')), 120), '');
  current_team public.teams%rowtype;
  saved_team public.teams%rowtype;
  old_leader uuid;
  transferred boolean := false;
begin
  if auth.uid() is null or not public.nexlab_has_approved_access() then
    raise exception 'Usuário não autenticado ou sem acesso aprovado.' using errcode = '42501';
  end if;

  if not public.nexlab_has_effective_permission_v2680('module_equipes') then
    raise exception 'O módulo Equipes não está autorizado para este perfil.' using errcode = '42501';
  end if;

  if normalized_name = '' then
    raise exception 'O nome da equipe é obrigatório.' using errcode = '22023';
  end if;

  if p_lider_id is null then
    raise exception 'Defina um responsável pela equipe.' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id = p_lider_id
      and p.ativo is distinct from false
      and coalesce(p.cadastro_completo, false)
  ) then
    raise exception 'O responsável selecionado não possui um perfil ativo e completo.' using errcode = '22023';
  end if;

  if p_team_id is null then
    if not public.nexlab_can_create_team_v2680() then
      raise exception 'Você não possui permissão para criar equipes.' using errcode = '42501';
    end if;

    if not public.nexlab_is_admin_v2680()
       and p_lider_id <> auth.uid()
    then
      raise exception 'Ao criar uma equipe, você deve ser o responsável inicial.' using errcode = '42501';
    end if;

    insert into public.teams (
      nome, descricao, area, lider_id, created_at, updated_at
    ) values (
      normalized_name, normalized_description, normalized_area,
      p_lider_id, now(), now()
    )
    returning * into saved_team;

    insert into public.team_members (
      team_id, user_id, funcao, adicionado_por, created_at, updated_at
    ) values (
      saved_team.id, p_lider_id, 'responsavel', auth.uid(), now(), now()
    )
    on conflict (team_id, user_id) do update
    set funcao = 'responsavel',
        updated_at = now();

    perform public.record_security_audit(
      'team_created',
      p_lider_id::text,
      jsonb_build_object(
        'team_id', saved_team.id,
        'team_name', saved_team.nome,
        'leader_id', p_lider_id,
        'module', 'equipes'
      )
    );
  else
    select * into current_team
    from public.teams
    where id = p_team_id
    for update;

    if current_team.id is null then
      raise exception 'Equipe não encontrada.' using errcode = 'P0002';
    end if;

    if current_team.archived_at is not null then
      raise exception 'Restaure a equipe antes de editá-la.' using errcode = '42501';
    end if;

    if not public.nexlab_can_manage_team_v2680(p_team_id) then
      raise exception 'Você não pode editar esta equipe.' using errcode = '42501';
    end if;

    old_leader := current_team.lider_id;
    transferred := old_leader is distinct from p_lider_id;

    update public.teams
    set nome = normalized_name,
        descricao = normalized_description,
        area = normalized_area,
        lider_id = p_lider_id,
        updated_at = now()
    where id = p_team_id
    returning * into saved_team;

    if transferred then
      update public.team_members
      set funcao = 'membro',
          updated_at = now()
      where team_id = p_team_id
        and funcao = 'responsavel'
        and user_id <> p_lider_id;
    end if;

    insert into public.team_members (
      team_id, user_id, funcao, adicionado_por, created_at, updated_at
    ) values (
      p_team_id, p_lider_id, 'responsavel', auth.uid(), now(), now()
    )
    on conflict (team_id, user_id) do update
    set funcao = 'responsavel',
        updated_at = now();

    perform public.record_security_audit(
      'team_updated',
      p_lider_id::text,
      jsonb_build_object(
        'team_id', saved_team.id,
        'team_name', saved_team.nome,
        'previous_leader_id', old_leader,
        'leader_id', p_lider_id,
        'responsibility_transferred', transferred,
        'module', 'equipes'
      )
    );

    if transferred then
      perform public.record_security_audit(
        'team_responsibility_transferred',
        p_lider_id::text,
        jsonb_build_object(
          'team_id', saved_team.id,
          'previous_leader_id', old_leader,
          'next_leader_id', p_lider_id,
          'module', 'equipes'
        )
      );
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'team', to_jsonb(saved_team),
    'responsibility_transferred', transferred
  );
end;
$$;

-- 5. RPC para adicionar, remover e alterar funções dos integrantes
create or replace function public.nexlab_manage_team_member_v2680(
  p_team_id uuid,
  p_user_id uuid,
  p_funcao text,
  p_action text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  current_team public.teams%rowtype;
  normalized_action text := lower(btrim(coalesce(p_action, 'upsert')));
  normalized_role text := lower(btrim(coalesce(p_funcao, 'membro')));
  previous_role text;
  created_member boolean := false;
  transferred boolean := false;
  affected integer := 0;
begin
  if auth.uid() is null or not public.nexlab_has_approved_access() then
    raise exception 'Usuário não autenticado ou sem acesso aprovado.' using errcode = '42501';
  end if;

  select * into current_team
  from public.teams
  where id = p_team_id
  for update;

  if current_team.id is null then
    raise exception 'Equipe não encontrada.' using errcode = 'P0002';
  end if;

  if current_team.archived_at is not null then
    raise exception 'Equipes arquivadas estão em modo somente leitura.' using errcode = '42501';
  end if;

  if not public.nexlab_can_manage_team_v2680(p_team_id) then
    raise exception 'Você não pode gerenciar os integrantes desta equipe.' using errcode = '42501';
  end if;

  if normalized_action not in ('upsert','remove') then
    raise exception 'Ação de integrante inválida.' using errcode = '22023';
  end if;

  select tm.funcao into previous_role
  from public.team_members tm
  where tm.team_id = p_team_id
    and tm.user_id = p_user_id;

  if normalized_action = 'remove' then
    if current_team.lider_id = p_user_id then
      raise exception 'Transfira a responsabilidade antes de remover o responsável atual.' using errcode = '23514';
    end if;

    delete from public.team_members
    where team_id = p_team_id
      and user_id = p_user_id;

    get diagnostics affected = row_count;

    if affected = 0 then
      raise exception 'O integrante não foi encontrado nesta equipe.' using errcode = 'P0002';
    end if;

    perform public.record_security_audit(
      'team_member_removed',
      p_user_id::text,
      jsonb_build_object(
        'team_id', p_team_id,
        'previous_role', previous_role,
        'module', 'equipes'
      )
    );

    return jsonb_build_object(
      'ok', true,
      'removed', true,
      'user_id', p_user_id,
      'team_id', p_team_id
    );
  end if;

  if normalized_role not in ('responsavel','vice_responsavel','organizador','membro') then
    raise exception 'Função de integrante inválida.' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id = p_user_id
      and p.ativo is distinct from false
      and coalesce(p.cadastro_completo, false)
  ) then
    raise exception 'O usuário selecionado não possui um perfil ativo e completo.' using errcode = '22023';
  end if;

  created_member := previous_role is null;

  if normalized_role = 'responsavel' then
    transferred := current_team.lider_id is distinct from p_user_id;

    if transferred then
      update public.team_members
      set funcao = 'membro',
          updated_at = now()
      where team_id = p_team_id
        and funcao = 'responsavel'
        and user_id <> p_user_id;

      update public.teams
      set lider_id = p_user_id,
          updated_at = now()
      where id = p_team_id;
    end if;
  elsif current_team.lider_id = p_user_id then
    raise exception 'O responsável atual não pode receber outra função antes da transferência de responsabilidade.' using errcode = '23514';
  end if;

  insert into public.team_members (
    team_id, user_id, funcao, adicionado_por, created_at, updated_at
  ) values (
    p_team_id, p_user_id, normalized_role, auth.uid(), now(), now()
  )
  on conflict (team_id, user_id) do update
  set funcao = excluded.funcao,
      updated_at = now();

  perform public.record_security_audit(
    case
      when transferred then 'team_responsibility_transferred'
      when created_member then 'team_member_added'
      else 'team_member_role_updated'
    end,
    p_user_id::text,
    jsonb_build_object(
      'team_id', p_team_id,
      'previous_role', previous_role,
      'next_role', normalized_role,
      'previous_leader_id', current_team.lider_id,
      'responsibility_transferred', transferred,
      'module', 'equipes'
    )
  );

  return jsonb_build_object(
    'ok', true,
    'created', created_member,
    'role', normalized_role,
    'responsibility_transferred', transferred,
    'user_id', p_user_id,
    'team_id', p_team_id
  );
end;
$$;

-- 6. RPC para arquivar e restaurar equipes
create or replace function public.nexlab_archive_team_v2680(
  p_team_id uuid,
  p_archive boolean,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  current_team public.teams%rowtype;
  saved_team public.teams%rowtype;
  normalized_reason text := nullif(left(btrim(coalesce(p_reason, '')), 300), '');
begin
  if auth.uid() is null or not public.nexlab_has_approved_access() then
    raise exception 'Usuário não autenticado ou sem acesso aprovado.' using errcode = '42501';
  end if;

  select * into current_team
  from public.teams
  where id = p_team_id
  for update;

  if current_team.id is null then
    raise exception 'Equipe não encontrada.' using errcode = 'P0002';
  end if;

  if not public.nexlab_can_manage_team_v2680(p_team_id) then
    raise exception 'Você não pode arquivar ou restaurar esta equipe.' using errcode = '42501';
  end if;

  if coalesce(p_archive, false) then
    if normalized_reason is null or char_length(normalized_reason) < 5 then
      raise exception 'Informe um motivo de arquivamento com pelo menos 5 caracteres.' using errcode = '22023';
    end if;

    update public.teams
    set archived_at = now(),
        archived_by = auth.uid(),
        archive_reason = normalized_reason,
        updated_at = now()
    where id = p_team_id
    returning * into saved_team;

    perform public.record_security_audit(
      'team_archived',
      current_team.lider_id::text,
      jsonb_build_object(
        'team_id', p_team_id,
        'reason', normalized_reason,
        'module', 'equipes'
      )
    );
  else
    if current_team.lider_id is null
       or not exists (
         select 1 from public.profiles p
         where p.id = current_team.lider_id
           and p.ativo is distinct from false
       )
    then
      raise exception 'Defina um responsável ativo antes de restaurar a equipe.' using errcode = '23514';
    end if;

    update public.teams
    set archived_at = null,
        archived_by = null,
        updated_at = now()
    where id = p_team_id
    returning * into saved_team;

    perform public.record_security_audit(
      'team_restored',
      current_team.lider_id::text,
      jsonb_build_object(
        'team_id', p_team_id,
        'previous_archive_reason', current_team.archive_reason,
        'module', 'equipes'
      )
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'team', to_jsonb(saved_team),
    'archived', coalesce(p_archive, false)
  );
end;
$$;

revoke all on function public.nexlab_save_team_v2680(uuid, text, text, text, uuid) from public, anon;
revoke all on function public.nexlab_manage_team_member_v2680(uuid, uuid, text, text) from public, anon;
revoke all on function public.nexlab_archive_team_v2680(uuid, boolean, text) from public, anon;

grant execute on function public.nexlab_save_team_v2680(uuid, text, text, text, uuid) to authenticated;
grant execute on function public.nexlab_manage_team_member_v2680(uuid, uuid, text, text) to authenticated;
grant execute on function public.nexlab_archive_team_v2680(uuid, boolean, text) to authenticated;

-- 7. Ações de auditoria utilizadas pelo NEXLAB
alter table public.security_audit_logs
  drop constraint if exists security_audit_logs_action_check;

alter table public.security_audit_logs
  add constraint security_audit_logs_action_check
  check (
    action = any (array[
      'user_access_updated','user_deactivated','user_reactivated','user_deleted',
      'detailed_user_report_pdf','detailed_user_report_excel',
      'event_created','event_updated','event_deleted',
      'project_created','project_updated','project_status_updated','project_deleted',
      'team_created','team_updated','team_archived','team_restored','team_deleted',
      'team_member_added','team_member_removed','team_member_role_updated','team_responsibility_transferred',
      'meeting_created','meeting_updated','meeting_cancelled','meeting_deleted','meeting_participants_replaced',
      'reservation_cancelled','reservation_deleted','reservation_participants_replaced',
      'marketing_created','marketing_updated','marketing_status_updated','marketing_deleted',
      'feedback_status_updated','asset_created','asset_updated','asset_condition_updated','asset_deleted',
      'post_created','post_updated','post_deleted',
      'privacy_documents_accepted','optional_consent_granted','optional_consent_revoked',
      'privacy_request_created','privacy_request_status_updated',
      'profile_avatar_updated','profile_avatar_removed','own_profile_updated','own_sensitive_profile_updated',
      'profile_admin_managed','profile_registration_submitted','profile_request_cancelled',
      'profile_request_resubmitted','profile_request_approved','profile_request_rejected',
      'report_export_recorded','role_permissions_updated','user_permissions_updated',
      'security_retention_applied','sensitive_user_report_accessed','activity_logs_bulk_deleted'
    ]::text[])
  );

-- Atualiza a coluna effective_permissions dos perfis existentes.
do $$
begin
  perform public.nexlab_recalculate_all_permissions();
exception
  when undefined_function then
    null;
end;
$$;

comment on column public.team_members.funcao is
  'Função interna do integrante: responsavel, vice_responsavel, organizador ou membro.';
comment on column public.teams.archive_reason is
  'Motivo informado no arquivamento da equipe; preservado após a restauração.';
comment on function public.nexlab_save_team_v2680(uuid, text, text, text, uuid) is
  'Cria ou edita equipes com responsável obrigatório e sincronização da função Responsável.';
comment on function public.nexlab_manage_team_member_v2680(uuid, uuid, text, text) is
  'Adiciona, remove ou altera a função de integrantes, incluindo transferência de responsabilidade.';
comment on function public.nexlab_archive_team_v2680(uuid, boolean, text) is
  'Arquiva equipes com motivo obrigatório ou restaura equipes com responsável ativo.';

commit;
