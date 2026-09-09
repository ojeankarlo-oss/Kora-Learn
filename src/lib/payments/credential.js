const ENVIRONMENTS = new Set(["sandbox", "staging", "production"]);

function requireEnvironment(environment) {
  const value = String(environment || "").trim().toLowerCase();
  if (!ENVIRONMENTS.has(value)) throw new Error("Ambiente de credential inválido");
  return value;
}

function bytesToBase64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function bytesToHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function randomBytes(length) {
  const bytes = new Uint8Array(length);
  globalThis.crypto.getRandomValues(bytes);
  return bytes;
}

function constantTimeEqual(left, right) {
  const leftBytes = new TextEncoder().encode(String(left));
  const rightBytes = new TextEncoder().encode(String(right));
  const length = Math.max(leftBytes.length, rightBytes.length);
  let difference = leftBytes.length ^ rightBytes.length;
  for (let index = 0; index < length; index += 1) {
    difference |= (leftBytes[index] || 0) ^ (rightBytes[index] || 0);
  }
  return difference === 0;
}

export function credentialPrefix(secret) {
  const value = String(secret || "");
  const match = /^kp_([a-z]+)_([a-f0-9]{16})_([A-Za-z0-9_-]{32,})$/.exec(value);
  if (!match) throw new Error("Credential inválida");
  return `kp_${match[1]}_${match[2]}`;
}

export async function hashCredential(secret) {
  const value = String(secret || "");
  if (!/^kp_[a-z]+_[a-f0-9]{16}_[A-Za-z0-9_-]{32,}$/.test(value)) throw new Error("Credential inválida");
  const digest = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function verifyCredential(secret, expectedHash) {
  try {
    const actualHash = await hashCredential(secret);
    return constantTimeEqual(actualHash, expectedHash);
  } catch {
    return false;
  }
}

export function generateCredential({ environment = "sandbox", randomBytesImpl = randomBytes } = {}) {
  const mode = requireEnvironment(environment);
  const publicIdentifier = bytesToHex(randomBytesImpl(8));
  const secretSuffix = bytesToBase64Url(randomBytesImpl(32));
  const secret = `kp_${mode}_${publicIdentifier}_${secretSuffix}`;
  const publicPrefix = `kp_${mode}_${publicIdentifier}`;
  return { secret, publicPrefix, publicIdentifier, environment: mode };
}

export async function buildCredentialRecord({ applicationId, tenantId, environment = "sandbox", rotatedFromId = null, now = new Date(), randomBytesImpl } = {}) {
  if (!applicationId || !tenantId) throw new Error("Application e tenant são obrigatórios");
  const generated = generateCredential({ environment, randomBytesImpl });
  return {
    ...generated,
    applicationId,
    tenantId,
    credentialHash: await hashCredential(generated.secret),
    status: "active",
    createdAt: new Date(now).toISOString(),
    expiresAt: null,
    revokedAt: null,
    rotatedFromId,
    rotatedAt: rotatedFromId ? new Date(now).toISOString() : null,
    credentialProvenance: "server_csprng_v1",
  };
}

export function isCredentialActive(record, now = new Date()) {
  if (!record || record.credentialProvenance !== "server_csprng_v1") return false;
  if (record.status !== "active" || record.revokedAt) return false;
  if (record.expiresAt && new Date(record.expiresAt).getTime() <= new Date(now).getTime()) return false;
  return true;
}

export function revokeCredentialRecord(record, now = new Date()) {
  if (!record?.id) throw new Error("Credential ausente para revogação");
  return {
    ...record,
    status: "revoked",
    revokedAt: new Date(now).toISOString(),
  };
}

export async function rotateCredentialRecord({ current, now = new Date(), randomBytesImpl } = {}) {
  if (!current?.id || current.status !== "active" || current.revokedAt) {
    throw new Error("Credential não está ativa para rotação");
  }
  const previous = revokeCredentialRecord(current, now);
  const next = await buildCredentialRecord({
    applicationId: current.applicationId ?? current.application_id,
    tenantId: current.tenantId ?? current.tenant_id,
    environment: current.environment,
    rotatedFromId: current.id,
    now,
    randomBytesImpl,
  });
  return { previous, next };
}

export const PAYMENT_API_ENVIRONMENTS = Object.freeze([...ENVIRONMENTS]);
export { constantTimeEqual };
