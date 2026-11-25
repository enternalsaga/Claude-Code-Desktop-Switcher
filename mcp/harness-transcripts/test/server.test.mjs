import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isNodeVersionSupported } from '../server.mjs';

const serverPath = fileURLToPath(new URL('../server.mjs', import.meta.url));
const fixturesDir = fileURLToPath(new URL('../../../tests/fixtures/xharness/', import.meta.url));

async function makeTempTree() {
  const base = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'ht-srv-test-'));
  const claudeHome = path.join(base, 'claude');
  const codexHome = path.join(base, 'codex');
  const agyHome = path.join(base, 'agy');

  const claudeFile = path.join(claudeHome, 'projects', 'C--work-demo', '11111111-1111-1111-1111-111111111111.jsonl');
  await fs.promises.mkdir(path.dirname(claudeFile), { recursive: true });
  await fs.promises.copyFile(path.join(fixturesDir, 'claude-session.jsonl'), claudeFile);

  const codexFile = path.join(
    codexHome,
    'sessions',
    '2026',
    '11',
    '25',
    'rollout-2026-11-25T10-00-00-22222222-2222-2222-2222-222222222222.jsonl',
  );
  await fs.promises.mkdir(path.dirname(codexFile), { recursive: true });
  await fs.promises.copyFile(path.join(fixturesDir, 'codex-rollout.jsonl'), codexFile);

  const agyFile = path.join(
    agyHome,
    'brain',
    '33333333-3333-3333-3333-333333333333',
    '.system_generated',
    'logs',
    'transcript.jsonl',
  );
  await fs.promises.mkdir(path.dirname(agyFile), { recursive: true });
  await fs.promises.copyFile(path.join(fixturesDir, 'agy-transcript.jsonl'), agyFile);

  return {
    base,
    env: {
      ...process.env,
      HT_CLAUDE_HOME: claudeHome,
      HT_CODEX_HOMES: codexHome,
      HT_AGY_HOME: agyHome,
    },
  };
}

test('node version check', () => {
  assert.equal(isNodeVersionSupported('21.9.0'), false);
  assert.equal(isNodeVersionSupported('22.14.9'), false);
  assert.equal(isNodeVersionSupported('22.15.0'), true);
  assert.equal(isNodeVersionSupported('24.22.1'), true);
});

test('full session', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  const child = spawn(process.execPath, [serverPath], {
    env: tree.env,
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
  });
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
  });

  const requests = [
    {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1.0' } },
    },
    { jsonrpc: '2.0', method: 'notifications/initialized' },
    { jsonrpc: '2.0', id: 2, method: 'ping' },
    { jsonrpc: '2.0', id: 3, method: 'tools/list' },
    { jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'list_sessions', arguments: {} } },
    {
      jsonrpc: '2.0',
      id: 5,
      method: 'tools/call',
      params: { name: 'read_session_tail', arguments: { harness: 'claude', id: '../bad' } },
    },
    { jsonrpc: '2.0', id: 6, method: 'unknown/method', params: {} },
  ];

  child.stdin.write(requests.map((r) => JSON.stringify(r)).join('\n') + '\n');
  child.stdin.end();

  const exitCode = await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', resolve);
  });

  assert.equal(exitCode, 0, `server exited ${exitCode}: ${stderr}`);
  const lines = stdout
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
  assert.equal(lines.length, 6, `expected 6 JSON-RPC lines, got ${lines.length}: ${stdout}`);

  const replies = lines.map((l) => JSON.parse(l));
  for (const r of replies) assert.equal(r.jsonrpc, '2.0');

  const byId = new Map(replies.map((r) => [r.id, r]));
  assert.equal(byId.get(1).result.protocolVersion, '2025-06-18');
  assert.ok(byId.get(1).result.capabilities.tools);
  assert.equal(byId.get(1).result.serverInfo.name, 'harness-transcripts');

  assert.deepEqual(byId.get(2).result, {});

  assert.deepEqual(
    byId.get(3).result.tools.map((tool) => tool.name),
    ['list_sessions', 'read_session_tail', 'search_sessions'],
  );

  const listResult = byId.get(4).result;
  assert.equal(listResult.isError, undefined);
  const sessions = JSON.parse(listResult.content[0].text);
  assert.equal(sessions.length, 3);

  const badTail = byId.get(5).result;
  assert.equal(badTail.isError, true);
  assert.ok(badTail.content[0].text.includes('invalid-id'));

  assert.equal(byId.get(6).error.code, -32601);
});

test('tools/call redacts error text', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  const child = spawn(process.execPath, [serverPath], {
    env: tree.env,
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  let stdout = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });

  child.stdin.write(
    JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name: 'read_session_tail', arguments: { harness: 'claude', id: 'sk-ant-ERRSECRET01234567890123456789' } },
    }) + '\n',
  );
  child.stdin.end();

  const exitCode = await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', resolve);
  });
  assert.equal(exitCode, 0);
  const reply = JSON.parse(stdout.trim());
  assert.equal(reply.result.isError, true);
  assert.ok(reply.result.content[0].text.includes('invalid-id'));
  assert.ok(reply.result.content[0].text.includes('[REDACTED]'));
  assert.ok(!reply.result.content[0].text.includes('ERRSECRET'));
});
