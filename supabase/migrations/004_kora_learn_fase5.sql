-- ============================================================
-- KORA LEARN — Migration 004: Fase 5 (Unidades / Polos)
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- O que faz:
--   1. Liga leads e matrículas a uma unidade/polo
--   2. Permite que o formulário público liste as unidades
--      ativas do tenant (sem login)
--   3. Cria uma unidade de demonstração no kora-demo
-- Obs.: a tabela `unidades` já existe desde a migration 001,
--       com RLS de leitura para membros e escrita para staff.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Vínculo de unidade em leads e matrículas
-- ------------------------------------------------------------
alter table leads
  add column if not exists unidade_id uuid references unidades(id) on delete set null;

alter table matriculas
  add column if not exists unidade_id uuid references unidades(id) on delete set null;

create index if not exists idx_leads_unidade on leads(unidade_id);
create index if not exists idx_matriculas_unidade on matriculas(unidade_id);

-- ------------------------------------------------------------
-- 2. Unidades visíveis ao público (para o select do formulário)
--    Retorna apenas campos seguros das unidades ativas.
-- ------------------------------------------------------------
create or replace function public.listar_unidades_publico(p_tenant_id uuid)
returns table (id uuid, nome text, cidade text, estado text)
language sql
stable
security definer
set search_path = public
as $$
  select u.id, u.nome, u.cidade, u.estado
  from unidades u
  where u.tenant_id = p_tenant_id
    and u.ativo = true
  order by u.nome;
$$;

grant execute on function public.listar_unidades_publico(uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 3. Unidade de demonstração (idempotente)
-- ------------------------------------------------------------
insert into unidades (tenant_id, nome, cidade, estado, pais)
select t.id, 'Unidade Bela Vista', 'São Paulo', 'SP', 'BR'
from tenants t
where t.slug = 'kora-demo'
  and not exists (
    select 1 from unidades u
    where u.tenant_id = t.id and u.nome = 'Unidade Bela Vista'
  );

-- ------------------------------------------------------------
-- Verificação (opcional):
-- select * from public.listar_unidades_publico(
--   (select id from tenants where slug = 'kora-demo')
-- );
-- Deve listar a Unidade Bela Vista.
-- ============================================================
