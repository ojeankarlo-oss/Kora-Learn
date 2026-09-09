#!/usr/bin/env bash
set -euo pipefail

rpc="select (get_or_create_payment_intent_atomic('aa000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aa300000-0000-0000-0000-000000000030','aa200000-0000-0000-0000-000000000001','asaas',3000,'concurrent-intent-request')).id;"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

psql -v ON_ERROR_STOP=1 -Atc "$rpc" >"$tmp_dir/first" &
first_pid=$!
psql -v ON_ERROR_STOP=1 -Atc "$rpc" >"$tmp_dir/second" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

test "$(cat "$tmp_dir/first")" = "$(cat "$tmp_dir/second")"
test "$(psql -v ON_ERROR_STOP=1 -Atc "select count(*) from payment_intents where tenant_id='aaaaaaaa-0000-0000-0000-000000000001' and invoice_id='aa300000-0000-0000-0000-000000000030' and provider='asaas'")" = "1"
test "$(psql -v ON_ERROR_STOP=1 -Atc "select count(*) from payment_intents where tenant_id='aaaaaaaa-0000-0000-0000-000000000001' and invoice_id='aa300000-0000-0000-0000-000000000030' and provider='asaas' and is_canonical")" = "1"
echo "CONCURRENT PAYMENT INTENT CREATION REAL: PASS"
