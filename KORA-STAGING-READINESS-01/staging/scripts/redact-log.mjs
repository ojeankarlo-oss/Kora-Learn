// KORA-STAGING — redator de logs/relatórios (PROVISIONING-03-FIX).
// Repositório PÚBLICO: logs do Actions e artefatos são públicos. Chaves LOCAIS do stack
// efêmero (anon/service_role JWT, sb_publishable_/sb_secret_, JWT secret, chaves S3,
// senhas) nunca devem ser publicadas, mesmo sendo efêmeras.
//
// Uso:
//   node redact-log.mjs <arquivo>              imprime o arquivo redigido em stdout (exit 0)
//   node redact-log.mjs --in-place <dir>       redige *.xml/*.txt de <dir> no lugar;
//                                              exit 3 se algo precisou ser redigido (fail-closed:
//                                              credencial em relatório é defeito), 0 se limpo.
// Nenhum valor secreto é impresso; apenas contagens.
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const R = "[REDACTED]";
const LABEL = /(secret|key|password|passwd|token|jwt)/i;

// Valores exatos conhecidos em runtime (variáveis do processo com nome sensível).
export function knownSecretValues(env = process.env) {
  return Object.entries(env)
    .filter(([k, v]) => /(KEY|SECRET|PASSWORD|TOKEN)/i.test(k) && typeof v === "string" && v.length >= 8)
    .map(([, v]) => v)
    .sort((a, b) => b.length - a.length);
}

export function redact(text, secrets = knownSecretValues()) {
  let n = 0;
  const sub = (s, rx, rep) => s.replace(rx, (...m) => { n++; return typeof rep === "function" ? rep(...m) : rep; });
  let out = text;
  for (const v of secrets) {
    if (out.includes(v)) { n += out.split(v).length - 1; out = out.split(v).join(R); }
  }
  out = sub(out, /eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+/g, R);
  out = sub(out, /eyJ[A-Za-z0-9_-]{16,}/g, R);
  out = sub(out, /\bsb_(secret|publishable)_[A-Za-z0-9_-]+/g, (_m, kind) => `sb_${kind}_${R}`);
  out = sub(out, /(postgres(?:ql)?:\/\/[^:\/\s@]+:)(?!\*\*\*@)([^@\s]+)@/g, (_m, pre) => `${pre}***@`);
  // Tabelas do Supabase CLI: "│ Secret │ <valor> │" / "| S3 Access Key | <valor> |".
  out = out.split("\n").map((line) => {
    const sep = line.includes("│") ? "│" : (/^\s*\|.*\|\s*$/.test(line) ? "|" : null);
    if (!sep) return line;
    const cells = line.split(sep);
    const idx = cells.findIndex((c) => LABEL.test(c) && c.trim().length > 0 && c.trim().length <= 40);
    if (idx < 0) return line;
    let changed = false;
    for (let i = idx + 1; i < cells.length; i++) {
      if (cells[i].trim() && !cells[i].includes(R)) {
        const pad = cells[i].match(/^\s*/)[0];
        cells[i] = `${pad}${R} `; changed = true;
      }
    }
    if (changed) n++;
    return cells.join(sep);
  }).join("\n");
  // Formas "NOME_KEY=valor", "anon key: valor", "JWT secret: valor".
  out = sub(out, /\b([A-Z0-9_]*(?:KEY|SECRET|PASSWORD|TOKEN)[A-Z0-9_]*)=(?!\[REDACTED\]|\*\*\*)("[^"]*"|'[^']*'|\S+)/g, (_m, k) => `${k}=${R}`);
  out = sub(out, /\b((?:anon|service[_ ]role|publishable|secret|jwt|s3[ \w]*?|access)[ _-]?(?:key|secret))\s*:\s*(?!\[REDACTED\]|\*\*\*)(\S+)/gi, (_m, k) => `${k}: ${R}`);
  return { text: out, count: n };
}

const isMain = process.argv[1] && /[\\/]redact-log\.mjs$/.test(process.argv[1]);
// Lê um arquivo KEY="valor" (ex.: `supabase status -o env`) e devolve os valores sensíveis.
export function secretsFromEnvFile(path) {
  const env = {};
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^([A-Z0-9_]+)="?([^"]*)"?\s*$/);
    if (m) env[m[1]] = m[2];
  }
  return knownSecretValues(env);
}

if (isMain) {
  const args = process.argv.slice(2);
  let extra = [];
  if (args[0] === "--secrets-env") {
    try { extra = secretsFromEnvFile(args[1]); } catch { extra = []; }
    args.splice(0, 2);
  }
  const secretsAll = [...new Set([...extra, ...knownSecretValues()])].sort((a, b) => b.length - a.length);
  if (args[0] === "--in-place") {
    const dir = args[1];
    let total = 0, filesTouched = 0;
    let entries = [];
    try { entries = readdirSync(dir); } catch { entries = []; }
    for (const name of entries.filter((x) => /\.(xml|txt)$/.test(x))) {
      const p = join(dir, name);
      if (!statSync(p).isFile()) continue;
      const { text, count } = redact(readFileSync(p, "utf8"), secretsAll);
      if (count) { writeFileSync(p, text); total += count; filesTouched++; console.log(`KORA-STG REDACT: ${name}: ${count} ocorrência(s) redigida(s)`); }
    }
    console.log(`KORA-STG REDACT: arquivos=${entries.length} alterados=${filesTouched} ocorrências=${total}`);
    process.exit(total ? 3 : 0);
  } else if (args[0]) {
    const { text, count } = redact(readFileSync(args[0], "utf8"), secretsAll);
    process.stdout.write(text.endsWith("\n") ? text : `${text}\n`);
    console.log(`KORA-STG REDACT: ${count} ocorrência(s) redigida(s) na saída acima`);
  } else {
    console.error("uso: redact-log.mjs <arquivo> | --in-place <dir>");
    process.exit(2);
  }
}
