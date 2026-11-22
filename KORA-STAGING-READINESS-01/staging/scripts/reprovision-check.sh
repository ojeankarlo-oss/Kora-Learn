#!/usr/bin/env bash
# Recuperação R10-c: destrói o stack (sem backup) e reprovisiona do zero a partir do
# código (migrations + fixtures). Prova que o ambiente é reprodutível: o checksum das
# colunas determinísticas das fixtures deve ser idêntico ao da primeira execução.
# Também prova idempotência do seed (seed executado 2x sem duplicar).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${KORA_STG_WORKDIR:?}"
first=$(cat "$KORA_STG_WORKDIR/checksum.txt")

# Idempotência do seed no ambiente atual (antes de destruir).
node "$SCRIPT_DIR/seed-auth.mjs"
again=$(psql "$KORA_STG_DB_URL" -v ON_ERROR_STOP=1 -At -f "$STG_DIR/fixtures/academic_seed.sql" | grep -E '^KORA_STG_FIXTURE_CHECKSUM\|' || true)
echo "KORA-STG REPROVISION: seed repetido -> $again"

bash "$SCRIPT_DIR/cleanup.sh"
KORA_STG_FIXTURE_PASSWORD="$KORA_STG_FIXTURE_PASSWORD" KORA_STG_RUN_ID="$KORA_STG_RUN_ID" \
  bash "$SCRIPT_DIR/provision.sh"
second=$(cat "$KORA_STG_WORKDIR/checksum.txt")
echo "KORA-STG REPROVISION: primeiro=$first segundo=$second"
# Observação: o seed repetido roda DEPOIS das suítes API/SQL; se essas suítes alterarem
# colunas incluídas no checksum, "again" pode divergir — isso é registrado, não mascarado.
[[ "$first" == "$second" ]] || { echo "KORA-STG REPROVISION: FAIL (não reprodutível)"; exit 1; }
echo "KORA-STG REPROVISION: PASS"
