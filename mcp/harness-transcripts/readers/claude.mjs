import path from 'node:path';
import { getFirstSentence, stripExtendedPrefix } from './common.mjs';

const TOOL_ARG_KEYS = [
  'command',
  'file_path',
  'path',
  'pattern',
  'url',
  'query',
  'description',
  'prompt',
];

function getClaudeToolArg(toolInput) {
  if (!toolInput || typeof toolInput !== 'object') return '';
  for (const name of TOOL_ARG_KEYS) {
    const val = toolInput[name];
    if (typeof val === 'string' && val) return val;
  }
  for (const val of Object.values(toolInput)) {
    if (typeof val === 'string') return val;
  }
  return '';
}

function convertToClaudeResultText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  const parts = [];
  for (const item of content) {
    if (item && item.type === 'text') {
      parts.push(item.text == null ? '' : String(item.text));
    }
  }
  return parts.join('\n');
}

export function parseClaudeLines(lines) {
  const entries = [];
  const toolById = new Map();

  for (const line of lines) {
    if (!line || !line.trim()) continue;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    if (!o || (o.type !== 'user' && o.type !== 'assistant') || o.isMeta || !o.message) continue;
    const ts = o.timestamp ?? null;
    const content = o.message.content;
    if (typeof content === 'string') {
      entries.push({ role: o.type, text: content, ts });
      continue;
    }
    if (!Array.isArray(content)) continue;

    const textParts = [];
    const tools = [];
    for (const part of content) {
      if (!part) continue;
      switch (part.type) {
        case 'text':
          textParts.push(part.text == null ? '' : String(part.text));
          break;
        case 'tool_use': {
          const t = {
            role: 'tool',
            text: '',
            ts,
            tool: {
              name: part.name ?? '',
              arg: getClaudeToolArg(part.input),
              output: '',
            },
          };
          if (part.id != null) toolById.set(part.id, t);
          tools.push(t);
          break;
        }
        case 'tool_result':
          if (part.tool_use_id != null && toolById.has(part.tool_use_id)) {
            toolById.get(part.tool_use_id).tool.output = convertToClaudeResultText(part.content);
          }
          break;
        default:
          break;
      }
    }
    if (textParts.length > 0) {
      entries.push({ role: o.type, text: textParts.join('\n'), ts });
    }
    for (const t of tools) entries.push(t);
  }
  return entries;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function parseClaudeMeta(lines, file) {
  const fileStem = path.basename(file, '.jsonl');
  let id = UUID_RE.test(fileStem) ? fileStem : null;
  let cwd = null;
  let customTitle = null;
  let aiTitle = null;
  let firstUserText = null;

  for (const line of lines) {
    if (!line || !line.trim()) continue;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    if (!o) continue;
    if (!id && typeof o.sessionId === 'string' && o.sessionId) id = o.sessionId;
    if (!cwd && typeof o.cwd === 'string' && o.cwd) cwd = stripExtendedPrefix(o.cwd);
    if (o.type === 'custom-title') {
      const t = o.customTitle ?? o.title;
      if (typeof t === 'string' && t.trim()) customTitle = t.trim();
    } else if (o.type === 'ai-title') {
      const t = o.aiTitle ?? o.title;
      if (typeof t === 'string' && t.trim()) aiTitle = t.trim();
    } else if (o.type === 'user' && !o.isMeta && o.message && firstUserText === null) {
      const c = o.message.content;
      if (typeof c === 'string' && c.trim()) {
        firstUserText = c;
      } else if (Array.isArray(c)) {
        const joined = c
          .filter((p) => p && p.type === 'text' && p.text)
          .map((p) => String(p.text))
          .join('\n');
        if (joined.trim()) firstUserText = joined;
      }
    }
  }

  if (!id) id = path.basename(file, '.jsonl');
  const title = customTitle || aiTitle || getFirstSentence(firstUserText) || id;
  return { id, title, cwd };
}
