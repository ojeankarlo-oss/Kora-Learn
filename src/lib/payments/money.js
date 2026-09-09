const CURRENCIES = new Set(["BRL", "USD", "EUR"]);

export function parseMoney(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, code: "invalid_request", message: "Money must be an object" };
  }
  if (!Number.isSafeInteger(value.amount) || value.amount < 0) {
    return { ok: false, code: "invalid_request", message: "Money amount must be a non-negative integer in minor units" };
  }
  if (typeof value.currency !== "string" || !CURRENCIES.has(value.currency)) {
    return { ok: false, code: "invalid_request", message: "Unsupported currency" };
  }
  return { ok: true, value: { amount: value.amount, currency: value.currency } };
}

export function rejectFloatMoney(value) {
  if (value && typeof value === "object" && Object.hasOwn(value, "amount") && !Number.isSafeInteger(value.amount)) {
    return { ok: false, code: "invalid_request", message: "Money amount must use integer minor units" };
  }
  return { ok: true };
}

export const MONEY_SCHEMA = Object.freeze({
  type: "object",
  additionalProperties: false,
  required: ["amount", "currency"],
  properties: {
    amount: { type: "integer", minimum: 0, description: "Integer minor units; never a floating point amount." },
    currency: { type: "string", enum: ["BRL", "USD", "EUR"] },
  },
});

export const CURRENCY_SCHEMA = Object.freeze({ type: "string", enum: ["BRL", "USD", "EUR"] });
