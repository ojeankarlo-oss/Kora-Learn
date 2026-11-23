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

  // PROVISIONING-02 (correção pós-run 45039098280): contextos de expressão permitidos por
  // posição, conforme a tabela "Context availability" do GitHub Actions. Um contexto fora
  // da lista invalida o arquivo inteiro e o run termina com 0 jobs.
  // KORA_STG_SELFCHECK_WORKFLOW permite teste de mutação (workflow adulterado deve FALHAR).
  const wfCtx = process.env.KORA_STG_SELFCHECK_WORKFLOW
    ? YAML.parse(readFileSync(process.env.KORA_STG_SELFCHECK_WORKFLOW, "utf8")) : wf;
  const STEP_CTX = ["github", "needs", "strategy", "matrix", "job", "runner", "env", "vars", "secrets", "steps", "inputs"];
  const ALLOWED = {
    "env": ["github", "secrets", "inputs", "vars"],
    "concurrency": ["github", "inputs", "vars"],
    "jobs.*.runs-on": ["github", "needs", "strategy", "matrix", "vars", "inputs"],
    "jobs.*.env": ["github", "needs", "strategy", "matrix", "vars", "secrets", "inputs"],
    "jobs.*.timeout-minutes": ["github", "needs", "strategy", "matrix", "vars", "inputs"],
    "jobs.*.concurrency": ["github", "needs", "strategy", "matrix", "vars", "inputs"],
    "jobs.*.if": ["github", "needs", "vars", "inputs"],
    "jobs.*.steps.*": STEP_CTX,
  };
  const exprsOf = (v, implicit = false) => {
    const s = typeof v === "string" ? v : JSON.stringify(v ?? "");
    const out = [...s.matchAll(/\$\{\{([\s\S]*?)\}\}/g)].map((m) => m[1]);
    return out.length || !implicit ? out : [s];
  };
  const namedValues = (expr) => {
    const noStr = expr.replace(/'(?:[^']|'')*'/g, "''");
    return [...noStr.matchAll(/(^|[^.\w-])([A-Za-z_][\w-]*)(?![\w-]*\s*\()/g)].map((m) => m[2])
      .filter((n) => !["true", "false", "null"].includes(n));
  };
  const ctxViolations = [];
  const scan = (pos, value, implicit = false) => {
    for (const e of exprsOf(value, implicit)) for (const n of namedValues(e)) {
      if (!ALLOWED[pos].includes(n)) ctxViolations.push(`${pos}: '${n}' em \${{${e.trim()}}}`);
    }
  };
  scan("env", wfCtx.env);
  scan("concurrency", wfCtx.concurrency);
  const envRefViolations = [];
  for (const [jid, job] of Object.entries(wfCtx.jobs)) {
    scan("jobs.*.runs-on", job["runs-on"]);
    scan("jobs.*.env", job.env);
    scan("jobs.*.timeout-minutes", job["timeout-minutes"]);
    scan("jobs.*.concurrency", job.concurrency);
    if (job.if !== undefined) scan("jobs.*.if", job.if, true);
    const declared = new Set([...Object.keys(wfCtx.env ?? {}), ...Object.keys(job.env ?? {})]);
    for (const [i, step] of (job.steps ?? []).entries()) {
      for (const k of ["name", "env", "with", "run", "continue-on-error", "working-directory", "timeout-minutes"]) {
        if (step[k] !== undefined) scan("jobs.*.steps.*", step[k]);
      }
      if (step.if !== undefined) scan("jobs.*.steps.*", step.if, true);
      // `${{ env.X }}` só para X declarado no YAML (workflow/job/step). Variáveis produzidas
      // em runtime via GITHUB_ENV devem ser lidas no shell ($X), nunca por expressão.
      const stepDeclared = new Set([...declared, ...Object.keys(step.env ?? {})]);
      for (const e of exprsOf(JSON.stringify(step))) {
        for (const m of e.matchAll(/\benv\.([A-Za-z_]\w*)/g)) {
          if (!stepDeclared.has(m[1])) envRefViolations.push(`${jid}.steps[${i}]: env.${m[1]} não declarado no YAML`);
        }
      }
    }
  }
  check("WF-CONTEXT-AVAILABILITY", ctxViolations.length === 0, ctxViolations.join("; "));
  check("WF-NO-RUNTIME-ENV-EXPR", envRefViolations.length === 0, envRefViolations.join("; "));
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
const { assertSafeTarget, PRODUCTION_REFS } = await import(new URL("./guard.mjs", import.meta.url));
const PRODUCTION_REF_FOR_TEST = PRODUCTION_REFS[0];
const attempt = (env) => { try { assertSafeTarget({}, env); return "ok"; } catch { return "denied"; } };
check("GUARD local permitido", attempt({ KORA_STG_API_URL: "http://127.0.0.1:54321", KORA_STG_DB_URL: "postgresql://postgres:postgres@127.0.0.1:54322/postgres" }) === "ok");
check("GUARD produção negada", attempt({ KORA_STG_API_URL: "https://goxaeupwxhbiobvvwnxj.supabase.co" }) === "denied");
check("GUARD produção negada via VITE_SUPABASE_URL", attempt({ KORA_STG_API_URL: "http://127.0.0.1:54321", VITE_SUPABASE_URL: "https://goxaeupwxhbiobvvwnxj.supabase.co" }) === "denied");
check("GUARD host remoto negado em modo local", attempt({ KORA_STG_API_URL: "https://abc.supabase.co" }) === "denied");
check("GUARD remoto sem autorização negado", attempt({ KORA_STG_MODE: "remote-staging", KORA_STG_API_URL: "https://abc.supabase.co", KORA_STG_REMOTE_HOST: "abc.supabase.co" }) === "denied");
check("GUARD remoto fora da allowlist negado", attempt({ KORA_STG_MODE: "remote-staging", KORA_STG_ALLOW_REMOTE: "1", KORA_STG_API_URL: "https://xyz.supabase.co", KORA_STG_REMOTE_HOST: "abc.supabase.co" }) === "denied");
check("GUARD remoto autorizado e na allowlist permitido", attempt({ KORA_STG_MODE: "remote-staging", KORA_STG_ALLOW_REMOTE: "1", KORA_STG_API_URL: "https://abc.supabase.co", KORA_STG_REMOTE_HOST: "abc.supabase.co" }) === "ok");
check("GUARD sem alvo negado", attempt({}) === "denied");
// PROVISIONING-03-FIX: mais formas de apontar para produção.
check("GUARD produção negada via DB_URL do pooler", attempt({ KORA_STG_API_URL: "http://127.0.0.1:54321", KORA_STG_DB_URL: "postgresql://postgres." + PRODUCTION_REF_FOR_TEST + ":x@aws-0-sa-east-1.pooler.supabase.com:6543/postgres" }) === "denied");
check("GUARD produção negada via SUPABASE_URL", attempt({ KORA_STG_API_URL: "http://127.0.0.1:54321", SUPABASE_URL: "https://" + PRODUCTION_REF_FOR_TEST + ".supabase.co" }) === "denied");

// 8. PROVISIONING-03-FIX — redação de logs/relatórios (run 45041095243 publicou chaves locais).
{
  const { redact } = await import(new URL("./redact-log.mjs", import.meta.url));
  // Valores FALSOS, montados por concatenação (não são chaves reais nem padrões literais).
  const fakePub = "sb_" + "publishable_" + "FAKEpub0000000000000000_abcdef";
  const fakeSec = "sb_" + "secret_" + "FAKEsec0000000000000000_abcdef";
  const fakeJwt = "ey" + "J" + "hbGciOiJIUzI1NiJ9FAKEFAKE" + "." + "ey" + "J" + "yb2xlIjoiYW5vbiJ9FAKEFAKE" + "." + "FAKEsignature000000";
  const fakeS3 = "FAKEs3secret0000000000000000000000000000";
  const fakeEnvVal = "FAKE-runtime-value-0000";
  const sample = [
    "Started supabase local development setup.",
    "╭──────────────────────────────────────╮",
    "│ 🌐 APIs                              │",
    "├─────────────┬────────────────────────┤",
    "│ Project URL │ http://127.0.0.1:54321 │",
    "╰─────────────┴────────────────────────╯",
    "│ Publishable │ " + fakePub + " │",
    "│ Secret      │ " + fakeSec + "      │",
    "│ Access Key  │ FAKEaccesskey0000000000000000 │",
    "│ Secret Key  │ " + fakeS3 + " │",
    "| JWT secret | FAKEjwtsecret-0000000000000000 |",
    "        anon key: " + fakeJwt,
    "SERVICE_ROLE_KEY=\"" + fakeJwt + "\"",
    "DB_URL=postgresql://postgres:FAKEpw000@127.0.0.1:54322/postgres",
    "assertion failed: got " + fakeEnvVal,
  ].join("\n");
  const { text: red, count } = redact(sample, [fakeEnvVal]);
  const leaked = [fakePub, fakeSec, fakeJwt, fakeS3, "FAKEaccesskey", "FAKEjwtsecret", "FAKEpw000", fakeEnvVal].filter((v) => red.includes(v));
  check("REDACT chaves do supabase start (sb_*, JWT, S3, JWT secret, senha DB, valor runtime)", leaked.length === 0, leaked.length ? `vazou ${leaked.length} valor(es)` : `${count} redações`);
  check("REDACT preserva diagnóstico não sensível", red.includes("http://127.0.0.1:54321") && red.includes("Started supabase local development setup.") && red.includes("127.0.0.1:54322/postgres"), "");
  check("REDACT texto limpo fica intacto", redact("KORA-STG MIGRATIONS: PASS (40 migrations)\nok 3 - tenant isolation", []).count === 0, "");
  // Modo --in-place: rc=3 e arquivo redigido quando há credencial; rc=0 quando limpo.
  const { mkdtempSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const tdir = mkdtempSync(join(tmpdir(), "kora-stg-redact-"));
  try {
    writeFileSync(join(tdir, "junit-x.xml"), `<failure message="token ${fakeJwt}"/>`);
    const r1 = spawnSync(process.execPath, [join(STG, "scripts", "redact-log.mjs"), "--in-place", tdir], { encoding: "utf8", env: { PATH: process.env.PATH } });
    const after = readFileSync(join(tdir, "junit-x.xml"), "utf8");
    check("REDACT --in-place: credencial em relatório -> rc=3 e redigida", r1.status === 3 && !after.includes(fakeJwt) && !r1.stdout.includes(fakeJwt), `rc=${r1.status}`);
    const r2 = spawnSync(process.execPath, [join(STG, "scripts", "redact-log.mjs"), "--in-place", tdir], { encoding: "utf8", env: { PATH: process.env.PATH } });
    check("REDACT --in-place: relatório limpo -> rc=0", r2.status === 0, `rc=${r2.status}`);
  } finally { rmSync(tdir, { recursive: true, force: true }); }

  const prov = readFileSync(join(STG, "scripts", "provision.sh"), "utf8");
  const startLines = prov.split("\n").filter((l) => /\bstart --workdir\b/.test(l));
  check("PROVISION supabase start sempre redirecionado a arquivo privado", startLines.length > 0 && startLines.every((l) => /> "\$START_LOG" 2>&1/.test(l)), `${startLines.length} invocação(ões)`);
  const iMask = prov.indexOf("::add-mask::");
  const iPrint = prov.indexOf('redact-log.mjs" --secrets-env "$STACK_ENV" "$START_LOG"');
  check("PROVISION saída do start só impressa redigida e após as máscaras", iMask > 0 && iPrint > iMask, "");
  check("PROVISION máscara cobre todo valor *KEY*/*SECRET* do stack", /\(KEY\|SECRET\|PASSWORD\|TOKEN\)/.test(prov.slice(iMask - 400, iMask)), "");
  check("CLEANUP remove o log bruto do start", readFileSync(join(STG, "scripts", "cleanup.sh"), "utf8").includes(".supabase-start.log"), "");
  let wfSteps = [];
  try { wfSteps = createRequire(join(REPO, "package.json"))("yaml").parse(readFileSync(join(STG, "workflow", "kora-staging-homologation.yml"), "utf8")).jobs.homologation.steps; } catch {}
  const iRedact = wfSteps.findIndex((s) => s.id === "redact");
  const iUpload = wfSteps.findIndex((s) => String(s.uses).startsWith("actions/upload-artifact"));
  check("WF relatórios redigidos antes do upload; upload condicionado ao redator", iRedact >= 0 && iRedact < iUpload && /steps\.redact\.outputs\.rc/.test(String(wfSteps[iUpload].if)), "");
  check("WF gate inclui o redator (credencial em relatório => BLOCKED)", /R_REDACT/.test(JSON.stringify(wfSteps.find((s) => /^Gate/.test(s.name ?? "")) ?? {})), "");
}

// 9. PROVISIONING-03-FIX — trava do seed e estado de baseline (tenant kora-demo da 001).
{
  const seedTxt = readFileSync(join(STG, "fixtures", "academic_seed.sql"), "utf8");
  const guardTxt = readFileSync(join(STG, "fixtures", "seed_guard.sql"), "utf8");
  const regrTxt = readFileSync(join(STG, "fixtures", "seed_guard_regression.sql"), "utf8");
  const prov = readFileSync(join(STG, "scripts", "provision.sh"), "utf8");
  const firstInsert = seedTxt.search(/insert into public\./i);
  const iGuard = seedTxt.indexOf("perform pg_temp.kora_stg_assert_seed_target()");
  check("SEED trava executada antes de qualquer insert", seedTxt.includes("\\ir seed_guard.sql") && iGuard > 0 && iGuard < firstInsert, "");
  check("SEED mantém exigência de >=10 usuários auth sintéticos", /< 10 then/.test(seedTxt), "");
  check("GUARD-SQL tolera somente slug kora-demo além de kora-stg-%", (guardTxt.match(/'kora-demo'/g) || []).length >= 2 && /slug not like 'kora-stg-%' and slug <> 'kora-demo'/.test(guardTxt) && !/slug in \(/i.test(guardTxt), "");
  check("GUARD-SQL exige kora-demo presente, único e com nome/plano do baseline", /v_demo_count <> 1/.test(guardTxt) && /nome = 'KORA Demo' and plano = 'starter'/.test(guardTxt), "");
  check("GUARD-SQL varre toda FK para tenants e toda coluna tenant_id", /confrelid = 'public\.tenants'::regclass/.test(guardTxt) && /a\.attname = 'tenant_id'/.test(guardTxt), "");
  check("GUARD-SQL única exceção de vínculo = 1 'Unidade Bela Vista'", /v_n <> 1/.test(guardTxt) && (guardTxt.match(/Unidade Bela Vista/g) || []).length >= 2, "");
  check("GUARD-SQL não altera dados", !/\b(insert|update|delete|truncate|drop|alter)\s/i.test(guardTxt.replace(/--.*$/gm, "").replace(/'[^']*'/g, "''")), "");
  // O estado tolerado precisa continuar sendo exatamente o que as migrations criam.
  const m001 = readFileSync(join(migDir, "001_kora_learn_nucleo.sql"), "utf8");
  const m004 = readFileSync(join(migDir, "004_kora_learn_fase5.sql"), "utf8");
  check("BASELINE 001 cria kora-demo ('KORA Demo','starter')", /values \('KORA Demo', 'kora-demo', 'starter'\)/.test(m001), "");
  check("BASELINE 004 cria 'Unidade Bela Vista' no kora-demo", /'Unidade Bela Vista'[\s\S]{0,200}t\.slug = 'kora-demo'/.test(m004), "");
  const otherTopLevelTenantInserts = readdirSync(migDir).sort().filter((n) => /^\d{3}_/.test(n)).filter((n) => {
    const s = readFileSync(join(migDir, n), "utf8");
    return /^insert into (public\.)?(tenants|unidades)\b/im.test(s) && !["001_kora_learn_nucleo.sql", "004_kora_learn_fase5.sql"].includes(n);
  });
  check("BASELINE nenhuma outra migration insere tenants/unidades no nível superior", otherTopLevelTenantInserts.length === 0, otherTopLevelTenantInserts.join(","));
  const cases = [...regrTxt.matchAll(/pg_temp\.kora_stg_case\('(G\d+) /g)].map((m) => m[1]);
  check("REGRESSÃO 12 cenários G1..G12", cases.length === 12 && cases.every((c, i) => c === `G${i + 1}`), cases.join(","));
  check("REGRESSÃO cobre esperado/desconhecido/vínculo/ausência/auth", ["baseline esperado", "tenant desconhecido", "kora-demo ausente", "vínculo por FK", "usuário auth não sintético", "unidade extra"].every((k) => regrTxt.includes(k)), "");
  check("REGRESSÃO sempre desfeita (subtransação + ROLLBACK final)", /errcode = 'KS999'/.test(regrTxt) && /\nrollback;\s*$/.test(regrTxt) && !/\ncommit;/i.test(regrTxt), "");
  check("REGRESSÃO erro de preparação/não relacionado = FAIL", /FAIL %s: erro na preparação/.test(regrTxt) && /FAIL %s: erro não relacionado/.test(regrTxt), "");
  const iRegr = prov.indexOf("seed_guard_regression.sql");
  const iSeedAuth = prov.indexOf('node "$SCRIPT_DIR/seed-auth.mjs"');
  const iMig = prov.indexOf("apply-migrations.sh");
  check("PROVISION roda a regressão após migrations e antes do seed", iMig > 0 && iRegr > iMig && iRegr < iSeedAuth, "");
}

// 10. PROVISIONING-04 — inicialização do stack (run 45187500465: EADDRINUSE em 54322).
{
  const prov = readFileSync(join(STG, "scripts", "provision.sh"), "utf8");
  const pre = readFileSync(join(STG, "scripts", "stack-preflight.sh"), "utf8");
  const preCode = pre.split("\n").filter((l) => !/^\s*#/.test(l)).join("\n");
  const lines = prov.split("\n");
  const iStartLine = lines.findIndex((l) => /\bstart --workdir\b/.test(l));
  const iUmaskLine = lines.findIndex((l) => /^umask 077\s*$/.test(l));
  const iCheckLine = lines.findIndex((l) => /stack-preflight\.sh" check\s*$/.test(l));
  const iCreateLine = lines.findIndex((l) => /^\( umask 077 && rm -f "\$START_LOG" "\$STACK_ENV" && : > "\$START_LOG" && : > "\$STACK_ENV" \)\s*$/.test(l));
  check("PROVISION umask 077 global só depois do start", iStartLine > 0 && iUmaskLine > iStartLine, `start=${iStartLine} umask=${iUmaskLine}`);
  check("PROVISION log do start e .stack.env criados 0600 (subshell umask 077) antes do start", iCreateLine > 0 && iCreateLine < iStartLine, "");
  check("PROVISION pré-voo executado antes do start", iCheckLine > iCreateLine && iCheckLine < iStartLine, "");
  const failBranch = lines.slice(iStartLine, iStartLine + 6).join("\n");
  check("PROVISION falha do start: redigido + postmortem + exit 1", /redact-log\.mjs" "\$START_LOG"/.test(failBranch) && /stack-preflight\.sh" postmortem/.test(failBranch) && /\n\s*exit 1\n/.test(failBranch), "");
  const allSh = files.filter((x) => extname(x) === ".sh").map((f) => readFileSync(f, "utf8")).join("\n");
  const startCount = (allSh.match(/\bstart --workdir\b/g) || []).length;
  const loopBeforeStart = lines.slice(iCheckLine, iStartLine).some((l) => /^\s*(for|while|until)\b/.test(l));
  check("START tentativa única (1 invocação em todos os scripts, fora de laço)", startCount === 1 && !loopBeforeStart && /^if ! "\$\{SB\[@\]\}" start/.test(lines[iStartLine]), `${startCount} invocação(ões)`);
  check("PREFLIGHT set -euo pipefail", /^set -euo pipefail$/m.test(pre), "");
  check("PREFLIGHT nunca mata processo nem remove contêiner/volume", !/\b(kill|pkill|killall|fuser)\b|docker\s+(rm|stop|kill|restart|start|run|volume\s+rm|system\s+prune|container\s+rm)\b|\bsupabase@|\bnpx\b|\bsupabase\s+(start|stop)\b/.test(preCode), "");
  check("PREFLIGHT não imprime env/logs de contêiner", !/docker\s+(inspect|logs|exec)\b|\bprintenv\b|^\s*env\s*$/m.test(preCode), "");
  check("PREFLIGHT sysctl somente ip_local_reserved_ports e somente no Actions", (preCode.match(/sysctl/g) || []).length === 1 && /sysctl -q -w "net\.ipv4\.ip_local_reserved_ports=/.test(preCode) && /reserve\)\n\s*if ! in_ci; then[\s\S]{0,200}exit 0/.test(preCode), "");
  check("PREFLIGHT diagnóstico passa pelo redator (falha do redator => suprimido, arquivo removido)", /node "\$SCRIPT_DIR\/redact-log\.mjs" "\$f" \|\| echo "KORA-STG DIAG: redator falhou; diagnóstico suprimido"\n\s*rm -f "\$f"/.test(preCode), "");
  check("PREFLIGHT falha fechada sem ss/docker e com LISTEN/remanescentes/ocupação persistente",
    /command -v ss[^\n]*exit 1/.test(preCode) && /docker info[^\n]*exit 1/.test(preCode) && /grep -Eq '\(\^\|\[\[:space:\]\]\)LISTEN\(\[\[:space:\]\]\|\$\)' <<< "\$socks"/.test(preCode) &&
    /remanescentes do projeto/.test(preCode) && /seguem ocupadas/.test(preCode), "");
  check("PREFLIGHT erro de ss/docker nunca conta como porta livre ou zero remanescentes",
    !/\bss -Hant[^\n]*\|\|\s*true/.test(preCode) && (preCode.match(/socks="\$\(port_sockets\)" \|\| \{/g) || []).length === 2 &&
    (preCode.match(/="\$\(docker (ps|volume ls) -[a]?q --filter "[^"]+"\)" \|\| return 1/g) || []).length === 4 && /if ! cont="\$\(project_containers\)" \|\| ! vols="\$\(project_volumes\)"; then/.test(preCode), "");
  // Comportamento (bash local; sem Docker, sem root): parse da reserva e modo reserve fora do Actions.
  if (bash.status === 0) {
    const preflight = join(STG, "scripts", "stack-preflight.sh");
    const env0 = { PATH: process.env.PATH, KORA_STG_WORKDIR: join(tmpdirSafe(), "kora-stg-preflight-selfcheck") };
    const run = (args, extra = {}) => spawnSync("bash", [preflight, ...args], { encoding: "utf8", env: { ...env0, ...extra } });
    const cov = (spec) => run(["_test-covers", spec]).status;
    check("PREFLIGHT reserva: cobre faixa exata, superconjunto e lista mista", cov("54320-54329") === 0 && cov("1000-2000,54300-54400") === 0 && cov("8080, 54320-54325,54326-54329") === 0, "");
    check("PREFLIGHT reserva: falta de qualquer porta => não coberto", cov("") === 1 && cov("54320-54328") === 1 && cov("54321-54329") === 1 && cov("lixo,54320-54329x") === 1, "");
    const r1 = run(["reserve"], { GITHUB_ACTIONS: "" });
    check("PREFLIGHT reserve fora do Actions não altera o host", r1.status === 0 && /ignorado fora do GitHub Actions/.test(r1.stdout), `rc=${r1.status}`);
    check("PREFLIGHT faixa de portas inválida => abort", run(["reserve"], { KORA_STG_STACK_PORTS: "1-99999" }).status === 2 && run(["reserve"], { KORA_STG_STACK_PORTS: "54320" }).status === 2, "");
    check("PREFLIGHT modo desconhecido => abort", run(["retry"]).status === 2, "");
  } else {
    results.push({ id: "PREFLIGHT comportamento", status: "NOT RUN", detail: "bash ausente" });
  }
  // Workflow: reserva antes de npm/pulls; limpeza sempre; gate inalterado.
  let steps = [];
  try { steps = createRequire(join(REPO, "package.json"))("yaml").parse(readFileSync(join(STG, "workflow", "kora-staging-homologation.yml"), "utf8")).jobs.homologation.steps; } catch {}
  const iRes = steps.findIndex((s) => /stack-preflight\.sh" reserve/.test(String(s.run)));
  const iNode = steps.findIndex((s) => String(s.uses).startsWith("actions/setup-node"));
  const iNpm = steps.findIndex((s) => /npm ci/.test(String(s.run)));
  const iProv = steps.findIndex((s) => /provision\.sh/.test(String(s.run)));
  const clean = steps.find((s) => /cleanup\.sh/.test(String(s.run)));
  check("WF reserva de portas antes de setup-node/npm ci/provision", iRes > 0 && iRes < iNode && iRes < iNpm && iRes < iProv, `reserve=${iRes} node=${iNode} npm=${iNpm} prov=${iProv}`);
  check("WF reserva sem continue-on-error (falha fechada)", iRes > 0 && steps[iRes]["continue-on-error"] === undefined && steps[iRes].if === undefined, "");
  check("WF limpeza sempre executada", !!clean && String(clean.if) === "always()", "");
}

function tmpdirSafe() { return process.env.RUNNER_TEMP || process.env.TMPDIR || process.env.TEMP || "/tmp"; }

// Resultado
const summary = results.reduce((a, r) => ((a[r.status] = (a[r.status] || 0) + 1), a), {});
for (const r of results) if (r.status !== "PASS") console.log(`${r.status} ${r.id} ${r.detail}`);
console.log(`STATIC SELFCHECK: ${JSON.stringify(summary)} (${results.length} verificações)`);
const out = process.env.KORA_STG_SELFCHECK_OUT;
if (out) writeFileSync(out, JSON.stringify({ summary, results }, null, 2));
process.exit(results.some((r) => r.status === "FAIL") ? 1 : 0);
