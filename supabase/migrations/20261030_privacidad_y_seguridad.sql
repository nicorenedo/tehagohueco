-- Te Hago Hueco · privacidad y avisos de seguridad (30-10-2026)
-- Ejecutar a mano en Supabase > SQL Editor. Es idempotente: se puede repetir sin problema.

-- 1) Sin sesión solo se ven las columnas públicas del viaje (sin conductor, zonas, paradas, vehículo ni descripción)
revoke select on public.trips from anon;
grant select (id, origin_city, dest_city, departure_at, flexibility, seats_total, seats_taken, cost_mode,
              contribution_eur, distance_km, status, created_at, origin_lat, origin_lng, dest_lat, dest_lng)
  on public.trips to anon;

-- 2) Los perfiles (nombre abreviado y foto) solo los ven usuarios con sesión
revoke select on public.profiles from anon;
alter policy profiles_select on public.profiles to authenticated;

-- 3) Funciones: nadie sin sesión puede llamarlas; las de los disparadores no se llaman desde fuera
revoke execute on function public.confirm_trip(uuid) from public, anon;
revoke execute on function public.remove_member(uuid, uuid) from public, anon;
revoke execute on function public.trips_after_update_notify() from public, anon, authenticated;
revoke execute on function public.trips_before_update() from public, anon, authenticated;
revoke execute on function public.reports_fill() from public, anon, authenticated;

-- 4) Tablas: quitar permisos que sobran (las políticas ya protegían, esto es una segunda capa)
revoke all on public.demand_signatures from anon;
revoke all on public.trip_private from anon;
revoke all on public.trip_removed from anon, authenticated;
revoke truncate, references, trigger on public.demand_signatures from authenticated;
revoke truncate, references, trigger on public.trip_private from authenticated;

-- 5) Los reportes cerrados se borran a los 90 días (lo promete la política de privacidad)
select cron.schedule('tehagohueco-purge-reports', '30 4 * * *',
  $$delete from public.reports where status in ('resuelto','descartado') and resolved_at < now() - interval '90 days'$$);
