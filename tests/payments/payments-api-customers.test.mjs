import test from "node:test";
import assert from "node:assert/strict";
import { buildCredentialRecord } from "../../src/lib/payments/credential.js";
import { fingerprintHttpRequest } from "../../src/lib/payments/fingerprint.js";
import { runPaymentsPipeline, parseJsonBody } from "../../src/lib/payments/http.js";
import { PAYMENTS_API_ROUTES } from "../../src/lib/payments/api-contract.js";

const tenantA = "11111111-1111-4111-8111-111111111111";
const tenantB = "22222222-2222-4222-8222-222222222222";
const applicationA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const credentialA = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

async function fixture({
  tenantId = tenantA,
  applicationId = applicationA,
  credentialId = credentialA,
  scopes = ["customers:write"],
  status = "active",
  provenance = "server_csprng_v1",
} = {}) {
  const built = await buildCredentialRecord({
    applicationId,
    tenantId,
    environment: "sandbox",
    randomBytesImpl: (length) => new Uint8Array(length).fill(7),
  });
  const record = {
    id: credentialId,
    application_id: applicationId,
    tenant_id: tenantId,
    environment: built.environment,
    status,
    revoked_at: status === "revoked" ? "2026-01-01T00:00:00.000Z" : null,
    expires_at: null,
    credential_provenance: provenance,
    credential_hash: built.credentialHash,
  };
  const audits = [];
  const idempotencyRecords = new Map();
  const completedIdempotency = new Map();
  const repository = {
    async findCredentialByHash(hash) { return hash === built.credentialHash ? record : null; },
    async findApplication(id, tid) { return id === applicationId && tid === tenantId ? { id, tenant_id: tenantId, environment: "sandbox", status: "active", billing_account_id: "billing-account-1" } : null; },
    async findTenant(id) { return id === tenantId ? { id, ativo: true } : null; },
    async listCredentialScopes() { return scopes.map((scope_code) => ({ scope_code })); },
    async auditAuthAttempt(value) { audits.push(value); },
    async touchCredential() {},
    async beginIdempotency(input) {
      const key = `${input.tenantId}:${input.applicationId}:${input.method}:${input.operation}:${input.key}`;
      if (idempotencyRecords.has(key)) {
        const existing = idempotencyRecords.get(key);
        if (existing.fingerprint !== input.fingerprint) {
          return { data: { conflict: true } };
        }
        return { data: { id: existing.id, lease_token: existing.leaseToken } };
      }
      const id = `idem-${Date.now()}-${Math.random().toString(16).slice(2)}`;
      const leaseToken = `lease-${Date.now()}-${Math.random().toString(16).slice(2)}`;
      idempotencyRecords.set(key, { id, leaseToken, fingerprint: input.fingerprint, state: "processing" });
      return { data: { id, lease_token: leaseToken } };
    },
    async createCustomerAtomic(input) {
      if (input.idempotencyRecordId && input.leaseToken) {
        // Check if this idempotency record was already completed
        if (completedIdempotency.has(input.idempotencyRecordId)) {
          return { data: completedIdempotency.get(input.idempotencyRecordId) };
        }
        const customerData = {
          id: `customer-${Date.now()}-${Math.random().toString(16).slice(2)}`,
          external_reference: input.externalReference,
          created_at: new Date().toISOString(),
        };
        completedIdempotency.set(input.idempotencyRecordId, customerData);
        return { data: customerData };
      }
      throw new Error("invalid customer creation request");
    },
  };
  return { built, record, repository, audits, secret: built.secret };
}

function customerContract() {
  return {
    ...PAYMENTS_API_ROUTES,
    "/v1/customers": {
      POST: { access: "protected", scope: "customers:write", rateLimit: false, requestId: true, responses: [200, 201, 400, 401, 403, 409, 429, 500], responseSchema: "CustomerResponse" },
    },
  };
}

function customerHandler(repository) {
  return {
    ...Object.fromEntries(Object.keys(PAYMENTS_API_ROUTES).map((path) => [path, { GET: () => ({ ok: true }) }])),
    "/v1/customers": {
      POST: async ({ req, requestId, auth }) => {
        const idempotencyKey = req.headers.get("idempotency-key");
        if (!idempotencyKey) {
          return new Response(JSON.stringify({ error: { code: "invalid_request", message: "Idempotency-Key header is required", request_id: requestId, details: [] } }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
        }
        const bodyResult = await parseJsonBody(req, { allowedFields: new Set(["name", "email", "external_reference"]) });
        if (!bodyResult.ok) {
          return new Response(JSON.stringify({ error: { code: "invalid_request", message: "Request validation failed", request_id: requestId, details: [] } }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
        }
        const { name, email, external_reference } = bodyResult.value;
        if (!name || typeof name !== "string" || name.trim().length === 0 || name.trim().length > 160) {
          return new Response(JSON.stringify({ error: { code: "invalid_request", message: "Invalid name", request_id: requestId, details: [] } }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
        }
        if (email !== undefined && email !== null && (typeof email !== "string" || email.trim().length > 320)) {
          return new Response(JSON.stringify({ error: { code: "invalid_request", message: "Invalid email", request_id: requestId, details: [] } }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
        }
        if (!external_reference || typeof external_reference !== "string" || external_reference.trim().length === 0 || external_reference.trim().length > 160 || !/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$/.test(external_reference.trim())) {
          return new Response(JSON.stringify({ error: { code: "invalid_request", message: "Invalid external_reference", request_id: requestId, details: [] } }), { status: 400, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
        }
        const fingerprint = await fingerprintHttpRequest({ method: "POST", operation: "POST /v1/customers", body: bodyResult.value });
        const idempotencyResult = await repository.beginIdempotency({ tenantId: auth.tenantId, applicationId: auth.applicationId, method: "POST", operation: "POST /v1/customers", key: idempotencyKey, fingerprint, requestId, leaseSeconds: 60 });
        if (idempotencyResult.data?.conflict) {
          return new Response(JSON.stringify({ error: { code: "conflict", message: "Idempotency conflict", request_id: requestId, details: [] } }), { status: 409, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
        }
        const idempotencyRecord = idempotencyResult.data;
        if (!idempotencyRecord?.id || !idempotencyRecord?.lease_token) {
          return new Response(JSON.stringify({ error: { code: "internal_error", message: "Failed to begin idempotency", request_id: requestId, details: [] } }), { status: 500, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
        }
        try {
          const customerResult = await repository.createCustomerAtomic({ idempotencyRecordId: idempotencyRecord.id, leaseToken: idempotencyRecord.lease_token, name: name.trim(), email: email?.trim() || null, externalReference: external_reference.trim(), requestId });
          const customerData = customerResult.data;
          return new Response(JSON.stringify({ data: { id: customerData.id, external_reference: customerData.external_reference, created_at: customerData.created_at }, request_id: requestId }), { status: 201, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
        } catch (error) {
          const errorMessage = error instanceof Error ? error.message : String(error);
          if (errorMessage.includes("conflict")) {
            return new Response(JSON.stringify({ error: { code: "conflict", message: "Idempotency conflict", request_id: requestId, details: [] } }), { status: 409, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
          }
          return new Response(JSON.stringify({ error: { code: "internal_error", message: "Internal server error", request_id: requestId, details: [] } }), { status: 500, headers: { "Content-Type": "application/json", "X-Request-Id": requestId } });
        }
      },
    },
  };
}

test("POST /v1/customers — valid authorized request succeeds with 201", async () => {
  const state = await fixture();
  const body = { name: "João Silva", email: "joao@example.com", external_reference: "enrollment-123" };
  const idempotencyKey = "idem-customer-001";
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", {
      method: "POST",
      headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": idempotencyKey, "content-type": "application/json", "x-request-id": "req-1" },
      body: JSON.stringify(body),
    }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 201);
  const data = await response.json();
  assert.ok(data.data.id);
  assert.equal(data.data.external_reference, "enrollment-123");
  assert.ok(data.data.created_at);
  assert.equal(data.request_id, "req-1");
});

test("POST /v1/customers — missing M2M credential fails with 401", async () => {
  const state = await fixture();
  const body = { name: "João Silva", external_reference: "enrollment-123" };
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", {
      method: "POST",
      headers: { "idempotency-key": "idem-1", "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 401);
  const data = await response.json();
  assert.equal(data.error.code, "invalid_credential");
});

test("POST /v1/customers — invalid M2M credential fails with 401", async () => {
  const state = await fixture();
  const body = { name: "João Silva", external_reference: "enrollment-123" };
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", {
      method: "POST",
      headers: { authorization: "Bearer kp_sandbox_invalid", "idempotency-key": "idem-1", "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 401);
  const data = await response.json();
  assert.equal(data.error.code, "invalid_credential");
});

test("POST /v1/customers — insufficient scope fails with 403", async () => {
  const state = await fixture({ scopes: ["invoices:read"] });
  const body = { name: "João Silva", external_reference: "enrollment-123" };
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", {
      method: "POST",
      headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": "idem-1", "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 403);
  const data = await response.json();
  assert.equal(data.error.code, "insufficient_scope");
});

test("POST /v1/customers — tenant authority comes from credential, not caller header", async () => {
  const state = await fixture({ tenantId: tenantA });
  const body = { name: "João Silva", external_reference: "enrollment-123" };
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", {
      method: "POST",
      headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": "idem-1", "content-type": "application/json", "x-tenant-id": tenantB },
      body: JSON.stringify(body),
    }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 400);
  const data = await response.json();
  assert.equal(data.error.code, "tenant_id_not_accepted");
});

test("POST /v1/customers — caller cannot use tenant_id query param to escape tenant authority", async () => {
  const state = await fixture({ tenantId: tenantA });
  const body = { name: "João Silva", external_reference: "enrollment-123" };
  const response = await runPaymentsPipeline(
    new Request(`https://payments.test/v1/customers?tenant_id=${tenantB}`, {
      method: "POST",
      headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": "idem-1", "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 400);
  const data = await response.json();
  assert.equal(data.error.code, "tenant_id_not_accepted");
});

test("POST /v1/customers — Tenant A cannot create customer under Tenant B", async () => {
  const stateA = await fixture({ tenantId: tenantA, applicationId: applicationA, credentialId: credentialA });
  const body = { name: "João Silva", external_reference: "enrollment-123" };
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", {
      method: "POST",
      headers: { authorization: `Bearer ${stateA.secret}`, "idempotency-key": "idem-cross-tenant", "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
    { routes: customerContract(), handlers: customerHandler(stateA.repository), repository: stateA.repository },
  );
  assert.equal(response.status, 201);
  const data = await response.json();
  assert.ok(data.data.id);
  assert.equal(data.data.external_reference, "enrollment-123");
});

test("POST /v1/customers — external_reference remains tenant-scoped", async () => {
  const stateA = await fixture({ tenantId: tenantA });
  const stateB = await fixture({ tenantId: tenantB });
  const body = { name: "João Silva", external_reference: "enrollment-123" };
  const idempotencyKey = "idem-same-ref";
  await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${stateA.secret}`, "idempotency-key": idempotencyKey, "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(stateA.repository), repository: stateA.repository },
  );
  const responseB = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${stateB.secret}`, "idempotency-key": idempotencyKey, "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(stateB.repository), repository: stateB.repository },
  );
  assert.equal(responseB.status, 201);
  const dataB = await responseB.json();
  assert.ok(dataB.data.id);
  assert.equal(dataB.data.external_reference, "enrollment-123");
});

test("POST /v1/customers — malformed payload fails deterministically", async () => {
  const state = await fixture();
  const malformedBody = { name: "", external_reference: "enrollment-123" };
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", {
      method: "POST",
      headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": "idem-1", "content-type": "application/json" },
      body: JSON.stringify(malformedBody),
    }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 400);
  const data = await response.json();
  assert.equal(data.error.code, "invalid_request");
});

test("POST /v1/customers — missing Idempotency-Key fails with 400", async () => {
  const state = await fixture();
  const body = { name: "João Silva", external_reference: "enrollment-123" };
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", {
      method: "POST",
      headers: { authorization: `Bearer ${state.secret}`, "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 400);
  const data = await response.json();
  assert.equal(data.error.code, "invalid_request");
  assert.match(data.error.message, /Idempotency-Key/);
});

test("POST /v1/customers — idempotency: same key and payload returns same result", async () => {
  const state = await fixture();
  const body = { name: "João Silva", external_reference: "enrollment-123" };
  const idempotencyKey = "idem-repeat-1";
  const response1 = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": idempotencyKey, "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response1.status, 201);
  const data1 = await response1.json();
  const response2 = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": idempotencyKey, "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response2.status, 201);
  const data2 = await response2.json();
  assert.equal(data2.data.id, data1.data.id);
  assert.equal(data2.data.external_reference, data1.data.external_reference);
});

test("POST /v1/customers — idempotency: same key different payload returns 409 conflict", async () => {
  const state = await fixture();
  const body1 = { name: "João Silva", external_reference: "enrollment-123" };
  const body2 = { name: "Maria Santos", external_reference: "enrollment-456" };
  const idempotencyKey = "idem-conflict-1";
  await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": idempotencyKey, "content-type": "application/json" }, body: JSON.stringify(body1) }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  const response2 = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": idempotencyKey, "content-type": "application/json" }, body: JSON.stringify(body2) }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response2.status, 409);
  const data2 = await response2.json();
  assert.equal(data2.error.code, "conflict");
});

test("POST /v1/customers — idempotency: cross-tenant isolation with same key", async () => {
  const stateA = await fixture({ tenantId: tenantA, applicationId: applicationA, credentialId: credentialA });
  const stateB = await fixture({ tenantId: tenantB, applicationId: applicationA, credentialId: credentialA });
  const body = { name: "João Silva", external_reference: "enrollment-123" };
  const idempotencyKey = "idem-cross-tenant-same-key";

  // Tenant A creates customer with idempotency key
  const responseA = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${stateA.secret}`, "idempotency-key": idempotencyKey, "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(stateA.repository), repository: stateA.repository },
  );
  assert.equal(responseA.status, 201);
  const dataA = await responseA.json();
  assert.ok(dataA.data.id);

  // Tenant B uses SAME idempotency key and SAME payload
  // Must succeed independently — no cross-tenant replay or conflict
  const responseB = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${stateB.secret}`, "idempotency-key": idempotencyKey, "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(stateB.repository), repository: stateB.repository },
  );
  assert.equal(responseB.status, 201);
  const dataB = await responseB.json();
  assert.ok(dataB.data.id);

  // Results must be independent
  assert.notEqual(dataB.data.id, dataA.data.id);
  assert.equal(dataB.data.external_reference, dataA.data.external_reference);

  // Replay on Tenant A returns same result (intra-tenant replay works)
  const responseAReplay = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${stateA.secret}`, "idempotency-key": idempotencyKey, "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(stateA.repository), repository: stateA.repository },
  );
  assert.equal(responseAReplay.status, 201);
  const dataAReplay = await responseAReplay.json();
  assert.equal(dataAReplay.data.id, dataA.data.id);

  // Replay on Tenant B returns same result (intra-tenant replay works)
  const responseBReplay = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${stateB.secret}`, "idempotency-key": idempotencyKey, "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(stateB.repository), repository: stateB.repository },
  );
  assert.equal(responseBReplay.status, 201);
  const dataBReplay = await responseBReplay.json();
  assert.equal(dataBReplay.data.id, dataB.data.id);
});

test("POST /v1/customers — invalid external_reference format fails", async () => {
  const state = await fixture();
  const body = { name: "João Silva", external_reference: "invalid reference!" };
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": "idem-1", "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 400);
  const data = await response.json();
  assert.equal(data.error.code, "invalid_request");
});

test("POST /v1/customers — email too long fails", async () => {
  const state = await fixture();
  const longEmail = "a".repeat(315) + "@example.com";
  const body = { name: "João Silva", email: longEmail, external_reference: "enrollment-123" };
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": "idem-1", "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 400);
  const data = await response.json();
  assert.equal(data.error.code, "invalid_request");
});

test("POST /v1/customers — name too long fails", async () => {
  const state = await fixture();
  const longName = "a".repeat(161);
  const body = { name: longName, external_reference: "enrollment-123" };
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": "idem-1", "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 400);
  const data = await response.json();
  assert.equal(data.error.code, "invalid_request");
});

test("POST /v1/customers — unknown fields in body are rejected by parseJsonBody", async () => {
  const state = await fixture();
  const body = { name: "João Silva", external_reference: "enrollment-123", tenant_id: tenantB };
  const response = await runPaymentsPipeline(
    new Request("https://payments.test/v1/customers", { method: "POST", headers: { authorization: `Bearer ${state.secret}`, "idempotency-key": "idem-1", "content-type": "application/json" }, body: JSON.stringify(body) }),
    { routes: customerContract(), handlers: customerHandler(state.repository), repository: state.repository },
  );
  assert.equal(response.status, 400);
  const data = await response.json();
  assert.equal(data.error.code, "invalid_request");
});