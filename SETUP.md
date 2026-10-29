# BlaBlaHelp · Guía de puesta en marcha

Tiempo estimado: 45 a 60 minutos la primera vez. Todo lo necesario es gratuito en los planes básicos.

Archivos:

- `index.html`: la web completa (frontend). Sin dependencias que instalar.
- `schema.sql`: base de datos, seguridad y funciones para Supabase.
- `SETUP.md`: esta guía.

Mientras `index.html` no tenga configuradas las claves de Supabase, funciona en **modo demostración** con viajes de ejemplo y un inicio de sesión simulado. Sirve para enseñarla y revisar diseño y textos.

---

## 1. Crear el proyecto en Supabase (10 min)

1. Entra en https://supabase.com y crea una cuenta (puedes usar tu Google o GitHub).
2. "New project":
   - **Name**: `blablahelp`
   - **Database password**: genera una y guárdala (no la necesitarás en la web, solo para administración).
   - **Region**: `West EU (Ireland)` o `Central EU (Frankfurt)`. Importante para RGPD: los datos se quedan en la UE.
3. Espera uno o dos minutos a que el proyecto esté listo.
4. Ve a **SQL Editor** (icono de terminal en el menú izquierdo) > "New query". Pega el contenido completo de `schema.sql` y pulsa **Run**. Debe terminar sin errores ("Success. No rows returned").
5. Ve a **Project Settings** (rueda dentada) > **API** y copia:
   - **Project URL** (algo como `https://abcdefgh.supabase.co`)
   - **anon public** key (una cadena larga que empieza por `eyJ...`)

   La clave `anon` está pensada para ir en el frontend; la seguridad real la aplican las reglas RLS del `schema.sql`. **Nunca pongas la clave `service_role` en la web.**

## 2. Activar el inicio de sesión con Google (15 min)

### 2a. En Google Cloud

1. Entra en https://console.cloud.google.com y crea un proyecto (por ejemplo `blablahelp`).
2. Menú > **APIs y servicios** > **Pantalla de consentimiento de OAuth**:
   - Tipo de usuario: **Externo**.
   - Nombre de la aplicación: `BlaBlaHelp`. Correo de asistencia: el tuyo.
   - Dominios autorizados: añade tu dominio final (por ejemplo `blablahelp.es`) y `supabase.co`.
   - Ámbitos (scopes): deja los básicos (`email`, `profile`, `openid`).
   - Guarda. En "Estado de publicación" pulsa **Publicar aplicación** para que cualquiera pueda entrar (si lo dejas en "Prueba", solo entran los correos que añadas a mano, máximo 100).
3. **APIs y servicios** > **Credenciales** > **Crear credenciales** > **ID de cliente de OAuth**:
   - Tipo: **Aplicación web**.
   - Orígenes de JavaScript autorizados: `https://TU-DOMINIO` (y `http://localhost:8080` si quieres probar en local).
   - URI de redireccionamiento autorizados: `https://TU-PROYECTO.supabase.co/auth/v1/callback` (sustituye por tu Project URL de Supabase).
   - Crear. Copia el **ID de cliente** y el **Secreto de cliente**.

### 2b. En Supabase

1. **Authentication** > **Providers** > **Google**: actívalo, pega el Client ID y el Client Secret, guarda.
2. **Authentication** > **URL Configuration**:
   - **Site URL**: `https://TU-DOMINIO`
   - **Redirect URLs**: añade `https://TU-DOMINIO/**` (y `http://localhost:8080/**` para pruebas locales).

Sin este paso, tras iniciar sesión Google devolverá al usuario a `localhost:3000` y parecerá que no funciona.

## 3. Configurar la web (2 min)

Abre `index.html` y, al principio del archivo, rellena el bloque `CAMINO_CONFIG`:

```js
window.CAMINO_CONFIG = {
  supabaseUrl: "https://TU-PROYECTO.supabase.co",
  supabaseAnonKey: "eyJ...",
  contactEmail: "hola@blablahelp.es",   // aparece en legal, reportes y contacto
  siteName: "BlaBlaHelp",
  ownerName: "Nicolás Renedo de la Lastra", // titular en el aviso legal (obligatorio por LSSI)
};
```

En cuanto `supabaseUrl` y `supabaseAnonKey` tienen valor, el modo demostración desaparece y todo pasa a ser real.

## 4. Publicar la web (10 min)

Cualquier alojamiento de archivos estáticos sirve. Dos opciones sin coste:

**Opción A: Netlify (la más rápida)**
1. Entra en https://app.netlify.com, crea cuenta.
2. "Add new site" > "Deploy manually" y arrastra la carpeta que contiene `index.html`.
3. Tendrás una URL tipo `https://nombre-aleatorio.netlify.app`. En "Domain management" puedes cambiar el subdominio o conectar tu dominio propio.

**Opción B: Cloudflare Pages o Vercel**: mismo flujo, subes la carpeta y te dan una URL con HTTPS.

**Dominio propio (recomendable para la confianza de la gente)**: compra `blablahelp.es` o similar (unos 10 €/año en cualquier registrador) y sigue las instrucciones del alojamiento para apuntar el DNS. Recuerda actualizar luego la Site URL en Supabase y los orígenes autorizados en Google Cloud con el dominio definitivo.

Para probar en local antes de publicar: `python3 -m http.server 8080` dentro de la carpeta y abre `http://localhost:8080`. No abras el archivo con doble clic (`file://`), porque el inicio de sesión con Google no funciona así.

## 5. Comprobación final (5 min)

1. Abre la web en el dominio definitivo. No debe verse la etiqueta "Modo demostración".
2. Entra con tu Google. Debe aparecer tu nombre abreviado arriba a la derecha.
3. Publica un viaje de prueba. Comprueba que aparece en la lista y en el mapa.
4. Con otra cuenta de Google (o pídeselo a alguien), apúntate a ese viaje: las plazas deben bajar, el estado debe pasar a "Completo" cuando se llene, y el chat debe funcionar en tiempo real en ambas pantallas.
5. Cancela el viaje de prueba desde "Mis viajes".

Si algo falla, abre la consola del navegador (F12 > Console): los errores de Supabase son explícitos (permisos, URL de redirección, etc.).

## 6. Mantenimiento mínimo

- **Limpieza de datos**: los viajes caducan a los 30 días de su salida. Para que se borren solos, activa la extensión `pg_cron` en Supabase (Database > Extensions) y descomenta las dos últimas líneas de `schema.sql`. Si no, ejecuta `select public.purge_old_trips();` en el SQL Editor de vez en cuando.
- **Reportes**: llegan al correo de `contactEmail`. Para expulsar a alguien, en Supabase > Authentication > Users puedes borrar su usuario; se eliminan en cascada sus viajes, inscripciones y mensajes.
- **Ver la actividad**: Supabase > Table Editor > `trips` muestra todos los viajes; `messages` solo deberías consultarla ante un reporte.
- **Cuando la línea se restablezca**: puedes cerrar la iniciativa borrando el proyecto de Supabase (se destruyen todos los datos) y retirando la web.

## 7. Aspectos legales que debes revisar tú

No soy abogado y esto no sustituye una revisión profesional, pero estos son los puntos cubiertos y los que quedan en tu mano:

- **LSSI**: el aviso legal identifica al titular (persona física) con un correo de contacto. Es obligatorio y ya está, pero confirma que quieres aparecer con nombre completo; es lo que exige la ley para quien presta un servicio de la sociedad de la información, aunque sea gratuito.
- **RGPD / LOPDGDD**: la política de privacidad describe datos, finalidades, base jurídica, encargados (Supabase en la UE, Google), conservación y derechos. Tratas pocos datos y con minimización real (no hay teléfonos; el correo no se muestra). Como persona física sin actividad económica no necesitas DPO ni registro ante la AEPD, pero sí debes atender los derechos que te pidan por correo. Si en algún momento usaras analítica (Google Analytics, etc.) tendrías que añadir banner de cookies; ahora mismo no hace falta.
- **Responsabilidad**: las condiciones dejan claro que eres un mero intermediario técnico sin participación en el acuerdo, sin verificación de conductores y sin gestión de pagos, y cada conductor acepta tres compromisos explícitos al publicar. Esto es lo habitual en este tipo de plataformas y te protege razonablemente, pero no es una inmunidad absoluta: si recibes un reporte de conducta peligrosa y no actúas, ahí sí podrías tener un problema. Atiende los reportes.
- **Transporte**: compartir gastos reales sin beneficio es legal en España y no requiere autorización de transporte. La web no fija ni cobra precios: cada viaje es gratis o a pachas, y el reparto de gastos se acuerda entre los viajeros en el grupo privado. La base de datos impide guardar cualquier importe.
- **Nombre y marca**: comprueba que el nombre que elijas no esté registrado (https://www.oepm.es). "BlaBlaHelp" es una propuesta; es trivial cambiarlo en `siteName` y en el `<title>`.

## 8. Mejoras posibles para una segunda versión

- Avisos por correo cuando alguien se apunta a tu viaje o el conductor cancela (Supabase Edge Function + Resend).
- Valoraciones entre viajeros tras el viaje.
- Búsqueda por radio ("a menos de 30 km de...") usando las coordenadas ya incluidas en la lista de localidades.
- Versión instalable en móvil (PWA): bastan un `manifest.json` y un service worker.
