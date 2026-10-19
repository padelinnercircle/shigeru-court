-- The Court · House by Shigeru Ban — complete database setup
-- Paste this whole file into Supabase → SQL Editor → New query → Run. Run it once, on an empty project.

create extension if not exists btree_gist with schema extensions;

create table public.settings (
  id int primary key default 1 check (id = 1),
  court_name text not null default 'House by Shigeru Ban — Court',
  address text not null default '224 NE 59th St, Miami, FL',
  timezone text not null default 'America/New_York',
  open_time time not null default '07:00',
  close_time time not null default '22:00',
  slot_minutes int not null default 30 check (slot_minutes in (15, 30, 60)),
  min_minutes int not null default 30,
  max_minutes int not null default 180,
  booking_window_days int not null default 7 check (booking_window_days between 1 and 60),
  max_bookings_per_week int not null default 3 check (max_bookings_per_week >= 0),
  updated_at timestamptz not null default now()
);
insert into public.settings default values;

create table public.approved_emails (
  email text primary key check (email = lower(btrim(email)) and email like '%_@_%._%'),
  full_name text check (char_length(full_name) <= 80),
  can_book boolean not null default true,
  is_admin boolean not null default false,
  notify_on_booking boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  email text not null default '',
  booker_name text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  note text check (char_length(note) <= 200),
  status text not null default 'confirmed' check (status in ('confirmed', 'cancelled')),
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by text,
  notified_created_at timestamptz,
  notified_cancelled_at timestamptz,
  check (ends_at > starts_at),
  constraint bookings_no_overlap exclude using gist (
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status = 'confirmed')
);
create index bookings_starts_idx on public.bookings (starts_at);
create index bookings_user_idx on public.bookings (user_id);

create or replace function public.current_email()
returns text language sql stable security definer set search_path = '' as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.approved_emails a where a.email = public.current_email() and a.is_admin);
$$;

create or replace function public.validate_booking()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  s public.settings; a public.approved_emails; tz text;
  ls timestamp; le timestamp; dur int; wk_count int;
begin
  select * into s from public.settings where id = 1;
  tz := s.timezone;
  new.user_id := auth.uid();
  if new.user_id is null then raise exception 'Please sign in to book the court.'; end if;
  new.email := public.current_email();
  select * into a from public.approved_emails where email = new.email;
  if a.email is null or not a.can_book then
    raise exception 'Your email (%) is not approved to book this court.', new.email;
  end if;
  new.booker_name := coalesce(nullif(btrim(a.full_name), ''), split_part(new.email, '@', 1));
  new.status := 'confirmed'; new.created_at := now();
  new.cancelled_at := null; new.cancelled_by := null;
  new.notified_created_at := null; new.notified_cancelled_at := null;

  ls := new.starts_at at time zone tz;
  le := new.ends_at at time zone tz;
  dur := (extract(epoch from (new.ends_at - new.starts_at)) / 60)::int;

  if new.starts_at <= now() then raise exception 'That start time has already passed.'; end if;
  if ls::date <> (le - interval '1 second')::date then raise exception 'A booking must start and end on the same day.'; end if;
  if ls::time < s.open_time or le::time > s.close_time or le::time = '00:00' then
    raise exception 'The court is bookable between % and %.', to_char(s.open_time, 'FMHH12:MI AM'), to_char(s.close_time, 'FMHH12:MI AM');
  end if;
  if extract(second from ls) <> 0 or (extract(minute from ls)::int % s.slot_minutes) <> 0 or dur % s.slot_minutes <> 0 then
    raise exception 'Bookings use % minute increments.', s.slot_minutes;
  end if;
  if dur < s.min_minutes or dur > s.max_minutes then
    raise exception 'A booking must be between % and % minutes.', s.min_minutes, s.max_minutes;
  end if;
  if ls::date >= (now() at time zone tz)::date + s.booking_window_days then
    raise exception 'You can only book up to % days ahead.', s.booking_window_days;
  end if;
  if not a.is_admin and s.max_bookings_per_week > 0 then
    select count(*) into wk_count from public.bookings b
    where b.user_id = new.user_id and b.status = 'confirmed'
      and date_trunc('week', b.starts_at at time zone tz) = date_trunc('week', ls);
    if wk_count >= s.max_bookings_per_week then
      raise exception 'You already have % booking(s) that week (limit %).', wk_count, s.max_bookings_per_week;
    end if;
  end if;
  return new;
end;
$$;

create trigger bookings_validate before insert on public.bookings
for each row execute function public.validate_booking();

create or replace function public.get_schedule(p_from timestamptz, p_to timestamptz)
returns table (id uuid, starts_at timestamptz, ends_at timestamptz, booker_name text, note text, is_mine boolean)
language sql stable security definer set search_path = '' as $$
  with me as (select exists (select 1 from public.approved_emails a where a.email = public.current_email()) as approved)
  select b.id, b.starts_at, b.ends_at,
         case when me.approved then b.booker_name else null end,
         case when me.approved then b.note else null end,
         (b.user_id = auth.uid())
  from public.bookings b, me
  where b.status = 'confirmed' and b.ends_at > p_from and b.starts_at < p_to
    and p_to - p_from <= interval '62 days'
  order by b.starts_at;
$$;

create or replace function public.check_email_approved(p_email text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.approved_emails where email = lower(btrim(p_email)));
$$;

create or replace function public.my_access()
returns table (email text, full_name text, can_book boolean, is_admin boolean)
language sql stable security definer set search_path = '' as $$
  select a.email, a.full_name, a.can_book, a.is_admin from public.approved_emails a where a.email = public.current_email();
$$;

create or replace function public.cancel_booking(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_id for update;
  if b.id is null or b.status <> 'confirmed' then raise exception 'Booking not found.'; end if;
  if b.user_id is distinct from auth.uid() and not public.is_admin() then raise exception 'You can only cancel your own bookings.'; end if;
  if b.ends_at <= now() then raise exception 'Past bookings cannot be cancelled.'; end if;
  update public.bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = public.current_email() where id = p_id;
end;
$$;

alter table public.settings enable row level security;
alter table public.approved_emails enable row level security;
alter table public.bookings enable row level security;

create policy settings_read on public.settings for select to anon, authenticated using (true);
create policy settings_admin_update on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy approved_read on public.approved_emails for select to authenticated using (email = public.current_email() or public.is_admin());
create policy approved_admin_insert on public.approved_emails for insert to authenticated with check (public.is_admin());
create policy approved_admin_update on public.approved_emails for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy approved_admin_delete on public.approved_emails for delete to authenticated using (public.is_admin() and email <> public.current_email());

create policy bookings_read on public.bookings for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy bookings_insert on public.bookings for insert to authenticated with check (user_id = auth.uid());

revoke all on public.bookings from anon;
revoke update, delete, truncate on public.bookings from authenticated;
revoke all on public.approved_emails from anon;
revoke insert, update, delete, truncate on public.settings from anon;

revoke execute on function public.validate_booking() from public, anon, authenticated;
revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.current_email() from public, anon;
revoke execute on function public.cancel_booking(uuid) from public, anon;
revoke execute on function public.my_access() from public, anon;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.current_email() to authenticated;
grant execute on function public.cancel_booking(uuid) to authenticated;
grant execute on function public.my_access() to authenticated;
grant execute on function public.get_schedule(timestamptz, timestamptz) to anon, authenticated;
grant execute on function public.check_email_approved(text) to anon, authenticated;

-- First admin: replace with the real admin email before running.
insert into public.approved_emails (email, full_name, can_book, is_admin, notify_on_booking)
values ('admin@example.com', 'Court Admin', true, true, true);

select 'Setup complete' as result;
