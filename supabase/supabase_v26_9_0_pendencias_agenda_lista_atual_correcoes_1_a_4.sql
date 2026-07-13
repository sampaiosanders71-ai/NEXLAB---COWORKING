-- NEXLAB v26.9.0 — Lista atual de Pendências e Agenda, correções 1 a 4
-- Esta migration já foi aplicada no projeto Supabase atual.
-- 1. usuario_id torna-se o proprietário canônico de Feedback; autor_id permanece como espelho legado.
-- 2. O cálculo de itens futuros é corrigido no frontend usando data e horário completos.
-- 3. Reuniões canceladas são removidas da resposta segura da Agenda.
-- 4. Projetos e campanhas encerrados deixam de ser enviados à Agenda.

begin;

update public.feedback
set
  usuario_id = coalesce(usuario_id, autor_id),
  autor_id = coalesce(usuario_id, autor_id)
where usuario_id is distinct from autor_id
   or usuario_id is null
   or autor_id is null;

alter table public.feedback
  alter column usuario_id set default auth.uid(),
  alter column usuario_id set not null,
  alter column autor_id set default auth.uid(),
  alter column autor_id set not null;

create or replace function public.nexlab_sync_feedback_owner_v2690()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  new.usuario_id := coalesce(new.usuario_id, new.autor_id, auth.uid());

  if new.usuario_id is null then
    raise exception 'O feedback precisa possuir um autor.'
      using errcode = '23502';
  end if;

  new.autor_id := new.usuario_id;
  return new;
end;
$$;

revoke all on function public.nexlab_sync_feedback_owner_v2690()
from public, anon, authenticated;

drop trigger if exists feedback_sync_owner_v2690 on public.feedback;
create trigger feedback_sync_owner_v2690
before insert or update of usuario_id, autor_id
on public.feedback
for each row
execute function public.nexlab_sync_feedback_owner_v2690();

comment on column public.feedback.usuario_id
is 'Proprietário canônico do feedback.';
comment on column public.feedback.autor_id
is 'Campo legado mantido como espelho de usuario_id para compatibilidade temporária.';

drop policy if exists "cria feedback" on public.feedback;
create policy "cria feedback" on public.feedback
for insert to public
with check (usuario_id = auth.uid());

drop policy if exists "ve feedback" on public.feedback;
create policy "ve feedback" on public.feedback
for select to public
using (usuario_id = auth.uid() or public.is_coord_or_admin());

drop policy if exists "exclui feedback" on public.feedback;
create policy "exclui feedback" on public.feedback
for delete to public
using (public.is_coord_or_admin() or usuario_id = auth.uid());

drop policy if exists feedback_pending_center_insert on public.feedback;
create policy feedback_pending_center_insert on public.feedback
for insert to authenticated
with check (
  usuario_id = (select auth.uid())
  or public.can_manage_operational_pending()
);

drop policy if exists feedback_pending_center_select on public.feedback;
create policy feedback_pending_center_select on public.feedback
for select to authenticated
using (
  usuario_id = (select auth.uid())
  or public.can_manage_operational_pending()
);

create or replace function public.nexlab_get_agenda_summary_v2690()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  current_user_id uuid := auth.uid();
  can_events boolean := false;
  can_projects boolean := false;
  can_reservations boolean := false;
  can_marketing boolean := false;
  events_result jsonb := '[]'::jsonb;
  meetings_result jsonb := '[]'::jsonb;
  reservations_result jsonb := '[]'::jsonb;
  projects_result jsonb := '[]'::jsonb;
  marketing_result jsonb := '[]'::jsonb;
  marketing_dates_result jsonb := '[]'::jsonb;
begin
  if current_user_id is null
     or not public.nexlab_has_approved_access()
     or not public.nexlab_has_effective_permission_v2680('module_agenda')
  then
    raise exception 'Você não possui acesso à Agenda.' using errcode = '42501';
  end if;

  can_events := public.nexlab_has_effective_permission_v2680('module_eventos');
  can_projects := public.nexlab_has_effective_permission_v2680('module_projetos');
  can_reservations := public.nexlab_has_effective_permission_v2680('module_reserva');
  can_marketing := public.nexlab_has_effective_permission_v2680('module_marketing');

  if can_events then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',e.id,'titulo',e.titulo,'data',e.data,'hora',e.hora,'horario',e.hora,
      'local',e.local,'vagas_limite',e.vagas_limite,'descricao',e.descricao,
      'organizador_id',e.responsavel_id,'created_at',e.created_at
    ) order by e.data,e.hora nulls last,e.id),'[]'::jsonb)
    into events_result from public.events e;
  end if;

  if can_reservations then
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',m.id,'titulo',m.titulo,'data',m.data,'hora',m.hora,'horario',m.hora,
      'local',m.local,'descricao',m.descricao,'link',m.link,'status',m.status,
      'cancelada_em',m.cancelada_em,'team_id',m.team_id,'autor_id',m.autor_id,
      'created_at',m.created_at
    )) order by m.data,m.hora nulls last,m.id),'[]'::jsonb)
    into meetings_result
    from public.meetings m
    where public.nexlab_can_view_meeting_v2690(m.id)
      and m.cancelada_em is null
      and lower(btrim(coalesce(m.status,'agendada'))) not in ('cancelada','cancelado','cancelled');

    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',r.id,'titulo',r.titulo,'finalidade',r.finalidade,'data',r.data,
      'hora_inicio',r.hora_inicio,'hora_fim',r.hora_fim,'status',r.status,
      'descricao',r.descricao,'sala_nome',r.sala_nome,'recursos',r.recursos,
      'created_at',r.created_at
    )) order by r.data,r.hora_inicio,r.id),'[]'::jsonb)
    into reservations_result from public.reservations r;
  end if;

  if can_projects then
    with visible_projects as (
      select p.id,p.nome,p.descricao,p.status,p.prioridade,p.responsavel_id,
             p.prazo,p.created_at,
             public.nexlab_can_view_project_full_v2690(p.id) as full_access
      from public.projects p
      where p.prazo is not null
        and lower(btrim(coalesce(p.status,''))) not in ('finalizado','arquivado')
        and public.nexlab_can_view_project_v2690(p.id)
    )
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',vp.id,'nome',vp.nome,
      'descricao',case when vp.full_access then vp.descricao else null end,
      'status',vp.status,'prioridade',vp.prioridade,
      'responsavel_id',case when vp.full_access then vp.responsavel_id else null end,
      'prazo',vp.prazo,'created_at',vp.created_at,
      'access_scope',case when vp.full_access then 'full' else 'task_only' end
    )) order by vp.prazo,vp.id),'[]'::jsonb)
    into projects_result from visible_projects vp;
  end if;

  if can_marketing then
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',mk.id,'titulo',mk.titulo,'descricao',mk.descricao,'tipo',mk.tipo,
      'canal',mk.canal,'status',mk.status,'data',mk.data,'link',mk.link,
      'responsavel_id',mk.responsavel_id,'created_at',mk.created_at
    )) order by mk.data nulls last,mk.id),'[]'::jsonb)
    into marketing_result
    from public.marketing mk
    where mk.data is not null
      and lower(btrim(coalesce(mk.status,'planejado'))) not in (
        'publicado','publicada','arquivado','arquivada','archived',
        'cancelado','cancelada','cancelled','encerrado','encerrada','closed',
        'finalizado','finalizada','concluido','concluida','concluído','concluída'
      );

    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',md.id,'titulo',md.titulo,'data',md.data,'tipo',md.tipo,
      'descricao',md.descricao,'autor_id',md.autor_id,'created_at',md.created_at
    )) order by md.data,md.id),'[]'::jsonb)
    into marketing_dates_result from public.marketing_dates md;
  end if;

  return jsonb_build_object(
    'ok',true,'events',events_result,'meetings',meetings_result,
    'reservations',reservations_result,'projects',projects_result,
    'marketing_campaigns',marketing_result,'marketing_dates',marketing_dates_result,
    'source_access',jsonb_build_object(
      'events',can_events,'projects',can_projects,
      'reservations',can_reservations,'marketing',can_marketing
    ),
    'generated_at',now()
  );
end;
$$;

revoke all on function public.nexlab_get_agenda_summary_v2690() from public, anon;
grant execute on function public.nexlab_get_agenda_summary_v2690() to authenticated;
comment on function public.nexlab_get_agenda_summary_v2690()
is 'Agenda segura com reuniões ativas, projetos em andamento, campanhas abertas e mascaramento por tarefa.';

commit;
