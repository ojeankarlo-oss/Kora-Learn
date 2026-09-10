#!/usr/bin/env bash
set -euo pipefail

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

sql="select public.payment_api_begin_idempotency('aaaaaaaa-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','POST','POST /v1/customers','idem-004b-race',repeat('9',64),'req-race',60);"

(psql -X -v ON_ERROR_STOP=1 -At -c "$sql" >"$workdir/one.out") &
first_pid=$!
(psql -X -v ON_ERROR_STOP=1 -At -c "$sql" >"$workdir/two.out") &
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
