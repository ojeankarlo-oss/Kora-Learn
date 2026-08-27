-- KORA P0-002B: hash-only API keys, rotation audit, idempotent contacts,
-- and atomic multi-scope rate limiting for b2g-api.
-- pix-create, pix-webhook and Banco Inter secrets are intentionally out of scope.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- The pre-flight found zero existing API keys in this project. The legacy
-- plaintext column is retained only as a nullable compatibility marker during
-- this migration, then constrained to remain NULL. New keys must be issued with
-- a SHA-256 hash and a non-secret prefix.
ALTER TABLE public.api_keys
  ADD COLUMN IF NOT EXISTS chave_hash text,
  ADD COLUMN IF NOT EXISTS chave_prefixo text,
  ADD COLUMN IF NOT EXISTS ambiente text NOT NULL DEFAULT 'producao',
  ADD COLUMN IF NOT EXISTS integracao text NOT NULL DEFAULT 'b2g-api',
  ADD COLUMN IF NOT EXISTS revoked_at timestamptz,
  ADD COLUMN IF NOT EXISTS rotated_from_id uuid REFERENCES public.api_keys(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS last_rotated_at timestamptz;

UPDATE public.api_keys
SET chave_hash = encode(digest(chave, 'sha256'), 'hex'),
    chave_prefixo = left(chave, 8)
WHERE chave IS NOT NULL
  AND (chave_hash IS NULL OR chave_hash = '');

UPDATE public.api_keys
SET chave = NULL
WHERE chave IS NOT NULL
  AND chave_hash IS NOT NULL;

ALTER TABLE public.api_keys
  ALTER COLUMN chave DROP NOT NULL,
  ALTER COLUMN chave_hash SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'api_keys_hash_only'
      AND conrelid = 'public.api_keys'::regclass
  ) THEN
    ALTER TABLE public.api_keys
      ADD CONSTRAINT api_keys_hash_only
      CHECK (chave IS NULL AND chave_hash IS NOT NULL AND chave_prefixo IS NOT NULL);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'api_keys_ambiente_valid'
      AND conrelid = 'public.api_keys'::regclass
  ) THEN
    ALTER TABLE public.api_keys
      ADD CONSTRAINT api_keys_ambiente_valid
      CHECK (ambiente IN ('sandbox', 'staging', 'producao'));
  END IF;
END $$;

DROP INDEX IF EXISTS public.idx_api_keys_chave;

CREATE UNIQUE INDEX IF NOT EXISTS uq_api_keys_chave_hash
  ON public.api_keys (chave_hash);

CREATE INDEX IF NOT EXISTS idx_api_keys_tenant_integration_env
  ON public.api_keys (tenant_id, integracao, ambiente);

CREATE INDEX IF NOT EXISTS idx_api_keys_prefix
  ON public.api_keys (chave_prefixo);

CREATE TABLE IF NOT EXISTS public.api_key_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  api_key_id uuid REFERENCES public.api_keys(id) ON DELETE SET NULL,
  evento text NOT NULL CHECK (evento IN ('created', 'rotated', 'revoked', 'reactivated')),
  chave_prefixo text,
  integracao text NOT NULL DEFAULT 'b2g-api',
  ambiente text NOT NULL DEFAULT 'producao',
  criado_em timestamptz NOT NULL DEFAULT now(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

ALTER TABLE public.api_key_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS api_key_audit_staff_read ON public.api_key_audit;
CREATE POLICY api_key_audit_staff_read ON public.api_key_audit
  FOR SELECT TO authenticated
  USING (tenant_id = public.current_tenant_id() AND public.is_staff());

CREATE INDEX IF NOT EXISTS idx_api_key_audit_tenant_created
  ON public.api_key_audit (tenant_id, criado_em DESC);

CREATE OR REPLACE FUNCTION public.audit_api_key_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_event text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_event := CASE WHEN NEW.rotated_from_id IS NULL THEN 'created' ELSE 'rotated' END;
  ELSIF NEW.revoked_at IS NOT NULL AND OLD.revoked_at IS NULL THEN
    v_event := 'revoked';
  ELSIF NEW.ativo = false AND OLD.ativo = true THEN
    v_event := 'revoked';
  ELSIF NEW.ativo = true AND OLD.ativo = false THEN
    v_event := 'reactivated';
  ELSIF NEW.chave_hash IS DISTINCT FROM OLD.chave_hash
     OR NEW.rotated_from_id IS DISTINCT FROM OLD.rotated_from_id
     OR NEW.last_rotated_at IS DISTINCT FROM OLD.last_rotated_at THEN
    v_event := 'rotated';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO public.api_key_audit (
    tenant_id, api_key_id, evento, chave_prefixo, integracao, ambiente
  ) VALUES (
    NEW.tenant_id, NEW.id, v_event, NEW.chave_prefixo,
    COALESCE(NEW.integracao, 'b2g-api'), COALESCE(NEW.ambiente, 'producao')
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_api_key_audit ON public.api_keys;
CREATE TRIGGER trg_api_key_audit
  AFTER INSERT OR UPDATE OF ativo, revoked_at, chave_hash, chave_prefixo, rotated_from_id, last_rotated_at
  ON public.api_keys
  FOR EACH ROW EXECUTE FUNCTION public.audit_api_key_changes();

ALTER TABLE public.contacts
  ADD COLUMN IF NOT EXISTS idempotency_key text,
  ADD COLUMN IF NOT EXISTS idempotency_fingerprint text;

CREATE UNIQUE INDEX IF NOT EXISTS uq_contacts_tenant_idempotency
  ON public.contacts (tenant_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.api_rate_limit_buckets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  janela_inicio timestamptz NOT NULL,
  janela_segundos integer NOT NULL CHECK (janela_segundos BETWEEN 1 AND 3600),
  scope_kind text NOT NULL CHECK (scope_kind IN ('api_key', 'tenant', 'ip', 'route')),
  scope_value text NOT NULL,
  rota text NOT NULL,
  limite integer NOT NULL CHECK (limite > 0),
  contagem integer NOT NULL DEFAULT 0 CHECK (contagem >= 0),
  atualizado_em timestamptz NOT NULL DEFAULT now(),
  UNIQUE (janela_inicio, janela_segundos, scope_kind, scope_value, rota)
);

ALTER TABLE public.api_rate_limit_buckets ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_api_rate_limit_prune
  ON public.api_rate_limit_buckets (janela_inicio);

CREATE OR REPLACE FUNCTION public.consume_b2g_rate_limits(
  p_api_key_id uuid,
  p_tenant_id uuid,
  p_ip_hash text,
  p_route text,
  p_window_seconds integer DEFAULT 60
)
RETURNS TABLE (
  allowed boolean,
  retry_after_seconds integer,
  remaining integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_window_start timestamptz;
  v_count integer;
  v_scope record;
  v_key_limit integer;
  v_tenant_limit integer;
  v_ip_limit integer;
  v_route_limit integer;
  v_route_scope text;
  v_allowed boolean := true;
  v_remaining integer := 2147483647;
  v_retry integer := 0;
BEGIN
  IF p_route NOT IN ('GET:/health', 'GET:/contacts', 'POST:/contacts')
     OR p_ip_hash IS NULL OR p_ip_hash = ''
     OR p_window_seconds < 1 OR p_window_seconds > 3600 THEN
    RAISE EXCEPTION 'invalid rate limit configuration';
  END IF;

  IF p_route = 'GET:/health' THEN
    v_key_limit := 120;
    v_tenant_limit := 480;
    v_ip_limit := 240;
    v_route_limit := 600;
  ELSIF p_route = 'GET:/contacts' THEN
    v_key_limit := 60;
    v_tenant_limit := 180;
    v_ip_limit := 120;
    v_route_limit := 360;
  ELSE
    v_key_limit := 20;
    v_tenant_limit := 60;
    v_ip_limit := 30;
    v_route_limit := 120;
  END IF;

  v_window_start := to_timestamp(
    floor(extract(epoch FROM clock_timestamp()) / p_window_seconds) * p_window_seconds
  );
  v_route_scope := COALESCE(p_tenant_id::text, 'anon') || ':' || p_route;

  FOR v_scope IN
    SELECT * FROM (VALUES
      ('ip'::text, p_ip_hash, v_ip_limit),
      ('route'::text, v_route_scope, v_route_limit)
    ) AS scopes(scope_kind, scope_value, scope_limit)
    UNION ALL
    SELECT * FROM (VALUES
      ('api_key'::text, p_api_key_id::text, v_key_limit),
      ('tenant'::text, p_tenant_id::text, v_tenant_limit)
    ) AS authenticated_scopes(scope_kind, scope_value, scope_limit)
    WHERE p_api_key_id IS NOT NULL AND p_tenant_id IS NOT NULL
  LOOP
    INSERT INTO public.api_rate_limit_buckets (
      janela_inicio, janela_segundos, scope_kind, scope_value,
      rota, limite, contagem, atualizado_em
    ) VALUES (
      v_window_start, p_window_seconds, v_scope.scope_kind,
      v_scope.scope_value, p_route, v_scope.scope_limit, 1, clock_timestamp()
    )
    ON CONFLICT (janela_inicio, janela_segundos, scope_kind, scope_value, rota)
    DO UPDATE SET
      contagem = public.api_rate_limit_buckets.contagem + 1,
      limite = EXCLUDED.limite,
      atualizado_em = clock_timestamp()
    RETURNING contagem INTO v_count;

    v_remaining := LEAST(v_remaining, GREATEST(v_scope.scope_limit - v_count, 0));
    IF v_count > v_scope.scope_limit THEN
      v_allowed := false;
    END IF;
  END LOOP;

  IF NOT v_allowed THEN
    v_retry := GREATEST(
      1,
      CEIL(EXTRACT(EPOCH FROM (
        v_window_start + make_interval(secs => p_window_seconds) - clock_timestamp()
      )))::integer
    );
  END IF;

  RETURN QUERY SELECT v_allowed, v_retry, v_remaining;
END;
$$;

REVOKE ALL ON FUNCTION public.consume_b2g_rate_limits(uuid, uuid, text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.audit_api_key_changes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_b2g_rate_limits(uuid, uuid, text, text, integer) TO service_role;
