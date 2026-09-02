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