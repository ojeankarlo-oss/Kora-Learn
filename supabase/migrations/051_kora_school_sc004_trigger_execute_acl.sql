-- SC004 trigger-only SECURITY DEFINER helpers must not expose caller EXECUTE.
-- Image defaults can grant named roles independently of PUBLIC.
BEGIN;

REVOKE EXECUTE ON FUNCTION public.sc004_assignment_lifecycle()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.sc004_validate_parent_integrity()
  FROM PUBLIC, anon, authenticated, service_role;

-- Fail closed on residual effective privileges (including inherited grants).
-- Do not guess or rewrite role memberships to make this assertion pass.
DO $acl$
DECLARE
  target_function text;
  target_role text;
BEGIN
  FOREACH target_function IN ARRAY ARRAY[
    'public.sc004_assignment_lifecycle()',
    'public.sc004_validate_parent_integrity()'
  ] LOOP
    FOREACH target_role IN ARRAY ARRAY['public','anon','authenticated','service_role'] LOOP
      IF has_function_privilege(target_role,target_function,'EXECUTE') IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'SC004 residual EXECUTE: role=% function=%',target_role,target_function;
      END IF;
    END LOOP;
  END LOOP;
END
$acl$;

COMMIT;
