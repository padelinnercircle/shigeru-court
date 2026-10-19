import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const smtpUser = Deno.env.get("SMTP_USER");
  const smtpPass = (Deno.env.get("SMTP_PASS") ?? "").replace(/\s+/g, "");
  const smtpHost = Deno.env.get("SMTP_HOST") ?? "smtp.gmail.com";
  const fromName = Deno.env.get("NOTIFY_FROM_NAME") ?? "The Court";
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const resendFrom = Deno.env.get("NOTIFY_FROM");
  const siteUrl = Deno.env.get("SITE_URL") ?? "";

  const admin = createClient(url, service, { auth: { persistSession: false } });
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: userData, error: userErr } = await admin.auth.getUser(token);
  if (userErr || !userData?.user) return json({ error: "unauthorized" }, 401);
  const callerEmail = (userData.user.email ?? "").toLowerCase();

  let body: { booking_id?: string; event?: string; emails?: string[] };
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const event = body.event === "cancelled" ? "cancelled" : body.event === "added" ? "added" : "created";
  if (!body.booking_id) return json({ error: "missing booking_id" }, 400);

  const { data: b } = await admin.from("bookings").select("*").eq("id", body.booking_id).maybeSingle();
  if (!b) return json({ error: "not_found" }, 404);
  const { data: callerRow } = await admin.from("approved_emails").select("is_admin").eq("email", callerEmail).maybeSingle();
  const allowed = b.user_id === userData.user.id || callerRow?.is_admin || (event === "cancelled" && b.cancelled_by === callerEmail);
  if (!allowed) return json({ error: "forbidden" }, 403);
  if (event === "created" && (b.status !== "confirmed" || b.notified_created_at)) return json({ skipped: "already_notified" });
  if (event === "cancelled" && (b.status !== "cancelled" || b.notified_cancelled_at)) return json({ skipped: "already_notified" });
  if (event === "added" && b.status !== "confirmed") return json({ skipped: "not_confirmed" });

  const { data: settings } = await admin.from("settings").select("*").eq("id", 1).single();
  const tz = settings?.timezone ?? "America/New_York";
  const day = new Date(b.starts_at).toLocaleDateString("en-US", { timeZone: tz, weekday: "long", month: "long", day: "numeric" });
  const t = (d: string) => new Date(d).toLocaleTimeString("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit" });
  const when = `${day}, ${t(b.starts_at)} - ${t(b.ends_at)}`;

  const { data: list } = await admin.from("approved_emails").select("email").eq("notify_on_booking", true);
  const players: string[] = Array.isArray(b.players) ? b.players : [];
  const guests: string[] = Array.isArray(b.guests) ? b.guests : [];
  const guestEmails = guests.filter((g) => g.includes("@"));   // name-only guests are never emailed
  const party = [...players, ...guestEmails];
  const added = event === "added" ? Array.from(new Set((body.emails ?? []).map((e) => String(e).toLowerCase().trim()))).filter((e) => party.includes(e)) : [];
  if (event === "added" && !added.length) return json({ skipped: "no_new_players" });
  const recipients = event === "added" ? added : Array.from(new Set([...(list ?? []).map((r) => r.email), b.email, ...party].filter(Boolean)));
  let playerNames: string[] = [];
  if (players.length) {
    const { data: pn } = await admin.from("approved_emails").select("email, full_name").in("email", players);
    const byEmail = new Map((pn ?? []).map((r) => [r.email, r.full_name || r.email.split("@")[0]]));
    playerNames = players.map((e) => byEmail.get(e) ?? e.split("@")[0]);
  }
  playerNames = [...playerNames, ...guests.map((g) => (g.includes("@") ? `${g} (guest)` : g))];

  const isAdded = event === "added";
  const isNew = event === "created" || isAdded;
  const subject = isAdded ? `You're playing: ${when}` : isNew ? `Court booked: ${when}` : `Booking cancelled: ${when}`;
  const dayLabel = new Date(b.starts_at).toLocaleDateString("en-US", { timeZone: tz, weekday: "long" });
  const dateLabel = new Date(b.starts_at).toLocaleDateString("en-US", { timeZone: tz, month: "long", day: "numeric" });
  const timeLabel = `${t(b.starts_at)} – ${t(b.ends_at)}`;
  const who = b.booker_name ?? b.email;
  const text = `${isAdded ? `${b.booker_name ?? b.email} added you to this booking` : isNew ? "Court booked" : "Booking cancelled"}\n${when}\nBooked by ${who} (${b.email})${playerNames.length ? `\nPlaying with: ${playerNames.join(", ")}` : ""}${b.note ? `\nComment: ${b.note}` : ""}${!isNew ? `\nCancelled by ${b.cancelled_by ?? ""}\nThis time is open again.` : ""}${siteUrl ? `\n\nSchedule: ${siteUrl}` : ""}\n\nHouse by Shigeru Ban - 224 NE 59th St, Miami, FL 33137`;

  const F = "Helvetica,Arial,sans-serif", S = "Georgia,'Times New Roman',serif";
  const row = (label: string, value: string) => `<tr>
      <td valign="top" style="padding:14px 0;border-bottom:1px solid #EDE6DA;width:120px;font:500 10.5px/1.6 ${F};letter-spacing:2.5px;text-transform:uppercase;color:#958B7E;">${label}</td>
      <td valign="top" style="padding:14px 0;border-bottom:1px solid #EDE6DA;font:400 17px/1.45 ${S};color:#24211D;">${value}</td></tr>`;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>${esc(subject)}</title></head>
<body style="margin:0;padding:0;background:#F6F2EB;-webkit-text-size-adjust:100%;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F6F2EB;"><tr><td align="center" style="padding:40px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">
  <tr><td style="padding:0 0 22px 0;"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
    <td width="30" height="30" align="center" valign="middle" style="width:30px;height:30px;border:1px solid #24211D;font:500 15px/30px ${S};color:#24211D;">H</td>
    <td style="padding-left:12px;font:500 11px/1.2 ${F};letter-spacing:4px;text-transform:uppercase;color:#24211D;">House by Shigeru Ban</td>
  </tr></table></td></tr>
  <tr><td style="background:#FBF9F5;border:1px solid #E2D9CB;${isNew ? "border-top:3px solid #A57C52;" : "border-top:3px solid #958B7E;"}padding:38px 40px 36px 40px;">
    <p style="margin:0 0 14px 0;font:500 11px/1.2 ${F};letter-spacing:3.5px;text-transform:uppercase;color:${isNew ? "#A57C52" : "#9B3B2E"};">The Court &middot; ${isAdded ? "You're in" : isNew ? "Reservation" : "Cancellation"}</p>
    <h1 style="margin:0 0 6px 0;font:400 38px/1.05 ${S};color:#24211D;">${isAdded ? `You're <em style="color:#A57C52;">playing</em>` : isNew ? `Court <em style="color:#A57C52;">booked</em>` : `Booking <em style="color:#958B7E;">cancelled</em>`}</h1>
    <p style="margin:0 0 24px 0;font:300 15px/1.6 ${F};color:#5E574E;">${isAdded ? `${esc(b.booker_name ?? b.email)} added you to this booking.` : isNew ? "The court is reserved for this time." : "This time is open again for anyone to book."}</p>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-top:1px solid #E2D9CB;">
      ${row("Day", `<span style="font-size:24px;${!isNew ? "text-decoration:line-through;color:#958B7E;" : ""}">${esc(dayLabel)}, ${esc(dateLabel)}</span>`)}
      ${row("Time", `<span style="${!isNew ? "text-decoration:line-through;color:#958B7E;" : ""}">${esc(timeLabel)}</span>`)}
      ${row("Booked by", `${esc(who)}<br><span style="font:300 13px/1.6 ${F};color:#958B7E;">${esc(b.email)}</span>`)}
      ${playerNames.length ? row("Playing with", esc(playerNames.join(", "))) : ""}
      ${b.note ? row("Comment", `<span style="font-style:italic;color:#5E574E;border-left:2px solid #C9A57E;padding-left:12px;display:inline-block;">&ldquo;${esc(b.note)}&rdquo;</span>`) : ""}
      ${!isNew ? row("Cancelled by", esc(b.cancelled_by ?? "")) : ""}
    </table>
    ${siteUrl ? `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:28px;"><tr><td style="background:#24211D;">
      <a href="${esc(siteUrl)}" style="display:inline-block;padding:15px 26px;font:500 11.5px/1 ${F};letter-spacing:3px;text-transform:uppercase;color:#F6F2EB;text-decoration:none;">Open the schedule</a>
    </td></tr></table>` : ""}
  </td></tr>
  <tr><td style="padding:22px 4px 0 4px;font:300 12px/1.6 ${F};color:#958B7E;">
    You're receiving this because you were added to this booking or are on the court's notification list.<br>
    House by Shigeru Ban &middot; 224 NE 59th St, Miami, FL 33137 &middot; Times in Miami time (ET)
  </td></tr>
</table></td></tr></table></body></html>`;

  let sent = 0; const failed: unknown[] = [];
  if (smtpUser && smtpPass) {
    const client = new SMTPClient({ connection: { hostname: smtpHost, port: 465, tls: true, auth: { username: smtpUser, password: smtpPass } } });
    try {
      for (const to of recipients) {
        try { await client.send({ from: `${fromName} <${smtpUser}>`, to, subject, content: text, html }); sent++; }
        catch (e) { failed.push({ to, error: String(e) }); }
      }
    } finally { try { await client.close(); } catch { /* ignore */ } }
  } else if (resendKey && resendFrom) {
    for (const to of recipients) {
      const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" }, body: JSON.stringify({ from: resendFrom, to: [to], subject, html, text }) });
      if (r.ok) sent++; else failed.push({ to, status: r.status });
    }
  } else {
    return json({ skipped: "no_email_configured", recipients: recipients.length });
  }

  if (sent > 0 && !isAdded) {
    await admin.from("bookings").update(event === "created" ? { notified_created_at: new Date().toISOString() } : { notified_cancelled_at: new Date().toISOString() }).eq("id", b.id);
  }
  return json({ sent, failed });
});
