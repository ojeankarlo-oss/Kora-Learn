-- ============================================================
-- KORA LEARN — Migration 009: Presença / Frequência (Fase 11)
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- O que faz:
--   1. Tabela `presencas`: registro de presença por aula/aluno,
--      com tipo (síncrona/assíncrona), ambiente e observação
--   2. Vínculo professor ↔ turma (para RLS: professor só
--      registra presença nas turmas dele)
--   3. RLS: professor/staff registram e leem do tenant; aluno
--      só lê a própria frequência
--   4. View de frequência consolidada por aluno/disciplina
-- ============================================================

-- ------------------------------------------------------------
-- 0. Tipos
-- ------------------------------------------------------------
do $$ begin
  create type tipo_aula as enum ('sincrona','assincrona');
exception when duplicate_object then null; end $$;

do $$ begin
  create type situacao_presenca as enum ('presente','ausente','justificada');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 1. Vínculo professor ↔ turma
--    (pré-requisito para RLS: sem isso não dá para restringir
--     "o professor só vê as turmas dele")
-- ------------------------------------------------------------
create table if not exists professores_turmas (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  usuario_id   uuid not null references usuarios(id) on delete cascade, -- o professor
  turma_id     uuid not null references turmas(id) on delete cascade,
  created_at   timestamptz not null default now(),
  unique (usuario_id, turma_id)
);
create index if not exists idx_prof_turmas_tenant on professores_turmas(tenant_id);
create index if not exists idx_prof_turmas_prof    on professores_turmas(usuario_id);
create index if not exists idx_prof_turmas_turma   on professores_turmas(turma_id);

alter table professores_turmas enable row level security;

create policy prof_turmas_staff on professores_turmas
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

create policy prof_turmas_select_proprio on professores_turmas
  for select to authenticated
  using (usuario_id = public.current_usuario_id());

-- ------------------------------------------------------------
-- 2. Registro de aula (o "evento" de uma aula dada)
--    Uma linha por (turma, disciplina, data) — o professor cria
--    o registro da aula e depois marca presença de cada aluno.
-- ------------------------------------------------------------
create table if not exists registros_aula (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  turma_id      uuid not null references turmas(id) on delete cascade,
  disciplina_id uuid references disciplinas(id) on delete set null,
  professor_id  uuid references usuarios(id) on delete set null,
  data_aula     date not null default current_date,
  tipo          tipo_aula not null default 'sincrona',
  ambiente      text,          -- ex.: "Sala 4", "Quadra", "Online", "Laboratório"
  observacao    text,          -- ex.: "Aula de educação física na quadra"
  created_at    timestamptz not null default now()
);
create index if not exists idx_registros_aula_tenant on registros_aula(tenant_id);
create index if not exists idx_registros_aula_turma  on registros_aula(turma_id, data_aula);

alter table registros_aula enable row level security;

-- Staff do tenant gerencia tudo
create policy registros_aula_staff on registros_aula
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

-- Professor cria/edita registros SÓ das turmas vinculadas a ele
create policy registros_aula_professor on registros_aula
  for all to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and exists (
      select 1 from professores_turmas pt
      where pt.turma_id = registros_aula.turma_id
        and pt.usuario_id = public.current_usuario_id()
    )
  )
  with check (
    tenant_id = public.current_tenant_id()
    and exists (
      select 1 from professores_turmas pt
      where pt.turma_id = registros_aula.turma_id
        and pt.usuario_id = public.current_usuario_id()
    )
  );

-- ------------------------------------------------------------
-- 3. Presença por aluno, dentro de cada registro de aula
-- ------------------------------------------------------------
create table if not exists presencas (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  registro_aula_id uuid not null references registros_aula(id) on delete cascade,
  usuario_id       uuid not null references usuarios(id) on delete cascade, -- o aluno
  situacao         situacao_presenca not null default 'presente',
  created_at       timestamptz not null default now(),
  unique (registro_aula_id, usuario_id)
);
create index if not exists idx_presencas_tenant  on presencas(tenant_id);
create index if not exists idx_presencas_aluno   on presencas(usuario_id);
create index if not exists idx_presencas_registro on presencas(registro_aula_id);

alter table presencas enable row level security;

-- Staff gerencia tudo
create policy presencas_staff on presencas
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

-- Professor marca presença SÓ nas turmas vinculadas a ele
create policy presencas_professor on presencas
  for all to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and exists (
      select 1 from registros_aula ra
      join professores_turmas pt on pt.turma_id = ra.turma_id
      where ra.id = presencas.registro_aula_id
        and pt.usuario_id = public.current_usuario_id()
    )
  )
  with check (
    tenant_id = public.current_tenant_id()
    and exists (
      select 1 from registros_aula ra
      join professores_turmas pt on pt.turma_id = ra.turma_id
      where ra.id = presencas.registro_aula_id
        and pt.usuario_id = public.current_usuario_id()
    )
  );

-- Aluno só LÊ a própria presença
create policy presencas_select_proprio on presencas
  for select to authenticated
  using (usuario_id = public.current_usuario_id());

-- ------------------------------------------------------------
-- 4. View de frequência consolidada (para o portal do aluno
--    e para o Módulo Pedagógico da Fase 12)
-- ------------------------------------------------------------
create or replace view frequencia_consolidada as
select
  p.tenant_id,
  p.usuario_id,
  ra.turma_id,
  ra.disciplina_id,
  count(*) filter (where p.situacao = 'presente')                        as total_presencas,
  count(*) filter (where p.situacao = 'ausente')                         as total_ausencias,
  count(*) filter (where p.situacao = 'justificada')                     as total_justificadas,
  count(*)                                                               as total_aulas,
  round(
    100.0 * count(*) filter (where p.situacao in ('presente','justificada'))
    / nullif(count(*), 0)
  , 1)                                                                   as percentual_frequencia
from presencas p
join registros_aula ra on ra.id = p.registro_aula_id
group by p.tenant_id, p.usuario_id, ra.turma_id, ra.disciplina_id;

-- Views não herdam RLS das tabelas base automaticamente em todas as
-- configurações; garantimos segurança via security_invoker (Postgres 15+)
alter view frequencia_consolidada set (security_invoker = true);

grant select on frequencia_consolidada to authenticated;

-- ------------------------------------------------------------
-- Verificação (opcional):
-- select tablename from pg_tables where schemaname='public'
--   and tablename in ('presencas','registros_aula','professores_turmas');
-- ============================================================
