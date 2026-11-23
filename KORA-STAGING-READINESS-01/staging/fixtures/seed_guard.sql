-- ============================================================================
-- KORA-STAGING — trava fail-closed do alvo do seed (PROVISIONING-03-FIX).
-- Define pg_temp.kora_stg_assert_seed_target(): aborta (raise exception) a menos
-- que o banco contenha SOMENTE dados sintéticos + o estado de baseline conhecido.
--
-- Estado de baseline tolerado (exatamente este, nada além):
--   * 1 tenant slug 'kora-demo', nome 'KORA Demo', plano 'starter'
--     (supabase/migrations/001_kora_learn_nucleo.sql:413-415; config ajustado por
--     003/005/006/008/011 — config não é verificado, não cria vínculos);
--   * 1 linha em public.unidades desse tenant, nome 'Unidade Bela Vista'
--     (supabase/migrations/004_kora_learn_fase5.sql:48-55);
--   * nenhum outro registro, em qualquer tabela, vinculado a esse tenant
--     (toda coluna com FK para public.tenants ou chamada tenant_id é varrida).
-- Qualquer outro tenant cujo slug não seja 'kora-stg-%', qualquer usuário auth
-- não sintético, a ausência do tenant de baseline ou um vínculo extra: ABORT.
-- Não altera dados. Usado por academic_seed.sql e seed_guard_regression.sql.
-- ============================================================================
create or replace function pg_temp.kora_stg_assert_seed_target()
returns void
language plpgsql
as $guard$
declare
  v_foreign_tenants int;
  v_foreign_users   int;
  v_demo_count      int;
  v_demo_id         uuid;
  v_unexpected      text := '';
  v_n               bigint;
  r                 record;
begin
  select count(*) into v_foreign_tenants from public.tenants
   where slug is null or (slug not like 'kora-stg-%' and slug <> 'kora-demo');
  select count(*) into v_foreign_users from auth.users
   where email is null or email not like '%@kora-staging.invalid';
  if v_foreign_tenants > 0 or v_foreign_users > 0 then
    raise exception 'KORA-STG SEED ABORT: alvo contém dados não sintéticos (tenants=%, auth.users=%)',
      v_foreign_tenants, v_foreign_users;
  end if;

  select count(*) into v_demo_count from public.tenants where slug = 'kora-demo';
  if v_demo_count <> 1 then
    raise exception 'KORA-STG SEED ABORT: tenant de baseline kora-demo ausente ou duplicado (n=%)', v_demo_count;
  end if;
  select id into v_demo_id from public.tenants
   where slug = 'kora-demo' and nome = 'KORA Demo' and plano = 'starter';
  if v_demo_id is null then
    raise exception 'KORA-STG SEED ABORT: tenant kora-demo diverge do baseline (nome/plano)';
  end if;

  for r in
    select distinct n.nspname as sch, c.relname as tbl, a.attname as col
      from pg_attribute a
      join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where c.relkind in ('r', 'p')
       and a.attnum > 0 and not a.attisdropped
       and n.nspname not in ('pg_catalog', 'information_schema')
       and n.nspname not like 'pg_toast%' and n.nspname not like 'pg_temp%'
       and not (n.nspname = 'public' and c.relname = 'tenants')
       and (
         (n.nspname = 'public' and a.attname = 'tenant_id')
         or exists (
           select 1 from pg_constraint k
            where k.contype = 'f' and k.conrelid = c.oid
              and k.confrelid = 'public.tenants'::regclass
              and a.attnum = any (k.conkey)
         )
       )
     order by 1, 2, 3
  loop
    execute format('select count(*) from %I.%I where %I::text = $1', r.sch, r.tbl, r.col)
      into v_n using v_demo_id::text;
    if r.sch = 'public' and r.tbl = 'unidades' and r.col = 'tenant_id' then
      if v_n <> 1 or not exists (
           select 1 from public.unidades u
            where u.tenant_id = v_demo_id and u.nome = 'Unidade Bela Vista') then
        v_unexpected := v_unexpected || format('%s.%s.%s=%s(esperado 1 Unidade Bela Vista) ', r.sch, r.tbl, r.col, v_n);
      end if;
    elsif v_n > 0 then
      v_unexpected := v_unexpected || format('%s.%s.%s=%s ', r.sch, r.tbl, r.col, v_n);
    end if;
  end loop;
  if v_unexpected <> '' then
    raise exception 'KORA-STG SEED ABORT: tenant kora-demo com vínculos não previstos: %', trim(v_unexpected);
  end if;
end
$guard$;
