-- Te Hago Hueco · Confirmación de plazas, quitar pasajeros, enlace de grupo y firmas por falta de transporte
-- Ejecutar completo en Supabase > SQL Editor > New query > Run. Se puede ejecutar más de una vez.

alter table public.trip_members add column if not exists confirmed_at timestamptz;

create table if not exists public.trip_removed (
  trip_id uuid not null references public.trips(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (trip_id, user_id)
);
alter table public.trip_removed enable row level security;

create table if not exists public.trip_private (
  trip_id uuid primary key references public.trips(id) on delete cascade,
  group_link text check (group_link is null or (group_link ~ '^https://' and char_length(group_link) <= 300)),
  updated_at timestamptz not null default now()
);
alter table public.trip_private enable row level security;
drop policy if exists trip_private_select on public.trip_private;
create policy trip_private_select on public.trip_private for select to authenticated using (public.is_trip_participant(trip_id));
drop policy if exists trip_private_insert on public.trip_private;
create policy trip_private_insert on public.trip_private for insert to authenticated
  with check (exists (select 1 from public.trips t where t.id = trip_id and t.driver_id = auth.uid()));
drop policy if exists trip_private_update on public.trip_private;
create policy trip_private_update on public.trip_private for update to authenticated
  using (exists (select 1 from public.trips t where t.id = trip_id and t.driver_id = auth.uid()))
  with check (exists (select 1 from public.trips t where t.id = trip_id and t.driver_id = auth.uid()));
grant select, insert, update on public.trip_private to authenticated;

create or replace function public.join_trip(p_trip_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.trips%rowtype; v_name text;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select * into t from public.trips where id = p_trip_id for update;
  if not found then raise exception 'El viaje no existe'; end if;
  if t.driver_id = auth.uid() then raise exception 'Eres el conductor de este viaje'; end if;
  if t.status = 'cancelado' then raise exception 'El viaje está cancelado'; end if;
  if t.departure_at < now() then raise exception 'El viaje ya ha salido'; end if;
  if exists (select 1 from public.trip_removed where trip_id = p_trip_id and user_id = auth.uid()) then
    raise exception 'El conductor te ha quitado de este viaje; busca otro';
  end if;
  if exists (select 1 from public.trip_members where trip_id = p_trip_id and user_id = auth.uid()) then
    raise exception 'Ya estás apuntado a este viaje';
  end if;
  if t.seats_taken >= t.seats_total then raise exception 'No quedan plazas libres'; end if;
  insert into public.trip_members (trip_id, user_id, confirmed_at)
    values (p_trip_id, auth.uid(), case when t.departure_at - interval '48 hours' <= now() then now() else null end);
  update public.trips set seats_taken = seats_taken + 1 where id = p_trip_id;
  select display_name into v_name from public.profiles where id = auth.uid();
  insert into public.messages (trip_id, user_id, body, is_system)
    values (p_trip_id, auth.uid(), coalesce(v_name,'Alguien') || ' se ha unido al viaje', true);
end $$;

create or replace function public.confirm_trip(p_trip_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.trips%rowtype; v_name text; v_count int;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select * into t from public.trips where id = p_trip_id;
  if not found then raise exception 'El viaje no existe'; end if;
  if t.status = 'cancelado' then raise exception 'El viaje está cancelado'; end if;
  if now() < t.departure_at - interval '48 hours' then raise exception 'Aún no se puede confirmar; podrás hacerlo 48 horas antes de la salida'; end if;
  if now() > t.departure_at then raise exception 'El viaje ya ha salido'; end if;
  update public.trip_members set confirmed_at = now()
    where trip_id = p_trip_id and user_id = auth.uid() and confirmed_at is null;
  get diagnostics v_count = row_count;
  if v_count = 0 then
    if not exists (select 1 from public.trip_members where trip_id = p_trip_id and user_id = auth.uid()) then
      raise exception 'No estás apuntado a este viaje';
    end if;
    return;
  end if;
  select display_name into v_name from public.profiles where id = auth.uid();
  insert into public.messages (trip_id, user_id, body, is_system)
    values (p_trip_id, auth.uid(), coalesce(v_name,'Alguien') || ' ha confirmado que viaja', true);
end $$;

create or replace function public.remove_member(p_trip_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text; v_deleted int;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  perform 1 from public.trips where id = p_trip_id and driver_id = auth.uid() for update;
  if not found then raise exception 'Solo el conductor puede quitar a alguien del viaje'; end if;
  delete from public.trip_members where trip_id = p_trip_id and user_id = p_user_id;
  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then raise exception 'Esa persona no está en el viaje'; end if;
  insert into public.trip_removed (trip_id, user_id) values (p_trip_id, p_user_id) on conflict do nothing;
  update public.trips set seats_taken = greatest(0, seats_taken - 1) where id = p_trip_id;
  select display_name into v_name from public.profiles where id = p_user_id;
  insert into public.messages (trip_id, user_id, body, is_system)
    values (p_trip_id, auth.uid(), 'El conductor ha quitado a ' || coalesce(v_name,'un pasajero') || ' del viaje', true);
end $$;

create or replace function public.release_unconfirmed()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if coalesce(auth.role(), '') in ('anon', 'authenticated') then raise exception 'No permitido'; end if;
  for r in
    select m.trip_id, m.user_id, p.display_name
    from public.trip_members m
    join public.trips t on t.id = m.trip_id
    left join public.profiles p on p.id = m.user_id
    where m.confirmed_at is null and t.status <> 'cancelado'
      and t.departure_at > now() and t.departure_at - interval '12 hours' <= now()
    for update of m
  loop
    delete from public.trip_members where trip_id = r.trip_id and user_id = r.user_id;
    update public.trips set seats_taken = greatest(0, seats_taken - 1) where id = r.trip_id;
    insert into public.messages (trip_id, user_id, body, is_system)
      values (r.trip_id, r.user_id, 'Se ha liberado la plaza de ' || coalesce(r.display_name,'un pasajero') || ' por no confirmar a tiempo', true);
    n := n + 1;
  end loop;
  return n;
end $$;

create table if not exists public.demand_signatures (
  user_id uuid not null references public.profiles(id) on delete cascade,
  origin_city text not null,
  dest_city text not null,
  need text not null check (need in ('puntual','semanal','diario')),
  created_at timestamptz not null default now(),
  primary key (user_id, origin_city, dest_city),
  check (origin_city <> dest_city),
  check (char_length(origin_city) <= 60 and char_length(dest_city) <= 60)
);
alter table public.demand_signatures enable row level security;
drop policy if exists demand_select_own on public.demand_signatures;
create policy demand_select_own on public.demand_signatures for select to authenticated using (user_id = auth.uid());
drop policy if exists demand_insert_own on public.demand_signatures;
create policy demand_insert_own on public.demand_signatures for insert to authenticated with check (user_id = auth.uid());
drop policy if exists demand_update_own on public.demand_signatures;
create policy demand_update_own on public.demand_signatures for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists demand_delete_own on public.demand_signatures;
create policy demand_delete_own on public.demand_signatures for delete to authenticated using (user_id = auth.uid());
grant select, insert, update, delete on public.demand_signatures to authenticated;

create or replace function public.demand_stats()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'people', (select count(distinct user_id) from public.demand_signatures),
    'signatures', (select count(*) from public.demand_signatures),
    'routes', coalesce((select json_agg(r order by r.total desc, r.origin_city, r.dest_city) from (
        select origin_city, dest_city, count(*) as total,
               count(*) filter (where need = 'diario') as diario,
               count(*) filter (where need = 'semanal') as semanal,
               count(*) filter (where need = 'puntual') as puntual
        from public.demand_signatures group by origin_city, dest_city
      ) r), '[]'::json)
  );
$$;

revoke execute on function public.confirm_trip(uuid) from public, anon;
revoke execute on function public.remove_member(uuid, uuid) from public, anon;
revoke execute on function public.release_unconfirmed() from public, anon, authenticated;
grant execute on function public.confirm_trip(uuid) to authenticated;
grant execute on function public.remove_member(uuid, uuid) to authenticated;
grant execute on function public.demand_stats() to anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'trip_private') then
    alter publication supabase_realtime add table public.trip_private;
  end if;
end $$;

-- Tareas programadas: liberar plazas sin confirmar (cada 10 min) y borrar viajes antiguos (cada noche)
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname in ('blablahelp-release-unconfirmed','blablahelp-purge-old-trips');
select cron.schedule('blablahelp-release-unconfirmed', '*/10 * * * *', 'select public.release_unconfirmed();');
select cron.schedule('blablahelp-purge-old-trips', '15 4 * * *', 'select public.purge_old_trips();');
