-- KORA LEARN — Migration 047: SC-004 academic configuration authority hardening
-- Forward-only. Historical migrations 001–046 remain unchanged.
--
-- Product boundary:
--   * cursos and disciplinas are institutional configuration/master data;
--   * aulas and materiais_apoio are catalog/course resources because their
--     schema has no turma_id and cannot express an exact Class + Subject
--     teacher assignment;
--   * class-specific teacher-authored resources remain in materiais_professor,
--     whose 042 policy already binds Teacher -> Assignment -> Class + Subject.
--
-- Regular Teachers remain able to read their tenant catalog, but cannot mutate
-- management/configuration objects merely because is_docente() is true.
-- Staff writes remain strictly bound to current_tenant_id().

DO $$
BEGIN
  IF to_regclass('public.cursos') IS NULL
     OR to_regclass('public.disciplinas') IS NULL
     OR to_regclass('public.aulas') IS NULL
     OR to_regclass('public.materiais_apoio') IS NULL
  THEN
    RAISE EXCEPTION 'SC-004 R5 academic configuration schema is incomplete'
      USING ERRCODE = '3F000';
  END IF;
END
$$;

-- Catalog/master-data management is staff-only. The existing SELECT policies
-- are intentionally preserved for authenticated tenant members.
DROP POLICY IF EXISTS cursos_write ON public.cursos;
DROP POLICY IF EXISTS cursos_staff_write_r5 ON public.cursos;
CREATE POLICY cursos_staff_write_r5 ON public.cursos
  FOR ALL TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND public.is_staff()
  )
  WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND public.is_staff()
  );

DROP POLICY IF EXISTS disciplinas_write ON public.disciplinas;
DROP POLICY IF EXISTS disciplinas_staff_write_r5 ON public.disciplinas;
CREATE POLICY disciplinas_staff_write_r5 ON public.disciplinas
  FOR ALL TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND public.is_staff()
  )
  WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND public.is_staff()
  );

-- These two legacy tables are course-level resources (no turma_id). Keeping
-- them teacher-writable would grant tenant-wide mutation with no safe way to
-- bind the write to an exact Class + Subject assignment. Teacher-authored,
-- class-specific material uses public.materiais_professor instead.
DROP POLICY IF EXISTS aulas_write ON public.aulas;
DROP POLICY IF EXISTS aulas_staff_write_r5 ON public.aulas;
CREATE POLICY aulas_staff_write_r5 ON public.aulas
  FOR ALL TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND public.is_staff()
  )
  WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND public.is_staff()
  );

DROP POLICY IF EXISTS materiais_write ON public.materiais_apoio;
DROP POLICY IF EXISTS materiais_staff_write_r5 ON public.materiais_apoio;
CREATE POLICY materiais_staff_write_r5 ON public.materiais_apoio
  FOR ALL TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND public.is_staff()
  )
  WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND public.is_staff()
  );

COMMENT ON POLICY cursos_staff_write_r5 ON public.cursos IS
  'SC-004 R5: institutional course lifecycle/configuration is staff-only and tenant-bound';
COMMENT ON POLICY disciplinas_staff_write_r5 ON public.disciplinas IS
  'SC-004 R5: canonical Subject master-data is staff-only and tenant-bound';
COMMENT ON POLICY aulas_staff_write_r5 ON public.aulas IS
  'SC-004 R5: catalog-level lesson resources are staff-only because no exact Class binding exists';
COMMENT ON POLICY materiais_staff_write_r5 ON public.materiais_apoio IS
  'SC-004 R5: catalog-level support resources are staff-only because no exact Class binding exists';

-- ---------------------------------------------------------------------------
-- R5.1: academic evidence cannot be physically cascade-deleted by a caller.
-- ---------------------------------------------------------------------------
-- The existing FK graph is intentionally destructive:
--   avaliacoes -> avaliacao_tentativas -> avaliacao_respostas
-- and also avaliacoes -> avaliacao_questoes. A normal Teacher DELETE on an
-- assessment must therefore be narrowed separately from ordinary assessment
-- read/insert/update authority. An attempt is evidence even when it has no
-- response yet; this protects the student's in-progress work as well as a
-- submitted/corrected result.
DO $$
BEGIN
  IF to_regclass('public.avaliacoes') IS NULL
     OR to_regclass('public.avaliacao_tentativas') IS NULL
     OR to_regclass('public.avaliacao_respostas') IS NULL
  THEN
    RAISE EXCEPTION 'SC-004 R5.1 assessment evidence schema is incomplete'
      USING ERRCODE = '3F000';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.sc004_assessment_has_evidence(p_assessment_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.avaliacao_tentativas t
    WHERE t.avaliacao_id = p_assessment_id
  )
$$;

REVOKE ALL ON FUNCTION public.sc004_assessment_has_evidence(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sc004_assessment_has_evidence(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.sc004_block_assessment_evidence_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF public.sc004_assessment_has_evidence(OLD.id) THEN
    RAISE EXCEPTION 'Avaliação com evidência acadêmica não pode ser excluída fisicamente'
      USING ERRCODE = '42501';
  END IF;
  RETURN OLD;
END
$$;

REVOKE ALL ON FUNCTION public.sc004_block_assessment_evidence_delete() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sc004_block_assessment_evidence_delete() TO authenticated;

DROP TRIGGER IF EXISTS trg_sc004_assessment_evidence_delete ON public.avaliacoes;
CREATE TRIGGER trg_sc004_assessment_evidence_delete
  BEFORE DELETE ON public.avaliacoes
  FOR EACH ROW
  EXECUTE FUNCTION public.sc004_block_assessment_evidence_delete();

-- Remove both the original 017 tenant-wide docente policy and the 045 FOR ALL
-- assignment policy. A FOR ALL policy would silently re-enable DELETE. Read,
-- insert, update and delete are deliberately separate below.
DROP POLICY IF EXISTS avaliacoes_docente ON public.avaliacoes;
DROP POLICY IF EXISTS avaliacoes_teacher_assignment ON public.avaliacoes;
DROP POLICY IF EXISTS avaliacoes_teacher_select_r51 ON public.avaliacoes;
DROP POLICY IF EXISTS avaliacoes_teacher_insert_r51 ON public.avaliacoes;
DROP POLICY IF EXISTS avaliacoes_teacher_update_r51 ON public.avaliacoes;
DROP POLICY IF EXISTS avaliacoes_teacher_delete_r51 ON public.avaliacoes;

CREATE POLICY avaliacoes_teacher_select_r51 ON public.avaliacoes
  FOR SELECT TO authenticated
  USING (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_assessment_scope(turma_id, disciplina_id)
    )
  );

CREATE POLICY avaliacoes_teacher_insert_r51 ON public.avaliacoes
  FOR INSERT TO authenticated
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

CREATE POLICY avaliacoes_teacher_update_r51 ON public.avaliacoes
  FOR UPDATE TO authenticated
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

-- Staff may administer an unused assessment inside its tenant. Once any
-- student attempt exists, the trigger above denies the physical DELETE even
-- to Staff; academic evidence is never removed by this path.
CREATE POLICY avaliacoes_teacher_delete_r51 ON public.avaliacoes
  FOR DELETE TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND (
      (
        public.is_staff()
        AND NOT public.sc004_assessment_has_evidence(id)
      )
      OR (
        NOT public.is_staff()
        AND criado_por = public.current_usuario_id()
        AND public.teacher_assessment_scope(turma_id, disciplina_id)
        AND NOT public.sc004_assessment_has_evidence(id)
      )
    )
  );

-- ---------------------------------------------------------------------------
-- R5.1: grading requires a submitted attempt and locks the source state.
-- ---------------------------------------------------------------------------
-- `enviada` is the existing lifecycle state produced by the Student submit
-- RPC when correction remains pending. `em_andamento` is never gradeable;
-- `corrigida` and `expirada` are terminal/non-gradeable for this RPC.
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
  v_updated integer;
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
    AND tenant_id = public.current_tenant_id()
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Resposta não encontrada';
  END IF;

  SELECT * INTO v_tentativa
  FROM public.avaliacao_tentativas
  WHERE id = v_resposta.tentativa_id
    AND tenant_id = public.current_tenant_id()
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tentativa não encontrada';
  END IF;

  IF v_tentativa.situacao <> 'enviada'::public.situacao_tentativa THEN
    RAISE EXCEPTION 'Tentativa ainda não está enviada para correção'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_avaliacao
  FROM public.avaliacoes
  WHERE id = v_tentativa.avaliacao_id
    AND tenant_id = public.current_tenant_id()
  FOR SHARE;
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

  -- The row lock above serializes this transition. The source-state predicate
  -- makes the lifecycle precondition authoritative at the UPDATE boundary.
  UPDATE public.avaliacao_tentativas
  SET nota = v_nota,
      nota_maxima = v_max,
      percentual = v_percentual,
      situacao = v_situacao,
      aprovada = CASE WHEN v_pendentes = 0 THEN v_percentual >= v_avaliacao.nota_minima ELSE NULL END
  WHERE id = v_tentativa.id
    AND situacao = 'enviada'::public.situacao_tentativa;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'Tentativa mudou de estado durante a correção'
      USING ERRCODE = '40001';
  END IF;

  RETURN jsonb_build_object(
    'tentativa_id', v_tentativa.id,
    'situacao', v_situacao,
    'percentual', v_percentual
  );
END
$$;

REVOKE ALL ON FUNCTION public.corrigir_resposta_avaliacao(uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.corrigir_resposta_avaliacao(uuid, numeric, text) TO authenticated;

-- No anonymous execution or arbitrary public access is introduced by R5.1.
-- Existing 001–046 student submission and gabarito column boundaries remain in force.
