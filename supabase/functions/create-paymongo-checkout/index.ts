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
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
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
  if (userError || !userResult.user) return json({ error: "Sign in to start checkout." }, 401);

  let requestBody: { booking_id?: unknown };
  try {
    requestBody = await request.json();
  } catch {
    return json({ error: "Invalid request body." }, 400);
  }

  const bookingId = requestBody.booking_id;
  if (typeof bookingId !== "string") return json({ error: "Invalid booking." }, 400);

  const { data: booking, error: bookingError } = await userClient
    .from("court_bookings")
    .select("id,user_id,court_name,total_price,status,payment_method,payment_status")
    .eq("id", bookingId)
    .eq("user_id", userResult.user.id)
    .maybeSingle();
  if (bookingError || !booking) return json({ error: "Booking not found." }, 404);
  if (
    booking.status !== "pending" || booking.payment_method !== "paymongo" ||
    !["unpaid", "pending"].includes(booking.payment_status)
  ) {
    return json({ error: "This booking is not eligible for PayMongo checkout." }, 409);
  }

  const amount = Math.round(Number(booking.total_price) * 100);
  if (!Number.isSafeInteger(amount) || amount <= 0) {
    return json({ error: "The booking total is invalid for checkout." }, 500);
  }

  let returnUrl: URL;
  const resolvedReturnUrl = resolveReturnUrl();
  try {
    returnUrl = new URL(resolvedReturnUrl);
  } catch {
    return json({ error: "The payment return URL is invalid." }, 503);
  }

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
  if (paymentMethods.length === 0) {
    return json({ error: "No PayMongo payment methods are configured." }, 503);
  }

  let checkoutSessionId: string | undefined;
  try {
    const checkoutResponse = await fetch("https://api.paymongo.com/v2/checkout_sessions", {
      method: "POST",
      headers: {
        Authorization: paymongoAuth(paymongoSecret),
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

    const checkoutBody = await checkoutResponse.json();
    if (!checkoutResponse.ok) {
      console.error("PayMongo checkout creation failed.", checkoutResponse.status);
      throw new Error("PayMongo could not start checkout. Please try again.");
    }

    checkoutSessionId = checkoutBody?.data?.id;
    const checkoutUrl = checkoutBody?.data?.attributes?.checkout_url;
    if (typeof checkoutSessionId !== "string" || typeof checkoutUrl !== "string") {
      throw new Error("PayMongo returned an invalid checkout response.");
    }
    const parsedCheckoutUrl = new URL(checkoutUrl);
    if (
      parsedCheckoutUrl.protocol !== "https:" ||
      !(parsedCheckoutUrl.hostname === "paymongo.com" || parsedCheckoutUrl.hostname.endsWith(".paymongo.com"))
    ) {
      throw new Error("PayMongo returned an invalid checkout URL.");
    }

    const { error: registerError } = await adminClient.rpc("register_paymongo_checkout", {
      p_booking_id: booking.id,
      p_checkout_session_id: checkoutSessionId,
    });
    if (registerError) throw new Error("Could not save the checkout reference.");

    return json({ booking_id: booking.id, checkout_url: checkoutUrl });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Could not start PayMongo checkout.";
    return json({ booking_id: booking.id, error: message }, 502);
  }
});
