import { hashCredential, isCredentialActive } from "./credential.js";

const PUBLIC_CREDENTIAL_PATTERN = /^kp_[a-z]+_[A-Za-z0-9_-]{32,}$/;

function requestIdFrom(input) {
  const supplied = input?.headers?.get?.("x-request-id") || input?.requestId || "";
  return String(supplied || globalThis.crypto.randomUUID()).trim().slice(0, 128);
}

function credentialFrom(input) {
  if (typeof input === "string") return input.trim();
  const authorization = input?.headers?.get?.("authorization") || input?.authorization || "";
  const match = /^Bearer\s+(.+)$/i.exec(String(authorization).trim());
  return match ? match[1].trim() : "";
}

function fail(code, status, requestId, reason = code) {
  return { ok: false, status, code, requestId, reason };
}

function activeAt(record, now) {
  return isCredentialActive({
    status: record.status,
    revokedAt: record.revoked_at ?? record.revokedAt,
    expiresAt: record.expires_at ?? record.expiresAt,
  }, now);
}

function scopesFromRows(rows) {
  return new Set((rows || []).map((row) => String(row.scope_code ?? row.code ?? row).trim()).filter(Boolean));
}

export async function authenticatePaymentCredential({ credential, request, repository, now = new Date() } = {}) {
  const requestId = requestIdFrom(request);
  const secret = credentialFrom(credential ?? request);
  if (!PUBLIC_CREDENTIAL_PATTERN.test(secret)) {
    await repository.auditAuthAttempt?.({ credentialId: null, applicationId: null, tenantId: null, requestId, success: false, reason: "invalid_format" });
    return fail("invalid_credential", 401, requestId, "invalid_format");
  }

  const credentialHash = await hashCredential(secret);
  const record = await repository.findCredentialByHash(credentialHash);
  if (!record) {
    await repository.auditAuthAttempt?.({ credentialId: null, applicationId: null, tenantId: null, requestId, success: false, reason: "not_found" });
    return fail("invalid_credential", 401, requestId, "not_found");
  }
  if (!activeAt(record, now)) {
    await repository.auditAuthAttempt?.({
      credentialId: record.id,
      applicationId: record.application_id,
      tenantId: record.tenant_id,
      requestId,
      success: false,
      reason: record.revoked_at ? "revoked" : "expired_or_inactive",
    });
    return fail("invalid_credential", 401, requestId, "inactive");
  }

  const application = await repository.findApplication(record.application_id, record.tenant_id);
  if (!application || application.tenant_id !== record.tenant_id) {
    await repository.auditAuthAttempt?.({
      credentialId: record.id,
      applicationId: record.application_id,
      tenantId: record.tenant_id,
      requestId,
      success: false,
      reason: "application_not_found",
    });
    return fail("invalid_credential", 401, requestId, "application_not_found");
  }
  if (application.status !== "active") {
    await repository.auditAuthAttempt?.({
      credentialId: record.id,
      applicationId: application.id,
      tenantId: application.tenant_id,
      requestId,
      success: false,
      reason: "application_inactive",
    });
    return fail("application_inactive", 403, requestId, "application_inactive");
  }
  const tenant = await repository.findTenant(record.tenant_id);
  if (!tenant || tenant.ativo !== true) {
    await repository.auditAuthAttempt?.({
      credentialId: record.id,
      applicationId: application.id,
      tenantId: application.tenant_id,
      requestId,
      success: false,
      reason: "tenant_inactive",
    });
    return fail("tenant_inactive", 403, requestId, "tenant_inactive");
  }

  const scopes = scopesFromRows(await repository.listCredentialScopes(record.id, record.tenant_id));
  await repository.touchCredential?.({ credentialId: record.id, requestId });
  return {
    ok: true,
    context: Object.freeze({
      applicationId: application.id,
      tenantId: application.tenant_id,
      credentialId: record.id,
      environment: record.environment,
      scopes,
      requestId,
    }),
  };
}

export function requirePaymentScope(authResult, requiredScope) {
  if (!authResult?.ok) return authResult;
  const scope = String(requiredScope || "").trim();
  if (!scope || !authResult.context?.scopes?.has?.(scope)) {
    return { ok: false, status: 403, code: "insufficient_scope", requestId: authResult.context?.requestId || "", reason: scope || "missing_scope" };
  }
  return { ok: true, context: authResult.context };
}

export function rejectCallerTenantOverride(input) {
  if (!input || typeof input !== "object") return { ok: true };
  if (Object.prototype.hasOwnProperty.call(input, "tenant_id") || Object.prototype.hasOwnProperty.call(input, "tenantId")) {
    return { ok: false, status: 400, code: "tenant_id_not_accepted", reason: "credential_authority_only" };
  }
  return { ok: true };
}

export { credentialFrom, requestIdFrom };
