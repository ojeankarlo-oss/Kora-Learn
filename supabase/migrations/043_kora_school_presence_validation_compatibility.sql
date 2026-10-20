-- KORA LEARN — SC-004CD-R1
-- Narrow compatibility remediation for the SC-003 presence validator.
--
-- Migration 040's invoker validator correctly rejected invalid enrollment
-- state, but could not see a legitimate enrollment through caller RLS.
-- Keep the SC-003 integrity guard and change only its visibility context.
-- SC-004 remains the Teacher -> Assignment -> Class + Subject authority.

DO $$
BEGIN
  IF to_regprocedure('public.sc003_validate_presenca()') IS NULL THEN
    RAISE EXCEPTION 'SC-004CD-R1 prerequisite function public.sc003_validate_presenca() is missing'
      USING ERRCODE = '42883';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.sc003_validate_presenca()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.registros_aula ra
    JOIN public.turmas t
      ON t.id = ra.turma_id
     AND t.tenant_id = ra.tenant_id
     AND t.ativa IS TRUE
    JOIN public.unidades un
      ON un.id = t.unidade_id
     AND un.tenant_id = ra.tenant_id
     AND un.ativo IS TRUE
    JOIN public.cursos c
      ON c.id = t.curso_id
     AND c.tenant_id = ra.tenant_id
     AND c.ativo IS TRUE
    JOIN public.matriculas m
      ON m.turma_id = t.id
     AND m.curso_id = t.curso_id
     AND m.unidade_id = t.unidade_id
     AND m.tenant_id = ra.tenant_id
     AND m.usuario_id = NEW.usuario_id
     AND m.situacao = 'ativa'
    JOIN public.usuarios student
      ON student.id = m.usuario_id
     AND student.tenant_id = m.tenant_id
     AND student.ativo IS TRUE
    WHERE ra.id = NEW.registro_aula_id
      AND ra.tenant_id = NEW.tenant_id
  ) THEN
    RAISE EXCEPTION 'SC003_R18_ENROLLMENT_MISMATCH' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END
$$;

-- This is a trigger-only validator, not a callable API or privileged RPC.
REVOKE EXECUTE ON FUNCTION public.sc003_validate_presenca() FROM PUBLIC, anon, authenticated;
