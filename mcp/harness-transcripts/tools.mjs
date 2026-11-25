import {
  getRoots,
  listSessions,
  readSessionTail,
  searchSessions,
} from './sessions.mjs';
import { makeError } from './readers/common.mjs';

export const TOOL_DEFS = [
  {
    name: 'list_sessions',
    description:
      'List recent chat sessions across Claude Code, Codex, and Antigravity, sorted by lastActivity descending.',
    inputSchema: {
      type: 'object',
      properties: {
        harness: {
          type: 'string',
          enum: ['claude', 'codex', 'antigravity'],
          description: 'Optional harness filter.',
        },
        cwd: {
          type: 'string',
          description: 'Optional working directory filter (case-insensitive, normalized).',
        },
        limit: {
          type: 'integer',
          minimum: 1,
          maximum: 100,
          default: 20,
          description: 'Maximum number of sessions to return (1-100).',
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'read_session_tail',
    description:
      'Read the most recent redacted turns of a chat session as Markdown.',
    inputSchema: {
      type: 'object',
      required: ['harness', 'id'],
      properties: {
        harness: {
          type: 'string',
          enum: ['claude', 'codex', 'antigravity'],
        },
        id: {
          type: 'string',
          description: 'Session UUID.',
        },
        turns: {
          type: 'integer',
          minimum: 1,
          maximum: 50,
          default: 10,
        },
        includeTools: {
          type: 'boolean',
          default: false,
        },
        maxChars: {
          type: 'integer',
          minimum: 1,
          maximum: 100000,
          default: 20000,
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'search_sessions',
    description:
      'Case-insensitive substring search across recent transcripts (redacted snippets).',
    inputSchema: {
      type: 'object',
      required: ['query'],
      properties: {
        query: {
          type: 'string',
          minLength: 3,
        },
        harness: {
          type: 'string',
          enum: ['claude', 'codex', 'antigravity'],
        },
        limit: {
          type: 'integer',
          minimum: 1,
          maximum: 100,
          default: 10,
        },
      },
      additionalProperties: false,
    },
  },
];

export async function callTool(name, args = {}, roots = getRoots()) {
  const safeArgs = args && typeof args === 'object' ? args : {};
  switch (name) {
    case 'list_sessions':
      return JSON.stringify(await listSessions(roots, safeArgs));
    case 'read_session_tail':
      return await readSessionTail(roots, safeArgs);
    case 'search_sessions':
      return JSON.stringify(await searchSessions(roots, safeArgs));
    default:
      throw makeError('invalid-args', `Unknown tool: ${name}`);
  }
}
