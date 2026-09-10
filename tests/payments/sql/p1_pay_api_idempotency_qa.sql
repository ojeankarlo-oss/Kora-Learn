\set ON_ERROR_STOP on

create or replace function pg_temp.assert_true(ok boolean, message text) returns void
language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'ASSERTION FAILED: %', message; end if;
end $$;

create or replace function pg_temp.assert_sql_error(statement text, expected_state text, expected_message text, assertion text) returns void
language plpgsql as $$
declare
  did_raise boolean := false;
  actual_state text;
  actual_message text;
begin
  begin
    execute statement;
  exception when others then
    did_raise := true;
    get stacked diagnostics actual_state = returned_sqlstate, actual_message = message_text;
  end;
  if not did_raise then
    raise exception 'ASSERTION FAILED: % (statement did not raise)', assertion;
  end if;
  if expected_state is not null and actual_state <> expected_state then
    raise exception 'ASSERTION FAILED: % (expected SQLSTATE %, got %)', assertion, expected_state, actual_state;
  end if;
  if expected_message is not null and actual_message <> expected_message then
    raise exception 'ASSERTION FAILED: % (expected message %, got %)', assertion, expected_message, actual_message;
  end if;
end $$;

create or replace function pg_temp.assert_complete_error(
  record_id uuid,
  lease_token text,
  response_status integer,
  response_body jsonb,
  expected_message text,
  assertion text
) returns void
language plpgsql as $$
declare
  did_raise boolean := false;
  actual_state text;
  actual_message text;
begin
  begin
    perform public.payment_api_complete_idempotency(record_id, lease_token, response_status, response_body, 'qa-004b-3');
  exception when others then
    did_raise := true;
    get stacked diagnostics actual_state = returned_sqlstate, actual_message = message_text;
  end;
  if not did_raise then
    raise exception 'ASSERTION FAILED: % (completion unexpectedly succeeded)', assertion;
  end if;
  if actual_message <> expected_message then
    raise exception 'ASSERTION FAILED: % (expected message %, got % [%])', assertion, expected_message, actual_message, actual_state;
  end if;
end $$;

create or replace function pg_temp.assert_fail_error(
  record_id uuid,
  lease_token text,
  response_status integer,
  response_body jsonb,
  expected_message text,
  assertion text
) returns void
language plpgsql as $$
declare
  did_raise boolean := false;
  actual_state text;
  actual_message text;
begin
  begin
    perform public.payment_api_fail_idempotency(record_id, lease_token, response_status, response_body, 'transient', 'qa-004b-3', 'qa-004b-3', 1);
  exception when others then
    did_raise := true;
    get stacked diagnostics actual_state = returned_sqlstate, actual_message = message_text;
  end;
  if not did_raise then
    raise exception 'ASSERTION FAILED: % (failure unexpectedly succeeded)', assertion;
  end if;
  if actual_message <> expected_message then
    raise exception 'ASSERTION FAILED: % (expected message %, got % [%])', assertion, expected_message, actual_message, actual_state;
  end if;
end $$;

-- Use dedicated applications coherent with the P0 tenant fixtures.
insert into public.payment_api_applications(id, tenant_id, name, slug, status, environment)
values ('ea000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'QA App A 004B', 'qa-app-a-004b', 'active', 'sandbox'),
       ('fb000000-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002', 'QA App B 004B', 'qa-app-b-004b', 'active', 'sandbox'),
       ('ea000000-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001', 'QA App A2 004B', 'qa-app-a2-004b', 'active', 'sandbox')
on conflict (id) do nothing;

-- External references are consumer identity, not tenant or provider authority.
select public.payment_api_register_external_reference(
  'aaaaaaaa-0000-0000-0000-000000000001',
  'ea000000-0000-0000-0000-000000000001',
  'customer',
  'aa100000-0000-0000-0000-000000000001',
  'same-payer-004b',
  'req-ext-1'
) as result;
select pg_temp.assert_true(
  (public.payment_api_register_external_reference(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'customer',
    'aa100000-0000-0000-0000-000000000001',
    'same-payer-004b',
    'req-ext-2'
  )->>'created')::boolean = false,
  'same external reference did not deterministically replay'
);
select pg_temp.assert_true(
  public.payment_api_resolve_external_reference(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'customer',
    'same-payer-004b'
  ) = 'aa100000-0000-0000-0000-000000000001'::uuid,
  'external reference did not resolve inside tenant/application'
);
select pg_temp.assert_sql_error($sql$
  select public.payment_api_register_external_reference(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'customer',
    'aa100000-0000-0000-0000-000000000001',
    'same payer',
    'req-ext-invalid'
  )
$sql$,'P0001','invalid external reference request','unsafe external reference accepted');
select pg_temp.assert_sql_error($sql$
  update public.payment_api_external_references
  set external_reference = 'changed-004b'
  where tenant_id = 'aaaaaaaa-0000-0000-0000-000000000001'
    and application_id = 'ea000000-0000-0000-0000-000000000001'
    and external_reference = 'same-payer-004b'
$sql$,'P0001','external reference is immutable','external reference was mutable');
select pg_temp.assert_sql_error($sql$
  select public.payment_api_register_external_reference(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'customer',
    'bb100000-0000-0000-0000-000000000002',
    'cross-tenant-resource',
    'req-ext-cross-tenant'
  )
$sql$,'P0001','external reference resource unavailable','cross-tenant resource reference accepted');
select public.payment_api_register_external_reference(
  'bbbbbbbb-0000-0000-0000-000000000002',
  'fb000000-0000-0000-0000-000000000002',
  'customer',
  'bb100000-0000-0000-0000-000000000002',
  'same-payer-004b',
  'req-ext-tenant-b'
);
select public.payment_api_register_external_reference(
  'aaaaaaaa-0000-0000-0000-000000000001',
  'ea000000-0000-0000-0000-000000000003',
  'customer',
  'aa100000-0000-0000-0000-000000000001',
  'same-payer-004b',
  'req-ext-app-a2'
);
select pg_temp.assert_true(
  public.payment_api_resolve_external_reference(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'customer', 'same-payer-004b'
  ) = 'aa100000-0000-0000-0000-000000000001'::uuid
  and public.payment_api_resolve_external_reference(
    'bbbbbbbb-0000-0000-0000-000000000002',
    'fb000000-0000-0000-0000-000000000002',
    'customer', 'same-payer-004b'
  ) = 'bb100000-0000-0000-0000-000000000002'::uuid,
  'same reference collided across tenant/application scopes'
);
select pg_temp.assert_true(
  public.payment_api_resolve_external_reference(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'fb000000-0000-0000-0000-000000000002',
    'customer', 'same-payer-004b'
  ) is null,
  'cross-tenant/application resolution was not isolated'
);

-- HTTP idempotency is a separate, persistent authority from payment_intents.
select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001',
  'ea000000-0000-0000-0000-000000000001',
  'POST', 'POST /v1/customers', 'idem-004b-same', repeat('a', 64), 'req-idem-1', 60
) as payload
\gset first_
select (:'first_payload'::jsonb ->> 'record_id') as record_id, (:'first_payload'::jsonb ->> 'lease_token') as lease_token
\gset first_
select pg_temp.assert_true((:'first_payload'::jsonb ->> 'decision') = 'acquired','first idempotency request was not acquired');

select public.payment_api_complete_idempotency(
  (:'first_record_id')::uuid, :'first_lease_token', 201,
  '{"data":{"id":"customer-004b"},"request_id":"req-idem-1"}'::jsonb,
  'req-idem-1'
);
select pg_temp.assert_true(
  (public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'POST', 'POST /v1/customers', 'idem-004b-same', repeat('a', 64), 'req-idem-replay', 60
  )->>'decision') = 'replay',
  'same key and fingerprint did not replay'
);
select pg_temp.assert_true(
  (public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'POST', 'POST /v1/customers', 'idem-004b-same', repeat('b', 64), 'req-idem-conflict', 60
  )->>'decision') = 'conflict',
  'same key with different fingerprint did not conflict'
);
select pg_temp.assert_true(
  (public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'POST', 'POST /v1/invoices', 'idem-004b-operation', repeat('a', 64), 'req-idem-operation', 60
  )->>'decision') = 'acquired',
  'same key collided across operations'
);
select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001',
  'ea000000-0000-0000-0000-000000000001',
  'POST', 'POST /v1/invoices', 'idem-004b-failure', repeat('a', 64), 'req-idem-operation-fail', 60
) as payload
\gset operation_
select public.payment_api_fail_idempotency(
  (:'operation_payload'::jsonb ->> 'record_id')::uuid,
  (:'operation_payload'::jsonb ->> 'lease_token'),
  422, '{"error":{"code":"invoice_not_payable"}}'::jsonb,
  'deterministic', 'invoice_not_payable', 'req-idem-operation-fail', 0
);
select pg_temp.assert_true(
  (public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'POST', 'POST /v1/invoices', 'idem-004b-failure', repeat('a', 64), 'req-idem-failed-replay', 60
  )->>'decision') = 'replay',
  'deterministic failure did not replay'
);

-- Tenant/application scopes are independent even with identical keys.
select pg_temp.assert_true(
  (public.payment_api_begin_idempotency(
    'bbbbbbbb-0000-0000-0000-000000000002',
    'fb000000-0000-0000-0000-000000000002',
    'POST', 'POST /v1/customers', 'idem-004b-same', repeat('a', 64), 'req-idem-tenant-b', 60
  )->>'decision') = 'acquired',
  'same idempotency key collided across tenants'
);
select pg_temp.assert_true(
  (public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000003',
    'POST', 'POST /v1/customers', 'idem-004b-same', repeat('a', 64), 'req-idem-app-a2', 60
  )->>'decision') = 'acquired',
  'same idempotency key collided across applications'
);

-- Stale processing can be safely recovered; live processing cannot be double-acquired.
select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001',
  'ea000000-0000-0000-0000-000000000001',
  'POST', 'POST /v1/customers', 'idem-004b-stale', repeat('c', 64), 'req-idem-stale', 60
) as payload
\gset stale_
update public.payment_api_idempotency
set lease_expires_at = pg_catalog.now() - interval '1 second'
where id = (:'stale_payload'::jsonb ->> 'record_id')::uuid;
select pg_temp.assert_true(
  (public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'POST', 'POST /v1/customers', 'idem-004b-stale', repeat('c', 64), 'req-idem-stale-retry', 60
  )->>'decision') = 'acquired',
  'stale processing was not recoverable'
);
select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001',
  'ea000000-0000-0000-0000-000000000001',
  'POST', 'POST /v1/customers', 'idem-004b-live', repeat('d', 64), 'req-idem-live', 60
) as payload
\gset live_
select pg_temp.assert_true(
  (public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'POST', 'POST /v1/customers', 'idem-004b-live', repeat('d', 64), 'req-idem-live-again', 60
  )->>'decision') = 'in_progress',
  'live processing was double-acquired'
);

select pg_temp.assert_sql_error($sql$
  select public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'GET', 'GET /v1/customers', 'idem-invalid-method', repeat('e', 64), 'req-invalid', 60
  )
$sql$,'P0001','invalid idempotency request','GET idempotency mutation was accepted');
select pg_temp.assert_sql_error($sql$
  select public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'ea000000-0000-0000-0000-000000000001',
    'POST', 'POST /v1/customers', repeat('x', 129), repeat('f', 64), 'req-invalid-key', 60
  )
$sql$,'P0001','invalid idempotency request','oversized idempotency key was accepted');
select pg_temp.assert_complete_error(
  (:'live_payload'::jsonb ->> 'record_id')::uuid,
  (:'live_payload'::jsonb ->> 'lease_token'),
  201, '{"Authorization":"secret"}'::jsonb,
  'invalid idempotency response', 'response with Authorization was persisted'
);
select pg_temp.assert_complete_error(
  (:'live_payload'::jsonb ->> 'record_id')::uuid,
  (:'live_payload'::jsonb ->> 'lease_token'),
  201, jsonb_build_object('data', repeat('x', 262145)),
  'invalid idempotency response', 'oversized response was persisted'
);

select pg_temp.assert_true(
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'payment_api_idempotency'
      and column_name in ('authorization', 'secret', 'credential_secret', 'provider_secret')
  ),
  'idempotency table contains a raw secret column'
);

-- Current Billing Core persistence is PostgreSQL integer; 034 pins every money column to that ceiling.
select pg_temp.assert_true(
  exists (select 1 from pg_constraint where conname = 'invoices_amount_cents_max_004b')
  and exists (select 1 from pg_constraint where conname = 'payment_intents_amount_cents_max_004b'),
  'money ceiling constraints were not installed'
);
select pg_temp.assert_sql_error($sql$
  insert into invoices(id,billing_account_id,tenant_id,customer_id,amount_cents,description,status)
  values ('aa300000-0000-0000-0000-000000000099','aa000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aa100000-0000-0000-0000-000000000001',2147483648,'Too large','open')
$sql$,'22003',null,'amount above PostgreSQL integer ceiling was accepted');

select 'P1 004B EXTERNAL REFERENCES: PASS' as result;
select 'P1 004B HTTP IDEMPOTENCY: PASS' as result;
select 'P1 004B MONEY CEILING: PASS' as result;

-- 004B-1 response sanitizer aliases: case/separator normalization and recursion.
select pg_temp.assert_true(not public.payment_api_response_is_sanitized('{"apiKey":"x"}'::jsonb), 'camelCase apiKey was accepted');
select pg_temp.assert_true(not public.payment_api_response_is_sanitized('{"api_key":"x"}'::jsonb), 'snake_case api_key was accepted');
select pg_temp.assert_true(not public.payment_api_response_is_sanitized('{"api-key":"x"}'::jsonb), 'kebab-case api-key was accepted');
select pg_temp.assert_true(not public.payment_api_response_is_sanitized('{"AccessToken":"x"}'::jsonb), 'uppercase/case access token was accepted');
select pg_temp.assert_true(not public.payment_api_response_is_sanitized('{"nested":{"credential_secret":"x"}}'::jsonb), 'nested credential secret was accepted');
select pg_temp.assert_true(not public.payment_api_response_is_sanitized('{"items":[{"providerAccountId":"x"}]}'::jsonb), 'array provider account id was accepted');
select pg_temp.assert_true(not public.payment_api_response_is_sanitized('{"refresh-token":"x"}'::jsonb), 'kebab refresh token was accepted');
select pg_temp.assert_true(not public.payment_api_response_is_sanitized('{"privateKey":"x"}'::jsonb), 'camelCase private key was accepted');
select pg_temp.assert_true(public.payment_api_response_is_sanitized('{"displayName":"safe","note":"safe"}'::jsonb), 'non-sensitive keys were rejected');

\echo 'P1 004B-1 SANITIZER ALIASES: PASS'

-- 004B-1 direct old-worker fencing: A expires, B reclaims, A cannot finalize, B owns result.
select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001',
  'ea000000-0000-0000-0000-000000000001',
  'POST', 'POST /v1/fencing', 'idem-004b-fencing', repeat('1',64), 'req-fence-a', 60
) as payload
\gset fence_a_
update public.payment_api_idempotency
set lease_expires_at = pg_catalog.now() - interval '1 second'
where id = (:'fence_a_payload'::jsonb ->> 'record_id')::uuid;
select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001',
  'ea000000-0000-0000-0000-000000000001',
  'POST', 'POST /v1/fencing', 'idem-004b-fencing', repeat('1',64), 'req-fence-b', 60
) as payload
\gset fence_b_
select pg_temp.assert_complete_error(
  (:'fence_a_payload'::jsonb ->> 'record_id')::uuid,
  (:'fence_a_payload'::jsonb ->> 'lease_token'),
  200, '{"owner":"A"}'::jsonb,
  'idempotency lease invalid', 'old worker A completion was accepted after reclaim'
);
select pg_temp.assert_fail_error(
  (:'fence_a_payload'::jsonb ->> 'record_id')::uuid,
  (:'fence_a_payload'::jsonb ->> 'lease_token'),
  500, '{"owner":"A"}'::jsonb,
  'idempotency lease invalid', 'old worker A failure was accepted after reclaim'
);
select public.payment_api_complete_idempotency(
  (:'fence_b_payload'::jsonb ->> 'record_id')::uuid,
  (:'fence_b_payload'::jsonb ->> 'lease_token'),
  200, '{"owner":"B"}'::jsonb, 'req-fence-b-complete'
);
select pg_temp.assert_true(
  (select state = 'completed' and response_body ->> 'owner' = 'B'
   from public.payment_api_idempotency
   where id = (:'fence_b_payload'::jsonb ->> 'record_id')::uuid),
  'final stored result is not owned by worker B'
);
\echo 'P1 004B-1 OLD-WORKER FENCING: PASS'

-- 004B-3 semantic sanitizer regression: sensitive concepts blocked, ordinary compounds allowed.
select pg_temp.assert_true(not public.payment_api_response_is_sanitized('{"stack_trace":"x"}'::jsonb), 'stack_trace was accepted');
select pg_temp.assert_true(not public.payment_api_response_is_sanitized('{"sql_error":"x"}'::jsonb), 'sql_error was accepted');
select pg_temp.assert_true(not public.payment_api_response_is_sanitized('{"provider_secret":"x"}'::jsonb), 'provider_secret was accepted');
select pg_temp.assert_true(public.payment_api_response_is_sanitized('{"tokenized":"ok","passwordPolicy":"ok","stackedItems":"ok"}'::jsonb), 'ordinary compound key was rejected');
\echo 'P1 004B-3 SANITIZER REGRESSION: PASS'
