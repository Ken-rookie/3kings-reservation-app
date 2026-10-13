-- Apply after schema.sql to enforce customer/admin separation on an existing project.
-- Admin role is trusted only from auth.users.raw_app_meta_data (JWT app_metadata).
-- Never expose a service_role key or an admin-role assignment RPC to client apps.

begin;

create or replace function public.is_court_admin()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin';
$$;

revoke all on function public.is_court_admin() from public, anon;
grant execute on function public.is_court_admin() to authenticated;

alter table public.court_settings enable row level security;
alter table public.profiles enable row level security;
alter table public.court_bookings enable row level security;
alter table public.booking_payments enable row level security;

-- Remove old or duplicate permissive policies so none can weaken these rules.
do $$
declare
  existing_policy record;
begin
  for existing_policy in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('court_settings', 'profiles', 'court_bookings', 'booking_payments')
  loop
    execute format(
      'drop policy %I on %I.%I',
      existing_policy.policyname,
      existing_policy.schemaname,
      existing_policy.tablename
    );
  end loop;
end;
$$;

-- Customers and admins can read settings; only admins can change them.
create policy court_settings_read
  on public.court_settings for select to anon, authenticated
  using (true);
create policy court_settings_admin_insert
  on public.court_settings for insert to authenticated
  with check (public.is_court_admin());
create policy court_settings_admin_update
  on public.court_settings for update to authenticated
  using (public.is_court_admin())
  with check (public.is_court_admin());
create policy court_settings_admin_delete
  on public.court_settings for delete to authenticated
  using (public.is_court_admin());

-- Customers can read/update only their own profile; admins can read customer profiles.
create policy profiles_read_self_or_admin
  on public.profiles for select to authenticated
  using (auth.uid() = id or public.is_court_admin());
create policy profiles_update_self
  on public.profiles for update to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Customers read only their own bookings. Booking creation/cancellation uses the
-- authenticated RPCs; direct booking management is reserved for admins.
create policy bookings_read_self_or_admin
  on public.court_bookings for select to authenticated
  using (auth.uid() = user_id or public.is_court_admin());
create policy bookings_admin_insert
  on public.court_bookings for insert to authenticated
  with check (public.is_court_admin());
create policy bookings_admin_update
  on public.court_bookings for update to authenticated
  using (public.is_court_admin())
  with check (public.is_court_admin());
create policy bookings_admin_delete
  on public.court_bookings for delete to authenticated
  using (public.is_court_admin());

-- Customers read their own payment records and admins can monitor all records.
-- Payment writes are reserved for trusted server/webhook workflows (service_role).
create policy payments_read_self_or_admin
  on public.booking_payments for select to authenticated
  using (auth.uid() = user_id or public.is_court_admin());

-- Keep table privileges aligned with the RLS policies.
-- Clear existing column-level grants too; table-level REVOKE does not remove them.
do $$
declare
  target_column record;
begin
  for target_column in
    select table_name, column_name
    from information_schema.columns
    where table_schema = 'public'
      and table_name in ('court_settings', 'profiles', 'court_bookings', 'booking_payments')
  loop
    execute format(
      'revoke select (%1$I), insert (%1$I), update (%1$I), references (%1$I) on public.%2$I from anon, authenticated',
      target_column.column_name,
      target_column.table_name
    );
  end loop;
end;
$$;

revoke all on public.court_settings from anon, authenticated;
grant select on public.court_settings to anon, authenticated;
grant insert, update, delete on public.court_settings to authenticated;

revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (full_name, avatar_url) on public.profiles to authenticated;

revoke all on public.court_bookings from anon, authenticated;
grant select, insert, update, delete on public.court_bookings to authenticated;

revoke all on public.booking_payments from anon, authenticated;
grant select on public.booking_payments to authenticated;

-- Only signed-in users may call these booking RPCs.
revoke all on function public.get_court_bookings(timestamptz, timestamptz) from public, anon;
grant execute on function public.get_court_bookings(timestamptz, timestamptz) to authenticated;
revoke all on function public.create_court_booking(timestamptz, integer, text) from public, anon;
grant execute on function public.create_court_booking(timestamptz, integer, text) to authenticated;
revoke all on function public.cancel_court_booking(uuid) from public, anon;
grant execute on function public.cancel_court_booking(uuid) to authenticated;

commit;

-- Grant admin access manually as the Supabase project owner, replacing the email.
-- This updates trusted app_metadata, never user_metadata. The admin must sign out
-- and sign in again to receive a JWT containing the updated role claim.
-- update auth.users
-- set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
-- where email = 'admin@example.com';
--
-- To remove admin access:
-- update auth.users
-- set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) - 'role'
-- where email = 'admin@example.com';
