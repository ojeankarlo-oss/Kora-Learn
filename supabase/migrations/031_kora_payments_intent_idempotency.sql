-- Preserve intent history while making one row canonical per tenant/invoice/provider.
alter table public.payment_intents
  add column if not exists is_canonical boolean not null default true;

do $$
begin
  if exists (
    select 1 from public.payment_intents
    where status in ('created', 'pending', 'confirmed')
    group by tenant_id, invoice_id, provider having count(*) > 1
  ) then
    raise exception 'cannot establish payment intent canonicality: multiple resolvable intents exist';
  end if;
end;
$$;

update public.payment_intents set is_canonical = false;
with ranked as (
  select id, row_number() over (
    partition by tenant_id, invoice_id, provider
    order by case when status in ('created', 'pending') then 0 when status = 'confirmed' then 1 else 2 end,
      created_at desc, id desc
  ) as position
  from public.payment_intents
)
update public.payment_intents intent
set is_canonical = true
from ranked
where ranked.id = intent.id and ranked.position = 1;

alter table public.payment_intents
  add constraint payment_intents_noncanonical_terminal_check
  check (is_canonical or status in ('failed', 'cancelled'));

alter table public.payment_intents
  drop constraint if exists payment_intents_provider_idempotency_key_key;

create unique index uq_payment_intents_tenant_provider_idempotency
  on public.payment_intents(tenant_id, provider, idempotency_key)
  where idempotency_key is not null;

create unique index uq_payment_intents_canonical_invoice_provider
  on public.payment_intents(tenant_id, invoice_id, provider)
  where is_canonical;

create or replace function public.get_or_create_payment_intent_atomic(
  p_billing_account_id uuid,
  p_tenant_id uuid,
  p_invoice_id uuid,
  p_provider_account_id uuid,
  p_provider text,
  p_amount_cents integer,
  p_idempotency_key text
) returns public.payment_intents
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  invoice public.invoices%rowtype;
  existing_intent public.payment_intents%rowtype;
  result_intent public.payment_intents%rowtype;
begin
  if nullif(pg_catalog.btrim(p_provider), '') is null
    or nullif(pg_catalog.btrim(p_idempotency_key), '') is null
    or p_amount_cents <= 0
  then raise exception 'invalid payment intent request'; end if;

  select * into invoice from public.invoices where id = p_invoice_id for update;
  if not found
    or invoice.tenant_id is distinct from p_tenant_id
    or invoice.billing_account_id is distinct from p_billing_account_id
  then raise exception 'invoice correlation failed'; end if;
  if invoice.status not in ('open', 'past_due') then raise exception 'invoice is not payable'; end if;
  if invoice.amount_cents <> p_amount_cents then raise exception 'payment intent amount mismatch'; end if;
  if p_provider_account_id is not null and not exists (
    select 1 from public.provider_accounts
    where id = p_provider_account_id and tenant_id = p_tenant_id
      and billing_account_id = p_billing_account_id and provider = p_provider
  ) then raise exception 'provider account correlation failed'; end if;

  select * into existing_intent from public.payment_intents
  where tenant_id = p_tenant_id and provider = p_provider
    and idempotency_key = p_idempotency_key
  for update;
  if found then
    if existing_intent.invoice_id is distinct from p_invoice_id
      or existing_intent.billing_account_id is distinct from p_billing_account_id
      or existing_intent.provider_account_id is distinct from p_provider_account_id
      or existing_intent.amount_cents <> p_amount_cents
    then raise exception 'payment intent idempotency conflict'; end if;
    return existing_intent;
  end if;

  select * into existing_intent from public.payment_intents
  where tenant_id = p_tenant_id and invoice_id = p_invoice_id
    and provider = p_provider and is_canonical
  for update;
  if found then
    if existing_intent.status in ('created', 'pending') then raise exception 'canonical payment intent already exists with another idempotency key'; end if;
    if existing_intent.status = 'confirmed' then raise exception 'invoice provider already has a confirmed intent'; end if;
    update public.payment_intents set is_canonical = false where id = existing_intent.id;
  end if;

  insert into public.payment_intents(
    billing_account_id, tenant_id, invoice_id, provider_account_id,
    provider, amount_cents, status, idempotency_key, is_canonical
  ) values (
    p_billing_account_id, p_tenant_id, p_invoice_id, p_provider_account_id,
    p_provider, p_amount_cents, 'created', p_idempotency_key, true
  ) returning * into result_intent;
  return result_intent;
end;
$$;

revoke all on function public.get_or_create_payment_intent_atomic(uuid, uuid, uuid, uuid, text, integer, text) from public, anon, authenticated;
grant execute on function public.get_or_create_payment_intent_atomic(uuid, uuid, uuid, uuid, text, integer, text) to service_role;
