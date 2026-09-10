export const MAX_MONEY_MINOR_UNITS = 2147483647;
const CURRENCIES = new Set(["BRL"]);

export function parseMoney(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, code: "invalid_request", message: "Money must be an object" };
  }
  if (!Number.isSafeInteger(value.amount) || value.amount < 1 || value.amount > MAX_MONEY_MINOR_UNITS) {
    return { ok: false, code: "invalid_request", message: "Money amount must be a safe integer in minor units" };
  }
  if (typeof value.currency !== "string" || !CURRENCIES.has(value.currency)) {
    return { ok: false, code: "invalid_request", message: "Unsupported currency" };
  }
  return { ok: true, value: { amount: value.amount, currency: value.currency } };
}

export function rejectFloatMoney(value) {
  if (value && typeof value === "object" && Object.hasOwn(value, "amount") && (
    !Number.isSafeInteger(value.amount) || value.amount > MAX_MONEY_MINOR_UNITS
  )) {
    return { ok: false, code: "invalid_request", message: "Money amount must use bounded integer minor units" };
  }
  return { ok: true };
}

export const MONEY_SCHEMA = Object.freeze({
  type: "object",
  additionalProperties: false,
  required: ["amount", "currency"],
  properties: {
    amount: { type: "integer", minimum: 1, maximum: MAX_MONEY_MINOR_UNITS, description: "Positive integer minor units; bounded by PostgreSQL integer persistence." },
    currency: { type: "string", enum: ["BRL"] },
  },
});

export const CURRENCY_SCHEMA = Object.freeze({ type: "string", enum: ["BRL"] });
