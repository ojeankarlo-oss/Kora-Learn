-- KORA Payments P1-PAY-API-002B
-- Canonical server-side credential provenance, rotation and revocation.
-- Do not accept caller-supplied secrets; no financial endpoints or provider calls.

create extension if not exists pgcrypto;

alter table public.payment_api_credentials
  add column if not exists credential_provenance text not null default 'legacy_unverified';

alter table public.payment_api_credentials
  drop constraint if exists payment_api_credentials_provenance_check;

alter table public.payment_api_credentials
  add constraint payment_api_credentials_provenance_check
  check (credential_provenance in ('legacy_unverified', 'server_csprng_v1'));

-- Existing 032 rows are intentionally legacy-unverified and must fail closed in
-- the application auth helper until reissued by the canonical RPC.
do $$
begin
  if exists (
    select 1
    from public.payment_api_credentials
    where status = 'active'
      and credential_provenance = 'server_csprng_v1'
    group by application_id
    having count(*) > 1
  ) then
    raise exception 'cannot establish one active canonical credential per application';
  end if;
end $$;

create unique index if not exists uq_payment_api_credentials_one_active_canonical
  on public.payment_api_credentials(application_id)
  where status = 'active' and credential_provenance = 'server_csprng_v1';

create or replace function public.payment_api_issue_credential(
  p_application_id uuid,
  p_tenant_id uuid,
  p_scopes text[],
  p_expires_at timestamptz,
  p_rotated_from_id uuid,
  p_request_id text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  app public.payment_api_applications%rowtype;
  tenant_active boolean;
  v_credential_id uuid;
  v_scope_codes text[];
  v_public_id text;
  v_secret_suffix text;
  v_raw_secret text;
  v_public_prefix text;
  v_credential_hash text;
  v_audit_id uuid;
  now_value timestamptz := pg_catalog.now();
begin
  select * into app
  from public.payment_api_applications
  where id = p_application_id and tenant_id = p_tenant_id
  for update;
  if not found or app.status <> 'active' then
    raise exception 'application unavailable';
  end if;

  select t.ativo into tenant_active
  from public.tenants t
  where t.id = p_tenant_id;
  if coalesce(tenant_active, false) is not true then
    raise exception 'tenant unavailable';
  end if;

  if p_expires_at is not null and p_expires_at <= now_value then
    raise exception 'credential expiry must be in the future';
  end if;

  if p_rotated_from_id is not null and not exists (
    select 1
    from public.payment_api_credentials previous
    where previous.id = p_rotated_from_id
      and previous.application_id = app.id
      and previous.tenant_id = app.tenant_id
      and previous.status = 'revoked'
  ) then
    raise exception 'rotation lineage mismatch';
  end if;

  select coalesce(array_agg(normalized_scope order by normalized_scope), array[]::text[])
  into v_scope_codes
  from (
    select distinct pg_catalog.lower(pg_catalog.btrim(scope_value)) as normalized_scope
    from pg_catalog.unnest(coalesce(p_scopes, array[]::text[])) as input_scope(scope_value)
    where pg_catalog.btrim(scope_value) <> ''
  ) normalized;

  if exists (
    select 1
    from pg_catalog.unnest(v_scope_codes) as requested_scope(scope_code)
    where not exists (
      select 1 from public.payment_api_scopes s where s.code = requested_scope.scope_code
    )
  ) then
    raise exception 'unknown payment API scope';
  end if;

  v_public_id := encode(extensions.gen_random_bytes(8), 'hex');
  v_secret_suffix := translate(encode(extensions.gen_random_bytes(32), 'base64'), E'+/=', '-_');
  v_raw_secret := format('kp_%s_%s_%s', app.environment, v_public_id, v_secret_suffix);
  v_public_prefix := format('kp_%s_%s', app.environment, v_public_id);
  v_credential_hash := encode(extensions.digest(v_raw_secret, 'sha256'), 'hex');

  insert into public.payment_api_credentials(
    application_id, tenant_id, public_prefix, credential_hash,
    environment, status, expires_at, rotated_from_id,
    rotated_at, credential_provenance
  ) values (
    app.id, app.tenant_id, v_public_prefix, v_credential_hash,
    app.environment, 'active', p_expires_at, p_rotated_from_id,
    case when p_rotated_from_id is null then null else now_value end,
    'server_csprng_v1'
  ) returning id into v_credential_id;

  insert into public.payment_api_credential_scopes(credential_id, tenant_id, scope_code)
  select v_credential_id, app.tenant_id, requested_scope
  from pg_catalog.unnest(v_scope_codes) as requested(requested_scope);

  select a.id into v_audit_id
  from public.payment_api_audit a
  where a.credential_id = v_credential_id
    and a.event_type = case when p_rotated_from_id is null then 'created' else 'rotated' end
  order by a.created_at desc, a.id desc
  limit 1;

  update public.payment_api_audit
  set request_id = pg_catalog.left(p_request_id, 128)
  where id = v_audit_id;

  return jsonb_build_object(
    'credential_id', v_credential_id,
    'application_id', app.id,
    'tenant_id', app.tenant_id,
    'public_prefix', v_public_prefix,
    'environment', app.environment,
    'expires_at', p_expires_at,
    'scopes', to_jsonb(v_scope_codes),
    'secret', v_raw_secret
  );
end;
$$;

revoke all on function public.payment_api_issue_credential(uuid, uuid, text[], timestamptz, uuid, text)
  from public, anon, authenticated;
grant execute on function public.payment_api_issue_credential(uuid, uuid, text[], timestamptz, uuid, text)
  to service_role;

create or replace function public.create_payment_api_credential(
  p_application_id uuid,
  p_scopes text[] default array[]::text[],
  p_expires_at timestamptz default null,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  application_tenant uuid;
begin
  select tenant_id into application_tenant
  from public.payment_api_applications
  where id = p_application_id;
  if application_tenant is null then
    raise exception 'application unavailable';
  end if;

  return public.payment_api_issue_credential(
    p_application_id, application_tenant, p_scopes,
    p_expires_at, null, p_request_id
  );
end;
$$;

revoke all on function public.create_payment_api_credential(uuid, text[], timestamptz, text)
  from public, anon, authenticated;
grant execute on function public.create_payment_api_credential(uuid, text[], timestamptz, text)
  to service_role;

create or replace function public.rotate_payment_api_credential(
  p_credential_id uuid,
  p_scopes text[] default null,
  p_expires_at timestamptz default null,
  p_request_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  old_credential public.payment_api_credentials%rowtype;
  old_scopes text[];
  next_expiry timestamptz;
  result jsonb;
  v_audit_id uuid;
begin
  select * into old_credential
  from public.payment_api_credentials
  where id = p_credential_id
  for update;
  if not found or old_credential.status <> 'active' then
    raise exception 'credential unavailable for rotation';
  end if;

  select coalesce(array_agg(scope_code order by scope_code), array[]::text[])
  into old_scopes
  from public.payment_api_credential_scopes
  where credential_id = old_credential.id and tenant_id = old_credential.tenant_id;

  next_expiry := coalesce(p_expires_at, old_credential.expires_at);

  -- Revoke first inside this transaction. The new insert and scope copy must
  -- succeed or the whole transaction rolls back and the old credential stays active.
  update public.payment_api_credentials
  set status = 'revoked', revoked_at = pg_catalog.now()
  where id = old_credential.id;

  select public.payment_api_issue_credential(
    old_credential.application_id,
    old_credential.tenant_id,
    case when p_scopes is null then old_scopes else p_scopes end,
    next_expiry,
    old_credential.id,
    p_request_id
  ) into result;

  select a.id into v_audit_id
  from public.payment_api_audit a
  where a.credential_id = old_credential.id and a.event_type = 'revoked'
  order by a.created_at desc, a.id desc
  limit 1;
  update public.payment_api_audit
  set request_id = pg_catalog.left(p_request_id, 128), reason = 'rotated'
  where id = v_audit_id;

  return result;
end;
$$;

revoke all on function public.rotate_payment_api_credential(uuid, text[], timestamptz, text)
  from public, anon, authenticated;
grant execute on function public.rotate_payment_api_credential(uuid, text[], timestamptz, text)
  to service_role;

create or replace function public.revoke_payment_api_credential(
  p_credential_id uuid,
  p_request_id text default null,
  p_reason text default 'revoked_by_operator'
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  old_credential public.payment_api_credentials%rowtype;
  v_audit_id uuid;
begin
  select * into old_credential
  from public.payment_api_credentials
  where id = p_credential_id
  for update;
  if not found then
    raise exception 'credential not found';
  end if;

  if old_credential.status = 'revoked' then
    return jsonb_build_object('credential_id', old_credential.id, 'revoked', true, 'already_revoked', true);
  end if;

  update public.payment_api_credentials
  set status = 'revoked', revoked_at = coalesce(revoked_at, pg_catalog.now())
  where id = old_credential.id;

  select a.id into v_audit_id
  from public.payment_api_audit a
  where a.credential_id = old_credential.id and a.event_type = 'revoked'
  order by a.created_at desc, a.id desc
  limit 1;
  update public.payment_api_audit
  set request_id = pg_catalog.left(p_request_id, 128), reason = pg_catalog.left(p_reason, 160)
  where id = v_audit_id;

  return jsonb_build_object('credential_id', old_credential.id, 'revoked', true, 'already_revoked', false);
end;
$$;

revoke all on function public.revoke_payment_api_credential(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.revoke_payment_api_credential(uuid, text, text)
  to service_role;

-- Direct table writes are not an API surface. Only the canonical service-role
-- functions above may create, rotate or revoke M2M credentials.
revoke all on table public.payment_api_credentials from public, anon, authenticated;
revoke insert, update, delete on table public.payment_api_credential_scopes from public, anon, authenticated;
revoke insert, update, delete on table public.payment_api_audit from public, anon, authenticated;
