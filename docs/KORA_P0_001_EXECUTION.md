# KORA P0-001 — Execution Notes

## Baseline

The local baseline was captured before database changes at Git HEAD `160f0f0fac63f4ee3ac283c065e5fa7b04d8ef6f` (`feat: implementa fases 8 a 10 do roadmap`). The Supabase target is `goxaeupwxhbiobvvwnxj`. The pre-flight showed that the administrative migration list was empty before this mission.

## Applied database changes

The first database operation was the idempotent correction of migration 019:

```sql
ALTER TABLE IF EXISTS public.questoes
  ADD COLUMN IF NOT EXISTS resposta_esperada text;

COMMENT ON COLUMN public.questoes.resposta_esperada IS
  'Referência opcional do professor para correção manual de questões dissertativas; não é exibida ao aluno.';
```

The Supabase migration record is `kora_p0_001_add_resposta_esperada` with version `20260825160013`. The live schema validates `text`, nullable, no default, and the expected comment. The live database has one question and the new field is null for that row; no row contents were returned.

The second database operation was the versioned migration `023_kora_p0_001_public_tenant_hardening.sql`, recorded live as `kora_p0_001_public_tenant_hardening`. It creates the slug-scoped RPCs `criar_lead_publico(text, uuid, uuid, text, text, text, text, boolean, text[])` and `listar_cursos_publicos(text)`, removes the direct anonymous INSERT policy on `leads`, revokes anonymous INSERT on `public.leads`, removes the broad anonymous SELECT policy on `cursos`, and revokes anonymous SELECT on `public.cursos`.

## Public tenant contract

The browser must resolve a public tenant using a URL slug, then call the RPCs with that slug. The RPC, not the browser, resolves the active tenant UUID. Course and unit UUIDs are accepted only after the function verifies that they belong to the resolved active tenant. The direct table grants for anonymous users are closed.

The frontend now calls `listar_cursos_publicos(p_tenant_slug)` and `criar_lead_publico(p_tenant_slug, ...)`. The browser no longer sends `tenant_id` as the source of truth for public lead creation.

## Storage contract

The canonical new-upload path is:

```text
{tenant_id}/{curso_id}/{arquivo}
```

This follows the Storage policy convention defined in migration 014. The previous client path used `{tenant_id}/{disciplina_id}/{arquivo}`. New uploads now use `curso.id`; existing objects are not moved, renamed, or deleted. A future migration or controlled maintenance job is required before any legacy object migration is considered.

The buckets remain private. No bucket limits, MIME allowlist, or existing object contents were changed in this mission.

## Reproducible negative checks

The script `scripts/kora-p0-tenant-boundaries.mjs` and package script `npm run test:p0:boundaries` cover:

- anonymous catalog retrieval scoped by Tenant A slug and rejection of direct access to a Tenant B course;
- anonymous direct lead injection into Tenant B being rejected;
- an authenticated Tenant A user being unable to read a Tenant B course or optional Tenant B class;
- an authenticated Tenant A user being unable to sign a Tenant B Storage object;
- optional creation through the scoped lead RPC, enabled only with `KORA_RUN_MUTATING_TESTS=1` and disposable fixtures.

The script does not contain credentials or fixture IDs. It fails closed if required fixtures are missing and does not run a mutating RPC test unless explicitly enabled in the environment.

## Migration tracking strategy

The database did not expose the historical 001–022 sequence through `list_migrations`. The mission did not fabricate that history and did not reapply old migrations. From this point forward, every approved DDL change should be sent through the official migration operation with a unique, descriptive name and captured in the administrative migration list. The repository SQL file and the live migration record should be kept together in the change evidence.

The live list now records the two operations from this mission: `kora_p0_001_add_resposta_esperada` and `kora_p0_001_public_tenant_hardening`. This establishes forward tracking without claiming that old migrations were applied by the same mechanism.

## Edge Function readiness checklist

No Edge Function was deployed in P0-001. Before the next stage, check the following:

| Area | `b2g-api` | `pix-create` | `pix-webhook` |
|---|---|---|---|
| Source present in Git | Yes | Yes | Yes |
| Live registration | Not registered at pre-flight | Not registered at pre-flight | Not registered at pre-flight |
| Imports | `npm:@supabase/supabase-js@2` | Supabase JS + shared Inter helper | Supabase JS |
| Auth | API key header/Bearer | Supabase Bearer session | Token query parameter |
| Tenant isolation | Tenant from API key | Profile/title tenant check | Tenant from matched Pix charge |
| Secrets | Supabase URL + service role | Supabase keys + Banco Inter/mTLS | Webhook token + service role |
| URL/callback | `/functions/v1/b2g-api` | `/functions/v1/pix-create` | HTTPS callback with token |
| Environment | Not deployed | Sandbox first | Sandbox callback first |

Secrets must be confirmed using the secure project mechanism without recording values. Banco Inter credentials and mTLS certificate validity must be checked before any production deployment.

## Validation record

The following checks passed locally:

- `git diff --check`;
- `node --check scripts/kora-p0-tenant-boundaries.mjs`;
- `npm run check:encoding` — 68 text files valid UTF-8;
- package script registration check.

The repository did not contain `node_modules/.bin/oxlint`, so lint was not run and no dependency was installed. The tenant boundary script was not run against live fixtures because no disposable Tenant A/Tenant B credentials and IDs were authorized for automated testing.
