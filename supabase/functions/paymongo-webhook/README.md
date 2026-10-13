# PayMongo webhook deployment

Deploy this function with JWT verification disabled only because PayMongo cannot send a Supabase user token. The handler verifies the `Paymongo-Signature` HMAC before parsing or writing payment data.

In the PayMongo Dashboard, create a webhook for `checkout_session.payment.paid` and point it to:

`https://YOUR_PROJECT_REF.supabase.co/functions/v1/paymongo-webhook`

Set the endpoint secret as `PAYMONGO_WEBHOOK_SECRET` in Supabase Function Secrets. Create separate webhook endpoints and secrets for test and live mode. Configure the Edge Function `PAYMONGO_MODE` to `test` or `live` to match its API key and webhook.
