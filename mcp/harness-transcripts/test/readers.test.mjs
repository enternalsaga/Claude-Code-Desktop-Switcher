import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readEntries, readMeta } from '../readers/common.mjs';

const fixturesDir = fileURLToPath(new URL('../../../tests/fixtures/xharness/', import.meta.url));
const claudeFile = path.join(fixturesDir, 'claude-session.jsonl');
const codexFile = path.join(fixturesDir, 'codex-rollout.jsonl');
const codexZstFile = path.join(fixturesDir, 'codex-rollout.jsonl.zst');
const agyFile = path.join(fixturesDir, 'agy-transcript.jsonl');

const EXPECTED_COUNTS = {
  claude: 5,
  codex: 5,
  antigravity: 5,
};

test('partial last line', async () => {
  const c = await readEntries('claude', claudeFile);
  assert.equal(c.length, EXPECTED_COUNTS.claude);
  assert.equal(c.at(-1).text, 'Đã xong.');

  const x = await readEntries('codex', codexFile);
  assert.equal(x.length, EXPECTED_COUNTS.codex);
  assert.equal(x.at(-1).text, 'Hoàn tất.');

  const a = await readEntries('antigravity', agyFile);
  assert.equal(a.length, EXPECTED_COUNTS.antigravity);
  assert.equal(a.at(-1).text, 'Xong rồi.');
});

test('drops thinking and system', async () => {
  const c = await readEntries('claude', claudeFile);
  const cJoined = c.map((e) => e.text).join('\n');
  assert.ok(!cJoined.includes('internal thoughts'));
  assert.ok(!cJoined.includes('meta noise'));

  const x = await readEntries('codex', codexFile);
  const xJoined = x.map((e) => e.text).join('\n');
  assert.ok(!xJoined.includes('System prompt'));
  assert.ok(!xJoined.includes('environment_context'));
  assert.ok(!xJoined.includes('gAAAA'));

  const a = await readEntries('antigravity', agyFile);
  const aJoined = a.map((e) => e.text).join('\n');
  assert.ok(!aJoined.includes('secret thinking'));
  assert.ok(!aJoined.includes('system init'));
  assert.ok(!aJoined.includes('checkpoint noise'));
  assert.ok(!aJoined.includes('cursor=1'));
});

test('keeps Vietnamese text intact', async () => {
  const expected = 'Kiểm tra tiếng Việt có dấu: Đặng, ngưỡng, phở.';
  for (const [h, f] of [
    ['claude', claudeFile],
    ['codex', codexFile],
    ['antigravity', agyFile],
  ]) {
    const entries = await readEntries(h, f);
    assert.ok(entries.some((e) => e.role === 'user' && e.text === expected), `${h} lost Vietnamese text`);
  }
});

test('BOM and CRLF', async () => {
  const c = await readEntries('claude', claudeFile);
  assert.equal(c[0].role, 'user');
  assert.equal(c[0].text, 'Fix the login bug. Please check env.');

  const x = await readEntries('codex', codexFile);
  assert.equal(x[0].role, 'user');
  assert.equal(x[0].text, 'Run tests in repo. First sentence!');
});

test('zst equals plain', async () => {
  const plain = await readEntries('codex', codexFile);
  const zst = await readEntries('codex', codexZstFile);
  assert.deepEqual(zst, plain);
});

test('meta', async () => {
  const cm = await readMeta('claude', claudeFile);
  assert.equal(cm.id, '11111111-1111-1111-1111-111111111111');
  assert.equal(cm.cwd, 'C:\\work\\demo');
  assert.equal(cm.title, 'Claude demo session');

  const xm = await readMeta('codex', codexFile);
  assert.equal(xm.id, '22222222-2222-2222-2222-222222222222');
  assert.equal(xm.cwd, 'C:\\work\\demo');
  assert.equal(xm.title, 'Run tests in repo.');

  const am = await readMeta('antigravity', agyFile);
  assert.equal(am.id, '33333333-3333-3333-3333-333333333333');
  assert.equal(am.cwd, 'C:\\work\\demo');
  assert.equal(am.title, 'Inspect build errors.');
});
