const appCallbackScheme = "com.example.threekings";
const appCallbackHost = "payment";
const appCallbackPath = "/callback";
const bookingIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

Deno.serve((request) => {
  if (request.method !== "GET") {
    return new Response("Method not allowed.", { status: 405 });
  }

  const requestUrl = new URL(request.url);
  const payment = requestUrl.searchParams.get("payment")?.toLowerCase();
  const bookingId = requestUrl.searchParams.get("booking_id");
  if (
    !["success", "cancelled"].includes(payment ?? "") ||
    !bookingId ||
    !bookingIdPattern.test(bookingId)
  ) {
    return new Response("Invalid payment return parameters.", { status: 400 });
  }

  const appCallback = new URL(`${appCallbackScheme}://${appCallbackHost}${appCallbackPath}`);
  appCallback.searchParams.set("payment", payment!);
  appCallback.searchParams.set("booking_id", bookingId);

  return new Response(null, {
    status: 302,
    headers: {
      "Cache-Control": "no-store",
      Location: appCallback.toString(),
    },
  });
});