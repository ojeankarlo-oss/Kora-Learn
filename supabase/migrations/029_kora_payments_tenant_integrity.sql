-- Enforce tenant equality across every financial relationship.
create unique index if not exists uq_usuarios_id_tenant on public.usuarios(id, tenant_id);

alter table public.reconciliation_events
  add column if not exists tenant_id uuid references public.tenants(id) on delete cascade;

update public.reconciliation_events child
set tenant_id = parent.tenant_id
from public.provider_accounts parent
where parent.id = child.provider_account_id
  and child.tenant_id is null;

create index if not exists idx_reconciliation_events_tenant
  on public.reconciliation_events(tenant_id, created_at desc);

alter table public.billing_customers
  add constraint billing_customers_user_requires_tenant
  check (user_id is null or tenant_id is not null);

alter table public.billing_customers
  add constraint billing_customers_user_tenant_fkey
  foreign key (user_id, tenant_id)
  references public.usuarios(id, tenant_id);

do $$
declare
  violation text;
begin
  select relation into violation
  from (
    select 'billing_customers.billing_account_id' relation from public.billing_customers c join public.billing_accounts p on p.id = c.billing_account_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'provider_accounts.billing_account_id' from public.provider_accounts c join public.billing_accounts p on p.id = c.billing_account_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'subscriptions.billing_account_id' from public.subscriptions c join public.billing_accounts p on p.id = c.billing_account_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'subscriptions.customer_id' from public.subscriptions c join public.billing_customers p on p.id = c.customer_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'subscriptions.provider_account_id' from public.subscriptions c join public.provider_accounts p on p.id = c.provider_account_id where c.provider_account_id is not null and c.tenant_id is distinct from p.tenant_id
    union all
    select 'invoices.billing_account_id' from public.invoices c join public.billing_accounts p on p.id = c.billing_account_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'invoices.customer_id' from public.invoices c join public.billing_customers p on p.id = c.customer_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'invoices.subscription_id' from public.invoices c join public.subscriptions p on p.id = c.subscription_id where c.subscription_id is not null and c.tenant_id is distinct from p.tenant_id
    union all
    select 'payment_intents.billing_account_id' from public.payment_intents c join public.billing_accounts p on p.id = c.billing_account_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'payment_intents.invoice_id' from public.payment_intents c join public.invoices p on p.id = c.invoice_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'payment_intents.provider_account_id' from public.payment_intents c join public.provider_accounts p on p.id = c.provider_account_id where c.provider_account_id is not null and c.tenant_id is distinct from p.tenant_id
    union all
    select 'payment_attempts.payment_intent_id' from public.payment_attempts c join public.payment_intents p on p.id = c.payment_intent_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'payments.billing_account_id' from public.payments c join public.billing_accounts p on p.id = c.billing_account_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'payments.invoice_id' from public.payments c join public.invoices p on p.id = c.invoice_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'payments.payment_intent_id' from public.payments c join public.payment_intents p on p.id = c.payment_intent_id where c.payment_intent_id is not null and c.tenant_id is distinct from p.tenant_id
    union all
    select 'refunds.payment_id' from public.refunds c join public.payments p on p.id = c.payment_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'chargebacks.payment_id' from public.chargebacks c join public.payments p on p.id = c.payment_id where c.tenant_id is distinct from p.tenant_id
    union all
    select 'provider_transactions.provider_account_id' from public.provider_transactions c join public.provider_accounts p on p.id = c.provider_account_id where c.provider_account_id is not null and c.tenant_id is distinct from p.tenant_id
    union all
    select 'provider_transactions.payment_id' from public.provider_transactions c join public.payments p on p.id = c.payment_id where c.payment_id is not null and c.tenant_id is distinct from p.tenant_id
    union all
    select 'webhook_events.invoice_id' from public.webhook_events c join public.invoices p on p.id = c.invoice_id where c.invoice_id is not null and c.tenant_id is distinct from p.tenant_id
    union all
    select 'webhook_events.payment_intent_id' from public.webhook_events c join public.payment_intents p on p.id = c.payment_intent_id where c.payment_intent_id is not null and c.tenant_id is distinct from p.tenant_id
    union all
    select 'billing_events.billing_account_id' from public.billing_events c join public.billing_accounts p on p.id = c.billing_account_id where c.billing_account_id is not null and c.tenant_id is distinct from p.tenant_id
    union all
    select 'reconciliation_events.provider_account_id' from public.reconciliation_events c join public.provider_accounts p on p.id = c.provider_account_id where c.provider_account_id is not null and c.tenant_id is distinct from p.tenant_id
  ) violations
  limit 1;

  if violation is not null then
    raise exception 'existing cross-tenant financial relation: %', violation;
  end if;
end;
$$;

create or replace function public.validate_kora_billing_tenant()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  related_tenant uuid;
begin
  if tg_table_name = 'billing_customers' then
    select tenant_id into related_tenant from public.billing_accounts where id = new.billing_account_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'billing customer account tenant mismatch'; end if;
  elsif tg_table_name = 'provider_accounts' then
    select tenant_id into related_tenant from public.billing_accounts where id = new.billing_account_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'provider account tenant mismatch'; end if;
  elsif tg_table_name = 'subscriptions' then
    select tenant_id into related_tenant from public.billing_accounts where id = new.billing_account_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'subscription account tenant mismatch'; end if;
    select tenant_id into related_tenant from public.billing_customers where id = new.customer_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'subscription customer tenant mismatch'; end if;
    if new.provider_account_id is not null then
      select tenant_id into related_tenant from public.provider_accounts where id = new.provider_account_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'subscription provider tenant mismatch'; end if;
    end if;
  elsif tg_table_name = 'invoices' then
    select tenant_id into related_tenant from public.billing_accounts where id = new.billing_account_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'invoice account tenant mismatch'; end if;
    select tenant_id into related_tenant from public.billing_customers where id = new.customer_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'invoice customer tenant mismatch'; end if;
    if new.subscription_id is not null then
      select tenant_id into related_tenant from public.subscriptions where id = new.subscription_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'invoice subscription tenant mismatch'; end if;
    end if;
  elsif tg_table_name = 'payment_intents' then
    select tenant_id into related_tenant from public.billing_accounts where id = new.billing_account_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'payment intent account tenant mismatch'; end if;
    select tenant_id into related_tenant from public.invoices where id = new.invoice_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'payment intent invoice tenant mismatch'; end if;
    if new.provider_account_id is not null then
      select tenant_id into related_tenant from public.provider_accounts where id = new.provider_account_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'payment intent provider tenant mismatch'; end if;
    end if;
  elsif tg_table_name = 'payments' then
    select tenant_id into related_tenant from public.billing_accounts where id = new.billing_account_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'payment account tenant mismatch'; end if;
    select tenant_id into related_tenant from public.invoices where id = new.invoice_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'payment invoice tenant mismatch'; end if;
    if new.payment_intent_id is not null then
      select tenant_id into related_tenant from public.payment_intents where id = new.payment_intent_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'payment intent tenant mismatch'; end if;
    end if;
  elsif tg_table_name = 'payment_attempts' then
    select tenant_id into related_tenant from public.payment_intents where id = new.payment_intent_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'payment attempt tenant mismatch'; end if;
  elsif tg_table_name in ('refunds', 'chargebacks') then
    select tenant_id into related_tenant from public.payments where id = new.payment_id;
    if related_tenant is distinct from new.tenant_id then raise exception 'payment adjustment tenant mismatch'; end if;
  elsif tg_table_name = 'provider_transactions' then
    if new.provider_account_id is not null then
      select tenant_id into related_tenant from public.provider_accounts where id = new.provider_account_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'provider transaction account tenant mismatch'; end if;
    end if;
    if new.payment_id is not null then
      select tenant_id into related_tenant from public.payments where id = new.payment_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'provider transaction payment tenant mismatch'; end if;
    end if;
  elsif tg_table_name = 'webhook_events' then
    if new.invoice_id is not null then
      select tenant_id into related_tenant from public.invoices where id = new.invoice_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'webhook invoice tenant mismatch'; end if;
    end if;
    if new.payment_intent_id is not null then
      select tenant_id into related_tenant from public.payment_intents where id = new.payment_intent_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'webhook intent tenant mismatch'; end if;
    end if;
  elsif tg_table_name = 'billing_events' then
    if new.billing_account_id is not null then
      select tenant_id into related_tenant from public.billing_accounts where id = new.billing_account_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'billing event account tenant mismatch'; end if;
    end if;
  elsif tg_table_name = 'reconciliation_events' then
    if new.provider_account_id is not null then
      select tenant_id into related_tenant from public.provider_accounts where id = new.provider_account_id;
      if related_tenant is distinct from new.tenant_id then raise exception 'reconciliation account tenant mismatch'; end if;
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.validate_kora_billing_tenant() from public, anon, authenticated;
grant execute on function public.validate_kora_billing_tenant() to service_role;

create trigger trg_webhook_events_tenant
before insert or update on public.webhook_events
for each row execute function public.validate_kora_billing_tenant();

create trigger trg_billing_events_account_tenant
before insert or update on public.billing_events
for each row execute function public.validate_kora_billing_tenant();

create trigger trg_reconciliation_events_tenant
before insert or update on public.reconciliation_events
for each row execute function public.validate_kora_billing_tenant();
