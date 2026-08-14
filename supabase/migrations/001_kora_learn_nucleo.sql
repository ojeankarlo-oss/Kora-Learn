-- ============================================================
-- KORA LEARN — Migration 001: Núcleo multi-tenant
-- Supabase (Postgres 15+) · pronto para colar no SQL Editor
-- Escopo: tenants, unidades, usuários, catálogo acadêmico,
--         turmas, matrículas, progresso e pré-matrícula (leads)
-- Fora deste arquivo (migrations futuras): financeiro,
--         gamificação, fórum, avaliações/banco de questões
-- ============================================================

-- ------------------------------------------------------------
-- 0. EXTENSÕES E TIPOS
-- ------------------------------------------------------------
create extension if not exists "pgcrypto";

do $$ begin
  create type perfil_usuario as enum
    ('super_admin','gestor','professor','tutor','aluno','responsavel','parceiro');
exception when duplicate_object then null; end $$;

do $$ begin
  create type situacao_matricula as enum
    ('ativa','cancelada','concluida','trancada');
exception when duplicate_object then null; end $$;

do $$ begin
  create type situacao_lead as enum
    ('novo','em_contato','convertido','descartado');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 1. TENANTS E UNIDADES
-- ------------------------------------------------------------
create table if not exists tenants (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  slug        text not null unique,          -- usado na URL pública: /t/{slug}
  logo_url    text,
  config      jsonb not null default '{}',
  plano       text not null default 'starter',
  ativo       boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists unidades (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  nome        text not null,
  cidade      text,
  estado      text,
  pais        text not null default 'BR',    -- pensado para Angola/CV desde já
  ativo       boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists idx_unidades_tenant on unidades(tenant_id);

-- ------------------------------------------------------------
-- 2. USUÁRIOS (perfil de aplicação ligado ao Supabase Auth)
-- ------------------------------------------------------------
create table if not exists usuarios (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid unique references auth.users(id) on delete set null,
  tenant_id     uuid not null references tenants(id) on delete cascade,
  unidade_id    uuid references unidades(id) on delete set null,
  perfil        perfil_usuario not null default 'aluno',
  nome          text not null,
  email         text not null,
  cpf           text,                        -- validar no app; em Angola usar BI
  telefone      text,
  avatar_url    text,
  ativo         boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (tenant_id, email)
);
create index if not exists idx_usuarios_tenant on usuarios(tenant_id);
create index if not exists idx_usuarios_auth on usuarios(auth_user_id);

-- ------------------------------------------------------------
-- 3. FUNÇÕES AUXILIARES DE CONTEXTO (base do RLS)
--    SECURITY DEFINER: executam como owner (postgres), que
--    ignora RLS — evita recursão nas policies de `usuarios`.
-- ------------------------------------------------------------
create or replace function public.current_usuario_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select id from usuarios where auth_user_id = auth.uid() limit 1;
$$;

create or replace function public.current_tenant_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select tenant_id from usuarios where auth_user_id = auth.uid() limit 1;
$$;

create or replace function public.current_perfil()
returns perfil_usuario
language sql stable security definer
set search_path = public
as $$
  select perfil from usuarios where auth_user_id = auth.uid() limit 1;
$$;

-- Atalho para policies de escrita administrativa
create or replace function public.is_staff()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(public.current_perfil() in ('super_admin','gestor'), false);
$$;

create or replace function public.is_docente()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(public.current_perfil() in ('super_admin','gestor','professor'), false);
$$;

-- ------------------------------------------------------------
-- 4. CATÁLOGO ACADÊMICO
-- ------------------------------------------------------------
create table if not exists cursos (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  nome           text not null,
  descricao      text,
  nivel          text not null default 'livre',   -- livre | tecnico | graduacao | pos | eja
  area           text,
  carga_horaria  int,
  imagem_url     text,
  preco_centavos int not null default 0,
  ativo          boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists idx_cursos_tenant on cursos(tenant_id);

create table if not exists disciplinas (
  id             uuid primary key default gen_random_uuid(),
  curso_id       uuid not null references cursos(id) on delete cascade,
  tenant_id      uuid not null references tenants(id) on delete cascade,
  nome           text not null,
  descricao      text,
  ordem          int not null default 0,
  carga_horaria  int,
  created_at     timestamptz not null default now()
);
create index if not exists idx_disciplinas_curso on disciplinas(curso_id);
create index if not exists idx_disciplinas_tenant on disciplinas(tenant_id);

create table if not exists aulas (
  id              uuid primary key default gen_random_uuid(),
  disciplina_id   uuid not null references disciplinas(id) on delete cascade,
  tenant_id       uuid not null references tenants(id) on delete cascade,
  titulo          text not null,
  tipo            text not null default 'video',  -- video | pdf | quiz | ao_vivo
  url_video       text,                           -- Bunny.net / YouTube privado
  duracao_seg     int,
  ordem           int not null default 0,
  obrigatoria     boolean not null default true,
  created_at      timestamptz not null default now()
);
create index if not exists idx_aulas_disciplina on aulas(disciplina_id);
create index if not exists idx_aulas_tenant on aulas(tenant_id);

create table if not exists materiais_apoio (
  id              uuid primary key default gen_random_uuid(),
  disciplina_id   uuid not null references disciplinas(id) on delete cascade,
  tenant_id       uuid not null references tenants(id) on delete cascade,
  titulo          text not null,
  tipo            text not null default 'pdf',    -- pdf | link | arquivo
  url             text not null,
  ordem           int not null default 0
);
create index if not exists idx_materiais_tenant on materiais_apoio(tenant_id);

-- ------------------------------------------------------------
-- 5. TURMAS E MATRÍCULAS
-- ------------------------------------------------------------
create table if not exists turmas (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  curso_id     uuid not null references cursos(id) on delete cascade,
  unidade_id   uuid references unidades(id) on delete set null,
  nome         text not null,
  data_inicio  date,
  data_fim     date,
  max_alunos   int,
  ativa        boolean not null default true,
  created_at   timestamptz not null default now()
);
create index if not exists idx_turmas_tenant on turmas(tenant_id);
create index if not exists idx_turmas_curso on turmas(curso_id);

create table if not exists matriculas (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  usuario_id      uuid not null references usuarios(id) on delete cascade,
  curso_id        uuid not null references cursos(id) on delete cascade,
  turma_id        uuid references turmas(id) on delete set null,
  situacao        situacao_matricula not null default 'ativa',
  origem          text not null default 'manual', -- manual | self_service | importacao | campanha
  data_matricula  date not null default current_date,
  created_at      timestamptz not null default now(),
  unique (usuario_id, curso_id, turma_id)
);
create index if not exists idx_matriculas_tenant on matriculas(tenant_id);
create index if not exists idx_matriculas_usuario on matriculas(usuario_id);

-- ------------------------------------------------------------
-- 6. PROGRESSO DO ALUNO
-- ------------------------------------------------------------
create table if not exists progresso_aulas (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references tenants(id) on delete cascade,
  usuario_id           uuid not null references usuarios(id) on delete cascade,
  aula_id              uuid not null references aulas(id) on delete cascade,
  percentual_assistido int not null default 0 check (percentual_assistido between 0 and 100),
  concluida            boolean not null default false,
  data_conclusao       timestamptz,
  updated_at           timestamptz not null default now(),
  unique (usuario_id, aula_id)
);
create index if not exists idx_progresso_tenant on progresso_aulas(tenant_id);
create index if not exists idx_progresso_usuario on progresso_aulas(usuario_id);

-- ------------------------------------------------------------
-- 7. PRÉ-MATRÍCULA / CAPTAÇÃO (formulário público)
-- ------------------------------------------------------------
create table if not exists leads (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  curso_id    uuid references cursos(id) on delete set null,
  nome        text not null,
  email       text not null,
  telefone    text,
  origem      text not null default 'site',     -- site | whatsapp | campanha | parceiro
  situacao    situacao_lead not null default 'novo',
  observacoes text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_leads_tenant on leads(tenant_id);
create index if not exists idx_leads_situacao on leads(tenant_id, situacao);

-- ------------------------------------------------------------
-- 8. TRIGGER updated_at
-- ------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

do $$ begin
  create trigger trg_usuarios_updated before update on usuarios
    for each row execute function public.set_updated_at();
exception when duplicate_object then null; end $$;

do $$ begin
  create trigger trg_cursos_updated before update on cursos
    for each row execute function public.set_updated_at();
exception when duplicate_object then null; end $$;

do $$ begin
  create trigger trg_progresso_updated before update on progresso_aulas
    for each row execute function public.set_updated_at();
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 9. ROW LEVEL SECURITY
-- ------------------------------------------------------------
alter table tenants          enable row level security;
alter table unidades         enable row level security;
alter table usuarios         enable row level security;
alter table cursos           enable row level security;
alter table disciplinas      enable row level security;
alter table aulas            enable row level security;
alter table materiais_apoio  enable row level security;
alter table turmas           enable row level security;
alter table matriculas       enable row level security;
alter table progresso_aulas  enable row level security;
alter table leads            enable row level security;

-- --- TENANTS: membro vê o próprio tenant; só super_admin altera
create policy tenants_select on tenants
  for select to authenticated
  using (id = public.current_tenant_id());

create policy tenants_update on tenants
  for update to authenticated
  using (id = public.current_tenant_id() and public.current_perfil() = 'super_admin');

-- --- UNIDADES
create policy unidades_select on unidades
  for select to authenticated
  using (tenant_id = public.current_tenant_id());

create policy unidades_write on unidades
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

-- --- USUARIOS: cada um vê a si mesmo; staff vê o tenant todo
create policy usuarios_select_self on usuarios
  for select to authenticated
  using (auth_user_id = auth.uid());

create policy usuarios_select_staff on usuarios
  for select to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff());

create policy usuarios_update_self on usuarios
  for update to authenticated
  using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

create policy usuarios_write_staff on usuarios
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

-- --- CATÁLOGO: leitura para todo membro; escrita para docentes/staff
create policy cursos_select on cursos
  for select to authenticated
  using (tenant_id = public.current_tenant_id());

create policy cursos_write on cursos
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_docente())
  with check (tenant_id = public.current_tenant_id() and public.is_docente());

create policy disciplinas_select on disciplinas
  for select to authenticated
  using (tenant_id = public.current_tenant_id());

create policy disciplinas_write on disciplinas
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_docente())
  with check (tenant_id = public.current_tenant_id() and public.is_docente());

create policy aulas_select on aulas
  for select to authenticated
  using (tenant_id = public.current_tenant_id());

create policy aulas_write on aulas
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_docente())
  with check (tenant_id = public.current_tenant_id() and public.is_docente());

create policy materiais_select on materiais_apoio
  for select to authenticated
  using (tenant_id = public.current_tenant_id());

create policy materiais_write on materiais_apoio
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_docente())
  with check (tenant_id = public.current_tenant_id() and public.is_docente());

-- --- TURMAS
create policy turmas_select on turmas
  for select to authenticated
  using (tenant_id = public.current_tenant_id());

create policy turmas_write on turmas
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

-- --- MATRÍCULAS: aluno vê as próprias; staff gerencia o tenant
create policy matriculas_select_self on matriculas
  for select to authenticated
  using (usuario_id = public.current_usuario_id());

create policy matriculas_staff on matriculas
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

-- --- PROGRESSO: aluno registra e lê o próprio; staff/professor lê o tenant
create policy progresso_self on progresso_aulas
  for all to authenticated
  using (usuario_id = public.current_usuario_id())
  with check (usuario_id = public.current_usuario_id()
              and tenant_id = public.current_tenant_id());

create policy progresso_select_docente on progresso_aulas
  for select to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_docente());

-- --- LEADS: formulário público pode INSERIR; só staff lê/gerencia
create policy leads_insert_public on leads
  for insert to anon, authenticated
  with check (true);

create policy leads_manage_staff on leads
  for select to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff());

create policy leads_update_staff on leads
  for update to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

-- ------------------------------------------------------------
-- 10. SEED DE DEMONSTRAÇÃO (opcional — remova em produção)
-- ------------------------------------------------------------
insert into tenants (nome, slug, plano)
values ('KORA Demo', 'kora-demo', 'starter')
on conflict (slug) do nothing;

-- Após criar seu usuário no Supabase Auth, vincule-o assim:
-- insert into usuarios (auth_user_id, tenant_id, perfil, nome, email)
-- values (
--   '<UUID_DO_AUTH_USERS>',
--   (select id from tenants where slug = 'kora-demo'),
--   'gestor',
--   'Jean Karlo',
--   'seu@email.com'
-- );

-- ============================================================
-- FIM DA MIGRATION 001
-- Próximas migrations sugeridas:
--   002_financeiro.sql   (planos_pagamento, titulos, gateway Asaas)
--   003_gamificacao.sql  (xp_eventos, badges, ranking)
--   004_avaliacoes.sql   (bancos_questoes, questoes, tentativas)
-- ============================================================
