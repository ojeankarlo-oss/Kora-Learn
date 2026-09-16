\set ON_ERROR_STOP on
-- Run only after disposable replay of canonical migrations 001-039.
--
-- TEST MATRIX (each identifier is unique in this file):
-- T01 self-update allow; T02 tenant mutation deny; T03 unit mutation deny;
-- T04 profile mutation deny; T05 rebind deny; T06 active flag deny;
-- T07 id mutation deny; T08 created_at mutation deny; T09 non-allowlisted field deny;
-- T10 legacy email-only bind deny; T11 inactive helpers; T12 inactive update;
-- T13 staff same-tenant profile allow; T14 cross-tenant profile deny;
-- T15 cross-tenant unit deny; T16 invitation reuse denial;
-- T17a real identity takeover denial; T17b direct rebind denial;
-- T18 super_admin update ceiling; T19 super_admin insert ceiling;
-- T20 direct pending bind denial; T21 cross-tenant invitation denial;
-- T22 inactive-target invitation denial; T23 legitimate invitation first bind;
-- T24 invalid invite denial; T25 unconfirmed-email denial;
-- T26 future-column fail-closed.

create or replace function pg_temp.attempt(p_sql text) returns boolean
language plpgsql as $$
declare n integer;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n > 0;
exception when others then return false;
end $$;

create or replace function pg_temp.attempt_expected(p_sql text, p_sqlstate text, p_message text)
returns boolean language plpgsql as $$
declare v_state text; v_message text;
begin
  execute p_sql;
  return false;
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  return v_state = p_sqlstate and v_message like '%' || p_message || '%';
end $$;

create or replace function pg_temp.assert_true(p_ok boolean, p_name text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'SCHOOL QA FAIL: %', p_name; end if;
end $$;

-- Auth identities are seeded before role authenticated. This mirrors the CI
-- privilege boundary: authenticated may bind, but cannot insert auth.users.
insert into auth.users(id,email,email_confirmed_at) values
 ('ba000000-0000-0000-0000-000000000001','school-admin@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000002','school-user@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000003','school-inactive@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000004','school-new@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000005','takeover@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000006','school-reuse@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000008','school-reuse-second@local.invalid',now()),
 ('ba000000-0000-0000-0000-000000000009','school-unconfirmed@local.invalid',null);

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

-- T01-T10: self-service boundaries.
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
select pg_temp.assert_true(not pg_temp.attempt($q$select public.vincular_minha_conta()$q$),'T10 legacy bind deny');

-- T11-T12: inactive identity cannot derive authority or update.
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000003',false);
select pg_temp.assert_true(public.current_usuario_id() is null and public.current_tenant_id() is null and public.current_perfil() is null
 and not public.is_staff() and not public.is_docente(),'T11 inactive helpers');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set nome='Bad' where id='bd000000-0000-0000-0000-000000000003'$q$),'T12 inactive update');

-- T13-T15 and T18-T22: staff, tenant and role ceilings.
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000001',false);
select pg_temp.assert_true(pg_temp.attempt($q$update public.usuarios set perfil='professor' where id='bd000000-0000-0000-0000-000000000002'$q$),'T13 staff profile allow');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set perfil='professor' where id='bd000000-0000-0000-0000-000000000004'$q$),'T14 cross tenant profile deny');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set unidade_id='bc000000-0000-0000-0000-000000000002' where id='bd000000-0000-0000-0000-000000000002'$q$),'T15 cross tenant unit deny');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set perfil='super_admin' where id='bd000000-0000-0000-0000-000000000002'$q$),'T18 super admin ceiling');
select pg_temp.assert_true(not pg_temp.attempt($q$insert into public.usuarios(tenant_id,perfil,nome,email) values ('bb000000-0000-0000-0000-000000000001','super_admin','Bad','bad@local.invalid')$q$),'T19 insert ceiling');
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set auth_user_id='ba000000-0000-0000-0000-000000000004' where id='bd000000-0000-0000-0000-000000000005'$q$),'T20 direct pending bind deny');
select pg_temp.assert_true(not pg_temp.attempt($q$select public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000004')$q$),'T21 cross tenant invitation deny');
select pg_temp.assert_true(not pg_temp.attempt($q$select public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000003')$q$),'T22 inactive invitation deny');

-- T23: legitimate invitation first bind. The token is interpolated by psql
-- outside any dollar-quoted PL/pgSQL string.
select pg_temp.assert_true(length(public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000005')) = 64,'T23 invitation issuance');
select public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000005') as convite_legit \gset
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000004',false);
select pg_temp.assert_true(public.vincular_minha_conta(:'convite_legit'),'T23 legitimate bind');
select pg_temp.assert_true((select auth_user_id='ba000000-0000-0000-0000-000000000004' from public.usuarios where id='bd000000-0000-0000-0000-000000000005'),'T23 auth binding state');
select pg_temp.assert_true((select consumed_at is not null from public.usuario_vinculo_convites where usuario_id='bd000000-0000-0000-0000-000000000005'),'T23 consumed state');

-- T24: invalid invite denial.
select pg_temp.assert_true(not pg_temp.attempt($q$select public.vincular_minha_conta('0000000000000000000000000000000000000000000000000000000000000000')$q$),'T24 invalid invite deny');

-- T16: real invite reuse. A second, different confirmed identity has a
-- different email, so a non-consumed token would reach the email mismatch;
-- an already-consumed token must fail specifically at invite lookup.
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000001',false);
insert into public.usuarios(id,auth_user_id,tenant_id,perfil,nome,email,ativo) values
 ('bd000000-0000-0000-0000-000000000007',null,'bb000000-0000-0000-0000-000000000001','aluno','Reuse Target','school-reuse@local.invalid',true);
select pg_temp.assert_true(length(public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000007')) = 64,'T16 invitation issuance');
select public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000007') as convite_reuse \gset
select pg_temp.assert_true((select consumed_at is null from public.usuario_vinculo_convites where usuario_id='bd000000-0000-0000-0000-000000000007'),'T16 pre-consumption state');
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000006',false);
select pg_temp.assert_true(public.vincular_minha_conta(:'convite_reuse'),'T16 first consumption');
select pg_temp.assert_true((select auth_user_id='ba000000-0000-0000-0000-000000000006' from public.usuarios where id='bd000000-0000-0000-0000-000000000007'),'T16 first binding state');
select pg_temp.assert_true((select consumed_at is not null from public.usuario_vinculo_convites where usuario_id='bd000000-0000-0000-0000-000000000007'),'T16 consumed_at after first');
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000008',false);
select pg_temp.assert_true(
 pg_temp.attempt_expected(format('select public.vincular_minha_conta(%L)', :'convite_reuse'),'42501','convite invalido'),
 'T16 second real attempt denied as consumed');
select pg_temp.assert_true((select auth_user_id='ba000000-0000-0000-0000-000000000006' from public.usuarios where id='bd000000-0000-0000-0000-000000000007'),'T16 owner unchanged');
select pg_temp.assert_true((select consumed_at is not null from public.usuario_vinculo_convites where usuario_id='bd000000-0000-0000-0000-000000000007'),'T16 consumed state after retry');

-- T17: real takeover. Identity A is already bound to User A; User B is a
-- distinct pending record with a valid invite. A attempts to use Invite B.
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000001',false);
insert into public.usuarios(id,auth_user_id,tenant_id,perfil,nome,email,ativo) values
 ('bd000000-0000-0000-0000-000000000006',null,'bb000000-0000-0000-0000-000000000001','aluno','Takeover Target','takeover@local.invalid',true);
select pg_temp.assert_true(length(public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000006')) = 64,'T17 invite issuance');
select public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000006') as convite_takeover \gset
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000002',false);
select pg_temp.assert_true(
 pg_temp.attempt_expected(format('select public.vincular_minha_conta(%L)', :'convite_takeover'),'42501','identidade nao elegivel'),
 'T17 identity A takeover denied');
select pg_temp.assert_true((select auth_user_id='ba000000-0000-0000-0000-000000000002' from public.usuarios where id='bd000000-0000-0000-0000-000000000002'),'T17 identity A still owns User A');
select pg_temp.assert_true((select auth_user_id is null from public.usuarios where id='bd000000-0000-0000-0000-000000000006'),'T17 User B remains pending');
select pg_temp.assert_true((select consumed_at is null from public.usuario_vinculo_convites where usuario_id='bd000000-0000-0000-0000-000000000006'),'T17 invite remains unconsumed');

-- T17b: direct rebind of an already linked row is separately denied.
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000001',false);
select pg_temp.assert_true(
 pg_temp.attempt_expected($q$update public.usuarios set auth_user_id='ba000000-0000-0000-0000-000000000005' where id='bd000000-0000-0000-0000-000000000002'$q$,'42501','rebind proibido'),
 'T17b direct rebind denied');
select pg_temp.assert_true((select auth_user_id='ba000000-0000-0000-0000-000000000002' from public.usuarios where id='bd000000-0000-0000-0000-000000000002'),'T17b original binding unchanged');

-- T25: an authenticated identity with an unconfirmed email cannot bind.
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000001',false);
insert into public.usuarios(id,auth_user_id,tenant_id,perfil,nome,email,ativo) values
 ('bd000000-0000-0000-0000-000000000008',null,'bb000000-0000-0000-0000-000000000001','aluno','Unconfirmed Target','school-unconfirmed@local.invalid',true);
select pg_temp.assert_true(length(public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000008')) = 64,'T25 invite issuance');
select public.criar_convite_vinculo('bd000000-0000-0000-0000-000000000008') as convite_unconfirmed \gset
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000009',false);
select pg_temp.assert_true(
 pg_temp.attempt_expected(format('select public.vincular_minha_conta(%L)', :'convite_unconfirmed'),'42501','identidade nao elegivel'),
 'T25 unconfirmed email denied');
select pg_temp.assert_true((select auth_user_id is null from public.usuarios where id='bd000000-0000-0000-0000-000000000008'),'T25 target remains unbound');
select pg_temp.assert_true((select consumed_at is null from public.usuario_vinculo_convites where usuario_id='bd000000-0000-0000-0000-000000000008'),'T25 invite remains unconsumed');

reset role;

-- T26: future-column fail closed.
alter table public.usuarios add column qa_future_system_field text;
set role authenticated;
select set_config('request.jwt.claim.sub','ba000000-0000-0000-0000-000000000002',false);
select pg_temp.assert_true(not pg_temp.attempt($q$update public.usuarios set qa_future_system_field='bad' where id='bd000000-0000-0000-0000-000000000002'$q$),'T26 future column fail closed');
reset role;

-- The CI deliberately has no T25 runtime pix-create harness in this file;
-- that remains documented infrastructure debt rather than a claimed PASS.
