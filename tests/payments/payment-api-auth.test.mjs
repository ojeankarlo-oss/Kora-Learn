import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  buildCredentialRecord,
  generateCredential,
  rotateCredentialRecord,
  verifyCredential,
} from "../../src/lib/payments/credential.js";
import {
  authenticatePaymentCredential,
  rejectCallerTenantOverride,
  requirePaymentScope,
} from "../../src/lib/payments/auth.js";

function fixedRandomBytes(seed) {
  return (length) => Uint8Array.from({ length }, (_, index) => (seed + index) % 256);
}

async function fixture({ seed = 1, applicationStatus = "active", tenantActive = true, expiresAt = null, status = "active" } = {}) {
  const built = await buildCredentialRecord({
    applicationId: "app-a",
    tenantId: "tenant-a",
    environment: "sandbox",
    now: new Date("2026-09-09T00:00:00Z"),
    randomBytesImpl: fixedRandomBytes(seed),
  });
  const record = {
    id: "credential-a",
    application_id: built.applicationId,
    tenant_id: built.tenantId,
    environment: built.environment,
    credential_hash: built.credentialHash,
    public_prefix: built.publicPrefix,
    credential_provenance: "server_csprng_v1",
    status,
    revoked_at: status === "revoked" ? "2026-09-09T00:01:00Z" : null,
    expires_at: expiresAt,
  };
  const audits = [];
  const touches = [];
  const repository = {
    async findCredentialByHash(hash) { return hash === record.credential_hash ? record : null; },
    async findApplication(id, tenantId) {
      return id === "app-a" && tenantId === "tenant-a" ? { id, tenant_id: tenantId, status: applicationStatus } : null;
    },
    async findTenant(id) { return id === "tenant-a" ? { id, ativo: tenantActive } : null; },
    async listCredentialScopes() { return [{ scope_code: "invoices:read" }, { scope_code: "payment_intents:write" }]; },
    async auditAuthAttempt(event) { audits.push(event); },
    async touchCredential(event) { touches.push(event); },
  };
  return { built, record, repository, audits, touches, secret: built.secret };
}

test("credential válida autentica e deriva application/tenant/scopes do registro", async () => {
  const state = await fixture();
  const result = await authenticatePaymentCredential({
    credential: state.secret,
    repository: state.repository,
    request: new Request("https://payments.test/v1/invoices", { headers: { "x-request-id": "req-valid" } }),
    now: new Date("2026-09-09T00:02:00Z"),
  });
  assert.equal(result.ok, true);
  assert.equal(result.context.applicationId, "app-a");
  assert.equal(result.context.tenantId, "tenant-a");
  assert.equal(result.context.credentialId, "credential-a");
  assert.equal(result.context.requestId, "req-valid");
  assert.equal(result.context.scopes.has("invoices:read"), true);
  assert.equal(result.context.scopes.has("payment_intents:write"), true);
  assert.equal(state.touches.length, 1);
  assert.deepEqual(state.touches[0], { credentialId: "credential-a", requestId: "req-valid" });
});

test("credencial inválida, revogada e expirada falham de forma sanitizada", async () => {
  const invalid = await fixture();
  const invalidResult = await authenticatePaymentCredential({ credential: "kp_sandbox_not-a-real-secret", repository: invalid.repository });
  assert.equal(invalidResult.status, 401);
  assert.equal(invalidResult.code, "invalid_credential");

  const revoked = await fixture({ status: "revoked" });
  const revokedResult = await authenticatePaymentCredential({ credential: revoked.secret, repository: revoked.repository });
  assert.equal(revokedResult.status, 401);
  assert.equal(revokedResult.code, "invalid_credential");
  assert.equal(revoked.audits[0].reason, "revoked");

  const expired = await fixture({ expiresAt: "2026-09-08T23:59:59Z" });
  const expiredResult = await authenticatePaymentCredential({
    credential: expired.secret,
    repository: expired.repository,
    now: new Date("2026-09-09T00:02:00Z"),
  });
  assert.equal(expiredResult.status, 401);
  assert.equal(expiredResult.code, "invalid_credential");
  assert.equal(expired.audits[0].reason, "expired_or_inactive");
});

test("application desativada e tenant inativo falham fechado", async () => {
  const inactiveApplication = await fixture({ applicationStatus: "suspended" });
  const applicationResult = await authenticatePaymentCredential({ credential: inactiveApplication.secret, repository: inactiveApplication.repository });
  assert.equal(applicationResult.status, 401);
  assert.equal(applicationResult.code, "invalid_credential");

  const inactiveTenant = await fixture({ tenantActive: false });
  const tenantResult = await authenticatePaymentCredential({ credential: inactiveTenant.secret, repository: inactiveTenant.repository });
  assert.equal(tenantResult.status, 401);
  assert.equal(tenantResult.code, "invalid_credential");
});

test("scope permitido passa e scope ausente retorna 403", async () => {
  const state = await fixture();
  const auth = await authenticatePaymentCredential({ credential: state.secret, repository: state.repository });
  assert.equal(requirePaymentScope(auth, "invoices:read").ok, true);
  const denied = requirePaymentScope(auth, "refunds:write");
  assert.equal(denied.ok, false);
  assert.equal(denied.status, 403);
  assert.equal(denied.code, "insufficient_scope");
});

test("tenant_id do caller nunca substitui a autoridade da credential", async () => {
  assert.deepEqual(rejectCallerTenantOverride({ amount_minor: 1000 }), { ok: true });
  const rejectedSnake = rejectCallerTenantOverride({ tenant_id: "tenant-b" });
  assert.equal(rejectedSnake.ok, false);
  assert.equal(rejectedSnake.status, 400);
  const rejectedCamel = rejectCallerTenantOverride({ tenantId: "tenant-b" });
  assert.equal(rejectedCamel.ok, false);
  assert.equal(rejectedCamel.status, 400);
});

test("secret é exibido somente no retorno transitório e nunca é o hash persistido", async () => {
  const state = await fixture();
  assert.equal(typeof state.secret, "string");
  assert.notEqual(state.built.credentialHash, state.secret);
  assert.match(state.built.credentialHash, /^[0-9a-f]{64}$/);
  assert.equal(await verifyCredential(state.secret, state.built.credentialHash), true);
  assert.equal(await verifyCredential(`${state.secret}x`, state.built.credentialHash), false);
  const persisted = { ...state.built };
  delete persisted.secret;
  assert.equal(Object.hasOwn(persisted, "secret"), false);
});

test("rotação cria nova credential e invalida a antiga por lifecycle", async () => {
  const first = await fixture({ seed: 10 });
  const current = {
    ...first.built,
    id: "credential-a",
    applicationId: "app-a",
    tenantId: "tenant-a",
    status: "active",
    revokedAt: null,
  };
  const rotated = await rotateCredentialRecord({
    current,
    now: new Date("2026-09-09T00:03:00Z"),
    randomBytesImpl: fixedRandomBytes(20),
  });
  assert.notEqual(rotated.previous.credentialHash, rotated.next.credentialHash);
  assert.equal(rotated.previous.status, "revoked");
  assert.equal(rotated.previous.revokedAt, "2026-09-09T00:03:00.000Z");
  assert.equal(rotated.next.rotatedFromId, "credential-a");
  assert.equal(rotated.next.rotatedAt, "2026-09-09T00:03:00.000Z");
  const oldRevoked = { ...first.record, status: "revoked", revoked_at: "2026-09-09T00:03:00Z" };
  const oldRepo = { ...first.repository, async findCredentialByHash(hash) { return hash === oldRevoked.credential_hash ? oldRevoked : null; } };
  const oldResult = await authenticatePaymentCredential({ credential: first.secret, repository: oldRepo });
  assert.equal(oldResult.status, 401);
});

test("auditoria local não serializa credential ou Authorization header", async () => {
  const state = await fixture({ status: "revoked" });
  await authenticatePaymentCredential({
    credential: state.secret,
    repository: state.repository,
    request: new Request("https://payments.test/v1/invoices", { headers: { authorization: `Bearer ${state.secret}`, "x-request-id": "req-log" } }),
  });
  const serialized = JSON.stringify(state.audits);
  assert.equal(serialized.includes(state.secret), false);
  assert.equal(serialized.includes("Authorization"), false);
  assert.equal(serialized.includes("authorization"), false);
});

test("credential generation uses public prefix without making the secret recoverable", () => {
  const generated = generateCredential({ environment: "production", randomBytesImpl: fixedRandomBytes(3) });
  assert.match(generated.secret, /^kp_production_/);
  assert.match(generated.publicPrefix, /^kp_production_[a-f0-9]{16}$/);
  assert.equal(generated.publicPrefix.length < generated.secret.length, true);
});


test("application e scopes são normalizados por helper reutilizável", async () => {
  const { normalizeApplication, normalizeScopes, hasScope } = await import("../../src/lib/payments/application.js");
  const application = normalizeApplication({ tenantId: "tenant-a", name: "ENEM", slug: "ENEM-App", environment: "sandbox" });
  assert.deepEqual(application, { tenantId: "tenant-a", name: "ENEM", slug: "enem-app", environment: "sandbox", status: "active" });
  const scopes = normalizeScopes(["Invoices:Read", "invoices:read", "payment_intents:write"]);
  assert.deepEqual(scopes, ["invoices:read", "payment_intents:write"]);
  assert.equal(hasScope(scopes, "invoices:read"), true);
  assert.equal(hasScope(scopes, "refunds:write"), false);
  assert.throws(() => normalizeApplication({ tenantId: "tenant-a", name: "ENEM", slug: "bad slug" }), /Slug/);
  assert.throws(() => normalizeScopes(["not-a-scope"]), /Scope/);
});


test("credential legacy_unverified falha fechado mesmo com hash correto", async () => {
  const state = await fixture();
  const legacy = { ...state.record, credential_provenance: "legacy_unverified" };
  const legacyRepository = { ...state.repository, async findCredentialByHash(hash) { return hash === legacy.credential_hash ? legacy : null; } };
  const result = await authenticatePaymentCredential({ credential: state.secret, repository: legacyRepository });
  assert.equal(result.status, 401);
  assert.equal(result.code, "invalid_credential");
  assert.equal(state.audits[0].reason, "unverified_provenance");
});

test("causas de inatividade não são enumeradas na resposta externa", async () => {
  const application = await fixture({ applicationStatus: "suspended" });
  const tenant = await fixture({ tenantActive: false });
  const appResult = await authenticatePaymentCredential({ credential: application.secret, repository: application.repository });
  const tenantResult = await authenticatePaymentCredential({ credential: tenant.secret, repository: tenant.repository });
  assert.deepEqual(
    { status: appResult.status, code: appResult.code },
    { status: tenantResult.status, code: tenantResult.code },
  );
  assert.notEqual(application.audits[0].reason, tenant.audits[0].reason);
});

test("migration 033 fecha a provenance no banco e gera o secret dentro da RPC", () => {
  const migration = readFileSync(new URL("../../supabase/migrations/033_kora_p1_pay_api_credential_hardening.sql", import.meta.url), "utf8");
  assert.match(migration, /gen_random_bytes\(32\)/);
  assert.match(migration, /digest\(v_raw_secret, 'sha256'\)/);
  assert.match(migration, /credential_provenance.*server_csprng_v1/s);
  assert.doesNotMatch(migration, /p_secret/);
  assert.match(migration, /revoke all on function public\.create_payment_api_credential/s);
  assert.match(migration, /grant execute on function public\.create_payment_api_credential[\s\S]+to service_role/);
});
