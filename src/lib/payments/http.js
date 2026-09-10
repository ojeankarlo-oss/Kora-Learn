import { authenticatePaymentCredential, rejectCallerTenantOverride, requirePaymentScope } from "./auth.js";
import { validateIdempotencyHeader } from "./idempotency.js";

export const API_ROOT = "/v1";
export const MAX_REQUEST_BODY_BYTES = 64 * 1024;
export const MAX_REQUEST_ID_LENGTH = 128;
export const MAX_IDEMPOTENCY_KEY_LENGTH = 128;
const SAFE_REQUEST_ID = /^[A-Za-z0-9._:-]{1,128}$/;
const VALID_ACCESS = new Set(["public", "protected"]);
const VALID_METHODS = new Set(["GET", "POST", "PUT", "PATCH", "DELETE"]);
/** @type {string[]} */
const EMPTY_ALLOWLIST = [];

function uuid() {
  return globalThis.crypto?.randomUUID?.() || `req-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

export function sanitizeRequestId(value) {
  const candidate = String(value || "").trim();
  return SAFE_REQUEST_ID.test(candidate) ? candidate : uuid();
}

export function requestIdFromRequest(req) {
  return sanitizeRequestId(req?.headers?.get?.("x-request-id"));
}

export function normalizePath(pathname) {
  const normalized = String(pathname || "/").replace(/\/+/g, "/");
  if (normalized.length > 1) return normalized.replace(/\/$/, "");
  return normalized;
}

function allowedOrigin(origin, allowlist) {
  if (!origin) return null;
  const values = Array.isArray(allowlist) ? allowlist : [];
  return values.includes(origin) ? origin : null;
}

export function corsHeaders(req, allowlist = []) {
  const origin = allowedOrigin(req?.headers?.get?.("origin"), allowlist);
  return {
    ...(origin ? { "Access-Control-Allow-Origin": origin, Vary: "Origin" } : {}),
    "Access-Control-Allow-Headers": "authorization, content-type, idempotency-key, x-request-id",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Expose-Headers": "X-Request-Id, Retry-After, X-RateLimit-Remaining",
  };
}

function baseHeaders(req, requestId, allowlist) {
  return {
    ...corsHeaders(req, allowlist),
    "Content-Type": "application/json; charset=utf-8",
    "X-Request-Id": requestId,
  };
}

export function errorBody(code, message, requestId, details = []) {
  return {
    error: {
      code,
      message,
      request_id: requestId,
      details: Array.isArray(details) ? details : [],
    },
  };
}

export function errorResponse(req, status, code, message, requestId, details = [], allowlist = [], extraHeaders = {}) {
  return new Response(JSON.stringify(errorBody(code, message, requestId, details)), {
    status,
    headers: { ...baseHeaders(req, requestId, allowlist), ...extraHeaders },
  });
}

export function successResponse(req, status, data, requestId, allowlist = [], headers = {}) {
  return new Response(JSON.stringify({ data, request_id: requestId }), {
    status,
    headers: { ...baseHeaders(req, requestId, allowlist), ...headers },
  });
}

export function methodNotAllowed(req, requestId, allow, allowlist = []) {
  return errorResponse(req, 405, "invalid_request", "Method not allowed", requestId, [], allowlist, {
    Allow: allow,
  });
}

export function validateIdempotencyKey(value, options = {}) {
  return validateIdempotencyHeader(value, options);
}

function invalidRequest(message = "Request validation failed") {
  return { ok: false, status: 400, code: "invalid_request", message };
}

export async function readBodyWithinLimit(req, maxBytes = MAX_REQUEST_BODY_BYTES) {
  const contentLength = req.headers.get("content-length");
  if (contentLength !== null) {
    if (!/^\d+$/.test(contentLength)) return invalidRequest("Request validation failed");
    try {
      if (BigInt(contentLength) > BigInt(maxBytes)) return invalidRequest("Request body is too large");
    } catch {
      return invalidRequest("Request validation failed");
    }
  }

  if (!req.body) return { ok: true, bytes: new Uint8Array() };
  const reader = req.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      const chunk = value instanceof Uint8Array ? value : new Uint8Array(value);
      total += chunk.byteLength;
      if (total > maxBytes) {
        await reader.cancel("request_body_too_large").catch(() => {});
        return invalidRequest("Request body is too large");
      }
      chunks.push(chunk);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { ok: true, bytes };
}

export async function parseJsonBody(req, { allowedFields = null, maxBytes = MAX_REQUEST_BODY_BYTES } = {}) {
  const contentType = req.headers.get("content-type") || "";
  if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
    return invalidRequest("Content-Type must be application/json");
  }
  const body = await readBodyWithinLimit(req, maxBytes);
  if (!body.ok) return body;
  let value;
  try {
    value = new TextDecoder("utf-8", { fatal: true }).decode(body.bytes);
    value = JSON.parse(value);
  } catch {
    return invalidRequest("Request validation failed");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return invalidRequest("Request validation failed");
  if (allowedFields) {
    const unknown = Object.keys(value).find((field) => !allowedFields.has(field));
    if (unknown) return invalidRequest("Request validation failed");
  }
  return { ok: true, value };
}

export function rejectTenantAuthority(input) {
  const result = rejectCallerTenantOverride(input);
  return result.ok ? result : { ok: false, code: result.code, message: "Request validation failed", status: 400 };
}

export function validateRouteRegistry(routes) {
  if (!routes || typeof routes !== "object" || Array.isArray(routes)) {
    return { ok: false, code: "invalid_route_registry", message: "Invalid route registry" };
  }
  for (const [path, methods] of Object.entries(routes)) {
    if (!path.startsWith(`${API_ROOT}/`) && path !== API_ROOT) return { ok: false, code: "invalid_route_registry", message: "Invalid route path" };
    if (!methods || typeof methods !== "object" || Array.isArray(methods)) return { ok: false, code: "invalid_route_registry", message: "Invalid route methods" };
    for (const [method, definition] of Object.entries(methods)) {
      if (!VALID_METHODS.has(method)) return { ok: false, code: "invalid_route_registry", message: "Invalid route method" };
      if (!definition || typeof definition !== "object" || !VALID_ACCESS.has(definition.access)) {
        return { ok: false, code: "invalid_route_registry", message: "Route access must be public or protected" };
      }
      if (definition.requestId !== true) return { ok: false, code: "invalid_route_registry", message: "Route request_id declaration missing" };
      if (!Array.isArray(definition.responses) || !definition.responses.includes(200)) {
        return { ok: false, code: "invalid_route_registry", message: "Route response contract missing" };
      }
      if (typeof definition.responseSchema !== "string" || !definition.responseSchema) {
        return { ok: false, code: "invalid_route_registry", message: "Route response schema missing" };
      }
    }
  }
  return { ok: true, value: routes };
}

export function assertValidRouteRegistry(routes) {
  const result = validateRouteRegistry(routes);
  if (!result.ok) throw new Error(result.message);
  return routes;
}

function requestForAuth(req, requestId) {
  const headers = new Headers(req.headers);
  headers.set("x-request-id", requestId);
  return { headers };
}

function publicAuthError(req, authResult, requestId, allowlist) {
  if (authResult?.code === "insufficient_scope") {
    return errorResponse(req, 403, "insufficient_scope", "Insufficient scope", requestId, [], allowlist);
  }
  return errorResponse(req, 401, "invalid_credential", "Invalid credential", requestId, [], allowlist);
}

/**
 * @typedef {{
 *   routes?: Record<string, Record<string, {access: string, scope?: string, requestId: boolean, responses: number[], responseSchema: string, rateLimit?: boolean}>>,
 *   handlers?: Record<string, Record<string, Function>>,
 *   repository?: object,
 *   rateLimiter?: {consume: (key: string) => Promise<{allowed: boolean, remaining?: number, retryAfterSeconds?: number}>} | null,
 *   allowlist?: string[],
 *   now?: Date,
 * }} PipelineOptions
 */
/** @param {Request} req @param {PipelineOptions} options */
export async function runPaymentsPipeline(req, {
  routes,
  handlers,
  repository,
  rateLimiter = null,
  allowlist = EMPTY_ALLOWLIST,
  now = new Date(),
} = {}) {
  const requestId = requestIdFromRequest(req);
  const registry = validateRouteRegistry(routes);
  if (!registry.ok) return errorResponse(req, 500, "internal_error", "Internal server error", requestId, [], allowlist);
  const url = new URL(req.url);
  const path = normalizePath(url.pathname);
  const route = routes[path];

  if (!route) return errorResponse(req, 404, "resource_not_found", "Resource not found", requestId, [], allowlist);
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: { ...corsHeaders(req, allowlist), "X-Request-Id": requestId } });
  }
  if (!route[req.method]) {
    const allow = Object.keys(route).join(", ");
    return methodNotAllowed(req, requestId, allow, allowlist);
  }

  const definition = route[req.method];
  const isProtected = definition.access === "protected";
  let authResult = { ok: true, context: null };
  if (isProtected) {
    const authorityInput = {};
    const headerTenant = req.headers.get("x-tenant-id");
    const headerTenantId = req.headers.get("x-tenantid");
    if (headerTenant !== null) authorityInput.tenant_id = headerTenant;
    if (headerTenantId !== null) authorityInput.tenantId = headerTenantId;
    if (url.searchParams.has("tenant_id")) authorityInput.tenant_id = url.searchParams.get("tenant_id");
    if (url.searchParams.has("tenantId")) authorityInput.tenantId = url.searchParams.get("tenantId");
    const override = rejectTenantAuthority(authorityInput);
    if (!override.ok) return errorResponse(req, 400, override.code, override.message, requestId, [], allowlist);

    authResult = await authenticatePaymentCredential({
      request: requestForAuth(req, requestId),
      repository,
      now,
    });
    if (!authResult.ok) return publicAuthError(req, authResult, requestId, allowlist);
    if (definition.scope) {
      const scoped = requirePaymentScope(authResult, definition.scope);
      if (!scoped.ok) return publicAuthError(req, scoped, requestId, allowlist);
      authResult = scoped;
    }
    if (definition.rateLimit) {
      if (!rateLimiter?.consume) {
        return errorResponse(req, 503, "provider_unavailable", "Service temporarily unavailable", requestId, [], allowlist);
      }
      const key = `${authResult.context.tenantId}:${authResult.context.applicationId}:${authResult.context.credentialId}:${path}`;
      const limited = await rateLimiter.consume(key);
      if (!limited?.allowed) {
        return errorResponse(req, 429, "rate_limited", "Too many requests", requestId, [], allowlist, {
          "Retry-After": String(Math.max(1, limited?.retryAfterSeconds || 1)),
          "X-RateLimit-Remaining": String(Math.max(0, limited?.remaining || 0)),
        });
      }
    }
  }

  const handler = handlers?.[path]?.[req.method];
  if (typeof handler !== "function") return errorResponse(req, 500, "internal_error", "Internal server error", requestId, [], allowlist);
  try {
    const result = await handler({ req, url, requestId, auth: authResult.context });
    if (result instanceof Response) return result;
    return successResponse(req, 200, result, requestId, allowlist);
  } catch {
    return errorResponse(req, 500, "internal_error", "Internal server error", requestId, [], allowlist);
  }
}

export { SAFE_REQUEST_ID };
