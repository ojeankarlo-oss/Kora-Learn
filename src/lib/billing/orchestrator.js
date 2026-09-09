import { assertProviderContract, PaymentStatus } from "./provider.js";

export function createBillingOrchestrator({ repository, provider }) {
  assertProviderContract(provider);
  if (!repository) throw new Error("Billing repository obrigatorio");

  return {
    async createPixPayment({ tenantId, invoiceId, providerCustomerId, idempotencyKey }) {
      const invoice = await repository.getInvoiceForTenant(invoiceId, tenantId);
      if (!invoice) throw new Error("Invoice nao encontrada");
      if (invoice.tenantId !== tenantId) throw new Error("Invoice fora do tenant");
      if (invoice.status !== "open") throw new Error("Invoice nao esta aberta");
      if (!String(idempotencyKey || "").trim()) throw new Error("Chave de idempotencia obrigatoria");
      const intent = await repository.getOrCreatePaymentIntent({
        tenantId, invoiceId, provider: provider.name, status: PaymentStatus.CREATED, idempotencyKey: String(idempotencyKey).trim(),
      });
      const charge = await provider.createPixCharge({ providerCustomerId, invoiceId, amountCents: invoice.amountCents, dueDate: invoice.dueDate, description: invoice.description });
      await repository.createPaymentAttempt({ paymentIntentId: intent.id, tenantId, provider: provider.name, providerPaymentId: charge.providerPaymentId, status: PaymentStatus.PENDING });
      return repository.attachProviderPayment(intent.id, { ...charge, status: PaymentStatus.PENDING });
    },
    async processWebhook({ headers, payload }) {
      if (!provider.validateWebhook(headers)) throw new Error("Webhook nao autorizado");
      const normalized = await provider.processWebhook(payload);
      return repository.transaction(async (tx) => {
        const event = await tx.recordWebhookEvent({ provider: provider.name, providerEventId: `${normalized.providerPaymentId}:${normalized.eventType}`, payload });
        if (!event.inserted) return { duplicate: true };
        const invoice = await tx.getInvoice(normalized.invoiceId);
        if (!invoice || normalized.amountCents !== invoice.amountCents) throw new Error("Webhook nao corresponde a invoice");
        if (invoice.status === "paid") return { duplicate: false, alreadyPaid: true };
        await tx.confirmPayment({ invoiceId: invoice.id, providerPaymentId: normalized.providerPaymentId, amountCents: normalized.amountCents });
        await tx.markInvoicePaid(invoice.id);
        return { duplicate: false, paid: true };
      });
    },
  };
}
