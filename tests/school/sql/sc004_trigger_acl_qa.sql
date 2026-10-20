\set ON_ERROR_STOP on
-- Additional regression evidence. Existing A/B and C/D expectations stay exact.
RESET ROLE;
\echo 'SC004 ACL effective matrix (includes inherited privileges)'
SELECT p.oid::regprocedure AS function_name,pg_get_userbyid(p.proowner) AS owner,
       p.prosecdef,p.prorettype::regtype AS return_type,p.proacl
FROM pg_proc p WHERE p.oid IN (
  'public.sc004_assignment_lifecycle()'::regprocedure,
  'public.sc004_validate_parent_integrity()'::regprocedure);
SELECT f.signature,r.role_name,has_function_privilege(r.role_name,f.signature,'EXECUTE') AS effective_execute
FROM (VALUES ('public.sc004_assignment_lifecycle()'),('public.sc004_validate_parent_integrity()')) f(signature)
CROSS JOIN (VALUES ('public'),('anon'),('authenticated'),('service_role')) r(role_name)
ORDER BY f.signature,r.role_name;
-- MEMBER includes NOINHERIT paths available through SET ROLE; USAGE means
-- immediately inherited privileges. Report both instead of conflating them.
SELECT actor.rolname AS actor,inherited.rolname AS reachable_role,
       pg_has_role(actor.oid,inherited.oid,'USAGE') AS immediately_inherited,
       pg_has_role(actor.oid,inherited.oid,'MEMBER') AS set_role_reachable
FROM pg_roles actor CROSS JOIN pg_roles inherited
WHERE actor.rolname IN ('anon','authenticated','service_role') AND actor.oid<>inherited.oid
  AND pg_has_role(actor.oid,inherited.oid,'MEMBER') ORDER BY actor.rolname,inherited.rolname;
SELECT p.oid::regprocedure AS function_name,a.grantee,a.privilege_type,a.is_grantable
FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
WHERE p.oid IN ('public.sc004_assignment_lifecycle()'::regprocedure,
  'public.sc004_validate_parent_integrity()'::regprocedure);
SELECT pg_temp.qa_probe_l4_execute('R58-ACL-EFFECTIVE-NO-INHERITED-EXECUTE');
SELECT actor.rolname AS actor,reachable.rolname AS reachable_role,f.signature,
       has_function_privilege(actor.oid,f.signature,'EXECUTE') AS actor_effective_execute,
       pg_has_role(actor.oid,reachable.oid,'USAGE') AS immediately_inherited,
       has_function_privilege(reachable.oid,f.signature,'EXECUTE') AS potential_set_role_execute
FROM pg_roles actor CROSS JOIN pg_roles reachable
CROSS JOIN (VALUES ('public.sc004_assignment_lifecycle()'),('public.sc004_validate_parent_integrity()')) f(signature)
WHERE actor.rolname IN ('anon','authenticated','service_role')
  AND pg_has_role(actor.oid,reachable.oid,'MEMBER') ORDER BY actor.rolname,reachable.rolname,f.signature;
SELECT pg_temp.qa_record('R58-ACL-MEMBERSHIP-SET-ROLE','DENY',
  CASE WHEN EXISTS (
    SELECT 1 FROM pg_roles actor CROSS JOIN pg_roles reachable
    CROSS JOIN (VALUES ('public.sc004_assignment_lifecycle()'),('public.sc004_validate_parent_integrity()')) f(signature)
    WHERE actor.rolname IN ('anon','authenticated','service_role')
      AND pg_has_role(actor.oid,reachable.oid,'MEMBER')
      AND has_function_privilege(reachable.oid,f.signature,'EXECUTE'))
    THEN 'ALLOW' ELSE 'DENY' END,'BLOCKING POTENTIAL SET ROLE EXECUTE','','',
    'MEMBER reachability checked separately from effective inherited EXECUTE');

-- R58 named-grant mutation, separate from the frozen 22 C/D mutation groups.
SELECT pg_temp.qa_probe_l4_execute('R58-ACL-NAMED-GRANT-BASELINE');
DO $named_baseline$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM qa_results WHERE id='R58-ACL-NAMED-GRANT-BASELINE'
    AND expected='DENY' AND observed='DENY' AND result='PASS') THEN
    RAISE EXCEPTION 'R58 named grant baseline must be PASS/DENY';
  END IF;
END
$named_baseline$;
BEGIN;
GRANT EXECUTE ON FUNCTION public.sc004_assignment_lifecycle() TO service_role;
SELECT pg_temp.qa_probe_l4_execute('R58-ACL-NAMED-GRANT-MUTATED');
DO $named_mutated$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM qa_results WHERE id='R58-ACL-NAMED-GRANT-MUTATED'
    AND expected='DENY' AND observed='ALLOW' AND result='FAIL')
    OR has_function_privilege('service_role','public.sc004_assignment_lifecycle()','EXECUTE') IS DISTINCT FROM true
    OR has_function_privilege('public','public.sc004_assignment_lifecycle()','EXECUTE') IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'R58 named grant mutation must be FAIL/ALLOW with PUBLIC still denied';
  END IF;
END
$named_mutated$;
-- The intentional FAIL is evidence, never a passing normal-test result.
SELECT * FROM qa_results WHERE id='R58-ACL-NAMED-GRANT-MUTATED';
ROLLBACK;
SELECT pg_temp.qa_probe_l4_execute('R58-ACL-NAMED-GRANT-ROLLBACK');
DO $named_rollback$
BEGIN
  IF EXISTS (SELECT 1 FROM qa_results WHERE id='R58-ACL-NAMED-GRANT-MUTATED')
    OR NOT EXISTS (SELECT 1 FROM qa_results WHERE id='R58-ACL-NAMED-GRANT-ROLLBACK'
      AND expected='DENY' AND observed='DENY' AND result='PASS') THEN
    RAISE EXCEPTION 'R58 named grant rollback must restore PASS/DENY';
  END IF;
END
$named_rollback$;
\echo 'R58_NAMED_GRANT: baseline PASS/DENY; mutation FAIL/ALLOW detected; rollback PASS/DENY'

-- Controlled fixture: schema USAGE and table TRIGGER are explicitly granted so
-- only the target function's EXECUTE can be the intended denial.
CREATE SCHEMA qa_sc004_acl_probe;
CREATE TABLE qa_sc004_acl_probe.target(id uuid);
GRANT USAGE ON SCHEMA qa_sc004_acl_probe TO anon,authenticated,service_role;
GRANT TRIGGER ON qa_sc004_acl_probe.target TO anon,authenticated,service_role;
DO $binding$
DECLARE
  actor_role text;
  function_name text;
  observed text;
  failure_state text;
  failure_message text;
BEGIN
  FOREACH function_name IN ARRAY ARRAY['sc004_assignment_lifecycle','sc004_validate_parent_integrity'] LOOP
    -- Positive creation control: the signature is valid and owner binding works.
    EXECUTE format('CREATE TRIGGER qa_owner_control BEFORE INSERT ON qa_sc004_acl_probe.target FOR EACH ROW EXECUTE FUNCTION public.%I()',function_name);
    DROP TRIGGER qa_owner_control ON qa_sc004_acl_probe.target;
    FOREACH actor_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
      IF NOT has_schema_privilege(actor_role,'qa_sc004_acl_probe','USAGE')
         OR NOT has_schema_privilege(actor_role,'public','USAGE')
         OR NOT has_table_privilege(actor_role,'qa_sc004_acl_probe.target','TRIGGER') THEN
        RAISE EXCEPTION 'ACL binding fixture prerequisites failed for %',actor_role;
      END IF;
      observed := 'INCONCLUSIVE';
      BEGIN
        EXECUTE format('SET LOCAL ROLE %I',actor_role);
        EXECUTE format('CREATE TRIGGER qa_forbidden BEFORE INSERT ON qa_sc004_acl_probe.target FOR EACH ROW EXECUTE FUNCTION public.%I()',function_name);
        observed := 'ALLOW';
        RAISE EXCEPTION '__QA_ACL_BIND_ROLLBACK__';
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS failure_state=RETURNED_SQLSTATE,failure_message=MESSAGE_TEXT;
        IF failure_state='42501' AND failure_message='permission denied for function public.'||function_name THEN
          observed := 'DENY';
        ELSIF failure_message <> '__QA_ACL_BIND_ROLLBACK__' THEN
          observed := 'INCONCLUSIVE';
        END IF;
      END;
      RESET ROLE;
      PERFORM pg_temp.qa_record('R58-ACL-BIND-'||function_name||'-'||actor_role,'DENY',observed,
        'BLOCKING TRIGGER FUNCTION BINDING','','',
        'schema_usage=true table_trigger=true sqlstate='||failure_state||' message='||failure_message);
    END LOOP;
  END LOOP;
END
$binding$;
-- QA-only NOINHERIT fixture. Everything inside the inner subtransaction is
-- rolled back; no production owner, membership or grant is changed.
DO $noinherit$
DECLARE
  detected boolean := false;
  failure_message text;
  failure_state text;
BEGIN
  BEGIN
    CREATE ROLE sc004_r58_qa_noinherit NOLOGIN NOINHERIT;
    CREATE ROLE sc004_r58_qa_executor NOLOGIN;
    GRANT sc004_r58_qa_executor TO sc004_r58_qa_noinherit;
    CREATE FUNCTION qa_sc004_acl_probe.membership_marker() RETURNS integer
      LANGUAGE sql AS $marker$ SELECT 1 $marker$;
    REVOKE EXECUTE ON FUNCTION qa_sc004_acl_probe.membership_marker() FROM PUBLIC;
    GRANT USAGE ON SCHEMA qa_sc004_acl_probe TO sc004_r58_qa_noinherit,sc004_r58_qa_executor;
    GRANT EXECUTE ON FUNCTION qa_sc004_acl_probe.membership_marker() TO sc004_r58_qa_executor;
    detected := pg_has_role('sc004_r58_qa_noinherit','sc004_r58_qa_executor','MEMBER')
      AND NOT pg_has_role('sc004_r58_qa_noinherit','sc004_r58_qa_executor','USAGE')
      AND NOT has_function_privilege('sc004_r58_qa_noinherit','qa_sc004_acl_probe.membership_marker()','EXECUTE')
      AND has_function_privilege('sc004_r58_qa_executor','qa_sc004_acl_probe.membership_marker()','EXECUTE');
    RAISE EXCEPTION '__QA_NOINHERIT_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS failure_state=RETURNED_SQLSTATE,failure_message=MESSAGE_TEXT;
    IF failure_message <> '__QA_NOINHERIT_ROLLBACK__' THEN detected := false; END IF;
  END;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('sc004_r58_qa_noinherit','sc004_r58_qa_executor'))
     OR to_regprocedure('qa_sc004_acl_probe.membership_marker()') IS NOT NULL THEN
    RAISE EXCEPTION 'NOINHERIT fixture rollback left objects behind';
  END IF;
  PERFORM pg_temp.qa_record('R58-ACL-NOINHERIT-SELFTEST','SET_ROLE_ONLY',
    CASE WHEN detected THEN 'SET_ROLE_ONLY' ELSE 'INCONCLUSIVE' END,
    'HARNESS SELF-TEST','','','QA-only MEMBER=true USAGE=false effective_execute=false potential_execute=true; rollback=true sqlstate='||failure_state);
  PERFORM pg_temp.qa_archive_selftest('R58-ACL-NOINHERIT-SELFTEST','SET_ROLE_ONLY');
END
$noinherit$;
DROP TABLE qa_sc004_acl_probe.target;
DROP SCHEMA qa_sc004_acl_probe;

-- Existing installed triggers must remain unqualified, enabled, BEFORE row
-- INSERT/UPDATE triggers on the real assignment relation.
SELECT pg_temp.qa_record('R58-ACL-INSTALLED-TRIGGERS','PRESENT',
  CASE WHEN (SELECT count(*) FROM pg_trigger t
    WHERE t.tgrelid='public.atribuicoes_academicas_professor'::regclass
      AND t.tgenabled='O' AND t.tgtype=23 AND t.tgqual IS NULL
      AND ((t.tgname='trg_sc004_assignment_lifecycle' AND t.tgfoid='public.sc004_assignment_lifecycle()'::regprocedure)
        OR (t.tgname='trg_sc004_parent_integrity' AND t.tgfoid='public.sc004_validate_parent_integrity()'::regprocedure)))=2
    THEN 'PRESENT' ELSE 'ABSENT' END,'BLOCKING LEGITIMATE TRIGGER RETENTION','','','exact installed trigger catalog');
DO $behavior$
DECLARE
  before_row text;
  after_row text;
  affected integer;
  behavior_ok boolean := false;
  failure_state text;
  failure_message text;
  observed text := 'INCONCLUSIVE';
BEGIN
  SELECT to_jsonb(a)::text INTO STRICT before_row FROM public.atribuicoes_academicas_professor a
    WHERE id='aa100000-0000-0000-0000-000000000001';
  BEGIN
    UPDATE public.atribuicoes_academicas_professor SET ativo=false,revoked_at=NULL
      WHERE id='aa100000-0000-0000-0000-000000000001';
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected<>1 OR NOT EXISTS (SELECT 1 FROM public.atribuicoes_academicas_professor
      WHERE id='aa100000-0000-0000-0000-000000000001' AND ativo=false AND revoked_at IS NOT NULL) THEN
      RAISE EXCEPTION 'assignment revocation trigger did not run';
    END IF;
    UPDATE public.atribuicoes_academicas_professor SET ativo=true
      WHERE id='aa100000-0000-0000-0000-000000000001';
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected<>1 OR NOT EXISTS (SELECT 1 FROM public.atribuicoes_academicas_professor
      WHERE id='aa100000-0000-0000-0000-000000000001' AND ativo=true AND revoked_at IS NULL) THEN
      RAISE EXCEPTION 'assignment reactivation trigger did not run';
    END IF;
    behavior_ok := true;
    RAISE EXCEPTION '__QA_ACL_BEHAVIOR_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS failure_state=RETURNED_SQLSTATE,failure_message=MESSAGE_TEXT;
    IF failure_message <> '__QA_ACL_BEHAVIOR_ROLLBACK__' THEN behavior_ok := false; END IF;
  END;
  SELECT to_jsonb(a)::text INTO STRICT after_row FROM public.atribuicoes_academicas_professor a
    WHERE id='aa100000-0000-0000-0000-000000000001';
  PERFORM pg_temp.qa_record('R58-ACL-LEGITIMATE-LIFECYCLE','ALLOW',
    CASE WHEN behavior_ok AND before_row=after_row THEN 'ALLOW' ELSE 'INCONCLUSIVE' END,
    'BLOCKING LEGITIMATE TRIGGER RETENTION',before_row,after_row,'owner maintenance; rollback=true message='||failure_message);
  BEGIN
    UPDATE public.atribuicoes_academicas_professor SET tenant_id='b1000000-0000-0000-0000-000000000001'
      WHERE id='aa100000-0000-0000-0000-000000000001';
    observed := 'ALLOW';
    RAISE EXCEPTION '__QA_ACL_TENANT_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS failure_state=RETURNED_SQLSTATE,failure_message=MESSAGE_TEXT;
    IF failure_state='23514' AND failure_message='professor fora do tenant da atribuicao' THEN observed := 'DENY';
    ELSIF failure_message <> '__QA_ACL_TENANT_ROLLBACK__' THEN observed := 'INCONCLUSIVE'; END IF;
  END;
  SELECT to_jsonb(a)::text INTO STRICT after_row FROM public.atribuicoes_academicas_professor a
    WHERE id='aa100000-0000-0000-0000-000000000001';
  IF before_row IS DISTINCT FROM after_row THEN observed := 'STATE_CHANGED'; END IF;
  PERFORM pg_temp.qa_record('R58-ACL-CROSS-TENANT-INTEGRITY','DENY',observed,
    'BLOCKING PRIVILEGED TENANT INTEGRITY',before_row,after_row,'sqlstate='||failure_state||' message='||failure_message);
END
$behavior$;
\echo 'SC004 ACL REGRESSION RESULTS'
SELECT * FROM qa_results WHERE id LIKE 'R58-ACL-%' ORDER BY id;
DO $gate$
BEGIN
  IF (SELECT count(*) FROM qa_results WHERE id LIKE 'R58-ACL-%')<>13
     OR EXISTS (SELECT 1 FROM qa_results WHERE id LIKE 'R58-ACL-%' AND result<>'PASS') THEN
    RAISE EXCEPTION 'SC004 ACL regression failed closed';
  END IF;
END
$gate$;
