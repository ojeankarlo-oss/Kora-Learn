// SEC-07 — Consistência de entregas (tentativas) e avaliações (correção) — REAL.
// Avaliação A1_fluxo: objetiva 2 pts (gabarito "b") + dissertativa 3 pts; nota mínima 60%.
import { test } from "node:test";
import assert from "node:assert/strict";
import { ids, as, ok, H, expectRows, expectRpcError } from "./lib/harness.mjs";

let tentativa; let respostaDiss; let respostaObj;

test("SEC-07-01 avaliação disponível ao aluno da turma e início com nota máxima correta", async () => {
  const a = await as("alunoA1");
  const avail = ok(await a.rpc("avaliacoes_disponiveis_aluno"), "disponíveis");
  assert.ok(JSON.stringify(avail).includes(ids.avaliacao("A1_fluxo")), "A1_fluxo não listada para aluno da Turma A1");
  const t = ok(await a.rpc("iniciar_tentativa_avaliacao", { p_avaliacao_id: ids.avaliacao("A1_fluxo"), p_matricula_id: ids.matricula("alunoA1") }), "iniciar");
  assert.equal(Number(t.nota_maxima), 5);
  assert.equal(t.questoes.length, 2);
  assert.equal(t.situacao, "em_andamento");
  tentativa = t.id;
});

test("SEC-07-02 envio corrige objetiva automaticamente e deixa dissertativa pendente", async () => {
  const a = await as("alunoA1");
  const r = ok(await a.rpc("enviar_tentativa_avaliacao", { p_tentativa_id: tentativa, p_respostas: [
    { questao_id: ids.questao("A_obj"), alternativa_id: "b" },
    { questao_id: ids.questao("A_diss"), resposta_texto: "Resposta sintética A1" },
  ] }), "enviar");
  assert.equal(r.situacao, "enviada");
  assert.equal(Number(r.nota), 2);
  assert.equal(Number(r.pendentes_correcao), 1);
  const rows = expectRows(await (await as("profA1")).from("avaliacao_respostas").select("id,questao_id,pontos_obtidos,corrigida").eq("tentativa_id", tentativa), 2, "respostas persistidas");
  respostaDiss = rows.find((x) => x.questao_id === ids.questao("A_diss")).id;
  respostaObj = rows.find((x) => x.questao_id === ids.questao("A_obj")).id;
});

test("SEC-07-03 correção fora dos limites é rejeitada e não altera estado", async () => {
  const p = await as("profA1");
  expectRpcError(await p.rpc("corrigir_resposta_avaliacao", { p_resposta_id: respostaDiss, p_pontos: 3.5 }), "fora do limite", "pontos acima do máximo");
  expectRpcError(await p.rpc("corrigir_resposta_avaliacao", { p_resposta_id: respostaDiss, p_pontos: -1 }), "fora do limite", "pontos negativos");
  const t = expectRows(await p.from("avaliacao_tentativas").select("nota,situacao").eq("id", tentativa), 1, "tentativa");
  assert.equal(Number(t[0].nota), 2);
  assert.equal(t[0].situacao, "enviada");
});

test("SEC-07-04 correção válida recalcula nota, percentual e aprovação; aluno vê resultado", async () => {
  const p = await as("profA1");
  const r = ok(await p.rpc("corrigir_resposta_avaliacao", { p_resposta_id: respostaDiss, p_pontos: 2.5, p_comentario: "STG bom" }), "corrigir");
  assert.equal(r.situacao, "corrigida");
  assert.equal(Number(r.percentual), 90);
  const a = await as("alunoA1");
  const t = expectRows(await a.from("avaliacao_tentativas").select("nota,percentual,aprovada,situacao").eq("id", tentativa), 1, "aluno vê tentativa");
  assert.deepEqual({ nota: Number(t[0].nota), percentual: Number(t[0].percentual), aprovada: t[0].aprovada, situacao: t[0].situacao },
    { nota: 4.5, percentual: 90, aprovada: true, situacao: "corrigida" });
  const resp = expectRows(await a.from("avaliacao_respostas").select("comentario").eq("id", respostaDiss), 1, "aluno vê comentário");
  assert.equal(resp[0].comentario, "STG bom");
});

test("SEC-07-05 invariante: nota da tentativa = soma das respostas", async () => {
  const p = await as("profA1");
  const t = expectRows(await p.from("avaliacao_tentativas").select("nota").eq("id", tentativa), 1, "tentativa");
  const rs = expectRows(await p.from("avaliacao_respostas").select("pontos_obtidos").eq("tentativa_id", tentativa), 2, "respostas");
  assert.equal(Number(t[0].nota), rs.reduce((s, x) => s + Number(x.pontos_obtidos), 0));
});

test(`SEC-07-06 professor não adultera pontuação por UPDATE direto fora do RPC ${H("H6")}`, async () => {
  const p = await as("profA1");
  const r = await p.from("avaliacao_respostas").update({ pontos_obtidos: 999, alternativa_id: "a" }).eq("id", respostaObj).select("id,pontos_obtidos");
  const tampered = !r.error && (r.data ?? []).length > 0;
  if (tampered) {
    // Restaura para não contaminar evidências seguintes e registra a inconsistência observada.
    await p.from("avaliacao_respostas").update({ pontos_obtidos: 2, alternativa_id: "b" }).eq("id", respostaObj);
  }
  assert.ok(!tampered, "UPDATE direto em avaliacao_respostas aceito: pontuação acima do máximo e resposta do aluno alteradas sem recálculo da nota");
});
