#!/usr/bin/env bash
set -euo pipefail

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

run_pair() {
  local sql_one=$1 sql_two=$2 label=$3 dir="$workdir/$3"
  mkdir -p "$dir"
  local start="$dir/start"
  (touch "$dir/ready1"; while [[ ! -e "$start" ]]; do sleep 0.01; done; psql -X -v ON_ERROR_STOP=1 -At -c "$sql_one" >"$dir/one.out") & p1=$!
  (touch "$dir/ready2"; while [[ ! -e "$start" ]]; do sleep 0.01; done; psql -X -v ON_ERROR_STOP=1 -At -c "$sql_two" >"$dir/two.out") & p2=$!
  for _ in $(seq 1 500); do [[ -e "$dir/ready1" && -e "$dir/ready2" ]] && break; sleep 0.01; done
  [[ -e "$dir/ready1" && -e "$dir/ready2" ]] || { echo "$label: readiness timeout" >&2; exit 1; }
  touch "$start"; wait "$p1"; wait "$p2"; cat "$dir/one.out" "$dir/two.out"
}

psql -X -v ON_ERROR_STOP=1 <<'SQL'
create or replace function public.qa_004c_customer_attempt(p_key text, p_fingerprint text, p_reference text, p_name text)
returns text language plpgsql as $$
declare acquired jsonb;
begin
  acquired := public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001','4ca00000-0000-0000-0000-000000000001',
    'POST','POST /v1/customers',p_key,p_fingerprint,'req-'||p_key,60
  );
  if acquired->>'decision' <> 'acquired' then return acquired->>'decision'; end if;
  begin
    perform public.payment_api_create_customer_atomic(
      (acquired->>'record_id')::uuid, acquired->>'lease_token', p_name, null, p_reference, 'req-'||p_key
    );
    return 'created';
  exception when others then
    if sqlerrm = 'external_reference_conflict' then return 'external_reference_conflict'; end if;
    raise;
  end;
end $$;
SQL

same="select public.qa_004c_customer_attempt('004c-concurrent-same',repeat('8',64),'external-concurrent-same','Concurrent Same');"
run_pair "$same" "$same" same
created=$(grep -h '^created$' "$workdir/same"/*.out | wc -l | tr -d ' ' || true)
other=$(grep -hE '^(replay|in_progress)$' "$workdir/same"/*.out | wc -l | tr -d ' ' || true)
[[ "$created" = 1 && "$other" = 1 ]] || { echo "CUSTOMER IDENTICAL CONCURRENCY: FAIL" >&2; exit 1; }
[[ "$(psql -X -At -c "select count(*) from public.billing_customers where name='Concurrent Same'")" = 1 ]] || exit 1
echo 'CUSTOMER IDENTICAL CONCURRENCY: PASS'

one="select public.qa_004c_customer_attempt('004c-ext-race-one',repeat('9',64),'external-concurrent-collision','External Race One');"
two="select public.qa_004c_customer_attempt('004c-ext-race-two',repeat('a',64),'external-concurrent-collision','External Race Two');"
run_pair "$one" "$two" external
created=$(grep -h '^created$' "$workdir/external"/*.out | wc -l | tr -d ' ' || true)
conflict=$(grep -h '^external_reference_conflict$' "$workdir/external"/*.out | wc -l | tr -d ' ' || true)
[[ "$created" = 1 && "$conflict" = 1 ]] || { echo "CUSTOMER EXTERNAL REFERENCE CONCURRENCY: FAIL" >&2; exit 1; }
[[ "$(psql -X -At -c "select count(*) from public.payment_api_external_references where external_reference='external-concurrent-collision'")" = 1 ]] || exit 1
[[ "$(psql -X -At -c "select count(*) from public.billing_customers where name in ('External Race One','External Race Two')")" = 1 ]] || exit 1
echo 'CUSTOMER EXTERNAL REFERENCE CONCURRENCY: PASS'

psql -X -v ON_ERROR_STOP=1 -c 'drop function public.qa_004c_customer_attempt(text,text,text,text)'
