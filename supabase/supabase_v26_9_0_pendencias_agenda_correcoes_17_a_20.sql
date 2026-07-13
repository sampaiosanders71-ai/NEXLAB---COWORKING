-- NEXLAB v26.9.0 — Pendências e Agenda, correções 17 a 20
-- 17. Acessibilidade da Central de Pendências (frontend).
-- 18. Remove índice duplicado de Feedback.
-- 19. Centraliza a visibilidade de reuniões para todos os perfis autorizados.
-- 20. Exige permissão do módulo Reserva para consultar reuniões.

begin;

-- A chave equivalente feedback_status_created_at_idx permanece instalada.
drop index if exists public.idx_nexlab_feedback_status_created;

create or replace function public.nexlab_can_view_meeting_v2690(
  p_meeting_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select
    auth.uid() is not null
    and public.nexlab_has_approved_access()
    and public.nexlab_has_effective_permission_v2680('module_reserva')
    and exists (
      select 1
      from public.meetings m
      where m.id = p_meeting_id
        and (
          public.nexlab_is_gestor()
          or m.autor_id = auth.uid()
          or m.para_todos = true
          or (
            m.alvo_roles is not null
            and (
              select lower(p.role::text)
              from public.profiles p
              where p.id = auth.uid()
                and p.ativo is distinct from false
            ) = any(m.alvo_roles)
          )
          or (
            m.alvo_users is not null
            and auth.uid() = any(m.alvo_users)
          )
          or (
            m.team_id is not null
            and exists (
              select 1
              from public.team_members tm
              where tm.team_id = m.team_id
                and tm.user_id = auth.uid()
            )
          )
          or exists (
            select 1
            from public.meeting_participants mp
            where mp.meeting_id = m.id
              and mp.user_id = auth.uid()
          )
        )
    );
$$;

revoke all on function public.nexlab_can_view_meeting_v2690(uuid)
from public, anon;

grant execute on function public.nexlab_can_view_meeting_v2690(uuid)
to authenticated;

comment on function public.nexlab_can_view_meeting_v2690(uuid)
is 'Regra canônica de leitura de reuniões: exige conta aprovada, módulo Reserva e vínculo autorizado.';

drop policy if exists "ve avisos" on public.meetings;

create policy "ve avisos"
on public.meetings
for select
to authenticated
using (public.nexlab_can_view_meeting_v2690(id));

comment on function public.nexlab_get_agenda_summary_v2690()
is 'Agenda consolidada: carrega reuniões para qualquer perfil autorizado e respeita a permissão de cada módulo de origem.';

commit;
