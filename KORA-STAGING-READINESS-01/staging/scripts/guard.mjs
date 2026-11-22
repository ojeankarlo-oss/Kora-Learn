// KORA-STAGING-READINESS-01 — guarda de alvo (fail-closed).
// Todo script de seed/teste importa assertSafeTarget() antes de qualquer chamada.
// Regras:
//  1. Modo padrão "local": a API e o banco PRECISAM ser 127.0.0.1/localhost.
//  2. Modo "remote-staging" exige KORA_STG_ALLOW_REMOTE=1 E host idêntico a
//     KORA_STG_REMOTE_HOST (projeto descartável aprovado por humano).
//  3. Qualquer referência ao projeto de produção conhecido aborta, em qualquer modo.
//  4. Nenhum valor de credencial é impresso.

// Ref do projeto hospedado usado pelo deploy de produção (.github/workflows/deploy.yml).
export const PRODUCTION_REFS = ["goxaeupwxhbiobvvwnxj"];
const LOCAL_HOSTS = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);

export class UnsafeTargetError extends Error {}

function hostOf(value, label) {
  try {
    return new URL(value).hostname.toLowerCase();
  } catch {
    throw new UnsafeTargetError(`KORA-STG GUARD: ${label} não é uma URL válida`);
  }
}

export function assertSafeTarget({ apiUrl, dbUrl } = {}, env = process.env) {
  const candidates = [
    ["KORA_STG_API_URL", apiUrl ?? env.KORA_STG_API_URL],
    ["KORA_STG_DB_URL", dbUrl ?? env.KORA_STG_DB_URL],
  ].filter(([, v]) => v);
  if (!candidates.length) throw new UnsafeTargetError("KORA-STG GUARD: nenhum alvo definido (KORA_STG_API_URL)");

  // Regra 3: varre também variáveis de ambiente conhecidas do Vite/Supabase.
  const scanned = [...candidates, ["VITE_SUPABASE_URL", env.VITE_SUPABASE_URL], ["SUPABASE_URL", env.SUPABASE_URL]];
  for (const [label, value] of scanned) {
    if (value && PRODUCTION_REFS.some((ref) => String(value).toLowerCase().includes(ref))) {
      throw new UnsafeTargetError(`KORA-STG GUARD: ${label} aponta para o projeto de PRODUÇÃO; abortado`);
    }
  }

  const mode = env.KORA_STG_MODE || "local";
  for (const [label, value] of candidates) {
    const host = hostOf(value, label);
    if (mode === "local") {
      if (!LOCAL_HOSTS.has(host)) {
        throw new UnsafeTargetError(`KORA-STG GUARD: ${label} host não-local em modo local; abortado`);
      }
    } else if (mode === "remote-staging") {
      if (env.KORA_STG_ALLOW_REMOTE !== "1") {
        throw new UnsafeTargetError("KORA-STG GUARD: modo remote-staging exige KORA_STG_ALLOW_REMOTE=1 (autorização humana)");
      }
      const allowedVar = label === "KORA_STG_DB_URL" ? "KORA_STG_REMOTE_DB_HOST" : "KORA_STG_REMOTE_HOST";
      const allowed = String(env[allowedVar] || "").toLowerCase();
      if (!allowed || host !== allowed) {
        throw new UnsafeTargetError(`KORA-STG GUARD: ${label} host fora da allowlist ${allowedVar}; abortado`);
      }
    } else {
      throw new UnsafeTargetError(`KORA-STG GUARD: KORA_STG_MODE desconhecido`);
    }
  }
  return { mode };
}

// Uso via CLI: `node guard.mjs` (sai 1 se inseguro). Usado pelos scripts .sh.
if (process.argv[1] && /[\\/]guard\.mjs$/.test(process.argv[1])) {
  try {
    const { mode } = assertSafeTarget();
    console.log(`KORA-STG GUARD: OK (modo=${mode})`);
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
}
