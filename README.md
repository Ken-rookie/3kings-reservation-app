# 3Kings Flutter Booking App

A dark, neon-lime Flutter frontend inspired by the supplied 3Kings User Booking Flow image. Includes Supabase email/password auth, signup, forgot-password request, customer profile, hourly booking, duration selection, live court rate, availability lookup, booking summary, payment-method selection UI, booking history, and cancellation of pending bookings.

## Included

- `lib/main.dart` — app UI and screens.
- `lib/services/supabase_service.dart` — Supabase Auth and database calls.
- `supabase/schema.sql` — schema, profile trigger, RLS, booking RPCs, exclusion constraint, and Realtime publication setup.

## 1. Requirements

- Flutter 3.19+ / Dart 3.3+
- A Supabase project

## 2. Set up Supabase

1. Open Supabase Dashboard → SQL Editor.
2. Run `supabase/schema.sql` in a new query. This script is intended for a new project; inspect existing table names first if you already created tables from earlier snippets.
3. Run `supabase/role_separation.sql` to apply the customer/admin RLS policies and grants. For an existing project, review the migration before applying; it replaces policies on the four app tables.
4. Run `supabase/paymongo_integration.sql` to add the payment-session records and server-only payment routines.
5. In Authentication → Providers, enable Email.
6. Configure Authentication → URL Configuration (Site URL and redirect URLs) for your app.
7. In Supabase Project Settings → API, copy the Project URL and publishable/anon key.

### Configure an admin

Admin permissions are based on the trusted JWT claim `app_metadata.role = "admin"`. See `supabase/role_separation.sql` for the owner-only SQL commands to grant/revoke this role. Users receive no role from signup metadata, and the customer frontend has no admin screens. Never put the `service_role` key in Flutter.

To change the price manually while developing, run in SQL Editor:

```sql
update public.court_settings set hourly_rate = 300.00 where id = true;
```

The app reads the rate from Supabase. To have an already-open screen update instantly when an admin changes the rate, add a Realtime subscription to `court_settings`; the current booking screen reloads the price on refresh/re-entry. Database booking totals always use the rate in the database.

## PayMongo hosted checkout

The customer app creates PayMongo Checkout Sessions through Supabase Edge Functions. The PayMongo secret key and webhook secret are never placed in Flutter or browser code. Use PayMongo test mode first; do not use live keys until test checkouts and webhook delivery have been verified.

1. Link the Supabase CLI to this project (`supabase link --project-ref kaloyqomoehfmfexwtja`) or deploy the functions from the Supabase Dashboard.
2. In Supabase Edge Function Secrets, set `PAYMONGO_SECRET_KEY` to the PayMongo secret key for the environment, `PAYMONGO_MODE` to `test` or `live`, and `PAYMONGO_RETURN_URL` to the customer app's HTTPS base URL. Optionally set `PAYMONGO_PAYMENT_METHOD_TYPES` to a comma-separated list of methods enabled for the merchant; the default is `card,gcash,paymaya,qrph`.
3. Deploy `create-paymongo-checkout`, `cancel-paymongo-checkout`, and `paymongo-webhook`. The repository's `supabase/config.toml` keeps JWT verification on for the customer functions and disables it only for the webhook, which validates PayMongo's signature itself.
4. In PayMongo Dashboard → Developer Tools → Webhooks, register `https://kaloyqomoehfmfexwtja.supabase.co/functions/v1/paymongo-webhook` for `checkout_session.payment.paid`. Copy the endpoint secret shown by PayMongo and then add it to Supabase Edge Function Secrets as `PAYMONGO_WEBHOOK_SECRET`. Keep test and live API keys, modes, and webhook secrets paired with the matching environment.
5. Complete a test checkout and confirm the webhook changes the booking to `confirmed` / `paid`. The browser redirect is not treated as payment proof.

For CLI deployment, after linking the project:

```powershell
supabase functions deploy create-paymongo-checkout
supabase functions deploy cancel-paymongo-checkout
supabase functions deploy paymongo-webhook
```

Never paste API secrets into source code, commit them, or send them in chat. A real live integration cannot be activated until live credentials, the customer return URL, and the live webhook endpoint are configured in their respective dashboards.

## 3. Run the Flutter app

From this folder:

```bash
flutter pub get
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY
```

On Windows PowerShell, use one line:

```powershell
flutter run --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co --dart-define=SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY
```

For a deployed build, use the same dart defines with `flutter build apk`, `flutter build appbundle`, or `flutter build web` as appropriate.

## 4. Booking behavior

- The user chooses a date, duration, and start time.
- The app queries occupied ranges and disables overlapping start times for the selected duration.
- `create_court_booking` reads the current hourly price in PostgreSQL and calculates the saved total; the client never submits a trusted price.
- A PostgreSQL exclusion constraint blocks overlaps even if two users book simultaneously.
- Pending bookings block time slots until cancelled or transitioned by a trusted workflow. Implement a scheduled expiry process before production if unpaid pending reservations should automatically release their slot.
- The app creates a `pending` / `unpaid` booking. The displayed payment method picker is a UI placeholder, not a real payment gateway. Integrate a provider and verify payments using a server-side webhook before changing a booking to confirmed/paid.

## 5. Add / update / delete (CRUD)

- **Create booking:** call `create_court_booking` RPC.
- **Read bookings:** select `court_bookings` for the signed-in user; RLS restricts rows to the owner (admins can manage all).
- **Update price:** update the single row in `court_settings`; RLS allows only trusted admins to update it through the client. Project owners can also update via SQL Editor.
- **Update booking status / payment records:** use a trusted server/payment webhook or admin session. Never allow a customer client to mark a payment paid.
- **Delete booking:** admin CRUD is allowed by RLS; customer cancellation uses `cancel_court_booking` and changes status to `cancelled` rather than deleting the audit record.
- **Profile:** customers can read/update their own profile; profiles are automatically created after signup.

## Important production notes

- Confirm the local timezone and business opening hours with the court owner. This sample displays start times from 6:00 AM to 8:00 PM and sends timestamps to Supabase in UTC.
- Configure the password-reset redirect URL in `lib/main.dart` (`https://example.com/reset-password`) before using password recovery in production.
- Google and Apple buttons are UI placeholders until those providers are configured in Supabase and OAuth redirect handling is added.
- Payment provider integrations, notification delivery, admin dashboard, and pending-booking expiry are intentionally not represented as complete payment functionality.
