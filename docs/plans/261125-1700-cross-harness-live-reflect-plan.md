# Cross-harness live reflect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an open chat in any harness read the latest turns of a chat in another harness (MCP bridge), keep a live Markdown mirror of up to 5 pinned chats with a "Reflect to X" button, and optionally re-import a pinned Claude Code chat into Codex when it grows.

**Architecture:** A dependency-free Node MCP server (`mcp/harness-transcripts/`) reads the three harnesses' transcript files read-only and redacts everything it returns. The PowerShell switcher gets three new units: MCP registration (through each app's own CLI or a backed-up JSON edit), a live mirror (FileSystemWatcher, debounce, `ConvertTo-HandoffMarkdown`), and a re-import path that reuses `Import-CodexExternalClaude`. Both sides read the same fixtures, and a parity test keeps their entry lists equal.

**Tech Stack:** Node ≥ 22.15 (ESM, built-in modules only, `node --test`), Windows PowerShell 5.1 + WinForms, repo test style (`tests\*.Tests.ps1`, `_TestHelper.ps1` `Import-TestFunctions` + `Assert`).

**Spec:** `docs/specs/261125-1600-cross-harness-live-reflect-spec.md` (approved by the owner 2026-11-25). Research: `docs/reports/261125-1530-cross-harness-session-sync-agy.md`.

## Global Constraints

- PowerShell source is ASCII; logic files ≤ 500 lines, UI files ≤ 800, functions ≤ 100 lines. `src\Harness.Core.ps1` is at 500 and `src\Harness.Codex.Chats.ps1` at 458: new code goes in new files.
- The switcher gets no new dependency. Node is needed only for the MCP bridge; mirror and Codex re-import work without Node.
- Node: built-in modules only (`fs`, `path`, `readline`, `zlib`, `os`), no npm install, no MCP SDK. Minimum version 22.15 (for `zlib.zstdDecompressSync`).
- The MCP server never writes files, never opens a network port, logs only to stderr, and reads only the roots of spec 4.2: `HT_CLAUDE_HOME` (default `%USERPROFILE%\.claude`), `HT_CODEX_HOMES` (`;`-separated; default `%USERPROFILE%\.codex` plus every `%USERPROFILE%\.codex-profiles\*\` that has `sessions`), `HT_AGY_HOME` (default `%USERPROFILE%\.gemini\antigravity`). It never reads `auth.json`, `.credentials.json` or Credential Manager.
- Every string the MCP server returns and every mirror file is redacted with the same patterns as `Get-SecretPatterns` (`src\Harness.Core.ps1:337`), redacting before truncating.
- Server name `harness-transcripts`; tools `list_sessions`, `read_session_tail`, `search_sessions`.
- `~\.claude.json` is never parsed or rewritten by our code (duplicate keys on the owner's machine); Claude registration goes only through `claude mcp add-json ... --scope user` / `claude mcp remove ... --scope user`.
- Codex import sends only `itemType = 'SESSIONS'`, never other item types.
- Never write the owner's email, personal paths, drive letters or tokens into the repo or tests; fixtures use synthetic paths such as `C:\work\demo`.
- Defaults (spec 9): 5 pins max; mirror debounce 2 s; Codex re-import after 60 s quiet; `read_session_tail` 10 turns / max 50, no tool output by default, `maxChars` 20000 / max 100000; list/search scan the newest 500 files per harness; search reads at most 64 MB per call; tool output cut at 2048 chars; mirror tail window 8 MB for sources over 50 MB; retry after an import error no sooner than 5 min.
- Spike rules: spikes touch only test profiles, copies or temp folders, never the Default profile's data, and never open UI on the owner's desktop without saying so.

## Review Focus

- A transcript whose last line is half written (app still appending): readers on both sides skip the broken last line without throwing and return every complete entry. Tests: Task 2 (`partial last line`), Task 6 (`mirror skips partial last line`).
- A very large transcript (hundreds of MB): `read_session_tail` reads only a bounded tail window, never the whole file. Test: Task 3 (`tail window bounded`).
- `cwd` values that differ only in case, a trailing `\`, `/` separators or a `\\?\` prefix (Codex `session_meta`) match in `list_sessions -cwd`. Test: Task 3 (`cwd filter normalizes`).
- Registration when the server path contains spaces and backslashes: the JSON given to `claude mcp add-json`, the `codex mcp add` argv and `mcp_config.json` all hold the exact path. Test: Task 5 (`path with spaces`).
- A pinned source deleted, or unpinned, while a debounced export is pending: no exception; the row shows "source missing" or simply disappears. Test: Task 6 (`deleted or unpinned while pending`).

---

## Lanes and order

- Task 0 is a stop point: its results may change the copy in Task 5 and Task 8.
- Node track: Tasks 1 → 2 → 3 → 4 (one lane, files under `mcp/` and the parity test).
- PowerShell track: Tasks 5, 6 and 7 are independent of each other and of the Node track (separate files).
- Task 8 (UI and wiring) needs Tasks 5, 6 and 7 landed.

### Task 0: Spikes R-S1, R-S2, R-S3

**Files:**
- Create: `tools/spikes/Spike-R1-McpHotLoad.md` (manual checklist + results), `tools/spikes/Spike-R2-CodexSidebarRefresh.ps1`
- Modify: `docs/specs/261111-1200-multi-harness-spike-results.md` (append section "R-S1..R-S3", dated)

**Interfaces:**
- Produces: three recorded answers used as copy in Task 5 (`Get-McpRegisterNote`) and Task 8: per app, "new chats only" / "restart app X"; Codex sidebar "instant / on focus / restart"; whether registration needs an absolute `node.exe` path.

- [ ] **Step 1: R-S3 first (cheapest).** Register a throwaway stdio server `node -e "process.stdin.on('data',()=>{}); console.error(process.cwd(), process.env.PATH.split(';').length)"` under the name `ht-spike` in a Codex test profile (`codex mcp add` with that profile's `CODEX_HOME`) and in a Claude test via `claude mcp add-json ht-spike ... --scope project` inside a temp folder (never user scope). Record cwd and whether bare `node` resolved. Remove both.
- [ ] **Step 2: R-S1.** With the same throwaway server, record for each app whether a chat started after registration sees it while the app keeps running, and whether an already open chat does. Antigravity: only if a test profile exists (fake home, spike S4 method); otherwise record "not tested" — do not edit the real `mcp_config.json`.
- [ ] **Step 3: R-S2.** In a Codex test profile with the desktop app open, run `Import-CodexExternalClaude` on a copied Claude session; record when the thread appears in the sidebar (instantly / after window focus / after restart).
- [ ] **Step 4: Write results and stop.** Append the three answers to the spike-results file and send them to the coordinator. If R-S3 says bare `node` fails, Task 5 registers the absolute path from `(Get-Command node).Source`.
- [ ] **Step 5: Commit**

```bash
git add tools/spikes/Spike-R1-McpHotLoad.md tools/spikes/Spike-R2-CodexSidebarRefresh.ps1 docs/specs/261111-1200-multi-harness-spike-results.md
git commit -m "test(spike): R-S1..R-S3 MCP hot load, Codex sidebar refresh, node path"
```

### Task 1: Redaction in Node with shared samples

**Files:**
- Create: `tests/fixtures/xharness/secret-samples.json`, `mcp/harness-transcripts/redact.mjs`, `mcp/harness-transcripts/test/redact.test.mjs`, `tests/XharnessParity.Tests.ps1`

**Interfaces:**
- Produces: `export function redact(text: string): string` (null/empty returns as is) in `redact.mjs`; `secret-samples.json` = array of `{ "in": string, "out": string }`; `tests/XharnessParity.Tests.ps1` with a helper `Invoke-NodeDump -Args <string[]>` returning stdout (used again in Task 2).

- [ ] **Step 1: Write the samples.** At least one case per pattern of `Get-SecretPatterns` (PEM block, `sk-`, `ghp_`, `github_pat_`, `AKIA`, `xoxb-`, `AIza`, `Bearer`, `NAME_TOKEN=...` line start and mid line, JSON `"password": "x"`, `--api-key=x`), plus two negatives (plain prose, already `[REDACTED]`). `out` is what `Protect-TranscriptText` returns today.
- [ ] **Step 2: Write the failing tests.**

```js
// redact.test.mjs
test('matches every PowerShell sample', () => {
  for (const s of samples) assert.equal(redact(s.in), s.out, s.in);
});
test('empty and null pass through', () => { assert.equal(redact(''), ''); assert.equal(redact(null), null); });
```

```powershell
# XharnessParity.Tests.ps1 (secret part)
foreach ($s in $samples) { Assert ((Protect-TranscriptText $s.in) -ceq $s.out) "PS sample: $($s.in)" }
```

- [ ] **Step 3: Run to see them fail.** `node --test mcp/harness-transcripts/test/` → FAIL (module missing). The PowerShell part passes already: it pins the samples to today's behaviour.
- [ ] **Step 4: Implement `redact`** by porting each `Get-SecretPatterns` regex in the same order with flag `i` (and `s` for the PEM block, `m` for the line-start rule). PowerShell's inline `(?-i:...)` has no JS equivalent: write those character classes case-sensitively as `[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*` in a separate regex without `i`. `${pre}` becomes `$<pre>`.
- [ ] **Step 5: Run both.** `node --test mcp/harness-transcripts/test/` → PASS; `powershell -NoProfile -ExecutionPolicy Bypass -File tests\XharnessParity.Tests.ps1` → `XharnessParity: OK`.
- [ ] **Step 6: Commit** `feat(mcp): redact() in Node, pinned to the PowerShell secret patterns`.

### Task 2: Transcript readers in Node and entry parity

**Files:**
- Create: `mcp/harness-transcripts/readers/claude.mjs`, `readers/codex.mjs`, `readers/antigravity.mjs`, `readers/common.mjs`, `mcp/harness-transcripts/dump.mjs`, `mcp/harness-transcripts/test/readers.test.mjs`
- Create fixtures: `tests/fixtures/xharness/claude-session.jsonl`, `codex-rollout.jsonl`, `codex-rollout.jsonl.zst`, `agy-transcript.jsonl` (synthetic, each with: two user turns, one assistant reply with a tool call and its result, one thinking block, one system message, one Vietnamese line with diacritics, CRLF in one file, a UTF-8 BOM in one file, and a half-written last line)
- Modify: `tests/XharnessParity.Tests.ps1`

**Interfaces:**
- Consumes: `redact` (Task 1).
- Produces:
  - `export async function readEntries(harness: 'claude'|'codex'|'antigravity', file: string, opts?: { tailBytes?: number }): Promise<Entry[]>` in `readers/common.mjs`, where `Entry = { role: 'user'|'assistant'|'tool', text: string, ts: string|null, tool?: { name, arg, output } }`, not yet redacted.
  - `export async function readMeta(harness, file): Promise<{ id, title, cwd, lastActivity, sizeBytes }>` in the same file.
  - `dump.mjs`: `node dump.mjs <harness> <file>` prints `JSON.stringify(entries.map(e => ({ role, text: redact(text), tool: e.tool?.name ?? null })))`. Test-only. (Spec 7 says `server.mjs --dump`; a separate file keeps test modes out of the server.)
- Reader rules mirror PowerShell: Claude as `ConvertFrom-ClaudeJsonl`; Codex as `ConvertFrom-CodexRollout` and `Test-CodexSystemMessage` (same prefix list); Antigravity as `ConvertFrom-AgyTranscriptJsonl` and `Get-AgySystemStepTypes` (`SYSTEM_MESSAGE`, `CHECKPOINT`, `CONVERSATION_HISTORY`, `ERROR_MESSAGE`). Thinking blocks are dropped everywhere. Lines that fail `JSON.parse` are skipped.
- With `tailBytes`, the reader opens the file, reads only the last `tailBytes`, and drops the first (cut) line.

- [ ] **Step 1: Write the failing Node tests.** `partial last line` (each fixture: no throw, last complete entry present, count equals the expected number written next to the fixture), `drops thinking and system`, `keeps Vietnamese text intact`, `BOM and CRLF`, `zst equals plain` (`readEntries('codex', zst)` deep-equals the `.jsonl` result), `meta` (`readMeta` returns the fixture's id, cwd and title).
- [ ] **Step 2: Write the failing parity test** in `XharnessParity.Tests.ps1`: for each fixture, PowerShell entries (via the existing readers, then `Protect-TranscriptEntries`) projected to `{role, text, tool name}` equal `Invoke-NodeDump`'s list. Skip with `Write-Output 'XharnessParity: node not found, entry parity skipped'` when `node` is absent or older than 22.15.
- [ ] **Step 3: Run to see them fail.** `node --test mcp/harness-transcripts/test/` → FAIL; parity test → FAIL (dump.mjs missing).
- [ ] **Step 4: Implement the readers and `dump.mjs`.** Stream lines with `readline` (strip a leading BOM); `.zst` through `zlib.zstdDecompressSync` on the whole file.
- [ ] **Step 5: Run both suites** → PASS, parity test prints `XharnessParity: OK`.
- [ ] **Step 6: Commit** `feat(mcp): transcript readers for Claude, Codex and Antigravity with PowerShell parity`.

### Task 3: Session index and the three tools

**Files:**
- Create: `mcp/harness-transcripts/sessions.mjs`, `mcp/harness-transcripts/tools.mjs`, `mcp/harness-transcripts/test/tools.test.mjs`

**Interfaces:**
- Consumes: `readEntries`, `readMeta`, `redact`.
- Produces:
  - `export function getRoots(env = process.env): { claude: string, codex: string[], antigravity: string }` (defaults from Global Constraints).
  - `export async function listSessions(roots, { harness?, cwd?, limit = 20 }): Promise<SessionInfo[]>`, `SessionInfo = { harness, id, title, cwd, lastActivity, sizeBytes, unreadable? }`, sorted by `lastActivity` descending, newest 500 files per harness, `limit` clamped to 1..100.
  - `export async function readSessionTail(roots, { harness, id, turns = 10, includeTools = false, maxChars = 20000 }): Promise<string>`.
  - `export async function searchSessions(roots, { query, harness?, limit = 10 }): Promise<{ results: { harness, id, title, snippets: string[] }[], truncated: boolean }>`.
  - `export const TOOL_DEFS` (name, description, inputSchema for the three tools) and `export async function callTool(name, args, roots): Promise<string>` (JSON text for list/search, Markdown for tail).
  - Errors are thrown as `Error` with `code` = `invalid-id` | `not-found` | `invalid-args`.
- `id` rules: claude/codex/antigravity ids must be uuids (`/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i`); the resolved file must start with the harness root (`path.resolve`, case-insensitive compare).
- Tail Markdown: same layout as the "Recent turns" part of `ConvertTo-HandoffMarkdown` (`### user`, `### assistant`, tool lines `` - tool `name`: arg `` with output in `~~~`, output cut at 2048 chars), redacted before any cut; when over `maxChars`, drop whole turns from the start and begin with `[... N earlier turns cut]`. Read with `tailBytes = 16 MB` (`TAIL_BYTES`, exported so the test can lower it).
- Metadata cache: a `Map` keyed by `path|size|mtimeMs`.

- [ ] **Step 1: Write the failing tests** against a temp tree built from the Task 2 fixtures (`HT_*` env pointed at `os.tmpdir()` folders):
  - `list sorts and limits` (3 sessions, `limit: 2` → 2 newest);
  - `cwd filter normalizes` (`C:\\Work\\Demo\\`, `c:/work/demo`, `\\\\?\\C:\\work\\demo` all match a session with cwd `C:\work\demo`);
  - `tail turns and tools` (`turns: 1` → only the last turn; `includeTools: false` → no `~~~`);
  - `tail redacts before cut` (a secret straddling the 2048 boundary never appears in clear);
  - `tail window bounded` (a 5 MB file with `TAIL_BYTES` lowered to 64 KB still returns the last turn and reads ≤ 64 KB, checked by spying `fs.promises.open` read length);
  - `invalid id and traversal` (`../x`, a non-uuid, a uuid whose file is outside the root → `invalid-id`);
  - `search snippets and cap` (≤ 3 snippets of ≤ 200 chars; `truncated: true` when the 64 MB cap, lowered for the test, is hit; query shorter than 3 chars → `invalid-args`).
- [ ] **Step 2: Run** `node --test mcp/harness-transcripts/test/` → FAIL.
- [ ] **Step 3: Implement `sessions.mjs` and `tools.mjs`.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mcp): list, tail and search over the three harnesses' transcripts`.

### Task 4: MCP stdio server and gate step

**Files:**
- Create: `mcp/harness-transcripts/server.mjs`, `mcp/harness-transcripts/test/server.test.mjs`, `mcp/harness-transcripts/README.md` (run command, env vars, tools — needed by whoever registers it by hand)
- Modify: `tools/Invoke-Gate.ps1` (add a `== node --test` step after the PowerShell suites)

**Interfaces:**
- Consumes: `TOOL_DEFS`, `callTool`, `getRoots`.
- Produces: `node mcp/harness-transcripts/server.mjs` speaking newline-delimited JSON-RPC 2.0 on stdio. Handles `initialize` (reply `protocolVersion` = the client's requested version if it is `2025-06-18` or `2025-03-26`, else `2025-06-18`; `capabilities: { tools: {} }`; `serverInfo: { name: 'harness-transcripts', version: '1.0.0' }`), `notifications/initialized` (no reply), `ping`, `tools/list`, `tools/call` (result `{ content: [{ type: 'text', text }] }`; tool errors as `{ content: [...], isError: true }` with the error code in the text), unknown method → JSON-RPC error `-32601`. On startup it checks `process.versions.node` ≥ 22.15 and exits 1 with a stderr message otherwise.

- [ ] **Step 1: Write the failing test** `full session`: spawn the server with `HT_*` pointing at the fixture tree, send `initialize`, `notifications/initialized`, `tools/list` (3 tools named as above), `tools/call list_sessions`, `tools/call read_session_tail` with a bad id (`isError: true`, text contains `invalid-id`), and an unknown method (`-32601`). Assert nothing but JSON-RPC lines arrives on stdout.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement `server.mjs`** with `readline` on stdin; one `process.stdout.write(JSON.stringify(msg) + '\n')` per reply.
- [ ] **Step 4: Run** `node --test mcp/harness-transcripts/test/` → PASS.
- [ ] **Step 5: Add the gate step.** In `Invoke-Gate.ps1`, when `node` exists and is ≥ 22.15, run `node --test mcp/harness-transcripts/test/` and add a failure on non-zero exit; otherwise print `node not found: MCP tests skipped`. Run `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Gate.ps1` → ends with `GATE PASSED`.
- [ ] **Step 6: Commit** `feat(mcp): harness-transcripts stdio server and gate step`.

### Task 5: MCP registration (`src/Harness.McpRegister.ps1`)

**Files:**
- Create: `src/Harness.McpRegister.ps1`, `tests/HarnessMcpRegister.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-WithCodexEnv -Profile -Action` (`src\Harness.Codex.Profiles.ps1:165`), `Get-CodexProfiles`-style profile objects with `CodexHome`, `Write-HarnessLog`, `Protect-TranscriptText` (for stderr shown in the UI). Task 0 answers.
- Produces:
  - `Get-McpServerPath` → absolute path of `mcp\harness-transcripts\server.mjs` next to `$PSScriptRoot` of the running script (single-file build: next to `ClaudeSwitcher.ps1`), or `$null` when missing.
  - `Test-McpNode [-NodeVersion <scriptblock>]` → `@{ Ok = [bool]; Version = [string]; Path = [string]; Reason = [string] }`; Ok only when ≥ 22.15.
  - `Get-McpServerSpec -ServerPath <string> -NodePath <string>` → `@{ command = $NodePath; args = @($ServerPath) }` (`$NodePath` is `node` or the absolute path, per Task 0).
  - `Register-McpClaude -Spec <hashtable> [-Run <scriptblock>]`, `Unregister-McpClaude [-Run]`, `Get-McpClaudeState [-Run]` → `'registered' | 'missing' | 'stale' | 'no-cli'`.
  - `Register-McpCodex -Profile <obj> -Spec <hashtable> [-Run]`, `Unregister-McpCodex -Profile [-Run]`, `Get-McpCodexState -Profile [-Run]` (same states).
  - `Register-McpAgy -Spec <hashtable> [-ConfigPath <string>] [-Now <datetime>]`, `Unregister-McpAgy [-ConfigPath] [-Now]`, `Get-McpAgyState [-ConfigPath]` (same states minus `no-cli`, plus `'bad-json'`).
  - `Get-McpRegisterNote -Target 'claude'|'codex'|'antigravity'` → the user-facing line from Task 0 (e.g. "Open a new chat to use it" or "Restart <app> to use it").
  - `-Run` is `{ param([string]$Exe, [string[]]$ArgList) ... }` returning `@{ ExitCode; StdOut; StdErr }`; the default starts the process with `ArgumentList` (no string concatenation). Test doubles record the calls.
- Exact commands: `claude mcp add-json harness-transcripts <json> --scope user`, `claude mcp remove harness-transcripts --scope user`, `claude mcp get harness-transcripts`; `codex mcp add harness-transcripts -- <command> <args...>`, `codex mcp remove harness-transcripts`, `codex mcp get harness-transcripts` (inside `Invoke-WithCodexEnv`). `<json>` = `ConvertTo-Json -Compress` of `@{ type = 'stdio'; command; args }`. State `stale` = registered but the path in `get` output is not the current `server.mjs`.
- Antigravity: read `mcp_config.json` with `ConvertFrom-Json`; set or remove only `mcpServers.harness-transcripts` (value `@{ command; args }`); before writing copy to `mcp_config.json.bak-<yyMMdd-HHmmss>` (from `-Now`); write UTF-8 without BOM to a tmp file in the same folder, then `[IO.File]::Replace`. Unparseable JSON → throw `bad-json: <path>` without writing. Missing file → create `{ "mcpServers": { ... } }` (no backup).

- [ ] **Step 1: Write the failing tests.**
  - `claude add-json argv`: recorded call is `claude` with `@('mcp','add-json','harness-transcripts', <json>, '--scope','user')` and `<json>` round-trips through `ConvertFrom-Json` to the spec.
  - `path with spaces`: server path `C:\x y\mcp\harness-transcripts\server.mjs` appears byte-exact in the Claude JSON (after parse), in the Codex argv element, and in `mcp_config.json` after a round trip.
  - `codex add uses profile env`: the `-Run` double sees `$env:CODEX_HOME` = the profile's `CodexHome` during the call and the old value after.
  - `agy keeps other servers`: a config with two other servers keeps both, byte-identical values, after register then unregister; one `.bak-` file per write, named from `-Now`.
  - `agy bad json`: throws `bad-json`, file unchanged, no backup.
  - `states`: `missing` / `registered` / `stale` / `no-cli` from canned `get` outputs and an `-Run` that throws "not found".
  - `node check`: `v22.14.0` → Ok false, `v22.15.0` and `v24.22.1` → Ok true.
- [ ] **Step 2: Run** `powershell -NoProfile -ExecutionPolicy Bypass -File tests\HarnessMcpRegister.Tests.ps1` → FAIL.
- [ ] **Step 3: Implement** the functions above.
- [ ] **Step 4: Run** → `HarnessMcpRegister: OK`.
- [ ] **Step 5: Commit** `feat(harness): register the harness-transcripts MCP server in Claude, Codex and Antigravity`.

### Task 6: Live mirror core (`src/Harness.Mirror.ps1`)

**Files:**
- Create: `src/Harness.Mirror.ps1`, `tests/HarnessMirror.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertFrom-ClaudeJsonl -Path`, `Get-CodexTranscriptEntries -Chat`, `ConvertFrom-AgyTranscriptJsonl -Path`, `ConvertTo-HandoffMarkdown -Entries -Harness -Title -Cwd -KeepTurns 40`, `Find-ClaudeProjectDir`, `Resolve-CodexRolloutFile`, `$script:SwitcherHome`.
- Produces (no WinForms in this file):
  - `Get-MirrorDir` → `Join-Path $script:SwitcherHome 'live-mirror'`.
  - `Read-MirrorPins [-Dir]` / `Write-MirrorPins -Pins <array> [-Dir]` on `pins.json`; a pin is `[pscustomobject]@{ harness; id; profileId; title; cwd; sourcePath; mirrorPath; codexSync = $false; codexProfileId = $null; lastSize = 0; lastTicks = 0; state = 'ok' }`. Atomic write (tmp + Replace).
  - `Resolve-MirrorSource -Harness <string> -Chat <obj>` → absolute source file (Claude: `<project dir>\<cliSessionId>.jsonl`; Codex: rollout file; Antigravity: `brain\<id>\.system_generated\logs\transcript.jsonl`), or `$null` when it does not exist (Antigravity chats without transcript cannot be pinned).
  - `Add-MirrorPin -Harness -Chat [-Dir]` → the new pin, or throws `pin-limit` (more than 5) / `no-source` / `already-pinned`. `Remove-MirrorPin -Harness -Id [-Dir]` (keeps the `.md`).
  - `Export-MirrorPin -Pin <obj> [-Now <datetime>]` → `'written' | 'unchanged' | 'missing'`; skips when `(size, LastWriteTimeUtc.Ticks)` equals `lastSize/lastTicks`; Codex pins read through `Get-CodexTranscriptEntries -Chat ([pscustomobject]@{ RolloutPath = $Pin.sourcePath })`; plain-text sources (not `.zst`) over 50 MB read only the last 8 MB (drop the first cut line) and the file says so in its header; first line of the `.md` is `<!-- live mirror, updated <ISO time> -->`; writes `<harness>-<id>.md` atomically; updates `lastSize/lastTicks/state` on the pin object.
  - `New-MirrorQueue` → `@{ Pending = @{}; DelayMs = 2000 }`; `Add-MirrorEvent -Queue -Key <harness:id> -Now <datetime>`; `Get-MirrorDue -Queue -Now <datetime>` → keys whose last event is ≥ `DelayMs` old, removed from `Pending`. (Pure; Task 8 drives it from a WinForms timer.)
  - `New-MirrorHandoffPrompt -Pin <obj>` → exactly: `Read <mirrorPath>. It updates itself after every turn of the <harness> chat "<title>"; read it again when you need newer context. If the harness-transcripts tool is available, call read_session_tail with harness=<harness> id=<id> instead.`

- [ ] **Step 1: Write the failing tests** (temp `SwitcherHome`, fixtures from Task 2 copied in; the Codex path uses a `-ZstEntries` stub where needed):
  - `pin and unpin` (round trip through `pins.json`; `.md` kept after unpin);
  - `pin limit` (6th → `pin-limit`), `already pinned`, `no source`;
  - `debounce` (3 events within 1 s for one key → `Get-MirrorDue` empty at +1.9 s, one key at +2.0 s);
  - `unchanged skip` (second `Export-MirrorPin` without a file change → `unchanged`, `.md` mtime unchanged);
  - `mirror skips partial last line` (append half a JSON line → export still `written`, contains the last complete turn);
  - `big source tail` (a 51 MB synthetic Claude file → `.md` header says only the tail was read, export reads ≤ 8 MB + one line);
  - `deleted or unpinned while pending` (source deleted after `Add-MirrorEvent` → `Export-MirrorPin` returns `missing`, `state = 'missing'`, no throw; a key whose pin was removed is ignored by the caller helper `Invoke-MirrorDue -Queue -Pins -Now` without throwing);
  - `redacted` (a fixture secret never appears in the `.md`);
  - `prompt text` equals the exact string above.
- [ ] **Step 2: Run** `powershell -NoProfile -ExecutionPolicy Bypass -File tests\HarnessMirror.Tests.ps1` → FAIL.
- [ ] **Step 3: Implement** the functions above, plus `Invoke-MirrorDue -Queue -Pins -Now` → list of `@{ Key; Result }` (exports each due pin that still exists).
- [ ] **Step 4: Run** → `HarnessMirror: OK`.
- [ ] **Step 5: Commit** `feat(harness): live mirror core for pinned chats`.

### Task 7: Codex re-import from a source jsonl and the `skipped` status

**Files:**
- Create: `src/Harness.Codex.ExternalImport.ps1` (move `Get-CodexNormalPath`, `Get-CodexExternalImportRecord`, `Select-CodexDetectedSession`, `Import-CodexExternalClaude` here from `src\Harness.Codex.Chats.ps1:356-431`, unchanged except below)
- Modify: `src/Harness.Codex.Chats.ps1` (remove the moved functions), any test that loads them by file through `Import-TestFunctions` (add the new file to `-Files`), and `Get-StorageScanFunctionNames`-style function lists if they name the moved functions (grep first)
- Test: `tests/HarnessCodexChats.Tests.ps1`

**Interfaces:**
- Produces: `Import-CodexExternalClaude [-BundlePath <string>] [-SourceJsonl <string>] -Profile <obj> [-ClaudeHome] [-StartServer] [-TimeoutSec]` — exactly one of `-BundlePath` / `-SourceJsonl` (else throw `bundle-or-source`). Returns `@{ Status = 'imported'|'exists'|'not-detected'|'skipped'; ThreadId }`. `skipped` replaces today's `throw 'Codex reported no result for the session.'` (every `itemTypeResults` entry has neither successes nor failures, or the list is empty). With `-SourceJsonl`, `maxSessionAgeDays` = max(30, days since the file's `LastWriteTimeUtc` + 2).
- `Invoke-HarnessImport` (`src\Ui.Harness.ps1`) keeps working: `skipped` falls back to the handoff path like `not-detected`.

- [ ] **Step 1: Move the functions** with no other change; run `tests\HarnessCodexChats.Tests.ps1` and `tests\ChatTransfer.Tests.ps1` → both still OK (pure move).
- [ ] **Step 2: Write the failing tests** with the existing fake app-server pattern: `source jsonl imports` (no bundle, `-SourceJsonl` path → `imported`, detect request carries `includeHome = $true`); `empty result is skipped` (completed notification with `itemTypeResults = @(@{ successes = @(); failures = @() })` → `skipped`, no throw); `bundle or source` (both or neither → `bundle-or-source`); `only SESSIONS sent` (the import request's `migrationItems` all have `itemType = 'SESSIONS'`); `transfer falls back on skipped` (`Invoke-HarnessImport` with an adapter returning `skipped` → `Status = 'handoff'`).
- [ ] **Step 3: Run** → FAIL.
- [ ] **Step 4: Implement** the parameter set and the `skipped` mapping; in `Invoke-HarnessImport` treat `skipped` like `not-detected`.
- [ ] **Step 5: Run** both test files → OK; `src\Harness.Codex.Chats.ps1` and the new file each ≤ 500 lines.
- [ ] **Step 6: Commit** `feat(codex): re-import a Claude session from its jsonl and report Codex's silent skip`.

### Task 8: UI and wiring (`src/Ui.Mirror.ps1`)

**Files:**
- Create: `src/Ui.Mirror.ps1`, `tests/HarnessUiMirror.Tests.ps1`
- Modify: `src/Ui.MainChats.ps1` (context menu on the chat list and a status column), the switcher start-up path that builds the Harness tab (call `Start-MirrorService` once; grep for where `New-HarnessChatPanel` is first called), `tools/Build-SingleFile.ps1` only if it must copy `mcp\` next to the built file (check how `dist` is used first; if the single file is never shipped without the repo, leave it and rely on `Get-McpServerPath` returning `$null`)

**Interfaces:**
- Consumes: everything Task 5, 6 and 7 produce; `Start-HarnessHandoff`-style handoff routes per target (`Start-CodexHandoff` deep link for Codex Default, clipboard otherwise; Claude deep link for Default; Antigravity clipboard); `Get-HarnessTransferTargets`; Task 0 copy via `Get-McpRegisterNote`.
- Produces:
  - `Start-MirrorService -Form <Form>`: loads pins, one `FileSystemWatcher` per pin (parent folder, `Filter` = file name, `NotifyFilter = LastWrite, Size`, `InternalBufferSize = 65536`), events only call `Add-MirrorEvent` under a lock; a `System.Windows.Forms.Timer` (500 ms) calls `Invoke-MirrorDue` on the UI thread; `Error` event → re-export every pin once. Exports every pin once at start.
  - `Stop-MirrorService`, `Update-MirrorWatchers` (after pin/unpin).
  - Chat list context menu items: "Pin for live mirror" / "Unpin", "Reflect to ▸" (one item per `Get-HarnessTransferTargets` entry of another harness; runs the target's handoff with `New-MirrorHandoffPrompt` as the prompt), "Sync to Codex" (checked state; Claude pins only; asks for the Codex profile when there is more than one), "Open mirror file".
  - A "Mirror" column in the chat list: empty for unpinned chats; else one of `Live, updated HH:mm`, `Source missing`, `Synced to Codex HH:mm`, `Codex skipped: close the thread in Codex or stop chatting there, then retry`, `Codex did not detect the session (folder gone?)`, or the error text.
  - Codex sync: after an export of a pin with `codexSync`, schedule an import when the source has been quiet for 60 s; run it in a background runspace/job (one per Codex profile at a time); after an error wait ≥ 5 min before the next try.
  - "MCP bridge…" button on the Harness tab: dialog listing each target (Claude, every Codex profile, Antigravity) with its state from Task 5, checkboxes, the files/commands that will change, the `Get-McpRegisterNote` line, and Register / Remove buttons. Disabled with the reason when `Test-McpNode` fails or `Get-McpServerPath` is `$null`.
  - All user-facing strings above are English, like the rest of the UI.

- [ ] **Step 1: Write the failing tests** for the non-WinForms helpers this file exposes: `Get-MirrorStatusText -Pin` (each status string above, exact), `Get-ReflectTargets -SourceHarness -Targets` (excludes the source harness), `Test-CodexSyncDue -Pin -LastEventAt -LastErrorAt -Now` (60 s quiet rule, 5 min error backoff), `Get-McpDialogRows -States` (one row per target, disabled reasons).
- [ ] **Step 2: Run** `powershell -NoProfile -ExecutionPolicy Bypass -File tests\HarnessUiMirror.Tests.ps1` → FAIL.
- [ ] **Step 3: Implement** the helpers, then the WinForms parts; `Ui.MainChats.ps1` stays ≤ 800 lines (only the menu hook and the column).
- [ ] **Step 4: Run** the new test plus `tests\HarnessUiMain.Tests.ps1` → OK; full gate `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Gate.ps1` → `GATE PASSED`.
- [ ] **Step 5: Commit** `feat(ui): live mirror pins, Reflect to, Sync to Codex and the MCP bridge dialog`.
- [ ] **Step 6: Owner acceptance (not a worker step).** Run A1–A3 from spec section 7 on the real apps and record the result in the coordinator's ledger.
