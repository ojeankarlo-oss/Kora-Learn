-- KORA LEARN — Migration 042: SC-004C/D
-- Canonical Teacher + Class + Subject authority and same-tenant integrity.
--
-- This migration is intentionally additive/forward-only. Legacy
-- public.professores_turmas rows are not converted because they contain no
-- trustworthy Subject information. They remain compatibility data only and
-- never authorize subject-specific operations.
--
-- Existing historical rows are not destructively rewritten. Deterministic
-- BEFORE triggers reject new invalid writes and updates. The canonical
-- assignment relation has direct FKs plus a validation trigger because the
-- historical parent tables contain legacy rows that cannot safely be
-- converted or validated by a new global composite FK without a separate,
-- explicitly approved data-repair project.

DO $$
BEGIN
  IF to_regclass('public.tenants') IS NULL
     OR to_regclass('public.unidades') IS NULL
     OR to_regclass('public.usuarios') IS NULL
     OR to_regclass('public.cursos') IS NULL
     OR to_regclass('public.disciplinas') IS NULL
     OR to_regclass('public.turmas') IS NULL
     OR to_regclass('public.matriculas') IS NULL
     OR to_regclass('public.professores_turmas') IS NULL
     OR to_regclass('public.registros_aula') IS NULL
     OR to_regclass('public.presencas') IS NULL
     OR to_regclass('public.materiais_professor') IS NULL
     OR to_regclass('public.avisos_turma') IS NULL
     OR to_regclass('public.questoes') IS NULL
     OR to_regclass('public.avaliacoes') IS NULL
     OR to_regclass('public.avaliacao_questoes') IS NULL
     OR to_regclass('public.avaliacao_tentativas') IS NULL
     OR to_regclass('public.avaliacao_respostas') IS NULL
  THEN
    RAISE EXCEPTION 'SC-004C/D prerequisite schema is incomplete' USING ERRCODE = '3F000';
  END IF;
END
$$;

DO $$
DECLARE
  v_required text[] := ARRAY[
    'tenant_id','auth_user_id','perfil','ativo'
  ];
  v_name text;
BEGIN
  FOREACH v_name IN ARRAY v_required LOOP
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'usuarios' AND column_name = v_name
    ) THEN
      RAISE EXCEPTION 'SC-004C/D missing public.usuarios.%', v_name USING ERRCODE = '42703';
    END IF;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 1. Canonical assignment relation
-- ---------------------------------------------------------------------------
CREATE TABLE public.atribuicoes_academicas_professor (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  professor_id  uuid NOT NULL REFERENCES public.usuarios(id) ON DELETE CASCADE,
  turma_id      uuid NOT NULL REFERENCES public.turmas(id) ON DELETE CASCADE,
  disciplina_id uuid NOT NULL REFERENCES public.disciplinas(id) ON DELETE CASCADE,
  ativo         boolean NOT NULL DEFAULT true,
  revoked_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT atribuicoes_academicas_professor_lifecycle_ck
    CHECK ((ativo AND revoked_at IS NULL) OR ((NOT ativo) AND revoked_at IS NOT NULL))
);

CREATE UNIQUE INDEX uq_atribuicoes_academicas_professor_active
  ON public.atribuicoes_academicas_professor(tenant_id, professor_id, turma_id, disciplina_id)
  WHERE ativo IS TRUE;

CREATE INDEX idx_atribuicoes_academicas_professor_teacher
  ON public.atribuicoes_academicas_professor(tenant_id, professor_id, ativo);
CREATE INDEX idx_atribuicoes_academicas_professor_class_subject
  ON public.atribuicoes_academicas_professor(tenant_id, turma_id, disciplina_id, ativo);

ALTER TABLE public.atribuicoes_academicas_professor ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.atribuicoes_academicas_professor FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.atribuicoes_academicas_professor TO authenticated;

CREATE POLICY atribuicoes_staff_all ON public.atribuicoes_academicas_professor
  FOR ALL TO authenticated
  USING (tenant_id = public.current_tenant_id() AND public.is_staff())
  WITH CHECK (tenant_id = public.current_tenant_id() AND public.is_staff());

CREATE POLICY atribuicoes_teacher_select_own ON public.atribuicoes_academicas_professor
  FOR SELECT TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND professor_id = public.current_usuario_id()
  );

-- ---------------------------------------------------------------------------
-- 2. Deterministic parent-integrity validation for new writes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sc004_validate_parent_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant uuid;
  v_parent_tenant uuid;
  v_course uuid;
  v_class_course uuid;
  v_subject_course uuid;
  v_class_unit uuid;
  v_unit_tenant uuid;
  v_user_tenant uuid;
  v_student_tenant uuid;
  v_student_class uuid;
  v_student_course uuid;
  v_student_unit uuid;
  v_class_tenant uuid;
  v_subject_tenant uuid;
  v_assessment_tenant uuid;
  v_assessment_course uuid;
  v_assessment_subject uuid;
  v_assessment_class uuid;
  v_attempt_tenant uuid;
  v_attempt_assessment uuid;
  v_attempt_user uuid;
  v_question_tenant uuid;
  v_question_subject uuid;
BEGIN
  IF TG_TABLE_NAME = 'disciplinas' THEN
    SELECT c.tenant_id, c.id INTO v_parent_tenant, v_course
    FROM public.cursos c WHERE c.id = NEW.curso_id;
    IF v_parent_tenant IS NULL OR NEW.tenant_id IS DISTINCT FROM v_parent_tenant THEN
      RAISE EXCEPTION 'disciplina fora do tenant do curso' USING ERRCODE = '23514';
    END IF;

  ELSIF TG_TABLE_NAME = 'turmas' THEN
    SELECT c.tenant_id, c.id INTO v_parent_tenant, v_course
    FROM public.cursos c WHERE c.id = NEW.curso_id;
    IF v_parent_tenant IS NULL OR NEW.tenant_id IS DISTINCT FROM v_parent_tenant THEN
      RAISE EXCEPTION 'turma fora do tenant do curso' USING ERRCODE = '23514';
    END IF;
    IF NEW.unidade_id IS NOT NULL THEN
      SELECT u.tenant_id INTO v_unit_tenant FROM public.unidades u WHERE u.id = NEW.unidade_id;
      IF v_unit_tenant IS NULL OR v_unit_tenant IS DISTINCT FROM NEW.tenant_id THEN
        RAISE EXCEPTION 'turma fora do tenant da unidade' USING ERRCODE = '23514';
      END IF;
    END IF;

  ELSIF TG_TABLE_NAME = 'matriculas' THEN
    SELECT u.tenant_id INTO v_user_tenant FROM public.usuarios u WHERE u.id = NEW.usuario_id;
    IF v_user_tenant IS NULL OR v_user_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'matricula fora do tenant do aluno' USING ERRCODE = '23514';
    END IF;
    SELECT c.tenant_id INTO v_parent_tenant FROM public.cursos c WHERE c.id = NEW.curso_id;
    IF v_parent_tenant IS NULL OR v_parent_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'matricula fora do tenant do curso' USING ERRCODE = '23514';
    END IF;
    IF NEW.turma_id IS NOT NULL THEN
      SELECT t.tenant_id, t.curso_id, t.unidade_id
        INTO v_parent_tenant, v_class_course, v_class_unit
      FROM public.turmas t WHERE t.id = NEW.turma_id;
      IF v_parent_tenant IS NULL OR v_parent_tenant IS DISTINCT FROM NEW.tenant_id
         OR v_class_course IS DISTINCT FROM NEW.curso_id THEN
        RAISE EXCEPTION 'matricula fora da turma/curso do tenant' USING ERRCODE = '23514';
      END IF;
      IF v_class_unit IS NULL OR NEW.unidade_id IS DISTINCT FROM v_class_unit THEN
        RAISE EXCEPTION 'matricula fora da unidade da turma' USING ERRCODE = '23514';
      END IF;
    END IF;
    IF NEW.unidade_id IS NOT NULL THEN
      SELECT u.tenant_id INTO v_unit_tenant FROM public.unidades u WHERE u.id = NEW.unidade_id;
      IF v_unit_tenant IS NULL OR v_unit_tenant IS DISTINCT FROM NEW.tenant_id THEN
        RAISE EXCEPTION 'matricula fora do tenant da unidade' USING ERRCODE = '23514';
      END IF;
    END IF;

  ELSIF TG_TABLE_NAME = 'professores_turmas' THEN
    SELECT u.tenant_id INTO v_user_tenant FROM public.usuarios u WHERE u.id = NEW.usuario_id;
    SELECT t.tenant_id INTO v_parent_tenant FROM public.turmas t WHERE t.id = NEW.turma_id;
    IF v_user_tenant IS NULL OR v_parent_tenant IS NULL
       OR NEW.tenant_id IS DISTINCT FROM v_user_tenant
       OR NEW.tenant_id IS DISTINCT FROM v_parent_tenant THEN
      RAISE EXCEPTION 'vinculo legado fora do tenant do professor/turma' USING ERRCODE = '23514';
    END IF;

  ELSIF TG_TABLE_NAME = 'atribuicoes_academicas_professor' THEN
    SELECT t.tenant_id, t.curso_id, t.unidade_id
      INTO v_class_tenant, v_class_course, v_class_unit
    FROM public.turmas t WHERE t.id = NEW.turma_id;
    SELECT d.tenant_id, d.curso_id
      INTO v_subject_tenant, v_subject_course
    FROM public.disciplinas d WHERE d.id = NEW.disciplina_id;
    SELECT u.tenant_id INTO v_user_tenant FROM public.usuarios u WHERE u.id = NEW.professor_id;
    IF NOT EXISTS (SELECT 1 FROM public.tenants t WHERE t.id = NEW.tenant_id AND t.ativo IS TRUE) THEN
      RAISE EXCEPTION 'tenant da atribuicao inativo ou inexistente' USING ERRCODE = '23514';
    END IF;
    IF v_user_tenant IS NULL OR v_user_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'professor fora do tenant da atribuicao' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.id = NEW.professor_id AND u.tenant_id = NEW.tenant_id
        AND u.perfil = 'professor' AND u.ativo IS TRUE
    ) THEN
      RAISE EXCEPTION 'professor inativo ou inelegivel' USING ERRCODE = '23514';
    END IF;
    SELECT t.tenant_id, t.curso_id, t.unidade_id
      INTO v_class_tenant, v_class_course, v_class_unit
    FROM public.turmas t WHERE t.id = NEW.turma_id;
    SELECT d.tenant_id, d.curso_id
      INTO v_subject_tenant, v_subject_course
    FROM public.disciplinas d WHERE d.id = NEW.disciplina_id;
    IF v_class_tenant IS NULL OR v_class_tenant IS DISTINCT FROM NEW.tenant_id
       OR v_subject_tenant IS NULL OR v_subject_tenant IS DISTINCT FROM NEW.tenant_id
       OR v_subject_course IS NULL OR v_subject_course IS DISTINCT FROM v_class_course THEN
      RAISE EXCEPTION 'turma/disciplina incompatíveis na atribuicao' USING ERRCODE = '23514';
    END IF;
    IF v_class_unit IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.unidades u
      WHERE u.id = v_class_unit AND u.tenant_id = NEW.tenant_id AND u.ativo IS TRUE
    ) THEN
      RAISE EXCEPTION 'unidade da turma inativa, ausente ou fora do tenant' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.turmas t
      WHERE t.id = NEW.turma_id AND t.tenant_id = NEW.tenant_id AND t.ativa IS TRUE
    ) THEN
      RAISE EXCEPTION 'turma inativa, ausente ou fora do tenant' USING ERRCODE = '23514';
    END IF;

  ELSIF TG_TABLE_NAME = 'registros_aula' THEN
    SELECT t.tenant_id, t.curso_id INTO v_class_tenant, v_class_course
    FROM public.turmas t WHERE t.id = NEW.turma_id;
    IF v_class_tenant IS NULL OR v_class_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'registro de aula fora do tenant da turma' USING ERRCODE = '23514';
    END IF;
    IF NEW.disciplina_id IS NOT NULL THEN
      SELECT d.tenant_id, d.curso_id INTO v_subject_tenant, v_subject_course
      FROM public.disciplinas d WHERE d.id = NEW.disciplina_id;
      IF v_subject_tenant IS NULL OR v_subject_tenant IS DISTINCT FROM NEW.tenant_id
         OR v_subject_course IS DISTINCT FROM v_class_course THEN
        RAISE EXCEPTION 'registro de aula com disciplina incompatível' USING ERRCODE = '23514';
      END IF;
    END IF;
    IF NEW.professor_id IS NOT NULL THEN
      SELECT u.tenant_id INTO v_user_tenant FROM public.usuarios u WHERE u.id = NEW.professor_id;
      IF v_user_tenant IS NULL OR v_user_tenant IS DISTINCT FROM NEW.tenant_id THEN
        RAISE EXCEPTION 'professor do registro fora do tenant' USING ERRCODE = '23514';
      END IF;
    END IF;

  ELSIF TG_TABLE_NAME = 'presencas' THEN
    SELECT ra.tenant_id, ra.turma_id INTO v_parent_tenant, v_student_class
    FROM public.registros_aula ra WHERE ra.id = NEW.registro_aula_id;
    SELECT u.tenant_id INTO v_student_tenant FROM public.usuarios u WHERE u.id = NEW.usuario_id;
    IF v_parent_tenant IS NULL OR v_student_tenant IS NULL
       OR NEW.tenant_id IS DISTINCT FROM v_parent_tenant
       OR NEW.tenant_id IS DISTINCT FROM v_student_tenant THEN
      RAISE EXCEPTION 'presenca fora do tenant do registro/aluno' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.matriculas m
      WHERE m.usuario_id = NEW.usuario_id AND m.tenant_id = NEW.tenant_id
        AND m.turma_id = v_student_class AND m.situacao = 'ativa'
    ) THEN
      RAISE EXCEPTION 'aluno não está matriculado ativamente na turma da presença' USING ERRCODE = '23514';
    END IF;

  ELSIF TG_TABLE_NAME = 'materiais_professor' THEN
    IF NEW.disciplina_id IS NULL THEN
      RAISE EXCEPTION 'material professor exige disciplina exata' USING ERRCODE = '23514';
    END IF;
    SELECT t.tenant_id, t.curso_id INTO v_class_tenant, v_class_course
    FROM public.turmas t WHERE t.id = NEW.turma_id;
    SELECT d.tenant_id, d.curso_id INTO v_subject_tenant, v_subject_course
    FROM public.disciplinas d WHERE d.id = NEW.disciplina_id;
    IF v_class_tenant IS NULL OR v_subject_course IS NULL
       OR v_class_tenant IS DISTINCT FROM NEW.tenant_id
       OR v_subject_tenant IS DISTINCT FROM NEW.tenant_id
       OR v_subject_course IS DISTINCT FROM v_class_course THEN
      RAISE EXCEPTION 'material com turma/disciplina incompatíveis' USING ERRCODE = '23514';
    END IF;
    SELECT u.tenant_id INTO v_user_tenant FROM public.usuarios u WHERE u.id = NEW.professor_id;
    IF v_user_tenant IS NULL OR v_user_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'material com professor fora do tenant' USING ERRCODE = '23514';
    END IF;

  ELSIF TG_TABLE_NAME = 'avisos_turma' THEN
    SELECT t.tenant_id INTO v_parent_tenant FROM public.turmas t WHERE t.id = NEW.turma_id;
    IF v_parent_tenant IS NULL OR v_parent_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'aviso fora do tenant da turma' USING ERRCODE = '23514';
    END IF;
    IF NEW.professor_id IS NOT NULL THEN
      SELECT u.tenant_id INTO v_user_tenant FROM public.usuarios u WHERE u.id = NEW.professor_id;
      IF v_user_tenant IS NULL OR v_user_tenant IS DISTINCT FROM NEW.tenant_id THEN
        RAISE EXCEPTION 'autor do aviso fora do tenant' USING ERRCODE = '23514';
      END IF;
    END IF;

  ELSIF TG_TABLE_NAME = 'questoes' THEN
    SELECT d.tenant_id INTO v_parent_tenant FROM public.disciplinas d WHERE d.id = NEW.disciplina_id;
    IF v_parent_tenant IS NULL OR v_parent_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'questao fora do tenant da disciplina' USING ERRCODE = '23514';
    END IF;
    IF NEW.criado_por IS NOT NULL THEN
      SELECT u.tenant_id INTO v_user_tenant FROM public.usuarios u WHERE u.id = NEW.criado_por;
      IF v_user_tenant IS NULL OR v_user_tenant IS DISTINCT FROM NEW.tenant_id THEN
        RAISE EXCEPTION 'autor da questao fora do tenant' USING ERRCODE = '23514';
      END IF;
    END IF;

  ELSIF TG_TABLE_NAME = 'avaliacoes' THEN
    SELECT c.tenant_id INTO v_parent_tenant FROM public.cursos c WHERE c.id = NEW.curso_id;
    SELECT d.tenant_id, d.curso_id INTO v_assessment_tenant, v_subject_course
    FROM public.disciplinas d WHERE d.id = NEW.disciplina_id;
    IF v_parent_tenant IS NULL OR v_assessment_tenant IS NULL
       OR NEW.tenant_id IS DISTINCT FROM v_parent_tenant
       OR NEW.tenant_id IS DISTINCT FROM v_assessment_tenant
       OR v_subject_course IS DISTINCT FROM NEW.curso_id THEN
      RAISE EXCEPTION 'avaliacao com curso/disciplina incompatíveis' USING ERRCODE = '23514';
    END IF;
    IF NEW.turma_id IS NOT NULL THEN
      SELECT t.tenant_id, t.curso_id INTO v_parent_tenant, v_class_course
      FROM public.turmas t WHERE t.id = NEW.turma_id;
      IF v_parent_tenant IS NULL OR v_parent_tenant IS DISTINCT FROM NEW.tenant_id
         OR v_class_course IS DISTINCT FROM NEW.curso_id THEN
        RAISE EXCEPTION 'avaliacao fora da turma/curso do tenant' USING ERRCODE = '23514';
      END IF;
    END IF;
    IF NEW.criado_por IS NOT NULL THEN
      SELECT u.tenant_id INTO v_user_tenant FROM public.usuarios u WHERE u.id = NEW.criado_por;
      IF v_user_tenant IS NULL OR v_user_tenant IS DISTINCT FROM NEW.tenant_id THEN
        RAISE EXCEPTION 'autor da avaliacao fora do tenant' USING ERRCODE = '23514';
      END IF;
    END IF;

  ELSIF TG_TABLE_NAME = 'avaliacao_questoes' THEN
    SELECT a.tenant_id, a.disciplina_id INTO v_assessment_tenant, v_assessment_subject
    FROM public.avaliacoes a WHERE a.id = NEW.avaliacao_id;
    SELECT q.tenant_id, q.disciplina_id INTO v_question_tenant, v_question_subject
    FROM public.questoes q WHERE q.id = NEW.questao_id;
    IF v_assessment_tenant IS NULL OR v_question_tenant IS NULL
       OR v_assessment_tenant IS DISTINCT FROM v_question_tenant
       OR v_assessment_subject IS DISTINCT FROM v_question_subject THEN
      RAISE EXCEPTION 'questao incompatível com a disciplina da avaliacao' USING ERRCODE = '23514';
    END IF;

  ELSIF TG_TABLE_NAME = 'avaliacao_tentativas' THEN
    SELECT a.tenant_id, a.curso_id, a.turma_id INTO v_assessment_tenant, v_assessment_course, v_assessment_class
    FROM public.avaliacoes a WHERE a.id = NEW.avaliacao_id;
    SELECT m.tenant_id, m.usuario_id, m.curso_id, m.turma_id INTO v_parent_tenant, v_attempt_user, v_student_course, v_student_class
    FROM public.matriculas m WHERE m.id = NEW.matricula_id;
    SELECT u.tenant_id INTO v_student_tenant FROM public.usuarios u WHERE u.id = NEW.usuario_id;
    IF v_assessment_tenant IS NULL OR v_parent_tenant IS NULL OR v_student_tenant IS NULL
       OR NEW.tenant_id IS DISTINCT FROM v_assessment_tenant
       OR NEW.tenant_id IS DISTINCT FROM v_parent_tenant
       OR NEW.tenant_id IS DISTINCT FROM v_student_tenant
       OR v_attempt_user IS DISTINCT FROM NEW.usuario_id
       OR v_student_course IS DISTINCT FROM v_assessment_course
       OR (v_assessment_class IS NOT NULL AND v_student_class IS DISTINCT FROM v_assessment_class) THEN
      RAISE EXCEPTION 'tentativa fora da cadeia de tenant/curso/turma/aluno' USING ERRCODE = '23514';
    END IF;

  ELSIF TG_TABLE_NAME = 'avaliacao_respostas' THEN
    SELECT t.tenant_id, t.avaliacao_id INTO v_attempt_tenant, v_attempt_assessment
    FROM public.avaliacao_tentativas t WHERE t.id = NEW.tentativa_id;
    SELECT a.disciplina_id INTO v_assessment_subject
    FROM public.avaliacoes a WHERE a.id = v_attempt_assessment;
    SELECT q.tenant_id, q.disciplina_id INTO v_question_tenant, v_question_subject
    FROM public.questoes q WHERE q.id = NEW.questao_id;
    IF v_attempt_tenant IS NULL OR v_question_tenant IS NULL
       OR NEW.tenant_id IS DISTINCT FROM v_attempt_tenant
       OR v_question_tenant IS DISTINCT FROM NEW.tenant_id
       OR v_question_subject IS DISTINCT FROM v_assessment_subject THEN
      RAISE EXCEPTION 'resposta fora da avaliacao/disciplina' USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION public.sc004_assignment_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.ativo IS TRUE THEN
    NEW.revoked_at := NULL;
  ELSE
    NEW.revoked_at := COALESCE(NEW.revoked_at, now());
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_sc004_assignment_lifecycle ON public.atribuicoes_academicas_professor;
CREATE TRIGGER trg_sc004_assignment_lifecycle
BEFORE INSERT OR UPDATE ON public.atribuicoes_academicas_professor
FOR EACH ROW EXECUTE FUNCTION public.sc004_assignment_lifecycle();

DO $$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'usuarios','disciplinas','turmas','matriculas','professores_turmas',
    'atribuicoes_academicas_professor','registros_aula','presencas',
    'materiais_professor','avisos_turma','questoes','avaliacoes',
    'avaliacao_questoes','avaliacao_tentativas','avaliacao_respostas'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_sc004_parent_integrity ON public.%I', v_table);
    EXECUTE format(
      'CREATE TRIGGER trg_sc004_parent_integrity BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.sc004_validate_parent_integrity()',
      v_table
    );
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. Canonical authorization primitives
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.teacher_has_assignment(
  p_turma_id uuid,
  p_disciplina_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.atribuicoes_academicas_professor a
    JOIN public.usuarios u ON u.id = a.professor_id
      AND u.auth_user_id = auth.uid()
      AND u.ativo IS TRUE
      AND u.perfil = 'professor'
      AND u.tenant_id = a.tenant_id
    JOIN public.tenants tn ON tn.id = a.tenant_id AND tn.ativo IS TRUE
    JOIN public.turmas t ON t.id = a.turma_id
      AND t.tenant_id = a.tenant_id
      AND t.ativa IS TRUE
      AND t.unidade_id IS NOT NULL
    JOIN public.unidades un ON un.id = t.unidade_id
      AND un.tenant_id = a.tenant_id
      AND un.ativo IS TRUE
    JOIN public.disciplinas d ON d.id = a.disciplina_id
      AND d.tenant_id = a.tenant_id
    JOIN public.cursos c ON c.id = t.curso_id
      AND c.tenant_id = a.tenant_id
      AND c.ativo IS TRUE
      AND c.id = d.curso_id
    WHERE a.tenant_id = public.current_tenant_id()
      AND a.turma_id = p_turma_id
      AND a.disciplina_id = p_disciplina_id
      AND a.ativo IS TRUE
  )
$$;

CREATE OR REPLACE FUNCTION public.teacher_has_subject_assignment(
  p_disciplina_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.atribuicoes_academicas_professor a
    JOIN public.usuarios u ON u.id = a.professor_id
      AND u.auth_user_id = auth.uid()
      AND u.ativo IS TRUE
      AND u.perfil = 'professor'
      AND u.tenant_id = a.tenant_id
    JOIN public.tenants tn ON tn.id = a.tenant_id AND tn.ativo IS TRUE
    JOIN public.turmas t ON t.id = a.turma_id
      AND t.tenant_id = a.tenant_id
      AND t.ativa IS TRUE
      AND t.unidade_id IS NOT NULL
    JOIN public.unidades un ON un.id = t.unidade_id
      AND un.tenant_id = a.tenant_id
      AND un.ativo IS TRUE
    JOIN public.disciplinas d ON d.id = a.disciplina_id
      AND d.id = p_disciplina_id
      AND d.tenant_id = a.tenant_id
    JOIN public.cursos c ON c.id = t.curso_id
      AND c.id = d.curso_id
      AND c.tenant_id = a.tenant_id
      AND c.ativo IS TRUE
    WHERE a.tenant_id = public.current_tenant_id()
      AND a.disciplina_id = p_disciplina_id
      AND a.ativo IS TRUE
  )
$$;

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
    WHEN p_turma_id IS NULL THEN public.teacher_has_subject_assignment(p_disciplina_id)
    ELSE public.teacher_has_assignment(p_turma_id, p_disciplina_id)
  END
$$;

CREATE OR REPLACE FUNCTION public.get_teacher_assignment(
  p_turma_id uuid,
  p_disciplina_id uuid
)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT a.id
  FROM public.atribuicoes_academicas_professor a
  JOIN public.usuarios u ON u.id = a.professor_id
    AND u.auth_user_id = auth.uid()
    AND u.ativo IS TRUE
    AND u.perfil = 'professor'
  JOIN public.tenants tn ON tn.id = a.tenant_id AND tn.ativo IS TRUE
  JOIN public.turmas t ON t.id = a.turma_id AND t.ativa IS TRUE AND t.unidade_id IS NOT NULL
  JOIN public.unidades un ON un.id = t.unidade_id AND un.ativo IS TRUE
  JOIN public.disciplinas d ON d.id = a.disciplina_id
  JOIN public.cursos c ON c.id = t.curso_id AND c.id = d.curso_id AND c.ativo IS TRUE
  WHERE a.tenant_id = public.current_tenant_id()
    AND a.turma_id = p_turma_id
    AND a.disciplina_id = p_disciplina_id
    AND a.ativo IS TRUE
  LIMIT 1
$$;

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
  SELECT EXISTS (
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
      AND m.tenant_id = p_tenant_id
      AND m.situacao = 'ativa'
  )
$$;

-- Staff-only management path. Client values are inputs to validation, never
-- authority; the actor is always derived from auth.uid().
CREATE OR REPLACE FUNCTION public.create_teacher_assignment(
  p_teacher_user_id uuid,
  p_class_id uuid,
  p_subject_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant uuid := public.current_tenant_id();
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_staff() THEN
    RAISE EXCEPTION 'staff ativo requerido' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.usuarios u
    WHERE u.id = p_teacher_user_id AND u.tenant_id = v_tenant
      AND u.perfil = 'professor' AND u.ativo IS TRUE
  ) OR NOT EXISTS (
    SELECT 1 FROM public.turmas t
    JOIN public.unidades un ON un.id = t.unidade_id
      AND un.tenant_id = v_tenant AND un.ativo IS TRUE
    WHERE t.id = p_class_id AND t.tenant_id = v_tenant AND t.ativa IS TRUE
      AND t.unidade_id IS NOT NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.disciplinas d
    JOIN public.turmas t ON t.id = p_class_id
      AND t.curso_id = d.curso_id
      AND t.tenant_id = v_tenant
    WHERE d.id = p_subject_id AND d.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'assignment fora do tenant, curso, unidade ou estado ativo' USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.atribuicoes_academicas_professor(tenant_id, professor_id, turma_id, disciplina_id)
  VALUES (v_tenant, p_teacher_user_id, p_class_id, p_subject_id)
  RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION public.revoke_teacher_assignment(p_assignment_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_staff() THEN
    RAISE EXCEPTION 'staff ativo requerido' USING ERRCODE = '42501';
  END IF;
  UPDATE public.atribuicoes_academicas_professor
  SET ativo = false, revoked_at = COALESCE(revoked_at, now())
  WHERE id = p_assignment_id AND tenant_id = public.current_tenant_id() AND ativo IS TRUE;
  RETURN FOUND;
END
$$;

CREATE OR REPLACE FUNCTION public.my_teacher_assignments()
RETURNS TABLE (
  assignment_id uuid,
  class_id uuid,
  class_name text,
  subject_id uuid,
  subject_name text,
  course_id uuid,
  course_name text,
  unit_id uuid,
  unit_name text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT a.id, t.id, t.nome, d.id, d.nome, c.id, c.nome, un.id, un.nome
  FROM public.atribuicoes_academicas_professor a
  JOIN public.usuarios u ON u.id = a.professor_id
    AND u.auth_user_id = auth.uid()
    AND u.ativo IS TRUE
    AND u.perfil = 'professor'
  JOIN public.tenants tn ON tn.id = a.tenant_id AND tn.ativo IS TRUE
  JOIN public.turmas t ON t.id = a.turma_id
    AND t.tenant_id = a.tenant_id AND t.ativa IS TRUE AND t.unidade_id IS NOT NULL
  JOIN public.unidades un ON un.id = t.unidade_id
    AND un.tenant_id = a.tenant_id AND un.ativo IS TRUE
  JOIN public.disciplinas d ON d.id = a.disciplina_id AND d.tenant_id = a.tenant_id
  JOIN public.cursos c ON c.id = t.curso_id
    AND c.id = d.curso_id AND c.tenant_id = a.tenant_id AND c.ativo IS TRUE
  WHERE a.tenant_id = public.current_tenant_id()
    AND a.ativo IS TRUE
  ORDER BY t.nome, d.ordem, d.nome, a.id
$$;

CREATE OR REPLACE FUNCTION public.teacher_assignment_roster(p_assignment_id uuid)
RETURNS TABLE (
  student_id uuid,
  student_name text,
  student_email text,
  enrollment_id uuid,
  class_id uuid,
  subject_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT u.id, u.nome, u.email, m.id, a.turma_id, a.disciplina_id
  FROM public.atribuicoes_academicas_professor a
  JOIN public.usuarios actor ON actor.id = a.professor_id
    AND actor.auth_user_id = auth.uid()
    AND actor.ativo IS TRUE
    AND actor.perfil = 'professor'
  JOIN public.tenants tn ON tn.id = a.tenant_id AND tn.ativo IS TRUE
  JOIN public.turmas t ON t.id = a.turma_id AND t.ativa IS TRUE AND t.unidade_id IS NOT NULL
  JOIN public.unidades un ON un.id = t.unidade_id AND un.ativo IS TRUE
  JOIN public.matriculas m ON m.turma_id = a.turma_id
    AND m.tenant_id = a.tenant_id
    AND m.situacao = 'ativa'
  JOIN public.usuarios u ON u.id = m.usuario_id
    AND u.tenant_id = a.tenant_id
    AND u.ativo IS TRUE
  WHERE a.id = p_assignment_id
    AND a.tenant_id = public.current_tenant_id()
    AND a.ativo IS TRUE
$$;

DO $$
BEGIN
  REVOKE ALL ON FUNCTION public.teacher_has_assignment(uuid, uuid) FROM PUBLIC, anon, authenticated;
  REVOKE ALL ON FUNCTION public.teacher_has_subject_assignment(uuid) FROM PUBLIC, anon, authenticated;
  REVOKE ALL ON FUNCTION public.teacher_assessment_scope(uuid, uuid) FROM PUBLIC, anon, authenticated;
  REVOKE ALL ON FUNCTION public.get_teacher_assignment(uuid, uuid) FROM PUBLIC, anon, authenticated;
  REVOKE ALL ON FUNCTION public.student_active_in_class(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
  REVOKE ALL ON FUNCTION public.create_teacher_assignment(uuid, uuid, uuid) FROM PUBLIC, anon;
  REVOKE ALL ON FUNCTION public.revoke_teacher_assignment(uuid) FROM PUBLIC, anon;
  REVOKE ALL ON FUNCTION public.my_teacher_assignments() FROM PUBLIC, anon;
  REVOKE ALL ON FUNCTION public.teacher_assignment_roster(uuid) FROM PUBLIC, anon;
  GRANT EXECUTE ON FUNCTION public.create_teacher_assignment(uuid, uuid, uuid) TO authenticated;
  GRANT EXECUTE ON FUNCTION public.revoke_teacher_assignment(uuid) TO authenticated;
  GRANT EXECUTE ON FUNCTION public.my_teacher_assignments() TO authenticated;
  -- RLS evaluates these SECURITY DEFINER helpers as the authenticated caller;
  -- authenticated must therefore have EXECUTE, while PUBLIC and anon remain
  -- explicitly denied. They accept no authority from the client.
  GRANT EXECUTE ON FUNCTION public.teacher_has_assignment(uuid, uuid) TO authenticated;
  GRANT EXECUTE ON FUNCTION public.teacher_has_subject_assignment(uuid) TO authenticated;
  GRANT EXECUTE ON FUNCTION public.teacher_assessment_scope(uuid, uuid) TO authenticated;
  GRANT EXECUTE ON FUNCTION public.get_teacher_assignment(uuid, uuid) TO authenticated;
  GRANT EXECUTE ON FUNCTION public.student_active_in_class(uuid, uuid, uuid) TO authenticated;
  GRANT EXECUTE ON FUNCTION public.teacher_assignment_roster(uuid) TO authenticated;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Legacy compatibility RPC: discovery only, never authority
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.minhas_turmas_professor()
RETURNS TABLE (turma_id uuid, turma_nome text, curso_nome text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT DISTINCT t.id, t.nome, c.nome
  FROM public.atribuicoes_academicas_professor a
  JOIN public.usuarios u ON u.id = a.professor_id
    AND u.auth_user_id = auth.uid() AND u.ativo IS TRUE AND u.perfil = 'professor'
  JOIN public.tenants tn ON tn.id = a.tenant_id AND tn.ativo IS TRUE
  JOIN public.turmas t ON t.id = a.turma_id AND t.tenant_id = a.tenant_id AND t.ativa IS TRUE
  JOIN public.unidades un ON un.id = t.unidade_id AND un.tenant_id = a.tenant_id AND un.ativo IS TRUE
  JOIN public.disciplinas d ON d.id = a.disciplina_id AND d.tenant_id = a.tenant_id
  JOIN public.cursos c ON c.id = t.curso_id AND c.id = d.curso_id AND c.ativo IS TRUE
  WHERE a.tenant_id = public.current_tenant_id() AND a.ativo IS TRUE
$$;
REVOKE ALL ON FUNCTION public.minhas_turmas_professor() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.minhas_turmas_professor() TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. RLS cutover: exact assignment for teachers; staff/student paths stay apart
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS registros_aula_professor ON public.registros_aula;
CREATE POLICY registros_aula_teacher_assignment ON public.registros_aula
  FOR ALL TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND professor_id = public.current_usuario_id()
    AND public.teacher_has_assignment(turma_id, disciplina_id)
  )
  WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND professor_id = public.current_usuario_id()
    AND public.teacher_has_assignment(turma_id, disciplina_id)
  );

DROP POLICY IF EXISTS presencas_professor ON public.presencas;
CREATE POLICY presencas_teacher_assignment ON public.presencas
  FOR ALL TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND EXISTS (
      SELECT 1
      FROM public.registros_aula ra
      WHERE ra.id = presencas.registro_aula_id
        AND ra.tenant_id = presencas.tenant_id
        AND public.teacher_has_assignment(ra.turma_id, ra.disciplina_id)
    )
    AND public.student_active_in_class(
      presencas.usuario_id,
      (SELECT ra.turma_id FROM public.registros_aula ra WHERE ra.id = presencas.registro_aula_id),
      presencas.tenant_id
    )
  )
  WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND EXISTS (
      SELECT 1
      FROM public.registros_aula ra
      WHERE ra.id = presencas.registro_aula_id
        AND ra.tenant_id = presencas.tenant_id
        AND public.teacher_has_assignment(ra.turma_id, ra.disciplina_id)
    )
    AND public.student_active_in_class(
      presencas.usuario_id,
      (SELECT ra.turma_id FROM public.registros_aula ra WHERE ra.id = presencas.registro_aula_id),
      presencas.tenant_id
    )
  );

DROP POLICY IF EXISTS materiais_prof_professor ON public.materiais_professor;
CREATE POLICY materiais_teacher_assignment ON public.materiais_professor
  FOR ALL TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND professor_id = public.current_usuario_id()
    AND public.teacher_has_assignment(turma_id, disciplina_id)
  )
  WITH CHECK (
    tenant_id = public.current_tenant_id()
    AND professor_id = public.current_usuario_id()
    AND disciplina_id IS NOT NULL
    AND public.teacher_has_assignment(turma_id, disciplina_id)
  );

DROP POLICY IF EXISTS materiais_prof_aluno_select ON public.materiais_professor;
CREATE POLICY materiais_student_select ON public.materiais_professor
  FOR SELECT TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND EXISTS (
      SELECT 1 FROM public.matriculas m
      JOIN public.turmas t ON t.id = materiais_professor.turma_id
      WHERE m.turma_id = materiais_professor.turma_id
        AND m.usuario_id = public.current_usuario_id()
        AND m.tenant_id = materiais_professor.tenant_id
        AND m.situacao = 'ativa'
        AND t.ativa IS TRUE
    )
  );

-- Announcements remain staff-managed/student-readable. No teacher class-wide
-- policy is created because a Subject assignment is not a class-wide grant.
DROP POLICY IF EXISTS avisos_professor ON public.avisos_turma;
DROP POLICY IF EXISTS avisos_aluno_select ON public.avisos_turma;
CREATE POLICY avisos_student_select ON public.avisos_turma
  FOR SELECT TO authenticated
  USING (
    tenant_id = public.current_tenant_id()
    AND EXISTS (
      SELECT 1 FROM public.matriculas m
      JOIN public.turmas t ON t.id = avisos_turma.turma_id
      WHERE m.turma_id = avisos_turma.turma_id
        AND m.usuario_id = public.current_usuario_id()
        AND m.tenant_id = avisos_turma.tenant_id
        AND m.situacao = 'ativa'
        AND t.ativa IS TRUE
    )
  );

DROP POLICY IF EXISTS questoes_docente ON public.questoes;
CREATE POLICY questoes_teacher_assignment ON public.questoes
  FOR ALL TO authenticated
  USING (
    public.is_staff()
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_has_subject_assignment(disciplina_id)
    )
  )
  WITH CHECK (
    public.is_staff()
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_has_subject_assignment(disciplina_id)
      AND criado_por = public.current_usuario_id()
    )
  );

DROP POLICY IF EXISTS avaliacoes_docente ON public.avaliacoes;
CREATE POLICY avaliacoes_teacher_assignment ON public.avaliacoes
  FOR ALL TO authenticated
  USING (
    public.is_staff()
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_assessment_scope(turma_id, disciplina_id)
    )
  )
  WITH CHECK (
    public.is_staff()
    OR (
      tenant_id = public.current_tenant_id()
      AND public.teacher_assessment_scope(turma_id, disciplina_id)
      AND criado_por = public.current_usuario_id()
    )
  );

DROP POLICY IF EXISTS avaliacao_questoes_docente ON public.avaliacao_questoes;
CREATE POLICY avaliacao_questoes_teacher_assignment ON public.avaliacao_questoes
  FOR ALL TO authenticated
  USING (
    public.is_staff()
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
    public.is_staff()
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

DROP POLICY IF EXISTS tentativas_docente ON public.avaliacao_tentativas;
CREATE POLICY tentativas_teacher_assignment ON public.avaliacao_tentativas
  FOR SELECT TO authenticated
  USING (
    public.is_staff()
    OR EXISTS (
      SELECT 1 FROM public.avaliacoes a
      WHERE a.id = avaliacao_tentativas.avaliacao_id
        AND a.tenant_id = public.current_tenant_id()
        AND public.teacher_assessment_scope(a.turma_id, a.disciplina_id)
    )
  );

DROP POLICY IF EXISTS respostas_docente ON public.avaliacao_respostas;
CREATE POLICY respostas_teacher_assignment ON public.avaliacao_respostas
  FOR ALL TO authenticated
  USING (
    public.is_staff()
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
    public.is_staff()
    OR EXISTS (
      SELECT 1
      FROM public.avaliacao_tentativas t
      JOIN public.avaliacoes a ON a.id = t.avaliacao_id
      WHERE t.id = avaliacao_respostas.tentativa_id
        AND t.tenant_id = public.current_tenant_id()
        AND public.teacher_assessment_scope(a.turma_id, a.disciplina_id)
    )
  );

-- ---------------------------------------------------------------------------
-- 6. Student class eligibility and server-side grading safety
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.avaliacoes_disponiveis_aluno()
RETURNS TABLE (
  avaliacao_id uuid,
  matricula_id uuid,
  curso_id uuid,
  disciplina_id uuid,
  turma_id uuid,
  titulo text,
  descricao text,
  disciplina_nome text,
  modo_aplicacao text,
  regra_liberacao text,
  intervalo_dias integer,
  tentativas_permitidas integer,
  tentativas_usadas integer,
  nota_minima numeric,
  disponivel boolean,
  motivo text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT
    a.id, m.id, a.curso_id, a.disciplina_id, a.turma_id, a.titulo, a.descricao,
    d.nome, a.modo_aplicacao, a.regra_liberacao, a.intervalo_dias,
    a.tentativas_permitidas,
    COALESCE((SELECT count(*)::integer FROM public.avaliacao_tentativas t
      WHERE t.avaliacao_id = a.id AND t.matricula_id = m.id), 0),
    a.nota_minima,
    (
      a.situacao = 'publicada'
      AND (a.disponivel_em IS NULL OR a.disponivel_em <= now())
      AND (a.turma_id IS NULL OR a.turma_id = m.turma_id)
      AND a.regra_liberacao = 'manual'
      OR (
        a.situacao = 'publicada'
        AND (a.disponivel_em IS NULL OR a.disponivel_em <= now())
        AND (a.turma_id IS NULL OR a.turma_id = m.turma_id)
        AND a.regra_liberacao = 'coorte'
        AND current_date >= m.data_matricula + (a.intervalo_dias * greatest(1, coalesce((
          SELECT count(*) + 1 FROM public.avaliacao_tentativas t2
          WHERE t2.avaliacao_id = a.id AND t2.matricula_id = m.id
        ), 1)))::integer
      )
      AND COALESCE((SELECT count(*) FROM public.avaliacao_tentativas t3
        WHERE t3.avaliacao_id = a.id AND t3.matricula_id = m.id
          AND t3.situacao <> 'expirada'), 0) < a.tentativas_permitidas
    ),
    CASE
      WHEN a.situacao <> 'publicada' THEN 'Não publicada'
      WHEN a.disponivel_em IS NOT NULL AND a.disponivel_em > now() THEN 'Disponível em breve'
      WHEN a.turma_id IS NOT NULL AND a.turma_id IS DISTINCT FROM m.turma_id THEN 'Turma incompatível'
      WHEN a.regra_liberacao = 'coorte' AND current_date < m.data_matricula + (a.intervalo_dias * greatest(1, coalesce((
        SELECT count(*) + 1 FROM public.avaliacao_tentativas t4
        WHERE t4.avaliacao_id = a.id AND t4.matricula_id = m.id
      ), 1)))::integer THEN 'Aguardando etapa da coorte'
      WHEN COALESCE((SELECT count(*) FROM public.avaliacao_tentativas t5
        WHERE t5.avaliacao_id = a.id AND t5.matricula_id = m.id
          AND t5.situacao <> 'expirada'), 0) >= a.tentativas_permitidas THEN 'Tentativas esgotadas'
      ELSE NULL
    END
  FROM public.avaliacoes a
  JOIN public.disciplinas d ON d.id = a.disciplina_id AND d.curso_id = a.curso_id
  JOIN public.matriculas m ON m.curso_id = a.curso_id
    AND m.usuario_id = public.current_usuario_id()
    AND m.tenant_id = public.current_tenant_id()
    AND m.situacao = 'ativa'
  WHERE a.tenant_id = public.current_tenant_id()
    AND (a.turma_id IS NULL OR a.turma_id = m.turma_id);
END
$$;

CREATE OR REPLACE FUNCTION public.iniciar_tentativa_avaliacao(p_avaliacao_id uuid, p_matricula_id uuid)
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
  v_agora timestamptz := now();
BEGIN
  SELECT * INTO v_avaliacao FROM public.avaliacoes
  WHERE id = p_avaliacao_id AND tenant_id = public.current_tenant_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Avaliação não encontrada'; END IF;
  SELECT * INTO v_matricula FROM public.matriculas
  WHERE id = p_matricula_id AND usuario_id = v_usuario_id
    AND tenant_id = public.current_tenant_id() AND situacao = 'ativa';
  IF NOT FOUND OR v_matricula.curso_id <> v_avaliacao.curso_id
     OR (v_avaliacao.turma_id IS NOT NULL AND v_matricula.turma_id IS DISTINCT FROM v_avaliacao.turma_id) THEN
    RAISE EXCEPTION 'Matrícula inválida para esta avaliação';
  END IF;
  IF v_avaliacao.turma_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.turmas t
    JOIN public.unidades un ON un.id = t.unidade_id
    WHERE t.id = v_avaliacao.turma_id AND t.tenant_id = v_avaliacao.tenant_id
      AND t.ativa IS TRUE AND un.ativo IS TRUE
  ) THEN
    RAISE EXCEPTION 'Turma da avaliação inativa ou inválida';
  END IF;
  IF v_avaliacao.situacao <> 'publicada' OR (v_avaliacao.disponivel_em IS NOT NULL AND v_avaliacao.disponivel_em > v_agora) THEN
    RAISE EXCEPTION 'Avaliação ainda não está disponível';
  END IF;
  SELECT COALESCE(MAX(numero_tentativa), 0) + 1 INTO v_numero
  FROM public.avaliacao_tentativas
  WHERE avaliacao_id = p_avaliacao_id AND matricula_id = p_matricula_id;
  IF v_numero > v_avaliacao.tentativas_permitidas THEN RAISE EXCEPTION 'Limite de tentativas atingido'; END IF;
  IF v_avaliacao.regra_liberacao = 'coorte'
     AND current_date < v_matricula.data_matricula + (v_avaliacao.intervalo_dias * v_numero)::integer THEN
    RAISE EXCEPTION 'Esta etapa da coorte ainda não está disponível';
  END IF;
  v_qtd := COALESCE(v_avaliacao.quantidade_questoes, 1000000);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'questao_id', q.id, 'enunciado', q.enunciado, 'tipo', q.tipo,
    'dificuldade', q.dificuldade, 'pontos', q.pontos,
    'alternativas', CASE WHEN q.tipo = 'objetiva' AND v_avaliacao.embaralhar_alternativas THEN
      COALESCE((SELECT jsonb_agg(alt ORDER BY random()) FROM jsonb_array_elements(q.alternativas) alt), '[]'::jsonb)
      ELSE q.alternativas END,
    '_gabarito', q.resposta_correta
  ) ORDER BY CASE WHEN v_avaliacao.embaralhar_questoes THEN random() ELSE q.ordem END), '[]'::jsonb)
  INTO v_questoes
  FROM (
    SELECT q.*, aq.ordem
    FROM public.avaliacao_questoes aq JOIN public.questoes q ON q.id = aq.questao_id
    WHERE aq.avaliacao_id = p_avaliacao_id AND q.ativa IS TRUE
    ORDER BY CASE WHEN v_avaliacao.embaralhar_questoes THEN random() ELSE aq.ordem END
    LIMIT v_qtd
  ) q;
  IF jsonb_array_length(v_questoes) = 0 THEN RAISE EXCEPTION 'A avaliação não possui questões ativas'; END IF;
  SELECT COALESCE(jsonb_object_agg(item->>'questao_id', item->>'_gabarito'), '{}'::jsonb)
    INTO v_gabarito FROM jsonb_array_elements(v_questoes) item;
  SELECT COALESCE(jsonb_agg(item - '_gabarito'), '[]'::jsonb)
    INTO v_questoes FROM jsonb_array_elements(v_questoes) item;
  INSERT INTO public.avaliacao_tentativas (
    tenant_id, avaliacao_id, matricula_id, usuario_id, numero_tentativa,
    expira_em, nota_maxima, questoes_ordem, gabarito_snapshot
  ) VALUES (
    v_avaliacao.tenant_id, v_avaliacao.id, v_matricula.id, v_usuario_id, v_numero,
    CASE WHEN v_avaliacao.expira_em_dias IS NULL THEN NULL ELSE v_agora + (v_avaliacao.expira_em_dias || ' days')::interval END,
    (SELECT COALESCE(sum((item->>'pontos')::numeric), 0) FROM jsonb_array_elements(v_questoes) item),
    v_questoes, v_gabarito
  ) RETURNING * INTO v_tentativa;
  RETURN jsonb_build_object(
    'id', v_tentativa.id, 'avaliacao_id', v_tentativa.avaliacao_id,
    'numero_tentativa', v_tentativa.numero_tentativa, 'situacao', v_tentativa.situacao,
    'iniciada_em', v_tentativa.iniciada_em, 'expira_em', v_tentativa.expira_em,
    'nota_maxima', v_tentativa.nota_maxima, 'questoes', v_tentativa.questoes_ordem
  );
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
  UPDATE public.avaliacao_tentativas SET nota = v_nota, nota_maxima = v_max,
    percentual = v_percentual,
    situacao = CASE WHEN v_pendentes = 0 THEN 'corrigida' ELSE 'enviada' END,
    aprovada = CASE WHEN v_pendentes = 0 THEN v_percentual >= v_avaliacao.nota_minima ELSE NULL END
  WHERE id = v_tentativa.id;
  RETURN jsonb_build_object('tentativa_id', v_tentativa.id,
    'situacao', CASE WHEN v_pendentes = 0 THEN 'corrigida' ELSE 'enviada' END,
    'percentual', v_percentual);
END
$$;

DO $$
BEGIN
  REVOKE ALL ON FUNCTION public.avaliacoes_disponiveis_aluno() FROM PUBLIC, anon;
  REVOKE ALL ON FUNCTION public.iniciar_tentativa_avaliacao(uuid, uuid) FROM PUBLIC, anon;
  REVOKE ALL ON FUNCTION public.corrigir_resposta_avaliacao(uuid, numeric, text) FROM PUBLIC, anon;
  GRANT EXECUTE ON FUNCTION public.avaliacoes_disponiveis_aluno() TO authenticated;
  GRANT EXECUTE ON FUNCTION public.iniciar_tentativa_avaliacao(uuid, uuid) TO authenticated;
  GRANT EXECUTE ON FUNCTION public.corrigir_resposta_avaliacao(uuid, numeric, text) TO authenticated;
END
$$;

-- ---------------------------------------------------------------------------
-- 7. gabarito_snapshot security hotfix
-- ---------------------------------------------------------------------------
REVOKE ALL ON public.avaliacao_tentativas FROM anon, authenticated;
GRANT SELECT (
  id, tenant_id, avaliacao_id, matricula_id, usuario_id, numero_tentativa,
  situacao, iniciada_em, expira_em, enviada_em, nota, nota_maxima,
  percentual, aprovada, questoes_ordem, created_at
) ON public.avaliacao_tentativas TO authenticated;

-- Ensure all canonical functions use an explicit empty search_path and expose
-- no anonymous/public execution. The database owner retains server-side use.
DO $$
BEGIN
  REVOKE ALL ON FUNCTION public.my_teacher_assignments() FROM PUBLIC, anon;
  REVOKE ALL ON FUNCTION public.create_teacher_assignment(uuid, uuid, uuid) FROM PUBLIC, anon;
  REVOKE ALL ON FUNCTION public.revoke_teacher_assignment(uuid) FROM PUBLIC, anon;
  GRANT EXECUTE ON FUNCTION public.my_teacher_assignments() TO authenticated;
  GRANT EXECUTE ON FUNCTION public.create_teacher_assignment(uuid, uuid, uuid) TO authenticated;
  GRANT EXECUTE ON FUNCTION public.revoke_teacher_assignment(uuid) TO authenticated;
END
$$;

-- End SC-004C/D.
