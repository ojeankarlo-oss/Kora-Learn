-- ============================================================
-- KORA LEARN — Migration 011: Central de Chamados
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- O que faz:
--   1. Tabela `chamados` (solicitação genérica, tipada)
--   2. Tabela `chamados_mensagens` (thread de conversa)
--   3. SLA configurável por tipo, guardado no config do tenant
--   4. RLS: solicitante vê os próprios; staff vê e gerencia do tenant
-- ============================================================

do $$ begin
  create type situacao_chamado as enum ('aberto','em_andamento','respondido','fechado');
exception when duplicate_object then null; end $$;

create table if not exists chamados (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  unidade_id      uuid references unidades(id) on delete set null,
  solicitante_id  uuid not null references usuarios(id) on delete cascade,
  tipo            text not null,
  assunto         text not null,
  detalhes        text,
  situacao        situacao_chamado not null default 'aberto',
  prazo_resposta  timestamptz,
  respondido_em   timestamptz,
  respondido_por  uuid references usuarios(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists idx_chamados_tenant     on chamados(tenant_id);
create index if not exists idx_chamados_solicitante on chamados(solicitante_id);
create index if not exists idx_chamados_situacao    on chamados(tenant_id, situacao, prazo_resposta);

do $$ begin
  create trigger trg_chamados_updated before update on chamados
    for each row execute function public.set_updated_at();
exception when duplicate_object then null; end $$;

alter table chamados enable row level security;

create policy chamados_self on chamados
  for all to authenticated
  using (solicitante_id = public.current_usuario_id())
  with check (
    solicitante_id = public.current_usuario_id()
    and tenant_id = public.current_tenant_id()
  );

create policy chamados_staff on chamados
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.is_staff())
  with check (tenant_id = public.current_tenant_id() and public.is_staff());

create table if not exists chamados_mensagens (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  chamado_id   uuid not null references chamados(id) on delete cascade,
  autor_id     uuid not null references usuarios(id) on delete cascade,
  mensagem     text not null,
  created_at   timestamptz not null default now()
);
create index if not exists idx_chamados_msg_chamado on chamados_mensagens(chamado_id, created_at);

alter table chamados_mensagens enable row level security;

create policy chamados_msg_participantes on chamados_mensagens
  for all to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (
      public.is_staff()
      or exists (
        select 1 from chamados c
        where c.id = chamados_mensagens.chamado_id
          and c.solicitante_id = public.current_usuario_id()
      )
    )
  )
  with check (
    tenant_id = public.current_tenant_id()
    and autor_id = public.current_usuario_id()
    and (
      public.is_staff()
      or exists (
        select 1 from chamados c
        where c.id = chamados_mensagens.chamado_id
          and c.solicitante_id = public.current_usuario_id()
      )
    )
  );

create or replace function public.calcular_prazo_chamado(p_tenant_id uuid, p_tipo text)
returns timestamptz
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_horas int;
begin
  select coalesce(
    (config->'sla_chamados_horas'->>p_tipo)::int,
    72
  ) into v_horas
  from tenants where id = p_tenant_id;

  return now() + (v_horas || ' hours')::interval;
end;
$$;

grant execute on function public.calcular_prazo_chamado(uuid, text) to authenticated;

update tenants
set config = jsonb_set(
  coalesce(config, '{}'::jsonb),
  '{sla_chamados_horas}',
  '{"documento": 72, "material_pedagogico": 48}'::jsonb,
  true
)
where slug = 'kora-demo';

-- ------------------------------------------------------------
-- Verificação (opcional):
-- select config->'sla_chamados_horas' from tenants where slug='kora-demo';
-- select public.calcular_prazo_chamado((select id from tenants where slug='kora-demo'), 'documento');
-- ============================================================
