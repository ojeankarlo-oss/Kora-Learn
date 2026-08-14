-- ============================================================
-- KORA LEARN — Migration 012: Notificação por e-mail (chamados)
-- Rodar no SQL Editor do Supabase (projeto Kora-learn)
-- Pré-requisito manual (fazer ANTES de rodar este SQL):
--   1. No painel do Supabase: Project Settings -> Vault
--      -> New secret -> nome: resend_api_key -> valor: sua chave
--      re_... do Resend (a mesma ja usada no SMTP).
-- O que este SQL faz:
--   1. Habilita a extensao pg_net (permite o Postgres fazer
--      requisicoes HTTP de dentro de um trigger)
--   2. Cria a funcao que monta e envia o e-mail via API do
--      Resend quando um chamado passa a 'respondido'
--   3. Cria o trigger que dispara essa funcao automaticamente
-- ============================================================

create extension if not exists pg_net with schema extensions;

create or replace function public.notificar_chamado_respondido()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email        text;
  v_nome         text;
  v_api_key      text;
  v_assunto_mail text;
  v_corpo        text;
  v_tenant_nome  text;
begin
  if new.situacao is distinct from 'respondido' or old.situacao = 'respondido' then
    return new;
  end if;

  select u.email, u.nome into v_email, v_nome
  from usuarios u where u.id = new.solicitante_id;

  select t.nome into v_tenant_nome
  from tenants t where t.id = new.tenant_id;

  if v_email is null then
    return new;
  end if;

  select decrypted_secret into v_api_key
  from vault.decrypted_secrets
  where name = 'resend_api_key'
  limit 1;

  if v_api_key is null then
    return new;
  end if;

  v_assunto_mail := 'Sua solicitacao foi respondida - ' || coalesce(v_tenant_nome, 'KORA Learn');
  v_corpo := '<p>Ola, ' || coalesce(v_nome, '') || '!</p>'
    || '<p>Sua solicitacao "<strong>' || coalesce(new.assunto, '') || '</strong>" foi respondida.</p>'
    || '<p>Acesse a plataforma para ver os detalhes da resposta.</p>'
    || '<p style="color:#5C6E67;font-size:12px">Este e um e-mail automatico, nao e necessario responder.</p>';

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_api_key,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'from', 'KORA Learn <nao-responda@koraed.com.br>',
      'to', array[v_email],
      'subject', v_assunto_mail,
      'html', v_corpo
    )
  );

  return new;
end;
$$;

drop trigger if exists trg_notificar_chamado_respondido on chamados;

create trigger trg_notificar_chamado_respondido
  after update on chamados
  for each row
  execute function public.notificar_chamado_respondido();

-- ------------------------------------------------------------
-- Verificacao (opcional, depois de configurar o Vault):
-- update chamados set situacao = 'respondido' where id = '<algum-id-de-teste>';
-- (confira a caixa de entrada do solicitante de teste)
-- ============================================================
