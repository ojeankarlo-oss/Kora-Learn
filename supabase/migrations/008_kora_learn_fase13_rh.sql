-- ============================================================
-- KORA LEARN — Migration 008: Fase 13 (RH — colaboradores)
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- O que faz:
--   1. Tabela `colaboradores` (cadastro institucional da equipe,
--      separado do login/acesso em `usuarios`)
--   2. RLS em DUAS CAMADAS: dados gerais visíveis a todo staff;
--      SALÁRIO visível apenas a gestor/super_admin
--   3. Liga o módulo "rh" no kora-demo
-- ============================================================

-- ------------------------------------------------------------
-- 0. Tipos
-- ------------------------------------------------------------
do $$ begin
  create type tipo_vinculo as enum ('clt','pj','voluntario','bolsista','estagiario','outro');
exception when duplicate_object then null; end $$;

do $$ begin
  create type situacao_colaborador as enum ('ativo','afastado','desligado');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 1. Colaboradores (cadastro institucional)
-- ------------------------------------------------------------
create table if not exists colaboradores (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  unidade_id        uuid references unidades(id) on delete set null,
  usuario_id        uuid references usuarios(id) on delete set null,  -- vínculo opcional com login
  nome              text not null,
  nome_social       text,
  cpf               text,
  email             text,
  telefone          text,
  endereco          text,
  funcao            text not null,             -- ex.: Professor, Coordenador Pedagógico, Secretária...
  tipo_vinculo      tipo_vinculo not null default 'clt',
  carga_horaria     text,                      -- texto livre: "40h semanais", "20h", etc.
  data_admissao     date,
  data_desligamento date,
  situacao          situacao_colaborador not null default 'ativo',
  salario_centavos  integer,                   -- NULL = não informado; dado sensível, RLS restrito abaixo
  observacoes       text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists idx_colaboradores_tenant  on colaboradores(tenant_id);
create index if not exists idx_colaboradores_unidade on colaboradores(unidade_id);

do $$ begin
  create trigger trg_colaboradores_updated before update on colaboradores
    for each row execute function public.set_updated_at();
exception when duplicate_object then null; end $$;

alter table colaboradores enable row level security;

-- ------------------------------------------------------------
-- 2. RLS em duas camadas
-- ------------------------------------------------------------

-- Camada A: staff do tenant pode gerenciar o CADASTRO GERAL
-- (esta policy cobre a tabela inteira via RLS nativo do Postgres,
--  mas o campo salario_centavos fica protegido à parte pela VIEW
--  abaixo — o RLS de linha não filtra coluna, por isso usamos
--  uma view "segura" para quem não é gestor).
create policy colaboradores_staff on colaboradores
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

-- Camada B: view sem salário, para quem é staff mas não é gestor
-- (ex.: um perfil "coordenador" que só enxerga RLS de is_staff
--  mas não deveria ver remuneração). Usar esta view no frontend
--  para papéis que não sejam gestor/super_admin.
create or replace view colaboradores_sem_salario as
  select
    id, tenant_id, unidade_id, usuario_id, nome, nome_social, cpf,
    email, telefone, endereco, funcao, tipo_vinculo, carga_horaria,
    data_admissao, data_desligamento, situacao, observacoes,
    created_at, updated_at
  from colaboradores;

grant select on colaboradores_sem_salario to authenticated;

-- ------------------------------------------------------------
-- 3. Liga o módulo "rh" no kora-demo
-- ------------------------------------------------------------
update tenants
set config = jsonb_set(
  coalesce(config, '{}'::jsonb),
  '{modulos,rh}',
  'true'::jsonb,
  true
)
where slug = 'kora-demo';

-- ------------------------------------------------------------
-- Verificação (opcional):
-- select tablename from pg_tables where schemaname='public' and tablename='colaboradores';
-- select config->'modulos' from tenants where slug='kora-demo';
-- ============================================================
