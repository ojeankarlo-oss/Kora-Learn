// SEC-02 — Isolamento entre instituições (REAL via PostgREST/RPC com sessões sintéticas).
import { test } from "node:test";
import assert from "node:assert/strict";
import { ids, as, ok, expectEmpty, expectRows, expectError, expectNoRowsAffected, expectRpcError, RLS_DENIED, RUN_ID } from "./lib/harness.mjs";

const readMatrix = [
  ["tenants", "id", () => ids.tenant("B")],
  ["unidades", "tenant_id", () => ids.tenant("B")],
  ["usuarios", "tenant_id", () => ids.tenant("B")],
  ["cursos", "tenant_id", () => ids.tenant("B")],
  ["disciplinas", "tenant_id", () => ids.tenant("B")],
  ["turmas", "tenant_id", () => ids.tenant("B")],
  ["matriculas", "tenant_id", () => ids.tenant("B")],
  ["professores_turmas", "tenant_id", () => ids.tenant("B")],
  ["questoes", "tenant_id", () => ids.tenant("B")],
  ["avaliacoes", "tenant_id", () => ids.tenant("B")],
];

test("SEC-02-01 gestorA não lê nenhuma entidade do tenant B; gestorB lê as suas (controle)", async () => {
  const ga = await as("gestorA");
  const gb = await as("gestorB");
  for (const [table, col, val] of readMatrix) {
    expectEmpty(await ga.from(table).select("id").eq(col, val()), `gestorA lê ${table} de B`);
    expectRows(await gb.from(table).select("id").eq(col, val()), undefined, `controle gestorB ${table}`);
  }
});

test("SEC-02-02 leitura por ID direto de registro de B retorna vazio para todos os perfis de A", async () => {
  for (const alias of ["gestorA", "profA1", "alunoA1"]) {
    const c = await as(alias);
    expectEmpty(await c.from("turmas").select("id").eq("id", ids.turma("B1")), `${alias} turma B1`);
    expectEmpty(await c.from("matriculas").select("id").eq("id", ids.matricula("alunoB1")), `${alias} matrícula B1`);
    expectEmpty(await c.from("avaliacoes").select("id").eq("id", ids.avaliacao("B1_fluxo")), `${alias} avaliação B1`);
    expectEmpty(await c.from("usuarios").select("id").eq("id", ids.user("alunoB1")), `${alias} usuário B1`);
  }
});

test("SEC-02-03 gestorA não insere registros com tenant_id de B (WITH CHECK)", async () => {
  const ga = await as("gestorA");
  expectError(await ga.from("cursos").insert({ tenant_id: ids.tenant("B"), nome: `STG intrusão ${RUN_ID}` }).select("id"), RLS_DENIED, "curso em B");
  expectError(await ga.from("turmas").insert({ tenant_id: ids.tenant("B"), curso_id: ids.curso("B"), nome: `STG intrusão ${RUN_ID}` }).select("id"), RLS_DENIED, "turma em B");
  expectError(await ga.from("usuarios").insert({ tenant_id: ids.tenant("B"), perfil: "aluno", nome: "STG intruso", email: `intruso-b-${RUN_ID}@kora-staging.invalid` }).select("id"), RLS_DENIED, "usuário em B");
  expectError(await ga.from("matriculas").insert({ tenant_id: ids.tenant("B"), usuario_id: ids.user("alunoB1"), curso_id: ids.curso("B"), turma_id: ids.turma("B1") }).select("id"), RLS_DENIED, "matrícula em B");
});

test("SEC-02-04 gestorA não altera nem exclui registros de B (0 linhas) e B permanece intacto", async () => {
  const ga = await as("gestorA");
  expectNoRowsAffected(await ga.from("turmas").update({ nome: "hijack" }).eq("id", ids.turma("B1")).select("id"), "update turma B1");
  expectNoRowsAffected(await ga.from("usuarios").update({ perfil: "gestor" }).eq("id", ids.user("alunoB1")).select("id"), "update usuário B1");
  expectNoRowsAffected(await ga.from("matriculas").delete().eq("id", ids.matricula("alunoB1")).select("id"), "delete matrícula B1");
  const gb = await as("gestorB");
  const t = expectRows(await gb.from("turmas").select("nome").eq("id", ids.turma("B1")), 1, "B1 intacta");
  assert.equal(t[0].nome, "Turma B1");
  expectRows(await gb.from("matriculas").select("id").eq("id", ids.matricula("alunoB1")), 1, "matrícula B1 intacta");
});

test("SEC-02-05 tenant_id não pode ser migrado de A para B por UPDATE", async () => {
  const ga = await as("gestorA");
  const res = await ga.from("turmas").update({ tenant_id: ids.tenant("B") }).eq("id", ids.turma("A2")).select("id");
  assert.ok(res.error, "turma A2 movida para o tenant B");
  const back = expectRows(await ga.from("turmas").select("tenant_id").eq("id", ids.turma("A2")), 1, "A2 continua em A");
  assert.equal(back[0].tenant_id, ids.tenant("A"));
});

test("SEC-02-06 RPCs não atravessam tenant", async () => {
  const a1 = await as("alunoA1");
  expectRpcError(await a1.rpc("iniciar_tentativa_avaliacao", { p_avaliacao_id: ids.avaliacao("B1_fluxo"), p_matricula_id: ids.matricula("alunoA1") }), "Avaliação não encontrada", "aluno A inicia avaliação B");
  const pa = await as("profA1");
  const r = await pa.rpc("minhas_turmas_professor");
  if (!r.error) assert.ok(!JSON.stringify(r.data).includes(ids.turma("B1")), "minhas_turmas_professor de A expõe turma B1");
  const avail = ok(await a1.rpc("avaliacoes_disponiveis_aluno"), "avaliações disponíveis A1");
  assert.ok(!JSON.stringify(avail).includes(ids.avaliacao("B1_fluxo")), "lista de A1 contém avaliação de B");
});

test("SEC-02-07 catálogo público por slug não vaza cursos do outro tenant", async () => {
  const { anon } = await import("./lib/harness.mjs");
  const c = anon();
  const r = await c.rpc("listar_cursos_publicos", { p_tenant_slug: "kora-stg-escola-alfa" });
  if (r.error) { assert.fail(`listar_cursos_publicos falhou: ${r.error.code} ${r.error.message}`); }
  assert.ok(!JSON.stringify(r.data).includes(ids.curso("B")), "catálogo de A contém curso de B");
});
