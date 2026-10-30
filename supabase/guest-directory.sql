-- Guest book for the "Someone else…" player spots: every guest from past
-- bookings, with their most recent email. One entry per person: the same email
-- is the same person (newest spelling of the name wins), so typos don't show
-- twice. Approved managers only (they can already see guests on the schedule).
create or replace function public.guest_directory()
returns table (name text, email text, last_used timestamptz, uses int)
language sql stable security definer set search_path = '' as $$
  with me as (select exists (select 1 from public.approved_emails a where a.email = public.current_email()) as ok),
  g as (
    select regexp_replace(btrim(e->>'name'), '\s+', ' ', 'g') as name, nullif(lower(btrim(e->>'email')), '') as email, b.created_at
    from public.bookings b, jsonb_array_elements(coalesce(b.guest_entries, '[]'::jsonb)) e
    where coalesce(btrim(e->>'name'), '') <> ''
  ),
  name_email as (
    select lower(name) as k, (array_agg(email order by created_at desc))[1] as email
    from g where email is not null group by lower(name)
  ),
  keyed as (
    select g.name, coalesce(g.email, ne.email) as email, g.created_at,
           coalesce(g.email, ne.email, 'name:' || lower(g.name)) as person
    from g left join name_email ne on ne.k = lower(g.name)
  ),
  people as (
    select (array_agg(name order by created_at desc))[1] as name,
           (array_agg(email order by created_at desc))[1] as email,
           max(created_at) as last_used, count(*)::int as uses
    from keyed group by person
  )
  select p.name, p.email, p.last_used, p.uses from people p, me
  where me.ok
  order by p.last_used desc
  limit 300;
$$;
revoke all on function public.guest_directory() from public, anon;
grant execute on function public.guest_directory() to authenticated;
