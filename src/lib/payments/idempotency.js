export const IDEMPOTENCY_HEADER = "Idempotency-Key";
export const IDEMPOTENCY_MAX_LENGTH = 128;
export const IDEMPOTENCY_RESPONSE_MAX_BYTES = 256 * 1024;
export const IDEMPOTENCY_LEASE_SECONDS = 60;
export const IDEMPOTENCY_STATES = Object.freeze(["processing", "completed", "failed"]);

export function validateIdempotencyHeader(value, { required = false } = {}) {
  const key = String(value || "").trim();
  if (!key && !required) return { ok: true, value: null };
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(key)) {
    return { ok: false, code: "invalid_request", message: "Invalid Idempotency-Key" };
  }
  return { ok: true, value: key };
}

export function buildIdempotencyScope({ tenantId, applicationId, method, operation, key }) {
  const parsed = validateIdempotencyHeader(key, { required: true });
  if (!parsed.ok) return parsed;
  const normalizedMethod = String(method || "").trim().toUpperCase();
  const normalizedOperation = String(operation || "").trim();
  if (!tenantId || !applicationId || !/^(POST|PUT|PATCH|DELETE)$/.test(normalizedMethod) || !normalizedOperation) {
    return { ok: false, code: "invalid_request", message: "Invalid idempotency scope" };
  }
  return {
    ok: true,
    value: Object.freeze({
      tenantId: String(tenantId),
      applicationId: String(applicationId),
      method: normalizedMethod,
      operation: normalizedOperation,
      key: parsed.value,
    }),
  };
}

export function classifyIdempotencyFailure({ transient = false } = {}) {
  return transient ? "transient" : "deterministic";
}

export function idempotencyPolicy() {
  return Object.freeze({
    header: IDEMPOTENCY_HEADER,
    maxLength: IDEMPOTENCY_MAX_LENGTH,
    responseMaxBytes: IDEMPOTENCY_RESPONSE_MAX_BYTES,
    leaseSeconds: IDEMPOTENCY_LEASE_SECONDS,
    states: IDEMPOTENCY_STATES,
    requiredFor: "future financial mutations only",
    scope: "tenant/application/http_method/operation/key",
    fingerprint: "canonical sorted-key JSON SHA-256; excludes Authorization, request_id and irrelevant headers",
    retry: "same key and same canonical payload returns the original result",
    mismatch: "same key with a different fingerprint returns 409 conflict",
    concurrency: "one authoritative lease wins; concurrent equivalent requests do not execute a handler twice",
    staleProcessing: "an expired lease can be acquired again; a live lease returns in_progress",
    storage: "persistent server-side registry; financial payment_intents remain the financial authority",
  });
}
