import test from "node:test";
import assert from "node:assert/strict";
import { createAsaasProvider } from "../../src/lib/billing/asaas.js";
import { createBillingOrchestrator } from "../../src/lib/billing/orchestrator.js";

function response(body, ok = true, status = 200) {
  return { ok, status, text: async () => JSON.stringify(body) };
}

test("Asaas Pix sandbox retorna QR e referencia a invoice KORA", async () => {
  const requests = [];
  const provider = createAsaasProvider({ apiKey: "sandbox-key", webhookSecret: "secret", fetchImpl: async (url, init) => {
    requests.push({ url, init });
    return response(url.endsWith("pixQrCode") ? { payload: "pix-copy-paste", encodedImage: "qr" } : { id: "asaas-pay-1", status: "PENDING" });
  } });
  const result = await provider.createPixCharge({ providerCustomerId: "cus-1", invoiceId: "invoice-1", amountCents: 1234, dueDate: "2026-09-10", description: "Mensalidade" });
  assert.equal(result.copyPaste, "pix-copy-paste");
  assert.match(requests[0].url, /sandbox\.asaas\.com/);
  assert.equal(JSON.parse(requests[0].init.body).externalReference, "invoice-1");
});

test("webhook duplicado tem um único efeito e tenant incorreto não encontra invoice", async () => {
  const calls = { paid: 0, events: 0 };
  const invoice = { id: "invoice-1", tenantId: "tenant-a", amountCents: 1000, status: "open" };
  const repository = {
    getInvoiceForTenant: async (id, tenantId) => id === invoice.id && tenantId === invoice.tenantId ? invoice : null,
    createPaymentIntent: async () => ({ id: "intent-1" }),
    createPaymentAttempt: async () => ({ id: "attempt-1" }),
    attachProviderPayment: async (_, value) => value,
    transaction: async (callback) => callback({
      recordWebhookEvent: async () => ({ inserted: calls.events++ === 0 }),
      getInvoice: async () => invoice,
      confirmPayment: async () => { calls.paid += 1; },
      markInvoicePaid: async () => { calls.paid += 1; },
    }),
  };
  const provider = createAsaasProvider({ apiKey: "key", webhookSecret: "secret" });
  const billing = createBillingOrchestrator({ repository, provider });
  await assert.rejects(() => billing.processWebhook({ headers: new Headers(), payload: {} }), /nao autorizado/);
  const input = { headers: new Headers({ "asaas-access-token": "secret" }), payload: { event: "PAYMENT_RECEIVED", payment: { id: "pay-1", externalReference: "invoice-1", value: 10 } } };
  await billing.processWebhook(input);
  assert.deepEqual(await billing.processWebhook(input), { duplicate: true });
  assert.equal(calls.paid, 2);
  await assert.rejects(() => billing.createPixPayment({ tenantId: "tenant-b", invoiceId: "invoice-1", providerCustomerId: "cus" }), /Invoice nao encontrada/);
});

test("valor divergente não confirma pagamento", async () => {
  const provider = createAsaasProvider({ apiKey: "key", webhookSecret: "secret" });
  const repository = {
    transaction: async (callback) => callback({
      recordWebhookEvent: async () => ({ inserted: true }),
      getInvoice: async () => ({ id: "invoice-1", amountCents: 999, status: "open" }),
      confirmPayment: async () => assert.fail("não deve confirmar"),
      markInvoicePaid: async () => assert.fail("não deve baixar"),
    }),
  };
  const billing = createBillingOrchestrator({ repository, provider });
  await assert.rejects(() => billing.processWebhook({ headers: new Headers({ "asaas-access-token": "secret" }), payload: { event: "PAYMENT_RECEIVED", payment: { id: "pay-1", externalReference: "invoice-1", value: 10 } } }), /nao corresponde/);
});

test("credencial ausente, payload malformado e provider indisponível falham fechado", async () => {
  assert.throws(() => createAsaasProvider({}), /ASAAS_API_KEY/);
  const provider = createAsaasProvider({ apiKey: "key", webhookSecret: "secret", fetchImpl: async () => response({}, false, 503) });
  await assert.rejects(() => provider.createPixCharge({ providerCustomerId: "cus", invoiceId: "inv", amountCents: 100, dueDate: "2026-09-10", description: "Teste" }), /Asaas 503/);
  await assert.rejects(() => provider.processWebhook({ event: "PAYMENT_RECEIVED", payment: {} }), /Webhook Asaas invalido/);
});

test("invoice já paga não gera segundo efeito financeiro", async () => {
  let confirmations = 0;
  const provider = createAsaasProvider({ apiKey: "key", webhookSecret: "secret" });
  const billing = createBillingOrchestrator({ provider, repository: {
    transaction: async (callback) => callback({
      recordWebhookEvent: async () => ({ inserted: true }),
      getInvoice: async () => ({ id: "invoice-1", amountCents: 1000, status: "paid" }),
      confirmPayment: async () => { confirmations += 1; },
      markInvoicePaid: async () => { confirmations += 1; },
    }),
  } });
  const result = await billing.processWebhook({ headers: new Headers({ "asaas-access-token": "secret" }), payload: { event: "PAYMENT_RECEIVED", payment: { id: "pay-1", externalReference: "invoice-1", value: 10 } } });
  assert.deepEqual(result, { duplicate: false, alreadyPaid: true });
  assert.equal(confirmations, 0);
});

test("duas chamadas simultâneas do mesmo evento têm um único efeito", async () => {
  let claimed = false;
  let paid = 0;
  const provider = createAsaasProvider({ apiKey: "key", webhookSecret: "secret" });
  const repository = {
    transaction: async (callback) => callback({
      recordWebhookEvent: async () => {
        if (claimed) return { inserted: false };
        claimed = true;
        await new Promise((resolve) => setImmediate(resolve));
        return { inserted: true };
      },
      getInvoice: async () => ({ id: "invoice-1", amountCents: 1000, status: "open" }),
      confirmPayment: async () => { paid += 1; },
      markInvoicePaid: async () => { paid += 1; },
    }),
  };
  const billing = createBillingOrchestrator({ repository, provider });
  const input = { headers: new Headers({ "asaas-access-token": "secret" }), payload: { event: "PAYMENT_RECEIVED", payment: { id: "pay-1", externalReference: "invoice-1", value: "10.00" } } };
  const results = await Promise.all([billing.processWebhook(input), billing.processWebhook(input)]);
  assert.equal(results.filter((result) => result.duplicate).length, 1);
  assert.equal(paid, 2);
});

test("falha intermediária permite retry porque a transação não confirma o evento", async () => {
  let eventInserted = false;
  let fail = true;
  const provider = createAsaasProvider({ apiKey: "key", webhookSecret: "secret" });
  const repository = {
    transaction: async (callback) => {
      const tx = {
        recordWebhookEvent: async () => { eventInserted = true; return { inserted: true }; },
        getInvoice: async () => ({ id: "invoice-1", amountCents: 1000, status: "open" }),
        confirmPayment: async () => { if (fail) { eventInserted = false; throw new Error("transient"); } },
        markInvoicePaid: async () => {},
      };
      return callback(tx);
    },
  };
  const billing = createBillingOrchestrator({ repository, provider });
  const input = { headers: new Headers({ "asaas-access-token": "secret" }), payload: { event: "PAYMENT_RECEIVED", payment: { id: "pay-1", externalReference: "invoice-1", value: 10 } } };
  await assert.rejects(() => billing.processWebhook(input), /transient/);
  assert.equal(eventInserted, false);
  fail = false;
  await billing.processWebhook(input);
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
  const provider = createAsaasProvider({ apiKey: "key", webhookSecret: "secret", fetchImpl: async (url) => response(url.endsWith("pixQrCode") ? { payload: "pix" } : { id: "pay-1", status: "PENDING" }) });
  const billing = createBillingOrchestrator({ provider, repository: {
    getInvoiceForTenant: async () => ({ id: "invoice-1", tenantId: "tenant-a", amountCents: 1, status: "open" }),
    createPaymentIntent: async () => ({ id: "intent-1" }),
    createPaymentAttempt: async (attempt) => { attempts.push(attempt); return attempt; },
    attachProviderPayment: async (_, value) => value,
  } });
  await billing.createPixPayment({ tenantId: "tenant-a", invoiceId: "invoice-1", providerCustomerId: "cus" });
  assert.deepEqual(attempts[0], { paymentIntentId: "intent-1", tenantId: "tenant-a", provider: "asaas", providerPaymentId: "pay-1", status: "pending" });
});

test("valores monetários são convertidos por centavos exatos", async () => {
  const { decimalReaisToCents } = await import("../../src/lib/billing/provider.js");
  assert.equal(decimalReaisToCents("0.01"), 1);
  assert.equal(decimalReaisToCents("19.99"), 1999);
  assert.equal(decimalReaisToCents("200,00"), 20000);
  assert.throws(() => decimalReaisToCents("19.999"), /inválido/);
  assert.throws(() => decimalReaisToCents("-0.01"), /inválido/);
});