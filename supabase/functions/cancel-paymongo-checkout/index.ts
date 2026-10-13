import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const paymongoAuth = (secret: string) => `Basic ${btoa(`${secret}:`)}`;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const authorization = request.headers.get("Authorization");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const paymongoSecret = Deno.env.get("PAYMONGO_SECRET_KEY");
  const paymongoMode = Deno.env.get("PAYMONGO_MODE");
  const configuredReturnUrl = Deno.env.get("PAYMONGO_RETURN_URL");
  if (!authorization || !supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ error: "Payment service is not configured." }, 503);
  }
  if (!paymongoSecret || !["test", "live"].includes(paymongoMode ?? "")) {
    return json({ error: "PayMongo is not configured on the server." }, 503);
  }
  if (!paymongoSecret.startsWith(`sk_${paymongoMode}_`)) {
    return json({ error: "PayMongo key mode does not match server configuration." }, 503);
  }

  const resolveReturnUrl = () => {
    const candidate = configuredReturnUrl ?? request.headers.get("origin") ?? request.headers.get("referer") ?? "http://localhost:3000";
    try {
      const parsed = new URL(candidate);
      const hostname = parsed.hostname.toLowerCase();
      const isLocalHost = ["localhost", "127.0.0.1", "0.0.0.0"].includes(hostname);
      const isHttps = parsed.protocol === "https:";
      const isAllowedLocalHttp = isLocalHost && parsed.protocol === "http:";
      if (!isHttps && !isAllowedLocalHttp) {
        return "http://localhost:3000";
      }
      return parsed.toString();
    } catch {
      return "http://localhost:3000";
    }
  };

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userResult, error: userError } = await userClient.auth.getUser();
  if (userError || !userResult.user) return json({ error: "Sign in to cancel this checkout." }, 401);

  let bookingId: unknown;
  try {
    ({ booking_id: bookingId } = await request.json());
  } catch {
    return json({ error: "Invalid request body." }, 400);
  }
  if (typeof bookingId !== "string") return json({ error: "Invalid booking." }, 400);

  const { data: booking, error: bookingError } = await userClient
    .from("court_bookings")
    .select("id,court_name,total_price,status,payment_method,payment_status")
    .eq("id", bookingId)
    .eq("user_id", userResult.user.id)
    .maybeSingle();
  if (bookingError || !booking) return json({ error: "Booking not found." }, 404);
  if (
    booking.status !== "pending" || booking.payment_method !== "paymongo" ||
    !["unpaid", "pending"].includes(booking.payment_status)
  ) {
    return json({ error: "This booking has no active PayMongo checkout." }, 409);
  }

  let returnUrl: URL;
  const resolvedReturnUrl = resolveReturnUrl();
  try {
    returnUrl = new URL(resolvedReturnUrl);
  } catch {
    return json({ error: "The payment return URL is invalid." }, 503);
  }

  const amount = Math.round(Number(booking.total_price) * 100);
  if (!Number.isSafeInteger(amount) || amount <= 0) {
    return json({ error: "The booking total is invalid for checkout." }, 500);
  }

  const headers = { Authorization: paymongoAuth(paymongoSecret) };
  const successUrl = new URL(returnUrl);
  successUrl.searchParams.set("payment", "success");
  successUrl.searchParams.set("booking_id", booking.id);
  const cancelUrl = new URL(returnUrl);
  cancelUrl.searchParams.set("payment", "cancelled");
  cancelUrl.searchParams.set("booking_id", booking.id);
  const paymentMethods = (Deno.env.get("PAYMONGO_PAYMENT_METHOD_TYPES") ?? "card,gcash,paymaya,qrph")
    .split(",")
    .map((method) => method.trim())
    .filter(Boolean);
  if (paymentMethods.length === 0) return json({ error: "No payment methods are configured." }, 503);

  let checkoutResponse: Response;
  try {
    checkoutResponse = await fetch("https://api.paymongo.com/v2/checkout_sessions", {
      method: "POST",
      headers: {
        ...headers,
        "Content-Type": "application/json",
        "Idempotency-Key": `booking-${booking.id}`,
      },
      body: JSON.stringify({
        data: {
          attributes: {
            line_items: [{
              name: `${booking.court_name ?? "Court 1"} court booking`,
              amount,
              currency: "PHP",
              quantity: 1,
            }],
            payment_method_types: paymentMethods,
            description: `3Kings court booking ${booking.id}`,
            reference_number: booking.id,
            metadata: { booking_id: booking.id, user_id: userResult.user.id },
            success_url: successUrl.toString(),
            cancel_url: cancelUrl.toString(),
          },
        },
      }),
    });
  } catch {
    return json({ error: "Could not verify the PayMongo checkout state. Retry or contact support." }, 502);
  }
  if (!checkoutResponse.ok) {
    return json({ error: "Could not retrieve the PayMongo checkout session." }, 502);
  }
  const checkoutBody = await checkoutResponse.json();
  const checkoutSessionId = checkoutBody?.data?.id;
  if (typeof checkoutSessionId !== "string") {
    return json({ error: "PayMongo returned an invalid checkout session." }, 502);
  }

  const { error: registerError } = await adminClient.rpc("register_paymongo_checkout", {
    p_booking_id: booking.id,
    p_checkout_session_id: checkoutSessionId,
  });
  if (registerError) return json({ error: "Could not save the checkout reference." }, 500);

  const sessionUrl = `https://api.paymongo.com/v1/checkout_sessions/${encodeURIComponent(checkoutSessionId)}`;
  const expireResponse = await fetch(`${sessionUrl}/expire`, { method: "POST", headers });
  if (!expireResponse.ok) {
    const retrieveResponse = await fetch(sessionUrl, { headers });
    if (!retrieveResponse.ok) {
      return json({ error: "Could not verify the PayMongo checkout state. Refresh and try again." }, 502);
    }
    const retrieveBody = await retrieveResponse.json();
    const attributes = retrieveBody?.data?.attributes;
    const paid = Array.isArray(attributes?.payments) && attributes.payments.some(
      (item: { attributes?: { status?: string } }) => item.attributes?.status === "paid",
    );
    if (paid) return json({ error: "Payment may have completed. Refresh bookings before trying again." }, 409);
    if (attributes?.status !== "expired") {
      return json({ error: "PayMongo could not expire this checkout. Please retry shortly." }, 502);
    }
  }

  const { error: cancelError } = await adminClient.rpc("expire_paymongo_booking", {
    p_booking_id: booking.id,
    p_checkout_session_id: checkoutSessionId,
  });
  if (cancelError) {
    console.error("Could not release expired PayMongo booking.", cancelError.message);
    return json({ error: "Checkout expired, but the booking could not be updated. Contact support." }, 500);
  }
  return json({ cancelled: true });
});
