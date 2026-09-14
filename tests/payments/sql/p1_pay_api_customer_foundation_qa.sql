\set ON_ERROR_STOP on

create or replace function pg_temp.assert_true(ok boolean, message text) returns void
language plpgsql as $$ begin if not coalesce(ok, false) then raise exception 'ASSERTION FAILED: %', message; end if; end $$;

create or replace function pg_temp.expect_error(statement text, expected text, message text) returns void
language plpgsql as $$
declare actual text;
begin
  begin
    execute statement;
  exception when others then
    get stacked diagnostics actual = message_text;
    if actual = expected then return; end if;
    raise exception 'ASSERTION FAILED: % (expected %, got %)', message, expected, actual;
  end;
  raise exception 'ASSERTION FAILED: % (operation succeeded)', message;
end $$;

insert into public.billing_accounts(id, account_type, tenant_id, display_name) values
  ('4c000000-0000-0000-0000-000000000001', 'tenant', 'aaaaaaaa-0000-0000-0000-000000000001', '004C Account A'),
  ('4c000000-0000-0000-0000-000000000002', 'tenant', 'bbbbbbbb-0000-0000-0000-000000000002', '004C Account B');

insert into public.payment_api_applications(id, tenant_id, name, slug, status, environment, billing_account_id) values
  ('4ca00000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', '004C App A', 'customer-api-a', 'active', 'sandbox', '4c000000-0000-0000-0000-000000000001'),
  ('4ca00000-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', '004C App Unbound', 'customer-api-unbound', 'active', 'sandbox', null),
  ('4cb00000-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002', '004C App B', 'customer-api-b', 'active', 'sandbox', '4c000000-0000-0000-0000-000000000002');

select pg_temp.assert_true(
  has_function_privilege('anon', 'public.payment_api_create_customer_atomic(uuid,text,text,text,text,text)', 'execute') = false
  and has_function_privilege('authenticated', 'public.payment_api_create_customer_atomic(uuid,text,text,text,text,text)', 'execute') = false
  and has_function_privilege('service_role', 'public.payment_api_create_customer_atomic(uuid,text,text,text,text,text)', 'execute') = true,
  'customer RPC privilege boundary is incorrect'
);

select pg_temp.expect_error(
  $$update public.payment_api_applications set billing_account_id='4c000000-0000-0000-0000-000000000002' where id='4ca00000-0000-0000-0000-000000000001'$$,
  'insert or update on table "payment_api_applications" violates foreign key constraint "payment_api_applications_billing_account_tenant_fkey"',
  'cross-tenant application billing account accepted'
);

select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001', '4ca00000-0000-0000-0000-000000000002',
  'POST', 'POST /v1/customers', '004c-unbound', repeat('1',64), 'req-004c-unbound', 60
) as payload \gset unbound_
select pg_temp.expect_error(
  format($sql$select public.payment_api_create_customer_atomic(%L::uuid,%L,'Unbound',null,'ext-unbound','req-004c-unbound')$sql$,
    :'unbound_payload'::jsonb->>'record_id', :'unbound_payload'::jsonb->>'lease_token'),
  'application billing account unavailable', 'unbound application did not fail closed'
);

select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001', '4ca00000-0000-0000-0000-000000000001',
  'POST', 'POST /v1/customers', '004c-create', repeat('2',64), 'req-004c-create', 60
) as payload \gset create_
select public.payment_api_create_customer_atomic(
  (:'create_payload'::jsonb->>'record_id')::uuid, :'create_payload'::jsonb->>'lease_token',
  'Customer 004C', 'customer@local.invalid', 'external-004c-create', 'req-004c-create'
) as response \gset created_

select pg_temp.assert_true(
  exists(select 1 from public.billing_customers c where c.id=(:'created_response'::jsonb#>>'{data,id}')::uuid and c.tenant_id='aaaaaaaa-0000-0000-0000-000000000001' and c.billing_account_id='4c000000-0000-0000-0000-000000000001' and c.user_id is null and c.provider_customer_id is null),
  'canonical customer was not created with trusted authority'
);
select pg_temp.assert_true(
  exists(select 1 from public.payment_api_external_references r where r.resource_id=(:'created_response'::jsonb#>>'{data,id}')::uuid and r.resource_type='customer' and r.external_reference='external-004c-create'),
  'customer external reference was not committed'
);
select pg_temp.assert_true(
  exists(select 1 from public.payment_api_idempotency i where i.id=(:'create_payload'::jsonb->>'record_id')::uuid and i.state='completed' and i.response_status=201 and i.response_body=:'created_response'::jsonb),
  'customer idempotency result was not atomically completed'
);

select pg_temp.assert_true(
  (public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001','4ca00000-0000-0000-0000-000000000001',
    'POST','POST /v1/customers','004c-create',repeat('2',64),'req-replay',60
  )->>'decision')='replay', 'same fingerprint did not replay'
);
select pg_temp.assert_true(
  (public.payment_api_begin_idempotency(
    'aaaaaaaa-0000-0000-0000-000000000001','4ca00000-0000-0000-0000-000000000001',
    'POST','POST /v1/customers','004c-create',repeat('3',64),'req-conflict',60
  )->>'decision')='conflict', 'different fingerprint did not conflict'
);
select pg_temp.assert_true(
  (select count(*)=1 from public.billing_customers where name='Customer 004C'),
  'replay or fingerprint conflict created another customer'
);

select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001','4ca00000-0000-0000-0000-000000000001',
  'POST','POST /v1/customers','004c-wrong-token',repeat('4',64),'req-wrong-token',60
) as payload \gset wrong_
select pg_temp.expect_error(
  format($sql$select public.payment_api_create_customer_atomic(%L::uuid,'wrong-token','Wrong',null,'external-wrong','req-wrong')$sql$, :'wrong_payload'::jsonb->>'record_id'),
  'customer idempotency lease invalid', 'wrong fencing token was accepted'
);
select pg_temp.assert_true(not exists(select 1 from public.billing_customers where name='Wrong'), 'wrong token left an orphan customer');

select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001','4ca00000-0000-0000-0000-000000000001',
  'POST','POST /v1/customers','004c-stale',repeat('5',64),'req-stale-a',60
) as payload \gset stale_a_
update public.payment_api_idempotency set lease_expires_at=pg_catalog.now()-interval '1 second'
where id=(:'stale_a_payload'::jsonb->>'record_id')::uuid;
select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001','4ca00000-0000-0000-0000-000000000001',
  'POST','POST /v1/customers','004c-stale',repeat('5',64),'req-stale-b',60
) as payload \gset stale_b_
select pg_temp.expect_error(
  format($sql$select public.payment_api_create_customer_atomic(%L::uuid,%L,'Stale A',null,'external-stale-a','req-stale-a')$sql$, :'stale_a_payload'::jsonb->>'record_id', :'stale_a_payload'::jsonb->>'lease_token'),
  'customer idempotency lease invalid', 'stale worker created a customer after reclaim'
);
select public.payment_api_create_customer_atomic(
  (:'stale_b_payload'::jsonb->>'record_id')::uuid, :'stale_b_payload'::jsonb->>'lease_token',
  'Stale B', null, 'external-stale-b', 'req-stale-b'
);
select pg_temp.assert_true(not exists(select 1 from public.billing_customers where name='Stale A') and (select count(*)=1 from public.billing_customers where name='Stale B'), 'stale-worker fencing result is incorrect');

-- A forced completion error proves that all earlier writes share its transaction.
create or replace function pg_temp.reject_004c_completion() returns trigger language plpgsql as $$
begin
  if new.state='completed' and new.last_request_id='req-force-completion-failure' then
    raise exception 'forced completion failure';
  end if;
  return new;
end $$;
create trigger trg_test_reject_004c_completion before update on public.payment_api_idempotency
for each row execute function pg_temp.reject_004c_completion();
select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001','4ca00000-0000-0000-0000-000000000001',
  'POST','POST /v1/customers','004c-completion-rollback',repeat('6',64),'req-force-completion-failure',60
) as payload \gset rollback_
select pg_temp.expect_error(
  format($sql$select public.payment_api_create_customer_atomic(%L::uuid,%L,'Rollback Completion',null,'external-completion-rollback','req-force-completion-failure')$sql$, :'rollback_payload'::jsonb->>'record_id', :'rollback_payload'::jsonb->>'lease_token'),
  'forced completion failure', 'completion failure did not abort the RPC'
);
drop trigger trg_test_reject_004c_completion on public.payment_api_idempotency;
select pg_temp.assert_true(
  not exists(select 1 from public.billing_customers where name='Rollback Completion')
  and not exists(select 1 from public.payment_api_external_references where external_reference='external-completion-rollback'),
  'completion failure left customer or external reference'
);

-- A pre-existing mapping forces registration failure after insert; the insert must roll back.
select public.payment_api_begin_idempotency(
  'aaaaaaaa-0000-0000-0000-000000000001','4ca00000-0000-0000-0000-000000000001',
  'POST','POST /v1/customers','004c-reference-rollback',repeat('7',64),'req-ref-rollback',60
) as payload \gset refrollback_
select pg_temp.expect_error(
  format($sql$select public.payment_api_create_customer_atomic(%L::uuid,%L,'Rollback Reference',null,'external-004c-create','req-ref-rollback')$sql$, :'refrollback_payload'::jsonb->>'record_id', :'refrollback_payload'::jsonb->>'lease_token'),
  'external_reference_conflict', 'external-reference collision did not fail'
);
select pg_temp.assert_true(not exists(select 1 from public.billing_customers where name='Rollback Reference'), 'external-reference failure left an orphan customer');

select pg_temp.assert_true(
  public.payment_api_resolve_external_reference('bbbbbbbb-0000-0000-0000-000000000002','4cb00000-0000-0000-0000-000000000002','customer','external-004c-create') is null,
  'tenant B resolved tenant A customer reference'
);

select 'P1 004C CUSTOMER CREATE: PASS' as result;
select 'P1 004C CUSTOMER ATOMICITY: PASS' as result;
select 'P1 004C CUSTOMER REPLAY AND CONFLICT: PASS' as result;
select 'P1 004C CUSTOMER FENCING: PASS' as result;
select 'P1 004C CUSTOMER TENANT AND PRIVILEGES: PASS' as result;
