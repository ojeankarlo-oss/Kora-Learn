# SC004 R5.8 — patch A: disposable dblink authentication

Base: d35fdaac8f270b337764571756d3c0b7fe0c6287. Environment-only patch; no migration or product change.

The run 38780264393 failed before concurrent submission with 2F003. The runner now prepends a narrow HBA rule for kora_ci/postgres/127.0.0.1 requiring SCRAM, leaving image defaults and roles intact. It records ordered HBA inventories before/after, rejects parser errors and wrong precedence, reloads, and tests new connections: no password and wrong password must fail for their expected authentication reasons, then the random password must connect. A separate SQL preflight proves dblink itself connects as the same non-superuser before the existing A/B/CD contract runs.

The fixture password stays random and environment-injected. Server statement, duration and audit logging are disabled for secret setup and subsequent postgres fixture sessions in this disposable instance; psql result logs and authentication outcomes remain. Credential conninfo and raw connection failure diagnostics are never emitted by the new preflight. Container logs retain the existing final redaction defense. The HBA export omits authentication options; the SCRAM verifier is checked only as a boolean, never printed. No dblink_connect_u, superuser promotion, role membership change, host port, external network or real credential is introduced.

Static checks: node tests/school/verify-sc004-r58.mjs; node tests/school/verify-sc004-auth-acl.mjs; bash -n tests/school/run-sc004-r58.sh; bash -n tests/school/configure-sc004-scram.sh. These do not execute PostgreSQL. Existing A/B and C/D SQL remain byte-identical to the frozen base, including SERIALIZED and DENY expectations, F1/F2 and M20 INVALID.

Runtime pending separate authorization on Ubuntu with the pinned image. Required evidence: hba-before.csv, hba-after.csv, auth-preflight.log with both negative probes and positive connection, SC004_DBLINK_AUTH PASS, non-superuser identity, two distinct submission backends, observed overlap, one submission success and one lifecycle denial, final academic state, and full A/B/autotest/C/D exports. No runtime PASS is claimed here.

PostgreSQL 15 references: https://www.postgresql.org/docs/15/view-pg-hba-file-rules.html (file contents alone do not prove loaded state); https://www.postgresql.org/docs/15/contrib-dblink-connect.html (password-authenticated connection required for non-superusers). Active negative and dblink probes supplement the file checks.
