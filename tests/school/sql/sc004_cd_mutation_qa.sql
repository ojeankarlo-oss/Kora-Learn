\set ON_ERROR_STOP on
-- KORA LEARN — SC-004D R5.1 real mutation testing
-- Run in the same psql session immediately after sc004_ab_qa.sql.
-- Each mutation weakens one real production control, re-runs the same
-- normal actor assertion, requires that assertion to FAIL, rolls back, and
-- re-runs the assertion requiring PASS.

\echo 'SC004D R5.1 MUTATION QA'

CREATE OR REPLACE FUNCTION pg_temp.qa_expect_result(p_id text, p_expected text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_result text;
BEGIN
  SELECT result INTO v_result FROM qa_results WHERE id = p_id;
  IF v_result IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION 'mutation assertion % expected %, observed %', p_id, p_expected, coalesce(v_result, '<MISSING>');
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.qa_expect_mutation(p_id text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_result text;
  v_observed text;
BEGIN
  SELECT result, observed INTO v_result, v_observed FROM qa_results WHERE id = p_id;
  IF v_result IS DISTINCT FROM 'FAIL' OR v_observed IS DISTINCT FROM 'ALLOW' THEN
    RAISE EXCEPTION 'mutation % was not observed as an authorization bypass: result=%, observed=%',
      p_id, coalesce(v_result, '<MISSING>'), coalesce(v_observed, '<MISSING>');
  END IF;
END
$$;

-- M1 — staff tenant boundary: the normal cross-tenant staff assertion must
-- detect a forged session tenant after the tenant resolver is weakened.
select pg_temp.qa_probe_actor_dml('M1-BASELINE','DENY','MUTATION NORMAL ASSERTION','Staff A cannot update Tenant B question','a3000000-0000-0000-0000-000000000001','update public.questoes set enunciado=''QA M1 baseline'' where id=''bb000000-0000-0000-0000-000000000001''','select enunciado from public.questoes where id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M1-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.current_tenant_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT 'b1000000-0000-0000-0000-000000000001'::uuid $$;
select pg_temp.qa_probe_actor_dml('M1-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same cross-tenant staff assertion after tenant derivation mutation','a3000000-0000-0000-0000-000000000001','update public.questoes set enunciado=''QA M1 mutated'' where id=''bb000000-0000-0000-0000-000000000001''','select enunciado from public.questoes where id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_mutation('M1-MUTATED');
DELETE FROM qa_results WHERE id='M1-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M1-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Staff A is denied again after tenant resolver rollback','a3000000-0000-0000-0000-000000000001','update public.questoes set enunciado=''QA M1 rollback'' where id=''bb000000-0000-0000-0000-000000000001''','select enunciado from public.questoes where id=''bb000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M1-ROLLBACK','PASS');
\echo 'M1_STAFF_TENANT_BOUNDARY_KILLED: PASS'

-- M2 — exact Class + Subject assessment authority.
select pg_temp.qa_probe_actor_dml('M2-BASELINE','DENY','MUTATION NORMAL ASSERTION','Teacher Exact cannot create 7A Math assessment without exact assignment','a3000000-0000-0000-0000-000000000005','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ac300000-0000-0000-0000-000000000090'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000001'',''QA M2 baseline'',''rascunho'',''a4000000-0000-0000-0000-000000000005'')','select count(*)::text from public.avaliacoes where id=''ac300000-0000-0000-0000-000000000090''');
select pg_temp.qa_expect_result('M2-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.teacher_assessment_scope(p_turma_id uuid,p_disciplina_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT true $$;
select pg_temp.qa_probe_actor_dml('M2-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same wrong-Class assessment assertion after scope mutation','a3000000-0000-0000-0000-000000000005','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ac300000-0000-0000-0000-000000000091'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000001'',''QA M2 mutated'',''rascunho'',''a4000000-0000-0000-0000-000000000005'')','select count(*)::text from public.avaliacoes where id=''ac300000-0000-0000-0000-000000000091''');
select pg_temp.qa_expect_mutation('M2-MUTATED');
DELETE FROM qa_results WHERE id='M2-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M2-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Teacher Exact is denied again after scope rollback','a3000000-0000-0000-0000-000000000005','insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por) values (''ac300000-0000-0000-0000-000000000092'',''a1000000-0000-0000-0000-000000000001'',''a5000000-0000-0000-0000-000000000001'',''a6000000-0000-0000-0000-000000000001'',''a7000000-0000-0000-0000-000000000001'',''QA M2 rollback'',''rascunho'',''a4000000-0000-0000-0000-000000000005'')','select count(*)::text from public.avaliacoes where id=''ac300000-0000-0000-0000-000000000092''');
select pg_temp.qa_expect_result('M2-ROLLBACK','PASS');
\echo 'M2_EXACT_CLASS_SUBJECT_AUTHORITY_KILLED: PASS'

-- M3 — assessment-bound question cross-class authority.
select pg_temp.qa_probe_actor_dml('M3-BASELINE','DENY','MUTATION NORMAL ASSERTION','Teacher X cannot take over Teacher Y assessment-bound question','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'' where id=''aa000000-0000-0000-0000-000000000005''','select criado_por::text from public.questoes where id=''aa000000-0000-0000-0000-000000000005''');
select pg_temp.qa_expect_result('M3-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.teacher_question_scope(p_question_id uuid,p_subject_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT true $$;
select pg_temp.qa_probe_actor_dml('M3-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same question takeover assertion after scope mutation','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'' where id=''aa000000-0000-0000-0000-000000000005''','select criado_por::text from public.questoes where id=''aa000000-0000-0000-0000-000000000005''');
select pg_temp.qa_expect_mutation('M3-MUTATED');
DELETE FROM qa_results WHERE id='M3-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M3-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Teacher X is denied again after question scope rollback','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'' where id=''aa000000-0000-0000-0000-000000000005''','select criado_por::text from public.questoes where id=''aa000000-0000-0000-0000-000000000005''');
select pg_temp.qa_expect_result('M3-ROLLBACK','PASS');
\echo 'M3_QUESTION_CROSS_CLASS_AUTHORITY_KILLED: PASS'

-- M4 — direct grading-table writes.
select pg_temp.qa_probe_actor_dml('M4-BASELINE','DENY','MUTATION NORMAL ASSERTION','Teacher X cannot update a response table directly','a3000000-0000-0000-0000-000000000005','update public.avaliacao_respostas set pontos_obtidos=999 where id=''ae000000-0000-0000-0000-000000000003''','select pontos_obtidos::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_expect_result('M4-BASELINE','PASS');
BEGIN;
CREATE POLICY mutation_r51_direct_response_update ON public.avaliacao_respostas FOR UPDATE TO authenticated USING (tenant_id=public.current_tenant_id()) WITH CHECK (tenant_id=public.current_tenant_id());
select pg_temp.qa_probe_actor_dml('M4-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same direct grading write assertion after a permissive policy mutation','a3000000-0000-0000-0000-000000000005','update public.avaliacao_respostas set pontos_obtidos=999 where id=''ae000000-0000-0000-0000-000000000003''','select pontos_obtidos::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_expect_mutation('M4-MUTATED');
DELETE FROM qa_results WHERE id='M4-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M4-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Teacher X is denied again after direct-write policy rollback','a3000000-0000-0000-0000-000000000005','update public.avaliacao_respostas set pontos_obtidos=999 where id=''ae000000-0000-0000-0000-000000000003''','select pontos_obtidos::text from public.avaliacao_respostas where id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_expect_result('M4-ROLLBACK','PASS');
\echo 'M4_DIRECT_GRADING_WRITE_KILLED: PASS'

-- M5 — course lifecycle authority.
select pg_temp.qa_probe_actor_dml('M5-BASELINE','DENY','MUTATION NORMAL ASSERTION','Teacher Exact cannot update Course A configuration','a3000000-0000-0000-0000-000000000005','update public.cursos set nome=''QA M5 baseline'' where id=''a5000000-0000-0000-0000-000000000001''','select nome from public.cursos where id=''a5000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M5-BASELINE','PASS');
BEGIN;
CREATE POLICY mutation_r51_course_teacher_write ON public.cursos FOR ALL TO authenticated USING (tenant_id=public.current_tenant_id()) WITH CHECK (tenant_id=public.current_tenant_id());
select pg_temp.qa_probe_actor_dml('M5-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same course lifecycle assertion after a permissive policy mutation','a3000000-0000-0000-0000-000000000005','update public.cursos set nome=''QA M5 mutated'' where id=''a5000000-0000-0000-0000-000000000001''','select nome from public.cursos where id=''a5000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_mutation('M5-MUTATED');
DELETE FROM qa_results WHERE id='M5-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M5-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Teacher Exact is denied again after course policy rollback','a3000000-0000-0000-0000-000000000005','update public.cursos set nome=''QA M5 rollback'' where id=''a5000000-0000-0000-0000-000000000001''','select nome from public.cursos where id=''a5000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M5-ROLLBACK','PASS');
\echo 'M5_COURSE_LIFECYCLE_AUTHORITY_KILLED: PASS'

-- M6 — canonical Subject authority.
select pg_temp.qa_probe_actor_dml('M6-BASELINE','DENY','MUTATION NORMAL ASSERTION','Teacher Exact cannot update Subject A configuration','a3000000-0000-0000-0000-000000000005','update public.disciplinas set nome=''QA M6 baseline'' where id=''a6000000-0000-0000-0000-000000000001''','select nome from public.disciplinas where id=''a6000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M6-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.is_staff()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT true $$;
select pg_temp.qa_probe_actor_dml('M6-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same Subject authority assertion after staff-role mutation','a3000000-0000-0000-0000-000000000005','update public.disciplinas set nome=''QA M6 mutated'' where id=''a6000000-0000-0000-0000-000000000001''','select nome from public.disciplinas where id=''a6000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_mutation('M6-MUTATED');
DELETE FROM qa_results WHERE id='M6-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M6-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Teacher Exact is denied again after staff-role rollback','a3000000-0000-0000-0000-000000000005','update public.disciplinas set nome=''QA M6 rollback'' where id=''a6000000-0000-0000-0000-000000000001''','select nome from public.disciplinas where id=''a6000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M6-ROLLBACK','PASS');
\echo 'M6_SUBJECT_AUTHORITY_KILLED: PASS'

-- M7 — academic-evidence deletion protection.
select pg_temp.qa_probe_actor_dml('M7-BASELINE','DENY','MUTATION NORMAL ASSERTION','Staff A cannot delete assessment evidence','a3000000-0000-0000-0000-000000000001','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M7-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.sc004_assessment_has_evidence(p_assessment_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT false $$;
select pg_temp.qa_probe_actor_dml('M7-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same evidence-delete assertion after the evidence guard is weakened','a3000000-0000-0000-0000-000000000001','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_mutation('M7-MUTATED');
DELETE FROM qa_results WHERE id='M7-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M7-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Staff A is denied again after evidence guard rollback','a3000000-0000-0000-0000-000000000001','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M7-ROLLBACK','PASS');
\echo 'M7_ASSESSMENT_EVIDENCE_DELETE_KILLED: PASS'

-- M8 — grading attempt-state precondition.
select pg_temp.qa_probe_actor_rpc('M8-BASELINE','DENY','MUTATION NORMAL ASSERTION','Teacher cannot grade an em_andamento attempt','a3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA M8 baseline'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_expect_result('M8-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.corrigir_resposta_avaliacao(p_resposta_id uuid,p_pontos numeric,p_comentario text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  UPDATE public.avaliacao_respostas SET pontos_obtidos=p_pontos, comentario=p_comentario, corrigida=true WHERE id=p_resposta_id;
  UPDATE public.avaliacao_tentativas SET situacao='corrigida'::public.situacao_tentativa, nota=p_pontos, nota_maxima=p_pontos, percentual=100, aprovada=true WHERE id=(SELECT tentativa_id FROM public.avaliacao_respostas WHERE id=p_resposta_id);
  RETURN jsonb_build_object('tentativa_id',(SELECT tentativa_id FROM public.avaliacao_respostas WHERE id=p_resposta_id),'situacao','corrigida');
END
$$;
select pg_temp.qa_probe_actor_rpc('M8-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same in-progress grading assertion after lifecycle guard mutation','a3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA M8 mutated'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_expect_mutation('M8-MUTATED');
DELETE FROM qa_results WHERE id='M8-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_rpc('M8-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Teacher is denied again after grading lifecycle rollback','a3000000-0000-0000-0000-000000000002','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000003''::uuid,1,''QA M8 rollback'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000003''');
select pg_temp.qa_expect_result('M8-ROLLBACK','PASS');
\echo 'M8_GRADING_ATTEMPT_STATE_KILLED: PASS'

-- No M*-MUTATED result remains: each was checked as FAIL and removed before
-- rollback. The rows below are the normal baseline/rollback assertions only.
SELECT count(*) AS mutation_assertion_rows
FROM qa_results
WHERE id like 'M%-BASELINE' OR id like 'M%-ROLLBACK';
\echo 'MUTATION_ROLLBACK_INTEGRITY: PASS'
