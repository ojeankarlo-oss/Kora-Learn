export const PAYMENTS_API_ROUTES = Object.freeze({
  "/v1": Object.freeze({ GET: Object.freeze({ auth: false }) }),
  "/v1/health": Object.freeze({ GET: Object.freeze({ auth: false }) }),
});

export const PAYMENTS_API_METADATA = Object.freeze({
  name: "KORA Payments API",
  version: "v1",
  root: "/v1",
  runtime: "supabase-edge-function",
  financialOperations: false,
});

export const FUTURE_FINANCIAL_PATHS = Object.freeze([
  "/v1/customers",
  "/v1/invoices",
  "/v1/payment-intents",
  "/v1/payments",
  "/v1/refunds",
]);

export function routeEntries() {
  return Object.entries(PAYMENTS_API_ROUTES).flatMap(([path, methods]) =>
    Object.entries(methods).map(([method, definition]) => ({ path, method: method.toLowerCase(), definition })),
  );
}
