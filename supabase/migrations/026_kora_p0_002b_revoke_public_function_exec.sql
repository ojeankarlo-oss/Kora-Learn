-- KORA P0-002B follow-up: remove inherited function execution grants.
-- Only the Edge Function runtime service_role may call the limiter; the audit
-- trigger is callable only by PostgreSQL through its trigger execution path.

REVOKE ALL ON FUNCTION public.consume_b2g_rate_limits(uuid, uuid, text, text, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_b2g_rate_limits(uuid, uuid, text, text, integer)
  TO service_role;

REVOKE ALL ON FUNCTION public.audit_api_key_changes()
  FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS api_rate_limit_buckets_service_role_all
  ON public.api_rate_limit_buckets;
CREATE POLICY api_rate_limit_buckets_service_role_all
  ON public.api_rate_limit_buckets
  FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);
