-- ============================================================
-- KORA LEARN — Migration 003: Fase 4 (Fundação SaaS)
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- O que faz:
--   1. Cria função pública que entrega a "marca" de um tenant
--      pelo slug (para o formulário público e páginas abertas)
--   2. Permite que o GESTOR edite a configuração do próprio
--      tenant (antes só super_admin podia)
--   3. Semeia a configuração padrão KORA no tenant kora-demo
-- ============================================================

-- ------------------------------------------------------------
-- 1. Marca pública por slug (visitantes precisam ver logo/cores
--    no formulário de inscrição, sem login)
--    Retorna SOMENTE campos seguros: id, nome, slug, logo, marca
--    e módulos. Nada de dados internos.
-- ------------------------------------------------------------
create or replace function public.obter_tenant_publico(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id',       t.id,
    'nome',     t.nome,
    'slug',     t.slug,
    'logo_url', t.logo_url,
    'marca',    coalesce(t.config->'marca', '{}'::jsonb),
    'modulos',  coalesce(t.config->'modulos', '{}'::jsonb)
  )
  from tenants t
  where t.slug = p_slug
    and t.ativo = true
  limit 1;
$$;

grant execute on function public.obter_tenant_publico(text) to anon, authenticated;

-- ------------------------------------------------------------
-- 2. Gestor pode editar a configuração do próprio tenant
-- ------------------------------------------------------------
drop policy if exists tenants_update on tenants;

create policy tenants_update on tenants
  for update to authenticated
  using (
    id = public.current_tenant_id()
    and public.current_perfil() in ('super_admin','gestor')
  )
  with check (
    id = public.current_tenant_id()
    and public.current_perfil() in ('super_admin','gestor')
  );

-- ------------------------------------------------------------
-- 3. Configuração padrão do tenant kora-demo
--    (merge: preserva chaves que já existirem no config)
-- ------------------------------------------------------------
update tenants
set config = coalesce(config, '{}'::jsonb) || jsonb_build_object(
  'marca', jsonb_build_object(
    'cor_primaria', '#17604A',
    'cor_destaque', '#E9A13B',
    'slogan', 'Cada aula aprendida, uma vida se transforma.'
  ),
  'modulos', jsonb_build_object(
    'inscricao_publica', true,
    'alunos', true,
    'financeiro', false,
    'documentos', false
  )
)
where slug = 'kora-demo';

-- ------------------------------------------------------------
-- Verificação (opcional):
-- select public.obter_tenant_publico('kora-demo');
-- Deve retornar o JSON com nome, marca e módulos.
-- ============================================================
