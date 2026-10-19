// Serves one booking as a calendar file (.ics) so "Apple Calendar" links in
// emails open straight into Calendar on iPhone/Mac. Public by design: the
// booking id is a random UUID that only appears in that booking's emails.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const icsDate = (d: string | Date) => new Date(d).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const icsText = (s: string) => String(s ?? "").replace(/\\/g, "\\\\").replace(/;/g, "\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
const fold = (line: string) => { const out: string[] = []; let cur = ""; for (const ch of line) { if (new TextEncoder().encode(cur + ch).length > 74) { out.push(cur); cur = " " + ch; } else cur += ch; } out.push(cur); return out.join("\r\n"); };
const EVENT_TITLE = "Padel Court - House";
const EVENT_LOCATION = "House by Shigeru Ban, 224 NE 59th St, Miami, FL 33137";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "GET") return new Response("Method not allowed", { status: 405 });
  const id = new URL(req.url).searchParams.get("id") ?? "";
  if (!UUID.test(id)) return new Response("Not found", { status: 404 });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: b } = await admin.from("bookings").select("id, starts_at, ends_at, booker_name, email, note, status, players, guest_entries").eq("id", id).maybeSingle();
  if (!b) return new Response("Not found", { status: 404 });

  const players: string[] = Array.isArray(b.players) ? b.players : [];
  let names: string[] = [];
  if (players.length) {
    const { data: pn } = await admin.from("approved_emails").select("email, full_name").in("email", players);
    const by = new Map((pn ?? []).map((r) => [r.email, r.full_name || r.email.split("@")[0]]));
    names = players.map((e) => by.get(e) ?? e.split("@")[0]);
  }
  const guests = (Array.isArray(b.guest_entries) ? b.guest_entries : []).filter((g: { name?: string }) => g && g.name).map((g: { name: string }) => `${g.name} (guest)`);
  const party = [...names, ...guests];
  const site = Deno.env.get("SITE_URL") ?? "";
  const description = [`Booked by ${b.booker_name ?? b.email}`, party.length ? `Playing with: ${party.join(", ")}` : "", b.note ? `Comment: ${b.note}` : "", site ? `Schedule: ${site}` : ""].filter(Boolean).join("\n");
  const cancelled = b.status !== "confirmed";

  const lines = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//House by Shigeru Ban//Padel Court//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    "BEGIN:VEVENT",
    `UID:${b.id}@shigeru-court`, `DTSTAMP:${icsDate(new Date())}`, `DTSTART:${icsDate(b.starts_at)}`, `DTEND:${icsDate(b.ends_at)}`,
    `SUMMARY:${icsText((cancelled ? "CANCELLED: " : "") + EVENT_TITLE)}`,
    `LOCATION:${icsText(EVENT_LOCATION)}`, `DESCRIPTION:${icsText(description)}`,
    `STATUS:${cancelled ? "CANCELLED" : "CONFIRMED"}`, `SEQUENCE:${cancelled ? 1 : 0}`,
    ...(cancelled ? [] : ["BEGIN:VALARM", "TRIGGER:-PT60M", "ACTION:DISPLAY", `DESCRIPTION:${icsText(EVENT_TITLE)}`, "END:VALARM"]),
    "END:VEVENT", "END:VCALENDAR",
  ];
  return new Response(lines.map(fold).join("\r\n") + "\r\n", {
    headers: {
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": 'inline; filename="court.ics"',
      "Cache-Control": "no-store",
    },
  });
});
