import { createClient } from "npm:@supabase/supabase-js@2";
import { assertValidRouteRegistry, runPaymentsPipeline, sanitizeRequestId, parseJsonBody } from "../../../src/lib/payments/http.js";
import { createPaymentsRepository } from "../../../src/lib/payments/supabase-repository.js";
import { PAYMENTS_API_METADATA, PAYMENTS_API_ROUTES } from "../../../src/lib/payments/api-contract.js";
import { fingerprintHttpRequest } from "../../../src/lib/payments/fingerprint.js";

/** @typedef {{
 *   id: string,
 *   external_reference: string,
 *   created_at: string
 * }} CustomerData */

/** @typedef {{
 *   data?: CustomerData,
 *   error?: Error
 * }} RpcResult */

/** @typedef {{
 *   data?: { id: string; lease_token: string },
 *   error?: Error
 * }} IdempotencyResult */

/** @typedef {{
 *   beginIdempotency: (input: { tenantId: string; applicationId: string; method: string; operation: string; key: string; fingerprint: string; requestId: string; leaseSeconds: number }) => Promise<IdempotencyResult>,
 *   createCustomerAtomic: (input: { idempotencyRecordId: string; leaseToken: string; name: string; email: string | null; externalReference: string; requestId: string }) => Promise<RpcResult>,
 *   findCredentialByHash: (hash: string) => Promise<any>,
 *   findApplication: (applicationId: string, tenantId: string) => Promise<any>,
 *   findTenant: (tenantId: string) => Promise<any>,
 *   listCredentialScopes: (credentialId: string, tenantId: string) => Promise<any>,
 *   auditAuthAttempt: (input: { credentialId: string | null; applicationId: string | null; tenantId: string | null; requestId: string; success: boolean; reason: string }) => Promise<void>,
 *   touchCredential: (input: { credentialId: string; requestId: string }) => Promise<void>
 * }} PaymentsRepository */

/** @typedef {{
 *   applicationId: string,
 *   tenantId: string,
 *   credentialId: string,
 *   environment: string,
 *   scopes: Set<string>,
 *   requestId: string
 * }} AuthContext */

const VERSION = PAYMENTS_API_METADATA.version;
const allowlist = (Deno.env.get("PAYMENTS_API_CORS_ORIGINS") || "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const routes = assertValidRouteRegistry(PAYMENTS_API_ROUTES);

function logEvent(event: string, fields: Record<string, unknown> = {}) {
  console.log(JSON.stringify({ service: "payments-api-v1", event, ...fields }));
}

function routesFor() {
  return routes;
}

function createCustomerHandler(/** @type {PaymentsRepository} */ repository) {
  return async function handleCreateCustomer({ req, requestId, auth }) {
    // Validate Idempotency-Key header (required for financial mutations)
    const idempotencyKey = req.headers.get("idempotency-key");
    if (!idempotencyKey) {
      return new Response(JSON.stringify({
        error: { code: "invalid_request", message: "Idempotency-Key header is required", request_id: requestId, details: [] },
      }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
    }

    // Parse and validate JSON body
    const bodyResult = await parseJsonBody(req, { allowedFields: new Set(["name", "email", "external_reference"]) });
    if (!bodyResult.ok) {
      return new Response(JSON.stringify({
        error: { code: "invalid_request", message: "Request validation failed", request_id: requestId, details: [] },
      }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
    }

    const { name, email, external_reference } = bodyResult.value;

    // Validate required fields
    if (!name || typeof name !== "string" || name.trim().length === 0 || name.trim().length > 160) {
      return new Response(JSON.stringify({
        error: { code: "invalid_request", message: "Invalid name", request_id: requestId, details: [] },
      }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
    }

    if (email !== undefined && email !== null) {
      if (typeof email !== "string" || email.trim().length > 320) {
        return new Response(JSON.stringify({
          error: { code: "invalid_request", message: "Invalid email", request_id: requestId, details: [] },
        }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
      }
    }

    if (!external_reference || typeof external_reference !== "string" || external_reference.trim().length === 0 || external_reference.trim().length > 160) {
      return new Response(JSON.stringify({
        error: { code: "invalid_request", message: "Invalid external_reference", request_id: requestId, details: [] },
      }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
    }

    // Validate external_reference format
    if (!/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$/.test(external_reference.trim())) {
      return new Response(JSON.stringify({
        error: { code: "invalid_request", message: "Invalid external_reference format", request_id: requestId, details: [] },
      }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
    }

    // Compute request fingerprint for idempotency
    const fingerprint = await fingerprintHttpRequest({
      method: "POST",
      operation: "POST /v1/customers",
      body: bodyResult.value,
    });

    // Begin idempotency lease
    const idempotencyResult = await repository.beginIdempotency({
      tenantId: auth.tenantId,
      applicationId: auth.applicationId,
      method: "POST",
      operation: "POST /v1/customers",
      key: idempotencyKey,
      fingerprint,
      requestId,
      leaseSeconds: 60,
    });

    const idempotencyRecord = idempotencyResult?.data;
    if (!idempotencyRecord?.id || !idempotencyRecord?.lease_token) {
      return new Response(JSON.stringify({
        error: { code: "internal_error", message: "Failed to begin idempotency", request_id: requestId, details: [] },
      }), { status: 500, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
    }

    // Call the customer creation RPC
    try {
      const customerResult = await repository.createCustomerAtomic({
        idempotencyRecordId: idempotencyRecord.id,
        leaseToken: idempotencyRecord.lease_token,
        name: name.trim(),
        email: email?.trim() || null,
        externalReference: external_reference.trim(),
        requestId,
      });

      const customerData = customerResult?.data;
      if (!customerData) {
        return new Response(JSON.stringify({
          error: { code: "internal_error", message: "Customer creation failed", request_id: requestId, details: [] },
        }), { status: 500, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
      }

      return new Response(JSON.stringify({
        data: {
          id: customerData.id,
          external_reference: customerData.external_reference,
          created_at: customerData.created_at,
        },
        request_id: requestId,
      }), { status: 201, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
    } catch (error) {
      // Check for specific error codes from the RPC
      const errorMessage = error instanceof Error ? error.message : String(error);
      if (errorMessage.includes("customer idempotency lease invalid") || errorMessage.includes("conflict")) {
        return new Response(JSON.stringify({
          error: { code: "conflict", message: "Idempotency conflict", request_id: requestId, details: [] },
        }), { status: 409, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
      }
      if (errorMessage.includes("application billing account unavailable")) {
        return new Response(JSON.stringify({
          error: { code: "invalid_request", message: "Application not configured for billing", request_id: requestId, details: [] },
        }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
      }
      // Generic error
      return new Response(JSON.stringify({
        error: { code: "internal_error", message: "Internal server error", request_id: requestId, details: [] },
      }), { status: 500, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
    }
  };
}

function handlersFor(prefix, /** @type {PaymentsRepository} */ repository) {
  const handleCreateCustomer = createCustomerHandler(repository);
  return {
    [`${prefix}/health`]: {
      GET: () => ({ ok: true, version: VERSION }),
    },
    [`${prefix}`]: {
      GET: () => ({ name: PAYMENTS_API_METADATA.name, version: VERSION, status: "foundation" }),
    },
    [`${prefix}/customers`]: {
      POST: handleCreateCustomer,
    },
  };
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
    const prefix = "/v1";
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
    const response = await runPaymentsPipeline(routedRequest, {
      routes: routesFor(),
      handlers: handlersFor(prefix, repository),
      repository,
      allowlist,
    });
    logEvent("request_completed", { request_id: requestId, method: req.method, path: incomingUrl.pathname, status: response.status });
    return response;
  } catch {
    logEvent("request_failed", { request_id: requestId });
    return jsonError(requestId);
  }
});
