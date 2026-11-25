import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  getRoots,
  listSessions,
  readSessionTail,
  searchSessions,
  setTailBytes,
  setSearchMaxBytes,
  TAIL_BYTES,
  SEARCH_MAX_BYTES,
} from '../sessions.mjs';
import { TOOL_DEFS, callTool } from '../tools.mjs';

const fixturesDir = fileURLToPath(new URL('../../../tests/fixtures/xharness/', import.meta.url));

async function makeTempTree() {
  const base = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'ht-tools-test-'));
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

  const now = Date.now() / 1000;
  await fs.promises.utimes(claudeFile, now - 30, now - 30);
  await fs.promises.utimes(codexFile, now - 20, now - 20);
  await fs.promises.utimes(agyFile, now - 10, now - 10);

  return {
    base,
    roots: getRoots({
      HT_CLAUDE_HOME: claudeHome,
      HT_CODEX_HOMES: codexHome,
      HT_AGY_HOME: agyHome,
    }),
    files: { claudeFile, codexFile, agyFile },
  };
}

test('list sorts and limits', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  const all = await listSessions(tree.roots, {});
  assert.equal(all.length, 3);
  assert.deepEqual(
    all.map((s) => s.harness),
    ['antigravity', 'codex', 'claude'],
  );

  const limited = await listSessions(tree.roots, { limit: 2 });
  assert.equal(limited.length, 2);
  assert.deepEqual(
    limited.map((s) => s.harness),
    ['antigravity', 'codex'],
  );

  assert.equal(TOOL_DEFS.length, 3);
  const viaTool = JSON.parse(await callTool('list_sessions', { limit: 2 }, tree.roots));
  assert.equal(viaTool.length, 2);
});

test('cwd filter normalizes', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  for (const variant of ['C:\\Work\\Demo\\', 'c:/work/demo', '\\\\?\\C:\\work\\demo']) {
    const res = await listSessions(tree.roots, { cwd: variant });
    assert.equal(res.length, 3, `Expected 3 matches for ${variant}`);
  }
  const none = await listSessions(tree.roots, { cwd: 'C:\\other\\repo' });
  assert.equal(none.length, 0);
});

test('tail turns and tools', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  const oneTurn = await readSessionTail(tree.roots, {
    harness: 'claude',
    id: '11111111-1111-1111-1111-111111111111',
    turns: 1,
    includeTools: false,
  });
  assert.ok(oneTurn.includes('Kiểm tra tiếng Việt có dấu'));
  assert.ok(oneTurn.includes('Đã xong.'));
  assert.ok(!oneTurn.includes('Fix the login bug'));
  assert.ok(!oneTurn.includes('~~~'));

  const withTools = await readSessionTail(tree.roots, {
    harness: 'claude',
    id: '11111111-1111-1111-1111-111111111111',
    turns: 2,
    includeTools: true,
  });
  assert.ok(withTools.includes('- tool `Bash`: git status'));
  assert.ok(withTools.includes('~~~\nOn branch main\n~~~'));
  assert.ok(!withTools.includes('sk-ant-TEST'));
  assert.ok(withTools.includes('[REDACTED]'));

  const capped = await readSessionTail(tree.roots, {
    harness: 'claude',
    id: '11111111-1111-1111-1111-111111111111',
    turns: 2,
    maxChars: 120,
  });
  assert.ok(capped.length <= 120);
  assert.ok(capped.startsWith('[... 1 earlier turns cut]'));
});

test('tail redacts before cut', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  const id = '44444444-4444-4444-4444-444444444444';
  const file = path.join(tree.roots.claude, 'projects', 'C--work-demo', `${id}.jsonl`);
  // Secret starts at 2035 and straddles the 2048-char boundary; cutting first would leave "sk-ant-BOUNDAR" unredacted.
  const prefix = 'A'.repeat(2035);
  const secret = 'sk-ant-BOUNDARY01234567890123456789';
  const lines = [
    JSON.stringify({
      type: 'user',
      timestamp: '2026-11-25T10:00:00.000Z',
      cwd: 'C:\\work\\demo',
      sessionId: id,
      message: { role: 'user', content: 'Run tool' },
    }),
    JSON.stringify({
      type: 'assistant',
      timestamp: '2026-11-25T10:00:01.000Z',
      message: {
        role: 'assistant',
        content: [{ type: 'tool_use', id: 'tu1', name: 'Bash', input: { command: 'cat x' } }],
      },
    }),
    JSON.stringify({
      type: 'user',
      timestamp: '2026-11-25T10:00:02.000Z',
      message: {
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: 'tu1', content: prefix + secret + 'END' }],
      },
    }),
  ];
  await fs.promises.writeFile(file, lines.join('\n') + '\n', 'utf8');

  const md = await readSessionTail(tree.roots, { harness: 'claude', id, includeTools: true });
  assert.ok(!md.includes('BOUNDARY'));
  assert.ok(!md.includes('sk-ant-'));
  assert.ok(md.includes('[REDACTED]'));
});

test('tail window bounded', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  const id = '55555555-5555-5555-5555-555555555555';
  const file = path.join(tree.roots.claude, 'projects', 'C--work-demo', `${id}.jsonl`);
  const fillerLine =
    JSON.stringify({
      type: 'assistant',
      timestamp: '2026-11-25T10:00:00.000Z',
      message: { role: 'assistant', content: [{ type: 'text', text: 'X'.repeat(900) }] },
    }) + '\n';
  const fd = await fs.promises.open(file, 'w');
  try {
    for (let i = 0; i < 5500; i++) {
      await fd.write(fillerLine);
    }
    await fd.write(
      JSON.stringify({
        type: 'user',
        timestamp: '2026-11-25T11:00:00.000Z',
        sessionId: id,
        message: { role: 'user', content: 'Final question here' },
      }) + '\n',
    );
    await fd.write(
      JSON.stringify({
        type: 'assistant',
        timestamp: '2026-11-25T11:00:01.000Z',
        message: { role: 'assistant', content: [{ type: 'text', text: 'Final answer here' }] },
      }) + '\n',
    );
  } finally {
    await fd.close();
  }

  const stat = await fs.promises.stat(file);
  assert.ok(stat.size > 5 * 1024 * 1024);

  const origTail = TAIL_BYTES;
  const origOpen = fs.promises.open;
  let bytesReadTotal = 0;
  setTailBytes(64 * 1024);
  fs.promises.open = async (...openArgs) => {
    const handle = await origOpen.apply(fs.promises, openArgs);
    const origRead = handle.read.bind(handle);
    handle.read = async (...readArgs) => {
      const res = await origRead(...readArgs);
      bytesReadTotal += res.bytesRead;
      return res;
    };
    return handle;
  };

  try {
    const md = await readSessionTail(tree.roots, { harness: 'claude', id, turns: 1 });
    assert.ok(md.includes('Final question here'));
    assert.ok(md.includes('Final answer here'));
    assert.ok(bytesReadTotal > 0 && bytesReadTotal <= 64 * 1024, `read ${bytesReadTotal} bytes`);
  } finally {
    fs.promises.open = origOpen;
    setTailBytes(origTail);
  }
});

test('invalid id and traversal', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  for (const badId of ['../x', 'not-a-uuid', '11111111-1111-1111-1111-111111111111/../evil']) {
    await assert.rejects(
      () => readSessionTail(tree.roots, { harness: 'claude', id: badId }),
      (err) => err.code === 'invalid-id',
    );
  }

  const outsideDir = path.join(tree.base, 'outside');
  const outsideId = '66666666-6666-6666-6666-666666666666';
  await fs.promises.mkdir(outsideDir, { recursive: true });
  await fs.promises.writeFile(
    path.join(outsideDir, `${outsideId}.jsonl`),
    JSON.stringify({
      type: 'user',
      sessionId: outsideId,
      message: { role: 'user', content: 'escaped' },
    }) + '\n',
    'utf8',
  );
  const linkPath = path.join(tree.roots.claude, 'projects', 'escape-link');
  await fs.promises.symlink(outsideDir, linkPath, 'junction');

  await assert.rejects(
    () => readSessionTail(tree.roots, { harness: 'claude', id: outsideId }),
    (err) => err.code === 'invalid-id',
  );
});

test('search snippets and cap', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  await assert.rejects(
    () => searchSessions(tree.roots, { query: 'ab' }),
    (err) => err.code === 'invalid-args',
  );

  const found = await searchSessions(tree.roots, { query: 'tiếng Việt' });
  assert.equal(found.truncated, false);
  assert.equal(found.results.length, 3);
  for (const r of found.results) {
    assert.ok(r.snippets.length >= 1 && r.snippets.length <= 3);
    for (const s of r.snippets) assert.ok(s.length <= 200);
  }

  const origCap = SEARCH_MAX_BYTES;
  const statAgy = await fs.promises.stat(tree.files.agyFile);
  setSearchMaxBytes(statAgy.size + 10);
  try {
    const capped = await searchSessions(tree.roots, { query: 'tiếng Việt' });
    assert.equal(capped.truncated, true);
    assert.ok(capped.results.length < 3);
  } finally {
    setSearchMaxBytes(origCap);
  }
});

test('title redacts before cut', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  const id1 = '77777777-7777-7777-7777-777777777771';
  const f1 = path.join(tree.roots.claude, 'projects', 'C--work-demo', `${id1}.jsonl`);
  await fs.promises.writeFile(
    f1,
    JSON.stringify({
      type: 'user',
      timestamp: '2026-11-25T12:00:00.000Z',
      cwd: 'C:\\work\\demo',
      sessionId: id1,
      message: { role: 'user', content: 'a'.repeat(145) + 'sk-' + 'B'.repeat(30) },
    }) + '\n',
    'utf8',
  );

  const id2 = '77777777-7777-7777-7777-777777777772';
  const f2 = path.join(tree.roots.claude, 'projects', 'C--work-demo', `${id2}.jsonl`);
  await fs.promises.writeFile(
    f2,
    JSON.stringify({
      type: 'user',
      timestamp: '2026-11-25T12:01:00.000Z',
      cwd: 'C:\\work\\demo',
      sessionId: id2,
      message: { role: 'user', content: 'a'.repeat(135) + ' API_TOKEN=supersecretvalue' },
    }) + '\n',
    'utf8',
  );

  const list = await listSessions(tree.roots, { harness: 'claude' });
  const s1 = list.find((x) => x.id === id1);
  const s2 = list.find((x) => x.id === id2);
  assert.ok(s1 && !s1.title.includes('sk-B') && s1.title.includes('[REDACTED]'), `s1 title: ${s1?.title}`);
  assert.ok(s2 && !s2.title.includes('supersecret') && s2.title.includes('[REDACTED]'), `s2 title: ${s2?.title}`);
});

test('corrupt file does not break list or search', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  const badZst = path.join(
    tree.roots.codex[0],
    'sessions',
    '2026',
    '11',
    '25',
    'rollout-2026-11-25T10-00-01-77777777-7777-7777-7777-777777777777.jsonl.zst',
  );
  await fs.promises.writeFile(badZst, 'not-a-valid-zstd-frame', 'utf8');

  const list = await listSessions(tree.roots, { harness: 'codex' });
  assert.equal(list.length, 2);
  const badRow = list.find((s) => s.unreadable === true);
  const goodRow = list.find((s) => !s.unreadable);
  assert.ok(badRow, 'expected unreadable row');
  assert.ok(goodRow && goodRow.id === '22222222-2222-2222-2222-222222222222', 'expected valid row');

  const found = await searchSessions(tree.roots, { query: 'tiếng Việt', harness: 'codex' });
  assert.equal(found.results.length, 1);
  assert.equal(found.results[0].id, '22222222-2222-2222-2222-222222222222');
});

test('list id resolves in tail', async (t) => {
  const base = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'ht-list-id-'));
  t.after(() => fs.promises.rm(base, { recursive: true, force: true }));

  const claudeHome = path.join(base, 'claude');
  const codexHome = path.join(base, 'codex');
  const agyHome = path.join(base, 'agy');

  const claudeFileId = 'aaaa1111-1111-1111-1111-111111111111';
  const claudeContentId = 'bbbb2222-2222-2222-2222-222222222222';
  const claudeFile = path.join(claudeHome, 'projects', 'C--work-demo', `${claudeFileId}.jsonl`);
  await fs.promises.mkdir(path.dirname(claudeFile), { recursive: true });
  await fs.promises.writeFile(
    claudeFile,
    JSON.stringify({
      type: 'user',
      timestamp: '2026-11-25T10:00:00.000Z',
      cwd: 'C:\\work\\demo',
      sessionId: claudeContentId,
      message: { role: 'user', content: 'Claude forked turn' },
    }) + '\n',
    'utf8',
  );

  const agyDirId = 'cccc3333-3333-3333-3333-333333333333';
  const agyContentId = 'dddd4444-4444-4444-4444-444444444444';
  const agyFile = path.join(agyHome, 'brain', agyDirId, '.system_generated', 'logs', 'transcript.jsonl');
  await fs.promises.mkdir(path.dirname(agyFile), { recursive: true });
  await fs.promises.writeFile(
    agyFile,
    JSON.stringify({
      step_index: 0,
      type: 'USER_INPUT',
      created_at: '2026-11-25T10:00:00.000Z',
      conversation_id: agyContentId,
      cwd: 'C:\\work\\demo',
      content: 'Agy renamed folder turn',
    }) + '\n',
    'utf8',
  );

  const codexFileId = 'eeee5555-5555-5555-5555-555555555555';
  const codexContentId = 'ffff6666-6666-6666-6666-666666666666';
  const codexFile = path.join(
    codexHome,
    'sessions',
    '2026',
    '11',
    '25',
    `rollout-2026-11-25T10-00-00-${codexFileId}.jsonl`,
  );
  await fs.promises.mkdir(path.dirname(codexFile), { recursive: true });
  await fs.promises.writeFile(
    codexFile,
    [
      JSON.stringify({
        timestamp: '2026-11-25T10:00:00.000Z',
        type: 'session_meta',
        payload: { id: codexContentId, cwd: 'C:\\work\\demo' },
      }),
      JSON.stringify({
        timestamp: '2026-11-25T10:00:01.000Z',
        type: 'response_item',
        payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Codex content id turn' }] },
      }),
    ].join('\n') + '\n',
    'utf8',
  );

  const roots = getRoots({
    HT_CLAUDE_HOME: claudeHome,
    HT_CODEX_HOMES: codexHome,
    HT_AGY_HOME: agyHome,
  });

  const listed = await listSessions(roots, {});
  assert.equal(listed.length, 3);

  const cRow = listed.find((s) => s.harness === 'claude');
  assert.equal(cRow.id, claudeFileId);
  const cTail = await readSessionTail(roots, { harness: 'claude', id: cRow.id });
  assert.ok(cTail.includes('Claude forked turn'));

  const aRow = listed.find((s) => s.harness === 'antigravity');
  assert.equal(aRow.id, agyDirId);
  const aTail = await readSessionTail(roots, { harness: 'antigravity', id: aRow.id });
  assert.ok(aTail.includes('Agy renamed folder turn'));

  const xRow = listed.find((s) => s.harness === 'codex');
  assert.equal(xRow.id, codexContentId);
  const xTail = await readSessionTail(roots, { harness: 'codex', id: xRow.id });
  assert.ok(xTail.includes('Codex content id turn'));
});

test('search skips single file over cap', async (t) => {
  const base = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'ht-overcap-'));
  t.after(() => fs.promises.rm(base, { recursive: true, force: true }));
  const claudeHome = path.join(base, 'claude');
  const proj = path.join(claudeHome, 'projects', 'C--work-demo');
  await fs.promises.mkdir(proj, { recursive: true });

  const bigId = '88888888-8888-8888-8888-888888888881';
  const smallId = '88888888-8888-8888-8888-888888888882';
  const bigFile = path.join(proj, `${bigId}.jsonl`);
  const smallFile = path.join(proj, `${smallId}.jsonl`);

  await fs.promises.writeFile(
    smallFile,
    JSON.stringify({ type: 'user', sessionId: smallId, message: { role: 'user', content: 'small-match-marker' } }) + '\n',
    'utf8',
  );
  await fs.promises.writeFile(
    bigFile,
    JSON.stringify({ type: 'user', sessionId: bigId, message: { role: 'user', content: 'Z'.repeat(500) } }) + '\n',
    'utf8',
  );
  const now = Date.now() / 1000;
  await fs.promises.utimes(smallFile, now - 20, now - 20);
  await fs.promises.utimes(bigFile, now - 5, now - 5);

  const roots = getRoots({ HT_CLAUDE_HOME: claudeHome, HT_CODEX_HOMES: path.join(base, 'codex'), HT_AGY_HOME: path.join(base, 'agy') });
  const origCap = SEARCH_MAX_BYTES;
  setSearchMaxBytes(250);
  try {
    const res = await searchSessions(roots, { query: 'small-match-marker', harness: 'claude' });
    assert.equal(res.truncated, true);
    assert.equal(res.results.length, 1);
    assert.equal(res.results[0].id, smallId);
  } finally {
    setSearchMaxBytes(origCap);
  }
});

test('includeTools string false is false', async (t) => {
  const tree = await makeTempTree();
  t.after(() => fs.promises.rm(tree.base, { recursive: true, force: true }));

  const asFalse = await readSessionTail(tree.roots, {
    harness: 'claude',
    id: '11111111-1111-1111-1111-111111111111',
    turns: 2,
    includeTools: 'false',
  });
  assert.ok(!asFalse.includes('~~~') && !asFalse.includes('- tool'));

  const asTrue = await readSessionTail(tree.roots, {
    harness: 'claude',
    id: '11111111-1111-1111-1111-111111111111',
    turns: 2,
    includeTools: 'true',
  });
  assert.ok(asTrue.includes('- tool `Bash`'));
});
