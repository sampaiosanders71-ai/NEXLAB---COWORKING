-- NEXLAB v25.17.8 — Permitir apagar notificações próprias
-- Execute no Supabase SQL Editor.
-- Escopo: somente notificações do usuário autenticado.
-- Não altera login, permissões gerais, Marketing, Agenda ou notificações por e-mail.

create or replace function public.delete_user_notifications(p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado.';
  end if;

  if p_ids is null or array_length(p_ids, 1) is null then
    return 0;
  end if;

  delete from public.notification_deliveries d
  using public.notifications n
  where d.notification_id = n.id
    and n.recipient_id = auth.uid()
    and n.id = any(p_ids);

  delete from public.notifications n
  where n.recipient_id = auth.uid()
    and n.id = any(p_ids);

  get diagnostics v_deleted = row_count;
  return coalesce(v_deleted, 0);
end;
$$;

grant execute on function public.delete_user_notifications(uuid[]) to authenticated;
