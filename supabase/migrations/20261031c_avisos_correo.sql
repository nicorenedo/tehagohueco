-- Avisos por correo (31-10-2026). Aplicada con el conector como `avisos_correo`.
-- Diseño:
--  * Esquema privado `avisos` (no expuesto por la API): cola de envíos, configuración y funciones internas.
--  * La cola se llena con disparadores y con una tarea cada 10 min; la función de Supabase `avisos-enviar`
--    la vacía, aplica límites y horario y envía con Brevo. Nadie puede pedir un envío desde la web.
--  * Preferencias por persona en public.notification_prefs, accesibles solo con RPC (sin políticas directas).
--  * Baja con un clic: token firmado (HMAC con secreto en Vault) que valida public.avisos_baja().
--  * La purga de la cola (30 días) la hace la propia función de envío.

create extension if not exists pg_net with schema extensions;

create schema if not exists avisos;

-- Configuración (una sola fila). mode: apagado | prueba (solo test_emails) | activo
create table if not exists avisos.config (
  id int primary key default 1 check (id = 1),
  mode text not null default 'prueba' check (mode in ('apagado','prueba','activo')),
  test_emails text[] not null default '{}',
  daily_cap int not null default 280,
  per_user_cap int not null default 3
);
insert into avisos.config (id, mode, test_emails) values (1, 'prueba', array['nico.renedo@gmail.com'])
  on conflict (id) do nothing;

create table if not exists avisos.outbox (
  id bigserial primary key,
  user_id uuid not null,
  kind text not null check (kind in ('cancelado','cambio','quitado','pasajeros','confirmar','sin_confirmar','alerta')),
  trip_id uuid,
  payload jsonb not null default '{}'::jsonb,
  dedupe_key text not null unique,
  urgent boolean not null default false,
  not_before timestamptz not null default now(),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz,
  attempts int not null default 0,
  status text not null default 'pendiente' check (status in ('pendiente','enviando','enviado','omitido','error')),
  last_error text,
  provider_id text
);
create index if not exists outbox_due on avisos.outbox (status, not_before);
create index if not exists outbox_user_sent on avisos.outbox (user_id, sent_at) where status = 'enviado';

create table if not exists avisos.suppressed (
  email text primary key,
  reason text,
  created_at timestamptz not null default now()
);

-- Secretos en Vault: token de baja y llamada interna de pg_cron a la función.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'avisos_hmac') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'avisos_hmac', 'Firma de enlaces de baja de avisos');
  end if;
  if not exists (select 1 from vault.secrets where name = 'avisos_cron') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'avisos_cron', 'Llamada interna pg_cron -> avisos-enviar');
  end if;
end $$;

-- Preferencias
create table if not exists public.notification_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  trip_updates boolean not null default true,
  route_alerts boolean not null default false,
  route_alerts_consent_at timestamptz,
  route_alerts_until timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.notification_prefs enable row level security;

-- Coordenadas en las firmas para emparejar por cercanía (35 km), como en la web.
alter table public.demand_signatures add column if not exists origin_lat double precision;
alter table public.demand_signatures add column if not exists origin_lng double precision;
alter table public.demand_signatures add column if not exists dest_lat double precision;
alter table public.demand_signatures add column if not exists dest_lng double precision;

-- Utilidades
create or replace function avisos.km(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns double precision language sql immutable as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(b_lat - a_lat) / 2), 2) +
    cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lng - a_lng) / 2), 2)))
$$;

create or replace function avisos.token(p_user uuid, p_grp text)
returns text language sql stable security definer set search_path = avisos, extensions as $$
  select p_user::text || '.' || p_grp || '.' || substr(encode(extensions.hmac(p_user::text || ':' || p_grp,
    (select decrypted_secret from vault.decrypted_secrets where name = 'avisos_hmac'), 'sha256'), 'hex'), 1, 32)
$$;

-- Añade a la cola. Si ya hay un aviso pendiente con la misma clave, junta los nombres en la lista indicada.
create or replace function avisos.enqueue(p_user uuid, p_kind text, p_trip uuid, p_key text, p_urgent boolean,
  p_not_before timestamptz, p_payload jsonb default '{}'::jsonb, p_list text default null, p_item text default null)
returns void language plpgsql security definer set search_path = avisos, public as $$
begin
  if p_user is null then return; end if;
  insert into avisos.outbox (user_id, kind, trip_id, dedupe_key, urgent, not_before, payload)
  values (p_user, p_kind, p_trip, p_key, p_urgent, p_not_before,
          case when p_list is null then p_payload else p_payload || jsonb_build_object(p_list, jsonb_build_array(p_item)) end)
  on conflict (dedupe_key) do update
    set payload = case when p_list is null then avisos.outbox.payload
                       else jsonb_set(avisos.outbox.payload, array[p_list],
                            coalesce(avisos.outbox.payload -> p_list, '[]'::jsonb) || to_jsonb(p_item)) end,
        urgent = avisos.outbox.urgent or excluded.urgent
    where avisos.outbox.status = 'pendiente';
end $$;

-- Disparadores -----------------------------------------------------------

-- Cancelación o cambio de fecha, hora o trayecto: a cada pasajero.
create or replace function avisos.on_trip_update() returns trigger
language plpgsql security definer set search_path = avisos, public as $$
declare m record; v_bucket text := floor(extract(epoch from now()) / 10800)::text;
begin
  if new.status = 'cancelado' and old.status <> 'cancelado' then
    for m in select user_id from public.trip_members where trip_id = new.id loop
      perform avisos.enqueue(m.user_id, 'cancelado', new.id, 'cancelado:' || new.id || ':' || m.user_id, true, now());
    end loop;
    return new;
  end if;
  if new.status <> 'cancelado' and (new.departure_at is distinct from old.departure_at
     or new.origin_city is distinct from old.origin_city or new.dest_city is distinct from old.dest_city) then
    for m in select user_id from public.trip_members where trip_id = new.id loop
      perform avisos.enqueue(m.user_id, 'cambio', new.id, 'cambio:' || new.id || ':' || m.user_id || ':' || v_bucket,
        least(new.departure_at, old.departure_at) < now() + interval '24 hours', now() + interval '10 minutes',
        jsonb_build_object('old_departure', old.departure_at, 'old_origin', old.origin_city, 'old_dest', old.dest_city));
    end loop;
  end if;
  return new;
end $$;
create trigger trips_after_update_avisos after update on public.trips
  for each row execute function avisos.on_trip_update();

-- Alguien se apunta o se va por su cuenta: al conductor, agrupado cada 3 h por viaje.
create or replace function avisos.on_member_change() returns trigger
language plpgsql security definer set search_path = avisos, public as $$
declare t public.trips%rowtype; v_user uuid; v_name text; v_list text;
begin
  if tg_op = 'INSERT' then v_user := new.user_id; v_list := 'joined';
  else
    v_user := old.user_id; v_list := 'left';
    -- Solo si se va la propia persona (no cuando el conductor la quita ni cuando se borra el viaje).
    if auth.uid() is distinct from old.user_id then return old; end if;
  end if;
  select * into t from public.trips where id = coalesce(new.trip_id, old.trip_id);
  if not found or t.status = 'cancelado' or t.departure_at < now() then return coalesce(new, old); end if;
  select display_name into v_name from public.profiles where id = v_user;
  perform avisos.enqueue(t.driver_id, 'pasajeros', t.id,
    'pasajeros:' || t.id || ':' || floor(extract(epoch from now()) / 10800)::text,
    t.departure_at < now() + interval '24 hours', now() + interval '10 minutes', '{}'::jsonb, v_list, coalesce(v_name, 'Alguien'));
  return coalesce(new, old);
end $$;
create trigger trip_members_avisos after insert or delete on public.trip_members
  for each row execute function avisos.on_member_change();

-- El conductor quita a alguien: a esa persona.
create or replace function avisos.on_removed() returns trigger
language plpgsql security definer set search_path = avisos, public as $$
declare t public.trips%rowtype;
begin
  select * into t from public.trips where id = new.trip_id;
  if not found or t.departure_at < now() then return new; end if;
  perform avisos.enqueue(new.user_id, 'quitado', new.trip_id, 'quitado:' || new.trip_id || ':' || new.user_id,
    t.departure_at < now() + interval '24 hours', now());
  return new;
end $$;
create trigger trip_removed_avisos after insert on public.trip_removed
  for each row execute function avisos.on_removed();

-- Viaje nuevo: alerta a quien pidió esa ruta (35 km) y aceptó alertas. Un resumen al día como máximo.
create or replace function avisos.on_trip_insert() returns trigger
language plpgsql security definer set search_path = avisos, public as $$
declare r record; v_day date := (now() at time zone 'Europe/Madrid')::date; v_key text; v_nb timestamptz;
begin
  if new.status <> 'abierto' or new.blocked then return new; end if;
  for r in
    select distinct p.user_id from public.notification_prefs p
    join public.demand_signatures s on s.user_id = p.user_id
    where p.route_alerts and p.route_alerts_until > now() and p.user_id <> new.driver_id
      and (lower(s.origin_city) = lower(new.origin_city)
           or (s.origin_lat is not null and new.origin_lat is not null and avisos.km(s.origin_lat, s.origin_lng, new.origin_lat, new.origin_lng) <= 35))
      and (lower(s.dest_city) = lower(new.dest_city)
           or (s.dest_lat is not null and new.dest_lat is not null and avisos.km(s.dest_lat, s.dest_lng, new.dest_lat, new.dest_lng) <= 35))
  loop
    v_key := 'alerta:' || r.user_id || ':' || v_day;
    v_nb := now() + interval '20 minutes';
    if exists (select 1 from avisos.outbox where dedupe_key = v_key and status <> 'pendiente') then
      v_key := 'alerta:' || r.user_id || ':' || (v_day + 1);
      v_nb := ((v_day + 1)::timestamp + time '09:00') at time zone 'Europe/Madrid';
    end if;
    perform avisos.enqueue(r.user_id, 'alerta', null, v_key, false, v_nb, '{}'::jsonb, 'trips', new.id::text);
  end loop;
  return new;
end $$;
create trigger trips_after_insert_avisos after insert on public.trips
  for each row execute function avisos.on_trip_insert();

-- Recordatorios y llamada a la función de envío (cada 10 min) -----------------
create or replace function avisos.tick() returns void
language plpgsql security definer set search_path = avisos, public, extensions as $$
declare m record;
begin
  -- Pasajero: confirmar (una vez, al abrirse la ventana de 48 h).
  for m in
    select tm.user_id, t.id from public.trip_members tm join public.trips t on t.id = tm.trip_id
    where tm.confirmed_at is null and t.status <> 'cancelado' and not t.blocked
      and t.departure_at between now() + interval '12 hours' and now() + interval '48 hours'
  loop
    perform avisos.enqueue(m.user_id, 'confirmar', m.id, 'confirmar:' || m.id || ':' || m.user_id, false, now());
  end loop;
  -- Conductor: gente sin confirmar (una vez, 24 h antes).
  for m in
    select t.driver_id, t.id from public.trips t
    where t.status <> 'cancelado' and not t.blocked
      and t.departure_at between now() + interval '3 hours' and now() + interval '24 hours'
      and exists (select 1 from public.trip_members tm where tm.trip_id = t.id and tm.confirmed_at is null)
  loop
    perform avisos.enqueue(m.driver_id, 'sin_confirmar', m.id, 'sin_confirmar:' || m.id, false, now());
  end loop;
  -- Despierta la función solo si hay algo que enviar.
  if (select mode from avisos.config where id = 1) <> 'apagado'
     and exists (select 1 from avisos.outbox where status = 'pendiente' and not_before <= now()) then
    perform net.http_post(
      url := 'https://dbmqyczwjuahlydbfgtm.supabase.co/functions/v1/avisos-enviar',
      headers := jsonb_build_object('Content-Type', 'application/json',
                   'x-avisos-key', (select decrypted_secret from vault.decrypted_secrets where name = 'avisos_cron')),
      body := '{}'::jsonb,
      timeout_milliseconds := 60000);
  end if;
end $$;

-- Reparto: devuelve los avisos listos para enviar ya filtrados (preferencias, límites, horario, validez).
create or replace function avisos.claim(p_limit int default 40) returns setof jsonb
language plpgsql security definer set search_path = avisos, public as $$
declare
  cfg avisos.config%rowtype; o avisos.outbox%rowtype; t public.trips%rowtype; p public.notification_prefs%rowtype;
  v_email text; v_name text; v_grp text; v_extra jsonb; v_skip text; v_n int;
  v_hour int := extract(hour from now() at time zone 'Europe/Madrid')::int;
  v_quiet boolean; v_global int;
begin
  select * into cfg from avisos.config where id = 1;
  if cfg.mode = 'apagado' then return; end if;
  v_quiet := v_hour >= 22 or v_hour < 8;
  update avisos.outbox set status = 'pendiente' where status = 'enviando' and claimed_at < now() - interval '15 minutes';
  update avisos.outbox set status = 'omitido', last_error = 'caducado' where status = 'pendiente' and created_at < now() - interval '36 hours';
  select count(*) into v_global from avisos.outbox where status = 'enviado' and sent_at > now() - interval '24 hours';

  for o in
    select * from avisos.outbox
    where status = 'pendiente' and not_before <= now() and (urgent or not v_quiet)
    order by urgent desc, created_at limit p_limit
    for update skip locked
  loop
    v_skip := null; v_extra := '{}'::jsonb; t := null;
    v_grp := case when o.kind = 'alerta' then 'alertas' else 'viajes' end;
    select email into v_email from auth.users where id = o.user_id;
    select display_name into v_name from public.profiles where id = o.user_id;
    select * into p from public.notification_prefs where user_id = o.user_id;

    if v_email is null then v_skip := 'sin cuenta';
    elsif cfg.mode = 'prueba' and not (lower(v_email) = any (cfg.test_emails)) then v_skip := 'modo prueba';
    elsif exists (select 1 from avisos.suppressed where email = lower(v_email)) then v_skip := 'bloqueado';
    elsif v_grp = 'viajes' and p.user_id is not null and not p.trip_updates then v_skip := 'desactivado';
    elsif v_grp = 'alertas' and not (coalesce(p.route_alerts, false) and p.route_alerts_until > now()) then v_skip := 'desactivado';
    end if;

    if v_skip is null and o.trip_id is not null then
      select * into t from public.trips where id = o.trip_id;
      if not found then v_skip := 'viaje borrado';
      elsif o.kind in ('cambio','pasajeros','confirmar','sin_confirmar') and (t.status = 'cancelado' or t.departure_at < now()) then v_skip := 'ya no aplica';
      elsif o.kind in ('cambio','confirmar') and not exists (select 1 from public.trip_members where trip_id = t.id and user_id = o.user_id) then v_skip := 'ya no aplica';
      elsif o.kind = 'confirmar' and exists (select 1 from public.trip_members where trip_id = t.id and user_id = o.user_id and confirmed_at is not null) then v_skip := 'ya confirmado';
      elsif o.kind = 'sin_confirmar' then
        select count(*) into v_n from public.trip_members where trip_id = t.id and confirmed_at is null;
        if v_n = 0 then v_skip := 'ya confirmado'; else v_extra := jsonb_build_object('unconfirmed', v_n); end if;
      end if;
    end if;

    if v_skip is null and o.kind = 'alerta' then
      select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'origin_city', x.origin_city, 'dest_city', x.dest_city,
               'departure_at', x.departure_at, 'free', x.seats_total - x.seats_taken, 'cost_mode', x.cost_mode) order by x.departure_at), '[]'::jsonb)
        into v_extra
        from public.trips x
        where x.id::text in (select jsonb_array_elements_text(o.payload -> 'trips'))
          and x.status = 'abierto' and not x.blocked and x.departure_at > now() and x.seats_taken < x.seats_total;
      if jsonb_array_length(v_extra) = 0 then v_skip := 'viajes ya no disponibles';
      else v_extra := jsonb_build_object('trips', v_extra, 'until', p.route_alerts_until); end if;
    end if;

    if v_skip is null and not o.urgent then
      select count(*) into v_n from avisos.outbox
        where user_id = o.user_id and status = 'enviado' and not urgent and sent_at > now() - interval '24 hours';
      if v_n >= cfg.per_user_cap then v_skip := 'límite diario por persona'; end if;
      if v_skip is null and v_global >= cfg.daily_cap then exit; end if;
    end if;

    if v_skip is not null then
      update avisos.outbox set status = 'omitido', last_error = v_skip where id = o.id;
      continue;
    end if;

    update avisos.outbox set status = 'enviando', claimed_at = now(), attempts = attempts + 1 where id = o.id;
    v_global := v_global + 1;
    return next jsonb_build_object(
      'id', o.id, 'kind', o.kind, 'urgent', o.urgent, 'email', v_email, 'name', v_name, 'grp', v_grp,
      'payload', o.payload, 'extra', v_extra, 'unsub', avisos.token(o.user_id, v_grp),
      'trip', case when t.id is null then null else jsonb_build_object('id', t.id, 'origin_city', t.origin_city,
        'dest_city', t.dest_city, 'departure_at', t.departure_at, 'seats_total', t.seats_total,
        'seats_taken', t.seats_taken, 'status', t.status) end);
  end loop;
end $$;

create or replace function avisos.mark(p_id bigint, p_ok boolean, p_error text default null, p_provider_id text default null)
returns void language plpgsql security definer set search_path = avisos as $$
begin
  if p_ok then
    update avisos.outbox set status = 'enviado', sent_at = now(), provider_id = p_provider_id, last_error = null where id = p_id;
  else
    update avisos.outbox
      set status = case when attempts >= 3 then 'error' else 'pendiente' end,
          not_before = now() + interval '10 minutes', last_error = left(p_error, 500)
      where id = p_id;
  end if;
end $$;

-- API pública -------------------------------------------------------------

create or replace function public.my_notify_prefs()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else coalesce(
    (select jsonb_build_object('trip_updates', trip_updates,
       'route_alerts', coalesce(route_alerts and route_alerts_until > now(), false), 'route_alerts_until', route_alerts_until)
     from public.notification_prefs where user_id = auth.uid()),
    jsonb_build_object('trip_updates', true, 'route_alerts', false, 'route_alerts_until', null)) end
$$;

-- null = no cambiar. Activar alertas registra el consentimiento y las mantiene 15 días.
create or replace function public.set_notify_prefs(p_trip_updates boolean default null, p_route_alerts boolean default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  insert into public.notification_prefs (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  update public.notification_prefs set
    trip_updates = coalesce(p_trip_updates, trip_updates),
    route_alerts = coalesce(p_route_alerts, route_alerts),
    route_alerts_consent_at = case when p_route_alerts then now() else route_alerts_consent_at end,
    route_alerts_until = case when p_route_alerts then now() + interval '15 days'
                              when p_route_alerts = false then null else route_alerts_until end,
    updated_at = now()
  where user_id = auth.uid();
  return public.my_notify_prefs();
end $$;

-- Baja desde el enlace del correo (sin sesión). El token lo firma el servidor.
create or replace function public.avisos_baja(p_token text)
returns text language plpgsql security definer set search_path = public, avisos as $$
declare v_parts text[] := string_to_array(coalesce(p_token, ''), '.'); v_user uuid; v_grp text;
begin
  if coalesce(array_length(v_parts, 1), 0) <> 3 or coalesce(v_parts[2], '') not in ('viajes','alertas') then raise exception 'Enlace no válido'; end if;
  begin v_user := v_parts[1]::uuid; exception when others then raise exception 'Enlace no válido'; end;
  v_grp := v_parts[2];
  if avisos.token(v_user, v_grp) <> p_token then raise exception 'Enlace no válido'; end if;
  if not exists (select 1 from auth.users where id = v_user) then return 'ok'; end if;
  insert into public.notification_prefs (user_id) values (v_user) on conflict (user_id) do nothing;
  if v_grp = 'viajes' then
    update public.notification_prefs set trip_updates = false, updated_at = now() where user_id = v_user;
  else
    update public.notification_prefs set route_alerts = false, route_alerts_until = null, updated_at = now() where user_id = v_user;
  end if;
  return 'ok';
end $$;

select cron.schedule('tehagohueco-avisos', '*/10 * * * *', 'select avisos.tick();');
