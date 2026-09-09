\set ON_ERROR_STOP on

create or replace function pg_temp.assert_true(ok boolean, message text) returns void
language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'ASSERTION FAILED: %', message; end if;
end $$;

insert into auth.users(id, email) values
  ('c0000000-0000-0000-0000-000000000001', 'p1-auth-a@local.invalid'),
  ('d0000000-0000-0000-0000-000000000002', 'p1-auth-b@local.invalid');

insert into tenants(id, nome, slug) values
  ('cccccccc-0000-0000-0000-000000000001', 'P1 Auth Tenant A', 'p1-auth-tenant-a'),
  ('dddddddd-0000-0000-0000-000000000002', 'P1 Auth Tenant B', 'p1-auth-tenant-b');

insert into usuarios(id, auth_user_id, tenant_id, perfil, nome, email) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'gestor', 'P1 Auth A', 'p1-auth-a@local.invalid'),
  ('d2000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000002', 'dddddddd-0000-0000-0000-000000000002', 'gestor', 'P1 Auth B', 'p1-auth-b@local.invalid');

insert into payment_api_applications(id, tenant_id, name, slug, environment) values
  ('ca000000-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'P1 ENEM A', 'p1-enem-a', 'sandbox'),
  ('db000000-0000-0000-0000-000000000002', 'dddddddd-0000-0000-0000-000000000002', 'P1 ETEC B', 'p1-etec-b', 'sandbox');

insert into payment_api_credentials(
  id, application_id, tenant_id, public_prefix, credential_hash, environment
) values
  ('cc100000-0000-0000-0000-000000000001', 'ca000000-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'kp_sandbox_p1autha01', repeat('a', 64), 'sandbox'),
  ('dd200000-0000-0000-0000-000000000002', 'db000000-0000-0000-0000-000000000002', 'dddddddd-0000-0000-0000-000000000002', 'kp_sandbox_p1authb02', repeat('b', 64), 'sandbox');

insert into payment_api_credential_scopes(credential_id, tenant_id, scope_code) values
  ('cc100000-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'invoices:read'),
  ('cc100000-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'payment_intents:write'),
  ('dd200000-0000-0000-0000-000000000002', 'dddddddd-0000-0000-0000-000000000002', 'customers:read');

select pg_temp.assert_true(
  (select credential_hash is not null and length(credential_hash) = 64 and public_prefix is not null from payment_api_credentials where id = 'cc100000-0000-0000-0000-000000000001'),
  'credential hash and public prefix persisted'
);
select pg_temp.assert_true(
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name in ('payment_api_credentials', 'payment_api_applications')
      and column_name in ('secret', 'raw_secret', 'credential', 'authorization')
  ),
  'plaintext credential column absent'
);
select pg_temp.assert_true(
  has_function_privilege('anon', 'public.payment_api_touch_credential(uuid,text)', 'execute') = false,
  'anon cannot execute credential touch'
);
select pg_temp.assert_true(
  has_function_privilege('authenticated', 'public.payment_api_touch_credential(uuid,text)', 'execute') = false,
  'authenticated cannot execute credential touch'
);
select pg_temp.assert_true(
  has_function_privilege('service_role', 'public.payment_api_touch_credential(uuid,text)', 'execute') = true,
  'service_role can execute credential touch'
);

-- Cross-tenant credential/application/scope relationships are rejected by composite FKs.
select pg_temp.assert_true(
  (select count(*) = 0 from payment_api_credentials where tenant_id = 'cccccccc-0000-0000-0000-000000000001' and application_id = 'db000000-0000-0000-0000-000000000002'),
  'fixture has no cross-tenant credential'
);

do $$
begin
  begin
    insert into payment_api_credentials(
      application_id, tenant_id, public_prefix, credential_hash, environment
    ) values (
      'db000000-0000-0000-0000-000000000002',
      'cccccccc-0000-0000-0000-000000000001',
      'kp_sandbox_cross01', repeat('c', 64), 'sandbox'
    );
    raise exception 'cross-tenant credential accepted';
  exception when others then
    if sqlerrm = 'cross-tenant credential accepted' then raise; end if;
  end;
end $$;

do $$
begin
  begin
    insert into payment_api_credential_scopes(credential_id, tenant_id, scope_code)
    values ('cc100000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000002', 'invoices:read');
    raise exception 'cross-tenant scope accepted';
  exception when others then
    if sqlerrm = 'cross-tenant scope accepted' then raise; end if;
  end;
end $$;

-- Staff RLS sees only the session tenant's applications.
set role authenticated;
select set_config('request.jwt.claim.sub', 'c0000000-0000-0000-0000-000000000001', false);
select pg_temp.assert_true((select count(*) = 1 from payment_api_applications), 'tenant A sees one own application');
select pg_temp.assert_true(not exists (select 1 from payment_api_applications where tenant_id = 'dddddddd-0000-0000-0000-000000000002'), 'tenant A cannot see tenant B application');
select set_config('request.jwt.claim.sub', 'd0000000-0000-0000-0000-000000000002', false);
select pg_temp.assert_true((select count(*) = 1 from payment_api_applications), 'tenant B sees one own application');
select pg_temp.assert_true(not exists (select 1 from payment_api_applications where tenant_id = 'cccccccc-0000-0000-0000-000000000001'), 'tenant B cannot see tenant A application');
reset role;

-- Credential lifecycle is audit-visible without persisting a raw secret.
update payment_api_credentials
set status = 'revoked', revoked_at = now()
where id = 'cc100000-0000-0000-0000-000000000001';
select pg_temp.assert_true(
  exists (select 1 from payment_api_audit where credential_id = 'cc100000-0000-0000-0000-000000000001' and event_type = 'revoked'),
  'revocation created an audit row'
);

insert into payment_api_credentials(
  id, application_id, tenant_id, public_prefix, credential_hash, environment, rotated_from_id, rotated_at
) values (
  'cc100000-0000-0000-0000-000000000003', 'ca000000-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'kp_sandbox_p1authc03', repeat('c', 64), 'sandbox', 'cc100000-0000-0000-0000-000000000001', now()
);
select pg_temp.assert_true(
  exists (select 1 from payment_api_audit where credential_id = 'cc100000-0000-0000-0000-000000000003' and event_type = 'rotated'),
  'rotation created an audit row'
);

select 'P1 AUTH APPLICATIONS: PASS' as result;
select 'P1 AUTH HASH ONLY: PASS' as result;
select 'P1 AUTH CROSS TENANT: PASS' as result;
select 'P1 AUTH RLS: PASS' as result;
select 'P1 AUTH LIFECYCLE AUDIT: PASS' as result;
