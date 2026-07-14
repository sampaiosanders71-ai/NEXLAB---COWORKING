-- NEXLAB v26.16.0 — Realtime dedicado ao núcleo unificado
alter table public.spaces replica identity full;
alter table public.bookings replica identity full;
alter table public.booking_participants replica identity full;
alter table public.booking_resources replica identity full;
alter table public.booking_history replica identity full;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='spaces') then
    alter publication supabase_realtime add table public.spaces;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='bookings') then
    alter publication supabase_realtime add table public.bookings;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='booking_participants') then
    alter publication supabase_realtime add table public.booking_participants;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='booking_resources') then
    alter publication supabase_realtime add table public.booking_resources;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='booking_history') then
    alter publication supabase_realtime add table public.booking_history;
  end if;
end $$;
