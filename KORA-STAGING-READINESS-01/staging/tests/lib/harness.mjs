// Harness das suítes de segurança KORA-STAGING-READINESS-01.
// Todas as chamadas usam a API REAL (GoTrue + PostgREST + Storage) com a chave anon
// e sessões de usuários sintéticos. A chave service_role NÃO é usada pelos testes.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { createClient } from "@supabase/supabase-js";
import { assertSafeTarget } from "../../scripts/guard.mjs";

assertSafeTarget();
for (const name of ["KORA_STG_API_URL", "KORA_STG_ANON_KEY", "KORA_STG_FIXTURE_PASSWORD"]) {
  if (!process.env[name]) throw new Error(`KORA-STG TEST: variável ausente ${name} (NOT RUN)`);
}

export const M = JSON.parse(readFileSync(new URL("../../fixtures/fixture-manifest.json", import.meta.url), "utf8"));
export const RUN_ID = process.env.KORA_STG_RUN_ID || String(Date.now());
const API_URL = process.env.KORA_STG_API_URL;
const ANON_KEY = process.env.KORA_STG_ANON_KEY;
const PASSWORD = process.env.KORA_STG_FIXTURE_PASSWORD;

export const ids = {
  tenant: (k) => M.tenants[k].id,
  user: (k) => M.users[k].id,
  turma: (k) => M.turmas[k].id,
  curso: (k) => M.cursos[k].id,
  disciplina: (k) => M.disciplinas[k].id,
  matricula: (k) => M.matriculas[k].id,
  avaliacao: (k) => M.avaliacoes[k].id,
  questao: (k) => M.questoes[k].id,
  registro: (k) => M.registrosAula[k].id,
  presenca: (k) => M.presencas[k].id,
  material: (k) => M.materiais[k].id,
  aviso: (k) => M.avisos[k].id,
};

export function newClient() {
  return createClient(API_URL, ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}

export function anon() {
  return newClient();
}

const sessions = new Map();
/** Sessão real via GoTrue (signInWithPassword). Cache por processo/arquivo. */
export async function as(alias) {
  if (sessions.has(alias)) return sessions.get(alias);
  const user = M.users[alias];
  if (!user) throw new Error(`alias desconhecido ${alias}`);
  const client = newClient();
  const { data, error } = await client.auth.signInWithPassword({ email: user.email, password: PASSWORD });
  if (error) throw new Error(`login ${alias} falhou: ${error.status ?? ""} ${error.code ?? error.message}`);
  assert.ok(data.session?.access_token, `sessão ausente para ${alias}`);
  sessions.set(alias, client);
  return client;
}

export async function signUp(email, password = PASSWORD) {
  const client = newClient();
  const { data, error } = await client.auth.signUp({ email, password });
  if (error) throw new Error(`signUp falhou: ${error.status ?? ""} ${error.code ?? error.message}`);
  assert.ok(data.session, "signUp sem sessão: confirme enable_confirmations=false no stack descartável");
  return { client, user: data.user, session: data.session };
}

export const RLS_DENIED = new Set(["42501"]); // insufficient_privilege / RLS with check
export const INTEGRITY_DENIED = new Set(["23503", "23514", "23502"]);

/** Exige ERRO com código esperado. Nunca aceita sucesso silencioso. */
export function expectError(res, codes, label) {
  assert.ok(res.error, `${label}: esperado erro, mas a operação foi aceita (data=${JSON.stringify(res.data)?.slice(0, 200)})`);
  if (codes) {
    assert.ok(codes.has(String(res.error.code)), `${label}: erro com código inesperado ${res.error.code} (${res.error.message}); um erro não relacionado não prova o controle`);
  }
}

/** Exige erro de RPC cuja mensagem contenha o trecho esperado (controle específico). */
export function expectRpcError(res, fragment, label) {
  assert.ok(res.error, `${label}: esperado erro, mas o RPC foi aceito (data=${JSON.stringify(res.data)?.slice(0, 200)})`);
  assert.ok(String(res.error.message).includes(fragment), `${label}: mensagem inesperada "${res.error.message}" (esperado "${fragment}")`);
}

/** Exige sucesso; retorna data. */
export function ok(res, label) {
  assert.ok(!res.error, `${label}: erro inesperado ${res.error?.code} ${res.error?.message}`);
  return res.data;
}

/** UPDATE/DELETE negados por RLS retornam 0 linhas: exige 0 linhas OU erro 42501. */
export function expectNoRowsAffected(res, label) {
  if (res.error) {
    assert.ok(RLS_DENIED.has(String(res.error.code)) || INTEGRITY_DENIED.has(String(res.error.code)) || String(res.error.code) === "P0001",
      `${label}: erro inesperado ${res.error.code} ${res.error.message}`);
    return;
  }
  assert.equal((res.data ?? []).length, 0, `${label}: ${res.data?.length} linha(s) alterada(s) indevidamente`);
}

/** SELECT negado: 0 linhas. SEMPRE combine com um controle positivo do dono. */
export function expectEmpty(res, label) {
  assert.ok(!res.error || RLS_DENIED.has(String(res.error.code)), `${label}: erro inesperado ${res.error?.code} ${res.error?.message}`);
  assert.equal((res.data ?? []).length, 0, `${label}: ${res.data?.length} linha(s) visível(is) indevidamente`);
}

export function expectRows(res, n, label) {
  const data = ok(res, label);
  if (typeof n === "number") assert.equal(data.length, n, `${label}: esperado ${n} linha(s), obtido ${data.length}`);
  else assert.ok(data.length > 0, `${label}: controle positivo sem linhas (fixture ausente => teste inválido)`);
  return data;
}

const STATE_DIR = process.env.KORA_STG_WORKDIR || process.cwd();
export function saveState(name, value) {
  writeFileSync(join(STATE_DIR, `.state-${name}.json`), JSON.stringify(value), { mode: 0o600 });
}
export function loadState(name) {
  const p = join(STATE_DIR, `.state-${name}.json`);
  return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null;
}

/** Rótulo para testes cuja falha foi PREVISTA por inspeção estática (hipótese, não prova). */
export const H = (code) => `[hipótese estática ${code}]`;
