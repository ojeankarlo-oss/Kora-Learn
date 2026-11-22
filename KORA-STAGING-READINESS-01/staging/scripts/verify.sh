#!/usr/bin/env bash
# Executa as suítes de segurança contra o stack descartável e consolida o resultado.
# Cada suíte roda isoladamente (uma falha não esconde as demais). Sai != 0 se qualquer
# suíte falhar: NOT RUN/falha nunca é convertido em PASS.
#
# Uso: verify.sh api        -> suítes 01..10 (API real: GoTrue + PostgREST + Storage)
#      verify.sh postrestart-> verificação de persistência após reinício do Postgres
#      verify.sh sql        -> suítes SQL versionadas do repo (auth SIMULADA por jwt claim)
set -uo pipefail
PHASE="${1:-api}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="${KORA_STG_REPO_ROOT:-$(git -C "$STG_DIR" rev-parse --show-toplevel)}"
OUT="${KORA_STG_REPORT_DIR:-$STG_DIR/reports}"
mkdir -p "$OUT"
node "$SCRIPT_DIR/guard.mjs" || exit 1

declare -a results=()
fail=0
run_suite() {
  local id="$1"; shift
  echo "::group::$id"
  "$@"; local rc=$?
  echo "::endgroup::"
  if (( rc == 0 )); then results+=("PASS $id"); else results+=("FAIL $id (rc=$rc)"); fail=1; fi
}

case "$PHASE" in
  api)
    for f in "$STG_DIR"/tests/[0-9][0-9]-*.test.mjs; do
      id=$(basename "$f" .test.mjs)
      run_suite "$id" node --test --test-concurrency=1 \
        --test-reporter=spec --test-reporter-destination=stdout \
        --test-reporter=junit --test-reporter-destination="$OUT/junit-$id.xml" "$f"
    done
    ;;
  postrestart)
    run_suite "06-persistence-post-restart" env KORA_STG_PHASE=post-restart node --test \
      --test-reporter=spec --test-reporter-destination=stdout \
      --test-reporter=junit --test-reporter-destination="$OUT/junit-06-post-restart.xml" \
      "$STG_DIR/tests/06-persistence.test.mjs"
    ;;
  sql)
    # Estas suítes inserem fixtures próprias e alteram usuarios (T26). Rodar por último,
    # antes do reprovisionamento que descarta o banco.
    run_suite "sql-session-authority (auth simulada)" psql "$KORA_STG_DB_URL" -v ON_ERROR_STOP=1 -q -f "$REPO_ROOT/tests/school/sql/session_authority_qa.sql"
    run_suite "sql-cross-tenant-integrity (owner/service_role)" psql "$KORA_STG_DB_URL" -v ON_ERROR_STOP=1 -q -f "$REPO_ROOT/tests/school/sql/cross_tenant_academic_integrity_qa.sql"
    # Fase 4 (somente execução candidata): QA SQL do candidato, com SHA-256 fixado.
    if [[ -n "${KORA_STG_CANDIDATE_SQL_QA:-}" ]]; then
      qa_sha=$(sha256sum "$KORA_STG_CANDIDATE_SQL_QA" 2>/dev/null | cut -d' ' -f1)
      if [[ -z "${KORA_STG_CANDIDATE_SQL_QA_SHA256:-}" || "$qa_sha" != "$KORA_STG_CANDIDATE_SQL_QA_SHA256" ]]; then
        results+=("FAIL sql-candidate-qa (SHA-256 ausente ou divergente)"); fail=1
      else
        run_suite "sql-candidate-qa" psql "$KORA_STG_DB_URL" -v ON_ERROR_STOP=1 -q -f "$KORA_STG_CANDIDATE_SQL_QA"
      fi
    fi
    ;;
  *) echo "fase desconhecida: $PHASE"; exit 2 ;;
esac

printf '%s\n' "${results[@]}" | tee "$OUT/summary-$PHASE.txt"
if (( fail )); then echo "KORA-STG VERIFY ($PHASE): FAIL"; exit 1; fi
echo "KORA-STG VERIFY ($PHASE): PASS"
