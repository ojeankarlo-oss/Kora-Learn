-- KORA Payments P1-PAY-API-004B.
-- Provider-neutral external references, persistent HTTP idempotency and
-- PostgreSQL-compatible money bounds. No endpoints or provider calls.

create table if not exists public.payment_api_external_references (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  application_id uuid not null,
  resource_type text not null check (
    resource_type in ('customer', 'invoice', 'subscription', 'order', 'enrollment')
    and resource_type ~ '^[a-z][a-z0-9_]{0,63}$'
  ),
  resource_id uuid not null,
  external_reference text not null check (
    length(external_reference) between 1 and 160
    and external_reference ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$'
  ),
  created_at timestamptz not null default pg_catalog.now(),
  unique (tenant_id, application_id, resource_type, external_reference),
  unique (tenant_id, application_id, resource_type, resource_id),
  unique (id, tenant_id),
  foreign key (application_id, tenant_id)
    references public.payment_api_applications(id, tenant_id)
    on delete cascade
);

create index if not exists idx_payment_api_external_refs_lookup
  on public.payment_api_external_references (tenant_id, application_id, resource_type, external_reference);

create or replace function public.validate_payment_api_external_reference()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  resource_tenant uuid;
begin
  if tg_op = 'UPDATE' and (
    new.tenant_id is distinct from old.tenant_id
    or new.application_id is distinct from old.application_id
    or new.resource_type is distinct from old.resource_type
    or new.resource_id is distinct from old.resource_id
    or new.external_reference is distinct from old.external_reference
  ) then
    raise exception 'external reference is immutable';
  end if;

  if new.resource_type = 'customer' then
    select tenant_id into resource_tenant
    from public.billing_customers
    where id = new.resource_id;
    if resource_tenant is distinct from new.tenant_id then
      raise exception 'external reference resource tenant mismatch';
    end if;
  elsif new.resource_type = 'invoice' then
    select tenant_id into resource_tenant
    from public.invoices
    where id = new.resource_id;
    if resource_tenant is distinct from new.tenant_id then
      raise exception 'external reference resource tenant mismatch';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.validate_payment_api_external_reference() from public, anon, authenticated;
grant execute on function public.validate_payment_api_external_reference() to service_role;

drop trigger if exists trg_payment_api_external_reference_integrity
  on public.payment_api_external_references;
create trigger trg_payment_api_external_reference_integrity
before insert or update on public.payment_api_external_references
for each row execute function public.validate_payment_api_external_reference();

create or replace function public.cleanup_payment_api_external_reference()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  delete from public.payment_api_external_references
  where resource_id = old.id
    and resource_type = case when tg_table_name = 'billing_customers' then 'customer' when tg_table_name = 'invoices' then 'invoice' else resource_type end;
  return old;
end;
$$;

revoke all on function public.cleanup_payment_api_external_reference() from public, anon, authenticated;
grant execute on function public.cleanup_payment_api_external_reference() to service_role;

drop trigger if exists trg_cleanup_customer_external_references on public.billing_customers;
create trigger trg_cleanup_customer_external_references
after delete on public.billing_customers
for each row execute function public.cleanup_payment_api_external_reference();

drop trigger if exists trg_cleanup_invoice_external_references on public.invoices;
create trigger trg_cleanup_invoice_external_references
after delete on public.invoices
for each row execute function public.cleanup_payment_api_external_reference();

alter table public.payment_api_external_references enable row level security;
revoke all on table public.payment_api_external_references from public, anon, authenticated;
drop policy if exists payment_api_external_references_service_role
  on public.payment_api_external_references;
create policy payment_api_external_references_service_role
  on public.payment_api_external_references
  for all to service_role using (true) with check (true);

create table if not exists public.payment_api_idempotency (
  id uuid primary key default extensions.gen_random_uuid(),
  tenant_id uuid not null,
  application_id uuid not null,
  http_method text not null check (http_method in ('POST', 'PUT', 'PATCH', 'DELETE')),
  operation text not null check (
    length(operation) between 1 and 160
    and operation ~ '^[A-Z]+ /[A-Za-z0-9._~:/{}-]+$'
  ),
  idempotency_key text not null check (
    length(idempotency_key) between 1 and 128
    and idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
  ),
  request_fingerprint text not null check (request_fingerprint ~ '^[0-9a-f]{64}$'),
  state text not null default 'processing' check (state in ('processing', 'completed', 'failed')),
  response_status smallint check (response_status between 100 and 599),
  response_body jsonb,
  response_size_bytes integer check (response_size_bytes between 0 and 262144),
  lease_token_hash text check (lease_token_hash is null or lease_token_hash ~ '^[0-9a-f]{64}$'),
  lease_expires_at timestamptz,
  retry_at timestamptz,
  failure_kind text check (failure_kind is null or failure_kind in ('deterministic', 'transient')),
  last_error_code text check (last_error_code is null or length(last_error_code) between 1 and 80),
  last_request_id text check (last_request_id is null or length(last_request_id) between 1 and 128),
  attempt_count integer not null default 1 check (attempt_count > 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  completed_at timestamptz,
  unique (tenant_id, application_id, http_method, operation, idempotency_key),
  unique (id, tenant_id),
  foreign key (application_id, tenant_id)
    references public.payment_api_applications(id, tenant_id)
    on delete cascade,
  check (
    (state = 'processing'
      and lease_token_hash is not null
      and lease_expires_at is not null
      and response_status is null
      and response_body is null)
    or
    (state in ('completed', 'failed')
      and response_status is not null
      and response_body is not null
      and lease_token_hash is null
      and lease_expires_at is null)
  ),
  check ((state = 'completed' and failure_kind is null) or (state <> 'completed')),
  check ((state = 'failed' and failure_kind is not null) or (state <> 'failed')),
  check (response_body is null or pg_catalog.octet_length(pg_catalog.convert_to(response_body::text, 'UTF8')) <= 262144)
);

create index if not exists idx_payment_api_idempotency_processing
  on public.payment_api_idempotency (lease_expires_at)
  where state = 'processing';

create index if not exists idx_payment_api_idempotency_updated
  on public.payment_api_idempotency (updated_at desc);

alter table public.payment_api_idempotency enable row level security;
revoke all on table public.payment_api_idempotency from public, anon, authenticated;
drop policy if exists payment_api_idempotency_service_role
  on public.payment_api_idempotency;
create policy payment_api_idempotency_service_role
  on public.payment_api_idempotency
  for all to service_role using (true) with check (true);

create or replace function public.payment_api_register_external_reference(
  p_tenant_id uuid,
  p_application_id uuid,
  p_resource_type text,
  p_resource_id uuid,
  p_external_reference text,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_type text := lower(pg_catalog.btrim(p_resource_type));
  normalized_reference text := pg_catalog.btrim(p_external_reference);
  existing public.payment_api_external_references%rowtype;
  inserted public.payment_api_external_references%rowtype;
  tenant_active boolean;
begin
  if p_tenant_id is null or p_application_id is null or p_resource_id is null
    or normalized_type is null or normalized_reference is null
    or normalized_type not in ('customer', 'invoice', 'subscription', 'order', 'enrollment')
    or normalized_type !~ '^[a-z][a-z0-9_]{0,63}$'
    or normalized_reference !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$'
  then raise exception 'invalid external reference request'; end if;

  select ativo into tenant_active from public.tenants where id = p_tenant_id;
  if not found or tenant_active is distinct from true then raise exception 'tenant unavailable'; end if;
  if not exists (
    select 1 from public.payment_api_applications
    where id = p_application_id and tenant_id = p_tenant_id and status = 'active'
  ) then raise exception 'application unavailable'; end if;

  if normalized_type = 'customer' and not exists (
    select 1 from public.billing_customers where id = p_resource_id and tenant_id = p_tenant_id
  ) then raise exception 'external reference resource unavailable'; end if;
  if normalized_type = 'invoice' and not exists (
    select 1 from public.invoices where id = p_resource_id and tenant_id = p_tenant_id
  ) then raise exception 'external reference resource unavailable'; end if;

  begin
    insert into public.payment_api_external_references(
      tenant_id, application_id, resource_type, resource_id, external_reference
    ) values (
      p_tenant_id, p_application_id, normalized_type, p_resource_id, normalized_reference
    ) returning * into inserted;
  exception when unique_violation then
    select * into existing
    from public.payment_api_external_references
    where tenant_id = p_tenant_id
      and application_id = p_application_id
      and resource_type = normalized_type
      and external_reference = normalized_reference
    for update;
    if found and existing.resource_id = p_resource_id then
      return jsonb_build_object('created', false, 'id', existing.id, 'resource_id', existing.resource_id);
    end if;
    raise exception 'external_reference_conflict';
  end;

  return jsonb_build_object('created', true, 'id', inserted.id, 'resource_id', inserted.resource_id);
end;
$$;

create or replace function public.payment_api_resolve_external_reference(
  p_tenant_id uuid,
  p_application_id uuid,
  p_resource_type text,
  p_external_reference text
) returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  resolved_id uuid;
begin
  if p_tenant_id is null or p_application_id is null
    or not exists (
      select 1 from public.payment_api_applications
      where id = p_application_id and tenant_id = p_tenant_id and status = 'active'
    ) then
    return null;
  end if;

  select resource_id into resolved_id
  from public.payment_api_external_references
  where tenant_id = p_tenant_id
    and application_id = p_application_id
    and resource_type = lower(pg_catalog.btrim(p_resource_type))
    and external_reference = pg_catalog.btrim(p_external_reference);
  return resolved_id;
end;
$$;

create or replace function public.payment_api_begin_idempotency(
  p_tenant_id uuid,
  p_application_id uuid,
  p_http_method text,
  p_operation text,
  p_idempotency_key text,
  p_request_fingerprint text,
  p_request_id text default null,
  p_lease_seconds integer default 60
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  record_row public.payment_api_idempotency%rowtype;
  lease_token text;
  now_at timestamptz := pg_catalog.now();
  normalized_method text := upper(pg_catalog.btrim(p_http_method));
  normalized_operation text := pg_catalog.btrim(p_operation);
  normalized_key text := pg_catalog.btrim(p_idempotency_key);
begin
  if p_tenant_id is null or p_application_id is null
    or normalized_method is null or normalized_operation is null or normalized_key is null
    or p_request_fingerprint is null or p_lease_seconds is null
    or normalized_method not in ('POST', 'PUT', 'PATCH', 'DELETE')
    or normalized_operation !~ '^[A-Z]+ /[A-Za-z0-9._~:/{}-]+$'
    or normalized_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
    or p_request_fingerprint !~ '^[0-9a-f]{64}$'
    or p_lease_seconds not between 1 and 3600
  then raise exception 'invalid idempotency request'; end if;

  if not exists (
    select 1 from public.payment_api_applications
    where id = p_application_id and tenant_id = p_tenant_id and status = 'active'
  ) then raise exception 'application unavailable'; end if;

  select * into record_row
  from public.payment_api_idempotency
  where tenant_id = p_tenant_id
    and application_id = p_application_id
    and http_method = normalized_method
    and operation = normalized_operation
    and idempotency_key = normalized_key
  for update;

  if found then
    if record_row.request_fingerprint <> p_request_fingerprint then
      return jsonb_build_object('decision', 'conflict', 'record_id', record_row.id);
    end if;
    if record_row.state = 'completed' or (record_row.state = 'failed' and record_row.failure_kind = 'deterministic') then
      return jsonb_build_object(
        'decision', 'replay', 'record_id', record_row.id,
        'status', record_row.response_status, 'body', record_row.response_body
      );
    end if;
    if record_row.state = 'failed' and record_row.failure_kind = 'transient'
      and record_row.retry_at is not null and record_row.retry_at > now_at then
      return jsonb_build_object(
        'decision', 'retry_later', 'record_id', record_row.id,
        'retry_after_seconds', greatest(1, floor(extract(epoch from (record_row.retry_at - now_at)))::integer)
      );
    end if;
    if record_row.state = 'processing' and record_row.lease_expires_at > now_at then
      return jsonb_build_object(
        'decision', 'in_progress', 'record_id', record_row.id,
        'retry_after_seconds', greatest(1, floor(extract(epoch from (record_row.lease_expires_at - now_at)))::integer)
      );
    end if;

    lease_token := encode(extensions.gen_random_bytes(32), 'hex');
    update public.payment_api_idempotency
    set state = 'processing', lease_token_hash = encode(extensions.digest(lease_token, 'sha256'), 'hex'),
        lease_expires_at = now_at + pg_catalog.make_interval(secs => p_lease_seconds),
        retry_at = null, response_status = null, response_body = null,
        response_size_bytes = null, failure_kind = null, last_error_code = null,
        last_request_id = p_request_id, attempt_count = record_row.attempt_count + 1,
        updated_at = now_at, completed_at = null
    where id = record_row.id;
    return jsonb_build_object('decision', 'acquired', 'record_id', record_row.id, 'lease_token', lease_token);
  end if;

  lease_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.payment_api_idempotency(
    tenant_id, application_id, http_method, operation, idempotency_key,
    request_fingerprint, state, lease_token_hash, lease_expires_at, last_request_id
  ) values (
    p_tenant_id, p_application_id, normalized_method, normalized_operation, normalized_key,
    p_request_fingerprint, 'processing', encode(extensions.digest(lease_token, 'sha256'), 'hex'),
    now_at + pg_catalog.make_interval(secs => p_lease_seconds), p_request_id
  ) returning * into record_row;
  return jsonb_build_object('decision', 'acquired', 'record_id', record_row.id, 'lease_token', lease_token);
exception when unique_violation then
  select * into record_row
  from public.payment_api_idempotency
  where tenant_id = p_tenant_id
    and application_id = p_application_id
    and http_method = normalized_method
    and operation = normalized_operation
    and idempotency_key = normalized_key
  for update;
  if record_row.request_fingerprint <> p_request_fingerprint then
    return jsonb_build_object('decision', 'conflict', 'record_id', record_row.id);
  end if;
  if record_row.state = 'completed' or (record_row.state = 'failed' and record_row.failure_kind = 'deterministic') then
    return jsonb_build_object(
      'decision', 'replay', 'record_id', record_row.id,
      'status', record_row.response_status, 'body', record_row.response_body
    );
  end if;
  if record_row.state = 'failed' and record_row.failure_kind = 'transient'
    and record_row.retry_at is not null and record_row.retry_at > pg_catalog.now() then
    return jsonb_build_object(
      'decision', 'retry_later', 'record_id', record_row.id,
      'retry_after_seconds', greatest(1, floor(extract(epoch from (record_row.retry_at - pg_catalog.now())))::integer)
    );
  end if;
  return jsonb_build_object('decision', 'in_progress', 'record_id', record_row.id, 'retry_after_seconds', 1);
end;
$$;

create or replace function public.payment_api_response_is_sanitized(p_body jsonb)
returns boolean
language sql
immutable
as $$
with recursive nodes(value) as (
  select p_body
  union all
  select child.value
  from nodes
  cross join lateral jsonb_each(
    case when jsonb_typeof(nodes.value) = 'object' then nodes.value else '{}'::jsonb end
  ) child
  union all
  select child.value
  from nodes
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(nodes.value) = 'array' then nodes.value else '[]'::jsonb end
  ) child
)
select not exists (
  select 1
  from nodes
  cross join lateral jsonb_object_keys(
    case when jsonb_typeof(nodes.value) = 'object' then nodes.value else '{}'::jsonb end
  ) as keys(key)
  where lower(keys.key) ~ '(authorization|secret|access_token|refresh_token|client_secret|private_key|password|stack|sql|provider_payment_id|provider_account_id)'
);
$$;

revoke all on function public.payment_api_response_is_sanitized(jsonb) from public, anon, authenticated;
grant execute on function public.payment_api_response_is_sanitized(jsonb) to service_role;

create or replace function public.payment_api_complete_idempotency(
  p_record_id uuid,
  p_lease_token text,
  p_response_status integer,
  p_response_body jsonb,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  record_row public.payment_api_idempotency%rowtype;
  response_bytes integer;
  now_at timestamptz := pg_catalog.now();
begin
  response_bytes := pg_catalog.octet_length(pg_catalog.convert_to(p_response_body::text, 'UTF8'));
  if p_record_id is null or p_lease_token is null or p_response_status is null
    or p_response_status not between 100 and 599 or p_response_body is null or response_bytes > 262144
    or not public.payment_api_response_is_sanitized(p_response_body) then
    raise exception 'invalid idempotency response';
  end if;
  select * into record_row from public.payment_api_idempotency where id = p_record_id for update;
  if not found or record_row.state <> 'processing'
    or record_row.lease_expires_at <= now_at
    or record_row.lease_token_hash <> encode(extensions.digest(p_lease_token, 'sha256'), 'hex')
  then raise exception 'idempotency lease invalid'; end if;

  update public.payment_api_idempotency
  set state = 'completed', response_status = p_response_status, response_body = p_response_body,
      response_size_bytes = response_bytes, lease_token_hash = null, lease_expires_at = null,
      failure_kind = null, last_error_code = null, last_request_id = p_request_id,
      retry_at = null, updated_at = now_at, completed_at = now_at
  where id = p_record_id;
  return jsonb_build_object('completed', true, 'record_id', p_record_id);
end;
$$;

create or replace function public.payment_api_fail_idempotency(
  p_record_id uuid,
  p_lease_token text,
  p_response_status integer,
  p_response_body jsonb,
  p_failure_kind text,
  p_error_code text,
  p_request_id text default null,
  p_retry_after_seconds integer default 0
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  record_row public.payment_api_idempotency%rowtype;
  response_bytes integer;
  now_at timestamptz := pg_catalog.now();
begin
  response_bytes := pg_catalog.octet_length(pg_catalog.convert_to(p_response_body::text, 'UTF8'));
  if p_record_id is null or p_lease_token is null or p_response_status is null
    or p_failure_kind is null or p_retry_after_seconds is null
    or p_response_status not between 400 and 599 or p_response_body is null
    or response_bytes > 262144 or not public.payment_api_response_is_sanitized(p_response_body)
    or p_failure_kind not in ('deterministic', 'transient')
    or p_retry_after_seconds < 0 then
    raise exception 'invalid idempotency failure';
  end if;
  select * into record_row from public.payment_api_idempotency where id = p_record_id for update;
  if not found or record_row.state <> 'processing'
    or record_row.lease_expires_at <= now_at
    or record_row.lease_token_hash <> encode(extensions.digest(p_lease_token, 'sha256'), 'hex')
  then raise exception 'idempotency lease invalid'; end if;

  update public.payment_api_idempotency
  set state = 'failed', response_status = p_response_status, response_body = p_response_body,
      response_size_bytes = response_bytes, lease_token_hash = null, lease_expires_at = null,
      failure_kind = p_failure_kind, last_error_code = p_error_code, last_request_id = p_request_id,
      retry_at = case when p_failure_kind = 'transient' and p_retry_after_seconds > 0
        then now_at + pg_catalog.make_interval(secs => p_retry_after_seconds) else null end,
      updated_at = now_at, completed_at = now_at
  where id = p_record_id;
  return jsonb_build_object('failed', true, 'record_id', p_record_id, 'failure_kind', p_failure_kind);
end;
$$;

revoke all on function public.validate_payment_api_external_reference() from public, anon, authenticated;
revoke all on function public.payment_api_response_is_sanitized(jsonb) from public, anon, authenticated;
revoke all on function public.payment_api_register_external_reference(uuid, uuid, text, uuid, text, text) from public, anon, authenticated;
revoke all on function public.payment_api_resolve_external_reference(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.payment_api_begin_idempotency(uuid, uuid, text, text, text, text, text, integer) from public, anon, authenticated;
revoke all on function public.payment_api_complete_idempotency(uuid, text, integer, jsonb, text) from public, anon, authenticated;
revoke all on function public.payment_api_fail_idempotency(uuid, text, integer, jsonb, text, text, text, integer) from public, anon, authenticated;
grant execute on function public.payment_api_register_external_reference(uuid, uuid, text, uuid, text, text) to service_role;
grant execute on function public.payment_api_resolve_external_reference(uuid, uuid, text, text) to service_role;
grant execute on function public.payment_api_begin_idempotency(uuid, uuid, text, text, text, text, text, integer) to service_role;
grant execute on function public.payment_api_complete_idempotency(uuid, text, integer, jsonb, text) to service_role;
grant execute on function public.payment_api_fail_idempotency(uuid, text, integer, jsonb, text, text, text, integer) to service_role;

-- PostgreSQL integer is the persistent authority for current Billing Core amounts.
-- Keep the public/runtime/OpenAPI contract below the integer ceiling.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'invoices_amount_cents_max_004b') then
    alter table public.invoices add constraint invoices_amount_cents_max_004b check (amount_cents between 1 and 2147483647);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'invoice_items_unit_amount_cents_max_004b') then
    alter table public.invoice_items add constraint invoice_items_unit_amount_cents_max_004b check (unit_amount_cents between 1 and 2147483647);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'invoice_items_amount_cents_max_004b') then
    alter table public.invoice_items add constraint invoice_items_amount_cents_max_004b check (amount_cents between 1 and 2147483647);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payment_intents_amount_cents_max_004b') then
    alter table public.payment_intents add constraint payment_intents_amount_cents_max_004b check (amount_cents between 1 and 2147483647);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payments_amount_cents_max_004b') then
    alter table public.payments add constraint payments_amount_cents_max_004b check (amount_cents between 1 and 2147483647);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'refunds_amount_cents_max_004b') then
    alter table public.refunds add constraint refunds_amount_cents_max_004b check (amount_cents between 1 and 2147483647);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'chargebacks_amount_cents_max_004b') then
    alter table public.chargebacks add constraint chargebacks_amount_cents_max_004b check (amount_cents between 1 and 2147483647);
  end if;
end $$;
