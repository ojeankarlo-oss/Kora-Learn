// E2E-UI — smoke de interface com sessão REAL do stack descartável.
// Escopo: prova que a UI autentica, mantém sessão após recarregar, encerra sessão e não
// renderiza dados do outro tenant nas telas iniciais. NÃO substitui as suítes de API:
// ausência de dado na tela não prova autorização (o controle é provado em tests/0x).
import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

const M = JSON.parse(readFileSync(new URL("../fixtures/fixture-manifest.json", import.meta.url), "utf8"));
const PASSWORD = process.env.KORA_STG_FIXTURE_PASSWORD;
const FORBIDDEN_FOR_A = [M.tenants.B.nome, M.users.alunoB1.nome, M.users.gestorB.nome, "Turma B1", M.cursos.B.nome];

async function login(page, alias) {
  await page.goto("./");
  await expect(page.getByText("Entrar na plataforma")).toBeVisible();
  await page.getByPlaceholder("voce@exemplo.com").first().fill(M.users[alias].email);
  await page.getByPlaceholder("••••••••").fill(PASSWORD);
  await page.getByRole("button", { name: "Entrar", exact: true }).click();
  await expect(page.getByText("Entrar na plataforma")).toBeHidden({ timeout: 20_000 });
}

async function assertNoTenantBText(page) {
  await page.waitForLoadState("networkidle");
  const text = await page.locator("body").innerText();
  for (const s of FORBIDDEN_FOR_A) expect(text, `UI de A exibiu "${s}"`).not.toContain(s);
}

test("E2E-01 aluno A1: login, sessão persiste após reload, sem dados de B", async ({ page }) => {
  test.skip(!PASSWORD, "KORA_STG_FIXTURE_PASSWORD ausente (NOT RUN)");
  await login(page, "alunoA1");
  await expect(page.getByText("Olá, Aluno!")).toBeVisible({ timeout: 20_000 });
  await assertNoTenantBText(page);
  await page.reload();
  await expect(page.getByText("Olá, Aluno!")).toBeVisible({ timeout: 20_000 });
});

test("E2E-02 gestor A: painel sem dados de B; sessão removida volta ao login", async ({ page }) => {
  test.skip(!PASSWORD, "KORA_STG_FIXTURE_PASSWORD ausente (NOT RUN)");
  await login(page, "gestorA");
  await expect(page.getByText("Gestor · Gestor")).toBeVisible({ timeout: 20_000 });
  await assertNoTenantBText(page);
  await page.evaluate(() => { for (const k of Object.keys(localStorage)) if (k.startsWith("sb-")) localStorage.removeItem(k); });
  await page.reload();
  await expect(page.getByText("Entrar na plataforma")).toBeVisible({ timeout: 20_000 });
});

test("E2E-03 senha errada mostra erro e não autentica", async ({ page }) => {
  await page.goto("./");
  await page.getByPlaceholder("voce@exemplo.com").first().fill(M.users.alunoA1.email);
  await page.getByPlaceholder("••••••••").fill("senha-incorreta-STG-000");
  await page.getByRole("button", { name: "Entrar", exact: true }).click();
  await expect(page.getByText("Entrar na plataforma")).toBeVisible();
  await expect(page.getByText("Olá, Aluno!")).toHaveCount(0);
});
