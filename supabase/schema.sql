-- 3Kings Supabase schema (run in SQL Editor on a NEW project)
-- Single court, flexible hourly reservations, live admin-controlled price.
-- Payment providers must be integrated separately; never trust client payment status.

create table if not exists public.court_settings (
  id boolean primary key default true check (id = true),
  court_name text not null default 'Court 1',
  hourly_rate numeric(10,2) not null default 250.00 check (hourly_rate >= 0),
  currency text not null default 'PHP',
  updated_at timestamptz not null default now()
);
insert into public.court_settings(id, court_name, hourly_rate, currency)
values (true, 'Court 1', 250.00, 'PHP') on conflict (id) do nothing;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  email text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.court_bookings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  court_name text not null default 'Court 1',
  start_at timestamptz not null,
  end_at timestamptz not null,
  duration_hours integer not null check (duration_hours between 1 and 24),
  hourly_rate numeric(10,2) not null check (hourly_rate >= 0),
  total_price numeric(10,2) not null check (total_price >= 0),
  status text not null default 'pending' check (status in ('pending','confirmed','cancelled','expired')),
  payment_method text check (payment_method is null or payment_method in ('walk_in','paymongo')),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','pending','paid','failed','refunded')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint valid_booking_time check (end_at > start_at),
  constraint duration_matches_time check (end_at = start_at + duration_hours * interval '1 hour'),
  -- A pending booking also blocks the slot. [) allows 10am start after an 8-10am booking.
  constraint no_overlapping_court_bookings exclude using gist (
    tstzrange(start_at, end_at, '[)') with &&
  ) where (status in ('pending','confirmed'))
);
create index if not exists court_bookings_user_start_idx on public.court_bookings(user_id, start_at);
create index if not exists court_bookings_status_start_idx on public.court_bookings(status, start_at);

create table if not exists public.booking_payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.court_bookings(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  payment_method text not null check (payment_method in ('walk_in','paymongo')),
  amount numeric(10,2) not null check (amount >= 0),
  status text not null default 'pending' check (status in ('pending','succeeded','failed','refunded')),
  provider_reference text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists booking_payments_booking_idx on public.booking_payments(booking_id);

-- Trusted admin role is assigned only by Supabase Auth Admin API in app_metadata.role.
create or replace function public.is_court_admin()
returns boolean language sql stable security invoker set search_path = '' as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin';
$$;

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end;
$$;

drop trigger if exists court_settings_updated_at on public.court_settings;
create trigger court_settings_updated_at before update on public.court_settings
for each row execute function public.set_updated_at();
drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at before update on public.profiles
for each row execute function public.set_updated_at();
drop trigger if exists court_bookings_updated_at on public.court_bookings;
create trigger court_bookings_updated_at before update on public.court_bookings
for each row execute function public.set_updated_at();
drop trigger if exists booking_payments_updated_at on public.booking_payments;
create trigger booking_payments_updated_at before update on public.booking_payments
for each row execute function public.set_updated_at();

-- Create profile after signup; password remains managed by Supabase Auth.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id, full_name, email)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name',''), new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.handle_user_email_update()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.email is distinct from old.email then
    update public.profiles set email = new.email where id = new.id;
  end if;
  return new;
end;
$$;
drop trigger if exists on_auth_user_email_updated on auth.users;
create trigger on_auth_user_email_updated after update of email on auth.users
for each row execute function public.handle_user_email_update();

alter table public.court_settings enable row level security;
alter table public.profiles enable row level security;
alter table public.court_bookings enable row level security;
alter table public.booking_payments enable row level security;

-- Court price can be read by customers, changed only by an admin.
drop policy if exists court_settings_read on public.court_settings;
create policy court_settings_read on public.court_settings for select to anon, authenticated using (true);
drop policy if exists court_settings_admin_update on public.court_settings;
create policy court_settings_admin_update on public.court_settings for update to authenticated
using (public.is_court_admin()) with check (public.is_court_admin());
drop policy if exists court_settings_admin_insert on public.court_settings;
create policy court_settings_admin_insert on public.court_settings for insert to authenticated
with check (public.is_court_admin());
drop policy if exists court_settings_admin_delete on public.court_settings;
create policy court_settings_admin_delete on public.court_settings for delete to authenticated
using (public.is_court_admin());

-- Profile CRUD: users can access only their own profile; admins can read/manage all.
drop policy if exists profiles_select_own_admin on public.profiles;
create policy profiles_select_own_admin on public.profiles for select to authenticated
using (auth.uid() = id or public.is_court_admin());
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
using (auth.uid() = id or public.is_court_admin()) with check (auth.uid() = id or public.is_court_admin());
drop policy if exists profiles_admin_delete on public.profiles;
create policy profiles_admin_delete on public.profiles for delete to authenticated
using (public.is_court_admin());
grant select, update on public.profiles to authenticated;

-- Customer read access is limited to their own rows; admin has full CRUD.
drop policy if exists bookings_select_own_admin on public.court_bookings;
create policy bookings_select_own_admin on public.court_bookings for select to authenticated
using (auth.uid() = user_id or public.is_court_admin());
drop policy if exists bookings_admin_insert on public.court_bookings;
create policy bookings_admin_insert on public.court_bookings for insert to authenticated
with check (public.is_court_admin());
drop policy if exists bookings_admin_update on public.court_bookings;
create policy bookings_admin_update on public.court_bookings for update to authenticated
using (public.is_court_admin()) with check (public.is_court_admin());
drop policy if exists bookings_admin_delete on public.court_bookings;
create policy bookings_admin_delete on public.court_bookings for delete to authenticated
using (public.is_court_admin());

-- Customer read access is limited to own payment rows. Payment writes must be trusted backend/admin.
drop policy if exists payments_select_own_admin on public.booking_payments;
create policy payments_select_own_admin on public.booking_payments for select to authenticated
using (auth.uid() = user_id or public.is_court_admin());
drop policy if exists payments_admin_insert on public.booking_payments;
create policy payments_admin_insert on public.booking_payments for insert to authenticated
with check (public.is_court_admin());
drop policy if exists payments_admin_update on public.booking_payments;
create policy payments_admin_update on public.booking_payments for update to authenticated
using (public.is_court_admin()) with check (public.is_court_admin());
drop policy if exists payments_admin_delete on public.booking_payments;
create policy payments_admin_delete on public.booking_payments for delete to authenticated
using (public.is_court_admin());

-- Availability exposes only occupied time ranges, not customer identities or payment data.
create or replace function public.get_court_bookings(p_from timestamptz, p_to timestamptz)
returns table(booking_start timestamptz, booking_end timestamptz)
language sql stable security definer set search_path = '' as $$
  select b.start_at, b.end_at from public.court_bookings b
  where b.status in ('pending','confirmed')
    and b.start_at < p_to and b.end_at > p_from
  order by b.start_at;
$$;
grant execute on function public.get_court_bookings(timestamptz,timestamptz) to authenticated;

-- Secure create operation: database fetches current price and exclusion constraint rejects overlap.
create or replace function public.create_court_booking(
  p_start_at timestamptz,
  p_duration_hours integer,
  p_payment_method text default null
)
returns public.court_bookings
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_rate numeric(10,2);
  v_court text;
  v_booking public.court_bookings;
begin
  if v_user is null then raise exception 'Please sign in before booking.'; end if;
  if p_start_at is null or p_start_at <= now()
     or extract(minute from p_start_at) <> 0 or extract(second from p_start_at) <> 0 then
    raise exception 'Choose a future start time on the hour.';
  end if;
  if p_duration_hours is null or p_duration_hours < 1 or p_duration_hours > 24 then
    raise exception 'Duration must be between 1 and 24 hours.';
  end if;
  if p_payment_method is not null and p_payment_method not in ('walk_in','paymongo') then
    raise exception 'Invalid payment method.';
  end if;
  select hourly_rate, court_name into v_rate, v_court
  from public.court_settings where id = true for share;
  if not found then raise exception 'Court settings are missing.'; end if;
  insert into public.court_bookings(user_id,court_name,start_at,end_at,duration_hours,hourly_rate,total_price,status,payment_method,payment_status)
  values(v_user,v_court,p_start_at,p_start_at + p_duration_hours * interval '1 hour',p_duration_hours,v_rate,round(v_rate * p_duration_hours,2),'pending',p_payment_method,'unpaid')
  returning * into v_booking;
  return v_booking;
exception when exclusion_violation then
  raise exception 'This time overlaps an existing reservation. Please select another time.';
end;
$$;
grant execute on function public.create_court_booking(timestamptz,integer,text) to authenticated;

-- Customers may cancel only their own pending bookings. Confirmed cancellations should be handled by policy/support.
create or replace function public.cancel_court_booking(p_booking_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_booking public.court_bookings;
begin
  if auth.uid() is null then raise exception 'Please sign in.'; end if;
  select * into v_booking from public.court_bookings
  where id = p_booking_id and user_id = auth.uid() for update;
  if not found then raise exception 'Booking not found.'; end if;
  if v_booking.status <> 'pending' then raise exception 'Only pending bookings can be cancelled by the customer.'; end if;
  update public.court_bookings set status = 'cancelled' where id = p_booking_id;
end;
$$;
grant execute on function public.cancel_court_booking(uuid) to authenticated;

-- Backfill profiles for any users who existed before this schema was installed.
insert into public.profiles(id, full_name, email)
select id, coalesce(raw_user_meta_data ->> 'full_name',''), email from auth.users
on conflict (id) do nothing;

-- Enable Realtime on relevant tables. Availability function remains the privacy-safe initial load.
do $$ declare t text; begin
  foreach t in array array['court_settings','court_bookings','booking_payments'] loop
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ADMIN PRICE UPDATE EXAMPLE (run in SQL Editor as project owner):
-- update public.court_settings set hourly_rate = 300 where id = true;
-- To grant an admin, use Supabase Auth Admin API from a trusted server to set app_metadata.role='admin'.
