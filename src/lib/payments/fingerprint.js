const encoder = new TextEncoder();

function canonicalValue(value) {
  if (value === null) return "null";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("Fingerprint value must be finite");
    return JSON.stringify(value);
  }
  if (typeof value === "bigint" || typeof value === "function" || typeof value === "symbol" || value === undefined) {
    throw new TypeError("Fingerprint value is not JSON-compatible");
  }
  if (Array.isArray(value)) return `[${value.map(canonicalValue).join(",")}]`;
  if (typeof value === "object") {
    const keys = Object.keys(value).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalValue(value[key])}`).join(",")}}`;
  }
  throw new TypeError("Fingerprint value is not JSON-compatible");
}

export function canonicalizeJson(value) {
  return canonicalValue(value);
}

export async function sha256Hex(value) {
  const digest = await globalThis.crypto.subtle.digest("SHA-256", encoder.encode(String(value)));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function fingerprintJson(value) {
  return sha256Hex(canonicalizeJson(value));
}

export async function fingerprintHttpRequest({ method, operation, body }) {
  return fingerprintJson({
    method: String(method || "").toUpperCase(),
    operation: String(operation || ""),
    body,
  });
}

export const FINGERPRINT_ALGORITHM = "SHA-256 over deterministic sorted-key JSON";
