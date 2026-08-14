-- ============================================================
-- KORA LEARN — Migration 010: Fase 17 - Etapa 1 (Acessibilidade)
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- O que faz:
--   1. Campos de acessibilidade/necessidades específicas em
--      `leads` (autodeclaração na inscrição pública) e em
--      `usuarios` (fica no cadastro após a matrícula)
--   2. Preferências de interface (fonte, contraste) no próprio
--      usuário — não é dado sensível, qualquer um edita o seu
--   3. RLS: o campo de necessidade específica já herda a
--      proteção das policies existentes de usuarios/leads
--      (self + staff) — não precisa de tabela nova, mas
--      documentamos aqui a intenção de acesso restrito via
--      convenção de UI (só coordenador/gestor devem exibir
--      esse campo em telas de listagem gerais)
-- ============================================================

-- ------------------------------------------------------------
-- 1. Campos em leads (autodeclaração já na inscrição pública)
-- ------------------------------------------------------------
alter table leads
  add column if not exists tem_necessidade_especifica boolean,
  add column if not exists necessidades_especificas text[]; -- ex.: '{baixa_visao,surdez}'

-- ------------------------------------------------------------
-- 2. Campos em usuarios (persistem após a matrícula/primeiro acesso)
-- ------------------------------------------------------------
alter table usuarios
  add column if not exists tem_necessidade_especifica boolean,
  add column if not exists necessidades_especificas text[],
  add column if not exists pref_fonte text default 'normal',       -- 'normal' | 'grande' | 'muito_grande'
  add column if not exists pref_alto_contraste boolean default false;

-- ------------------------------------------------------------
-- 3. Comentários de documentação (não afeta comportamento,
--    apenas registra a intenção de privacidade no catálogo)
-- ------------------------------------------------------------
comment on column usuarios.necessidades_especificas is
  'Dado sensível (LGPD Art. 5º, XI) — autodeclarado. Exibir em telas de listagem geral apenas para perfis gestor/super_admin ou papel de coordenação pedagógica quando existir; não expor a professores comuns por padrão.';

-- ------------------------------------------------------------
-- Verificação (opcional):
-- select column_name from information_schema.columns
--   where table_name='usuarios' and column_name like '%necessidade%' or column_name like 'pref_%';
-- ============================================================
