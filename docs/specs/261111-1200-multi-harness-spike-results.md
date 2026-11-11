# Kết quả spike GĐ0, lane SP-A (S6, S2a, S3, S5, S7)

- Ngày chạy: 2026-11-11. Máy: Windows 11, Windows PowerShell 5.1.26100.9711 (không có `pwsh`).
- Script nằm ở `tools/spikes/`. Mọi dữ liệu thật chỉ đọc qua bản sao trong `%TEMP%\harness-spike\<Sx>`.

## S6: đọc SQLite qua `winsqlite3.dll` — ĐẠT

- Lệnh: `powershell -NoProfile -ExecutionPolicy Bypass -File tools\spikes\S6-WinSqlite.ps1` (tiền đề: bản sao `state_5.sqlite`, 2 file `.db` Antigravity và `conversation_summaries.db` trong `%TEMP%\harness-spike\S6`).
- Bằng chứng (PS 5.1, 64-bit, `sqlite 3.53.4`):
  - `select id,title,cwd from threads limit 5` trả đủ 5 dòng, tiêu đề và cwd đúng (kể cả đường dẫn Windows), qua `sqlite3_column_text16` + `Marshal.PtrToStringUni`.
  - `steps.step_payload` đọc được bằng `sqlite3_column_blob` + `sqlite3_column_bytes` + `Marshal.Copy`: idx 0..4 cho 2286, 2109, 36788, 940, 15262 byte; byte đầu `08 65 20 03 2a ...` là protobuf.
  - Mở bằng `sqlite3_open_v2` cờ `SQLITE_OPEN_READONLY` (=1) chạy được.
- Chi tiết kỹ thuật cho C5:
  - `CallingConvention.Cdecl` chạy tốt. `sqlite3_open_v2` khai báo `CharSet.Ansi`, đường dẫn có ký tự ngoài ASCII chưa thử (cần UTF-8, để C5 lưu ý).
  - Bản sao `state_5.sqlite` lúc chạy không có `-wal`/`-shm` (Codex đóng WAL sạch); khi có thì chép cùng.
  - `conversation_summaries.db` có cột `app_data_dir`, `workspace_uris`, `raw_summary` (blob), cùng bảng FTS5. Xem S5.
- Hệ quả cho spec: không đổi. C5 làm được.
- Chưa kiểm trên PS 7 (máy không có `pwsh`).

## S2a: chép rollout Codex sang `CODEX_HOME` khác, cùng account, không gọi model — ĐẠT

- Lệnh: `powershell -NoProfile -ExecutionPolicy Bypass -File tools\spikes\S2a-CodexRolloutList.ps1 -Fresh -Rollouts <rollout tương đối dưới ~\.codex\sessions>[,…]` (hoặc `-PickLatest <N>`) (client JSON-RPC ở `S2a-AppServerClient.ps1`).
- Home thử: `%TEMP%\harness-spike\S2\home`. **Không có `auth.json`**; `config.toml` là bản tối giản (chỉ dòng `model`), vì `config.toml` thật có `notify`, `marketplaces` và `model_provider` trỏ về Cockpit cục bộ, sẽ chạy hoặc kéo mạng lúc khởi động. Script từ chối chạy nếu `CODEX_HOME` không nằm dưới `%TEMP%\harness-spike` hoặc có `auth.json`. Không gọi model, không `resume`.
- Chép 1 rollout `.jsonl` (`2026/11/08/…ce84…`, 180 KB, `source=exec`) và 1 `.jsonl.zst` (`2026/09/04/…53f5…`, 8 KB, `source=vscode`) vào `sessions\YYYY\MM\DD\`, giữ nguyên tên.
- Bằng chứng:
  - **Codex tự lập chỉ mục khi `codex app-server` khởi động**: ngay sau `initialize`, `state_5.sqlite` (do Codex tạo trong home thử) đã có 2 dòng `threads` cho cả hai rollout, `rollout_path` trỏ vào home thử, `history_mode=paginated`. Không cần chèn dòng thủ công (không phải dùng `sqlite3.exe` để chèn).
  - `thread/read` (`includeTurns:false`) đọc được cả hai thread, kể cả `.zst` (Codex tự giải nén; `preview`, `cwd`, `gitInfo` đúng). `thread_history_1.sqlite` cũng được Codex tự tạo lại trong home thử.
  - **`thread/list` mặc định trả rỗng** dù đã có dòng `threads`. Hai bộ lọc mặc định gây ra việc này, không phải do thiếu chỉ mục:
    1. `modelProviders` mặc định chỉ lấy provider của config hiện tại (config thử không có `model_provider`, còn thread của `codex_local_access`);
    2. `sourceKinds` mặc định chỉ lấy nguồn "interactive" (`cli`, `vscode`), nên thread `source=exec` bị ẩn.
    Với `{limit:50, modelProviders:[], sourceKinds:["cli","vscode","exec","appServer"]}` cả hai thread đều hiện.
  - `thread/read` với `includeTurns:true` trả `turns=0`: danh sách turn nằm ở API phân trang khác, không dùng cho quyết định này.
- Phát hiện kỹ thuật (cho adapter Codex ở GĐ2): với Windows PowerShell 5.1, `ProcessStartInfo` + stdin chuyển hướng làm hỏng message đầu tiên (server ghi `Failed to deserialize JSONRPCMessage … column 1` và không trả lời). Cách khắc phục đã kiểm: bọc `StreamWriter` UTF-8 không BOM quanh `StandardInput.BaseStream` và gửi một dòng trống làm "mồi" trước message đầu. Dùng `codex.exe` thật trong `node_modules\@openai\codex-win32-x64\…\codex.exe`, không qua `codex.cmd`.
- Một cảnh báo vô hại: `Refusing to create helper binaries under temporary dir` (home dưới `%TEMP%`); home thật ở `.codex-profiles\…` thì không gặp.
- Hệ quả cho spec §6 "Codex → Codex": chọn phương án **(a) thả rollout vào `sessions\…` rồi để Codex tự lập chỉ mục khi khởi động**; không cần ghi `threads`. Thread `source=exec` bị ẩn khỏi danh sách mặc định của Codex, nên khi chuyển phải kiểm xem app có hiện chúng không (không thuộc spike này). Phần "khác account" và resume là việc của S2b.

## S3: Claude → Codex qua `externalAgentConfig/import` — ĐẠT (không cần đăng nhập)

- Lệnh: `powershell -NoProfile -ExecutionPolicy Bypass -File tools\spikes\S3-ClaudeToCodexImport.ps1 -SourceJsonl <jsonl dưới ~\.claude\projects> -SessionCwd <cwd của phiên> [-DetectHome]`. Dùng lại home thử S2 (không `auth.json`, không gọi model). Chữ ký message lấy từ `codex app-server generate-json-schema --out %TEMP%\harness-spike\S3\schema` (`ExternalAgentConfigDetectParams`, `…ImportParams`, `…ImportResponse`, `…ImportCompletedNotification`).
- **Import chạy không cần đăng nhập.** Kết quả ở home thử: `externalAgentConfig/import/completed` báo 1 `success` (`target` = thread id mới `01a1c912-…`), `external_agent_session_imports.json` trong home thử có bản ghi `{source_path, content_sha256, imported_thread_id, imported_at, source_modified_at, title}`, và `thread/list` liệt kê thread đó (`source=vscode`, `preview` là tin nhắn đầu của phiên Claude). File jsonl nguồn và `~\.codex\external_agent_session_imports.json` thật không đổi (so SHA-256).
- Quy trình gọi (đã kiểm):
  1. `initialize`, rồi `initialized`.
  2. `externalAgentConfig/detect {includeHome:true, maxSessions:N, maxSessionAgeDays:D}`. Kết quả có một mục `SESSIONS` với `details.sessions[] = {cwd, path, title}`.
  3. `externalAgentConfig/import {migrationItems:[{itemType:"SESSIONS", description, cwd, details:{sessions:[<đúng các phần tử detect trả về>]}}]}` trả `{importId}` ngay; kết quả thật đến bằng notification `externalAgentConfig/import/completed` (có `successes[]` với `target` = thread id Codex, `failures[]`), kèm `…/progress`.
- **Import chỉ nhận các phiên mà chính `detect` đã báo.** Gọi import với đường dẫn tùy ý (bản sao jsonl trong `%TEMP%`) cho `failures[0].subErrorType = "session_not_detected"` (`failureStage: "session_missing"`). Kiểm với `detect {includeHome:false, cwds:[<thư mục tạm hoặc cwd thật>]}`: trả 0 mục, tức phiên Claude là phạm vi **home**, `cwds` không giúp ích.
- **`detect` quét `~\.claude` thật** (thư mục của user chạy process): với `includeHome:true` nó thấy 804 phiên, toàn bộ nằm dưới `~\.claude\projects\…` (kèm AGENTS_MD, COMMANDS, CONFIG, HOOKS, MCP_SERVER_CONFIG, PLUGINS, SKILLS, SUBAGENTS). Để chỉ nhập đúng file mình chọn: gọi detect với `includeHome:true` (đủ `maxSessions`/`maxSessionAgeDays` để file đó nằm trong cửa sổ), **lọc `details.sessions` còn đúng phần tử mong muốn** và chỉ truyền mục `SESSIONS` đó (không truyền các `itemType` khác, vì chúng ghi cấu hình/skills vào home Codex). Cách này đã chạy đúng (đích chỉ nhận 1 thread). Chưa thử cách dùng `USERPROFILE` giả để thu hẹp phạm vi detect.
- Hệ quả cho spec:
  - §6 "Claude → Codex": đúng như dự kiến. Cần bổ sung hai ràng buộc: (a) jsonl phải nằm dưới `~\.claude\projects\…` của user máy đích thì `detect` mới thấy, nên với bundle từ máy khác phải chép jsonl vào đó (bước "Claude → Claude, khác máy") **trước** khi import; (b) import là bất đồng bộ, chờ notification `completed`.
  - Không còn cần "chạy lại trong S2b với home `spike1`" vì import không đòi đăng nhập; S2b chỉ cần kiểm lại nếu muốn xác nhận trên account thật.
- Nhập cùng một phiên vào home khác không chạm home nguồn: dedupe theo `content_sha256` nằm ở `external_agent_session_imports.json` của chính home đích.

## S5: transcript Antigravity và cấu trúc chép native — ĐẠT (transcript); chép native: chưa chạy (đúng phạm vi)

- Lệnh: `powershell -NoProfile -ExecutionPolicy Bypass -File tools\spikes\S5-AgyDecode.ps1 -DbPath <bản sao .db> [-BrainTranscript <bản sao transcript.jsonl>] [-ReportDir <thư mục>]`. Mẫu: conversation `41230053-…` (74 step, 1 MB) và `brain\<id>\*.md`, tất cả là bản sao trong `%TEMP%\harness-spike\S5`.
- **Giải mã protobuf theo wire format thành công**: cả 74 step đều well-formed. Bộ giải mã (C# nhúng bằng `Add-Type`, chạy PS 5.1) thử mỗi trường length-delimited như UTF-8 không có ký tự điều khiển trước, nếu không thì đệ quy như message con. Ra ngay: lời user, text trả lời của model, JSON tham số tool, kết quả tool, id.
- **Bảng `step_type` → vai trò**, đối chiếu từng step với `transcript.jsonl` của chính Antigravity (join `step_index` = `steps.idx`, khớp 100%):

  | step_type | Loại (Antigravity) | Nguồn | Trường chứa nội dung (đường dẫn protobuf) |
  |---|---|---|---|
  | 14 | USER_INPUT | user | `/19/2` lời user (`/19/3` gần như lặp lại, `/19/12/…` là metadata @-mention) |
  | 15 | PLANNER_RESPONSE | model | `/20/1` text trả lời, `/20/3` phần suy nghĩ, `/20/7/{1,3}` id và JSON tham số các tool call; `/20/14` là blob mã hóa (chữ ký thinking), bỏ qua |
  | 8, 9, 21 | VIEW_FILE, LIST_DIRECTORY, RUN_COMMAND | model (tool) | `/5/4/3` JSON tham số (có `toolAction`, `toolSummary`) |
  | 5 | CODE_ACTION (ghi file/artifact) | model (tool) | `/5/4/3` tham số, `/10/1/2/1` nội dung file được ghi |
  | 127 | INVOKE_SUBAGENT | model (tool) | `/143/9/3` prompt cho subagent |
  | 132 | GENERIC | model (tool) | `/5/4/3` tham số |
  | 101 | SYSTEM_MESSAGE | hệ thống | `/114/2/*` thư từ subagent |
  | 17 | ERROR_MESSAGE | hệ thống | `/24/3/*` |
  | 23 | CHECKPOINT | hệ thống | `/30/4` tiêu đề tự đặt, `/30/19` prompt đầu |
  | 98 | CONVERSATION_HISTORY | hệ thống | chỉ id |
  Chỉ một conversation mẫu, nên các step_type hiếm có thể còn thiếu; bảng hiện có 12 loại.
- **Dựng được transcript user/model đọc được chỉ từ `.db`**: script ghi `transcript-from-protobuf.md` (2 khối USER, 22 khối MODEL cho 72 step, kèm các dòng tool). Chất lượng đủ cho handoff.
- **Phát hiện lớn: Antigravity tự ghi sẵn transcript** `brain\<id>\.system_generated\logs\transcript.jsonl` (và `transcript_full.jsonl`), mỗi dòng JSON `{step_index, source, type, status, created_at, content | thinking | tool_calls}` với `type` có tên (USER_INPUT, PLANNER_RESPONSE, …). Cả 44 conversation `.db` trên máy có file này; 100 conversation `.pb` cũ không có (0/100). Dòng đầu của `content` USER_INPUT bọc trong `<USER_REQUEST>…</USER_REQUEST>` kèm `<ADDITIONAL_METADATA>`. Một dòng của file mẫu không parse được ở dạng JSON thuần (1/72), nên bộ đọc phải bỏ qua dòng lỗi.
- Hệ quả cho spec (§2.3, §5, §6, GĐ3): **handoff Antigravity nên đọc `transcript.jsonl` làm nguồn chính** (không cần giải mã protobuf), dùng bộ giải mã `.db` làm phương án dự phòng khi thiếu file. Cập nhật §2.3: "Blob là protobuf… chỉ giải mã chung được" vẫn đúng nhưng không còn là con đường duy nhất. `.pb` cũ: chỉ có `brain\<id>\*.md` để làm handoff.
- **Cấu trúc để chép native (chưa chạy, theo kế hoạch):**
  - `conversation_summaries.db` (một file cho cả `~\.gemini\antigravity`): bảng `conversation_summaries` (khóa `conversation_id`; cột `title`, `preview`, `step_count`, `last_modified_time`, `workspace_uris` dạng JSON `file:///…`, `status`, `project_id`, `parent_conversation_id`, `app_data_dir`, `raw_summary` blob 722 byte…), cùng bảng FTS5 `conversations_fts` và các bảng shadow. Có dòng cho `41230053-…` với `app_data_dir=antigravity`; cả 877 dòng đều `app_data_dir=antigravity`.
  - Cạnh đó còn `agyhub_summaries_proto.pb` (593 KB), nhiều khả năng là chỉ mục khác.
  - Vì vậy "thả `<id>.db` và `brain\<id>\` vào thư mục gemini đích" chưa chắc đủ để conversation hiện ra: có thể phải thêm dòng vào `conversation_summaries.db` (và FTS) hoặc app tự quét `conversations\` khi khởi động. Chưa biết; việc của S4 khi có profile Antigravity thử.
  - `sqlite3.exe` trên máy **không có FTS5** ("no such module: fts5"), nên không dùng nó để sửa `conversation_summaries.db`; `winsqlite3.dll` thì chưa thử với FTS5 (S6 chỉ đọc bảng thường).

## S7: deep link mở phiên mới kèm prompt — ĐẠT (Claude và Codex có cú pháp xác định; Antigravity: không có link, rơi về clipboard)

- Lệnh: `tools\spikes\S7-DeepLinkScan.ps1` (chỉ đọc: tự phân tích header `app.asar`, quét các `.js`, không mở link, không chạy app). Có thêm `-ContextPattern`/`-PathFilter` để in đoạn mã quanh một mẫu. Gọi script bằng `& .\tools\spikes\S7-DeepLinkScan.ps1 …` trong cùng session, không qua `powershell -File` (PowerShell 5.1 làm mất dấu `"` trong đối số native).
- Phiên bản đã đọc: Claude 5.1231.2.0, Codex (OpenAI.Codex) 26.1103.7773.0, Antigravity và Antigravity IDE bản cài trong `%LOCALAPPDATA%\Programs`.

| App | Scheme (đăng ký ở HKCU hoặc MSIX) | Phiên mới kèm prompt | Tham số | Kết luận |
|---|---|---|---|---|
| Claude Code (desktop) | `claude://` | `claude://code/new?q=<prompt>&folder=<đường dẫn>` (`prompt` cũng được, `q` ưu tiên) | `q`/`prompt` (tối đa 14336 ký tự, `rM=14336`), `folder` (lặp được), `file` (lặp được), `ssh_host`… | Có. Còn `claude://code/continue?session=<id|last>`, `claude://code/needs-input`, chat thường `claude://claude.ai/new?q=<prompt>&surface=chat`. Handler đưa vào `/task/new?q=…&folder=…&src=external` (điền sẵn composer; chưa chạy thử nên chưa biết có tự gửi hay không). Có cờ `ccd_deeplink_trusted_folder_skip`, tức link kèm `folder` đi qua kiểm tra thư mục tin cậy. Không có ngầm định nào cho profile cụ thể |
| Codex (desktop) | `codex://` (cả `codex-dev://`, `chatgpt://` cho một số route) | `codex://threads/new?prompt=<prompt>&path=<thư mục>&mode=<work…>` | route `threads/new` chấp nhận đúng các khóa `browserUrl`, `mode`, `originUrl`, `path`, `prompt`; không có khóa nào khác thì là `newThread` trống. Còn `codex://threads/<uuid>` (mở thread, kèm `hostId`), `codex://launch`, `codex://review?pr=…`. Cổng web `?q=` cũng được đổi thành `prompt` | Có. Ngoài ra cờ dòng lệnh dạng thư mục dự án (đường dẫn Windows trần) mở `newThread` với `path` |
| Antigravity (Electron) | `antigravity://` (đăng ký HKCU: `Antigravity.exe "%1"`; tên scheme suy ra từ tên app) | **Không xác định được.** Main process chỉ chuyển nguyên URL cho renderer qua IPC `deep-link`; renderer là web UI do `language_server.exe` phục vụ, trong đó không có chuỗi `antigravity://`, `onDeepLink` hay `deeplink` | — | Không có cú pháp xác nhận được bằng đọc tĩnh. Dùng clipboard. (Cách thử duy nhất là mở link thật trong profile thử, thuộc SP-B sau S4.) |
| Antigravity IDE | `antigravity-ide://` (đăng ký HKCU: `Antigravity IDE.exe --open-url -- "%1"`) | Không. Chỉ có chuẩn VS Code: `antigravity-ide://file/<đường dẫn>[:dòng[:cột]]`, `antigravity-ide://?windowId=_blank`; extension `antigravity` không đăng ký `registerUriHandler` | — | Không có link tạo phiên agent kèm prompt. Dùng clipboard |

- Hệ quả cho spec §5 (handoff vào harness đích): Claude và Codex dùng deep link (kèm giới hạn độ dài prompt: Claude 14336 ký tự; nên đưa prompt ngắn "đọc file handoff tại <đường dẫn>" thay vì cả transcript); Antigravity cả hai app rơi về clipboard.
- Cảnh báo cho UI: link `claude://` và `codex://` đi tới app đã đăng ký scheme ở MSIX (một instance), **không** chọn được profile phụ. Với profile không phải Default, link có thể mở nhầm instance. Phải kiểm bằng SP-B/GĐ2 hoặc mặc định chép clipboard cho profile phụ.
