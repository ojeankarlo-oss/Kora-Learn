import { readFileSync } from "node:fs";
import { parse } from "yaml";
import { FUTURE_FINANCIAL_PATHS, PAYMENTS_API_ROUTES } from "../src/lib/payments/api-contract.js";

const specPath = new URL("../docs/openapi/kora-payments-v1.yaml", import.meta.url);
const spec = parse(readFileSync(specPath, "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(`OPENAPI CONTRACT: FAIL — ${message}`);
}

assert(spec && spec.openapi === "3.1.0", "openapi must be 3.1.0");
assert(spec.info?.version === "1.0.0", "metadata version missing");
assert(spec.components?.securitySchemes?.M2MBearer?.type === "http", "M2MBearer security scheme missing");
assert(spec.components?.parameters?.RequestId, "RequestId parameter missing");
assert(spec.components?.parameters?.IdempotencyKey, "Idempotency-Key parameter missing");
assert(spec.components?.schemas?.ErrorResponse, "ErrorResponse schema missing");
assert(spec.components?.schemas?.Money?.properties?.amount?.type === "integer", "Money amount must be integer");
assert(spec.components?.schemas?.Currency?.enum?.includes("BRL"), "BRL currency missing");

const specPaths = Object.keys(spec.paths || {});
for (const forbidden of FUTURE_FINANCIAL_PATHS) {
  assert(!specPaths.includes(forbidden), `financial path must not be implemented: ${forbidden}`);
}

for (const [path, methods] of Object.entries(PAYMENTS_API_ROUTES)) {
  assert(spec.paths?.[path], `missing path ${path}`);
  for (const [method, definition] of Object.entries(methods)) {
    const operation = spec.paths[path][method.toLowerCase()];
    assert(operation, `missing operation ${method} ${path}`);
    if (definition.auth === false) assert(Array.isArray(operation.security) && operation.security.length === 0, `public security drift ${method} ${path}`);
  }
}

for (const path of specPaths) {
  assert(Object.hasOwn(PAYMENTS_API_ROUTES, path), `spec path has no implementation: ${path}`);
  const allowedMethods = new Set(Object.keys(PAYMENTS_API_ROUTES[path]).map((method) => method.toLowerCase()));
  for (const method of Object.keys(spec.paths[path])) {
    assert(allowedMethods.has(method), `spec method has no implementation: ${method.toUpperCase()} ${path}`);
  }
}

console.log(`OPENAPI CONTRACT: PASS (${specPaths.length} paths, ${Object.values(PAYMENTS_API_ROUTES).reduce((total, methods) => total + Object.keys(methods).length, 0)} runtime operations)`);
