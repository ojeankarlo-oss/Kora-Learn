#!/usr/bin/env bash
# Disposable local QA only. No published ports, host database, or remote URL.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
base=711f761073253c4d0f010f35f75606a31ab075aa
image=${SC004_QA_IMAGE:-supabase/postgres:15.14.1.167}
evidence=${SC004_QA_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/kora-sc004-r58-evidence.XXXXXX")}
mkdir -p "$evidence"
evidence=$(cd "$evidence" && pwd)
container_id=
status=BLOCKED

cleanup() {
  local code=$?
  trap - EXIT
  if [[ "$status" == RUNTIME_RUNNING && "$code" -ne 0 ]]; then status=RUNTIME_FAILED; fi
  if [[ "$container_id" =~ ^[a-f0-9]{64}$ ]]; then
    docker logs "$container_id" 2>&1 | sed "s/${POSTGRES_PASSWORD}/[REDACTED]/g" > "$evidence/container.log" || true
    docker rm -f "$container_id" > /dev/null || true
  fi
  printf 'STATUS=%s\nEXIT_CODE=%s\n' "$status" "$code" > "$evidence/status.txt"
  printf 'Evidence: %s\nStatus: %s (exit %s)\n' "$evidence" "$status" "$code"
  exit "$code"
}
trap cleanup EXIT

for tool in git docker openssl sha256sum sed tee; do
  command -v "$tool" > /dev/null || { printf 'BLOCKED: missing %s\n' "$tool" >&2; exit 2; }
done
git merge-base --is-ancestor "$base" HEAD || { echo 'BLOCKED: wrong candidate ancestry' >&2; exit 2; }
if [[ -n $(git status --porcelain --untracked-files=normal) ]]; then
  echo 'BLOCKED: run against a clean frozen checkout' >&2
  exit 2
fi
docker info > "$evidence/docker-info.txt" 2>&1 || { echo 'BLOCKED: Docker daemon unavailable' >&2; exit 2; }
docker image inspect "$image" > "$evidence/image.json" 2>&1 || {
  printf 'BLOCKED: local image unavailable; prepare with docker pull %s\n' "$image" >&2
  exit 2
}
{
  printf 'BASE=%s\nSHA=%s\nBRANCH=%s\nIMAGE=%s\n' "$base" "$(git rev-parse HEAD)" "$(git branch --show-current)" "$image"
  git diff --stat "$base" HEAD
  sha256sum tests/school/sql/sc004_ab_qa.sql tests/school/sql/sc004_cd_mutation_qa.sql
} > "$evidence/metadata.txt"
git diff --binary "$base" HEAD > "$evidence/diff.patch"

export POSTGRES_PASSWORD
POSTGRES_PASSWORD=$(openssl rand -hex 24)
export PGPASSWORD="$POSTGRES_PASSWORD"
container_id=$(docker run --detach --pull=never --network none \
  --label kora.qa=sc004-r58 --env POSTGRES_DB=kora_ci \
  --env POSTGRES_USER=supabase_admin --env POSTGRES_PASSWORD "$image")

ready=false
for ((i=0; i<90; i++)); do
  if docker exec "$container_id" pg_isready -U supabase_admin -d kora_ci > /dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || { echo 'BLOCKED: disposable PostgreSQL did not become ready' >&2; exit 2; }
status=RUNTIME_RUNNING
docker exec "$container_id" mkdir -p /tmp/sc004-r58/migrations /tmp/sc004-r58/sql
docker cp supabase/migrations/. "$container_id:/tmp/sc004-r58/migrations/"
docker cp tests/school/sql/. "$container_id:/tmp/sc004-r58/sql/"
docker cp tests/payments/sql/bootstrap.sql "$container_id:/tmp/sc004-r58/bootstrap.sql"

run_psql() {
  docker exec -i --env PGPASSWORD "$container_id" \
    psql -X -h 127.0.0.1 -U "$1" -d kora_ci -v ON_ERROR_STOP=1 "${@:2}"
}
redact_log() { sed "s/${POSTGRES_PASSWORD}/[REDACTED]/g" | tee "$evidence/$1"; }

run_psql supabase_admin <<'SQL' 2>&1 | redact_log bootstrap-auth.log
SET ROLE supabase_auth_admin;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS email_confirmed_at timestamptz;
RESET ROLE;
SQL
bash tests/school/configure-sc004-scram.sh "$container_id" "$evidence" 2>&1 | redact_log auth-preflight.log
run_psql postgres -f /tmp/sc004-r58/bootstrap.sql 2>&1 | redact_log bootstrap.log
run_psql postgres <<'SQL' 2>&1 | redact_log default-acl.log
GRANT CONNECT, CREATE ON DATABASE kora_ci TO postgres;
GRANT USAGE, CREATE ON SCHEMA public TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES
  ON TABLES TO anon, authenticated;
SQL

mapfile -t migrations < <(find supabase/migrations -maxdepth 1 -type f -name '*.sql' | LC_ALL=C sort)
[[ ${#migrations[@]} -gt 0 ]] || { echo 'BLOCKED: canonical migrations missing' >&2; exit 2; }
declare -A prefixes=()
for migration in "${migrations[@]}"; do
  name=${migration##*/}
  [[ "$name" =~ ^([0-9]{3})_[a-z0-9][a-z0-9_]*\.sql$ ]] || { echo "BLOCKED: invalid migration $name" >&2; exit 2; }
  prefix=${BASH_REMATCH[1]}
  [[ -z ${prefixes[$prefix]:-} ]] || { echo "BLOCKED: duplicate migration prefix $prefix" >&2; exit 2; }
  prefixes[$prefix]=$name
done
for migration in "${migrations[@]}"; do
  name=${migration##*/}
  run_psql postgres -f "/tmp/sc004-r58/migrations/$name" 2>&1 | redact_log "migration-$name.log"
done
printf 'CANONICAL_MIGRATIONS=%s\n' "${#migrations[@]}" >> "$evidence/metadata.txt"

# One psql process/session is mandatory: pg_temp helpers/results are shared.
run_psql postgres <<'SQL' 2>&1 | redact_log qa-runtime.log
\getenv qa_password PGPASSWORD
SELECT set_config('kora.ci.dblink_password', :'qa_password', false) AS ignored_password \gset
\unset qa_password
\unset ignored_password
SET kora.ci.dblink_host = '127.0.0.1';
SET kora.ci.dblink_port = '5432';
SELECT version();
\i /tmp/sc004-r58/sql/sc004_dblink_auth_qa.sql
\i /tmp/sc004-r58/sql/sc004_ab_qa.sql
\i /tmp/sc004-r58/sql/sc004_cd_mutation_qa.sql
\copy (select * from qa_results order by id) to '/tmp/sc004-r58/results.csv' csv header
\copy (select * from qa_selftest_results order by id) to '/tmp/sc004-r58/selftests.csv' csv header
\copy (select * from qa_mutation_results order by substring(id from 2)::integer) to '/tmp/sc004-r58/mutations.csv' csv header
\copy (select status,count(*) from qa_mutation_results group by status order by status) to '/tmp/sc004-r58/mutation-counts.csv' csv header
SQL
for artifact in results selftests mutations mutation-counts; do
  docker exec "$container_id" cat "/tmp/sc004-r58/$artifact.csv" | sed "s/${POSTGRES_PASSWORD}/[REDACTED]/g" > "$evidence/$artifact.csv"
done
status=RUNTIME_COMPLETED
