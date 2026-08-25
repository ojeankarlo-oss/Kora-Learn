import { createClient } from "@supabase/supabase-js";

const required = [
  "KORA_TEST_SUPABASE_URL",
  "KORA_TEST_SUPABASE_ANON_KEY",
  "KORA_TEST_TENANT_A_SLUG",
  "KORA_TEST_TENANT_B_ID",
  "KORA_TEST_COURSE_B_ID",
  "KORA_TEST_TENANT_A_EMAIL",
  "KORA_TEST_TENANT_A_PASSWORD",
];
const missing = required.filter((name) => !process.env[name]);
if (missing.length) {
  throw new Error(`Defina fixtures de teste antes de executar: ${missing.join(", ")}`);
}

const supabaseUrl = process.env.KORA_TEST_SUPABASE_URL;
const anonKey = process.env.KORA_TEST_SUPABASE_ANON_KEY;
const tenantASlug = process.env.KORA_TEST_TENANT_A_SLUG;
const tenantBId = process.env.KORA_TEST_TENANT_B_ID;
const courseBId = process.env.KORA_TEST_COURSE_B_ID;
const client = createClient(supabaseUrl, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });

function assert(condition, message) {
  if (!condition) throw new Error(`FAIL: ${message}`);
  console.log(`PASS: ${message}`);
}

function isExpectedDenied(error) {
  const status = error?.status ?? error?.statusCode;
  const code = error?.code;
  const message = String(error?.message ?? "").toLowerCase();
  return status === 401 || status === 403 || code === "42501" || message.includes("permission denied") || message.includes("row-level security") || message.includes("not found");
}

function assertForbiddenOrEmpty({ data, error }, message) {
  if (!error && (data ?? []).length === 0) {
    assert(true, message);
    return;
  }
  if (error && isExpectedDenied(error)) {
    assert(true, message);
    return;
  }
  if (!error && (data ?? []).length > 0) {
    assert(false, `${message} — acesso indevido: dados retornados`);
    return;
  }
  assert(false, `${message} — erro inesperado de infraestrutura/autorização: ${error?.code ?? error?.status ?? error?.statusCode ?? "desconhecido"}`);
}

async function testAnonCatalog() {
  const { data, error } = await client.rpc("listar_cursos_publicos", { p_tenant_slug: tenantASlug });
  if (error) throw error;
  assert(!data.some((course) => course.id === courseBId), "anon não lista curso do Tenant B no catálogo do Tenant A");

  const { data: directB, error: directError } = await client
    .from("cursos")
    .select("id")
    .eq("id", courseBId)
    .limit(1);
  assertForbiddenOrEmpty({ data: directB, error: directError }, "anon não lê diretamente curso do Tenant B");
}

async function testAnonLeadInjectionDenied() {
  const { data, error } = await client.from("leads").insert({
    tenant_id: tenantBId,
    nome: "KORA P0 negative test",
    email: "p0-negative-test@example.invalid",
    origem: "test",
  });
  assert(!data && !!error && isExpectedDenied(error), "anon não injeta lead diretamente em Tenant B");
}

async function testAuthenticatedBoundary() {
  const { error: authError } = await client.auth.signInWithPassword({
    email: process.env.KORA_TEST_TENANT_A_EMAIL,
    password: process.env.KORA_TEST_TENANT_A_PASSWORD,
  });
  if (authError) throw authError;

  const { data: courseB, error: courseError } = await client
    .from("cursos")
    .select("id")
    .eq("id", courseBId)
    .limit(1);
  assertForbiddenOrEmpty({ data: courseB, error: courseError }, "usuário do Tenant A não lê curso do Tenant B");

  if (process.env.KORA_TEST_TURMA_B_ID) {
    const { data: turmaB, error: turmaError } = await client
      .from("turmas")
      .select("id")
      .eq("id", process.env.KORA_TEST_TURMA_B_ID)
      .limit(1);
    assertForbiddenOrEmpty({ data: turmaB, error: turmaError }, "usuário do Tenant A não lê turma do Tenant B");
  }

  if (process.env.KORA_TEST_FILE_B_PATH) {
    const bucket = process.env.KORA_TEST_FILE_BUCKET || "documentos";
    const { data: signed, error: fileError } = await client.storage
      .from(bucket)
      .createSignedUrl(process.env.KORA_TEST_FILE_B_PATH, 60);
    assert(!signed?.signedUrl && !!fileError && isExpectedDenied(fileError), "usuário do Tenant A não assina arquivo do Tenant B");
  }
}

async function testScopedLeadRpc() {
  if (process.env.KORA_RUN_MUTATING_TESTS !== "1") {
    console.log("SKIP: RPC de criação de lead; defina KORA_RUN_MUTATING_TESTS=1 apenas com fixture descartável.");
    return;
  }
  const { data, error } = await client.rpc("criar_lead_publico", {
    p_tenant_slug: tenantASlug,
    p_curso_id: null,
    p_unidade_id: null,
    p_nome: "KORA P0 scoped test",
    p_email: `p0-scoped-${Date.now()}@example.invalid`,
    p_telefone: null,
    p_origem: "test",
    p_tem_necessidade_especifica: false,
    p_necessidades_especificas: null,
  });
  if (error) throw error;
  assert(!!data, "RPC de lead resolve o tenant pelo slug");
}

await testAnonCatalog();
await testAnonLeadInjectionDenied();
await testAuthenticatedBoundary();
await testScopedLeadRpc();
console.log("KORA P0 tenant boundary checks concluídos.");
