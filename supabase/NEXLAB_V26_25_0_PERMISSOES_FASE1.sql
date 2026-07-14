-- NEXLAB v26.25.0 — Permissões, Fase 1
-- Projeto: eahldhabwulnwhuwrhvc
-- CONSOLIDADO DE BACKUP. As migrations já foram aplicadas no projeto atual.
-- Não executar novamente no mesmo banco.

-- 1. Versão, proteção do Administrador e acesso ao Mural.
insert into public.nexlab_app_versions(
  version,title,release_status,notes,installed_at,installed_by
) values (
  '26.25.0',
  'Permissões — Segurança Administrativa',
  'stable',
  'Proteção do perfil Administrador, acesso ao Mural, privilégios mínimos e autorização unificada.',
  now(),
  null
)
on conflict (version) do update
set title=excluded.title,
    release_status=excluded.release_status,
    notes=excluded.notes,
    installed_at=excluded.installed_at;

update public.nexlab_permission_catalog
set eligible_roles=array['admin','coordenador','bolsista','coworking_junior']::text[],
    description='Feed interno disponível aos perfis ativos conforme a matriz de permissões.',
    updated_at=now()
where permission_key='module_mural';

insert into public.nexlab_role_permission_defaults(
  role_key,permission_key,allowed,updated_by,updated_at
)
select role_key,'module_mural',true,null,now()
from (values ('admin'),('coordenador'),('bolsista'),('coworking_junior')) roles(role_key)
on conflict (role_key,permission_key) do update
set allowed=true,updated_by=null,updated_at=now();

insert into public.nexlab_role_permission_defaults(
  role_key,permission_key,allowed,updated_by,updated_at
)
select 'admin',catalog.permission_key,true,null,now()
from public.nexlab_permission_catalog catalog
where catalog.active and 'admin'=any(catalog.eligible_roles)
on conflict (role_key,permission_key) do update
set allowed=true,updated_by=null,updated_at=now();

with removed as (
  delete from public.nexlab_user_permission_overrides override_row
  using public.profiles profile
  where profile.id=override_row.user_id
    and lower(profile.role::text) in ('admin','administrador')
  returning override_row.user_id,override_row.permission_key,override_row.effect,override_row.reason
)
insert into public.nexlab_permission_history(
  scope,user_id,permission_key,previous_value,next_value,reason,actor_id,metadata
)
select
  'migration',removed.user_id,removed.permission_key,removed.effect,'protected_admin',
  'Exceção removida pela proteção estrutural do perfil Administrador.',null,
  jsonb_build_object('version','26.25.0','previous_reason',removed.reason)
from removed;

-- 2. Privilégios mínimos e RLS administrativa.
revoke all privileges on table public.nexlab_permission_catalog from authenticated;
revoke all privileges on table public.nexlab_role_permission_defaults from authenticated;
revoke all privileges on table public.nexlab_user_permission_overrides from authenticated;
revoke all privileges on table public.nexlab_permission_history from authenticated;

grant select on table public.nexlab_permission_catalog to authenticated;
grant select on table public.nexlab_role_permission_defaults to authenticated;
grant select on table public.nexlab_user_permission_overrides to authenticated;
grant select on table public.nexlab_permission_history to authenticated;

drop policy if exists nexlab_approved_account_gate on public.nexlab_permission_catalog;
drop policy if exists nexlab_permission_catalog_admin_select on public.nexlab_permission_catalog;
create policy nexlab_permission_catalog_admin_read_v26250
on public.nexlab_permission_catalog for select to authenticated
using (public.nexlab_has_approved_access() and public.nexlab_is_admin());

drop policy if exists nexlab_approved_account_gate on public.nexlab_role_permission_defaults;
drop policy if exists nexlab_role_permission_defaults_admin_select on public.nexlab_role_permission_defaults;
create policy nexlab_role_permission_defaults_admin_read_v26250
on public.nexlab_role_permission_defaults for select to authenticated
using (public.nexlab_has_approved_access() and public.nexlab_is_admin());

drop policy if exists nexlab_approved_account_gate on public.nexlab_user_permission_overrides;
drop policy if exists nexlab_user_permission_overrides_admin_select on public.nexlab_user_permission_overrides;
create policy nexlab_user_permission_overrides_admin_read_v26250
on public.nexlab_user_permission_overrides for select to authenticated
using (public.nexlab_has_approved_access() and public.nexlab_is_admin());

drop policy if exists nexlab_approved_account_gate on public.nexlab_permission_history;
drop policy if exists nexlab_permission_history_admin_select on public.nexlab_permission_history;
create policy nexlab_permission_history_admin_read_v26250
on public.nexlab_permission_history for select to authenticated
using (public.nexlab_has_approved_access() and public.nexlab_is_admin());

revoke execute on function public.nexlab_get_permission_matrix() from public,anon;
grant execute on function public.nexlab_get_permission_matrix() to authenticated;

revoke execute on function public.nexlab_recalculate_profile_permissions(text) from public,anon,authenticated;
grant execute on function public.nexlab_recalculate_profile_permissions(text) to service_role;
revoke execute on function public.nexlab_guard_effective_permissions() from public,anon,authenticated;
grant execute on function public.nexlab_guard_effective_permissions() to service_role;
revoke execute on function public.nexlab_guard_sensitive_permission_grant() from public,anon,authenticated;
grant execute on function public.nexlab_guard_sensitive_permission_grant() to service_role;

-- 3. Fonte de verdade: effective_permissions; acessos é somente espelho legado.
create or replace function public.nexlab_recalculate_profile_permissions(p_target_user_id text)
returns text[]
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  target_role text;
  permissions_result text[] := '{}'::text[];
  legacy_tokens text[] := '{}'::text[];
begin
  select case
           when lower(coalesce(profile.role::text,''))='administrador' then 'admin'
           else lower(coalesce(profile.role::text,''))
         end
  into target_role
  from public.profiles profile
  where profile.id::text=p_target_user_id
  for update;

  if target_role is null then
    raise exception 'Usuário não encontrado.' using errcode='P0002';
  end if;

  select coalesce(array_agg(catalog.permission_key order by catalog.sort_order,catalog.permission_key),'{}'::text[])
  into permissions_result
  from public.nexlab_permission_catalog catalog
  left join public.nexlab_role_permission_defaults default_row
    on default_row.role_key=target_role and default_row.permission_key=catalog.permission_key
  left join public.nexlab_user_permission_overrides override_row
    on override_row.user_id::text=p_target_user_id and override_row.permission_key=catalog.permission_key
  where catalog.active
    and target_role=any(catalog.eligible_roles)
    and (
      target_role='admin'
      or catalog.core
      or (
        not catalog.admin_only
        and case
          when override_row.effect='allow' then true
          when override_row.effect='deny' then false
          else coalesce(default_row.allowed,false)
        end
      )
    );

  legacy_tokens:=array_remove(array[
    case when 'patrimonio_manage'=any(permissions_result) then 'patr' end,
    case when 'module_marketing'=any(permissions_result) then 'mkt' end,
    case when 'action_sensitive_export'=any(permissions_result) then 'usr_report' end,
    case when target_role in ('admin','coordenador') and 'module_eventos'=any(permissions_result) then 'evt_manage' end
  ]::text[],null);

  perform set_config('nexlab.permission_flow','trusted',true);
  update public.profiles
  set effective_permissions=permissions_result,
      acessos=legacy_tokens
  where id::text=p_target_user_id;
  perform set_config('nexlab.permission_flow','',true);
  return permissions_result;
end;
$$;

create or replace function public.guard_acessos()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if new.acessos is not distinct from old.acessos then return new; end if;
  if coalesce(current_setting('nexlab.permission_flow',true),'')='trusted'
     or auth.uid() is null then
    return new;
  end if;
  raise exception 'A coluna legada de acessos é somente leitura e é derivada das permissões efetivas.'
    using errcode='42501';
end;
$$;

create or replace function public.has_cap(cap text)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists(
    select 1 from public.profiles profile
    where profile.id=auth.uid()
      and profile.ativo is distinct from false
      and (
        lower(profile.role::text) in ('admin','administrador')
        or case lower(coalesce(cap,''))
          when 'mkt' then 'module_marketing'=any(coalesce(profile.effective_permissions,'{}'::text[]))
          when 'patr' then 'patrimonio_manage'=any(coalesce(profile.effective_permissions,'{}'::text[]))
          when 'usr_report' then 'action_sensitive_export'=any(coalesce(profile.effective_permissions,'{}'::text[]))
          when 'evt_manage' then lower(profile.role::text) in ('admin','administrador','coordenador')
                                and 'module_eventos'=any(coalesce(profile.effective_permissions,'{}'::text[]))
          else lower(coalesce(cap,''))=any(coalesce(profile.effective_permissions,'{}'::text[]))
        end
      )
  )
$$;

create or replace function public.can_manage_operational_records(required_access text default null)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists(
    select 1 from public.profiles profile
    where profile.id=auth.uid()
      and profile.ativo is distinct from false
      and (
        lower(profile.role::text) in ('admin','administrador','coordenador')
        or (
          required_access is not null
          and case lower(required_access)
            when 'mkt' then 'module_marketing'=any(coalesce(profile.effective_permissions,'{}'::text[]))
            when 'patr' then 'patrimonio_manage'=any(coalesce(profile.effective_permissions,'{}'::text[]))
            when 'usr_report' then 'action_sensitive_export'=any(coalesce(profile.effective_permissions,'{}'::text[]))
            when 'evt_manage' then false
            else lower(required_access)=any(coalesce(profile.effective_permissions,'{}'::text[]))
          end
        )
      )
  )
$$;

create or replace function public.can_export_sensitive_event_participants()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists(
    select 1 from public.profiles profile
    where profile.id=auth.uid()
      and profile.ativo is distinct from false
      and 'action_sensitive_export'=any(coalesce(profile.effective_permissions,'{}'::text[]))
  )
$$;

create or replace function public.can_manage_event_participants()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists(
    select 1 from public.profiles profile
    where profile.id=auth.uid()
      and profile.ativo is distinct from false
      and lower(profile.role::text) in ('admin','administrador','coordenador')
      and 'module_eventos'=any(coalesce(profile.effective_permissions,'{}'::text[]))
  )
$$;

-- 4. Auditoria autorizada pela matriz atual.
create or replace function public.record_security_audit(
  action_name text,
  target_user_id uuid default null,
  event_details jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  requester_role text;
  requester_active boolean;
  requester_name text;
  requester_email text;
  requester_permissions text[];
  allowed_action boolean:=false;
begin
  if auth.uid() is null then raise exception 'Autenticação obrigatória.' using errcode='42501'; end if;

  select profile.role::text,profile.ativo is distinct from false,
         profile.nome::text,profile.email::text,
         coalesce(profile.effective_permissions,'{}'::text[])
  into requester_role,requester_active,requester_name,requester_email,requester_permissions
  from public.profiles profile where profile.id=auth.uid();

  if requester_role is null or not requester_active then
    raise exception 'Perfil não autorizado.' using errcode='42501';
  end if;

  if action_name in (
    'user_access_updated','user_deactivated','user_reactivated','user_deleted',
    'event_deleted','project_deleted','team_deleted','meeting_deleted',
    'reservation_deleted','marketing_deleted','asset_deleted','post_deleted'
  ) then
    allowed_action:=lower(requester_role) in ('admin','administrador');
  elsif action_name in (
    'event_created','event_updated','project_created','project_updated',
    'project_status_updated','team_created','team_updated','team_archived',
    'team_restored','meeting_created','meeting_updated','meeting_cancelled',
    'feedback_status_updated'
  ) then
    allowed_action:=lower(requester_role) in ('admin','administrador','coordenador');
  elsif action_name in ('marketing_created','marketing_updated','marketing_status_updated') then
    allowed_action:='module_marketing'=any(requester_permissions);
  elsif action_name in ('asset_created','asset_updated','asset_condition_updated') then
    allowed_action:='patrimonio_manage'=any(requester_permissions);
  elsif action_name in ('post_created','post_updated') then
    allowed_action:='module_mural'=any(requester_permissions);
  elsif action_name='reservation_cancelled' then
    allowed_action:=true;
  elsif action_name in ('detailed_user_report_pdf','detailed_user_report_excel') then
    allowed_action:='action_sensitive_export'=any(requester_permissions);
  end if;

  if not allowed_action then
    raise exception 'Ação de auditoria inválida ou não autorizada.' using errcode='42501';
  end if;

  perform public.record_security_audit(
    action_name,target_user_id::text,
    coalesce(event_details,'{}'::jsonb)||jsonb_build_object(
      'actor_name',requester_name,
      'actor_email',requester_email,
      'permission_source','effective_permissions'
    )
  );
end;
$$;

-- 5. RPCs administrativas transacionais.
create or replace function public.nexlab_admin_save_role_permissions(
  p_role text,p_permissions jsonb,p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  permission_entry record;
  catalog_row public.nexlab_permission_catalog%rowtype;
  normalized_role text;
  old_allowed boolean;
  new_allowed boolean;
  changed_count integer:=0;
  profile_row record;
  correlation_id uuid:=gen_random_uuid();
  audit_id uuid;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then raise exception 'Ação exclusiva de Administradores.' using errcode='42501'; end if;
  normalized_role:=lower(btrim(coalesce(p_role,'')));
  if normalized_role='administrador' then normalized_role:='admin'; end if;
  if normalized_role not in ('admin','coordenador','bolsista','coworking_junior') then raise exception 'Perfil inválido.' using errcode='22023'; end if;
  if normalized_role='admin' then raise exception 'O perfil Administrador é protegido e utiliza acesso integral compatível com o catálogo.' using errcode='42501'; end if;
  if jsonb_typeof(p_permissions)<>'object' then raise exception 'A matriz de permissões deve ser um objeto JSON.' using errcode='22023'; end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then raise exception 'Informe o motivo da alteração.' using errcode='22023'; end if;

  for permission_entry in select key as permission_key,value from jsonb_each(p_permissions)
  loop
    select * into catalog_row from public.nexlab_permission_catalog catalog
    where catalog.permission_key=permission_entry.permission_key and catalog.active;
    if catalog_row.permission_key is null then raise exception 'Permissão desconhecida: %',permission_entry.permission_key using errcode='22023'; end if;
    if catalog_row.core or catalog_row.admin_only or not catalog_row.grantable then raise exception 'A permissão % é protegida e não pode ser alterada.',catalog_row.label using errcode='42501'; end if;
    if jsonb_typeof(permission_entry.value)<>'boolean' then raise exception 'O valor de % deve ser booleano.',catalog_row.label using errcode='22023'; end if;
    new_allowed:=permission_entry.value='true'::jsonb;
    if new_allowed and not normalized_role=any(catalog_row.eligible_roles) then raise exception 'A permissão % não é compatível com o perfil %.',catalog_row.label,normalized_role using errcode='23514'; end if;
    select default_row.allowed into old_allowed from public.nexlab_role_permission_defaults default_row
    where default_row.role_key=normalized_role and default_row.permission_key=catalog_row.permission_key;
    old_allowed:=coalesce(old_allowed,false);
    if old_allowed is distinct from new_allowed then
      insert into public.nexlab_role_permission_defaults(role_key,permission_key,allowed,updated_by,updated_at)
      values(normalized_role,catalog_row.permission_key,new_allowed,auth.uid(),now())
      on conflict(role_key,permission_key) do update set allowed=excluded.allowed,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
      insert into public.nexlab_permission_history(scope,role_key,permission_key,previous_value,next_value,reason,actor_id,metadata)
      values('role_default',normalized_role,catalog_row.permission_key,old_allowed::text,new_allowed::text,btrim(p_reason),auth.uid(),
        jsonb_build_object('label',catalog_row.label,'correlation_id',correlation_id,'version','26.25.0'));
      changed_count:=changed_count+1;
    end if;
  end loop;

  for profile_row in select profile.id::text as id_text from public.profiles profile
    where case when lower(profile.role::text)='administrador' then 'admin' else lower(profile.role::text) end=normalized_role
  loop
    perform public.nexlab_recalculate_profile_permissions(profile_row.id_text);
  end loop;

  audit_id:=public.record_security_audit('role_permissions_updated',null::text,
    jsonb_build_object('role',normalized_role,'changed_count',changed_count,'reason',btrim(p_reason),'correlation_id',correlation_id,'version','26.25.0'));
  return jsonb_build_object('ok',true,'role',normalized_role,'changed_count',changed_count,'correlation_id',correlation_id,'audit_id',audit_id);
end;
$$;

create or replace function public.nexlab_admin_save_user_permissions(
  p_target_user_id text,p_overrides jsonb,p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  target_profile record;
  permission_entry record;
  catalog_row public.nexlab_permission_catalog%rowtype;
  old_effect text;
  new_effect text;
  changed_count integer:=0;
  effective_result text[];
  correlation_id uuid:=gen_random_uuid();
  audit_id uuid;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then raise exception 'Ação exclusiva de Administradores.' using errcode='42501'; end if;
  if nullif(btrim(coalesce(p_target_user_id,'')),'') is null then raise exception 'Usuário alvo não informado.' using errcode='22023'; end if;
  if jsonb_typeof(p_overrides)<>'object' then raise exception 'As exceções devem ser um objeto JSON.' using errcode='22023'; end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then raise exception 'Informe o motivo da alteração.' using errcode='22023'; end if;

  select profile.id,profile.nome,case when lower(profile.role::text)='administrador' then 'admin' else lower(profile.role::text) end as role_key
  into target_profile from public.profiles profile where profile.id::text=p_target_user_id for update;
  if target_profile.id is null then raise exception 'Usuário não encontrado.' using errcode='P0002'; end if;
  if target_profile.role_key='admin' then raise exception 'Permissões individuais de Administradores são protegidas e não aceitam exceções.' using errcode='42501'; end if;

  for permission_entry in select key as permission_key,value from jsonb_each(p_overrides)
  loop
    select * into catalog_row from public.nexlab_permission_catalog catalog
    where catalog.permission_key=permission_entry.permission_key and catalog.active;
    if catalog_row.permission_key is null then raise exception 'Permissão desconhecida: %',permission_entry.permission_key using errcode='22023'; end if;
    if catalog_row.core or catalog_row.admin_only or not catalog_row.grantable then raise exception 'A permissão % é protegida e não aceita exceções individuais.',catalog_row.label using errcode='42501'; end if;
    new_effect:=case when permission_entry.value is null or permission_entry.value='null'::jsonb then null else lower(trim(both '"' from permission_entry.value::text)) end;
    if new_effect='default' then new_effect:=null; end if;
    if new_effect is not null and new_effect not in ('allow','deny') then raise exception 'Exceção inválida para %.',catalog_row.label using errcode='22023'; end if;
    if new_effect='allow' and not target_profile.role_key=any(catalog_row.eligible_roles) then raise exception 'A permissão % não é compatível com o perfil atual do usuário.',catalog_row.label using errcode='23514'; end if;
    select override_row.effect into old_effect from public.nexlab_user_permission_overrides override_row
    where override_row.user_id=target_profile.id and override_row.permission_key=catalog_row.permission_key;
    if old_effect is distinct from new_effect then
      if new_effect is null then
        delete from public.nexlab_user_permission_overrides where user_id=target_profile.id and permission_key=catalog_row.permission_key;
      else
        insert into public.nexlab_user_permission_overrides(user_id,permission_key,effect,reason,updated_by,updated_at)
        values(target_profile.id,catalog_row.permission_key,new_effect,btrim(p_reason),auth.uid(),now())
        on conflict(user_id,permission_key) do update set effect=excluded.effect,reason=excluded.reason,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
      end if;
      insert into public.nexlab_permission_history(scope,user_id,permission_key,previous_value,next_value,reason,actor_id,metadata)
      values('user_override',target_profile.id,catalog_row.permission_key,old_effect,coalesce(new_effect,'default'),btrim(p_reason),auth.uid(),
        jsonb_build_object('label',catalog_row.label,'role',target_profile.role_key,'correlation_id',correlation_id,'version','26.25.0'));
      changed_count:=changed_count+1;
    end if;
  end loop;

  effective_result:=public.nexlab_recalculate_profile_permissions(p_target_user_id);
  audit_id:=public.record_security_audit('user_permissions_updated',p_target_user_id,
    jsonb_build_object('mode','override','changed_count',changed_count,'reason',btrim(p_reason),'effective_permissions',effective_result,'correlation_id',correlation_id,'version','26.25.0'));
  if changed_count>0 then
    begin
      perform public.nexlab_profile_flow_notification(p_target_user_id,'Acessos do NexLab atualizados',
        format('Um Administrador atualizou seus acessos no NexLab. Foram registradas %s alteração(ões).',changed_count),
        'perfil',format('permission-update:%s:%s',p_target_user_id,extract(epoch from clock_timestamp())::bigint),
        'normal',jsonb_build_object('changed_count',changed_count,'reason',btrim(p_reason)));
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok',true,'user_id',p_target_user_id,'changed_count',changed_count,'effective_permissions',effective_result,'correlation_id',correlation_id,'audit_id',audit_id);
end;
$$;

create or replace function public.nexlab_admin_restore_user_permissions(
  p_target_user_id text,p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  target_profile record;
  deleted_count integer:=0;
  effective_result text[];
  correlation_id uuid:=gen_random_uuid();
  audit_id uuid;
begin
  if auth.uid() is null or not public.nexlab_is_admin() then raise exception 'Ação exclusiva de Administradores.' using errcode='42501'; end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then raise exception 'Informe o motivo da restauração.' using errcode='22023'; end if;
  select profile.id,profile.nome,case when lower(profile.role::text)='administrador' then 'admin' else lower(profile.role::text) end as role_key
  into target_profile from public.profiles profile where profile.id::text=p_target_user_id for update;
  if target_profile.id is null then raise exception 'Usuário não encontrado.' using errcode='P0002'; end if;
  select count(*) into deleted_count from public.nexlab_user_permission_overrides override_row where override_row.user_id=target_profile.id;
  delete from public.nexlab_user_permission_overrides where user_id=target_profile.id;
  insert into public.nexlab_permission_history(scope,user_id,previous_value,next_value,reason,actor_id,metadata)
  values('restore_defaults',target_profile.id,deleted_count::text,'0',btrim(p_reason),auth.uid(),
    jsonb_build_object('role',target_profile.role_key,'correlation_id',correlation_id,'version','26.25.0'));
  effective_result:=public.nexlab_recalculate_profile_permissions(p_target_user_id);
  audit_id:=public.record_security_audit('user_permissions_updated',p_target_user_id,
    jsonb_build_object('mode','restore_defaults','removed_overrides',deleted_count,'reason',btrim(p_reason),'effective_permissions',effective_result,'correlation_id',correlation_id,'version','26.25.0'));
  begin
    perform public.nexlab_profile_flow_notification(p_target_user_id,'Permissões restauradas',
      'Suas permissões personalizadas foram removidas e os acessos padrão do seu perfil foram restaurados.',
      'perfil',format('permission-restore:%s:%s',p_target_user_id,extract(epoch from clock_timestamp())::bigint),
      'normal',jsonb_build_object('removed_overrides',deleted_count,'reason',btrim(p_reason)));
  exception when others then null;
  end;
  return jsonb_build_object('ok',true,'user_id',p_target_user_id,'removed_overrides',deleted_count,'effective_permissions',effective_result,'correlation_id',correlation_id,'audit_id',audit_id);
end;
$$;

-- 6. View de perfis com effective_permissions e somente leitura ao cliente.
create or replace view public.nexlab_profiles_visible
with (security_barrier=true)
as
select
  profile.id,profile.nome,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.email else null::text end as email,
  profile.avatar_url,profile.avatar_path,profile.role,profile.ativo,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.acessos else null::text[] end as acessos,
  profile.created_at,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.curso else null::text end as curso,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.matricula else null::text end as matricula,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.vinculo_solicitado else null::text end as vinculo_solicitado,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.cadastro_completo else null::boolean end as cadastro_completo,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.role_request_status else null::text end as role_request_status,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.role_request_reason else null::text end as role_request_reason,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.role_request_created_at else null::timestamptz end as role_request_created_at,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.role_request_reviewed_at else null::timestamptz end as role_request_reviewed_at,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.role_request_reviewed_by else null::uuid end as role_request_reviewed_by,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.account_status_reason else null::text end as account_status_reason,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.account_status_changed_at else null::timestamptz end as account_status_changed_at,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.account_status_changed_by else null::uuid end as account_status_changed_by,
  case when public.nexlab_is_gestor() or profile.id::text=auth.uid()::text then profile.effective_permissions else null::text[] end as effective_permissions
from public.profiles profile
where public.nexlab_has_approved_access()
  and (profile.ativo is distinct from false or public.nexlab_is_gestor());

revoke all privileges on table public.nexlab_profiles_visible from authenticated;
grant select on table public.nexlab_profiles_visible to authenticated;

-- 7. Alinhamento da prontidão.
-- Na base v26.24.0, a função pública anterior foi preservada com o nome abaixo.
alter function public.nexlab_get_production_readiness(jsonb)
rename to nexlab_get_production_readiness_v26240_base;

create function public.nexlab_get_production_readiness(
  p_client_context jsonb default '{}'::jsonb
)
returns jsonb
language sql
security definer
set search_path = public, auth, pg_temp
as $$
  select public.nexlab_get_production_readiness_v26240_base(
    coalesce(p_client_context,'{}'::jsonb)
  ) || jsonb_build_object('diagnostic_version','26.25.0')
$$;

revoke execute on function public.nexlab_get_production_readiness_v26240_base(jsonb)
from public,anon,authenticated;
grant execute on function public.nexlab_get_production_readiness_v26240_base(jsonb)
to service_role;
revoke execute on function public.nexlab_get_production_readiness(jsonb)
from public,anon;
grant execute on function public.nexlab_get_production_readiness(jsonb)
to authenticated;

select public.nexlab_recalculate_profile_permissions(profile.id::text)
from public.profiles profile;
