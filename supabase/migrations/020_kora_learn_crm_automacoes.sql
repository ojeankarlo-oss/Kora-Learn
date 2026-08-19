-- Kora Learn — Migration 020
-- Phase 8: CRM, automações e WhatsApp stub.
-- Usa current_* / is_staff() para respeitar auth_user_id -> usuarios.id.
-- Idempotente: tabelas, índices, funções e triggers podem ser reaplicados.

create table if not exists contacts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  nome text not null,
  email text,
  telefone text,
  tipo text not null default 'lead' check (tipo in ('lead','contato','prospect','cliente')),
  status text not null default 'ativo' check (status in ('ativo','inativo','bloqueado')),
  fonte text check (fonte is null or fonte in ('website','indicacao','evento','campanha','manual','whatsapp','parceiro')),
  data_primeiro_contato timestamptz not null default now(),
  data_ultimo_contato timestamptz,
  notas text,
  criado_por uuid references usuarios(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists automations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  nome text not null,
  descricao text,
  tipo text not null check (tipo in ('email','whatsapp','sms','chamado')),
  trigger_tipo text not null check (trigger_tipo in ('novo_contato','data_marcada','evento','manual')),
  trigger_dados jsonb not null default '{}'::jsonb,
  acao_tipo text not null check (acao_tipo in ('enviar_msg','criar_chamado','atualizar_status')),
  acao_dados jsonb not null default '{}'::jsonb,
  ativo boolean not null default true,
  criado_por uuid references usuarios(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists whatsapp_templates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  nome text not null,
  corpo text not null,
  variaveis jsonb not null default '{}'::jsonb,
  status text not null default 'draft' check (status in ('draft','aprovado','rejeitado')),
  criado_por uuid references usuarios(id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists contact_messages (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid not null references contacts(id) on delete cascade,
  automation_id uuid references automations(id) on delete set null,
  canal text not null check (canal in ('email','whatsapp','sms')),
  destinatario text,
  assunto text,
  corpo text not null,
  variaveis_usadas jsonb not null default '{}'::jsonb,
  status text not null default 'enviado' check (status in ('enviado','falhou','entregue','lido')),
  tentativas integer not null default 1 check (tentativas > 0),
  proxima_tentativa timestamptz,
  respondido_em timestamptz,
  resposta_corpo text,
  criado_em timestamptz not null default now()
);

create index if not exists idx_contacts_tenant on contacts(tenant_id);
create index if not exists idx_contacts_tipo on contacts(tipo);
create index if not exists idx_contacts_status on contacts(status);
create index if not exists idx_contacts_email on contacts(email);
create index if not exists idx_contacts_telefone on contacts(telefone);
create index if not exists idx_automations_tenant on automations(tenant_id);
create index if not exists idx_automations_ativo on automations(ativo);
create index if not exists idx_messages_contact on contact_messages(contact_id);
create index if not exists idx_messages_automation on contact_messages(automation_id);
create index if not exists idx_messages_canal on contact_messages(canal);

create or replace function public.set_atualizado_em()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.atualizado_em = now();
  return new;
end;
$$;

drop trigger if exists trg_contacts_atualizado_em on contacts;
create trigger trg_contacts_atualizado_em before update on contacts
for each row execute function public.set_atualizado_em();
drop trigger if exists trg_automations_atualizado_em on automations;
create trigger trg_automations_atualizado_em before update on automations
for each row execute function public.set_atualizado_em();
drop trigger if exists trg_whatsapp_templates_atualizado_em on whatsapp_templates;
create trigger trg_whatsapp_templates_atualizado_em before update on whatsapp_templates
for each row execute function public.set_atualizado_em();

alter table contacts enable row level security;
alter table automations enable row level security;
alter table whatsapp_templates enable row level security;
alter table contact_messages enable row level security;

drop policy if exists contacts_select_staff on contacts;
create policy contacts_select_staff on contacts for select to authenticated
using (tenant_id = public.current_tenant_id() and public.is_staff());
drop policy if exists contacts_insert_staff on contacts;
create policy contacts_insert_staff on contacts for insert to authenticated
with check (tenant_id = public.current_tenant_id() and public.is_staff());
drop policy if exists contacts_update_staff on contacts;
create policy contacts_update_staff on contacts for update to authenticated
using (tenant_id = public.current_tenant_id() and public.is_staff())
with check (tenant_id = public.current_tenant_id() and public.is_staff());
drop policy if exists contacts_delete_staff on contacts;
create policy contacts_delete_staff on contacts for delete to authenticated
using (tenant_id = public.current_tenant_id() and public.is_staff());

drop policy if exists automations_select_staff on automations;
create policy automations_select_staff on automations for select to authenticated
using (tenant_id = public.current_tenant_id() and public.is_staff());
drop policy if exists automations_insert_staff on automations;
create policy automations_insert_staff on automations for insert to authenticated
with check (tenant_id = public.current_tenant_id() and public.is_staff());
drop policy if exists automations_update_staff on automations;
create policy automations_update_staff on automations for update to authenticated
using (tenant_id = public.current_tenant_id() and public.is_staff())
with check (tenant_id = public.current_tenant_id() and public.is_staff());
drop policy if exists automations_delete_staff on automations;
create policy automations_delete_staff on automations for delete to authenticated
using (tenant_id = public.current_tenant_id() and public.is_staff());

drop policy if exists templates_select_staff on whatsapp_templates;
create policy templates_select_staff on whatsapp_templates for select to authenticated
using (tenant_id = public.current_tenant_id() and public.is_staff());
drop policy if exists templates_insert_staff on whatsapp_templates;
create policy templates_insert_staff on whatsapp_templates for insert to authenticated
with check (tenant_id = public.current_tenant_id() and public.is_staff());
drop policy if exists templates_update_staff on whatsapp_templates;
create policy templates_update_staff on whatsapp_templates for update to authenticated
using (tenant_id = public.current_tenant_id() and public.is_staff())
with check (tenant_id = public.current_tenant_id() and public.is_staff());
drop policy if exists templates_delete_staff on whatsapp_templates;
create policy templates_delete_staff on whatsapp_templates for delete to authenticated
using (tenant_id = public.current_tenant_id() and public.is_staff());

drop policy if exists messages_select_staff on contact_messages;
create policy messages_select_staff on contact_messages for select to authenticated
using (exists (
  select 1 from contacts c
  where c.id = contact_messages.contact_id
    and c.tenant_id = public.current_tenant_id()
    and public.is_staff()
));
drop policy if exists messages_insert_staff on contact_messages;
create policy messages_insert_staff on contact_messages for insert to authenticated
with check (exists (
  select 1 from contacts c
  where c.id = contact_messages.contact_id
    and c.tenant_id = public.current_tenant_id()
    and public.is_staff()
));
drop policy if exists messages_update_staff on contact_messages;
create policy messages_update_staff on contact_messages for update to authenticated
using (exists (
  select 1 from contacts c
  where c.id = contact_messages.contact_id
    and c.tenant_id = public.current_tenant_id()
    and public.is_staff()
))
with check (exists (
  select 1 from contacts c
  where c.id = contact_messages.contact_id
    and c.tenant_id = public.current_tenant_id()
    and public.is_staff()
));
