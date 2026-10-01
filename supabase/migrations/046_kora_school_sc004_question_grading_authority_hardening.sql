-- KORA LEARN — Migration 046: SC-004 question and grading authority hardening
-- Forward-only. Historical migrations 001–045 remain unchanged.
--
-- Security boundaries closed here:
--   1) a Teacher may access/mutate an assessment-bound question only when every
--      authoritative assessment relationship is inside the Teacher's exact
--      active Class + Subject assignment;
--   2) direct Teacher writes to student responses are removed; business-validated
--      grading remains on corrigir_resposta_avaliacao(...);
--   3) staff override remains tenant-bound and student submission RPCs remain
--      the supported write path.

DO $$
BEGIN
  IF to_regclass('public.questoes') IS NULL
     OR to_regclass('public.avaliacoes') IS NULL
     OR to_regclass('public.avaliacao_questoes') IS NULL
     OR to_regclass('public.avaliacao_respostas') IS NULL
     OR to_regclass('public.avaliacao_tentativas') IS NULL
  THEN
    RAISE EXCEPTION 'SC-004 R4 prerequisite assessment schema is incomplete'
      USING ERRCODE = '3F000';
  END IF;
  IF to_regprocedure('public.teacher_assessment_scope(uuid,uuid)') IS NULL
     OR to_regprocedure('public.current_tenant_id()') IS NULL
  THEN
    RAISE EXCEPTION 'SC-004 R4 prerequisite authorization functions are missing'
      USING ERRCODE = '42883';
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 1. Assessment-bound question authority
-- ---------------------------------------------------------------------------
-- Questions are reusable records in the existing bank. An unlinked question
-- remains subject-bank scoped. Once linked to one or more assessments, the
-- conservative rule is ALL linked assessments: a teacher must hold an exact
-- active Class + Subject assignment for every link, and each link must retain
-- the same Subject. This prevents a question owned by another class/teacher
-- from becoming mutable merely by changing criado_por.
CREATE OR REPLACE FUNCTION public.teacher_question_scope(
  p_question_id uuid,
  p_subject_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.questoes q
    WHERE q.id = p_question_id
      AND q.tenant_id = public.current_tenant_id()
      AND q.disciplina_id = p_subject_id
      AND (
        (
          NOT EXISTS (
            SELECT 1
            FROM public.avaliacao_questoes aq
            WHERE aq.questao_id = q.id
          )
          AND q.criado_por = public.current_usuario_id()
          AND public.teacher_has_subject_assignment(p_subject_id)
        )
        OR (
          EXISTS (
            SELECT 1
            FROM public.avaliacao_questoes aq
            WHERE aq.questao_id = q.id
          )
          AND NOT EXISTS (
            SELECT 1
            FROM public.avaliacao_questoes aq
            JOIN public.avaliacoes a ON a.id = aq.avaliacao_id
            WHERE aq.questao_id = q.id
              AND (
                a.tenant_id IS DISTINCT FROM q.tenant_id
                OR a.disciplina_id IS DISTINCT FROM p_subject_id
                OR NOT public.teacher_assessment_scope(a.turma_id, p_subject_id)
              )
          )
        )
      )
  )
$$;

REVOKE ALL ON FUNCTION public.teacher_question_scope(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.teacher_question_scope(uuid, uuid) TO authenticated;

-- Assessment-bound questions are selected/deleted/updated only through the
-- authoritative relationship predicate. INSERT has no existing row to inspect,
-- so a new question is subject-bank scoped until it is linked to an assessment.
DROP POLICY IF EXISTS questoes_teacher_assignment ON public.questoes;
DROP POLICY IF EXISTS questoes_teacher_select_r4 ON public.questoes;
DROP POLICY IF EXISTS questoes_teacher_insert_r4 ON public.questoes;
DROP POLICY IF EXISTS questoes_teacher_update_r4 ON public.questoes;
DROP POLICY IF EXISTS questoes_teacher_delete_r4 ON public.questoes;

CREATE POLICY questoes_teacher_select_r4 ON public.questoes
  FOR SELECT TO authenticated
  USING (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_question_scope(id, disciplina_id)
    )
  );

CREATE POLICY questoes_teacher_insert_r4 ON public.questoes
  FOR INSERT TO authenticated
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

CREATE POLICY questoes_teacher_update_r4 ON public.questoes
  FOR UPDATE TO authenticated
  USING (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_question_scope(id, disciplina_id)
    )
  )
  WITH CHECK (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_question_scope(id, disciplina_id)
      AND public.teacher_has_subject_assignment(disciplina_id)
      AND criado_por = public.current_usuario_id()
    )
  );

CREATE POLICY questoes_teacher_delete_r4 ON public.questoes
  FOR DELETE TO authenticated
  USING (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_question_scope(id, disciplina_id)
    )
  );

-- ---------------------------------------------------------------------------
-- 2. Direct response-table writes are not a grading API
-- ---------------------------------------------------------------------------
-- Keep direct SELECT for the same-tenant staff/teacher surfaces where the
-- caller is authorized to inspect the response. Remove UPDATE/DELETE/INSERT
-- policies for authenticated callers. Student submission and teacher grading
-- continue through SECURITY DEFINER RPCs that validate their own contracts.
DROP POLICY IF EXISTS respostas_teacher_assignment ON public.avaliacao_respostas;
DROP POLICY IF EXISTS respostas_staff_select_r4 ON public.avaliacao_respostas;
DROP POLICY IF EXISTS respostas_teacher_select_r4 ON public.avaliacao_respostas;

CREATE POLICY respostas_staff_select_r4 ON public.avaliacao_respostas
  FOR SELECT TO authenticated
  USING (
    public.is_staff()
    AND tenant_id = public.current_tenant_id()
  );

CREATE POLICY respostas_teacher_select_r4 ON public.avaliacao_respostas
  FOR SELECT TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND EXISTS (
      SELECT 1
      FROM public.avaliacao_tentativas t
      JOIN public.avaliacoes a ON a.id = t.avaliacao_id
      WHERE t.id = avaliacao_respostas.tentativa_id
        AND t.tenant_id = public.current_tenant_id()
        AND public.teacher_assessment_scope(a.turma_id, a.disciplina_id)
    )
  );

-- ---------------------------------------------------------------------------
-- 3. Grading RPC remains the sole Teacher mutation path
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.corrigir_resposta_avaliacao(
  p_resposta_id uuid,
  p_pontos numeric,
  p_comentario text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_resposta public.avaliacao_respostas%rowtype;
  v_tentativa public.avaliacao_tentativas%rowtype;
  v_avaliacao public.avaliacoes%rowtype;
  v_max numeric;
  v_nota numeric;
  v_pendentes integer;
  v_percentual numeric;
  v_situacao public.situacao_tentativa;
BEGIN
  IF NOT public.is_staff() AND NOT public.teacher_assessment_scope(
    (
      SELECT a.turma_id
      FROM public.avaliacoes a
      JOIN public.avaliacao_tentativas t ON t.avaliacao_id = a.id
      JOIN public.avaliacao_respostas r ON r.tentativa_id = t.id
      WHERE r.id = p_resposta_id
    ),
    (
      SELECT a.disciplina_id
      FROM public.avaliacoes a
      JOIN public.avaliacao_tentativas t ON t.avaliacao_id = a.id
      JOIN public.avaliacao_respostas r ON r.tentativa_id = t.id
      WHERE r.id = p_resposta_id
    )
  ) THEN
    RAISE EXCEPTION 'Professor sem assignment exato para corrigir resposta'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_resposta
  FROM public.avaliacao_respostas
  WHERE id = p_resposta_id
    AND tenant_id = public.current_tenant_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Resposta não encontrada';
  END IF;

  SELECT * INTO v_tentativa
  FROM public.avaliacao_tentativas
  WHERE id = v_resposta.tentativa_id
    AND tenant_id = public.current_tenant_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tentativa não encontrada';
  END IF;

  SELECT * INTO v_avaliacao
  FROM public.avaliacoes
  WHERE id = v_tentativa.avaliacao_id
    AND tenant_id = public.current_tenant_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Avaliação não encontrada';
  END IF;

  IF p_pontos < 0 OR p_pontos > COALESCE((
    SELECT (q->>'pontos')::numeric
    FROM jsonb_array_elements(v_tentativa.questoes_ordem) q
    WHERE (q->>'questao_id')::uuid = v_resposta.questao_id
  ), 0) THEN
    RAISE EXCEPTION 'Pontuação fora do limite da questão';
  END IF;

  UPDATE public.avaliacao_respostas
  SET pontos_obtidos = p_pontos,
      comentario = p_comentario,
      corrigida = true
  WHERE id = p_resposta_id;

  SELECT COALESCE(sum((q->>'pontos')::numeric), 0)
    INTO v_max
  FROM jsonb_array_elements(v_tentativa.questoes_ordem) q;
  SELECT COALESCE(sum(pontos_obtidos), 0), count(*) FILTER (WHERE NOT corrigida)
    INTO v_nota, v_pendentes
  FROM public.avaliacao_respostas
  WHERE tentativa_id = v_tentativa.id;
  v_percentual := CASE WHEN v_max = 0 THEN 0 ELSE round(100 * v_nota / v_max, 2) END;
  v_situacao := CASE
    WHEN v_pendentes = 0 THEN 'corrigida'::public.situacao_tentativa
    ELSE 'enviada'::public.situacao_tentativa
  END;

  UPDATE public.avaliacao_tentativas
  SET nota = v_nota,
      nota_maxima = v_max,
      percentual = v_percentual,
      situacao = v_situacao,
      aprovada = CASE WHEN v_pendentes = 0 THEN v_percentual >= v_avaliacao.nota_minima ELSE NULL END
  WHERE id = v_tentativa.id;

  RETURN jsonb_build_object(
    'tentativa_id', v_tentativa.id,
    'situacao', v_situacao,
    'percentual', v_percentual
  );
END
$$;

REVOKE ALL ON FUNCTION public.corrigir_resposta_avaliacao(uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.corrigir_resposta_avaliacao(uuid, numeric, text) TO authenticated;

-- No anonymous execution or arbitrary public access is introduced by R4.
-- Existing 001–045 student submission and gabarito column boundaries remain in force.
