-- NexLab v25.11.0 — Reversão para v25.10.0
-- Use somente se a v25.11 causar um bloqueio confirmado.
-- Execute integralmente no Supabase SQL Editor.

begin;

-- 1. Remover automações exclusivas da v25.11 antes de alterar os dados.
drop trigger if exists nexlab_capture_profile_management_history_trigger
on public.profiles;

drop trigger if exists nexlab_prevent_last_active_admin_trigger
on public.profiles;

drop function if exists public.nexlab_capture_profile_management_history();
drop function if exists public.nexlab_prevent_last_active_admin();

drop function if exists public.nexlab_admin_manage_profile(
  text, text, boolean, jsonb, text, text, text, text, boolean
);

drop function if exists public.nexlab_cancel_own_profile_request(text);

-- 2. Normalizar estados que a v25.10 não reconhece.
update public.profiles
set
  role_request_status = case
    when lower(role::text) = 'coworking_junior' then 'auto_approved'
    else 'approved'
  end,
  vinculo_solicitado = role,
  role_request_reason = null
where role_request_status = 'cancelled';

alter table public.profiles
  drop constraint if exists profiles_role_request_status_check;

alter table public.profiles
  add constraint profiles_role_request_status_check
  check (role_request_status in ('pending', 'approved', 'rejected', 'auto_approved'));

-- 3. Remover histórico e metadados exclusivos da v25.11.
drop policy if exists profile_management_history_select_own_or_admin
on public.profile_management_history;

drop table if exists public.profile_management_history;

alter table public.profiles
  drop column if exists account_status_changed_by,
  drop column if exists account_status_changed_at,
  drop column if exists account_status_reason;

-- 4. Restaurar a revisão de perfis da v25.10.
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

-- 5. Restaurar o registro de versão.
delete from public.nexlab_app_versions
where version = '25.11.0';

update public.nexlab_app_versions
set
  release_status = 'stable',
  notes = 'Versão testada e aprovada. Fluxo seguro de perfis validado.'
where version = '25.10.0';

commit;
