\set ON_ERROR_STOP on

create or replace function pg_temp.assert_true(ok boolean, message text) returns void
language plpgsql as $$ begin if not coalesce(ok, false) then raise exception 'ASSERTION FAILED: %', message; end if; end $$;

insert into auth.users(id,email) values
  ('10000000-0000-0000-0000-000000000001','qa-a@local.invalid'),
  ('20000000-0000-0000-0000-000000000002','qa-b@local.invalid');
insert into tenants(id,nome,slug) values
  ('aaaaaaaa-0000-0000-0000-000000000001','QA Tenant A','qa-tenant-a'),
  ('bbbbbbbb-0000-0000-0000-000000000002','QA Tenant B','qa-tenant-b');
insert into usuarios(id,auth_user_id,tenant_id,perfil,nome,email) values
  ('a1000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','gestor','QA A','qa-a@local.invalid'),
  ('b2000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002','gestor','QA B','qa-b@local.invalid');
insert into billing_accounts(id,account_type,tenant_id,display_name) values
  ('aa000000-0000-0000-0000-000000000001','tenant','aaaaaaaa-0000-0000-0000-000000000001','Account A'),
  ('bb000000-0000-0000-0000-000000000002','tenant','bbbbbbbb-0000-0000-0000-000000000002','Account B');
insert into billing_customers(id,billing_account_id,tenant_id,name,email) values
  ('aa100000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Customer A','a@local.invalid'),
  ('bb100000-0000-0000-0000-000000000002','bb000000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002','Customer B','b@local.invalid');
insert into provider_accounts(id,billing_account_id,tenant_id,provider,environment,external_account_id) values
  ('aa200000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','asaas','sandbox','local-a'),
  ('bb200000-0000-0000-0000-000000000002','bb000000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002','asaas','sandbox','local-b');

insert into invoices(id,billing_account_id,tenant_id,customer_id,amount_cents,description,status) values
  ('aa300000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aa100000-0000-0000-0000-000000000001',10000,'Atomic QA','open'),
  ('aa300000-0000-0000-0000-000000000002','aa000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aa100000-0000-0000-0000-000000000001',20000,'Concurrency QA','open'),
  ('bb300000-0000-0000-0000-000000000002','bb000000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002','bb100000-0000-0000-0000-000000000002',10000,'Tenant B','open');
insert into payment_intents(id,billing_account_id,tenant_id,invoice_id,provider_account_id,provider,amount_cents,status,idempotency_key) values
  ('aa400000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aa300000-0000-0000-0000-000000000001','aa200000-0000-0000-0000-000000000001','asaas',10000,'pending','atomic-qa'),
  ('aa400000-0000-0000-0000-000000000002','aa000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aa300000-0000-0000-0000-000000000002','aa200000-0000-0000-0000-000000000001','asaas',20000,'pending','concurrent-qa'),
  ('bb400000-0000-0000-0000-000000000002','bb000000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002','bb300000-0000-0000-0000-000000000002','bb200000-0000-0000-0000-000000000002','asaas',10000,'pending','tenant-b-qa');
insert into payment_attempts(payment_intent_id,tenant_id,provider,provider_payment_id,status) values
  ('aa400000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','asaas','pay-atomic','pending'),
  ('aa400000-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','asaas','pay-concurrent','pending'),
  ('bb400000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002','asaas','pay-b','pending');

-- RLS: each authenticated fixture sees only its own tenant and cannot mutate B from A.
set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',false);
select pg_temp.assert_true((select count(*) = 2 from invoices),'tenant A reads only its two invoices');
select pg_temp.assert_true(not exists(select 1 from invoices where tenant_id='bbbbbbbb-0000-0000-0000-000000000002'),'tenant A cannot read tenant B');
update invoices set description='forbidden' where id='bb300000-0000-0000-0000-000000000002';
select pg_temp.assert_true(not exists(select 1 from invoices where description='forbidden'),'tenant A cannot alter tenant B');
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000002',false);
select pg_temp.assert_true((select count(*) = 1 from invoices),'tenant B reads only its invoice');
reset role;

-- Cross-tenant references are rejected by database triggers.
do $$ begin
  begin
    insert into payment_intents(billing_account_id,tenant_id,invoice_id,provider_account_id,provider,amount_cents)
    values ('aa000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','bb300000-0000-0000-0000-000000000002','aa200000-0000-0000-0000-000000000001','asaas',10000);
    raise exception 'cross-tenant insert was accepted';
  exception when others then if sqlerrm='cross-tenant insert was accepted' then raise; end if; end;
end $$;

-- Every correlation mutation, including one cent, must roll the whole RPC back.
do $$
declare before_events bigint; before_payments bigint; bad text;
begin
  select count(*) into before_events from webhook_events;
  select count(*) into before_payments from payments;
  foreach bad in array array['tenant','provider','provider_account','external_payment_id','invoice','payment_intent','amount_minus','amount_plus'] loop
    begin
      perform process_asaas_webhook_atomic(
        case when bad='provider' then 'other' else 'asaas' end,
        case when bad in ('tenant','provider_account') then 'bb200000-0000-0000-0000-000000000002'::uuid else 'aa200000-0000-0000-0000-000000000001'::uuid end,
        case when bad='payment_intent' then 'bb400000-0000-0000-0000-000000000002'::uuid else 'aa400000-0000-0000-0000-000000000001'::uuid end,
        case when bad='invoice' then 'bb300000-0000-0000-0000-000000000002'::uuid else 'aa300000-0000-0000-0000-000000000001'::uuid end,
        case when bad='external_payment_id' then 'tampered-id' else 'pay-atomic' end,
        'PAYMENT_RECEIVED', case when bad='amount_minus' then 9999 when bad='amount_plus' then 10001 else 10000 end, 'BRL','{}');
      raise exception 'correlation mutation accepted: %', bad;
    exception when others then
      if sqlerrm like 'correlation mutation accepted:%' then raise; end if;
    end;
    perform pg_temp.assert_true((select count(*)=before_events from webhook_events),'failed RPC rolled back webhook event');
    perform pg_temp.assert_true((select count(*)=before_payments from payments),'failed RPC rolled back payment');
    perform pg_temp.assert_true((select status='open' from invoices where id='aa300000-0000-0000-0000-000000000001'),'failed RPC did not settle invoice');
  end loop;
end $$;

select process_asaas_webhook_atomic('asaas','aa200000-0000-0000-0000-000000000001','aa400000-0000-0000-0000-000000000001','aa300000-0000-0000-0000-000000000001','pay-atomic','PAYMENT_RECEIVED',10000,'BRL','{}');
select pg_temp.assert_true((select status='paid' from invoices where id='aa300000-0000-0000-0000-000000000001'),'atomic RPC settled invoice');
select pg_temp.assert_true((select count(*)=1 from payments where invoice_id='aa300000-0000-0000-0000-000000000001'),'atomic RPC created exactly one payment');

-- Forbidden state transitions executed directly in PostgreSQL.
update payments set status='refunded' where invoice_id='aa300000-0000-0000-0000-000000000001';
insert into invoices(id,billing_account_id,tenant_id,customer_id,amount_cents,description,status) values
 ('aa300000-0000-0000-0000-000000000010','aa000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aa100000-0000-0000-0000-000000000001',100,'Cancelled state','cancelled');
do $$ begin
  begin update invoices set status='paid' where id='aa300000-0000-0000-0000-000000000010'; raise exception 'cancelled -> paid accepted'; exception when others then if sqlerrm='cancelled -> paid accepted' then raise; end if; end;
  begin update payments set status='confirmed' where invoice_id='aa300000-0000-0000-0000-000000000001' and status='refunded'; raise exception 'refunded -> paid accepted'; exception when others then if sqlerrm='refunded -> paid accepted' then raise; end if; end;
  begin update invoices set status='pending' where id='aa300000-0000-0000-0000-000000000001'; raise exception 'paid -> pending accepted'; exception when others then if sqlerrm='paid -> pending accepted' then raise; end if; end;
end $$;

select 'RLS TENANT A/B: PASS' as result;
select 'CROSS-TENANT DB INTEGRITY: PASS' as result;
select 'ATOMIC RPC REAL: PASS' as result;
select 'ROLLBACK REAL: PASS' as result;
select 'STATE MACHINE REAL: PASS' as result;
select 'EXTERNAL CORRELATION REAL: PASS' as result;
