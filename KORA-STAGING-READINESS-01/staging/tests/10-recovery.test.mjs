// SEC-10 — Recuperação após falhas.
//  10-01/10-02 REAL: atomicidade transacional do RPC de envio (falha no meio -> nada parcial)
//               e reenvio bem-sucedido após a falha.
//  10-03 REAL: erro de rede no cliente (porta fechada) não deixa efeito colateral no servidor.
//  Reinício do Postgres e reprovisionamento: scripts/recovery-restart.sh e
//  scripts/reprovision-check.sh (REAL, no runner). Backup/restore do ambiente HOSPEDADO:
//  NÃO COBERTO (ver MATRIZ-TESTES-SEGURANCA.md).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createClient } from "@supabase/supabase-js";
import { ids, as, ok, expectRows, expectRpcError } from "./lib/harness.mjs";

let tentativa;

test("SEC-10-01 envio com questão inválida no meio falha por inteiro (sem respostas parciais)", async () => {
  const b = await as("alunoB1");
  tentativa = ok(await b.rpc("iniciar_tentativa_avaliacao", { p_avaliacao_id: ids.avaliacao("B1_fluxo"), p_matricula_id: ids.matricula("alunoB1") }), "iniciar B1").id;
  expectRpcError(await b.rpc("enviar_tentativa_avaliacao", { p_tentativa_id: tentativa, p_respostas: [
    { questao_id: ids.questao("B_obj"), alternativa_id: "b" },
    { questao_id: ids.questao("A_obj"), alternativa_id: "b" }, // questão de outro tenant/prova
  ] }), "Questão inválida", "envio com questão estranha");
  const pb = await as("profB1");
  const rs = await pb.from("avaliacao_respostas").select("id").eq("tentativa_id", tentativa);
  assert.ok(!rs.error);
  assert.equal(rs.data.length, 0, "resposta parcial persistida após falha");
  const t = expectRows(await b.from("avaliacao_tentativas").select("situacao,nota").eq("id", tentativa), 1, "tentativa")[0];
  assert.equal(t.situacao, "em_andamento");
  assert.equal(t.nota, null);
});

test("SEC-10-02 após a falha, o reenvio válido conclui com estado consistente", async () => {
  const b = await as("alunoB1");
  const r = ok(await b.rpc("enviar_tentativa_avaliacao", { p_tentativa_id: tentativa, p_respostas: [
    { questao_id: ids.questao("B_obj"), alternativa_id: "b" },
    { questao_id: ids.questao("B_diss"), resposta_texto: "Resposta sintética B1" },
  ] }), "reenvio válido");
  assert.equal(r.situacao, "enviada");
  assert.equal(Number(r.nota), 2);
});

test("SEC-10-03 falha de rede do cliente não produz efeito no servidor", async () => {
  const broken = createClient("http://127.0.0.1:9", process.env.KORA_STG_ANON_KEY, { auth: { persistSession: false } });
  const r = await broken.rpc("iniciar_tentativa_avaliacao", { p_avaliacao_id: ids.avaliacao("B1_fluxo"), p_matricula_id: ids.matricula("alunoB1") });
  assert.ok(r.error, "chamada sem rede não falhou");
  const b = await as("alunoB1");
  const all = expectRows(await b.from("avaliacao_tentativas").select("id").eq("avaliacao_id", ids.avaliacao("B1_fluxo")), 1, "apenas a tentativa original");
  assert.equal(all[0].id, tentativa);
});
