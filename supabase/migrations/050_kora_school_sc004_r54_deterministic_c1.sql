-- KORA LEARN — Migration 050: SC-004C/D R5.4 deterministic C1 hardening
-- Forward-only. Historical migrations 001–049 remain unchanged.
--
-- The empty search_path remains mandatory: adding pg_catalog, public would
-- implicitly re-enable pg_temp lookup. Built-in types are explicitly bound to
-- pg_catalog below, while application relations/helpers remain public-qualified.

DO $$
BEGIN
  IF to_regprocedure('public.iniciar_tentativa_avaliacao(uuid,uuid)') IS NULL
     OR to_regprocedure('public.enviar_tentativa_avaliacao(uuid,jsonb)') IS NULL
  THEN
    RAISE EXCEPTION 'SC-004 R5.4 C1 prerequisites are incomplete'
      USING ERRCODE = '3F000';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.iniciar_tentativa_avaliacao(
  p_avaliacao_id pg_catalog.uuid,
  p_matricula_id pg_catalog.uuid
)
RETURNS pg_catalog.jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_avaliacao public.avaliacoes%rowtype;
  v_matricula public.matriculas%rowtype;
  v_usuario_id pg_catalog.uuid := public.current_usuario_id();
  v_numero pg_catalog.int4;
  v_tentativa public.avaliacao_tentativas%rowtype;
  v_questoes pg_catalog.jsonb;
  v_gabarito pg_catalog.jsonb;
  v_qtd pg_catalog.int4;
  v_agora pg_catalog.timestamptz := pg_catalog.now();
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
         + (v_avaliacao.intervalo_dias * v_numero)::pg_catalog.int4
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
            '[]'::pg_catalog.jsonb
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
    '[]'::pg_catalog.jsonb
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
    '{}'::pg_catalog.jsonb
  ) INTO v_gabarito
  FROM pg_catalog.jsonb_array_elements(v_questoes) AS item;
  SELECT COALESCE(
    pg_catalog.jsonb_agg(item - '_gabarito'),
    '[]'::pg_catalog.jsonb
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
      ELSE v_agora + (v_avaliacao.expira_em_dias || ' days')::pg_catalog.interval
    END,
    (
      SELECT COALESCE(
        pg_catalog.sum((item->>'pontos')::pg_catalog.numeric), 0
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
  p_tentativa_id pg_catalog.uuid,
  p_respostas pg_catalog.jsonb
)
RETURNS pg_catalog.jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tentativa public.avaliacao_tentativas%rowtype;
  v_avaliacao public.avaliacoes%rowtype;
  v_item pg_catalog.jsonb;
  v_questao_id pg_catalog.uuid;
  v_alternativa pg_catalog.text;
  v_texto pg_catalog.text;
  v_gabarito pg_catalog.text;
  v_pontos pg_catalog.numeric;
  v_max pg_catalog.numeric := 0;
  v_nota pg_catalog.numeric := 0;
  v_pendentes pg_catalog.int4 := 0;
  v_percentual pg_catalog.numeric := 0;
  v_situacao public.situacao_tentativa;
  v_expirada pg_catalog.bool;
  v_updated pg_catalog.int4;
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
    SELECT * FROM pg_catalog.jsonb_array_elements(COALESCE(p_respostas, '[]'::pg_catalog.jsonb))
  LOOP
    v_questao_id := (v_item->>'questao_id')::pg_catalog.uuid;
    v_alternativa := NULLIF(v_item->>'alternativa_id', '');
    v_texto := NULLIF(v_item->>'resposta_texto', '');
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_tentativa.questoes_ordem) AS q
      WHERE (q->>'questao_id')::pg_catalog.uuid = v_questao_id
    ) THEN
      RAISE EXCEPTION 'Questão inválida para esta tentativa';
    END IF;

    v_gabarito := v_tentativa.gabarito_snapshot->>v_questao_id::pg_catalog.text;
    v_pontos := COALESCE(
      (
        SELECT (q->>'pontos')::pg_catalog.numeric
        FROM pg_catalog.jsonb_array_elements(v_tentativa.questoes_ordem) AS q
        WHERE (q->>'questao_id')::pg_catalog.uuid = v_questao_id
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
    pg_catalog.sum((q->>'pontos')::pg_catalog.numeric), 0
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

COMMENT ON FUNCTION public.iniciar_tentativa_avaliacao(uuid, uuid) IS
  'SC-004 R5.4: empty search_path; built-in types explicitly bound to pg_catalog; application names public-qualified';
COMMENT ON FUNCTION public.enviar_tentativa_avaliacao(uuid, jsonb) IS
  'SC-004 R5.4: empty search_path; built-in types explicitly bound to pg_catalog; application names public-qualified';

-- L4: these SECURITY DEFINER helpers are invoked only by table triggers;
-- callers never need direct EXECUTE. Keep trigger execution intact while
-- removing the unnecessary PUBLIC surface.
REVOKE ALL ON FUNCTION public.sc004_assignment_lifecycle() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sc004_validate_parent_integrity() FROM PUBLIC;
