-- Moves Santiago's court account from his Gmail to his PIC address.
-- Run AFTER signing in once on the court site with santi@padelinnercircle.com.
-- Safe to run twice. Moves bookings (as booker and as player) and the Google
-- Calendar sync, then removes the Gmail from the approved list.
do $$
declare
  old_e text := 's.garciamateosagasta@gmail.com';
  new_e text := 'santi@padelinnercircle.com';
  new_uid uuid;
begin
  select id into new_uid from auth.users where lower(email) = new_e;
  if new_uid is null then
    raise exception 'Sign in once on the court site with % first, then run this again.', new_e;
  end if;
  if not exists (select 1 from public.approved_emails where email = new_e and is_admin) then
    raise exception '% is not an admin on the approved list yet.', new_e;
  end if;

  update public.bookings set user_id = new_uid, email = new_e where email = old_e;
  update public.bookings set players = array_replace(players, old_e, new_e) where old_e = any(players);

  insert into public.calendar_sync (email, calendar_id, act_as, include_added)
    select new_e, calendar_id, act_as, include_added from public.calendar_sync where email = old_e
  on conflict (email) do update
    set calendar_id = excluded.calendar_id, act_as = excluded.act_as, include_added = excluded.include_added;

  delete from public.approved_emails where email = old_e;  -- also clears the Gmail's calendar rows
end $$;

select email, is_admin, can_book, notify_on_booking from public.approved_emails where email in ('santi@padelinnercircle.com', 's.garciamateosagasta@gmail.com');
select count(*) as bookings_now_under_pic_email from public.bookings where email = 'santi@padelinnercircle.com';
select email, include_added from public.calendar_sync;
