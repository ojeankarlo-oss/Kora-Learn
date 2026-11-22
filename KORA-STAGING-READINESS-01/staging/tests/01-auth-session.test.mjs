// SEC-01 — Autenticação e sessão (REAL: GoTrue + PostgREST do stack descartável).
import { test } from "node:test";
import assert from "node:assert/strict";
import { M, ids, as, anon, newClient, signUp, RUN_ID, ok, expectEmpty, expectRows, expectRpcError, expectNoRowsAffected } from "./lib/harness.mjs";

const PASSWORD = process.env.KORA_STG_FIXTURE_PASSWORD;

test("SEC-01-01 login válido retorna sessão e identidade correta", async () => {
  const c = await as("alunoA1");
  const { data } = await c.auth.getUser();
  assert.equal(data.user.email, M.users.alunoA1.email);
  const perfil = expectRows(await c.from("usuarios").select("id,tenant_id,perfil").eq("auth_user_id", data.user.id), 1, "perfil próprio");
  assert.equal(perfil[0].id, ids.user("alunoA1"));
  assert.equal(perfil[0].tenant_id, ids.tenant("A"));
});

test("SEC-01-02 senha incorreta é rejeitada sem sessão", async () => {
  const c = newClient();
  const { data, error } = await c.auth.signInWithPassword({ email: M.users.alunoA1.email, password: `${PASSWORD}x` });
  assert.ok(error, "login com senha errada foi aceito");
  assert.equal(data.session, null);
});

test("SEC-01-03 anon não lê dados acadêmicos (com controle positivo)", async () => {
  const a = anon();
  for (const table of ["usuarios", "matriculas", "turmas", "avaliacoes", "avaliacao_tentativas", "presencas"]) {
    expectEmpty(await a.from(table).select("id").limit(5), `anon ${table}`);
  }
  const g = await as("gestorA");
  expectRows(await g.from("matriculas").select("id").eq("tenant_id", ids.tenant("A")), undefined, "controle positivo gestorA matriculas");
});

test("SEC-01-04 JWT adulterado (sub trocado, assinatura original) é rejeitado pela API", async () => {
  const c = await as("alunoA1");
  const { data: { session } } = await c.auth.getSession();
  const [h, p, s] = session.access_token.split(".");
  const payload = JSON.parse(Buffer.from(p, "base64url").toString());
  const victim = await as("alunoB1");
  const { data: { user: vu } } = await victim.auth.getUser();
  payload.sub = vu.id;
  const forged = `${h}.${Buffer.from(JSON.stringify(payload)).toString("base64url")}.${s}`;
  const res = await fetch(`${process.env.KORA_STG_API_URL}/rest/v1/usuarios?select=id`, {
    headers: { apikey: process.env.KORA_STG_ANON_KEY, Authorization: `Bearer ${forged}` },
  });
  assert.equal(res.status, 401, `token adulterado aceito (HTTP ${res.status})`);
});

test("SEC-01-05 JWT com alg=none é rejeitado", async () => {
  const header = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
  const body = Buffer.from(JSON.stringify({ sub: M.users.gestorB.id, role: "authenticated", exp: Math.floor(Date.now() / 1000) + 600 })).toString("base64url");
  const res = await fetch(`${process.env.KORA_STG_API_URL}/rest/v1/usuarios?select=id`, {
    headers: { apikey: process.env.KORA_STG_ANON_KEY, Authorization: `Bearer ${header}.${body}.` },
  });
  assert.equal(res.status, 401, `alg=none aceito (HTTP ${res.status})`);
});

test("SEC-01-06 logout global invalida o refresh token", async (t) => {
  const c = newClient();
  const { data, error } = await c.auth.signInWithPassword({ email: M.users.profA2.email, password: PASSWORD });
  assert.ok(!error);
  const refresh = data.session.refresh_token;
  const access = data.session.access_token;
  assert.ok(!(await c.auth.signOut({ scope: "global" })).error);
  const reuse = newClient();
  const r = await reuse.auth.refreshSession({ refresh_token: refresh });
  assert.ok(r.error, "refresh token reutilizado após logout");
  // Observação (não PASS/FAIL): access token JWT é stateless até expirar.
  const probe = await fetch(`${process.env.KORA_STG_API_URL}/rest/v1/usuarios?select=id&limit=1`, {
    headers: { apikey: process.env.KORA_STG_ANON_KEY, Authorization: `Bearer ${access}` },
  });
  t.diagnostic(`OBS SEC-01-06: access token pós-logout HTTP ${probe.status} (validade residual até exp do JWT)`);
});

test("SEC-01-07 usuário inativo autentica no Auth mas não obtém autoridade acadêmica", async () => {
  const c = await as("inativoA");
  expectEmpty(await c.from("turmas").select("id"), "inativo turmas");
  expectEmpty(await c.from("matriculas").select("id"), "inativo matriculas");
  const r = await c.rpc("criar_convite_vinculo", { p_usuario_id: ids.user("pendenteA") });
  assert.ok(r.error, "inativo emitiu convite");
  const positive = await as("alunoA1");
  expectRows(await positive.from("turmas").select("id").eq("id", ids.turma("A1")), 1, "controle positivo alunoA1 turma A1");
});

test("SEC-01-08 vínculo por convite: emissão por gestor do tenant, uso único, e-mail exigido", async () => {
  const gb = await as("gestorB");
  assert.ok((await gb.rpc("criar_convite_vinculo", { p_usuario_id: ids.user("pendenteA") })).error, "gestor B emitiu convite para usuário do tenant A");
  const ga = await as("gestorA");
  const token = ok(await ga.rpc("criar_convite_vinculo", { p_usuario_id: ids.user("pendenteA") }), "gestorA emite convite");
  assert.equal(String(token).length, 64);

  // Identidade com e-mail diferente não consegue usar o convite.
  const intruder = await signUp(`intruso-${RUN_ID}@kora-staging.invalid`);
  expectRpcError(await intruder.client.rpc("vincular_minha_conta", { p_convite: token }), "cadastro ausente ou ambiguo", "convite com e-mail divergente");

  const legit = await signUp(M.users.pendenteA.email);
  assert.equal(ok(await legit.client.rpc("vincular_minha_conta", { p_convite: token }), "vínculo legítimo"), true);
  const me = expectRows(await legit.client.from("usuarios").select("id,tenant_id,perfil").eq("auth_user_id", legit.user.id), 1, "perfil vinculado");
  assert.equal(me[0].id, ids.user("pendenteA"));

  const second = await signUp(`reuso-${RUN_ID}@kora-staging.invalid`);
  expectRpcError(await second.client.rpc("vincular_minha_conta", { p_convite: token }), "convite invalido", "reuso de convite consumido");
});

test("SEC-01-09 autocadastro cria escola isolada (tenant C) sem acesso a A/B; repetição bloqueada", async () => {
  const c = await signUp(`gestor-c-${RUN_ID}@kora-staging.invalid`);
  const status = ok(await c.client.rpc("meu_status_onboarding"), "status onboarding");
  assert.equal(status.tem_tenant, false);
  expectEmpty(await c.client.from("turmas").select("id"), "sem tenant: turmas");
  const created = ok(await c.client.rpc("criar_minha_escola", { p_nome_escola: "Escola Sintética C", p_slug: `kora-stg-c-${RUN_ID}`, p_nome_gestor: "Gestor C Sintético" }), "criar escola C");
  assert.ok(created.tenant_id && created.tenant_id !== ids.tenant("A") && created.tenant_id !== ids.tenant("B"));
  for (const t of ["A", "B"]) {
    expectEmpty(await c.client.from("turmas").select("id").eq("tenant_id", ids.tenant(t)), `gestor C turmas de ${t}`);
    expectEmpty(await c.client.from("usuarios").select("id").eq("tenant_id", ids.tenant(t)), `gestor C usuarios de ${t}`);
    expectNoRowsAffected(await c.client.from("tenants").update({ nome: "hijack" }).eq("id", ids.tenant(t)).select("id"), `gestor C altera tenant ${t}`);
  }
  const again = await c.client.rpc("criar_minha_escola", { p_nome_escola: "Escola C2", p_slug: `kora-stg-c2-${RUN_ID}`, p_nome_gestor: "Gestor C" });
  expectRpcError(again, "já está vinculado", "segunda escola para o mesmo login");
});
