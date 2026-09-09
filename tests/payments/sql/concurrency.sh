#!/usr/bin/env bash
set -euo pipefail

rpc="select process_asaas_webhook_atomic('asaas','aa200000-0000-0000-0000-000000000001','aa400000-0000-0000-0000-000000000002','aa300000-0000-0000-0000-000000000002','pay-concurrent','PAYMENT_RECEIVED',20000,'BRL','{}');"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

psql -v ON_ERROR_STOP=1 -Atc "$rpc" >"$tmp_dir/first" &
first_pid=$!
psql -v ON_ERROR_STOP=1 -Atc "$rpc" >"$tmp_dir/second" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

test "$(psql -v ON_ERROR_STOP=1 -Atc "select count(*) from payments where invoice_id='aa300000-0000-0000-0000-000000000002'")" = "1"
test "$(psql -v ON_ERROR_STOP=1 -Atc "select count(*) from billing_events where aggregate_id='aa300000-0000-0000-0000-000000000002' and event_type='payment.paid'")" = "1"
test "$(psql -v ON_ERROR_STOP=1 -Atc "select status from invoices where id='aa300000-0000-0000-0000-000000000002'")" = "paid"
grep -q '"duplicate": true' "$tmp_dir/first" "$tmp_dir/second"
grep -q '"paid": true' "$tmp_dir/first" "$tmp_dir/second"
echo "CONCURRENT IDEMPOTENCY REAL: PASS"
