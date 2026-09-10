export const RATE_LIMIT_BACKEND = "abstraction_only";

export function buildRateLimitKey({ tenantId, applicationId, credentialId, route }) {
  const values = [tenantId, applicationId, credentialId, route].map((value) => String(value || "").trim());
  if (values.some((value) => !value)) throw new Error("Rate-limit identity is incomplete");
  return values.join(":");
}

export function createMemoryRateLimiter({ limit = 60, windowMs = 60_000, now = () => Date.now() } = {}) {
  const buckets = new Map();
  return {
    async consume(key) {
      const current = now();
      const previous = buckets.get(key);
      if (!previous || current - previous.startedAt >= windowMs) {
        buckets.set(key, { startedAt: current, count: 1 });
        return { allowed: true, remaining: Math.max(0, limit - 1), retryAfterSeconds: 0 };
      }
      if (previous.count >= limit) {
        return {
          allowed: false,
          remaining: 0,
          retryAfterSeconds: Math.max(1, Math.ceil((windowMs - (current - previous.startedAt)) / 1000)),
        };
      }
      previous.count += 1;
      return { allowed: true, remaining: Math.max(0, limit - previous.count), retryAfterSeconds: 0 };
    },
    reset() {
      buckets.clear();
    },
  };
}

export function rateLimitPolicy() {
  return Object.freeze({
    identity: ["tenant_id", "application_id", "credential_id", "route"],
    backend: RATE_LIMIT_BACKEND,
    failSafe: true,
    operational: false,
    note: "A distributed backend is required before enabling production enforcement.",
  });
}
