export const PaymentCapability = Object.freeze({
  PIX: "PIX",
  BOLETO: "BOLETO",
  CARD: "CARD",
  GOOGLE_PAY: "GOOGLE_PAY",
  RECURRING: "RECURRING",
  PIX_AUTOMATICO: "PIX_AUTOMATICO",
  SPLIT: "SPLIT",
  SUBACCOUNTS: "SUBACCOUNTS",
});

export const PaymentStatus = Object.freeze({
  CREATED: "created",
  PENDING: "pending",
  CONFIRMED: "confirmed",
  FAILED: "failed",
  REFUNDED: "refunded",
  CHARGEBACK: "chargeback",
});

export function assertProviderContract(provider) {
  const methods = [
    "createPixCharge", "createBoleto", "createCardPayment", "createSubscription",
    "cancelSubscription", "refundPayment", "getPayment", "getCharge", "reconcile",
    "validateWebhook", "processWebhook",
  ];
  for (const method of methods) {
    if (typeof provider?.[method] !== "function") throw new Error(`Provider incompleto: ${method}`);
  }
  if (!Array.isArray(provider.capabilities)) throw new Error("Provider sem capabilities");
  return provider;
}

export function centsToReais(cents) {
  const value = Number(cents);
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error("Valor em centavos inválido");
  return (value / 100).toFixed(2);
}

export function decimalReaisToCents(value) {
  const text = String(value ?? "").trim().replace(",", ".");
  if (!/^\d+(?:\.\d{1,2})?$/.test(text)) throw new Error("Valor decimal inválido");
  const [whole, fraction = ""] = text.split(".");
  const cents = Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
  if (!Number.isSafeInteger(cents) || cents <= 0) throw new Error("Valor decimal inválido");
  return cents;
}