-- NexLab v25.13.0 — Governança e Histórico de Exportações
-- Execute integralmente no Supabase SQL Editor após a v25.12.1.
-- Não exige alteração em Edge Functions, Secrets ou Cron.

begin;

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1. Histórico persistente de exportações
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

  if to_regclass('public.nexlab_report_exports') is null then
    execute format(
      'create table public.nexlab_report_exports (
         id uuid primary key default gen_random_uuid(),
         user_id %s not null references public.profiles(id) on delete cascade,
         scope text not null,
         file_type text not null,
         record_count integer not null default 0,
         confidential boolean not null default false,
         filters jsonb not null default ''{}''::jsonb,
         created_at timestamptz not null default now(),
         constraint nexlab_report_exports_scope_check
           check (scope in (''geral'', ''patrimonio'', ''projetos'', ''eventos'', ''usuarios'')),
         constraint nexlab_report_exports_file_type_check
           check (file_type in (''pdf'', ''xlsx'')),
         constraint nexlab_report_exports_record_count_check
           check (record_count >= 0)
       )',
      profile_id_type
    );
  end if;
end
$$;

create index if not exists nexlab_report_exports_created_idx
  on public.nexlab_report_exports (created_at desc);

create index if not exists nexlab_report_exports_user_created_idx
  on public.nexlab_report_exports (user_id, created_at desc);

create index if not exists nexlab_report_exports_scope_created_idx
  on public.nexlab_report_exports (scope, created_at desc);

-- -----------------------------------------------------------------------------
-- 2. Verificação central de acesso ao módulo de relatórios
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_can_access_reports()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select
    auth.uid() is not null
    and exists (
      select 1
      from public.profiles p
      where p.id::text = auth.uid()::text
        and coalesce(p.ativo, true)
        and coalesce(p.cadastro_completo, false)
        and (
          lower(coalesce(p.role::text, '')) in ('admin', 'administrador', 'coordenador')
          or 'module_relatorios' = any(
            coalesce(p.effective_permissions, '{}'::text[])
          )
        )
    );
$$;

revoke all on function public.nexlab_can_access_reports() from public;
grant execute on function public.nexlab_can_access_reports() to authenticated;

-- -----------------------------------------------------------------------------
-- 3. RLS: usuário vê as próprias exportações; gestores veem todas
-- -----------------------------------------------------------------------------

alter table public.nexlab_report_exports enable row level security;

revoke all on public.nexlab_report_exports from anon;
revoke insert, update, delete on public.nexlab_report_exports from authenticated;
grant select on public.nexlab_report_exports to authenticated;

drop policy if exists nexlab_report_exports_select_own_or_gestor
on public.nexlab_report_exports;

create policy nexlab_report_exports_select_own_or_gestor
on public.nexlab_report_exports
for select
to authenticated
using (
  user_id::text = auth.uid()::text
  or public.nexlab_is_gestor()
);

-- -----------------------------------------------------------------------------
-- 4. Registro seguro de uma exportação concluída
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_record_report_export(
  p_scope text,
  p_file_type text,
  p_record_count integer default 0,
  p_confidential boolean default false,
  p_filters jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  export_id uuid;
  normalized_scope text;
  normalized_type text;
  profile_id profiles.id%type;
begin
  if auth.uid() is null or not public.nexlab_can_access_reports() then
    raise exception 'Usuário sem autorização para registrar exportações.'
      using errcode = '42501';
  end if;

  normalized_scope := lower(btrim(coalesce(p_scope, '')));
  normalized_type := lower(btrim(coalesce(p_file_type, '')));

  if normalized_type = 'excel' then
    normalized_type := 'xlsx';
  end if;

  if normalized_scope not in ('geral', 'patrimonio', 'projetos', 'eventos', 'usuarios') then
    raise exception 'Escopo de relatório inválido.'
      using errcode = '22023';
  end if;

  if normalized_type not in ('pdf', 'xlsx') then
    raise exception 'Formato de relatório inválido.'
      using errcode = '22023';
  end if;

  if coalesce(p_record_count, 0) < 0 then
    raise exception 'A quantidade de registros não pode ser negativa.'
      using errcode = '22023';
  end if;

  select p.id
    into profile_id
  from public.profiles p
  where p.id::text = auth.uid()::text
    and coalesce(p.ativo, true)
  limit 1;

  if profile_id is null then
    raise exception 'Perfil ativo do NexLab não encontrado.'
      using errcode = 'P0002';
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
    profile_id,
    normalized_scope,
    normalized_type,
    coalesce(p_record_count, 0),
    coalesce(p_confidential, false),
    coalesce(p_filters, '{}'::jsonb)
  )
  returning id into export_id;

  begin
    perform public.record_security_audit(
      'report_export_recorded',
      null,
      jsonb_build_object(
        'export_id', export_id,
        'scope', normalized_scope,
        'file_type', normalized_type,
        'record_count', coalesce(p_record_count, 0),
        'confidential', coalesce(p_confidential, false),
        'filters', coalesce(p_filters, '{}'::jsonb)
      )
    );
  exception
    when undefined_function then null;
    when others then null;
  end;

  return jsonb_build_object(
    'ok', true,
    'export_id', export_id,
    'scope', normalized_scope,
    'file_type', normalized_type,
    'record_count', coalesce(p_record_count, 0),
    'confidential', coalesce(p_confidential, false)
  );
end;
$$;

revoke all on function public.nexlab_record_report_export(
  text,
  text,
  integer,
  boolean,
  jsonb
) from public;

grant execute on function public.nexlab_record_report_export(
  text,
  text,
  integer,
  boolean,
  jsonb
) to authenticated;

-- -----------------------------------------------------------------------------
-- 5. Leitura consolidada do histórico
-- -----------------------------------------------------------------------------

create or replace function public.nexlab_get_report_export_history(
  p_limit integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  safe_limit integer;
  gestor boolean;
begin
  if auth.uid() is null or not public.nexlab_can_access_reports() then
    raise exception 'Usuário sem autorização para consultar exportações.'
      using errcode = '42501';
  end if;

  safe_limit := least(greatest(coalesce(p_limit, 30), 1), 100);
  gestor := public.nexlab_is_gestor();

  return coalesce((
    select jsonb_agg(to_jsonb(history_row) order by history_row.created_at desc)
    from (
      select
        e.id,
        e.user_id,
        e.scope,
        e.file_type,
        e.record_count,
        e.confidential,
        e.filters,
        e.created_at,
        p.nome as profile_name,
        p.email as profile_email,
        p.role::text as profile_role
      from public.nexlab_report_exports e
      join public.profiles p
        on p.id = e.user_id
      where gestor
         or e.user_id::text = auth.uid()::text
      order by e.created_at desc
      limit safe_limit
    ) history_row
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.nexlab_get_report_export_history(integer)
from public;

grant execute on function public.nexlab_get_report_export_history(integer)
to authenticated;

-- -----------------------------------------------------------------------------
-- 6. Versões instaladas e recarga do schema
-- -----------------------------------------------------------------------------

update public.nexlab_app_versions
set
  release_status = 'stable',
  notes = 'Versão testada e aprovada. Matriz de permissões e correções de relatórios validadas.'
where version in ('25.12.0', '25.12.1');

insert into public.nexlab_app_versions (
  version,
  title,
  release_status,
  notes
)
values (
  '25.13.0',
  'Governança e Histórico de Exportações',
  'rc',
  'Registra exportações concluídas, exibe histórico por responsável e reforça a rastreabilidade de relatórios operacionais e confidenciais.'
)
on conflict (version) do update
set
  title = excluded.title,
  release_status = excluded.release_status,
  notes = excluded.notes,
  installed_at = now(),
  installed_by = auth.uid();

notify pgrst, 'reload schema';

commit;
