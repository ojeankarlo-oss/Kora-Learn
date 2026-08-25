-- KORA LEARN — Migration 024: P0-001C (security cleanup)
-- Purpose: make the RH projection view honor the querying user's RLS.
-- No salary column is added or exposed. No grants or base-table RLS are changed.

alter view public.colaboradores_sem_salario
  set (security_invoker = true);

comment on view public.colaboradores_sem_salario is
  'Projection without salary that honors the querying user permissions and RLS.';
