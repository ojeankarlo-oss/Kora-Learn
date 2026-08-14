-- ============================================================
-- KORA LEARN — Migration 007: Onboarding de gestor sem SQL
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- O que faz:
--   1. Cria a função `criar_minha_escola`: qualquer pessoa
--      autenticada (que ainda não tenha vínculo com nenhum
--      tenant) pode criar um tenant novo e virar gestora dele,
--      num único passo — sem SQL, sem você no meio.
--   2. Cria a função `meu_status_onboarding`: o app usa para
--      saber se o usuário logado já tem tenant ou precisa
--      passar pela tela de "Criar minha escola".
-- ============================================================

-- ------------------------------------------------------------
-- 1. Criar escola (tenant) + virar gestor, em uma transação
-- ------------------------------------------------------------
create or replace function public.criar_minha_escola(
  p_nome_escola text,
  p_slug text,
  p_nome_gestor text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_email text;
  v_tenant_id uuid;
  v_usuario_id uuid;
  v_slug_normalizado text;
begin
  if v_auth_uid is null then
    raise exception 'Usuário não autenticado.';
  end if;

  -- Impede um login já vinculado a algum tenant de criar outro
  if exists (select 1 from usuarios where auth_user_id = v_auth_uid) then
    raise exception 'Este login já está vinculado a uma escola existente.';
  end if;

  select email into v_email from auth.users where id = v_auth_uid;

  -- Normaliza o slug: minúsculas, sem espaços/acentos, só letras/números/hífen
  v_slug_normalizado := lower(regexp_replace(trim(p_slug), '[^a-zA-Z0-9]+', '-', 'g'));
  v_slug_normalizado := trim(both '-' from v_slug_normalizado);

  if v_slug_normalizado = '' or v_slug_normalizado is null then
    raise exception 'Informe um identificador válido para a escola (ex.: minha-escola).';
  end if;

  if exists (select 1 from tenants where slug = v_slug_normalizado) then
    raise exception 'Já existe uma escola com este identificador. Escolha outro.';
  end if;

  -- Cria o tenant com a configuração padrão KORA (mesma da migration 003)
  insert into tenants (nome, slug, plano, config)
  values (
    trim(p_nome_escola),
    v_slug_normalizado,
    'starter',
    jsonb_build_object(
      'marca', jsonb_build_object(
        'cor_primaria', '#17604A',
        'cor_destaque', '#E9A13B',
        'slogan', 'Cada aula aprendida, uma vida se transforma.'
      ),
      'modulos', jsonb_build_object(
        'inscricao_publica', true,
        'alunos', true,
        'financeiro', true,
        'documentos', true
      )
    )
  )
  returning id into v_tenant_id;

  -- Vincula o usuário autenticado como gestor deste tenant
  insert into usuarios (auth_user_id, tenant_id, perfil, nome, email)
  values (v_auth_uid, v_tenant_id, 'gestor', trim(p_nome_gestor), v_email)
  returning id into v_usuario_id;

  return jsonb_build_object(
    'tenant_id', v_tenant_id,
    'slug', v_slug_normalizado,
    'usuario_id', v_usuario_id
  );
end;
$$;

grant execute on function public.criar_minha_escola(text, text, text) to authenticated;

-- ------------------------------------------------------------
-- 2. Status de onboarding: o app pergunta "eu já tenho escola?"
-- ------------------------------------------------------------
create or replace function public.meu_status_onboarding()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'tem_tenant', exists(select 1 from usuarios where auth_user_id = auth.uid()),
    'email', (select email from auth.users where id = auth.uid())
  );
$$;

grant execute on function public.meu_status_onboarding() to authenticated;

-- ------------------------------------------------------------
-- Verificação (opcional, após um usuário de teste logar):
-- select public.meu_status_onboarding();
-- ============================================================
