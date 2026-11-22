// SEC-06 — Persistência após nova sessão (REAL) e após reinício do Postgres (REAL, fase 2).
// Fase 1 (padrão): grava, encerra sessão, reabre sessão nova e confere.
// Fase 2 (KORA_STG_PHASE=post-restart): roda após scripts/recovery-restart.sh.
import { test } from "node:test";
import assert from "node:assert/strict";
import { M, ids, newClient, ok, expectRows, saveState, loadState, RUN_ID } from "./lib/harness.mjs";

const PASSWORD = process.env.KORA_STG_FIXTURE_PASSWORD;
const PHASE = process.env.KORA_STG_PHASE || "initial";

async function freshLogin(alias) {
  const c = newClient();
  const { data, error } = await c.auth.signInWithPassword({ email: M.users[alias].email, password: PASSWORD });
  assert.ok(!error, `login ${alias}: ${error?.message}`);
  return { c, session: data.session };
}

if (PHASE === "initial") {
  test("SEC-06-01 dado gravado numa sessão sobrevive a logout e nova sessão", async () => {
    const titulo = `STG persist ${RUN_ID}`;
    const s1 = await freshLogin("profA1");
    const created = ok(await s1.c.from("avisos_turma").insert({ tenant_id: ids.tenant("A"), turma_id: ids.turma("A1"), professor_id: ids.user("profA1"), titulo, tipo: "trabalho" }).select("id,titulo"), "profA1 cria aviso")[0];
    assert.ok(!(await s1.c.auth.signOut({ scope: "global" })).error);

    const s2 = await freshLogin("profA1");
    const again = expectRows(await s2.c.from("avisos_turma").select("id,titulo,tipo").eq("id", created.id), 1, "aviso após nova sessão");
    assert.deepEqual(again[0], { id: created.id, titulo, tipo: "trabalho" });

    const aluno = await freshLogin("alunoA1");
    expectRows(await aluno.c.from("avisos_turma").select("id").eq("id", created.id), 1, "aluno da turma vê aviso persistido");

    const tel = `+00 persist ${RUN_ID}`;
    ok(await aluno.c.from("usuarios").update({ telefone: tel }).eq("id", ids.user("alunoA1")).select("id"), "aluno atualiza telefone");
    const aluno2 = await freshLogin("alunoA1");
    const me = expectRows(await aluno2.c.from("usuarios").select("telefone").eq("id", ids.user("alunoA1")), 1, "telefone persistido");
    assert.equal(me[0].telefone, tel);

    const keep = await freshLogin("gestorA");
    saveState("persistence", { avisoId: created.id, titulo, telefone: tel, refreshToken: keep.session.refresh_token });
  });
} else {
  test("SEC-06-02 após reinício do Postgres: dados, login e refresh token preservados", async () => {
    const st = loadState("persistence");
    assert.ok(st, "estado da fase 1 ausente: rode a fase inicial antes (NOT RUN)");
    const c = newClient();
    const r = await c.auth.refreshSession({ refresh_token: st.refreshToken });
    assert.ok(!r.error && r.data.session, `refresh token emitido antes do reinício falhou: ${r.error?.message}`);
    const aviso = expectRows(await c.from("avisos_turma").select("titulo").eq("id", st.avisoId), 1, "aviso após reinício");
    assert.equal(aviso[0].titulo, st.titulo);
    const a = await freshLogin("alunoA1");
    const me = expectRows(await a.c.from("usuarios").select("telefone").eq("id", ids.user("alunoA1")), 1, "telefone após reinício");
    assert.equal(me[0].telefone, st.telefone);
  });
}
