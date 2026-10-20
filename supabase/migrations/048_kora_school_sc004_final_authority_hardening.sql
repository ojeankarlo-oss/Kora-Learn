-- KORA LEARN — Migration 048: SC-004 final authority hardening
-- Forward-only. Historical migrations 001–047 remain unchanged.
--
-- This migration closes only controls reproduced by the SC-004 R5.2 audit:
--   * immutable Teacher provenance and question authorship;
--   * immutable assessment/question structure after academic evidence;
--   * no parent DELETE may cascade away an evidenced attempt;
--   * serialized student submission with a state-guarded final update;
--   * explicit test-time inventory of TRUNCATE absence for anon/authenticated.

DO $$
BEGIN
  IF to_regclass('public.questoes') IS NULL
     OR to_regclass('public.avaliacoes') IS NULL
     OR to_regclass('public.avaliacao_questoes') IS NULL
     OR to_regclass('public.avaliacao_tentativas') IS NULL
     OR to_regclass('public.avaliacao_respostas') IS NULL
     OR to_regclass('public.matriculas') IS NULL
     OR to_regclass('public.usuarios') IS NULL
  THEN
    RAISE EXCEPTION 'SC-004 R5.2 prerequisite academic schema is incomplete'
      USING ERRCODE = '3F000';
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 1. Teacher provenance and academic-content immutability
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sc004_guard_academic_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_has_evidence boolean := false;
BEGIN
  IF TG_OP <> 'UPDATE' THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'questoes' THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.avaliacao_questoes aq
      JOIN public.avaliacao_tentativas t ON t.avaliacao_id = aq.avaliacao_id
      WHERE aq.questao_id = OLD.id
    ) INTO v_has_evidence;

    -- A regular Teacher cannot manufacture ownership, rebind a question to
    -- another subject/tenant, or edit another Teacher's bound question merely
    -- by using a shared scope.
    IF NOT public.is_staff()
       AND (
         NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
         OR NEW.disciplina_id IS DISTINCT FROM OLD.disciplina_id
         OR NEW.criado_por IS DISTINCT FROM OLD.criado_por
       )
    THEN
      RAISE EXCEPTION 'A autoria da questão não pode ser transferida por um docente'
        USING ERRCODE = '42501';
    END IF;

    IF NOT public.is_staff()
       AND OLD.criado_por IS DISTINCT FROM public.current_usuario_id()
       AND (
         NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
         OR NEW.disciplina_id IS DISTINCT FROM OLD.disciplina_id
         OR NEW.enunciado IS DISTINCT FROM OLD.enunciado
         OR NEW.tipo IS DISTINCT FROM OLD.tipo
         OR NEW.dificuldade IS DISTINCT FROM OLD.dificuldade
         OR NEW.alternativas IS DISTINCT FROM OLD.alternativas
         OR NEW.resposta_correta IS DISTINCT FROM OLD.resposta_correta
         OR NEW.resposta_esperada IS DISTINCT FROM OLD.resposta_esperada
         OR NEW.pontos IS DISTINCT FROM OLD.pontos
         OR NEW.ativa IS DISTINCT FROM OLD.ativa
       )
    THEN
      RAISE EXCEPTION 'Somente o autor da questão ou a administração pode alterar seu conteúdo'
        USING ERRCODE = '42501';
    END IF;

    -- Once an attempt exists, the question snapshot and its grading material
    -- are evidence-bearing and cannot be rewritten by any caller.
    IF v_has_evidence
       AND (
         NEW.criado_por IS DISTINCT FROM OLD.criado_por
         OR NEW.enunciado IS DISTINCT FROM OLD.enunciado
         OR NEW.tipo IS DISTINCT FROM OLD.tipo
         OR NEW.dificuldade IS DISTINCT FROM OLD.dificuldade
         OR NEW.alternativas IS DISTINCT FROM OLD.alternativas
         OR NEW.resposta_correta IS DISTINCT FROM OLD.resposta_correta
         OR NEW.resposta_esperada IS DISTINCT FROM OLD.resposta_esperada
         OR NEW.pontos IS DISTINCT FROM OLD.pontos
         OR NEW.ativa IS DISTINCT FROM OLD.ativa
       )
    THEN
      RAISE EXCEPTION 'Questão vinculada a evidência acadêmica não pode ser alterada'
        USING ERRCODE = '42501';
    END IF;
  ELSIF TG_TABLE_NAME = 'avaliacoes' THEN
    SELECT public.sc004_assessment_has_evidence(OLD.id) INTO v_has_evidence;

    -- A Teacher may not turn a shared assignment into ownership of an
    -- assessment. The existing RLS scope remains necessary and this trigger
    -- makes the provenance invariant independent of the post-image policy.
    IF NOT public.is_staff()
       AND NEW.criado_por IS DISTINCT FROM OLD.criado_por
    THEN
      RAISE EXCEPTION 'A autoria da avaliação não pode ser transferida por um docente'
        USING ERRCODE = '23514';
    END IF;

    -- Assessment configuration and class/subject structure are frozen once
    -- an attempt exists. This prevents a valid historical result from being
    -- reinterpreted after submission.
    IF v_has_evidence
       AND (
         NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
         OR NEW.curso_id IS DISTINCT FROM OLD.curso_id
         OR NEW.disciplina_id IS DISTINCT FROM OLD.disciplina_id
         OR NEW.turma_id IS DISTINCT FROM OLD.turma_id
         OR NEW.titulo IS DISTINCT FROM OLD.titulo
         OR NEW.descricao IS DISTINCT FROM OLD.descricao
         OR NEW.situacao IS DISTINCT FROM OLD.situacao
         OR NEW.modo_aplicacao IS DISTINCT FROM OLD.modo_aplicacao
         OR NEW.regra_liberacao IS DISTINCT FROM OLD.regra_liberacao
         OR NEW.intervalo_dias IS DISTINCT FROM OLD.intervalo_dias
         OR NEW.tentativas_permitidas IS DISTINCT FROM OLD.tentativas_permitidas
         OR NEW.nota_minima IS DISTINCT FROM OLD.nota_minima
         OR NEW.expira_em_dias IS DISTINCT FROM OLD.expira_em_dias
         OR NEW.quantidade_questoes IS DISTINCT FROM OLD.quantidade_questoes
         OR NEW.embaralhar_questoes IS DISTINCT FROM OLD.embaralhar_questoes
         OR NEW.embaralhar_alternativas IS DISTINCT FROM OLD.embaralhar_alternativas
         OR NEW.disponivel_em IS DISTINCT FROM OLD.disponivel_em
         OR NEW.criado_por IS DISTINCT FROM OLD.criado_por
       )
    THEN
      RAISE EXCEPTION 'Avaliação com evidência acadêmica não pode ter sua estrutura ou configuração alterada'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION public.sc004_guard_academic_update() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_sc004_question_authority_update ON public.questoes;
CREATE TRIGGER trg_sc004_question_authority_update
  BEFORE UPDATE ON public.questoes
  FOR EACH ROW
  EXECUTE FUNCTION public.sc004_guard_academic_update();

-- A shared Class + Subject assignment is enough to inspect a bound question,
-- but it is not ownership of the reusable question record. Keep DELETE
-- creator-bound for regular Teachers; staff remains tenant-bound.
DROP POLICY IF EXISTS questoes_teacher_delete_r4 ON public.questoes;
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
      AND criado_por = public.current_usuario_id()
    )
  );

DROP TRIGGER IF EXISTS trg_sc004_assessment_authority_update ON public.avaliacoes;
CREATE TRIGGER trg_sc004_assessment_authority_update
  BEFORE UPDATE ON public.avaliacoes
  FOR EACH ROW
  EXECUTE FUNCTION public.sc004_guard_academic_update();

CREATE OR REPLACE FUNCTION public.sc004_guard_evidence_structure()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_assessment_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_assessment_id := OLD.avaliacao_id;
  ELSE
    v_assessment_id := NEW.avaliacao_id;
  END IF;
  IF public.sc004_assessment_has_evidence(v_assessment_id) THEN
    RAISE EXCEPTION 'A composição da avaliação não pode ser alterada após evidência acadêmica'
      USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION public.sc004_guard_evidence_structure() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_sc004_assessment_question_evidence ON public.avaliacao_questoes;
CREATE TRIGGER trg_sc004_assessment_question_evidence
  BEFORE INSERT OR UPDATE OR DELETE ON public.avaliacao_questoes
  FOR EACH ROW
  EXECUTE FUNCTION public.sc004_guard_evidence_structure();

-- ---------------------------------------------------------------------------
-- 2. Parent DELETE cannot destroy academic evidence through FK cascades
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sc004_guard_evidence_parent_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_has_evidence boolean := false;
BEGIN
  IF TG_TABLE_NAME = 'matriculas' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.avaliacao_tentativas t WHERE t.matricula_id = OLD.id
    ) INTO v_has_evidence;
  ELSIF TG_TABLE_NAME = 'usuarios' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.avaliacao_tentativas t WHERE t.usuario_id = OLD.id
    ) INTO v_has_evidence;
  ELSIF TG_TABLE_NAME = 'turmas' THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.avaliacao_tentativas t
      JOIN public.avaliacoes a ON a.id = t.avaliacao_id
      WHERE a.turma_id = OLD.id
    ) INTO v_has_evidence;
  ELSIF TG_TABLE_NAME = 'disciplinas' THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.avaliacao_tentativas t
      JOIN public.avaliacoes a ON a.id = t.avaliacao_id
      WHERE a.disciplina_id = OLD.id
    ) INTO v_has_evidence;
  ELSIF TG_TABLE_NAME = 'cursos' THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.avaliacao_tentativas t
      JOIN public.avaliacoes a ON a.id = t.avaliacao_id
      WHERE a.curso_id = OLD.id
    ) INTO v_has_evidence;
  ELSIF TG_TABLE_NAME = 'unidades' THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.avaliacao_tentativas t
      JOIN public.avaliacoes a ON a.id = t.avaliacao_id
      JOIN public.turmas tr ON tr.id = a.turma_id
      WHERE tr.unidade_id = OLD.id
    ) INTO v_has_evidence;
  ELSIF TG_TABLE_NAME = 'tenants' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.avaliacao_tentativas t WHERE t.tenant_id = OLD.id
    ) INTO v_has_evidence;
  END IF;

  IF v_has_evidence THEN
    RAISE EXCEPTION 'Registro acadêmico com evidência não pode ser excluído fisicamente'
      USING ERRCODE = '42501';
  END IF;

  RETURN OLD;
END
$$;

REVOKE ALL ON FUNCTION public.sc004_guard_evidence_parent_delete() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_sc004_matricula_evidence_delete ON public.matriculas;
CREATE TRIGGER trg_sc004_matricula_evidence_delete
  BEFORE DELETE ON public.matriculas
  FOR EACH ROW EXECUTE FUNCTION public.sc004_guard_evidence_parent_delete();

DROP TRIGGER IF EXISTS trg_sc004_usuario_evidence_delete ON public.usuarios;
CREATE TRIGGER trg_sc004_usuario_evidence_delete
  BEFORE DELETE ON public.usuarios
  FOR EACH ROW EXECUTE FUNCTION public.sc004_guard_evidence_parent_delete();

DROP TRIGGER IF EXISTS trg_sc004_turma_evidence_delete ON public.turmas;
CREATE TRIGGER trg_sc004_turma_evidence_delete
  BEFORE DELETE ON public.turmas
  FOR EACH ROW EXECUTE FUNCTION public.sc004_guard_evidence_parent_delete();

DROP TRIGGER IF EXISTS trg_sc004_disciplina_evidence_delete ON public.disciplinas;
CREATE TRIGGER trg_sc004_disciplina_evidence_delete
  BEFORE DELETE ON public.disciplinas
  FOR EACH ROW EXECUTE FUNCTION public.sc004_guard_evidence_parent_delete();

DROP TRIGGER IF EXISTS trg_sc004_curso_evidence_delete ON public.cursos;
CREATE TRIGGER trg_sc004_curso_evidence_delete
  BEFORE DELETE ON public.cursos
  FOR EACH ROW EXECUTE FUNCTION public.sc004_guard_evidence_parent_delete();

DROP TRIGGER IF EXISTS trg_sc004_unidade_evidence_delete ON public.unidades;
CREATE TRIGGER trg_sc004_unidade_evidence_delete
  BEFORE DELETE ON public.unidades
  FOR EACH ROW EXECUTE FUNCTION public.sc004_guard_evidence_parent_delete();

DROP TRIGGER IF EXISTS trg_sc004_tenant_evidence_delete ON public.tenants;
CREATE TRIGGER trg_sc004_tenant_evidence_delete
  BEFORE DELETE ON public.tenants
  FOR EACH ROW EXECUTE FUNCTION public.sc004_guard_evidence_parent_delete();

-- ---------------------------------------------------------------------------
-- 3. Serialize student submission and keep the final state transition atomic
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.iniciar_tentativa_avaliacao(
  p_avaliacao_id uuid,
  p_matricula_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_avaliacao avaliacoes%rowtype;
  v_matricula matriculas%rowtype;
  v_usuario_id uuid := public.current_usuario_id();
  v_numero integer;
  v_tentativa avaliacao_tentativas%rowtype;
  v_questoes jsonb;
  v_gabarito jsonb;
  v_qtd integer;
  v_agora timestamptz := now();
BEGIN
  SELECT * INTO v_avaliacao
  FROM avaliacoes
  WHERE id = p_avaliacao_id
    AND tenant_id = public.current_tenant_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Avaliação não encontrada';
  END IF;

  -- Lock the enrollment before allocating the next attempt number. Two
  -- simultaneous starts for the same student/class therefore serialize.
  SELECT * INTO v_matricula
  FROM matriculas
  WHERE id = p_matricula_id
    AND usuario_id = v_usuario_id
    AND tenant_id = public.current_tenant_id()
    AND situacao = 'ativa'
  FOR UPDATE;
  IF NOT FOUND
     OR v_matricula.curso_id <> v_avaliacao.curso_id
     OR (v_avaliacao.turma_id IS NOT NULL AND v_matricula.turma_id IS DISTINCT FROM v_avaliacao.turma_id)
  THEN
    RAISE EXCEPTION 'Matrícula inválida para esta avaliação';
  END IF;
  IF v_avaliacao.situacao <> 'publicada'
     OR (v_avaliacao.disponivel_em IS NOT NULL AND v_avaliacao.disponivel_em > v_agora)
  THEN
    RAISE EXCEPTION 'Avaliação ainda não está disponível';
  END IF;

  SELECT COALESCE(max(numero_tentativa), 0) + 1 INTO v_numero
  FROM avaliacao_tentativas
  WHERE avaliacao_id = p_avaliacao_id
    AND matricula_id = p_matricula_id;
  IF v_numero > v_avaliacao.tentativas_permitidas THEN
    RAISE EXCEPTION 'Limite de tentativas atingido';
  END IF;
  IF v_avaliacao.regra_liberacao = 'coorte'
     AND current_date < v_matricula.data_matricula + (v_avaliacao.intervalo_dias * v_numero)::integer
  THEN
    RAISE EXCEPTION 'Esta etapa da coorte ainda não está disponível';
  END IF;

  v_qtd := COALESCE(v_avaliacao.quantidade_questoes, 1000000);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'questao_id', q.id,
    'enunciado', q.enunciado,
    'tipo', q.tipo,
    'dificuldade', q.dificuldade,
    'pontos', q.pontos,
    'alternativas', CASE
      WHEN q.tipo = 'objetiva' AND v_avaliacao.embaralhar_alternativas
      THEN COALESCE((SELECT jsonb_agg(alt ORDER BY random()) FROM jsonb_array_elements(q.alternativas) alt), '[]'::jsonb)
      ELSE q.alternativas
    END,
    '_gabarito', q.resposta_correta
  ) ORDER BY CASE WHEN v_avaliacao.embaralhar_questoes THEN random() ELSE q.ordem END), '[]'::jsonb)
  INTO v_questoes
  FROM (
    SELECT q.*, aq.ordem
    FROM avaliacao_questoes aq
    JOIN questoes q ON q.id = aq.questao_id
    WHERE aq.avaliacao_id = p_avaliacao_id
      AND q.ativa = true
    ORDER BY CASE WHEN v_avaliacao.embaralhar_questoes THEN random() ELSE aq.ordem END
    LIMIT v_qtd
  ) q;
  IF jsonb_array_length(v_questoes) = 0 THEN
    RAISE EXCEPTION 'A avaliação não possui questões ativas';
  END IF;

  SELECT COALESCE(jsonb_object_agg(item->>'questao_id', item->>'_gabarito'), '{}'::jsonb)
    INTO v_gabarito
  FROM jsonb_array_elements(v_questoes) item;
  SELECT COALESCE(jsonb_agg(item - '_gabarito'), '[]'::jsonb)
    INTO v_questoes
  FROM jsonb_array_elements(v_questoes) item;

  INSERT INTO avaliacao_tentativas (
    tenant_id, avaliacao_id, matricula_id, usuario_id, numero_tentativa,
    expira_em, nota_maxima, questoes_ordem, gabarito_snapshot
  ) VALUES (
    v_avaliacao.tenant_id, v_avaliacao.id, v_matricula.id, v_usuario_id, v_numero,
    CASE WHEN v_avaliacao.expira_em_dias IS NULL THEN NULL ELSE v_agora + (v_avaliacao.expira_em_dias || ' days')::interval END,
    (SELECT COALESCE(sum((item->>'pontos')::numeric), 0) FROM jsonb_array_elements(v_questoes) item),
    v_questoes, v_gabarito
  ) RETURNING * INTO v_tentativa;

  RETURN jsonb_build_object(
    'id', v_tentativa.id,
    'avaliacao_id', v_tentativa.avaliacao_id,
    'numero_tentativa', v_tentativa.numero_tentativa,
    'situacao', v_tentativa.situacao,
    'iniciada_em', v_tentativa.iniciada_em,
    'expira_em', v_tentativa.expira_em,
    'nota_maxima', v_tentativa.nota_maxima,
    'questoes', v_tentativa.questoes_ordem
  );
END
$$;

REVOKE ALL ON FUNCTION public.iniciar_tentativa_avaliacao(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.iniciar_tentativa_avaliacao(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.enviar_tentativa_avaliacao(
  p_tentativa_id uuid,
  p_respostas jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tentativa avaliacao_tentativas%rowtype;
  v_avaliacao avaliacoes%rowtype;
  v_item jsonb;
  v_questao_id uuid;
  v_alternativa text;
  v_texto text;
  v_gabarito text;
  v_pontos numeric;
  v_max numeric := 0;
  v_nota numeric := 0;
  v_pendentes integer := 0;
  v_percentual numeric := 0;
  v_situacao situacao_tentativa;
  v_expirada boolean;
  v_updated integer;
BEGIN
  -- The row lock is acquired before checking the lifecycle. A second submit
  -- waits and then observes the first transaction's terminal state.
  SELECT * INTO v_tentativa
  FROM avaliacao_tentativas
  WHERE id = p_tentativa_id
    AND usuario_id = public.current_usuario_id()
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tentativa não encontrada';
  END IF;
  IF v_tentativa.situacao <> 'em_andamento' THEN
    RAISE EXCEPTION 'Tentativa já enviada';
  END IF;

  v_expirada := v_tentativa.expira_em IS NOT NULL AND v_tentativa.expira_em < now();
  IF v_expirada THEN
    UPDATE avaliacao_tentativas
    SET situacao = 'expirada', enviada_em = now()
    WHERE id = v_tentativa.id AND situacao = 'em_andamento';
    RAISE EXCEPTION 'O prazo desta tentativa expirou';
  END IF;

  SELECT * INTO v_avaliacao FROM avaliacoes WHERE id = v_tentativa.avaliacao_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_respostas, '[]'::jsonb)) LOOP
    v_questao_id := (v_item->>'questao_id')::uuid;
    v_alternativa := NULLIF(v_item->>'alternativa_id', '');
    v_texto := NULLIF(v_item->>'resposta_texto', '');
    IF NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_tentativa.questoes_ordem) q
      WHERE (q->>'questao_id')::uuid = v_questao_id
    ) THEN
      RAISE EXCEPTION 'Questão inválida para esta tentativa';
    END IF;
    v_gabarito := v_tentativa.gabarito_snapshot->>v_questao_id::text;
    v_pontos := COALESCE((
      SELECT (q->>'pontos')::numeric
      FROM jsonb_array_elements(v_tentativa.questoes_ordem) q
      WHERE (q->>'questao_id')::uuid = v_questao_id
    ), 0);
    INSERT INTO avaliacao_respostas (
      tenant_id, tentativa_id, questao_id, alternativa_id, resposta_texto,
      pontos_obtidos, corrigida
    ) VALUES (
      v_tentativa.tenant_id, v_tentativa.id, v_questao_id, v_alternativa, v_texto,
      CASE WHEN v_gabarito IS NOT NULL AND v_alternativa = v_gabarito THEN v_pontos ELSE 0 END,
      v_gabarito IS NOT NULL
    )
    ON CONFLICT (tentativa_id, questao_id) DO UPDATE SET
      alternativa_id = EXCLUDED.alternativa_id,
      resposta_texto = EXCLUDED.resposta_texto,
      pontos_obtidos = EXCLUDED.pontos_obtidos,
      corrigida = EXCLUDED.corrigida;
  END LOOP;

  SELECT COALESCE(sum((q->>'pontos')::numeric), 0)
    INTO v_max
  FROM jsonb_array_elements(v_tentativa.questoes_ordem) q;
  SELECT COALESCE(sum(r.pontos_obtidos), 0), count(*) FILTER (WHERE NOT r.corrigida)
    INTO v_nota, v_pendentes
  FROM avaliacao_respostas r
  WHERE r.tentativa_id = v_tentativa.id;
  v_percentual := CASE WHEN v_max = 0 THEN 0 ELSE round(100 * v_nota / v_max, 2) END;
  v_situacao := CASE WHEN v_pendentes > 0 THEN 'enviada' ELSE 'corrigida' END;

  UPDATE avaliacao_tentativas
  SET situacao = v_situacao,
      enviada_em = now(),
      nota = v_nota,
      nota_maxima = v_max,
      percentual = v_percentual,
      aprovada = CASE WHEN v_pendentes > 0 THEN NULL ELSE v_percentual >= v_avaliacao.nota_minima END
  WHERE id = v_tentativa.id
    AND situacao = 'em_andamento';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'Tentativa mudou de estado durante o envio'
      USING ERRCODE = '40001';
  END IF;

  RETURN jsonb_build_object(
    'id', v_tentativa.id,
    'situacao', v_situacao,
    'nota', v_nota,
    'nota_maxima', v_max,
    'percentual', v_percentual,
    'pendentes_correcao', v_pendentes
  );
END
$$;

REVOKE ALL ON FUNCTION public.enviar_tentativa_avaliacao(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enviar_tentativa_avaliacao(uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION public.sc004_guard_academic_update() IS
  'SC-004 R5.2: protects Teacher provenance and freezes evidenced academic content';
COMMENT ON FUNCTION public.sc004_guard_evidence_parent_delete() IS
  'SC-004 R5.2: blocks parent deletes that would cascade evidenced attempts';
COMMENT ON FUNCTION public.enviar_tentativa_avaliacao(uuid, jsonb) IS
  'SC-004 R5.2: locks the attempt and performs a state-guarded atomic submit';
