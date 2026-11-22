// SEC-03 — Autorização entre turmas no MESMO tenant (REAL).
// Professor A1 está vinculado somente à Turma A1; Professor A2 somente à Turma A2.
// Testes marcados com H(...) têm falha PREVISTA por inspeção estática das políticas
// (tenant + is_docente() sem vínculo de turma). A asserção continua exigindo o
// comportamento seguro: uma falha aqui é um ACHADO, não um teste a ser relaxado.
import { test, before } from "node:test";
import assert from "node:assert/strict";
import { ids, as, ok, H, expectEmpty, expectRows, expectError, expectNoRowsAffected, RLS_DENIED, RUN_ID } from "./lib/harness.mjs";

let tentativaA2; let respostaDissA2;

before(async () => {
  // Entrega real do alunoA2 na avaliação da Turma A2 (objetiva correta + dissertativa).
  const a2 = await as("alunoA2");
  const t = ok(await a2.rpc("iniciar_tentativa_avaliacao", { p_avaliacao_id: ids.avaliacao("A2_fluxo"), p_matricula_id: ids.matricula("alunoA2") }), "alunoA2 inicia A2_fluxo");
  tentativaA2 = t.id;
  ok(await a2.rpc("enviar_tentativa_avaliacao", { p_tentativa_id: t.id, p_respostas: [
    { questao_id: ids.questao("A_obj"), alternativa_id: "b" },
    { questao_id: ids.questao("A_diss"), resposta_texto: "Resposta sintética A2" },
  ] }), "alunoA2 envia A2_fluxo");
  const pa2 = await as("profA2");
  const rs = expectRows(await pa2.from("avaliacao_respostas").select("id,questao_id").eq("tentativa_id", t.id), 2, "controle profA2 vê respostas A2");
  respostaDissA2 = rs.find((r) => r.questao_id === ids.questao("A_diss")).id;
});

test("SEC-03-01 professor vê somente os próprios vínculos de turma", async () => {
  const p = await as("profA1");
  const rows = expectRows(await p.from("professores_turmas").select("turma_id"), 1, "vínculos profA1");
  assert.equal(rows[0].turma_id, ids.turma("A1"));
});

test("SEC-03-02 professor não cria registro de aula/presença em turma alheia; cria na própria (controle)", async () => {
  const p = await as("profA1");
  expectError(await p.from("registros_aula").insert({ tenant_id: ids.tenant("A"), turma_id: ids.turma("A2"), disciplina_id: ids.disciplina("A"), professor_id: ids.user("profA1") }).select("id"), RLS_DENIED, "registro em A2");
  ok(await p.from("registros_aula").insert({ tenant_id: ids.tenant("A"), turma_id: ids.turma("A1"), disciplina_id: ids.disciplina("A"), professor_id: ids.user("profA1"), observacao: `STG ${RUN_ID}` }).select("id"), "controle registro em A1");
  expectError(await p.from("presencas").insert({ tenant_id: ids.tenant("A"), registro_aula_id: ids.registro("A2"), usuario_id: ids.user("alunoA2"), situacao: "ausente" }).select("id"), RLS_DENIED, "presença em A2");
  expectNoRowsAffected(await p.from("presencas").update({ situacao: "ausente" }).eq("id", ids.presenca("alunoA2")).select("id"), "alterar presença de A2");
});

test("SEC-03-03 professor não publica material/aviso em turma alheia e não lê material de A2", async () => {
  const p = await as("profA1");
  expectError(await p.from("materiais_professor").insert({ tenant_id: ids.tenant("A"), turma_id: ids.turma("A2"), disciplina_id: ids.disciplina("A"), professor_id: ids.user("profA1"), titulo: "STG intrusão" }).select("id"), RLS_DENIED, "material em A2");
  expectError(await p.from("avisos_turma").insert({ tenant_id: ids.tenant("A"), turma_id: ids.turma("A2"), professor_id: ids.user("profA1"), titulo: "STG intrusão" }).select("id"), RLS_DENIED, "aviso em A2");
  expectEmpty(await p.from("materiais_professor").select("id").eq("id", ids.material("A2")), "profA1 lê material A2");
  expectRows(await (await as("profA2")).from("materiais_professor").select("id").eq("id", ids.material("A2")), 1, "controle profA2 material A2");
});

test("SEC-03-04 aluno não vê aviso/material de outra turma do mesmo tenant", async () => {
  const a1 = await as("alunoA1");
  expectEmpty(await a1.from("avisos_turma").select("id").eq("id", ids.aviso("A2")), "alunoA1 aviso A2");
  expectEmpty(await a1.from("materiais_professor").select("id").eq("id", ids.material("A2")), "alunoA1 material A2");
  expectRows(await (await as("alunoA2")).from("avisos_turma").select("id").eq("id", ids.aviso("A2")), 1, "controle alunoA2 aviso A2");
});

test(`SEC-03-05 professor não lê tentativas de turma alheia ${H("H1")}`, async () => {
  const p = await as("profA1");
  expectEmpty(await p.from("avaliacao_tentativas").select("id,nota").eq("id", tentativaA2), "profA1 lê tentativa de A2");
});

test(`SEC-03-06 professor não lê respostas de aluno de turma alheia ${H("H1")}`, async () => {
  const p = await as("profA1");
  expectEmpty(await p.from("avaliacao_respostas").select("id,resposta_texto").eq("tentativa_id", tentativaA2), "profA1 lê respostas de A2");
});

test(`SEC-03-07 professor não corrige resposta de aluno de turma alheia ${H("H1")}`, async () => {
  const p = await as("profA1");
  const r = await p.rpc("corrigir_resposta_avaliacao", { p_resposta_id: respostaDissA2, p_pontos: 0, p_comentario: "STG correção indevida" });
  assert.ok(r.error, "profA1 corrigiu resposta de aluno da Turma A2 (autorização por turma ausente)");
  const pa2 = await as("profA2");
  const after = expectRows(await pa2.from("avaliacao_respostas").select("corrigida,comentario").eq("id", respostaDissA2), 1, "estado da resposta A2");
  assert.notEqual(after[0].comentario, "STG correção indevida", "comentário indevido persistido");
});

test(`SEC-03-08 professor não altera avaliação de turma alheia ${H("H1")}`, async () => {
  const p = await as("profA1");
  expectNoRowsAffected(await p.from("avaliacoes").update({ titulo: "STG hijack" }).eq("id", ids.avaliacao("A2_fluxo")).select("id"), "profA1 altera avaliação A2");
});

test("SEC-03-09 professor do tenant A não alcança turma do tenant B (controle cruzado)", async () => {
  const p = await as("profA1");
  expectEmpty(await p.from("avaliacoes").select("id").eq("id", ids.avaliacao("B1_fluxo")), "profA1 avaliação B1");
  expectError(await p.from("registros_aula").insert({ tenant_id: ids.tenant("B"), turma_id: ids.turma("B1"), professor_id: ids.user("profA1") }).select("id"), RLS_DENIED, "registro em B1");
});

test("SEC-03-10 controle positivo: professor vinculado corrige a própria turma", async () => {
  const pa2 = await as("profA2");
  const r = ok(await pa2.rpc("corrigir_resposta_avaliacao", { p_resposta_id: respostaDissA2, p_pontos: 3, p_comentario: "STG correção legítima" }), "profA2 corrige A2");
  assert.equal(r.situacao, "corrigida");
});
