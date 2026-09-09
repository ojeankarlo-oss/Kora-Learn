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

-- P1-PAY-API-002B: canonical server-side issuance and privilege boundaries.
select pg_temp.assert_true(
  has_function_privilege('anon', 'public.create_payment_api_credential(uuid,text[],timestamp with time zone,text)', 'execute') = false,
  'anon cannot issue credentials'
);
select pg_temp.assert_true(
  has_function_privilege('authenticated', 'public.create_payment_api_credential(uuid,text[],timestamp with time zone,text)', 'execute') = false,
  'authenticated cannot issue credentials'
);
select pg_temp.assert_true(
  has_function_privilege('service_role', 'public.create_payment_api_credential(uuid,text[],timestamp with time zone,text)', 'execute') = true,
  'service_role can issue credentials'
);
select pg_temp.assert_true(
  has_table_privilege('anon', 'public.payment_api_credentials', 'INSERT') = false
    and has_table_privilege('authenticated', 'public.payment_api_credentials', 'INSERT') = false,
  'direct credential insert is blocked for public roles'
);
select pg_temp.assert_true(
  not exists (
    select 1
    from pg_proc p
    where p.oid = 'public.create_payment_api_credential(uuid,text[],timestamp with time zone,text)'::regprocedure
      and coalesce(p.proargnames, array[]::text[]) && array['secret', 'raw_secret', 'credential', 'p_secret']
  ),
  'canonical issue function accepts no caller secret'
);

-- The canonical function accepts only application/scopes/expiry/request metadata;
-- it generates the secret internally and returns it once in a transient result.
select public.create_payment_api_credential(
  'ca000000-0000-0000-0000-000000000001',
  array['invoices:read', 'payment_intents:write'],
  pg_catalog.now() + interval '1 day',
  'req-issue-assert'
) as payload
\gset canonical_

select (:'canonical_payload'::jsonb ->> 'credential_id')::uuid as credential_id,
       (:'canonical_payload'::jsonb ->> 'secret') as secret
\gset canonical_

select pg_temp.assert_true(
  (select credential_provenance = 'server_csprng_v1'
     and credential_hash = encode(extensions.digest(:'canonical_secret', 'sha256'), 'hex')
     and credential_hash <> :'canonical_secret'
   from payment_api_credentials
   where id = (:'canonical_credential_id')::uuid),
  'canonical issue stores only the hash and provenance'
);
select pg_temp.assert_true(
  length(:'canonical_secret') >= 70,
  'canonical secret has public envelope plus at least 256-bit suffix'
);
select pg_temp.assert_true(
  (select count(*) = 2 from payment_api_credential_scopes where credential_id = (:'canonical_credential_id')::uuid),
  'canonical issue persists requested scopes'
);
select pg_temp.assert_true(
  exists (select 1 from payment_api_audit where credential_id = (:'canonical_credential_id')::uuid and event_type = 'created' and request_id = 'req-issue-assert'),
  'canonical issue creates an audit event'
);

select public.rotate_payment_api_credential(
  (:'canonical_credential_id')::uuid,
  null,
  pg_catalog.now() + interval '2 days',
  'req-rotate'
) as payload
\gset rotation_

select (:'rotation_payload'::jsonb ->> 'credential_id')::uuid as credential_id,
       (:'rotation_payload'::jsonb ->> 'secret') as secret
\gset rotation_

select pg_temp.assert_true(
  (select status = 'revoked' from payment_api_credentials where id = (:'canonical_credential_id')::uuid),
  'rotation revokes the old credential'
);
select pg_temp.assert_true(
  (select status = 'active' and credential_provenance = 'server_csprng_v1'
     and rotated_from_id = (:'canonical_credential_id')::uuid
     and credential_hash = encode(extensions.digest(:'rotation_secret', 'sha256'), 'hex')
   from payment_api_credentials
   where id = (:'rotation_credential_id')::uuid),
  'rotation creates a new canonical credential with matching hash'
);
select pg_temp.assert_true(
  (select count(*) = 2 from payment_api_credential_scopes where credential_id = (:'rotation_credential_id')::uuid),
  'rotation preserves scopes'
);
select pg_temp.assert_true(
  (select count(*) = 1 from payment_api_credentials where application_id = 'ca000000-0000-0000-0000-000000000001' and status = 'active' and credential_provenance = 'server_csprng_v1'),
  'one active canonical credential remains after rotation'
);
select pg_temp.assert_true(
  exists (select 1 from payment_api_audit where credential_id = (:'canonical_credential_id')::uuid and event_type = 'revoked' and reason = 'rotated')
    and exists (select 1 from payment_api_audit where credential_id = (:'rotation_credential_id')::uuid and event_type = 'rotated'),
  'rotation audits both sides of lifecycle'
);

-- A failing rotation must roll back the old revocation and new insert.
select public.create_payment_api_credential(
  'db000000-0000-0000-0000-000000000002',
  array['customers:read'],
  pg_catalog.now() + interval '1 day',
  'req-rollback-base'
) as payload
\gset rollback_
select (:'rollback_payload'::jsonb ->> 'credential_id')::uuid as credential_id
\gset rollback_

create or replace function pg_temp.expect_invalid_rotation(p_id uuid) returns void
language plpgsql as $$
begin
  begin
    perform public.rotate_payment_api_credential(p_id, array['scope:not_real'], null, 'req-rollback-fail');
    raise exception 'invalid scope rotation unexpectedly committed';
  exception when others then
    if sqlerrm = 'invalid scope rotation unexpectedly committed' then raise; end if;
  end;
end $$;
select pg_temp.expect_invalid_rotation(:'rollback_credential_id'::uuid);

select pg_temp.assert_true(
  (select status = 'active' from payment_api_credentials where id = (:'rollback_credential_id')::uuid),
  'failed rotation rolled back old credential revocation'
);
select pg_temp.assert_true(
  (select count(*) = 0 from payment_api_credentials where rotated_from_id = (:'rollback_credential_id')::uuid),
  'failed rotation created no replacement credential'
);

select public.revoke_payment_api_credential(
  (:'rotation_credential_id')::uuid,
  'req-revoke',
  'operator_test'
) as payload
\gset revoke_
select pg_temp.assert_true(
  (select status = 'revoked' from payment_api_credentials where id = (:'rotation_credential_id')::uuid),
  'canonical revocation changes status'
);
select pg_temp.assert_true(
  (public.revoke_payment_api_credential((:'rotation_credential_id')::uuid, 'req-revoke-again', 'operator_test') ->> 'already_revoked')::boolean = true,
  'canonical revocation is idempotent'
);

select 'P1 AUTH CANONICAL ISSUANCE: PASS' as result;
select 'P1 AUTH DIRECT INSERT BLOCK: PASS' as result;
select 'P1 AUTH ROTATION ATOMIC: PASS' as result;
select 'P1 AUTH ROTATION ROLLBACK: PASS' as result;
select 'P1 AUTH REVOCATION: PASS' as result;
