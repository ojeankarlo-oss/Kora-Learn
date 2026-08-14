-- ============================================================
-- KORA LEARN — Migration 013: Portal do Professor (Fase 11)
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- Pré-requisito: professores_turmas já existe (migration 009).
-- O que faz:
--   1. Tabela `materiais_professor` (artigos, PDFs, links por
--      disciplina/turma, publicados pelo professor)
--   2. Tabela `avisos_turma` (agenda: provas, trabalhos, eventos)
--   3. RLS: professor só cria/edita nas turmas vinculadas a ele;
--      aluno matriculado na turma lê; staff gerencia tudo
--   4. Função pública para o app saber "estou logado como
--      professor de quais turmas?"
-- ============================================================

-- ------------------------------------------------------------
-- 0. Tipos
-- ------------------------------------------------------------
do $$ begin
  create type tipo_material as enum ('artigo','pdf','link','video','livro_indicado');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tipo_aviso as enum ('prova','trabalho','evento','aviso_geral');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 1. Materiais publicados pelo professor
-- ------------------------------------------------------------
create table if not exists materiais_professor (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  turma_id       uuid not null references turmas(id) on delete cascade,
  disciplina_id  uuid references disciplinas(id) on delete set null,
  professor_id   uuid not null references usuarios(id) on delete cascade,
  tipo           tipo_material not null default 'artigo',
  titulo         text not null,
  descricao      text,
  url            text,              -- link externo ou caminho de arquivo (Storage)
  created_at     timestamptz not null default now()
);
create index if not exists idx_materiais_prof_tenant on materiais_professor(tenant_id);
create index if not exists idx_materiais_prof_turma  on materiais_professor(turma_id);

alter table materiais_professor enable row level security;

create policy materiais_prof_staff on materiais_professor
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

create policy materiais_prof_professor on materiais_professor
  for all to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and exists (
      select 1 from professores_turmas pt
      where pt.turma_id = materiais_professor.turma_id
        and pt.usuario_id = public.current_usuario_id()
    )
  )
  with check (
    tenant_id = public.current_tenant_id()
    and professor_id = public.current_usuario_id()
    and exists (
      select 1 from professores_turmas pt
      where pt.turma_id = materiais_professor.turma_id
        and pt.usuario_id = public.current_usuario_id()
    )
  );

-- Aluno matriculado na turma pode LER os materiais dela
create policy materiais_prof_aluno_select on materiais_professor
  for select to authenticated
  using (
    exists (
      select 1 from matriculas m
      where m.turma_id = materiais_professor.turma_id
        and m.usuario_id = public.current_usuario_id()
        and m.situacao = 'ativa'
    )
  );

-- ------------------------------------------------------------
-- 2. Avisos/agenda da turma (provas, trabalhos, eventos)
-- ------------------------------------------------------------
create table if not exists avisos_turma (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  turma_id      uuid not null references turmas(id) on delete cascade,
  professor_id  uuid references usuarios(id) on delete set null,
  tipo          tipo_aviso not null default 'aviso_geral',
  titulo        text not null,
  descricao     text,
  data_evento   date,              -- data da prova/entrega/evento (opcional para aviso_geral)
  created_at    timestamptz not null default now()
);
create index if not exists idx_avisos_tenant on avisos_turma(tenant_id);
create index if not exists idx_avisos_turma  on avisos_turma(turma_id, data_evento);

alter table avisos_turma enable row level security;

create policy avisos_staff on avisos_turma
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

create policy avisos_professor on avisos_turma
  for all to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and exists (
      select 1 from professores_turmas pt
      where pt.turma_id = avisos_turma.turma_id
        and pt.usuario_id = public.current_usuario_id()
    )
  )
  with check (
    tenant_id = public.current_tenant_id()
    and exists (
      select 1 from professores_turmas pt
      where pt.turma_id = avisos_turma.turma_id
        and pt.usuario_id = public.current_usuario_id()
    )
  );

create policy avisos_aluno_select on avisos_turma
  for select to authenticated
  using (
    exists (
      select 1 from matriculas m
      where m.turma_id = avisos_turma.turma_id
        and m.usuario_id = public.current_usuario_id()
        and m.situacao = 'ativa'
    )
  );

-- ------------------------------------------------------------
-- 3. Função: turmas do professor logado (para o roteamento
--    e para as telas do Portal do Professor)
-- ------------------------------------------------------------
create or replace function public.minhas_turmas_professor()
returns table (turma_id uuid, turma_nome text, curso_nome text)
language sql
stable
security definer
set search_path = public
as $$
  select t.id, t.nome, c.nome
  from professores_turmas pt
  join turmas t on t.id = pt.turma_id
  join cursos c on c.id = t.curso_id
  where pt.usuario_id = public.current_usuario_id();
$$;

grant execute on function public.minhas_turmas_professor() to authenticated;

-- ------------------------------------------------------------
-- Verificação (opcional):
-- select tablename from pg_tables where schemaname='public'
--   and tablename in ('materiais_professor','avisos_turma');
-- ============================================================
