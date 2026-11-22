// Autoverificação ESTÁTICA (offline, sem banco/Docker, ~50 MB RAM).
// Prova consistência interna dos artefatos; NÃO prova segurança da aplicação.
// Uso: node KORA-STAGING-READINESS-01/staging/scripts/static-selfcheck.mjs
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, relative, extname } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const STG = fileURLToPath(new URL("..", import.meta.url));
const REPO = fileURLToPath(new URL("../../..", import.meta.url));
const results = [];
const check = (id, pass, detail = "") => results.push({ id, status: pass ? "PASS" : "FAIL", detail });

function walk(dir) {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    if (n === "node_modules" || n === "reports") return [];
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}
const files = walk(STG);

// 1. Sintaxe JS
for (const f of files.filter((x) => extname(x) === ".mjs")) {
  const r = spawnSync(process.execPath, ["--check", f], { encoding: "utf8" });
  check(`JS-SYNTAX ${relative(STG, f)}`, r.status === 0, r.stderr.trim().split("\n")[0] || "");
}
// 2. Sintaxe bash (se bash disponível)
const bash = spawnSync("bash", ["--version"], { encoding: "utf8" });
for (const f of files.filter((x) => extname(x) === ".sh")) {
  if (bash.status !== 0) { results.push({ id: `SH-SYNTAX ${relative(STG, f)}`, status: "NOT RUN", detail: "bash ausente" }); continue; }
  const r = spawnSync("bash", ["-n", f], { encoding: "utf8" });
  check(`SH-SYNTAX ${relative(STG, f)}`, r.status === 0, r.stderr.trim());
}
// 3. YAML do workflow
try {
  const require = createRequire(join(REPO, "package.json"));
  const YAML = require("yaml");
  const wf = YAML.parse(readFileSync(join(STG, "workflow", "kora-staging-homologation.yml"), "utf8"));
  const on = wf.on ?? wf[true];
  check("WF-PARSE", !!wf.jobs?.homologation, "");
  check("WF-NO-MAIN-TRIGGER", !JSON.stringify(on).includes('"main"') && !(on.pull_request), JSON.stringify(on));
  check("WF-PERMISSIONS-READONLY", JSON.stringify(wf.permissions) === JSON.stringify({ contents: "read" }), JSON.stringify(wf.permissions));
  check("WF-NO-SECRETS", !readFileSync(join(STG, "workflow", "kora-staging-homologation.yml"), "utf8").includes("secrets."), "");
  // PROVISIONING-02: workflow ativo (se existir) idêntico à proposta versionada; trigger
  // somente staging/homologation-**; checkout sem credencial persistida; baseline fixado.
  const wfText = readFileSync(join(STG, "workflow", "kora-staging-homologation.yml"), "utf8");
  let active = null;
  try { active = readFileSync(join(REPO, ".github", "workflows", "kora-staging-homologation.yml"), "utf8"); } catch {}
  if (active !== null) check("WF-ACTIVE-EQUALS-PROPOSAL", active.replace(/\r\n/g, "\n") === wfText.replace(/\r\n/g, "\n"), "");
  check("WF-TRIGGER-STAGING-ONLY", JSON.stringify(on) === JSON.stringify({ push: { branches: ["staging/homologation-**"] } }), JSON.stringify(on));
  check("WF-CHECKOUT-NO-PERSISTED-TOKEN", wf.jobs.homologation.steps.some((s) => String(s.uses).startsWith("actions/checkout") && s.with?.["persist-credentials"] === false), "");
  check("WF-RUN-IDENTITY", !!wf.jobs.homologation.env?.KORA_STG_RUN_LABEL && !!wf.jobs.homologation.env?.KORA_STG_EXPECT_LAST_MIGRATION, "");
  check("WF-BUNDLE-SCAN", wfText.includes("scan-bundle.mjs"), "");
} catch (e) { results.push({ id: "WF-PARSE", status: "NOT RUN", detail: e.message }); }

// 4. Esquema: colunas do seed existem nas migrations
const migDir = join(REPO, "supabase", "migrations");
const migSql = readdirSync(migDir).sort().map((n) => readFileSync(join(migDir, n), "utf8")).join("\n");
const columns = new Map();
const addCol = (t, c) => { if (!columns.has(t)) columns.set(t, new Set()); columns.get(t).add(c); };
for (const m of migSql.matchAll(/create table (?:if not exists )?(?:public\.)?([a-z_]+)\s*\(([\s\S]*?)\n\);/gi)) {
  for (const line of m[2].split("\n")) {
    const c = line.trim().match(/^([a-z_][a-z0-9_]*)\s+(uuid|text|int|integer|bigint|boolean|date|timestamptz|jsonb|numeric|smallint|perfil_usuario|situacao_[a-z_]+|tipo_[a-z_]+|dificuldade_questao|public\.[a-z_]+)/i);
    if (c && !["primary", "unique", "constraint", "check", "foreign"].includes(c[1].toLowerCase())) addCol(m[1], c[1]);
  }
}
for (const m of migSql.matchAll(/alter table (?:if exists )?(?:only )?(?:public\.)?([a-z_]+)\s+add column (?:if not exists )?([a-z_][a-z0-9_]*)/gi)) addCol(m[1], m[2]);
for (const m of migSql.matchAll(/alter table (?:if exists )?(?:public\.)?([a-z_]+)\s*\n?\s*add column (?:if not exists )?([a-z_][a-z0-9_]*)/gi)) addCol(m[1], m[2]);
for (const m of migSql.matchAll(/alter table (?:if exists )?(?:public\.)?([a-z_]+)([^;]*);/gi)) {
  for (const a of m[2].matchAll(/add column (?:if not exists )?([a-z_][a-z0-9_]*)/gi)) addCol(m[1], a[1]);
}
// KORA_STG_SELFCHECK_SEED permite teste de mutação (seed adulterado deve FALHAR).
const seed = readFileSync(process.env.KORA_STG_SELFCHECK_SEED || join(STG, "fixtures", "academic_seed.sql"), "utf8");
for (const m of seed.matchAll(/insert into public\.([a-z_]+)\(([^)]*)\)/gi)) {
  const known = columns.get(m[1]);
  const cols = m[2].split(",").map((s) => s.trim());
  const missing = known ? cols.filter((c) => !known.has(c)) : cols;
  check(`SCHEMA seed ${m[1]}`, missing.length === 0, missing.length ? `colunas não encontradas nas migrations: ${missing.join(",")}` : `${cols.length} colunas`);
}
// 4b. Tabelas usadas pelos testes existem
const testSrc = files.filter((f) => f.includes(`${join("staging", "tests")}`) && f.endsWith(".mjs")).map((f) => readFileSync(f, "utf8")).join("\n");
const tables = new Set([...testSrc.matchAll(/\.from\("([a-z_]+)"\)/g)].map((m) => m[1]));
const buckets = new Set(["documentos", "conteudo-cursos"]);
for (const t of tables) {
  if (buckets.has(t)) continue;
  check(`SCHEMA test-table ${t}`, columns.has(t), columns.has(t) ? "" : "tabela inexistente nas migrations");
}
// 4c. Colunas usadas em insert/update/select dos testes (heurística)
for (const m of testSrc.matchAll(/\.from\("([a-z_]+)"\)\.(?:insert|update)\(\{([^}]*)\}/g)) {
  if (buckets.has(m[1]) || !columns.has(m[1])) continue;
  const keys = [...m[2].matchAll(/([a-z_]+)\s*:/g)].map((k) => k[1]);
  const missing = keys.filter((k) => !columns.get(m[1]).has(k));
  if (missing.length) check(`SCHEMA test-cols ${m[1]}`, false, missing.join(","));
}
for (const m of testSrc.matchAll(/\.from\("([a-z_]+)"\)\.select\("([^"]*)"\)/g)) {
  if (!columns.has(m[1])) continue;
  const missing = m[2].split(",").map((s) => s.trim()).filter((c) => c && !columns.get(m[1]).has(c));
  if (missing.length) check(`SCHEMA test-select ${m[1]}`, false, missing.join(","));
}
// 4d. RPCs usados existem
const rpcs = new Set([...testSrc.matchAll(/\.rpc\("([a-z_]+)"/g)].map((m) => m[1]));
for (const r of rpcs) check(`SCHEMA rpc ${r}`, new RegExp(`function public\\.${r}\\s*\\(`, "i").test(migSql), "");

// 5. Manifesto x seed e invariantes de tenant
const M = JSON.parse(readFileSync(join(STG, "fixtures", "fixture-manifest.json"), "utf8"));
const allIds = JSON.stringify(M).match(/f[0-9a-f]000000-0000-4000-8000-[0-9a-f]{12}/g) ?? [];
const absent = [...new Set(allIds)].filter((id) => !seed.includes(id));
check("FIXTURE ids do manifesto presentes no seed", absent.length === 0, absent.join(","));
const tOf = { turma: (k) => M.turmas[k].tenant, user: (k) => M.users[k].tenant, curso: (k) => M.cursos[k].tenant };
const inv = [];
for (const [k, t] of Object.entries(M.turmas)) if (tOf.curso(t.curso) !== t.tenant) inv.push(`turma ${k}`);
for (const [k, m] of Object.entries(M.matriculas)) if (tOf.user(m.user) !== tOf.turma(m.turma)) inv.push(`matricula ${k}`);
for (const [k, p] of Object.entries(M.professoresTurmas)) if (tOf.user(p.user) !== tOf.turma(p.turma)) inv.push(`prof_turma ${k}`);
check("FIXTURE relações no mesmo tenant", inv.length === 0, inv.join(","));
check("FIXTURE 2 tenants, 2 gestores, 3 professores, 4 alunos ativos com matrícula",
  Object.keys(M.tenants).length === 2 && Object.values(M.users).filter((u) => u.perfil === "gestor").length === 2 &&
  Object.values(M.users).filter((u) => u.perfil === "professor").length === 3 && Object.keys(M.matriculas).length === 4, "");
check("FIXTURE e-mails sintéticos (.invalid)", Object.values(M.users).every((u) => u.email.endsWith("@kora-staging.invalid")), "");

// 6. Varredura de segredos e referência de produção
const secretRx = [/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/, /sb_secret_[A-Za-z0-9]/, /sb_publishable_[A-Za-z0-9]/, /-----BEGIN [A-Z ]*PRIVATE KEY-----/];
for (const f of files.filter((x) => /\.(mjs|sh|sql|json|yml|md|toml)$/.test(x))) {
  if (f.endsWith("static-selfcheck.mjs")) continue;
  const s = readFileSync(f, "utf8");
  const hit = secretRx.find((rx) => rx.test(s));
  check(`SECRETS ${relative(STG, f)}`, !hit, hit ? `padrão ${hit}` : "");
  if (s.includes("goxaeupwxhbiobvvwnxj") && !f.endsWith("guard.mjs")) check(`PROD-REF ${relative(STG, f)}`, false, "referência ao projeto de produção fora do guard");
}

// 7. Testes unitários do guard
const { assertSafeTarget } = await import(new URL("./guard.mjs", import.meta.url));
const attempt = (env) => { try { assertSafeTarget({}, env); return "ok"; } catch { return "denied"; } };
check("GUARD local permitido", attempt({ KORA_STG_API_URL: "http://127.0.0.1:54321", KORA_STG_DB_URL: "postgresql://postgres:postgres@127.0.0.1:54322/postgres" }) === "ok");
check("GUARD produção negada", attempt({ KORA_STG_API_URL: "https://goxaeupwxhbiobvvwnxj.supabase.co" }) === "denied");
check("GUARD produção negada via VITE_SUPABASE_URL", attempt({ KORA_STG_API_URL: "http://127.0.0.1:54321", VITE_SUPABASE_URL: "https://goxaeupwxhbiobvvwnxj.supabase.co" }) === "denied");
check("GUARD host remoto negado em modo local", attempt({ KORA_STG_API_URL: "https://abc.supabase.co" }) === "denied");
check("GUARD remoto sem autorização negado", attempt({ KORA_STG_MODE: "remote-staging", KORA_STG_API_URL: "https://abc.supabase.co", KORA_STG_REMOTE_HOST: "abc.supabase.co" }) === "denied");
check("GUARD remoto fora da allowlist negado", attempt({ KORA_STG_MODE: "remote-staging", KORA_STG_ALLOW_REMOTE: "1", KORA_STG_API_URL: "https://xyz.supabase.co", KORA_STG_REMOTE_HOST: "abc.supabase.co" }) === "denied");
check("GUARD remoto autorizado e na allowlist permitido", attempt({ KORA_STG_MODE: "remote-staging", KORA_STG_ALLOW_REMOTE: "1", KORA_STG_API_URL: "https://abc.supabase.co", KORA_STG_REMOTE_HOST: "abc.supabase.co" }) === "ok");
check("GUARD sem alvo negado", attempt({}) === "denied");

// Resultado
const summary = results.reduce((a, r) => ((a[r.status] = (a[r.status] || 0) + 1), a), {});
for (const r of results) if (r.status !== "PASS") console.log(`${r.status} ${r.id} ${r.detail}`);
console.log(`STATIC SELFCHECK: ${JSON.stringify(summary)} (${results.length} verificações)`);
const out = process.env.KORA_STG_SELFCHECK_OUT;
if (out) writeFileSync(out, JSON.stringify({ summary, results }, null, 2));
process.exit(results.some((r) => r.status === "FAIL") ? 1 : 0);
