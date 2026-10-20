-- KORA LEARN — SC-004CD-R2
-- Narrow enum/text compatibility remediation for server-side grading.
-- The authoritative database type remains public.situacao_tentativa.

DO $$
BEGIN
  IF to_regprocedure('public.corrigir_resposta_avaliacao(uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'SC-004CD-R2 prerequisite grading function is missing'
      USING ERRCODE = '42883';
  END IF;
  IF to_regtype('public.situacao_tentativa') IS NULL THEN
    RAISE EXCEPTION 'SC-004CD-R2 prerequisite enum public.situacao_tentativa is missing'
      USING ERRCODE = '42704';
  END IF;
END
$$;

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
    (SELECT a.turma_id FROM public.avaliacoes a JOIN public.avaliacao_tentativas t ON t.avaliacao_id = a.id JOIN public.avaliacao_respostas r ON r.tentativa_id = t.id WHERE r.id = p_resposta_id),
    (SELECT a.disciplina_id FROM public.avaliacoes a JOIN public.avaliacao_tentativas t ON t.avaliacao_id = a.id JOIN public.avaliacao_respostas r ON r.tentativa_id = t.id WHERE r.id = p_resposta_id)
  ) THEN
    RAISE EXCEPTION 'Professor sem assignment exato para corrigir resposta' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_resposta FROM public.avaliacao_respostas
  WHERE id = p_resposta_id AND tenant_id = public.current_tenant_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Resposta não encontrada'; END IF;
  SELECT * INTO v_tentativa FROM public.avaliacao_tentativas WHERE id = v_resposta.tentativa_id;
  SELECT * INTO v_avaliacao FROM public.avaliacoes WHERE id = v_tentativa.avaliacao_id;
  IF p_pontos < 0 OR p_pontos > COALESCE((
    SELECT (q->>'pontos')::numeric FROM jsonb_array_elements(v_tentativa.questoes_ordem) q
    WHERE (q->>'questao_id')::uuid = v_resposta.questao_id
  ), 0) THEN
    RAISE EXCEPTION 'Pontuação fora do limite da questão';
  END IF;
  UPDATE public.avaliacao_respostas
  SET pontos_obtidos = p_pontos, comentario = p_comentario, corrigida = true
  WHERE id = p_resposta_id;
  SELECT COALESCE(sum((q->>'pontos')::numeric), 0) INTO v_max
  FROM jsonb_array_elements(v_tentativa.questoes_ordem) q;
  SELECT COALESCE(sum(pontos_obtidos), 0), count(*) FILTER (WHERE NOT corrigida)
    INTO v_nota, v_pendentes FROM public.avaliacao_respostas
    WHERE tentativa_id = v_tentativa.id;
  v_percentual := CASE WHEN v_max = 0 THEN 0 ELSE round(100 * v_nota / v_max, 2) END;
  v_situacao := CASE
    WHEN v_pendentes = 0 THEN 'corrigida'::public.situacao_tentativa
    ELSE 'enviada'::public.situacao_tentativa
  END;
  UPDATE public.avaliacao_tentativas SET nota = v_nota, nota_maxima = v_max,
    percentual = v_percentual,
    situacao = v_situacao,
    aprovada = CASE WHEN v_pendentes = 0 THEN v_percentual >= v_avaliacao.nota_minima ELSE NULL END
  WHERE id = v_tentativa.id;
  RETURN jsonb_build_object('tentativa_id', v_tentativa.id,
    'situacao', v_situacao,
    'percentual', v_percentual);
END
$$;
