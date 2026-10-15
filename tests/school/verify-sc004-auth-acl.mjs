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
console.log(JSON.stringify({result:'STATIC PASS',patch:'A',frozenExpectationsUnchanged:true,scramPrecedenceAndNegativeProbesPrepared:true,runtime:'NOT RUN'},null,2));
