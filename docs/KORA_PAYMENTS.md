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

## P1-PAY-API-003 — HTTP foundation `/v1`

A fundação HTTP versionada de Payments usa **Supabase Edge Functions com runtime Deno**, em vez de introduzir um servidor Node/Fastify/Express separado. Essa decisão reutiliza o runtime já operacional do repositório, mantém o baixo custo operacional do deployment existente e permite que a autenticação M2M criada no P1-PAY-API-002 seja aplicada antes de qualquer futuro handler financeiro.

A entrada pública é a Edge Function `payments-api-v1`, com a fronteira lógica `/v1`. A função usa `verify_jwt = false` somente porque o pipeline próprio valida a credential M2M; o tenant nunca vem do caller. O caminho de autoridade é `credential → application → tenant → scopes`.

O pipeline comum é: request HTTP, geração/sanitização de `request_id`, validação de request, autenticação M2M, contexto de tenant, scope enforcement, handler, resposta padronizada e observabilidade. Nesta fase, somente `GET /v1` e `GET /v1/health` existem; não há invoices, payment intents, payments, refunds, checkout, Pix, boleto, cartão, provider novo, outbound webhook ou integração ENEM.

O contrato versionado está em `docs/openapi/kora-payments-v1.yaml`. Valores monetários futuros usarão minor units inteiras, `Idempotency-Key` será obrigatória para mutações financeiras futuras, e o rate limiting será identificado por tenant/application/credential/rota. A implementação atual fornece uma abstração in-memory somente para testes; enforcement distribuído e operacionalização de produção ficam para uma fase posterior.

O fluxo de produto permanece:

`Consumer → KORA Payments API /v1 → M2M Auth → Tenant Context → Billing Core → Provider Adapter`.

Produtos consumidores nunca chamam Asaas diretamente. A API `/v1` deverá evoluir para `/v2` por meio de novos módulos de versão, sem espalhar condicionais de versão pelos handlers existentes.
