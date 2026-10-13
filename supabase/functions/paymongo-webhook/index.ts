import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return [...new Uint8Array(signature)].map((value) => value.toString(16).padStart(2, "0")).join("");
}

function constantTimeHexEquals(expected: string, actual: string): boolean {
  if (!/^[a-f0-9]+$/i.test(actual) || expected.length !== actual.length) return false;
  let difference = 0;
  for (let index = 0; index < expected.length; index++) {
    difference |= expected.charCodeAt(index) ^ actual.toLowerCase().charCodeAt(index);
  }
  return difference === 0;
}

function parsePaymongoSignature(
  header: string,
  mode: string,
): { timestamp: string; signature: string } | null {
  const parts = new Map<string, string>();
  for (const part of header.split(",")) {
    const separator = part.indexOf("=");
    if (separator < 1) continue;
    parts.set(part.slice(0, separator).trim(), part.slice(separator + 1).trim());
  }

  const timestamp = parts.get("t") ?? "";
  const signature = parts.get(mode === "live" ? "li" : "te")?.toLowerCase() ?? "";
  if (!/^\d+$/.test(timestamp) || !/^[a-f0-9]{64}$/.test(signature)) return null;
  return { timestamp, signature };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const webhookSecret = Deno.env.get("PAYMONGO_WEBHOOK_SECRET");
  const mode = Deno.env.get("PAYMONGO_MODE");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!webhookSecret || !["test", "live"].includes(mode ?? "") || !supabaseUrl || !serviceRoleKey) {
    return json({ error: "Webhook is not configured." }, 503);
  }

  const rawBody = await request.text();
  const signature = parsePaymongoSignature(
    request.headers.get("Paymongo-Signature") ?? "",
    mode!,
  );
  if (!signature) return json({ error: "Invalid webhook signature." }, 401);

  const signedPayload = `${signature.timestamp}.${rawBody}`;
  const expectedSignature = await hmacSha256Hex(webhookSecret, signedPayload);
  if (!constantTimeHexEquals(expectedSignature, signature.signature)) {
    return json({ error: "Invalid webhook signature." }, 401);
  }

  let payload: Record<string, any>;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return json({ error: "Invalid JSON payload." }, 400);
  }

  const event = payload.data ?? payload;
  const eventType = event.type ?? event.attributes?.type;
  if (eventType !== "checkout_session.payment.paid") {
    return json({ received: true, ignored: true });
  }

  const session = event.attributes?.data ?? event.data;
  const attributes = session?.attributes;
  if (typeof session?.id !== "string" || !attributes) {
    return json({ error: "Invalid paid checkout event." }, 400);
  }

  const livemode = event.livemode ?? event.attributes?.livemode ?? attributes.livemode;
  if (typeof livemode !== "boolean" || livemode !== (mode === "live")) {
    return json({ error: "Webhook mode does not match server configuration." }, 401);
  }

  const bookingId = attributes.reference_number;
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  if (typeof bookingId !== "string" || !uuidPattern.test(bookingId)) {
    return json({ error: "Checkout session has no valid booking reference." }, 400);
  }

  const paidPayment = Array.isArray(attributes.payments) && attributes.payments.find(
    (item: { attributes?: { status?: string } }) => item.attributes?.status === "paid",
  );
  if (!paidPayment) return json({ error: "Paid checkout has no paid payment record." }, 400);

  const lineItems = attributes.line_items;
  if (!Array.isArray(lineItems) || lineItems.length === 0) {
    return json({ error: "Checkout has no line items." }, 400);
  }
  let lineTotal = 0;
  for (const item of lineItems) {
    if (item.currency !== "PHP" || !Number.isSafeInteger(item.amount) || !Number.isSafeInteger(item.quantity)) {
      return json({ error: "Checkout amount is invalid." }, 400);
    }
    lineTotal += item.amount * item.quantity;
  }
  if (!Number.isSafeInteger(lineTotal) || lineTotal <= 0) {
    return json({ error: "Checkout total is invalid." }, 400);
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const eventId = event.id ?? payload.id ?? `${session.id}:checkout_session.payment.paid`;
  const { data, error } = await adminClient.rpc("confirm_paymongo_payment", {
    p_event_id: eventId,
    p_checkout_session_id: session.id,
    p_booking_id: bookingId,
    p_currency: "PHP",
    p_line_total: lineTotal,
  });
  if (error) {
    console.error("PayMongo webhook could not be applied.", error.message);
    return json({ error: "Payment confirmation could not be recorded." }, 500);
  }
  if (data === "paid_for_inactive_booking") {
    console.error("PayMongo payment succeeded for a cancelled or expired booking.", bookingId);
  }
  return json({ received: true, result: data });
});
