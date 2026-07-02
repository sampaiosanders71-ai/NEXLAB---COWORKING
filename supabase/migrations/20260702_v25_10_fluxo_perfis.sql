-- NexLab v25.10.0 — Fluxo Seguro de Perfis
-- Execute integralmente no Supabase SQL Editor após as migrations até v25.9.1.
-- Não exige alteração na Edge Function, nos Secrets ou no Cron.

begin;

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1. Metadados do fluxo e histórico de solicitações
-- -----------------------------------------------------------------------------

do $$
declare
  profile_id_type text;
  role_type text;
  requested_role_type text;
begin
  if to_regclass('public.profiles') is null then
    raise exception 'A tabela public.profiles não existe. Execute primeiro as migrations anteriores do NexLab.';
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

  select format_type(a.atttypid, a.atttypmod)
    into requested_role_type
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass
    and a.attname = 'vinculo_solicitado'
    and a.attnum > 0
    and not a.attisdropped;

  if profile_id_type is null or role_type is null or requested_role_type is null then
    raise exception 'Não foi possível identificar os tipos de profiles.id, profiles.role ou profiles.vinculo_solicitado.';
  end if;

  alter table public.profiles
    add column if not exists role_request_status text not null default 'approved',
    add column if not exists role_request_reason text null,
    add column if not exists role_request_created_at timestamptz null,
    add column if not exists role_request_reviewed_at timestamptz null;

  if not exists (
    select 1
    from pg_attribute
    where attrelid = 'public.profiles'::regclass
      and attname = 'role_request_reviewed_by'
      and attnum > 0
      and not attisdropped
  ) then
    execute format(
      'alter table public.profiles add column role_request_reviewed_by %s null',
      profile_id_type
    );
  end if;

  if to_regclass('public.profile_role_requests') is null then
    execute format(
      'create table public.profile_role_requests (
         id uuid primary key default gen_random_uuid(),
         user_id %s not null references public.profiles(id) on delete cascade,
         requested_role %s not null,
         previous_role %s not null,
         status text not null default ''pending'',
         automatic boolean not null default false,
         reason text null,
         reviewed_by %s null references public.profiles(id) on delete set null,
         reviewed_at timestamptz null,
         created_at timestamptz not null default now(),
         updated_at timestamptz not null default now(),
         constraint profile_role_requests_status_check
           check (status in (''pending'', ''approved'', ''rejected'', ''auto_approved'', ''cancelled''))
       )',
      profile_id_type,
      requested_role_type,
      role_type,
      profile_id_type
    );
  end if;
end
$$;

alter table public.profiles
  drop constraint if exists profiles_role_request_status_check;

alter table public.profiles
  add constraint profiles_role_request_status_check
  check (role_request_status in ('pending', 'approved', 'rejected', 'auto_approved'));

create unique index if not exists profile_role_requests_one_pending_per_user_idx
  on public.profile_role_requests (user_id)
  where status = 'pending';

create index if not exists profile_role_requests_user_created_idx
  on public.profile_role_requests (user_id, created_at desc);

create index if not exists profile_role_requests_status_created_idx
  on public.profile_role_requests (status, created_at desc);

create index if not exists profiles_role_request_status_idx
  on public.profiles (role_request_status, created_at desc);

-- -----------------------------------------------------------------------------
-- 2. RLS do histórico: usuário vê o próprio histórico; ADM vê todos
-- -----------------------------------------------------------------------------

alter table public.profile_role_requests enable row level security;

revoke all on public.profile_role_requests from anon;
revoke insert, update, delete on public.profile_role_requests from authenticated;
grant select on public.profile_role_requests to authenticated;

drop policy if exists profile_role_requests_select_own_or_admin
on public.profile_role_requests;

create policy profile_role_requests_select_own_or_admin
on public.profile_role_requests
for select
to authenticated
using (
  user_id::text = auth.uid()::text
  or public.nexlab_is_admin()
);

-- -----------------------------------------------------------------------------
-- 3. Funções auxiliares de rótulo e notificação
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_profile_role_label(p_role text)
returns text
language sql
immutable
set search_path = public
as $$
  select case lower(coalesce(p_role, ''))
    when 'admin' then 'Administrador'
    when 'administrador' then 'Administrador'
    when 'coordenador' then 'Coordenador'
    when 'bolsista' then 'Bolsista'
    when 'coworking_junior' then 'Coworking Júnior'
    else coalesce(nullif(p_role, ''), 'Não informado')
  end;
$$;

create or replace function public.nexlab_profile_flow_notification(
  p_recipient_id text,
  p_title text,
  p_message text,
  p_target_tab text,
  p_source_key text,
  p_priority text default 'normal',
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if to_regclass('public.notifications') is null then
    return;
  end if;

  begin
    insert into public.notifications (
      recipient_id,
      type,
      title,
      message,
      target_tab,
      source_key,
      category,
      priority,
      metadata,
      email_eligible,
      push_eligible
    )
    select
      p.id,
      'profile_request',
      p_title,
      p_message,
      p_target_tab,
      p_source_key,
      'usuarios',
      case when p_priority in ('baixa', 'normal', 'alta', 'urgente') then p_priority else 'normal' end,
      coalesce(p_metadata, '{}'::jsonb),
      true,
      true
    from public.profiles p
    where p.id::text = p_recipient_id
      and coalesce(p.ativo, true)
      and not exists (
        select 1
        from public.notifications n
        where n.source_key = p_source_key
          and n.recipient_id::text = p_recipient_id
      );
  exception
    when invalid_text_representation then
      insert into public.notifications (
        recipient_id,
        type,
        title,
        message,
        target_tab,
        source_key,
        category,
        priority,
        metadata,
        email_eligible,
        push_eligible
      )
      select
        p.id,
        'system',
        p_title,
        p_message,
        p_target_tab,
        p_source_key,
        'usuarios',
        case when p_priority in ('baixa', 'normal', 'alta', 'urgente') then p_priority else 'normal' end,
        coalesce(p_metadata, '{}'::jsonb),
        true,
        true
      from public.profiles p
      where p.id::text = p_recipient_id
        and coalesce(p.ativo, true)
        and not exists (
          select 1
          from public.notifications n
          where n.source_key = p_source_key
            and n.recipient_id::text = p_recipient_id
        );
  end;
end;
$$;

revoke all on function public.nexlab_profile_flow_notification(text, text, text, text, text, text, jsonb) from public;

-- -----------------------------------------------------------------------------
-- 4. Proteção dos campos de cargo e normalização do cadastro inicial
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_guard_profile_role_fields()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  actor_is_admin boolean := false;
  trusted_flow boolean := coalesce(current_setting('nexlab.profile_flow', true), '') = 'trusted';
  requested_role_text text;
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  begin
    actor_is_admin := public.nexlab_is_admin();
  exception
    when others then actor_is_admin := false;
  end;

  -- Alteração administrativa direta de cargo encerra qualquer solicitação antiga.
  if actor_is_admin and not trusted_flow and new.role is distinct from old.role then
    new.vinculo_solicitado := new.role;
    new.role_request_status := 'approved';
    new.role_request_reason := null;
    new.role_request_reviewed_at := now();
    new.role_request_reviewed_by := auth.uid();
    return new;
  end if;

  -- O próprio usuário só pode preencher os campos protegidos durante o primeiro cadastro.
  if auth.uid() is not null
     and auth.uid()::text = old.id::text
     and not actor_is_admin
     and not trusted_flow
  then
    if coalesce(old.cadastro_completo, false) = false
       and coalesce(new.cadastro_completo, false) = true
    then
      if new.role is distinct from old.role then
        raise exception 'O usuário não pode definir o próprio perfil atual.'
          using errcode = '42501';
      end if;

      requested_role_text := lower(coalesce(new.vinculo_solicitado::text, ''));

      if requested_role_text not in ('coworking_junior', 'bolsista', 'coordenador', 'admin') then
        raise exception 'Perfil solicitado inválido.'
          using errcode = '22023';
      end if;

      -- Todo novo usuário começa pelo nível básico. O acesso aos demais
      -- perfis só nasce após a decisão de um Administrador.
      new.role := 'coworking_junior';
      new.role_request_created_at := now();
      new.role_request_reviewed_at := null;
      new.role_request_reviewed_by := null;
      new.role_request_reason := null;

      if requested_role_text = 'coworking_junior' then
        new.role_request_status := 'auto_approved';
      else
        new.role_request_status := 'pending';
      end if;

      return new;
    end if;

    if new.role is distinct from old.role
       or new.vinculo_solicitado is distinct from old.vinculo_solicitado
       or new.cadastro_completo is distinct from old.cadastro_completo
       or new.role_request_status is distinct from old.role_request_status
       or new.role_request_reason is distinct from old.role_request_reason
       or new.role_request_created_at is distinct from old.role_request_created_at
       or new.role_request_reviewed_at is distinct from old.role_request_reviewed_at
       or new.role_request_reviewed_by is distinct from old.role_request_reviewed_by
    then
      raise exception 'Campos de perfil e aprovação só podem ser alterados pelo fluxo seguro do NexLab.'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_guard_profile_role_fields_trigger
on public.profiles;

create trigger nexlab_guard_profile_role_fields_trigger
before update on public.profiles
for each row
execute function public.nexlab_guard_profile_role_fields();

-- -----------------------------------------------------------------------------
-- 5. Registro da solicitação e aviso a todos os Administradores
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_after_profile_registration()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  request_id uuid;
  admin_row record;
  requested_role_text text;
  role_label text;
  registration_status text;
  notification_message text;
begin
  if coalesce(old.cadastro_completo, false) = false
     and coalesce(new.cadastro_completo, false) = true
  then
    requested_role_text := lower(coalesce(new.vinculo_solicitado::text, ''));
    registration_status := coalesce(new.role_request_status, 'pending');
    role_label := public.nexlab_profile_role_label(requested_role_text);

    insert into public.profile_role_requests (
      user_id,
      requested_role,
      previous_role,
      status,
      automatic,
      created_at,
      updated_at
    )
    values (
      new.id,
      new.vinculo_solicitado,
      old.role,
      registration_status,
      registration_status = 'auto_approved',
      coalesce(new.role_request_created_at, now()),
      now()
    )
    returning id into request_id;

    if registration_status = 'auto_approved' then
      notification_message := format(
        '%s concluiu o cadastro como %s. O perfil foi aprovado automaticamente.',
        coalesce(new.nome, new.email, 'Novo usuário'),
        role_label
      );
    else
      notification_message := format(
        '%s concluiu o cadastro e solicitou o perfil %s. A aprovação de um Administrador é necessária.',
        coalesce(new.nome, new.email, 'Novo usuário'),
        role_label
      );
    end if;

    for admin_row in
      select p.id::text as id_text
      from public.profiles p
      where lower(p.role::text) in ('admin', 'administrador')
        and coalesce(p.ativo, true)
        and p.id::text <> new.id::text
    loop
      perform public.nexlab_profile_flow_notification(
        admin_row.id_text,
        case
          when registration_status = 'auto_approved' then 'Novo usuário cadastrado'
          else 'Nova solicitação de perfil'
        end,
        notification_message,
        case when registration_status = 'auto_approved' then 'participantes' else 'pendencias' end,
        format('profile-registration:%s:%s', request_id, admin_row.id_text),
        case when registration_status = 'auto_approved' then 'normal' else 'alta' end,
        jsonb_build_object(
          'request_id', request_id,
          'user_id', new.id,
          'user_name', new.nome,
          'requested_role', requested_role_text,
          'status', registration_status,
          'automatic', registration_status = 'auto_approved'
        )
      );
    end loop;

    if registration_status = 'auto_approved' then
      perform public.nexlab_profile_flow_notification(
        new.id::text,
        'Perfil ativado automaticamente',
        'Seu perfil Coworking Júnior foi ativado. Você já pode utilizar os módulos liberados para esse vínculo.',
        'perfil',
        format('profile-auto-approved:%s:%s', request_id, new.id),
        'normal',
        jsonb_build_object(
          'request_id', request_id,
          'requested_role', requested_role_text,
          'status', registration_status
        )
      );
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists nexlab_after_profile_registration_trigger
on public.profiles;

create trigger nexlab_after_profile_registration_trigger
after update of cadastro_completo, vinculo_solicitado, role_request_status
on public.profiles
for each row
execute function public.nexlab_after_profile_registration();

-- -----------------------------------------------------------------------------
-- 6. RPC segura para concluir o cadastro inicial
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_complete_profile_registration(
  p_nome text,
  p_curso text,
  p_matricula text,
  p_habilidades text,
  p_requested_role text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  profile_id_text text;
  role_type text;
  requested_role_type text;
  current_role_text text;
  result_status text;
  already_complete boolean;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.' using errcode = '42501';
  end if;

  if btrim(coalesce(p_nome, '')) = ''
     or btrim(coalesce(p_curso, '')) = ''
     or btrim(coalesce(p_matricula, '')) = ''
  then
    raise exception 'Nome, curso e matrícula são obrigatórios.' using errcode = '22023';
  end if;

  p_requested_role := lower(btrim(coalesce(p_requested_role, '')));
  if p_requested_role not in ('coworking_junior', 'bolsista', 'coordenador', 'admin') then
    raise exception 'Perfil solicitado inválido.' using errcode = '22023';
  end if;

  select
    p.id::text,
    p.role::text,
    coalesce(p.cadastro_completo, false)
  into
    profile_id_text,
    current_role_text,
    already_complete
  from public.profiles p
  where p.id::text = auth.uid()::text
  for update;

  if profile_id_text is null then
    raise exception 'Perfil do NexLab não encontrado.' using errcode = 'P0002';
  end if;

  if already_complete then
    raise exception 'O cadastro inicial já foi concluído.' using errcode = '23505';
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

  if role_type is null or requested_role_type is null then
    raise exception 'Tipos de perfil não identificados.';
  end if;

  perform set_config('nexlab.profile_flow', 'trusted', true);

  if p_requested_role = 'coworking_junior' then
    execute format(
      'update public.profiles
         set nome = $1,
             curso = $2,
             matricula = $3,
             habilidades = nullif(btrim($4), ''''),
             role = $5::%s,
             vinculo_solicitado = $5::%s,
             cadastro_completo = true,
             role_request_status = ''auto_approved'',
             role_request_reason = null,
             role_request_created_at = now(),
             role_request_reviewed_at = null,
             role_request_reviewed_by = null
       where id::text = $6',
      role_type,
      requested_role_type
    )
    using
      btrim(p_nome),
      btrim(p_curso),
      btrim(p_matricula),
      coalesce(p_habilidades, ''),
      p_requested_role,
      auth.uid()::text;
  else
    execute format(
      'update public.profiles
         set nome = $1,
             curso = $2,
             matricula = $3,
             habilidades = nullif(btrim($4), ''''),
             role = ''coworking_junior''::%s,
             vinculo_solicitado = $5::%s,
             cadastro_completo = true,
             role_request_status = ''pending'',
             role_request_reason = null,
             role_request_created_at = now(),
             role_request_reviewed_at = null,
             role_request_reviewed_by = null
       where id::text = $6',
      role_type,
      requested_role_type
    )
    using
      btrim(p_nome),
      btrim(p_curso),
      btrim(p_matricula),
      coalesce(p_habilidades, ''),
      p_requested_role,
      auth.uid()::text;
  end if;

  select p.role::text, p.role_request_status
    into current_role_text, result_status
  from public.profiles p
  where p.id::text = auth.uid()::text;

  return jsonb_build_object(
    'ok', true,
    'status', result_status,
    'current_role', current_role_text,
    'requested_role', p_requested_role
  );
end;
$$;

revoke all on function public.nexlab_complete_profile_registration(text, text, text, text, text) from public;
grant execute on function public.nexlab_complete_profile_registration(text, text, text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 7. RPC exclusiva do ADM para aprovar ou recusar
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

  if p_target_user_id is null or btrim(p_target_user_id) = '' then
    raise exception 'Usuário alvo não informado.' using errcode = '22023';
  end if;

  if p_target_user_id = auth.uid()::text then
    raise exception 'Um Administrador não pode aprovar a própria solicitação.' using errcode = '42501';
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
  final_reason := case
    when p_approved then null
    else coalesce(nullif(btrim(p_reason), ''), 'Solicitação recusada pelo Administrador.')
  end;

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
    )
    using requested_role_text, p_target_user_id;
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
-- 8. Compatibilidade e correção dos perfis existentes
-- -----------------------------------------------------------------------------

-- Perfis sem solicitação explícita passam a refletir o cargo atual.
update public.profiles
set
  vinculo_solicitado = role,
  role_request_status = case
    when lower(role::text) = 'coworking_junior' then 'auto_approved'
    else 'approved'
  end,
  role_request_reason = null,
  role_request_created_at = coalesce(role_request_created_at, created_at),
  role_request_reviewed_at = coalesce(role_request_reviewed_at, created_at)
where coalesce(cadastro_completo, false)
  and vinculo_solicitado is null;

-- Solicitação antiga de Coworking Júnior nunca deve permanecer pendente.
-- Se o cargo atual já é superior, preserva-se o cargo atual e encerra-se o dado antigo.
update public.profiles
set
  vinculo_solicitado = role,
  role_request_status = case
    when lower(role::text) = 'coworking_junior' then 'auto_approved'
    else 'approved'
  end,
  role_request_reason = null,
  role_request_created_at = coalesce(role_request_created_at, created_at),
  role_request_reviewed_at = coalesce(role_request_reviewed_at, now())
where coalesce(cadastro_completo, false)
  and lower(coalesce(vinculo_solicitado::text, '')) = 'coworking_junior';

-- Solicitações antigas já iguais ao cargo atual são consideradas resolvidas.
update public.profiles
set
  role_request_status = case
    when lower(role::text) = 'coworking_junior' then 'auto_approved'
    else 'approved'
  end,
  role_request_reason = null,
  role_request_created_at = coalesce(role_request_created_at, created_at),
  role_request_reviewed_at = coalesce(role_request_reviewed_at, created_at)
where coalesce(cadastro_completo, false)
  and vinculo_solicitado::text = role::text;

-- Diferenças antigas para Bolsista, Coordenador ou ADM viram pendências reais.
update public.profiles
set
  role_request_status = 'pending',
  role_request_reason = null,
  role_request_created_at = coalesce(role_request_created_at, created_at),
  role_request_reviewed_at = null,
  role_request_reviewed_by = null
where coalesce(cadastro_completo, false)
  and lower(coalesce(vinculo_solicitado::text, '')) in ('bolsista', 'coordenador', 'admin')
  and vinculo_solicitado::text <> role::text;

insert into public.profile_role_requests (
  user_id,
  requested_role,
  previous_role,
  status,
  automatic,
  created_at,
  updated_at
)
select
  p.id,
  p.vinculo_solicitado,
  p.role,
  'pending',
  false,
  coalesce(p.role_request_created_at, p.created_at, now()),
  now()
from public.profiles p
where p.role_request_status = 'pending'
  and not exists (
    select 1
    from public.profile_role_requests r
    where r.user_id = p.id
      and r.status = 'pending'
  );

-- Gera avisos para pendências antigas que estavam invisíveis ao ADM.
do $$
declare
  pending_row record;
  admin_row record;
begin
  for pending_row in
    select
      p.id::text as user_id_text,
      p.nome,
      p.vinculo_solicitado::text as requested_role_text,
      r.id as request_id
    from public.profiles p
    join lateral (
      select pr.id
      from public.profile_role_requests pr
      where pr.user_id = p.id
        and pr.status = 'pending'
      order by pr.created_at desc
      limit 1
    ) r on true
    where p.role_request_status = 'pending'
      and coalesce(p.ativo, true)
  loop
    for admin_row in
      select p.id::text as id_text
      from public.profiles p
      where lower(p.role::text) in ('admin', 'administrador')
        and coalesce(p.ativo, true)
        and p.id::text <> pending_row.user_id_text
    loop
      perform public.nexlab_profile_flow_notification(
        admin_row.id_text,
        'Solicitação de perfil pendente',
        format(
          '%s solicitou o perfil %s e aguarda aprovação.',
          coalesce(pending_row.nome, 'Usuário'),
          public.nexlab_profile_role_label(pending_row.requested_role_text)
        ),
        'pendencias',
        format('profile-backfill:%s:%s', pending_row.request_id, admin_row.id_text),
        'alta',
        jsonb_build_object(
          'request_id', pending_row.request_id,
          'user_id', pending_row.user_id_text,
          'requested_role', pending_row.requested_role_text,
          'status', 'pending',
          'backfilled', true
        )
      );
    end loop;
  end loop;
end
$$;

-- -----------------------------------------------------------------------------
-- 9. Realtime e versão instalada
-- -----------------------------------------------------------------------------

do $$
begin
  begin
    alter publication supabase_realtime add table public.profiles;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.profile_role_requests;
  exception
    when duplicate_object then null;
  end;
end
$$;

insert into public.nexlab_app_versions (
  version,
  title,
  release_status,
  notes
)
values (
  '25.10.0',
  'Fluxo Seguro de Perfis',
  'rc',
  'Notifica Administradores em novos cadastros, aprova Coworking Júnior automaticamente e exige aprovação administrativa para Bolsista, Coordenador e Administrador.'
)
on conflict (version) do update
set
  title = excluded.title,
  release_status = excluded.release_status,
  notes = excluded.notes,
  installed_at = now(),
  installed_by = auth.uid();

commit;
