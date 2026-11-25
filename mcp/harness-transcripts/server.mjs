import path from 'node:path';
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';
import { redact } from './redact.mjs';
import { getRoots } from './sessions.mjs';
import { TOOL_DEFS, callTool } from './tools.mjs';

const SUPPORTED_PROTOCOL_VERSIONS = new Set(['2025-06-18', '2025-03-26']);
const SERVER_INFO = { name: 'harness-transcripts', version: '1.0.0' };

export function isNodeVersionSupported(version = process.versions.node) {
  const m = /^v?(\d+)\.(\d+)/.exec(String(version ?? ''));
  if (!m) return false;
  const major = Number(m[1]);
  const minor = Number(m[2]);
  return major > 22 || (major === 22 && minor >= 15);
}

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function sendResult(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function sendError(id, code, message) {
  send({ jsonrpc: '2.0', id: id ?? null, error: { code, message } });
}

async function handleRequest(msg, roots) {
  const { id, method, params } = msg;
  if (method === 'notifications/initialized' || id === undefined) {
    return;
  }

  switch (method) {
    case 'initialize': {
      const requested = params?.protocolVersion;
      const protocolVersion = SUPPORTED_PROTOCOL_VERSIONS.has(requested) ? requested : '2025-06-18';
      sendResult(id, {
        protocolVersion,
        capabilities: { tools: {} },
        serverInfo: SERVER_INFO,
      });
      break;
    }
    case 'ping':
      sendResult(id, {});
      break;
    case 'tools/list':
      sendResult(id, { tools: TOOL_DEFS });
      break;
    case 'tools/call': {
      const name = params?.name;
      const args = params?.arguments ?? {};
      try {
        const text = await callTool(name, args, roots);
        sendResult(id, { content: [{ type: 'text', text }] });
      } catch (err) {
        const code = err?.code || 'error';
        const message = err?.message || String(err);
        sendResult(id, {
          content: [{ type: 'text', text: redact(`${code}: ${message}`) }],
          isError: true,
        });
      }
      break;
    }
    default:
      sendError(id, -32601, `Method not found: ${method}`);
      break;
  }
}

async function main() {
  if (!isNodeVersionSupported()) {
    process.stderr.write(
      `harness-transcripts requires Node.js >= 22.15.0 (found ${process.versions.node})\n`,
    );
    process.exit(1);
  }

  const roots = getRoots();
  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const rawLine of rl) {
    const line = rawLine.trim();
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      sendError(null, -32700, 'Parse error');
      continue;
    }
    if (!msg || typeof msg !== 'object' || typeof msg.method !== 'string') {
      sendError(msg?.id ?? null, -32600, 'Invalid Request');
      continue;
    }
    try {
      await handleRequest(msg, roots);
    } catch (err) {
      process.stderr.write(`Unhandled error for ${msg.method}: ${err?.stack || err}\n`);
      if (msg.id !== undefined) {
        sendError(msg.id, -32603, 'Internal error');
      }
    }
  }
}

const isEntrypoint =
  Boolean(process.argv[1]) &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isEntrypoint) {
  main().catch((err) => {
    process.stderr.write(`Fatal error: ${err?.stack || err}\n`);
    process.exit(1);
  });
}
