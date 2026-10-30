-- Guest book for the "Someone else…" player spots: every guest name used in a
-- past booking, with the email most recently given for that name. Approved
-- managers only (they can already see guests on the schedule).
create or replace function public.guest_directory()
returns table (name text, email text, last_used timestamptz, uses int)
language sql stable security definer set search_path = '' as $$
  with me as (select exists (select 1 from public.approved_emails a where a.email = public.current_email()) as ok),
  g as (
    select btrim(e->>'name') as name, nullif(lower(btrim(e->>'email')), '') as email, b.created_at
    from public.bookings b, jsonb_array_elements(coalesce(b.guest_entries, '[]'::jsonb)) e
    where coalesce(btrim(e->>'name'), '') <> ''
  ),
  ranked as (
    select lower(name) as k,
           (array_agg(name order by created_at desc))[1] as name,
           (array_agg(email order by created_at desc) filter (where email is not null))[1] as email,
           max(created_at) as last_used, count(*)::int as uses
    from g group by lower(name)
  )
  select r.name, r.email, r.last_used, r.uses from ranked r, me
  where me.ok
  order by r.last_used desc
  limit 300;
$$;
revoke all on function public.guest_directory() from public, anon;
grant execute on function public.guest_directory() to authenticated;

-- v2: one entry per person. Same email = same person (newest spelling of the
-- name wins), so typos like "Baranovsky"/"Baronovsky" don't show up twice.
-- (Applied as migration guest_directory_dedupe_by_email; see the live function.)
