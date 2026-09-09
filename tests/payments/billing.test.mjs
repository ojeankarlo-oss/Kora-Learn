import test from "node:test";
import assert from "node:assert/strict";
import { createAsaasProvider } from "../../src/lib/billing/asaas.js";
import { createBillingOrchestrator } from "../../src/lib/billing/orchestrator.js";

function response(body, ok = true, status = 200) {
  return { ok, status, text: async () => JSON.stringify(body) };
}

test("Asaas Pix sandbox retorna QR e referencia a invoice KORA", async () => {
  const requests = [];
  const provider = createAsaasProvider({ apiKey: "sandbox-key", fetchImpl: async (url, init) => {
    requests.push({ url, init });
    return response(url.endsWith("pixQrCode") ? { payload: "pix-copy-paste", encodedImage: "qr" } : { id: "asaas-pay-1", status: "PENDING" });
  } });
  const result = await provider.createPixCharge({ providerCustomerId: "cus-1", invoiceId: "invoice-1", amountCents: 1234, dueDate: "2026-09-10", description: "Mensalidade" });
  assert.equal(result.copyPaste, "pix-copy-paste");
  assert.match(requests[0].url, /sandbox\.asaas\.com/);
  assert.equal(JSON.parse(requests[0].init.body).externalReference, "invoice-1");
});

test("orchestrator não expõe caminho alternativo de settlement", async () => {
  const invoice = { id: "invoice-1", tenantId: "tenant-a", amountCents: 1000, status: "open" };
  const repository = {
    getInvoiceForTenant: async (id, tenantId) => id === invoice.id && tenantId === invoice.tenantId ? invoice : null,
  };
  const provider = createAsaasProvider({ apiKey: "key" });
  const billing = createBillingOrchestrator({ repository, provider });
  assert.equal("processWebhook" in billing, false);
  assert.equal("processWebhook" in provider, false);
  await assert.rejects(() => billing.createPixPayment({ tenantId: "tenant-b", invoiceId: "invoice-1", providerCustomerId: "cus", idempotencyKey: "request-1" }), /Invoice nao encontrada/);
});

test("credencial ausente e provider indisponível falham fechado", async () => {
  assert.throws(() => createAsaasProvider({}), /ASAAS_API_KEY/);
  const provider = createAsaasProvider({ apiKey: "key", fetchImpl: async () => response({}, false, 503) });
  await assert.rejects(() => provider.createPixCharge({ providerCustomerId: "cus", invoiceId: "inv", amountCents: 100, dueDate: "2026-09-10", description: "Teste" }), /Asaas 503/);
});

test("migration contém RPC, RLS, constraints de estado e nenhuma operação destrutiva", async () => {
  const { readFile } = await import("node:fs/promises");
  const sql = await readFile(new URL("../../supabase/migrations/027_kora_payments_billing_core.sql", import.meta.url), "utf8");
  assert.match(sql, /process_asaas_webhook_atomic/);
  assert.match(sql, /security definer/i);
  assert.match(sql, /set search_path = pg_catalog, public/i);
  assert.match(sql, /revoke all on function public\.process_asaas_webhook_atomic/i);
  assert.match(sql, /create policy webhook_events_service_role/i);
  assert.doesNotMatch(sql, /\b(delete|drop)\s+(from|table|index|function)/i);
});

test("criação de Pix persiste payment attempt com o ID externo", async () => {
  const attempts = [];
  const intents = [];
  const provider = createAsaasProvider({ apiKey: "key", fetchImpl: async (url) => response(url.endsWith("pixQrCode") ? { payload: "pix" } : { id: "pay-1", status: "PENDING" }) });
  const billing = createBillingOrchestrator({ provider, repository: {
    getInvoiceForTenant: async () => ({ id: "invoice-1", tenantId: "tenant-a", amountCents: 1, status: "open" }),
    getOrCreatePaymentIntent: async (intent) => { intents.push(intent); return { id: "intent-1" }; },
    createPaymentAttempt: async (attempt) => { attempts.push(attempt); return attempt; },
    attachProviderPayment: async (_, value) => value,
  } });
  await billing.createPixPayment({ tenantId: "tenant-a", invoiceId: "invoice-1", providerCustomerId: "cus", idempotencyKey: "request-1" });
  assert.deepEqual(intents[0], { tenantId: "tenant-a", invoiceId: "invoice-1", provider: "asaas", status: "created", idempotencyKey: "request-1" });
  assert.deepEqual(attempts[0], { paymentIntentId: "intent-1", tenantId: "tenant-a", provider: "asaas", providerPaymentId: "pay-1", status: "pending" });
});

test("Pix creation requires a persistent idempotency identity", async () => {
  const provider = createAsaasProvider({ apiKey: "key" });
  const billing = createBillingOrchestrator({ provider, repository: {
    getInvoiceForTenant: async () => ({ id: "invoice-1", tenantId: "tenant-a", amountCents: 100, status: "open" }),
  } });
  await assert.rejects(
    () => billing.createPixPayment({ tenantId: "tenant-a", invoiceId: "invoice-1", providerCustomerId: "cus" }),
    /Chave de idempotencia obrigatoria/,
  );
});

test("valores monetários são convertidos por centavos exatos", async () => {
  const { decimalReaisToCents } = await import("../../src/lib/billing/provider.js");
  assert.equal(decimalReaisToCents("0.01"), 1);
  assert.equal(decimalReaisToCents("19.99"), 1999);
  assert.equal(decimalReaisToCents("200,00"), 20000);
  assert.throws(() => decimalReaisToCents("19.999"), /inválido/);
  assert.throws(() => decimalReaisToCents("-0.01"), /inválido/);
});
