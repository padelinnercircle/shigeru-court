-- Change a booking's day/time (drag-and-drop on the schedule, or "Change time").
-- Same rules as a new booking: open hours, slot steps, min/max length, booking
-- window, weekly limit for non-admins, and no overlaps (the exclusion constraint).
-- Only the booker or an admin can move it, and only before it starts.
alter table public.bookings add column if not exists prev_starts_at timestamptz;
alter table public.bookings add column if not exists prev_ends_at timestamptz;
alter table public.bookings add column if not exists modified_at timestamptz;
alter table public.bookings add column if not exists modified_by text;
alter table public.bookings add column if not exists notified_modified_at timestamptz;
alter table public.bookings add column if not exists revision int not null default 0;

create or replace function public.move_booking(p_id uuid, p_starts_at timestamptz, p_ends_at timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings; s public.settings; a public.approved_emails; tz text;
  ls timestamp; le timestamp; dur int; wk_count int;
begin
  select * into b from public.bookings where id = p_id for update;
  if b.id is null or b.status <> 'confirmed' then raise exception 'Booking not found.'; end if;
  if b.user_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'You can only change your own bookings.';
  end if;
  if b.starts_at <= now() then raise exception 'A booking that has already started can''t be moved.'; end if;
  if p_starts_at = b.starts_at and p_ends_at = b.ends_at then return; end if;

  select * into s from public.settings where id = 1;
  tz := s.timezone;
  ls := p_starts_at at time zone tz;
  le := p_ends_at at time zone tz;
  dur := (extract(epoch from (p_ends_at - p_starts_at)) / 60)::int;

  if p_ends_at <= p_starts_at then raise exception 'The end time must be after the start time.'; end if;
  if p_starts_at <= now() then raise exception 'That start time has already passed.'; end if;
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

  -- Weekly limit applies to the booker (not to an admin moving it for them).
  select * into a from public.approved_emails where email = b.email;
  if (a.email is null or not a.is_admin) and s.max_bookings_per_week > 0
     and date_trunc('week', b.starts_at at time zone tz) <> date_trunc('week', ls) then
    select count(*) into wk_count from public.bookings x
    where x.user_id = b.user_id and x.status = 'confirmed' and x.id <> b.id
      and date_trunc('week', x.starts_at at time zone tz) = date_trunc('week', ls);
    if wk_count >= s.max_bookings_per_week then
      raise exception 'That week already has % booking(s) by this person (limit %).', wk_count, s.max_bookings_per_week;
    end if;
  end if;

  update public.bookings set
    prev_starts_at = b.starts_at, prev_ends_at = b.ends_at,
    starts_at = p_starts_at, ends_at = p_ends_at,
    modified_at = now(), modified_by = public.current_email(),
    notified_modified_at = null, revision = b.revision + 1
  where id = p_id;
end;
$$;
revoke all on function public.move_booking(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.move_booking(uuid, timestamptz, timestamptz) to authenticated;
