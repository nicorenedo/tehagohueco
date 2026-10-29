# BlaBlaHelp

Web solidaria sin ánimo de lucro para compartir coche Madrid–Andalucía mientras la alta velocidad está interrumpida (accidente de Urda, 28-10-2026).

## Archivos
- `index.html`: toda la aplicación (HTML, CSS y JS, sin build). Configuración en `window.CAMINO_CONFIG` al principio del archivo. Sin `supabaseUrl` y `supabaseAnonKey` funciona en modo demostración.
- `schema.sql`: Postgres para Supabase (tablas, RLS, RPC `join_trip`/`leave_trip`/`delete_own_account`, realtime). Idempotente.
- `SETUP.md`: guía de despliegue paso a paso (Supabase, Google OAuth, hosting, dominio, legal).
- `.taste-skill/`: archivos de trabajo del proceso de diseño. No desplegar.

## Reglas del proyecto
- Español con tildes correctas. Sin guiones largos en la prosa.
- Una sola tipografía (Switzer, Fontshare). Paleta: fondo hueso `#e9e3d8`, tinta `#1f1917`, campo azul pizarra `#2f4a58`, acento mostaza `#e0a912`. Sin degradados, sin sombras en reposo, sin líneas finas como separadores.
- El routing es por hash (`#/publicar`, `#/viaje/:id`), así que cualquier hosting estático sirve sin reglas de reescritura.
- Sin precios: cada viaje es `gratis` o `compartir` ("a pachas"); el reparto se acuerda en el grupo. `contribution_eur` siempre es 0.
- Vercel: proyecto `blablahelp` vinculado al repositorio; cada push a `main` publica en https://blablahelp.vercel.app
- Nunca guardar teléfonos. Nunca poner la clave `service_role` en el frontend.
- Antes de dar por buena una edición visual: servir con `python3 -m http.server 8080` y revisar a 1440 y 390 px.

## Estado
- Supabase: proyecto `BlaBlaHelp` (ref `dbmqyczwjuahlydbfgtm`, eu-west-1). Esquema aplicado como migraciones `blablahelp_initial_schema`, `harden_function_privileges` y `trip_editing_and_no_prices`. URL y clave publicable ya están en `CAMINO_CONFIG`.
- Pendiente: activar Google en Supabase > Authentication > Providers (necesita cliente OAuth de Google Cloud) y poner la URL de producción en Authentication > URL Configuration.

## Despliegue
1. Supabase: activar Google en Authentication > Providers, configurar Site URL y Redirect URLs con el dominio final.
2. Google Cloud: cliente OAuth web con redirect `https://<proyecto>.supabase.co/auth/v1/callback`.
3. `CAMINO_CONFIG` ya apunta al proyecto; cambia `contactEmail` por un correo real.
4. Vercel: importar este repositorio (framework "Other", sin build). Conectar el dominio y volver al paso 1 con la URL definitiva.
