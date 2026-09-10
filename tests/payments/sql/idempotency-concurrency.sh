#!/usr/bin/env bash
set -euo pipefail

workdir=$(mktemp -d)
diffdir=$(mktemp -d)
trap 'rm -rf "$workdir" "$diffdir"' EXIT

same_sql="select public.payment_api_begin_idempotency('aaaaaaaa-0000-0000-0000-000000000001','ea000000-0000-0000-0000-000000000001','POST','POST /v1/customers','idem-004b-race',repeat('9',64),'req-race',60);"

(psql -X -v ON_ERROR_STOP=1 -At -c "$same_sql" >"$workdir/one.out") &
first_pid=$!
(psql -X -v ON_ERROR_STOP=1 -At -c "$same_sql" >"$workdir/two.out") &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

cat "$workdir/one.out" "$workdir/two.out"

acquired=$(grep -h -o '"decision": "acquired"' "$workdir"/*.out | wc -l | tr -d ' ')
in_progress=$(grep -h -o '"decision": "in_progress"' "$workdir"/*.out | wc -l | tr -d ' ')
if [[ "$acquired" != "1" || "$in_progress" != "1" ]]; then
  echo "IDEMPOTENCY CONCURRENCY: FAIL (acquired=$acquired in_progress=$in_progress)" >&2
  exit 1
fi

echo "IDEMPOTENCY CONCURRENCY: PASS (one lease, one in_progress)"

diff_sql_one="select public.payment_api_begin_idempotency('aaaaaaaa-0000-0000-0000-000000000001','ea000000-0000-0000-0000-000000000001','POST','POST /v1/different-fingerprint','idem-004b-different-fingerprint',repeat('a',64),'req-diff-a',60);"
diff_sql_two="select public.payment_api_begin_idempotency('aaaaaaaa-0000-0000-0000-000000000001','ea000000-0000-0000-0000-000000000001','POST','POST /v1/different-fingerprint','idem-004b-different-fingerprint',repeat('b',64),'req-diff-b',60);"

(psql -X -v ON_ERROR_STOP=1 -At -c "$diff_sql_one" >"$diffdir/one.out") &
diff_first_pid=$!
(psql -X -v ON_ERROR_STOP=1 -At -c "$diff_sql_two" >"$diffdir/two.out") &
diff_second_pid=$!
wait "$diff_first_pid"
wait "$diff_second_pid"

cat "$diffdir/one.out" "$diffdir/two.out"

acquired_diff=$(grep -h -o '"decision": "acquired"' "$diffdir"/*.out | wc -l | tr -d ' ')
conflict_diff=$(grep -h -o '"decision": "conflict"' "$diffdir"/*.out | wc -l | tr -d ' ')
if [[ "$acquired_diff" != "1" || "$conflict_diff" != "1" ]]; then
  echo "IDEMPOTENCY DIFFERENT-FINGERPRINT CONCURRENCY: FAIL (acquired=$acquired_diff conflict=$conflict_diff)" >&2
  exit 1
fi

record_count=$(psql -X -v ON_ERROR_STOP=1 -At -c "select count(*) from public.payment_api_idempotency where tenant_id='aaaaaaaa-0000-0000-0000-000000000001' and application_id='ea000000-0000-0000-0000-000000000001' and http_method='POST' and operation='POST /v1/different-fingerprint' and idempotency_key='idem-004b-different-fingerprint';")
if [[ "$record_count" != "1" ]]; then
  echo "IDEMPOTENCY DIFFERENT-FINGERPRINT CONCURRENCY: FAIL (records=$record_count)" >&2
  exit 1
fi

echo "IDEMPOTENCY DIFFERENT-FINGERPRINT CONCURRENCY: PASS (one owner, one conflict, one record)"
