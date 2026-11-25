import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { redact } from './redact.mjs';
import { makeError, readEntries, readMeta } from './readers/common.mjs';

export let TAIL_BYTES = 16 * 1024 * 1024;
export let SEARCH_MAX_BYTES = 64 * 1024 * 1024;

export function setTailBytes(bytes) {
  TAIL_BYTES = bytes;
}

export function setSearchMaxBytes(bytes) {
  SEARCH_MAX_BYTES = bytes;
}

const MAX_FILES_PER_HARNESS = 500;
const VALID_HARNESSES = new Set(['claude', 'codex', 'antigravity']);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CODEX_ROLLOUT_RE = /^rollout-.*\.jsonl(\.zst)?$/i;
const metaCache = new Map();

function clampInt(value, fallback, min, max) {
  const n = Number.isFinite(value) ? Math.trunc(value) : fallback;
  return Math.max(min, Math.min(max, n));
}

function normalizeCwd(cwd) {
  if (!cwd) return '';
  return String(cwd)
    .replace(/^\\\\\?\\/, '')
    .replace(/\//g, '\\')
    .replace(/\\+$/, '')
    .toLowerCase();
}

function validateHarness(harness, required = false) {
  if (harness == null || harness === '') {
    if (required) throw makeError('invalid-args', 'harness is required');
    return null;
  }
  if (!VALID_HARNESSES.has(harness)) {
    throw makeError('invalid-args', `Invalid harness: ${harness}`);
  }
  return harness;
}

function validateUuid(id) {
  if (typeof id !== 'string' || !UUID_RE.test(id)) {
    if (typeof id === 'string' && id.startsWith('local_')) {
      throw makeError(
        'invalid-id',
        `Invalid session id "${id}": Claude Desktop "local_" ids are not MCP session ids. Call list_sessions and use its id.`,
      );
    }
    throw makeError('invalid-id', `Invalid session id: ${id}`);
  }
}

function isInsideResolved(candidate, root) {
  const r = root.replace(/\\+$/, '').toLowerCase() + path.sep;
  const c = candidate.toLowerCase();
  return c.startsWith(r);
}

async function assertInsideRoot(file, rootsList) {
  const resolvedFile = path.resolve(file);
  let realFile;
  try {
    realFile = await fs.promises.realpath(resolvedFile);
  } catch {
    throw makeError('not-found', `Session file not found: ${path.basename(file)}`);
  }

  for (const root of rootsList) {
    const resolvedRoot = path.resolve(root);
    let realRoot = resolvedRoot;
    try {
      realRoot = await fs.promises.realpath(resolvedRoot);
    } catch {
      continue;
    }
    if (isInsideResolved(resolvedFile, resolvedRoot) && isInsideResolved(realFile, realRoot)) {
      return;
    }
  }
  throw makeError('invalid-id', 'Session path escapes harness root');
}

export function getRoots(env = process.env) {
  const home = env.USERPROFILE || env.HOME || os.homedir();
  const claude = env.HT_CLAUDE_HOME || path.join(home, '.claude');
  const antigravity = env.HT_AGY_HOME || path.join(home, '.gemini', 'antigravity');

  let codex;
  if (env.HT_CODEX_HOMES) {
    codex = env.HT_CODEX_HOMES.split(';')
      .map((s) => s.trim())
      .filter(Boolean);
  } else {
    codex = [path.join(home, '.codex')];
    const profilesDir = path.join(home, '.codex-profiles');
    try {
      for (const entry of fs.readdirSync(profilesDir, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue;
        const candidate = path.join(profilesDir, entry.name);
        if (fs.existsSync(path.join(candidate, 'sessions'))) {
          codex.push(candidate);
        }
      }
    } catch {
      // .codex-profiles is optional
    }
  }

  return { claude, codex, antigravity };
}

async function safeReaddir(dir) {
  try {
    return await fs.promises.readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }
}

async function safeStat(file) {
  try {
    return await fs.promises.stat(file);
  } catch {
    return null;
  }
}

async function collectCodexFiles(sessionsDir, depth, out) {
  if (depth > 4) return;
  for (const entry of await safeReaddir(sessionsDir)) {
    if (entry.isSymbolicLink()) continue;
    const full = path.join(sessionsDir, entry.name);
    if (entry.isDirectory()) {
      await collectCodexFiles(full, depth + 1, out);
    } else if (entry.isFile() && CODEX_ROLLOUT_RE.test(entry.name)) {
      const st = await safeStat(full);
      if (st && st.isFile()) out.push({ file: full, stat: st });
    }
  }
}

async function discoverHarnessFiles(harness, roots) {
  const found = [];
  if (harness === 'claude') {
    const projectsDir = path.join(roots.claude, 'projects');
    for (const proj of await safeReaddir(projectsDir)) {
      if (proj.isSymbolicLink() || !proj.isDirectory()) continue;
      const projPath = path.join(projectsDir, proj.name);
      for (const item of await safeReaddir(projPath)) {
        if (item.isSymbolicLink() || !item.isFile()) continue;
        if (!item.name.toLowerCase().endsWith('.jsonl')) continue;
        const base = item.name.slice(0, -6);
        if (!UUID_RE.test(base)) continue;
        const full = path.join(projPath, item.name);
        const st = await safeStat(full);
        if (st && st.isFile()) found.push({ file: full, stat: st });
      }
    }
  } else if (harness === 'codex') {
    for (const home of roots.codex) {
      await collectCodexFiles(path.join(home, 'sessions'), 0, found);
    }
  } else if (harness === 'antigravity') {
    const brainDir = path.join(roots.antigravity, 'brain');
    for (const conv of await safeReaddir(brainDir)) {
      if (conv.isSymbolicLink() || !conv.isDirectory()) continue;
      if (!UUID_RE.test(conv.name)) continue;
      const full = path.join(brainDir, conv.name, '.system_generated', 'logs', 'transcript.jsonl');
      const st = await safeStat(full);
      if (st && st.isFile()) found.push({ file: full, stat: st });
    }
  }

  found.sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);
  return found.slice(0, MAX_FILES_PER_HARNESS);
}

async function getCachedMeta(harness, file, stat) {
  const key = `${file}|${stat.size}|${stat.mtimeMs}`;
  if (metaCache.has(key)) return metaCache.get(key);
  try {
    const m = await readMeta(harness, file);
    const info = { harness, ...m };
    metaCache.set(key, info);
    return info;
  } catch {
    const base = path.basename(file).replace(/\.jsonl(\.zst)?$/i, '');
    return {
      harness,
      id: base,
      title: base,
      cwd: null,
      lastActivity: stat.mtime.toISOString(),
      sizeBytes: stat.size,
      unreadable: true,
    };
  }
}

export async function listSessions(roots, opts = {}) {
  const harnessFilter = validateHarness(opts.harness, false);
  const limit = clampInt(opts.limit, 20, 1, 100);
  const wantCwd = opts.cwd ? normalizeCwd(opts.cwd) : null;
  const harnesses = harnessFilter ? [harnessFilter] : ['claude', 'codex', 'antigravity'];

  const items = [];
  for (const h of harnesses) {
    const files = await discoverHarnessFiles(h, roots);
    for (const { file, stat } of files) {
      const meta = await getCachedMeta(h, file, stat);
      if (wantCwd && normalizeCwd(meta.cwd) !== wantCwd) continue;
      items.push({
        harness: meta.harness,
        id: meta.id,
        title: redact(meta.title),
        cwd: meta.cwd ? redact(meta.cwd) : null,
        lastActivity: meta.lastActivity,
        sizeBytes: meta.sizeBytes,
        ...(meta.unreadable ? { unreadable: true } : {}),
      });
    }
  }

  items.sort((a, b) => b.lastActivity.localeCompare(a.lastActivity));
  return items.slice(0, limit);
}

async function findSessionFile(roots, harness, id) {
  const lowerId = id.toLowerCase();
  if (harness === 'claude') {
    const projectsDir = path.join(roots.claude, 'projects');
    for (const proj of await safeReaddir(projectsDir)) {
      if (!proj.isDirectory() && !proj.isSymbolicLink()) continue;
      const candidate = path.join(projectsDir, proj.name, `${id}.jsonl`);
      if (await safeStat(candidate)) {
        await assertInsideRoot(candidate, [roots.claude]);
        return candidate;
      }
    }
    throw makeError('not-found', `Claude session not found: ${id}`);
  }

  if (harness === 'antigravity') {
    const candidate = path.join(
      roots.antigravity,
      'brain',
      id,
      '.system_generated',
      'logs',
      'transcript.jsonl',
    );
    if (await safeStat(candidate)) {
      await assertInsideRoot(candidate, [roots.antigravity]);
      return candidate;
    }
    throw makeError('not-found', `Antigravity session not found: ${id}`);
  }

  for (const home of roots.codex) {
    const files = [];
    await collectCodexFilesIncludingLinks(path.join(home, 'sessions'), 0, files);
    const match = files.find((f) => path.basename(f).toLowerCase().includes(lowerId));
    if (match) {
      await assertInsideRoot(match, roots.codex);
      return match;
    }
  }
  for (const { file, stat } of await discoverHarnessFiles('codex', roots)) {
    const meta = await getCachedMeta('codex', file, stat);
    if (!meta.unreadable && String(meta.id).toLowerCase() === lowerId) {
      await assertInsideRoot(file, roots.codex);
      return file;
    }
  }
  throw makeError('not-found', `Codex session not found: ${id}`);
}

async function collectCodexFilesIncludingLinks(dir, depth, out) {
  if (depth > 4) return;
  for (const entry of await safeReaddir(dir)) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory() || entry.isSymbolicLink()) {
      const st = await safeStat(full);
      if (st && st.isDirectory()) await collectCodexFilesIncludingLinks(full, depth + 1, out);
    } else if (entry.isFile() && CODEX_ROLLOUT_RE.test(entry.name)) {
      out.push(full);
    }
  }
}

function formatTurn(turn, includeTools) {
  const lines = [];
  for (const e of turn) {
    if (e.role === 'tool') {
      if (!includeTools) continue;
      let arg = redact(e.tool?.arg ?? '').replace(/\s+/g, ' ').trim();
      if (arg.length > 200) arg = arg.slice(0, 200) + '...';
      lines.push(`- tool \`${e.tool?.name ?? ''}\`: ${arg}`);
      let output = redact(e.tool?.output ?? '');
      if (output) {
        if (output.length > 2048) {
          output = `${output.slice(0, 2048)}\n... [truncated ${output.length - 2048} more chars]`;
        }
        lines.push('~~~', output, '~~~');
      }
    } else {
      lines.push(`### ${e.role}`, redact(e.text ?? ''), '');
    }
  }
  return lines.join('\n');
}

export async function readSessionTail(roots, opts = {}) {
  const harness = validateHarness(opts.harness, true);
  validateUuid(opts.id);
  const turns = clampInt(opts.turns, 10, 1, 50);
  const includeTools = opts.includeTools === true || opts.includeTools === 'true';
  const maxChars = clampInt(opts.maxChars, 20000, 1, 100000);

  const file = await findSessionFile(roots, harness, opts.id);
  const entries = await readEntries(harness, file, { tailBytes: TAIL_BYTES });

  const grouped = [];
  for (const e of entries) {
    if (e.role === 'user' || grouped.length === 0) grouped.push([]);
    grouped[grouped.length - 1].push(e);
  }

  const kept = grouped.slice(-turns);
  const blocks = kept.map((t) => formatTurn(t, includeTools)).filter(Boolean);
  if (blocks.length === 0) return '';

  const full = blocks.join('\n');
  if (full.length <= maxChars) return full;

  for (let cut = 1; cut < blocks.length; cut++) {
    const banner = `[... ${cut} earlier turns cut]\n\n`;
    const candidate = banner + blocks.slice(cut).join('\n');
    if (candidate.length <= maxChars) return candidate;
  }

  const last = blocks[blocks.length - 1];
  const cutCount = blocks.length - 1;
  const prefix = cutCount > 0 ? `[... ${cutCount} earlier turns cut]\n\n` : '';
  const available = Math.max(0, maxChars - prefix.length);
  return (prefix + last.slice(last.length - available)).slice(0, maxChars);
}

function extractSnippet(text, queryLower) {
  const idx = text.toLowerCase().indexOf(queryLower);
  if (idx < 0) return null;
  const radius = 90;
  let start = Math.max(0, idx - radius);
  let end = Math.min(text.length, idx + queryLower.length + radius);
  if (end - start > 200) end = start + 200;
  let snippet = text.slice(start, end).replace(/\s+/g, ' ').trim();
  if (snippet.length > 200) snippet = snippet.slice(0, 200);
  return snippet;
}

export async function searchSessions(roots, opts = {}) {
  const query = opts.query;
  if (typeof query !== 'string' || query.length < 3) {
    throw makeError('invalid-args', 'query must be at least 3 characters');
  }
  const harnessFilter = validateHarness(opts.harness, false);
  const limit = clampInt(opts.limit, 10, 1, 100);
  const harnesses = harnessFilter ? [harnessFilter] : ['claude', 'codex', 'antigravity'];

  const candidates = [];
  for (const h of harnesses) {
    for (const item of await discoverHarnessFiles(h, roots)) {
      candidates.push({ harness: h, file: item.file, stat: item.stat });
    }
  }
  candidates.sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);

  const queryLower = query.toLowerCase();
  const results = [];
  let bytesRead = 0;
  let truncated = false;

  for (const item of candidates) {
    if (results.length >= limit) break;
    if (item.stat.size > SEARCH_MAX_BYTES) {
      truncated = true;
      continue;
    }
    if (bytesRead + item.stat.size > SEARCH_MAX_BYTES) {
      truncated = true;
      break;
    }
    bytesRead += item.stat.size;

    let meta;
    let entries;
    try {
      meta = await getCachedMeta(item.harness, item.file, item.stat);
      if (meta.unreadable) continue;
      entries = await readEntries(item.harness, item.file);
    } catch {
      continue;
    }

    const snippets = [];
    for (const e of entries) {
      if (snippets.length >= 3) break;
      const fields = [redact(e.text ?? '')];
      if (e.tool) {
        fields.push(redact(e.tool.arg ?? ''), redact(e.tool.output ?? ''));
      }
      for (const f of fields) {
        if (snippets.length >= 3) break;
        const snip = extractSnippet(f, queryLower);
        if (snip) snippets.push(snip);
      }
    }

    if (snippets.length > 0) {
      results.push({
        harness: item.harness,
        id: meta.id,
        title: redact(meta.title),
        snippets,
      });
    }
  }

  return { results, truncated };
}
