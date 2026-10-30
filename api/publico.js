// Datos públicos de la portada (viajes próximos y firmas), cacheados en la CDN de Vercel.
// Así miles de visitas simultáneas se sirven desde caché y Supabase recibe
// como mucho una consulta cada pocos segundos por región.
// Usa la clave publicable: ve exactamente lo mismo que un visitante anónimo.

const SUPABASE_URL = process.env.SUPABASE_URL || "https://dbmqyczwjuahlydbfgtm.supabase.co";
const SUPABASE_KEY = process.env.SUPABASE_ANON_KEY || "sb_publishable_IBV9ny5inC9MFPl5kJE1mw_Ql3Epku3";

const TRIP_SELECT = "*,driver:profiles!trips_driver_id_fkey(id,display_name,avatar_url)";

async function getJson(url, init) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 8000);
  try {
    const r = await fetch(url, Object.assign({ signal: ctrl.signal }, init));
    if (!r.ok) throw new Error(`${r.status} ${await r.text().catch(() => "")}`.slice(0, 300));
    return await r.json();
  } finally {
    clearTimeout(timer);
  }
}

module.exports = async (req, res) => {
  const headers = { apikey: SUPABASE_KEY, Accept: "application/json" };
  const since = new Date(Date.now() - 2 * 3600e3).toISOString();
  const tripsUrl = `${SUPABASE_URL}/rest/v1/trips?select=${encodeURIComponent(TRIP_SELECT)}` +
    `&departure_at=gte.${encodeURIComponent(since)}&status=neq.cancelado&order=departure_at.asc&limit=1000`;
  try {
    const [trips, demand] = await Promise.all([
      getJson(tripsUrl, { headers }),
      getJson(`${SUPABASE_URL}/rest/v1/rpc/demand_stats`, {
        method: "POST",
        headers: Object.assign({ "Content-Type": "application/json" }, headers),
        body: "{}"
      }).catch(() => null)
    ]);
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    // El navegador no guarda copia; la CDN de Vercel sí: 15 s fresca y hasta 2 min sirviendo la anterior mientras se renueva.
    res.setHeader("Cache-Control", "public, max-age=0, must-revalidate");
    res.setHeader("Vercel-CDN-Cache-Control", "max-age=15, stale-while-revalidate=120");
    res.statusCode = 200;
    res.end(JSON.stringify({ at: new Date().toISOString(), trips, demand }));
  } catch (err) {
    console.error("publico:", err && err.message);
    res.setHeader("Cache-Control", "no-store");
    res.statusCode = 502;
    res.end(JSON.stringify({ error: "upstream" }));
  }
};
