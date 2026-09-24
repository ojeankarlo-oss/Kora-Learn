import { parseJsonBody, errorBody, errorResponse, successResponse } from "./http.js";
import { fingerprintHttpRequest } from "./fingerprint.js";
import { validateIdempotencyHeader, IDEMPOTENCY_LEASE_SECONDS } from "./idempotency.js";

/** @param {unknown} value @returns {value is Record<string, unknown>} */
function isRecord(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }

/** @param {unknown} body */
function customerData(body) {
  if (!isRecord(body) || !isRecord(body.data)) return null;
  const { id, external_reference, created_at } = body.data;
  if (typeof id !== "string" || !id || typeof external_reference !== "string" || !external_reference
    || typeof created_at !== "string" || !created_at) return null;
  return { id, external_reference, created_at };
}

// Deterministic Customer RPC failures, matched on the exact PostgREST message.
// They are recorded through payment_api_fail_idempotency and replayed for the same key.
const DETERMINISTIC_FAILURES = new Map([
  ["external_reference_conflict", { status: 409, code: "conflict", message: "External reference conflict" }],
  ["application billing account unavailable", { status: 400, code: "invalid_request", message: "Application not configured for billing" }],
  ["invalid customer creation request", { status: 400, code: "invalid_request", message: "Request validation failed" }],
]);
const REPLAYABLE_ERROR_CODES = new Set(["invalid_request", "conflict"]);

/** @param {unknown} status @param {unknown} body */
function storedFailure(status, body) {
  if (typeof status !== "number" || !Number.isInteger(status) || status < 400 || status > 499) return null;
  if (!isRecord(body) || !isRecord(body.error)) return null;
  const { code, message } = body.error;
  if (typeof code !== "string" || !REPLAYABLE_ERROR_CODES.has(code) || typeof message !== "string" || !message) return null;
  return { status, code, message };
}

/** @param {unknown} error */
function rpcErrorMessage(error) {
  // PostgREST errors may be plain objects rather than Error instances.
  return isRecord(error) && typeof error.message === "string" ? error.message : "";
}

/**
 * @param {Pick<ReturnType<typeof import("./supabase-repository.js").createPaymentsRepository>, "beginIdempotency" | "createCustomerAtomic" | "failIdempotency">} repository
 * @param {string[]} allowlist
 */
export function createCustomerHandler(repository, allowlist = []) {
  /** @param {{req: Request, requestId: string, auth: {tenantId: string, applicationId: string}}} input */
  return async function handleCreateCustomer({ req, requestId, auth }) {
    /**
     * @param {number} status
     * @param {string} code
     * @param {string} message
     * @param {Record<string, string>} [headers]
     */
    const fail = (status, code, message, headers = {}) => errorResponse(req, status, code, message, requestId, [], allowlist, headers);
    const key = validateIdempotencyHeader(req.headers.get("idempotency-key"), { required: true });
    if (!key.ok || !key.value) return fail(400, "invalid_request", "Invalid Idempotency-Key");
    const parsed = await parseJsonBody(req);
    if (!parsed.ok || !("value" in parsed) || !isRecord(parsed.value)) return fail(400, "invalid_request", "Request validation failed");
    const body = parsed.value;
    if (Object.keys(body).some((field) => !["name", "email", "external_reference"].includes(field))) return fail(400, "invalid_request", "Request validation failed");
    const { name, email, external_reference } = body;
    if (typeof name !== "string" || !name.trim() || name.trim().length > 160) return fail(400, "invalid_request", "Invalid name");
    if (email !== undefined && email !== null && (typeof email !== "string" || email.trim().length > 320)) return fail(400, "invalid_request", "Invalid email");
    if (typeof external_reference !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$/.test(external_reference.trim())) return fail(400, "invalid_request", "Invalid external_reference");

    /** @type {unknown} */
    let result;
    try {
      const fingerprint = await fingerprintHttpRequest({ method: "POST", operation: "POST /v1/customers", body });
      result = await repository.beginIdempotency({
        tenantId: auth.tenantId, applicationId: auth.applicationId,
        method: "POST", operation: "POST /v1/customers", key: key.value,
        fingerprint, requestId, leaseSeconds: IDEMPOTENCY_LEASE_SECONDS,
      });
    } catch (error) {
      if (rpcErrorMessage(error) === "invalid idempotency request") return fail(400, "invalid_request", "Request validation failed");
      return fail(500, "internal_error", "Internal server error");
    }
    if (!isRecord(result)) return fail(500, "internal_error", "Internal server error");
    switch (result.decision) {
      case "conflict": return fail(409, "conflict", "Idempotency conflict");
      case "in_progress":
      case "retry_later": {
        const seconds = result.retry_after_seconds;
        if (typeof seconds !== "number" || !Number.isInteger(seconds) || seconds < 1) return fail(500, "internal_error", "Internal server error");
        return fail(result.decision === "in_progress" ? 409 : 503,
          result.decision === "in_progress" ? "conflict" : "provider_unavailable",
          "Retry this request later", { "Retry-After": String(seconds) });
      }
      case "replay": {
        // Only project public Customer fields or a recorded public error, never arbitrary RPC fields.
        if (result.status === 201) {
          const data = customerData(result.body);
          if (!data) return fail(500, "internal_error", "Internal server error");
          return successResponse(req, 201, data, requestId, allowlist);
        }
        const stored = storedFailure(result.status, result.body);
        if (!stored) return fail(500, "internal_error", "Internal server error");
        return fail(stored.status, stored.code, stored.message);
      }
      case "acquired":
        if (typeof result.record_id !== "string" || !result.record_id || typeof result.lease_token !== "string" || !result.lease_token) return fail(500, "internal_error", "Internal server error");
        break;
      default: return fail(500, "internal_error", "Internal server error");
    }
    const recordId = result.record_id, leaseToken = result.lease_token;

    try {
      const resultBody = await repository.createCustomerAtomic({
        idempotencyRecordId: recordId, leaseToken,
        name: name.trim(), email: typeof email === "string" ? email.trim() || null : null,
        externalReference: external_reference.trim(), requestId,
      });
      const data = customerData(resultBody);
      if (!data) return fail(500, "internal_error", "Internal server error");
      return successResponse(req, 201, data, requestId, allowlist);
    } catch (error) {
      const message = rpcErrorMessage(error);
      // The lease is no longer ours; there is nothing this request may record.
      if (message === "customer idempotency lease invalid") return fail(409, "conflict", "Idempotency conflict");
      const deterministic = DETERMINISTIC_FAILURES.get(message);
      const failure = deterministic || { status: 500, code: "internal_error", message: "Internal server error" };
      try {
        // Release the lease through the existing lifecycle. Deterministic failures replay;
        // transient ones may be retried immediately with the same key. The lease fence in SQL
        // rejects this call if the Customer transaction actually completed.
        await repository.failIdempotency({
          recordId, leaseToken, status: failure.status,
          body: errorBody(failure.code, failure.message, requestId),
          failureKind: deterministic ? "deterministic" : "transient",
          errorCode: failure.code, requestId, retryAfterSeconds: 0,
        });
      } catch {
        // Best effort: an unrecorded failure falls back to lease expiry.
      }
      return fail(failure.status, failure.code, failure.message);
    }
  };
}
