\set ON_ERROR_STOP on
-- ============================================================================
-- KORA-STAGING — regressão da trava do seed (PROVISIONING-03-FIX).
-- Roda no stack DESCARTÁVEL logo após as migrations 001..040 e ANTES de qualquer
-- dado sintético. Cada cenário altera o banco dentro de uma subtransação que é
-- sempre desfeita; o arquivo inteiro também termina em ROLLBACK.
-- Um cenário só é PASS se a trava se comportar exatamente como esperado
-- (sem erro, ou erro P0001 com a mensagem esperada). Erro de preparação ou erro
-- não relacionado = FAIL (nunca é aceito como prova do controle).
-- ============================================================================
begin;
\ir seed_guard.sql

create or replace function pg_temp.kora_stg_case(p_label text, p_setup text, p_expect text)
returns text
language plpgsql
as $case$
declare
  v_msg text;
  v_res text;
begin
  begin
    if p_setup is not null then
      begin
        execute p_setup;
      exception when others then
        v_res := format('FAIL %s: erro na preparação %s %s', p_label, sqlstate, sqlerrm);
      end;
    end if;
    if v_res is null then
      begin
        perform pg_temp.kora_stg_assert_seed_target();
      exception
        when raise_exception then v_msg := sqlerrm;
        when others then v_res := format('FAIL %s: erro não relacionado %s %s', p_label, sqlstate, sqlerrm);
      end;
    end if;
    if v_res is null then
      if p_expect is null and v_msg is null then
        v_res := format('PASS %s', p_label);
      elsif p_expect is not null and v_msg like p_expect then
        v_res := format('PASS %s -> %s', p_label, v_msg);
      else
        v_res := format('FAIL %s: esperado [%s] obtido [%s]', p_label,
                        coalesce(p_expect, 'sem erro'), coalesce(v_msg, 'sem erro'));
      end if;
    end if;
    raise exception using errcode = 'KS999', message = 'kora-stg-case-rollback';
  exception when sqlstate 'KS999' then
    return v_res;
  end;
end
$case$;

create temporary table kora_stg_guard_results(ord int, result text) on commit drop;

insert into kora_stg_guard_results values
 (1, pg_temp.kora_stg_case('G1 baseline esperado (kora-demo + Unidade Bela Vista)', null, null)),
 (2, pg_temp.kora_stg_case('G2 tenant desconhecido',
     $s$insert into public.tenants(nome, slug, plano) values ('Escola Real X', 'escola-real-x', 'starter')$s$,
     'KORA-STG SEED ABORT: alvo contém dados não sintéticos (tenants=1,%')),
 (3, pg_temp.kora_stg_case('G3 tenant sem slug',
     $s$alter table public.tenants alter column slug drop not null;
        insert into public.tenants(nome, slug, plano) values ('Sem Slug', null, 'starter')$s$,
     'KORA-STG SEED ABORT: alvo contém dados não sintéticos (tenants=1,%')),
 (4, pg_temp.kora_stg_case('G4 usuário auth não sintético',
     $s$insert into auth.users(id, email) values (gen_random_uuid(), 'pessoa@exemplo.invalid')$s$,
     'KORA-STG SEED ABORT: alvo contém dados não sintéticos (tenants=0, auth.users=1)')),
 (5, pg_temp.kora_stg_case('G5 kora-demo ausente',
     $s$delete from public.unidades where tenant_id = (select id from public.tenants where slug = 'kora-demo');
        delete from public.tenants where slug = 'kora-demo'$s$,
     'KORA-STG SEED ABORT: tenant de baseline kora-demo ausente ou duplicado (n=0)')),
 (6, pg_temp.kora_stg_case('G6 kora-demo divergente (nome)',
     $s$update public.tenants set nome = 'Escola Renomeada' where slug = 'kora-demo'$s$,
     'KORA-STG SEED ABORT: tenant kora-demo diverge do baseline%')),
 (7, pg_temp.kora_stg_case('G7 unidade extra no kora-demo',
     $s$insert into public.unidades(tenant_id, nome) select id, 'Unidade Extra' from public.tenants where slug = 'kora-demo'$s$,
     'KORA-STG SEED ABORT: tenant kora-demo com vínculos não previstos: public.unidades.tenant_id=2%')),
 (8, pg_temp.kora_stg_case('G8 unidade de baseline ausente',
     $s$delete from public.unidades where tenant_id = (select id from public.tenants where slug = 'kora-demo')$s$,
     'KORA-STG SEED ABORT: tenant kora-demo com vínculos não previstos: public.unidades.tenant_id=0%')),
 (9, pg_temp.kora_stg_case('G9 vínculo por FK em tabela qualquer',
     $s$create table public.kora_stg_regr_fk(x int, escola uuid references public.tenants(id));
        insert into public.kora_stg_regr_fk select 1, id from public.tenants where slug = 'kora-demo'$s$,
     'KORA-STG SEED ABORT: tenant kora-demo com vínculos não previstos: public.kora_stg_regr_fk.escola=1')),
 (10, pg_temp.kora_stg_case('G10 vínculo por coluna tenant_id sem FK',
     $s$create table public.kora_stg_regr_col(tenant_id uuid);
        insert into public.kora_stg_regr_col select id from public.tenants where slug = 'kora-demo'$s$,
     'KORA-STG SEED ABORT: tenant kora-demo com vínculos não previstos: public.kora_stg_regr_col.tenant_id=1')),
 (11, pg_temp.kora_stg_case('G11 usuário da escola vinculado ao kora-demo',
     $s$insert into public.usuarios(tenant_id, perfil, nome, email)
          select id, 'gestor', 'Pessoa Teste', 'p@kora-staging.invalid' from public.tenants where slug = 'kora-demo'$s$,
     'KORA-STG SEED ABORT: tenant kora-demo com vínculos não previstos: %public.usuarios.tenant_id=1%')),
 (12, pg_temp.kora_stg_case('G12 tenants sintéticos kora-stg-* tolerados',
     $s$insert into public.tenants(nome, slug, plano) values ('Sintética', 'kora-stg-escola-z', 'starter')$s$,
     null));

select 'KORA_STG_SEED_GUARD|' || result from kora_stg_guard_results order by ord;

do $$
declare v_total int; v_pass int;
begin
  select count(*), count(*) filter (where result like 'PASS %') into v_total, v_pass from kora_stg_guard_results;
  if v_total <> 12 or v_pass <> v_total then
    raise exception 'KORA-STG SEED GUARD REGRESSION: FAIL (% de % PASS)', v_pass, v_total;
  end if;
  raise notice 'KORA-STG SEED GUARD REGRESSION: PASS (%/%)', v_pass, v_total;
end $$;

rollback;
