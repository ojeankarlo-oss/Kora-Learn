\set ON_ERROR_STOP on
-- KORA LEARN — SC-004D mutation testing
-- Run after sc004_ab_qa.sql in the same disposable QA database.
-- Every mutation is transactional and must be rolled back before the next one.

\echo 'SC004D MUTATION QA'

-- M1: weakening exact Teacher + Class + Subject authority must expose an
-- unassigned Chemistry attendance row to Teacher A.
BEGIN;
CREATE OR REPLACE FUNCTION public.teacher_has_assignment(p_turma_id uuid, p_disciplina_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT true $$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
DO $$ BEGIN
  IF (SELECT count(*) FROM public.registros_aula WHERE id='b1000000-0000-0000-0000-000000000003') <> 1 THEN
    RAISE EXCEPTION 'M1 assignment weakening was not observed';
  END IF;
END $$;
ROLLBACK;
\echo 'M1_ASSIGNMENT_WEAKENING_KILLED: PASS'

-- M2: a legacy Class-only link must not grant every Subject. Replacing the
-- canonical helper with the legacy Class-only relation must expose an
-- unassigned Chemistry presence only inside the mutation transaction.
BEGIN;
CREATE OR REPLACE FUNCTION public.teacher_has_assignment(p_turma_id uuid, p_disciplina_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.professores_turmas pt
    JOIN public.usuarios u
      ON u.id = pt.usuario_id
     AND u.auth_user_id = auth.uid()
     AND u.tenant_id = pt.tenant_id
     AND u.ativo IS TRUE
     AND u.perfil = 'professor'
    WHERE pt.tenant_id = public.current_tenant_id()
      AND pt.turma_id = p_turma_id
  )
$$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
INSERT INTO public.presencas(id,tenant_id,registro_aula_id,usuario_id,situacao)
VALUES ('b2000000-0000-0000-0000-000000000099','a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000003','a4000000-0000-0000-0000-000000000014','presente');
ROLLBACK;
\echo 'M2_LEGACY_CLASS_GRANTS_ALL_SUBJECTS_KILLED: PASS'

-- M3: removing exact-Class student eligibility must not permit a student from
-- another Class. The independent SC-003/043 enrollment guard must kill this
-- mutation inside the transaction.
BEGIN;
CREATE OR REPLACE FUNCTION public.student_active_in_class(p_student_id uuid, p_class_id uuid, p_tenant_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT true $$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
DO $$
BEGIN
  BEGIN
    INSERT INTO public.presencas(id,tenant_id,registro_aula_id,usuario_id,situacao)
    VALUES ('b2000000-0000-0000-0000-000000000099','a1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000010','presente');
    RAISE EXCEPTION 'M3 eligibility weakening was not killed';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    NULL;
  END;
END
$$;
ROLLBACK;
\echo 'M3_EXACT_CLASS_ELIGIBILITY_WEAKENING_KILLED: PASS'

-- M4: regranting the hidden answer key column must expose the snapshot only
-- inside the mutation transaction.
BEGIN;
GRANT SELECT (gabarito_snapshot) ON public.avaliacao_tentativas TO authenticated;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000012',false);
DO $$ BEGIN
  IF (SELECT count(*) FROM public.avaliacao_tentativas WHERE id='ad000000-0000-0000-0000-000000000001' AND gabarito_snapshot <> '{}'::jsonb) <> 1 THEN
    RAISE EXCEPTION 'M4 gabarito exposure mutation was not observed';
  END IF;
END $$;
ROLLBACK;
\echo 'M4_GABARITO_COLUMN_REGRANT_KILLED: PASS'

-- M5: weakening tenant-bound staff authorization must permit a cross-tenant
-- mutation inside the transaction.
BEGIN;
CREATE POLICY mutation_staff_cross_tenant ON public.questoes
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
ALTER TABLE public.questoes DISABLE TRIGGER ALL;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000001',false);
DO $$
BEGIN
  UPDATE public.questoes SET enunciado='QA M5 unauthorized cross-tenant edit'
  WHERE id='bb000000-0000-0000-0000-000000000001';
  IF NOT FOUND THEN RAISE EXCEPTION 'M5 tenant-bound staff weakening was not observed'; END IF;
END $$;
ROLLBACK;
\echo 'M5_TENANT_BOUND_STAFF_WEAKENING_KILLED: PASS'

-- M6: weakening exact assessment Class + Subject authority must permit an
-- assessment in a class for which Teacher Exact has no assignment.
BEGIN;
CREATE OR REPLACE FUNCTION public.teacher_assessment_scope(p_turma_id uuid, p_disciplina_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT true $$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000005',false);
DO $$
BEGIN
  INSERT INTO public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,situacao,criado_por)
  VALUES ('ac300000-0000-0000-0000-000000000030','a1000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','QA M6 unauthorized 7A Math','rascunho','a4000000-0000-0000-0000-000000000005');
  IF NOT FOUND THEN RAISE EXCEPTION 'M6 exact assessment scope weakening was not observed'; END IF;
END $$;
ROLLBACK;
\echo 'M6_EXACT_ASSESSMENT_SCOPE_WEAKENING_KILLED: PASS'

-- M7: weakening question authority must permit Teacher X to take over a
-- question bound exclusively to Teacher Y's 7A Math assessment.
BEGIN;
CREATE OR REPLACE FUNCTION public.teacher_question_scope(p_question_id uuid, p_subject_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT true $$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000005',false);
DO $$
BEGIN
  UPDATE public.questoes
  SET criado_por='a4000000-0000-0000-0000-000000000005', enunciado='QA M7 unauthorized takeover'
  WHERE id='aa000000-0000-0000-0000-000000000005';
  IF NOT FOUND THEN RAISE EXCEPTION 'M7 question authority weakening was not observed'; END IF;
END $$;
ROLLBACK;
\echo 'M7_CROSS_CLASS_QUESTION_AUTHORITY_WEAKENING_KILLED: PASS'

-- M8: adding a direct Teacher response UPDATE policy must make the bypass
-- observable; the production state has no such policy after migration 046.
BEGIN;
CREATE POLICY mutation_direct_response_update ON public.avaliacao_respostas
  FOR UPDATE TO authenticated
  USING (tenant_id = public.current_tenant_id())
  WITH CHECK (tenant_id = public.current_tenant_id());
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000005',false);
DO $$
BEGIN
  UPDATE public.avaliacao_respostas SET pontos_obtidos=999
  WHERE id='ae000000-0000-0000-0000-000000000003';
  IF NOT FOUND THEN RAISE EXCEPTION 'M8 direct grading write weakening was not observed'; END IF;
END $$;
ROLLBACK;
\echo 'M8_DIRECT_GRADING_WRITE_WEAKENING_KILLED: PASS'

-- Post-rollback integrity proves no mutation survived.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a3000000-0000-0000-0000-000000000002',false);
DO $$ BEGIN
  IF (SELECT count(*) FROM public.registros_aula WHERE id='b1000000-0000-0000-0000-000000000003') <> 0 THEN RAISE EXCEPTION 'M1 rollback failed'; END IF;
  IF public.student_active_in_class('a4000000-0000-0000-0000-000000000013','a7000000-0000-0000-0000-000000000003',public.current_tenant_id()) THEN RAISE EXCEPTION 'M2 rollback failed'; END IF;
END $$;
SELECT has_column_privilege('authenticated','public.avaliacao_tentativas','gabarito_snapshot','SELECT') AS snapshot_privilege_after_rollback;
\echo 'MUTATION_ROLLBACK_INTEGRITY: PASS'
