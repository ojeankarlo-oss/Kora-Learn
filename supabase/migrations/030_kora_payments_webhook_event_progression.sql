-- Accept a distinct, compatible settlement event after the payment is materialized.
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
  existing_payment public.payments%rowtype;
  existing_transaction public.provider_transactions%rowtype;
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

  select * into existing_event
  from public.webhook_events
  where provider = p_provider and provider_event_id = p_provider_payment_id || ':' || p_event_type
  for update;
  if found then
    if existing_event.tenant_id is distinct from invoice.tenant_id
      or existing_event.invoice_id is distinct from invoice.id
      or existing_event.payment_intent_id is distinct from intent.id
      or existing_event.provider_payment_id is distinct from p_provider_payment_id
      or existing_event.event_type is distinct from p_event_type
    then raise exception 'webhook event correlation conflict'; end if;
    if existing_event.status = 'processed' then return jsonb_build_object('duplicate', true); end if;
    raise exception 'webhook event already processing';
  end if;

  select * into existing_payment
  from public.payments
  where provider = p_provider and provider_payment_id = p_provider_payment_id
  for update;
  if found then
    if existing_payment.tenant_id is distinct from invoice.tenant_id
      or existing_payment.invoice_id is distinct from invoice.id
      or existing_payment.payment_intent_id is distinct from intent.id
      or existing_payment.billing_account_id is distinct from invoice.billing_account_id
      or existing_payment.amount_cents <> p_amount_cents
    then raise exception 'settled payment correlation conflict'; end if;
    if existing_payment.status <> 'confirmed' or invoice.status <> 'paid' or intent.status <> 'confirmed' then raise exception 'invalid materialized financial state'; end if;

    select * into existing_transaction
    from public.provider_transactions
    where provider = p_provider and provider_transaction_id = p_provider_payment_id
    for update;
    if not found
      or existing_transaction.tenant_id is distinct from invoice.tenant_id
      or existing_transaction.provider_account_id is distinct from p_provider_account_id
      or existing_transaction.payment_id is distinct from existing_payment.id
    then raise exception 'provider transaction correlation failed'; end if;

    insert into public.webhook_events(provider, provider_event_id, event_type, payload, tenant_id, status, processed_at, invoice_id, payment_intent_id, provider_payment_id)
    values (p_provider, p_provider_payment_id || ':' || p_event_type, p_event_type, p_payload, invoice.tenant_id, 'processed', pg_catalog.now(), invoice.id, intent.id, p_provider_payment_id)
    on conflict (provider, provider_event_id) do nothing
    returning id into event_id;
    if event_id is null then
      select * into existing_event from public.webhook_events
      where provider = p_provider and provider_event_id = p_provider_payment_id || ':' || p_event_type
      for update;
      if existing_event.tenant_id is distinct from invoice.tenant_id
        or existing_event.invoice_id is distinct from invoice.id
        or existing_event.payment_intent_id is distinct from intent.id
        or existing_event.provider_payment_id is distinct from p_provider_payment_id
        or existing_event.event_type is distinct from p_event_type
      then raise exception 'webhook event correlation conflict'; end if;
      if existing_event.status = 'processed' then return jsonb_build_object('duplicate', true); end if;
      raise exception 'webhook event already processing';
    end if;
    return jsonb_build_object('paid', true, 'successive_event', true, 'payment_id', existing_payment.id);
  end if;

  if invoice.status not in ('open', 'past_due') or intent.status not in ('created', 'pending') then raise exception 'invalid financial state'; end if;

  insert into public.webhook_events(provider, provider_event_id, event_type, payload, tenant_id, status, invoice_id, payment_intent_id, provider_payment_id)
  values (p_provider, p_provider_payment_id || ':' || p_event_type, p_event_type, p_payload, invoice.tenant_id, 'processing', invoice.id, intent.id, p_provider_payment_id)
  on conflict (provider, provider_event_id) do nothing returning id into event_id;
  if event_id is null then raise exception 'webhook event insertion conflict'; end if;

  insert into public.provider_transactions(tenant_id, provider, provider_account_id, provider_transaction_id, payload)
  values (invoice.tenant_id, p_provider, p_provider_account_id, p_provider_payment_id, p_payload)
  on conflict (provider, provider_transaction_id) do nothing;
  if exists (select 1 from public.provider_transactions where provider = p_provider and provider_transaction_id = p_provider_payment_id and (tenant_id <> invoice.tenant_id or provider_account_id <> p_provider_account_id)) then raise exception 'provider transaction correlation failed'; end if;
  if exists (select 1 from public.payments where invoice_id = invoice.id and (provider <> p_provider or provider_payment_id <> p_provider_payment_id)) then raise exception 'invoice already linked to another provider payment'; end if;
  insert into public.payments(billing_account_id, tenant_id, invoice_id, payment_intent_id, provider, provider_payment_id, amount_cents)
  values (invoice.billing_account_id, invoice.tenant_id, invoice.id, intent.id, p_provider, p_provider_payment_id, p_amount_cents)
  on conflict (invoice_id) do nothing returning id into payment_record_id;
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
