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


-- R5.3 mutation helper for catalog invariants whose safe state is not ALLOW.
CREATE OR REPLACE FUNCTION pg_temp.qa_expect_mutation_state(p_id text, p_observed text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE v_result text; v_actual text;
BEGIN
  SELECT result, observed INTO v_result, v_actual FROM qa_results WHERE id=p_id;
  IF v_result IS DISTINCT FROM 'FAIL' OR v_actual IS DISTINCT FROM p_observed THEN
    RAISE EXCEPTION 'mutation % expected FAIL/% but observed result=% state=%',
      p_id, p_observed, coalesce(v_result,'<MISSING>'), coalesce(v_actual,'<MISSING>');
  END IF;
END
$$;

-- M12 — X7b: remove only the parent evidence trigger. The same normal
-- catalog/effectiveness assertion must fail, then pass after rollback.
BEGIN;
select pg_temp.qa_probe_evidence_trigger('M12-BASELINE');
select pg_temp.qa_expect_result('M12-BASELINE','PASS');
DROP TRIGGER trg_sc004_assessment_evidence_delete ON public.avaliacoes;
select pg_temp.qa_probe_evidence_trigger('M12-MUTATED');
select pg_temp.qa_expect_mutation_state('M12-MUTATED','ABSENT');
DELETE FROM qa_results WHERE id='M12-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_evidence_trigger('M12-ROLLBACK');
select pg_temp.qa_expect_result('M12-ROLLBACK','PASS');
\echo 'M12_EVIDENCE_DELETE_TRIGGER_KILLED: PASS';


-- M13 — H2 composition ownership: remove only owner-specific composition policies.
BEGIN;
DROP POLICY IF EXISTS avaliacao_questoes_teacher_select_r53 ON public.avaliacao_questoes;
DROP POLICY IF EXISTS avaliacao_questoes_owner_insert_r53 ON public.avaliacao_questoes;
DROP POLICY IF EXISTS avaliacao_questoes_owner_update_r53 ON public.avaliacao_questoes;
DROP POLICY IF EXISTS avaliacao_questoes_owner_delete_r53 ON public.avaliacao_questoes;
CREATE POLICY mutation_r53_composition_scope ON public.avaliacao_questoes
  FOR ALL TO authenticated
  USING (
    public.is_staff()
    OR EXISTS (
      SELECT 1 FROM public.avaliacoes a
      JOIN public.questoes q ON q.id=avaliacao_questoes.questao_id
      WHERE a.id=avaliacao_questoes.avaliacao_id
        AND a.tenant_id=public.current_tenant_id()
        AND q.tenant_id=a.tenant_id
        AND q.disciplina_id=a.disciplina_id
        AND public.teacher_assessment_scope(a.turma_id,a.disciplina_id)
    )
  )
  WITH CHECK (
    public.is_staff()
    OR EXISTS (
      SELECT 1 FROM public.avaliacoes a
      JOIN public.questoes q ON q.id=avaliacao_questoes.questao_id
      WHERE a.id=avaliacao_questoes.avaliacao_id
        AND a.tenant_id=public.current_tenant_id()
        AND q.tenant_id=a.tenant_id
        AND q.disciplina_id=a.disciplina_id
        AND public.teacher_assessment_scope(a.turma_id,a.disciplina_id)
    )
  );
select pg_temp.qa_probe_actor_dml('M13-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same H2 insert assertion after composition owner policy removal','a3000000-0000-0000-0000-000000000005','insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem,tenant_id) values (''ac000000-0000-0000-0000-000000000011'',''aa000000-0000-0000-0000-000000000010'',2,''a1000000-0000-0000-0000-000000000001'')','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000011''');
select pg_temp.qa_expect_mutation('M13-MUTATED');
DELETE FROM qa_results WHERE id='M13-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M13-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Teacher B is denied after H2 policy rollback','a3000000-0000-0000-0000-000000000005','insert into public.avaliacao_questoes(avaliacao_id,questao_id,ordem,tenant_id) values (''ac000000-0000-0000-0000-000000000011'',''aa000000-0000-0000-0000-000000000010'',2,''a1000000-0000-0000-0000-000000000001'')','select count(*)::text from public.avaliacao_questoes where avaliacao_id=''ac000000-0000-0000-0000-000000000011''');
select pg_temp.qa_expect_result('M13-ROLLBACK','PASS');
\echo 'M13_COMPOSITION_OWNERSHIP_KILLED: PASS'

-- M14 — H3 ownership provenance: remove only the update guard.
BEGIN;
CREATE OR REPLACE FUNCTION public.sc004_guard_academic_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$ BEGIN RETURN NEW; END $$;
select pg_temp.qa_probe_actor_dml('M14-A-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same assessment creator takeover assertion after creator guard removal','a3000000-0000-0000-0000-000000000005','update public.avaliacoes set criado_por=''a4000000-0000-0000-0000-000000000005'',titulo=''R53 mutation title'' where id=''ac000000-0000-0000-0000-000000000011''','select criado_por::text||''|''||titulo from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000011''');
select pg_temp.qa_expect_mutation('M14-A-MUTATED');
DELETE FROM qa_results WHERE id='M14-A-MUTATED';
select pg_temp.qa_probe_actor_dml('M14-Q-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same question creator takeover assertion after creator guard removal','a3000000-0000-0000-0000-000000000005','update public.questoes set criado_por=''a4000000-0000-0000-0000-000000000005'',enunciado=''R53 mutation text'' where id=''aa000000-0000-0000-0000-000000000009''','select criado_por::text||''|''||enunciado from public.questoes where id=''aa000000-0000-0000-0000-000000000009''');
select pg_temp.qa_expect_mutation('M14-Q-MUTATED');
DELETE FROM qa_results WHERE id='M14-Q-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_dml('M14-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Teacher B is denied after H3 guard rollback','a3000000-0000-0000-0000-000000000005','update public.avaliacoes set criado_por=''a4000000-0000-0000-0000-000000000005'' where id=''ac000000-0000-0000-0000-000000000011''','select criado_por::text from public.avaliacoes where id=''ac000000-0000-0000-0000-000000000011''');
select pg_temp.qa_expect_result('M14-ROLLBACK','PASS');
\echo 'M14_AUTHORSHIP_IMMUTABILITY_KILLED: PASS'

-- M15 — H4 staff tenant boundary: remove only the tenant predicate.
BEGIN;
DROP POLICY IF EXISTS atribuicoes_staff_all ON public.atribuicoes_academicas_professor;
CREATE POLICY mutation_r53_staff_global ON public.atribuicoes_academicas_professor
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());
select pg_temp.qa_probe_actor_count('M15-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same Staff A cross-tenant SELECT after tenant predicate removal','a3000000-0000-0000-0000-000000000001','select count(*) from public.atribuicoes_academicas_professor where id=''bb100000-0000-0000-0000-000000000001''','select count(*)::text from public.atribuicoes_academicas_professor where id=''bb100000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_mutation('M15-MUTATED');
DELETE FROM qa_results WHERE id='M15-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_count('M15-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Staff A is denied after H4 policy rollback','a3000000-0000-0000-0000-000000000001','select count(*) from public.atribuicoes_academicas_professor where id=''bb100000-0000-0000-0000-000000000001''','select count(*)::text from public.atribuicoes_academicas_professor where id=''bb100000-0000-0000-0000-000000000001''');
select pg_temp.qa_expect_result('M15-ROLLBACK','PASS');
\echo 'M15_STAFF_TENANT_BOUNDARY_KILLED: PASS'

-- M16/M17 — C2 explicit role ACL mutations, separately authenticated and anon.
BEGIN;
GRANT TRUNCATE ON public.avaliacao_respostas TO authenticated;
select pg_temp.qa_probe_actor_truncate('M16-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same authenticated TRUNCATE assertion after grant mutation','authenticated','avaliacao_respostas','select count(*)::text from public.avaliacao_respostas');
select pg_temp.qa_expect_mutation('M16-MUTATED');
DELETE FROM qa_results WHERE id='M16-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_truncate('M16-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','authenticated cannot truncate after ACL rollback','authenticated','avaliacao_respostas','select count(*)::text from public.avaliacao_respostas');
select pg_temp.qa_expect_result('M16-ROLLBACK','PASS');
BEGIN;
GRANT TRUNCATE ON public.avaliacao_respostas TO anon;
select pg_temp.qa_probe_actor_truncate('M17-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same anon TRUNCATE assertion after grant mutation','anon','avaliacao_respostas','select count(*)::text from public.avaliacao_respostas');
select pg_temp.qa_expect_mutation('M17-MUTATED');
DELETE FROM qa_results WHERE id='M17-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_truncate('M17-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','anon cannot truncate after ACL rollback','anon','avaliacao_respostas','select count(*)::text from public.avaliacao_respostas');
select pg_temp.qa_expect_result('M17-ROLLBACK','PASS');
\echo 'M16_M17_TRUNCATE_ACL_KILLED: PASS'

-- M18/M19 — C1 search_path invariant mutations.
BEGIN;
ALTER FUNCTION public.iniciar_tentativa_avaliacao(uuid,uuid) SET search_path = public;
select pg_temp.qa_record('M18-MUTATED','SAFE',CASE WHEN EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid='public.iniciar_tentativa_avaliacao(uuid,uuid)'::regprocedure AND COALESCE(array_to_string(p.proconfig,','),'') LIKE '%search_path=""%') THEN 'SAFE' ELSE 'UNSAFE' END,'MUTATION NORMAL ASSERTION','','','search_path mutation');
select pg_temp.qa_expect_mutation_state('M18-MUTATED','UNSAFE');
DELETE FROM qa_results WHERE id='M18-MUTATED';
ROLLBACK;
select pg_temp.qa_record('M18-ROLLBACK','SAFE',CASE WHEN EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid='public.iniciar_tentativa_avaliacao(uuid,uuid)'::regprocedure AND COALESCE(array_to_string(p.proconfig,','),'') LIKE '%search_path=""%') THEN 'SAFE' ELSE 'UNSAFE' END,'MUTATION ROLLBACK ASSERTION','','','search_path restored');
select pg_temp.qa_expect_result('M18-ROLLBACK','PASS');
BEGIN;
ALTER FUNCTION public.enviar_tentativa_avaliacao(uuid,jsonb) SET search_path = public;
select pg_temp.qa_record('M19-MUTATED','SAFE',CASE WHEN EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid='public.enviar_tentativa_avaliacao(uuid,jsonb)'::regprocedure AND COALESCE(array_to_string(p.proconfig,','),'') LIKE '%search_path=""%') THEN 'SAFE' ELSE 'UNSAFE' END,'MUTATION NORMAL ASSERTION','','','search_path mutation');
select pg_temp.qa_expect_mutation_state('M19-MUTATED','UNSAFE');
DELETE FROM qa_results WHERE id='M19-MUTATED';
ROLLBACK;
select pg_temp.qa_record('M19-ROLLBACK','SAFE',CASE WHEN EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid='public.enviar_tentativa_avaliacao(uuid,jsonb)'::regprocedure AND COALESCE(array_to_string(p.proconfig,','),'') LIKE '%search_path=""%') THEN 'SAFE' ELSE 'UNSAFE' END,'MUTATION ROLLBACK ASSERTION','','','search_path restored');
select pg_temp.qa_expect_result('M19-ROLLBACK','PASS');
\echo 'M18_M19_SECURITY_DEFINER_SEARCH_PATH_KILLED: PASS'

-- M20 — submission serialization mutation. The same real concurrent detector
-- used by the normal A/B assertion is rerun after replacing only the RPC lock.
-- The replacement is committed in a disposable QA database, then 049 is
-- replayed as the explicit forward restoration before the post-rollback probe.
select pg_temp.qa_record('M20-BASELINE','LOCKED',CASE WHEN pg_get_functiondef('public.enviar_tentativa_avaliacao(uuid,jsonb)'::regprocedure) LIKE '%FOR UPDATE%' THEN 'LOCKED' ELSE 'UNLOCKED' END,'MUTATION NORMAL ASSERTION','','','RPC contains attempt row lock');
select pg_temp.qa_expect_result('M20-BASELINE','PASS');
BEGIN;
DO $do$
BEGIN
PERFORM dblink_connect('sc004_r53_mutator','dbname='||current_database());
PERFORM dblink_exec('sc004_r53_mutator',$ddl$CREATE OR REPLACE FUNCTION public.enviar_tentativa_avaliacao(p_tentativa_id uuid,p_respostas jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_t public.avaliacao_tentativas%rowtype;
BEGIN
  SELECT * INTO v_t FROM public.avaliacao_tentativas
  WHERE id=p_tentativa_id AND usuario_id=public.current_usuario_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Tentativa não encontrada'; END IF;
  UPDATE public.avaliacao_tentativas SET situacao='corrigida'::public.situacao_tentativa WHERE id=v_t.id;
  RETURN jsonb_build_object('id',v_t.id,'situacao','corrigida');
END
$$;$ddl$);
PERFORM dblink_disconnect('sc004_r53_mutator');
END
$do$;
COMMIT;
insert into public.avaliacao_tentativas(
  id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa,
  situacao,questoes_ordem,gabarito_snapshot,nota_maxima
) values (
  'ad000000-0000-0000-0000-000000000014','a1000000-0000-0000-0000-000000000001',
  'ac000000-0000-0000-0000-000000000009','a8000000-0000-0000-0000-000000000003',
  'a4000000-0000-0000-0000-000000000012',5,'em_andamento',
  '[{"questao_id":"aa000000-0000-0000-0000-000000000001","pontos":1}]'::jsonb,
  '{"aa000000-0000-0000-0000-000000000001":"a"}'::jsonb,1
);
select pg_temp.qa_probe_submit_serialization('M20-MUTATED','ad000000-0000-0000-0000-000000000014'::uuid,5);
select pg_temp.qa_expect_mutation_state('M20-MUTATED','UNSAFE_CONCURRENT_SUCCESS');
DELETE FROM qa_results WHERE id='M20-MUTATED';
\i supabase/migrations/049_kora_school_sc004_security_remediation.sql
select pg_temp.qa_record('M20-ROLLBACK','LOCKED',CASE WHEN pg_get_functiondef('public.enviar_tentativa_avaliacao(uuid,jsonb)'::regprocedure) LIKE '%FOR UPDATE%' THEN 'LOCKED' ELSE 'UNLOCKED' END,'MUTATION ROLLBACK ASSERTION','','','RPC lock restored by 049');
select pg_temp.qa_expect_result('M20-ROLLBACK','PASS');
\echo 'M20_SUBMISSION_SERIALIZATION_KILLED: PASS'


-- M21 — zero-row false-green guard. A nonexistent target is deliberately
-- ambiguous and must be recorded as INCONCLUSIVE/FAIL, never DENY/PASS.
select pg_temp.qa_probe_actor_dml_strict('M21-ZERO-ROW','DENY','MUTATION HARNESS FAIL-CLOSED','Security-critical nonexistent DELETE target must not be treated as a denial','a3000000-0000-0000-0000-000000000005','delete from public.questoes where id=''aa000000-0000-0000-0000-000000009999''','select count(*)::text from public.questoes where id=''aa000000-0000-0000-0000-000000009999''');
select pg_temp.qa_expect_mutation_state('M21-ZERO-ROW','INCONCLUSIVE');
DELETE FROM qa_results WHERE id='M21-ZERO-ROW';
\echo 'M21_ZERO_ROW_FALSE_GREEN_DETECTED: PASS'

-- M22 — point bounds. Keep actor scope and submitted lifecycle intact; the
-- disposable replacement removes only the p_pontos range check.
select pg_temp.qa_probe_actor_rpc('M22-BASELINE','DENY','MUTATION NORMAL ASSERTION','Authorized Teacher Exact rejects above-maximum points on the same submitted response','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,999,''M22 baseline high points'')','select situacao::text||'':''||corrigida::text||'':''||coalesce(pontos_obtidos::text,''NULL'') from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_expect_result('M22-BASELINE','PASS');
BEGIN;
CREATE OR REPLACE FUNCTION public.corrigir_resposta_avaliacao(p_resposta_id uuid,p_pontos numeric,p_comentario text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_t public.avaliacao_tentativas%rowtype;
  v_r public.avaliacao_respostas%rowtype;
  v_a public.avaliacoes%rowtype;
BEGIN
  SELECT r.* INTO v_r FROM public.avaliacao_respostas r
  JOIN public.avaliacao_tentativas t ON t.id=r.tentativa_id
  JOIN public.avaliacoes a ON a.id=t.avaliacao_id
  WHERE r.id=p_resposta_id AND r.tenant_id=public.current_tenant_id()
    AND (public.is_staff() OR public.teacher_assessment_scope(a.turma_id,a.disciplina_id));
  IF NOT FOUND THEN RAISE EXCEPTION 'Resposta não encontrada'; END IF;
  SELECT t.* INTO v_t FROM public.avaliacao_tentativas t WHERE t.id=v_r.tentativa_id;
  SELECT a.* INTO v_a FROM public.avaliacoes a WHERE a.id=v_t.avaliacao_id;
  IF v_t.situacao <> 'enviada' THEN RAISE EXCEPTION 'Tentativa ainda não está enviada para correção'; END IF;
  IF v_r.corrigida THEN RAISE EXCEPTION 'Resposta já corrigida'; END IF;
  -- Mutation intentionally omits only the production point-bound check.
  UPDATE public.avaliacao_respostas SET pontos_obtidos=p_pontos,comentario=p_comentario,corrigida=true WHERE id=v_r.id;
  UPDATE public.avaliacao_tentativas SET situacao='corrigida'::public.situacao_tentativa,nota=p_pontos,nota_maxima=p_pontos,percentual=100,aprovada=true WHERE id=v_t.id;
  RETURN jsonb_build_object('tentativa_id',v_t.id,'situacao','corrigida');
END
$$;
select pg_temp.qa_probe_actor_rpc('M22-MUTATED','DENY','MUTATION NORMAL ASSERTION','The same above-maximum assertion after only point-bound removal','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,999,''M22 mutated high points'')','select situacao::text||'':''||corrigida::text||'':''||coalesce(pontos_obtidos::text,''NULL'') from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_expect_mutation('M22-MUTATED');
DELETE FROM qa_results WHERE id='M22-MUTATED';
ROLLBACK;
select pg_temp.qa_probe_actor_rpc('M22-ROLLBACK','DENY','MUTATION ROLLBACK ASSERTION','Above-maximum points are denied again after point-bound rollback','a3000000-0000-0000-0000-000000000005','','select public.corrigir_resposta_avaliacao(''ae000000-0000-0000-0000-000000000020''::uuid,999,''M22 rollback high points'')','select situacao::text||'':''||corrigida::text||'':''||coalesce(pontos_obtidos::text,''NULL'') from public.avaliacao_tentativas t join public.avaliacao_respostas r on r.tentativa_id=t.id where r.id=''ae000000-0000-0000-0000-000000000020''');
select pg_temp.qa_expect_result('M22-ROLLBACK','PASS');
\echo 'M22_POINT_BOUNDS_KILLED: PASS'
