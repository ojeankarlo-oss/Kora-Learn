# KORA Learn Engineering Governance

## Repository workflow

- `main` is canonical. Verify its SHA before beginning a new roadmap slice.
- Work on isolated feature or documentation branches. Do not make implementation commits directly to `main` or force-push it.
- Changes reach `main` through reviewed pull requests. Independent review is required before merge and may be performed by an authorized human reviewer **or** an independent audit agent that did not implement the change; when an audit agent is used, its review evidence must be recorded before merge. An implementer's own PASS is not sufficient. For security-sensitive changes: **implementer != final auditor**. A second GitHub account and a formal GitHub "Approved" review are not required when independent audit evidence is recorded.

## Merge and deployment awareness

`.github/workflows/deploy.yml` can deploy GitHub Pages when changes are pushed or merged into `main`. **Merge is an operational action.** Before merging, verify the PR identity, exact HEAD, authorized file scope, required CI, mergeability, and deployment consequences. “Safe to open PR” does not mean “safe to merge.”

## Database migrations

- Applied or published numbered migrations are immutable. Implement new database behavior in a new numbered migration; never edit an earlier migration for it.
- Later security work may inspect historical migrations. Changing one requires separately approved remediation.

## Multi-tenant security

- Tenant isolation is structural. Never trust tenant identity solely from frontend input; backend and database authorization must validate tenant context.
- Cross-tenant relationships must fail closed. Where relational integrity is required, RLS alone is insufficient. `service_role` and database-owner privileges must not permit structural cross-tenant corruption.
- Never guess or automatically repair tenant ownership in an integrity migration. Ambiguous historical data must block the migration and require explicit remediation.

## Environment safety and secrets

- During audit, local, and CI missions, do not access real Supabase, staging, production, real Asaas, real customer data, or real secrets unless explicitly authorized. Prefer disposable local or CI infrastructure.
- Never commit credentials, tokens, service-role keys, or secrets. Use secure environment injection instead of requesting secrets in prompts or logs, and redact sensitive evidence.

## Local agent configuration

`.kilo` and `.kilo/kilo.jsonc` are local configuration. Keep them outside Git unless a separate reviewed decision explicitly changes this policy.

## Agent separation

- Codex: architecture, repository inspection, security review, and independent audit when assigned.
- Kilo Backend: backend and database implementation.
- Kilo Frontend: frontend implementation.
- Kilo QA: independent read and test validation.

An implementer's own PASS cannot be the sole acceptance evidence. For security-sensitive slices, **implementer != final auditor**.

## Gate model

Audit → scope freeze → implement → independent QA → runtime CI → PR → PR audit → merge → post-merge verification → closed. A PASS at one gate does not authorize later gates.

## KORA Payments boundary

KORA Payments is the payment system-of-record boundary. School modules must not integrate directly with Asaas. Payment providers remain behind KORA Payments and provider adapters. Student and payer are distinct domain concepts; do not couple academic ownership to payer identity.

## Fail-closed behavior

Security uncertainty must not silently reduce protection. Do not weaken a test to obtain PASS, convert NOT RUN into PASS, treat RLS-hidden data as proof of relational integrity, accept an unrelated SQL error as proof of the intended control, or automatically remediate ambiguous tenant ownership.
