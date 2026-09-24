import { createClient } from "npm:@supabase/supabase-js@2";
import { sanitizeRequestId } from "../../../src/lib/payments/http.js";
import { createPaymentsRepository } from "../../../src/lib/payments/supabase-repository.js";
import { createPaymentsApi } from "../../../src/lib/payments/api-runtime.js";

const allowlist = (Deno.env.get("PAYMENTS_API_CORS_ORIGINS") || "")
  .split(",").map((value) => value.trim()).filter(Boolean);

function logEvent(event: string, fields: Record<string, unknown> = {}) {
  console.log(JSON.stringify({ service: "payments-api-v1", event, ...fields }));
}

function jsonError(requestId: string, status = 500) {
  return new Response(JSON.stringify({
    error: { code: "internal_error", message: "Internal server error", request_id: requestId, details: [] },
  }), { status, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
}

Deno.serve(async (req) => {
  const requestId = sanitizeRequestId(req.headers.get("x-request-id"));
  try {
    const incomingUrl = new URL(req.url);
    const functionPrefix = "/functions/v1/payments-api-v1";
    const publicPath = incomingUrl.pathname.startsWith(functionPrefix)
      ? incomingUrl.pathname.slice(functionPrefix.length) || "/"
      : incomingUrl.pathname;
    const routedUrl = new URL(req.url);
    routedUrl.pathname = publicPath;
    const routedRequest = new Request(routedUrl, req);
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      logEvent("configuration_missing", { request_id: requestId });
      return jsonError(requestId);
    }
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const repository = createPaymentsRepository(admin);
    const response = await createPaymentsApi({ repository, allowlist })(routedRequest);
    logEvent("request_completed", { request_id: requestId, method: req.method, path: incomingUrl.pathname, status: response.status });
    return response;
  } catch {
    logEvent("request_failed", { request_id: requestId });
    return jsonError(requestId);
  }
});
