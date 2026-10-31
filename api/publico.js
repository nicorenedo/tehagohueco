// Datos públicos de la portada (viajes próximos y firmas), cacheados en la CDN de Vercel.
// Así miles de visitas simultáneas se sirven desde caché y Supabase recibe
// como mucho una consulta cada pocos segundos por región.
// Usa la clave publicable: ve exactamente lo mismo que un visitante anónimo.

const SUPABASE_URL = process.env.SUPABASE_URL || "https://dbmqyczwjuahlydbfgtm.supabase.co";
const SUPABASE_KEY = process.env.SUPABASE_ANON_KEY || "sb_publishable_IBV9ny5inC9MFPl5kJE1mw_Ql3Epku3";

// Solo columnas públicas: sin conductor, zonas, paradas, vehículo ni descripción (eso solo con sesión).
const TRIP_SELECT = "id,origin_city,dest_city,departure_at,flexibility,seats_total,seats_taken,cost_mode,contribution_eur,distance_km,status,created_at,origin_lat,origin_lng,dest_lat,dest_lng";

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
    const rpc = name => getJson(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: Object.assign({ "Content-Type": "application/json" }, headers),
      body: "{}"
    }).catch(() => null);
    const [trips, demand, impact] = await Promise.all([getJson(tripsUrl, { headers }), rpc("demand_stats"), rpc("impact_stats")]);
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    // El navegador no guarda copia; la CDN de Vercel sí: 15 s fresca y hasta 2 min sirviendo la anterior mientras se renueva.
    res.setHeader("Cache-Control", "public, max-age=0, must-revalidate");
    res.setHeader("Vercel-CDN-Cache-Control", "max-age=15, stale-while-revalidate=120");
    res.statusCode = 200;
    res.end(JSON.stringify({ at: new Date().toISOString(), trips, demand, impact }));
  } catch (err) {
    console.error("publico:", err && err.message);
    res.setHeader("Cache-Control", "no-store");
    res.statusCode = 502;
    res.end(JSON.stringify({ error: "upstream" }));
  }
};
