# Plan: Multi-harness GĐ2, Codex

- Spec: `docs/specs/261111-1200-multi-harness-manager-and-drive-sync-spec.md` (§3.2, §3.3, §5, §6, §11 GĐ2).
- Kết quả spike: `docs/specs/261111-1200-multi-harness-spike-results.md` (SP-A, đã land ở db61536). Phần SP-B (`…-spike-results-user.md`) đang chờ land; các điểm cần dùng được tóm ở §1.
- Base: `db61536` trên `desktop-4.29-patches`. Người duyệt: `switcher-think-multiharness` (local_16d53f2d-cb24-4b5c-8d40-db17aa4a98fe). Người land: orchestra.
- Lệnh kiểm tra và quy ước chung giống plan GĐ0–1 §0 (`docs/plans/261111-1206-multi-harness-phase0-1-plan.md`):
  - test là script thuần, chạy `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\<X>.Tests.ps1`;
  - gate đầy đủ là `tools\Invoke-Gate.ps1`, chỉ orchestra chạy.

## 1. Những gì spike đã chốt (đầu vào bắt buộc)

| # | Sự thật | Nguồn |
|---|---|---|
| F1 | Profile Codex là cặp `CODEX_HOME` + `CODEX_ELECTRON_USER_DATA_PATH`, chạy `ChatGPT.exe --user-data-dir=<electron>`. Hai instance chạy song song được; `Win32_Process` phân biệt qua `--user-data-dir=`. Đặt ngoài AppData thì không bị MSIX chuyển hướng ghi | S1 |
| F2 | Nút Sign in trong instance thứ hai **không chạy**. Đăng nhập bằng `codex login` với `CODEX_HOME` của profile. Cổng callback 1455 cố định, nên mỗi lúc chỉ chạy được một lần đăng nhập | S1 |
| F3 | Rollout thả vào `sessions\YYYY\MM\DD\` được tự lập chỉ mục **chỉ khi home chưa có `state_5.sqlite`**. Home đã có DB thì thread không hiện, cho tới khi được resume theo id | S2a, S2b |
| F4 | Native khác account resume được với rollout `model_provider=openai`, cả `.jsonl` lẫn `.jsonl.zst`. Rollout có provider không khai trong `config.toml` đích thì lỗi `modelProviderNotConfigured` | S2b |
| F5 | `thread/list` mặc định ẩn thread `source=exec` và lọc theo provider. Muốn lấy đủ thì truyền `modelProviders:[]` và `sourceKinds:["cli","vscode","exec","appServer","unknown"]`. App vẫn hiện thread exec | S2a, S2b |
| F6 | Claude → Codex: gọi `externalAgentConfig/detect {includeHome:true}`, lọc `details.sessions` còn đúng file, rồi `externalAgentConfig/import` chỉ với mục `SESSIONS`. Kết quả về bất đồng bộ qua `…/import/completed`. Không cần đăng nhập. Jsonl phải nằm dưới `~\.claude\projects` | S3 |
| F7 | Deep link `codex://threads/new?prompt=&path=` luôn rơi vào instance **Default** | S2b, S7 |
| F8 | Client JSON-RPC viết bằng PS 5.1: bọc `StreamWriter` UTF-8 không BOM quanh `StandardInput.BaseStream` và gửi một dòng trống làm "mồi" trước message đầu. Gọi thẳng `codex.exe`, không qua `.cmd` | S2a |
| F9 | `.zst` không giải nén được trong PS mà không thêm dependency. Codex tự đọc được loại file này | S2a, S2b |

Chưa kiểm: reasoning có `encrypted_content` khi khác account (rủi ro R1); "cùng account với Default".

## 2. Lane và thứ tự

```
Lane 2a (profiles, launch, tray, shortcut)      : P1 → P2 → P3 → P4 → P5
Lane 2b (chat: list, export, native, import, UI): S8 → K1 → K2 → K3 → K4 → K5 → K6
```

- **Chạy song song.** Hai lane không có file chung (bảng §5).
- **Thứ tự land: 2a trước, 2b sau.**
  - 2b chỉ phụ thuộc 2a qua hợp đồng §3 (tên hàm và hình dạng object), không qua mã. Test của 2b dùng profile object giả.
  - Khi 2a đã land, 2b cắt nhánh mới từ tip đã land và cherry-pick commit của mình (không có file chung nên không xung đột), rồi báo lại.
- `.github/workflows/lint.yml` thuộc **2b**, vì 2b land sau. 2b thêm bước CI PS 5.1/PS 7 cho **cả hai** file test (`HarnessCodexProfiles.Tests.ps1` và `HarnessCodexChats.Tests.ps1`).
- `tools/Build-SingleFile.ps1` **không cần sửa**: `Harness.Codex.Profiles.ps1` và `Harness.Codex.Chats.ps1` đã có trong danh sách thứ tự, còn file mới (`Ui.Tray.ps1`, `Harness.Codex.AppServer.ps1`) được nối theo tên.
- Profile thử `%USERPROFILE%\.codex-profiles\spike1` (account 2, đã đăng nhập) **được giữ tới khi GĐ2 land**, để làm S8 và kiểm tay (xin orchestra xác nhận, §7). Không lane nào ghi vào `~\.codex` thật. Đọc Default chỉ qua bản sao.

## 3. Hợp đồng giữa hai lane

**Profile object** (2a tạo, 2b dùng):

```powershell
[pscustomobject]@{ Harness='codex'; Id='Default'|'<id>'; Name='<label>'; IsDefault=$bool
                   CodexHome='<abs>'; UserDataDir='<abs>'|$null; Pid=$int|$null }
```

- Default: `CodexHome = $env:USERPROFILE\.codex`, `UserDataDir = $null`.
- Profile thêm: `CodexHome = %USERPROFILE%\.codex-profiles\<Id>`, `UserDataDir = <CodexHome>\electron`.

**Adapter** do 2a đăng ký trong `Register-CodexHarness` (file Profiles). Các năng lực về chat gọi hàm của 2b theo tên, phân giải lúc gọi:

```powershell
ListChats            = { param($Profile)             Get-CodexChats -Profile $Profile }
Export               = { param($Chat, $OutPath)      Export-CodexChat -Chat $Chat -OutPath $OutPath }
ImportNative         = { param($BundlePath, $Profile) Import-CodexNative -BundlePath $BundlePath -Profile $Profile }
ImportHandoff        = { param($BundlePath, $Profile) Start-CodexHandoff -BundlePath $BundlePath -Profile $Profile }
ImportExternalClaude = { param($BundlePath, $Profile) Import-CodexExternalClaude -BundlePath $BundlePath -Profile $Profile }
ImportNeedsClose     = { param($Profile)             Test-CodexImportNeedsClose -Profile $Profile }
```

**Chat object** (2b tạo):

```powershell
[pscustomobject]@{ ChatId; Title; Cwd; Updated; Activity; Parent; Source; ModelProvider; RolloutPath; Profile }
```

**Giá trị trả về của import:**

- `Import-CodexNative` trả `copied` | `exists` | `provider-mismatch`. Khi nhận `provider-mismatch`, UI chuyển sang handoff và ghi rõ lý do.
- `Import-CodexExternalClaude` trả `@{ Status='imported'|'exists'|'not-detected'; ThreadId }`.

## 4. Lane 2a: profile, launch, tray, shortcut

**Sở hữu:**

- `src/Harness.Codex.Profiles.ps1`
- `src/Ui.Tray.ps1` (mới)
- `tests/HarnessCodexProfiles.Tests.ps1`
- Trong `ClaudeSwitcher.ps1`: khối `harness-ui-tray` hiện có, và một khối mới `harness-launch`. Tổng hook của file này sau GĐ2 **≤ 30 dòng** (hiện là 20).

**Kiểm mỗi commit:** parse check, `tests\HarnessCodexProfiles.Tests.ps1`, `tests\ProfileLaunch.Tests.ps1`.

### P1: phát hiện cài đặt

- Test trước: `Find-CodexInstall` trả `{Installed, Kind='Msix', Exe=<InstallLocation>\app\ChatGPT.exe, CodexExe, Version, Aumid}`.
  - `Aumid` là `<PackageFamilyName>!App`, lấy Id từ AppxManifest. Bản đã cài có Id `App` (đã thấy trong lúc thăm dò).
  - `CodexExe` ưu tiên `<InstallLocation>\app\resources\codex.exe`; nếu không chạy được thì dùng `codex.exe` thật của npm (theo F8, không dùng `.cmd`).
- Trong test, `Get-AppxPackage` được thay bằng hàm giả qua tham số `-Package`.

### P2: danh sách và vòng đời profile

- `Get-CodexProfiles`:
  - Default, cộng mỗi thư mục con của `%USERPROFILE%\.codex-profiles\` có tên hợp lệ. Bỏ qua thư mục `spike*`, không liệt kê chúng.
  - Nhãn lấy từ settings `Harnesses.codex.Labels`, dùng `Get-Setting` / `Set-Setting` có sẵn.
  - `Pid`: lọc `Win32_Process` có `Name='ChatGPT.exe'`, đường dẫn exe nằm trong thư mục package OpenAI.Codex, không có `--type=`. Ghép theo `--user-data-dir=`; process không có cờ này là Default.
- `New-CodexProfile -Name`: kiểm tên theo luật giống `Test-ProfileName` (viết hàm riêng `Test-CodexProfileName`, không gọi hàm của Claude), rồi tạo `<home>` và `<home>\electron`.
- `Rename-CodexProfile`: chỉ đổi nhãn.
- `Remove-CodexProfile`:
  - từ chối khi profile đang chạy;
  - xóa thư mục profile sau khi kiểm đường dẫn nằm dưới `.codex-profiles\` và không phải junction;
  - **không bao giờ** xóa Default.
- Test dùng thư mục giả trong `%TEMP%`, đổi `USERPROFILE` của test.

### P3: launch và đăng nhập

- `Start-CodexProfile -Profile`:
  - Đang chạy thì `Show-ProfileWindow -ProcessId` (hàm có sẵn) và trả `focused`.
  - Default: `explorer.exe shell:AppsFolder\<Aumid>`, để giữ package identity.
  - Profile thêm: đặt `CODEX_HOME` và `CODEX_ELECTRON_USER_DATA_PATH` **chỉ trong lúc** gọi `Start-Process`, rồi khôi phục giá trị cũ trong `finally` (đúng mẫu S1). Chạy `ChatGPT.exe --user-data-dir="<electron>"` với `-WindowStyle Normal -PassThru`.
  - Trong test, `Start-Process` được thay qua biến `$script:CodexStartProcess` (scriptblock). Test kiểm env được đặt và được khôi phục, kiểm đối số đúng.
- `Invoke-CodexLogin -Profile`:
  - Chạy `CodexExe login` với `CODEX_HOME` của profile, trong cửa sổ console hiện ra, và chờ process kết thúc.
  - Khóa tuần tự (F2): `System.Threading.Mutex` tên `Local\HarnessSwitcher-CodexLogin`. Đang có lần đăng nhập khác thì báo "đang có một lần đăng nhập Codex khác".
  - Xong thì kiểm `<CodexHome>\auth.json` có tồn tại: có thì trả `signed-in`, không thì `cancelled`.
  - **Không đọc** nội dung `auth.json`.
- `Add-CodexAccount -Name`: `New-CodexProfile`, rồi `Invoke-CodexLogin`, nếu `signed-in` thì `Start-CodexProfile`.

### P4: tray, shortcut, `-Launch codex:<id>`

- `src/Ui.Tray.ps1`, hàm `Add-HarnessTrayItems -Menu`:
  - Submenu "Codex" gồm các profile Codex (dấu tick nếu đang chạy, bấm để launch), dải phân cách, "Add Codex account…" (hỏi tên bằng `Show-Prompt` có sẵn).
  - Chỉ hiện khi `Find-CodexInstall` báo đã cài.
- Hook `harness-ui-tray` trong `ClaudeSwitcher.ps1`: thêm một dòng `if (Get-Command Add-HarnessTrayItems …) { Add-HarnessTrayItems -Menu $trayMenu }`. Dòng Export hiện có giữ nguyên.
- Hook mới `harness-launch`, đặt ngay đầu khối `if ($Launch) {`, ≤ 6 dòng:
  - nếu `$Launch` khớp `^(?<h>codex):(?<id>.+)$` thì gọi `Start-CodexProfile` cho profile đó rồi `return`;
  - profile không tồn tại thì `throw` với danh sách profile, giống thông báo của Claude.
- `New-CodexShortcut -Profile -Directory`:
  - Tạo `Codex - <name>.lnk` bằng `Set-LauncherTarget -ScriptArgs "-Launch ""codex:<id>"""` (hàm có sẵn).
  - Default trỏ `shell:AppsFolder\<Aumid>`.
  - Icon: dùng icon của `ChatGPT.exe`. Badge màu và taskbar identity để GĐ5 (Q9).
  - Submenu tray có mục "Add shortcut" cho từng profile.

### P5: đăng ký adapter

- `Register-CodexHarness` (file Profiles):
  - `Detect`, `GetProfiles`, `Launch`, `NewProfile` (= `Add-CodexAccount`), `RemoveProfile`, `Rename`;
  - cộng 6 năng lực chat theo hợp đồng §3.
- Test:
  - `Register-Harnesses` có đăng ký `codex` khi các hàm có mặt;
  - `Resolve-TransferMode codex codex` trả `native`, `claude codex` trả `codex-import`.
- Kiểm cuối lane:
  - các test ở trên;
  - `powershell -File .\ClaudeSwitcher.ps1 -List` vẫn in như cũ;
  - **kiểm tay** `-Launch codex:spike1` mở đúng instance spike1 (account 2 đã đăng nhập sẵn), trong khi Default vẫn chạy.
- **USER ACTION, tùy chọn:** thử "Add Codex account" từ đầu đến cuối cần user đăng nhập trong trình duyệt. Chỉ làm nếu user có mặt. Nếu không thì ghi "chưa kiểm tay" trong báo cáo.

## 5. Lane 2b: chat Codex

**Sở hữu:**

- `src/Harness.Codex.Chats.ps1`
- `src/Harness.Codex.AppServer.ps1` (mới, client JSON-RPC)
- `src/Ui.Harness.ps1`
- `tests/HarnessCodexChats.Tests.ps1`
- `tools/spikes/S8-*.ps1`
- mục S8 trong `docs/specs/261111-1200-multi-harness-spike-results.md`
- `.github/workflows/lint.yml`

**Kiểm mỗi commit:** parse check, `tests\HarnessCodexChats.Tests.ps1`, `tests\HarnessCore.Tests.ps1`, `tests\HarnessClaude.Tests.ps1`.

### S8: spike nhỏ, làm trước tiên

Chỉ dùng `spike1` và home tạm dưới `%TEMP%\harness-spike\S8`. Không ghi vào `~\.codex`.

- **S8a: đăng ký thread vào home đã có DB mà không gọi model.**
  - Thả một rollout `openai` vào `spike1\sessions\…` khi app spike1 đã đóng.
  - Chạy `codex app-server` với `CODEX_HOME=spike1`: `initialize`, rồi `thread/resume {threadId}` (**không** gửi `turn/start`), rồi tắt.
  - Sau đó `thread/list` (theo F5) có thấy thread không? Mở app spike1 có thấy không?
  - Nếu không được: thử khởi động lại app-server (xem có quét lại không), rồi phương án chèn dòng `threads`. Phương án chèn dòng chỉ ghi nhận làm bằng chứng, không đưa vào sản phẩm khi chưa có quyết định.
- **S8b: transcript cho rollout `.zst`.** Tìm trong `codex app-server generate-json-schema` method đọc item theo trang (ví dụ `thread/turns/list` hoặc tương tự) rồi kiểm nó trả được text user/assistant của một thread `.zst` dưới home tạm.
  - Phương án dự phòng: mở `thread_history_1.sqlite` tại chỗ ở chế độ chỉ đọc (cờ `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`, `?mode=ro`), vì file 1,8 GB thì không chép làm bản sao được. Phương án này phải được ghi rõ là ngoại lệ của luật "luôn đọc qua bản sao".
- **S8c: app-server chạy song song với app đang mở trên cùng `CODEX_HOME`.** Có an toàn không: lỗi khóa, `database is locked`? Kết quả quyết định giá trị của `Test-CodexImportNeedsClose`.
- **S8d:** `<InstallLocation>\app\resources\codex.exe --version` và `login --help` có chạy được từ ngoài package không. Ghi kết quả cho P1 của 2a, và nhắn thẳng lane 2a.
- Ghi kết quả vào mục "S8" của file kết quả spike.
- Nếu S8a không có cách nào sạch: gửi `BLOCKED: native Codex vào profile đã có DB` cho reviewer. Lane làm tiếp K1–K4, còn K3 tạm chỉ hỗ trợ home chưa có DB và trả `needs-close` cho trường hợp còn lại.

### K1: client app-server

- `src/Harness.Codex.AppServer.ps1`:
  - `Start-CodexAppServer -CodexHome -CodexExe` khởi `ProcessStartInfo` với stdin/stdout chuyển hướng, env `CODEX_HOME`, theo F8.
  - `Invoke-CodexRpc -Server -Method -Params -TimeoutSec` có id tăng dần và bỏ qua notification không khớp id.
  - `Wait-CodexNotification -Server -Method -TimeoutSec`.
  - `Stop-CodexAppServer` tắt đúng PID của mình.
- Test: framing và parse message bằng một process giả. Process giả là script PowerShell đọc stdin và trả JSON cố định, đặt trong thư mục test tạm. Test cả trường hợp có notification xen giữa và trường hợp timeout.

### K2: liệt kê chat

- `Get-CodexChats -Profile`:
  - Đọc `threads` từ bản sao `state_5.sqlite` (`Copy-SqliteSnapshot` và `Invoke-SqliteQuery` có sẵn).
  - Lấy `archived=0`, bỏ thread subagent (`thread_source='subagent'`), lấy **mọi** `source`.
  - Bỏ tiền tố `\\?\` ở `cwd` và `rollout_path`.
  - `Activity` lấy `updated_at_ms`; `Parent` lấy từ `thread_spawn_edges` nếu có.
- Test: tạo fixture `state_5.sqlite` có đúng các cột đang dùng, bằng cách C5 đã làm (winsqlite mở read-write, chỉ trong `%TEMP%`).

### K3: export và native

- `ConvertFrom-CodexRollout -Path` (chỉ `.jsonl`): chuẩn hóa `response_item` thành entry.
  - `message` có role `user` hoặc `assistant` thành entry text.
  - `function_call` / `custom_tool_call` ghép với `*_output` theo `call_id`, thành entry tool.
  - Bỏ `reasoning`, `token_count`, `turn_context`. Bỏ cả message `user` mang nội dung hệ thống, ví dụ khối `<environment_context>` hay AGENTS.md: lọc theo thẻ mở đầu.
- `.zst`: lấy transcript theo kết quả S8b. Nếu S8b không có cách nào thì transcript ghi một dòng "chỉ có native, không có transcript".
- `Export-CodexChat -Chat -OutPath`:
  - `native/<tên rollout gốc>` giữ nguyên byte;
  - `native/threads-row.json` gồm các cột của dòng `threads` trừ `first_user_message` và `preview`;
  - `transcript.md` và `transcript.jsonl` đã che secret;
  - `source.codex = { modelProvider, source, rolloutRelPath='sessions/YYYY/MM/DD/<tên>', cliVersion }`.
- `Import-CodexNative -BundlePath -Profile`:
  1. Đọc `model_provider` của `config.toml` đích, chỉ cần dòng `model_provider = "…"` ở cấp trên cùng; không có dòng đó thì coi là `openai`. Lệch với bundle thì trả `provider-mismatch`.
  2. Chép rollout vào `<CodexHome>\<rolloutRelPath>`. Đã có file cùng tên: cùng sha thì trả `exists`; khác sha thì chép bản mới hơn theo `lastActivityAt`, cùng quy tắc với Claude.
  3. Đăng ký thread theo S8a. Home chưa có DB thì không cần làm gì.
- `Test-CodexImportNeedsClose -Profile`: theo S8c.
- Test:
  - fixture rollout jsonl tổng hợp, không dùng dữ liệu thật: kiểm entry, che secret, lọc thẻ hệ thống;
  - bundle round-trip;
  - provider lệch;
  - trường hợp `exists`.
  - Phần đăng ký thread không có test tự động; kiểm tay trên spike1.

### K4: Claude → Codex và handoff

- `Import-CodexExternalClaude -BundlePath -Profile`:
  - Lấy `cliSessionId` và jsonl từ bundle.
  - Jsonl phải có sẵn ở `~\.claude\projects` của máy này, dùng `Find-ClaudeProjectDir` có sẵn. Không có thì trả `not-detected`; trường hợp khác máy để GĐ4.
  - Gọi detect `{includeHome:true, maxSessions:<đủ lớn>, maxSessionAgeDays:<từ lastActivityAt>}`, lọc `details.sessions` theo `path` (so không phân biệt hoa thường, bỏ `\\?\`), rồi import chỉ mục `SESSIONS` đó và chờ `…/import/completed` tối đa 120 giây.
  - **Không bao giờ** truyền các `itemType` khác.
- `Start-CodexHandoff -BundlePath -Profile`:
  - Default: deep link `codex://threads/new?prompt=<urlencoded>&path=<cwd đã resolve>`, mở qua `Start-Process`.
  - Profile thêm: dùng `Start-HarnessHandoff` có sẵn, tức clipboard rồi launch (F7).
  - Prompt là câu `New-HandoffPrompt` (ngắn), không phải cả transcript.
- Test:
  - lọc detect với dữ liệu giả;
  - URL encode của deep link;
  - nhánh Default và nhánh profile thêm (thay `Start-Process` và `Start-HarnessHandoff` bằng hàm giả).

### K5: dialog dùng chung

- `src/Ui.Harness.ps1`, mở rộng `Show-HarnessExportDialog`. Giữ nguyên tên hàm để không phải sửa hook.
  - Thêm combobox **harness nguồn** (Claude, cộng Codex nếu đã đăng ký).
  - Thêm combobox **đích**: "Chỉ tạo file handoff" (mặc định, như hiện nay), cộng mọi profile của mọi harness đã đăng ký.
  - Cột "Kiểu" lấy từ `Resolve-TransferMode`.
  - Bấm nút chính:
    - `native` → `ImportNative`; trả `provider-mismatch` thì báo rồi làm handoff;
    - `codex-import` → `ImportExternalClaude`;
    - `handoff` → `ImportHandoff`.
  - Trước mọi import, nếu `ImportNeedsClose` trả true mà profile đích đang chạy thì báo "đóng <profile> trước" và dừng.
  - Mọi lỗi đều hiện bằng `Show-Message`, không để script dừng.
- Không mở UI để thử bằng profile thật. Kiểm bằng parse, cộng các hàm điều phối tách ra khỏi phần WinForms: `Invoke-HarnessTransfer -Chat -SourceHarness -Target`. Hàm này có test riêng với adapter giả.

### K6: CI

- `.github/workflows/lint.yml`: thêm bước PS 5.1 và PS 7 cho `HarnessCodexProfiles.Tests.ps1` và `HarnessCodexChats.Tests.ps1`.
- Kiểm cuối lane:
  - mọi test kể trên;
  - **kiểm tay** trên spike1, nguồn chỉ đọc từ Default qua bản sao:
    1. Codex → Codex native, một rollout `openai`;
    2. Claude → Codex import, một phiên Claude có sẵn;
    3. handoff vào spike1 bằng clipboard.
  - Ghi kết quả vào báo cáo. Không gửi turn nào tới model ngoài prompt `ping` khi cần kiểm resume.

## 6. Rủi ro

| # | Rủi ro | Xử lý |
|---|---|---|
| R1 | Reasoning `encrypted_content` hỏng khi resume ở account khác | Kiểm tay ở K6 nếu gặp rollout có reasoning. Nếu lỗi thì báo reviewer; khi đó thêm giá trị trả về `account-mismatch` cho `Import-CodexNative`, xử lý giống `provider-mismatch` (UI chuyển sang handoff) |
| R2 | App-server cùng `CODEX_HOME` với app đang chạy làm khóa DB | S8c quyết định. Mặc định an toàn: yêu cầu đóng app đích |
| R3 | Cockpit quản lý `~\.codex` Default (`model_provider=codex_local_access`) | Kiểm provider (K3). Không ghi gì vào `config.toml` |
| R4 | `codex.exe` trong package không chạy được từ ngoài | S8d; dùng CLI npm làm dự phòng |

## 7. Cần quyết (orchestra)

- Giữ `%USERPROFILE%\.codex-profiles\spike1` tới khi GĐ2 land, không chỉ tới khi plan chốt. Hai lane cần nó cho S8 và cho kiểm tay.
- Kiểm tay "Add Codex account" (P5) cần user đăng nhập. Tùy chọn, chỉ khi user có mặt.

## 8. Báo cáo

- Mỗi lane gửi `SẴN SÀNG CHUYẾN` cho reviewer trước. Báo cáo gồm sha, nhánh, file đã đổi, kiểm tra đã chạy kèm kết quả, phần đã kiểm tay hoặc chưa, câu hỏi mở.
- Lane tạo worktree mới dưới `.worktrees\codex-profiles` (2a) và `.worktrees\codex-chats` (2b), cắt từ `db61536`. Orchestra tạo worktree.
