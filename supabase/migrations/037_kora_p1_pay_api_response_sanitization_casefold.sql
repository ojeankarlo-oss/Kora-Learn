-- KORA Payments P1-PAY-API-004B-6.
-- Make sensitive response identifiers invariant to case and separators.

create or replace function public.payment_api_response_is_sanitized(p_body jsonb)
returns boolean
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
declare
  item jsonb;
  json_key text;
  compact_key text;
begin
  if p_body is null then return false; end if;
  if jsonb_typeof(p_body) = 'object' then
    for json_key, item in
      select object_key, object_value
      from jsonb_each(p_body) as entries(object_key, object_value)
    loop
      -- Case-fold and remove separators before matching complete semantic
      -- identifiers. Ordinary compounds remain allowed because matching is exact.
      compact_key := pg_catalog.regexp_replace(
        pg_catalog.lower(json_key),
        '[^a-z0-9]+',
        '',
        'g'
      );
      if compact_key in (
        'authorization',
        'apikey',
        'accesstoken',
        'refreshtoken',
        'clientsecret',
        'credentialsecret',
        'privatekey',
        'password',
        'secret',
        'token',
        'stack',
        'stacktrace',
        'sql',
        'sqlerror',
        'providersecret',
        'providerpaymentid',
        'provideraccountid'
      ) then
        return false;
      end if;
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
