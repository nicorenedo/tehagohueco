-- ============================================================
-- BlaBlaHelp · Esquema de base de datos para Supabase
-- Ejecutar completo en: Supabase > SQL Editor > New query > Run
-- Es idempotente: puede volver a ejecutarse sin romper nada.
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 1. PERFILES (una fila por usuario, creada automáticamente)
--    Solo guardamos lo mínimo. El correo se queda en auth.users.
-- ------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  display_name text not null default 'Viajero',
  avatar_url text,
  created_at timestamptz not null default now()
);

-- Nombre de pila + inicial del apellido: "Lucía G."
create or replace function public.short_name(p_full text)
returns text language sql immutable as $$
  select case
    when p_full is null or btrim(p_full) = '' then 'Viajero'
    when array_length(regexp_split_to_array(btrim(p_full), '\s+'), 1) > 1
      then (regexp_split_to_array(btrim(p_full), '\s+'))[1] || ' ' ||
           upper(left((regexp_split_to_array(btrim(p_full), '\s+'))[2], 1)) || '.'
    else btrim(p_full)
  end
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  v_name := coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(new.email, '@', 1));
  insert into public.profiles (id, full_name, display_name, avatar_url)
  values (new.id, v_name, public.short_name(v_name), new.raw_user_meta_data->>'avatar_url')
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- ------------------------------------------------------------
-- 2. VIAJES
-- ------------------------------------------------------------
create table if not exists public.trips (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.profiles(id) on delete cascade,
  origin_city text not null,
  origin_detail text,
  dest_city text not null,
  dest_detail text,
  stops text,
  departure_at timestamptz not null,
  flexibility text,
  seats_total int not null check (seats_total between 1 and 6),
  seats_taken int not null default 0 check (seats_taken >= 0),
  vehicle text,
  cost_mode text not null default 'compartir' check (cost_mode in ('gratis','compartir')),
  contribution_eur numeric(6,2) not null default 0 check (contribution_eur >= 0),
  distance_km int not null default 0 check (distance_km >= 0),
  description text not null,
  status text not null default 'abierto' check (status in ('abierto','completo','cancelado')),
  created_at timestamptz not null default now(),
  constraint trips_distinct_cities check (origin_city <> dest_city),
  constraint trips_seats_consistent check (seats_taken <= seats_total),
  constraint trips_description_len check (char_length(description) between 20 and 600),
  -- Tope de seguridad anti-lucro: nunca más de 0,07 €/km por pasajero
  -- (el cálculo fino por plazas, consumo y precio se hace en la web).
  constraint trips_contribution_cap check (
    cost_mode = 'gratis' and contribution_eur = 0
    or cost_mode = 'compartir' and contribution_eur <= greatest(3, distance_km * 0.07)
  )
);
create index if not exists trips_departure_idx on public.trips (departure_at);
create index if not exists trips_route_idx on public.trips (origin_city, dest_city, departure_at);
create index if not exists trips_driver_idx on public.trips (driver_id);

-- ------------------------------------------------------------
-- 3. PASAJEROS APUNTADOS
-- ------------------------------------------------------------
create table if not exists public.trip_members (
  trip_id uuid not null references public.trips(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (trip_id, user_id)
);
create index if not exists trip_members_user_idx on public.trip_members (user_id);

-- ------------------------------------------------------------
-- 4. MENSAJES DEL GRUPO
-- ------------------------------------------------------------
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  body text not null check (char_length(body) between 1 and 600),
  is_system boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists messages_trip_idx on public.messages (trip_id, created_at);

-- ------------------------------------------------------------
-- 5. FUNCIONES AUXILIARES
-- ------------------------------------------------------------
create or replace function public.is_trip_participant(p_trip_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.trips t where t.id = p_trip_id and t.driver_id = auth.uid())
      or exists (select 1 from public.trip_members m where m.trip_id = p_trip_id and m.user_id = auth.uid());
$$;

-- Apuntarse a un viaje de forma atómica (bloquea la fila para evitar sobreventa)
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
  if exists (select 1 from public.trip_members where trip_id = p_trip_id and user_id = auth.uid()) then
    raise exception 'Ya estás apuntado a este viaje';
  end if;
  if t.seats_taken >= t.seats_total then raise exception 'No quedan plazas libres'; end if;

  insert into public.trip_members (trip_id, user_id) values (p_trip_id, auth.uid());
  update public.trips set seats_taken = seats_taken + 1,
    status = case when seats_taken + 1 >= seats_total then 'completo' else 'abierto' end
    where id = p_trip_id;
  select display_name into v_name from public.profiles where id = auth.uid();
  insert into public.messages (trip_id, user_id, body, is_system)
    values (p_trip_id, auth.uid(), coalesce(v_name,'Alguien') || ' se ha unido al viaje', true);
end $$;

-- Dejar un viaje (libera la plaza y reabre si estaba completo)
create or replace function public.leave_trip(p_trip_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text; v_deleted int;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  perform 1 from public.trips where id = p_trip_id for update;
  delete from public.trip_members where trip_id = p_trip_id and user_id = auth.uid();
  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then raise exception 'No estabas apuntado a este viaje'; end if;
  update public.trips set seats_taken = greatest(0, seats_taken - 1),
    status = case when status = 'cancelado' then 'cancelado' else 'abierto' end
    where id = p_trip_id;
  select display_name into v_name from public.profiles where id = auth.uid();
  insert into public.messages (trip_id, user_id, body, is_system)
    values (p_trip_id, auth.uid(), coalesce(v_name,'Alguien') || ' ha dejado el viaje', true);
end $$;

-- Borrado de cuenta (RGPD): elimina al usuario y, en cascada, todo lo suyo
create or replace function public.delete_own_account()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  -- Libera plazas en los viajes donde iba de pasajero
  update public.trips t set seats_taken = greatest(0, seats_taken - 1),
    status = case when status = 'cancelado' then 'cancelado' else 'abierto' end
    where t.id in (select trip_id from public.trip_members where user_id = auth.uid());
  delete from auth.users where id = auth.uid();
end $$;

-- Limpieza: borra viajes 30 días después de su salida (ejecutar con pg_cron o manualmente)
create or replace function public.purge_old_trips()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.trips where departure_at < now() - interval '30 days';
  get diagnostics n = row_count; return n;
end $$;

-- ------------------------------------------------------------
-- 6. SEGURIDAD A NIVEL DE FILA (RLS)
-- ------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.trips enable row level security;
alter table public.trip_members enable row level security;
alter table public.messages enable row level security;

-- profiles: cualquiera autenticado puede ver nombre abreviado y avatar (necesario para listar viajes);
-- los anónimos también, porque la búsqueda es pública. Solo el dueño edita.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select using (true);
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- Vista pública de perfiles sin full_name (por si se consulta directamente)
revoke all on public.profiles from anon, authenticated;
grant select (id, display_name, avatar_url, created_at) on public.profiles to anon, authenticated;
grant update (display_name) on public.profiles to authenticated;

-- trips: lectura pública; crear solo el propio; editar/cancelar solo el conductor
drop policy if exists trips_select on public.trips;
create policy trips_select on public.trips for select using (true);
drop policy if exists trips_insert_own on public.trips;
create policy trips_insert_own on public.trips for insert to authenticated with check (auth.uid() = driver_id and departure_at > now());
drop policy if exists trips_update_own on public.trips;
create policy trips_update_own on public.trips for update to authenticated using (auth.uid() = driver_id) with check (auth.uid() = driver_id);
drop policy if exists trips_delete_own on public.trips;
create policy trips_delete_own on public.trips for delete to authenticated using (auth.uid() = driver_id);
-- El conductor no puede manipular seats_taken desde el cliente
revoke all on public.trips from anon, authenticated;
grant select on public.trips to anon, authenticated;
grant insert (driver_id, origin_city, origin_detail, dest_city, dest_detail, stops, departure_at, flexibility, seats_total, vehicle, cost_mode, contribution_eur, distance_km, description) on public.trips to authenticated;
grant update (origin_detail, dest_detail, stops, flexibility, vehicle, description, status) on public.trips to authenticated;
grant delete on public.trips to authenticated;

-- trip_members: solo participantes del viaje ven la lista; altas y bajas únicamente vía RPC
drop policy if exists members_select_participants on public.trip_members;
create policy members_select_participants on public.trip_members for select to authenticated using (public.is_trip_participant(trip_id));
revoke all on public.trip_members from anon, authenticated;
grant select on public.trip_members to authenticated;

-- messages: solo participantes leen y escriben; los mensajes de sistema solo los crea el servidor
drop policy if exists messages_select_participants on public.messages;
create policy messages_select_participants on public.messages for select to authenticated using (public.is_trip_participant(trip_id));
drop policy if exists messages_insert_participants on public.messages;
create policy messages_insert_participants on public.messages for insert to authenticated
  with check (auth.uid() = user_id and is_system = false and public.is_trip_participant(trip_id)
              and exists (select 1 from public.trips t where t.id = trip_id and t.status <> 'cancelado'));
revoke all on public.messages from anon, authenticated;
grant select on public.messages to authenticated;
grant insert (trip_id, user_id, body) on public.messages to authenticated;

-- Permisos de ejecución de las funciones
revoke all on function public.join_trip(uuid) from public;
revoke all on function public.leave_trip(uuid) from public;
revoke all on function public.delete_own_account() from public;
revoke all on function public.purge_old_trips() from public;
grant execute on function public.join_trip(uuid) to authenticated;
grant execute on function public.leave_trip(uuid) to authenticated;
grant execute on function public.delete_own_account() to authenticated;
grant execute on function public.is_trip_participant(uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 7. TIEMPO REAL (chat y plazas se actualizan sin recargar)
-- ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'trip_members') then
    alter publication supabase_realtime add table public.trip_members;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'trips') then
    alter publication supabase_realtime add table public.trips;
  end if;
end $$;

-- ------------------------------------------------------------
-- 8. LIMPIEZA AUTOMÁTICA (opcional; requiere la extensión pg_cron,
--    activable en Database > Extensions). Si no la activas, ejecuta
--    "select public.purge_old_trips();" de vez en cuando.
-- ------------------------------------------------------------
-- create extension if not exists pg_cron;
-- select cron.schedule('purge-old-trips', '0 4 * * *', $$select public.purge_old_trips();$$);
