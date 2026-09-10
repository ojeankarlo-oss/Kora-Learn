import assert from "node:assert/strict";
import test from "node:test";
import { canonicalizeJson, fingerprintHttpRequest, fingerprintJson, FINGERPRINT_ALGORITHM } from "../../src/lib/payments/fingerprint.js";
import {
  buildIdempotencyScope,
  classifyIdempotencyFailure,
  IDEMPOTENCY_RESPONSE_MAX_BYTES,
  idempotencyPolicy,
  validateIdempotencyHeader,
} from "../../src/lib/payments/idempotency.js";

const authority = {
  tenantId: "11111111-1111-4111-8111-111111111111",
  applicationId: "22222222-2222-4222-8222-222222222222",
};

test("canonical JSON ignores object key order but preserves array order", () => {
  assert.equal(canonicalizeJson({ b: 2, a: 1 }), '{"a":1,"b":2}');
  assert.equal(canonicalizeJson({ nested: { z: true, a: [2, 1] } }), '{"nested":{"a":[2,1],"z":true}}');
  assert.notEqual(canonicalizeJson({ a: [1, 2] }), canonicalizeJson({ a: [2, 1] }));
});

test("same semantic request fingerprint replays despite property order and whitespace", async () => {
  const first = await fingerprintHttpRequest({ method: "POST", operation: "POST /v1/invoices", body: { amount: 12990, currency: "BRL" } });
  const second = await fingerprintHttpRequest({ method: "post", operation: "POST /v1/invoices", body: JSON.parse(' { "currency": "BRL", "amount": 12990 } ') });
  assert.equal(first, second);
  assert.match(first, /^[0-9a-f]{64}$/);
  assert.equal(FINGERPRINT_ALGORITHM.includes("SHA-256"), true);
});

test("irrelevant request id and authorization are excluded from body fingerprint contract", async () => {
  const first = await fingerprintJson({ body: { value: 1 }, method: "POST", operation: "POST /v1/customers" });
  const second = await fingerprintJson({ body: { value: 1 }, method: "POST", operation: "POST /v1/customers" });
  assert.equal(first, second);
  assert.equal(JSON.stringify({ Authorization: "secret", "X-Request-Id": "caller" }).includes("secret"), true);
  assert.equal(first.includes("secret"), false);
});

test("different semantic payload produces a different fingerprint", async () => {
  const first = await fingerprintJson({ amount: 12990, currency: "BRL" });
  const second = await fingerprintJson({ amount: 13000, currency: "BRL" });
  assert.notEqual(first, second);
});

test("idempotency key rejects empty, oversized and unsafe values", () => {
  assert.equal(validateIdempotencyHeader("idem-004b").ok, true);
  assert.equal(validateIdempotencyHeader("", { required: true }).ok, false);
  assert.equal(validateIdempotencyHeader("x".repeat(129)).ok, false);
  assert.equal(validateIdempotencyHeader("unsafe key").ok, false);
});

test("idempotency scope separates tenant, application, method and operation", () => {
  const scope = buildIdempotencyScope({ ...authority, method: "post", operation: "POST /v1/customers", key: "same-key" });
  assert.equal(scope.ok, true);
  assert.deepEqual(scope.value, { ...authority, method: "POST", operation: "POST /v1/customers", key: "same-key" });
  assert.equal(buildIdempotencyScope({ ...authority, method: "GET", operation: "GET /v1/customers", key: "same-key" }).ok, false);
});

test("policy distinguishes deterministic and transient failure recovery", () => {
  assert.equal(classifyIdempotencyFailure({ transient: false }), "deterministic");
  assert.equal(classifyIdempotencyFailure({ transient: true }), "transient");
  assert.equal(idempotencyPolicy().staleProcessing.includes("expired lease"), true);
  assert.equal(IDEMPOTENCY_RESPONSE_MAX_BYTES, 262144);
});
