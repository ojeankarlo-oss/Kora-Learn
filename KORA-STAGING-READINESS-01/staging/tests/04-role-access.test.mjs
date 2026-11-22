// SEC-04 — Controle de acesso por perfil (REAL).
import { test } from "node:test";
import assert from "node:assert/strict";
import { M, ids, as, ok, expectEmpty, expectRows, expectError, expectNoRowsAffected, RLS_DENIED, RUN_ID } from "./lib/harness.mjs";

test("SEC-04-01 aluno não cria entidades acadêmicas", async () => {
  const a = await as("alunoA1");
  const A = ids.tenant("A");
  expectError(await a.from("cursos").insert({ tenant_id: A, nome: "STG aluno" }).select("id"), RLS_DENIED, "aluno cria curso");
  expectError(await a.from("turmas").insert({ tenant_id: A, curso_id: ids.curso("A"), nome: "STG aluno" }).select("id"), RLS_DENIED, "aluno cria turma");
  expectError(await a.from("avaliacoes").insert({ tenant_id: A, curso_id: ids.curso("A"), disciplina_id: ids.disciplina("A"), titulo: "STG aluno" }).select("id"), RLS_DENIED, "aluno cria avaliação");
  expectError(await a.from("matriculas").insert({ tenant_id: A, usuario_id: ids.user("alunoA1"), curso_id: ids.curso("A"), turma_id: ids.turma("A2") }).select("id"), RLS_DENIED, "aluno se matricula em A2");
  expectError(await a.from("professores_turmas").insert({ tenant_id: A, usuario_id: ids.user("alunoA1"), turma_id: ids.turma("A1") }).select("id"), RLS_DENIED, "aluno se vincula como professor");
});

test("SEC-04-02 aluno não eleva o próprio perfil, tenant, unidade ou estado ativo", async () => {
  const a = await as("alunoA1");
  for (const patch of [{ perfil: "gestor" }, { perfil: "super_admin" }, { tenant_id: ids.tenant("B") }, { ativo: false }, { unidade_id: M.unidades.B.id }]) {
    const r = await a.from("usuarios").update(patch).eq("id", ids.user("alunoA1")).select("id");
    assert.ok(r.error || (r.data ?? []).length === 0, `aluno alterou ${Object.keys(patch)[0]}`);
  }
  const me = expectRows(await a.from("usuarios").select("perfil,tenant_id,ativo").eq("id", ids.user("alunoA1")), 1, "perfil intacto");
  assert.deepEqual(me[0], { perfil: "aluno", tenant_id: ids.tenant("A"), ativo: true });
  ok(await a.from("usuarios").update({ telefone: `+00 ${RUN_ID}` }).eq("id", ids.user("alunoA1")).select("id"), "controle: campo allowlist (telefone)");
});

test("SEC-04-03 aluno não lê banco de questões nem gabaritos", async () => {
  const a = await as("alunoA1");
  expectEmpty(await a.from("questoes").select("id,resposta_correta"), "aluno lê questoes");
  expectEmpty(await a.from("avaliacoes").select("id"), "aluno lê avaliacoes diretamente");
  expectRows(await (await as("profA1")).from("questoes").select("id").eq("id", ids.questao("A_obj")), 1, "controle professor lê questão");
});

test("SEC-04-04 professor não gerencia matrículas, usuários ou vínculos docentes", async () => {
  const p = await as("profA1");
  const A = ids.tenant("A");
  expectError(await p.from("matriculas").insert({ tenant_id: A, usuario_id: ids.user("alunoA2"), curso_id: ids.curso("A"), turma_id: ids.turma("A1") }).select("id"), RLS_DENIED, "professor matricula aluno");
  expectNoRowsAffected(await p.from("usuarios").update({ perfil: "professor" }).eq("id", ids.user("alunoA1")).select("id"), "professor altera perfil de aluno");
  expectError(await p.from("professores_turmas").insert({ tenant_id: A, usuario_id: ids.user("profA1"), turma_id: ids.turma("A2") }).select("id"), RLS_DENIED, "professor se vincula a A2");
  expectError(await p.from("turmas").insert({ tenant_id: A, curso_id: ids.curso("A"), nome: "STG prof" }).select("id"), RLS_DENIED, "professor cria turma");
  assert.ok((await p.rpc("criar_convite_vinculo", { p_usuario_id: ids.user("pendenteA") })).error, "professor emitiu convite");
});

test("SEC-04-05 gestor administra o próprio tenant dentro do teto (sem super_admin)", async (t) => {
  const g = await as("gestorA");
  const novo = ok(await g.from("usuarios").insert({ tenant_id: ids.tenant("A"), perfil: "aluno", nome: "STG novo", email: `novo-${RUN_ID}@kora-staging.invalid` }).select("id"), "gestor cria usuário")[0];
  ok(await g.from("usuarios").update({ perfil: "professor" }).eq("id", novo.id).select("id"), "gestor altera perfil no tenant");
  const elev = await g.from("usuarios").update({ perfil: "super_admin" }).eq("id", novo.id).select("id");
  assert.ok(elev.error || (elev.data ?? []).length === 0, "gestor promoveu usuário a super_admin");
  expectError(await g.from("usuarios").insert({ tenant_id: ids.tenant("A"), perfil: "super_admin", nome: "STG sa", email: `sa-${RUN_ID}@kora-staging.invalid` }).select("id"), RLS_DENIED, "gestor cria super_admin");
  ok(await g.from("usuarios").delete().eq("id", novo.id).select("id"), "gestor remove usuário de teste");
  t.diagnostic("Delete de usuário pelo gestor é permitido por usuarios_write_staff (FOR ALL) — confirmar regra de produto (soft delete?).");
});

test("SEC-04-06 [decisão de produto] professor pode editar catálogo do tenant inteiro (cursos)", async (t) => {
  // Política cursos_write = tenant + is_docente(). Registrado como OBSERVAÇÃO, não PASS/FAIL,
  // até decisão de produto sobre quem edita catálogo. O valor é restaurado.
  const p = await as("profA1");
  const r = await p.from("cursos").update({ descricao: `STG obs ${RUN_ID}` }).eq("id", ids.curso("A")).select("id");
  t.diagnostic(`OBS SEC-04-06: professor editou curso? ${!r.error && (r.data ?? []).length > 0}`);
  if (!r.error && r.data?.length) await p.from("cursos").update({ descricao: null }).eq("id", ids.curso("A"));
});
