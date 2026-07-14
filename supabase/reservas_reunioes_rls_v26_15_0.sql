-- NEXLAB v26.15.0 — RLS e privilégios de Reservas e Reuniões
-- Já aplicado ao projeto Nexlab. Não executar novamente no mesmo projeto.

alter table public.reservations enable row level security;
alter table public.meetings enable row level security;
alter table public.reservation_participants enable row level security;
alter table public.meeting_participants enable row level security;

drop policy if exists "edita reservas" on public.reservations;
drop policy if exists "exclui reservas" on public.reservations;
drop policy if exists "todos criam reservas" on public.reservations;
drop policy if exists "todos veem reservas" on public.reservations;
drop policy if exists reservations_pending_center_insert on public.reservations;
drop policy if exists reservations_pending_center_select on public.reservations;
drop policy if exists reservations_pending_center_update on public.reservations;
drop policy if exists nexlab_approved_account_gate on public.reservations;
drop policy if exists reservations_v26150_approved_gate on public.reservations;
drop policy if exists reservations_v26150_select on public.reservations;
create policy reservations_v26150_approved_gate on public.reservations as restrictive for all to authenticated using (public.nexlab_has_approved_access()) with check (public.nexlab_has_approved_access());
create policy reservations_v26150_select on public.reservations for select to authenticated using (public.nexlab_has_effective_permission_v2680('module_reserva'));

drop policy if exists "cria avisos" on public.meetings;
drop policy if exists "edita avisos" on public.meetings;
drop policy if exists "exclui avisos" on public.meetings;
drop policy if exists meetings_v256_insert on public.meetings;
drop policy if exists meetings_v256_update on public.meetings;
drop policy if exists "ve avisos" on public.meetings;
drop policy if exists nexlab_approved_account_gate on public.meetings;
drop policy if exists meetings_v26150_approved_gate on public.meetings;
drop policy if exists meetings_v26150_select on public.meetings;
create policy meetings_v26150_approved_gate on public.meetings as restrictive for all to authenticated using (public.nexlab_has_approved_access()) with check (public.nexlab_has_approved_access());
create policy meetings_v26150_select on public.meetings for select to authenticated using (public.nexlab_can_view_meeting_v2690(id));

drop policy if exists reservation_participants_select on public.reservation_participants;
drop policy if exists reservation_participants_insert on public.reservation_participants;
drop policy if exists reservation_participants_delete on public.reservation_participants;
drop policy if exists nexlab_approved_account_gate on public.reservation_participants;
drop policy if exists reservation_participants_v26150_gate on public.reservation_participants;
drop policy if exists reservation_participants_v26150_select on public.reservation_participants;
create policy reservation_participants_v26150_gate on public.reservation_participants as restrictive for all to authenticated using (public.nexlab_has_approved_access()) with check (public.nexlab_has_approved_access());
create policy reservation_participants_v26150_select on public.reservation_participants for select to authenticated using (public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or user_id=auth.uid() or exists(select 1 from public.reservations r where r.id=reservation_id and r.usuario_id=auth.uid())));

drop policy if exists meeting_participants_select on public.meeting_participants;
drop policy if exists meeting_participants_insert on public.meeting_participants;
drop policy if exists meeting_participants_delete on public.meeting_participants;
drop policy if exists nexlab_approved_account_gate on public.meeting_participants;
drop policy if exists meeting_participants_v26150_gate on public.meeting_participants;
drop policy if exists meeting_participants_v26150_select on public.meeting_participants;
create policy meeting_participants_v26150_gate on public.meeting_participants as restrictive for all to authenticated using (public.nexlab_has_approved_access()) with check (public.nexlab_has_approved_access());
create policy meeting_participants_v26150_select on public.meeting_participants for select to authenticated using (public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or user_id=auth.uid() or exists(select 1 from public.meetings m where m.id=meeting_id and m.autor_id=auth.uid())));

-- Tabelas do núcleo unificado.
drop policy if exists spaces_v26150_select on public.spaces;
create policy spaces_v26150_select on public.spaces for select to authenticated using (public.nexlab_has_approved_access() and public.nexlab_has_effective_permission_v2680('module_reserva'));
drop policy if exists bookings_v26150_select on public.bookings;
create policy bookings_v26150_select on public.bookings for select to authenticated using (public.nexlab_has_approved_access() and public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or responsavel_id=auth.uid()));
drop policy if exists booking_participants_v26150_select on public.booking_participants;
create policy booking_participants_v26150_select on public.booking_participants for select to authenticated using (public.nexlab_has_approved_access() and public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or user_id=auth.uid() or exists(select 1 from public.bookings b where b.id=booking_id and b.responsavel_id=auth.uid())));
drop policy if exists booking_resources_v26150_select on public.booking_resources;
create policy booking_resources_v26150_select on public.booking_resources for select to authenticated using (exists(select 1 from public.bookings b where b.id=booking_id and public.nexlab_has_approved_access() and public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or b.responsavel_id=auth.uid())));
drop policy if exists booking_history_v26150_select on public.booking_history;
create policy booking_history_v26150_select on public.booking_history for select to authenticated using (exists(select 1 from public.bookings b where b.id=booking_id and public.nexlab_has_approved_access() and public.nexlab_has_effective_permission_v2680('module_reserva') and (public.nexlab_is_gestor() or b.responsavel_id=auth.uid())));

revoke all on public.reservations,public.meetings,public.reservation_participants,public.meeting_participants from anon;
revoke insert,update,delete,truncate,references,trigger on public.reservations,public.meetings,public.reservation_participants,public.meeting_participants from authenticated;
grant select on public.reservations,public.meetings,public.reservation_participants,public.meeting_participants to authenticated;

revoke all on public.spaces,public.bookings,public.booking_participants,public.booking_resources,public.booking_history from anon;
revoke insert,update,delete,truncate,references,trigger on public.spaces,public.bookings,public.booking_participants,public.booking_resources,public.booking_history from authenticated;
grant select on public.spaces,public.bookings,public.booking_participants,public.booking_resources,public.booking_history to authenticated;

revoke all on function public.replace_reservation_participants(text,text[]) from public,anon,authenticated;
revoke all on function public.replace_meeting_participants(text,text[]) from public,anon,authenticated;
revoke all on function public.cancel_reservation_secure(uuid) from public,anon,authenticated;
revoke all on function public.nexlab_review_reservation_v2690(uuid,text,text,text) from public,anon,authenticated;
revoke all on function public.notifications_reservation_trigger() from public,anon,authenticated;
revoke all on function public.prevent_reservation_time_conflict() from public,anon,authenticated;
revoke all on function public.nexlab_sync_reservation_owner_v2690() from public,anon,authenticated;
grant execute on function public.cancel_reservation_secure(uuid) to service_role;
grant execute on function public.nexlab_review_reservation_v2690(uuid,text,text,text) to service_role;
