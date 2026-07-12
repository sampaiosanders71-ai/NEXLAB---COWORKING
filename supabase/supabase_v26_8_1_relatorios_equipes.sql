-- NEXLAB v26.8.1 — Indicadores e Relatórios de Equipes
-- Aplicação: Supabase Dashboard > SQL Editor > New query > Run.
-- No projeto atual, esta migration já foi aplicada pelo assistente.

begin;

alter table public.nexlab_report_exports
  drop constraint if exists nexlab_report_exports_scope_check;

alter table public.nexlab_report_exports
  add constraint nexlab_report_exports_scope_check
  check (
    scope = any (
      array[
        'geral',
        'patrimonio',
        'projetos',
        'eventos',
        'equipes',
        'usuarios'
      ]::text[]
    )
  );

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
set search_path = public, auth, extensions, pg_temp
as $$
declare
  export_id uuid;
  normalized_scope text;
  normalized_type text;
  profile_id public.profiles.id%type;
begin
  if auth.uid() is null
     or not public.nexlab_can_access_reports()
  then
    raise exception 'Usuário sem autorização para registrar exportações.'
      using errcode = '42501';
  end if;

  normalized_scope := lower(btrim(coalesce(p_scope, '')));
  normalized_type := lower(btrim(coalesce(p_file_type, '')));

  if normalized_type = 'excel' then
    normalized_type := 'xlsx';
  end if;

  if normalized_scope not in (
    'geral',
    'patrimonio',
    'projetos',
    'eventos',
    'equipes',
    'usuarios'
  ) then
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
  where p.id = auth.uid()
    and p.ativo is distinct from false
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

create or replace function public.nexlab_get_teams_report_v2681()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
  summary_data jsonb;
  teams_data jsonb;
begin
  if auth.uid() is null
     or not public.nexlab_can_access_reports()
  then
    raise exception 'Acesso não autorizado aos relatórios de equipes.'
      using errcode = '42501';
  end if;

  if not public.nexlab_has_effective_permission_v2680('module_equipes')
     or not public.nexlab_can_view_all_teams_v2680()
  then
    raise exception 'Seu perfil não possui acesso completo às equipes.'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
    'total', count(*),
    'active', count(*) filter (where t.archived_at is null),
    'archived', count(*) filter (where t.archived_at is not null),
    'without_responsible', count(*) filter (
      where t.archived_at is null and t.lider_id is null
    ),
    'unique_members', (
      select count(distinct tm.user_id)
      from public.team_members tm
    ),
    'total_links', (
      select count(*)
      from public.team_links tl
    ),
    'project_links', (
      select count(*)
      from public.team_links tl
      where tl.entity_type = 'project'
    ),
    'event_links', (
      select count(*)
      from public.team_links tl
      where tl.entity_type = 'event'
    ),
    'meeting_links', (
      select count(*)
      from public.team_links tl
      where tl.entity_type = 'meeting'
    )
  )
  into summary_data
  from public.teams t;

  select coalesce(
    jsonb_agg(team_row order by lower(team_row->>'nome')),
    '[]'::jsonb
  )
  into teams_data
  from (
    select jsonb_build_object(
      'id', t.id,
      'nome', t.nome,
      'descricao', t.descricao,
      'area', t.area,
      'status', case
        when t.archived_at is null then 'ativa'
        else 'arquivada'
      end,
      'lider_id', t.lider_id,
      'responsavel', coalesce(leader.nome, 'Não definido'),
      'archive_reason', t.archive_reason,
      'created_at', t.created_at,
      'updated_at', t.updated_at,
      'archived_at', t.archived_at,
      'members_count', coalesce(member_data.members_count, 0),
      'members', coalesce(member_data.members, '[]'::jsonb),
      'links_count', coalesce(link_data.links_count, 0),
      'project_links', coalesce(link_data.project_links, 0),
      'event_links', coalesce(link_data.event_links, 0),
      'meeting_links', coalesce(link_data.meeting_links, 0),
      'links', coalesce(link_data.links, '[]'::jsonb)
    ) as team_row
    from public.teams t
    left join public.profiles leader
      on leader.id = t.lider_id
    left join lateral (
      select
        count(*)::integer as members_count,
        jsonb_agg(
          jsonb_build_object(
            'user_id', tm.user_id,
            'nome', coalesce(p.nome, 'Usuário não encontrado'),
            'funcao', tm.funcao,
            'adicionado_em', tm.created_at
          )
          order by
            case tm.funcao
              when 'responsavel' then 1
              when 'vice_responsavel' then 2
              when 'organizador' then 3
              else 4
            end,
            lower(coalesce(p.nome, ''))
        ) as members
      from public.team_members tm
      left join public.profiles p
        on p.id = tm.user_id
      where tm.team_id = t.id
    ) member_data on true
    left join lateral (
      select
        count(*)::integer as links_count,
        count(*) filter (where tl.entity_type = 'project')::integer
          as project_links,
        count(*) filter (where tl.entity_type = 'event')::integer
          as event_links,
        count(*) filter (where tl.entity_type = 'meeting')::integer
          as meeting_links,
        jsonb_agg(
          jsonb_build_object(
            'entity_type', tl.entity_type,
            'entity_id', tl.entity_id,
            'label', case tl.entity_type
              when 'project' then coalesce(pr.nome, 'Projeto não encontrado')
              when 'event' then coalesce(ev.titulo, 'Evento não encontrado')
              when 'meeting' then coalesce(mt.titulo, 'Reunião não encontrada')
              else 'Registro vinculado'
            end,
            'subtitle', case tl.entity_type
              when 'project' then coalesce(pr.status, 'Sem status')
              when 'event' then coalesce(to_char(ev.data, 'DD/MM/YYYY'), 'Sem data')
              when 'meeting' then coalesce(to_char(mt.data, 'DD/MM/YYYY'), 'Sem data')
              else null
            end,
            'created_at', tl.created_at
          )
          order by tl.entity_type, tl.created_at
        ) as links
      from public.team_links tl
      left join public.projects pr
        on tl.entity_type = 'project'
       and pr.id = tl.entity_id
      left join public.events ev
        on tl.entity_type = 'event'
       and ev.id = tl.entity_id
      left join public.meetings mt
        on tl.entity_type = 'meeting'
       and mt.id = tl.entity_id
      where tl.team_id = t.id
    ) link_data on true
  ) report_rows;

  return jsonb_build_object(
    'summary', coalesce(summary_data, '{}'::jsonb),
    'teams', coalesce(teams_data, '[]'::jsonb),
    'generated_at', now()
  );
end;
$$;

revoke all on function public.nexlab_get_teams_report_v2681()
  from public, anon;
grant execute on function public.nexlab_get_teams_report_v2681()
  to authenticated;

revoke all on function public.nexlab_record_report_export(
  text,
  text,
  integer,
  boolean,
  jsonb
) from public, anon;
grant execute on function public.nexlab_record_report_export(
  text,
  text,
  integer,
  boolean,
  jsonb
) to authenticated;

comment on function public.nexlab_get_teams_report_v2681()
is 'Retorna resumo, integrantes, funções e vínculos para relatórios PDF/XLSX de equipes.';

commit;
