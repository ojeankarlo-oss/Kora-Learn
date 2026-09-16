\set ON_ERROR_STOP on
-- Run after disposable replay through migration 040.

create or replace function pg_temp.assert_true(p_ok boolean,p_name text) returns void language plpgsql as $$
begin if not coalesce(p_ok,false) then raise exception 'SC003 QA FAIL: %',p_name; end if; end $$;
create or replace function pg_temp.denied(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
create or replace function pg_temp.denied_integrity(p_sql text) returns boolean language plpgsql as $$
declare v_state text;
begin
  execute p_sql;
  return false;
exception when others then
  get stacked diagnostics v_state=returned_sqlstate;
  return v_state in ('23502','23503','23514');
end $$;

-- Every frozen relation must have an enabled, validated database control.
select pg_temp.assert_true(count(*)=38,'all 38 tenant-aware FKs present and validated')
from pg_constraint where conname like '%\_sc003' escape '\' and contype='f' and convalidated;
select pg_temp.assert_true(count(*)=6,'all semantic triggers enabled')
from pg_trigger where tgname like 'sc003\_%\_integrity' escape '\' and tgenabled <> 'D';
select pg_temp.assert_true(exists(select 1 from information_schema.columns where table_schema='public'
 and table_name='avaliacao_questoes' and column_name='tenant_id' and is_nullable='NO'),'R30 tenant materialized');

-- Two complete, isolated academic graphs. Inserts themselves prove valid
-- same-tenant regression for every frozen relation.
insert into public.tenants(id,nome,slug) values
 ('ca000000-0000-0000-0000-000000000001','SC003 A','sc003-a'),
 ('ca000000-0000-0000-0000-000000000002','SC003 B','sc003-b');
insert into public.unidades(id,tenant_id,nome) values
 ('cb000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','A'),
 ('cb000000-0000-0000-0000-000000000002','ca000000-0000-0000-0000-000000000002','B');
insert into public.usuarios(id,tenant_id,perfil,nome,email) values
 ('cc000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','professor','Professor A','prof-a@local.invalid'),
 ('cc000000-0000-0000-0000-000000000002','ca000000-0000-0000-0000-000000000001','aluno','Aluno A','aluno-a@local.invalid'),
 ('cc000000-0000-0000-0000-000000000003','ca000000-0000-0000-0000-000000000002','professor','Professor B','prof-b@local.invalid'),
 ('cc000000-0000-0000-0000-000000000004','ca000000-0000-0000-0000-000000000002','aluno','Aluno B','aluno-b@local.invalid');
insert into public.cursos(id,tenant_id,nome) values
 ('cd000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','Curso A'),
 ('cd000000-0000-0000-0000-000000000002','ca000000-0000-0000-0000-000000000002','Curso B'),
 ('cd000000-0000-0000-0000-000000000003','ca000000-0000-0000-0000-000000000001','Curso A2');
insert into public.disciplinas(id,curso_id,tenant_id,nome) values
 ('ce000000-0000-0000-0000-000000000001','cd000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','Disc A'),
 ('ce000000-0000-0000-0000-000000000002','cd000000-0000-0000-0000-000000000002','ca000000-0000-0000-0000-000000000002','Disc B'),
 ('ce000000-0000-0000-0000-000000000003','cd000000-0000-0000-0000-000000000003','ca000000-0000-0000-0000-000000000001','Disc A2');
insert into public.aulas(id,disciplina_id,tenant_id,titulo) values
 ('cf000000-0000-0000-0000-000000000001','ce000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','Aula A'),
 ('cf000000-0000-0000-0000-000000000002','ce000000-0000-0000-0000-000000000002','ca000000-0000-0000-0000-000000000002','Aula B');
insert into public.materiais_apoio(id,disciplina_id,tenant_id,titulo,url) values
 ('d0000000-0000-0000-0000-000000000001','ce000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','Mat A','https://local.invalid/a');
insert into public.turmas(id,tenant_id,curso_id,unidade_id,nome) values
 ('d1000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','cd000000-0000-0000-0000-000000000001','cb000000-0000-0000-0000-000000000001','Turma A'),
 ('d1000000-0000-0000-0000-000000000002','ca000000-0000-0000-0000-000000000002','cd000000-0000-0000-0000-000000000002','cb000000-0000-0000-0000-000000000002','Turma B'),
 ('d1000000-0000-0000-0000-000000000003','ca000000-0000-0000-0000-000000000001','cd000000-0000-0000-0000-000000000003','cb000000-0000-0000-0000-000000000001','Turma A2');
insert into public.matriculas(id,tenant_id,usuario_id,curso_id,turma_id,unidade_id) values
 ('d2000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000002','cd000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','cb000000-0000-0000-0000-000000000001'),
 ('d2000000-0000-0000-0000-000000000002','ca000000-0000-0000-0000-000000000002','cc000000-0000-0000-0000-000000000004','cd000000-0000-0000-0000-000000000002','d1000000-0000-0000-0000-000000000002','cb000000-0000-0000-0000-000000000002');
insert into public.progresso_aulas(id,tenant_id,usuario_id,aula_id) values ('d3000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000002','cf000000-0000-0000-0000-000000000001');
insert into public.leads(id,tenant_id,curso_id,unidade_id,nome,email) values ('d4000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','cd000000-0000-0000-0000-000000000001','cb000000-0000-0000-0000-000000000001','Lead A','lead-a@local.invalid');
insert into public.professores_turmas(id,tenant_id,usuario_id,turma_id) values ('d5000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001');
insert into public.registros_aula(id,tenant_id,turma_id,disciplina_id,professor_id) values ('d6000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','ce000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000001');
insert into public.presencas(id,tenant_id,registro_aula_id,usuario_id) values ('d7000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','d6000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000002');
insert into public.materiais_professor(id,tenant_id,turma_id,disciplina_id,professor_id,titulo) values ('d8000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','ce000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000001','Material A');
insert into public.avisos_turma(id,tenant_id,turma_id,professor_id,titulo) values ('d9000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000001','Aviso A');
insert into public.questoes(id,tenant_id,disciplina_id,enunciado,tipo,criado_por) values
 ('da000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','ce000000-0000-0000-0000-000000000001','Q A','dissertativa','cc000000-0000-0000-0000-000000000001'),
 ('da000000-0000-0000-0000-000000000002','ca000000-0000-0000-0000-000000000002','ce000000-0000-0000-0000-000000000002','Q B','dissertativa','cc000000-0000-0000-0000-000000000003'),
 ('da000000-0000-0000-0000-000000000003','ca000000-0000-0000-0000-000000000001','ce000000-0000-0000-0000-000000000003','Q A2','dissertativa','cc000000-0000-0000-0000-000000000001');
insert into public.avaliacoes(id,tenant_id,curso_id,disciplina_id,turma_id,titulo,criado_por) values
 ('db000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','cd000000-0000-0000-0000-000000000001','ce000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','Aval A','cc000000-0000-0000-0000-000000000001'),
 ('db000000-0000-0000-0000-000000000002','ca000000-0000-0000-0000-000000000002','cd000000-0000-0000-0000-000000000002','ce000000-0000-0000-0000-000000000002','d1000000-0000-0000-0000-000000000002','Aval B','cc000000-0000-0000-0000-000000000003');
-- tenant_id omission proves backward-compatible unambiguous derivation.
insert into public.avaliacao_questoes(avaliacao_id,questao_id) values ('db000000-0000-0000-0000-000000000001','da000000-0000-0000-0000-000000000001');
insert into public.avaliacao_tentativas(id,tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa) values ('dc000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','db000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000002',1);
insert into public.avaliacao_respostas(id,tenant_id,tentativa_id,questao_id) values ('dd000000-0000-0000-0000-000000000001','ca000000-0000-0000-0000-000000000001','dc000000-0000-0000-0000-000000000001','da000000-0000-0000-0000-000000000001');

-- Owner-level mutations: RLS is bypassed, so each denial proves structural
-- enforcement. Failed statements leave the valid fixture unchanged.
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.disciplinas set curso_id='cd000000-0000-0000-0000-000000000002' where id='ce000000-0000-0000-0000-000000000001'$q$),'CT-R01-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.aulas set disciplina_id='ce000000-0000-0000-0000-000000000002' where id='cf000000-0000-0000-0000-000000000001'$q$),'CT-R02-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.materiais_apoio set disciplina_id='ce000000-0000-0000-0000-000000000002' where id='d0000000-0000-0000-0000-000000000001'$q$),'CT-R03-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.turmas set curso_id='cd000000-0000-0000-0000-000000000002' where id='d1000000-0000-0000-0000-000000000001'$q$),'CT-R04-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.turmas set unidade_id='cb000000-0000-0000-0000-000000000002' where id='d1000000-0000-0000-0000-000000000001'$q$),'CT-R05-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.matriculas set usuario_id='cc000000-0000-0000-0000-000000000004' where id='d2000000-0000-0000-0000-000000000001'$q$),'CT-R06-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.matriculas set curso_id='cd000000-0000-0000-0000-000000000002' where id='d2000000-0000-0000-0000-000000000001'$q$),'CT-R07-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.matriculas set turma_id='d1000000-0000-0000-0000-000000000002' where id='d2000000-0000-0000-0000-000000000001'$q$),'CT-R08-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.matriculas set unidade_id='cb000000-0000-0000-0000-000000000002' where id='d2000000-0000-0000-0000-000000000001'$q$),'CT-R09-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.progresso_aulas set usuario_id='cc000000-0000-0000-0000-000000000004' where id='d3000000-0000-0000-0000-000000000001'$q$),'CT-R10-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.progresso_aulas set aula_id='cf000000-0000-0000-0000-000000000002' where id='d3000000-0000-0000-0000-000000000001'$q$),'CT-R11-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.professores_turmas set usuario_id='cc000000-0000-0000-0000-000000000003' where id='d5000000-0000-0000-0000-000000000001'$q$),'CT-R12-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.professores_turmas set turma_id='d1000000-0000-0000-0000-000000000002' where id='d5000000-0000-0000-0000-000000000001'$q$),'CT-R13-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.registros_aula set turma_id='d1000000-0000-0000-0000-000000000002' where id='d6000000-0000-0000-0000-000000000001'$q$),'CT-R14-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.registros_aula set disciplina_id='ce000000-0000-0000-0000-000000000002' where id='d6000000-0000-0000-0000-000000000001'$q$),'CT-R15-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.registros_aula set professor_id='cc000000-0000-0000-0000-000000000003' where id='d6000000-0000-0000-0000-000000000001'$q$),'CT-R16-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.presencas set registro_aula_id='00000000-0000-0000-0000-000000000001' where id='d7000000-0000-0000-0000-000000000001'$q$),'CT-R17-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.presencas set usuario_id='cc000000-0000-0000-0000-000000000004' where id='d7000000-0000-0000-0000-000000000001'$q$),'CT-R18-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.materiais_professor set turma_id='d1000000-0000-0000-0000-000000000002' where id='d8000000-0000-0000-0000-000000000001'$q$),'CT-R19-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.materiais_professor set disciplina_id='ce000000-0000-0000-0000-000000000003' where id='d8000000-0000-0000-0000-000000000001'$q$),'CT-R20-SM1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.materiais_professor set professor_id='cc000000-0000-0000-0000-000000000003' where id='d8000000-0000-0000-0000-000000000001'$q$),'CT-R21-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avisos_turma set turma_id='d1000000-0000-0000-0000-000000000002' where id='d9000000-0000-0000-0000-000000000001'$q$),'CT-R22-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avisos_turma set professor_id='cc000000-0000-0000-0000-000000000003' where id='d9000000-0000-0000-0000-000000000001'$q$),'CT-R23-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.questoes set disciplina_id='ce000000-0000-0000-0000-000000000002' where id='da000000-0000-0000-0000-000000000001'$q$),'CT-R24-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.questoes set criado_por='cc000000-0000-0000-0000-000000000003' where id='da000000-0000-0000-0000-000000000001'$q$),'CT-R25-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avaliacoes set curso_id='cd000000-0000-0000-0000-000000000002' where id='db000000-0000-0000-0000-000000000001'$q$),'CT-R26-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avaliacoes set disciplina_id='ce000000-0000-0000-0000-000000000003' where id='db000000-0000-0000-0000-000000000001'$q$),'CT-R27-SM1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avaliacoes set turma_id='d1000000-0000-0000-0000-000000000003' where id='db000000-0000-0000-0000-000000000001'$q$),'CT-R28-SM1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avaliacoes set criado_por='cc000000-0000-0000-0000-000000000003' where id='db000000-0000-0000-0000-000000000001'$q$),'CT-R29-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avaliacao_questoes set avaliacao_id='db000000-0000-0000-0000-000000000002' where avaliacao_id='db000000-0000-0000-0000-000000000001'$q$),'CT-R30-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avaliacao_questoes set questao_id='da000000-0000-0000-0000-000000000003' where avaliacao_id='db000000-0000-0000-0000-000000000001'$q$),'CT-R31-SM1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avaliacao_tentativas set avaliacao_id='db000000-0000-0000-0000-000000000002' where id='dc000000-0000-0000-0000-000000000001'$q$),'CT-R32-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avaliacao_tentativas set matricula_id='d2000000-0000-0000-0000-000000000002' where id='dc000000-0000-0000-0000-000000000001'$q$),'CT-R33-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avaliacao_tentativas set usuario_id='cc000000-0000-0000-0000-000000000001' where id='dc000000-0000-0000-0000-000000000001'$q$),'CT-R34-SM1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avaliacao_respostas set tentativa_id='00000000-0000-0000-0000-000000000001' where id='dd000000-0000-0000-0000-000000000001'$q$),'CT-R35-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.avaliacao_respostas set questao_id='da000000-0000-0000-0000-000000000003' where id='dd000000-0000-0000-0000-000000000001'$q$),'CT-R36-SM1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.leads set curso_id='cd000000-0000-0000-0000-000000000002' where id='d4000000-0000-0000-0000-000000000001'$q$),'CT-R37-U2/S1');
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.leads set unidade_id='cb000000-0000-0000-0000-000000000002' where id='d4000000-0000-0000-0000-000000000001'$q$),'CT-R38-U2/S1');

-- Explicit INSERT denial for every semantic trigger; declarative INSERT and
-- UPDATE coverage for all other relations is guaranteed by the same catalog-
-- asserted composite FKs exercised above.
select pg_temp.assert_true(pg_temp.denied_integrity($q$insert into public.registros_aula(tenant_id,turma_id,disciplina_id) values('ca000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','ce000000-0000-0000-0000-000000000003')$q$),'CT-R15-I2 semantic insert');
select pg_temp.assert_true(pg_temp.denied_integrity($q$insert into public.presencas(tenant_id,registro_aula_id,usuario_id) values('ca000000-0000-0000-0000-000000000001','d6000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000001')$q$),'CT-R18-I2 semantic insert');
select pg_temp.assert_true(pg_temp.denied_integrity($q$insert into public.materiais_professor(tenant_id,turma_id,disciplina_id,professor_id,titulo) values('ca000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','ce000000-0000-0000-0000-000000000003','cc000000-0000-0000-0000-000000000001','bad')$q$),'CT-R20-I2 semantic insert');
select pg_temp.assert_true(pg_temp.denied_integrity($q$insert into public.avaliacao_questoes(avaliacao_id,questao_id) values('db000000-0000-0000-0000-000000000001','da000000-0000-0000-0000-000000000003')$q$),'CT-R31-I2 semantic insert');
select pg_temp.assert_true(pg_temp.denied_integrity($q$insert into public.avaliacao_tentativas(tenant_id,avaliacao_id,matricula_id,usuario_id,numero_tentativa) values('ca000000-0000-0000-0000-000000000001','db000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000001',2)$q$),'CT-R33/R34-I2 semantic insert');
select pg_temp.assert_true(pg_temp.denied_integrity($q$insert into public.avaliacao_respostas(tenant_id,tentativa_id,questao_id) values('ca000000-0000-0000-0000-000000000001','dc000000-0000-0000-0000-000000000001','da000000-0000-0000-0000-000000000003')$q$),'CT-R36-I2 semantic insert');

begin;
grant update on public.leads to service_role;
set role service_role;
select pg_temp.assert_true(pg_temp.denied_integrity($q$update public.leads set curso_id='cd000000-0000-0000-0000-000000000002' where id='d4000000-0000-0000-0000-000000000001'$q$),'CT-SERVICE-ROLE structural denial');
reset role;
rollback;

-- Same-tenant update and nullable regressions.
update public.leads set curso_id=null,unidade_id=null where id='d4000000-0000-0000-0000-000000000001';
update public.registros_aula set disciplina_id=null,professor_id=null where id='d6000000-0000-0000-0000-000000000001';
update public.avisos_turma set professor_id=null where id='d9000000-0000-0000-0000-000000000001';
select pg_temp.assert_true((select tenant_id='ca000000-0000-0000-0000-000000000001' from public.avaliacao_questoes where avaliacao_id='db000000-0000-0000-0000-000000000001'),'R30 derived tenant persisted');

-- Public capture remains RPC-only and rejects cross-tenant identifiers.
set role anon;
select pg_temp.assert_true(pg_temp.denied($q$insert into public.leads(tenant_id,nome,email) values('ca000000-0000-0000-0000-000000000001','bad','bad@local.invalid')$q$),'CT-LEAD-P4 direct anon insert denied');
select pg_temp.assert_true(pg_temp.denied($q$select public.criar_lead_publico('sc003-a','cd000000-0000-0000-0000-000000000002',null,'bad','bad@local.invalid',null,'site',false,null)$q$),'CT-LEAD-P2 cross course denied');
reset role;

select 'SC003 CROSS-TENANT QA: PASS' as result;
