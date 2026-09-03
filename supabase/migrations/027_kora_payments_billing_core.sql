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
alter table refunds add constraint refunds_status_check check (status in ('requested', 'processing', 'refunded', 'failed'));
alter table chargebacks add constraint chargebacks_status_check check (status in ('open', 'won', 'lost'));
alter table payment_attempts add constraint payment_attempts_status_check check (status in ('created', 'pending', 'succeeded', 'failed', 'cancelled'));

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
create policy invoices_tenant on invoices for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy invoice_items_tenant on invoice_items for all to authenticated using (invoice_id in (select id from invoices where tenant_id = public.current_tenant_id()) and public.is_staff()) with check (invoice_id in (select id from invoices where tenant_id = public.current_tenant_id()) and public.is_staff());
create policy payment_intents_tenant on payment_intents for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy payments_tenant on payments for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy billing_events_tenant on billing_events for select to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff());

-- Cross-tenant integrity is enforced in the database, including relationships
-- whose tenant is derived from another aggregate.
alter table subscriptions add column if not exists tenant_id uuid references tenants(id) on delete cascade;
alter table payment_attempts add column if not exists tenant_id uuid references tenants(id) on delete cascade;
alter table refunds add column if not exists tenant_id uuid references tenants(id) on delete cascade;
alter table chargebacks add column if not exists tenant_id uuid references tenants(id) on delete cascade;
alter table provider_transactions add column if not exists tenant_id uuid references tenants(id) on delete cascade;
alter table webhook_events add column if not exists tenant_id uuid references tenants(id) on delete cascade;
alter table webhook_events add column if not exists status text not null default 'received' check (status in ('received', 'processing', 'processed', 'failed', 'rejected'));
alter table webhook_events add column if not exists processed_at timestamptz;
alter table webhook_events add column if not exists failed_at timestamptz;
alter table webhook_events add column if not exists invoice_id uuid references invoices(id) on delete set null;
alter table webhook_events add column if not exists payment_intent_id uuid references payment_intents(id) on delete set null;
alter table webhook_events add column if not exists provider_payment_id text;

create unique index if not exists uq_billing_accounts_id_tenant on billing_accounts(id, tenant_id);
create unique index if not exists uq_billing_customers_id_tenant on billing_customers(id, tenant_id);
create unique index if not exists uq_provider_accounts_id_tenant on provider_accounts(id, tenant_id);
create unique index if not exists uq_invoices_id_tenant on invoices(id, tenant_id);
create unique index if not exists uq_payment_intents_id_tenant on payment_intents(id, tenant_id);
create unique index if not exists uq_payments_id_tenant on payments(id, tenant_id);

create or replace function public.validate_kora_billing_tenant()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare related_tenant uuid;
begin
  if tg_table_name = 'billing_customers' then
    select tenant_id into related_tenant from public.billing_accounts where id = new.billing_account_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'billing customer tenant mismatch'; end if;
  elsif tg_table_name = 'provider_accounts' then
    select tenant_id into related_tenant from public.billing_accounts where id = new.billing_account_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'provider account tenant mismatch'; end if;
  elsif tg_table_name = 'subscriptions' then
    select tenant_id into related_tenant from public.billing_customers where id = new.customer_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'subscription customer tenant mismatch'; end if;
  elsif tg_table_name = 'invoices' then
    select tenant_id into related_tenant from public.billing_customers where id = new.customer_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'invoice customer tenant mismatch'; end if;
    if new.subscription_id is not null then
      select tenant_id into related_tenant from public.subscriptions where id = new.subscription_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'invoice subscription tenant mismatch'; end if;
    end if;
  elsif tg_table_name = 'payment_intents' then
    select tenant_id into related_tenant from public.invoices where id = new.invoice_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'payment intent invoice tenant mismatch'; end if;
    if new.provider_account_id is not null then
      select tenant_id into related_tenant from public.provider_accounts where id = new.provider_account_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'payment intent provider tenant mismatch'; end if;
    end if;
  elsif tg_table_name = 'payments' then
    select tenant_id into related_tenant from public.invoices where id = new.invoice_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'payment invoice tenant mismatch'; end if;
  elsif tg_table_name = 'payment_attempts' then
    select tenant_id into related_tenant from public.payment_intents where id = new.payment_intent_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'payment attempt tenant mismatch'; end if;
  elsif tg_table_name in ('refunds', 'chargebacks') then
    select tenant_id into related_tenant from public.payments where id = new.payment_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'payment adjustment tenant mismatch'; end if;
  elsif tg_table_name = 'provider_transactions' then
    if new.payment_id is not null then
      select tenant_id into related_tenant from public.payments where id = new.payment_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'provider transaction payment tenant mismatch'; end if;
    end if;
    if new.provider_account_id is not null then
      select tenant_id into related_tenant from public.provider_accounts where id = new.provider_account_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'provider transaction account tenant mismatch'; end if;
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.validate_kora_billing_tenant() from public, anon, authenticated;
grant execute on function public.validate_kora_billing_tenant() to service_role;
create trigger trg_billing_customers_tenant before insert or update on billing_customers for each row execute function public.validate_kora_billing_tenant();
create trigger trg_provider_accounts_tenant before insert or update on provider_accounts for each row execute function public.validate_kora_billing_tenant();
create trigger trg_subscriptions_tenant before insert or update on subscriptions for each row execute function public.validate_kora_billing_tenant();
create trigger trg_invoices_tenant before insert or update on invoices for each row execute function public.validate_kora_billing_tenant();
create trigger trg_payment_intents_tenant before insert or update on payment_intents for each row execute function public.validate_kora_billing_tenant();
create trigger trg_payments_tenant before insert or update on payments for each row execute function public.validate_kora_billing_tenant();
create trigger trg_payment_attempts_tenant before insert or update on payment_attempts for each row execute function public.validate_kora_billing_tenant();
create trigger trg_refunds_tenant before insert or update on refunds for each row execute function public.validate_kora_billing_tenant();
create trigger trg_chargebacks_tenant before insert or update on chargebacks for each row execute function public.validate_kora_billing_tenant();
create trigger trg_provider_transactions_tenant before insert or update on provider_transactions for each row execute function public.validate_kora_billing_tenant();

create or replace function public.enforce_kora_billing_state()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if tg_table_name = 'invoices' and old.status is distinct from new.status and not (
    (old.status in ('draft', 'open', 'past_due') and new.status in ('open', 'past_due', 'paid', 'void', 'cancelled'))
    or (old.status = 'paid' and new.status = 'paid')
    or (old.status = 'cancelled' and new.status = 'cancelled')
    or (old.status = 'void' and new.status = 'void')
  ) then raise exception 'invalid invoice state transition: % -> %', old.status, new.status; end if;
  if tg_table_name = 'payment_intents' and old.status is distinct from new.status and not (
    (old.status in ('created', 'pending') and new.status in ('pending', 'confirmed', 'failed', 'cancelled'))
    or (old.status in ('confirmed', 'failed', 'cancelled') and new.status = old.status)
  ) then raise exception 'invalid payment intent state transition: % -> %', old.status, new.status; end if;
  if tg_table_name = 'payment_attempts' and old.status is distinct from new.status and not ((old.status in ('created', 'pending') and new.status in ('pending', 'succeeded', 'failed', 'cancelled')) or (old.status in ('succeeded', 'failed', 'cancelled') and new.status = old.status)) then raise exception 'invalid payment attempt state transition: % -> %', old.status, new.status; end if;
  if tg_table_name = 'refunds' and old.status is distinct from new.status and not ((old.status in ('requested', 'processing') and new.status in ('processing', 'refunded', 'failed')) or (old.status in ('refunded', 'failed') and new.status = old.status)) then raise exception 'invalid refund state transition: % -> %', old.status, new.status; end if;
  if tg_table_name = 'chargebacks' and old.status is distinct from new.status and not ((old.status = 'open' and new.status in ('won', 'lost')) or (old.status in ('won', 'lost') and new.status = old.status)) then raise exception 'invalid chargeback state transition: % -> %', old.status, new.status; end if;
  if tg_table_name = 'payments' and old.status is distinct from new.status and not (old.status = 'confirmed' and new.status in ('refunded', 'chargeback')) then raise exception 'invalid payment state transition: % -> %', old.status, new.status; end if;
  if tg_table_name = 'webhook_events' and old.status is distinct from new.status and not ((old.status in ('received', 'processing') and new.status in ('processing', 'processed', 'failed', 'rejected')) or (old.status = 'failed' and new.status in ('processing', 'failed')) or (old.status in ('processed', 'rejected') and new.status = old.status)) then raise exception 'invalid webhook state transition: % -> %', old.status, new.status; end if;
  return new;
end;
$$;
revoke all on function public.enforce_kora_billing_state() from public, anon, authenticated;
grant execute on function public.enforce_kora_billing_state() to service_role;
create trigger trg_invoice_state before update on invoices for each row execute function public.enforce_kora_billing_state();
create trigger trg_payment_intent_state before update on payment_intents for each row execute function public.enforce_kora_billing_state();
create trigger trg_payment_state before update on payments for each row execute function public.enforce_kora_billing_state();
create trigger trg_payment_attempt_state before update on payment_attempts for each row execute function public.enforce_kora_billing_state();
create trigger trg_refund_state before update on refunds for each row execute function public.enforce_kora_billing_state();
create trigger trg_chargeback_state before update on chargebacks for each row execute function public.enforce_kora_billing_state();
create trigger trg_webhook_state before update on webhook_events for each row execute function public.enforce_kora_billing_state();

-- One transaction owns event deduplication, correlation, payment creation,
-- invoice settlement and audit. A failed call rolls back the event insert.
create or replace function public.process_asaas_webhook_atomic(
  p_provider text, p_provider_account_id uuid, p_payment_intent_id uuid,
  p_invoice_id uuid, p_provider_payment_id text, p_event_type text,
  p_amount_cents integer, p_currency text, p_payload jsonb
) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  intent public.payment_intents%rowtype;
  invoice public.invoices%rowtype;
  account public.provider_accounts%rowtype;
  existing_event public.webhook_events%rowtype;
  event_id uuid;
  payment_record_id uuid;
begin
  if p_provider <> 'asaas' or p_provider_payment_id is null or p_event_type not in ('PAYMENT_RECEIVED', 'PAYMENT_CONFIRMED') then raise exception 'invalid provider webhook'; end if;
  select * into intent from public.payment_intents where id = p_payment_intent_id for update;
  if not found then raise exception 'payment intent not found'; end if;
  select * into invoice from public.invoices where id = p_invoice_id for update;
  if not found or invoice.id <> intent.invoice_id or invoice.tenant_id is distinct from intent.tenant_id then raise exception 'invoice correlation failed'; end if;
  if intent.provider <> p_provider or intent.provider_account_id is distinct from p_provider_account_id then raise exception 'provider account correlation failed'; end if;
  select * into account from public.provider_accounts where id = p_provider_account_id and tenant_id = invoice.tenant_id for update;
  if not found or account.provider <> p_provider then raise exception 'provider account not found'; end if;
  if not exists (select 1 from public.payment_attempts where payment_intent_id = intent.id and tenant_id = invoice.tenant_id and provider = p_provider and provider_payment_id = p_provider_payment_id) then raise exception 'provider payment is not linked to payment intent'; end if;
  if invoice.currency <> p_currency or invoice.amount_cents <> p_amount_cents or intent.amount_cents <> p_amount_cents then raise exception 'amount or currency mismatch'; end if;
  if invoice.status not in ('open', 'past_due') or intent.status not in ('created', 'pending') then raise exception 'invalid financial state'; end if;

  insert into public.webhook_events(provider, provider_event_id, event_type, payload, tenant_id, status, invoice_id, payment_intent_id, provider_payment_id)
  values (p_provider, p_provider_payment_id || ':' || p_event_type, p_event_type, p_payload, invoice.tenant_id, 'processing', invoice.id, intent.id, p_provider_payment_id)
  on conflict (provider, provider_event_id) do nothing
  returning id into event_id;
  if event_id is null then
    select * into existing_event from public.webhook_events where provider = p_provider and provider_event_id = p_provider_payment_id || ':' || p_event_type for update;
    if existing_event.status = 'processed' then return jsonb_build_object('duplicate', true); end if;
    raise exception 'webhook event already processing';
  end if;

  insert into public.provider_transactions(tenant_id, provider, provider_account_id, provider_transaction_id, payload)
  values (invoice.tenant_id, p_provider, p_provider_account_id, p_provider_payment_id, p_payload)
  on conflict (provider, provider_transaction_id) do nothing;
  if exists (select 1 from public.provider_transactions where provider = p_provider and provider_transaction_id = p_provider_payment_id and (tenant_id <> invoice.tenant_id or provider_account_id <> p_provider_account_id)) then raise exception 'provider transaction correlation failed'; end if;
  if exists (select 1 from public.payments where invoice_id = invoice.id and (provider <> p_provider or provider_payment_id <> p_provider_payment_id)) then raise exception 'invoice already linked to another provider payment'; end if;
  insert into public.payments(billing_account_id, tenant_id, invoice_id, payment_intent_id, provider, provider_payment_id, amount_cents)
  values (invoice.billing_account_id, invoice.tenant_id, invoice.id, intent.id, p_provider, p_provider_payment_id, p_amount_cents)
  on conflict (invoice_id) do nothing
  returning id into payment_record_id;
  if payment_record_id is null then select id into payment_record_id from public.payments where invoice_id = invoice.id for update; end if;
  update public.provider_transactions set payment_id = payment_record_id where provider = p_provider and provider_transaction_id = p_provider_payment_id and payment_id is null;
  update public.payment_intents set status = 'confirmed' where id = intent.id;
  update public.invoices set status = 'paid', paid_at = pg_catalog.now() where id = invoice.id;
  insert into public.billing_events(billing_account_id, tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (invoice.billing_account_id, invoice.tenant_id, 'payment.paid', 'invoice', invoice.id, jsonb_build_object('provider', p_provider, 'provider_payment_id', p_provider_payment_id));
  update public.webhook_events set status = 'processed', processed_at = pg_catalog.now() where id = event_id;
  return jsonb_build_object('paid', true, 'payment_id', payment_record_id);
end;
$$;
revoke all on function public.process_asaas_webhook_atomic(text, uuid, uuid, uuid, text, text, integer, text, jsonb) from public, anon, authenticated;
grant execute on function public.process_asaas_webhook_atomic(text, uuid, uuid, uuid, text, text, integer, text, jsonb) to service_role;

-- Operational tables are server-side only; tenant staff can access ledger data,
-- while webhook/provider/reconciliation records remain closed to the frontend.
drop policy if exists subscriptions_tenant on subscriptions;
create policy subscriptions_tenant on subscriptions for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy payment_attempts_tenant on payment_attempts for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy refunds_tenant on refunds for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy chargebacks_tenant on chargebacks for all to authenticated using (tenant_id = public.current_tenant_id() and public.is_staff()) with check (tenant_id = public.current_tenant_id() and public.is_staff());
create policy payment_attempts_service_role on payment_attempts for all to service_role using (true) with check (true);
create policy refunds_service_role on refunds for all to service_role using (true) with check (true);
create policy chargebacks_service_role on chargebacks for all to service_role using (true) with check (true);
create policy provider_transactions_service_role on provider_transactions for all to service_role using (true) with check (true);
create policy webhook_events_service_role on webhook_events for all to service_role using (true) with check (true);
create policy billing_events_service_role on billing_events for all to service_role using (true) with check (true);
create policy reconciliation_events_service_role on reconciliation_events for all to service_role using (true) with check (true);