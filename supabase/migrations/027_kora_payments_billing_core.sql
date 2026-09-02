-- KORA Payments foundation: provider-neutral billing system of record.
-- No provider call, charge, seed, backfill, or financial data mutation.

create table if not exists billing_accounts (
  id uuid primary key default gen_random_uuid(), account_type text not null check (account_type in ('tenant', 'kora')),
  tenant_id uuid references tenants(id) on delete cascade, display_name text not null,
  status text not null default 'active' check (status in ('active', 'suspended', 'closed')), created_at timestamptz not null default now(),
  check ((account_type = 'tenant' and tenant_id is not null) or (account_type = 'kora' and tenant_id is null))
);
create table if not exists billing_customers (
  id uuid primary key default gen_random_uuid(), billing_account_id uuid not null references billing_accounts(id) on delete cascade,
  tenant_id uuid references tenants(id) on delete cascade, user_id uuid references usuarios(id) on delete set null,
  name text not null, email text, provider_customer_id text, created_at timestamptz not null default now()
);
create table if not exists provider_accounts (
  id uuid primary key default gen_random_uuid(), billing_account_id uuid not null references billing_accounts(id) on delete cascade,
  tenant_id uuid references tenants(id) on delete cascade, provider text not null, environment text not null default 'sandbox' check (environment in ('sandbox', 'production')),
  external_account_id text, secret_reference text, status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(), unique (billing_account_id, provider, environment)
);
create table if not exists subscriptions (
  id uuid primary key default gen_random_uuid(), billing_account_id uuid not null references billing_accounts(id) on delete cascade,
  customer_id uuid not null references billing_customers(id) on delete restrict, provider_account_id uuid references provider_accounts(id) on delete set null,
  provider text, provider_subscription_id text, status text not null default 'active' check (status in ('active', 'past_due', 'cancelled', 'suspended')),
  due_policy jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create table if not exists invoices (
  id uuid primary key default gen_random_uuid(), billing_account_id uuid not null references billing_accounts(id) on delete restrict,
  tenant_id uuid references tenants(id) on delete cascade, customer_id uuid not null references billing_customers(id) on delete restrict,
  subscription_id uuid references subscriptions(id) on delete set null, amount_cents integer not null check (amount_cents > 0), currency text not null default 'BRL' check (currency = 'BRL'),
  description text not null, due_date date, status text not null default 'open' check (status in ('draft', 'open', 'paid', 'past_due', 'void', 'cancelled')),
  paid_at timestamptz, created_at timestamptz not null default now()
);
create table if not exists invoice_items (
  id uuid primary key default gen_random_uuid(), invoice_id uuid not null references invoices(id) on delete cascade,
  description text not null, quantity integer not null default 1 check (quantity > 0), unit_amount_cents integer not null check (unit_amount_cents > 0), amount_cents integer not null check (amount_cents > 0)
);
create table if not exists payment_intents (
  id uuid primary key default gen_random_uuid(), billing_account_id uuid not null references billing_accounts(id) on delete restrict,
  tenant_id uuid references tenants(id) on delete cascade, invoice_id uuid not null references invoices(id) on delete restrict,
  provider_account_id uuid references provider_accounts(id) on delete set null, provider text not null, amount_cents integer not null check (amount_cents > 0),
  status text not null default 'created' check (status in ('created', 'pending', 'confirmed', 'failed', 'cancelled')), idempotency_key text, created_at timestamptz not null default now(), unique (provider, idempotency_key)
);
create table if not exists payment_attempts (
  id uuid primary key default gen_random_uuid(), payment_intent_id uuid not null references payment_intents(id) on delete cascade,
  provider text not null, provider_payment_id text, status text not null default 'created', error_code text, created_at timestamptz not null default now()
);
create table if not exists payments (
  id uuid primary key default gen_random_uuid(), billing_account_id uuid not null references billing_accounts(id) on delete restrict,
  tenant_id uuid references tenants(id) on delete cascade, invoice_id uuid not null unique references invoices(id) on delete restrict,
  payment_intent_id uuid references payment_intents(id) on delete set null, provider text not null, provider_payment_id text not null,
  amount_cents integer not null check (amount_cents > 0), status text not null default 'confirmed' check (status in ('confirmed', 'refunded', 'chargeback')),
  paid_at timestamptz not null default now(), unique (provider, provider_payment_id)
);
create table if not exists refunds (
  id uuid primary key default gen_random_uuid(), payment_id uuid not null references payments(id) on delete restrict, provider_refund_id text,
  amount_cents integer not null check (amount_cents > 0), status text not null default 'requested', created_at timestamptz not null default now()
);
create table if not exists chargebacks (
  id uuid primary key default gen_random_uuid(), payment_id uuid not null references payments(id) on delete restrict, provider_case_id text,
  amount_cents integer not null check (amount_cents > 0), status text not null default 'open', created_at timestamptz not null default now()
);
create table if not exists provider_transactions (
  id uuid primary key default gen_random_uuid(), provider text not null, provider_account_id uuid references provider_accounts(id) on delete set null,
  provider_transaction_id text not null, payment_id uuid references payments(id) on delete set null, payload jsonb not null default '{}'::jsonb, created_at timestamptz not null default now(), unique (provider, provider_transaction_id)
);
create table if not exists webhook_events (
  id uuid primary key default gen_random_uuid(), provider text not null, provider_event_id text not null, event_type text not null, payload jsonb not null,
  processed_at timestamptz, created_at timestamptz not null default now(), unique (provider, provider_event_id)
);
create table if not exists billing_events (
  id uuid primary key default gen_random_uuid(), billing_account_id uuid references billing_accounts(id) on delete set null, tenant_id uuid references tenants(id) on delete set null,
  event_type text not null, aggregate_type text not null, aggregate_id uuid, correlation_id text, payload jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create table if not exists reconciliation_events (
  id uuid primary key default gen_random_uuid(), provider text not null, provider_account_id uuid references provider_accounts(id) on delete set null,
  provider_transaction_id text, status text not null, details jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);

create index if not exists idx_billing_customers_tenant on billing_customers(tenant_id);
create index if not exists idx_invoices_tenant_status on invoices(tenant_id, status, due_date);
create index if not exists idx_payment_intents_tenant on payment_intents(tenant_id, created_at desc);
create index if not exists idx_billing_events_tenant on billing_events(tenant_id, created_at desc);
create index if not exists idx_provider_transactions_payment on provider_transactions(payment_id);

alter table billing_accounts enable row level security;
alter table billing_customers enable row level security;
alter table provider_accounts enable row level security;
alter table subscriptions enable row level security;
alter table invoices enable row level security;
alter table invoice_items enable row level security;
alter table payment_intents enable row level security;
alter table payment_attempts enable row level security;
alter table payments enable row level security;
alter table refunds enable row level security;
alter table chargebacks enable row level security;
alter table provider_transactions enable row level security;
alter table webhook_events enable row level security;
alter table billing_events enable row level security;
alter table reconciliation_events enable row level security;

create policy billing_accounts_tenant on billing_accounts for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy billing_customers_tenant on billing_customers for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy provider_accounts_tenant on provider_accounts for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy subscriptions_tenant on subscriptions for all to authenticated using (billing_account_id in (select id from billing_accounts where tenant_id = public.current_tenant_id()) and public.is_staff()) with check (billing_account_id in (select id from billing_accounts where tenant_id = public.current_tenant_id()) and public.is_staff());
create policy invoices_tenant on invoices for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy invoice_items_tenant on invoice_items for all to authenticated using (invoice_id in (select id from invoices where tenant_id = public.current_tenant_id()) and public.is_staff()) with check (invoice_id in (select id from invoices where tenant_id = public.current_tenant_id()) and public.is_staff());
create policy payment_intents_tenant on payment_intents for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy payments_tenant on payments for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy billing_events_tenant on billing_events for select to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff());