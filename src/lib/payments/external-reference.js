export const EXTERNAL_REFERENCE_MAX_LENGTH = 160;
export const EXTERNAL_REFERENCE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$/;
export const EXTERNAL_REFERENCE_RESOURCE_TYPES = Object.freeze(["customer", "invoice", "subscription", "order", "enrollment"]);

export function normalizeExternalReference(value) {
  const reference = String(value ?? "").trim();
  if (!EXTERNAL_REFERENCE_PATTERN.test(reference)) {
    return { ok: false, code: "invalid_request", message: "Invalid external reference" };
  }
  return { ok: true, value: reference };
}

export function normalizeResourceType(value) {
  const resourceType = String(value ?? "").trim().toLowerCase();
  if (!EXTERNAL_REFERENCE_RESOURCE_TYPES.includes(resourceType)) {
    return { ok: false, code: "invalid_request", message: "Invalid external resource type" };
  }
  return { ok: true, value: resourceType };
}

export function buildExternalReferenceScope({ tenantId, applicationId, resourceType, externalReference }) {
  const type = normalizeResourceType(resourceType);
  const reference = normalizeExternalReference(externalReference);
  if (!tenantId || !applicationId || !type.ok || !reference.ok) {
    return { ok: false, code: "invalid_request", message: "Invalid external reference scope" };
  }
  return {
    ok: true,
    value: Object.freeze({
      tenantId: String(tenantId),
      applicationId: String(applicationId),
      resourceType: type.value,
      externalReference: reference.value,
    }),
  };
}
