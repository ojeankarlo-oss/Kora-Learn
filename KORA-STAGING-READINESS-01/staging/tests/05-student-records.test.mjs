// SEC-05 — Bloqueio de acesso a registros de outros estudantes + sigilo de gabarito
// + Storage (REAL: PostgREST, RPC e Storage API).
import { test, before } from "node:test";
import assert from "node:assert/strict";
import { ids, as, ok, H, expectEmpty, expectRows, expectRpcError, expectNoRowsAffected, RUN_ID } from "./lib/harness.mjs";

let tentativaSigilo; let iniciarPayload;
const tA = ids.tenant("A"); const tB = ids.tenant("B");
const docPath = `${tA}/${ids.user("alunoA1")}/stg-${RUN_ID}.txt`;

before(async () => {
  const b = await as("alunoA1b");
  iniciarPayload = ok(await b.rpc("iniciar_tentativa_avaliacao", { p_avaliacao_id: ids.avaliacao("A1_sigilo"), p_matricula_id: ids.matricula("alunoA1b") }), "alunoA1b inicia A1_sigilo");
  tentativaSigilo = iniciarPayload.id;
});

test("SEC-05-01 aluno vê apenas a própria matrícula, perfil e presença", async () => {
  const a = await as("alunoA1");
  const m = expectRows(await a.from("matriculas").select("id"), 1, "matrículas visíveis a alunoA1");
  assert.equal(m[0].id, ids.matricula("alunoA1"));
  expectEmpty(await a.from("matriculas").select("id").eq("id", ids.matricula("alunoA1b")), "matrícula do colega");
  const u = expectRows(await a.from("usuarios").select("id"), 1, "usuários visíveis a alunoA1");
  assert.equal(u[0].id, ids.user("alunoA1"));
  expectEmpty(await a.from("presencas").select("id").eq("id", ids.presenca("alunoA1b")), "presença do colega");
  expectRows(await a.from("presencas").select("id").eq("id", ids.presenca("alunoA1")), 1, "controle presença própria");
});

test("SEC-05-02 aluno não lê nem envia tentativa de colega", async () => {
  const a = await as("alunoA1");
  expectEmpty(await a.from("avaliacao_tentativas").select("id").eq("id", tentativaSigilo), "tentativa do colega");
  expectEmpty(await a.from("avaliacao_respostas").select("id").eq("tentativa_id", tentativaSigilo), "respostas do colega");
  expectRpcError(await a.rpc("enviar_tentativa_avaliacao", { p_tentativa_id: tentativaSigilo, p_respostas: [] }), "Tentativa não encontrada", "enviar tentativa alheia");
  expectRpcError(await a.rpc("iniciar_tentativa_avaliacao", { p_avaliacao_id: ids.avaliacao("A1_sigilo"), p_matricula_id: ids.matricula("alunoA1b") }), "Matrícula inválida", "iniciar com matrícula alheia");
  const own = expectRows(await (await as("alunoA1b")).from("avaliacao_tentativas").select("situacao").eq("id", tentativaSigilo), 1, "controle dono");
  assert.equal(own[0].situacao, "em_andamento", "tentativa do colega mudou de estado");
});

test("SEC-05-03 payload de início de prova não contém gabarito", () => {
  const s = JSON.stringify(iniciarPayload);
  assert.ok(!s.includes("_gabarito") && !s.includes("resposta_correta") && !s.includes("gabarito_snapshot"), "payload expõe gabarito");
});

test(`SEC-05-04 aluno não lê o gabarito da própria tentativa em andamento ${H("H7")}`, async () => {
  const b = await as("alunoA1b");
  const r = await b.from("avaliacao_tentativas").select("gabarito_snapshot").eq("id", tentativaSigilo);
  const leaked = !r.error && (r.data ?? []).some((row) => row.gabarito_snapshot && Object.keys(row.gabarito_snapshot).length > 0);
  assert.ok(!leaked, "gabarito_snapshot legível pelo aluno durante a prova (sigilo de avaliação violado)");
});

test(`SEC-05-05 aluno de outra turma não inicia avaliação restrita à Turma A1 ${H("H4")}`, async () => {
  const a2 = await as("alunoA2");
  const avail = ok(await a2.rpc("avaliacoes_disponiveis_aluno"), "lista alunoA2");
  assert.ok(!JSON.stringify(avail).includes(ids.avaliacao("A1_sigilo")), "lista de A2 mostra avaliação de A1");
  const r = await a2.rpc("iniciar_tentativa_avaliacao", { p_avaliacao_id: ids.avaliacao("A1_sigilo"), p_matricula_id: ids.matricula("alunoA2") });
  assert.ok(r.error, "alunoA2 (Turma A2) iniciou avaliação destinada à Turma A1 chamando o RPC diretamente");
});

test("SEC-05-06 aluno não altera nota/situação da própria tentativa nem insere respostas diretamente", async () => {
  const b = await as("alunoA1b");
  expectNoRowsAffected(await b.from("avaliacao_tentativas").update({ nota: 100, situacao: "corrigida" }).eq("id", tentativaSigilo).select("id"), "aluno altera própria nota");
  const ins = await b.from("avaliacao_respostas").insert({ tenant_id: tA, tentativa_id: tentativaSigilo, questao_id: ids.questao("A_obj"), alternativa_id: "b", pontos_obtidos: 2, corrigida: true }).select("id");
  assert.ok(ins.error, "aluno inseriu resposta corrigida diretamente");
});

test("SEC-05-07 Storage documentos: dono grava/lê; colega, outro tenant e caminhos forjados são negados", async () => {
  const a1 = await as("alunoA1");
  const body = new Blob([`STG documento sintético ${RUN_ID}`], { type: "text/plain" });
  ok(await a1.storage.from("documentos").upload(docPath, body, { upsert: false }), "upload próprio");
  ok(await a1.storage.from("documentos").download(docPath), "download próprio");
  assert.ok((await (await as("alunoA1b")).storage.from("documentos").download(docPath)).error, "colega baixou documento");
  assert.ok((await (await as("gestorB")).storage.from("documentos").download(docPath)).error, "gestor B baixou documento de A");
  assert.ok((await (await as("profA1")).storage.from("documentos").download(docPath)).error, "professor baixou documento pessoal do aluno");
  ok(await (await as("gestorA")).storage.from("documentos").download(docPath), "controle gestorA (staff do tenant)");
  assert.ok((await a1.storage.from("documentos").upload(`${tA}/${ids.user("alunoA1b")}/forjado-${RUN_ID}.txt`, body)).error, "upload na pasta do colega");
  assert.ok((await a1.storage.from("documentos").upload(`${tB}/${ids.user("alunoA1")}/forjado-${RUN_ID}.txt`, body)).error, "upload na pasta de outro tenant");
  const signed = await (await as("alunoA1b")).storage.from("documentos").createSignedUrl(docPath, 60);
  assert.ok(signed.error || !signed.data?.signedUrl, "colega gerou URL assinada");
});

test("SEC-05-08 Storage conteudo-cursos: staff do tenant grava; aluno matriculado lê; outro tenant não", async () => {
  const path = `${tA}/${ids.curso("A")}/stg-${RUN_ID}.txt`;
  const g = await as("gestorA");
  ok(await g.storage.from("conteudo-cursos").upload(path, new Blob(["STG conteúdo"], { type: "text/plain" })), "gestorA grava conteúdo");
  ok(await (await as("alunoA1")).storage.from("conteudo-cursos").download(path), "aluno matriculado lê");
  assert.ok((await (await as("alunoB1")).storage.from("conteudo-cursos").download(path)).error, "aluno de B leu conteúdo de A");
  assert.ok((await (await as("alunoA1")).storage.from("conteudo-cursos").upload(`${tA}/${ids.curso("A")}/aluno-${RUN_ID}.txt`, new Blob(["x"]))).error, "aluno gravou conteúdo de curso");
});
