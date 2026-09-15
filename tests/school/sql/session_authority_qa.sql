\set ON_ERROR_STOP on
-- Run only after disposable replay of canonical migrations 001-039.
create or replace function pg_temp.attempt(p_sql text) returns boolean
language plpgsql as $$
declare n integer;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n > 0;
exception when others then return false;
end $$;
create or replace function pg_temp.assert_true(p_ok boolean, p_name text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'SCHOOL QA FAIL: %', p_name; end if;
end $$;

insert into auth.users(id,email,email_confirmed_at) values
 ('ba000000-0000-0000-0000-000000000001','school-admin@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000002','school-user@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000003','school-inactive@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000004','school-new@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000005','takeover@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000006','school-reuse@local.invalid',now());
insert into public.tenants(id,nome,slug) values
 ('bb000000-0000-0000-0000-000000000001','School A QA','school-a-qa'),
 ('bb000000-0000-0000-0000-000000000002','School B QA','school-b-qa');
insert into public.unidades(id,tenant_id,nome) values
 ('bc000000-0000-0000-0000-000000000001','bb000000-0000-0000-0000-000000000001','A unit'),
 ('bc000000-0000-0000-0000-000000000002','bb000000-0000-0000-0000-000000000002','B unit');
insert into public.usuarios(id,auth_user_id,tenant_id,perfil,nome,email,ativo) values
 ('bd000000-0000-0000-0000-000000000001','ba000000-0000-0000-0000-000000000001','bb000000-0000-0000-0000-000000000001','gestor','Admin A','school-admin@local.invalid',true),
 ('bd000000-0000-0000-0000-000000000002','ba000000-0000-0000-0000-000000000002','bb000000-0000-0000-0000-000000000001','aluno','User A','school-user@local.invalid',true),
 ('bd000000-0000-0000-0000-000000000003','ba000000-0000-0000-0000-000000000003','bb000000-0000-0000-0000-000000000001','aluno','Inactive A','school-inactive@local.invalid',false),
 ('bd000000-0000-0000-0000-000000000004',null,'bb000000-0000-0000-0000-000000000002','aluno','B target','other@local.invalid',true),
 ('bd000000-0000-0000-0000-000000000005',null,'bb000000-0000-0000-0000-000000000001','aluno','Pending A','school-new@local.invalid',true);

set role authenticated;
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000002',false);
select pg_temp.assert_true(pg_temp.attempt($q$update public.usuarios set nome='Allowed name' where id='bd000000-0000-0000-0000-000000000002'$q$),'T01 personal allow');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set tenant_id='bb000000-0000-0000-0000-000000000002' where id='bd000000-0000-0000-0000-000000000002'$q$),'T02 tenant deny');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set unidade_id='bc000000-0000-0000-0000-000000000001' where id='bd000000-0000-0000-0000-000000000002'$q$),'T03 unit deny');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set perfil='gestor' where id='bd000000-0000-0000-0000-000000000002'$q$),'T04 profile deny');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set auth_user_id='ba000000-0000-0000-0000-000000000004' where id='bd000000-0000-0000-0000-000000000002'$q$),'T05 rebind deny');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set ativo=false where id='bd000000-0000-0000-0000-000000000002'$q$),'T06 active deny');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set id='bd000000-0000-0000-0000-000000000099' where id='bd000000-0000-0000-0000-000000000002'$q$),'T07 id deny');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set created_at=now() + interval '1 day' where id='bd000000-0000-0000-0000-000000000002'$q$),'T08 created_at deny');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set cpf='99999999999' where id='bd000000-0000-0000-0000-000000000002'$q$),'T09 nonallowlist deny');
select pg_temp.assert_true(not pg_temp.attempt($q$select public.vincular_minha_conta()$q$),'T13 legacy bind deny');

select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000003',false);
select pg_temp.assert_true(public.current_usuario_id() is null and public.current_tenant_id() is null and public.current_perfil() is null
 and not public.is_staff() and not public.is_docente(),'T11 inactive helpers');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set nome='Bad' where id='bd000000-0000-0000-0000-000000000003'$q$),'T10 inactive update');

select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000001',false);
select pg_temp.assert_true(pg_temp.attempt($q$update public.usuarios set perfil='professor' where id='bd000000-0000-0000-0000-000000000002'$q$),'T16 admin allow');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set perfil='professor' where id='bd000000-0000-0000-0000-000000000004'$q$),'T17 cross tenant deny');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set unidade_id='bc000000-0000-0000-0000-000000000002' where id='bd000000-0000-0000-0000-000000000002'$q$),'T18 cross tenant unit deny');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set perfil='super_admin' where id='bd000000-0000-0000-0000-000000000002'$q$),'T19 super admin ceiling');
select pg_temp.assert_true(not pg_temp.attempt($q$insert into public.usuarios(tenant_id,perfil,nome,email) values ('bb000000-0000-0000-0000-000000000001','super_admin','Bad','bad@local.invalid')$q$),'T19 insert ceiling');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set auth_user_id='ba000000-0000-0000-0000-000000000004' where id='bd000000-0000-0000-0000-000000000005'$q$),'T20 direct pending bind deny');
select pg_temp.assert_true(length(public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000005')) = 64,'T12 invitation issuance');
select pg_temp.assert_true(not pg_temp.attempt($q$select public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000004')$q$),'T15 cross tenant invitation deny');
select pg_temp.assert_true(not pg_temp.attempt($q$select public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000003')$q$),'T14 inactive invitation deny');
select public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000005') as convite \gset
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000004',false);
select pg_temp.assert_true(public.vincular_minha_conta(:'convite'),'T12 legitimate bind');
select pg_temp.assert_true(not pg_temp.attempt($q$select public.vincular_minha_conta('0000000000000000000000000000000000000000000000000000000000000000')$q$),'T13 invalid rebind');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set auth_user_id='ba000000-0000-0000-0000-000000000002' where id='bd000000-0000-0000-0000-000000000005'$q$),'T13 direct rebind');

-- T16: convite institucional reutilizado (consumed_at já preenchido)
-- Use um cadastro pendente novo: bd...005 foi consumido no T12 legítimo acima.
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000001',false);
insert into public.usuarios(id,auth_user_id,tenant_id,perfil,nome,email,ativo) values
 ('bd000000-0000-0000-0000-000000000007',null,'bb000000-0000-0000-0000-000000000001','aluno','Reuse Target','school-reuse@local.invalid',true);
select pg_temp.assert_true(length(public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000007')) = 64,'T16 invitation issuance for reuse test');
select public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000007') as convite_t16 \gset
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000006',false);
select pg_temp.assert_true(public.vincular_minha_conta(:'convite_t16'),'T16 first bind succeeds');
select pg_temp.assert_true(not pg_temp.attempt($q$select public.vincular_minha_conta(:'convite_t16')$q$),'T16 reused invite deny');

-- T17: takeover/rebind indevido de auth_user_id
-- T17a: identidade já vinculada tenta vincular outro cadastro (takeover)
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000001',false);
insert into public.usuarios(id,auth_user_id,tenant_id,perfil,nome,email,ativo) values
 ('bd000000-0000-0000-0000-000000000006',null,'bb000000-0000-0000-0000-000000000001','aluno','Takeover Target','takeover@local.invalid',true);
select pg_temp.assert_true(length(public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000006')) = 64,'T17 invite for takeover target');
select public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000006') as convite_t17 \gset
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000005',false);
select pg_temp.assert_true(not pg_temp.attempt($q$select public.vincular_minha_conta(:'convite_t17')$q$),'T17 takeover deny');

-- T17b: rebind direto via UPDATE (já testado em T13/T05 mas reforçando integridade)
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000001',false);
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set auth_user_id='ba000000-0000-0000-0000-000000000005' where id='bd000000-0000-0000-0000-000000000002'$q$),'T17 rebind deny');

reset role;

alter table public.usuarios add column qa_future_system_field text;
set role authenticated;
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000002',false);
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set qa_future_system_field='bad' where id='bd000000-0000-0000-0000-000000000002'$q$),'T09 future column fail closed');
reset role;
