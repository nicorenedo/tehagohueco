-- Te Hago Hueco · Parte final: quitar pasajeros y liberar plazas sin confirmar
-- Pegar completo en Supabase > SQL Editor > New query > Run.
-- Si pregunta por operaciones destructivas, confirmar: solo crea dos funciones y una tarea programada.

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

grant execute on function public.remove_member(uuid, uuid) to authenticated;
revoke execute on function public.release_unconfirmed() from public, anon, authenticated;

create extension if not exists pg_cron;
select cron.schedule('blablahelp-release-unconfirmed', '*/10 * * * *', 'select public.release_unconfirmed();');
select cron.schedule('blablahelp-purge-old-trips', '15 4 * * *', 'select public.purge_old_trips();');
