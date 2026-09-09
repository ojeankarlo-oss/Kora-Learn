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
  };
}
