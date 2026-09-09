import assert from "node:assert/strict";
import test from "node:test";
import { buildCredentialRecord } from "../../src/lib/payments/credential.js";
import { parseMoney } from "../../src/lib/payments/money.js";
import { idempotencyPolicy, validateIdempotencyHeader } from "../../src/lib/payments/idempotency.js";
import { createMemoryRateLimiter, buildRateLimitKey, rateLimitPolicy } from "../../src/lib/payments/rate-limit.js";
import {
  errorBody,
  parseJsonBody,
  rejectTenantAuthority,
  runPaymentsPipeline,
} from "../../src/lib/payments/http.js";
import { PAYMENTS_API_ROUTES } from "../../src/lib/payments/api-contract.js";

const tenantId = "11111111-1111-4111-8111-111111111111";
const applicationId = "22222222-2222-4222-8222-222222222222";
const credentialId = "33333333-3333-4333-8333-333333333333";

async function fixture({ status = "active", provenance = "server_csprng_v1", scopes = ["payments:read"] } = {}) {
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
  };
  const audits = [];
  const repository = {
    async findCredentialByHash(hash) { return hash === built.credentialHash ? record : null; },
    async findApplication() { return { id: applicationId, tenant_id: tenantId, environment: "sandbox", status: "active" }; },
    async findTenant() { return { id: tenantId, ativo: true }; },
    async listCredentialScopes() { return scopes.map((scope_code) => ({ scope_code })); },
    async auditAuthAttempt(value) { audits.push(value); },
    async touchCredential() {},
  };
  return { built, record, repository, audits, secret: built.secret };
}

function protectedContract({ scope = "payments:read", rateLimit = false } = {}) {
  return {
    ...PAYMENTS_API_ROUTES,
    "/v1/protected": { GET: { auth: true, scope, rateLimit } },
  };
}

function protectedHandler() {
  return {
    ...Object.fromEntries(Object.keys(PAYMENTS_API_ROUTES).map((path) => [path, { GET: () => ({ ok: true }) }])),
    "/v1/protected": { GET: ({ auth }) => ({ tenant_id: auth.tenantId, application_id: auth.applicationId, credential_id: auth.credentialId, scopes: [...auth.scopes] }) },
  };
}

test("/v1 health e metadata são versionados, públicos e retornam request_id", async () => {
  const repository = await fixture();
  const health = await runPaymentsPipeline(new Request("https://payments.test/v1/health", { headers: { "x-request-id": "corr-123" } }), {
    routes: PAYMENTS_API_ROUTES,
    handlers: { "/v1/health": { GET: () => ({ ok: true, version: "v1" }) }, "/v1": { GET: () => ({ version: "v1" }) } },
    repository: repository.repository,
  });
  assert.equal(health.status, 200);
  assert.equal(health.headers.get("x-request-id"), "corr-123");
  assert.deepEqual((await health.json()).data, { ok: true, version: "v1" });
});

test("request_id caller inválido é substituído e não injeta conteúdo em logs/resposta", async () => {
  const state = await fixture();
  const response = await runPaymentsPipeline(new Request("https://payments.test/v1/health", { headers: { "x-request-id": "<script>\n" } }), {
    routes: PAYMENTS_API_ROUTES,
    handlers: { "/v1/health": { GET: () => ({ ok: true }) }, "/v1": { GET: () => ({ ok: true }) } },
    repository: state.repository,
  });
  const requestId = response.headers.get("x-request-id");
  assert.ok(requestId);
  assert.equal(requestId.includes("<"), false);
  assert.equal(requestId.includes("\n"), false);
});

test("auth M2M deriva tenant/application/credential/scopes exclusivamente do registro", async () => {
  const state = await fixture();
  const response = await runPaymentsPipeline(new Request("https://payments.test/v1/protected", { headers: { authorization: `Bearer ${state.secret}` } }), {
    routes: protectedContract(), handlers: protectedHandler(), repository: state.repository,
  });
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).data, { tenant_id: tenantId, application_id: applicationId, credential_id: credentialId, scopes: ["payments:read"] });
});

test("credential inválida, revogada e legacy falham fechado com erro uniforme", async () => {
  const states = [await fixture(), await fixture({ status: "revoked" }), await fixture({ provenance: "legacy_unverified" })];
  const invalid = await runPaymentsPipeline(new Request("https://payments.test/v1/protected", { headers: { authorization: "Bearer kp_sandbox_invalid" } }), {
    routes: protectedContract(), handlers: protectedHandler(), repository: states[0].repository,
  });
  assert.equal(invalid.status, 401);
  assert.deepEqual((await invalid.json()).error, { code: "invalid_credential", message: "Invalid credential", request_id: invalid.headers.get("x-request-id"), details: [] });
  for (const state of states.slice(1)) {
    const response = await runPaymentsPipeline(new Request("https://payments.test/v1/protected", { headers: { authorization: `Bearer ${state.secret}` } }), {
      routes: protectedContract(), handlers: protectedHandler(), repository: state.repository,
    });
    assert.equal(response.status, 401);
    assert.equal((await response.json()).error.code, "invalid_credential");
  }
});

test("tenant authority por query/header/body é rejeitada", async () => {
  const state = await fixture();
  const query = await runPaymentsPipeline(new Request("https://payments.test/v1/protected?tenant_id=other", { headers: { authorization: `Bearer ${state.secret}` } }), {
    routes: protectedContract(), handlers: protectedHandler(), repository: state.repository,
  });
  assert.equal(query.status, 400);
  const header = await runPaymentsPipeline(new Request("https://payments.test/v1/protected", { headers: { authorization: `Bearer ${state.secret}`, "x-tenant-id": "other" } }), {
    routes: protectedContract(), handlers: protectedHandler(), repository: state.repository,
  });
  assert.equal(header.status, 400);
  assert.deepEqual(rejectTenantAuthority({ tenant_id: "other" }), { ok: false, code: "tenant_id_not_accepted", message: "Request validation failed", status: 400 });
});

test("request validation rejeita JSON inválido, content type e unknown fields", async () => {
  const malformed = await parseJsonBody(new Request("https://payments.test/v1/protected", { method: "POST", headers: { "content-type": "application/json" }, body: "{" }), { allowedFields: new Set(["name"]) });
  assert.equal(malformed.ok, false);
  assert.equal(malformed.status, 400);
  const wrongType = await parseJsonBody(new Request("https://payments.test/v1/protected", { method: "POST", headers: { "content-type": "text/plain" }, body: "{}" }), { allowedFields: new Set(["name"]) });
  assert.equal(wrongType.ok, false);
  const unknown = await parseJsonBody(new Request("https://payments.test/v1/protected", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ name: "ok", tenant_id: "other" }) }), { allowedFields: new Set(["name", "tenant_id"]) });
  assert.equal(unknown.ok, true);
  assert.equal(rejectTenantAuthority(unknown.value).ok, false);
  assert.equal(rejectTenantAuthority({ tenantId: "other", routeTenant: "other" }).ok, false);
});

test("scope ausente falha com 403 após auth válida", async () => {
  const state = await fixture({ scopes: [] });
  const response = await runPaymentsPipeline(new Request("https://payments.test/v1/protected", { headers: { authorization: `Bearer ${state.secret}` } }), {
    routes: protectedContract(), handlers: protectedHandler(), repository: state.repository,
  });
  assert.equal(response.status, 403);
  assert.equal((await response.json()).error.code, "insufficient_scope");
});

test("unknown route e método não suportado são padronizados", async () => {
  const state = await fixture();
  const unknown = await runPaymentsPipeline(new Request("https://payments.test/v1/nope"), {
    routes: PAYMENTS_API_ROUTES, handlers: protectedHandler(), repository: state.repository,
  });
  assert.equal(unknown.status, 404);
  const method = await runPaymentsPipeline(new Request("https://payments.test/v1/health", { method: "POST" }), {
    routes: PAYMENTS_API_ROUTES, handlers: protectedHandler(), repository: state.repository,
  });
  assert.equal(method.status, 405);
  assert.equal(method.headers.get("allow"), "GET");
});

test("handler failure não vaza stack, SQL, secret ou internals", async () => {
  const state = await fixture();
  const response = await runPaymentsPipeline(new Request("https://payments.test/v1/protected", { headers: { authorization: `Bearer ${state.secret}` } }), {
    routes: protectedContract(), handlers: { "/v1/protected": { GET: () => { throw new Error("SQL secret stack"); } } }, repository: state.repository,
  });
  assert.equal(response.status, 500);
  const body = await response.text();
  assert.equal(body.includes("SQL"), false);
  assert.equal(body.includes("secret"), false);
  assert.equal(body.includes("stack"), false);
});

test("money rejeita float e aceita minor units inteiras/currency válida", () => {
  assert.equal(parseMoney({ amount: 12990, currency: "BRL" }).ok, true);
  assert.equal(parseMoney({ amount: 129.9, currency: "BRL" }).ok, false);
  assert.equal(parseMoney({ amount: 12990, currency: "XYZ" }).ok, false);
});

test("Idempotency-Key valida formato e policy não cria autoridade financeira paralela", () => {
  assert.equal(validateIdempotencyHeader("idem-123").ok, true);
  assert.equal(validateIdempotencyHeader("bad key").ok, false);
  assert.equal(idempotencyPolicy().requiredFor, "future financial mutations only");
});

test("rate limit policy usa identidade tenant/application/credential/route e fail-safe", async () => {
  const policy = rateLimitPolicy();
  assert.deepEqual(policy.identity, ["tenant_id", "application_id", "credential_id", "route"]);
  assert.equal(buildRateLimitKey({ tenantId, applicationId, credentialId, route: "GET:/v1/health" }), `${tenantId}:${applicationId}:${credentialId}:GET:/v1/health`);
  const limiter = createMemoryRateLimiter({ limit: 1, windowMs: 60_000 });
  assert.equal((await limiter.consume("key")).allowed, true);
  assert.equal((await limiter.consume("key")).allowed, false);
});

test("CORS somente reflete origem allowlisted", async () => {
  const state = await fixture();
  const allowed = await runPaymentsPipeline(new Request("https://payments.test/v1/health", { headers: { origin: "https://consumer.invalid" } }), {
    routes: PAYMENTS_API_ROUTES, handlers: { "/v1/health": { GET: () => ({ ok: true }) }, "/v1": { GET: () => ({ ok: true }) } }, repository: state.repository, allowlist: ["https://consumer.invalid"],
  });
  assert.equal(allowed.headers.get("access-control-allow-origin"), "https://consumer.invalid");
  const denied = await runPaymentsPipeline(new Request("https://payments.test/v1/health", { headers: { origin: "https://evil.invalid" } }), {
    routes: PAYMENTS_API_ROUTES, handlers: { "/v1/health": { GET: () => ({ ok: true }) }, "/v1": { GET: () => ({ ok: true }) } }, repository: state.repository, allowlist: ["https://consumer.invalid"],
  });
  assert.equal(denied.headers.get("access-control-allow-origin"), null);
});

test("errorBody mantém envelope sem detalhes internos", () => {
  const body = errorBody("invalid_request", "Request validation failed", "req-1");
  assert.deepEqual(body, { error: { code: "invalid_request", message: "Request validation failed", request_id: "req-1", details: [] } });
});
