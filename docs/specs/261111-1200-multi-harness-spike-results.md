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

# Kết quả spike SP-B (cần user đăng nhập)

Lane `switcher-work-2`, nhánh `mh-spike-b`, 2026-11-11. Orchestra sẽ nối file này vào `261111-1200-multi-harness-spike-results.md` khi land.
Profile thử: `%USERPROFILE%\.codex-profiles\spike1` (Codex). Không chép `auth.json` nào ra khỏi Default.

## S1: hai account Codex song song: **Đạt** (đăng nhập GUI không dùng được, xem ghi chú)

- Lệnh: `tools/spikes/S1-CodexProfile.ps1 -Name spike1` (đặt `CODEX_HOME`, `CODEX_ELECTRON_USER_DATA_PATH` cho process con, chạy `ChatGPT.exe --user-data-dir=<spike1\electron>`), rồi `-Check`.
- Bằng chứng:
  - Hai `ChatGPT.exe` chính (không có `--type=`) chạy song song: PID 25828 (Default, cmdline không có tham số) và PID 38772 (`--user-data-dir="...\spike1\electron"`). `Win32_Process` phân biệt được qua `--user-data-dir=`. Khớp spec §3.3.
  - `CODEX_HOME=spike1` được app tôn trọng: app-server riêng tạo `state_5.sqlite`, `logs_2.sqlite`, `config.toml`, `installation_id`... ngay trong `spike1\`. Default giữ nguyên.
  - Dữ liệu Electron của spike1 nằm ở `spike1\electron\Default\...` (Cookies, Local Storage...), không thấy gì tên `spike` trong `Packages\OpenAI.Codex_*\LocalCache`. Các file `LocalCache\Roaming\Codex\...` đổi giờ là do instance Default ghi. Không có chuyển hướng MSIX cho đường dẫn nằm ngoài AppData, khớp giả thuyết ở §3.3.
  - Sau đăng nhập: `spike1\auth.json` sha12 `EF273B3E1B79`, Default `5B0D4C3B6EDC`, khác nhau. `auth_mode` spike1 = `chatgpt` (khóa `auth_mode, OPENAI_API_KEY, tokens, last_refresh`). `account_id` băm sha8: Default `E3B0C442` (đây là hash chuỗi rỗng: Default không có `tokens.account_id`), spike1 `8E61FA26`. Tức hai account khác nhau.
- **Phát hiện phụ (quan trọng cho UI):** trong cửa sổ test (instance thứ hai, `hasExplicitUserDataPath`), nút **Continue to sign in** / **Sign in another way** bấm không phản ứng, không mở trình duyệt, không có cổng 1455 nào được mở. Đã thử đưa cửa sổ lên foreground, vẫn không được. Cách làm được: `CODEX_HOME=spike1 codex.exe login` (CLI) mở server `127.0.0.1:1455` và link OAuth, user đăng nhập trong Chrome, ghi `spike1\auth.json`.
- Hệ quả cho spec:
  - §3.3: "Đăng nhập lần đầu ngay trong app" **không chắc dùng được**. Phương án chắc chắn: nút "Add Codex account" chạy `codex login` với `CODEX_HOME` của profile (đường dẫn `codex.exe` ở `app\resources\codex.exe` của package hoặc CLI trong PATH), rồi mới launch app. Cần kiểm lại trên app mở lại sau khi đã có `auth.json` (S2b).
  - Cổng 1455 là cổng cố định của login callback: hai lần `codex login` song song sẽ xung đột. Phải đăng nhập tuần tự.

## S2b: rollout Codex sang account khác (native), cộng deep link và thread `exec`: **Đạt một phần**

Công cụ: `tools/spikes/S2b-AppServerProbe.py` (JSON-RPC qua stdio với `CODEX_HOME` thử; bản PowerShell bị codex từ chối dòng đầu `expected value at line 1 column 1`, cùng nội dung ghi từ Python thì được nhận). Chỉ dùng auth của chính `spike1` (account thứ hai), sandbox `read-only`, prompt `ping`. Không chép `auth.json` nào.

### Kết quả theo câu hỏi

1. **Cùng account, home không có auth (quyết định của orchestra).**
   - Tạo rollout trong spike1 bằng `codex exec --sandbox read-only "ping"` (account 2, trả `Pong.`), chép sang `%TEMP%\harness-spike\S2b\home-noauth\sessions\2026\11\11\` (home chỉ có thư mục `sessions`).
   - `codex app-server` với home đó, không đăng nhập: `thread/list` mặc định trả `[]`; thêm `sourceKinds:["cli","vscode","exec","appServer","unknown"]` thì thấy thread, `path` trỏ vào home mới; `thread/read includeTurns:false` đọc được. Không cần đăng nhập để liệt kê.
   - Cơ chế: Codex **tự lập chỉ mục khi khởi động** (home chưa có `state_5.sqlite` nên được quét và dựng lại). Không phải chèn dòng `threads`.
   - Hai chi tiết: (i) `thread/list` mặc định **ẩn thread `source=exec`** (`originator=codex_exec`); (ii) app-server in cảnh báo "Refusing to create helper binaries under temporary dir" nhưng vẫn chạy.
2. **Khác account, rollout lấy từ Default chép vào `spike1\sessions\…`** (spike1 đã có `state_5.sqlite` từ trước).
   - `thread/list` **không liệt kê** rollout vừa thả vào (DB đã có, không quét lại), nhưng `thread/read` theo id vẫn đọc được (preview rỗng).
   - `codex exec resume <id> "ping"` dưới account 2:
     - rollout `01a1af66…` (`model_provider=codex_local_access`, tạo qua công cụ Cockpit): **lỗi** `modelProviderNotConfigured`, nghĩa là chat gắn provider không có trong `config.toml` đích. Không liên quan đến account.
     - rollout `01a1b9d7…` (`openai`, `.jsonl` 179 KB): **resume được**, trả `Pong.`.
     - rollout `01a18331…` (`openai`, `.jsonl.zst` 9,5 KB): **resume được**; sau resume, file trong spike1 thành `.jsonl` (Codex tự giải nén).
     - Sau các lần resume, cả hai thread `openai` **hiện trong `thread/list`** của spike1 (resume cũng đăng ký thread vào DB), thread `codex_local_access` thì không.
   - **Chưa kiểm:** mục `reasoning` có `encrypted_content`. Cả ba rollout nguồn đều không có item `reasoning` (các rollout `openai` còn lại của Default là `.zst` không giải nén được tại chỗ). Vì vậy giả thuyết ở spec §2.2 chưa được kiểm chứng hay bác bỏ.
   - **Chưa kiểm:** "cùng account với Default" (không chép auth Default, theo quyết định).
3. **Deep link (a)**, khi spike1 đang chạy cùng Default và hai Claude:
   - `codex://threads/new?prompt=ping-test&path=<tmp>`: mở vào **Default** (PID 25828), không vào spike1. Composer của Default điền sẵn `ping-test`, project `work` (đường dẫn `…\harness-spike\S2b\work`), chưa gửi. Một tiến trình kích hoạt (PID 35092, log rỗng) chuyển link rồi thoát. Lý do hợp lý: instance Default giữ khóa single-instance, spike1 (có `--user-data-dir`) không giữ khóa nên không nhận link.
   - `claude://code/new?q=ping-test&folder=<tmp>`: mở vào Claude **Default** (PID 50200), không vào `ClaudeProfile-Account 2`. Session mới, composer `ping-test`, thư mục `work`, chưa gửi.
   - Hệ quả: deep link **luôn rơi vào instance Default**, không chọn được profile. Khi handoff vào profile khác thì không dùng link được; dùng clipboard hoặc ghi vào chính DB/app-server của profile đó.
   - Tác dụng phụ trên máy user: Codex Default có thêm project `work` và bản nháp `ping-test` trong composer; Claude Default có bản nháp `ping-test`. Chưa gửi. User có thể xóa tay.
4. **Thread `exec` (b):** app Codex của spike1 (mở lại sau khi đăng nhập, đọc auth của spike1 từ `CODEX_HOME`) **hiện** thread `ping` (đã tạo bằng `codex exec`) đầu mục Recents. API `thread/list` mặc định thì ẩn loại này. Giao diện app khác với Default: tên "ChatGPT", danh sách Recents của account 2.

### Kết luận
- Native Codex sang account khác: **Đạt** cho rollout `openai` (cả `.jsonl` và `.zst`), với điều kiện chat không gắn provider riêng (`codex_local_access` không dùng được). Phần reasoning mã hóa: **chưa kiểm**.
- Hệ quả cho spec §6: nhập native cần để Codex đích đăng ký thread. Hai cách đã thấy hoạt động: (a) thả vào `sessions\…` khi home chưa có DB (tự lập chỉ mục); (b) khi đã có DB thì resume theo id (`codex exec resume <id>`) làm thread hiện ra, nhưng đó là một lệnh gọi model (một turn). Chưa thử chèn dòng `threads` vào DB của spike1. Switcher phải kiểm `model_provider` của rollout so với `config.toml` đích trước khi chép.
- §9 (UI): `thread/list` mặc định ẩn `source=exec`; khi liệt kê chat để chuyển, truyền `sourceKinds` đầy đủ.

## S4: hai account Antigravity: **Một phần** (tách dữ liệu được, đăng nhập thì không tách được)

Mục này gồm hai đợt. Đợt 1: dừng trước đăng nhập vì lo ghi đè credential. Đợt 2 (bổ sung bên dưới, mục "Đợt 2"): user đã chấp nhận rủi ro và đăng nhập account thứ hai.

Lệnh: `tools/spikes/S4-AgyProfile.ps1 -Name spike1 [-FakeHome] [-App 'Antigravity IDE']`, rồi `-Check`.

- **`ANTIGRAVITY_GEMINI_DIR` và `ANTIGRAVITY_APP_DATA_DIR` không tách được dữ liệu agent** (giả thuyết §3.3 sai ở điểm này).
  - Chạy `Antigravity.exe --user-data-dir=%LOCALAPPDATA%\AgyProfile-spike1` kèm hai biến đó: `language_server.exe` của instance thử ghi `hub_59665.json` vào `~\.gemini\antigravity\daemon\` thật và `reconcile checked 144 conversations`, tức là đọc đúng kho conversation của Default. Instance thử còn ghi các file mô tả MCP (`antigravity\mcp\*`) vào `~\.gemini` thật lúc khởi động (có thể do instance Default cùng lúc; chưa phân biệt được). Đã tắt ngay instance này.
  - Trong binary, `ANTIGRAVITY_GEMINI_DIR` chỉ xuất hiện cạnh đường dẫn `…/run/credentials-cache`; thư mục gốc lấy từ cờ `--app_data_dir antigravity` (tên tương đối dưới thư mục `.gemini` của home).
  - File thừa còn lại trong thư mục thật: `~\.gemini\antigravity\daemon\hub_59665.json` (file khám phá hub của instance thử, đã chết). Orchestra quyết định xóa hay giữ.
- **Cách tách đã chạy được: đổi home của process con** (`-FakeHome`: `USERPROFILE` và `HOME` trỏ vào `%USERPROFILE%\.gemini-profiles\spike1\home`). Khi đó toàn bộ `.gemini\antigravity\{conversations,brain,daemon,bin,…}` nằm trong home giả, `reconcile checked 0 conversations`, thư mục `daemon` thật không đổi. Antigravity IDE cũng chạy được kiểu này, ghi vào `home\.gemini\antigravity-ide` và `home\.antigravity-ide`.
- **Trả lời Q2:** hai app **không** dùng chung `~\.gemini\antigravity`. IDE dùng `~\.gemini\antigravity-ide` (thư mục riêng, có sẵn trên máy) và `~\.antigravity-ide\extensions`.
- **Điều chặn: đăng nhập không tách theo profile.** Instance thử (userData mới, home giả, không có file credential nào trong đó) vẫn báo `Auth succeeded` và chào đúng tên account Default. Credential nằm trong **Windows Credential Manager**, mục `gemini:antigravity` (khóa theo tên, không theo profile). Đăng nhập account Google thứ hai trong cửa sổ thử nhiều khả năng **ghi đè mục này** và làm Default bị đăng xuất hoặc đổi account. Vì vậy mình **không nhờ user đăng nhập** (không có cách quay lại an toàn), và các phép thử còn lại của S4 (chat mới trong `conversations` của spike1, hai instance cùng account khác nhau, chép native `.db` + `brain\<id>`) **chưa chạy**.
- Hệ quả cho spec:
  - §3.3 / §6: Antigravity chỉ có một account trên mỗi user Windows. Theo phương án đã nêu ở §3.3, ẩn nút Add account cho Antigravity; launch và handoff vẫn dùng được.
  - Nếu muốn thử tiếp: cần user chấp nhận có thể phải đăng nhập lại Default, hoặc dùng một user Windows khác. Chưa kiểm xem `-FakeHome` có đổi tên mục Credential Manager hay không (mục vẫn là `gemini:antigravity` theo quan sát).

### Đợt 2: đăng nhập account thứ hai (user chấp nhận rủi ro, 2026-11-11)

Công cụ thêm: `tools/spikes/S4-CredStamp.ps1` (chỉ in tên mục và thời điểm sửa của Credential Manager, không đọc nội dung).

- **Credential bị ghi đè:** mục `gemini:antigravity` có `LastWritten` **13:58:50** trước khi đăng nhập, **14:01:53** sau khi user đăng nhập trong cửa sổ spike1 (đúng lúc đăng nhập xong). Nội dung không đọc, nhưng thời điểm trùng với đăng nhập ở spike1 cho thấy mục dùng chung đã bị thay bằng account thứ hai. Instance Default đang chạy giữ token trong bộ nhớ, **chưa kiểm** nó đổi account hay bị đăng xuất khi khởi động lại (không khởi động lại app của user). `~\.gemini\oauth_creds.json` và `google_accounts.json` thật không đổi (sửa lần cuối 2026-06-07).
- **Dữ liệu agent đúng chỗ:** chat user vừa tạo nằm ở `.gemini-profiles\spike1\home\.gemini\antigravity\conversations\<id>.db` (+ `-wal`, `-shm`, `annotations`, `conversation_summaries.db`). `~\.gemini\antigravity\conversations` thật vẫn 44 file `.db`, thư mục `daemon` thật không thêm file. Đăng nhập mở trình duyệt mặc định của user (Firefox) với profile nằm trong home giả của spike1: cả `USERPROFILE` lẫn `appdata` bị đổi, nên Firefox tạo profile mới trong `home\appdata\…`.
- **Chạy song song:** instance spike1 (`--user-data-dir=…\AgyProfile-spike1`) chạy cùng Default (hai nhóm tiến trình Antigravity riêng, mỗi nhóm một `language_server.exe`).
- **Chép native (thử):** đóng spike1, chép một `<id>.db` (266 KB) và thư mục `brain\<id>` từ Default sang `home\.gemini\antigravity\`, mở lại spike1. Log: `reconcile checked 2 conversations, restored 1, cached 1` và sidebar hiện một conversation lấy từ bản chép (cùng project). Tức là Antigravity tự nhận `<id>.db` mới khi khởi động. **Chưa kiểm** tiếp tục chat (cần gọi model dưới account khác) và việc conversation gắn account phía server.
- Một thay đổi trong thư mục thật chưa rõ nguồn: `~\.gemini\config\config.json` sửa lúc 14:00:14, trong lúc cả hai instance chạy. Không phân biệt được là Default hay spike1 ghi.
- **Kết luận cho spec:**
  - Tách dữ liệu agent và chạy song song: **Đạt** nếu đặt home riêng cho process con (`USERPROFILE`, `HOME`); `ANTIGRAVITY_GEMINI_DIR` không đủ.
  - Tách đăng nhập: **Không đạt** trên cùng user Windows (Credential Manager dùng chung). Hai account chỉ chạy song song nếu mỗi instance tự giữ phiên, điều chưa chứng minh. Mặc định giữ nguyên: Antigravity một account, ẩn Add account (§3.3). Native chép `<id>.db` + `brain\<id>` là khả thi về mặt hiển thị (§6, giai đoạn 3b) nhưng phần tiếp tục chat chưa kiểm.
  - Nếu sau này cho phép Add account: phải cảnh báo rằng đăng nhập ở profile mới có thể đăng xuất Default.

## S8: chat Codex trong home đã có DB, transcript `.zst`, app-server song song, `codex.exe` trong package (lane 2b) — **ĐẠT**

Chạy 2026-11-11 trên `spike1` (account 2, app đã đóng trừ phần S8c) và home tạm `%TEMP%\harness-spike\S8\*`. Nguồn rollout chỉ đọc từ Default. Không có turn nào gửi tới model (chỉ `initialize`, `thread/list`, `thread/read`, `thread/resume`, `thread/items/list`). Script: `tools/spikes/S8-*.ps1` (đường dẫn rollout truyền bằng tham số).

### S8a: đăng ký thread vào home đã có DB, không gọi model — ĐẠT, không cần resume và không cần chèn dòng

- Lệnh: `& .\tools\spikes\S8-ThreadRegister.ps1 -CodexHome <home> -Rollout <rollout tương đối dưới ~\.codex\sessions> [-SourceRoot <thư mục khác>] [-SkipResume]`. Rollout thử là bản `openai` có tin nhắn user, đổi sang id mới (`S8-MakeSyntheticRollout.ps1`) vì mọi rollout thật phù hợp đã có trong `spike1`.
- Kết quả, lặp lại được ở cả `spike1` (5 dòng sẵn có) và home tạm có DB:
  - Ngay sau `initialize`, `thread/list` (theo F5) **đã liệt kê** rollout vừa thả (app-server quét `sessions\`), trong khi `state_5.sqlite` chưa có dòng; sau khoảng 10 giây (hoặc ngay khi `thread/read` theo id) dòng `threads` xuất hiện trong DB. `thread/resume` (không `turn/start`) trả `ok`, `status=idle`, không đổi gì thêm. Khởi động lại app-server không làm mất thread.
  - Thread **không có tin nhắn user** (preview rỗng) được đăng ký vào DB nhưng **không hiện** trong `thread/list` (bộ lọc hiển thị cần `preview<>''`); đó là hành vi bình thường, rollout trống cũng bị ẩn ở Default.
- Khác với F3 (S2b ghi "home đã có DB thì thread không hiện cho tới khi resume theo id"): ở hai lần chạy này nó hiện mà không cần resume. Chưa giải thích được chắc chắn sự khác biệt (nghi do rollout S2b có preview rỗng, hoặc đo quá sớm). Hệ quả an toàn cho sản phẩm: sau khi chép rollout, **khởi một app-server trên home đích, `initialize`, `thread/read {threadId}`, chờ dòng `threads` xuất hiện (tối đa ~30 giây)**; không dùng `thread/resume` và không chèn dòng.
- Chưa kiểm bằng mắt: cửa sổ app spike1 có hiện thread này không (không điều khiển được GUI trong spike này). S8c cho thấy app đang mở không chặn việc đăng ký.

### S8b: transcript cho rollout `.zst` — ĐẠT qua app-server

- Lệnh: `& .\tools\spikes\S8-TranscriptProbe.ps1 -ZstRollout <rel> [-JsonlRollout <rel>] -Resume`.
- Cách làm được: `thread/read` rồi `thread/resume` (không `turn/start`), chờ vài giây, rồi `thread/items/list {threadId, limit}` phân trang bằng `nextCursor`. Chưa `resume` thì `items`/`turns` trả rỗng.
- Kết quả: rollout `.zst` 73 KB cho 14 item: `userMessage` ×1, `agentMessage` ×2, `reasoning` ×6, `commandExecution` ×2, `webSearch` ×3. Mỗi phần tử có `{turnId, item, startedAtMs, completedAtMs}`. `userMessage.content[].text` và `agentMessage.text` đủ làm transcript. Rollout `.jsonl` cho cùng dạng. Không cần đăng nhập (home tạm không có `auth.json`).
- Phương án đọc thẳng `thread_history_1.sqlite` không cần dùng.
- Hệ quả cho K3: `.zst` lấy transcript bằng app-server trên home đích tạm hoặc chính home nguồn. Với bản chép Default thì dùng home tạm chỉ có rollout đó (không đụng Default, không cần auth).

### S8c: app-server chạy song song với app đang mở trên cùng `CODEX_HOME` — an toàn trong phạm vi đã thử

- Lệnh: `& .\tools\spikes\S8-ConcurrentAppServer.ps1 -Name spike1 -SyntheticRel <rel> -SyntheticRoot <root>` (mở app spike1 bằng S1, chạy app-server thứ hai cùng home, rồi chỉ đóng cây process do script mở).
- `initialize` mất ~120 ms khi app đang chạy. 4 lần `thread/list` cách nhau 4 giây, `thread/read`, và đăng ký thread mới đều thành công; stderr không có `locked`/`busy`; dòng `threads` được ghi vào DB.
- Giới hạn: ít thao tác, không có ghi đồng thời từ phía app. Chưa biết giao diện app đang mở có tự làm mới danh sách khi DB đổi từ bên ngoài. Quyết định cho `Test-CodexImportNeedsClose`: **trả true khi app của profile đích đang chạy** (mặc định an toàn của plan R2), dù thử nghiệm không thấy lỗi khóa; có thể nới sau khi kiểm giao diện.

### S8d: `codex.exe` trong package — chạy được từ ngoài package

- `<InstallLocation>\app\resources\codex.exe --version` → `codex-cli 0.167.0-alpha.3.2`, `login --help` chạy được (exit 0). Dùng được cho `codex login` (P3) và làm `CodexExe` (P1). CLI npm hiện là 0.167.1 (dự phòng). `AppId` trong manifest là `App` (khớp `Aumid = <PackageFamilyName>!App`). Đã nhắn lane 2a.

### Phát hiện phụ cho K2/K3 (cần biết khi viết mã)

- `threads.rollout_path` có thể không khớp tên file thật: nhiều dòng ghi `….jsonl` trong khi file trên đĩa là `….jsonl.zst`, và đường dẫn có tiền tố `\\?\`. Khi tìm rollout phải thử cả `path` và `path + '.zst'`.
- Cột `source` của thread subagent là chuỗi JSON `{"subagent":…}`; cột `thread_source` là `subagent` (728 dòng), `user` (710), `agent_created_thread` (20), `chatgpt_handoff` (1), `onboarding_checklist` (2). Lọc chat người dùng bằng `thread_source NOT IN ('subagent')` (xem K2).
- **Rủi ro cho giá trị của native Default → profile khác:** ở Default, 773 chat có `model_provider=codex_local_access` (đường Cockpit) và chỉ 688 dòng `openai`, trong đó hầu hết là subagent (665/688); chỉ ~3 thread người dùng `openai`. Với account thường, `Import-CodexNative` sẽ trả `provider-mismatch` cho gần như mọi chat của Default, nên đường handoff sẽ là đường chính cho Default → profile phụ.

## S13: snapshot SQLite nhất quán bằng `VACUUM INTO` trên DB WAL đang ghi — **ĐẠT**

Chạy 2026-11-11, Windows PowerShell 5.1, `winsqlite3.dll` (SQLite 3.53.4). Script: `tools\spikes\S13-SqliteSnapshotConsistency.ps1` (chỉ ghi dưới `%TEMP%`, xóa sạch khi xong).

- Cách thử: một process riêng ghi liên tục vào DB WAL (commit mỗi 20 dòng kèm blob 2 KB, thỉnh thoảng `DELETE`), DB tăng tới ~70 MB. Process chính mở kết nối **chỉ đọc** (`SQLITE_OPEN_READONLY`), chạy `PRAGMA busy_timeout=5000` rồi `VACUUM INTO '<tmp>'` 50 lần, mỗi bản chạy `PRAGMA integrity_check`.
- Kết quả: **50/50 bản `ok`**, không lỗi `locked`/`busy`. Thời gian mỗi lần: min 121 ms, trung bình 492 ms, max 1172 ms (DB ~70 MB, đang bị ghi liên tục).
- So với cách hiện tại (`Copy-SqliteSnapshot` chép `.db`, `-wal`, `-shm` từng file) trong cùng điều kiện: **26/50 lần hỏng**, chủ yếu do `Copy-Item` ném lỗi vì `-shm` đang bị khóa một phần ("another process has locked a portion of the file"). Lần chép được vẫn có thể lệch giữa ba file.
- Kết luận cho H1d: dùng `VACUUM INTO` từ kết nối chỉ đọc, không cần `sqlite3_backup_*`. Giữ đường lui về chép file (kèm log) khi `VACUUM INTO` lỗi. Cần `busy_timeout`. Bản vacuum chỉ có một file, không mang `-wal`/`-shm`.
- Lưu ý: `VACUUM INTO` dựng lại cả DB nên với DB lớn tốn thời gian và dung lượng tạm tương đương; đặt trần kích thước ở nơi gọi.

## S10: ngữ nghĩa ghi/đọc trên Google Drive for desktop (DriveFS) — **ĐẠT, kèm hai ràng buộc cho lane S**

Chạy 2026-11-11, Windows PowerShell 5.1, ổ Drive của một account (My Drive đọc theo nhãn volume, không in tên). Script: `tools\spikes\S10-DriveFsSemantics.ps1 -DriveRoot <My Drive>`; chỉ ghi dưới `<My Drive>\HarnessSync-test\s10\` và `%TEMP%`, đã xóa sạch (script tự kiểm).

- **(a) tmp rồi rename, bên đọc cùng máy (process thứ hai): ĐẠT.** Writer ghi `a-final.bin.tmp-<guid>` (2 MB, đầu và đuôi mang cùng số đếm) rồi rename đè lên `a-final.bin` 40 lần; bên đọc lặp liên tục: khoảng 1.000-1.300 lượt đọc mỗi đợt, **0 lượt thấy file dở** (mọi bản đọc đủ 2 MB, đầu khớp đuôi), thấy đủ 40 phiên bản. Hai lỗi mở file xảy ra thoáng qua lúc đang rename: `being used by another process` và `Access ... is denied`. Cả hai đều là lỗi mở, không phải dữ liệu dở, nên bên đọc chỉ cần thử lại. (Số `missing` lớn trong log là do bên đọc chạy trước khi writer khởi động xong, không có ý nghĩa.)
- **Ràng buộc 1: cách rename.** `Move-Item -Force` đè lên file đang có thất bại **37/40** khi bên đọc đang mở file không kèm `FileShare.Delete` (`Cannot create a file when that file already exists`); không có bên đọc thì 40/40 đạt. Gọi thẳng `MoveFileEx(tmp, dest, MOVEFILE_REPLACE_EXISTING)` qua P/Invoke đạt **40/40 cả khi có bên đọc**. `Write-SyncFileAtomic` (S2) dùng `MoveFileEx` kèm thử lại có hạn, không dùng `Move-Item -Force`. Bên đọc mở file với `FileShare.ReadWrite | Delete`. (`[IO.File]::Replace` chưa thử trọn vẹn vì lỗi tham số; không cần dùng.)
- **(b) mở file ngay sau khi ghi, lúc DriveFS đang tải lên: ĐẠT.** File 50 MB ghi xong trong ~0,3 s. Ngay sau đó mở được ở cả ba chế độ (đọc loại trừ, đọc chia sẻ, mở ghi), không bị khóa; sha của bản đọc ngay sau khi ghi khớp bản đã ghi; rename ngay sau khi ghi cũng được.
- **(c) chép 50 MB về `%TEMP%`: ĐẠT.** Lần đầu 386-415 ms, các lần sau 42-62 ms (bản đã nằm trong cache cục bộ của DriveFS); sha khớp 3/3, và khớp cả lần chép sau 15 giây. Lưu ý: số này là file do máy này vừa ghi nên đã có sẵn cục bộ. Với file do máy khác đẩy lên, DriveFS có thể phải tải về trước (chế độ stream), thời gian sẽ phụ thuộc mạng. Chưa đo được trên một máy thứ hai.
- **(d) ghi trùng tên trên cùng một máy: ĐẠT.** Ghi đè hai lần rồi đè bằng rename, chờ 20 s: **không** sinh file `tên (1).ext`; nội dung cuối là bản mới nhất. `CreateNew` lên tên có sẵn bị từ chối bình thường. **Chưa kiểm được:** xung đột thật khi hai máy ghi cùng tên, vì cần máy thứ hai. Thiết kế "mỗi file chỉ một máy ghi" (D8, S1) vẫn giữ; bên đọc vẫn bỏ qua `* (n).*`.
- **Kết luận cho lane S:** (1) S2 ghi bằng tmp + `MoveFileEx` thay thế, kèm kiểm sha sau khi ghi; (2) S5 thử lại có hạn (vài lần, cách nhau 200-500 ms) khi mở hoặc chép file lỗi `used by another process`/`access denied`, rồi kiểm sha theo row; (3) không cần giữ trần kích thước riêng cho việc chép 50 MB.

## S12: rollout Codex có cwd không tồn tại trên máy — **ĐẠT**

Chạy 2026-11-11 trong home tạm `%TEMP%\harness-spike\S12\home` (đã xóa), `codex app-server` trong package, không gọi model. Script: `tools\spikes\S12-CodexMissingCwd.ps1 -SourceRollout <rollout .jsonl chỉ đọc>`. Rollout thử là bản chép của một rollout thật, đổi thread id và đổi mọi chỗ ghi cwd (`session_meta` và các dòng khác) sang `Z:\NoSuchRoot\SomeProject` (không tồn tại); bản đối chứng đổi sang `%TEMP%` (tồn tại).

- Home rỗng: app-server tự tạo `state_5.sqlite` ngay lần khởi động đầu. Thả hai rollout vào `sessions\`, khởi động lại, đợi 12 s, rồi `thread/read {includeTurns:false}`.
- **Cwd không tồn tại: `thread/read` thành công và dòng `threads` được đăng ký**, `archived=0`. Cột `cwd` mang đúng chuỗi trong rollout (`Z:\NoSuchRoot\SomeProject`), không bị đổi hay làm rỗng. `thread/read` trả cùng cwd đó.
- Đối chứng cwd tồn tại: cũng đăng ký; cột `cwd` được chuẩn hóa thành dạng `\\?\C:\...` (tiền tố `\\?\`), còn `thread/read` trả đường dẫn thường. Tức app-server chỉ chuẩn hóa (canonicalize) được khi đường dẫn có thật, nếu không thì giữ nguyên chuỗi.
- Hai thread đều **không** hiện trong `thread/list` (bản rollout nguồn chép không có tin nhắn user thích hợp trong phạm vi lọc của list, như S8a đã ghi về preview rỗng). Nên kết quả này chỉ chứng minh đăng ký dòng `threads`, không chứng minh hiển thị. Hai thread cư xử giống nhau, nên không có dấu hiệu cwd thiếu làm khác đi.
- Không thử được: cửa sổ ChatGPT/Codex có hiện thread có cwd thiếu và mở tiếp (resume) được không. Cần mắt người nếu muốn chắc.
- Kết luận cho D5/lane C: Codex khác máy có thể chép native nguyên bản (không cần viết lại cwd để đăng ký được). UI chỉ nên cảnh báo khi cwd nguồn không tồn tại trên máy này. Khuyến nghị: hỏi người dùng có muốn dùng handoff khi cwd thiếu, vì resume trong thư mục không có là điều chưa kiểm.
