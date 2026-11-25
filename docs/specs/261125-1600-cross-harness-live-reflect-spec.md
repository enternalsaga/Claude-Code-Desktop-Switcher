# Spec: phản chiếu phiên chat giữa các harness gần thời gian thực (MCP bridge, live mirror, đồng bộ lại sang Codex)

- Ngày: 2026-11-25
- Trạng thái: bản nháp, chờ owner duyệt
- Nhánh gốc: `desktop-4.29-patches`
- Nguồn:
  - báo cáo nghiên cứu [261125-1530-cross-harness-session-sync-agy.md](../reports/261125-1530-cross-harness-session-sync-agy.md);
  - spec gốc [261111-1200-multi-harness-manager-and-drive-sync-spec.md](261111-1200-multi-harness-manager-and-drive-sync-spec.md) và kết quả spike [261111-1200-multi-harness-spike-results.md](261111-1200-multi-harness-spike-results.md).

## 1. Vấn đề

Owner chat song song ở nhiều harness (Claude Desktop tab Code, Codex desktop, Antigravity) và muốn harness này thấy được nội dung vừa diễn ra ở harness kia, tự động, gần thời gian thực, **không phải khởi động lại app desktop**.

Hiện app chỉ có chuyển một lần: transfer native cùng loại, handoff Markdown khi khác loại, và import một lần Claude Code → Codex qua importer của Codex (`Import-CodexExternalClaude`, `src/Harness.Codex.Chats.ps1:385`). Sau khi chuyển, hai bên trôi khỏi nhau.

Đã xác minh (báo cáo nghiên cứu, mục 2–3):
- Không có đường ghi native vào Antigravity. Claude Desktop không theo dõi thư mục phiên, nên mọi cách ghi file native từ ngoài đều phải khởi động lại app.
- Importer của Codex chỉ nhận Claude Code và Cursor. Nó nối thêm lượt mới vào thread đã import, nhưng bỏ qua im lặng khi thread đích đang mở, đã chat thêm, đã lưu trữ, hoặc nguồn có `compact_boundary` (openai/codex issue #53403, đang mở).

## 2. Quyết định đã chốt (owner, 2026-11-25)

| Câu hỏi | Quyết định |
|---|---|
| Phạm vi v1 | Cả hai: MCP bridge và live mirror, cùng một bộ lọc secret |
| Ngôn ngữ MCP server | Node.js |
| Đăng ký MCP vào app | Nút tự đăng ký trong switcher, có xác nhận, backup và nút gỡ |
| Importer của Codex | Có, làm tùy chọn phụ: đồng bộ lại phiên Claude Code đã chọn sang Codex |

## 3. Mục tiêu và ngoài phạm vi

**Mục tiêu**
- G1. Một tab **đang mở** ở bất kỳ harness nào gọi được tool MCP để liệt kê và đọc các lượt gần nhất của phiên ở harness khác. Nội dung trễ không quá thời gian app nguồn ghi file (thường dưới 2 giây). Không khởi động lại app, không mở tab mới.
- G2. Owner ghim tối đa 5 phiên trong switcher. Mỗi phiên ghim có một file Markdown tự cập nhật sau mỗi lượt, và nút "Reflect sang X" mở phiên mới ở harness X kèm prompt trỏ tới file đó.
- G3. Với phiên Claude Code đã ghim, tùy chọn "Đồng bộ sang Codex" tự gọi lại importer của Codex khi phiên lớn thêm, và hiện rõ khi Codex bỏ qua.
- G4. Mọi nội dung đi ra (tool MCP, file mirror) đều đã qua bộ lọc secret, cùng bộ pattern với `Get-SecretPatterns`.

**Ngoài phạm vi**
- Ghi native vào kho phiên của Claude hoặc Antigravity; hiện lượt chat của harness khác thành bong bóng chat native.
- Đồng bộ hai chiều tự động, giải quyết xung đột giữa hai bên.
- Chat claude.ai thường (không phải tab Code), Cursor, Gemini CLI.
- Conversation Antigravity không có `transcript.jsonl` (`.pb` cũ, `.db` thiếu transcript): không giải mã protobuf trong v1.
- Bật/tắt setting "Keep imports in sync" của chính Codex desktop.

## 4. Thiết kế

### 4.1 Thành phần

```
                 ┌───────────────────────── switcher (PowerShell 5.1, WinForms) ─────────────────────────┐
                 │ Ui.Harness: ghim phiên, Reflect sang X, Đồng bộ sang Codex, nút Đăng ký/Gỡ MCP        │
                 │ Harness.Mirror.ps1: FileSystemWatcher + debounce → ConvertTo-HandoffMarkdown → .md    │
                 │ Harness.McpRegister.ps1: claude mcp / codex mcp / mcp_config.json của Antigravity     │
                 └─────────────────────────────────────────────────────────────────────────────────────┘
  đọc ~/.claude/projects, ~/.codex*/sessions, ~/.gemini/antigravity/brain        ▲ đăng ký
                                                                                  │
  ┌────────── mcp/harness-transcripts/server.mjs (Node ≥ 22.15, không npm deps) ──┴───────┐
  │ stdio JSON-RPC (MCP): list_sessions, read_session_tail, search_sessions               │
  │ readers/{claude,codex,antigravity}.mjs → entry chuẩn {role,text,ts,tool}              │
  │ redact.mjs (port của Get-SecretPatterns), fixture chung với test PowerShell            │
  └───────────────────────────────────────────────────────────────────────────────────────┘
        ▲ spawn bởi từng app (Claude Code, Codex, Antigravity) khi mở phiên
```

- **MCP server** là tiến trình do app đích tự spawn. Nó không cần switcher đang chạy.
- **Mirror** chạy trong tiến trình switcher, nên chỉ cập nhật khi switcher đang mở (switcher vốn chạy nền ở tray).
- Hai phía có hai bộ đọc (JS cho MCP, PowerShell cho mirror). Đây là trùng lặp có chủ đích, đổi lấy lựa chọn Node của owner. Ràng buộc: cùng một bộ fixture transcript trong `tests/fixtures/xharness/` phải cho ra cùng danh sách entry ở cả hai phía (test parity, mục 7).

### 4.2 MCP server `mcp/harness-transcripts/`

**Vị trí và chạy**
- `mcp/harness-transcripts/server.mjs`, cùng thư mục `readers/` và `redact.mjs`. ESM thuần, chỉ dùng module có sẵn của Node: `fs`, `path`, `readline`, `zlib` (`zstdDecompressSync`, cho rollout `.jsonl.zst`; cần Node ≥ 22.15).
- Không dùng SDK MCP. Server tự cài tối thiểu `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `ping` trên stdio, mỗi message một dòng JSON.
- Log chỉ ra stderr. Không ghi file, không mở cổng mạng.

**Nguồn đọc** (chỉ đọc; đường dẫn lấy từ env, có mặc định):

| Harness | Env | Mặc định | Đọc gì |
|---|---|---|---|
| claude | `HT_CLAUDE_HOME` | `%USERPROFILE%\.claude` | `projects\<slug>\<id>.jsonl` (không đọc thư mục subagent). Tiêu đề lấy từ dòng `custom-title` / `ai-title`, nếu không có thì dùng câu đầu của lượt user đầu tiên |
| codex | `HT_CODEX_HOMES` (`;` ngăn cách) | `%USERPROFILE%\.codex` cộng mọi `%USERPROFILE%\.codex-profiles\*\` có thư mục `sessions` | `sessions\YYYY\MM\DD\rollout-*.jsonl[.zst]`. Dòng `session_meta` cho id và cwd; tiêu đề lấy từ `state_5.sqlite`, nhưng v1 không đọc sqlite mà dùng câu đầu user |
| antigravity | `HT_AGY_HOME` | `%USERPROFILE%\.gemini\antigravity` | `brain\<id>\.system_generated\logs\transcript.jsonl`; tiêu đề lấy từ `brain\<id>\*.md` đầu tiên nếu có. Dòng lỗi thì bỏ qua (spike S5: 1/72 dòng không parse được) |

**Entry chuẩn**: giống PowerShell, `{ role: 'user'|'assistant'|'tool', text, ts, tool?: { name, arg, output } }`. Quy tắc lọc theo đúng bộ đọc PowerShell tương ứng: bỏ system message của Codex (như `Test-CodexSystemMessage`), bỏ step hệ thống của Antigravity (như `Get-AgySystemStepTypes`), bỏ block thinking.

**Tools**

| Tool | Tham số | Trả về |
|---|---|---|
| `list_sessions` | `harness?` (`claude`/`codex`/`antigravity`), `cwd?` (so khớp không phân biệt hoa thường, bỏ `\` cuối), `limit?` (mặc định 20, tối đa 100) | Danh sách xếp theo `lastActivity` giảm dần: `{ harness, id, title, cwd, lastActivity (ISO), sizeBytes }` |
| `read_session_tail` | `harness`, `id`, `turns?` (mặc định 10, tối đa 50), `includeTools?` (mặc định false), `maxChars?` (mặc định 20000, tối đa 100000) | Markdown giống phần "Recent turns" của `ConvertTo-HandoffMarkdown`: mỗi lượt bắt đầu ở một entry user; tool output cắt ở 2048 ký tự; cắt từ đầu nếu vượt `maxChars` và ghi rõ đã cắt |
| `search_sessions` | `query` (≥ 3 ký tự, so khớp chuỗi con không phân biệt hoa thường), `harness?`, `limit?` (mặc định 10) | Các phiên có khớp, mỗi phiên tối đa 3 đoạn trích 200 ký tự quanh chỗ khớp |

- Mọi chuỗi trả ra đều đi qua `redact()`, và redact **trước** khi cắt ngắn (cùng lý do như `ConvertTo-HandoffMarkdown`).
- `id` phải khớp mẫu của harness (uuid cho claude/codex, như `Test-AgyConversationId` cho antigravity). File được mở phải nằm dưới gốc của harness đó sau khi resolve, nếu không thì trả lỗi `invalid-id`. Không có tool nào nhận đường dẫn tự do.
- Phạm vi quét: `list_sessions` và `search_sessions` chỉ xem 500 file mới nhất theo mtime mỗi harness. `search_sessions` đọc tối đa 64 MB tổng mỗi lần gọi rồi dừng, và ghi `truncated: true`.
- Cache trong bộ nhớ theo `(path, size, mtime)` cho metadata, để lần gọi sau rẻ.

### 4.3 Đăng ký MCP vào app (`src/Harness.McpRegister.ps1`)

Tên server: `harness-transcripts`. Lệnh: `node <đường dẫn tuyệt đối tới server.mjs>`. Nút "Đăng ký MCP" trên tab Harness mở hộp xác nhận liệt kê từng đích và file sẽ bị sửa. Owner chọn đích nào thì chỉ đăng ký đích đó.

| Đích | Cách ghi | Lý do |
|---|---|---|
| Claude (tab Code của mọi profile, dùng chung `~\.claude.json`) | `claude mcp add-json harness-transcripts '<json>' --scope user` | `~\.claude.json` trên máy owner có khóa trùng khác hoa thường: `ConvertFrom-Json` của PS 5.1 từ chối, và JSON.parse sẽ làm mất một khóa. Vì vậy **không bao giờ** đọc rồi ghi lại file này; để CLI của Claude tự sửa |
| Codex, từng profile | `codex mcp add harness-transcripts -- node <server.mjs>` chạy với `CODEX_HOME` của profile (qua `Invoke-WithCodexEnv` sẵn có trong `Harness.Codex.Profiles.ps1`) | Codex tự ghi `config.toml`; không tự sửa TOML |
| Antigravity | Sửa `~\.gemini\antigravity\mcp_config.json`: thêm hoặc thay khóa `mcpServers.harness-transcripts`, giữ nguyên các khóa khác. Trước khi ghi, chép backup `mcp_config.json.bak-<yyMMdd-HHmmss>`. Ghi qua file tmp rồi `Replace` | Không có CLI. Nếu file không parse được thì dừng và báo, không ghi |

- **Gỡ**: dùng `claude mcp remove harness-transcripts --scope user`, `codex mcp remove harness-transcripts`, và xóa đúng khóa đó trong `mcp_config.json` (cũng có backup).
- **Trạng thái**: tab Harness hiện từng đích là đã đăng ký, chưa đăng ký, hay đường dẫn đã cũ (khi repo được dời chỗ). Đọc qua `claude mcp get harness-transcripts`, `codex mcp get harness-transcripts`, và khóa trong `mcp_config.json`.
- **Kiểm tra trước khi đăng ký**: `node --version` ≥ 22.15, nếu không thì báo và không ghi. Lệnh `claude` / `codex` phải tìm thấy được; nếu không thì bỏ đích đó và nói lý do.
- App đang chạy thường chỉ nạp MCP cho phiên mới. Spike R-S1 (mục 8) xác nhận từng app; hộp xác nhận ghi đúng kết quả spike ("mở phiên mới để dùng" hoặc "cần khởi động lại app X").

### 4.4 Live mirror (`src/Harness.Mirror.ps1`)

- **Ghim**: trong danh sách chat của tab Harness, menu chuột phải "Ghim để phản chiếu". Tối đa 5 phiên. Danh sách ghim lưu trong `.switcher\live-mirror\pins.json` dạng `[{ harness, id, profileId, sourcePath, mirrorPath, codexSync: false }]`.
- **Theo dõi**: một `FileSystemWatcher` cho mỗi file nguồn đã ghim (thư mục cha, `Filter` = tên file, `NotifyFilter = LastWrite, Size`). Sự kiện được đẩy vào hàng đợi; một `System.Windows.Forms.Timer` trên luồng UI gom lại với debounce 2 giây rồi mới xử lý. Không làm việc nặng trong callback của watcher.
- **Xuất**: dùng bộ đọc sẵn có (`ConvertFrom-ClaudeJsonl`, `Get-CodexTranscriptEntries`, `ConvertFrom-AgyTranscriptJsonl`) rồi `ConvertTo-HandoffMarkdown -KeepTurns 40`. Ghi vào `.switcher\live-mirror\<harness>-<id>.md` qua file tmp + `Replace`. Dòng đầu file ghi thời điểm cập nhật cuối.
- **Hiệu năng**: bỏ qua lượt xuất nếu `(size, mtime)` không đổi so với lần trước. File nguồn lớn hơn 50 MB thì chỉ xuất phần đuôi (đọc 8 MB cuối, bỏ dòng đầu bị cắt dở) và ghi rõ trong file.
- **Reflect sang X**: nút trên phiên đã ghim. Nó gọi đường handoff hiện có của harness đích (deep link với Claude và Codex Default; clipboard với profile phụ và Antigravity), nhưng prompt trỏ tới file mirror sống: "Đọc `<mirrorPath>`; file này tự cập nhật, đọc lại khi cần ngữ cảnh mới hơn. Nếu có tool `harness-transcripts` thì dùng `read_session_tail` với harness=`<h>` id=`<id>`."
- **Bỏ ghim**: dừng watcher, xóa dòng khỏi `pins.json`, giữ lại file `.md` cho đến khi owner xóa.
- Khi switcher khởi động, nó nạp lại `pins.json`, tạo lại watcher và xuất lại một lần.

### 4.5 Đồng bộ lại sang Codex (tùy chọn phụ)

- Chỉ áp dụng cho phiên **claude** đã ghim. Bật bằng checkbox "Đồng bộ sang Codex" và chọn profile Codex đích (mặc định Default). Ghi vào `pins.json` (`codexSync: true`, `codexProfileId`).
- **Kích hoạt**: sau một lượt xuất mirror, nếu file nguồn không đổi thêm trong 60 giây (để không import giữa lúc Claude còn đang viết), chạy importer trong job nền với cùng `Import-CodexExternalClaude` hiện có. Thêm tham số `-SourceJsonl` để không cần bundle: phiên đã ghim có sẵn đường dẫn jsonl.
- **Ánh xạ kết quả**: hàm hiện tại `throw` khi Codex trả về không success cũng không failure (`'Codex reported no result for the session.'`). Đổi thành `Status = 'skipped'`. Đây chính là trường hợp bỏ qua im lặng của Codex (thread đích đang mở, đã chat thêm, đã lưu trữ, hoặc có `compact_boundary`). UI hiện trên dòng phiên ghim:
  - `imported` / `exists`: "Đã đồng bộ lúc HH:mm";
  - `skipped`: "Codex bỏ qua: đóng thread trong Codex hoặc đừng chat tiếp ở đó, rồi thử lại";
  - `not-detected`: "Codex không thấy phiên (cwd không còn?)";
  - lỗi khác: hiện thông điệp lỗi.
- Không bao giờ gửi item type khác `SESSIONS` (giữ nguyên quy tắc hiện có; tránh issue #61683 tạo `AGENTS.md`).
- Không chạy importer khi profile Codex đích đang bị một import khác giữ. Mỗi profile chỉ có một job import tại một thời điểm.
- Sidebar Codex desktop đang mở có thể không hiện ngay thread vừa import từ app-server ngoài (báo cáo mục 1.3, độ tin cậy trung bình). Spike R-S2 kiểm. UI không hứa "hiện ngay".

## 5. Xử lý lỗi

| Tình huống | Xử lý |
|---|---|
| File transcript đang được app ghi dở (dòng cuối chưa xong) | Bộ đọc bỏ dòng cuối không parse được; lần sau đọc lại |
| File nguồn bị xóa hoặc đổi tên | MCP: không còn trong danh sách, `read_session_tail` trả `not-found`. Mirror: watcher báo, dòng ghim chuyển trạng thái "nguồn mất", không xóa file `.md` |
| `.jsonl.zst` mà Node không có `zstdDecompressSync` | Đã chặn ở bước kiểm Node ≥ 22.15. Nếu vẫn thiếu thì bỏ qua file đó, `list_sessions` ghi `unreadable: true` |
| `mcp_config.json` không parse được | Dừng, báo đường dẫn, không ghi |
| `claude` / `codex` CLI lỗi khi đăng ký | Hiện stderr (đã redact), không đánh dấu là đã đăng ký |
| Codex app-server không khởi động hoặc quá thời gian | Trạng thái lỗi trên dòng ghim; thử lại ở lần thay đổi sau, không lặp liên tục (tối thiểu 5 phút giữa hai lần thử sau lỗi) |
| Số watcher vượt giới hạn hoặc buffer tràn (`InternalBufferOverflow`) | Xuất lại toàn bộ phiên ghim một lần |

## 6. Ràng buộc

- PowerShell 5.1, không thêm phụ thuộc cho switcher. Node chỉ cần khi owner bật MCP bridge; mirror và đồng bộ Codex không cần Node.
- Giới hạn kích thước của repo: file logic ≤ 500 dòng, UI ≤ 800, hàm ≤ 100. `Harness.Core.ps1` đã 500 dòng và `Harness.Codex.Chats.ps1` 458 dòng, nên phần mới vào file mới. Riêng thay đổi trong `Import-CodexExternalClaude` (tham số `-SourceJsonl`, trạng thái `skipped`) phải giữ file dưới 500 dòng; nếu vượt thì tách phần import ngoài sang `Harness.Codex.ExternalImport.ps1`.
- Source PowerShell là ASCII. `Build-SingleFile.ps1` gộp `src\*.ps1`. Bản single-file phải biết đường dẫn `mcp\harness-transcripts\server.mjs` nằm cạnh nó, và nút đăng ký báo lỗi rõ nếu không có thư mục này.
- Không ghi email, đường dẫn cá nhân hay token vào repo. MCP server không đọc `auth.json`, `.credentials.json`, Credential Manager hay bất kỳ file nào ngoài các gốc ở mục 4.2.

## 7. Kiểm thử

- **Node** (`node --test mcp/harness-transcripts/test/`):
  - bộ đọc của từng harness trên fixture;
  - redact trên `tests/fixtures/xharness/secret-samples.json`;
  - chặn id sai và path traversal;
  - giới hạn `turns`, `maxChars`, 64 MB;
  - một phiên MCP stdio đầy đủ: `initialize` → `tools/list` → `tools/call`.
- **Parity PowerShell ↔ Node**: test PowerShell chạy bộ đọc PS và `node server.mjs --dump <harness> <file>` (chế độ chỉ dùng cho test) trên cùng fixture, rồi so danh sách entry (role, text sau redact, tên tool). Nếu không có Node thì test bỏ qua và in lý do. Cùng file secret-samples cho `Protect-TranscriptText` và `redact()` ra kết quả giống hệt.
- **PowerShell**:
  - `Harness.Mirror`: ghim/bỏ ghim, debounce (ghi 3 lần trong 1 giây cho ra 1 lần xuất), bỏ qua khi `(size, mtime)` không đổi, đuôi 8 MB, nạp lại `pins.json`;
  - `Harness.McpRegister`: lệnh sinh ra cho từng đích (CLI giả qua scriptblock), sửa `mcp_config.json` giữ khóa khác, có backup, dừng khi JSON hỏng, gỡ đúng khóa;
  - `Import-CodexExternalClaude` với `-SourceJsonl` và kết quả rỗng thành `skipped` (app-server giả, như test hiện có).
- **Gate**: `tools/Invoke-Gate.ps1` thêm bước `node --test` khi có Node.
- **Nghiệm thu thủ công (owner)**:
  - A1: đăng ký MCP, mở phiên mới trong Antigravity, hỏi "đọc 5 lượt cuối phiên Claude đang mở ở repo này". Kết quả phải đúng nội dung vừa chat bên Claude, cập nhật sau mỗi lượt.
  - A2: ghim một phiên Claude, chat thêm, file mirror cập nhật trong vòng khoảng 3 giây; "Reflect sang Codex" mở thread mới với prompt trỏ tới file.
  - A3: bật "Đồng bộ sang Codex", chat thêm bên Claude, sau khoảng 60 giây Codex có lượt mới. Rồi **trả lời một lượt ngay trong thread đã import ở Codex**, chat thêm bên Claude, chờ 60 giây: dòng ghim hiện `Codex skipped: ...`.
    - Sửa ngày 2026-11-26, sau lần nghiệm thu đầu: chỉ **mở** thread trong Codex desktop thì không gây `skipped`. `append_existing_session` của Codex chỉ coi là "active" những thread nằm trong ThreadManager của chính app-server đó, mà switcher import qua một tiến trình `codex app-server` riêng. Khi đó Codex vẫn nối thêm, và cột hiện `Synced to Codex HH:mm`. `skipped` chỉ xảy ra khi thread đích đã lệch trên đĩa (có người trả lời trong Codex) hoặc đã bị lưu trữ. Nguồn: `docs/reports/261125-2200-xreflect-lane-accept-fix-agy.md` mục 3(d).

## 8. Spike cần chạy trước khi viết plan chi tiết

Chạy trên profile thử hoặc bản sao, đúng quy tắc spike của repo. Không đụng dữ liệu thật của profile Default.
- **R-S1**: mỗi app (tab Code của Claude Desktop, Codex desktop, Antigravity) có nạp MCP server mới đăng ký khi app đang chạy không: với phiên mới, với phiên đang mở? Cần biết để ghi đúng hướng dẫn trong hộp xác nhận.
- **R-S2**: sidebar Codex desktop đang mở có hiện thread vừa import bởi `codex app-server` ngoài không: ngay lập tức, khi focus lại cửa sổ, hay chỉ sau khởi động lại?
- **R-S3**: lệnh spawn MCP của từng app chạy `node` với cwd và PATH nào. Có cần ghi đường dẫn tuyệt đối tới `node.exe` khi đăng ký không?

## 9. Câu hỏi mở

Không còn câu hỏi chặn. Các mặc định có thể chỉnh khi duyệt:
- số phiên ghim tối đa 5;
- debounce mirror 2 giây;
- chờ yên 60 giây trước khi đồng bộ Codex;
- `read_session_tail` mặc định 10 lượt, không kèm tool output;
- MCP chỉ quét 500 file mới nhất mỗi harness.
