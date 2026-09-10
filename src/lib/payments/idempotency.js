export const IDEMPOTENCY_HEADER = "Idempotency-Key";
export const IDEMPOTENCY_MAX_LENGTH = 128;

export function validateIdempotencyHeader(value, { required = false } = {}) {
  const key = String(value || "").trim();
  if (!key && !required) return { ok: true, value: null };
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(key)) {
    return { ok: false, code: "invalid_request", message: "Invalid Idempotency-Key" };
  }
  return { ok: true, value: key };
}

export function idempotencyPolicy() {
  return Object.freeze({
    header: IDEMPOTENCY_HEADER,
    maxLength: IDEMPOTENCY_MAX_LENGTH,
    requiredFor: "future financial mutations only",
    scope: "tenant/application/credential/route",
    retry: "same key and same canonical payload returns the original result",
    mismatch: "same key with a different payload returns 409 conflict",
    concurrency: "one authoritative record wins; concurrent equivalent requests replay it",
    storage: "must reuse the Billing Core idempotency authority when financial resources are added",
  });
}
