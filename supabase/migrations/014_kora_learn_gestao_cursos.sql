-- ============================================================
-- KORA LEARN — Migration 014: Gestao de Cursos (self-service)
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- Contexto: as tabelas cursos, disciplinas, aulas e
-- materiais_apoio JA EXISTEM desde a migration 001, com RLS que
-- ja permite ao staff (gestor/super_admin) fazer INSERT/UPDATE/
-- DELETE completo (policies cursos_write, disciplinas_write,
-- aulas_write, materiais_write). Ou seja: NAO falta nada no
-- banco para o gestor cadastrar cursos - falta so a TELA.
-- Este SQL apenas garante dois ajustes pequenos:
--   1. Coluna "ordem" em cursos (para reordenar a vitrine)
--   2. Valor padrao explicito de ativo=true ao criar curso
-- ============================================================

alter table cursos
  add column if not exists ordem int not null default 0;

alter table cursos
  alter column ativo set default true;

-- Verificacao (opcional):
-- select column_name, column_default from information_schema.columns
--   where table_name = 'cursos' and column_name in ('ordem','ativo');

-- ------------------------------------------------------------
-- 3. Bucket de Storage para conteudo de curso (upload direto)
--    Leitura: staff do tenant OU aluno matriculado no curso da aula.
--    Escrita: apenas staff do tenant.
--    Convencao de caminho: {tenant_id}/{curso_id}/{arquivo}
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('conteudo-cursos', 'conteudo-cursos', false)
on conflict (id) do nothing;

create policy conteudo_cursos_staff_write on storage.objects
  for all to authenticated
  using (
    bucket_id = 'conteudo-cursos'
    and (storage.foldername(name))[1] = public.current_tenant_id()::text
    and public.is_staff()
  )
  with check (
    bucket_id = 'conteudo-cursos'
    and (storage.foldername(name))[1] = public.current_tenant_id()::text
    and public.is_staff()
  );

create policy conteudo_cursos_aluno_leitura on storage.objects
  for select to authenticated
  using (
    bucket_id = 'conteudo-cursos'
    and (storage.foldername(name))[1] = public.current_tenant_id()::text
    and exists (
      select 1 from matriculas m
      join cursos c on c.id = m.curso_id
      where c.id::text = (storage.foldername(name))[2]
        and m.usuario_id = public.current_usuario_id()
        and m.situacao = 'ativa'
    )
  );

-- Verificacao (opcional):
-- select id, public from storage.buckets where id = 'conteudo-cursos';
