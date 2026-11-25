import fs from 'node:fs';
import path from 'node:path';
import { getFirstSentence, stripExtendedPrefix } from './common.mjs';

const SYSTEM_STEP_TYPES = new Set([
  'SYSTEM_MESSAGE',
  'CHECKPOINT',
  'CONVERSATION_HISTORY',
  'ERROR_MESSAGE',
]);

const TOOL_ARG_KEYS = [
  'toolSummary',
  'CommandLine',
  'command',
  'TargetFile',
  'AbsolutePath',
  'Path',
  'Query',
  'Url',
];

function getAgyToolArg(toolArgs) {
  if (!toolArgs || typeof toolArgs === 'string') return toolArgs ? String(toolArgs) : '';
  if (typeof toolArgs !== 'object') return '';
  const entries = Object.entries(toolArgs);
  for (const name of TOOL_ARG_KEYS) {
    const lower = name.toLowerCase();
    const hit = entries.find(([k, v]) => k.toLowerCase() === lower && typeof v === 'string' && v);
    if (hit) return hit[1];
  }
  const first = entries.find(([, v]) => typeof v === 'string' && v);
  return first ? first[1] : '';
}

function getAgyUserText(content) {
  const s = content == null ? '' : String(content);
  const m = /<USER_REQUEST>([\s\S]*?)<\/USER_REQUEST>/.exec(s);
  if (m) return m[1].trim();
  return s.replace(/<ADDITIONAL_METADATA>[\s\S]*?<\/ADDITIONAL_METADATA>/g, '').trim();
}

export function parseAgyLines(lines) {
  const entries = [];
  const pending = [];

  for (const line of lines) {
    if (!line || !line.trim()) continue;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    if (!o || SYSTEM_STEP_TYPES.has(o.type)) continue;
    const ts = o.created_at ?? null;
    switch (o.type) {
      case 'USER_INPUT': {
        const text = getAgyUserText(o.content);
        if (text) entries.push({ role: 'user', text, ts });
        break;
      }
      case 'PLANNER_RESPONSE': {
        if (o.content) {
          entries.push({ role: 'assistant', text: String(o.content), ts });
        }
        const calls = Array.isArray(o.tool_calls) ? o.tool_calls : [];
        for (const call of calls) {
          if (!call) continue;
          const t = {
            role: 'tool',
            text: '',
            ts,
            tool: {
              name: call.name == null ? '' : String(call.name),
              arg: getAgyToolArg(call.args),
              output: '',
            },
          };
          entries.push(t);
          pending.push(t);
        }
        break;
      }
      default:
        if (o.content && pending.length > 0) {
          pending.shift().tool.output = String(o.content);
        }
        break;
    }
  }
  return entries;
}

async function readBrainMdTitle(brainDir) {
  let dirEntries;
  try {
    dirEntries = await fs.promises.readdir(brainDir, { withFileTypes: true });
  } catch {
    return null;
  }
  const mdFiles = dirEntries
    .filter((d) => d.isFile() && d.name.toLowerCase().endsWith('.md'))
    .map((d) => d.name)
    .sort((a, b) => a.localeCompare(b));
  for (const name of mdFiles) {
    try {
      const content = await fs.promises.readFile(path.join(brainDir, name), 'utf8');
      const lines = content.split(/\r?\n/).slice(0, 12);
      const first = lines.find((l) => l.trim());
      if (first) return first.replace(/^\s*#+\s*/, '').trim();
    } catch {
      // ignore unreadable markdown file
    }
  }
  return null;
}

export async function parseAgyMeta(lines, file) {
  let id = null;
  let cwd = null;
  let firstUserText = null;

  const norm = path.resolve(file);
  const logsDir = path.dirname(norm);
  const sysDir = path.dirname(logsDir);
  let brainDir = null;
  if (path.basename(logsDir) === 'logs' && path.basename(sysDir) === '.system_generated') {
    brainDir = path.dirname(sysDir);
    id = path.basename(brainDir);
  }

  for (const line of lines) {
    if (!line || !line.trim()) continue;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    if (!o) continue;
    if (!id && typeof o.conversation_id === 'string' && o.conversation_id) id = o.conversation_id;
    if (!cwd && typeof o.cwd === 'string' && o.cwd) cwd = stripExtendedPrefix(o.cwd);
    if (firstUserText === null && o.type === 'USER_INPUT') {
      const text = getAgyUserText(o.content);
      if (text) firstUserText = text;
    }
  }

  if (!id) id = path.basename(file, '.jsonl');
  const mdTitle = brainDir ? await readBrainMdTitle(brainDir) : null;
  const title = mdTitle || getFirstSentence(firstUserText) || id;
  return { id, title, cwd };
}
