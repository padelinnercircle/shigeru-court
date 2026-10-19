# The Court · House by Shigeru Ban

Booking site for the court at House by Shigeru Ban, 224 NE 59th St, Miami.

- **Live site:** https://shigeru-court.netlify.app (auto-deploys from `main`)
- **Database / logins / email function:** Supabase project `shigeru-ban-court` (org: House by Shigeru Ban)

| Path | What it is | Public? |
|---|---|---|
| `site/index.html` | The whole website (7-day schedule, booking, admin) | Yes |
| `supabase/setup.sql` | Full database setup: tables, rules, security | No |
| `supabase/functions/notify-booking/` | Booking/cancellation email function | No |
| `email-templates/sign-in-code.html` | Sign-in email template, pasted into Supabase Auth | No |
| `SETUP.md` | Step-by-step setup guide | No |

**Daily keep-alive:** `.github/workflows/keep-alive.yml` queries the database every morning so the free Supabase project never pauses, and keeps itself enabled. Run it by hand from the **Actions** tab → **Keep database awake** → **Run workflow**.

Only `site/` is published (see `netlify.toml`). Never commit passwords or API keys:
the Gmail app password lives only in Supabase.
