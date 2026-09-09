const APPLICATION_STATUSES = new Set(["active", "suspended", "revoked"]);
const ENVIRONMENTS = new Set(["sandbox", "staging", "production"]);
const SCOPE_PATTERN = /^[a-z][a-z0-9_]*:[a-z][a-z0-9_]*$/;

export function normalizeApplication(input = {}) {
  const name = String(input.name || "").trim();
  const slug = String(input.slug || "").trim().toLowerCase();
  const environment = String(input.environment || "sandbox").trim().toLowerCase();
  const status = String(input.status || "active").trim().toLowerCase();
  if (!name || name.length > 160) throw new Error("Nome de application inválido");
  if (!/^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$/.test(slug)) throw new Error("Slug de application inválido");
  if (!ENVIRONMENTS.has(environment)) throw new Error("Ambiente de application inválido");
  if (!APPLICATION_STATUSES.has(status)) throw new Error("Status de application inválido");
  if (!input.tenantId) throw new Error("Tenant de application obrigatório");
  return Object.freeze({
    tenantId: String(input.tenantId),
    name,
    slug,
    environment,
    status,
  });
}

export function normalizeScopes(scopes = []) {
  if (!Array.isArray(scopes)) throw new Error("Scopes inválidos");
  const normalized = [...new Set(scopes.map((scope) => String(scope || "").trim().toLowerCase()))].filter(Boolean);
  if (normalized.some((scope) => !SCOPE_PATTERN.test(scope))) throw new Error("Scope inválido");
  return Object.freeze(normalized);
}

export function hasScope(scopes, requiredScope) {
  const required = String(requiredScope || "").trim().toLowerCase();
  return Boolean(required && (scopes instanceof Set ? scopes.has(required) : normalizeScopes(scopes).includes(required)));
}

export const PAYMENT_APPLICATION_STATUSES = Object.freeze([...APPLICATION_STATUSES]);
export const PAYMENT_APPLICATION_ENVIRONMENTS = Object.freeze([...ENVIRONMENTS]);
