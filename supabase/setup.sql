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
  notify_on_booking boolean not null default true,
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

create or replace function public.my_profile()
returns table (email text, full_name text, can_book boolean, is_admin boolean, notify_on_booking boolean)
language sql stable security definer set search_path = '' as $$
  select a.email, a.full_name, a.can_book, a.is_admin, a.notify_on_booking
  from public.approved_emails a where a.email = public.current_email();
$$;
revoke execute on function public.my_profile() from public, anon;
grant execute on function public.my_profile() to authenticated;

-- Each approved person can switch their own booking emails on or off.
create or replace function public.set_my_notifications(p_on boolean)
returns boolean language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.approved_emails set notify_on_booking = p_on where email = public.current_email();
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Your email is not on the approved list.'; end if;
  return p_on;
end;
$$;
revoke execute on function public.set_my_notifications(boolean) from public, anon;
grant execute on function public.set_my_notifications(boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Booking party: other members (players) and people not on the site (guests).
-- Guests are an email (notified) or just a name (shown only). Max 3 per booking.
alter table public.bookings add column if not exists players text[] not null default '{}';
alter table public.bookings add column if not exists guests text[] not null default '{}';

create or replace function public.reset_booking_players()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.players := '{}';
  new.guests := '{}';
  return new;
end;
$$;
revoke execute on function public.reset_booking_players() from public, anon, authenticated;
create trigger bookings_reset_players before insert on public.bookings
for each row execute function public.reset_booking_players();

create or replace function public.list_members()
returns table (email text, full_name text)
language sql stable security definer set search_path = '' as $$
  select a.email, coalesce(nullif(btrim(a.full_name), ''), split_part(a.email, '@', 1))
  from public.approved_emails a
  where a.can_book
    and exists (select 1 from public.approved_emails me where me.email = public.current_email())
  order by 2;
$$;
revoke execute on function public.list_members() from public, anon;
grant execute on function public.list_members() to authenticated;

create or replace function public.set_booking_players(p_booking uuid, p_emails text[])
returns integer language plpgsql security definer set search_path = '' as $$
declare b public.bookings; clean text[]; mem text[]; gst text[]; bad text;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or b.status <> 'confirmed' then raise exception 'Booking not found.'; end if;
  if b.user_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Only the person who booked can change who is playing.';
  end if;
  if b.ends_at <= now() then raise exception 'Past bookings cannot be changed.'; end if;
  select coalesce(array_agg(x order by x), '{}') into clean from (
    select distinct case when position('@' in e) > 0 then lower(btrim(e)) else regexp_replace(btrim(e), '\s+', ' ', 'g') end as x
    from unnest(coalesce(p_emails, '{}')) e
    where btrim(e) <> '' and lower(btrim(e)) <> b.email) s;
  if coalesce(array_length(clean, 1), 0) > 3 then raise exception 'A booking can include up to 3 other players.'; end if;
  select e into bad from unnest(clean) e
  where (position('@' in e) > 0 and (e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(e) > 254))
     or (position('@' in e) = 0 and char_length(e) > 60) limit 1;
  if bad is not null then raise exception '"%" is not a valid email address or name.', bad; end if;
  select coalesce(array_agg(e order by e), '{}') into mem from unnest(clean) e
  where exists (select 1 from public.approved_emails a where a.email = e and a.can_book);
  select coalesce(array_agg(e order by e), '{}') into gst from unnest(clean) e where not (e = any(mem));
  update public.bookings set players = mem, guests = gst where id = p_booking;
  return coalesce(array_length(clean, 1), 0);
end;
$$;
revoke execute on function public.set_booking_players(uuid, text[]) from public, anon;
grant execute on function public.set_booking_players(uuid, text[]) to authenticated;

create or replace function public.get_schedule_v3(p_from timestamptz, p_to timestamptz)
returns table (id uuid, starts_at timestamptz, ends_at timestamptz, booker_name text, note text,
               is_mine boolean, is_player boolean, players text[], player_emails text[], guests text[])
language sql stable security definer set search_path = '' as $$
  with me as (
    select exists (select 1 from public.approved_emails a where a.email = public.current_email()) as approved,
           public.current_email() as email
  )
  select b.id, b.starts_at, b.ends_at,
         case when me.approved then b.booker_name end,
         case when me.approved then b.note end,
         (b.user_id = auth.uid()),
         (me.email <> '' and me.email = any(b.players)),
         case when me.approved then coalesce((
           select array_agg(coalesce(nullif(btrim(a.full_name), ''), split_part(p.e, '@', 1)) order by p.ord)
           from unnest(b.players) with ordinality as p(e, ord)
           left join public.approved_emails a on a.email = p.e), '{}') else '{}' end,
         case when me.approved then b.players else '{}' end,
         case when me.approved then b.guests else '{}' end
  from public.bookings b, me
  where b.status = 'confirmed' and b.ends_at > p_from and b.starts_at < p_to
    and p_to - p_from <= interval '62 days'
  order by b.starts_at;
$$;
grant execute on function public.get_schedule_v3(timestamptz, timestamptz) to anon, authenticated;

-- First admin: replace with the real admin email before running.
insert into public.approved_emails (email, full_name, can_book, is_admin, notify_on_booking)
values ('admin@example.com', 'Court Admin', true, true, true);

select 'Setup complete' as result;
