import { PaymentCapability, centsToReais } from "./provider.js";

const BASE_URLS = Object.freeze({
  sandbox: "https://sandbox.asaas.com/api/v3",
  production: "https://api.asaas.com/api/v3",
});

function required(value, name) {
  if (!String(value || "").trim()) throw new Error(`Configuração ausente: ${name}`);
  return String(value).trim();
}

async function responseJson(response) {
  const text = await response.text();
  try { return text ? JSON.parse(text) : {}; } catch { return { raw: text }; }
}

export function createAsaasProvider({ apiKey, environment = "sandbox", fetchImpl = fetch } = {}) {
  const key = required(apiKey, "ASAAS_API_KEY");
  const mode = String(environment).toLowerCase() === "production" ? "production" : "sandbox";
  const baseUrl = BASE_URLS[mode];

  async function request(path, init = {}) {
    const response = await fetchImpl(`${baseUrl}${path}`, {
      ...init,
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        access_token: key,
        ...(init.headers || {}),
      },
    });
    const body = await responseJson(response);
    if (!response.ok) throw new Error(`Asaas ${response.status}: ${body?.errors?.[0]?.description || "requisicao recusada"}`);
    return body;
  }

  return {
    name: "asaas",
    environment: mode,
    capabilities: [PaymentCapability.PIX, PaymentCapability.BOLETO, PaymentCapability.CARD, PaymentCapability.RECURRING],
    async createPixCharge(input) {
      const charge = await request("/payments", {
        method: "POST",
        body: JSON.stringify({
          customer: required(input.providerCustomerId, "providerCustomerId"),
          billingType: "PIX",
          value: Number(centsToReais(input.amountCents)),
          dueDate: input.dueDate,
          description: input.description,
          externalReference: required(input.invoiceId, "invoiceId"),
        }),
      });
      const pix = await request(`/payments/${charge.id}/pixQrCode`);
      return { providerPaymentId: charge.id, status: charge.status, qrCode: pix.encodedImage, copyPaste: pix.payload, raw: charge };
    },
    async createBoleto() { throw new Error("Asaas boleto ainda nao implementado"); },
    async createCardPayment() { throw new Error("Asaas cartao ainda nao implementado"); },
    async createSubscription() { throw new Error("Asaas assinatura ainda nao implementada"); },
    async cancelSubscription() { throw new Error("Asaas assinatura ainda nao implementada"); },
    async refundPayment(input) { return request(`/payments/${required(input.providerPaymentId, "providerPaymentId")}/refund`, { method: "POST" }); },
    async getPayment(input) { return request(`/payments/${required(input.providerPaymentId, "providerPaymentId")}`); },
    async getCharge(input) { return this.getPayment(input); },
    async reconcile() { return { provider: "asaas", status: "not_implemented" }; },
  };
}
