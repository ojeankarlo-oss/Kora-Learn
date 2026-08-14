-- ============================================================
-- KORA LEARN — Migration 005: Fase 6 (Documentos + Contrato + LGPD)
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- O que faz:
--   1. Tabela de documentos do aluno (RG, comprovantes, etc.)
--   2. Bucket de Storage 'documentos' com políticas RLS
--   3. Modelos de contrato por tenant (ou padrão KORA)
--   4. Registro de aceites (contrato e LGPD) com hash e data
-- ============================================================

-- ------------------------------------------------------------
-- 0. Tipos
-- ------------------------------------------------------------
do $$ begin
  create type situacao_documento as enum ('pendente','aprovado','reprovado');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tipo_aceite as enum ('contrato','lgpd');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 1. Documentos do aluno
-- ------------------------------------------------------------
create table if not exists documentos (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  usuario_id    uuid not null references usuarios(id) on delete cascade,
  matricula_id  uuid references matriculas(id) on delete set null,
  tipo          text not null,                 -- rg | cpf | comprovante_residencia | historico | outro
  nome_arquivo  text not null,
  storage_path  text not null,                 -- tenant_id/usuario_id/arquivo
  situacao      situacao_documento not null default 'pendente',
  motivo        text,                          -- preenchido quando reprovado
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists idx_documentos_tenant on documentos(tenant_id);
create index if not exists idx_documentos_usuario on documentos(usuario_id);

do $$ begin
  create trigger trg_documentos_updated before update on documentos
    for each row execute function public.set_updated_at();
exception when duplicate_object then null; end $$;

alter table documentos enable row level security;

-- Aluno gerencia os próprios documentos
create policy documentos_self on documentos
  for all to authenticated
  using (usuario_id = public.current_usuario_id())
  with check (usuario_id = public.current_usuario_id()
              and tenant_id = public.current_tenant_id());

-- Staff vê e atualiza (aprovar/reprovar) os do tenant
create policy documentos_staff_select on documentos
  for select to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff());

create policy documentos_staff_update on documentos
  for update to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

-- ------------------------------------------------------------
-- 2. Bucket de Storage + políticas
--    Convenção de caminho: {tenant_id}/{usuario_id}/{arquivo}
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('documentos', 'documentos', false)
on conflict (id) do nothing;

-- Aluno envia apenas na própria pasta (tenant/usuario)
create policy "documentos_upload_proprio"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'documentos'
  and (storage.foldername(name))[1] = public.current_tenant_id()::text
  and (storage.foldername(name))[2] = public.current_usuario_id()::text
);

-- Aluno lê os próprios arquivos
create policy "documentos_leitura_propria"
on storage.objects for select to authenticated
using (
  bucket_id = 'documentos'
  and (storage.foldername(name))[2] = public.current_usuario_id()::text
);

-- Staff lê qualquer arquivo do próprio tenant
create policy "documentos_leitura_staff"
on storage.objects for select to authenticated
using (
  bucket_id = 'documentos'
  and (storage.foldername(name))[1] = public.current_tenant_id()::text
  and public.is_staff()
);

-- Aluno pode substituir/remover o próprio arquivo (reenvio)
create policy "documentos_delete_proprio"
on storage.objects for delete to authenticated
using (
  bucket_id = 'documentos'
  and (storage.foldername(name))[2] = public.current_usuario_id()::text
);

-- ------------------------------------------------------------
-- 3. Modelos de contrato por tenant
--    Se o tenant não tiver contrato ativo, o app usa o modelo
--    padrão KORA embutido no código.
-- ------------------------------------------------------------
create table if not exists contratos (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  titulo      text not null default 'Contrato de Prestação de Serviços Educacionais',
  corpo_md    text not null,                   -- markdown com placeholders {{...}}
  versao      int  not null default 1,
  ativo       boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists idx_contratos_tenant on contratos(tenant_id);

alter table contratos enable row level security;

create policy contratos_select on contratos
  for select to authenticated
  using (tenant_id = public.current_tenant_id());

create policy contratos_write on contratos
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

-- ------------------------------------------------------------
-- 4. Aceites (contrato e LGPD) — a prova jurídica
-- ------------------------------------------------------------
create table if not exists aceites (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  usuario_id     uuid not null references usuarios(id) on delete cascade,
  matricula_id   uuid references matriculas(id) on delete set null,
  tipo           tipo_aceite not null,
  contrato_id    uuid references contratos(id) on delete set null,  -- null = modelo padrão KORA
  versao         text not null,                 -- versão do texto aceito
  hash_conteudo  text not null,                 -- SHA-256 do texto exato aceito
  user_agent     text,
  aceito_em      timestamptz not null default now(),
  unique (usuario_id, tipo, versao)
);
create index if not exists idx_aceites_tenant on aceites(tenant_id);
create index if not exists idx_aceites_usuario on aceites(usuario_id);

alter table aceites enable row level security;

-- Aluno registra e consulta os próprios aceites
create policy aceites_self on aceites
  for all to authenticated
  using (usuario_id = public.current_usuario_id())
  with check (usuario_id = public.current_usuario_id()
              and tenant_id = public.current_tenant_id());

-- Staff consulta os aceites do tenant (auditoria)
create policy aceites_staff on aceites
  for select to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff());

-- ------------------------------------------------------------
-- 5. Liga o módulo Documentos no kora-demo (para testes)
-- ------------------------------------------------------------
update tenants
set config = jsonb_set(
  coalesce(config, '{}'::jsonb),
  '{modulos,documentos}', 'true'::jsonb, true
)
where slug = 'kora-demo';

-- ------------------------------------------------------------
-- Verificação (opcional):
-- select id, name from storage.buckets where id = 'documentos';
-- select tablename from pg_tables where tablename in
--   ('documentos','contratos','aceites');
-- ============================================================
