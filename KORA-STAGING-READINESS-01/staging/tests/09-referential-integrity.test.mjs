// SEC-09 — Integridade referencial pelo caminho da API (REAL). Complementa as suítes SQL
// versionadas (tests/school/sql/*), que provam o controle como owner/service_role.
// Exige o CÓDIGO de integridade (23503/23514): um erro RLS (42501) aqui NÃO prova a FK,
// pois o objetivo é mostrar que, mesmo passando no WITH CHECK do próprio tenant, a
// relação cruzada é rejeitada estruturalmente.
import { test } from "node:test";
import assert from "node:assert/strict";
import { ids, as, ok, expectError, expectRows, INTEGRITY_DENIED, RUN_ID } from "./lib/harness.mjs";

const A = ids.tenant("A");

test("SEC-09-01 matrícula do tenant A apontando para turma do tenant B é rejeitada pela FK composta", async () => {
  const g = await as("gestorA");
  expectError(await g.from("matriculas").insert({ tenant_id: A, usuario_id: ids.user("alunoA2"), curso_id: ids.curso("A"), turma_id: ids.turma("B1") }).select("id"), INTEGRITY_DENIED, "matrícula A -> turma B1");
});

test("SEC-09-02 matrícula com aluno do tenant B é rejeitada", async () => {
  const g = await as("gestorA");
  expectError(await g.from("matriculas").insert({ tenant_id: A, usuario_id: ids.user("alunoB1"), curso_id: ids.curso("A"), turma_id: ids.turma("A1") }).select("id"), INTEGRITY_DENIED, "matrícula A com aluno B");
});

test("SEC-09-03 vínculo docente com professor do tenant B é rejeitado", async () => {
  const g = await as("gestorA");
  expectError(await g.from("professores_turmas").insert({ tenant_id: A, usuario_id: ids.user("profB1"), turma_id: ids.turma("A1") }).select("id"), INTEGRITY_DENIED, "profB1 em A1");
});

test("SEC-09-04 turma de A com curso de B é rejeitada; turma válida é aceita (controle)", async () => {
  const g = await as("gestorA");
  expectError(await g.from("turmas").insert({ tenant_id: A, curso_id: ids.curso("B"), nome: `STG cruzada ${RUN_ID}` }).select("id"), INTEGRITY_DENIED, "turma A com curso B");
  const t = ok(await g.from("turmas").insert({ tenant_id: A, curso_id: ids.curso("A"), nome: `STG válida ${RUN_ID}` }).select("id"), "controle turma válida")[0];
  ok(await g.from("turmas").delete().eq("id", t.id).select("id"), "remover turma de controle");
});

test("SEC-09-05 UPDATE de matrícula existente para turma de B é rejeitado e a linha permanece", async () => {
  const g = await as("gestorA");
  expectError(await g.from("matriculas").update({ turma_id: ids.turma("B1") }).eq("id", ids.matricula("alunoA1")).select("id"), INTEGRITY_DENIED, "update matrícula -> B1");
  const m = expectRows(await g.from("matriculas").select("turma_id").eq("id", ids.matricula("alunoA1")), 1, "matrícula intacta")[0];
  assert.equal(m.turma_id, ids.turma("A1"));
});

test("SEC-09-06 avaliação de A com disciplina de B é rejeitada", async () => {
  const p = await as("profA1");
  expectError(await p.from("avaliacoes").insert({ tenant_id: A, curso_id: ids.curso("A"), disciplina_id: ids.disciplina("B"), turma_id: ids.turma("A1"), titulo: `STG cruzada ${RUN_ID}` }).select("id"), INTEGRITY_DENIED, "avaliação A com disciplina B");
});
