// Static freeze/security-boundary checks only; no SQL, Docker or runtime execution.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
const base='508b00e19326f176d3c92df5d6341fdafd27fb2d';
const git=(...args)=>execFileSync('git',args,{encoding:'utf8'});
const read=p=>fs.readFileSync(p,'utf8').replaceAll('\r\n','\n');
const original=p=>git('show',base+':'+p).replaceAll('\r\n','\n');
const sqlPath='tests/school/sql/sc004_trigger_acl_qa.sql';
const sql=read(sqlPath), before=original(sqlPath);
assert.equal(git('diff','--name-only',base,'--','supabase/migrations',
  'tests/school/sql/sc004_ab_qa.sql','tests/school/sql/sc004_cd_mutation_qa.sql',
  'tests/school/run-sc004-r58.sh','tests/school/sc004-r58-migrations.txt','.github/workflows').trim(),'');
const cd=read('tests/school/sql/sc004_cd_mutation_qa.sql');
assert.equal(cd,original('tests/school/sql/sc004_cd_mutation_qa.sql'));
assert.equal([...cd.matchAll(/insert into qa_mutation_results values \('(M\d+)','KILLED'/g)].length,22);
assert(cd.includes("qa_expect_result('M20-INVALID','INVALID')"));
assert(!sql.includes('insert into qa_mutation_results'));
const bindingStart=sql.indexOf('DO $binding$');
const bindingEnd=sql.indexOf('$binding$;',bindingStart);
assert(bindingStart>=0 && bindingEnd>bindingStart,'binding block must exist');
const binding=sql.slice(bindingStart,bindingEnd);
assert(binding.includes('EXECUTE FUNCTION public.%I()'));
assert(binding.includes("failure_state='42501' AND failure_message='permission denied for function public.'||function_name"));
assert(!/\b(?:LIKE|ILIKE|strpos)\b/i.test(binding),'binding must retain exact error comparison');
const gate=source=>source.slice(source.indexOf('DO $gate$'));
assert.equal(gate(sql),gate(before).replace('<>10','<>13'));
// Two retained named-grant rows + one MEMBER reachability row; mutated FAIL
// rolls back and the NOINHERIT self-test is archived outside qa_results.
const named=sql.slice(sql.indexOf('-- R58 named-grant mutation'),sql.indexOf('-- Controlled fixture'));
assert.equal((named.match(/GRANT EXECUTE ON FUNCTION/g)||[]).length,1);
assert(named.includes('GRANT EXECUTE ON FUNCTION public.sc004_assignment_lifecycle() TO service_role;'));
assert(named.includes("expected='DENY' AND observed='DENY' AND result='PASS'"));
assert(named.includes("expected='DENY' AND observed='ALLOW' AND result='FAIL'"));
assert(named.includes("has_function_privilege('public','public.sc004_assignment_lifecycle()','EXECUTE') IS DISTINCT FROM false"));
assert(named.indexOf("SELECT * FROM qa_results WHERE id='R58-ACL-NAMED-GRANT-MUTATED'")<named.indexOf('ROLLBACK;'));
assert(named.indexOf('ROLLBACK;')<named.indexOf("qa_probe_l4_execute('R58-ACL-NAMED-GRANT-ROLLBACK')"));
assert(named.includes("EXISTS (SELECT 1 FROM qa_results WHERE id='R58-ACL-NAMED-GRANT-MUTATED')"));
assert(sql.includes("pg_has_role(actor.oid,reachable.oid,'MEMBER')"));
assert(sql.includes("pg_has_role(actor.oid,reachable.oid,'USAGE') AS immediately_inherited"));
assert(sql.includes("has_function_privilege(reachable.oid,f.signature,'EXECUTE')"));
const fixture=sql.slice(sql.indexOf('DO $noinherit$'),sql.indexOf('DROP TABLE qa_sc004_acl_probe.target;'));
assert(fixture.includes('CREATE ROLE sc004_r58_qa_noinherit NOLOGIN NOINHERIT;'));
assert(fixture.includes('GRANT sc004_r58_qa_executor TO sc004_r58_qa_noinherit;'));
assert(fixture.includes("pg_has_role('sc004_r58_qa_noinherit','sc004_r58_qa_executor','MEMBER')"));
assert(fixture.includes("NOT pg_has_role('sc004_r58_qa_noinherit','sc004_r58_qa_executor','USAGE')"));
assert(fixture.includes("NOT has_function_privilege('sc004_r58_qa_noinherit'"));
assert(fixture.includes("qa_archive_selftest('R58-ACL-NOINHERIT-SELFTEST','SET_ROLE_ONLY')"));
assert(!/ALTER\s+(?:ROLE|FUNCTION)|TO\s+(?:postgres|anon|authenticated|service_role)\b/i.test(fixture));
const setup=read('tests/school/configure-sc004-scram.sh');
for(const line of ["qa_negative_auth AUTH_NO_PASSWORD '' 'no password supplied'",
  "qa_negative_auth AUTH_WRONG_PASSWORD 'sc004-negative-not-a-real-secret' 'password authentication failed'"]) {
  assert(original('tests/school/configure-sc004-scram.sh').includes(line));assert(setup.includes(line));
}
assert(!/^sleep 1$/m.test(setup));
assert(setup.includes('qa_limit=10'));
assert(setup.includes('qa_attempt<=qa_limit'));
assert(setup.includes('"$qa_mode" == AUTH_NO_PASSWORD && "$qa_code" == 0'));
assert(setup.includes('"$qa_attempt" -lt "$qa_limit"'));
assert(setup.includes('PGCONNECT_TIMEOUT=5'));
assert(!/(?:printf|echo)[^\n]*\$qa_output/.test(setup));
assert(setup.includes('raw diagnostic suppressed'));
console.log(JSON.stringify({result:'STATIC PASS',base,m1:'PASS/DENY -> FAIL/ALLOW -> PASS/DENY assertions prepared',
  m2:'MEMBER vs USAGE and rolled-back QA-only NOINHERIT fixture',m3:'maximum 10 passwordless probes; only pre-reload success is retried',
  retainedR58NormalRows:13,frozenCDMutationGroups:22,m20:'INVALID',runtime:'NOT RUN',blocker1:'FIXED (static); runtime NOT RUN'},null,2));
