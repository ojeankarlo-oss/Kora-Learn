import { readFileSync } from "node:fs";
import { parse } from "yaml";
import { FUTURE_FINANCIAL_PATHS, PAYMENTS_API_ROUTES } from "../src/lib/payments/api-contract.js";

function assert(condition, message) {
  if (!condition) throw new Error(`OPENAPI CONTRACT: FAIL — ${message}`);
}

function operationParameters(operation) {
  return Array.isArray(operation?.parameters) ? operation.parameters : [];
}

function hasRequestIdParameter(operation) {
  return operationParameters(operation).some((parameter) =>
    parameter?.$ref === "#/components/parameters/RequestId" ||
    (parameter?.in === "header" && parameter?.name === "X-Request-Id"),
  );
}

function hasBearerSecurity(operation) {
  return Array.isArray(operation?.security) && operation.security.some((requirement) =>
    requirement && Object.hasOwn(requirement, "M2MBearer") && Array.isArray(requirement.M2MBearer),
  );
}

function resolveLocalRef(spec, value) {
  if (!value || typeof value !== "object" || typeof value.$ref !== "string" || !value.$ref.startsWith("#/")) return value;
  return value.$ref.slice(2).split("/").reduce((current, key) => current?.[key], spec);
}

function responseSchemaRef(spec, response) {
  const resolvedResponse = resolveLocalRef(spec, response);
  return resolvedResponse?.content?.["application/json"]?.schema?.$ref || null;
}

export function validatePaymentsOpenApi(spec, routes = PAYMENTS_API_ROUTES) {
  assert(spec && spec.openapi === "3.1.0", "openapi must be 3.1.0");
  assert(spec.info?.version === "1.0.0", "metadata version missing");
  assert(spec.components?.securitySchemes?.M2MBearer?.type === "http", "M2MBearer security scheme missing");
  assert(spec.components?.parameters?.RequestId, "RequestId parameter missing");
  assert(spec.components?.parameters?.IdempotencyKey, "Idempotency-Key parameter missing");
  assert(spec.components?.schemas?.ErrorResponse, "ErrorResponse schema missing");
  assert(spec.components?.schemas?.Money?.properties?.amount?.type === "integer", "Money amount must be integer");
  assert(spec.components?.schemas?.Money?.properties?.amount?.maximum === Number.MAX_SAFE_INTEGER, "Money amount maximum must equal Number.MAX_SAFE_INTEGER");
  assert(spec.components?.schemas?.Currency?.enum?.includes("BRL"), "BRL currency missing");

  const specPaths = Object.keys(spec.paths || {});
  for (const forbidden of FUTURE_FINANCIAL_PATHS) {
    assert(!specPaths.includes(forbidden), `financial path must not be implemented: ${forbidden}`);
  }

  for (const [path, methods] of Object.entries(routes)) {
    assert(spec.paths?.[path], `missing path ${path}`);
    for (const [method, definition] of Object.entries(methods)) {
      assert(definition?.access === "public" || definition?.access === "protected", `invalid runtime access ${method} ${path}`);
      const operation = spec.paths[path][method.toLowerCase()];
      assert(operation, `missing operation ${method} ${path}`);
      assert(hasRequestIdParameter(operation), `request-id parameter missing ${method} ${path}`);
      if (definition.access === "public") {
        assert(Array.isArray(operation.security) && operation.security.length === 0, `public security drift ${method} ${path}`);
      } else {
        assert(hasBearerSecurity(operation), `protected operation missing M2MBearer ${method} ${path}`);
        assert(!Array.isArray(operation.security) || operation.security.length > 0, `protected operation is public ${method} ${path}`);
      }
      for (const status of definition.responses) {
        assert(Object.hasOwn(operation.responses || {}, String(status)), `status ${status} missing ${method} ${path}`);
      }
      assert(responseSchemaRef(spec, operation.responses?.["200"]) === `#/components/schemas/${definition.responseSchema}`, `success schema drift ${method} ${path}`);
      for (const [status, response] of Object.entries(operation.responses || {})) {
        if (status.startsWith("4") || status.startsWith("5")) {
          assert(responseSchemaRef(spec, response) === "#/components/schemas/ErrorResponse", `error schema drift ${status} ${method} ${path}`);
        }
      }
    }
  }

  for (const path of specPaths) {
    assert(Object.hasOwn(routes, path), `spec path has no implementation: ${path}`);
    const allowedMethods = new Set(Object.keys(routes[path]).map((method) => method.toLowerCase()));
    for (const method of Object.keys(spec.paths[path])) {
      assert(allowedMethods.has(method), `spec method has no implementation: ${method.toUpperCase()} ${path}`);
    }
  }
  return { paths: specPaths.length };
}

const specPath = new URL("../docs/openapi/kora-payments-v1.yaml", import.meta.url);
const spec = parse(readFileSync(specPath, "utf8"));
const result = validatePaymentsOpenApi(spec);
console.log(`OPENAPI CONTRACT: PASS (${result.paths} paths, ${Object.values(PAYMENTS_API_ROUTES).reduce((total, methods) => total + Object.keys(methods).length, 0)} runtime operations)`);
