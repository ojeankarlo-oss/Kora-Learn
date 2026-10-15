\set ON_ERROR_STOP on
-- Environment preflight only; no product object or authorization is changed.
CREATE EXTENSION IF NOT EXISTS dblink;
DO $auth$
DECLARE
  fixture_password text := nullif(current_setting('kora.ci.dblink_password',true),'');
  remote_user text;
  remote_super boolean;
  phase text := 'preflight';
  failure_state text;
BEGIN
  IF current_user <> 'postgres' OR session_user <> 'postgres'
     OR (SELECT rolsuper FROM pg_roles WHERE rolname=current_user) IS DISTINCT FROM false
     OR fixture_password IS NULL THEN
    RAISE EXCEPTION 'SC004 dblink fixture prerequisites missing';
  END IF;
  phase := 'connect';
  PERFORM dblink_connect('sc004_auth_preflight',format(
    'host=127.0.0.1 port=5432 dbname=%s user=postgres password=%s connect_timeout=5',
    current_database(),fixture_password));
  phase := 'identity';
  SELECT role_name,is_super INTO STRICT remote_user,remote_super
    FROM dblink('sc004_auth_preflight',
      'SELECT current_user::text,rolsuper FROM pg_roles WHERE rolname=current_user')
      AS identity_row(role_name text,is_super boolean);
  IF remote_user <> 'postgres' OR remote_super IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'SC004 dblink changed fixture privilege identity';
  END IF;
  PERFORM dblink_disconnect('sc004_auth_preflight');
  RAISE NOTICE 'SC004_DBLINK_AUTH: PASS (password-authenticated non-superuser)';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS failure_state=RETURNED_SQLSTATE;
  BEGIN PERFORM dblink_disconnect('sc004_auth_preflight'); EXCEPTION WHEN OTHERS THEN NULL; END;
  -- Never propagate libpq conninfo, exception detail/context, or password values.
  RAISE EXCEPTION 'SC004_DBLINK_AUTH failed phase=% sqlstate=% (credential diagnostics suppressed)',phase,failure_state;
END
$auth$;
