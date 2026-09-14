-- KORA Payments P1-PAY-API-004C-2.
-- Provider-neutral Customer database foundation. No HTTP routes or provider calls.

alter table public.payment_api_applications
  add column if not exists billing_account_id uuid;

do $$
begin
  if exists (
    select 1
    from public.payment_api_applications a
    join public.billing_accounts b on b.id = a.billing_account_id
    where a.billing_account_id is not null
      and (b.tenant_id is distinct from a.tenant_id or b.account_type <> 'tenant')
  ) then
    raise exception 'cannot establish application billing account authority: incompatible existing association';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'payment_api_applications_billing_account_tenant_fkey'
      and conrelid = 'public.payment_api_applications'::regclass
  ) then
    alter table public.payment_api_applications
      add constraint payment_api_applications_billing_account_tenant_fkey
      foreign key (billing_account_id, tenant_id)
      references public.billing_accounts(id, tenant_id)
      on delete restrict;
  end if;
end;
$$;

do $$
begin
  if exists (
    select 1 from public.billing_customers
    where name is null
      or name <> pg_catalog.btrim(name)
      or pg_catalog.char_length(name) not between 1 and 160
  ) then
    raise exception 'cannot enforce billing customer name constraints: incompatible existing rows';
  end if;
  if exists (
    select 1 from public.billing_customers
    where email is not null and pg_catalog.char_length(email) > 320
  ) then
    raise exception 'cannot enforce billing customer email constraints: incompatible existing rows';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'billing_customers_name_normalized_004c'
      and conrelid = 'public.billing_customers'::regclass
  ) then
    alter table public.billing_customers
      add constraint billing_customers_name_normalized_004c
      check (name = pg_catalog.btrim(name) and pg_catalog.char_length(name) between 1 and 160);
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'billing_customers_email_length_004c'
      and conrelid = 'public.billing_customers'::regclass
  ) then
    alter table public.billing_customers
      add constraint billing_customers_email_length_004c
      check (email is null or pg_catalog.char_length(email) <= 320);
  end if;
end;
$$;

create or replace function public.payment_api_create_customer_atomic(
  p_idempotency_record_id uuid,
  p_lease_token text,
  p_name text,
  p_email text,
  p_external_reference text,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  idem public.payment_api_idempotency%rowtype;
  app public.payment_api_applications%rowtype;
  account public.billing_accounts%rowtype;
  customer public.billing_customers%rowtype;
  normalized_name text := pg_catalog.btrim(p_name);
  normalized_email text := nullif(pg_catalog.btrim(p_email), '');
  normalized_reference text := pg_catalog.btrim(p_external_reference);
  response_body jsonb;
  now_at timestamptz := pg_catalog.now();
begin
  if p_idempotency_record_id is null or p_lease_token is null
    or normalized_name is null or pg_catalog.char_length(normalized_name) not between 1 and 160
    or (normalized_email is not null and pg_catalog.char_length(normalized_email) > 320)
    or normalized_reference is null
    or normalized_reference !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$'
    or (p_request_id is not null and pg_catalog.char_length(p_request_id) > 128)
  then
    raise exception 'invalid customer creation request';
  end if;

  select * into idem
  from public.payment_api_idempotency
  where id = p_idempotency_record_id
  for update;

  if not found
    or idem.http_method <> 'POST'
    or idem.operation <> 'POST /v1/customers'
    or idem.state <> 'processing'
    or idem.lease_expires_at <= now_at
    or idem.lease_token_hash <> encode(extensions.digest(p_lease_token, 'sha256'), 'hex')
  then
    raise exception 'customer idempotency lease invalid';
  end if;

  select * into app
  from public.payment_api_applications
  where id = idem.application_id
    and tenant_id = idem.tenant_id
    and status = 'active'
  for share;
  if not found or app.billing_account_id is null then
    raise exception 'application billing account unavailable';
  end if;

  select * into account
  from public.billing_accounts
  where id = app.billing_account_id
    and tenant_id = idem.tenant_id
    and account_type = 'tenant'
    and status = 'active'
  for share;
  if not found then
    raise exception 'application billing account unavailable';
  end if;

  insert into public.billing_customers(
    billing_account_id, tenant_id, user_id, name, email, provider_customer_id
  ) values (
    account.id, idem.tenant_id, null, normalized_name, normalized_email, null
  ) returning * into customer;

  perform public.payment_api_register_external_reference(
    idem.tenant_id,
    idem.application_id,
    'customer',
    customer.id,
    normalized_reference,
    p_request_id
  );

  response_body := pg_catalog.jsonb_build_object(
    'data', pg_catalog.jsonb_build_object(
      'id', customer.id,
      'external_reference', normalized_reference,
      'created_at', customer.created_at
    ),
    'request_id', coalesce(p_request_id, idem.last_request_id)
  );

  if not public.payment_api_response_is_sanitized(response_body) then
    raise exception 'customer response rejected';
  end if;

  perform public.payment_api_complete_idempotency(
    idem.id,
    p_lease_token,
    201,
    response_body,
    p_request_id
  );

  return response_body;
end;
$$;

revoke all on function public.payment_api_create_customer_atomic(uuid, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.payment_api_create_customer_atomic(uuid, text, text, text, text, text)
  to service_role;
