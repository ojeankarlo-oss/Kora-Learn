-- KORA Payments P1-PAY-API-002
-- Machine-to-machine applications, hash-only credentials, scopes and audit.
-- No financial endpoints, provider calls, seeds with customer data, or production writes.

create table if not exists public.payment_api_applications (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 160),
  slug text not null check (slug ~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$'),
  status text not null default 'active' check (status in ('active', 'suspended', 'revoked')),
  environment text not null default 'sandbox' check (environment in ('sandbox', 'staging', 'production')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, slug),
  unique (id, tenant_id)
);

create index if not exists idx_payment_api_applications_tenant_status
  on public.payment_api_applications (tenant_id, status, environment);

create table if not exists public.payment_api_credentials (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null,
  tenant_id uuid not null,
  public_prefix text not null check (public_prefix ~ '^kp_[a-z]+_[A-Za-z0-9_-]{8,32}$'),
  credential_hash text not null check (credential_hash ~ '^[0-9a-f]{64}$'),
  environment text not null check (environment in ('sandbox', 'staging', 'production')),
  status text not null default 'active' check (status in ('active', 'revoked')),
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  last_used_at timestamptz,
  rotated_from_id uuid references public.payment_api_credentials(id) on delete set null,
  rotated_at timestamptz,
  unique (credential_hash),
  unique (application_id, public_prefix),
  unique (id, tenant_id),
  foreign key (application_id, tenant_id)
    references public.payment_api_applications(id, tenant_id)
    on delete cascade,
  check ((status = 'active' and revoked_at is null) or (status = 'revoked' and revoked_at is not null)),
  check (expires_at is null or expires_at > created_at),
  check (rotated_at is null or rotated_at >= created_at)
);

create index if not exists idx_payment_api_credentials_lookup
  on public.payment_api_credentials (environment, public_prefix, status, expires_at);

create table if not exists public.payment_api_scopes (
  code text primary key check (code ~ '^[a-z][a-z0-9_]*:[a-z][a-z0-9_]*$'),
  description text not null,
  created_at timestamptz not null default now()
);

insert into public.payment_api_scopes (code, description) values
  ('customers:read', 'Read billing customers'),
  ('customers:write', 'Create and update billing customers'),
  ('invoices:read', 'Read invoices'),
  ('invoices:write', 'Create and update invoices'),
  ('payments:read', 'Read payments'),
  ('payment_intents:write', 'Create payment intents'),
  ('refunds:write', 'Request refunds'),
  ('events:read', 'Read KORA billing events')
on conflict (code) do update set description = excluded.description;

create table if not exists public.payment_api_credential_scopes (
  credential_id uuid not null,
  tenant_id uuid not null,
  scope_code text not null references public.payment_api_scopes(code) on delete restrict,
  granted_at timestamptz not null default now(),
  granted_by uuid references public.usuarios(id) on delete set null,
  primary key (credential_id, scope_code),
  foreign key (credential_id, tenant_id)
    references public.payment_api_credentials(id, tenant_id)
    on delete cascade
);

create index if not exists idx_payment_api_credential_scopes_tenant
  on public.payment_api_credential_scopes (tenant_id, credential_id);

create table if not exists public.payment_api_audit (
  id uuid primary key default gen_random_uuid(),
  credential_id uuid,
  application_id uuid,
  tenant_id uuid,
  request_id text,
  event_type text not null check (event_type in ('created', 'rotated', 'revoked', 'reactivated', 'auth_succeeded', 'auth_failed')),
  outcome text check (outcome is null or outcome in ('success', 'failure')),
  reason text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (credential_id, tenant_id)
    references public.payment_api_credentials(id, tenant_id)
    on delete set null,
  foreign key (application_id, tenant_id)
    references public.payment_api_applications(id, tenant_id)
    on delete set null,
  check (request_id is null or length(request_id) between 1 and 128),
  check (reason is null or length(reason) <= 160)
);

create index if not exists idx_payment_api_audit_tenant_created
  on public.payment_api_audit (tenant_id, created_at desc);

create index if not exists idx_payment_api_audit_credential_created
  on public.payment_api_audit (credential_id, created_at desc);

alter table public.payment_api_applications enable row level security;
alter table public.payment_api_credentials enable row level security;
alter table public.payment_api_scopes enable row level security;
alter table public.payment_api_credential_scopes enable row level security;
alter table public.payment_api_audit enable row level security;

drop policy if exists payment_api_applications_staff_read on public.payment_api_applications;
create policy payment_api_applications_staff_read
  on public.payment_api_applications for select to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff());

drop policy if exists payment_api_credential_scopes_staff_read on public.payment_api_credential_scopes;
create policy payment_api_credential_scopes_staff_read
  on public.payment_api_credential_scopes for select to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff());

drop policy if exists payment_api_audit_staff_read on public.payment_api_audit;
create policy payment_api_audit_staff_read
  on public.payment_api_audit for select to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff());

create or replace function public.payment_api_audit_auth_attempt(
  p_credential_id uuid,
  p_application_id uuid,
  p_tenant_id uuid,
  p_request_id text,
  p_success boolean,
  p_reason text
) returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.payment_api_audit(
    credential_id, application_id, tenant_id, request_id,
    event_type, outcome, reason
  ) values (
    p_credential_id, p_application_id, p_tenant_id, left(p_request_id, 128),
    case when p_success then 'auth_succeeded' else 'auth_failed' end,
    case when p_success then 'success' else 'failure' end,
    left(p_reason, 160)
  );
end;
$$;

revoke all on function public.payment_api_audit_auth_attempt(uuid, uuid, uuid, text, boolean, text)
  from public, anon, authenticated;
grant execute on function public.payment_api_audit_auth_attempt(uuid, uuid, uuid, text, boolean, text)
  to service_role;

create or replace function public.payment_api_touch_credential(
  p_credential_id uuid,
  p_request_id text
) returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.payment_api_credentials
  set last_used_at = pg_catalog.now()
  where id = p_credential_id and status = 'active' and revoked_at is null;

  insert into public.payment_api_audit(
    credential_id, application_id, tenant_id, request_id,
    event_type, outcome, reason
  )
  select c.id, c.application_id, c.tenant_id, left(p_request_id, 128),
    'auth_succeeded', 'success', 'credential_authenticated'
  from public.payment_api_credentials c
  where c.id = p_credential_id and c.status = 'active' and c.revoked_at is null;
end;
$$;

revoke all on function public.payment_api_touch_credential(uuid, text)
  from public, anon, authenticated;
grant execute on function public.payment_api_touch_credential(uuid, text)
  to service_role;

create or replace function public.payment_api_validate_application_tenant()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not exists (select 1 from public.tenants t where t.id = new.tenant_id) then
    raise exception 'payment API tenant not found';
  end if;
  return new;
end;
$$;

revoke all on function public.payment_api_validate_application_tenant()
  from public, anon, authenticated;
grant execute on function public.payment_api_validate_application_tenant()
  to service_role;

drop trigger if exists trg_payment_api_application_tenant on public.payment_api_applications;
create trigger trg_payment_api_application_tenant
before insert or update on public.payment_api_applications
for each row execute function public.payment_api_validate_application_tenant();

create or replace function public.payment_api_audit_credential_mutation()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_event text;
begin
  if tg_op = 'INSERT' then
    v_event := case when new.rotated_from_id is null then 'created' else 'rotated' end;
  elsif new.status = 'revoked' and old.status <> 'revoked' then
    v_event := 'revoked';
  elsif new.status = 'active' and old.status = 'revoked' then
    v_event := 'reactivated';
  elsif new.rotated_from_id is distinct from old.rotated_from_id
     or new.rotated_at is distinct from old.rotated_at then
    v_event := 'rotated';
  else
    return new;
  end if;

  insert into public.payment_api_audit(
    credential_id, application_id, tenant_id, event_type, outcome
  ) values (
    new.id, new.application_id, new.tenant_id, v_event, 'success'
  );
  return new;
end;
$$;

revoke all on function public.payment_api_audit_credential_mutation()
  from public, anon, authenticated;
grant execute on function public.payment_api_audit_credential_mutation()
  to service_role;

drop trigger if exists trg_payment_api_credential_audit on public.payment_api_credentials;
create trigger trg_payment_api_credential_audit
after insert or update of status, revoked_at, rotated_from_id, rotated_at
on public.payment_api_credentials
for each row execute function public.payment_api_audit_credential_mutation();

-- Credential hashes, secrets, and write paths remain server-side only.
grant select on table public.payment_api_applications to authenticated;
grant select on table public.payment_api_credential_scopes to authenticated;
grant select on table public.payment_api_audit to authenticated;
grant select on table public.payment_api_scopes to authenticated;
revoke all on table public.payment_api_credentials from anon, authenticated;
revoke all on table public.payment_api_credential_scopes from anon;
revoke all on table public.payment_api_audit from anon;
revoke all on table public.payment_api_applications from anon;
revoke all on table public.payment_api_scopes from anon;
