import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { buildCredentialRecord } from "../../src/lib/payments/credential.js";
import { createPaymentsApi } from "../../src/lib/payments/api-runtime.js";
import { createPaymentsRepository } from "../../src/lib/payments/supabase-repository.js";
import { fingerprintHttpRequest } from "../../src/lib/payments/fingerprint.js";

// HTTP/repository contract fixture only; SQL invariants and concurrency require PostgreSQL.
// Both tenants use this ONE store and the real production repository adapter. The simulated
// RPCs mirror migrations 034/038: begin, fenced Customer completion and fenced failure.
async function fixture({ scopes = ["customers:write"], namespace = "tenant-application", rateLimiter } = {}) {
  const identities = [];
  for (let i = 0; i < 2; i++) {
    const tenantId = randomUUID(), applicationId = randomUUID(), credentialId = randomUUID();
    const built = await buildCredentialRecord({ tenantId, applicationId, environment: "sandbox", randomBytesImpl: n => new Uint8Array(n).fill(i + 7) });
    identities.push({ tenantId, applicationId, credentialId, built });
  }
  const tables = {
    payment_api_credentials: identities.map(x => ({ id: x.credentialId, tenant_id: x.tenantId, application_id: x.applicationId, credential_hash: x.built.credentialHash, status: "active", environment: "sandbox", credential_provenance: "server_csprng_v1" })),
    payment_api_applications: identities.map(x => ({ id: x.applicationId, tenant_id: x.tenantId, status: "active", environment: "sandbox" })),
    tenants: identities.map(x => ({ id: x.tenantId, ativo: true })),
    payment_api_credential_scopes: identities.flatMap(x => scopes.map(scope_code => ({ credential_id: x.credentialId, tenant_id: x.tenantId, scope_code }))),
  };
  const records = new Map(), customers = new Map(), references = new Map(), calls = [];
  const state = { identities, tables, records, customers, references, calls, beginOverride: undefined, atomicError: null, failError: null };
  const leaseInvalid = message => ({ data: null, error: { code: "P0001", message, details: null, hint: null } });
  const admin = {
    from(table) {
      const filters = [];
      const result = () => ({ data: tables[table].filter(row => filters.every(([k, v]) => row[k] === v)), error: null });
      const query = { select() { return query; }, eq(k, v) { filters.push([k, v]); return query; }, async maybeSingle() { return { ...result(), data: result().data[0] ?? null }; }, then(resolve, reject) { return Promise.resolve(result()).then(resolve, reject); } };
      return query;
    },
    async rpc(name, args) {
      calls.push({ name, args });
      if (name === "payment_api_touch_credential" || name === "payment_api_audit_auth_attempt") return { data: null, error: null };
      if (name === "payment_api_begin_idempotency") {
        if (state.beginOverride !== undefined) return { data: state.beginOverride, error: null };
        assert.ok(identities.some(x => x.tenantId === args.p_tenant_id && x.applicationId === args.p_application_id));
        const scope = namespace === "tenant-application"
          ? [args.p_tenant_id, args.p_application_id, args.p_http_method, args.p_operation, args.p_idempotency_key]
          : [args.p_http_method, args.p_operation, args.p_idempotency_key]; // deliberately broken namespace
        const key = JSON.stringify(scope);
        const old = records.get(key);
        if (old) {
          if (old.fingerprint !== args.p_request_fingerprint) return { data: { decision: "conflict", record_id: old.id }, error: null };
          if (old.state === "completed" || (old.state === "failed" && old.failureKind === "deterministic")) return { data: { decision: "replay", record_id: old.id, status: old.status, body: old.body }, error: null };
          if (old.state === "processing") return { data: { decision: "in_progress", record_id: old.id, retry_after_seconds: 60 }, error: null };
          old.state = "processing"; old.token = randomUUID(); old.status = old.body = old.failureKind = null;
          return { data: { decision: "acquired", record_id: old.id, lease_token: old.token }, error: null };
        }
        const record = { id: randomUUID(), token: randomUUID(), state: "processing", tenantId: args.p_tenant_id, applicationId: args.p_application_id, fingerprint: args.p_request_fingerprint };
        records.set(key, record);
        return { data: { decision: "acquired", record_id: record.id, lease_token: record.token }, error: null };
      }
      const record = [...records.values()].find(x => x.id === args.p_idempotency_record_id || x.id === args.p_record_id);
      const leaseHeld = record && record.state === "processing" && record.token === args.p_lease_token;
      if (name === "payment_api_create_customer_atomic") {
        if (!leaseHeld) return leaseInvalid("customer idempotency lease invalid");
        if (state.atomicError) return { data: null, error: state.atomicError }; // transaction rolled back; lease stays held
        const refKey = JSON.stringify([record.tenantId, record.applicationId, args.p_external_reference]);
        if (references.has(refKey)) return leaseInvalid("external_reference_conflict");
        const data = { id: randomUUID(), external_reference: args.p_external_reference, created_at: new Date().toISOString() };
        customers.set(data.id, { ...data, tenantId: record.tenantId, applicationId: record.applicationId });
        references.set(refKey, data.id);
        Object.assign(record, { state: "completed", status: 201, body: { data, request_id: args.p_request_id }, token: null });
        return { data: record.body, error: null };
      }
      if (name === "payment_api_fail_idempotency") {
        if (state.failError) return { data: null, error: state.failError };
        assert.ok(args.p_response_status >= 400 && args.p_response_status <= 599);
        assert.ok(["deterministic", "transient"].includes(args.p_failure_kind));
        if (!leaseHeld) return leaseInvalid("idempotency lease invalid");
        Object.assign(record, { state: "failed", status: args.p_response_status, body: args.p_response_body, failureKind: args.p_failure_kind, token: null });
        return { data: { failed: true, record_id: record.id, failure_kind: args.p_failure_kind }, error: null };
      }
      throw new Error("Unexpected RPC: " + name);
    },
  };
  state.repository = createPaymentsRepository(admin);
  // Same composition as supabase/functions/payments-api-v1/index.ts (no rate limiter).
  state.api = rateLimiter === undefined
    ? createPaymentsApi({ repository: state.repository, allowlist: [] })
    : createPaymentsApi({ repository: state.repository, rateLimiter, allowlist: [] });
  state.request = ({ tenant = 0, key = "customer-key", body = { name: "Customer", external_reference: "external-1" }, headers = {}, query = "" } = {}) => {
    const requestHeaders = { authorization: "Bearer " + identities[tenant].built.secret, "content-type": "application/json", "x-request-id": "request-current", ...headers };
    if (key !== null) requestHeaders["idempotency-key"] = key;
    return new Request("https://payments.test/v1/customers" + query, { method: "POST", headers: requestHeaders, body: typeof body === "string" ? body : JSON.stringify(body) });
  };
  return state;
}
const MUTATION_RPCS = ["payment_api_begin_idempotency", "payment_api_create_customer_atomic", "payment_api_fail_idempotency"];
const mutationCalls = state => state.calls.filter(x => MUTATION_RPCS.includes(x.name));
const atomicCalls = state => state.calls.filter(x => x.name === "payment_api_create_customer_atomic");
const failCalls = state => state.calls.filter(x => x.name === "payment_api_fail_idempotency");

test("production composition without rate limiter reaches the Customer handler and returns 201", async () => {
  const s = await fixture();
  const response = await s.api(s.request());
  assert.equal(response.status, 201);
  const body = await response.json();
  assert.equal(body.data.external_reference, "external-1");
  assert.equal(s.customers.get(body.data.id).tenantId, s.identities[0].tenantId);
  assert.equal(body.request_id, response.headers.get("x-request-id"));
  assert.equal(atomicCalls(s).length, 1);
  const begin = mutationCalls(s)[0].args;
  assert.equal(begin.p_tenant_id, s.identities[0].tenantId);
  assert.equal(begin.p_application_id, s.identities[0].applicationId);
  assert.equal(begin.p_http_method, "POST");
  assert.equal(begin.p_operation, "POST /v1/customers");
});
test("Customer route never consults a rate limiter, even a denying one", async () => {
  let consulted = 0;
  const s = await fixture({ rateLimiter: { async consume() { consulted += 1; return { allowed: false, remaining: 0, retryAfterSeconds: 30 }; } } });
  assert.equal((await s.api(s.request())).status, 201);
  assert.equal(consulted, 0);
  assert.equal(atomicCalls(s).length, 1);
});
test("CORS preflight advertises POST for the Customer route", async () => {
  const s = await fixture();
  const response = await s.api(new Request("https://payments.test/v1/customers", { method: "OPTIONS" }));
  assert.equal(response.status, 204);
  assert.equal(response.headers.get("access-control-allow-methods"), "GET, POST, OPTIONS");
  assert.match(response.headers.get("access-control-allow-headers"), /idempotency-key/);
});

for (const authorization of ["", "Bearer invalid"]) test("missing/invalid M2M rejected: " + authorization, async () => {
  const s = await fixture();
  assert.equal((await s.api(s.request({ headers: { authorization } }))).status, 401);
  assert.equal(mutationCalls(s).length, 0);
});
for (const scenario of ["revoked", "expired", "inactive application", "inactive tenant"]) test("auth fails closed: " + scenario, async () => {
  const s = await fixture();
  if (scenario === "revoked") s.tables.payment_api_credentials[0].revoked_at = "2020-01-01T00:00:00Z";
  if (scenario === "expired") s.tables.payment_api_credentials[0].expires_at = "2020-01-01T00:00:00Z";
  if (scenario === "inactive application") s.tables.payment_api_applications[0].status = "inactive";
  if (scenario === "inactive tenant") s.tables.tenants[0].ativo = false;
  assert.equal((await s.api(s.request())).status, 401);
  assert.equal(mutationCalls(s).length, 0);
});
test("customers:write enforced before mutations", async () => {
  const s = await fixture({ scopes: ["invoices:read"] });
  assert.equal((await s.api(s.request())).status, 403);
  assert.equal(mutationCalls(s).length, 0);
});
for (const channel of ["body", "query", "x-tenant-id", "x-tenantid"]) test("tenant override rejected: " + channel, async () => {
  const s = await fixture(), target = s.identities[1].tenantId;
  const input = channel === "body" ? { body: { name: "Customer", external_reference: "ref", tenant_id: target } } : channel === "query" ? { query: "?tenant_id=" + target } : { headers: { [channel]: target } };
  assert.equal((await s.api(s.request(input))).status, 400);
  assert.equal(mutationCalls(s).length, 0);
});
for (const key of [null, "", "   ", "bad key", "bad,key", ".leading-dot", "a".repeat(129)]) test("invalid Idempotency-Key rejected before RPC: " + JSON.stringify(key).slice(0, 40), async () => {
  const s = await fixture();
  const response = await s.api(s.request({ key }));
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, "invalid_request");
  assert.equal(mutationCalls(s).length, 0);
});
for (const key of ["a", "a".repeat(128), "order-1_x:y.z"]) test("valid Idempotency-Key accepted: length " + key.length, async () => {
  const s = await fixture();
  assert.equal((await s.api(s.request({ key }))).status, 201);
  assert.equal(mutationCalls(s)[0].args.p_idempotency_key, key);
});
for (const body of ["{broken", '{"name":"a","name":"b"}', {}, { name: "", external_reference: "ref" }, { name: "a".repeat(161), external_reference: "ref" }, { name: "a", external_reference: "bad reference" }, { name: "a", external_reference: "ref", email: "a".repeat(321) }, { name: "a", external_reference: "ref", email: 5 }, { name: "a", external_reference: "ref", unexpected: true }]) test("invalid body rejected before RPC: " + JSON.stringify(body).slice(0,65), async () => {
  const s = await fixture();
  assert.equal((await s.api(s.request({ body }))).status, 400);
  assert.equal(mutationCalls(s).length, 0);
});
for (const [label, email, stored] of [["null", null, null], ["omitted", undefined, null], ["blank", "   ", null], ["trimmed", " a@b.test ", "a@b.test"]]) test("email accepted as nullable string: " + label, async () => {
  const s = await fixture();
  assert.equal((await s.api(s.request({ body: { name: "Customer", external_reference: "external-1", email } }))).status, 201);
  assert.equal(atomicCalls(s)[0].args.p_email, stored);
});
test("same key/body replays without a second Customer RPC, using current request id", async () => {
  const s = await fixture();
  const first = await s.api(s.request({ headers: { "x-request-id": "first" } }));
  assert.equal(first.status, 201);
  const response = await s.api(s.request());
  assert.equal(response.status, 201);
  const replay = await response.json();
  assert.deepEqual(replay.data, (await first.json()).data);
  assert.equal(replay.request_id, "request-current");
  assert.equal(atomicCalls(s).length, 1);
  assert.equal(s.customers.size, 1);
});
test("different payload with same key conflicts without another mutation", async () => {
  const s = await fixture();
  assert.equal((await s.api(s.request())).status, 201);
  const response = await s.api(s.request({ body: { name: "Other", external_reference: "external-1" } }));
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error.code, "conflict");
  assert.equal(atomicCalls(s).length, 1);
});

// Runs the cross-tenant scenario against ONE shared store; returns whether isolation held.
async function crossTenantIsolation(s) {
  const results = [];
  for (const tenant of [0, 1]) {
    const response = await s.api(s.request({ tenant }));
    results.push({ status: response.status, body: await response.json() });
  }
  const replays = [];
  for (const tenant of [0, 1]) {
    const response = await s.api(s.request({ tenant }));
    replays.push({ status: response.status, body: await response.json() });
  }
  return results.every(r => r.status === 201) && replays.every(r => r.status === 201)
    && results[0].body.data.id !== results[1].body.data.id
    && [0, 1].every(t => replays[t].body.data.id === results[t].body.data.id
      && s.customers.get(results[t].body.data.id)?.tenantId === s.identities[t].tenantId
      && s.customers.get(results[t].body.data.id)?.applicationId === s.identities[t].applicationId)
    && s.records.size === 2 && atomicCalls(s).length === 2;
}
test("same key/reference across tenants uses one store, independent records and results", async () => {
  const s = await fixture();
  assert.equal(await crossTenantIsolation(s), true);
});
test("negative control: the isolation check fails if tenant/application leave the namespace", async () => {
  const s = await fixture({ namespace: "method-operation-key-only" });
  assert.equal(await crossTenantIsolation(s), false);
  assert.equal(s.records.size, 1);
});
test("same tenant reference under a new key conflicts without duplicating Customer", async () => {
  const s = await fixture();
  assert.equal((await s.api(s.request())).status, 201);
  assert.equal((await s.api(s.request({ key: "new-key" }))).status, 409);
  assert.equal(s.customers.size, 1);
});
for (const [decision, status, code] of [["in_progress", 409, "conflict"], ["retry_later", 503, "provider_unavailable"]]) test("RPC decision " + decision + " preserves Retry-After and never mutates", async () => {
  const s = await fixture();
  s.beginOverride = { decision, record_id: randomUUID(), retry_after_seconds: 17 };
  const response = await s.api(s.request());
  assert.equal(response.status, status);
  assert.equal((await response.json()).error.code, code);
  assert.equal(response.headers.get("retry-after"), "17");
  assert.equal(atomicCalls(s).length, 0);
});
test("same-key request while another lease is live returns in_progress", async () => {
  const s = await fixture();
  // Another worker holds the lease: acquire it without completing, then send the HTTP request.
  const fingerprint = await fingerprintHttpRequest({ method: "POST", operation: "POST /v1/customers", body: { name: "Customer", external_reference: "external-1" } });
  const lease = await s.repository.beginIdempotency({ tenantId: s.identities[0].tenantId, applicationId: s.identities[0].applicationId, method: "POST", operation: "POST /v1/customers", key: "customer-key", fingerprint, requestId: "other", leaseSeconds: 60 });
  assert.equal(lease.decision, "acquired");
  const response = await s.api(s.request());
  assert.equal(response.status, 409);
  assert.equal(response.headers.get("retry-after"), "60");
  assert.equal(atomicCalls(s).length, 0);
});
for (const data of [null, {}, { data: { id: "old-mock", lease_token: "old-token" } }, { decision: "acquired", record_id: "id" }, { decision: "unknown" }, { decision: "replay", status: 201, body: {} }, { decision: "replay", status: 500, body: { error: { code: "internal_error", message: "x" } } }, { decision: "replay", status: 409, body: { error: { code: "rate_limited", message: "x" } } }, { decision: "retry_later", retry_after_seconds: -1 }]) test("malformed RPC payload fails closed: " + JSON.stringify(data).slice(0, 80), async () => {
  const s = await fixture();
  s.beginOverride = data;
  assert.equal((await s.api(s.request())).status, 500);
  assert.equal(atomicCalls(s).length, 0);
});
test("replay projects only public Customer fields", async () => {
  const s = await fixture();
  s.beginOverride = { decision: "replay", record_id: randomUUID(), status: 201, body: { data: { id: "x", external_reference: "e", created_at: "t", provider_customer_id: "PRIVATE_FIXTURE" }, request_id: "old" } };
  const text = await (await s.api(s.request())).text();
  assert.doesNotMatch(text, /PRIVATE_FIXTURE|"old"/);
});
for (const [message, status] of [["external_reference_conflict", 409], ["customer idempotency lease invalid", 409], ["application billing account unavailable", 400], ["invalid customer creation request", 400], ["unrelated conflict SQL secret fixture", 500]]) test("structured PostgREST error mapping: " + message, async () => {
  const s = await fixture();
  s.atomicError = { code: "P0001", message, details: "PRIVATE_FIXTURE_DETAIL", hint: "PRIVATE_FIXTURE_HINT" };
  const response = await s.api(s.request());
  assert.equal(response.status, status);
  assert.doesNotMatch(await response.text(), /PRIVATE_FIXTURE|SQL secret/);
});
test("invalid idempotency request raised by begin RPC maps to 400", async () => {
  const s = await fixture();
  s.repository.beginIdempotency = async () => { throw { code: "P0001", message: "invalid idempotency request", details: null, hint: null }; };
  const api = createPaymentsApi({ repository: s.repository, allowlist: [] });
  assert.equal((await api(s.request())).status, 400);
});
for (const [message, status, code] of [["external_reference_conflict", 409, "conflict"], ["application billing account unavailable", 400, "invalid_request"]]) test("deterministic failure is recorded and replayed without re-executing: " + message, async () => {
  const s = await fixture();
  s.atomicError = { code: "P0001", message, details: null, hint: null };
  const first = await s.api(s.request({ headers: { "x-request-id": "first" } }));
  assert.equal(first.status, status);
  assert.equal(failCalls(s).length, 1);
  const recorded = failCalls(s)[0].args;
  assert.equal(recorded.p_failure_kind, "deterministic");
  assert.equal(recorded.p_response_status, status);
  assert.equal(recorded.p_response_body.error.code, code);
  s.atomicError = null;
  const replay = await s.api(s.request());
  assert.equal(replay.status, status);
  const body = await replay.json();
  assert.equal(body.error.code, code);
  assert.equal(body.error.request_id, "request-current");
  assert.equal(atomicCalls(s).length, 1);
  assert.equal(s.customers.size, 0);
});
test("unexpected failure releases the lease as transient so the same key can retry", async () => {
  const s = await fixture();
  s.atomicError = { code: "XX000", message: "unexpected", details: null, hint: null };
  assert.equal((await s.api(s.request())).status, 500);
  assert.equal(failCalls(s)[0].args.p_failure_kind, "transient");
  assert.equal(failCalls(s)[0].args.p_retry_after_seconds, 0);
  s.atomicError = null;
  assert.equal((await s.api(s.request())).status, 201);
  assert.equal(atomicCalls(s).length, 2);
  assert.equal(s.customers.size, 1);
});
test("lost lease is not recorded as a failure", async () => {
  const s = await fixture();
  s.atomicError = { code: "P0001", message: "customer idempotency lease invalid", details: null, hint: null };
  assert.equal((await s.api(s.request())).status, 409);
  assert.equal(failCalls(s).length, 0);
});
test("failure-recording error does not change the mapped response", async () => {
  const s = await fixture();
  s.atomicError = { code: "P0001", message: "external_reference_conflict", details: null, hint: null };
  s.failError = { code: "P0001", message: "idempotency lease invalid", details: "PRIVATE_FIXTURE", hint: null };
  const response = await s.api(s.request());
  assert.equal(response.status, 409);
  assert.doesNotMatch(await response.text(), /PRIVATE_FIXTURE/);
});
