// Private, subscribable calendar feed: every court booking the owner of the
// token made or is playing in. Apple/Google/Outlook poll it, so new bookings
// appear and cancelled ones disappear on their own. Deploy with verify_jwt=false;
// the random per-person token in the URL is the access check.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const icsDate = (d: string | Date) => new Date(d).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const icsText = (s: string) => String(s ?? "").replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
const fold = (line: string) => { const out: string[] = []; let cur = ""; for (const ch of line) { if (new TextEncoder().encode(cur + ch).length > 74) { out.push(cur); cur = " " + ch; } else cur += ch; } out.push(cur); return out.join("\r\n"); };
const TITLE = "Padel Court - House";
const LOCATION = "House by Shigeru Ban, 224 NE 59th St, Miami, FL 33137";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Booking = { id: string; starts_at: string; ends_at: string; booker_name: string | null; email: string; note: string | null; players: string[] | null; guest_entries: { name?: string }[] | null };

Deno.serve(async (req) => {
  if (req.method !== "GET" && req.method !== "HEAD") return new Response("Method not allowed", { status: 405 });
  const token = (new URL(req.url).searchParams.get("t") ?? "").replace(/\.ics$/i, "");
  if (!UUID.test(token)) return new Response("Not found", { status: 404 });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: feed } = await db.from("calendar_feeds").select("email").eq("token", token).maybeSingle();
  if (!feed) return new Response("Not found", { status: 404 });
  const me = feed.email.toLowerCase();
  const { data: still } = await db.from("approved_emails").select("email").eq("email", me).maybeSingle();
  if (!still) return new Response("Not found", { status: 404 });

  const since = new Date(Date.now() - 60 * 864e5).toISOString();
  const cols = "id, starts_at, ends_at, booker_name, email, note, players, guest_entries";
  const [mine, joined] = await Promise.all([
    db.from("bookings").select(cols).eq("status", "confirmed").gte("starts_at", since).eq("email", me),
    db.from("bookings").select(cols).eq("status", "confirmed").gte("starts_at", since).contains("players", [me]),
  ]);
  const byId = new Map<string, Booking>();
  for (const b of [...(mine.data ?? []), ...(joined.data ?? [])] as Booking[]) byId.set(b.id, b);
  const bookings = [...byId.values()].sort((a, b) => a.starts_at.localeCompare(b.starts_at));

  const emails = new Set<string>();
  for (const b of bookings) { emails.add(b.email); (b.players ?? []).forEach((p) => emails.add(p)); }
  const names = new Map<string, string>();
  if (emails.size) {
    const { data } = await db.from("approved_emails").select("email, full_name").in("email", [...emails]);
    (data ?? []).forEach((r) => names.set(r.email, r.full_name || r.email.split("@")[0]));
  }
  const nm = (e: string) => names.get(e) ?? e.split("@")[0];
  const site = Deno.env.get("SITE_URL") ?? "";
  const stamp = icsDate(new Date());

  const lines = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//House by Shigeru Ban//Padel Court//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    "X-WR-CALNAME:Padel", "X-WR-TIMEZONE:America/New_York", "REFRESH-INTERVAL;VALUE=DURATION:PT15M", "X-PUBLISHED-TTL:PT15M",
  ];
  for (const b of bookings) {
    const party = [b.email, ...(b.players ?? [])].filter((e) => e !== me).map(nm);
    const guests = (b.guest_entries ?? []).filter((g) => g?.name).map((g) => `${g.name} (guest)`);
    const withWho = [...party, ...guests];
    const desc = [b.email === me ? "You booked" : `Booked by ${b.booker_name ?? nm(b.email)}`, withWho.length ? `Playing with: ${withWho.join(", ")}` : "", b.note ? `Comment: ${b.note}` : "", site ? `Schedule: ${site}` : ""].filter(Boolean).join("\n");
    lines.push(
      "BEGIN:VEVENT", `UID:${b.id}@shigeru-court`, `DTSTAMP:${stamp}`, `DTSTART:${icsDate(b.starts_at)}`, `DTEND:${icsDate(b.ends_at)}`,
      `SUMMARY:${icsText(TITLE)}`, `LOCATION:${icsText(LOCATION)}`, `DESCRIPTION:${icsText(desc)}`, "STATUS:CONFIRMED",
      ...(site ? [`URL:${site}`] : []),
      "BEGIN:VALARM", "TRIGGER:-PT60M", "ACTION:DISPLAY", `DESCRIPTION:${icsText(TITLE)}`, "END:VALARM", "END:VEVENT",
    );
  }
  lines.push("END:VCALENDAR");
  return new Response(lines.map(fold).join("\r\n") + "\r\n", {
    headers: { "Content-Type": "text/calendar; charset=utf-8", "Content-Disposition": 'inline; filename="padel.ics"', "Cache-Control": "no-store" },
  });
});
