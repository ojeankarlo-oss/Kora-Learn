// Source/structure checks only. No PostgreSQL or Docker execution.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
const frozen='d35fdaac8f270b337764571756d3c0b7fe0c6287';
const read=p=>fs.readFileSync(p,'utf8').replaceAll('\r\n','\n');
const original=p=>execFileSync('git',['show',frozen+':'+p],{encoding:'utf8'}).replaceAll('\r\n','\n');
for(const p of ['tests/school/sql/sc004_ab_qa.sql','tests/school/sql/sc004_cd_mutation_qa.sql']) {
  assert.equal(read(p),original(p),'frozen expectations and mutation contracts must remain exact');
}
const setup=read('tests/school/configure-sc004-scram.sh');
const auth=read('tests/school/sql/sc004_dblink_auth_qa.sql');
const runner=read('tests/school/run-sc004-r58.sh');
for(const token of [
  'host kora_ci postgres 127.0.0.1/32 scram-sha-256',
  'ORDER BY line_number LIMIT 1', 'pg_reload_conf()',
  'hba-before.csv','hba-after.csv','PGPASSFILE=/dev/null',
  "qa_negative_auth AUTH_NO_PASSWORD '' 'no password supplied'",
  "qa_negative_auth AUTH_WRONG_PASSWORD 'sc004-negative-not-a-real-secret' 'password authentication failed'",
  "SET password_encryption = 'scram-sha-256'",'rolsuper','pg_authid',
  "SET log_statement = 'none'", "ALTER ROLE postgres SET log_statement = 'none'",
  "SET pgaudit.log = 'none'",'raw diagnostic suppressed',
]) assert(setup.includes(token),token);
assert(setup.indexOf("SET log_statement = 'none'") < setup.indexOf('ALTER ROLE postgres PASSWORD'));
assert(!/dblink_connect_u|ALTER\s+ROLE\s+\w+\s+SUPERUSER/i.test(setup+auth+runner));
assert(!/set -[a-z]*x\b/.test(setup));
assert(auth.includes('remote_super IS DISTINCT FROM false'));
assert(auth.includes('SC004_DBLINK_AUTH: PASS'));
assert(auth.includes('credential diagnostics suppressed'));
assert(runner.indexOf('configure-sc004-scram.sh') < runner.indexOf('run_psql postgres -f'));
assert(runner.indexOf('\\i /tmp/sc004-r58/sql/sc004_dblink_auth_qa.sql') < runner.indexOf('\\i /tmp/sc004-r58/sql/sc004_ab_qa.sql'));
const migration='051_kora_school_sc004_trigger_execute_acl.sql';
const inventory=read('tests/school/sc004-r58-migrations.txt').trim().split('\n');
const actual=fs.readdirSync('supabase/migrations').filter(n=>/^\d{3}_.*\.sql$/.test(n)).sort();
assert.deepEqual(inventory,actual);
assert.equal(inventory.length,50);
assert.deepEqual(inventory.map(n=>Number(n.slice(0,3))),Array.from({length:51},(_,i)=>i+1).filter(n=>n!==41));
assert.equal(inventory.at(-1),migration);
const historical=execFileSync('git',['ls-tree','-r','--name-only',frozen,'supabase/migrations'],{encoding:'utf8'}).trim().split('\n');
assert.equal(historical.length,49);
for(const p of historical)assert.equal(read(p),original(p),'historical migration changed: '+p);
const acl=read('supabase/migrations/'+migration);
for(const name of ['sc004_assignment_lifecycle','sc004_validate_parent_integrity']) {
  assert(acl.includes('REVOKE EXECUTE ON FUNCTION public.'+name+'()\n  FROM PUBLIC, anon, authenticated, service_role;'));
}
assert(acl.includes("has_function_privilege(target_role,target_function,'EXECUTE') IS DISTINCT FROM false"));
assert(!/\b(?:GRANT|CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION|ALTER\s+(?:ROLE|POLICY|TABLE))\b/i.test(acl.replace(/--[^\n]*/g,'')));
const regression=read('tests/school/sql/sc004_trigger_acl_qa.sql');
for(const marker of ['aclexplode','pg_has_role','has_table_privilege','has_schema_privilege',
  'permission denied for function ','R58-ACL-INSTALLED-TRIGGERS',
  'R58-ACL-LEGITIMATE-LIFECYCLE','R58-ACL-CROSS-TENANT-INTEGRITY',
  "failure_state='23514'",'professor fora do tenant da atribuicao',"result<>'PASS'",'<>13'])assert(regression.includes(marker),marker);
assert(runner.includes('${#migrations[@]} == 50 && ${#expected_migrations[@]} == 50'));
assert(runner.includes('${migrations[$i]##*/} == "${expected_migrations[$i]}"'));
console.log(JSON.stringify({result:'STATIC PASS',patches:['A','B'],frozenExpectationsUnchanged:true,
  scramPrecedenceAndNegativeProbesPrepared:true,historicalMigrationsUnchanged:historical.length,
  canonicalMigrations:inventory.length,newMigration:migration,aclRegressionCases:13,runtime:'NOT RUN'},null,2));
