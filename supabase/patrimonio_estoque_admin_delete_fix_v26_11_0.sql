-- NEXLAB v26.11.0 — ajuste de autorização da exclusão permanente no Estoque
create or replace function public.nexlab_delete_stock_item_v26110(p_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  current_item public.stock_items%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Autenticação obrigatória.' using errcode = '42501';
  end if;
  if not public.nexlab_is_admin() then
    raise exception 'Somente Administradores podem excluir itens de estoque permanentemente.' using errcode = '42501';
  end if;
  select * into current_item
  from public.stock_items s where s.id=p_item_id for update;
  if current_item.id is null then
    raise exception 'Item de estoque não encontrado.' using errcode = 'P0002';
  end if;
  delete from public.stock_items where id=p_item_id;
  perform public.record_security_audit(
    'stock_item_deleted', null::text,
    jsonb_build_object(
      'entity_id',current_item.id,
      'entity_name',current_item.nome,
      'module','estoque',
      'quantity',current_item.quantidade
    )
  );
  return jsonb_build_object('ok',true,'deleted',true,'item_id',current_item.id);
end;
$function$;

revoke execute on function public.nexlab_delete_stock_item_v26110(uuid)
from public, anon;
grant execute on function public.nexlab_delete_stock_item_v26110(uuid)
to authenticated, service_role;
