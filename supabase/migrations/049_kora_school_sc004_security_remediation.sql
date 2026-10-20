-- KORA LEARN — Migration 049: SC-004C/D R5.3 security remediation
-- Forward-only. Historical migrations 001–048 remain unchanged.
--
-- Scope:
--   * close SECURITY DEFINER pg_temp shadowing for the two student RPCs;
--   * remove TRUNCATE/TRIGGER/REFERENCES from School Core application roles;
--   * make assessment composition owner-controlled before evidence;
--   * restate the staff tenant boundary for canonical assignments.
--
-- Payments/community/public catalog tables are inventoried in the R5.3 report
-- and intentionally remain platform-security follow-up, not this migration.

DO $$
BEGIN
  IF to_regprocedure('public.iniciar_tentativa_avaliacao(uuid,uuid)') IS NULL
     OR to_regprocedure('public.enviar_tentativa_avaliacao(uuid,jsonb)') IS NULL
     OR to_regclass('public.avaliacoes') IS NULL
     OR to_regclass('public.avaliacao_tentativas') IS NULL
     OR to_regclass('public.avaliacao_respostas') IS NULL
  THEN
    RAISE EXCEPTION 'SC-004 R5.3 prerequisites are incomplete'
      USING ERRCODE = '3F000';
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 1. C1 — SECURITY DEFINER functions cannot resolve pg_temp shadows.
-- ---------------------------------------------------------------------------
-- The empty search_path is deliberate. Every application relation, helper,
-- type and non-operator function in these bodies is schema-qualified. Built-in
-- SQL expressions and pg_catalog functions are explicitly qualified where they
-- are ordinary function calls.
CREATE OR REPLACE FUNCTION public.iniciar_tentativa_avaliacao(
  p_avaliacao_id uuid,
  p_matricula_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_avaliacao public.avaliacoes%rowtype;
  v_matricula public.matriculas%rowtype;
  v_usuario_id uuid := public.current_usuario_id();
  v_numero integer;
  v_tentativa public.avaliacao_tentativas%rowtype;
  v_questoes jsonb;
  v_gabarito jsonb;
  v_qtd integer;
  v_agora timestamptz := pg_catalog.now();
BEGIN
  SELECT * INTO v_avaliacao
  FROM public.avaliacoes
  WHERE id = p_avaliacao_id
    AND tenant_id = public.current_tenant_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Avaliação não encontrada';
  END IF;

  SELECT * INTO v_matricula
  FROM public.matriculas
  WHERE id = p_matricula_id
    AND usuario_id = v_usuario_id
    AND tenant_id = public.current_tenant_id()
    AND situacao = 'ativa'
  FOR UPDATE;
  IF NOT FOUND
     OR v_matricula.curso_id <> v_avaliacao.curso_id
     OR (v_avaliacao.turma_id IS NOT NULL
         AND v_matricula.turma_id IS DISTINCT FROM v_avaliacao.turma_id)
  THEN
    RAISE EXCEPTION 'Matrícula inválida para esta avaliação';
  END IF;
  IF v_avaliacao.situacao <> 'publicada'
     OR (v_avaliacao.disponivel_em IS NOT NULL
         AND v_avaliacao.disponivel_em > v_agora)
  THEN
    RAISE EXCEPTION 'Avaliação ainda não está disponível';
  END IF;

  SELECT COALESCE(pg_catalog.max(numero_tentativa), 0) + 1 INTO v_numero
  FROM public.avaliacao_tentativas
  WHERE avaliacao_id = p_avaliacao_id
    AND matricula_id = p_matricula_id;
  IF v_numero > v_avaliacao.tentativas_permitidas THEN
    RAISE EXCEPTION 'Limite de tentativas atingido';
  END IF;
  IF v_avaliacao.regra_liberacao = 'coorte'
     AND current_date < v_matricula.data_matricula
         + (v_avaliacao.intervalo_dias * v_numero)::integer
  THEN
    RAISE EXCEPTION 'Esta etapa da coorte ainda não está disponível';
  END IF;

  v_qtd := COALESCE(v_avaliacao.quantidade_questoes, 1000000);
  SELECT COALESCE(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'questao_id', q.id,
        'enunciado', q.enunciado,
        'tipo', q.tipo,
        'dificuldade', q.dificuldade,
        'pontos', q.pontos,
        'alternativas', CASE
          WHEN q.tipo = 'objetiva' AND v_avaliacao.embaralhar_alternativas
          THEN COALESCE(
            (
              SELECT pg_catalog.jsonb_agg(alt ORDER BY pg_catalog.random())
              FROM pg_catalog.jsonb_array_elements(q.alternativas) AS alt
            ),
            '[]'::jsonb
          )
          ELSE q.alternativas
        END,
        '_gabarito', q.resposta_correta
      )
      ORDER BY CASE
        WHEN v_avaliacao.embaralhar_questoes THEN pg_catalog.random()
        ELSE q.ordem
      END
    ),
    '[]'::jsonb
  ) INTO v_questoes
  FROM (
    SELECT q.*, aq.ordem
    FROM public.avaliacao_questoes AS aq
    JOIN public.questoes AS q ON q.id = aq.questao_id
    WHERE aq.avaliacao_id = p_avaliacao_id
      AND q.ativa IS TRUE
    ORDER BY CASE
      WHEN v_avaliacao.embaralhar_questoes THEN pg_catalog.random()
      ELSE aq.ordem
    END
    LIMIT v_qtd
  ) AS q;
  IF pg_catalog.jsonb_array_length(v_questoes) = 0 THEN
    RAISE EXCEPTION 'A avaliação não possui questões ativas';
  END IF;

  SELECT COALESCE(
    pg_catalog.jsonb_object_agg(item->>'questao_id', item->>'_gabarito'),
    '{}'::jsonb
  ) INTO v_gabarito
  FROM pg_catalog.jsonb_array_elements(v_questoes) AS item;
  SELECT COALESCE(
    pg_catalog.jsonb_agg(item - '_gabarito'),
    '[]'::jsonb
  ) INTO v_questoes
  FROM pg_catalog.jsonb_array_elements(v_questoes) AS item;

  INSERT INTO public.avaliacao_tentativas (
    tenant_id, avaliacao_id, matricula_id, usuario_id, numero_tentativa,
    expira_em, nota_maxima, questoes_ordem, gabarito_snapshot
  ) VALUES (
    v_avaliacao.tenant_id, v_avaliacao.id, v_matricula.id, v_usuario_id,
    v_numero,
    CASE
      WHEN v_avaliacao.expira_em_dias IS NULL THEN NULL
      ELSE v_agora + (v_avaliacao.expira_em_dias || ' days')::interval
    END,
    (
      SELECT COALESCE(
        pg_catalog.sum((item->>'pontos')::numeric), 0
      )
      FROM pg_catalog.jsonb_array_elements(v_questoes) AS item
    ),
    v_questoes,
    v_gabarito
  ) RETURNING * INTO v_tentativa;

  RETURN pg_catalog.jsonb_build_object(
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

REVOKE ALL ON FUNCTION public.iniciar_tentativa_avaliacao(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.iniciar_tentativa_avaliacao(uuid, uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.enviar_tentativa_avaliacao(
  p_tentativa_id uuid,
  p_respostas jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tentativa public.avaliacao_tentativas%rowtype;
  v_avaliacao public.avaliacoes%rowtype;
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
  v_situacao public.situacao_tentativa;
  v_expirada boolean;
  v_updated integer;
BEGIN
  SELECT * INTO v_tentativa
  FROM public.avaliacao_tentativas
  WHERE id = p_tentativa_id
    AND usuario_id = public.current_usuario_id()
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tentativa não encontrada';
  END IF;
  IF v_tentativa.situacao <> 'em_andamento' THEN
    RAISE EXCEPTION 'Tentativa já enviada';
  END IF;

  v_expirada := v_tentativa.expira_em IS NOT NULL
    AND v_tentativa.expira_em < pg_catalog.now();
  IF v_expirada THEN
    UPDATE public.avaliacao_tentativas
    SET situacao = 'expirada', enviada_em = pg_catalog.now()
    WHERE id = v_tentativa.id
      AND situacao = 'em_andamento';
    RAISE EXCEPTION 'O prazo desta tentativa expirou';
  END IF;

  SELECT * INTO v_avaliacao
  FROM public.avaliacoes
  WHERE id = v_tentativa.avaliacao_id;

  FOR v_item IN
    SELECT * FROM pg_catalog.jsonb_array_elements(COALESCE(p_respostas, '[]'::jsonb))
  LOOP
    v_questao_id := (v_item->>'questao_id')::uuid;
    v_alternativa := NULLIF(v_item->>'alternativa_id', '');
    v_texto := NULLIF(v_item->>'resposta_texto', '');
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_tentativa.questoes_ordem) AS q
      WHERE (q->>'questao_id')::uuid = v_questao_id
    ) THEN
      RAISE EXCEPTION 'Questão inválida para esta tentativa';
    END IF;

    v_gabarito := v_tentativa.gabarito_snapshot->>v_questao_id::text;
    v_pontos := COALESCE(
      (
        SELECT (q->>'pontos')::numeric
        FROM pg_catalog.jsonb_array_elements(v_tentativa.questoes_ordem) AS q
        WHERE (q->>'questao_id')::uuid = v_questao_id
      ),
      0
    );
    INSERT INTO public.avaliacao_respostas (
      tenant_id, tentativa_id, questao_id, alternativa_id, resposta_texto,
      pontos_obtidos, corrigida
    ) VALUES (
      v_tentativa.tenant_id, v_tentativa.id, v_questao_id, v_alternativa,
      v_texto,
      CASE
        WHEN v_gabarito IS NOT NULL AND v_alternativa = v_gabarito
        THEN v_pontos
        ELSE 0
      END,
      v_gabarito IS NOT NULL
    )
    ON CONFLICT (tentativa_id, questao_id) DO UPDATE SET
      alternativa_id = EXCLUDED.alternativa_id,
      resposta_texto = EXCLUDED.resposta_texto,
      pontos_obtidos = EXCLUDED.pontos_obtidos,
      corrigida = EXCLUDED.corrigida;
  END LOOP;

  SELECT COALESCE(
    pg_catalog.sum((q->>'pontos')::numeric), 0
  ) INTO v_max
  FROM pg_catalog.jsonb_array_elements(v_tentativa.questoes_ordem) AS q;
  SELECT COALESCE(pg_catalog.sum(r.pontos_obtidos), 0),
         pg_catalog.count(*) FILTER (WHERE NOT r.corrigida)
    INTO v_nota, v_pendentes
  FROM public.avaliacao_respostas AS r
  WHERE r.tentativa_id = v_tentativa.id;
  v_percentual := CASE
    WHEN v_max = 0 THEN 0
    ELSE pg_catalog.round(100 * v_nota / v_max, 2)
  END;
  v_situacao := CASE
    WHEN v_pendentes > 0 THEN 'enviada'
    ELSE 'corrigida'
  END;

  UPDATE public.avaliacao_tentativas
  SET situacao = v_situacao,
      enviada_em = pg_catalog.now(),
      nota = v_nota,
      nota_maxima = v_max,
      percentual = v_percentual,
      aprovada = CASE
        WHEN v_pendentes > 0 THEN NULL
        ELSE v_percentual >= v_avaliacao.nota_minima
      END
  WHERE id = v_tentativa.id
    AND situacao = 'em_andamento';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'Tentativa mudou de estado durante o envio'
      USING ERRCODE = '40001';
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'id', v_tentativa.id,
    'situacao', v_situacao,
    'nota', v_nota,
    'nota_maxima', v_max,
    'percentual', v_percentual,
    'pendentes_correcao', v_pendentes
  );
END
$$;

REVOKE ALL ON FUNCTION public.enviar_tentativa_avaliacao(uuid, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enviar_tentativa_avaliacao(uuid, jsonb)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. C2 — explicit application-role ACL boundary for School Core.
-- ---------------------------------------------------------------------------
-- Inventory in scope: the School Core parent, authority, attendance and
-- assessment/evidence tables. auth.users, storage.*, Payments, community and
-- public-catalog tables are outside this slice and remain documented follow-up.
DO $$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'tenants', 'unidades', 'cursos', 'disciplinas', 'turmas', 'usuarios',
    'matriculas', 'professores_turmas', 'atribuicoes_academicas_professor',
    'registros_aula', 'presencas', 'materiais_professor', 'avisos_turma',
    'questoes', 'avaliacoes', 'avaliacao_questoes', 'avaliacao_tentativas',
    'avaliacao_respostas'
  ] LOOP
    IF to_regclass('public.' || v_table) IS NOT NULL THEN
      EXECUTE format(
        'REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE public.%I FROM anon, authenticated',
        v_table
      );
    END IF;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. H2 — only the assessment creator may change composition before evidence.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS avaliacao_questoes_teacher_assignment
  ON public.avaliacao_questoes;
DROP POLICY IF EXISTS avaliacao_questoes_teacher_select_r53
  ON public.avaliacao_questoes;
DROP POLICY IF EXISTS avaliacao_questoes_owner_insert_r53
  ON public.avaliacao_questoes;
DROP POLICY IF EXISTS avaliacao_questoes_owner_update_r53
  ON public.avaliacao_questoes;
DROP POLICY IF EXISTS avaliacao_questoes_owner_delete_r53
  ON public.avaliacao_questoes;

CREATE POLICY avaliacao_questoes_teacher_select_r53
  ON public.avaliacao_questoes
  FOR SELECT TO authenticated
  USING (
    (
      public.is_staff()
      AND EXISTS (
        SELECT 1 FROM public.avaliacoes a
        WHERE a.id = avaliacao_questoes.avaliacao_id
          AND a.tenant_id = public.current_tenant_id()
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

CREATE POLICY avaliacao_questoes_owner_insert_r53
  ON public.avaliacao_questoes
  FOR INSERT TO authenticated
  WITH CHECK (
    (
      public.is_staff()
      AND tenant_id = public.current_tenant_id()
    )
    OR EXISTS (
      SELECT 1
      FROM public.avaliacoes a
      JOIN public.questoes q ON q.id = avaliacao_questoes.questao_id
      WHERE a.id = avaliacao_questoes.avaliacao_id
        AND a.tenant_id = public.current_tenant_id()
        AND a.criado_por = public.current_usuario_id()
        AND q.tenant_id = a.tenant_id
        AND q.disciplina_id = a.disciplina_id
        AND public.teacher_assessment_scope(a.turma_id, a.disciplina_id)
    )
  );

CREATE POLICY avaliacao_questoes_owner_update_r53
  ON public.avaliacao_questoes
  FOR UPDATE TO authenticated
  USING (
    (
      public.is_staff()
      AND EXISTS (
        SELECT 1 FROM public.avaliacoes a
        WHERE a.id = avaliacao_questoes.avaliacao_id
          AND a.tenant_id = public.current_tenant_id()
      )
    )
    OR EXISTS (
      SELECT 1
      FROM public.avaliacoes a
      JOIN public.questoes q ON q.id = avaliacao_questoes.questao_id
      WHERE a.id = avaliacao_questoes.avaliacao_id
        AND a.tenant_id = public.current_tenant_id()
        AND a.criado_por = public.current_usuario_id()
        AND q.tenant_id = a.tenant_id
        AND q.disciplina_id = a.disciplina_id
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
      FROM public.avaliacoes a
      JOIN public.questoes q ON q.id = avaliacao_questoes.questao_id
      WHERE a.id = avaliacao_questoes.avaliacao_id
        AND a.tenant_id = public.current_tenant_id()
        AND a.criado_por = public.current_usuario_id()
        AND q.tenant_id = a.tenant_id
        AND q.disciplina_id = a.disciplina_id
        AND public.teacher_assessment_scope(a.turma_id, a.disciplina_id)
    )
  );

CREATE POLICY avaliacao_questoes_owner_delete_r53
  ON public.avaliacao_questoes
  FOR DELETE TO authenticated
  USING (
    (
      public.is_staff()
      AND EXISTS (
        SELECT 1 FROM public.avaliacoes a
        WHERE a.id = avaliacao_questoes.avaliacao_id
          AND a.tenant_id = public.current_tenant_id()
      )
    )
    OR EXISTS (
      SELECT 1
      FROM public.avaliacoes a
      JOIN public.questoes q ON q.id = avaliacao_questoes.questao_id
      WHERE a.id = avaliacao_questoes.avaliacao_id
        AND a.tenant_id = public.current_tenant_id()
        AND a.criado_por = public.current_usuario_id()
        AND q.tenant_id = a.tenant_id
        AND q.disciplina_id = a.disciplina_id
        AND public.teacher_assessment_scope(a.turma_id, a.disciplina_id)
    )
  );

-- ---------------------------------------------------------------------------
-- 4. H4 — restate the canonical staff tenant boundary.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS atribuicoes_staff_all
  ON public.atribuicoes_academicas_professor;
CREATE POLICY atribuicoes_staff_all
  ON public.atribuicoes_academicas_professor
  FOR ALL TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND public.is_staff()
  )
  WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND public.is_staff()
  );

COMMENT ON FUNCTION public.iniciar_tentativa_avaliacao(uuid, uuid) IS
  'SC-004 R5.3: SECURITY DEFINER uses empty search_path and fully-qualified relations';
COMMENT ON FUNCTION public.enviar_tentativa_avaliacao(uuid, jsonb) IS
  'SC-004 R5.3: SECURITY DEFINER uses empty search_path and fully-qualified relations';
COMMENT ON TABLE public.avaliacao_respostas IS
  'SC-004 R5.3: anon/authenticated never receive TRUNCATE, TRIGGER or REFERENCES';
