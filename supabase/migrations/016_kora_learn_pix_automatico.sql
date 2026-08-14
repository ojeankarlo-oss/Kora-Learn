-- KORA LEARN — Migration 016: Pix automático (Fase 7-B)
--
-- Fonte da verdade do fluxo Pix automático. As credenciais do Banco Inter
-- NÃO ficam no banco nem no frontend: configure-as como secrets da Edge
-- Function (INTER_CLIENT_ID, INTER_CLIENT_SECRET, INTER_CERT_PEM,
-- INTER_KEY_PEM, INTER_PIX_KEY e PIX_WEBHOOK_TOKEN).
--
-- O fluxo é:
--   1. Uma Edge Function cria a cobrança no Banco Inter para um título.
--   2. A resposta é persistida em pix_cobrancas, ligada ao título específico.
--   3. O webhook público recebe callbacks, grava pix_eventos de forma
--      idempotente e dá baixa no título somente quando o valor confere.
--   4. A baixa manual da Fase 7-A continua disponível para pagamentos fora
--      do fluxo automático.
-- ============================================================

create table if not exists pix_cobrancas (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants(id) on delete cascade,
  titulo_id          uuid not null unique references titulos(id) on delete cascade,
  txid               text not null,
  chave              text not null,
  location           text,
  pix_copia_e_cola   text,
  status_banco       text not null default 'ATIVA',
  situacao           text not null default 'criada'
    check (situacao in ('criada', 'paga', 'expirada', 'cancelada', 'erro')),
  valor_centavos     integer not null check (valor_centavos > 0),
  expira_em          timestamptz,
  paga_em            timestamptz,
  end_to_end_id      text,
  resposta_banco     jsonb,
  erro               text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

alter table pix_cobrancas add column if not exists tenant_id uuid;
alter table pix_cobrancas add column if not exists titulo_id uuid;
alter table pix_cobrancas add column if not exists txid text;
alter table pix_cobrancas add column if not exists chave text;
alter table pix_cobrancas add column if not exists location text;
alter table pix_cobrancas add column if not exists pix_copia_e_cola text;
alter table pix_cobrancas add column if not exists status_banco text;
alter table pix_cobrancas add column if not exists situacao text;
alter table pix_cobrancas add column if not exists valor_centavos integer;
alter table pix_cobrancas add column if not exists expira_em timestamptz;
alter table pix_cobrancas add column if not exists paga_em timestamptz;
alter table pix_cobrancas add column if not exists end_to_end_id text;
alter table pix_cobrancas add column if not exists resposta_banco jsonb;
alter table pix_cobrancas add column if not exists erro text;
alter table pix_cobrancas add column if not exists created_at timestamptz;
alter table pix_cobrancas add column if not exists updated_at timestamptz;

create unique index if not exists uq_pix_cobrancas_tenant_txid
  on pix_cobrancas(tenant_id, txid);
create index if not exists idx_pix_cobrancas_titulo
  on pix_cobrancas(titulo_id);
create index if not exists idx_pix_cobrancas_situacao
  on pix_cobrancas(tenant_id, situacao, created_at desc);
create index if not exists idx_pix_cobrancas_e2eid
  on pix_cobrancas(end_to_end_id)
  where end_to_end_id is not null;

create table if not exists pix_eventos (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references tenants(id) on delete set null,
  txid            text,
  end_to_end_id   text,
  valor_centavos  integer,
  payload         jsonb not null,
  recebido_em     timestamptz not null default now(),
  processado_em   timestamptz,
  erro            text,
  created_at      timestamptz not null default now()
);

create unique index if not exists uq_pix_eventos_txid_e2eid
  on pix_eventos(txid, end_to_end_id)
  where txid is not null and end_to_end_id is not null;
create index if not exists idx_pix_eventos_tenant
  on pix_eventos(tenant_id, recebido_em desc);

-- Atualização comum usada por todas as tabelas da base (migration 001).
do $$ begin
  create trigger trg_pix_cobrancas_updated before update on pix_cobrancas
    for each row execute function public.set_updated_at();
exception when duplicate_object then null; end $$;

alter table pix_cobrancas enable row level security;
alter table pix_eventos enable row level security;

drop policy if exists pix_cobrancas_select_owner on pix_cobrancas;
create policy pix_cobrancas_select_owner on pix_cobrancas
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (
      public.is_staff()
      or exists (
        select 1 from titulos t
        where t.id = pix_cobrancas.titulo_id
          and t.usuario_id = public.current_usuario_id()
      )
    )
  );

drop policy if exists pix_cobrancas_staff on pix_cobrancas;
create policy pix_cobrancas_staff on pix_cobrancas
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

drop policy if exists pix_eventos_staff on pix_eventos;
create policy pix_eventos_staff on pix_eventos
  for select to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff());

comment on table pix_cobrancas is
  'Cobranças Pix do Banco Inter ligadas a um título. Segredos ficam em Edge Function secrets.';
comment on table pix_eventos is
  'Callbacks recebidos do Banco Inter; o índice único por txid/e2eid apoia idempotência.';
comment on column pix_cobrancas.pix_copia_e_cola is
  'Payload/URL retornado pelo PSP e usado pela interface para QR/copia e cola.';

-- Verificação opcional:
-- select id, titulo_id, txid, situacao, valor_centavos from pix_cobrancas;
-- select count(*) from pix_eventos;
-- ============================================================
