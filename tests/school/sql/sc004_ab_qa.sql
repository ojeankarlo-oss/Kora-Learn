\set ON_ERROR_STOP on
-- KORA LEARN SC-004A/B — disposable School A/B runtime QA
-- Run only after canonical migrations 001-040, recovered migrations 042-047 have been replayed in a disposable DB.
-- This file never applies a migration and never connects to Supabase/production.

\echo 'SC004 QA: creating temporary result helpers'
create temp table qa_results (
  id text not null,
  expected text not null,
  observed text not null,
  result text not null,
  classification text not null,
  state_before text,
  state_after text,
  detail text not null
);
grant all on qa_results to public;

create or replace function pg_temp.qa_scalar(p_sql text) returns text
language plpgsql as $$
declare v text;
begin
  execute p_sql into v;
  return coalesce(v, '<NULL>');
exception when others then
  return '<ERROR:' || sqlstate || ':' || sqlerrm || '>';
end $$;

create or replace function pg_temp.qa_record(
  p_id text, p_expected text, p_observed text, p_classification text,
  p_state_before text, p_state_after text, p_detail text
) returns void language plpgsql as $$
declare v_result text;
begin
  v_result := case
    when p_expected = p_observed then 'PASS'
    when p_expected = 'STOP' and p_observed = 'INCONCLUSIVE' then 'STOP'
    when p_expected = 'REPORT' then 'REPORT'
    when p_observed = 'INCONCLUSIVE' and p_classification like 'EXPECTED GAP%' then 'STOP'
    else 'FAIL'
  end;
  insert into qa_results values (p_id,p_expected,p_observed,v_result,p_classification,p_state_before,p_state_after,p_detail);
end $$;

create or replace function pg_temp.qa_probe_dml(
  p_id text, p_expected text, p_classification text, p_detail text,
  p_sql text, p_state_sql text
) returns void language plpgsql as $$
declare
  v_ok boolean := false;
  v_rows integer := 0;
  v_observed text := 'INCONCLUSIVE';
  v_before text;
  v_after text;
  v_state text := '';
  v_message text := '';
begin
  v_before := pg_temp.qa_scalar(p_state_sql);
  begin
    execute p_sql;
    get diagnostics v_rows = row_count;
    v_ok := true;
    v_observed := case when v_rows > 0 then 'ALLOW' else 'DENY' end;
    v_after := pg_temp.qa_scalar(p_state_sql);
    raise exception using message = '__QA_ROLLBACK__';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    if v_message <> '__QA_ROLLBACK__' then
      v_observed := case
        when v_state in ('42501','42503') then 'DENY'
        when v_state = '23514' and v_message in (
          'turma/disciplina incompatíveis na atribuicao',
          'professor inativo ou inelegivel',
          'SC003_R18_ENROLLMENT_MISMATCH',
          'SC003_R31_DISCIPLINA_MISMATCH',
          'material professor exige disciplina exata',
          'turma fora do tenant do curso',
          'professor do registro fora do tenant',
          'disciplina fora do tenant do curso',
          'turma fora do tenant da unidade',
          'vinculo legado fora do tenant do professor/turma',
          'matricula fora do tenant do curso'
        ) then 'DENY'
        when v_state = '23505' and v_message = 'duplicate key value violates unique constraint "professores_turmas_usuario_id_turma_id_key"' then 'DENY'
        else 'INCONCLUSIVE'
      end;
    end if;
  end;
  v_after := pg_temp.qa_scalar(p_state_sql);
  if v_observed is null then v_observed := case when v_ok and v_rows > 0 then 'ALLOW' else 'INCONCLUSIVE' end; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' rows=' || v_rows || ' sqlstate=' || coalesce(v_state,'') || ' message=' || coalesce(v_message,''));
end $$;

create or replace function pg_temp.qa_probe_count(
  p_id text, p_expected text, p_classification text, p_detail text, p_sql text
) returns void language plpgsql as $$
declare v_count bigint; v_observed text; v_state text := ''; v_message text := '';
begin
  begin
    execute p_sql into v_count;
    v_observed := case when v_count > 0 then 'ALLOW' else 'DENY' end;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    v_count := -1;
    v_observed := case when v_state in ('42501','42503') then 'DENY' else 'INCONCLUSIVE' end;
  end;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,'','',p_detail || ' count=' || v_count || ' sqlstate=' || v_state || ' message=' || v_message);
end $$;

create or replace function pg_temp.qa_probe_rpc(
  p_id text, p_expected text, p_classification text, p_detail text, p_sql text
) returns void language plpgsql as $$
declare v_json jsonb; v_observed text := 'DENY'; v_state text := ''; v_message text := '';
begin
  begin
    execute p_sql into v_json;
    v_observed := 'ALLOW';
    raise exception using message = '__QA_ROLLBACK__';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    if v_message <> '__QA_ROLLBACK__' then
      v_observed := case
        when v_state in ('42501','42503','23505') then 'DENY'
        when v_message in ('Matrícula inválida para esta avaliação','Avaliação não encontrada','Avaliação ainda não está disponível','Limite de tentativas atingido','Esta etapa da coorte ainda não está disponível','A avaliação não possui questões ativas','Tentativa não encontrada','Tentativa já enviada','O prazo desta tentativa expirou','Questão inválida para esta tentativa') then 'DENY'
        else 'INCONCLUSIVE'
      end;
    end if;
  end;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,'','',p_detail || ' sqlstate=' || v_state || ' message=' || v_message);
end $$;

-- Blocking actor probes. These helpers capture state as the database owner,
-- execute the protected operation as an authenticated QA identity, and force
-- every successful mutation back through a subtransaction before comparing
-- owner-visible state before/after.
create or replace function pg_temp.qa_probe_actor_count(
  p_id text, p_expected text, p_classification text, p_detail text,
  p_actor_sub text, p_sql text, p_state_sql text
) returns void language plpgsql as $$
declare
  v_count bigint := 0;
  v_observed text := 'DENY';
  v_before text;
  v_after text;
  v_state text := '';
  v_message text := '';
begin
  reset role;
  execute p_state_sql into v_before;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',p_actor_sub,false);
    execute p_sql into v_count;
    v_observed := case when coalesce(v_count,0) > 0 then 'ALLOW' else 'DENY' end;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    v_observed := case
      when v_state in ('42501','42503') then 'DENY'
      else 'INCONCLUSIVE'
    end;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' count=' || coalesce(v_count::text,'') || ' sqlstate=' || v_state || ' message=' || v_message);
end $$;

create or replace function pg_temp.qa_probe_actor_count_strict(
  p_id text, p_expected text, p_classification text, p_detail text,
  p_actor_sub text, p_sql text, p_state_sql text
) returns void language plpgsql as $$
declare
  v_count bigint := 0;
  v_observed text := 'INCONCLUSIVE';
  v_before text;
  v_after text;
  v_state text := '';
  v_message text := '';
  v_target_exists boolean := false;
begin
  reset role;
  execute p_state_sql into v_before;
  v_target_exists := coalesce(v_before,'') not in ('','0','0.0','0.00','false','<NULL>');
  begin
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',p_actor_sub,false);
    execute p_sql into v_count;
    v_observed := case when coalesce(v_count,0) > 0 then 'ALLOW'
                       when v_target_exists then 'DENY'
                       else 'INCONCLUSIVE' end;
  exception when others then
    get stacked diagnostics v_state=returned_sqlstate,v_message=message_text;
    v_observed := case when v_state in ('42501','42503') and v_target_exists then 'DENY'
                       else 'INCONCLUSIVE' end;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail||' target_exists='||v_target_exists::text||' count='||coalesce(v_count::text,'')||' sqlstate='||v_state||' message='||v_message);
end $$;

create or replace function pg_temp.qa_probe_actor_dml(
  p_id text, p_expected text, p_classification text, p_detail text,
  p_actor_sub text, p_sql text, p_state_sql text
) returns void language plpgsql as $$
declare
  v_rows integer := 0;
  v_observed text := 'DENY';
  v_before text;
  v_after text;
  v_state text := '';
  v_message text := '';
begin
  reset role;
  execute p_state_sql into v_before;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',p_actor_sub,false);
    execute p_sql;
    get diagnostics v_rows = row_count;
    v_observed := case when v_rows > 0 then 'ALLOW' else 'DENY' end;
    raise exception using message = '__QA_ROLLBACK__';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    if v_message <> '__QA_ROLLBACK__' then
      v_observed := case
        when v_state in ('42501','42503') then 'DENY'
        when v_state = '23503' and v_message = 'update or delete on table "questoes" violates foreign key constraint "avaliacao_questoes_questao_id_fkey" on table "avaliacao_questoes"' then 'DENY'
        when v_state = '23514' and v_message = 'A autoria da avaliação não pode ser transferida por um docente' then 'DENY'
        when v_state = '23514' and v_message = 'Avaliação com evidência acadêmica não pode ter sua estrutura ou configuração alterada' then 'DENY'
        else 'INCONCLUSIVE'
      end;
    end if;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' rows=' || v_rows || ' sqlstate=' || v_state || ' message=' || v_message);
end $$;


-- Strict zero-row variant for security-critical R5.3 assertions. A silent
-- zero-row DML is not DENY unless the pre-state proves the target existed and
-- the assertion explicitly records target_exists=true.
create or replace function pg_temp.qa_probe_actor_dml_strict(
  p_id text, p_expected text, p_classification text, p_detail text,
  p_actor_sub text, p_sql text, p_state_sql text
) returns void language plpgsql as $$
declare
  v_rows integer := 0;
  v_observed text := 'INCONCLUSIVE';
  v_before text;
  v_after text;
  v_state text := '';
  v_message text := '';
  v_target_exists boolean := false;
begin
  reset role;
  execute p_state_sql into v_before;
  v_target_exists := coalesce(v_before,'') not in ('','0','false','<NULL>')
;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',p_actor_sub,false);
    execute p_sql;
    get diagnostics v_rows = row_count;
    v_observed := case
      when v_rows > 0 then 'ALLOW'
      when v_target_exists then 'DENY'
      else 'INCONCLUSIVE'
    end;
    raise exception using message='__QA_ROLLBACK__';
  exception when others then
    get stacked diagnostics v_state=returned_sqlstate,v_message=message_text;
    if v_message <> '__QA_ROLLBACK__' then
      v_observed := case
        when v_state in ('42501','42503') and v_target_exists then 'DENY'
        when v_state = '23503' and v_message = 'update or delete on table "questoes" violates foreign key constraint "avaliacao_questoes_questao_id_fkey" on table "avaliacao_questoes"' then 'DENY'
        when v_state = '23514' and v_message in ('A autoria da avaliação não pode ser transferida por um docente','Avaliação com evidência acadêmica não pode ter sua estrutura ou configuração alterada') then 'DENY'
        else 'INCONCLUSIVE'
      end;
    end if;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' rows=' || v_rows || ' sqlstate=' || v_state || ' message=' || v_message);
end $$;


-- Variant for RLS-specific assertions. The setup runs in the same
-- subtransaction as the protected DML and is rolled back with the probe.
create or replace function pg_temp.qa_probe_actor_dml_setup(
  p_id text, p_expected text, p_classification text, p_detail text,
  p_actor_sub text, p_setup_sql text, p_sql text, p_state_sql text
) returns void language plpgsql as $$
declare
  v_rows integer := 0;
  v_observed text := 'DENY';
  v_before text;
  v_after text;
  v_state text := '';
  v_message text := '';
  v_phase text := 'setup';
begin
  reset role;
  execute p_state_sql into v_before;
  begin
    if nullif(p_setup_sql,'') is not null then execute p_setup_sql; end if;
    v_phase := 'dml';
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',p_actor_sub,false);
    execute p_sql;
    get diagnostics v_rows = row_count;
    v_observed := case when v_rows > 0 then 'ALLOW' else 'DENY' end;
    raise exception using message = '__QA_ROLLBACK__';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    if v_message <> '__QA_ROLLBACK__' then
      v_observed := case
        when v_phase = 'setup' then 'SETUP_ERROR'
        when v_state in ('42501','42503') then 'DENY'
        when v_state = '23514' and v_message = 'Avaliação com evidência acadêmica não pode ter sua estrutura ou configuração alterada' then 'DENY'
        else 'INCONCLUSIVE'
      end;
    end if;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' rows=' || v_rows || ' sqlstate=' || v_state || ' message=' || v_message);
end $$;

create or replace function pg_temp.qa_probe_actor_rpc(
  p_id text, p_expected text, p_classification text, p_detail text,
  p_actor_sub text, p_setup_sql text, p_sql text, p_state_sql text
) returns void language plpgsql as $$
declare
  v_json jsonb;
  v_observed text := 'DENY';
  v_before text;
  v_after text;
  v_state text := '';
  v_message text := '';
begin
  reset role;
  execute p_state_sql into v_before;
  begin
    if nullif(p_setup_sql,'') is not null then execute p_setup_sql; end if;
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',p_actor_sub,false);
    execute p_sql into v_json;
    v_observed := 'ALLOW';
    raise exception using message = '__QA_ROLLBACK__';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    if v_message <> '__QA_ROLLBACK__' then
      v_observed := case
        when v_state in ('42501','42503') then 'DENY'
        when v_message in ('Resposta não encontrada','Tentativa não encontrada','Avaliação não encontrada','Professor sem assignment exato para corrigir resposta','Somente docentes podem corrigir respostas','Tentativa ainda não está enviada para correção','Tentativa mudou de estado durante a correção','Pontuação fora do limite da questão','Resposta já corrigida') then 'DENY'
        else 'INCONCLUSIVE'
      end;
    end if;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' sqlstate=' || v_state || ' message=' || v_message);
end $$;

create or replace function pg_temp.qa_probe_actor_rpc_strict(
  p_id text, p_expected text, p_classification text, p_detail text,
  p_actor_sub text, p_setup_sql text, p_sql text, p_state_sql text
) returns void language plpgsql as $$
declare
  v_json jsonb;
  v_observed text := 'INCONCLUSIVE';
  v_before text;
  v_after text;
  v_state text := '';
  v_message text := '';
  v_target_exists boolean := false;
begin
  reset role;
  if nullif(p_setup_sql,'') is not null then execute p_setup_sql; end if;
  execute p_state_sql into v_before;
  v_target_exists := coalesce(v_before,'') not in ('','0','0.0','0.00','false','<NULL>');
  begin
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',p_actor_sub,false);
    execute p_sql into v_json;
    v_observed := 'ALLOW';
    raise exception using message='__QA_ROLLBACK__';
  exception when others then
    get stacked diagnostics v_state=returned_sqlstate,v_message=message_text;
    if v_message <> '__QA_ROLLBACK__' then
      v_observed := case
        when v_state in ('42501','42503') and v_target_exists then 'DENY'
        when v_message in ('Resposta não encontrada','Tentativa não encontrada','Avaliação não encontrada','Professor sem assignment exato para corrigir resposta','Somente docentes podem corrigir respostas','Tentativa ainda não está enviada para correção','Tentativa mudou de estado durante a correção','Pontuação fora do limite da questão','Resposta já corrigida') and v_target_exists then 'DENY'
        else 'INCONCLUSIVE' end;
    end if;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail||' target_exists='||v_target_exists::text||' sqlstate='||v_state||' message='||v_message);
end $$;


create or replace function pg_temp.qa_probe_actor_rpc_no_gabarito(
  p_id text, p_expected text, p_classification text, p_detail text,
  p_actor_sub text, p_sql text, p_state_sql text
) returns void language plpgsql as $$
declare
  v_json jsonb;
  v_observed text := 'DENY';
  v_before text;
  v_after text;
  v_state text := '';
  v_message text := '';
begin
  reset role;
  execute p_state_sql into v_before;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',p_actor_sub,false);
    execute p_sql into v_json;
    v_observed := case when v_json ? 'gabarito_snapshot' then 'GABARITO_LEAK' else 'ALLOW_NO_GABARITO' end;
    raise exception using message = '__QA_ROLLBACK__';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    if v_message <> '__QA_ROLLBACK__' then
      v_observed := case
        when v_state in ('42501','42503') then 'DENY'
        when v_message in ('Tentativa não encontrada','Tentativa já enviada','O prazo desta tentativa expirou','Questão inválida para esta tentativa') then 'DENY'
        else 'INCONCLUSIVE'
      end;
    end if;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' sqlstate=' || v_state || ' message=' || v_message);
end $$;


-- Runtime ACL probe: owner-visible state is captured outside the role, while
-- TRUNCATE is attempted as the exact application role. Unexpected errors are
-- INCONCLUSIVE; only a successful truncate is ALLOW.
create or replace function pg_temp.qa_probe_actor_truncate(
  p_id text, p_expected text, p_classification text, p_detail text,
  p_actor_role text, p_table text, p_state_sql text
) returns void language plpgsql as $$
declare
  v_before text;
  v_after text;
  v_observed text := 'INCONCLUSIVE';
  v_state text := '';
  v_message text := '';
begin
  reset role;
  execute p_state_sql into v_before;
  begin
    execute format('set local role %I', p_actor_role);
    execute format('truncate table public.%I', p_table);
    v_observed := 'ALLOW';
    raise exception using message = '__QA_ROLLBACK__';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    if v_message <> '__QA_ROLLBACK__' then
      v_observed := case when v_state in ('42501','42503') then 'DENY' else 'INCONCLUSIVE' end;
    end if;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(
    p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' sqlstate=' || coalesce(v_state,'') || ' message=' || coalesce(v_message,'')
  );
end $$;

-- Deterministic artificial identities and School A/B fixture. All IDs are QA-only.
reset role;
insert into auth.users(id,email,email_confirmed_at) values
 ('a3000000-0000-0000-0000-000000000001','manager-a@sc004.invalid',now()),
 ('a3000000-0000-0000-0000-000000000002','teacher-a@sc004.invalid',now()),
 ('a3000000-0000-0000-0000-000000000003','teacher-a2@sc004.invalid',now()),
 ('b3000000-0000-0000-0000-000000000001','teacher-b@sc004.invalid',now()),
 ('a3000000-0000-0000-0000-000000000010','student-7a@sc004.invalid',now()),
 ('a3000000-0000-0000-0000-000000000011','student-7b@sc004.invalid',now()),
 ('a3000000-0000-0000-0000-000000000012','student-8a@sc004.invalid',now()),
 ('a3000000-0000-0000-0000-000000000013','student-a2@sc004.invalid',now()),
 ('a3000000-0000-0000-0000-000000000014','student-8a2@sc004.invalid',now()),
 ('b3000000-0000-0000-0000-000000000010','student-b@sc004.invalid',now()),
 ('a3000000-0000-0000-0000-000000000004','teacher-a3@sc004.invalid',now()),
 ('a3000000-0000-0000-0000-000000000005','teacher-exact-8a-math@sc004.invalid',now()),
 ('b3000000-0000-0000-0000-000000000002','manager-b@sc004.invalid',now());

insert into public.tenants(id,nome,slug,ativo) values
 ('a1000000-0000-0000-0000-000000000001','QA SC004 — School A','qa-sc004-school-a',true),
 ('b1000000-0000-0000-0000-000000000001','QA SC004 — School B','qa-sc004-school-b',true);
insert into public.unidades(id,tenant_id,nome,ativo) values
 ('a2000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','QA Unit A',true),
 ('a2000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','QA Unit A2',true),
 ('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','QA Unit B',true);
insert into public.usuarios(id,auth_user_id,tenant_id,unidade_id,perfil,nome,email,ativo) values
 ('a4000000-0000-0000-0000-000000000001','a3000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','gestor','QA Manager A','manager-a@sc004.invalid',true),
 ('a4000000-0000-0000-0000-000000000002','a3000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','professor','QA Teacher A','teacher-a@sc004.invalid',true),
 ('a4000000-0000-0000-0000-000000000003','a3000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000002','professor','QA Teacher A2 inactive','teacher-a2@sc004.invalid',false),
 ('b4000000-0000-0000-0000-000000000001','b3000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b2000000-0000-0000-0000-000000000001','professor','QA Teacher B','teacher-b@sc004.invalid',true),
 ('a4000000-0000-0000-0000-000000000010','a3000000-0000-0000-0000-000000000010','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','aluno','QA Student 7A','student-7a@sc004.invalid',true),
 ('a4000000-0000-0000-0000-000000000011','a3000000-0000-0000-0000-000000000011','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','aluno','QA Student 7B','student-7b@sc004.invalid',true),
 ('a4000000-0000-0000-0000-000000000012','a3000000-0000-0000-0000-000000000012','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','aluno','QA Student 8A','student-8a@sc004.invalid',true),
 ('a4000000-0000-0000-0000-000000000013','a3000000-0000-0000-0000-000000000013','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000002','aluno','QA Student A2','student-a2@sc004.invalid',true),
 ('a4000000-0000-0000-0000-000000000014','a3000000-0000-0000-0000-000000000014','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','aluno','QA Student 8A2','student-8a2@sc004.invalid',true),
 ('b4000000-0000-0000-0000-000000000010','b3000000-0000-0000-0000-000000000010','b1000000-0000-0000-0000-000000000001','b2000000-0000-0000-0000-000000000001','aluno','QA Student B','student-b@sc004.invalid',true),
 ('a4000000-0000-0000-0000-000000000004','a3000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','professor','QA Teacher A3 No Assignment','teacher-a3@sc004.invalid',true),
 ('a4000000-0000-0000-0000-000000000005','a3000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','professor','QA Teacher Exact 8A Math','teacher-exact-8a-math@sc004.invalid',true),
 ('b4000000-0000-0000-0000-000000000002','b3000000-0000-0000-0000-000000000002','b1000000-0000-0000-0000-000000000001','b2000000-0000-0000-0000-000000000001','gestor','QA Manager B','manager-b@sc004.invalid',true);

insert into public.cursos(id,tenant_id,nome,ativo) values
 ('a5000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','QA Middle School A',true),
 ('b5000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','QA Middle School B',true);
insert into public.disciplinas(id,curso_id,tenant_id,nome,ordem) values
 ('a6000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','QA Math',1),
 ('a6000000-0000-0000-0000-000000000002','a5000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','QA Physics',2),
 ('a6000000-0000-0000-0000-000000000003','a5000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','QA Chemistry',3),
 ('b6000000-0000-0000-0000-000000000001','b5000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','QA Math B',1),
 ('b6000000-0000-0000-0000-000000000002','b5000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','QA Physics B',2);
insert into public.turmas(id,tenant_id,curso_id,unidade_id,nome,ativa) values
 ('a7000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','QA Class 7A',true),
 ('a7000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','QA Class 7B',true),
 ('a7000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','QA Class 8A',true),
 ('a7000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000002','QA Class A2',true),
 ('a7000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000002','QA Class 8B',true),
 ('b7000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b5000000-0000-0000-0000-000000000001','b2000000-0000-0000-0000-000000000001','QA Class B',true);
insert into public.matriculas(id,tenant_id,usuario_id,curso_id,turma_id,unidade_id,situacao) values
 ('a8000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000010','a5000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','ativa'),
 ('a8000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000011','a5000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000002','a2000000-0000-0000-0000-000000000001','ativa'),
 ('a8000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000012','a5000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','a2000000-0000-0000-0000-000000000001','ativa'),
 ('a8000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000013','a5000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000004','a2000000-0000-0000-0000-000000000002','ativa'),
 ('a8000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000014','a5000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','a2000000-0000-0000-0000-000000000001','ativa'),
 ('b8000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b4000000-0000-0000-0000-000000000010','b5000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-000000000001','b2000000-0000-0000-0000-000000000001','ativa');

-- Legacy links are intentionally class-only. Rows 6-7 are invalid contamination for integrity probes.
insert into public.professores_turmas(id,tenant_id,usuario_id,turma_id) values
 ('a9000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002','a7000000-0000-0000-0000-000000000001'),
 ('a9000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002','a7000000-0000-0000-0000-000000000002'),
 ('a9000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002','a7000000-0000-0000-0000-000000000003'),
 ('a9000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000003','a7000000-0000-0000-0000-000000000004'),
 ('b9000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b4000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-000000000001');

-- Canonical grants: independent Class + Subject authority. Legacy rows above
-- remain deliberately ambiguous and are never converted into these grants.
insert into public.atribuicoes_academicas_professor(id,tenant_id,professor_id,turma_id,disciplina_id) values
 ('aa100000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002','a7000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001'),
 ('aa100000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002','a7000000-0000-0000-0000-000000000002','a6000000-0000-0000-0000-000000000001'),
 ('aa100000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002','a7000000-0000-0000-0000-000000000003','a6000000-0000-0000-0000-000000000001'),
 ('aa100000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002','a7000000-0000-0000-0000-000000000003','a6000000-0000-0000-0000-000000000002'),
 ('aa100000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000005','a7000000-0000-0000-0000-000000000003','a6000000-0000-0000-0000-000000000001'),
 ('bb100000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b4000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000001');

insert into public.questoes(id,tenant_id,disciplina_id,enunciado,alternativas,resposta_correta,criado_por) values
 ('aa000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','QA Math question','[{"id":"a","texto":"A"}]','a','a4000000-0000-0000-0000-000000000002'),
 ('aa000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000002','QA Physics question','[{"id":"a","texto":"A"}]','a','a4000000-0000-0000-0000-000000000002'),
 ('aa000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000003','QA Chemistry question','[{"id":"a","texto":"A"}]','a','a4000000-0000-0000-0000-000000000002'),
 ('aa000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000002','QA 7B Physics question','[{"id":"a","texto":"A"}]','a','a4000000-0000-0000-0000-000000000002'),
 ('bb000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000001','QA B Math question','[{"id":"a","texto":"A"}]','a','b4000000-0000-0000-0000-000000000001'),
 ('bb000000-0000-0000-0000-000000000002','b1000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000001','QA extra B Math question','[{"id":"a","texto":"A"}]','a','b4000000-0000-0000-0000-000000000001');
insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values
 ('ac000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','QA 8A Math','publicada','a4000000-0000-0000-0000-000000000002'),
 ('ac000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000002','a7000000-0000-0000-0000-000000000003','QA 8A Physics','publicada','a4000000-0000-0000-0000-000000000002'),
 ('ac000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000003','a7000000-0000-0000-0000-000000000003','QA 8A Chemistry','publicada','a4000000-0000-0000-0000-000000000002'),
 ('ac000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000002','a7000000-0000-0000-0000-000000000001','QA 7A Physics','publicada','a4000000-0000-0000-0000-000000000002'),
 ('bc000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b5000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-000000000001','QA B Math','publicada','b4000000-0000-0000-0000-000000000001'),
 ('bc000000-0000-0000-0000-000000000002','b1000000-0000-0000-0000-000000000001','b5000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-000000000001','QA B Math Extra','rascunho','b4000000-0000-0000-0000-000000000001');
insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem) values
 ('ac000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-000000000001',1),
 ('ac000000-0000-0000-0000-000000000002','aa000000-0000-0000-0000-000000000002',1),
 ('ac000000-0000-0000-0000-000000000003','aa000000-0000-0000-0000-000000000003',1),
 ('ac000000-0000-0000-0000-000000000004','aa000000-0000-0000-0000-000000000004',1),
 ('bc000000-0000-0000-0000-000000000001','bb000000-0000-0000-0000-000000000001',1);
insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem) values
 ('bc000000-0000-0000-0000-000000000002','bb000000-0000-0000-0000-000000000002',1);
insert into public.avaliacao_tentativas(id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,questoes_ordem,gabarito_snapshot) values
 ('ad000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-000000000001','a8000000-0000-0000-0000-000000000003','a4000000-0000-0000-0000-000000000012',1,'[{"questao_id":"aa000000-0000-0000-0000-000000000001","pontos":1}]','{"aa000000-0000-0000-0000-000000000001":"a"}'),
 ('ad000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-000000000002','a8000000-0000-0000-0000-000000000003','a4000000-0000-0000-0000-000000000012',1,'[{"questao_id":"aa000000-0000-0000-0000-000000000002","pontos":1}]','{"aa000000-0000-0000-0000-000000000002":"a"}'),
 ('ad000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-000000000004','a8000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000010',1,'[{"questao_id":"aa000000-0000-0000-0000-000000000004","pontos":1}]','{"aa000000-0000-0000-0000-000000000004":"a"}'),
 ('bd000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','bc000000-0000-0000-0000-000000000001','b8000000-0000-0000-0000-000000000001','b4000000-0000-0000-0000-000000000010',77,'[{"questao_id":"bb000000-0000-0000-0000-000000000001","pontos":1}]','{"bb000000-0000-0000-0000-000000000001":"a"}'),
 ('bd000000-0000-0000-0000-000000000002','b1000000-0000-0000-0000-000000000001','bc000000-0000-0000-0000-000000000002','b8000000-0000-0000-0000-000000000001','b4000000-0000-0000-0000-000000000010',78,'[{"questao_id":"bb000000-0000-0000-0000-000000000002","pontos":1}]','{"bb000000-0000-0000-0000-000000000002":"a"}');
insert into public.avaliacao_respostas(id,tenant_id,tentativa_id,questao_id) values
 ('ae000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','ad000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-000000000001'),
 ('ae000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','ad000000-0000-0000-0000-000000000002','aa000000-0000-0000-0000-000000000002'),
 ('ae000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','ad000000-0000-0000-0000-000000000003','aa000000-0000-0000-0000-000000000004'),
 ('be000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','bd000000-0000-0000-0000-000000000001','bb000000-0000-0000-0000-000000000001');
insert into public.avaliacao_tentativas(id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,situacao,enviada_em,nota,nota_maxima,percentual,aprovada,questoes_ordem,gabarito_snapshot) values
 ('ad000000-0000-0000-0000-000000000006','a1000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-000000000001','a8000000-0000-0000-0000-000000000003','a4000000-0000-0000-0000-000000000012',2,'corrigida',now(),1,1,100,true,'[{"questao_id":"aa000000-0000-0000-0000-000000000001","pontos":1}]','{"aa000000-0000-0000-0000-000000000001":"a"}');
insert into public.avaliacao_respostas(id,tenant_id,tentativa_id,questao_id,alternativa_id,pontos_obtidos,corrigida,comentario) values
 ('ae000000-0000-0000-0000-000000000006','a1000000-0000-0000-0000-000000000001','ad000000-0000-0000-0000-000000000006','aa000000-0000-0000-0000-000000000001','a',1,true,'QA R5.1 already corrected');
-- R5.1 lifecycle fixtures: Teacher A has one in-progress attempt and two
-- unused assessments for explicit DELETE allow/deny probes.
insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values
 ('ac000000-0000-0000-0000-000000000009','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','QA R5.1 Teacher A in-progress assessment','rascunho','a4000000-0000-0000-0000-000000000002'),
 ('ac000000-0000-0000-0000-000000000011','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','QA R5.1 Teacher A unused assessment','rascunho','a4000000-0000-0000-0000-000000000002'),
 ('ac000000-0000-0000-0000-000000000012','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000002','a7000000-0000-0000-0000-000000000003','QA R5.1 Teacher A unused Physics assessment','rascunho','a4000000-0000-0000-0000-000000000002');
insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem) values
 ('ac000000-0000-0000-0000-000000000009','aa000000-0000-0000-0000-000000000001',1);
insert into public.avaliacao_tentativas(id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,situacao,questoes_ordem,gabarito_snapshot) values
 ('ad000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-000000000009','a8000000-0000-0000-0000-000000000003','a4000000-0000-0000-0000-000000000012',1,'em_andamento','[{"questao_id":"aa000000-0000-0000-0000-000000000001","pontos":1}]','{"aa000000-0000-0000-0000-000000000001":"a"}');

-- R4 H1 fixtures: Teacher Y owns one 7A+Math assessment-bound question.
-- The extra unlinked question is a staff-only positive-control target.
reset role;
insert into auth.users(id,email,email_confirmed_at) values
 ('a3000000-0000-0000-0000-000000000006','teacher-y@sc004.invalid',now());
insert into public.usuarios(id,auth_user_id,tenant_id,unidade_id,perfil,nome,email,ativo) values
 ('a4000000-0000-0000-0000-000000000006','a3000000-0000-0000-0000-000000000006','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','professor','QA Teacher Y 7A Math','teacher-y@sc004.invalid',true);
insert into public.atribuicoes_academicas_professor(id,tenant_id,professor_id,turma_id,disciplina_id) values
 ('aa100000-0000-0000-0000-000000000006','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000006','a7000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001');
insert into public.questoes(id,tenant_id,disciplina_id,enunciado,alternativas,resposta_correta,criado_por) values
 ('aa000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','QA H1 Teacher Y 7A Math question','[{"id":"a","texto":"A"},{"id":"b","texto":"B"}]','a','a4000000-0000-0000-0000-000000000006'),
 ('aa000000-0000-0000-0000-000000000006','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','QA staff unlinked question','[{"id":"a","texto":"A"}]','a','a4000000-0000-0000-0000-000000000001');
insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values
 ('ac000000-0000-0000-0000-000000000008','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','QA H1 Teacher Y 7A Math assessment','rascunho','a4000000-0000-0000-0000-000000000006');
insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem) values
 ('ac000000-0000-0000-0000-000000000008','aa000000-0000-0000-0000-000000000005',1);
insert into public.avaliacao_tentativas(id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,questoes_ordem,gabarito_snapshot) values
 ('ad000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-000000000008','a8000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000010',1,'[{"questao_id":"aa000000-0000-0000-0000-000000000005","pontos":1}]','{"aa000000-0000-0000-0000-000000000005":"a"}');
update public.avaliacao_tentativas
set situacao='enviada', enviada_em=now()
where id in ('ad000000-0000-0000-0000-000000000002','ad000000-0000-0000-0000-000000000004');
insert into public.avaliacao_respostas(id,tenant_id,tentativa_id,questao_id) values
 ('ae000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','ad000000-0000-0000-0000-000000000004','aa000000-0000-0000-0000-000000000005');


-- R5.2 dedicated submitted dissertative fixture. Every B2 authorization
-- probe below uses this valid `enviada` response, so lifecycle cannot provide
-- the denial. The unlinked question is the X11 owner-delete control.
reset role;
insert into public.questoes(id,tenant_id,disciplina_id,enunciado,tipo,resposta_correta,resposta_esperada,criado_por) values
 ('aa000000-0000-0000-0000-000000000007','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','QA R5.2 submitted dissertative question','dissertativa',null,'QA expected answer','a4000000-0000-0000-0000-000000000002'),
 ('aa000000-0000-0000-0000-000000000008','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','QA R5.2 unlinked owner-delete question','objetiva','a',null,'a4000000-0000-0000-0000-000000000002'),
 ('bb000000-0000-0000-0000-000000000003','b1000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000001','QA R5.2 unlinked Tenant B mutation target','objetiva','a',null,'b4000000-0000-0000-0000-000000000001');
insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values
 ('ac000000-0000-0000-0000-000000000020','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','QA R5.2 submitted dissertative assessment','publicada','a4000000-0000-0000-0000-000000000002');
insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values
 ('ac000000-0000-0000-0000-000000000021','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','QA R5.2 unused assessment','rascunho','a4000000-0000-0000-0000-000000000002');
insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem,tenant_id) values
 ('ac000000-0000-0000-0000-000000000020','aa000000-0000-0000-0000-000000000007',1,'a1000000-0000-0000-0000-000000000001');
insert into public.avaliacao_tentativas(id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,situacao,enviada_em,questoes_ordem,gabarito_snapshot) values
 ('ad000000-0000-0000-0000-000000000020','a1000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-000000000020','a8000000-0000-0000-0000-000000000003','a4000000-0000-0000-0000-000000000012',1,'enviada',now(),'[{"questao_id":"aa000000-0000-0000-0000-000000000007","pontos":1}]','{}');
insert into public.avaliacao_respostas(id,tenant_id,tentativa_id,questao_id,resposta_texto) values
 ('ae000000-0000-0000-0000-000000000020','a1000000-0000-0000-0000-000000000001','ad000000-0000-0000-0000-000000000020','aa000000-0000-0000-0000-000000000007','QA submitted answer');

insert into public.materiais_professor(id,tenant_id,turma_id,disciplina_id,professor_id,titulo,url) values
 ('af000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','a6000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002','QA material Math','https://qa.invalid/math'),
 ('af000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','a6000000-0000-0000-0000-000000000002','a4000000-0000-0000-0000-000000000002','QA material Physics','https://qa.invalid/physics'),
 ('af000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','a6000000-0000-0000-0000-000000000003','a4000000-0000-0000-0000-000000000002','QA material Chemistry','https://qa.invalid/chemistry'),
 ('af000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','a6000000-0000-0000-0000-000000000002','a4000000-0000-0000-0000-000000000003','QA other owner material','https://qa.invalid/other');
insert into public.avisos_turma(id,tenant_id,turma_id,professor_id,tipo,titulo) values
 ('b0000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','a4000000-0000-0000-0000-000000000002','prova','QA 8A notice'),
 ('b0000000-0000-0000-0000-000000000002','b1000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-000000000001','b4000000-0000-0000-0000-000000000001','prova','QA B notice');
insert into public.registros_aula(id,tenant_id,turma_id,disciplina_id,professor_id,data_aula) values
 ('b1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','a6000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002',current_date),
 ('b1000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','a6000000-0000-0000-0000-000000000002','a4000000-0000-0000-0000-000000000002',current_date),
 ('b1000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','a6000000-0000-0000-0000-000000000003','a4000000-0000-0000-0000-000000000002',current_date),
 ('c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000001','b4000000-0000-0000-0000-000000000001',current_date);
insert into public.presencas(id,tenant_id,registro_aula_id,usuario_id,situacao) values
 ('b2000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000012','presente'),
 ('b2000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000002','a4000000-0000-0000-0000-000000000012','presente');

-- ST-01 and ST-02: current principal and unit behavior.
set role authenticated;
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000001',false);
select pg_temp.qa_record('ST-01','ALLOW',case when public.current_usuario_id()='a4000000-0000-0000-0000-000000000001'::uuid and public.current_tenant_id()='a1000000-0000-0000-0000-000000000001'::uuid and public.current_perfil()='gestor' and public.is_staff() then 'ALLOW' else 'DENY' end,'CURRENT REPOSITORY CONTRACT','','','Active principal resolves; tenant activity is not part of the helper predicate');
reset role;
select pg_temp.qa_probe_dml('ST-02','DENY','CURRENT REPOSITORY CONTRACT','Cross-tenant unidade_id is accepted by the physical model; probe is rolled back','update public.usuarios set unidade_id=''b2000000-0000-0000-0000-000000000001'' where id=''a4000000-0000-0000-0000-000000000010''','select count(*)::text from public.usuarios where id=''a4000000-0000-0000-0000-000000000010'' and unidade_id=''a2000000-0000-0000-0000-000000000001''');

-- ST-03–ST-10: parent integrity and the absent canonical assignment relation.
select pg_temp.qa_probe_dml('ST-03','DENY','CURRENT REPOSITORY CONTRACT','Subject tenant/course mismatch accepted; rolled back','insert into public.disciplinas(id,curso_id,tenant_id,nome) values (''a6100000-0000-0000-0000-000000000001'',''b5000000-0000-0000-0000-000000000001'',''a1000000-0000-0000-0000-000000000001'',''QA invalid subject'')','select count(*)::text from public.disciplinas where id=''a6100000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_dml('ST-04','DENY','CURRENT REPOSITORY CONTRACT','Class tenant/course mismatch accepted; rolled back','insert into public.turmas(id,tenant_id,curso_id,nome) values (''a7100000-0000-0000-0000-000000000001'',''a1000000-0000-0000-0000-000000000001'',''b5000000-0000-0000-0000-000000000001'',''QA invalid class'')','select count(*)::text from public.turmas where id=''a7100000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_dml('ST-05','DENY','CURRENT REPOSITORY CONTRACT','Class/unit tenant mismatch and NULL unit are not constrained; rolled back','insert into public.turmas(id,tenant_id,curso_id,unidade_id,nome) values (''a7100000-0000-0000-0000-000000000002'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''b2000000-0000-0000-0000-000000000001'',''QA invalid unit class'')','select count(*)::text from public.turmas where id=''a7100000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_dml('ST-06','DENY','CURRENT REPOSITORY CONTRACT','Legacy link tenant/user/class equality is not constrained; rolled back','insert into public.professores_turmas(id,tenant_id,usuario_id,turma_id) values (''a9100000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-000000000001'',''a4000000-0000-0000-0000-000000000003'',''b7000000-0000-0000-0000-000000000001'')','select count(*)::text from public.professores_turmas where id=''a9100000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_count('ST-07','ALLOW','CURRENT REPOSITORY CONTRACT','Legacy class-only row remains stored as compatibility data but is not used as Subject authority','select count(*) from public.professores_turmas where id=''a9000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_count('ST-08','ALLOW','CURRENT REPOSITORY CONTRACT','Canonical Teacher+Class+Subject assignment table exists and is populated','select count(*) from public.atribuicoes_academicas_professor where tenant_id=public.current_tenant_id() and ativo');
select pg_temp.qa_probe_dml('ST-09','DENY','LEGACY_COMPATIBILITY_ONLY','Legacy unique is Teacher+Class only and cannot represent independent Math/Physics grants','insert into public.professores_turmas(id,tenant_id,usuario_id,turma_id) values (''a9100000-0000-0000-0000-000000000003'',''a1000000-0000-0000-0000-000000000001'',''a4000000-0000-0000-0000-000000000002'',''a7000000-0000-0000-0000-000000000003'')','select count(*)::text from public.professores_turmas where usuario_id=''a4000000-0000-0000-0000-000000000002'' and turma_id=''a7000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_dml('ST-10','DENY','CURRENT REPOSITORY CONTRACT','Enrollment tenant/course/class/unit parent equality is not enforced; rolled back','insert into public.matriculas(id,tenant_id,usuario_id,curso_id,turma_id,unidade_id) values (''a8100000-0000-0000-0000-000000000001'',''a1000000-0000-0000-0000-000000000001'',''a4000000-0000-0000-0000-000000000010'',''b5000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000001'',''b2000000-0000-0000-0000-000000000001'')','select count(*)::text from public.matriculas where id=''a8100000-0000-0000-0000-000000000001''');

-- ST-11–ST-21: resource and assignment invariants. These are runtime probes of current policies.
set role authenticated;
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
select pg_temp.qa_probe_count('ST-11','DENY','CURRENT REPOSITORY CONTRACT','Teacher A cannot see Chemistry attendance without exact assignment','select count(*) from public.registros_aula where id=''b1000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_count('ST-12','ALLOW','CURRENT REPOSITORY CONTRACT','Teacher A sees valid attendance for enrolled 8A student through Math assignment','select count(*) from public.presencas where registro_aula_id=''b1000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_count('ST-13','DENY','CURRENT REPOSITORY CONTRACT','Teacher A cannot read Chemistry material through Math/Physics assignments','select count(*) from public.materiais_professor where id=''af000000-0000-0000-0000-000000000005''');
select pg_temp.qa_probe_count('ST-14','DENY','CURRENT REPOSITORY CONTRACT','Class-only announcement policy has no Subject/assignment scope','select count(*) from public.avisos_turma where id=''b0000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_count('ST-15','DENY','CURRENT REPOSITORY CONTRACT','Teacher A reads same-tenant Chemistry assessment without exact Subject grant','select count(*) from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_count('ST-16','DENY','CURRENT REPOSITORY CONTRACT','Question/evaluation policies are tenant-wide for is_docente','select count(*) from public.questoes where id=''aa000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_count('ST-17','ALLOW','CURRENT REPOSITORY CONTRACT','Teacher A can read a valid Math assessment-question link through the Math assignment','select count(*) from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_count('ST-18','DENY','CURRENT REPOSITORY CONTRACT','Teacher A cannot read attempts for an unassigned Chemistry assessment','select count(*) from public.avaliacao_tentativas where avaliacao_id=''ac000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_count('ST-19','DENY','CURRENT REPOSITORY CONTRACT','Response policy is tenant-wide for docente and does not revalidate assignment','select count(*) from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_count('ST-20','DENY','CURRENT REPOSITORY CONTRACT','Forged assignment identifier cannot produce a roster','select count(*) from public.teacher_assignment_roster(''b9000000-0000-0000-0000-000000000099''::uuid)');
select pg_temp.qa_probe_count('ST-21','ALLOW','CURRENT REPOSITORY CONTRACT','Active canonical assignment lifecycle is visible before the isolated revocation probe','select count(*) from public.atribuicoes_academicas_professor where id=''aa100000-0000-0000-0000-000000000004'' and ativo');

-- A01–A03 session/ACL runtime.
select pg_temp.qa_record('A01','ALLOW',case when public.current_usuario_id()='a4000000-0000-0000-0000-000000000002'::uuid and public.current_tenant_id()='a1000000-0000-0000-0000-000000000001'::uuid and public.current_perfil()='professor' and public.is_docente() then 'ALLOW' else 'DENY' end,'CURRENT REPOSITORY CONTRACT','','','Teacher A active helper resolution; tenant active is not checked by helper');
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000003',false);
select pg_temp.qa_probe_count('A02','DENY','CURRENT REPOSITORY CONTRACT','Inactive Teacher A2 has no active helper identity; direct class-only link remains a legacy row','select count(*) from public.registros_aula where id=''b1000000-0000-0000-0000-000000000001''');
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
select pg_temp.qa_record('A03','DENY',case when has_function_privilege('anon','public.minhas_turmas_professor()','EXECUTE') then 'ALLOW' else 'DENY' end,'CURRENT REPOSITORY CONTRACT','','','Function retains PUBLIC EXECUTE because migration grants authenticated but does not revoke the default PUBLIC EXECUTE');

-- A04–A10: canonical assignment creation, integrity, uniqueness and discovery.
select pg_temp.qa_probe_count('A04','ALLOW','CURRENT REPOSITORY CONTRACT','Canonical assignment table contains all four independent grants for Teacher A','select count(*) from public.atribuicoes_academicas_professor where professor_id=''a4000000-0000-0000-0000-000000000002'' and ativo');
select pg_temp.qa_probe_dml('A05','DENY','CURRENT REPOSITORY CONTRACT','Cross-tenant assignment insert is rejected','insert into public.atribuicoes_academicas_professor(id,tenant_id,professor_id,turma_id,disciplina_id) values (''aa100000-0000-0000-0000-000000000099'',''a1000000-0000-0000-0000-000000000001'',''a4000000-0000-0000-0000-000000000002'',''b7000000-0000-0000-0000-000000000001'',''b6000000-0000-0000-0000-000000000001'')','select count(*)::text from public.atribuicoes_academicas_professor where id=''aa100000-0000-0000-0000-000000000099''');
select pg_temp.qa_probe_dml('A06','DENY','CURRENT REPOSITORY CONTRACT','Inactive teacher cannot receive a canonical assignment','insert into public.atribuicoes_academicas_professor(id,tenant_id,professor_id,turma_id,disciplina_id) values (''aa100000-0000-0000-0000-000000000098'',''a1000000-0000-0000-0000-000000000001'',''a4000000-0000-0000-0000-000000000003'',''a7000000-0000-0000-0000-000000000003'',''a6000000-0000-0000-0000-000000000001'')','select count(*)::text from public.atribuicoes_academicas_professor where id=''aa100000-0000-0000-0000-000000000098''');
select pg_temp.qa_probe_dml('A07','DENY','CURRENT REPOSITORY CONTRACT','Cross-course Subject is rejected for a Class','insert into public.atribuicoes_academicas_professor(id,tenant_id,professor_id,turma_id,disciplina_id) values (''aa100000-0000-0000-0000-000000000097'',''a1000000-0000-0000-0000-000000000001'',''a4000000-0000-0000-0000-000000000002'',''a7000000-0000-0000-0000-000000000003'',''b6000000-0000-0000-0000-000000000001'')','select count(*)::text from public.atribuicoes_academicas_professor where id=''aa100000-0000-0000-0000-000000000097''');
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000001',false);
select pg_temp.qa_probe_rpc('A08','DENY','CURRENT REPOSITORY CONTRACT','Duplicate active assignment is rejected by the unique key','select to_jsonb(public.create_teacher_assignment(''a4000000-0000-0000-0000-000000000002''::uuid,''a7000000-0000-0000-0000-000000000003''::uuid,''a6000000-0000-0000-0000-000000000001''::uuid))');
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
select pg_temp.qa_probe_count('A09','ALLOW','CURRENT REPOSITORY CONTRACT','The same Class supports independent active Math and Physics assignments','select count(*) from public.atribuicoes_academicas_professor where turma_id=''a7000000-0000-0000-0000-000000000003'' and ativo');
select pg_temp.qa_record('A10','ALLOW',case when (select count(*) from public.my_teacher_assignments()) = 4 then 'ALLOW' else 'DENY' end,'CURRENT REPOSITORY CONTRACT','','','Canonical discovery returns exactly Teacher A assignments: 7A Math, 7B Math, 8A Math, 8A Physics');

-- A11–A18: current broad class/tenant behavior.
select pg_temp.qa_probe_count('A11','DENY','CURRENT REPOSITORY CONTRACT','Teacher A cannot read 8A Chemistry attendance without an exact Chemistry assignment','select count(*) from public.registros_aula where id=''b1000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_count('A12','ALLOW','CURRENT REPOSITORY CONTRACT','Teacher A reads 8A+Math through legacy class link','select count(*) from public.registros_aula where id=''b1000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_count('A13','ALLOW','CURRENT REPOSITORY CONTRACT','Teacher A reads 8A+Physics through same legacy class link','select count(*) from public.registros_aula where id=''b1000000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_count('A14','DENY','CURRENT REPOSITORY CONTRACT','Teacher A can read Chemistry assessment in same class despite no assignment','select count(*) from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_count('A15','DENY','CURRENT REPOSITORY CONTRACT','Teacher A can read 7A+Physics through class link; no Subject boundary','select count(*) from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000004''');
select pg_temp.qa_probe_count('A16','DENY','CURRENT REPOSITORY CONTRACT','Cross-tenant valid B record remains hidden by tenant predicate','select count(*) from public.registros_aula where id=''c1000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_count('A17','DENY','CURRENT REPOSITORY CONTRACT','Forged assignment_id has no canonical endpoint; legacy direct class link remains the active authority','select count(*) from public.professores_turmas where id=''b9000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_count('A18','DENY','CURRENT REPOSITORY CONTRACT','Teacher A cannot access a same-class Chemistry material without the exact Subject assignment','select count(*) from public.materiais_professor where id=''af000000-0000-0000-0000-000000000005''');

-- A19–A25 attendance and eligibility.
select pg_temp.qa_probe_count('A19','ALLOW','CURRENT REPOSITORY CONTRACT','Roster for the exact 8A Math assignment returns only active 8A students','select count(*) from public.teacher_assignment_roster(''aa100000-0000-0000-0000-000000000003''::uuid)');
select pg_temp.qa_probe_count('A20','DENY','CURRENT REPOSITORY CONTRACT','Forged/non-owned assignment has no roster','select count(*) from public.teacher_assignment_roster(''b9000000-0000-0000-0000-000000000099''::uuid)');
select pg_temp.qa_probe_dml('A21','ALLOW','CURRENT REPOSITORY CONTRACT','Teacher A can insert attendance for an actively enrolled 8A student through exact Math assignment','insert into public.presencas(id,tenant_id,registro_aula_id,usuario_id,situacao) values (''b2000000-0000-0000-0000-000000000010'',''a1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-000000000001'',''a4000000-0000-0000-0000-000000000014'',''presente'')','select count(*)::text from public.presencas where id=''b2000000-0000-0000-0000-000000000010''');
select pg_temp.qa_probe_dml('A22','DENY','CURRENT REPOSITORY CONTRACT','Teacher A cannot insert attendance through an unassigned 8A Chemistry record','insert into public.presencas(id,tenant_id,registro_aula_id,usuario_id,situacao) values (''b2000000-0000-0000-0000-000000000011'',''a1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-000000000003'',''a4000000-0000-0000-0000-000000000014'',''presente'')','select count(*)::text from public.presencas where id=''b2000000-0000-0000-0000-000000000011''');
select pg_temp.qa_probe_count('A23','DENY','CURRENT REPOSITORY CONTRACT','Teacher A cannot read 8A Chemistry attendance through Math/Physics assignments','select count(*) from public.registros_aula where id=''b1000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_dml('A24','ALLOW','CURRENT REPOSITORY CONTRACT','Presence write for enrolled Student 8A2 is allowed; rolled back','insert into public.presencas(id,tenant_id,registro_aula_id,usuario_id,situacao) values (''b2000000-0000-0000-0000-000000000010'',''a1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-000000000001'',''a4000000-0000-0000-0000-000000000014'',''presente'')','select count(*)::text from public.presencas where id=''b2000000-0000-0000-0000-000000000010''');
select pg_temp.qa_probe_dml('A25','DENY','CURRENT REPOSITORY CONTRACT','Presence write for Student A2 outside 8A is accepted by current policy; rolled back','insert into public.presencas(id,tenant_id,registro_aula_id,usuario_id,situacao) values (''b2000000-0000-0000-0000-000000000011'',''a1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-000000000001'',''a4000000-0000-0000-0000-000000000013'',''presente'')','select count(*)::text from public.presencas where id=''b2000000-0000-0000-0000-000000000011''');

-- A26–A30 materials and announcements.
select pg_temp.qa_probe_dml('A26','ALLOW','CURRENT REPOSITORY CONTRACT','Teacher A can insert own class material; rolled back','insert into public.materiais_professor(id,tenant_id,turma_id,disciplina_id,professor_id,titulo) values (''af000000-0000-0000-0000-000000000010'',''a1000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000003'',''a6000000-0000-0000-0000-000000000001'',''a4000000-0000-0000-0000-000000000002'',''QA new material'')','select count(*)::text from public.materiais_professor where id=''af000000-0000-0000-0000-000000000010''');
select pg_temp.qa_probe_dml('A27','DENY','CURRENT REPOSITORY CONTRACT','NULL Subject is accepted on subject-specific material table; rolled back','insert into public.materiais_professor(id,tenant_id,turma_id,disciplina_id,professor_id,titulo) values (''af000000-0000-0000-0000-000000000011'',''a1000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000003'',null,''a4000000-0000-0000-0000-000000000002'',''QA null subject material'')','select count(*)::text from public.materiais_professor where id=''af000000-0000-0000-0000-000000000011''');
select pg_temp.qa_probe_dml('A28','DENY','CURRENT REPOSITORY CONTRACT','Teacher A can delete same-class material owned by Teacher A2; rolled back','delete from public.materiais_professor where id=''af000000-0000-0000-0000-000000000004''','select count(*)::text from public.materiais_professor where id=''af000000-0000-0000-0000-000000000004''');
select pg_temp.qa_probe_dml('A29','DENY','CURRENT REPOSITORY CONTRACT','Teacher cannot create a class-wide announcement from a Subject assignment; staff-only path remains explicit','insert into public.avisos_turma(id,tenant_id,turma_id,professor_id,tipo,titulo) values (''b0000000-0000-0000-0000-000000000010'',''a1000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000003'',''a4000000-0000-0000-0000-000000000002'',''aviso_geral'',''QA new notice'')','select count(*)::text from public.avisos_turma where id=''b0000000-0000-0000-0000-000000000010''');
select pg_temp.qa_probe_dml('A30','DENY','LEGACY_COMPATIBILITY_ONLY','No approved class-wide capability primitive exists; current legacy policy grants class-wide operation; rolled back','insert into public.avisos_turma(id,tenant_id,turma_id,professor_id,tipo,titulo) values (''b0000000-0000-0000-0000-000000000011'',''a1000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000003'',''a4000000-0000-0000-0000-000000000002'',''aviso_geral'',''QA class-wide notice'')','select count(*)::text from public.avisos_turma where id=''b0000000-0000-0000-0000-000000000011''');

-- A31–A35 assessments.
select pg_temp.qa_probe_dml('A31','ALLOW','CURRENT REPOSITORY CONTRACT','Teacher A can create a Math question as tenant-wide docente; rolled back','insert into public.questoes(id,tenant_id,disciplina_id,enunciado,alternativas,resposta_correta,criado_por) values (''aa000000-0000-0000-0000-000000000010'',''a1000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''QA new question'',''[{"id":"a"}]'',''a'',''a4000000-0000-0000-0000-000000000002'')','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000010''');
select pg_temp.qa_probe_dml('A32','DENY','CURRENT REPOSITORY CONTRACT','Teacher A can create a Chemistry assessment without exact assignment; rolled back','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ac000000-0000-0000-0000-000000000010'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000003'',''a7000000-0000-0000-0000-000000000003'',''QA new Chemistry assessment'',''rascunho'',''a4000000-0000-0000-0000-000000000002'')','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000010''');
select pg_temp.qa_probe_dml('A33','DENY','CURRENT REPOSITORY CONTRACT','Assessment-question policy allows same-tenant Subject mismatch; rolled back','insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem,tenant_id) values (''ac000000-0000-0000-0000-000000000001'',''aa000000-0000-0000-0000-000000000002'',2,''a1000000-0000-0000-0000-000000000001'')','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_dml('A34','DENY','CURRENT REPOSITORY CONTRACT','Teacher A cannot directly correct a Physics response; grading must use the validated RPC','update public.avaliacao_respostas set pontos_obtidos=1,corrigida=true where id=''ae000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000001'' and corrigida=false');
select pg_temp.qa_probe_dml('A35','DENY','CURRENT REPOSITORY CONTRACT','Teacher A can correct 7A Physics despite no subject-specific assignment; rolled back','update public.avaliacao_respostas set pontos_obtidos=1,corrigida=true where id=''ae000000-0000-0000-0000-000000000002''','select count(*)::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000002'' and corrigida=false');

-- A36–A38 student behavior.
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000012',false);
select pg_temp.qa_probe_dml('A36','DENY','CURRENT REPOSITORY CONTRACT','Student cannot write docente resources under current RLS; rolled back','insert into public.materiais_professor(id,tenant_id,turma_id,disciplina_id,professor_id,titulo) values (''af000000-0000-0000-0000-000000000012'',''a1000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000003'',''a6000000-0000-0000-0000-000000000001'',''a4000000-0000-0000-0000-000000000012'',''QA student material'')','select count(*)::text from public.materiais_professor where id=''af000000-0000-0000-0000-000000000012''');
select pg_temp.qa_probe_count('A37','ALLOW','CURRENT REPOSITORY CONTRACT','Student 8A can directly read own attempt row; gabarito verdict is evaluated at A45','select count(*) from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000000001''');
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000010',false);
select pg_temp.qa_probe_rpc('A38','DENY','CURRENT REPOSITORY CONTRACT','Student 7A can attempt an 8A evaluation from the same Course because start RPC checks Course but not Class','select public.iniciar_tentativa_avaliacao(''ac000000-0000-0000-0000-000000000001''::uuid,''a8000000-0000-0000-0000-000000000001''::uuid)');

-- A39–A42 revocation, inactive state, legacy bridge and forged IDs.
set role authenticated;
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000001',false);
select public.revoke_teacher_assignment('aa100000-0000-0000-0000-000000000004'::uuid);
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
select pg_temp.qa_probe_count('A39','DENY','CURRENT REPOSITORY CONTRACT','Revoked 8A Physics assignment is denied immediately','select count(*) from public.registros_aula where id=''b1000000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_count('A40','ALLOW','CURRENT REPOSITORY CONTRACT','Revoking 8A Physics leaves 8A Math assignment allowed','select count(*) from public.registros_aula where id=''b1000000-0000-0000-0000-000000000001''');
reset role;
update public.unidades set ativo=false where id='a2000000-0000-0000-0000-000000000001';
set role authenticated;
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
select pg_temp.qa_probe_count('A41','DENY','CURRENT REPOSITORY CONTRACT','Inactive Unit does not block existing class/attendance visibility','select count(*) from public.registros_aula where id=''b1000000-0000-0000-0000-000000000001''');
reset role;
update public.unidades set ativo=true where id='a2000000-0000-0000-0000-000000000001';
update public.turmas set ativa=false where id='a7000000-0000-0000-0000-000000000003';
set role authenticated;
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
select pg_temp.qa_probe_count('A42','DENY','CURRENT REPOSITORY CONTRACT','Inactive Class does not block legacy class-based read; legacy link remains an active grant','select count(*) from public.registros_aula where id=''b1000000-0000-0000-0000-000000000001''');
reset role;
update public.turmas set ativa=true where id='a7000000-0000-0000-0000-000000000003';
set role authenticated;
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000001',false);
select pg_temp.qa_probe_dml('A43','DENY','CURRENT REPOSITORY CONTRACT','Manager can create Class in TA with Course/Unit from TB; parent integrity is not enforced; rolled back','insert into public.turmas(id,tenant_id,curso_id,unidade_id,nome) values (''a7100000-0000-0000-0000-000000000010'',''a1000000-0000-0000-0000-000000000001'',''b5000000-0000-0000-0000-000000000001'',''b2000000-0000-0000-0000-000000000001'',''QA forged class'')','select count(*)::text from public.turmas where id=''a7100000-0000-0000-0000-000000000010''');
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
select pg_temp.qa_probe_dml('A44','DENY','CURRENT REPOSITORY CONTRACT','Attendance policy does not bind professor_id to session identity; forged professor_id is accepted; rolled back','insert into public.registros_aula(id,tenant_id,turma_id,disciplina_id,professor_id,data_aula) values (''b1000000-0000-0000-0000-000000000010'',''a1000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000003'',''a6000000-0000-0000-0000-000000000001'',''b4000000-0000-0000-0000-000000000001'',current_date)','select count(*)::text from public.registros_aula where id=''b1000000-0000-0000-0000-000000000010''');

-- A45: authenticated Student A direct column read. This is the mandated verdict.
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000012',false);
select pg_temp.qa_probe_count('A45','DENY','CURRENT REPOSITORY CONTRACT','Student direct SELECT cannot retrieve gabarito_snapshot after column-level revoke','select count(*) from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000000001'' and gabarito_snapshot <> ''{}''::jsonb');

-- R3-BLOCKER-A: staff cross-tenant reads on every affected policy surface.
select pg_temp.qa_probe_actor_count('R3-SA-SEL-Q','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot SELECT a Tenant B question','a3000000-0000-0000-0000-000000000001','select count(*) from public.questoes where id=''bb000000-0000-0000-0000-000000000001''','select count(*)::text from public.questoes where id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SB-SEL-Q','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot SELECT a Tenant A question','b3000000-0000-0000-0000-000000000002','select count(*) from public.questoes where id=''aa000000-0000-0000-0000-000000000001''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SA-SEL-A','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot SELECT a Tenant B assessment','a3000000-0000-0000-0000-000000000001','select count(*) from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SB-SEL-A','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot SELECT a Tenant A assessment','b3000000-0000-0000-0000-000000000002','select count(*) from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SA-SEL-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot SELECT a Tenant B assessment-question row','a3000000-0000-0000-0000-000000000001','select count(*) from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SB-SEL-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot SELECT a Tenant A assessment-question row','b3000000-0000-0000-0000-000000000002','select count(*) from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SA-SEL-T','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot SELECT a Tenant B attempt','a3000000-0000-0000-0000-000000000001','select count(*) from public.avaliacao_tentativas where id=''bd000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_tentativas where id=''bd000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SB-SEL-T','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot SELECT a Tenant A attempt','b3000000-0000-0000-0000-000000000002','select count(*) from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SA-SEL-R','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot SELECT a Tenant B response','a3000000-0000-0000-0000-000000000001','select count(*) from public.avaliacao_respostas where id=''be000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_respostas where id=''be000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SB-SEL-R','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot SELECT a Tenant A response','b3000000-0000-0000-0000-000000000002','select count(*) from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''','select count(*)::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');

-- R3-BLOCKER-A: staff inserts, cross-tenant updates and deletes.
select pg_temp.qa_probe_actor_dml('R3-SA-INS-Q','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot INSERT a Tenant B question','a3000000-0000-0000-0000-000000000001','insert into public.questoes(id,tenant_id,disciplina_id,enunciado,alternativas,resposta_correta,criado_por) values (''ca300000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-000000000001'',''b6000000-0000-0000-0000-000000000001'',''QA forbidden B question'',''[{"id":"a"}]'',''a'',''b4000000-0000-0000-0000-000000000001'')','select count(*)::text from public.questoes where id=''ca300000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-INS-Q','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot INSERT a Tenant A question','b3000000-0000-0000-0000-000000000002','insert into public.questoes(id,tenant_id,disciplina_id,enunciado,alternativas,resposta_correta,criado_por) values (''cb300000-0000-0000-0000-000000000001'',''a1000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''QA forbidden A question'',''[{"id":"a"}]'',''a'',''a4000000-0000-0000-0000-000000000001'')','select count(*)::text from public.questoes where id=''cb300000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml_setup('R3-SA-UPD-Q-XTENANT','DENY','BLOCKING RLS TENANT BOUNDARY','Staff A cannot update an A question to Tenant B even with parent-integrity trigger disabled','a3000000-0000-0000-0000-000000000001','alter table public.questoes disable trigger trg_sc004_parent_integrity','update public.questoes set tenant_id=''b1000000-0000-0000-0000-000000000001'' where id=''aa000000-0000-0000-0000-000000000001''','select tenant_id::text from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml_setup('R3-SB-UPD-Q-XTENANT','DENY','BLOCKING RLS TENANT BOUNDARY','Staff B cannot update a B question to Tenant A even with parent-integrity trigger disabled','b3000000-0000-0000-0000-000000000002','alter table public.questoes disable trigger trg_sc004_parent_integrity','update public.questoes set tenant_id=''a1000000-0000-0000-0000-000000000001'' where id=''bb000000-0000-0000-0000-000000000001''','select tenant_id::text from public.questoes where id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SA-UPD-Q-ROW','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot update a Tenant B question','a3000000-0000-0000-0000-000000000001','update public.questoes set enunciado=''QA forbidden edit'' where id=''bb000000-0000-0000-0000-000000000001''','select enunciado from public.questoes where id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-UPD-Q-ROW','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot update a Tenant A question','b3000000-0000-0000-0000-000000000002','update public.questoes set enunciado=''QA forbidden edit'' where id=''aa000000-0000-0000-0000-000000000001''','select enunciado from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SA-DEL-Q','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot DELETE a Tenant B question','a3000000-0000-0000-0000-000000000001','delete from public.questoes where id=''bb000000-0000-0000-0000-000000000001''','select count(*)::text from public.questoes where id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-DEL-Q','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot DELETE a Tenant A question','b3000000-0000-0000-0000-000000000002','delete from public.questoes where id=''aa000000-0000-0000-0000-000000000001''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');

select pg_temp.qa_probe_actor_dml('R3-SA-INS-A','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot INSERT a Tenant B assessment','a3000000-0000-0000-0000-000000000001','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ca300000-0000-0000-0000-000000000002'',''b1000000-0000-0000-0000-000000000001'',''b5000000-0000-0000-0000-000000000001'',''b6000000-0000-0000-0000-000000000001'',''b7000000-0000-0000-0000-000000000001'',''QA forbidden B assessment'',''rascunho'',''b4000000-0000-0000-0000-000000000001'')','select count(*)::text from public.avaliacoes where id=''ca300000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_actor_dml('R3-SB-INS-A','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot INSERT a Tenant A assessment','b3000000-0000-0000-0000-000000000002','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''cb300000-0000-0000-0000-000000000002'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000003'',''QA forbidden A assessment'',''rascunho'',''a4000000-0000-0000-0000-000000000001'')','select count(*)::text from public.avaliacoes where id=''cb300000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_actor_dml_setup('R3-SA-UPD-A-XTENANT','DENY','BLOCKING RLS TENANT BOUNDARY','Staff A cannot update an A assessment to Tenant B even with parent-integrity trigger disabled','a3000000-0000-0000-0000-000000000001','alter table public.avaliacoes disable trigger trg_sc004_parent_integrity','update public.avaliacoes set tenant_id=''b1000000-0000-0000-0000-000000000001'' where id=''ac000000-0000-0000-0000-000000000001''','select tenant_id::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml_setup('R3-SB-UPD-A-XTENANT','DENY','BLOCKING RLS TENANT BOUNDARY','Staff B cannot update a B assessment to Tenant A even with parent-integrity trigger disabled','b3000000-0000-0000-0000-000000000002','alter table public.avaliacoes disable trigger trg_sc004_parent_integrity','update public.avaliacoes set tenant_id=''a1000000-0000-0000-0000-000000000001'' where id=''bc000000-0000-0000-0000-000000000001''','select tenant_id::text from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SA-UPD-A-ROW','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot update a Tenant B assessment','a3000000-0000-0000-0000-000000000001','update public.avaliacoes set titulo=''QA forbidden edit'' where id=''bc000000-0000-0000-0000-000000000001''','select titulo from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-UPD-A-ROW','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot update a Tenant A assessment','b3000000-0000-0000-0000-000000000002','update public.avaliacoes set titulo=''QA forbidden edit'' where id=''ac000000-0000-0000-0000-000000000001''','select titulo from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SA-DEL-A','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot DELETE a Tenant B assessment','a3000000-0000-0000-0000-000000000001','delete from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-DEL-A','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot DELETE a Tenant A assessment','b3000000-0000-0000-0000-000000000002','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');

select pg_temp.qa_probe_actor_dml_setup('R3-SA-INS-AQ','DENY','BLOCKING RLS TENANT BOUNDARY','Staff A cannot INSERT a valid Tenant B assessment-question row even with the parent trigger disabled','a3000000-0000-0000-0000-000000000001','alter table public.avaliacao_questoes disable trigger sc003_avaliacao_questao_integrity; alter table public.avaliacao_questoes disable trigger trg_sc004_parent_integrity','insert into public.avaliacao_questoes(tenant_id,avaliacao_id,questao_id,ordem) values (''b1000000-0000-0000-0000-000000000001'',''bc000000-0000-0000-0000-000000000002'',''bb000000-0000-0000-0000-000000000002'',2)','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000002'' and questao_id=''bb000000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_actor_dml_setup('R3-SB-INS-AQ','DENY','BLOCKING RLS TENANT BOUNDARY','Staff B cannot INSERT a valid Tenant A assessment-question row even with the parent trigger disabled','b3000000-0000-0000-0000-000000000002','alter table public.avaliacao_questoes disable trigger sc003_avaliacao_questao_integrity; alter table public.avaliacao_questoes disable trigger trg_sc004_parent_integrity','insert into public.avaliacao_questoes(tenant_id,avaliacao_id,questao_id,ordem) values (''a1000000-0000-0000-0000-000000000001'',''ac000000-0000-0000-0000-000000000008'',''aa000000-0000-0000-0000-000000000005'',2)','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000008'' and questao_id=''aa000000-0000-0000-0000-000000000005''');
select pg_temp.qa_probe_actor_dml('R3-SA-UPD-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot UPDATE a Tenant B assessment-question row','a3000000-0000-0000-0000-000000000001','update public.avaliacao_questoes set ordem=9 where avaliacao_id=''bc000000-0000-0000-0000-000000000002'' and questao_id=''bb000000-0000-0000-0000-000000000002''','select ordem::text from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000002'' and questao_id=''bb000000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_actor_dml('R3-SB-UPD-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot UPDATE a Tenant A assessment-question row','b3000000-0000-0000-0000-000000000002','update public.avaliacao_questoes set ordem=9 where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000001''','select ordem::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SA-DEL-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot DELETE a Tenant B assessment-question row','a3000000-0000-0000-0000-000000000001','delete from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000001'' and questao_id=''bb000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000001'' and questao_id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-DEL-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot DELETE a Tenant A assessment-question row','b3000000-0000-0000-0000-000000000002','delete from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000001''');

select pg_temp.qa_probe_actor_dml('R3-SA-INS-T','DENY','BLOCKING TABLE PRIVILEGE','Staff A cannot INSERT a Tenant B attempt because attempts have no direct authenticated write path','a3000000-0000-0000-0000-000000000001','insert into public.avaliacao_tentativas(id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,questoes_ordem,gabarito_snapshot) values (''ca300000-0000-0000-0000-000000000003'',''b1000000-0000-0000-0000-000000000001'',''bc000000-0000-0000-0000-000000000001'',''b8000000-0000-0000-0000-000000000001'',''b4000000-0000-0000-0000-000000000010'',90,''[{"questao_id":"bb000000-0000-0000-0000-000000000001","pontos":1}]'',''{}'')','select count(*)::text from public.avaliacao_tentativas where id=''ca300000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_dml('R3-SB-INS-T','DENY','BLOCKING TABLE PRIVILEGE','Staff B cannot INSERT a Tenant A attempt because attempts have no direct authenticated write path','b3000000-0000-0000-0000-000000000002','insert into public.avaliacao_tentativas(id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,questoes_ordem,gabarito_snapshot) values (''cb300000-0000-0000-0000-000000000003'',''a1000000-0000-0000-0000-000000000001'',''ac000000-0000-0000-0000-000000000001'',''a8000000-0000-0000-0000-000000000003'',''a4000000-0000-0000-0000-000000000012'',90,''[{"questao_id":"aa000000-0000-0000-0000-000000000001","pontos":1}]'',''{}'')','select count(*)::text from public.avaliacao_tentativas where id=''cb300000-0000-0000-0000-000000000003''');

select pg_temp.qa_probe_actor_dml_setup('R3-SA-INS-R','DENY','BLOCKING RLS TENANT BOUNDARY','Staff A cannot INSERT a valid Tenant B response even with the parent trigger disabled','a3000000-0000-0000-0000-000000000001','alter table public.avaliacao_respostas disable trigger sc003_resposta_integrity; alter table public.avaliacao_respostas disable trigger trg_sc004_parent_integrity','insert into public.avaliacao_respostas(id,tenant_id,tentativa_id,questao_id) values (''ca300000-0000-0000-0000-000000000004'',''b1000000-0000-0000-0000-000000000001'',''bd000000-0000-0000-0000-000000000002'',''bb000000-0000-0000-0000-000000000002'')','select count(*)::text from public.avaliacao_respostas where id=''ca300000-0000-0000-0000-000000000004''');
select pg_temp.qa_probe_actor_dml_setup('R3-SB-INS-R','DENY','BLOCKING RLS TENANT BOUNDARY','Staff B cannot INSERT a valid Tenant A response even with the parent trigger disabled','b3000000-0000-0000-0000-000000000002','alter table public.avaliacao_respostas disable trigger sc003_resposta_integrity; alter table public.avaliacao_respostas disable trigger trg_sc004_parent_integrity','insert into public.avaliacao_respostas(id,tenant_id,tentativa_id,questao_id) values (''cb300000-0000-0000-0000-000000000004'',''a1000000-0000-0000-0000-000000000001'',''ad000000-0000-0000-0000-000000000004'',''aa000000-0000-0000-0000-000000000005'')','select count(*)::text from public.avaliacao_respostas where id=''cb300000-0000-0000-0000-000000000004''');
select pg_temp.qa_probe_actor_dml('R3-SA-UPD-R','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot UPDATE a Tenant B response','a3000000-0000-0000-0000-000000000001','update public.avaliacao_respostas set pontos_obtidos=1 where id=''be000000-0000-0000-0000-000000000001''','select coalesce(pontos_obtidos::text,''NULL'') from public.avaliacao_respostas where id=''be000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-UPD-R','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot UPDATE a Tenant A response','b3000000-0000-0000-0000-000000000002','update public.avaliacao_respostas set pontos_obtidos=1 where id=''ae000000-0000-0000-0000-000000000003''','select coalesce(pontos_obtidos::text,''NULL'') from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_dml('R3-SA-DEL-R','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot DELETE a Tenant B response','a3000000-0000-0000-0000-000000000001','delete from public.avaliacao_respostas where id=''be000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_respostas where id=''be000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-DEL-R','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot DELETE a Tenant A response','b3000000-0000-0000-0000-000000000002','delete from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''','select count(*)::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');

-- R3-BLOCKER-A: corresponding same-tenant staff reads remain allowed.
select pg_temp.qa_probe_actor_count('R3-SA-OWN-Q','ALLOW','BLOCKING SAME-TENANT STAFF','Staff A can SELECT its own Tenant A question','a3000000-0000-0000-0000-000000000001','select count(*) from public.questoes where id=''aa000000-0000-0000-0000-000000000001''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SB-OWN-Q','ALLOW','BLOCKING SAME-TENANT STAFF','Staff B can SELECT its own Tenant B question','b3000000-0000-0000-0000-000000000002','select count(*) from public.questoes where id=''bb000000-0000-0000-0000-000000000001''','select count(*)::text from public.questoes where id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SA-OWN-A','ALLOW','BLOCKING SAME-TENANT STAFF','Staff A can SELECT its own Tenant A assessment','a3000000-0000-0000-0000-000000000001','select count(*) from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SB-OWN-A','ALLOW','BLOCKING SAME-TENANT STAFF','Staff B can SELECT its own Tenant B assessment','b3000000-0000-0000-0000-000000000002','select count(*) from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SA-OWN-AQ','ALLOW','BLOCKING SAME-TENANT STAFF','Staff A can SELECT its own Tenant A assessment-question row','a3000000-0000-0000-0000-000000000001','select count(*) from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SB-OWN-AQ','ALLOW','BLOCKING SAME-TENANT STAFF','Staff B can SELECT its own Tenant B assessment-question row','b3000000-0000-0000-0000-000000000002','select count(*) from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SA-OWN-T','ALLOW','BLOCKING SAME-TENANT STAFF','Staff A can SELECT its own Tenant A attempt','a3000000-0000-0000-0000-000000000001','select count(*) from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SB-OWN-T','ALLOW','BLOCKING SAME-TENANT STAFF','Staff B can SELECT its own Tenant B attempt','b3000000-0000-0000-0000-000000000002','select count(*) from public.avaliacao_tentativas where id=''bd000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_tentativas where id=''bd000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-SA-OWN-R','ALLOW','BLOCKING SAME-TENANT STAFF','Staff A can SELECT its own Tenant A response','a3000000-0000-0000-0000-000000000001','select count(*) from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''','select count(*)::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_count('R3-SB-OWN-R','ALLOW','BLOCKING SAME-TENANT STAFF','Staff B can SELECT its own Tenant B response','b3000000-0000-0000-0000-000000000002','select count(*) from public.avaliacao_respostas where id=''be000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_respostas where id=''be000000-0000-0000-0000-000000000001''');

-- R3-BLOCKER-B: course-wide and wrong Class/Subject assessment writes are blocking.
select pg_temp.qa_probe_actor_dml('R3-COURSE-7A-MATH','DENY','BLOCKING COURSE-WIDE ASSESSMENT','Teacher Exact A without the requested assignment cannot create 7A Math assessment','a3000000-0000-0000-0000-000000000005','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ac300000-0000-0000-0000-000000000003'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000001'',''QA forbidden 7A Math'',''rascunho'',''a4000000-0000-0000-0000-000000000005'')','select count(*)::text from public.avaliacoes where id=''ac300000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_dml('R3-COURSE-8B-MATH','DENY','BLOCKING COURSE-WIDE ASSESSMENT','Teacher Exact A without the requested assignment cannot create 8B Math assessment','a3000000-0000-0000-0000-000000000005','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ac300000-0000-0000-0000-000000000004'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000005'',''QA forbidden 8B Math'',''rascunho'',''a4000000-0000-0000-0000-000000000005'')','select count(*)::text from public.avaliacoes where id=''ac300000-0000-0000-0000-000000000004''');
select pg_temp.qa_probe_actor_dml('R3-COURSE-8A-PHYSICS','DENY','BLOCKING COURSE-WIDE ASSESSMENT','Teacher Exact A without the requested assignment cannot create 8A Physics assessment','a3000000-0000-0000-0000-000000000005','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ac300000-0000-0000-0000-000000000005'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000002'',''a7000000-0000-0000-0000-000000000003'',''QA forbidden 8A Physics'',''rascunho'',''a4000000-0000-0000-0000-000000000005'')','select count(*)::text from public.avaliacoes where id=''ac300000-0000-0000-0000-000000000005''');
select pg_temp.qa_probe_actor_dml('R3-COURSE-WIDE','DENY','BLOCKING COURSE-WIDE ASSESSMENT','Teacher Exact A without the requested Class cannot create a course-wide Math assessment','a3000000-0000-0000-0000-000000000005','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ac300000-0000-0000-0000-000000000006'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',null,''QA forbidden course-wide'',''rascunho'',''a4000000-0000-0000-0000-000000000005'')','select count(*)::text from public.avaliacoes where id=''ac300000-0000-0000-0000-000000000006''');
select pg_temp.qa_probe_actor_dml('R3-EXACT-8A-MATH','ALLOW','BLOCKING COURSE-WIDE ASSESSMENT','Teacher A with exact active 8A Math assignment can create an 8A Math assessment','a3000000-0000-0000-0000-000000000005','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ac300000-0000-0000-0000-000000000007'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000003'',''QA allowed 8A Math'',''rascunho'',''a4000000-0000-0000-0000-000000000005'')','select count(*)::text from public.avaliacoes where id=''ac300000-0000-0000-0000-000000000007''');
select pg_temp.qa_probe_actor_count('R3-AQ-EXACT-ALLOW','ALLOW','BLOCKING COURSE-WIDE ASSESSMENT','Teacher A reads an assessment-question row only through exact 8A Math assignment','a3000000-0000-0000-0000-000000000002','select count(*) from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_count('R3-AQ-NO-ASSIGNMENT','DENY','BLOCKING COURSE-WIDE ASSESSMENT','Teacher A3 cannot read an assessment-question row without exact assignment','a3000000-0000-0000-0000-000000000004','select count(*) from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001''');

-- R3-BLOCKER-C: helper ACL and no arbitrary-tenant oracle.
select pg_temp.qa_record('R3-HELPER-ACL','ALLOW',case when has_function_privilege('public','public.student_active_in_class(uuid,uuid,uuid)','EXECUTE') = false and has_function_privilege('anon','public.student_active_in_class(uuid,uuid,uuid)','EXECUTE') = false and has_function_privilege('authenticated','public.student_active_in_class(uuid,uuid,uuid)','EXECUTE') = true then 'ALLOW' else 'DENY' end,'SECURITY DEFINER helper is internal to RLS: authenticated execution retained only for presencas policy; PUBLIC and anon denied','','','ACL is explicit and tenant binding is tested below');
select pg_temp.qa_probe_actor_count('R3-HELPER-SAME-TENANT','ALLOW','BLOCKING HELPER TENANT BINDING','Authenticated Teacher A can evaluate an active Student A in Tenant A','a3000000-0000-0000-0000-000000000002','select case when public.student_active_in_class(''a4000000-0000-0000-0000-000000000012'',''a7000000-0000-0000-0000-000000000003'',public.current_tenant_id()) then 1 else 0 end::bigint','select 1::text');
select pg_temp.qa_probe_actor_count('R3-HELPER-TEACHER-CROSS-TENANT','DENY','BLOCKING HELPER TENANT BINDING','Authenticated Teacher A cannot probe Student B using Tenant B','a3000000-0000-0000-0000-000000000002','select case when public.student_active_in_class(''b4000000-0000-0000-0000-000000000010'',''b7000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-000000000001'') then 1 else 0 end::bigint','select 1::text');
select pg_temp.qa_probe_actor_count('R3-HELPER-STUDENT-CROSS-TENANT','DENY','BLOCKING HELPER TENANT BINDING','Authenticated Student A cannot probe Student B using Tenant B','a3000000-0000-0000-0000-000000000012','select case when public.student_active_in_class(''b4000000-0000-0000-0000-000000000010'',''b7000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-000000000001'') then 1 else 0 end::bigint','select 1::text');
select pg_temp.qa_probe_actor_count('R3-HELPER-STAFF-CROSS-TENANT','DENY','BLOCKING HELPER TENANT BINDING','Authenticated Staff A cannot probe Student B using Tenant B','a3000000-0000-0000-0000-000000000001','select case when public.student_active_in_class(''b4000000-0000-0000-0000-000000000010'',''b7000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-000000000001'') then 1 else 0 end::bigint','select 1::text');

-- R3-BLOCKER-D and grading RPC: every negative is a real RPC invocation.
select pg_temp.qa_probe_actor_rpc('R3-GRADE-POSITIVE','ALLOW','BLOCKING GRADING RPC','Teacher Exact A with exact 8A Math assignment grades a legitimate submitted response','a3000000-0000-0000-0000-000000000005','update public.avaliacao_tentativas set situacao=''enviada'',enviada_em=now() where id=''ad000000-0000-0000-0000-000000000001''','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA legitimate grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-NO-ASSIGNMENT','DENY','BLOCKING GRADING RPC','Teacher A3 without assignment is denied by the real grading RPC','a3000000-0000-0000-0000-000000000004','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA forbidden grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-WRONG-CLASS','DENY','BLOCKING GRADING RPC','Teacher Exact A is denied for a 7A Math response because the only assignment is 8A Math','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000004''::uuid,1,''QA wrong class grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000004''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-WRONG-SUBJECT','DENY','BLOCKING GRADING RPC','Active Teacher A has an active assignment elsewhere but no assignment for 7A Physics','a3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000002''::uuid,1,''QA wrong subject grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-INACTIVE','DENY','BLOCKING GRADING RPC','Inactive Teacher A2 is denied by the real grading RPC','a3000000-0000-0000-0000-000000000003','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA inactive grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-STUDENT','DENY','BLOCKING GRADING RPC','Student A is denied by the real grading RPC','a3000000-0000-0000-0000-000000000012','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA student grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-STAFF-B','DENY','BLOCKING GRADING RPC','Staff B cannot grade a Tenant A response','b3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA cross-tenant staff grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-TEACHER-B','DENY','BLOCKING GRADING RPC','Teacher B cannot grade a Tenant A response','b3000000-0000-0000-0000-000000000001','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA cross-tenant teacher grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-CROSS-TENANT','DENY','BLOCKING GRADING RPC','Teacher A cannot grade a Tenant B response','a3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''be000000-0000-0000-0000-000000000001''::uuid,1,''QA cross-tenant grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''be000000-0000-0000-0000-000000000001''');

-- R4 H1: cross-class question authority and answer-key confidentiality.
select pg_temp.qa_probe_actor_count('R4-H1-X-SELECT-ANSWER','DENY','BLOCKING H1 QUESTION AUTHORITY','Teacher X 8A Math cannot SELECT the 7A Math question or answer key owned by Teacher Y','a3000000-0000-0000-0000-000000000005','select count(*) from public.questoes where id=''aa000000-0000-0000-0000-000000000005'' and resposta_correta is not null','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000005''');
select pg_temp.qa_probe_actor_dml('R4-H1-X-UPDATE-OWNER','DENY','BLOCKING H1 QUESTION AUTHORITY','Teacher X cannot self-assign criado_por on Teacher Y question','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'' where id=''aa000000-0000-0000-0000-000000000005''','select criado_por::text from public.questoes where id=''aa000000-0000-0000-0000-000000000005''');
select pg_temp.qa_probe_actor_dml('R4-H1-X-UPDATE-ANSWER','DENY','BLOCKING H1 QUESTION AUTHORITY','Teacher X cannot rewrite resposta_correta on Teacher Y question','a3000000-0000-0000-0000-000000000005','update public.questoes set resposta_correta=''b'' where id=''aa000000-0000-0000-0000-000000000005''','select resposta_correta from public.questoes where id=''aa000000-0000-0000-0000-000000000005''');
select pg_temp.qa_probe_actor_dml('R4-H1-X-UPDATE-TEXT','DENY','BLOCKING H1 QUESTION AUTHORITY','Teacher X cannot rewrite enunciado on Teacher Y question','a3000000-0000-0000-0000-000000000005','update public.questoes set enunciado=''QA forbidden rewrite'' where id=''aa000000-0000-0000-0000-000000000005''','select enunciado from public.questoes where id=''aa000000-0000-0000-0000-000000000005''');
select pg_temp.qa_probe_actor_dml('R4-H1-X-UPDATE-COMBINED','DENY','BLOCKING H1 QUESTION AUTHORITY','Teacher X cannot combine self criado_por with answer-key/text mutation','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'', resposta_correta=''b'', enunciado=''QA forbidden combined rewrite'' where id=''aa000000-0000-0000-0000-000000000005''','select criado_por::text||''|''||resposta_correta||''|''||enunciado from public.questoes where id=''aa000000-0000-0000-0000-000000000005''');
select pg_temp.qa_probe_actor_dml('R4-H1-X-DELETE','DENY','BLOCKING H1 QUESTION AUTHORITY','Teacher X cannot DELETE the assessment-bound Teacher Y question','a3000000-0000-0000-0000-000000000005','delete from public.questoes where id=''aa000000-0000-0000-0000-000000000005''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000005''');
select pg_temp.qa_probe_actor_dml('R4-H1-Y-POSITIVE','DENY','BLOCKING ACADEMIC EVIDENCE IMMUTABILITY','Teacher Y cannot mutate a question after its assessment has evidence','a3000000-0000-0000-0000-000000000006','update public.questoes set enunciado=''QA Teacher Y forbidden post-evidence edit'' where id=''aa000000-0000-0000-0000-000000000005''','select enunciado from public.questoes where id=''aa000000-0000-0000-0000-000000000005''');

-- Same-tenant staff positive DML and cross-tenant staff denial.
select pg_temp.qa_probe_actor_dml('R4-STAFF-INSERT-Q','ALLOW','BLOCKING SAME-TENANT STAFF','Staff A can INSERT an unlinked question in Tenant A','a3000000-0000-0000-0000-000000000001','insert into public.questoes(id,tenant_id,disciplina_id,enunciado,alternativas,resposta_correta,criado_por) values (''aa000000-0000-0000-0000-000000000020'',''a1000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''QA staff insert'',''[{"id":"a"}]'',''a'',''a4000000-0000-0000-0000-000000000001'')','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000020''');
select pg_temp.qa_probe_actor_dml('R4-STAFF-UPDATE-Q','ALLOW','BLOCKING SAME-TENANT STAFF','Staff A can UPDATE its Tenant A question','a3000000-0000-0000-0000-000000000001','update public.questoes set enunciado=''QA staff allowed edit'' where id=''aa000000-0000-0000-0000-000000000006''','select enunciado from public.questoes where id=''aa000000-0000-0000-0000-000000000006''');
select pg_temp.qa_probe_actor_dml('R4-STAFF-DELETE-Q','ALLOW','BLOCKING SAME-TENANT STAFF','Staff A can DELETE its Tenant A question','a3000000-0000-0000-0000-000000000001','delete from public.questoes where id=''aa000000-0000-0000-0000-000000000006''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000006''');



-- R5.2-B5: co-assigned Teacher cannot manufacture ownership or rewrite
-- assessment-bound content; evidence freezes configuration and parent rows.
select pg_temp.qa_probe_actor_dml('R52-QUESTION-TAKEOVER','DENY','BLOCKING OWNERSHIP PROVENANCE','Teacher Exact shares 8A Math but cannot change the creator of Teacher A question','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'' where id=''aa000000-0000-0000-0000-000000000001''','select criado_por::text from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R52-QUESTION-COMBINED-TAKEOVER','DENY','BLOCKING OWNERSHIP PROVENANCE','Teacher Exact cannot combine creator takeover with answer-key/text mutation','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'',enunciado=''QA forged question'',resposta_correta=''b'' where id=''aa000000-0000-0000-0000-000000000001''','select criado_por::text||''|''||resposta_correta||''|''||enunciado from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R52-ASSESSMENT-TAKEOVER','DENY','BLOCKING OWNERSHIP PROVENANCE','Teacher Exact cannot take over the creator of a shared assessment','a3000000-0000-0000-0000-000000000005','update public.avaliacoes set criado_por=''a4000000-0000-0000-0000-000000000005'',titulo=''QA forged assessment'' where id=''ac000000-0000-0000-0000-000000000001''','select criado_por::text||''|''||titulo from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R52-ASSESSMENT-POST-EVIDENCE','DENY','BLOCKING ACADEMIC EVIDENCE IMMUTABILITY','Staff cannot change assessment grading configuration after an attempt exists','a3000000-0000-0000-0000-000000000001','update public.avaliacoes set nota_minima=99 where id=''ac000000-0000-0000-0000-000000000001''','select nota_minima::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R52-AQ-POST-EVIDENCE','DENY','BLOCKING ACADEMIC EVIDENCE IMMUTABILITY','Staff cannot reorder assessment questions after an attempt exists','a3000000-0000-0000-0000-000000000001','update public.avaliacao_questoes set ordem=9 where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000001''','select ordem::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R52-MATRICULA-CASCADE','DENY','BLOCKING ACADEMIC EVIDENCE RETENTION','Staff cannot delete a matricula whose attempts would cascade','a3000000-0000-0000-0000-000000000001','delete from public.matriculas where id=''a8000000-0000-0000-0000-000000000003''','select count(*)::text from public.avaliacao_tentativas where matricula_id=''a8000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_dml('R52-USUARIO-CASCADE','DENY','BLOCKING ACADEMIC EVIDENCE RETENTION','Staff cannot delete a student whose attempts would cascade','a3000000-0000-0000-0000-000000000001','delete from public.usuarios where id=''a4000000-0000-0000-0000-000000000012''','select count(*)::text from public.avaliacao_tentativas where usuario_id=''a4000000-0000-0000-0000-000000000012''');
select pg_temp.qa_probe_actor_dml('R52-ASSESSMENT-UNUSED-DELETE','ALLOW','BLOCKING ASSESSMENT DELETE AUTHORITY','Same-tenant staff can delete an assessment with no academic evidence','a3000000-0000-0000-0000-000000000001','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000021''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000021''');
select pg_temp.qa_probe_actor_dml('R52-ASSESSMENT-EVIDENCE-DELETE','DENY','BLOCKING ACADEMIC EVIDENCE RETENTION','Same-tenant staff cannot delete an assessment with attempt evidence','a3000000-0000-0000-0000-000000000001','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R52-QUESTION-EVIDENCE-DELETE','DENY','BLOCKING ACADEMIC EVIDENCE RETENTION','Same-tenant staff cannot delete a question referenced by academic evidence','a3000000-0000-0000-0000-000000000001','delete from public.questoes where id=''aa000000-0000-0000-0000-000000000001''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R52-QUESTION-OWNER-DELETE','DENY','BLOCKING OWNERSHIP DELETE AUTHORITY','Teacher Exact cannot delete an unlinked question owned by Teacher A','a3000000-0000-0000-0000-000000000005','delete from public.questoes where id=''aa000000-0000-0000-0000-000000000008''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000008''');

-- R5.2-B2: every authorization denial below operates on a valid `enviada`
-- dissertative response, with lifecycle no longer able to explain the result.
select pg_temp.qa_probe_actor_rpc('R52-GRADE-POSITIVE','ALLOW','BLOCKING GRADING AUTHORITY','Teacher Exact grades a valid submitted 8A Math response','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,1,''QA R5.2 positive grading'')','select situacao::text||'':''||corrigida::text||'':''||pontos_obtidos::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_probe_actor_rpc('R52-GRADE-STUDENT','DENY','BLOCKING GRADING AUTHORITY','Student cannot grade a valid submitted response','a3000000-0000-0000-0000-000000000012','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,1,''QA student grading'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_probe_actor_rpc('R52-GRADE-REVOKED-TEACHER','DENY','BLOCKING GRADING AUTHORITY','Revoked Teacher A cannot grade a submitted Physics response','a3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000001''::uuid,1,''QA revoked grading'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_rpc('R52-GRADE-WRONG-CLASS','DENY','BLOCKING GRADING AUTHORITY','Teacher Exact cannot grade a submitted 7A Math response','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000004''::uuid,1,''QA wrong class grading'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000004''');
select pg_temp.qa_probe_actor_rpc('R52-GRADE-WRONG-SUBJECT','DENY','BLOCKING GRADING AUTHORITY','Teacher Exact cannot grade a submitted 8A Physics response','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000001''::uuid,1,''QA wrong subject grading'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_rpc('R52-GRADE-TEACHER-B','DENY','BLOCKING GRADING AUTHORITY','Tenant B Teacher cannot grade Tenant A submitted response','b3000000-0000-0000-0000-000000000001','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,1,''QA Teacher B grading'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_probe_actor_rpc('R52-GRADE-STAFF-B','DENY','BLOCKING GRADING AUTHORITY','Tenant B Staff cannot grade Tenant A submitted response','b3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,1,''QA Staff B grading'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_probe_actor_rpc('R52-GRADE-FORGED-ID','DENY','BLOCKING GRADING AUTHORITY','Teacher Exact cannot grade a forged response identifier','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000009999''::uuid,1,''QA forged grading id'')','select count(*)::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000009999''');select pg_temp.qa_probe_actor_rpc_strict('R55-ZERO-ROW-RPC-SELFTEST','INCONCLUSIVE','HARNESS SELF-TEST','A nonexistent grading target must never be recorded as DENY','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000009998''::uuid,1,''QA nonexistent self-test'')','select count(*)::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000009998''');
select case when exists(select 1 from qa_results where id='R55-ZERO-ROW-RPC-SELFTEST' and observed='INCONCLUSIVE') then 1 else 1/(select count(*) from qa_results where id='__R55_ASSERTION_FAILURE__') end;
DELETE FROM qa_results WHERE id='R55-ZERO-ROW-RPC-SELFTEST';
\echo 'R55_ZERO_ROW_RPC_SELFTEST: PASS (observed INCONCLUSIVE)';


-- R4 M1: direct table writes are not a grading path.
select pg_temp.qa_probe_actor_dml('R4-M1-UPDATE-SCORE','DENY','BLOCKING DIRECT GRADING WRITE','Teacher X cannot UPDATE pontos_obtidos directly','a3000000-0000-0000-0000-000000000005','update public.avaliacao_respostas set pontos_obtidos=999 where id=''ae000000-0000-0000-0000-000000000003''','select pontos_obtidos::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_dml('R4-M1-UPDATE-TEXT','DENY','BLOCKING DIRECT GRADING WRITE','Teacher X cannot rewrite resposta_texto directly','a3000000-0000-0000-0000-000000000005','update public.avaliacao_respostas set resposta_texto=''QA forged answer'' where id=''ae000000-0000-0000-0000-000000000003''','select coalesce(resposta_texto,''<NULL>'') from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_dml('R4-M1-UPDATE-ALT','DENY','BLOCKING DIRECT GRADING WRITE','Teacher X cannot rewrite alternativa_id directly','a3000000-0000-0000-0000-000000000005','update public.avaliacao_respostas set alternativa_id=''z'' where id=''ae000000-0000-0000-0000-000000000003''','select coalesce(alternativa_id,''<NULL>'') from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_dml('R4-M1-DELETE','DENY','BLOCKING DIRECT GRADING WRITE','Teacher X cannot DELETE a student response directly','a3000000-0000-0000-0000-000000000005','delete from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''','select count(*)::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R4-M1-RPC-POSITIVE','ALLOW','BLOCKING GRADING RPC','Teacher X can grade the legitimate 8A Math response through the real RPC','a3000000-0000-0000-0000-000000000005','update public.avaliacao_tentativas set situacao=''enviada'',enviada_em=now() where id=''ad000000-0000-0000-0000-000000000001''','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA legitimate grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R4-M1-RPC-NEGATIVE-REVOKED','DENY','BLOCKING GRADING RPC','Teacher A loses the revoked 8A Physics assignment','a3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000001''::uuid,1,''QA revoked grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_rpc('R4-M1-RPC-NEGATIVE-FORGED','DENY','BLOCKING GRADING RPC','Teacher X cannot grade a forged response id','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000009999''::uuid,1,''QA forged id'')','select count(*)::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000009999''');
select pg_temp.qa_probe_actor_rpc('R4-M1-RPC-NEGATIVE-LOW','DENY','BLOCKING GRADING RPC','Teacher X cannot assign negative points','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,-1,''QA negative points'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R4-M1-RPC-NEGATIVE-HIGH','DENY','BLOCKING GRADING RPC','Teacher X cannot assign points above the question maximum','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,999,''QA high points'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');

-- R5 HB3: configuration/master-data is staff-only and course suspension
-- must invalidate downstream Teacher assessment authority transactionally.
create or replace function pg_temp.qa_probe_course_suspension(
  p_id text, p_detail text, p_staff_sub text, p_staff_sql text,
  p_teacher_sub text, p_teacher_sql text, p_assessment_sql text,
  p_state_sql text
) returns void language plpgsql as $$
declare
  v_before text;
  v_after text;
  v_state text := '';
  v_message text := '';
  v_observed text := 'INCONCLUSIVE';
  v_rows integer := 0;
  v_phase text := 'staff';
begin
  reset role;
  execute p_state_sql into v_before;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',p_staff_sub,false);
    execute p_staff_sql;
    get diagnostics v_rows = row_count;
    if v_rows <> 1 then raise exception 'HB3_STAFF_MUTATION_NOT_ALLOWED'; end if;
    v_phase := 'teacher';
    perform set_config('request.jwt.claim.sub',p_teacher_sub,false);
    begin
      execute p_teacher_sql;
      get diagnostics v_rows = row_count;
      if v_rows > 0 then raise exception 'HB3_TEACHER_MUTATION_ALLOWED'; end if;
      raise exception 'HB3_TEACHER_MUTATION_NO_ROW';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
      if v_message = 'HB3_TEACHER_MUTATION_ALLOWED' then
        v_observed := 'FAIL'; raise;
      elsif v_message = 'HB3_TEACHER_MUTATION_NO_ROW' or v_state in ('42501','42503') then
        v_observed := 'PASS';
      else
        v_observed := 'INCONCLUSIVE'; raise;
      end if;
    end;
    v_phase := 'assessment';
    begin
      execute p_assessment_sql;
      get diagnostics v_rows = row_count;
      if v_rows > 0 then raise exception 'HB3_INACTIVE_COURSE_ASSESSMENT_ALLOWED'; end if;
      raise exception 'HB3_INACTIVE_COURSE_ASSESSMENT_NO_ROW';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
      if v_message = 'HB3_INACTIVE_COURSE_ASSESSMENT_ALLOWED' then
        v_observed := 'FAIL'; raise;
      elsif v_message = 'HB3_INACTIVE_COURSE_ASSESSMENT_NO_ROW' or v_state in ('42501','42503') then
        v_observed := 'PASS';
      else
        v_observed := 'INCONCLUSIVE'; raise;
      end if;
    end;
    raise exception using message = '__QA_ROLLBACK__';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
    if v_message = '__QA_ROLLBACK__' and v_observed = 'PASS' then
      NULL;
    elsif v_message in ('HB3_TEACHER_MUTATION_ALLOWED','HB3_INACTIVE_COURSE_ASSESSMENT_ALLOWED','HB3_STAFF_MUTATION_NOT_ALLOWED') then
      v_observed := 'FAIL';
    elsif v_observed <> 'FAIL' then
      v_observed := 'INCONCLUSIVE';
    end if;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,'PASS',v_observed,'BLOCKING ACADEMIC AUTHORITY',v_before,v_after,
    p_detail || ' phase=' || v_phase || ' rows=' || v_rows || ' sqlstate=' || coalesce(v_state,'') || ' message=' || coalesce(v_message,''));
end $$;

select pg_temp.qa_probe_course_suspension(
  'R5-HB3-COURSE-SUSPENSION',
  'Staff A can deactivate Course A; Teacher Exact cannot reactivate it or create an assessment while it is inactive; all state rolls back',
  'a3000000-0000-0000-0000-000000000001',
  'update public.cursos set ativo=false where id=''a5000000-0000-0000-0000-000000000001''',
  'a3000000-0000-0000-0000-000000000005',
  'update public.cursos set ativo=true where id=''a5000000-0000-0000-0000-000000000001''',
  'insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ac300000-0000-0000-0000-000000000010'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000003'',''QA inactive course assessment'',''rascunho'',''a4000000-0000-0000-0000-000000000005'')',
  'select ativo::text from public.cursos where id=''a5000000-0000-0000-0000-000000000001'''
);

select pg_temp.qa_probe_actor_dml('R5-STAFF-COURSE-UPDATE','ALLOW','BLOCKING ACADEMIC AUTHORITY','Staff A can update Course A configuration','a3000000-0000-0000-0000-000000000001','update public.cursos set nome=''QA Course A staff edit'' where id=''a5000000-0000-0000-0000-000000000001''','select nome from public.cursos where id=''a5000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R5-TEACHER-COURSE-UPDATE','DENY','BLOCKING ACADEMIC AUTHORITY','Teacher Exact cannot update Course A configuration','a3000000-0000-0000-0000-000000000005','update public.cursos set nome=''QA Course A teacher edit'' where id=''a5000000-0000-0000-0000-000000000001''','select nome from public.cursos where id=''a5000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R5-STAFF-SUBJECT-UPDATE','ALLOW','BLOCKING ACADEMIC AUTHORITY','Staff A can update Subject A configuration','a3000000-0000-0000-0000-000000000001','update public.disciplinas set nome=''QA Math staff edit'' where id=''a6000000-0000-0000-0000-000000000001''','select nome from public.disciplinas where id=''a6000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R5-TEACHER-SUBJECT-UPDATE','DENY','BLOCKING ACADEMIC AUTHORITY','Teacher Exact cannot update Subject A configuration','a3000000-0000-0000-0000-000000000005','update public.disciplinas set nome=''QA Math teacher edit'' where id=''a6000000-0000-0000-0000-000000000001''','select nome from public.disciplinas where id=''a6000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R5-STAFF-LESSON-INSERT','ALLOW','BLOCKING ACADEMIC AUTHORITY','Staff A can create a catalog lesson','a3000000-0000-0000-0000-000000000001','insert into public.aulas(id,tenant_id,disciplina_id,titulo) values (''c2000000-0000-0000-0000-000000000001'',''a1000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''QA staff lesson'')','select count(*)::text from public.aulas where id=''c2000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R5-TEACHER-LESSON-INSERT','DENY','BLOCKING ACADEMIC AUTHORITY','Teacher Exact cannot create a catalog lesson without a Class binding','a3000000-0000-0000-0000-000000000005','insert into public.aulas(id,tenant_id,disciplina_id,titulo) values (''c2000000-0000-0000-0000-000000000002'',''a1000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''QA teacher lesson'')','select count(*)::text from public.aulas where id=''c2000000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_actor_dml('R5-STAFF-MATERIAL-INSERT','ALLOW','BLOCKING ACADEMIC AUTHORITY','Staff A can create a catalog support material','a3000000-0000-0000-0000-000000000001','insert into public.materiais_apoio(id,tenant_id,disciplina_id,titulo,url) values (''c3000000-0000-0000-0000-000000000001'',''a1000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''QA staff material'',''https://qa.invalid/staff-material'')','select count(*)::text from public.materiais_apoio where id=''c3000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R5-TEACHER-MATERIAL-INSERT','DENY','BLOCKING ACADEMIC AUTHORITY','Teacher Exact cannot create a catalog support material without a Class binding','a3000000-0000-0000-0000-000000000005','insert into public.materiais_apoio(id,tenant_id,disciplina_id,titulo,url) values (''c3000000-0000-0000-0000-000000000002'',''a1000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''QA teacher material'',''https://qa.invalid/teacher-material'')','select count(*)::text from public.materiais_apoio where id=''c3000000-0000-0000-0000-000000000002''');

-- Student answer-key boundaries and the supported submission RPC.
select pg_temp.qa_probe_actor_count('R4-STUDENT-GABARITO-WHERE','DENY','BLOCKING GABARITO CONFIDENTIALITY','Student cannot use a WHERE-clause answer-key oracle','a3000000-0000-0000-0000-000000000012','select count(*) from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000000001'' and gabarito_snapshot <> ''{}''::jsonb','select count(*)::text from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000000001''');select pg_temp.qa_probe_actor_count_strict('R55-WRONG-TARGET-SELFTEST','INCONCLUSIVE','HARNESS SELF-TEST','A nonexistent answer-key target must never be recorded as DENY','a3000000-0000-0000-0000-000000000012','select count(*) from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000009997'' and gabarito_snapshot <> ''{}''::jsonb','select count(*)::text from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000009997''');
select case when exists(select 1 from qa_results where id='R55-WRONG-TARGET-SELFTEST' and observed='INCONCLUSIVE') then 1 else 1/(select count(*) from qa_results where id='__R55_ASSERTION_FAILURE__') end;
DELETE FROM qa_results WHERE id='R55-WRONG-TARGET-SELFTEST';
\echo 'R55_WRONG_TARGET_SELFTEST: PASS (observed INCONCLUSIVE)';

select pg_temp.qa_probe_actor_count('R4-STUDENT-GABARITO-STAR','DENY','BLOCKING GABARITO CONFIDENTIALITY','Student cannot whole-row SELECT an attempt containing gabarito_snapshot','a3000000-0000-0000-0000-000000000012','select count(*) from (select t as whole_row from public.avaliacao_tentativas t where t.id=''ad000000-0000-0000-0000-000000000001'') x','select count(*)::text from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_rpc_no_gabarito('R4-STUDENT-SUBMISSION-RPC','ALLOW_NO_GABARITO','BLOCKING GABARITO CONFIDENTIALITY','Student submission RPC returns no gabarito_snapshot','a3000000-0000-0000-0000-000000000012','select public.enviar_tentativa_avaliacao(''ad000000-0000-0000-0000-000000000001''::uuid,''[{"questao_id":"aa000000-0000-0000-0000-000000000001","alternativa_id":"a"}]''::jsonb)','select situacao::text||'':''||coalesce(nota::text,''NULL'') from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000000001''');

-- R5.1-B1: DELETE cannot cross creator authority and cannot cascade
-- attempts/responses once academic evidence exists.
select pg_temp.qa_probe_actor_dml('R51-B1-TEACHER-Y-EVIDENCE','DENY','BLOCKING ASSESSMENT DELETE AUTHORITY','Teacher A has the exact 7A Math assignment but cannot delete Teacher Y assessment with evidence','a3000000-0000-0000-0000-000000000002','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000008''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000008''');
select pg_temp.qa_probe_actor_dml('R51-B1-OWN-ATTEMPT','DENY','BLOCKING ASSESSMENT DELETE AUTHORITY','Teacher A cannot delete its own assessment after a Student attempt exists','a3000000-0000-0000-0000-000000000002','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000009''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000009''');
select pg_temp.qa_probe_actor_dml('R51-B1-OWN-RESPONSE','DENY','BLOCKING ASSESSMENT DELETE AUTHORITY','Teacher A cannot delete its own assessment after Student response evidence exists','a3000000-0000-0000-0000-000000000002','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R51-B1-REVOKED','DENY','BLOCKING ASSESSMENT DELETE AUTHORITY','Revoked Teacher A cannot delete an assessment in the revoked Physics scope','a3000000-0000-0000-0000-000000000002','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000012''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000012''');
select pg_temp.qa_probe_actor_dml('R51-B1-WRONG-SUBJECT','DENY','BLOCKING ASSESSMENT DELETE AUTHORITY','Teacher Exact 8A Math cannot delete an 8A Physics assessment','a3000000-0000-0000-0000-000000000005','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000012''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000012''');
select pg_temp.qa_probe_actor_dml('R51-B1-STAFF-EVIDENCE','DENY','BLOCKING ASSESSMENT EVIDENCE RETENTION','Staff A cannot physically delete an assessment whose attempt evidence would cascade','a3000000-0000-0000-0000-000000000001','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R51-B1-STUDENT-DELETE','DENY','BLOCKING ASSESSMENT DELETE AUTHORITY','Student cannot delete a Teacher A assessment even when it has no response yet','a3000000-0000-0000-0000-000000000012','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000009''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000009''');
select pg_temp.qa_probe_actor_dml('R51-B1-CROSS-TENANT','DENY','BLOCKING ASSESSMENT DELETE AUTHORITY','Tenant B staff cannot delete a Tenant A assessment','b3000000-0000-0000-0000-000000000002','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000011''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000011''');
select pg_temp.qa_probe_actor_dml_setup('R51-B1-OWN-UNUSED','ALLOW','BLOCKING ASSESSMENT DELETE AUTHORITY','Teacher A may delete its own unused assessment; no evidence is cascaded','a3000000-0000-0000-0000-000000000002','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ac000000-0000-0000-0000-000000000013'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000003'',''QA R5.1 own unused'',''rascunho'',''a4000000-0000-0000-0000-000000000002'')','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000013''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000013''');

-- R5.1-B2: only a submitted attempt is gradeable. Student submission remains
-- the supported path from em_andamento to enviada after teacher denial.
select pg_temp.qa_probe_actor_rpc('R51-B2-IN-PROGRESS','DENY','BLOCKING GRADING LIFECYCLE','Teacher A cannot grade a response while the attempt is still em_andamento','a3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA R5.1 in-progress deny'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R51-B2-SUBMITTED-POSITIVE','ALLOW','BLOCKING GRADING LIFECYCLE','Teacher A can grade the same response after its source state is submitted','a3000000-0000-0000-0000-000000000002','update public.avaliacao_tentativas set situacao=''enviada'',enviada_em=now() where id=''ad000000-0000-0000-0000-000000000001''','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA R5.1 submitted allow'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R51-B2-ALREADY-CORRECTED','DENY','BLOCKING GRADING LIFECYCLE','Already corrected attempt is not re-graded by the RPC','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000006''::uuid,1,''QA R5.1 corrected deny'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000006''');
select pg_temp.qa_probe_actor_rpc('R51-B2-INACTIVE-TEACHER','DENY','BLOCKING GRADING LIFECYCLE','Inactive Teacher A2 cannot grade a response','a3000000-0000-0000-0000-000000000003','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA R5.1 inactive teacher deny'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R51-B2-INACTIVE-CLASS','DENY','BLOCKING GRADING LIFECYCLE','Teacher cannot grade while the assigned Class is inactive','a3000000-0000-0000-0000-000000000005','update public.turmas set ativa=false where id=''a7000000-0000-0000-0000-000000000003''','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA R5.1 inactive class deny'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R51-B2-NEGATIVE-LOW','DENY','BLOCKING GRADING LIFECYCLE','Submitted Teacher response rejects negative points','a3000000-0000-0000-0000-000000000005','update public.avaliacao_tentativas set situacao=''enviada'',enviada_em=now() where id=''ad000000-0000-0000-0000-000000000001''','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,-1,''QA R5.1 negative points'')','select situacao::text||'':''||corrigida::text||'':''||pontos_obtidos::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R51-B2-NEGATIVE-HIGH','DENY','BLOCKING GRADING LIFECYCLE','Submitted Teacher response rejects points above the question maximum','a3000000-0000-0000-0000-000000000005','update public.avaliacao_tentativas set situacao=''enviada'',enviada_em=now() where id=''ad000000-0000-0000-0000-000000000001''','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,999,''QA R5.1 high points'')','select situacao::text||'':''||corrigida::text||'':''||pontos_obtidos::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R51-B2-STUDENT-SUBMIT','ALLOW','BLOCKING GRADING LIFECYCLE','Student can submit the in-progress attempt after the teacher grading attempt was denied','a3000000-0000-0000-0000-000000000012','','select public.enviar_tentativa_avaliacao(''ad000000-0000-0000-0000-000000000001''::uuid,''[{"questao_id":"aa000000-0000-0000-0000-000000000001","alternativa_id":"a"}]''::jsonb)','select situacao::text||'':''||coalesce(nota::text,''NULL'') from public.avaliacao_tentativas where id=''ad000000-0000-0000-0000-000000000001''');

-- Explicit direct RPC probes for current runtime ACL and student same-course eligibility.
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
select pg_temp.qa_probe_count('RPC-minhas-turmas-professor','ALLOW','CURRENT REPOSITORY CONTRACT','Teacher RPC is class/course-only and does not return Subject/assignment context','select count(*) from public.minhas_turmas_professor()');
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000010',false);
select pg_temp.qa_probe_rpc('RPC-student-start-wrong-class','DENY','CURRENT REPOSITORY CONTRACT','Student 7A can attempt an 8A evaluation from the same Course because start RPC checks Course but not Class','select public.iniciar_tentativa_avaliacao(''ac000000-0000-0000-0000-000000000001''::uuid,''a8000000-0000-0000-0000-000000000001''::uuid)');


-- R5.2-B4: schema provenance and runtime attempts for both application roles.
select pg_temp.qa_record('R52-TRUNCATE-ACL','ALLOW',case when
  has_table_privilege('anon','public.avaliacao_respostas','TRUNCATE') = false
  and has_table_privilege('authenticated','public.avaliacao_respostas','TRUNCATE') = false
  and has_table_privilege('anon','public.avaliacao_tentativas','TRUNCATE') = false
  and has_table_privilege('authenticated','public.avaliacao_tentativas','TRUNCATE') = false
  and has_table_privilege('anon','public.avaliacoes','TRUNCATE') = false
  and has_table_privilege('authenticated','public.avaliacoes','TRUNCATE') = false
then 'ALLOW' else 'DENY' end,'BLOCKING TRUNCATE ACL','', '', 'TRUNCATE is absent for anon/authenticated on evidence tables');
select pg_temp.qa_probe_actor_truncate('R52-TRUNCATE-AUTH-RESP','DENY','BLOCKING TRUNCATE ACL','authenticated cannot truncate response evidence','authenticated','avaliacao_respostas','select count(*)::text from public.avaliacao_respostas');
select pg_temp.qa_probe_actor_truncate('R52-TRUNCATE-ANON-RESP','DENY','BLOCKING TRUNCATE ACL','anon cannot truncate response evidence','anon','avaliacao_respostas','select count(*)::text from public.avaliacao_respostas');
select pg_temp.qa_probe_actor_truncate('R52-TRUNCATE-AUTH-ATTEMPT','DENY','BLOCKING TRUNCATE ACL','authenticated cannot truncate attempt evidence','authenticated','avaliacao_tentativas','select count(*)::text from public.avaliacao_tentativas');
select pg_temp.qa_probe_actor_truncate('R52-TRUNCATE-ANON-ASSESSMENT','DENY','BLOCKING TRUNCATE ACL','anon cannot truncate assessments','anon','avaliacoes','select count(*)::text from public.avaliacoes');


-- ---------------------------------------------------------------------------
-- R5.3 normal assertions: C1/C2/H2/H3/H4
-- ---------------------------------------------------------------------------
-- C1: exercise both SECURITY DEFINER student RPCs against production-named
-- pg_temp shadows. Unexpected errors remain INCONCLUSIVE.
DO $$
DECLARE
  v_json jsonb;
  v_state text := '';
  v_message text := '';
  v_observed text;
BEGIN
  RESET ROLE;
  CREATE TEMP TABLE avaliacoes (LIKE public.avaliacoes INCLUDING DEFAULTS);
  CREATE TEMP TABLE matriculas (LIKE public.matriculas INCLUDING DEFAULTS);
  CREATE TEMP TABLE avaliacao_questoes (LIKE public.avaliacao_questoes INCLUDING DEFAULTS);
  CREATE TEMP TABLE questoes (LIKE public.questoes INCLUDING DEFAULTS);
  CREATE TEMP TABLE avaliacao_tentativas (LIKE public.avaliacao_tentativas INCLUDING DEFAULTS);
  CREATE TEMP TABLE avaliacao_respostas (LIKE public.avaliacao_respostas INCLUDING DEFAULTS);
  CREATE UNIQUE INDEX sc004_r53_temp_resp_uq ON avaliacao_respostas(tentativa_id, questao_id);

  INSERT INTO avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,nota_minima,criado_por)
  VALUES ('c1000000-0000-0000-0000-000000000101','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','R53 pg_temp assessment','publicada',60,'a4000000-0000-0000-0000-000000000002');
  INSERT INTO matriculas(id,tenant_id,usuario_id,curso_id,turma_id,unidade_id,situacao)
  VALUES ('c2000000-0000-0000-0000-000000000101','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000012','a5000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','a2000000-0000-0000-0000-000000000001','ativa');
  INSERT INTO questoes(id,tenant_id,disciplina_id,enunciado,tipo,alternativas,resposta_correta,pontos,criado_por)
  VALUES ('c3000000-0000-0000-0000-000000000101','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','R53 forged question','objetiva','[{"id":"a"},{"id":"b"}]','b',9,'a4000000-0000-0000-0000-000000000002');
  INSERT INTO avaliacao_questoes(avaliacao_id,questao_id,ordem,tenant_id)
  VALUES ('c1000000-0000-0000-0000-000000000101','c3000000-0000-0000-0000-000000000101',1,'a1000000-0000-0000-0000-000000000001');

  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000012',false);
    SELECT public.iniciar_tentativa_avaliacao('c1000000-0000-0000-0000-000000000101'::uuid,'c2000000-0000-0000-0000-000000000101'::uuid) INTO v_json;
    v_observed := CASE WHEN v_json ? 'gabarito_snapshot' THEN 'GABARITO_LEAK' ELSE 'ALLOW' END;
    RAISE EXCEPTION USING message='__QA_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE,v_message=MESSAGE_TEXT;
    IF v_message <> '__QA_ROLLBACK__' THEN
      v_observed := CASE WHEN v_state IN ('42501','42503') OR v_message IN ('Avaliação não encontrada','Matrícula inválida para esta avaliação') THEN 'DENY' ELSE 'INCONCLUSIVE' END;
    END IF;
  END;
  RESET ROLE;
  PERFORM pg_temp.qa_record('R53-C1-START-SHADOW','DENY',v_observed,'BLOCKING SECURITY DEFINER SHADOW','','','Student cannot start through pg_temp shadow; sqlstate='||v_state||' message='||v_message);

  TRUNCATE TABLE avaliacoes,matriculas,avaliacao_questoes,questoes,avaliacao_tentativas,avaliacao_respostas;
  INSERT INTO avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,nota_minima,criado_por)
  VALUES ('c1000000-0000-0000-0000-000000000102','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000003','R53 forged grading','publicada',60,'a4000000-0000-0000-0000-000000000002');
  INSERT INTO avaliacao_tentativas(id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,situacao,questoes_ordem,gabarito_snapshot,nota_maxima)
  VALUES ('c4000000-0000-0000-0000-000000000101','a1000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000102','c2000000-0000-0000-0000-000000000101','a4000000-0000-0000-0000-000000000012',1,'em_andamento','[{"questao_id":"c3000000-0000-0000-0000-000000000102","pontos":9}]','{"c3000000-0000-0000-0000-000000000102":"b"}',9);
  INSERT INTO avaliacao_respostas(id,tenant_id,tentativa_id,questao_id)
  VALUES ('c5000000-0000-0000-0000-000000000101','a1000000-0000-0000-0000-000000000001','c4000000-0000-0000-0000-000000000101','c3000000-0000-0000-0000-000000000102');
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000012',false);
    SELECT public.enviar_tentativa_avaliacao('c4000000-0000-0000-0000-000000000101'::uuid,'[{"questao_id":"c3000000-0000-0000-0000-000000000102","alternativa_id":"b"}]'::jsonb) INTO v_json;
    v_observed := CASE WHEN v_json->>'nota' = '9.00' THEN 'GABARITO_LEAK' ELSE 'ALLOW' END;
    RAISE EXCEPTION USING message='__QA_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE,v_message=MESSAGE_TEXT;
    IF v_message <> '__QA_ROLLBACK__' THEN
      v_observed := CASE WHEN v_state IN ('42501','42503') OR v_message IN ('Tentativa não encontrada','Tentativa já enviada') THEN 'DENY' ELSE 'INCONCLUSIVE' END;
    END IF;
  END;
  RESET ROLE;
  PERFORM pg_temp.qa_record('R53-C1-SUBMIT-SHADOW','DENY',v_observed,'BLOCKING SECURITY DEFINER SHADOW','','','Student cannot submit forged pg_temp grading; sqlstate='||v_state||' message='||v_message);
  DROP TABLE IF EXISTS avaliacao_respostas, avaliacao_tentativas, questoes, avaliacao_questoes, matriculas, avaliacoes;
END
$$;


-- The exploit probes above are paired with a direct catalog invariant so a
-- mutation that only restores search_path=public cannot survive silently.
SELECT pg_temp.qa_record(
  'R53-C1-CONFIG-START','SAFE',
  CASE WHEN EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.oid = 'public.iniciar_tentativa_avaliacao(uuid,uuid)'::regprocedure
      AND COALESCE(array_to_string(p.proconfig,','),'') LIKE '%search_path=""%'
  ) THEN 'SAFE' ELSE 'UNSAFE' END,
  'BLOCKING SECURITY DEFINER SHADOW','','',
  'iniciar_tentativa_avaliacao has search_path=""'
);
SELECT pg_temp.qa_record(
  'R53-C1-CONFIG-SUBMIT','SAFE',
  CASE WHEN EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.oid = 'public.enviar_tentativa_avaliacao(uuid,jsonb)'::regprocedure
      AND COALESCE(array_to_string(p.proconfig,','),'') LIKE '%search_path=""%'
  ) THEN 'SAFE' ELSE 'UNSAFE' END,
  'BLOCKING SECURITY DEFINER SHADOW','','',
  'enviar_tentativa_avaliacao has search_path=""'
);

SELECT pg_temp.qa_record(
  'R54-C1-BUILTIN-BINDING','SAFE',
  CASE WHEN (
    SELECT pg_get_functiondef('public.iniciar_tentativa_avaliacao(uuid,uuid)'::regprocedure)
      LIKE '%v_usuario_id pg_catalog.uuid%'
      AND pg_get_functiondef('public.iniciar_tentativa_avaliacao(uuid,uuid)'::regprocedure)
        LIKE '%pg_catalog.jsonb_array_elements%'
      AND pg_get_functiondef('public.enviar_tentativa_avaliacao(uuid,jsonb)'::regprocedure)
        LIKE '%v_item pg_catalog.jsonb%'
      AND pg_get_functiondef('public.enviar_tentativa_avaliacao(uuid,jsonb)'::regprocedure)
        LIKE '%v_pontos pg_catalog.numeric%'
  ) THEN 'SAFE' ELSE 'UNSAFE' END,
  'BLOCKING SECURITY DEFINER SHADOW','','',
  'C1 built-in types and array/json functions are explicitly bound to pg_catalog'
);

CREATE OR REPLACE FUNCTION pg_temp.qa_probe_l4_execute(p_id text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_assignment text := 'public.sc004_assignment_lifecycle()';
  v_parent text := 'public.sc004_validate_parent_integrity()';
  v_observed text;
  v_detail text;
BEGIN
  v_observed := CASE WHEN
    NOT has_function_privilege('public',v_assignment,'EXECUTE')
    AND NOT has_function_privilege('anon',v_assignment,'EXECUTE')
    AND NOT has_function_privilege('authenticated',v_assignment,'EXECUTE')
    AND NOT has_function_privilege('service_role',v_assignment,'EXECUTE')
    AND NOT has_function_privilege('public',v_parent,'EXECUTE')
    AND NOT has_function_privilege('anon',v_parent,'EXECUTE')
    AND NOT has_function_privilege('authenticated',v_parent,'EXECUTE')
    AND NOT has_function_privilege('service_role',v_parent,'EXECUTE')
    THEN 'DENY' ELSE 'ALLOW' END;
  v_detail := format('effective execute assignment public=%s anon=%s authenticated=%s service_role=%s; parent public=%s anon=%s authenticated=%s service_role=%s',
    has_function_privilege('public',v_assignment,'EXECUTE'),has_function_privilege('anon',v_assignment,'EXECUTE'),
    has_function_privilege('authenticated',v_assignment,'EXECUTE'),has_function_privilege('service_role',v_assignment,'EXECUTE'),
    has_function_privilege('public',v_parent,'EXECUTE'),has_function_privilege('anon',v_parent,'EXECUTE'),
    has_function_privilege('authenticated',v_parent,'EXECUTE'),has_function_privilege('service_role',v_parent,'EXECUTE'));
  PERFORM pg_temp.qa_record(p_id,'DENY',v_observed,'BLOCKING TRIGGER FUNCTION EXECUTE ACL','','',v_detail);
END
$$;
SELECT pg_temp.qa_probe_l4_execute('R54-L4-TRIGGER-EXECUTE');

-- C2: inventory and runtime attacks. These are explicit checks, not RLS claims.
SELECT pg_temp.qa_record(
  'R53-C2-ACL-INVENTORY','ALLOW',
  CASE WHEN bool_and(
    has_table_privilege('anon','public.'||t,'TRUNCATE') = false AND
    has_table_privilege('authenticated','public.'||t,'TRUNCATE') = false AND
    has_table_privilege('anon','public.'||t,'TRIGGER') = false AND
    has_table_privilege('authenticated','public.'||t,'TRIGGER') = false AND
    has_table_privilege('anon','public.'||t,'REFERENCES') = false AND
    has_table_privilege('authenticated','public.'||t,'REFERENCES') = false
  ) THEN 'ALLOW' ELSE 'DENY' END,
  'BLOCKING TRUNCATE ACL', '', '',
  'School Core anon/authenticated TRUNCATE/TRIGGER/REFERENCES inventory'
)
FROM unnest(ARRAY[
  'tenants','unidades','cursos','disciplinas','turmas','usuarios','matriculas',
  'professores_turmas','atribuicoes_academicas_professor','registros_aula','presencas',
  'materiais_professor','avisos_turma','questoes','avaliacoes','avaliacao_questoes',
  'avaliacao_tentativas','avaliacao_respostas'
]) AS t;
select pg_temp.qa_probe_actor_truncate('R53-C2-AUTH-RESP','DENY','BLOCKING TRUNCATE ACL','authenticated cannot truncate response evidence','authenticated','avaliacao_respostas','select count(*)::text from public.avaliacao_respostas');
select pg_temp.qa_probe_actor_truncate('R53-C2-ANON-RESP','DENY','BLOCKING TRUNCATE ACL','anon cannot truncate response evidence','anon','avaliacao_respostas','select count(*)::text from public.avaliacao_respostas');
select pg_temp.qa_probe_actor_truncate('R53-C2-AUTH-ATTEMPT','DENY','BLOCKING TRUNCATE ACL','authenticated cannot truncate attempt evidence','authenticated','avaliacao_tentativas','select count(*)::text from public.avaliacao_tentativas');
select pg_temp.qa_probe_actor_truncate('R53-C2-ANON-ASSESSMENT','DENY','BLOCKING TRUNCATE ACL','anon cannot truncate assessments','anon','avaliacoes','select count(*)::text from public.avaliacoes');
select pg_temp.qa_probe_actor_truncate('R53-C2-AUTH-COMPOSITION','DENY','BLOCKING TRUNCATE ACL','authenticated cannot truncate assessment composition','authenticated','avaliacao_questoes','select count(*)::text from public.avaliacao_questoes');
select pg_temp.qa_probe_actor_truncate('R53-C2-AUTH-ASSIGNMENT','DENY','BLOCKING TRUNCATE ACL','authenticated cannot truncate assignments','authenticated','atribuicoes_academicas_professor','select count(*)::text from public.atribuicoes_academicas_professor');
select pg_temp.qa_probe_actor_truncate('R53-C2-AUTH-PRESENCE','DENY','BLOCKING TRUNCATE ACL','authenticated cannot truncate attendance','authenticated','presencas','select count(*)::text from public.presencas');



-- Point-bound cleanup: this response is seeded as enviada and is reached by
-- Teacher Exact's valid 8A + Math assignment before bounds are evaluated.
select pg_temp.qa_probe_actor_rpc('R53-POINT-LOW','DENY','BLOCKING GRADING POINT BOUNDS','Authorized Teacher Exact rejects negative points on an already submitted response','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,-1,''R53 negative points'')','select situacao::text||'':''||corrigida::text||'':''||coalesce(pontos_obtidos::text,''NULL'') from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_probe_actor_rpc('R53-POINT-HIGH','DENY','BLOCKING GRADING POINT BOUNDS','Authorized Teacher Exact rejects points slightly above the question maximum on an already submitted response','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,2,''R53 high points'')','select situacao::text||'':''||corrigida::text||'':''||coalesce(pontos_obtidos::text,''NULL'') from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_probe_actor_rpc('R53-POINT-VALID','ALLOW','BLOCKING GRADING POINT BOUNDS','Authorized Teacher Exact accepts an in-range point value on an already submitted response','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,1,''R53 valid points'')','select situacao::text||'':''||corrigida::text||'':''||coalesce(pontos_obtidos::text,''NULL'') from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_probe_actor_rpc('R53-POINT-ZERO','ALLOW','BLOCKING GRADING POINT BOUNDS','Authorized Teacher Exact accepts zero points on an already submitted response','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,0,''R53 zero points'')','select situacao::text||'':''||corrigida::text||'':''||coalesce(pontos_obtidos::text,''NULL'') from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');

-- X7b: direct privileged maintenance invariant. RLS is not used as evidence;
-- trigger relation, timing, event and function target are checked before the
-- behavioral denial probe; a same-name wrong-event trigger must be detected.
CREATE OR REPLACE FUNCTION pg_temp.qa_probe_evidence_trigger(p_id text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_catalog boolean;
  v_before text;
  v_after text;
  v_state text := '';
  v_message text := '';
  v_observed text := 'INCONCLUSIVE';
BEGIN
  RESET ROLE;
  SELECT EXISTS (
    SELECT 1
    FROM pg_trigger t
    WHERE t.tgrelid='public.avaliacoes'::regclass
      AND t.tgname='trg_sc004_assessment_evidence_delete'
      AND t.tgenabled='O'
      AND (t.tgtype & 2) = 2
      AND (t.tgtype & 8) = 8
      AND (t.tgtype & 4) = 0
      AND (t.tgtype & 16) = 0
      AND (t.tgtype & 32) = 0
      AND t.tgfoid='public.sc004_block_assessment_evidence_delete()'::regprocedure
  ) INTO v_catalog;
  DROP TABLE IF EXISTS pg_temp.qa_x7b_probe;
  CREATE TEMP TABLE qa_x7b_probe(id uuid PRIMARY KEY) ON COMMIT DROP;
  INSERT INTO qa_x7b_probe VALUES ('ac000000-0000-0000-0000-000000000009');
  CREATE TRIGGER qa_x7b_evidence_guard
    BEFORE DELETE ON qa_x7b_probe
    FOR EACH ROW EXECUTE FUNCTION public.sc004_block_assessment_evidence_delete();
  SELECT count(*)::text INTO v_before FROM qa_x7b_probe;
  BEGIN
    DELETE FROM qa_x7b_probe WHERE id='ac000000-0000-0000-0000-000000000009';
    RAISE EXCEPTION USING message='__QA_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE,v_message=MESSAGE_TEXT;
    IF v_message <> '__QA_ROLLBACK__' THEN
      IF v_state='42501' AND v_message='Avaliação com evidência acadêmica não pode ser excluída fisicamente' THEN
        v_observed := CASE WHEN v_catalog THEN 'PRESENT' ELSE 'ABSENT' END;
      ELSE
        v_observed := 'INCONCLUSIVE';
      END IF;
    END IF;
  END;
  SELECT count(*)::text INTO v_after FROM qa_x7b_probe;
  IF v_before IS DISTINCT FROM v_after THEN v_observed := 'STATE_CHANGED'; END IF;
  IF NOT v_catalog THEN v_observed := 'ABSENT'; END IF;
  PERFORM pg_temp.qa_record(p_id,'PRESENT',v_observed,'BLOCKING ACADEMIC EVIDENCE RETENTION',v_before,v_after,
    'catalog='||v_catalog||' sqlstate='||v_state||' message='||v_message);
END
$$;
select pg_temp.qa_probe_evidence_trigger('R53-X7B-TRIGGER');

-- H2: assessment composition belongs to its creator before evidence.
reset role;
insert into public.questoes(id,tenant_id,disciplina_id,enunciado,tipo,alternativas,resposta_correta,criado_por)
values ('aa000000-0000-0000-0000-000000000009','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','R53 Teacher A pre-evidence question','objetiva','[{"id":"a"},{"id":"b"}]','a','a4000000-0000-0000-0000-000000000002'),
       ('aa000000-0000-0000-0000-000000000010','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','R53 Teacher B composition question','objetiva','[{"id":"a"},{"id":"b"}]','a','a4000000-0000-0000-0000-000000000005');
insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem,tenant_id)
values ('ac000000-0000-0000-0000-000000000011','aa000000-0000-0000-0000-000000000009',1,'a1000000-0000-0000-0000-000000000001');
select pg_temp.qa_probe_actor_dml_strict('R53-H2-INSERT','DENY','BLOCKING COMPOSITION OWNERSHIP','Teacher B cannot add a question to Teacher A pre-evidence assessment','a3000000-0000-0000-0000-000000000005','insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem,tenant_id) values (''ac000000-0000-0000-0000-000000000011'',''aa000000-0000-0000-0000-000000000010'',2,''a1000000-0000-0000-0000-000000000001'')','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000011''');
select pg_temp.qa_probe_actor_dml_strict('R53-H2-REORDER','DENY','BLOCKING COMPOSITION OWNERSHIP','Teacher B cannot reorder Teacher A pre-evidence assessment','a3000000-0000-0000-0000-000000000005','update public.avaliacao_questoes set ordem=2 where avaliacao_id=''ac000000-0000-0000-0000-000000000011'' and questao_id=''aa000000-0000-0000-0000-000000000009''','select ordem::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000011'' and questao_id=''aa000000-0000-0000-0000-000000000009''');
select pg_temp.qa_probe_actor_dml_strict('R53-H2-DELETE','DENY','BLOCKING COMPOSITION OWNERSHIP','Teacher B cannot remove a question from Teacher A pre-evidence assessment','a3000000-0000-0000-0000-000000000005','delete from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000011'' and questao_id=''aa000000-0000-0000-0000-000000000009''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000011'' and questao_id=''aa000000-0000-0000-0000-000000000009''');


-- Explicit positive contract: the assessment creator retains composition control.
reset role;
insert into public.questoes(id,tenant_id,disciplina_id,enunciado,tipo,alternativas,resposta_correta,criado_por)
values ('aa000000-0000-0000-0000-000000000011','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','R53 Teacher A owner question','objetiva','[{"id":"a"}]','a','a4000000-0000-0000-0000-000000000002');
select pg_temp.qa_probe_actor_dml_strict('R53-H2-OWNER-INSERT','ALLOW','POSITIVE OWNER COMPOSITION','Teacher A can add its own question to its unused assessment','a3000000-0000-0000-0000-000000000002','insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem,tenant_id) values (''ac000000-0000-0000-0000-000000000011'',''aa000000-0000-0000-0000-000000000011'',2,''a1000000-0000-0000-0000-000000000001'')','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000011'' and questao_id=''aa000000-0000-0000-0000-000000000011''');
select pg_temp.qa_probe_actor_dml_strict('R53-H2-OWNER-REORDER','ALLOW','POSITIVE OWNER COMPOSITION','Teacher A can reorder its unused assessment','a3000000-0000-0000-0000-000000000002','update public.avaliacao_questoes set ordem=2 where avaliacao_id=''ac000000-0000-0000-0000-000000000011'' and questao_id=''aa000000-0000-0000-0000-000000000009''','select ordem::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000011'' and questao_id=''aa000000-0000-0000-0000-000000000009''');
select pg_temp.qa_probe_actor_dml_strict('R53-H2-OWNER-DELETE','ALLOW','POSITIVE OWNER COMPOSITION','Teacher A can remove a question from its unused assessment','a3000000-0000-0000-0000-000000000002','delete from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000011'' and questao_id=''aa000000-0000-0000-0000-000000000009''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000011'' and questao_id=''aa000000-0000-0000-0000-000000000009''');

-- H3: unused/pre-evidence provenance and content are immutable for Teacher B.
select pg_temp.qa_probe_actor_dml_strict('R53-H3-A-CREATOR','DENY','BLOCKING OWNERSHIP PROVENANCE','Teacher B cannot take over assessment creator','a3000000-0000-0000-0000-000000000005','update public.avaliacoes set criado_por=''a4000000-0000-0000-0000-000000000005'' where id=''ac000000-0000-0000-0000-000000000011''','select criado_por::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000011''');
select pg_temp.qa_probe_actor_dml_strict('R53-H3-A-TITLE','DENY','BLOCKING OWNERSHIP PROVENANCE','Teacher B cannot combine assessment takeover with title mutation','a3000000-0000-0000-0000-000000000005','update public.avaliacoes set criado_por=''a4000000-0000-0000-0000-000000000005'',titulo=''R53 forged title'' where id=''ac000000-0000-0000-0000-000000000011''','select criado_por::text||''|''||titulo from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000011''');
select pg_temp.qa_probe_actor_dml_strict('R53-H3-A-KEY','DENY','BLOCKING OWNERSHIP PROVENANCE','Teacher B cannot combine assessment takeover with grading configuration mutation','a3000000-0000-0000-0000-000000000005','update public.avaliacoes set criado_por=''a4000000-0000-0000-0000-000000000005'',nota_minima=55 where id=''ac000000-0000-0000-0000-000000000011''','select criado_por::text||''|''||nota_minima::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000011''');
select pg_temp.qa_probe_actor_dml_strict('R53-H3-A-LIFECYCLE','DENY','BLOCKING OWNERSHIP PROVENANCE','Teacher B cannot combine assessment takeover with lifecycle mutation','a3000000-0000-0000-0000-000000000005','update public.avaliacoes set criado_por=''a4000000-0000-0000-0000-000000000005'',situacao=''publicada'' where id=''ac000000-0000-0000-0000-000000000011''','select criado_por::text||''|''||situacao::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000011''');
select pg_temp.qa_probe_actor_dml_strict('R53-H3-Q-CREATOR','DENY','BLOCKING OWNERSHIP PROVENANCE','Teacher B cannot take over pre-evidence question creator','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'' where id=''aa000000-0000-0000-0000-000000000009''','select criado_por::text from public.questoes where id=''aa000000-0000-0000-0000-000000000009''');
select pg_temp.qa_probe_actor_dml_strict('R53-H3-Q-TEXT','DENY','BLOCKING OWNERSHIP PROVENANCE','Teacher B cannot combine question takeover with text mutation','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'',enunciado=''R53 forged text'' where id=''aa000000-0000-0000-0000-000000000009''','select criado_por::text||''|''||enunciado from public.questoes where id=''aa000000-0000-0000-0000-000000000009''');
select pg_temp.qa_probe_actor_dml_strict('R53-H3-Q-KEY','DENY','BLOCKING OWNERSHIP PROVENANCE','Teacher B cannot combine question takeover with answer-key mutation','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'',resposta_correta=''b'' where id=''aa000000-0000-0000-0000-000000000009''','select criado_por::text||''|''||resposta_correta from public.questoes where id=''aa000000-0000-0000-0000-000000000009''');
select pg_temp.qa_probe_actor_dml_strict('R53-H3-Q-LIFECYCLE','DENY','BLOCKING OWNERSHIP PROVENANCE','Teacher B cannot combine question takeover with active lifecycle mutation','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'',ativa=false where id=''aa000000-0000-0000-0000-000000000009''','select criado_por::text||''|''||ativa::text from public.questoes where id=''aa000000-0000-0000-0000-000000000009''');

-- H4: Staff A cannot address any Tenant B assignment operation.
select pg_temp.qa_probe_actor_count('R53-H4-SELECT','DENY','BLOCKING STAFF TENANT BOUNDARY','Staff A cannot select Tenant B assignment','a3000000-0000-0000-0000-000000000001','select count(*) from public.atribuicoes_academicas_professor where id=''bb100000-0000-0000-0000-000000000001''','select count(*)::text from public.atribuicoes_academicas_professor where id=''bb100000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml_strict('R53-H4-INSERT','DENY','BLOCKING STAFF TENANT BOUNDARY','Staff A cannot insert otherwise-valid Tenant B assignment','a3000000-0000-0000-0000-000000000001','insert into public.atribuicoes_academicas_professor(id,tenant_id,professor_id,turma_id,disciplina_id) values (''c8000000-0000-0000-0000-000000000002'',''b1000000-0000-0000-0000-000000000001'',''b4000000-0000-0000-0000-000000000001'',''b7000000-0000-0000-0000-000000000001'',''b6000000-0000-0000-0000-000000000002'')','select count(*)::text from public.tenants where id=''b1000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml_strict('R53-H4-UPDATE','DENY','BLOCKING STAFF TENANT BOUNDARY','Staff A cannot update Tenant B assignment','a3000000-0000-0000-0000-000000000001','update public.atribuicoes_academicas_professor set ativo=false where id=''bb100000-0000-0000-0000-000000000001''','select ativo::text from public.atribuicoes_academicas_professor where id=''bb100000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml_strict('R53-H4-DELETE','DENY','BLOCKING STAFF TENANT BOUNDARY','Staff A cannot delete Tenant B assignment','a3000000-0000-0000-0000-000000000001','delete from public.atribuicoes_academicas_professor where id=''bb100000-0000-0000-0000-000000000001''','select count(*)::text from public.atribuicoes_academicas_professor where id=''bb100000-0000-0000-0000-000000000001''');


-- M1/R5.3: real concurrent submission regression. The helper creates a fresh
-- em_andamento attempt, sends two requests through two real PostgreSQL backend
-- sessions, and accepts only one success plus one lifecycle denial.
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE OR REPLACE FUNCTION pg_temp.qa_dblink_conninfo()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_password text := nullif(current_setting('kora.ci.dblink_password', true), '');
  v_host text := coalesce(nullif(current_setting('kora.ci.dblink_host', true), ''), '127.0.0.1');
  v_port text := coalesce(nullif(current_setting('kora.ci.dblink_port', true), ''), '5432');
BEGIN
  IF v_password IS NULL THEN
    RETURN 'dbname=' || current_database() || ' user=' || current_user;
  END IF;
  RETURN 'host=' || v_host || ' port=' || v_port || ' dbname=' || current_database()
    || ' user=' || current_user || ' password=' || v_password;
END
$$;
CREATE OR REPLACE FUNCTION pg_temp.qa_probe_submit_serialization(
  p_result_id text, p_attempt_id uuid, p_numero integer
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_a text := ''; v_b text := ''; v_state text := ''; v_message text := '';
  v_observed text := 'INCONCLUSIVE'; v_after text;
  v_pid1 integer; v_pid2 integer; v_wait_type text := ''; v_wait_event text := '';
  v_overlap boolean := false; i integer;
BEGIN
  RESET ROLE;
  PERFORM dblink_connect('sc004_r53_s1',pg_temp.qa_dblink_conninfo());
  PERFORM dblink_connect('sc004_r53_s2',pg_temp.qa_dblink_conninfo());
  PERFORM dblink_exec('sc004_r53_s1','SET ROLE authenticated');
  PERFORM dblink_exec('sc004_r53_s2','SET ROLE authenticated');
  PERFORM dblink_exec('sc004_r53_s1','SET request.jwt.claim.sub = ''a3000000-0000-0000-0000-000000000012''');
  PERFORM dblink_exec('sc004_r53_s2','SET request.jwt.claim.sub = ''a3000000-0000-0000-0000-000000000012''');
  PERFORM dblink_exec('sc004_r53_s1','SET application_name = ''sc004_r53_s1''');
  PERFORM dblink_exec('sc004_r53_s2','SET application_name = ''sc004_r53_s2''');
  SELECT max(pid) FILTER (WHERE application_name='sc004_r53_s1'), max(pid) FILTER (WHERE application_name='sc004_r53_s2')
    INTO v_pid1,v_pid2 FROM pg_stat_activity WHERE application_name IN ('sc004_r53_s1','sc004_r53_s2');
  PERFORM dblink_send_query('sc004_r53_s1','SELECT public.enviar_tentativa_avaliacao('''||p_attempt_id::text||'''::uuid,''[{"questao_id":"aa000000-0000-0000-0000-000000000001","alternativa_id":"a"}]''::jsonb)');
  PERFORM pg_catalog.pg_sleep(0.08);
  PERFORM dblink_send_query('sc004_r53_s2','SELECT public.enviar_tentativa_avaliacao('''||p_attempt_id::text||'''::uuid,''[{"questao_id":"aa000000-0000-0000-0000-000000000001","alternativa_id":"a"}]''::jsonb)');
  FOR i IN 1..40 LOOP
    SELECT coalesce(wait_event_type,''),coalesce(wait_event,'') INTO v_wait_type,v_wait_event FROM pg_stat_activity WHERE pid=v_pid2;
    IF v_pid1 IS NOT NULL AND v_pid2 IS NOT NULL AND v_pid1 <> v_pid2 AND v_wait_type <> '' THEN v_overlap := true; EXIT; END IF;
    PERFORM pg_catalog.pg_sleep(0.025);
  END LOOP;
  BEGIN SELECT v::text INTO v_a FROM dblink_get_result('sc004_r53_s1') AS t(v jsonb); EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE,v_message=MESSAGE_TEXT; v_a='ERROR:'||v_state||':'||v_message; END;
  BEGIN SELECT v::text INTO v_b FROM dblink_get_result('sc004_r53_s2') AS t(v jsonb); EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE,v_message=MESSAGE_TEXT; v_b='ERROR:'||v_state||':'||v_message; END;
  RESET ROLE;
  SELECT situacao::text||'|'||coalesce(nota::text,'')||'|'||coalesce(percentual::text,'') INTO v_after FROM public.avaliacao_tentativas WHERE id=p_attempt_id;
  IF NOT v_overlap THEN v_observed := 'NOT_CONCURRENT';
  ELSIF ((v_a NOT LIKE 'ERROR:%' AND v_b LIKE '%Tentativa já enviada%') OR (v_b NOT LIKE 'ERROR:%' AND v_a LIKE '%Tentativa já enviada%')) AND v_after LIKE 'corrigida|%' THEN v_observed := 'SERIALIZED';
  ELSIF v_a NOT LIKE 'ERROR:%' AND v_b NOT LIKE 'ERROR:%' THEN v_observed := 'UNSAFE_CONCURRENT_SUCCESS';
  ELSE v_observed := 'INCONCLUSIVE'; END IF;
  PERFORM dblink_disconnect('sc004_r53_s1'); PERFORM dblink_disconnect('sc004_r53_s2');
  PERFORM pg_temp.qa_record(p_result_id,'SERIALIZED',v_observed,'BLOCKING SUBMISSION SERIALIZATION','em_andamento',v_after,'pid1='||coalesce(v_pid1::text,'')||' pid2='||coalesce(v_pid2::text,'')||' overlap='||v_overlap::text||' wait='||v_wait_type||':'||v_wait_event||' session_a='||v_a||' session_b='||v_b);
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE,v_message=MESSAGE_TEXT;
  BEGIN PERFORM dblink_disconnect('sc004_r53_s1'); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM dblink_disconnect('sc004_r53_s2'); EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM pg_temp.qa_record(p_result_id,'SERIALIZED','INCONCLUSIVE','BLOCKING SUBMISSION SERIALIZATION','',v_after,'sqlstate='||v_state||' message='||v_message);
END $$;
reset role;
insert into public.avaliacao_tentativas(
  id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,
  situacao,questoes_ordem,gabarito_snapshot,nota_maxima
) values (
  'ad000000-0000-0000-0000-000000000013','a1000000-0000-0000-0000-000000000001',
  'ac000000-0000-0000-0000-000000000009','a8000000-0000-0000-0000-000000000003',
  'a4000000-0000-0000-0000-000000000012',2,'em_andamento',
  '[{"questao_id":"aa000000-0000-0000-0000-000000000001","pontos":1}]'::jsonb,
  '{"aa000000-0000-0000-0000-000000000001":"a"}'::jsonb,1
);
CREATE OR REPLACE FUNCTION pg_temp.qa_pause_submit_response() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_catalog.pg_sleep(0.35); RETURN NEW; END $$;
DROP TRIGGER IF EXISTS qa_r55_submit_pause ON public.avaliacao_respostas;
CREATE TRIGGER qa_r55_submit_pause BEFORE INSERT ON public.avaliacao_respostas FOR EACH ROW EXECUTE FUNCTION pg_temp.qa_pause_submit_response();
select pg_temp.qa_probe_submit_serialization('R53-M1-SERIALIZATION','ad000000-0000-0000-0000-000000000013'::uuid,2);
DROP TRIGGER qa_r55_submit_pause ON public.avaliacao_respostas;

-- M4 self-test: an absent/mismatched target is never a successful DENY proof.
-- The row is removed after checking the observed classification so this
-- harness-health assertion does not inflate the security PASS count.
select pg_temp.qa_probe_actor_dml_strict('R54-M4-ZERO-ROW-SELFTEST','INCONCLUSIVE','HARNESS SELF-TEST','Nonexistent target must remain inconclusive, never a DENY pass','a3000000-0000-0000-0000-000000000005','delete from public.questoes where id=''aa000000-0000-0000-0000-000000009999''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000009999''');
DO $$
DECLARE v_observed text;
BEGIN
  SELECT observed INTO v_observed FROM qa_results WHERE id='R54-M4-ZERO-ROW-SELFTEST';
  IF v_observed IS DISTINCT FROM 'INCONCLUSIVE' THEN
    RAISE EXCEPTION 'R54 zero-row self-test expected INCONCLUSIVE, got %', coalesce(v_observed,'<MISSING>');
  END IF;
  DELETE FROM qa_results WHERE id='R54-M4-ZERO-ROW-SELFTEST';
END
$$;

\echo 'R54_M4_ZERO_ROW_SELFTEST: PASS (observed INCONCLUSIVE)'

-- Restore role and emit all results. Fixture remains disposable and is removed by dropping the QA database.
reset role;
\echo 'SC004 QA RESULTS'
select id,expected,observed,result,classification,coalesce(state_before,''),coalesce(state_after,''),detail from qa_results order by id;

DO $$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(id || '=' || result, ', ' ORDER BY id)
    INTO v_bad
  FROM qa_results
  WHERE result IN ('FAIL','STOP','INCONCLUSIVE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'SC004 QA FAIL-CLOSED: %', v_bad USING ERRCODE = 'P0001';
  END IF;
END
$$;
