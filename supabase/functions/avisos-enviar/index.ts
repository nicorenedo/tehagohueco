// Te Hago Hueco · envío de avisos por correo (Brevo).
// La despierta pg_cron (avisos.tick) cada 10 minutos cuando hay avisos pendientes.
// Reglas (preferencias, límites, horario, validez) en avisos.claim(); aquí solo se redacta y se envía.
// Sin seguimiento propio: no añadimos píxeles ni enlaces de seguimiento.
import postgres from "npm:postgres@3.4.5";

const SITE = "https://www.tehagohueco.es";
const FROM = { name: "Te Hago Hueco", email: "avisos@tehagohueco.es" };
const REPLY_TO = { name: "Te Hago Hueco", email: "tehagohueco.contacto@gmail.com" };
const TZ = "Europe/Madrid";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 20 });

type Trip = { id: string; origin_city: string; dest_city: string; departure_at: string; seats_total?: number; seats_taken?: number; status?: string };
type Job = {
  id: number; kind: string; urgent: boolean; email: string; name: string | null; grp: "viajes" | "alertas";
  payload: Record<string, any>; extra: Record<string, any>; unsub: string; trip: Trip | null;
};

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const day = (iso: string) => new Intl.DateTimeFormat("es-ES", { timeZone: TZ, weekday: "long", day: "numeric", month: "long" }).format(new Date(iso)).replace(",", "");
const time = (iso: string) => new Intl.DateTimeFormat("es-ES", { timeZone: TZ, hour: "2-digit", minute: "2-digit" }).format(new Date(iso));
const when = (iso: string) => `el ${day(iso)} a las ${time(iso)}`;
const tripUrl = (id: string) => `${SITE}/#/viaje/${id}`;
const searchUrl = (o: string, d: string) => `${SITE}/#/?o=${encodeURIComponent(o)}&d=${encodeURIComponent(d)}`;
const firstName = (n: string | null) => (n || "").split(" ")[0] || "";
const dot = (s: string) => /[.!?]$/.test(s) ? s : s + ".";
const list = (a: string[]) => a.length <= 1 ? (a[0] || "") : a.slice(0, -1).join(", ") + " y " + a[a.length - 1];

function compose(j: Job) {
  const t = j.trip!;
  const hi = firstName(j.name) ? `Hola, ${firstName(j.name)}:` : "Hola:";
  const route = t ? `${t.origin_city} a ${t.dest_city}` : "";
  let subject = "", lines: string[] = [], cta = { label: "Abrir Te Hago Hueco", url: SITE };

  switch (j.kind) {
    case "cancelado":
      subject = `Viaje cancelado: ${t.origin_city} a ${t.dest_city}, ${day(t.departure_at)}`;
      lines = [`El conductor ha cancelado el viaje de ${route} que salía ${when(t.departure_at)}.`,
        "Lo sentimos. Puede que haya otros viajes parecidos en la web."];
      cta = { label: "Buscar otro viaje", url: searchUrl(t.origin_city, t.dest_city) };
      break;
    case "cambio": {
      const p = j.payload || {};
      const changed: string[] = [];
      if (p.old_departure && p.old_departure !== t.departure_at) changed.push(`Salida: antes ${when(p.old_departure)}, ahora ${when(t.departure_at)}.`);
      if ((p.old_origin && p.old_origin !== t.origin_city) || (p.old_dest && p.old_dest !== t.dest_city)) changed.push(`Trayecto: antes ${p.old_origin} a ${p.old_dest}, ahora ${route}.`);
      subject = `Cambios en tu viaje a ${t.dest_city}`;
      lines = ["El conductor ha cambiado el viaje en el que estás apuntado.", ...(changed.length ? changed : [`Ahora sale de ${t.origin_city} hacia ${t.dest_city} ${when(t.departure_at)}.`]),
        "Si ya no te viene bien, entra y pulsa \"Ya no viajo\" para dejar la plaza a otra persona."];
      cta = { label: "Ver el viaje", url: tripUrl(t.id) };
      break;
    }
    case "quitado":
      subject = `Ya no estás en el viaje a ${t.dest_city}`;
      lines = [`El conductor del viaje de ${route} (${when(t.departure_at)}) te ha quitado del viaje. Suele pasar cuando no se ha confirmado a tiempo o cambian los planes.`,
        "Puedes buscar otro viaje para esa ruta."];
      cta = { label: "Buscar otro viaje", url: searchUrl(t.origin_city, t.dest_city) };
      break;
    case "pasajeros": {
      const joined: string[] = j.payload.joined || [], left: string[] = j.payload.left || [];
      subject = joined.length && !left.length
        ? (joined.length === 1 ? `${joined[0]} se ha apuntado a tu viaje a ${t.dest_city}` : `${joined.length} personas se han apuntado a tu viaje a ${t.dest_city}`)
        : !joined.length && left.length ? `Alguien ha dejado tu viaje a ${t.dest_city}` : `Cambios en los pasajeros de tu viaje a ${t.dest_city}`;
      lines = [`Tu viaje de ${route} sale ${when(t.departure_at)}.`];
      if (joined.length) lines.push(dot(`Se ${joined.length === 1 ? "ha apuntado" : "han apuntado"}: ${list(joined)}`));
      if (left.length) lines.push(dot(`${left.length === 1 ? "Ha dejado" : "Han dejado"} el viaje: ${list(left)}`));
      lines.push(`Ahora hay ${t.seats_taken} de ${t.seats_total} plazas ocupadas. Saludad en el grupo del viaje para ir organizándoos.`);
      cta = { label: "Ver el viaje y el grupo", url: tripUrl(t.id) };
      break;
    }
    case "confirmar":
      subject = `Confirma tu viaje a ${t.dest_city} del ${day(t.departure_at)}`;
      lines = [`Tu viaje de ${route} sale ${when(t.departure_at)}.`,
        "Confirma que sigues viajando para que el conductor sepa que cuenta contigo.",
        "Si ya no vas, entra y pulsa \"Ya no viajo\": la plaza quedará libre para otra persona."];
      cta = { label: "Confirmar que viajo", url: tripUrl(t.id) };
      break;
    case "sin_confirmar": {
      const n = Number(j.extra.unconfirmed || 0);
      subject = `${n === 1 ? "Una persona no ha confirmado" : `${n} personas no han confirmado`} tu viaje a ${t.dest_city}`;
      lines = [`Tu viaje de ${route} sale ${when(t.departure_at)}.`,
        `${n === 1 ? "Una persona apuntada no ha confirmado" : `${n} personas apuntadas no han confirmado`} todavía que ${n === 1 ? "viaja" : "viajan"}.`,
        "Puedes escribirles en el grupo del viaje. Si no responden, puedes quitarles para dejar la plaza libre. Nada se libera solo: decides tú."];
      cta = { label: "Ver el viaje", url: tripUrl(t.id) };
      break;
    }
    case "alerta": {
      const trips: any[] = j.extra.trips || [];
      subject = trips.length === 1
        ? `Nuevo viaje: ${trips[0].origin_city} a ${trips[0].dest_city}, ${day(trips[0].departure_at)}`
        : `${trips.length} viajes nuevos en la ruta que pediste`;
      lines = [trips.length === 1 ? "Ha salido un viaje en la ruta que pediste:" : "Han salido viajes en la ruta que pediste:"];
      const until = j.extra.until ? day(j.extra.until) : "";
      return finish(j, subject, hi, lines, { label: trips.length === 1 ? "Ver el viaje" : "Ver los viajes", url: trips.length === 1 ? tripUrl(trips[0].id) : searchUrl(trips[0].origin_city, trips[0].dest_city) },
        trips.map(x => ({ text: `${x.origin_city} a ${x.dest_city}, ${when(x.departure_at)}. ${x.free === 1 ? "Queda 1 plaza" : `Quedan ${x.free} plazas`}${x.cost_mode === "gratis" ? ", gratis" : ", a pachas"}.`, url: tripUrl(x.id) })),
        until ? `Estas alertas se apagan solas el ${until}.` : "");
    }
  }
  return finish(j, subject, hi, lines, cta, [], "");
}

function finish(j: Job, subject: string, hi: string, lines: string[], cta: { label: string; url: string }, items: { text: string; url: string }[], note: string) {
  const unsubUrl = `${SITE}/api/baja?t=${encodeURIComponent(j.unsub)}`;
  const why = j.grp === "alertas"
    ? "Recibes este correo porque al pedir transporte marcaste que te avisáramos de viajes nuevos en tu ruta."
    : "Recibes este correo porque participas en un viaje de Te Hago Hueco.";
  const stop = j.grp === "alertas" ? "Dejar de recibir alertas de ruta" : "Dejar de recibir avisos de mis viajes";

  const text = [hi, "", ...lines, ...items.map(i => `- ${i.text} ${i.url}`), "", `${cta.label}: ${cta.url}`, ...(note ? ["", note] : []),
    "", "--", why, `${stop}: ${unsubUrl}`, "También puedes cambiarlo en Mis viajes, en la web.",
    "Te Hago Hueco es una iniciativa solidaria sin ánimo de lucro. Si respondes a este correo, nos llega a nosotros."].join("\n");

  const p = (s: string) => `<p style="margin:0 0 14px;font-size:16px;line-height:1.5;color:#1f1917">${esc(s)}</p>`;
  const html = `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(subject)}</title></head>
<body style="margin:0;padding:0;background:#e9e3d8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#e9e3d8"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:16px">
<tr><td style="padding:26px 26px 6px;font-size:18px;font-weight:700;color:#1f1917">Te Hago <span style="color:#2f4a58">Hueco</span></td></tr>
<tr><td style="padding:12px 26px 8px">
${p(hi)}${lines.map(p).join("")}
${items.length ? `<ul style="margin:0 0 16px;padding-left:20px">${items.map(i => `<li style="margin:0 0 8px;font-size:16px;line-height:1.45;color:#1f1917"><a href="${esc(i.url)}" style="color:#2f4a58">${esc(i.text)}</a></li>`).join("")}</ul>` : ""}
<table role="presentation" cellpadding="0" cellspacing="0" style="margin:6px 0 18px"><tr><td style="background:#e0a912;border-radius:999px">
<a href="${esc(cta.url)}" style="display:inline-block;padding:12px 22px;font-size:16px;font-weight:600;color:#1f1917;text-decoration:none">${esc(cta.label)}</a></td></tr></table>
${note ? `<p style="margin:0 0 14px;font-size:14px;line-height:1.5;color:#5b534d">${esc(note)}</p>` : ""}
</td></tr>
<tr><td style="padding:16px 26px 24px;background:#f4f0e9;border-radius:0 0 16px 16px;font-size:13px;line-height:1.5;color:#5b534d">
${esc(why)} <a href="${esc(unsubUrl)}" style="color:#5b534d">${esc(stop)}</a>. También puedes cambiarlo en Mis viajes.<br><br>
Te Hago Hueco es una iniciativa solidaria sin ánimo de lucro. Si respondes a este correo, nos llega a nosotros.
</td></tr></table></td></tr></table></body></html>`;

  return { subject, html, text, unsubUrl };
}

async function send(j: Job, key: string) {
  const m = compose(j);
  const r = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": key, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      sender: FROM, replyTo: REPLY_TO,
      to: [{ email: j.email, ...(j.name ? { name: j.name } : {}) }],
      subject: m.subject, htmlContent: m.html, textContent: m.text,
      headers: {
        "List-Unsubscribe": `<${m.unsubUrl}>, <mailto:${REPLY_TO.email}?subject=Baja%20de%20avisos>`,
        "List-Unsubscribe-Post": "List-Unsubscribe=One-Click"
      },
      tags: [j.kind]
    })
  });
  const body = await r.text();
  if (!r.ok) throw new Error(`Brevo ${r.status}: ${body.slice(0, 300)}`);
  try { return JSON.parse(body).messageId || null; } catch { return null; }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const given = req.headers.get("x-avisos-key") || "";
  if (given.length !== 64) return new Response("Unauthorized", { status: 401 });
  const [{ ok }] = await sql`select coalesce((select decrypted_secret = ${given} from vault.decrypted_secrets where name = 'avisos_cron'), false) as ok`;
  if (!ok) return new Response("Unauthorized", { status: 401 });

  const key = Deno.env.get("BREVO_API_KEY");
  if (!key) return Response.json({ ok: false, error: "Falta BREVO_API_KEY" }, { status: 503 });

  let sent = 0, failed = 0;
  const rows = await sql`select avisos.claim(40) as j`;
  for (const { j } of rows as unknown as { j: Job }[]) {
    try {
      const id = await send(j, key);
      await sql`select avisos.mark(${j.id}, true, null, ${id})`;
      sent++;
    } catch (e) {
      await sql`select avisos.mark(${j.id}, false, ${String((e as Error).message || e)}, null)`;
      failed++;
    }
  }
  await sql`delete from avisos.outbox where created_at < now() - interval '30 days'`;
  return Response.json({ ok: true, sent, failed });
});
