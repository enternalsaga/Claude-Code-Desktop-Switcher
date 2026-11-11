# Spec: trình quản lý chung 3 harness (Claude, Codex, Antigravity) và đồng bộ qua Google Drive

- Ngày: 2026-11-11
- Trạng thái: đã duyệt (orchestra, 2026-11-11, 20955bb), Q1–Q12 theo mặc định
- Phạm vi: chỉ thiết kế. Chưa có plan, chưa có code.
- Nhánh gốc: `desktop-4.29-patches` (fork của `PriyanshuGeTRekT/Claude-Code-Desktop-Switcher`)

## 1. Mục tiêu và quyết định đã chốt

Mở rộng Claude Profile Switcher (một file `ClaudeSwitcher.ps1`, PowerShell 5.1, không phụ thuộc gì thêm) thành trình quản lý chung cho ba app desktop:

| Harness | App trên máy này | Ghi chú |
|---|---|---|
| Claude | `Claude` MSIX 5.1231.2.0 | đã hỗ trợ: nhiều account, tray, transfer chat Claude Code |
| Codex | `OpenAI.Codex` MSIX 26.1103.7773.0, exe `app\ChatGPT.exe` | user gọi là "ChatGPT Desktop" |
| Antigravity | `%LOCALAPPDATA%\Programs\Antigravity` (app agent mới) và `...\Antigravity IDE` (bản fork VS Code 1.107) | hai app khác nhau, xem Q2 |

Quyết định của user (2026-11-11), giữ nguyên:

- "ChatGPT Desktop" là app **Codex** desktop (OpenAI.Codex MSIX). App ChatGPT thường nằm ngoài phạm vi.
- Kiểu transfer là **Lai**:
  - Cùng loại harness: chuyển **native**, resume y nguyên (như `Copy-CodeSession` hiện nay).
  - Khác loại harness: **bàn giao ngữ cảnh** (handoff). Xuất transcript sạch rồi mở phiên mới ở harness đích với ngữ cảnh đó.
- Với Antigravity và Codex: nhiều account, transfer chat, launch/tray chung.
- Cloud là **thư mục Google Drive** của account Google mà user chọn (Drive for desktop).
  - Ký tự ổ khác nhau giữa các máy, nên không hardcode.
  - Không ghi email vào code hay vào repo.

Ngoài phạm vi: app ChatGPT thường, macOS/Linux, server riêng, đồng bộ hai chiều tự động theo thời gian thực.

## 2. Kết quả thăm dò (2026-11-11, chỉ đọc)

Ký hiệu: **[XM]** đã xác minh trên máy, **[GĐ]** là giả định, cần spike ở giai đoạn 0.

### 2.1 Claude

- [XM] Metadata phiên nằm ở `claude-code-sessions\<account>\<org>\local_<id>.json`.
  - Trên Store build 4.29+, profile Default nằm dưới `%LOCALAPPDATA%\Claude-Data\claude_<pkgid>\`. Script đã xử lý chỗ này trong `Get-CodeSessionRoot`.
- [XM] `local_*.json` có các trường `sessionId`, `cliSessionId`, `cwd`, `originCwd`, `title`, `lastActivityAt`, `forkedFromSessionId`, `model`, …
- [XM] Transcript thật nằm ở `~\.claude\projects\<slug(cwd)>\<cliSessionId>.jsonl`, cạnh một thư mục cùng tên (subagent, tool results).
  - Slug thay `:`, `\` và `_` bằng `-`. Ví dụ `H:\AI_Software\Claude-Code-Desktop-Switcher` thành `H--AI-Software-Claude-Code-Desktop-Switcher`.
  - Các account trên cùng máy dùng chung thư mục này. Vì vậy transfer hiện nay chỉ chép `local_*.json`.
  - Sang máy khác thì phải mang theo cả jsonl và thư mục đi kèm.
- [XM] Transfer hiện có (`Copy-CodeSession`) đã xử lý: thay account/org, so `lastActivityAt`, đồng bộ tên chat, kéo theo cả họ fork.

### 2.2 Codex

- [XM] **Nhiều account là việc app hỗ trợ chính thức.** Bundle `app.asar` có:
  - `app.setPath("userData", env.CODEX_ELECTRON_USER_DATA_PATH ?? <AppData>\Codex)`.
  - Khi có `CODEX_ELECTRON_USER_DATA_PATH`, app bỏ qua `requestSingleInstanceLock` (`hasExplicitUserDataPath`).
  - App tôn trọng `CODEX_HOME`. Chính app cũng mở "demo build" bằng `CODEX_HOME=… CODEX_ELECTRON_USER_DATA_PATH=… --user-data-dir=…`.
  - Một profile Codex vì vậy gồm một cặp: `CODEX_HOME` (auth, sessions, sqlite) và user data của Electron.
- [GĐ] Trên Windows MSIX, chạy thẳng `ChatGPT.exe` kèm hai biến môi trường đó thì hai instance chạy song song. Script đang làm đúng cách này với `Claude.exe`, nhưng với Codex chưa chạy thử.
- [XM] `~\.codex` gồm:
  - `auth.json` (khóa: `OPENAI_API_KEY`, `auth_mode`), `config.toml`, `session_index.jsonl`, `history.jsonl`;
  - `state_5.sqlite` (bảng `threads`: `id`, `rollout_path`, `cwd`, `title`, `source`, `thread_source`, `archived`, `creator_account_id`, `project_id`, …);
  - `thread_history_1.sqlite` (1,8 GB: `thread_turns`, `thread_items.item_json`, `thread_history_projection_state` với byte offset vào rollout);
  - `sessions\YYYY\MM\DD\rollout-<ts>-<threadId>.jsonl` hoặc `.jsonl.zst`. Máy này có 1240 file zst và 116 file jsonl thường.
- [XM] Rollout là nguồn gốc. Dòng đầu là `session_meta` (`id`, `cwd`, `source`, `originator`, `cli_version`, `history_mode`, …). Các dòng sau là `response_item`, `event_msg`, `turn_context`, `token_usage_record`, …
  - Hai DB là chỉ mục và projection dẫn xuất từ rollout. `rollout_migration_state` `legacy_to_paginated_v1` đã chạy xong.
- [XM] **Codex tự nhập được phiên Claude Code.**
  - `~\.codex\external_agent_session_imports.json` có 568 bản ghi `{source_path: ~\.claude\projects\…jsonl, content_sha256, imported_thread_id, title}`.
  - App-server có các method `externalAgentConfig/detect` và `externalAgentConfig/import` với `itemType: "SESSIONS"` và `SessionMigration {cwd, path, title}`. Đã xác nhận qua `codex app-server generate-json-schema`.
- [XM] `thread/resume` và `thread/fork` chỉ nhận `threadId`, không nhận đường dẫn rollout. Nhập native một rollout vào `CODEX_HOME` khác vì vậy chưa có API chính thức. **[GĐ]** Cách khả dĩ: thả file vào `sessions\…` rồi để Codex tự lập chỉ mục, hoặc ghi dòng `threads`.
- [GĐ] Rollout có item `reasoning` mang `encrypted_content`. Item này có thể không giải mã được khi resume dưới account hay org khác.
- [XM] Codex CLI 0.167.1 có trong PATH (npm), và app ship kèm `codex.exe`.
- [XM] Trên máy có công cụ thứ ba "Cockpit" đang thao tác trên `~\.codex` (`.cockpit_codex_auth.json`, `cockpit-model-catalog.json`).
  - Profile mới của switcher dùng `CODEX_HOME` riêng nên không đụng nó.
  - Riêng profile Default (`~\.codex`) thì Cockpit cũng đang quản lý.

### 2.3 Antigravity

- [XM] Có hai app:
  - **Antigravity**: Electron, có `resources\bin\language_server.exe`.
  - **Antigravity IDE**: fork VS Code, `product.json` có `dataFolderName: .antigravity-ide`, `urlProtocol: antigravity-ide`, `win32MutexName: antigravity-ide`, AUMID `Google.AntigravityIDE`.
- [XM] Dữ liệu agent nằm chung ở `~\.gemini\antigravity\`: `conversations\`, `brain\`, `annotations\`, `conversation_summaries.db`, `user_settings.pb`, `mcp_config.json`, …
- [XM] `conversations\` có 44 file `<uuid>.db` và 100 file `<uuid>.pb`.
  - `.pb` là định dạng cũ, entropy cao, nhiều khả năng **đã mã hóa**. Coi như không đọc được.
  - `.db` là SQLite, mỗi conversation một file. Các bảng: `trajectory_meta(trajectory_id, cascade_id, trajectory_type, source)`, `steps(idx, step_type, status, metadata, step_payload, …)` với blob protobuf, `gen_metadata`, `executor_metadata`, `trajectory_metadata_blob`, …
  - Blob là protobuf **không mã hóa**, nhưng không có file `.proto`. Chỉ giải mã chung theo wire format được, tức là rút ra được chuỗi văn bản mà không biết nghĩa từng trường.
- [XM] `brain\<id>\` chứa artifact markdown (`task.md`, `implementation_plan.md`, `walkthrough.md`). Dùng rất tốt cho handoff.
- [XM] Trong `language_server.exe` có chuỗi `ANTIGRAVITY_GEMINI_DIR`, `ANTIGRAVITY_APP_DATA_DIR`, các trường proto `gemini_dir` / `app_data_dir`, và câu SQL `app_data_dir = ? AND …`.
  - **[GĐ]** Đặt `ANTIGRAVITY_GEMINI_DIR` có thể tách dữ liệu agent cho từng profile. Chưa chạy thử.
  - **[GĐ]** Electron của Antigravity nhận `--user-data-dir`, nên phiên đăng nhập Google tách theo profile. Bản IDE gần như chắc chắn nhận vì là fork VS Code.
- [GĐ] Conversation có thể gắn với account Google ở phía server (cascade_id). Mở `.db` dưới account khác có thể không tiếp tục được.

### 2.4 Google Drive for desktop

- [XM] `HKCU\Software\Google\DriveFS\PerAccountPreferences` ánh xạ account token (ID số) sang ổ mount (`mount_point_path`). Máy này có hai account, mount ở hai ổ khác nhau.
  - Nhãn volume có dạng `<email> - Google Drive`, đủ để hiện trong hộp chọn mà không phải lưu email.
  - Thư mục gốc là `<ổ>:\My Drive\`. Cache nội dung đặt ở `ContentCachePath`.
- [GĐ] Token là ID account Google, giống nhau trên mọi máy. Nếu sai thì dùng phương án dự phòng: user chọn lại ổ trên máy mới, một lần.
- [GĐ] Ổ DriveFS ở chế độ streaming: file chỉ tải về khi được đọc, không có khóa file liên máy, và xung đột tạo ra bản `name (1).ext`.
  - SQLite (WAL) đặt trên ổ này dễ hỏng, nên **không bao giờ** mở DB trực tiếp trên Drive.

### 2.5 Nền tảng

- [XM] `C:\Windows\System32\winsqlite3.dll` có sẵn trên Windows 10/11. Gọi P/Invoke qua `Add-Type` thì đọc được SQLite mà vẫn giữ nguyên tắc "không phụ thuộc". [GĐ] Chưa thử trên PS 5.1.
- [XM] Windows không có sẵn zstd. Tránh phải giải nén:
  - Muốn đọc nội dung Codex thì đọc `thread_history_1.sqlite.thread_items` (mọi thread đều đã ở `history_mode=paginated`).
  - Muốn chuyển native thì chép nguyên file `.zst`.
- [XM] Test hiện tại lấy hàm ra từ AST của đúng một file `ClaudeSwitcher.ps1` theo tên. CI chạy parse check cùng các test transfer trên PS 5.1 và PS 7.

## 3. Kiến trúc

### 3.1 Bố cục mã nguồn và khả năng merge với upstream

Đề xuất: **giữ `ClaudeSwitcher.ps1` làm entry point, sửa ít nhất có thể. Mã mới đặt trong file riêng.**

```
ClaudeSwitcher.ps1            entry, UI chính, Claude (upstream + các local patch hiện có)
src/Harness.Core.ps1          registry adapter, kiểu dữ liệu chung, bundle, redaction, crypto, winsqlite
src/Harness.Claude.ps1        adapter Claude: bọc các hàm sẵn có (Get-CodeSessions, Copy-CodeSession…)
src/Harness.Codex.Profiles.ps1       adapter Codex: Detect, profile, launch, nhận diện instance (lane 2a)
src/Harness.Codex.Chats.ps1          adapter Codex: ListChats, Export, ImportNative, Codex import (lane 2b)
src/Harness.Antigravity.Profiles.ps1 adapter Antigravity: Detect, profile, launch (lane 3a)
src/Harness.Antigravity.Chats.ps1    adapter Antigravity: ListChats, Export, ImportNative (lane 3a/3b)
src/Sync.Drive.ps1            dò Drive, push/pull bundle, path map
src/Ui.Harness.ps1            dialog transfer mới, tab harness, menu tray theo harness
tools/Build-SingleFile.ps1    ghép src/*.ps1 vào giữa marker để ra dist/ClaudeSwitcher.ps1 cho bản release một file
tests/*.Tests.ps1             nạp hàm từ nhiều file qua một helper chung
```

- Trong `ClaudeSwitcher.ps1` chỉ thêm 3 điểm móc, mỗi điểm vài dòng:
  1. dot-source `src\*.ps1` (khi chạy từ bản clone hoặc từ thư mục đã cài);
  2. gọi `Register-Harnesses` sau khi phát hiện Claude;
  3. nút và menu gọi `Show-HarnessTransferDialog` cùng `Add-HarnessTrayItems`.
- Upstream sửa `ClaudeSwitcher.ps1` thì ta vẫn merge được, vì xung đột chỉ rơi vào 3 điểm móc.
- `-Install` chép cả `src\` vào `%LOCALAPPDATA%\ClaudeProfiles\.switcher\`. Cài một dòng (`irm …`) thì dùng bản `dist` đã ghép.
- `Show-TransferDialog` cũ giữ nguyên cho tới khi dialog mới thay thế được nó, rồi mới bỏ trong một commit riêng.
- Tên app vẫn để "Claude Profile Switcher" cho tới khi có quyết định khác (Q1).
- **Mỗi file chỉ một lane ghi** (orchestra, 2026-11-11). Adapter tách thành hai file `*.Profiles.ps1` và `*.Chats.ps1`, rồi gộp lại trong một hàm đăng ký nằm ở file `*.Profiles.ps1`. Hàm đăng ký nhận các năng lực về chat theo tên hàm, nên lane chat không phải sửa file profile.

### 3.2 Mô hình adapter

Mỗi harness đăng ký một hashtable chứa scriptblock. Không dùng class của PowerShell vì class dễ vỡ khi dot-source trên PS 5.1.

| Năng lực | Chữ ký (tóm tắt) | Claude | Codex | Antigravity |
|---|---|---|---|---|
| `Detect` | → `{Installed, Kind, Exe, Version, Aumid}` | có sẵn (`Find-ClaudeInstall`) | `Get-AppxPackage OpenAI.Codex` | thư mục `Programs\Antigravity*` |
| `GetProfiles` | → `[{Id, Name, Paths, IsDefault, Pid}]` | có sẵn | Default + `CodexProfile-<Id>` | Default + `AgyProfile-<Id>` (nếu S4 đạt) |
| `NewProfile` / `RemoveProfile` / `Rename` | | có sẵn | tạo cặp thư mục | tạo thư mục |
| `Launch` | `(profile)` → `started` / `focused` | có sẵn | đặt env, chạy `ChatGPT.exe` | `--user-data-dir` (+ env S4) |
| `ListChats` | `(profile)` → `[{ChatId, Title, Cwd, Updated, Activity, Parent}]` | `Get-CodeSessions` | `state_5.sqlite.threads` (bản sao tạm) | `conversation_summaries.db` + `conversations\*.db` |
| `Export` | `(chat)` → bundle (native + transcript) | jsonl + local json | rollout + dòng threads | `.db` + `brain\<id>` |
| `ImportNative` | `(bundle, profile)` → `copied` / `updated` / `exists` / `renamed` | `Copy-CodeSession` mở rộng | S2 | S5, tùy chọn |
| `ImportHandoff` | `(bundle, profile)` → mở phiên mới | chung | chung | chung |
| `ImportNeedsClose` | → bool | false (cần mở lại app mới thấy) | true nếu S2 yêu cầu | true |

Quy tắc chọn kiểu transfer:

- Cùng harness thì dùng `ImportNative`. Nếu adapter chưa hỗ trợ native thì dùng `ImportHandoff` và hiện rõ trên dòng đó.
- Khác harness thì dùng `ImportHandoff`.
  - Ngoại lệ đề xuất (Q3): **Claude → Codex** đi qua bộ nhập chính thức của Codex (`externalAgentConfig/import`, SESSIONS). Đây là đường của chính Codex, giữ lịch sử tốt hơn handoff.

### 3.3 Profile theo từng harness

- **Claude**: giữ nguyên như hiện tại.
- **Codex**:
  - Default dùng `~\.codex` và userData mặc định của package.
  - Profile thêm: `CODEX_HOME=%USERPROFILE%\.codex-profiles\<Id>` và `CODEX_ELECTRON_USER_DATA_PATH=%USERPROFILE%\.codex-profiles\<Id>\electron`.
    - Đặt ngoài AppData để MSIX không chuyển hướng ghi vào `LocalCache`. Ghi chú `/multi-session-handoff` cũng cảnh báo điều này.
  - Đăng nhập lần đầu ngay trong app.
  - Nhận diện instance đang chạy: lọc `Win32_Process` theo đường dẫn `ChatGPT.exe` trong package, loại các process `--type=`, rồi đọc biến môi trường. Biến môi trường không đọc được qua WMI, nên đối chiếu theo `--user-data-dir=` đặt thêm vào dòng lệnh.
- **Antigravity**:
  - Profile thêm dùng `--user-data-dir=%LOCALAPPDATA%\AgyProfile-<Id>` và `ANTIGRAVITY_GEMINI_DIR=%USERPROFILE%\.gemini-profiles\<Id>` (S4).
  - Nếu S4 thất bại thì Antigravity chỉ có một account. Switcher vẫn launch được và vẫn transfer handoff; nút Add account cho Antigravity bị ẩn.
- Settings vẫn ở `%LOCALAPPDATA%\ClaudeProfiles\settings.json`, thêm khóa `Harnesses.<harness>.Labels`, `ProfileEnv` và `ProfileArgs` theo harness. Khóa cũ không có tiền tố harness được hiểu là của Claude, để tương thích ngược.

## 4. Định dạng bundle (`harness-bundle` v1)

Mỗi lần xuất ra một file zip `<bundleId>.hbundle.zip`, tạo bằng `System.IO.Compression` (có sẵn trong .NET 4.5+). Nội dung:

```
manifest.json
native/…                 file gốc, giữ nguyên byte (Claude: local_*.json, <cli>.jsonl, <cli>/…;
                         Codex: rollout-*.jsonl[.zst], threads-row.json; Antigravity: <id>.db, brain/<id>/…)
transcript.md            bản sạch để đọc và handoff
transcript.jsonl         dạng chuẩn hóa: {"role":"user|assistant|tool","text":…,"ts":…,"tool":{…}?}
```

`manifest.json`:

```json
{
  "format": "harness-bundle",
  "version": 1,
  "bundleId": "uuid",
  "chatKey": "codex:01a1c8bf-…",
  "source": {
    "harness": "codex", "harnessVersion": "26.1103.7773.0",
    "profileLabel": "Work", "machineId": "uuid", "machineName": "Desktop-1",
    "chatId": "…", "parentChatId": null, "title": "…",
    "cwd": { "absolute": "H:\\AI_Software\\x", "root": "AI_Software", "relative": "x" },
    "createdAt": 0, "lastActivityAt": 0
  },
  "files": [ { "role": "native|transcript|artifact", "path": "native/…", "size": 0, "sha256": "…" } ],
  "lineage": { "previousBundleId": null, "contentSha256": "…" },
  "redaction": { "scanned": true, "findings": 0, "transcriptRedacted": true },
  "encryption": null
}
```

- `chatKey` là khóa ổn định của một cuộc chat, tạo từ harness nguồn và id gốc. Chat đó tiếp tục ở máy khác thì vẫn giữ `chatKey`.
- Tạo `transcript.md`:
  - Chỉ lấy text của user và assistant.
  - Mỗi tool call rút gọn thành một dòng (tên tool, tham số chính). Output dài cắt còn 2 KB.
  - Bỏ reasoning đã mã hóa.
  - Thêm phần đầu gồm: harness nguồn, cwd, tên nhánh git nếu có, danh sách artifact.
- Handoff dài: giữ trọn N lượt cuối (mặc định 40) cộng với tóm tắt cơ học các lượt trước (tiêu đề và câu đầu của user), để không vượt context của harness đích.

## 5. Handoff vào harness đích

Một cơ chế chung, không phụ thuộc vào API riêng của app:

1. Ghi `transcript.md` ra `%LOCALAPPDATA%\ClaudeProfiles\.switcher\handoff\<bundleId>.md`.
   - Không ghi vào repo của user, để tránh commit nhầm (Q6).
2. Soạn câu mở đầu: `Tiếp tục công việc từ phiên <harness> "<title>". Đọc ngữ cảnh ở <đường dẫn file> rồi tóm tắt trạng thái trước khi làm tiếp.`
3. Đưa câu mở đầu đó vào phiên mới, theo thứ tự ưu tiên:
   - deep link của app đích có chỗ cho prompt và thư mục (S7: `claude://`, `codex://` với `--single-argument`, `antigravity-ide://`);
   - nếu không có, chép vào clipboard rồi launch profile đích (với IDE thì mở đúng cwd) và hiện hướng dẫn "dán vào ô chat".
4. Ghi lại một dòng vào `handoff-log.jsonl` (bundleId, đích, thời gian).

## 6. Chuyển native theo từng harness

- **Claude → Claude, cùng máy**: giữ nguyên `Copy-CodeSession`.
- **Claude → Claude, khác máy (qua Drive)**: thêm bước chép `<cli>.jsonl` và thư mục `<cli>\` vào `~\.claude\projects\<slug(cwd đã ánh xạ)>\`.
  - Đổi các chuỗi cwd: chỉ thay giá trị chuỗi JSON nằm trọn trong key `cwd`/`originCwd` hoặc bắt đầu bằng gốc cũ, không replace mù.
  - Nếu file đích đã có thì so `lastActivityAt` như hiện nay.
- **Codex → Codex** (S2):
  - Chép rollout, giữ nguyên tên file, vào `<CODEX_HOME đích>\sessions\YYYY\MM\DD\`.
  - Sau đó, theo kết quả S2: (a) để Codex tự lập chỉ mục khi khởi động, hoặc (b) chèn dòng `threads` theo `threads-row.json`, chỉ khi app đích đã đóng.
  - Không bao giờ ghi vào `thread_history_1.sqlite`. Đó là projection, Codex tự dựng lại theo byte offset.
  - Nếu S2 cho thấy reasoning mã hóa làm hỏng resume khi khác account: native chỉ bật cho cùng account. Khác account thì dùng handoff.
- **Claude → Codex** (Q3): gọi `externalAgentConfig/import` lên app-server của profile đích, chạy `codex app-server` với `CODEX_HOME` của profile đó, truyền `SessionMigration {path: <jsonl>, cwd, title}`.
  - Khi profile đích đang chạy thì dùng `codex app-server proxy` vào daemon của nó (S3).
- **Antigravity → Antigravity** (S5, tùy chọn, giai đoạn 3b): chép `<id>.db` và `brain\<id>\` sang thư mục gemini của profile đích, khi app đã đóng.
  - Chỉ bật nếu S5 chứng minh conversation mở và tiếp tục được. Ngược lại thì dùng handoff.
  - File `.pb` cũ không chuyển được, và dialog ghi rõ lý do.

## 7. Đồng bộ qua Google Drive

### 7.1 Chọn và dò thư mục

- Settings lưu `Sync.DriveAccountToken` (ID số, không phải email) và `Sync.Folder` (đường dẫn tương đối dưới `My Drive`, mặc định `HarnessSync`).
- Khi chạy: đọc `PerAccountPreferences` để lấy ổ của token, ghép thành `<ổ>:\My Drive\HarnessSync`.
- Không tìm thấy token hoặc ổ thì hiện hộp chọn liệt kê các ổ DriveFS theo nhãn volume, user chọn lại một lần trên máy mới.
- Phương án dự phòng: user trỏ tay vào một thư mục bất kỳ (`Sync.CustomPath`), dùng được cả với OneDrive.

### 7.2 Layout thư mục

```
HarnessSync/
  sync.json                         {format, version, kdf:{salt, iterations}, keyCheck}   chỉ máy đầu tiên tạo
  machines/<machineId>.json         {name, lastSeen, harnesses, pathRoots:{AI_Software:"H:\\AI_Software"}}
  index/<machineId>.jsonl           mỗi dòng: {bundleId, chatKey, harness, title, lastActivityAt, path, size}
  bundles/<harness>/<chatKey>/<bundleId>.hbundle.zip[.enc]
```

- **Mỗi file chỉ có một máy ghi.** `machines/<id>.json` và `index/<id>.jsonl` thuộc máy đó. Mỗi bundle là bất biến và mang tên duy nhất, nên không cần khóa liên máy và không bao giờ có hai máy ghi cùng một file.
- Ghi theo kiểu nguyên tử: ghi `*.tmp` trong cùng thư mục, xong rồi mới đổi tên. Bên đọc bỏ qua file `*.tmp` và kiểm `sha256` theo `index` trước khi giải nén.
- `machineId` là GUID sinh một lần, lưu trong settings local.
- Đọc bundle: chép về `%TEMP%` trước khi giải nén, vì có thể phải chờ Drive tải về. SQLite trong bundle chỉ được mở từ bản local.
- Dọn dẹp: mỗi máy chỉ xóa bundle do chính nó tạo, giữ lại 3 bản mới nhất cho mỗi `chatKey` (Q8).
- Gặp file xung đột `… (1).zip` thì coi là bản trùng và bỏ qua. Nhờ tên duy nhất, trường hợp này gần như không xảy ra.

### 7.3 Push và pull

- **Push**: từ dialog transfer chọn đích "Google Drive". Thao tác này xuất bundle, mã hóa, ghi vào `bundles/…`, rồi nối thêm một dòng vào `index/<mình>.jsonl`.
- **Pull**: chọn nguồn "Google Drive".
  - Danh sách lấy từ mọi `index/*.jsonl`, gộp theo `chatKey` và giữ bản mới nhất, kèm tên máy nguồn.
  - Sau đó chọn profile đích, rồi native hoặc handoff theo quy tắc ở 3.2.
- Phân kỳ, khi hai máy cùng tiếp tục một chat: nếu `lastActivityAt` của bản local lớn hơn bản trên Drive, và `lineage.contentSha256` của bản local không có trong chuỗi lineage của bundle, thì chat đã phân kỳ.
  - Mặc định nhập thành bản sao mới, có id mới và tiêu đề kèm hậu tố ` (từ <máy>)`, không ghi đè (Q7).
- Không đồng bộ tự động ở nền trong v1, chỉ thao tác tay. Đồng bộ theo lịch để sau.

### 7.4 Ánh xạ đường dẫn

- Mỗi máy khai `pathRoots`, là các gốc có tên. Khi xuất, cwd được lưu dạng `{root, relative}` theo gốc dài nhất khớp.
- Khi nhập: tra `pathRoots` của máy đích theo tên gốc.
  - Không có thì hỏi user chọn thư mục và ghi nhớ.
  - Thư mục đích không tồn tại thì vẫn nhập, nhưng cảnh báo rằng phiên cần cwd để resume.

## 8. Bảo mật

- Transcript có thể chứa secret: API key, token, nội dung `.env`, output của lệnh.
- **Quét**: bộ regex gồm `sk-…`, `sk-ant-…`, `ghp_/gho_/github_pat_`, `AKIA…`, `xox[abp]-`, `AIza…`, `-----BEGIN … PRIVATE KEY-----`, `Bearer …`, và dòng dạng `KEY=…` có tên chứa `KEY|TOKEN|SECRET|PASSWORD`.
  - `transcript.md` và `transcript.jsonl` luôn được che (redact). Che thì không tốn gì, và handoff không cần giá trị thật.
  - File native thì **không sửa**, vì sửa có thể làm hỏng hash hoặc offset. Chỉ đếm số phát hiện, ghi vào manifest và cảnh báo trên UI.
- **Mã hóa khi lên Drive**, mặc định bật và bắt buộc khi native có phát hiện secret:
  - AES-256-CBC kết hợp HMAC-SHA256 (encrypt-then-MAC). .NET Framework 4.x không có `AesGcm`, nên dùng cách này.
  - Khóa dẫn xuất từ passphrase bằng PBKDF2-SHA256, 600.000 vòng (`Rfc2898DeriveBytes` với `HashAlgorithmName`, có từ .NET 4.7.2), salt lấy từ `sync.json`.
  - `keyCheck` là HMAC của một hằng số, để báo sai passphrase ngay lập tức.
  - DPAPI **chỉ dùng để cache passphrase trên từng máy** (CurrentUser). Máy mới hỏi passphrase một lần.
  - Không có dịch vụ khóa nào. Mất passphrase thì mất các bundle đã mã hóa.
  - **Lần đầu bật sync** (orchestra, 2026-11-11): UI bắt buộc hỏi passphrase, nhập hai lần, và hiện rõ dòng "Mất passphrase = mất bundle trên Drive (dữ liệu gốc trên máy vẫn còn)". User phải tick xác nhận đã đọc thì mới bật được.
- Không đưa vào bundle: `auth.json`, cookies, `config.json` của profile, hoặc bất kỳ file nào nằm ngoài danh sách native của adapter. Phần này là danh sách cho phép (allowlist), không phải danh sách chặn.
- Repo không chứa email, token Drive hay đường dẫn cá nhân. Test dùng fixture giả.

## 9. UI và tray

- **Cửa sổ chính**:
  - Hàng tab lọc `Tất cả | Claude | Codex | Antigravity` phía trên danh sách. Mỗi dòng có biểu tượng harness cạnh badge màu sẵn có.
  - **Add account** thành nút tách đôi, chọn harness. Harness nào không có trên máy thì ẩn.
  - Các nút Launch, Rename, Delete và Shortcut hoạt động theo adapter.
- **Shortcut và taskbar**:
  - `Codex - <name>` và `Antigravity - <name>` dùng cùng cơ chế icon badge và AUMID riêng như Claude.
  - Phần identity taskbar cho Codex và Antigravity là "nên có", làm sau (Q9).
- **Tray**: mỗi harness một submenu, liệt kê profile kèm dấu tick cho profile đang mở, thêm "Add account". Ngoài ra có mục "Transfer chats…" và "Sync: Push/Pull".
- **Dialog transfer mới** (`Show-HarnessTransferDialog`):
  - Nguồn: harness + profile, hoặc "Google Drive".
  - Danh sách chat giữ các bộ lọc hiện có (fork family, thời gian, thư mục).
  - Đích: harness + profile, hoặc "Google Drive".
  - Cột "Kiểu" hiện `Native`, `Handoff` hoặc `Codex import` cho từng dòng.
  - Có cảnh báo secret, và cảnh báo "cần đóng app đích".
- **CLI**:
  - `-Harness codex|antigravity|claude` dùng được với `-Launch`, `-List`, `-AddAccount` và `-Shortcut`. Mặc định là `claude` để tương thích.
  - Thêm `-Export <chatId> -Harness … -Profile …`, `-Import <bundle>`, `-SyncPush`, `-SyncPull`.

## 10. Rủi ro

| Rủi ro | Ảnh hưởng | Giảm thiểu |
|---|---|---|
| App cập nhật làm đổi schema (Codex sqlite, Antigravity proto) | native hỏng | đọc qua bản sao; kiểm `_sqlx_migrations` hoặc phiên bản app; không khớp thì tự rơi về handoff |
| Ghi vào DB khi app đang chạy | hỏng DB | native nào cần ghi DB thì đòi đóng app đích; Codex ưu tiên đi qua app-server |
| Reasoning mã hóa của Codex khi khác account | resume lỗi | S2; khác account thì handoff |
| Drive streaming chậm hoặc file chưa tải xong | treo UI | chép về tạm có tiến độ, chạy job nền, kiểm sha256 |
| Mất passphrase | mất bundle mã hóa | cảnh báo khi bật; bundle chỉ là bản sao, dữ liệu gốc vẫn ở máy nguồn |
| Fork lệch xa upstream | khó merge | chỉ 3 điểm móc trong file upstream; mã mới nằm trong `src\` |
| Cockpit cùng quản lý `~\.codex` | xung đột auth ở Default | không đụng auth của Default; profile thêm dùng `CODEX_HOME` riêng |

## 11. Giai đoạn và lane

**GĐ0: spike**, chỉ thử trên thư mục tạm và profile thử, không đụng dữ liệu thật. Mỗi spike có kết quả rõ đạt hay không đạt, ghi vào `docs/specs/` thành phụ lục.

S1 và S4 là **USER ACTION**: script dựng profile tạm và launch app, rồi dừng lại để user tự đăng nhập account thứ hai. S2, S3, S5, S6 và S7 chạy không cần user. Riêng trường hợp "khác account" của S2 phải chờ S1 xong.

| Spike | Câu hỏi | Đạt khi |
|---|---|---|
| S1 (USER ACTION) | Codex MSIX chạy 2 instance song song với `CODEX_HOME` + `CODEX_ELECTRON_USER_DATA_PATH` + `--user-data-dir` | hai cửa sổ, hai account, không chồng dữ liệu; biết đường dẫn thực tế có bị MSIX chuyển hướng không |
| S2 | Rollout Codex chép sang `CODEX_HOME` khác có hiện ra và resume được không; với cùng account và khác account | thread hiện trong app, tiếp tục được |
| S3 | `externalAgentConfig/import` SESSIONS gọi được từ script, qua `codex app-server` stdio hoặc `proxy` | phiên Claude hiện trong Codex của profile đích |
| S4 (USER ACTION) | Antigravity nhận `--user-data-dir` + `ANTIGRAVITY_GEMINI_DIR` để chạy hai account | hai account, `conversations` tách riêng |
| S5 | `.db` của Antigravity: rút được transcript; chép sang profile khác có mở lại được không | transcript đọc được; native đạt hoặc không đạt |
| S6 | Đọc SQLite qua `winsqlite3.dll` bằng P/Invoke trên PS 5.1 và PS 7 | đọc được bảng `threads` từ bản sao |
| S7 | Deep link mở phiên mới kèm prompt và thư mục cho từng app | có hoặc không, kèm cú pháp |

**GĐ1: lõi**, làm tuần tự, một lane:

- `Harness.Core` (registry, bundle, redaction, winsqlite) và adapter Claude bọc mã có sẵn, không đổi hành vi. Test transfer cũ phải giữ xanh.
- Xuất và handoff chung trên cùng máy (Claude → file → handoff vào Claude) để chạy thử đường đi đầu đến cuối.
- Thêm 3 điểm móc trong `ClaudeSwitcher.ps1`, `tools/Build-SingleFile.ps1`, và helper nạp test từ nhiều file.

**GĐ2: Codex**, sau GĐ1:

- Profile, launch, tray, shortcut (lane 2a).
- `ListChats`, xuất, handoff Claude ↔ Codex, native Codex ↔ Codex theo S2, Codex import theo S3 (lane 2b).
- 2a ghi `src\Harness.Codex.Profiles.ps1`, 2b ghi `src\Harness.Codex.Chats.ps1`. Hai lane không ghi chung file nào nên chạy song song được. Lane 2a land trước vì nó chứa hàm đăng ký.

**GĐ3: Antigravity**, chạy song song với GĐ2 được, vì dùng file riêng:

- 3a: launch, tray, profile nếu S4 đạt (`src\Harness.Antigravity.Profiles.ps1`); xuất transcript, handoff vào và ra (`src\Harness.Antigravity.Chats.ps1`).
- 3b, tùy chọn: native theo S5. Lane này ghi `Harness.Antigravity.Chats.ps1` sau khi 3a land, hoặc nhận đúng hàm `Import-AgyNative` theo ngoại lệ có giới hạn.

**GĐ4: Drive sync**, sau GĐ2:

- Dò Drive, settings, layout, push/pull, mã hóa, path map, phân kỳ, dọn dẹp.
- Native Claude khác máy, có mang theo jsonl.

**GĐ5: UI hoàn thiện**: dialog mới thay dialog cũ, tab harness, CLI, README.

Khi có hai lane cùng sửa `src\Ui.Harness.ps1`, áp dụng ngoại lệ có giới hạn: mỗi adapter chỉ thêm một mục đăng ký menu (≤ 5 dòng), còn phần khung UI thuộc về GĐ1.

## 12. Câu hỏi mở và mặc định đề xuất

| # | Câu hỏi | Mặc định đề xuất |
|---|---|---|
| Q1 | Có đổi tên app, ví dụ "AI Desktop Switcher", hay giữ "Claude Profile Switcher"? | Giữ tên file và tên repo để dễ merge. Chỉ đổi tiêu đề cửa sổ thành "Profile Switcher" ở GĐ5 |
| Q2 | Hỗ trợ Antigravity (app agent), Antigravity IDE, hay cả hai? | Cả hai, coi là một harness có 2 `Kind`, vì dùng chung `~\.gemini\antigravity`. Launch chọn theo `Kind`. Ưu tiên app agent |
| Q3 | Claude → Codex dùng bộ nhập chính thức của Codex thay vì handoff? | Có, khi S3 đạt. Đây vẫn là đường do chính Codex cung cấp. Không đạt thì dùng handoff |
| Q4 | Codex → Claude hay Antigravity → Claude có cố làm native không? | Không. Chỉ handoff, đúng quyết định "Lai" |
| Q5 | Đồng bộ Drive mặc định có mã hóa không? | **Chốt (orchestra, 2026-11-11):** bật mặc định. Passphrase do user đặt, cache bằng DPAPI trên từng máy. Lần đầu bật sync, UI hỏi passphrase kèm cảnh báo mất passphrase = mất bundle |
| Q6 | File handoff ghi ở đâu? | `.switcher\handoff\` (ngoài repo). Tùy chọn ghi vào `<cwd>\.handoff\` kèm cảnh báo `.gitignore` |
| Q7 | Chat phân kỳ giữa hai máy thì làm gì? | Nhập thành bản sao mới, tiêu đề có hậu tố máy nguồn. Không ghi đè |
| Q8 | Giữ bao nhiêu bản bundle trên Drive cho mỗi chat? | 3 bản mới nhất. Mỗi máy chỉ dọn bản của chính nó |
| Q9 | Codex và Antigravity có cần taskbar identity riêng (AUMID, badge) như Claude không? | Có, nhưng để GĐ5 |
| Q10 | Có đồng bộ nền theo lịch không? | Không ở v1, chỉ thao tác tay |
| Q11 | Thư mục profile Codex đặt ở `%USERPROFILE%\.codex-profiles` (ngoài AppData)? | Có, để tránh MSIX chuyển hướng. S1 xác nhận lại |
| Q12 | Có đưa phiên Cowork, Agent hay chat thường của Claude vào không? | Không, chỉ phiên Claude Code như hiện nay |

## 13. Tiêu chí hoàn thành ở mức spec

- Mỗi năng lực trong bảng 3.2 có hành vi xác định cho cả 3 harness, hoặc nói rõ là rơi về handoff.
- Mọi thao tác ghi vào dữ liệu app đều có điều kiện an toàn: đóng app, hoặc đi qua API chính thức, hoặc chỉ ghi file mới.
- Mỗi file trên Drive chỉ có một máy ghi, và có kiểm toàn vẹn.
- Không có secret hay email trong repo. Bundle trên Drive được mã hóa mặc định.
