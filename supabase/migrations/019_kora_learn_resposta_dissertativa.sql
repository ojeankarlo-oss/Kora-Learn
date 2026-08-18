-- KORA LEARN — Migration 019: Referência para correção dissertativa
-- Armazena uma resposta esperada opcional para orientar a correção manual.
-- Não participa da correção automática.
-- ============================================================

alter table if exists public.questoes
  add column if not exists resposta_esperada text;

comment on column public.questoes.resposta_esperada is
  'Referência opcional do professor para correção manual de questões dissertativas; não é exibida ao aluno.';

-- Verificação opcional:
-- select id, tipo, resposta_esperada from public.questoes limit 10;
-- ============================================================
