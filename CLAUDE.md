# Te Hago Hueco

Web solidaria sin ánimo de lucro para compartir coche Madrid–Andalucía mientras la alta velocidad está interrumpida (accidente de Urda, 28-10-2026).

## Archivos
- `og.png`: imagen de vista previa para redes (1200×630). Se regenera con la plantilla de diseño fuera del repositorio si cambia el nombre o el lema.
- `index.html`: toda la aplicación (HTML, CSS y JS, sin build). Configuración en `window.CAMINO_CONFIG` al principio del archivo. Sin `supabaseUrl` y `supabaseAnonKey` funciona en modo demostración.
- `api/publico.js`: función de Vercel que sirve viajes próximos y `demand_stats` con caché de CDN (15 s, 2 min stale). La portada lee de aquí; tras cualquier cambio del usuario el cliente consulta Supabase directamente 90 s (`touchPublic`). Leaflet y `municipios.json` se cargan solo cuando hacen falta; realtime solo con sesión iniciada.
- Mapa: con `cartoKey` en `CAMINO_CONFIG` usa CARTO (exige clave gratuita desde agosto de 2026); sin clave, OpenStreetMap en gris.
- Navegación: barra superior siempre visible (en la portada aparece al pasar el héroe) y barra inferior fija en móvil. `#/buscar` lleva al buscador.
- `schema.sql`: Postgres para Supabase (tablas, RLS, RPC `join_trip`/`leave_trip`/`delete_own_account`, realtime). Idempotente.
- `SETUP.md`: guía de despliegue paso a paso (Supabase, Google OAuth, hosting, dominio, legal).
- `.taste-skill/`: archivos de trabajo del proceso de diseño. No desplegar.

## Reglas del proyecto
- Español con tildes correctas. Sin guiones largos en la prosa.
- Una sola tipografía (Switzer, Fontshare). Paleta: fondo hueso `#e9e3d8`, tinta `#1f1917`, campo azul pizarra `#2f4a58`, acento mostaza `#e0a912`. Sin degradados, sin sombras en reposo, sin líneas finas como separadores.
- Localidades: `municipios.json` (8.132 municipios del INE, paquete `spanish-cities-info`, licencia ISC) se carga bajo demanda; las ciudades de `CITIES` en `index.html` tienen coordenadas de núcleo urbano y se priorizan. Los viajes guardan `origin_lat/lng` y `dest_lat/lng`; la búsqueda filtra por distancia (35 km con "Incluir a 35 km").
- El routing es por hash (`#/publicar`, `#/viaje/:id`), así que cualquier hosting estático sirve sin reglas de reescritura.
- Sin precios: cada viaje es `gratis` o `compartir` ("a pachas"); el reparto se acuerda en el grupo. `contribution_eur` siempre es 0.
- Vercel: proyecto `tehagohueco` vinculado al repositorio; cada push a `main` publica en https://www.tehagohueco.es
- Para hacer push desde el entorno de Claude, usa el remoto `https://github.com/nicorenedo/blablahelp` (GitHub redirige al repositorio renombrado `tehagohueco`; la URL nueva devuelve 403 por los permisos de la app).
- Privacidad: sin sesión solo columnas públicas de `trips` (`PUBLIC_COLS`); nombre, foto, zonas, paradas, vehículo y descripción solo con sesión.
- Reportes: tabla `reports` (solo inserción desde la web). Revisar con SQL a petición de Nico: `select * from reports where status='abierto' order by created_at`.
- Nunca guardar teléfonos. Nunca poner la clave `service_role` en el frontend.
- Antes de dar por buena una edición visual: servir con `python3 -m http.server 8080` y revisar a 1440 y 390 px.

## Estado
- Supabase: proyecto de Supabase llamado `BlaBlaHelp` (nombre interno; ref `dbmqyczwjuahlydbfgtm`, eu-west-1). Esquema aplicado como migraciones `blablahelp_initial_schema`, `harden_function_privileges` y `trip_editing_and_no_prices`, `p1_tables_confirm_private_demand`, `p2_join_confirm_stats`, `p4_realtime_private`, `trip_coordinates` y el SQL manual `supabase/migrations/20261029b_quitar_y_liberar.sql`; migración `reports` aplicada y SQL manual `supabase/migrations/20261030_privacidad_y_seguridad.sql` ejecutado el 30-10 (permisos por columna para anon, perfiles solo con sesión, avisos de seguridad, cron `tehagohueco-purge-reports`). Las migraciones que contienen borrados (`delete`) hay que ejecutarlas a mano en el SQL Editor: el conector pide una confirmación que falla. URL y clave publicable ya están en `CAMINO_CONFIG`.
- Google OAuth activo y publicado. Antes se llamaba BlaBlaHelp y vivía en blablahelp.vercel.app; ese dominio y tehagohueco.vercel.app redirigen con 308 a https://www.tehagohueco.es (reglas en `vercel.json`). Dominio comprado en OVH; DNS: A @ 216.198.79.1 y CNAME www 9e943dbbd4a32f64.vercel-dns-017.com. No usar el nombre antiguo en ningún sitio. Site URL y Redirect URLs deben apuntar a https://www.tehagohueco.es

## Despliegue
1. Supabase: activar Google en Authentication > Providers, configurar Site URL y Redirect URLs con el dominio final.
2. Google Cloud: cliente OAuth web con redirect `https://<proyecto>.supabase.co/auth/v1/callback`.
3. `CAMINO_CONFIG` ya apunta al proyecto; `contactEmail` es `tehagohueco.contacto@gmail.com`.
4. Vercel: importar este repositorio (framework "Other", sin build). Conectar el dominio y volver al paso 1 con la URL definitiva.
