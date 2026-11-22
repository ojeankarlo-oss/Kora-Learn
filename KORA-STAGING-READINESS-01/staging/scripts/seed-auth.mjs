// KORA-STAGING-READINESS-01 — cria usuários Auth sintéticos (idempotente).
// Requer: KORA_STG_API_URL, KORA_STG_SERVICE_ROLE_KEY (chave LOCAL do stack
// descartável), KORA_STG_FIXTURE_PASSWORD (gerada por execução, mascarada no CI).
// Nunca imprime chaves ou senhas.
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";
import { assertSafeTarget } from "./guard.mjs";

assertSafeTarget();
for (const name of ["KORA_STG_SERVICE_ROLE_KEY", "KORA_STG_FIXTURE_PASSWORD"]) {
  if (!process.env[name]) throw new Error(`KORA-STG SEED: variável ausente ${name}`);
}
if (process.env.KORA_STG_FIXTURE_PASSWORD.length < 16) throw new Error("KORA-STG SEED: senha de fixture curta demais");

const manifest = JSON.parse(readFileSync(new URL("../fixtures/fixture-manifest.json", import.meta.url), "utf8"));
const domain = `@${manifest.emailDomain}`;
const admin = createClient(process.env.KORA_STG_API_URL, process.env.KORA_STG_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function listAllUsers() {
  const users = [];
  for (let page = 1; ; page += 1) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw new Error(`KORA-STG SEED: listUsers falhou (${error.status ?? error.code})`);
    users.push(...data.users);
    if (data.users.length < 200) return users;
  }
}

// Fail-closed: qualquer usuário fora do domínio sintético bloqueia o seed.
const existing = await listAllUsers();
const foreign = existing.filter((u) => !String(u.email || "").endsWith(domain));
if (foreign.length) {
  throw new Error(`KORA-STG SEED ABORT: alvo contém ${foreign.length} usuário(s) Auth não sintético(s)`);
}

const byEmail = new Map(existing.map((u) => [u.email, u]));
let created = 0;
let updated = 0;
for (const [alias, user] of Object.entries(manifest.users)) {
  if (!user.auth) continue;
  if (!user.email.endsWith(domain)) throw new Error(`KORA-STG SEED: e-mail fora do domínio sintético (${alias})`);
  const current = byEmail.get(user.email);
  if (current) {
    const { error } = await admin.auth.admin.updateUserById(current.id, {
      password: process.env.KORA_STG_FIXTURE_PASSWORD,
      email_confirm: true,
    });
    if (error) throw new Error(`KORA-STG SEED: updateUser ${alias} falhou (${error.status ?? error.code})`);
    updated += 1;
  } else {
    const { error } = await admin.auth.admin.createUser({
      email: user.email,
      password: process.env.KORA_STG_FIXTURE_PASSWORD,
      email_confirm: true,
      user_metadata: { kora_stg: true, alias },
    });
    if (error) throw new Error(`KORA-STG SEED: createUser ${alias} falhou (${error.status ?? error.code})`);
    created += 1;
  }
}
console.log(`KORA-STG SEED AUTH: OK created=${created} updated=${updated}`);
