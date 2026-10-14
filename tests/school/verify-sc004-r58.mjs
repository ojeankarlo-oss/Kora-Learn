// Static QA checks only: this does not execute SQL or certify PostgreSQL runtime.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const base = '711f761073253c4d0f010f35f75606a31ab075aa';
const abPath = 'tests/school/sql/sc004_ab_qa.sql';
const cdPath = 'tests/school/sql/sc004_cd_mutation_qa.sql';
const read = name => fs.readFileSync(name, 'utf8').replaceAll('\r\n', '\n');
const ab = read(abPath), cd = read(cdPath);
const originalAB = execFileSync('git', ['show', `${base}:${abPath}`], { encoding: 'utf8' }).replaceAll('\r\n', '\n');
const originalCD = execFileSync('git', ['show', `${base}:${cdPath}`], { encoding: 'utf8' }).replaceAll('\r\n', '\n');

function calls(source, boundOnly = true) {
  const result = [];
  const start = /\bselect pg_temp\.qa_probe_actor_(dml|count|rpc)(_bound)?\(/g;
  for (const match of source.matchAll(start)) {
    if (boundOnly && !match[2]) continue;
    const args = [];
    const token = /\s*(?:'((?:''|[^'])*)'|(null))\s*(,|\))/gy;
    token.lastIndex = match.index + match[0].length;
    for (;;) {
      const at = token.lastIndex;
      const item = token.exec(source);
      assert(item, `cannot parse ${args[0]} argument ${args.length} near ${JSON.stringify(source.slice(at,at+160))}`);
      args.push(item[2] ? null : item[1].replaceAll("''", "'"));
      if (item[3] === ')') break;
    }
    result.push({ kind: match[1], bound: Boolean(match[2]), args, id: args[0] });
  }
  return result;
}
const boundCalls = [...calls(ab), ...calls(cd)];
const templates = [...ab.matchAll(/\(\$sql\$([\s\S]*?)\$sql\$,\s*\$sql\$([\s\S]*?)\$sql\$\)/g)]
  .map(m => [m[1], m[2]]);
assert.equal(templates.length, 30);
assert.equal(new Set(templates.map(p => JSON.stringify(p))).size, templates.length);
const allowed = new Set(templates.map(p => JSON.stringify(p)));
const rejected = new Set([
  'R58-DML-PARAMETER-DECOY','R58-DML-PARAMETER-COMMENT',
  'R58-COUNT-PARAMETER-DECOY','R58-RPC-PARAMETER-DECOY',
  'R58-STATE-PARAMETER-DECOY','R58-STATE-SIDE-EFFECT',
]);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
for (const { id, args } of boundCalls) {
  assert(uuid.test(args[4]), `${id}: malformed actor UUID`);
  const approved = allowed.has(JSON.stringify(args.slice(-2)));
  assert.equal(approved, !rejected.has(id), `${id}: unexpected statement approval`);
}
assert.equal(boundCalls.filter(c => rejected.has(c.id)).length, rejected.size);
const countNull = boundCalls.find(c => c.id === 'R57-COUNT-NULL');
assert.equal(countNull.args[4], 'a3000000-0000-0000-0000-000000000002');
assert(ab.includes("WHEN 'R57-COUNT-NULL' THEN strpos(detail,' reason=STATE_NULL ') > 0"));
assert(ab.includes("AND strpos(detail,' before_id=aa100000-0000-0000-0000-000000000001 ') > 0"));

for (const id of ['R53-H2-REORDER','R53-H2-DELETE','R53-H2-OWNER-REORDER','R53-H2-OWNER-DELETE']) {
  const c = boundCalls.find(c => c.id === id);
  assert(c, id);
  const [operationTarget, declaredTarget, operationSQL, stateSQL] = c.args.slice(-4);
  assert.equal(operationTarget, declaredTarget);
  assert(operationTarget.split('|').length === 2 && operationTarget.split('|').every(p => uuid.test(p)));
  for (const sql of [operationSQL, stateSQL]) {
    assert(sql.includes("avaliacao_id=split_part($1::text,'|',1)::uuid and questao_id=split_part($1::text,'|',2)::uuid"));
    assert(!sql.includes('aa000000'), `${id}: hardcoded question in SQL`);
  }
  assert(stateSQL.includes("avaliacao_id::text||'|'||questao_id::text"));
}
const divergent = boundCalls.find(c => c.id === 'R56-BOUND-DIVERGENT-TARGET');
assert.notEqual(divergent.args[5], divergent.args[6]);
const malformed = boundCalls.find(c => c.id === 'R56-BOUND-MALFORMED-ID');
assert.deepEqual(malformed.args.slice(5,7), ['not-a-uuid','not-a-uuid']);
assert(ab.includes("WHEN 'R56-BOUND-MALFORMED-ID' THEN strpos(detail,' reason=STATE_QUERY_ERROR ') > 0"));
assert(ab.includes("AND strpos(detail,' sqlstate=22P02 message=') > 0"));
assert(!ab.includes('-- Variant for RLS-specific assertions.--'));
assert(ab.includes("when p_expected = 'INVALID' and p_observed = 'INVALID' then 'INVALID'"));
assert(cd.includes("qa_expect_result('M20-INVALID','INVALID')"));
assert(!cd.includes('M20_SUBMISSION_SERIALIZATION_INVALID: PASS'));
assert(!cd.includes("qa_expect_result('M20-INVALID','PASS')"));
const mutationIDs = [...cd.matchAll(/insert into qa_mutation_results values \('(M\d+)','KILLED'/g)].map(m => m[1]);
assert.equal(mutationIDs.length, 22);
assert.equal(new Set(mutationIDs).size, 22);
assert(!mutationIDs.includes('M20') && !mutationIDs.includes('M21'));

// Existing point-bound inputs and the narrow M22/M23 source contract stay exact.
const points = source => calls(source, false).filter(c => c.args[2] === 'BLOCKING GRADING POINT BOUNDS');
assert.deepEqual(points(ab), points(originalAB));
const oldLegacy = calls(originalAB, false).filter(c => !c.bound);
const newLegacy = new Map(calls(ab, false).filter(c => !c.bound).map(c => [c.id,c]));
for (const c of oldLegacy) assert.deepEqual(newLegacy.get(c.id), c, `existing legacy probe changed: ${c.id}`);
const narrowStart = '-- M22/M23';
const narrowEnd = '-- M24';
const narrow = source => source.slice(source.indexOf(narrowStart), source.indexOf(narrowEnd))
  .split('\n').filter(line => !line.startsWith('insert into qa_mutation_results')).join('\n');
assert.equal(narrow(cd), narrow(originalCD));
// F2 regressions remain: both mismatch directions in all three helper contracts.
for (const kind of ['DML','COUNT','RPC']) {
  for (const suffix of ['OP-A-STATE-B','OP-B-STATE-A','OP-A-DECLARED-B','MALFORMED','NULL','UNAUTHORIZED','AUTHORIZED']) {
    const id = `R57-${kind}-${suffix}`;
    assert(boundCalls.some(c => c.id === id), `missing F2 regression ${id}`);
  }
}
const runner = read('tests/school/run-sc004-r58.sh');
assert(runner.includes('--network none'));
assert(!/--publish|--network host/.test(runner));
assert(runner.includes('-v ON_ERROR_STOP=1'));
assert(runner.includes('\\i /tmp/sc004-r58/sql/sc004_ab_qa.sql\n\\i /tmp/sc004-r58/sql/sc004_cd_mutation_qa.sql'));
console.log(JSON.stringify({
  check: 'STATIC QA ONLY', result: 'PASS',
  approvedStatementPairs: templates.length, boundCalls: boundCalls.length,
  rejectedDecoyCases: rejected.size, compositeCases: 4,
  plannedValidMutationGroups: mutationIDs.length, plannedInvalid: ['M20'],
  excludedMutationSelftest: 'M21', runtime: 'NOT RUN',
}, null, 2));
