-- Apply after schema.sql and role_separation.sql.
-- This migration stores hosted checkout sessions and confirms payments only from
-- the signature-verified PayMongo webhook Edge Function.

begin;

create table if not exists public.paymongo_webhook_events (
  event_id text primary key,
  event_type text not null,
  received_at timestamptz not null default now()
);
alter table public.paymongo_webhook_events enable row level security;
revoke all on public.paymongo_webhook_events from public, anon, authenticated;

create or replace function public.register_paymongo_checkout(
  p_booking_id uuid,
  p_checkout_session_id text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.court_bookings;
  v_payment public.booking_payments;
begin
  if p_checkout_session_id is null or p_checkout_session_id = '' then
    raise exception 'Checkout session ID is required.';
  end if;

  select * into v_booking
  from public.court_bookings
  where id = p_booking_id
  for update;

  if not found
     or v_booking.status <> 'pending'
     or v_booking.payment_method <> 'paymongo'
     or v_booking.payment_status not in ('unpaid', 'pending') then
    raise exception 'Booking is not eligible for PayMongo checkout.';
  end if;

  select * into v_payment
  from public.booking_payments
  where provider_reference = p_checkout_session_id;

  if found then
    if v_payment.booking_id <> p_booking_id
       or v_payment.user_id <> v_booking.user_id
       or v_payment.amount <> v_booking.total_price
       or v_payment.status <> 'pending' then
      raise exception 'Checkout session is already linked to another payment.';
    end if;
  else
    insert into public.booking_payments(
      booking_id, user_id, payment_method, amount, status, provider_reference
    ) values (
      v_booking.id, v_booking.user_id, 'paymongo', v_booking.total_price,
      'pending', p_checkout_session_id
    );
  end if;

  update public.court_bookings
  set payment_status = 'pending'
  where id = p_booking_id;
end;
$$;

revoke all on function public.register_paymongo_checkout(uuid, text) from public, anon, authenticated;
grant execute on function public.register_paymongo_checkout(uuid, text) to service_role;

create or replace function public.expire_paymongo_booking(
  p_booking_id uuid,
  p_checkout_session_id text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.court_bookings;
begin
  select b.* into v_booking
  from public.court_bookings b
  join public.booking_payments p on p.booking_id = b.id
  where b.id = p_booking_id
    and b.status = 'pending'
    and b.payment_method = 'paymongo'
    and b.payment_status = 'pending'
    and p.payment_method = 'paymongo'
    and p.status = 'pending'
    and p.provider_reference = p_checkout_session_id
  for update of b;

  if not found then
    if exists (
      select 1 from public.court_bookings b
      join public.booking_payments p on p.booking_id = b.id
      where b.id = p_booking_id and b.status = 'cancelled'
        and p.provider_reference = p_checkout_session_id and p.status = 'failed'
    ) then
      return;
    end if;
    raise exception 'Booking no longer has this active PayMongo checkout.';
  end if;

  update public.booking_payments
  set status = 'failed'
  where provider_reference = p_checkout_session_id and status = 'pending';

  update public.court_bookings
  set status = 'cancelled', payment_status = 'failed'
  where id = p_booking_id and status = 'pending';
end;
$$;

revoke all on function public.expire_paymongo_booking(uuid, text) from public, anon, authenticated;
grant execute on function public.expire_paymongo_booking(uuid, text) to service_role;

create or replace function public.confirm_paymongo_payment(
  p_event_id text,
  p_checkout_session_id text,
  p_booking_id uuid,
  p_currency text,
  p_line_total bigint
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.court_bookings;
  v_payment public.booking_payments;
  v_inserted integer;
begin
  if p_event_id is null or p_event_id = ''
     or p_checkout_session_id is null or p_checkout_session_id = '' then
    raise exception 'Webhook event and session IDs are required.';
  end if;
  if p_currency <> 'PHP' or p_line_total <= 0 then
    raise exception 'Invalid PayMongo amount or currency.';
  end if;

  insert into public.paymongo_webhook_events(event_id, event_type)
  values (p_event_id, 'checkout_session.payment.paid')
  on conflict (event_id) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    return 'duplicate';
  end if;

  select b.* into v_booking
  from public.court_bookings b
  join public.booking_payments p on p.booking_id = b.id
  where b.id = p_booking_id
    and p.provider_reference = p_checkout_session_id
    and p.payment_method = 'paymongo'
  for update of b;
  if not found then
    raise exception 'PayMongo session is not registered to this booking.';
  end if;
  if v_booking.payment_method <> 'paymongo'
     or p_line_total <> round(v_booking.total_price * 100)::bigint then
    raise exception 'PayMongo total does not match booking total.';
  end if;

  select * into v_payment
  from public.booking_payments
  where provider_reference = p_checkout_session_id
  for update;
  if v_payment.booking_id <> p_booking_id or v_payment.amount <> v_booking.total_price then
    raise exception 'PayMongo payment does not match booking.';
  end if;

  update public.booking_payments
  set status = 'succeeded'
  where provider_reference = p_checkout_session_id;

  if v_booking.status in ('cancelled', 'expired') then
    update public.court_bookings
    set payment_status = 'paid'
    where id = p_booking_id;
    return 'paid_for_inactive_booking';
  end if;

  update public.court_bookings
  set status = 'confirmed', payment_status = 'paid'
  where id = p_booking_id and status = 'pending';

  return 'confirmed';
end;
$$;

revoke all on function public.confirm_paymongo_payment(text, text, uuid, text, bigint) from public, anon, authenticated;
grant execute on function public.confirm_paymongo_payment(text, text, uuid, text, bigint) to service_role;

-- Do not release a slot while its PayMongo session can still accept payment.
create or replace function public.cancel_court_booking(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.court_bookings;
begin
  if auth.uid() is null then raise exception 'Please sign in.'; end if;
  select * into v_booking from public.court_bookings
  where id = p_booking_id and user_id = auth.uid() for update;
  if not found then raise exception 'Booking not found.'; end if;
  if v_booking.status <> 'pending' then
    raise exception 'Only pending bookings can be cancelled by the customer.';
  end if;
  if v_booking.payment_method = 'paymongo' then
    raise exception 'Use the PayMongo cancellation function to expire its checkout before cancelling this booking.';
  end if;
  update public.court_bookings set status = 'cancelled' where id = p_booking_id;
end;
$$;
revoke all on function public.cancel_court_booking(uuid) from public, anon;
grant execute on function public.cancel_court_booking(uuid) to authenticated;

commit;
