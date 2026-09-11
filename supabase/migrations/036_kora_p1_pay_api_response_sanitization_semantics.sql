-- KORA Payments P1-PAY-API-004B-3.
-- Extend response-key policy by semantic identifier tokens.
-- Do not modify migration 035.

create or replace function public.payment_api_response_is_sanitized(p_body jsonb)
returns boolean
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
declare
  item jsonb;
  json_key text;
  key_with_words text;
  normalized_key text;
  sensitive_identifier boolean;
begin
  if p_body is null then return false; end if;
  if jsonb_typeof(p_body) = 'object' then
    for json_key, item in
      select object_key, object_value
      from jsonb_each(p_body) as entries(object_key, object_value)
    loop
      -- Split camelCase before normalizing separators. Exact semantic tokens
      -- block sensitive classes while allowing tokenized/passwordPolicy/stackedItems.
      key_with_words := pg_catalog.regexp_replace(json_key, '([a-z0-9])([A-Z])', '\1 \2', 'g');
      normalized_key := pg_catalog.btrim(pg_catalog.regexp_replace(pg_catalog.lower(key_with_words), '[^a-z0-9]+', ' ', 'g'));
      -- Match complete normalized semantic identifiers. This blocks
      -- stack_trace/sql_error/provider_secret while allowing ordinary names
      -- such as tokenized, passwordPolicy and stackedItems.
      sensitive_identifier := normalized_key in (
        'authorization',
        'api key',
        'access token',
        'refresh token',
        'client secret',
        'credential secret',
        'private key',
        'password',
        'secret',
        'token',
        'stack',
        'stack trace',
        'sql',
        'sql error',
        'provider secret',
        'provider payment id',
        'provider account id'
      );

      if sensitive_identifier then return false; end if;
      if not public.payment_api_response_is_sanitized(item) then return false; end if;
    end loop;
  elsif jsonb_typeof(p_body) = 'array' then
    for item in select value from jsonb_array_elements(p_body) loop
      if not public.payment_api_response_is_sanitized(item) then return false; end if;
    end loop;
  end if;
  return true;
end;
$$;

revoke all on function public.payment_api_response_is_sanitized(jsonb) from public, anon, authenticated;
grant execute on function public.payment_api_response_is_sanitized(jsonb) to service_role;
