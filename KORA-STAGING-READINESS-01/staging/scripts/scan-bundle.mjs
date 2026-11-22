// KORA-STAGING-PROVISIONING-02 — varredura do bundle gerado (fail-closed).
// Prova que o build de homologação não embute nenhum alvo hospedado: falha se encontrar
// a ref de produção, qualquer host *.supabase.co/*.supabase.in, ou se NÃO encontrar a
// URL local esperada (KORA_STG_API_URL), o que indicaria build sem a variável correta.
// Uso: node scan-bundle.mjs <dir-dist>
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { PRODUCTION_REFS, assertSafeTarget } from "./guard.mjs";

assertSafeTarget();
const dist = process.argv[2];
if (!dist) { console.error("uso: scan-bundle.mjs <dir-dist>"); process.exit(2); }
const expected = process.env.KORA_STG_API_URL;

const walk = (d) => readdirSync(d).flatMap((n) => {
  const p = join(d, n);
  return statSync(p).isDirectory() ? walk(p) : [p];
});
const files = walk(dist).filter((f) => /\.(js|mjs|html|css|json|map)$/.test(f));
if (!files.length) { console.error("KORA-STG BUNDLE: nenhum arquivo no dist (NOT RUN)"); process.exit(1); }

let prod = 0, hosted = 0, local = 0;
for (const f of files) {
  const s = readFileSync(f, "utf8").toLowerCase();
  if (PRODUCTION_REFS.some((r) => s.includes(r))) prod += 1;
  if (/[a-z0-9-]+\.supabase\.(co|in)\b/.test(s)) hosted += 1;
  if (expected && s.includes(expected.toLowerCase())) local += 1;
}
console.log(`KORA-STG BUNDLE: arquivos=${files.length} prod_ref=${prod} hosted_supabase=${hosted} local_api=${local}`);
if (prod || hosted) { console.error("KORA-STG BUNDLE: FAIL (alvo hospedado embutido no build)"); process.exit(1); }
if (!local) { console.error("KORA-STG BUNDLE: FAIL (URL do stack local ausente; build sem VITE_SUPABASE_URL)"); process.exit(1); }
console.log("KORA-STG BUNDLE: PASS");
