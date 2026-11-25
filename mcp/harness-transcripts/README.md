# harness-transcripts

Dependency-free Node.js MCP stdio server for reading recent transcripts across Claude Code, Codex, and Antigravity (read-only, redacted).

## Requirements

- Node.js `>= 22.15.0` (uses built-in `zlib.zstdDecompressSync` and ESM). No `npm install` needed.

## Run

```sh
node mcp/harness-transcripts/server.mjs
```

Logs go only to `stderr`; newline-delimited JSON-RPC 2.0 messages use `stdin`/`stdout`. The server never writes files or opens network ports, and never reads `auth.json`, `.credentials.json`, or Credential Manager.

## Environment Variables

- `HT_CLAUDE_HOME`: overrides `%USERPROFILE%\.claude`
- `HT_CODEX_HOMES`: `;`-separated Codex homes (default: `%USERPROFILE%\.codex` plus any `%USERPROFILE%\.codex-profiles\*\` containing a `sessions` directory)
- `HT_AGY_HOME`: overrides `%USERPROFILE%\.gemini\antigravity`

## Tools

- `list_sessions({ harness?, cwd?, limit? })`: lists sessions sorted by `lastActivity` descending (scans newest 500 files per harness, `limit` 1..100, default 20).
- `read_session_tail({ harness, id, turns?, includeTools?, maxChars? })`: returns redacted Markdown of the last turns (`turns` 1..50 default 10, `includeTools` default false, `maxChars` 1..100000 default 20000).
- `search_sessions({ query, harness?, limit? })`: case-insensitive substring search (`query` length >= 3, up to 3 snippets <= 200 chars per session, 64 MB scan cap per call).

## Tests

```sh
node --test mcp/harness-transcripts/test/redact.test.mjs mcp/harness-transcripts/test/readers.test.mjs mcp/harness-transcripts/test/tools.test.mjs mcp/harness-transcripts/test/server.test.mjs
```
