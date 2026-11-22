// SEC-08 — Idempotência e concorrência (REAL: requisições HTTP paralelas ao PostgREST).
import { test } from "node:test";
import assert from "node:assert/strict";
import { M, ids, as, newClient, ok, H, expectRows, expectRpcError } from "./lib/harness.mjs";

const PASSWORD = process.env.KORA_STG_FIXTURE_PASSWORD;
async function parallelClients(alias, n) {
  return Promise.all(Array.from({ length: n }, async () => {
    const c = newClient();
    const { error } = await c.auth.signInWithPassword({ email: M.users[alias].email, password: PASSWORD });
    assert.ok(!error, `login paralelo ${alias}`);
    return c;
  }));
}

test("SEC-08-01 início concorrente (5x) com 1 tentativa permitida gera exatamente 1 tentativa", async () => {
  const clients = await parallelClients("alunoA1", 5);
  const results = await Promise.all(clients.map((c) => c.rpc("iniciar_tentativa_avaliacao", { p_avaliacao_id: ids.avaliacao("A1_inicio"), p_matricula_id: ids.matricula("alunoA1") })));
  const success = results.filter((r) => !r.error).length;
  const rows = expectRows(await (await as("alunoA1")).from("avaliacao_tentativas").select("id,numero_tentativa").eq("avaliacao_id", ids.avaliacao("A1_inicio")), undefined, "tentativas criadas");
  assert.equal(rows.length, 1, `tentativas duplicadas: ${rows.length}`);
  assert.equal(success, 1, `${success} inícios aceitos para 1 tentativa permitida`);
});

test("SEC-08-02 reenvio sequencial é rejeitado e não altera a nota", async () => {
  const a = await as("alunoA1");
  const t = expectRows(await a.from("avaliacao_tentativas").select("id").eq("avaliacao_id", ids.avaliacao("A1_inicio")), 1, "tentativa")[0];
  const first = ok(await a.rpc("enviar_tentativa_avaliacao", { p_tentativa_id: t.id, p_respostas: [{ questao_id: ids.questao("A_obj"), alternativa_id: "a" }] }), "primeiro envio");
  assert.equal(Number(first.nota), 0);
  expectRpcError(await a.rpc("enviar_tentativa_avaliacao", { p_tentativa_id: t.id, p_respostas: [{ questao_id: ids.questao("A_obj"), alternativa_id: "b" }] }), "já enviada", "reenvio");
  const after = expectRows(await a.from("avaliacao_tentativas").select("nota").eq("id", t.id), 1, "nota após reenvio")[0];
  assert.equal(Number(after.nota), 0, "reenvio alterou a nota");
});

test(`SEC-08-03 envio concorrente (5x, respostas diferentes) aceita exatamente 1 envio ${H("H3")}`, async () => {
  const owner = await as("alunoA1b");
  const t = ok(await owner.rpc("iniciar_tentativa_avaliacao", { p_avaliacao_id: ids.avaliacao("A1_concorrencia"), p_matricula_id: ids.matricula("alunoA1b") }), "iniciar");
  const clients = await parallelClients("alunoA1b", 5);
  const answers = ["a", "b", "c", "a", "b"];
  const results = await Promise.all(clients.map((c, i) => c.rpc("enviar_tentativa_avaliacao", { p_tentativa_id: t.id, p_respostas: [{ questao_id: ids.questao("A_obj"), alternativa_id: answers[i] }] })));
  const accepted = results.filter((r) => !r.error);
  const final = expectRows(await owner.from("avaliacao_tentativas").select("nota,situacao").eq("id", t.id), 1, "estado final")[0];
  const resp = expectRows(await owner.from("avaliacao_respostas").select("alternativa_id,pontos_obtidos").eq("tentativa_id", t.id), 1, "uma resposta por questão")[0];
  // Invariante de consistência: a nota final corresponde à resposta persistida.
  assert.equal(Number(final.nota), Number(resp.pontos_obtidos), "nota final não corresponde à resposta persistida");
  assert.equal(accepted.length, 1, `${accepted.length} envios concorrentes aceitos (sem bloqueio de linha: último a gravar vence)`);
});

test("SEC-08-04 tentativa além do limite é rejeitada", async () => {
  const a = await as("alunoA1");
  expectRpcError(await a.rpc("iniciar_tentativa_avaliacao", { p_avaliacao_id: ids.avaliacao("A1_inicio"), p_matricula_id: ids.matricula("alunoA1") }), "Limite de tentativas", "nova tentativa além do limite");
});
