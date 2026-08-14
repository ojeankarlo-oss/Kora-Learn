-- ============================================================
-- KORA LEARN — Migration 006: Fase 7-A (Financeiro do aluno)
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- O que faz:
--   1. Tabela `titulos` (mensalidades e cobranças avulsas)
--   2. RLS: aluno vê os próprios títulos; staff gerencia o tenant
--   3. Liga o módulo "financeiro" no kora-demo
-- Etapa B (futura): integração Asaas (Pix/boleto) via webhook.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Tipo de situação
-- ------------------------------------------------------------
do $$ begin
  create type situacao_titulo as enum ('aberto','pago','cancelado');
exception when duplicate_object then null; end $$;
-- Obs.: "vencido" é derivado (aberto + data_vencimento < hoje),
-- assim não depende de rotina agendada para virar o status.

-- ------------------------------------------------------------
-- 1. Títulos (mensalidades / cobranças)
-- ------------------------------------------------------------
create table if not exists titulos (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  usuario_id       uuid not null references usuarios(id) on delete cascade,
  matricula_id     uuid references matriculas(id) on delete set null,
  descricao        text not null,            -- ex.: "Mensalidade 03/12 — Marketing Digital"
  valor_centavos   integer not null check (valor_centavos > 0),
  data_vencimento  date not null,
  data_pagamento   date,
  situacao         situacao_titulo not null default 'aberto',
  forma_pagamento  text,                     -- pix | dinheiro | cartao | boleto | outro
  observacao       text,
  criado_por       uuid references usuarios(id) on delete set null,
  created_at       timestamptz not null default now()
);

create index if not exists idx_titulos_tenant     on titulos(tenant_id);
create index if not exists idx_titulos_usuario    on titulos(usuario_id);
create index if not exists idx_titulos_vencimento on titulos(tenant_id, situacao, data_vencimento);

alter table titulos enable row level security;

-- Aluno vê os próprios títulos (somente leitura)
create policy titulos_select_self on titulos
  for select to authenticated
  using (usuario_id = public.current_usuario_id());

-- Staff (gestor/super_admin) gerencia os títulos do tenant
create policy titulos_staff on titulos
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

-- ------------------------------------------------------------
-- 2. Liga o módulo "financeiro" no kora-demo
-- ------------------------------------------------------------
update tenants
set config = jsonb_set(
  coalesce(config, '{}'::jsonb),
  '{modulos,financeiro}',
  'true'::jsonb,
  true
)
where slug = 'kora-demo';

-- ------------------------------------------------------------
-- Verificação (opcional):
-- select tablename from pg_tables where schemaname='public' and tablename='titulos';
-- select config->'modulos' from tenants where slug='kora-demo';
-- ============================================================
