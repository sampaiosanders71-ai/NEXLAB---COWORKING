-- NexLab v25.11.0 — Gestão de Usuários e Vínculos
-- Execute integralmente no Supabase SQL Editor após a v25.10.0.
-- Não exige alteração em Edge Functions, Secrets ou Cron.

begin;

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1. Metadados de situação da conta e histórico administrativo
-- -----------------------------------------------------------------------------

do $$
declare
  profile_id_type text;
  role_type text;
begin
  if to_regclass('public.profiles') is null then
    raise exception 'A tabela public.profiles não existe.';
  end if;

  select format_type(a.atttypid, a.atttypmod)
    into profile_id_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'id'
    and a.attnum > 0
    and not a.attisdropped;

  select format_type(a.atttypid, a.atttypmod)
    into role_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'role'
    and a.attnum > 0
    and not a.attisdropped;

  if profile_id_type is null or role_type is null then
    raise exception 'Não foi possível identificar os tipos de profiles.id e profiles.role.';
  end if;

  alter table public.profiles
    add column if not exists account_status_reason text null,
    add column if not exists account_status_changed_at timestamptz null;

  if not exists (
    select 1
    from pg_attribute
    where attrelid = 'public.profiles'::regclass
      and attname = 'account_status_changed_by'
      and attnum > 0
      and not attisdropped
  ) then
    execute format(
      'alter table public.profiles add column account_status_changed_by %s null references public.profiles(id) on delete set null',
      profile_id_type
    );
  end if;

  if to_regclass('public.profile_management_history') is null then
    execute format(
      'create table public.profile_management_history (
         id uuid primary key default gen_random_uuid(),
         user_id %s not null references public.profiles(id) on delete cascade,
         actor_id %s null references public.profiles(id) on delete set null,
         event_type text not null,
         previous_role %s null,
         next_role %s null,
         previous_active boolean null,
         next_active boolean null,
         reason text null,
         metadata jsonb not null default ''{}''::jsonb,
         created_at timestamptz not null default now(),
         constraint profile_management_history_event_check check (
           event_type in (
             ''role_changed'',
             ''account_activated'',
             ''account_deactivated'',
             ''request_approved'',
             ''request_rejected'',
             ''request_cancelled'',
             ''request_auto_approved'',
             ''profile_completed'',
             ''profile_corrected'',
             ''access_updated''
           )
         )
       )',
      profile_id_type,
      profile_id_type,
      role_type,
      role_type
    );
  end if;
end
$$;

alter table public.profiles
  drop constraint if exists profiles_role_request_status_check;

alter table public.profiles
  add constraint profiles_role_request_status_check
  check (role_request_status in ('pending', 'approved', 'rejected', 'auto_approved', 'cancelled'));

create index if not exists profile_management_history_user_created_idx
  on public.profile_management_history (user_id, created_at desc);

create index if not exists profile_management_history_actor_created_idx
  on public.profile_management_history (actor_id, created_at desc);

create index if not exists profiles_account_status_idx
  on public.profiles (ativo, cadastro_completo, role_request_status, created_at desc);

-- -----------------------------------------------------------------------------
-- 2. RLS do histórico administrativo
-- -----------------------------------------------------------------------------

alter table public.profile_management_history enable row level security;

revoke all on public.profile_management_history from anon;
revoke insert, update, delete on public.profile_management_history from authenticated;
grant select on public.profile_management_history to authenticated;

drop policy if exists profile_management_history_select_own_or_admin
on public.profile_management_history;

create policy profile_management_history_select_own_or_admin
on public.profile_management_history
for select
to authenticated
using (
  user_id::text = auth.uid()::text
  or public.nexlab_is_admin()
);

-- -----------------------------------------------------------------------------
-- 3. Proteção: nunca deixar o NexLab sem Administrador ativo
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_prevent_last_active_admin()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  remaining_admins integer;
begin
  if lower(coalesce(old.role::text, '')) in ('admin', 'administrador')
     and coalesce(old.ativo, true)
     and (
       lower(coalesce(new.role::text, '')) not in ('admin', 'administrador')
       or not coalesce(new.ativo, true)
     )
  then
    select count(*)
      into remaining_admins
    from public.profiles p
    where p.id::text <> old.id::text
      and lower(coalesce(p.role::text, '')) in ('admin', 'administrador')
      and coalesce(p.ativo, true);

    if remaining_admins = 0 then
      raise exception 'O NexLab precisa manter pelo menos um Administrador ativo.'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_prevent_last_active_admin_trigger
on public.profiles;

create trigger nexlab_prevent_last_active_admin_trigger
before update of role, ativo on public.profiles
for each row
execute function public.nexlab_prevent_last_active_admin();

-- -----------------------------------------------------------------------------
-- 4. Captura automática do histórico
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_capture_profile_management_history()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  actor_value profiles.id%type;
  event_reason text;
begin
  begin
    actor_value := auth.uid();
  exception
    when others then actor_value := null;
  end;

  event_reason := coalesce(
    nullif(new.account_status_reason, ''),
    nullif(new.role_request_reason, '')
  );

  if new.role is distinct from old.role then
    insert into public.profile_management_history (
      user_id, actor_id, event_type,
      previous_role, next_role,
      previous_active, next_active,
      reason, metadata
    ) values (
      new.id, actor_value, 'role_changed',
      old.role, new.role,
      old.ativo, new.ativo,
      event_reason,
      jsonb_build_object(
        'source', coalesce(current_setting('nexlab.profile_flow', true), 'direct'),
        'requested_role', new.vinculo_solicitado::text
      )
    );
  end if;

  if new.ativo is distinct from old.ativo then
    insert into public.profile_management_history (
      user_id, actor_id, event_type,
      previous_role, next_role,
      previous_active, next_active,
      reason, metadata
    ) values (
      new.id,
      actor_value,
      case when coalesce(new.ativo, true)
        then 'account_activated'
        else 'account_deactivated'
      end,
      old.role,
      new.role,
      old.ativo,
      new.ativo,
      event_reason,
      jsonb_build_object('source', coalesce(current_setting('nexlab.profile_flow', true), 'direct'))
    );
  end if;

  if new.role_request_status is distinct from old.role_request_status then
    insert into public.profile_management_history (
      user_id, actor_id, event_type,
      previous_role, next_role,
      previous_active, next_active,
      reason, metadata
    ) values (
      new.id,
      actor_value,
      case
        when new.role_request_status = 'approved'
             and current_setting('nexlab.pending_resolution', true) = 'cancelled'
          then 'request_cancelled'
        when new.role_request_status = 'approved' then 'request_approved'
        when new.role_request_status = 'rejected' then 'request_rejected'
        when new.role_request_status = 'cancelled' then 'request_cancelled'
        when new.role_request_status = 'auto_approved' then 'request_auto_approved'
        else 'profile_corrected'
      end,
      old.role,
      new.role,
      old.ativo,
      new.ativo,
      coalesce(new.role_request_reason, event_reason),
      jsonb_build_object(
        'previous_status', old.role_request_status,
        'next_status', new.role_request_status,
        'requested_role', new.vinculo_solicitado::text,
        'pending_resolution', nullif(current_setting('nexlab.pending_resolution', true), '')
      )
    );
  end if;

  if coalesce(old.cadastro_completo, false) = false
     and coalesce(new.cadastro_completo, false) = true
  then
    insert into public.profile_management_history (
      user_id, actor_id, event_type,
      previous_role, next_role,
      previous_active, next_active,
      reason, metadata
    ) values (
      new.id, actor_value, 'profile_completed',
      old.role, new.role,
      old.ativo, new.ativo,
      event_reason,
      jsonb_build_object('completed_by_admin', actor_value is distinct from new.id)
    );
  elsif new.nome is distinct from old.nome
     or new.curso is distinct from old.curso
     or new.matricula is distinct from old.matricula
  then
    insert into public.profile_management_history (
      user_id, actor_id, event_type,
      previous_role, next_role,
      previous_active, next_active,
      reason, metadata
    ) values (
      new.id, actor_value, 'profile_corrected',
      old.role, new.role,
      old.ativo, new.ativo,
      event_reason,
      jsonb_build_object(
        'name_changed', new.nome is distinct from old.nome,
        'course_changed', new.curso is distinct from old.curso,
        'registration_changed', new.matricula is distinct from old.matricula
      )
    );
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_capture_profile_management_history_trigger
on public.profiles;

create trigger nexlab_capture_profile_management_history_trigger
after update of role, ativo, role_request_status, cadastro_completo, nome, curso, matricula
on public.profiles
for each row
execute function public.nexlab_capture_profile_management_history();

-- -----------------------------------------------------------------------------
-- 5. Revisão de perfil com motivo obrigatório na recusa
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_review_profile_request(
  p_target_user_id text,
  p_approved boolean,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  role_type text;
  requested_role_type text;
  target_name text;
  current_role_text text;
  requested_role_text text;
  current_status text;
  request_id uuid;
  final_status text;
  final_reason text;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode = '42501';
  end if;

  if nullif(btrim(coalesce(p_target_user_id, '')), '') is null then
    raise exception 'Usuário alvo não informado.' using errcode = '22023';
  end if;

  if p_target_user_id = auth.uid()::text then
    raise exception 'Um Administrador não pode aprovar a própria solicitação.' using errcode = '42501';
  end if;

  if not p_approved and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Informe o motivo da recusa.' using errcode = '22023';
  end if;

  select
    p.nome,
    p.role::text,
    p.vinculo_solicitado::text,
    p.role_request_status
  into
    target_name,
    current_role_text,
    requested_role_text,
    current_status
  from public.profiles p
  where p.id::text = p_target_user_id
  for update;

  if target_name is null then
    raise exception 'Usuário não encontrado.' using errcode = 'P0002';
  end if;

  if current_status <> 'pending' then
    raise exception 'Esta solicitação não está mais pendente.' using errcode = 'P0001';
  end if;

  if requested_role_text not in ('bolsista', 'coordenador', 'admin') then
    raise exception 'A solicitação pendente possui um perfil inválido.' using errcode = '22023';
  end if;

  select r.id
    into request_id
  from public.profile_role_requests r
  where r.user_id::text = p_target_user_id
    and r.status = 'pending'
  order by r.created_at desc
  limit 1
  for update;

  if request_id is null then
    raise exception 'Registro da solicitação pendente não encontrado.' using errcode = 'P0002';
  end if;

  final_status := case when p_approved then 'approved' else 'rejected' end;
  final_reason := case when p_approved then null else btrim(p_reason) end;

  select format_type(a.atttypid, a.atttypmod)
    into role_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'role'
    and a.attnum > 0
    and not a.attisdropped;

  select format_type(a.atttypid, a.atttypmod)
    into requested_role_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'vinculo_solicitado'
    and a.attnum > 0
    and not a.attisdropped;

  perform set_config('nexlab.profile_flow', 'trusted', true);

  if p_approved then
    execute format(
      'update public.profiles
         set role = $1::%s,
             vinculo_solicitado = $1::%s,
             role_request_status = ''approved'',
             role_request_reason = null,
             role_request_reviewed_at = now(),
             role_request_reviewed_by = auth.uid()
       where id::text = $2',
      role_type,
      requested_role_type
    ) using requested_role_text, p_target_user_id;
  else
    update public.profiles
    set
      role_request_status = 'rejected',
      role_request_reason = final_reason,
      role_request_reviewed_at = now(),
      role_request_reviewed_by = auth.uid()
    where id::text = p_target_user_id;
  end if;

  update public.profile_role_requests
  set
    status = final_status,
    reason = final_reason,
    reviewed_by = auth.uid(),
    reviewed_at = now(),
    updated_at = now()
  where id = request_id;

  perform public.nexlab_profile_flow_notification(
    p_target_user_id,
    case when p_approved then 'Perfil aprovado' else 'Solicitação de perfil recusada' end,
    case
      when p_approved then format(
        'Seu perfil %s foi aprovado por um Administrador. O novo acesso já está disponível.',
        public.nexlab_profile_role_label(requested_role_text)
      )
      else format(
        'Sua solicitação para o perfil %s foi recusada. Motivo: %s',
        public.nexlab_profile_role_label(requested_role_text),
        final_reason
      )
    end,
    'perfil',
    format('profile-review:%s:%s', request_id, p_target_user_id),
    case when p_approved then 'alta' else 'normal' end,
    jsonb_build_object(
      'request_id', request_id,
      'decision', final_status,
      'requested_role', requested_role_text,
      'previous_role', current_role_text,
      'reviewed_by', auth.uid(),
      'reason', final_reason
    )
  );

  begin
    perform public.record_security_audit(
      'profile_request_reviewed',
      p_target_user_id,
      jsonb_build_object(
        'request_id', request_id,
        'decision', final_status,
        'requested_role', requested_role_text,
        'previous_role', current_role_text,
        'reason', final_reason
      )
    );
  exception
    when undefined_function then null;
    when others then null;
  end;

  return jsonb_build_object(
    'ok', true,
    'request_id', request_id,
    'decision', final_status,
    'user_id', p_target_user_id,
    'requested_role', requested_role_text
  );
end;
$$;

revoke all on function public.nexlab_review_profile_request(text, boolean, text) from public;
grant execute on function public.nexlab_review_profile_request(text, boolean, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 6. RPC administrativa única para perfil, situação, acessos e correções
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_admin_manage_profile(
  p_target_user_id text,
  p_next_role text default null,
  p_active boolean default null,
  p_accesses jsonb default null,
  p_reason text default null,
  p_nome text default null,
  p_curso text default null,
  p_matricula text default null,
  p_mark_complete boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  role_type text;
  requested_role_type text;
  accesses_type text;
  current_role_text text;
  current_requested_role_text text;
  current_request_status text;
  next_role_text text;
  current_active boolean;
  next_active boolean;
  current_accesses jsonb;
  next_nome text;
  next_curso text;
  next_matricula text;
  current_complete boolean;
  reason_required boolean := false;
  role_changed boolean := false;
  active_changed boolean := false;
  pending_request_id uuid;
  pending_requested_role_text text;
  pending_resolution text;
  result_profile jsonb;
  role_rank_current integer;
  role_rank_next integer;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode = '42501';
  end if;

  if nullif(btrim(coalesce(p_target_user_id, '')), '') is null then
    raise exception 'Usuário alvo não informado.' using errcode = '22023';
  end if;

  if p_target_user_id = auth.uid()::text then
    raise exception 'Use outro Administrador para alterar seu próprio cargo ou situação.'
      using errcode = '42501';
  end if;

  select
    p.role::text,
    p.vinculo_solicitado::text,
    p.role_request_status,
    coalesce(p.ativo, true),
    to_jsonb(p.acessos),
    p.nome,
    p.curso,
    p.matricula,
    coalesce(p.cadastro_completo, false)
  into
    current_role_text,
    current_requested_role_text,
    current_request_status,
    current_active,
    current_accesses,
    next_nome,
    next_curso,
    next_matricula,
    current_complete
  from public.profiles p
  where p.id::text = p_target_user_id
  for update;

  if current_role_text is null then
    raise exception 'Usuário não encontrado.' using errcode = 'P0002';
  end if;

  next_role_text := lower(btrim(coalesce(p_next_role, current_role_text)));
  next_active := coalesce(p_active, current_active);
  next_nome := coalesce(nullif(btrim(p_nome), ''), next_nome);
  next_curso := coalesce(nullif(btrim(p_curso), ''), next_curso);
  next_matricula := coalesce(nullif(btrim(p_matricula), ''), next_matricula);

  if next_role_text not in ('coworking_junior', 'bolsista', 'coordenador', 'admin') then
    raise exception 'Perfil informado é inválido.' using errcode = '22023';
  end if;

  role_changed := lower(current_role_text) is distinct from next_role_text;
  active_changed := current_active is distinct from next_active;

  role_rank_current := case lower(current_role_text)
    when 'admin' then 4
    when 'administrador' then 4
    when 'coordenador' then 3
    when 'bolsista' then 2
    else 1
  end;

  role_rank_next := case next_role_text
    when 'admin' then 4
    when 'coordenador' then 3
    when 'bolsista' then 2
    else 1
  end;

  reason_required :=
    (current_active and not next_active)
    or role_rank_next < role_rank_current;

  if reason_required and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Informe o motivo para desativar a conta ou reduzir o perfil.'
      using errcode = '22023';
  end if;

  if p_mark_complete then
    if nullif(btrim(coalesce(next_nome, '')), '') is null
       or nullif(btrim(coalesce(next_curso, '')), '') is null
       or nullif(btrim(coalesce(next_matricula, '')), '') is null
    then
      raise exception 'Nome, curso e matrícula são obrigatórios para concluir o cadastro.'
        using errcode = '22023';
    end if;
  end if;

  select format_type(a.atttypid, a.atttypmod)
    into role_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'role'
    and a.attnum > 0
    and not a.attisdropped;

  select format_type(a.atttypid, a.atttypmod)
    into requested_role_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'vinculo_solicitado'
    and a.attnum > 0
    and not a.attisdropped;

  select format_type(a.atttypid, a.atttypmod)
    into accesses_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'acessos'
    and a.attnum > 0
    and not a.attisdropped;

  if role_type is null or requested_role_type is null then
    raise exception 'Não foi possível identificar os tipos dos campos de perfil.';
  end if;

  if current_request_status = 'pending' then
    select
      r.id,
      r.requested_role::text
    into
      pending_request_id,
      pending_requested_role_text
    from public.profile_role_requests r
    where r.user_id::text = p_target_user_id
      and r.status = 'pending'
    order by r.created_at desc
    limit 1
    for update;
  end if;

  if pending_request_id is not null and role_changed then
    pending_resolution := case
      when lower(coalesce(pending_requested_role_text, '')) = next_role_text then 'approved'
      else 'cancelled'
    end;
  end if;

  perform set_config('nexlab.profile_flow', 'trusted', true);
  perform set_config('nexlab.pending_resolution', coalesce(pending_resolution, ''), true);

  execute format(
    'update public.profiles
       set role = $1::%s,
           vinculo_solicitado = case
             when role::text is distinct from $1 then $1::%s
             else vinculo_solicitado
           end,
           ativo = $2,
           nome = $3,
           curso = $4,
           matricula = $5,
           cadastro_completo = case when $6 then true else cadastro_completo end,
           role_request_status = case
             when role::text is distinct from $1 then ''approved''
             else role_request_status
           end,
           role_request_reason = case
             when role::text is distinct from $1 then null
             else role_request_reason
           end,
           role_request_reviewed_at = case
             when role::text is distinct from $1 then now()
             else role_request_reviewed_at
           end,
           role_request_reviewed_by = case
             when role::text is distinct from $1 then auth.uid()
             else role_request_reviewed_by
           end,
           account_status_reason = case
             when ativo is distinct from $2 or role::text is distinct from $1
               then nullif(btrim($7), '''')
             else account_status_reason
           end,
           account_status_changed_at = case
             when ativo is distinct from $2 or role::text is distinct from $1 then now()
             else account_status_changed_at
           end,
           account_status_changed_by = case
             when ativo is distinct from $2 or role::text is distinct from $1 then auth.uid()
             else account_status_changed_by
           end
     where id::text = $8',
    role_type,
    requested_role_type
  )
  using
    next_role_text,
    next_active,
    next_nome,
    next_curso,
    next_matricula,
    p_mark_complete,
    coalesce(p_reason, ''),
    p_target_user_id;

  if p_accesses is not null and accesses_type is not null then
    if accesses_type = 'jsonb' then
      execute 'update public.profiles set acessos = $1 where id::text = $2'
        using p_accesses, p_target_user_id;
    elsif accesses_type = 'json' then
      execute 'update public.profiles set acessos = $1::json where id::text = $2'
        using p_accesses, p_target_user_id;
    elsif accesses_type = 'text[]' then
      execute 'update public.profiles set acessos = array(select jsonb_array_elements_text($1)) where id::text = $2'
        using p_accesses, p_target_user_id;
    end if;

    if p_accesses is distinct from current_accesses then
      insert into public.profile_management_history (
        user_id, actor_id, event_type,
        previous_role, next_role,
        previous_active, next_active,
        reason, metadata
      )
      select
        p.id,
        auth.uid(),
        'access_updated',
        p.role,
        p.role,
        p.ativo,
        p.ativo,
        nullif(btrim(coalesce(p_reason, '')), ''),
        jsonb_build_object('previous_access', current_accesses, 'next_access', p_accesses)
      from public.profiles p
      where p.id::text = p_target_user_id;
    end if;
  end if;

  if pending_request_id is not null and role_changed then
    update public.profile_role_requests
    set
      status = pending_resolution,
      reason = case
        when pending_resolution = 'approved' then null
        else coalesce(
          nullif(btrim(p_reason), ''),
          'Solicitação encerrada por alteração administrativa de perfil.'
        )
      end,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
    where id = pending_request_id;
  end if;

  if role_changed
     or active_changed
     or (p_mark_complete and not current_complete)
  then
    perform public.nexlab_profile_flow_notification(
      p_target_user_id,
      'Cadastro atualizado pelo Administrador',
      format(
        'Seu cadastro foi atualizado. Perfil atual: %s. Situação: %s.%s',
        public.nexlab_profile_role_label(next_role_text),
        case when next_active then 'ativo' else 'inativo' end,
        case
          when nullif(btrim(coalesce(p_reason, '')), '') is not null
            then format(' Motivo: %s', btrim(p_reason))
          else ''
        end
      ),
      'perfil',
      format('profile-admin-management:%s:%s', p_target_user_id, extract(epoch from clock_timestamp())::bigint),
      'alta',
      jsonb_build_object(
        'previous_role', current_role_text,
        'next_role', next_role_text,
        'previous_active', current_active,
        'next_active', next_active,
        'previous_requested_role', current_requested_role_text,
        'previous_request_status', current_request_status,
        'pending_resolution', pending_resolution,
        'reason', nullif(btrim(coalesce(p_reason, '')), '')
      )
    );
  end if;

  begin
    perform public.record_security_audit(
      'profile_admin_managed',
      p_target_user_id,
      jsonb_build_object(
        'previous_role', current_role_text,
        'next_role', next_role_text,
        'previous_active', current_active,
        'next_active', next_active,
        'previous_requested_role', current_requested_role_text,
        'previous_request_status', current_request_status,
        'pending_resolution', pending_resolution,
        'reason', nullif(btrim(coalesce(p_reason, '')), ''),
        'profile_completed', p_mark_complete and not current_complete
      )
    );
  exception
    when undefined_function then null;
    when others then null;
  end;

  select to_jsonb(p)
    into result_profile
  from public.profiles p
  where p.id::text = p_target_user_id;

  return jsonb_build_object(
    'ok', true,
    'profile', result_profile,
    'pending_resolution', pending_resolution
  );
end;
$$;

revoke all on function public.nexlab_admin_manage_profile(
  text, text, boolean, jsonb, text, text, text, text, boolean
) from public;

grant execute on function public.nexlab_admin_manage_profile(
  text, text, boolean, jsonb, text, text, text, text, boolean
) to authenticated;

-- -----------------------------------------------------------------------------
-- 7. Cancelamento da própria solicitação pendente
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_cancel_own_profile_request(
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  request_id uuid;
  requested_role_text text;
  current_role_text text;
  admin_row record;
  result_profile jsonb;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.' using errcode = '42501';
  end if;

  select
    p.role::text,
    p.vinculo_solicitado::text
  into
    current_role_text,
    requested_role_text
  from public.profiles p
  where p.id::text = auth.uid()::text
    and p.role_request_status = 'pending'
  for update;

  if current_role_text is null then
    raise exception 'Não existe solicitação pendente para cancelar.' using errcode = 'P0002';
  end if;

  select r.id
    into request_id
  from public.profile_role_requests r
  where r.user_id::text = auth.uid()::text
    and r.status = 'pending'
  order by r.created_at desc
  limit 1
  for update;

  if request_id is null then
    raise exception 'Registro da solicitação pendente não encontrado.' using errcode = 'P0002';
  end if;

  update public.profile_role_requests
  set
    status = 'cancelled',
    reason = coalesce(nullif(btrim(p_reason), ''), 'Cancelada pelo solicitante.'),
    reviewed_by = auth.uid(),
    reviewed_at = now(),
    updated_at = now()
  where id = request_id;

  perform set_config('nexlab.profile_flow', 'trusted', true);

  update public.profiles
  set
    vinculo_solicitado = role,
    role_request_status = 'cancelled',
    role_request_reason = coalesce(nullif(btrim(p_reason), ''), 'Cancelada pelo solicitante.'),
    role_request_reviewed_at = now(),
    role_request_reviewed_by = auth.uid()
  where id::text = auth.uid()::text;

  for admin_row in
    select p.id::text as id_text
    from public.profiles p
    where lower(p.role::text) in ('admin', 'administrador')
      and coalesce(p.ativo, true)
      and p.id::text <> auth.uid()::text
  loop
    perform public.nexlab_profile_flow_notification(
      admin_row.id_text,
      'Solicitação de perfil cancelada',
      format(
        'O usuário cancelou a solicitação para o perfil %s.',
        public.nexlab_profile_role_label(requested_role_text)
      ),
      'participantes',
      format('profile-request-cancelled:%s:%s', request_id, admin_row.id_text),
      'normal',
      jsonb_build_object(
        'request_id', request_id,
        'user_id', auth.uid(),
        'requested_role', requested_role_text,
        'status', 'cancelled'
      )
    );
  end loop;

  select to_jsonb(p)
    into result_profile
  from public.profiles p
  where p.id::text = auth.uid()::text;

  return jsonb_build_object(
    'ok', true,
    'request_id', request_id,
    'profile', result_profile
  );
end;
$$;

revoke all on function public.nexlab_cancel_own_profile_request(text) from public;
grant execute on function public.nexlab_cancel_own_profile_request(text) to authenticated;

-- -----------------------------------------------------------------------------
-- 8. Backfill mínimo do histórico e registro da versão
-- -----------------------------------------------------------------------------

insert into public.profile_management_history (
  user_id,
  actor_id,
  event_type,
  previous_role,
  next_role,
  previous_active,
  next_active,
  reason,
  metadata,
  created_at
)
select
  p.id,
  p.role_request_reviewed_by,
  case p.role_request_status
    when 'auto_approved' then 'request_auto_approved'
    when 'rejected' then 'request_rejected'
    when 'cancelled' then 'request_cancelled'
    else 'request_approved'
  end,
  p.role,
  p.role,
  p.ativo,
  p.ativo,
  p.role_request_reason,
  jsonb_build_object('backfilled', true),
  coalesce(p.role_request_reviewed_at, p.created_at, now())
from public.profiles p
where coalesce(p.cadastro_completo, false)
  and not exists (
    select 1
    from public.profile_management_history h
    where h.user_id = p.id
  );

update public.nexlab_app_versions
set
  release_status = 'stable',
  notes = 'Versão testada e aprovada. Fluxo seguro de perfis validado.'
where version = '25.10.0';

insert into public.nexlab_app_versions (
  version,
  title,
  release_status,
  notes
)
values (
  '25.11.0',
  'Gestão de Usuários e Vínculos',
  'rc',
  'Painel administrativo por situação, histórico de vínculos, correção de cadastros, desativação com motivo, cancelamento de solicitação e proteção do último Administrador.'
)
on conflict (version) do update
set
  title = excluded.title,
  release_status = excluded.release_status,
  notes = excluded.notes,
  installed_at = now(),
  installed_by = auth.uid();

commit;
