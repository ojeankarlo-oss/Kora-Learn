\set ON_ERROR_STOP on
-- ============================================================================
-- Limpeza de dados SINTÉTICOS em staging REMOTO descartável (Opção C).
-- Preferência: EXCLUIR O PROJETO inteiro (ver PLANO-ROLLBACK.md). Use este script
-- apenas para "resetar" um projeto descartável dedicado entre execuções.
--
-- Pré-condições obrigatórias (fail-closed):
--   * projeto dedicado e descartável, NUNCA o de produção;
--   * arquivos do Storage removidos ANTES via Storage API (apagar storage.objects
--     por SQL deixa o binário órfão no backend de arquivos);
--   * executar dentro de transação e conferir o relatório antes do COMMIT manual.
-- ============================================================================
begin;

do $$
declare v_foreign int;
begin
  select count(*) into v_foreign from public.tenants where slug not like 'kora-stg-%';
  if v_foreign > 0 then
    raise exception 'KORA-STG CLEANUP ABORT: % tenant(s) não sintético(s) presentes; este não é um alvo descartável', v_foreign;
  end if;
  select count(*) into v_foreign from auth.users where email is null or email not like '%@kora-staging.invalid';
  if v_foreign > 0 then
    raise exception 'KORA-STG CLEANUP ABORT: % usuário(s) Auth não sintético(s) presentes', v_foreign;
  end if;
end $$;

-- avaliacao_questoes -> questoes é ON DELETE RESTRICT: remover vínculos antes.
delete from public.avaliacao_questoes aq
 using public.avaliacoes a, public.tenants t
 where aq.avaliacao_id = a.id and a.tenant_id = t.id and t.slug like 'kora-stg-%';

-- Demais tabelas dependem de tenants com ON DELETE CASCADE.
delete from public.tenants where slug like 'kora-stg-%';
delete from auth.users where email like '%@kora-staging.invalid';

select 'restantes_tenants_stg', count(*) from public.tenants where slug like 'kora-stg-%'
union all select 'restantes_auth_stg', count(*) from auth.users where email like '%@kora-staging.invalid'
union all select 'restantes_objetos_storage', count(*) from storage.objects
 where bucket_id in ('documentos','conteudo-cursos') and name like 'f1000000-0000-4000-8000-00000000000%';

-- Conferir os números acima. Se tudo zerado: COMMIT; caso contrário: ROLLBACK.
-- (sem COMMIT automático de propósito)
