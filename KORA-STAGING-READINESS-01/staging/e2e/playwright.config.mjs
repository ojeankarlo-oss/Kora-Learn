// Playwright — UM navegador (Chromium headless), 1 worker, sem vídeo: perfil de baixo
// consumo. O app é servido por `vite preview` com base /Kora-Learn/ apontando ao stack local.
import { defineConfig } from "@playwright/test";
import { assertSafeTarget } from "../scripts/guard.mjs";

assertSafeTarget();

export default defineConfig({
  testDir: ".",
  testMatch: /.*\.spec\.mjs/,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  reporter: [["list"], ["junit", { outputFile: process.env.KORA_STG_E2E_JUNIT || "../reports/junit-e2e.xml" }]],
  use: {
    baseURL: process.env.KORA_STG_APP_URL || "http://127.0.0.1:4173/Kora-Learn/",
    headless: true,
    trace: "retain-on-failure",
    video: "off",
    screenshot: "only-on-failure",
  },
  projects: [{ name: "chromium", use: { browserName: "chromium" } }],
});
