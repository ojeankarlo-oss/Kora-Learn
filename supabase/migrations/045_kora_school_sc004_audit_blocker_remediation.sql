-- KORA LEARN — Migration 045: SC-004C/D independent audit blocker remediation
-- Forward-only. Historical migrations 001-044 remain unchanged.
--
-- This migration closes three runtime paths:
--   1) staff branches on assessment policies are tenant-bound;
--   2) teacher assessment authority requires an exact Class + Subject assignment;
--   3) student_active_in_class cannot be used as an arbitrary-tenant oracle.
--
-- The existing student policies remain separate. Their effective row identity
-- is still checked by the QA harness after this policy inventory.

DO $$
BEGIN
  IF to_regclass('public.questoes') IS NULL
     OR to_regclass('public.avaliacoes') IS NULL
     OR to_regclass('public.avaliacao_questoes') IS NULL
     OR to_regclass('public.avaliacao_tentativas') IS NULL
     OR to_regclass('public.avaliacao_respostas') IS NULL
  THEN
    RAISE EXCEPTION 'SC-004 R3 prerequisite assessment schema is incomplete'
      USING ERRCODE = '3F000';
  END IF;
  IF to_regprocedure('public.teacher_assessment_scope(uuid,uuid)') IS NULL
     OR to_regprocedure('public.student_active_in_class(uuid,uuid,uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'SC-004 R3 prerequisite authorization functions are missing'
      USING ERRCODE = '42883';
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 1. Course-wide assessment authority is never a teacher authority path.
--    A teacher must have an active exact Class + Subject assignment.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.teacher_assessment_scope(
  p_turma_id uuid,
  p_disciplina_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_turma_id IS NULL OR p_disciplina_id IS NULL THEN false
    ELSE public.teacher_has_assignment(p_turma_id, p_disciplina_id)
  END
$$;

-- ---------------------------------------------------------------------------
-- 2. The helper is an internal RLS primitive. It retains authenticated
--    EXECUTE because presencas policies invoke it as authenticated, but the
--    supplied tenant is no longer authority: it must equal the session tenant.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.student_active_in_class(
  p_student_id uuid,
  p_class_id uuid,
  p_tenant_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public.current_tenant_id() IS NOT NULL
    AND p_tenant_id = public.current_tenant_id()
    AND EXISTS (
      SELECT 1
      FROM public.matriculas m
      JOIN public.turmas t ON t.id = m.turma_id
        AND t.tenant_id = m.tenant_id
        AND t.ativa IS TRUE
        AND t.unidade_id IS NOT NULL
      JOIN public.unidades un ON un.id = t.unidade_id
        AND un.tenant_id = m.tenant_id
        AND un.ativo IS TRUE
      JOIN public.usuarios u ON u.id = m.usuario_id
        AND u.tenant_id = m.tenant_id
        AND u.ativo IS TRUE
      WHERE m.usuario_id = p_student_id
        AND m.turma_id = p_class_id
        AND m.tenant_id = public.current_tenant_id()
        AND m.situacao = 'ativa'
    )
$$;

REVOKE EXECUTE ON FUNCTION public.student_active_in_class(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.student_active_in_class(uuid, uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Replace the five staff authorization branches. Every staff branch is
--    explicitly tenant-bound. Teacher branches remain exact assignment paths.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS questoes_teacher_assignment ON public.questoes;
CREATE POLICY questoes_teacher_assignment ON public.questoes
  FOR ALL TO authenticated
  USING (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_has_subject_assignment(disciplina_id)
    )
  )
  WITH CHECK (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_has_subject_assignment(disciplina_id)
      AND criado_por = public.current_usuario_id()
    )
  );

DROP POLICY IF EXISTS avaliacoes_teacher_assignment ON public.avaliacoes;
CREATE POLICY avaliacoes_teacher_assignment ON public.avaliacoes
  FOR ALL TO authenticated
  USING (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_assessment_scope(turma_id, disciplina_id)
    )
  )
  WITH CHECK (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_assessment_scope(turma_id, disciplina_id)
      AND criado_por = public.current_usuario_id()
    )
  );

DROP POLICY IF EXISTS avaliacao_questoes_teacher_assignment ON public.avaliacao_questoes;
CREATE POLICY avaliacao_questoes_teacher_assignment ON public.avaliacao_questoes
  FOR ALL TO authenticated
  USING (
    (
      public.is_staff()
      AND EXISTS (
        SELECT 1
        FROM public.avaliacoes a
        JOIN public.questoes q ON q.id = avaliacao_questoes.questao_id
        WHERE a.id = avaliacao_questoes.avaliacao_id
          AND a.tenant_id = public.current_tenant_id()
          AND q.tenant_id = a.tenant_id
          AND q.disciplina_id = a.disciplina_id
      )
    )
    OR EXISTS (
      SELECT 1
      FROM public.avaliacoes a
      JOIN public.questoes q ON q.id = avaliacao_questoes.questao_id
      WHERE a.id = avaliacao_questoes.avaliacao_id
        AND a.tenant_id = public.current_tenant_id()
        AND q.tenant_id = a.tenant_id
        AND q.disciplina_id = a.disciplina_id
        AND public.teacher_assessment_scope(a.turma_id, a.disciplina_id)
    )
  )
  WITH CHECK (
    (
      public.is_staff()
      AND EXISTS (
        SELECT 1
        FROM public.avaliacoes a
        JOIN public.questoes q ON q.id = avaliacao_questoes.questao_id
        WHERE a.id = avaliacao_questoes.avaliacao_id
          AND a.tenant_id = public.current_tenant_id()
          AND q.tenant_id = a.tenant_id
          AND q.disciplina_id = a.disciplina_id
      )
    )
    OR EXISTS (
      SELECT 1
      FROM public.avaliacoes a
      JOIN public.questoes q ON q.id = avaliacao_questoes.questao_id
      WHERE a.id = avaliacao_questoes.avaliacao_id
        AND a.tenant_id = public.current_tenant_id()
        AND q.tenant_id = a.tenant_id
        AND q.disciplina_id = a.disciplina_id
        AND public.teacher_assessment_scope(a.turma_id, a.disciplina_id)
    )
  );

DROP POLICY IF EXISTS tentativas_teacher_assignment ON public.avaliacao_tentativas;
CREATE POLICY tentativas_teacher_assignment ON public.avaliacao_tentativas
  FOR SELECT TO authenticated
  USING (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR EXISTS (
      SELECT 1
      FROM public.avaliacoes a
      WHERE a.id = avaliacao_tentativas.avaliacao_id
        AND a.tenant_id = public.current_tenant_id()
        AND public.teacher_assessment_scope(a.turma_id, a.disciplina_id)
    )
  );

DROP POLICY IF EXISTS respostas_teacher_assignment ON public.avaliacao_respostas;
CREATE POLICY respostas_teacher_assignment ON public.avaliacao_respostas
  FOR ALL TO authenticated
  USING (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR EXISTS (
      SELECT 1
      FROM public.avaliacao_tentativas t
      JOIN public.avaliacoes a ON a.id = t.avaliacao_id
      WHERE t.id = avaliacao_respostas.tentativa_id
        AND t.tenant_id = public.current_tenant_id()
        AND public.teacher_assessment_scope(a.turma_id, a.disciplina_id)
    )
  )
  WITH CHECK (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR EXISTS (
      SELECT 1
      FROM public.avaliacao_tentativas t
      JOIN public.avaliacoes a ON a.id = t.avaliacao_id
      WHERE t.id = avaliacao_respostas.tentativa_id
        AND t.tenant_id = public.current_tenant_id()
        AND public.teacher_assessment_scope(a.turma_id, a.disciplina_id)
    )
  );
