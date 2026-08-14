-- ============================================================
-- KORA LEARN — Migration 015: Correcao da funcao de notificacao
-- (reconciliacao com o que ja roda em producao)
--
-- CONTEXTO: o arquivo 012_kora_learn_notificacao_email.sql, na
-- versao original, tinha um bug de serializacao (usava
-- array[v_email] em vez de jsonb_build_array(v_email) no campo
-- "to" da chamada a API do Resend), causando erro 400 "Request
-- body must be valid JSON". A correcao foi aplicada diretamente
-- no SQL Editor do Supabase durante a sessao de debug, e nunca
-- tinha virado arquivo de migration versionado ate agora.
--
-- Rodar este arquivo e seguro mesmo que a correcao ja esteja
-- aplicada em producao (create or replace e idempotente) — serve
-- para o repositorio Git refletir o estado real do banco.
-- ============================================================

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

  -- CORRECAO (vs. migration 012 original): 'to' precisa ser um
  -- array JSON de verdade. array[v_email] (array nativo do
  -- Postgres) nao serializa corretamente; jsonb_build_array(v_email)
  -- resolve.
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_api_key,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'from', 'KORA Learn <nao-responda@koraed.com.br>',
      'to', jsonb_build_array(v_email),
      'subject', v_assunto_mail,
      'html', v_corpo
    )
  );

  return new;
end;
$$;

-- Verificacao (opcional):
-- select prosrc from pg_proc where proname = 'notificar_chamado_respondido';
-- (deve conter "jsonb_build_array", nao "array[")
