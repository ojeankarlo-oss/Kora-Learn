\set ON_ERROR_STOP on
-- KORA LEARN SC-004A/B — disposable School A/B runtime QA
-- Run only after canonical migrations 001-040, recovered migration 042, and compatibility migration 043 have been replayed in a disposable DB.
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
  v_observed text;
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
      v_observed := 'DENY';
    end if;
  end;
  v_after := pg_temp.qa_scalar(p_state_sql);
  if v_observed is null then v_observed := case when v_ok and v_rows > 0 then 'ALLOW' else 'DENY' end; end if;
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
    v_observed := case when v_state = '42501' then 'DENY' else 'INCONCLUSIVE' end;
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
    if v_message <> '__QA_ROLLBACK__' then v_observed := 'DENY'; end if;
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
    v_observed := 'DENY';
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' count=' || coalesce(v_count::text,'') || ' sqlstate=' || v_state || ' message=' || v_message);
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
    if v_message <> '__QA_ROLLBACK__' then v_observed := 'DENY'; end if;
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
    if v_message <> '__QA_ROLLBACK__' then v_observed := 'DENY'; end if;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' sqlstate=' || v_state || ' message=' || v_message);
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
    if v_message <> '__QA_ROLLBACK__' then v_observed := 'DENY'; end if;
  end;
  reset role;
  execute p_state_sql into v_after;
  if v_before is distinct from v_after then v_observed := 'STATE_CHANGED'; end if;
  perform pg_temp.qa_record(p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' sqlstate=' || v_state || ' message=' || v_message);
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

-- Legacy quality inventory: structurally plausible links are subject-ambiguous by definition.
select pg_temp.qa_record('LEGACY-VALID-LOOKING','REPORT','VALID-LOOKING','QA-INJECTED INVALID STATE','','', 'Teacher A links in School A have matching tenant/class/unit shape but no Subject and cannot become subject grants');
select pg_temp.qa_record('LEGACY-AMBIGUOUS','REPORT','AMBIGUOUS','LEGACY_COMPATIBILITY_ONLY','','', 'Every professores_turmas row is ambiguous for Subject; no inference is made');
select pg_temp.qa_record('LEGACY-INVALID-CROSS-TENANT','REPORT','INVALID','QA-INJECTED INVALID STATE','','', 'Injected Teacher A→Class B and mismatched tenant rows demonstrate missing parent equality guards');
select pg_temp.qa_record('LEGACY-INVALID-CROSS-UNIT','REPORT','INVALID','QA-INJECTED INVALID STATE','','', 'Injected inactive Teacher A2/UA2→Class 8A/UA row demonstrates no unit equality guard');

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
select pg_temp.qa_probe_dml('A33','DENY','CURRENT REPOSITORY CONTRACT','Assessment-question policy allows same-tenant Subject mismatch; rolled back','insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem) values (''ac000000-0000-0000-0000-000000000001'',''aa000000-0000-0000-0000-000000000002'',2)','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_dml('A34','ALLOW','CURRENT REPOSITORY CONTRACT','Teacher A can correct a Physics response via tenant-wide docente gate; rolled back','update public.avaliacao_respostas set pontos_obtidos=1,corrigida=true where id=''ae000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000001'' and corrigida=false');
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
select pg_temp.qa_probe_actor_dml('R3-SA-UPD-Q-XTENANT','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot update an A question to Tenant B','a3000000-0000-0000-0000-000000000001','update public.questoes set tenant_id=''b1000000-0000-0000-0000-000000000001'' where id=''aa000000-0000-0000-0000-000000000001''','select tenant_id::text from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-UPD-Q-XTENANT','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot update a B question to Tenant A','b3000000-0000-0000-0000-000000000002','update public.questoes set tenant_id=''a1000000-0000-0000-0000-000000000001'' where id=''bb000000-0000-0000-0000-000000000001''','select tenant_id::text from public.questoes where id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SA-UPD-Q-ROW','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot update a Tenant B question','a3000000-0000-0000-0000-000000000001','update public.questoes set enunciado=''QA forbidden edit'' where id=''bb000000-0000-0000-0000-000000000001''','select enunciado from public.questoes where id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-UPD-Q-ROW','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot update a Tenant A question','b3000000-0000-0000-0000-000000000002','update public.questoes set enunciado=''QA forbidden edit'' where id=''aa000000-0000-0000-0000-000000000001''','select enunciado from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SA-DEL-Q','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot DELETE a Tenant B question','a3000000-0000-0000-0000-000000000001','delete from public.questoes where id=''bb000000-0000-0000-0000-000000000001''','select count(*)::text from public.questoes where id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-DEL-Q','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot DELETE a Tenant A question','b3000000-0000-0000-0000-000000000002','delete from public.questoes where id=''aa000000-0000-0000-0000-000000000001''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');

select pg_temp.qa_probe_actor_dml('R3-SA-INS-A','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot INSERT a Tenant B assessment','a3000000-0000-0000-0000-000000000001','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ca300000-0000-0000-0000-000000000002'',''b1000000-0000-0000-0000-000000000001'',''b5000000-0000-0000-0000-000000000001'',''b6000000-0000-0000-0000-000000000001'',''b7000000-0000-0000-0000-000000000001'',''QA forbidden B assessment'',''rascunho'',''b4000000-0000-0000-0000-000000000001'')','select count(*)::text from public.avaliacoes where id=''ca300000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_actor_dml('R3-SB-INS-A','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot INSERT a Tenant A assessment','b3000000-0000-0000-0000-000000000002','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''cb300000-0000-0000-0000-000000000002'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000003'',''QA forbidden A assessment'',''rascunho'',''a4000000-0000-0000-0000-000000000001'')','select count(*)::text from public.avaliacoes where id=''cb300000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_actor_dml('R3-SA-UPD-A-XTENANT','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot update an A assessment to Tenant B','a3000000-0000-0000-0000-000000000001','update public.avaliacoes set tenant_id=''b1000000-0000-0000-0000-000000000001'' where id=''ac000000-0000-0000-0000-000000000001''','select tenant_id::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-UPD-A-XTENANT','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot update a B assessment to Tenant A','b3000000-0000-0000-0000-000000000002','update public.avaliacoes set tenant_id=''a1000000-0000-0000-0000-000000000001'' where id=''bc000000-0000-0000-0000-000000000001''','select tenant_id::text from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SA-UPD-A-ROW','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot update a Tenant B assessment','a3000000-0000-0000-0000-000000000001','update public.avaliacoes set titulo=''QA forbidden edit'' where id=''bc000000-0000-0000-0000-000000000001''','select titulo from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-UPD-A-ROW','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot update a Tenant A assessment','b3000000-0000-0000-0000-000000000002','update public.avaliacoes set titulo=''QA forbidden edit'' where id=''ac000000-0000-0000-0000-000000000001''','select titulo from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SA-DEL-A','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot DELETE a Tenant B assessment','a3000000-0000-0000-0000-000000000001','delete from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''bc000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-DEL-A','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot DELETE a Tenant A assessment','b3000000-0000-0000-0000-000000000002','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');

select pg_temp.qa_probe_actor_dml('R3-SA-INS-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot INSERT a Tenant B assessment-question row','a3000000-0000-0000-0000-000000000001','insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem) values (''bc000000-0000-0000-0000-000000000002'',''bb000000-0000-0000-0000-000000000001'',2)','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000002'' and questao_id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-INS-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot INSERT a Tenant A assessment-question row','b3000000-0000-0000-0000-000000000002','insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem) values (''ac000000-0000-0000-0000-000000000001'',''aa000000-0000-0000-0000-000000000010'',2)','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000010''');
select pg_temp.qa_probe_actor_dml('R3-SA-UPD-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot UPDATE a Tenant B assessment-question row','a3000000-0000-0000-0000-000000000001','update public.avaliacao_questoes set ordem=9 where avaliacao_id=''bc000000-0000-0000-0000-000000000002'' and questao_id=''bb000000-0000-0000-0000-000000000002''','select ordem::text from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000002'' and questao_id=''bb000000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_actor_dml('R3-SB-UPD-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot UPDATE a Tenant A assessment-question row','b3000000-0000-0000-0000-000000000002','update public.avaliacao_questoes set ordem=9 where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000001''','select ordem::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SA-DEL-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot DELETE a Tenant B assessment-question row','a3000000-0000-0000-0000-000000000001','delete from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000001'' and questao_id=''bb000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''bc000000-0000-0000-0000-000000000001'' and questao_id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_dml('R3-SB-DEL-AQ','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot DELETE a Tenant A assessment-question row','b3000000-0000-0000-0000-000000000002','delete from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000001'' and questao_id=''aa000000-0000-0000-0000-000000000001''');

select pg_temp.qa_probe_actor_dml('R3-SA-INS-T','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot INSERT a Tenant B attempt (no write policy)','a3000000-0000-0000-0000-000000000001','insert into public.avaliacao_tentativas(id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,questoes_ordem,gabarito_snapshot) values (''ca300000-0000-0000-0000-000000000003'',''b1000000-0000-0000-0000-000000000001'',''bc000000-0000-0000-0000-000000000001'',''b8000000-0000-0000-0000-000000000001'',''b4000000-0000-0000-0000-000000000010'',90,''[{"questao_id":"bb000000-0000-0000-0000-000000000001","pontos":1}]'',''{}'')','select count(*)::text from public.avaliacao_tentativas where id=''ca300000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_dml('R3-SB-INS-T','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot INSERT a Tenant A attempt (no write policy)','b3000000-0000-0000-0000-000000000002','insert into public.avaliacao_tentativas(id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,questoes_ordem,gabarito_snapshot) values (''cb300000-0000-0000-0000-000000000003'',''a1000000-0000-0000-0000-000000000001'',''ac000000-0000-0000-0000-000000000001'',''a8000000-0000-0000-0000-000000000003'',''a4000000-0000-0000-0000-000000000012'',90,''[{"questao_id":"aa000000-0000-0000-0000-000000000001","pontos":1}]'',''{}'')','select count(*)::text from public.avaliacao_tentativas where id=''cb300000-0000-0000-0000-000000000003''');

select pg_temp.qa_probe_actor_dml('R3-SA-INS-R','DENY','BLOCKING CROSS-TENANT STAFF','Staff A cannot INSERT a Tenant B response','a3000000-0000-0000-0000-000000000001','insert into public.avaliacao_respostas(id,tenant_id,tentativa_id,questao_id) values (''ca300000-0000-0000-0000-000000000004'',''b1000000-0000-0000-0000-000000000001'',''bd000000-0000-0000-0000-000000000001'',''bb000000-0000-0000-0000-000000000001'')','select count(*)::text from public.avaliacao_respostas where id=''ca300000-0000-0000-0000-000000000004''');
select pg_temp.qa_probe_actor_dml('R3-SB-INS-R','DENY','BLOCKING CROSS-TENANT STAFF','Staff B cannot INSERT a Tenant A response','b3000000-0000-0000-0000-000000000002','insert into public.avaliacao_respostas(id,tenant_id,tentativa_id,questao_id) values (''cb300000-0000-0000-0000-000000000004'',''a1000000-0000-0000-0000-000000000001'',''ad000000-0000-0000-0000-000000000001'',''aa000000-0000-0000-0000-000000000001'')','select count(*)::text from public.avaliacao_respostas where id=''cb300000-0000-0000-0000-000000000004''');
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
select pg_temp.qa_probe_actor_rpc_no_gabarito('R3-GRADE-POSITIVE','ALLOW_NO_GABARITO','BLOCKING GRADING RPC','Teacher Exact A with exact 8A Math assignment grades a legitimate response; response has no gabarito key','a3000000-0000-0000-0000-000000000005','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA legitimate grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-NO-ASSIGNMENT','DENY','BLOCKING GRADING RPC','Teacher A3 without assignment is denied by the real grading RPC','a3000000-0000-0000-0000-000000000004','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA forbidden grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-WRONG-CLASS','DENY','BLOCKING GRADING RPC','Teacher A is denied for a 7A Physics response without exact Class + Subject assignment','a3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000002''::uuid,1,''QA wrong class grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000002''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-WRONG-SUBJECT','DENY','BLOCKING GRADING RPC','Teacher A is denied for revoked 8A Physics assignment','a3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000001''::uuid,1,''QA revoked subject grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000001''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-INACTIVE','DENY','BLOCKING GRADING RPC','Inactive Teacher A2 is denied by the real grading RPC','a3000000-0000-0000-0000-000000000003','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA inactive grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-STUDENT','DENY','BLOCKING GRADING RPC','Student A is denied by the real grading RPC','a3000000-0000-0000-0000-000000000012','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA student grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-STAFF-B','DENY','BLOCKING GRADING RPC','Staff B cannot grade a Tenant A response','b3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA cross-tenant staff grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-TEACHER-B','DENY','BLOCKING GRADING RPC','Teacher B cannot grade a Tenant A response','b3000000-0000-0000-0000-000000000001','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA cross-tenant teacher grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_probe_actor_rpc('R3-GRADE-CROSS-TENANT','DENY','BLOCKING GRADING RPC','Teacher A cannot grade a Tenant B response','a3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''be000000-0000-0000-0000-000000000001''::uuid,1,''QA cross-tenant grading'')','select coalesce(pontos_obtidos::text,''NULL'')||'':''||corrigida::text from public.avaliacao_respostas where id=''be000000-0000-0000-0000-000000000001''');

-- Explicit direct RPC probes for current runtime ACL and student same-course eligibility.
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
select pg_temp.qa_probe_count('RPC-minhas-turmas-professor','ALLOW','CURRENT REPOSITORY CONTRACT','Teacher RPC is class/course-only and does not return Subject/assignment context','select count(*) from public.minhas_turmas_professor()');
select set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000010',false);
select pg_temp.qa_probe_rpc('RPC-student-start-wrong-class','DENY','CURRENT REPOSITORY CONTRACT','Student 7A can attempt an 8A evaluation from the same Course because start RPC checks Course but not Class','select public.iniciar_tentativa_avaliacao(''ac000000-0000-0000-0000-000000000001''::uuid,''a8000000-0000-0000-0000-000000000001''::uuid)');

-- Restore role and emit all results. Fixture remains disposable and is removed by dropping the QA database.
reset role;
\echo 'SC004 QA RESULTS'
select id,expected,observed,result,classification,coalesce(state_before,''),coalesce(state_after,''),detail from qa_results order by id;
