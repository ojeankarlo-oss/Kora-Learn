#!/usr/bin/env bash
# Disposable SC004 container only. Never print a password or credential conninfo.
set +x
set -euo pipefail
qa_container=${1:?container required}
qa_evidence=${2:?evidence directory required}
[[ "$qa_container" =~ ^[a-f0-9]{64}$ ]] || exit 2
[[ -n ${PGPASSWORD:-} ]] || { echo 'BLOCKED: fixture password missing'; exit 2; }
[[ $(docker inspect -f '{{ index .Config.Labels "kora.qa" }}' "$qa_container") == sc004-r58 ]] || exit 2
[[ $(docker inspect -f '{{ .HostConfig.NetworkMode }}' "$qa_container") == none ]] || exit 2

qa_admin() {
  docker exec -i --env PGPASSWORD --env PGCONNECT_TIMEOUT=5 "$qa_container" \
    psql -X -w -h 127.0.0.1 -U supabase_admin -d kora_ci -v ON_ERROR_STOP=1 "$@"
}
qa_hba_inventory() {
  qa_admin -c "COPY (SELECT line_number,type,database,user_name,address,netmask,auth_method,error IS NOT NULL AS invalid FROM pg_hba_file_rules ORDER BY line_number) TO STDOUT WITH CSV HEADER"
}
qa_hba_inventory > "$qa_evidence/hba-before.csv"

# Suppress server statement/error-statement/audit logging before any secret SQL.
# These settings affect only this disposable instance's fixture sessions.
qa_admin <<'SQL'
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_duration_sample = -1;
SET log_min_error_statement = 'panic';
SET pgaudit.log = 'none';
ALTER ROLE postgres SET log_statement = 'none';
ALTER ROLE postgres SET log_min_duration_statement = -1;
ALTER ROLE postgres SET log_min_duration_sample = -1;
ALTER ROLE postgres SET log_min_error_statement = 'panic';
ALTER ROLE postgres SET pgaudit.log = 'none';
SET password_encryption = 'scram-sha-256';
\getenv qa_password PGPASSWORD
ALTER ROLE postgres PASSWORD :'qa_password';
\unset qa_password
DO $role_check$
BEGIN
  IF (SELECT rolsuper FROM pg_roles WHERE rolname='postgres') IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'SC004 requires a non-superuser postgres fixture';
  END IF;
  IF (SELECT rolpassword LIKE 'SCRAM-SHA-256$%' FROM pg_authid WHERE rolname='postgres') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'SC004 fixture verifier must be SCRAM';
  END IF;
END
$role_check$;
SQL

# First matching HBA rule wins. Preserve file ownership by overwriting in place.
docker exec -i --env PGPASSWORD "$qa_container" sh -s <<'SH'
set -eu
qa_hba=$(psql -X -w -h 127.0.0.1 -U supabase_admin -d kora_ci -At -v ON_ERROR_STOP=1 -c 'SHOW hba_file')
test -f "$qa_hba"
{
  printf '%s\n' '# SC004 disposable fixture: must precede image defaults' \
    'host kora_ci postgres 127.0.0.1/32 scram-sha-256'
  cat "$qa_hba"
} > /tmp/sc004-r58/hba.scram.conf
cat /tmp/sc004-r58/hba.scram.conf > "$qa_hba"
SH
qa_admin <<'SQL'
DO $hba_check$
DECLARE first_rule record;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_hba_file_rules WHERE error IS NOT NULL) THEN
    RAISE EXCEPTION 'SC004 HBA parse failure';
  END IF;
  SELECT * INTO STRICT first_rule FROM pg_hba_file_rules ORDER BY line_number LIMIT 1;
  IF first_rule.type <> 'host' OR first_rule.database IS DISTINCT FROM ARRAY['kora_ci']::text[]
     OR first_rule.user_name IS DISTINCT FROM ARRAY['postgres']::text[]
     OR first_rule.address <> '127.0.0.1' OR first_rule.netmask <> '255.255.255.255'
     OR first_rule.auth_method <> 'scram-sha-256' THEN
    RAISE EXCEPTION 'SC004 SCRAM rule does not have first precedence';
  END IF;
END
$hba_check$;
SELECT pg_reload_conf() AS reloaded \gset
\if :reloaded
\else
  \quit 2
\endif
SQL
qa_hba_inventory > "$qa_evidence/hba-after.csv"
# pg_hba_file_rules describes the file, not loaded state. Probe new sessions too.
qa_negative_auth() {
  local qa_mode=$1 qa_bad_password=$2 qa_expected=$3 qa_output qa_code qa_attempt qa_limit=1
  [[ "$qa_mode" != AUTH_NO_PASSWORD ]] || qa_limit=10
  for ((qa_attempt=1; qa_attempt<=qa_limit; qa_attempt++)); do
    set +e
    qa_output=$(docker exec --env PGPASSWORD="$qa_bad_password" --env PGPASSFILE=/dev/null \
      --env PGCONNECT_TIMEOUT=5 "$qa_container" psql -X -w -h 127.0.0.1 \
      -U postgres -d kora_ci -v ON_ERROR_STOP=1 -c 'SELECT 1' 2>&1)
    qa_code=$?
    set -e
    if [[ "$qa_code" == 2 && "$qa_output" == *"$qa_expected"* ]]; then
      printf '%s=DENIED expected_authentication_failure=true exit=%s\n' "$qa_mode" "$qa_code"
      return 0
    fi
    # Only an accepted passwordless session can mean reload propagation.
    # Network/daemon failures and unrelated authentication errors fail now.
    if [[ "$qa_mode" == AUTH_NO_PASSWORD && "$qa_code" == 0 && "$qa_attempt" -lt "$qa_limit" ]]; then
      printf 'HBA_PROPAGATION_PENDING attempt=%s limit=%s\n' "$qa_attempt" "$qa_limit"
      sleep 0.1
      continue
    fi
    printf 'BLOCKED: %s unexpected authentication outcome exit=%s (raw diagnostic suppressed)\n' "$qa_mode" "$qa_code"
    exit 2
  done
  echo 'BLOCKED: SCRAM propagation probe exhausted'
  exit 2
}
qa_negative_auth AUTH_NO_PASSWORD '' 'no password supplied'
qa_negative_auth AUTH_WRONG_PASSWORD 'sc004-negative-not-a-real-secret' 'password authentication failed'
docker exec --env PGPASSWORD --env PGPASSFILE=/dev/null --env PGCONNECT_TIMEOUT=5 "$qa_container" \
  psql -X -w -h 127.0.0.1 -U postgres -d kora_ci -v ON_ERROR_STOP=1 \
  -c "SELECT current_user,session_user,rolsuper FROM pg_roles WHERE rolname=current_user"
echo 'AUTH_VALID_PASSWORD=CONNECTED; dblink validation follows in the QA session'
