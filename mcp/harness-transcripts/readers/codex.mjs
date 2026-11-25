import path from 'node:path';
import { getFirstSentence, stripExtendedPrefix } from './common.mjs';

const SYSTEM_PREFIXES = [
  '# AGENTS.md instructions',
  '<INSTRUCTIONS>',
  '<environment_context',
  '<user_instructions',
  '<permissions',
  '<collaboration_mode',
  '<turn_aborted',
  '<skill>',
  '<user_shell_command',
].map((p) => p.toLowerCase());

const TOOL_ARG_KEYS = ['cmd', 'command', 'path', 'query', 'url', 'pattern', 'input'];
const UUID_IN_NAME_RE = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i;

export function testCodexSystemMessage(text) {
  const t = String(text ?? '').trimStart().toLowerCase();
  for (const prefix of SYSTEM_PREFIXES) {
    if (t.startsWith(prefix)) return true;
  }
  return false;
}

function getCodexToolArg(argsText) {
  if (!argsText) return '';
  let obj;
  try {
    obj = JSON.parse(argsText);
  } catch {
    return String(argsText);
  }
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return String(argsText);
  for (const name of TOOL_ARG_KEYS) {
    const val = obj[name];
    if (val) {
      if (Array.isArray(val)) return val.map((x) => String(x)).join(' ');
      return String(val);
    }
  }
  return String(argsText);
}

function convertToCodexToolOutput(output) {
  if (output == null) return '';
  if (typeof output === 'string') return output;
  if (!Array.isArray(output)) return '';
  const parts = [];
  for (const item of output) {
    if (typeof item === 'string') {
      parts.push(item);
    } else if (item && Object.prototype.hasOwnProperty.call(item, 'text')) {
      parts.push(item.text == null ? '' : String(item.text));
    }
  }
  return parts.join('\n');
}

export function parseCodexLines(lines) {
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
    if (!o || o.type !== 'response_item' || !o.payload) continue;
    const p = o.payload;
    const ts = o.timestamp ?? null;
    switch (p.type) {
      case 'message': {
        if (p.role !== 'user' && p.role !== 'assistant') break;
        const text = (Array.isArray(p.content) ? p.content : [])
          .filter((c) => c && c.text)
          .map((c) => String(c.text))
          .join('\n');
        if (!text || (p.role === 'user' && testCodexSystemMessage(text))) break;
        entries.push({ role: p.role, text, ts });
        break;
      }
      case 'function_call':
      case 'custom_tool_call': {
        const arg = p.type === 'function_call' ? getCodexToolArg(p.arguments) : String(p.input ?? '');
        const t = {
          role: 'tool',
          text: '',
          ts,
          tool: { name: p.name ?? '', arg, output: '' },
        };
        if (p.call_id != null) toolById.set(p.call_id, t);
        entries.push(t);
        break;
      }
      case 'function_call_output':
      case 'custom_tool_call_output':
        if (p.call_id != null && toolById.has(p.call_id)) {
          toolById.get(p.call_id).tool.output = convertToCodexToolOutput(p.output);
        }
        break;
      default:
        break;
    }
  }
  return entries;
}

export function parseCodexMeta(lines, file) {
  let id = null;
  let cwd = null;
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
    if (o.type === 'session_meta' && o.payload) {
      if (!id && typeof o.payload.id === 'string' && o.payload.id) id = o.payload.id;
      if (!cwd && typeof o.payload.cwd === 'string' && o.payload.cwd) {
        cwd = stripExtendedPrefix(o.payload.cwd);
      }
    } else if (
      firstUserText === null &&
      o.type === 'response_item' &&
      o.payload?.type === 'message' &&
      o.payload.role === 'user'
    ) {
      const text = (Array.isArray(o.payload.content) ? o.payload.content : [])
        .filter((c) => c && c.text)
        .map((c) => String(c.text))
        .join('\n');
      if (text && !testCodexSystemMessage(text)) firstUserText = text;
    }
  }

  if (!id) {
    const m = UUID_IN_NAME_RE.exec(path.basename(file));
    id = m ? m[1] : path.basename(file).replace(/\.jsonl(\.zst)?$/i, '');
  }
  const title = getFirstSentence(firstUserText) || id;
  return { id, title, cwd };
}
