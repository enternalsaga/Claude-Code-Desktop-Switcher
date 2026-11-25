import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import zlib from 'node:zlib';
import { redact } from '../redact.mjs';
import { parseClaudeLines, parseClaudeMeta } from './claude.mjs';
import { parseCodexLines, parseCodexMeta } from './codex.mjs';
import { parseAgyLines, parseAgyMeta } from './antigravity.mjs';

export function makeError(code, message) {
  const err = new Error(message);
  err.code = code;
  return err;
}

export function stripExtendedPrefix(p) {
  if (!p) return null;
  return String(p).replace(/^\\\\\?\\/, '');
}

export function getFirstSentence(text, maxLength = 160) {
  if (!text) return '';
  const safe = redact(text);
  const lines = String(safe).split(/\r?\n/);
  let line = '';
  for (const candidate of lines) {
    if (candidate.trim()) {
      line = candidate.trim();
      break;
    }
  }
  if (!line) return '';
  const m = /^(.*?[.!?])(\s|$)/.exec(line);
  if (m) line = m[1];
  if (line.length > maxLength) line = line.slice(0, maxLength) + '...';
  return line;
}

export async function readLines(file, opts = {}) {
  const isZst = file.toLowerCase().endsWith('.zst');
  if (isZst) {
    if (typeof zlib.zstdDecompressSync !== 'function') {
      throw makeError('zstd-unsupported', 'zstdDecompressSync is not available in this Node version');
    }
    const raw = await fs.promises.readFile(file);
    let text = zlib.zstdDecompressSync(raw).toString('utf8');
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    return text.split(/\r?\n/);
  }

  const tailBytes = opts && typeof opts.tailBytes === 'number' && opts.tailBytes > 0 ? opts.tailBytes : 0;
  if (tailBytes > 0) {
    const stat = await fs.promises.stat(file);
    if (stat.size > tailBytes) {
      const handle = await fs.promises.open(file, 'r');
      try {
        const start = stat.size - tailBytes;
        const buf = Buffer.allocUnsafe(tailBytes);
        let total = 0;
        while (total < tailBytes) {
          const { bytesRead } = await handle.read(buf, total, tailBytes - total, start + total);
          if (bytesRead === 0) break;
          total += bytesRead;
        }
        const text = buf.subarray(0, total).toString('utf8');
        const lines = text.split(/\r?\n/);
        lines.shift();
        return lines;
      } finally {
        await handle.close();
      }
    }
  }

  const lines = [];
  const input = fs.createReadStream(file, { encoding: 'utf8' });
  const rl = readline.createInterface({ input, crlfDelay: Infinity });
  let first = true;
  try {
    for await (let line of rl) {
      if (first) {
        first = false;
        if (line.charCodeAt(0) === 0xfeff) line = line.slice(1);
      }
      lines.push(line);
    }
  } finally {
    rl.close();
    input.destroy();
  }
  return lines;
}

export async function readEntries(harness, file, opts = {}) {
  const lines = await readLines(file, opts);
  switch (harness) {
    case 'claude':
      return parseClaudeLines(lines);
    case 'codex':
      return parseCodexLines(lines);
    case 'antigravity':
      return parseAgyLines(lines);
    default:
      throw makeError('invalid-args', `Unknown harness: ${harness}`);
  }
}

export async function readMeta(harness, file) {
  const stat = await fs.promises.stat(file);
  const lines = await readLines(file);
  const base = {
    lastActivity: stat.mtime.toISOString(),
    sizeBytes: stat.size,
  };
  let meta;
  switch (harness) {
    case 'claude':
      meta = parseClaudeMeta(lines, file);
      break;
    case 'codex':
      meta = parseCodexMeta(lines, file);
      break;
    case 'antigravity':
      meta = await parseAgyMeta(lines, file);
      break;
    default:
      throw makeError('invalid-args', `Unknown harness: ${harness}`);
  }
  return {
    id: meta.id || path.basename(file),
    title: meta.title || meta.id || path.basename(file),
    cwd: meta.cwd || null,
    lastActivity: base.lastActivity,
    sizeBytes: base.sizeBytes,
  };
}
