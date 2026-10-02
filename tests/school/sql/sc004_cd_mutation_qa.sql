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


-- A trigger-level mutation must be exercised even when the application policy
-- also denies the same action. This helper uses service_role (not a database
-- superuser) only to reach the database trigger boundary; state is always
-- rolled back and unexpected errors are INCONCLUSIVE.
CREATE OR REPLACE FUNCTION pg_temp.qa_probe_role_dml(
  p_id text, p_expected text, p_classification text, p_detail text,
  p_actor_role text, p_sql text, p_state_sql text
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_before text;
  v_after text;
  v_rows integer := 0;
  v_observed text := 'INCONCLUSIVE';
  v_state text := '';
  v_message text := '';
BEGIN
  RESET ROLE;
  EXECUTE p_state_sql INTO v_before;
  BEGIN
    EXECUTE format('SET LOCAL ROLE %I', p_actor_role);
    EXECUTE p_sql;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_observed := CASE WHEN v_rows > 0 THEN 'ALLOW' ELSE 'DENY' END;
    RAISE EXCEPTION USING MESSAGE = '__QA_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    IF v_message <> '__QA_ROLLBACK__' THEN
      v_observed := CASE WHEN v_state IN ('42501','42503') THEN 'DENY' ELSE 'INCONCLUSIVE' END;
    END IF;
  END;
  RESET ROLE;
  EXECUTE p_state_sql INTO v_after;
  IF v_before IS DISTINCT FROM v_after THEN v_observed := 'STATE_CHANGED'; END IF;
  PERFORM pg_temp.qa_record(
    p_id,p_expected,v_observed,p_classification,v_before,v_after,
    p_detail || ' rows=' || v_rows || ' sqlstate=' || coalesce(v_state,'') || ' message=' || coalesce(v_message,'')
  );
END
$$;

-- M1 — staff tenant boundary: the normal cross-tenant staff assertion must
-- detect a forged session tenant after the tenant resolver is weakened.
select pg_temp.qa_probe_actor_dml('M1-BASELINE','DENY','MUTATION NORMAL ASSERTION','Staff A cannot update Tenant B question','a3000000-0000-0000-0000-000000000001','update public.questoes set enunciado=''QA M1 baseline'' where id=''bb000000-0000-0000-0000-000000000003''','select enunciado from public.questoes where id=''bb000000-0000-0000-0000-000000000003''');
select pg_temp.qa_expect_result('M1-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.current_tenant_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT 'b1000000-0000-0000-0000-000000000001'::uuid $$;
select pg_temp.qa_probe_actor_dml('M1-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same cross-tenant staff assertion after tenant derivation mutation','a3000000-0000-0000-0000-000000000001','update public.questoes set enunciado=''QA M1 mutated'' where id=''bb000000-0000-0000-0000-000000000003''','select enunciado from public.questoes where id=''bb000000-0000-0000-0000-000000000003''');
select pg_temp.qa_expect_mutation('M1-MUTATED');
DELETE FROM qa_results WHERE id='M1-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M1-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Staff A is denied again after tenant resolver rollback','a3000000-0000-0000-0000-000000000001','update public.questoes set enunciado=''QA M1 rollback'' where id=''bb000000-0000-0000-0000-000000000003''','select enunciado from public.questoes where id=''bb000000-0000-0000-0000-000000000003''');
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
-- Teacher Exact shares the 8A + Math assignment with Teacher A, so this is
-- specifically a provenance takeover rather than a wrong-scope denial.
select pg_temp.qa_probe_actor_dml('M3-BASELINE','DENY','MUTATION NORMAL ASSERTION','Teacher Exact cannot take over Teacher A assessment-bound question','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'' where id=''aa000000-0000-0000-0000-000000000001''','select criado_por::text from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M3-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.sc004_guard_academic_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$ BEGIN RETURN NEW; END $$;
select pg_temp.qa_probe_actor_dml('M3-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same question takeover assertion after scope mutation','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'' where id=''aa000000-0000-0000-0000-000000000001''','select criado_por::text from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_mutation('M3-MUTATED');
DELETE FROM qa_results WHERE id='M3-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M3-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Teacher Exact is denied again after question scope rollback','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'' where id=''aa000000-0000-0000-0000-000000000001''','select criado_por::text from public.questoes where id=''aa000000-0000-0000-0000-000000000001''');
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


-- M9 — grading authorization. The same valid submitted response must become
-- ALLOW only when the exact-assignment primitive is weakened.
select pg_temp.qa_probe_actor_rpc('M9-BASELINE','DENY','MUTATION NORMAL ASSERTION','Teacher A3 without assignment cannot grade an already submitted response','a3000000-0000-0000-0000-000000000004','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,1,''QA M9 baseline'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_expect_result('M9-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.teacher_assessment_scope(p_turma_id uuid,p_disciplina_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT true $$;
select pg_temp.qa_probe_actor_rpc('M9-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same submitted grading assertion after grading authorization mutation','a3000000-0000-0000-0000-000000000004','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,1,''QA M9 mutated'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_expect_mutation('M9-MUTATED');
DELETE FROM qa_results WHERE id='M9-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_rpc('M9-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Teacher A3 is denied again after grading authorization rollback','a3000000-0000-0000-0000-000000000004','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,1,''QA M9 rollback'')','select situacao::text||'':''||corrigida::text from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_expect_result('M9-ROLLBACK','PASS');
\echo 'M9_GRADING_AUTHORIZATION_KILLED: PASS';

-- M10 — X11 owner DELETE guard. Both the helper's unlinked-question owner
-- branch and the policy's creator condition are weakened inside the mutation.
select pg_temp.qa_probe_actor_dml('M10-BASELINE','DENY','MUTATION NORMAL ASSERTION','Teacher Exact cannot delete Teacher A unlinked question','a3000000-0000-0000-0000-000000000005','delete from public.questoes where id=''aa000000-0000-0000-0000-000000000008''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000008''');
select pg_temp.qa_expect_result('M10-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.teacher_question_scope(p_question_id uuid,p_subject_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT true $$;
DROP POLICY IF EXISTS questoes_teacher_delete_r4 ON public.questoes;
CREATE POLICY mutation_x11_question_delete ON public.questoes FOR DELETE TO authenticated
  USING (tenant_id = public.current_tenant_id() AND public.teacher_question_scope(id, disciplina_id));
select pg_temp.qa_probe_actor_dml('M10-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same question DELETE assertion after X11 owner condition removal','a3000000-0000-0000-0000-000000000005','delete from public.questoes where id=''aa000000-0000-0000-0000-000000000008''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000008''');
select pg_temp.qa_expect_mutation('M10-MUTATED');
DELETE FROM qa_results WHERE id='M10-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M10-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Teacher Exact is denied again after X11 rollback','a3000000-0000-0000-0000-000000000005','delete from public.questoes where id=''aa000000-0000-0000-0000-000000000008''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000000008''');
select pg_temp.qa_expect_result('M10-ROLLBACK','PASS');
\echo 'M10_OWNER_DELETE_GUARD_KILLED: PASS';

-- M11 — post-evidence academic configuration immutability.
select pg_temp.qa_probe_actor_dml('M11-BASELINE','DENY','MUTATION NORMAL ASSERTION','Staff cannot change nota_minima after evidence exists','a3000000-0000-0000-0000-000000000001','update public.avaliacoes set nota_minima=99 where id=''ac000000-0000-0000-0000-000000000001''','select nota_minima::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M11-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.sc004_guard_academic_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$ BEGIN RETURN NEW; END $$;
select pg_temp.qa_probe_actor_dml('M11-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same post-evidence configuration assertion after guard removal','a3000000-0000-0000-0000-000000000001','update public.avaliacoes set nota_minima=99 where id=''ac000000-0000-0000-0000-000000000001''','select nota_minima::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_mutation('M11-MUTATED');
DELETE FROM qa_results WHERE id='M11-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M11-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Staff is denied again after post-evidence guard rollback','a3000000-0000-0000-0000-000000000001','update public.avaliacoes set nota_minima=99 where id=''ac000000-0000-0000-0000-000000000001''','select nota_minima::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M11-ROLLBACK','PASS');
\echo 'M11_POST_EVIDENCE_IMMUTABILITY_KILLED: PASS';

-- M12 — X7b trigger removal. service_role is used only to pass the RLS
-- boundary and reach the physical evidence trigger; it is not a superuser.
BEGIN;
GRANT SELECT, DELETE ON public.avaliacoes TO service_role;
GRANT SELECT, DELETE ON public.avaliacao_questoes, public.avaliacao_tentativas, public.avaliacao_respostas TO service_role;
select pg_temp.qa_probe_role_dml('M12-BASELINE','DENY','MUTATION NORMAL ASSERTION','Evidence trigger rejects physical assessment delete','service_role','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M12-BASELINE','PASS');
DROP TRIGGER trg_sc004_assessment_evidence_delete ON public.avaliacoes;
DROP TRIGGER trg_sc004_assessment_question_evidence ON public.avaliacao_questoes;
select pg_temp.qa_probe_role_dml('M12-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same physical-delete assertion after X7b trigger removal','service_role','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_mutation('M12-MUTATED');
DELETE FROM qa_results WHERE id='M12-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_role_dml('M12-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Physical evidence delete is denied again after X7b rollback','service_role','delete from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''','select count(*)::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M12-ROLLBACK','PASS');
\echo 'M12_EVIDENCE_DELETE_TRIGGER_KILLED: PASS';
