-- KORA P0-001 — hardening de leads e catálogo público
-- Resolve o tenant por slug no servidor; não confia em tenant_id enviado pelo cliente.
-- Acesso público passa exclusivamente pelas RPCs abaixo.

create or replace function public.criar_lead_publico(
  p_tenant_slug text,
  p_curso_id uuid,
  p_unidade_id uuid,
  p_nome text,
  p_email text,
  p_telefone text,
  p_origem text,
  p_tem_necessidade_especifica boolean,
  p_necessidades_especificas text[]
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant_id uuid;
  v_lead_id uuid;
begin
  if nullif(trim(p_tenant_slug), '') is null then
    raise exception using errcode = '22023', message = 'Tenant público obrigatório';
  end if;

  if nullif(trim(p_nome), '') is null then
    raise exception using errcode = '22023', message = 'Nome obrigatório';
  end if;

  if nullif(trim(p_email), '') is null then
    raise exception using errcode = '22023', message = 'E-mail obrigatório';
  end if;

  select t.id
    into v_tenant_id
    from public.tenants t
   where t.slug = lower(trim(p_tenant_slug))
     and t.ativo = true;

  if v_tenant_id is null then
    raise exception using errcode = '22023', message = 'Tenant público inválido';
  end if;

  if p_curso_id is not null and not exists (
    select 1
      from public.cursos c
     where c.id = p_curso_id
       and c.tenant_id = v_tenant_id
       and c.ativo = true
  ) then
    raise exception using errcode = '22023', message = 'Curso inválido para o tenant público';
  end if;

  if p_unidade_id is not null and not exists (
    select 1
      from public.unidades u
     where u.id = p_unidade_id
       and u.tenant_id = v_tenant_id
       and u.ativo = true
  ) then
    raise exception using errcode = '22023', message = 'Unidade inválida para o tenant público';
  end if;

  insert into public.leads (
    tenant_id,
    curso_id,
    unidade_id,
    nome,
    email,
    telefone,
    origem,
    tem_necessidade_especifica,
    necessidades_especificas
  ) values (
    v_tenant_id,
    p_curso_id,
    p_unidade_id,
    trim(p_nome),
    lower(trim(p_email)),
    nullif(trim(p_telefone), ''),
    coalesce(nullif(trim(p_origem), ''), 'site'),
    coalesce(p_tem_necessidade_especifica, false),
    p_necessidades_especificas
  )
  returning id into v_lead_id;

  return v_lead_id;
end;
$$;

revoke all on function public.criar_lead_publico(text, uuid, uuid, text, text, text, text, boolean, text[]) from public;
grant execute on function public.criar_lead_publico(text, uuid, uuid, text, text, text, text, boolean, text[]) to anon, authenticated;

-- Remove a inserção direta pública; leads entram pelo RPC que resolve o tenant.
drop policy if exists leads_insert_public on public.leads;
revoke insert on table public.leads from anon, authenticated;

create or replace function public.listar_cursos_publicos(p_tenant_slug text)
returns table (id uuid, nome text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select c.id, c.nome
    from public.cursos c
    join public.tenants t on t.id = c.tenant_id
   where t.slug = lower(trim(p_tenant_slug))
     and t.ativo = true
     and c.ativo = true
   order by c.nome;
$$;

revoke all on function public.listar_cursos_publicos(text) from public;
grant execute on function public.listar_cursos_publicos(text) to anon, authenticated;

-- Remove o SELECT amplo de anon; o catálogo público passa pela RPC com slug.
drop policy if exists cursos_select_publico on public.cursos;
revoke select on table public.cursos from anon;
