// Writes court bookings straight into chosen Google Calendars.
// Each row in public.calendar_sync = one manager's email + one Google Calendar ID
// that has been shared with the service account ("Make changes to events").
// The service account can touch only calendars shared with it.
// Every run reconciles all upcoming bookings, so it is idempotent and self-healing:
// bookings you make (and, if include_added, games you were added to) are
// added/updated; cancelled or no-longer-yours bookings are removed. Past events are never touched.
// Secret: GOOGLE_SERVICE_ACCOUNT = the service account's JSON key (whole file).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const TITLE = "Padel Court - House";
const LOCATION = "House by Shigeru Ban, 224 NE 59th St, Miami, FL 33137";
const API = "https://www.googleapis.com/calendar/v3/calendars";
const b64url = (buf: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(buf as ArrayBuffer))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const enc = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));
// Google event ids allow only a-v and 0-9; a UUID without dashes fits.
const eventId = (bookingId: string) => "court" + bookingId.replace(/-/g, "").toLowerCase();

async function googleToken(sa: { client_email: string; private_key: string }, sub?: string) {
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${enc({ alg: "RS256", typ: "JWT" })}.${enc({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/calendar.events", aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600, ...(sub ? { sub } : {}) })}`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${unsigned}.${b64url(sig)}` }) });
  const j = await r.json();
  if (!r.ok) throw new Error(`google_token: ${j.error_description ?? j.error ?? r.status}`);
  return j.access_token as string;
}

type Booking = { id: string; starts_at: string; ends_at: string; booker_name: string | null; email: string; note: string | null; players: string[] | null; guest_entries: { name?: string }[] | null };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  // Any approved, signed-in manager may trigger a reconcile (it only mirrors the schedule).
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: u } = await db.auth.getUser(jwt);
  const caller = (u?.user?.email ?? "").toLowerCase();
  const { data: ok } = await db.from("approved_emails").select("email").eq("email", caller).maybeSingle();
  if (!ok) return json({ error: "unauthorized" }, 401);

  const raw = Deno.env.get("GOOGLE_SERVICE_ACCOUNT");
  if (!raw) return json({ skipped: "no_google_credentials" });
  const { data: targets } = await db.from("calendar_sync").select("email, calendar_id, act_as, include_added");
  if (!targets?.length) return json({ skipped: "no_calendars" });

  const since = new Date(Date.now() - 864e5).toISOString();
  const { data: rows } = await db.from("bookings").select("id, starts_at, ends_at, booker_name, email, note, players, guest_entries").eq("status", "confirmed").gte("starts_at", since);
  const bookings = (rows ?? []) as Booking[];
  const emails = new Set<string>(); bookings.forEach((b) => { emails.add(b.email); (b.players ?? []).forEach((p) => emails.add(p)); });
  const names = new Map<string, string>();
  if (emails.size) (await db.from("approved_emails").select("email, full_name").in("email", [...emails])).data?.forEach((r) => names.set(r.email, r.full_name || r.email.split("@")[0]));
  const nm = (e: string) => names.get(e) ?? e.split("@")[0];
  const site = Deno.env.get("SITE_URL") ?? "";

  const sa = JSON.parse(raw);
  const tokens = new Map<string, string>();
  const report: Record<string, unknown> = {};

  for (const t of targets) {
    const me = t.email.toLowerCase(); const cal = encodeURIComponent(t.calendar_id);
    const r = { added: 0, updated: 0, removed: 0, unchanged: 0, errors: [] as string[] };
    try {
      // act_as set: domain-wide delegation, the robot acts as that Workspace user.
      // act_as empty: the calendar is shared with the robot directly.
      const who = t.act_as ?? "";
      if (!tokens.has(who)) tokens.set(who, await googleToken(sa, who || undefined));
      const H = { Authorization: `Bearer ${tokens.get(who)}`, "Content-Type": "application/json" };
      const want = new Map<string, Record<string, unknown>>();
      for (const b of bookings) {
        // Only bookings this person made; also games others added them to if include_added is on.
        if (b.email !== me && !(t.include_added && (b.players ?? []).includes(me))) continue;
        const others = [b.email, ...(b.players ?? [])].filter((e) => e !== me).map(nm);
        const guests = (b.guest_entries ?? []).filter((g) => g?.name).map((g) => `${g.name} (guest)`);
        const withWho = [...others, ...guests];
        const description = [b.email === me ? "You booked" : `Booked by ${b.booker_name ?? nm(b.email)}`, withWho.length ? `Playing with: ${withWho.join(", ")}` : "", b.note ? `Comment: ${b.note}` : "", site ? `Schedule: ${site}` : ""].filter(Boolean).join("\n");
        want.set(eventId(b.id), {
          id: eventId(b.id), status: "confirmed", summary: TITLE, location: LOCATION, description,
          start: { dateTime: new Date(b.starts_at).toISOString(), timeZone: "America/New_York" },
          end: { dateTime: new Date(b.ends_at).toISOString(), timeZone: "America/New_York" },
          extendedProperties: { private: { court: "1", booking: b.id } },
        });
      }
      // What the court system put there before (only its own events, tagged court=1).
      const have = new Map<string, { id: string; description?: string; start?: { dateTime?: string }; end?: { dateTime?: string } }>();
      let page = "";
      do {
        const q = new URLSearchParams({ privateExtendedProperty: "court=1", timeMin: since, maxResults: "250", singleEvents: "true", ...(page ? { pageToken: page } : {}) });
        const lr = await fetch(`${API}/${cal}/events?${q}`, { headers: H }); const lj = await lr.json();
        if (!lr.ok) throw new Error(`list ${lr.status}: ${lj.error?.message ?? ""}`);
        (lj.items ?? []).forEach((e: { id: string }) => have.set(e.id, e)); page = lj.nextPageToken ?? "";
      } while (page);

      const same = (a: string | undefined, b: string) => !!a && new Date(a).getTime() === new Date(b).getTime();
      for (const [id, ev] of want) {
        const cur = have.get(id);
        const s = (ev.start as { dateTime: string }).dateTime, e = (ev.end as { dateTime: string }).dateTime;
        if (cur && cur.description === ev.description && same(cur.start?.dateTime, s) && same(cur.end?.dateTime, e)) { r.unchanged++; continue; }
        // PUT also revives an event that was deleted earlier (Google keeps the id reserved).
        let res = await fetch(`${API}/${cal}/events/${id}`, { method: "PUT", headers: H, body: JSON.stringify(ev) });
        if (res.status === 404) { res = await fetch(`${API}/${cal}/events`, { method: "POST", headers: H, body: JSON.stringify(ev) }); if (res.ok) { r.added++; continue; } }
        else if (res.ok) { cur ? r.updated++ : r.added++; continue; }
        r.errors.push(`${id}: ${res.status} ${(await res.json().catch(() => ({}))).error?.message ?? ""}`);
      }
      for (const id of have.keys()) {
        if (want.has(id)) continue;
        const dr = await fetch(`${API}/${cal}/events/${id}`, { method: "DELETE", headers: H });
        if (dr.ok || dr.status === 404 || dr.status === 410) r.removed++; else r.errors.push(`delete ${id}: ${dr.status}`);
      }
    } catch (e) { r.errors.push(String(e)); }
    report[me] = r;
  }
  return json(report);
});
