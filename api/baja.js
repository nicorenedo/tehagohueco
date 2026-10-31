// Baja de avisos por correo con un clic.
// GET muestra una confirmación (los antivirus y previsualizadores abren enlaces: GET nunca cambia nada).
// POST da de baja: desde el botón de la página o desde el botón "Cancelar suscripción" de Gmail
// (List-Unsubscribe-Post, RFC 8058). El token lo firma la base de datos; aquí solo se reenvía.

const SUPABASE_URL = process.env.SUPABASE_URL || "https://dbmqyczwjuahlydbfgtm.supabase.co";
const SUPABASE_KEY = process.env.SUPABASE_ANON_KEY || "sb_publishable_IBV9ny5inC9MFPl5kJE1mw_Ql3Epku3";

const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function page(title, body) {
  return `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>${esc(title)} · Te Hago Hueco</title>
<style>
body{margin:0;background:#e9e3d8;color:#1f1917;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
main{max-width:520px;margin:0 auto;padding:48px 20px}
.card{background:#fff;border-radius:16px;padding:28px 24px}
.brand{font-weight:700;font-size:18px;margin:0 0 18px}.brand span{color:#2f4a58}
h1{font-size:24px;line-height:1.2;margin:0 0 12px}
p{margin:0 0 14px}.muted{color:#5b534d;font-size:14px}
button,.btn{display:inline-block;border:0;border-radius:999px;padding:12px 22px;font-family:inherit;font-size:16px;font-weight:600;line-height:1;cursor:pointer;text-decoration:none}
button{background:#e0a912;color:#1f1917}.btn{background:#1f1917;color:#fff;margin-top:6px}
a{color:#2f4a58}
</style></head><body><main><div class="card"><p class="brand">Te Hago <span>Hueco</span></p>${body}</div></main></body></html>`;
}

function label(grp) {
  return grp === "alertas" ? "las alertas de viajes nuevos en las rutas que pediste" : "los avisos de tus viajes (cancelaciones, cambios, confirmaciones y pasajeros)";
}

module.exports = async (req, res) => {
  const url = new URL(req.url, "https://www.tehagohueco.es");
  const token = (url.searchParams.get("t") || "").slice(0, 200);
  const grp = token.split(".")[1];
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("X-Robots-Tag", "noindex");

  if (!token || (grp !== "viajes" && grp !== "alertas")) {
    res.statusCode = 400;
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    return res.end(page("Enlace no válido", `<h1>Este enlace no es válido</h1><p>Puedes cambiar tus avisos en <a href="/#/mis-viajes">Mis viajes</a> o escribirnos a <a href="mailto:tehagohueco.contacto@gmail.com">tehagohueco.contacto@gmail.com</a>.</p>`));
  }

  if (req.method === "GET" || req.method === "HEAD") {
    res.statusCode = 200;
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    return res.end(page("Dejar de recibir avisos", `<h1>¿Dejar de recibir estos correos?</h1>
<p>Dejarás de recibir ${esc(label(grp))}.</p>
<form method="post" action="/api/baja?t=${encodeURIComponent(token)}"><button type="submit">Sí, darme de baja</button></form>
<p class="muted" style="margin-top:18px">Podrás volver a activarlos cuando quieras en Mis viajes.</p>`));
  }

  if (req.method !== "POST") {
    res.statusCode = 405;
    res.setHeader("Allow", "GET, POST");
    return res.end();
  }

  let ok = false;
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/avisos_baja`, {
      method: "POST",
      headers: { apikey: SUPABASE_KEY, "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ p_token: token })
    });
    ok = r.ok;
  } catch (_) { ok = false; }

  res.setHeader("Content-Type", "text/html; charset=utf-8");
  if (!ok) {
    res.statusCode = 400;
    return res.end(page("No se pudo completar", `<h1>No hemos podido darte de baja</h1><p>El enlace no es válido o ha caducado. Puedes cambiar tus avisos en <a href="/#/mis-viajes">Mis viajes</a> o escribirnos a <a href="mailto:tehagohueco.contacto@gmail.com">tehagohueco.contacto@gmail.com</a> y lo hacemos nosotros.</p>`));
  }
  res.statusCode = 200;
  return res.end(page("Baja completada", `<h1>Hecho</h1><p>Ya no recibirás ${esc(label(grp))}.</p><p class="muted">Si cambias de idea, puedes activarlos de nuevo en Mis viajes.</p><a class="btn" href="/">Ir a Te Hago Hueco</a>`));
};
