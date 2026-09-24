import { assertValidRouteRegistry, runPaymentsPipeline } from "./http.js";
import { PAYMENTS_API_METADATA, PAYMENTS_API_ROUTES } from "./api-contract.js";
import { createCustomerHandler } from "./customer-handler.js";

/**
 * Shared production composition, also exercised by HTTP tests.
 * @param {{repository: ReturnType<typeof import("./supabase-repository.js").createPaymentsRepository>, rateLimiter?: import("./http.js").PipelineOptions["rateLimiter"], allowlist?: string[]}} options
 */
export function createPaymentsApi({ repository, rateLimiter = null, allowlist = [] }) {
  const routes = assertValidRouteRegistry(PAYMENTS_API_ROUTES);
  const handlers = {
    "/v1": { GET: () => ({ name: PAYMENTS_API_METADATA.name, version: PAYMENTS_API_METADATA.version, status: "foundation" }) },
    "/v1/health": { GET: () => ({ ok: true, version: PAYMENTS_API_METADATA.version }) },
    "/v1/customers": { POST: createCustomerHandler(repository, allowlist) },
  };
  /** @param {Request} req */
  return (req) => runPaymentsPipeline(req, { routes, handlers, repository, rateLimiter, allowlist });
}
