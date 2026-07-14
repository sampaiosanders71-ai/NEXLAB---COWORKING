-- NEXLAB v26.26.1 — R47
-- Permissões: senha administrativa para exportação sensível
-- JÁ APLICADO NO PROJETO eahldhabwulnwhuwrhvc.
-- NÃO EXECUTAR NOVAMENTE NO MESMO BANCO.
-- A senha solicitada não aparece em texto neste arquivo; somente o hash bcrypt é armazenado.

insert into public.nexlab_app_versions(version,title,release_status,notes,installed_at,installed_by)
values('26.26.1','Permissões — Senha Administrativa','stable','Substitui a exigência de AAL2 pela senha administrativa validada por hash ao conceder exportação sensível.',now(),null)
on conflict(version) do update
set title=excluded.title,release_status=excluded.release_status,notes=excluded.notes,installed_at=excluded.installed_at;

insert into public.nexlab_system_settings(setting_key,setting_value,description,updated_at,updated_by)
values(
  'sensitive_permission_password',
  jsonb_build_object('hash','$2a$12$pjBB5EhSxoweiE1LI6zo6OUAESLHde7FWY7p4HeuXeK.oPGSitbrK','algorithm','bcrypt'),
  'Hash da senha administrativa exigida somente para conceder a permissão de exportação sensível.',
  now(),null
)
on conflict(setting_key) do update
set setting_value=excluded.setting_value,description=excluded.description,updated_at=excluded.updated_at,updated_by=excluded.updated_by;

update public.nexlab_permission_catalog
set description='Permite gerar relatório restrito com CPF e data de nascimento. Exige senha administrativa e auditoria.',updated_at=now()
where permission_key='action_sensitive_export';

create or replace function public.nexlab_verify_sensitive_permission_password_v26261(p_password text)
returns boolean
language plpgsql
security definer
set search_path=public,auth,extensions,pg_temp
as $$
declare
  stored_hash text;
  password_valid boolean:=false;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;
  select setting_value->>'hash' into stored_hash
  from public.nexlab_system_settings
  where setting_key='sensitive_permission_password';
  if nullif(stored_hash,'') is null then
    raise exception 'A senha administrativa ainda não foi configurada.' using errcode='55000';
  end if;
  password_valid:=extensions.crypt(coalesce(p_password,''),stored_hash)=stored_hash;
  if password_valid then
    perform set_config('nexlab.sensitive_password_verified','true',true);
  else
    perform pg_sleep(0.35);
  end if;
  return password_valid;
end;
$$;

revoke execute on function public.nexlab_verify_sensitive_permission_password_v26261(text)
from public,anon,authenticated;
grant execute on function public.nexlab_verify_sensitive_permission_password_v26261(text)
to service_role;

create or replace function public.nexlab_guard_sensitive_permission_grant()
returns trigger
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  permission_key_value text:=coalesce(to_jsonb(new)->>'permission_key','');
  grant_attempt boolean:=false;
  password_verified boolean:=coalesce(current_setting('nexlab.sensitive_password_verified',true),'')='true';
begin
  if permission_key_value<>'action_sensitive_export' then return new; end if;
  if tg_table_name='nexlab_role_permission_defaults' then
    grant_attempt:=coalesce((to_jsonb(new)->>'allowed')::boolean,false);
  elsif tg_table_name='nexlab_user_permission_overrides' then
    grant_attempt:=lower(coalesce(to_jsonb(new)->>'effect',''))='allow';
  end if;
  if grant_attempt and auth.uid() is not null then
    if not public.nexlab_is_admin() or not password_verified then
      raise exception 'Informe a senha administrativa para conceder a exportação de dados pessoais.' using errcode='42501';
    end if;
  elsif grant_attempt and auth.uid() is null and session_user not in ('postgres','supabase_admin') then
    raise exception 'Concessão sensível sem identidade administrativa válida.' using errcode='42501';
  end if;
  return new;
end;
$$;

create or replace function public.nexlab_admin_save_role_permissions_v26261(
  p_role text,p_permissions jsonb,p_reason text,p_expected_revision bigint,p_sensitive_password text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare grants_sensitive boolean:=false;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;
  grants_sensitive:=coalesce(p_permissions->'action_sensitive_export'='true'::jsonb,false);
  if grants_sensitive and not public.nexlab_verify_sensitive_permission_password_v26261(p_sensitive_password) then
    raise exception 'Senha administrativa incorreta.' using errcode='42501';
  end if;
  return public.nexlab_admin_save_role_permissions(p_role,p_permissions,p_reason,p_expected_revision)
    || jsonb_build_object('sensitive_authorization',case when grants_sensitive then 'admin_password' else 'not_required' end,'version','26.26.1');
end;
$$;

revoke execute on function public.nexlab_admin_save_role_permissions_v26261(text,jsonb,text,bigint,text)
from public,anon;
grant execute on function public.nexlab_admin_save_role_permissions_v26261(text,jsonb,text,bigint,text)
to authenticated;

create or replace function public.nexlab_admin_save_user_permissions_v26261(
  p_target_user_id text,p_overrides jsonb,p_reason text,p_expected_revision bigint,p_sensitive_password text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare grants_sensitive boolean:=false;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then
    raise exception 'Ação exclusiva de Administradores.' using errcode='42501';
  end if;
  grants_sensitive:=lower(coalesce(p_overrides->>'action_sensitive_export',''))='allow';
  if grants_sensitive and not public.nexlab_verify_sensitive_permission_password_v26261(p_sensitive_password) then
    raise exception 'Senha administrativa incorreta.' using errcode='42501';
  end if;
  return public.nexlab_admin_save_user_permissions(p_target_user_id,p_overrides,p_reason,p_expected_revision)
    || jsonb_build_object('sensitive_authorization',case when grants_sensitive then 'admin_password' else 'not_required' end,'version','26.26.1');
end;
$$;

revoke execute on function public.nexlab_admin_save_user_permissions_v26261(text,jsonb,text,bigint,text)
from public,anon;
grant execute on function public.nexlab_admin_save_user_permissions_v26261(text,jsonb,text,bigint,text)
to authenticated;

create or replace function public.nexlab_can_export_sensitive_data()
returns boolean
language sql
stable
security definer
set search_path=public,auth
as $$
  select exists(
    select 1
    from public.profiles profile
    where profile.id::text=auth.uid()::text
      and profile.ativo is distinct from false
      and profile.role_request_status in ('approved','auto_approved')
      and 'action_sensitive_export'=any(coalesce(profile.effective_permissions,'{}'::text[]))
  )
$$;

create or replace function public.nexlab_get_sensitive_action_status()
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth
as $$
declare has_permission boolean:=false;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.' using errcode='42501';
  end if;
  select 'action_sensitive_export'=any(coalesce(profile.effective_permissions,'{}'::text[]))
  into has_permission
  from public.profiles profile
  where profile.id::text=auth.uid()::text and profile.ativo is distinct from false;
  return jsonb_build_object(
    'has_sensitive_export_permission',coalesce(has_permission,false),
    'requires_mfa',false,
    'requires_password_on_grant',true,
    'authorization_method','admin_password'
  );
end;
$$;

create or replace function public.nexlab_get_production_readiness(p_client_context jsonb default '{}'::jsonb)
returns jsonb
language sql
security definer
set search_path=public,auth,pg_temp
as $$
  select public.nexlab_get_production_readiness_v26240_base(coalesce(p_client_context,'{}'::jsonb))
    || jsonb_build_object('diagnostic_version','26.26.1')
$$;

revoke execute on function public.nexlab_get_production_readiness(jsonb) from public,anon;
grant execute on function public.nexlab_get_production_readiness(jsonb) to authenticated;
