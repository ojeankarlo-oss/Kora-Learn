# KORA Payments Foundation

## Boundary

KORA Billing is the system of record for both financial directions:

- tenant billing a student or responsible party;
- KORA billing a tenant for SaaS, modules, usage, or add-ons.

These directions share provider-neutral primitives but never share tenant debt or authorization. The current student finance tables (`titulos`, `pix_cobrancas`, and `pix_eventos`) remain intact; this foundation does not replace the Banco Inter flow and does not recreate the lost P0-003B.

## Provider contract

`src/lib/billing/provider.js` defines the provider contract and capabilities. `src/lib/billing/asaas.js` is the first adapter and defaults to sandbox. Credentials are supplied at runtime through `ASAAS_API_KEY` and `ASAAS_WEBHOOK_SECRET`; they are never persisted in the database or logged. Inter can be added later as `InterProvider` without changing Billing Core.

The orchestrator handles outbound payment creation only and requires tenant-scoped repository reads plus atomic payment-intent creation. Asaas webhooks have one authorized settlement path: the `asaas-webhook` Edge Function delegates to `process_asaas_webhook_atomic(...)`. The RPC authenticates correlation to a KORA invoice through `externalReference`, enforces exact amount and supported event types, and provides idempotency through unique provider event and payment identifiers.

## Migration

`027_kora_payments_billing_core.sql` creates the provider-neutral ledger and RLS policies. It creates no financial records, performs no backfill, calls no provider, and must be applied through the normal Supabase migration process in the target environment after review.

## Current scope

Implemented locally: invoice/payment-intent orchestration, Asaas sandbox Pix charge and QR payload, secure webhook handler, idempotency, amount and tenant checks, and deterministic tests. Boleto, card, subscriptions, reconciliation, and fiscal issuance are explicit extension points and currently fail closed rather than pretending to be supported.
