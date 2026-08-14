-- ============================================================
-- KORA LEARN — Migration 002: Fase 3
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- O que faz:
--   1. Permite que o formulário público liste os cursos ativos
--      (necessário para o campo "Curso de interesse")
--   2. Cria a função de "Primeiro acesso" do aluno: vincula a
--      conta de login recém-criada ao cadastro feito pelo gestor
-- ============================================================

-- 1. Catálogo público: visitantes podem VER cursos ativos
--    (somente leitura; criação/edição continua restrita)
do $$ begin
  create policy cursos_select_publico on cursos
    for select to anon
    using (ativo = true);
exception when duplicate_object then null; end $$;

-- 2. Primeiro acesso do aluno
--    Quando o aluno cria seu login (e-mail + senha) no app, esta
--    função liga o novo login ao cadastro de aluno que o gestor
--    criou na conversão do lead — comparando pelo e-mail.
create or replace function public.vincular_minha_conta()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update usuarios
     set auth_user_id = auth.uid()
   where lower(email) = lower((select email from auth.users where id = auth.uid()))
     and auth_user_id is null;
  return found;  -- true se vinculou; false se não havia cadastro pendente
end;
$$;

grant execute on function public.vincular_minha_conta() to authenticated;

-- ============================================================
-- Verificação (opcional): deve listar a policy nova
-- select policyname from pg_policies where tablename = 'cursos';
-- ============================================================
