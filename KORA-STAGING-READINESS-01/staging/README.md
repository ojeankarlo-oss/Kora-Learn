# KORA staging descartável — harness de homologação escolar

Pacote preparado por KORA-STAGING-READINESS-01 sobre `main` `e84ea018b4bd1be092ea60917c0f0c6ce3a4f618`.
**Nada aqui foi executado contra banco ou API.** Somente `scripts/static-selfcheck.mjs` (offline) foi executado.

```
staging/
  fixtures/fixture-manifest.json   IDs, aliases e e-mails sintéticos (sem senhas)
  fixtures/academic_seed.sql       seed idempotente, aborta se houver dado não sintético
  scripts/guard.mjs                trava de alvo: só localhost; produção sempre negada
  scripts/provision.sh             stack Supabase efêmero + migrations + fixtures (exige confirmação)
  scripts/apply-migrations.sh      aplica supabase/migrations em ordem (somente leitura dos arquivos)
  scripts/seed-auth.mjs            usuários GoTrue sintéticos (admin API do stack LOCAL)
  scripts/verify.sh                executa suítes: api | postrestart | sql
  scripts/recovery-restart.sh      reinicia Postgres e confere persistência
  scripts/reprovision-check.sh     idempotência do seed + destruir/recriar + checksum
  scripts/cleanup.sh               destrói o stack (volumes inclusos)
  scripts/cleanup-remote.sql       limpeza sintética de staging remoto (sem COMMIT automático)
  scripts/static-selfcheck.mjs     autoverificação offline (sintaxe, esquema, guard, segredos)
  tests/01..10-*.test.mjs          suítes de segurança (node:test + supabase-js, API real)
  e2e/                             smoke de UI Playwright 1.64.1 (isolado do package.json raiz)
  workflow/kora-staging-homologation.yml  PROPOSTA de workflow (inativa)
```

Ordem canônica (runner Linux): `provision.sh` → `verify.sh api` → build + e2e →
`recovery-restart.sh` + `verify.sh postrestart` → `reprovision-check.sh` → `verify.sh sql` → `cleanup.sh`.

Cada ambiente provisionado suporta **uma** execução das suítes API (01 consome o convite de
`pendenteA`; 03/05/07/08/10 consomem tentativas únicas). Para repetir, reprovisione.

Testes rotulados `[hipótese estática Hx]` têm falha prevista pela leitura das políticas. Eles
exigem o comportamento seguro; uma falha é achado a corrigir por nova migration, nunca motivo
para relaxar a asserção.

## Revisão KORA-STAGING-PROVISIONING-02 (sobre o ZIP `d6e0d25f…a1`)

- `scripts/scan-bundle.mjs` (novo): falha se o build embutir a ref de produção ou qualquer
  `*.supabase.co`, ou se não contiver a URL do stack local.
- `apply-migrations.sh`: `KORA_STG_EXPECT_LAST_MIGRATION` (baseline = `040`) aborta se o
  diretório canônico tiver outra última migration; `KORA_STG_CANDIDATE_MIGRATION` +
  `KORA_STG_CANDIDATE_SHA256` aplicam UM candidato externo, hash fixado, prefixo seguinte.
- `verify.sh sql`: QA SQL do candidato apenas com `KORA_STG_CANDIDATE_SQL_QA(_SHA256)`.
- Workflow: só `push` em `staging/homologation-**` (sem `workflow_dispatch`), checkout sem
  credencial persistida, rótulo de execução nos artefatos, self-check e varredura do bundle no CI.
- `static-selfcheck.mjs`: +5 verificações do workflow (ativo == proposta, gatilho, checkout,
  identidade, varredura).
