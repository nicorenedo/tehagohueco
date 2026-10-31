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
- Reportes: tabla `reports` (solo inserción desde la web). Motivo `seguridad` (conducción peligrosa o accidente) = urgente; si la restricción aún no lo admite, el cliente lo guarda como `conducta` con el texto marcado. Revisar con SQL a petición de Nico: `select * from reports where status='abierto' order by created_at`.
- Protecciones (migración `no_autorelease_and_abuse_limits`, 31-10): las plazas sin confirmar ya NO se liberan solas (`release_unconfirmed()` devuelve 0; decide el conductor y puede quitar a quien no responda). `trips.blocked`: si más de 7 personas distintas reportan un viaje (reportes abiertos o revisados), un trigger lo bloquea; deja de verse en la búsqueda y nadie puede apuntarse; solo lo ve su conductor, con un aviso de "en revisión". El umbral NO se muestra en la web. Desbloquear: `update trips set blocked=false where id='…'`. Límites: 5 viajes por conductor cada 24 h y 10 mensajes por minuto por usuario.
- Revisión diaria de reportes: tarea programada (create_trigger) a las 8:58 hora de Madrid; solo lee y avisa, nunca actúa sola.
- Web: botón Compartir en la página del viaje (navigator.share, si no hay, WhatsApp o copiar enlace); "Publica la vuelta" (`#/publicar?vuelta=ID`, copia el viaje al revés y deja la fecha vacía); aviso numérico en "Mis viajes" con viajes por confirmar.
- Avisos por correo (migración `avisos_correo`, 31-10): Resend (dominio tehagohueco.es en región eu-west-1, DKIM `resend._domainkey` y CNAME `send`/`rsend` en OVH; remitente avisos@tehagohueco.es; respuestas a tehagohueco.contacto@gmail.com; plan gratuito, 100 al día, tope en `daily_cap` 95; sin seguimiento de aperturas ni clics). Brevo se probó y se descartó porque su plan gratuito no deja quitar el seguimiento; sus registros DNS siguen en OVH sin uso. Esquema privado `avisos` (no expuesto): `outbox` (cola con clave única anti duplicados), `config` (mode `apagado|prueba|activo`, `test_emails`, `daily_cap` 95, `per_user_cap` 3), `suppressed`. Disparadores en trips, trip_members y trip_removed; `avisos.tick()` cada 10 min (cron `tehagohueco-avisos`) crea recordatorios y despierta la función `avisos-enviar` (Supabase, verify_jwt false, autentica con el secreto `avisos_cron` de Vault; clave `RESEND_API_KEY` en los secretos de funciones; idempotency-key por aviso). Reglas en `avisos.claim()`: preferencias, horario silencioso 22-8 (salvo urgentes), máx. 3 al día por persona, caducidad 36 h. Preferencias en `public.notification_prefs` solo vía RPC `my_notify_prefs`/`set_notify_prefs`; alertas de ruta con consentimiento explícito y 15 días. Baja: `/api/baja?t=…` (Vercel) llama a `avisos_baja(token)`, token HMAC con el secreto `avisos_hmac`. Código de la función en `supabase/functions/avisos-enviar/`. Cambiar modo: `update avisos.config set mode='activo'`. Ver envíos: `select kind,status,last_error,created_at from avisos.outbox order by id desc limit 50`.
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
