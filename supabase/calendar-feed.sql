-- Personal calendar feeds (subscribe once in Apple/Google/Outlook Calendar).
-- Run once in Supabase → SQL Editor. Additive: changes nothing that exists.
create table if not exists public.calendar_feeds (
  email text primary key references public.approved_emails(email) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default now()
);
alter table public.calendar_feeds enable row level security;  -- no policies: only the server reads it
revoke all on public.calendar_feeds from anon, authenticated;

-- Returns the signed-in manager's private feed token, creating it on first use.
create or replace function public.my_calendar_token()
returns uuid language plpgsql security definer set search_path = public as $$
declare e text := lower(auth.jwt() ->> 'email'); t uuid;
begin
  if e is null or not exists (select 1 from approved_emails where email = e) then
    raise exception 'not_approved';
  end if;
  insert into calendar_feeds(email) values (e) on conflict (email) do nothing;
  select token into t from calendar_feeds where email = e;
  return t;
end $$;
revoke all on function public.my_calendar_token() from public, anon;
grant execute on function public.my_calendar_token() to authenticated;

-- Replaces the token (old subscription stops working). For a leaked link.
create or replace function public.reset_my_calendar_token()
returns uuid language plpgsql security definer set search_path = public as $$
declare e text := lower(auth.jwt() ->> 'email'); t uuid;
begin
  if e is null or not exists (select 1 from approved_emails where email = e) then
    raise exception 'not_approved';
  end if;
  insert into calendar_feeds(email, token) values (e, gen_random_uuid())
    on conflict (email) do update set token = gen_random_uuid(), created_at = now()
    returning token into t;
  return t;
end $$;
revoke all on function public.reset_my_calendar_token() from public, anon;
grant execute on function public.reset_my_calendar_token() to authenticated;

-- Direct Google Calendar sync: one row per manager who wants their court
-- bookings written into an existing Google Calendar (shared with the service account).
create table if not exists public.calendar_sync (
  email text primary key references public.approved_emails(email) on delete cascade,
  calendar_id text not null,
  created_at timestamptz not null default now()
);
alter table public.calendar_sync enable row level security;  -- server only
revoke all on public.calendar_sync from anon, authenticated;
