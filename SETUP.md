# The Court · House by Shigeru Ban: complete setup guide

**Goal:** the booking site at **https://shigeru-court.netlify.app** (✅ online), with sign-in codes and booking emails arriving in inboxes.
**Domain needed:** none. **Cost:** $0. **Time:** about 30 minutes.

Work through the parts in order. Each one ends with a ✅ check. Don't move on until the check passes.

---

## How it fits together

| Piece | What it does | Status |
|---|---|---|
| **Netlify** (free) | Hosts the web page | ✅ Online at https://shigeru-court.netlify.app (re-upload the latest zip: Part 1) |
| **Gmail: housepadelcourt@gmail.com** (free) | Sends sign-in codes and booking emails (500/day) | ✅ Created. You still do 2b–2c |
| **Supabase** project **shigeru-ban-court** in org **House by Shigeru Ban** (free) | Database, logins, booking rules, email function | ✅ Built. You connect Gmail in Parts 3–4 |
| Your admin access | The first admin email is set up as admin, can book, gets notified | ✅ Done |

**Your Supabase project:** https://supabase.com/dashboard/project/uaaderuakjvtqhbztoig
Every "Supabase" step below starts from this link.

> **Is a hidden address enough security?** No, and it doesn't need to be. Even if a stranger finds the link, they can only see which hours are busy. Names, comments and booking require signing in with an email you approved, and the database enforces that.

---

## Part 1: Update the live site (Netlify) ✅ site exists, re-upload once

Your site is already online at **https://shigeru-court.netlify.app**, but it holds an **older version** that points at the old, paused database. Replace it with the latest zip:

1. On your computer, **unzip the newest `shigeru-court-site.zip`** (the one sent with this guide). You get a folder containing `index.html`, `SETUP.md` and a `supabase` folder.
2. Go to **https://app.netlify.com** → click the **shigeru-court** site → **Deploys**.
3. Scroll to the box **"Need to update your site? Drag and drop your site output folder here"** and **drag the unzipped folder** onto it.
4. Wait for **Published** (a few seconds).

✅ **Check:** open https://shigeru-court.netlify.app and hard-refresh (Mac: Cmd+Shift+R, Windows: Ctrl+F5).
- The "Right now" box shows **Available**, **In use** or **Closed for booking**.
- If it says **"Schedule unavailable"**, the old file is still live: repeat step 3.

---

## Part 2: Create the sending Gmail account

All emails come from **housepadelcourt@gmail.com**, a neutral sender, so the app password never touches your personal account.

### 2a. Create the account ✅ done
The court's sending account is **housepadelcourt@gmail.com**. Do 2b and 2c signed in to that account (a private/incognito window helps if your personal Gmail is also signed in).

### 2b. Turn on 2-Step Verification (Google requires it for app passwords)
1. Signed in as housepadelcourt@gmail.com, go to **https://myaccount.google.com/signinoptions/twosv**.
2. Click **Turn on 2-Step Verification** and follow the prompts. Your phone number is fine.

### 2c. Create an app password
1. Go to **https://myaccount.google.com/apppasswords** (still signed in as housepadelcourt@gmail.com).
2. App name: `Court site` → **Create**.
3. Google shows a **16-letter password** like `abcd efgh ijkl mnop`. **Copy it now**, because it's shown only once.
   Below it's called **APP-PASSWORD**. Spaces don't matter.

> If the app passwords page says "not available", 2-Step Verification isn't on yet. Redo 2b.
> If you ever change housepadelcourt@gmail.com's normal password, Google cancels the app password. Create a new one and update Parts 3a and 4.

✅ **Check:** you have housepadelcourt@gmail.com and a 16-letter APP-PASSWORD written down.

---

## Part 3: Make Supabase send sign-in emails through Gmail

Supabase's built-in mailer only emails people in your Supabase organization, so the rest of the team would never get their code. This part fixes that.

### 3a. SMTP settings
Open **Supabase → Authentication → Emails → SMTP Settings**
(direct link: https://supabase.com/dashboard/project/uaaderuakjvtqhbztoig/auth/smtp). Turn on **Enable custom SMTP** and fill in:

| Field | Value |
|---|---|
| Sender email | housepadelcourt@gmail.com (must be exactly the Gmail address) |
| Sender name | `The Court · House by Shigeru Ban` |
| Host | `smtp.gmail.com` |
| Port | `465` |
| Minimum interval between emails | `10` (seconds) |
| Username | housepadelcourt@gmail.com |
| Password | APP-PASSWORD (no spaces) |

Click **Save changes**.

### 3b. Email templates (styled to match the site, with the 6-digit code)
Open **Authentication → Emails → Templates**
(https://supabase.com/dashboard/project/uaaderuakjvtqhbztoig/auth/templates).

People get **Confirm signup** on their very first sign-in and **Magic Link** after that. Give **both** the same template:

1. On your computer, open **`email-templates/sign-in-code.html`** from the zip in a text editor (TextEdit on Mac: Format → Make Plain Text first; Notepad on Windows). Select all and copy.
2. In Supabase, click **Confirm signup**:
   - **Subject:** `Your sign-in code for The Court`
   - **Body:** select everything in the box, delete it, and paste the template.
   - Click **Save**.
3. Click **Magic Link** and do exactly the same (same subject, same body) → **Save**.

> Keep `{{ .Token }}`, `{{ .ConfirmationURL }}` and `{{ .Email }}` exactly as they are. Supabase replaces them with the code, the link and the person's email.
> The booking and cancellation emails already use the same design. They're built into the notification function, so there's nothing to paste for those.

### 3c. Site address and redirects
Open **Authentication → URL Configuration**
(https://supabase.com/dashboard/project/uaaderuakjvtqhbztoig/auth/url-configuration).

- **Site URL:** `https://shigeru-court.netlify.app`
- **Redirect URLs → Add URL:** `https://shigeru-court.netlify.app/**`

Save.

### 3d. Email rate limit
Open **Authentication → Rate Limits**
(https://supabase.com/dashboard/project/uaaderuakjvtqhbztoig/auth/rate-limits). Set **Rate limit for sending emails** to `60` per hour → Save.

✅ **Check:** open https://shigeru-court.netlify.app → **Sign in** → enter your admin email → **Send code**.
- Within a minute you get an email from "The Court" with a 6-digit code. Check spam the first time and mark it "Not spam".
- Enter the code and you're signed in. **Manage** appears in the top bar.

---

## Part 4: Turn on booking notifications

Open **Edge Functions → Secrets**
(https://supabase.com/dashboard/project/uaaderuakjvtqhbztoig/functions/secrets) and add these four secrets, clicking **Save** after each:

| Name (type exactly) | Value |
|---|---|
| `SMTP_USER` | `housepadelcourt@gmail.com` |
| `SMTP_PASS` | APP-PASSWORD |
| `NOTIFY_FROM_NAME` | `The Court · House by Shigeru Ban` |
| `SITE_URL` | `https://shigeru-court.netlify.app` |

No redeploy is needed. The notification function reads these on every booking.

✅ **Check:**
1. On the site: **Book the court** → pick tomorrow at any open time → comment `Test booking` → **Confirm booking**.
2. Within a minute you get a **"Court booked"** email.
3. Click your booking on the grid → **Cancel booking** → you get a **"Court cancelled"** email.

---

## Part 5: Delete any old, paused copies

If an earlier test copy of this system exists in another Supabase organization, delete it from that project's **Settings → General → Delete project** so it stops using a free project slot. Double-check the project ID in the address bar before deleting. **Never delete `uaaderuakjvtqhbztoig`**, the live court project.

---

## Part 6: Add people

On the site, signed in → **Manage → People**:

1. Type the person's **email** and **full name**. The name is what appears on their bookings.
2. Choose:
   - **Can book**: they can reserve the court. Leave it unticked for people who should only get notifications, such as building staff.
   - **Notify on bookings**: they get an email for every booking and cancellation.
   - **Admin**: they can manage people and rules. Keep this list short.
3. Click **Add**.
4. Send them https://shigeru-court.netlify.app and tell them to **Sign in** with that exact email.

To remove someone, click **Remove**. Their future bookings stay on the calendar, and you can cancel those by clicking them.

**Email budget:** Gmail sends up to 500 emails a day. Each booking emails every "Notify" person plus the booker. With 5 people on the notify list that's 6 emails per booking, so you'd need more than 80 bookings in a day to hit the limit.

---

## Part 7: Booking rules

**Manage → Booking rules**:

| Rule | Default | Notes |
|---|---|---|
| Opens / Closes | 7:00 AM / 10:00 PM | Miami time, on the half hour |
| Shortest booking | 30 min | |
| Longest booking | 180 min | |
| Book up to | 7 days ahead | The grid always shows 7 days |
| Max bookings per person per week | 3 | `0` = unlimited. Admins are exempt |

The database enforces these rules, so no one can get around them from their browser.

---

## Part 8: Automatic updates (GitHub → Netlify, one-time link)

The site's files live in the private GitHub repository **padelinnercircle/shigeru-court**. Once Netlify is linked to it, every change Claude pushes goes live in about 30 seconds. **You never upload a zip again.**

**Link it once:**
1. Netlify → **shigeru-court** site → **Site configuration → Build & deploy → Continuous deployment** → **Link repository** (it may say "Link site to Git").
2. Choose **GitHub** → approve Netlify's access if asked → pick **padelinnercircle/shigeru-court**.
   - If the repository isn't in the list, click **Configure the Netlify app on GitHub** and give Netlify access to `shigeru-court`.
3. **Branch to deploy:** `main`. **Build command:** leave empty. **Publish directory:** leave as `site` (the repo's `netlify.toml` sets it).
4. Click **Deploy** / **Save**.

✅ **Check:** Netlify → **Deploys** shows a deploy from **main** marked **Published**, and https://shigeru-court.netlify.app/SETUP.md now shows "Page not found". Only the web page is public.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| **"That email isn't on the approved list"** | Add the email under Manage → People. It must match exactly; capitals don't matter. |
| **No sign-in email arrives** | Check spam. Recheck Part 3a: port `465`, and the sender email and username are both housepadelcourt@gmail.com. Supabase → **Logs → Auth** shows the exact error. `535` / `534-5.7.9` means the app password is wrong or missing: redo Part 2c. |
| **"Email rate limit exceeded"** | Raise the limit in Part 3d, or wait an hour. |
| **Code says "expired" or "invalid"** | Only the newest code works, for 1 hour. Request a fresh one. |
| **Google blocks the account or sends a "suspicious sign-in" alert** | Sign in to housepadelcourt@gmail.com, approve the activity ("Yes, it was me"), then try again. It's common in the first days of a new account. |
| **Bookings work but no notification emails** | Check the four secrets in Part 4 (exact names). Supabase → **Edge Functions → notify-booking → Logs** shows the error. |
| **Site says "Couldn't load the schedule"** | The free Supabase project pauses after 7 days without activity. Supabase dashboard → **Restore project** (takes a few minutes). |
| **The sign-in link opens a blank or wrong page** | Part 3c: the Site URL must be https://shigeru-court.netlify.app. Or just type the 6-digit code instead. |

---

## Reference

- **Supabase project:** shigeru-ban-court · ID `uaaderuakjvtqhbztoig` · us-east-1 · free plan
- **API address:** `https://uaaderuakjvtqhbztoig.supabase.co`
- **Public key (already in `index.html`):** `sb_publishable_Rf4FIGbOZd1DonxuOudIZw_w6LKyXWj`. This key is public by design; the database rules enforce access.
- **Never put the Gmail app password in `index.html`.** It belongs only in Supabase (Parts 3a and 4).
- **Preview with fake data:** add `?demo` to the address, e.g. `https://shigeru-court.netlify.app/?demo`
- **Free-plan limits:**
  - Supabase: 500 MB database, paused after 7 days without activity.
  - Gmail: 500 emails/day.
  - Netlify: free for a site this size.
- **Moving to a real domain later:** buy any domain, add it in Netlify → Domain management, then update the Site URL (Part 3c) and `SITE_URL` (Part 4). Nothing else changes.
