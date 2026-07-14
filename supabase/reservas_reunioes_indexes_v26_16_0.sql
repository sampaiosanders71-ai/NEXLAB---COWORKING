-- NEXLAB v26.16.0 — Índices de apoio para cancelamento e arquivamento
create index if not exists reservations_cancelled_by_idx on public.reservations(cancelled_by) where cancelled_by is not null;
create index if not exists reservations_archived_by_idx on public.reservations(archived_by) where archived_by is not null;
create index if not exists meetings_cancelled_by_idx on public.meetings(cancelled_by) where cancelled_by is not null;
create index if not exists meetings_archived_by_idx on public.meetings(archived_by) where archived_by is not null;
