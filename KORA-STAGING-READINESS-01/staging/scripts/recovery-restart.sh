#!/usr/bin/env bash
# Recuperação R10-b: reinicia o contêiner Postgres do stack descartável e aguarda
# Postgres + PostgREST + GoTrue voltarem. Depois rode: verify.sh postrestart
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node "$SCRIPT_DIR/guard.mjs"
: "${KORA_STG_API_URL:?}"; : "${KORA_STG_ANON_KEY:?}"; : "${KORA_STG_DB_URL:?}"
DB_CONTAINER="${KORA_STG_DB_CONTAINER:-supabase_db_kora-stg}"
docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || { echo "contêiner $DB_CONTAINER não encontrado"; exit 1; }

before=$(psql "$KORA_STG_DB_URL" -At -c "select count(*) from public.avisos_turma where titulo like 'STG persist %'")
echo "KORA-STG RESTART: avisos de persistência antes=$before"
docker restart "$DB_CONTAINER" >/dev/null
for i in $(seq 1 60); do
  if psql "$KORA_STG_DB_URL" -At -c "select 1" >/dev/null 2>&1; then break; fi
  sleep 2
done
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "apikey: $KORA_STG_ANON_KEY" "$KORA_STG_API_URL/rest/v1/tenants?select=id&limit=1" || true)
  auth=$(curl -s -o /dev/null -w '%{http_code}' -H "apikey: $KORA_STG_ANON_KEY" "$KORA_STG_API_URL/auth/v1/health" || true)
  if [[ "$code" == "200" && "$auth" == "200" ]]; then break; fi
  sleep 2
done
[[ "$code" == "200" && "$auth" == "200" ]] || { echo "KORA-STG RESTART: API não recuperou (rest=$code auth=$auth)"; exit 1; }
after=$(psql "$KORA_STG_DB_URL" -At -c "select count(*) from public.avisos_turma where titulo like 'STG persist %'")
echo "KORA-STG RESTART: avisos de persistência depois=$after"
[[ "$before" == "$after" && "$after" != "0" ]] || { echo "KORA-STG RESTART: FAIL (perda ou ausência de dados)"; exit 1; }
echo "KORA-STG RESTART: PASS"
