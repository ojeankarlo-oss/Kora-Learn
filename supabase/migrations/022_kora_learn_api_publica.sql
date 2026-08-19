-- Kora Learn — Migration 022
-- Phase 10: API B2G pública via Edge Function.
-- As chaves ficam protegidas por RLS; o endpoint público valida via service role.

create table if not exists api_keys (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  chave text not null unique,
  nome text,
  descricao text,
  ativo boolean not null default true,
  ultimo_uso timestamptz,
  criado_em timestamptz not null default now(),
  expires_at timestamptz
);

create table if not exists api_webhooks (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  url text not null,
  evento text not null check (evento in ('contato_criado','mensagem_enviada','post_criado')),
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

create index if not exists idx_api_keys_tenant on api_keys(tenant_id);
create index if not exists idx_api_keys_chave on api_keys(chave);
create index if not exists idx_api_keys_active_expiry on api_keys(ativo, expires_at);
create index if not exists idx_api_webhooks_tenant on api_webhooks(tenant_id);
create index if not exists idx_api_webhooks_evento on api_webhooks(tenant_id, evento, ativo);

alter table api_keys enable row level security;
alter table api_webhooks enable row level security;

drop policy if exists api_keys_staff_all on api_keys;
create policy api_keys_staff_all on api_keys for all to authenticated
using (tenant_id = public.current_tenant_id() and public.is_staff())
with check (tenant_id = public.current_tenant_id() and public.is_staff());

drop policy if exists api_webhooks_staff_all on api_webhooks;
create policy api_webhooks_staff_all on api_webhooks for all to authenticated
using (tenant_id = public.current_tenant_id() and public.is_staff())
with check (tenant_id = public.current_tenant_id() and public.is_staff());
