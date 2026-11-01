-- Opiniones tras el viaje (01-11-2026).
-- Conductores y pasajeros pueden decir si el viaje se hizo y dejar un comentario opcional.
-- Solo lo lee el equipo (SQL); cada usuario ve únicamente su propia respuesta.

create table if not exists public.trip_feedback (
  id bigint generated always as identity primary key,
  trip_id uuid references public.trips(id) on delete set null,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('conductor','pasajero')),
  happened boolean not null,
  comment text check (comment is null or char_length(comment) <= 800),
  can_share boolean not null default false,
  origin_city text,
  dest_city text,
  departure_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trip_id, user_id)
);

alter table public.trip_feedback enable row level security;

create policy "feedback propio" on public.trip_feedback
  for select to authenticated using (user_id = auth.uid());

revoke all on public.trip_feedback from anon, authenticated;
grant select (trip_id, role, happened, comment, can_share, created_at) on public.trip_feedback to authenticated;

create or replace function public.send_trip_feedback(p_trip_id uuid, p_happened boolean, p_comment text default null, p_can_share boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.trips%rowtype;
  v_role text;
  v_happened boolean;
  v_comment text := nullif(btrim(coalesce(p_comment, '')), '');
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select * into t from public.trips where id = p_trip_id;
  if not found then raise exception 'El viaje ya no existe'; end if;
  if t.departure_at > now() then raise exception 'Podrás contarnos qué tal cuando llegue la hora de salida'; end if;
  if t.departure_at < now() - interval '30 days' then raise exception 'Este viaje es demasiado antiguo'; end if;

  if t.driver_id = auth.uid() then
    v_role := 'conductor';
    -- El conductor responde primero con mark_trip_done; aquí se reutiliza su respuesta.
    v_happened := coalesce(t.done, p_happened);
  elsif exists (select 1 from public.trip_members m where m.trip_id = p_trip_id and m.user_id = auth.uid()) then
    v_role := 'pasajero';
    v_happened := p_happened;
  else
    raise exception 'Solo quienes iban en el viaje pueden opinar';
  end if;

  if v_happened is null then raise exception 'Falta la respuesta'; end if;
  if v_comment is not null and char_length(v_comment) > 800 then v_comment := left(v_comment, 800); end if;

  insert into public.trip_feedback (trip_id, user_id, role, happened, comment, can_share, origin_city, dest_city, departure_at)
  values (p_trip_id, auth.uid(), v_role, v_happened, v_comment, coalesce(p_can_share, false) and v_comment is not null, t.origin_city, t.dest_city, t.departure_at)
  on conflict (trip_id, user_id) do update
    set happened = excluded.happened,
        comment = coalesce(excluded.comment, public.trip_feedback.comment),
        can_share = case when excluded.comment is not null then excluded.can_share else public.trip_feedback.can_share end,
        updated_at = now();
end $$;

revoke all on function public.send_trip_feedback(uuid, boolean, text, boolean) from public, anon;
grant execute on function public.send_trip_feedback(uuid, boolean, text, boolean) to authenticated;

-- Las opiniones se conservan como máximo 12 meses.
select cron.schedule('tehagohueco-purge-feedback', '45 4 * * *', $$delete from public.trip_feedback where created_at < now() - interval '12 months'$$);
