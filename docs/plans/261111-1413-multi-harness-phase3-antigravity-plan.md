# Plan: Multi-harness GĐ3, Antigravity

- Spec: `docs/specs/261111-1200-multi-harness-manager-and-drive-sync-spec.md` (§2.3, §3.2, §3.3, §5, §6, §11 GĐ3).
- Kết quả spike: `docs/specs/261111-1200-multi-harness-spike-results.md`, các mục S5, S6, S7 và S4 (đợt 1 và 2).
- Base: `5e223ee` trên `desktop-4.29-patches`. Người duyệt: `switcher-think-multiharness` (local_16d53f2d-cb24-4b5c-8d40-db17aa4a98fe). Người land: orchestra.
- Lệnh kiểm tra và quy ước giống plan GĐ0–1 §0.
- Chạy song song với GĐ2 (`docs/plans/261111-1410-multi-harness-phase2-codex-plan.md`).

## 1. Phán quyết và sự thật đầu vào

**Phán quyết của orchestra (2026-11-11):** Antigravity **một account**, ẩn Add account. Mỗi máy chỉ có một account Antigravity trên một user Windows.

| # | Sự thật | Nguồn |
|---|---|---|
| A1 | Hai app riêng biệt. **Antigravity** (`%LOCALAPPDATA%\Programs\Antigravity\Antigravity.exe`) dùng `~\.gemini\antigravity`. **Antigravity IDE** (`…\Antigravity IDE\Antigravity IDE.exe`) dùng `~\.gemini\antigravity-ide` | S4 (Q2) |
| A2 | Đăng nhập nằm ở Windows Credential Manager, mục `gemini:antigravity`, dùng chung cho mọi profile. Tách đăng nhập không làm được | S4 đợt 2 |
| A3 | Mỗi conversation có `conversations\<id>.db` (SQLite, blob protobuf không mã hóa) và `brain\<id>\`. File `.pb` cũ đã mã hóa | S5 |
| A4 | App tự ghi `brain\<id>\.system_generated\logs\transcript.jsonl`: mỗi dòng `{step_index, source, type, status, created_at, content \| thinking \| tool_calls}`. Có ở 44/44 conversation `.db`, không có ở `.pb`. Khoảng 1/72 dòng không phải JSON hợp lệ. Nội dung USER_INPUT bọc trong `<USER_REQUEST>…</USER_REQUEST>` và kèm `<ADDITIONAL_METADATA>` | S5 |
| A5 | Giải mã protobuf chung theo wire format chạy được (74/74 step), đã có bảng `step_type` → vai trò. Mã ở `tools/spikes/S5-AgyDecode.ps1` | S5 |
| A6 | `conversation_summaries.db` có bảng `conversation_summaries` (`conversation_id`, `title`, `preview`, `step_count`, `last_modified_time`, `workspace_uris`, `status`, `parent_conversation_id`, `app_data_dir`, …) và bảng FTS5 | S5, S6 |
| A7 | **Chép native được:** đóng app, chép `<id>.db` và `brain\<id>` vào thư mục antigravity đích, mở lại app. Log báo `restored 1` và conversation hiện trong sidebar. Không cần sửa `conversation_summaries.db`. Chưa thử chat tiếp | S4 đợt 2 |
| A8 | Không có deep link tạo phiên kèm prompt, cho cả hai app. Handoff vào Antigravity dùng clipboard | S7 |

"Native giữa các máy cùng account" là việc chở bundle từ máy này sang máy kia. Phần chở qua Drive thuộc GĐ4. GĐ3 làm export và import bundle dưới dạng **file**: user có thể tự mang file sang, và GĐ4 sẽ dùng lại đúng hai hàm này.

## 2. Lane

**Một lane (lane 3)**, làm tuần tự. Phần profile nhỏ, không đáng tách thành lane riêng.

**Sở hữu:**

- `src/Harness.Antigravity.Profiles.ps1`
- `src/Harness.Antigravity.Chats.ps1`
- `src/Harness.Antigravity.Proto.ps1` (mới; bộ giải mã protobuf, chuyển từ S5)
- `tests/HarnessAntigravity.Tests.ps1`
- `.github/workflows/lint.yml`, theo ngoại lệ chỉ được thêm ở plan GĐ2 §2: nối bước của mình trước `Install PSScriptAnalyzer`, lane land sau giữ cả hai khối.

**Không sửa:**

- `ClaudeSwitcher.ps1`, `src/Ui.Tray.ps1`, `src/Ui.Harness.ps1`, các file Codex.
- Tray và lệnh `-Launch antigravity:<id>` tự có qua hàm chung của lane 2a (`Add-HarnessTrayItems`, `Invoke-HarnessLaunchArg`).
- Dialog transfer tự có qua `Show-HarnessExportDialog` của lane 2b, vì dialog đó duyệt theo registry.
- Lane 3 chỉ cần đăng ký adapter đúng hợp đồng.

**Kiểm mỗi commit:** parse check, `tests\HarnessAntigravity.Tests.ps1`, `tests\HarnessCore.Tests.ps1`.

**Thứ tự land:** độc lập với 2a và 2b.

- Nếu land trước 2a thì Antigravity chưa hiện trong tray cho tới khi 2a land. Như vậy vẫn chấp nhận được.
- Lane land sau (giữa lane 3 và 2b) cherry-pick lên tip mới và giải xung đột `lint.yml` bằng cách giữ cả hai khối.

## 3. Hợp đồng

**Profile object:** mỗi app đã cài là một profile; không có profile tự tạo.

```powershell
[pscustomobject]@{ Harness='antigravity'; Id='app'|'ide'; Name='Antigravity'|'Antigravity IDE'; IsDefault=$true
                   Kind='app'|'ide'; Exe='<abs>'; DataDir='~\.gemini\antigravity' | '~\.gemini\antigravity-ide'; Pid=$int|$null }
```

**Adapter** trong `Register-AntigravityHarness`:

- `DisplayName = 'Antigravity'`
- `Detect`, `GetProfiles`, `Launch`, `ListChats`, `Export`, `ImportNative`, `ImportHandoff`
- `ImportNeedsClose = { $true }`
- **Không có** `NewProfile`, `RemoveProfile`, `Rename`.

**Chat object:**

```powershell
[pscustomobject]@{ ChatId; Title; Cwd; Updated; Activity; Parent; Kind; Format='db'|'pb'; Profile }
```

**`Import-AgyNative` trả:** `copied` | `updated` | `exists` | `kind-mismatch` | `no-native` (bundle từ `.pb` cũ, chỉ có artifact).

## 4. Task

### G1: phát hiện cài đặt, profile, launch

- `Find-AntigravityInstall` trả danh sách `{Kind, Exe, Version, DataDir}` cho mỗi app có exe. Version lấy từ `FileVersionInfo`.
- `Get-AntigravityProfiles` trả mỗi app một profile.
  - `Pid`: lọc `Win32_Process` có tên exe khớp, đường dẫn nằm trong thư mục cài của app đó, không có `--type=`.
  - Bỏ qua instance có `--user-data-dir` trỏ vào `AgyProfile-*` (instance spike).
- `Start-AntigravityProfile -Profile`:
  - đang chạy thì `Show-ProfileWindow` và trả `focused`;
  - không thì `Start-Process <Exe> -WindowStyle Normal`, **không** truyền env hay `--user-data-dir`.
- Test:
  - thư mục cài giả trong `%TEMP%`;
  - thay `Get-CimInstance` và `Start-Process` qua biến scriptblock của script, giống cách lane 2a làm.

### G2: liệt kê chat

- `Get-AntigravityChats -Profile`:
  - Ưu tiên đọc bản sao `<DataDir>\conversation_summaries.db` (`Copy-SqliteSnapshot`):
    - `select conversation_id, title, last_modified_time, workspace_uris, parent_conversation_id, status from conversation_summaries`;
    - lọc `app_data_dir` theo `Kind`: `antigravity` cho `app`, `antigravity-ide` cho `ide`. Giá trị thật của IDE cần xem lúc làm; nếu cột không lọc được thì bỏ lọc, vì mỗi app đã có thư mục riêng.
  - Bổ sung các `conversations\*.pb` không có trong summaries, với `Format='pb'` và tiêu đề lấy từ `brain\<id>\*.md` đầu tiên nếu có.
  - `Cwd` lấy từ phần tử đầu của `workspace_uris`, đổi `file:///h:/x` thành `H:\x`.
  - **Kiểm trước:** winsqlite3 mở và đọc được bảng thường trong một DB có bảng FTS5 không. Nếu lỗi "no such module", đọc `conversations\*.db` (bảng `trajectory_meta`) cộng `brain\` làm phương án dự phòng, và ghi lại.
- Test: fixture `conversation_summaries.db` tạo bằng winsqlite trong `%TEMP%`, gồm bảng thường. Thêm một bảng FTS5 nếu bản winsqlite3 có hỗ trợ. Cộng fixture thư mục `.pb` và `brain`.

### G3: transcript

- `ConvertFrom-AgyTranscriptJsonl -Path`:
  - đọc từng dòng, bỏ qua dòng không parse được và đếm số dòng bỏ;
  - `USER_INPUT` thành `user`: lấy nội dung trong `<USER_REQUEST>`, bỏ `<ADDITIONAL_METADATA>`;
  - `PLANNER_RESPONSE` thành `assistant`: lấy `content`, bỏ `thinking`;
  - `tool_calls` thành entry tool, gồm tên và tham số chính: `toolSummary`, hoặc `command` / `path` nếu có;
  - các `type` hệ thống (`SYSTEM_MESSAGE`, `CHECKPOINT`, `CONVERSATION_HISTORY`, `ERROR_MESSAGE`) bị bỏ.
- `src/Harness.Antigravity.Proto.ps1`: chuyển bộ giải mã C# của S5 vào file này, dọn cho gọn, với hai hàm:
  - `ConvertFrom-AgyProtobuf -Bytes` trả cây trường;
  - `ConvertFrom-AgyDb -Path` đọc bản sao `.db` qua `Invoke-SqliteQuery`, áp bảng `step_type` → vai trò và đường dẫn trường theo S5, trả entry chuẩn hóa.
  - Chỉ dùng khi thiếu `transcript.jsonl`.
- `.pb`: không có transcript. Bundle chỉ gồm artifact `brain\<id>\*.md`.
- Test:
  - fixture `transcript.jsonl` tổng hợp: có một dòng hỏng, có `<USER_REQUEST>`, có `tool_calls`, có thinking. Kiểm thinking bị bỏ và metadata bị bỏ;
  - fixture protobuf nhỏ, tạo bằng byte cố định trong test: kiểm decode varint, length-delimited lồng nhau và chuỗi UTF-8.

### G4: export và native

- `Export-AgyChat -Chat -OutPath`. `native/` gồm:
  - `conversations/<id>.db`, cùng `<id>.db-wal` nếu có, lấy từ **bản sao** (`Copy-SqliteSnapshot`). Không checkpoint, vì lớp SQLite chỉ đọc và không thêm đường ghi. Không đưa `-shm` vào bundle: SQLite tự dựng lại file này từ WAL;
  - toàn bộ `brain/<id>/**` trừ `browser_recordings` (có thể rất lớn).
  - `source.antigravity = { kind, format, stepCount }`.
  - Transcript lấy theo G3 và đã che secret.
  - **Dừng:** `.db` lớn hơn 50 MB thì hỏi trước trong UI (dialog đã có sẵn chỗ báo lỗi), hoặc trả lỗi rõ ràng. Không tự cắt bớt.
- `Import-AgyNative -BundlePath -Profile`:
  1. `kind` của bundle khác `Kind` của profile thì trả `kind-mismatch`.
  2. Bundle không có `.db` thì trả `no-native`.
  3. App đích đang chạy thì `throw "Close <Name> first"`. Dialog đã chặn trước qua `ImportNeedsClose`, đây là lớp an toàn thứ hai.
  4. Đích đã có `<id>.db`: so `lastActivityAt` của bundle với mtime của `.db` đích. Bundle mới hơn thì ghi đè cả `.db` lẫn `brain\<id>\` và trả `updated`; không thì trả `exists`.
  5. Xóa `<id>.db-wal` và `<id>.db-shm` cũ của đích nếu có. Chép `.db`, và `-wal` nếu bundle có, qua file tạm trong cùng thư mục rồi đổi tên. Chép `brain\<id>\`. **Không** sửa `conversation_summaries.db`, vì app tự `restore` (A7).
- Test:
  - round-trip export rồi import vào `DataDir` giả;
  - `exists`, `updated`, `kind-mismatch`, `no-native`;
  - kiểm `browser_recordings` không có trong bundle.

### G5: handoff và đăng ký adapter

- `ImportHandoff`: gọi `Start-HarnessHandoff` có sẵn (clipboard rồi launch, A8).
  - Với IDE: chèn thêm đường dẫn cwd vào câu prompt, để user mở đúng thư mục. Không đổi `New-HandoffPrompt`; nối chuỗi trong adapter.
- `Register-AntigravityHarness` theo §3.
- Test:
  - `Register-Harnesses` có `antigravity`;
  - `Resolve-TransferMode antigravity antigravity` trả `native`, `antigravity codex` trả `handoff`;
  - adapter không có `NewProfile`.
- Kiểm cuối lane:
  - các test ở trên;
  - **kiểm tay:**
    1. export 1 conversation `.db` từ Default (chỉ đọc, qua bản sao);
    2. import vào home thử `%USERPROFILE%\.gemini-profiles\spike1\home\.gemini\antigravity`, khi app thử đã đóng. Gọi hàm với một profile object giả trỏ `DataDir` vào đó; **không** import vào Default thật;
    3. mở app thử bằng `tools/spikes/S4-AgyProfile.ps1 -Name spike1 -FakeHome`, xem conversation hiện ra, rồi tắt theo PID.
  - Không đăng nhập. Không gửi turn nào.

## 5. Rủi ro

| # | Rủi ro | Xử lý |
|---|---|---|
| R1 | Khác máy, đường dẫn workspace trong `.db` (protobuf) và trong `workspace_uris` không còn đúng | GĐ3 không sửa blob. Sau khi import, dialog báo "thư mục làm việc gốc: <đường dẫn>". Ánh xạ đường dẫn để GĐ4 xem xét lại khi có `pathRoots` |
| R2 | Conversation gắn account phía server: tiếp tục chat có thể lỗi dù conversation đã hiện | Chỉ hứa "hiện ra và đọc được". Kiểm tiếp tục chat để lúc user có mặt |
| R3 | winsqlite3 thiếu FTS5 | Đã có phương án dự phòng ở G2 |
| R4 | App ghi `.db` trong lúc export | Luôn export từ bản sao; khuyến nghị đóng app, nhưng không bắt buộc với export |

## 6. Cần quyết

- Không có câu hỏi mới. Kiểm tay G5 dùng lại home thử `spike1` của Antigravity. Xin orchestra giữ `%USERPROFILE%\.gemini-profiles\spike1` và `%LOCALAPPDATA%\AgyProfile-spike1` tới khi GĐ3 land, giống `spike1` của Codex.
- Worktree: `.worktrees\antigravity`, cắt từ `5e223ee`.

## 7. Báo cáo

Lane gửi `SẴN SÀNG CHUYẾN` cho reviewer trước. Báo cáo gồm sha, nhánh, file đã đổi, kiểm tra đã chạy kèm kết quả, phần đã kiểm tay hoặc chưa, câu hỏi mở.
