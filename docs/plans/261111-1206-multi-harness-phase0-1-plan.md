# Plan: Multi-harness, GĐ0 (spike) và GĐ1 (lõi)

- Spec: `docs/specs/261111-1200-multi-harness-manager-and-drive-sync-spec.md`, đã duyệt ở 20955bb, sửa theo review ở 21e420d.
- Nhánh gốc: `desktop-4.29-patches`. Mỗi lane cắt nhánh mới từ tip hiện tại của nhánh này.
- Người duyệt mặc định: `switcher-think-multiharness`. Người land: orchestra.

## 0. Quy ước chung

### Lệnh kiểm tra

Test trong repo là script PowerShell thuần, **không dùng Pester**. Mỗi file `tests/*.Tests.ps1` ném lỗi khi fail và thoát 0 khi pass.

**Kiểm tra mỗi commit** (lane chạy, Windows PowerShell 5.1):

```powershell
# 1. Parse mọi .ps1 (giống bước "Parse check" của CI)
powershell -NoProfile -Command "$bad=0; Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object { $e=$null; [Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$e) | Out-Null; if ($e) { $bad++; $e | ForEach-Object { Write-Host ""$($_.Extent.File):$($_.Extent.StartLineNumber) $($_.Message)"" } } }; exit $bad"
# 2. Chỉ những test mà task chạm tới, theo path, ví dụ:
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\HarnessCore.Tests.ps1
```

**Gate đầy đủ** (chỉ orchestra chạy, mỗi batch một lần): parse cùng toàn bộ `tests/*.Tests.ps1` trên PS 5.1.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-Gate.ps1   # tạo ở task C6
```

Trước khi có C6, chạy tay:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem .\tests -Filter *.Tests.ps1 | ForEach-Object { Write-Host '==' $_.Name; & powershell -NoProfile -ExecutionPolicy Bypass -File $_.FullName; if ($LASTEXITCODE) { throw ""FAIL $($_.Name)"" } }"
```

- CI (`.github/workflows/lint.yml`) còn chạy từng test trên **PowerShell 7** và chạy **PSScriptAnalyzer**. CI chỉ fail khi PSScriptAnalyzer báo lỗi mức Error.
- Máy này không có `pwsh` và chưa cài PSScriptAnalyzer. Hai phần đó vì vậy chỉ được kiểm trên CI, sau khi push (xem mục "Cần quyết").
- Mỗi test mới thêm vào CI phải có hai bước, PS 5.1 và PS 7, giống các test hiện có.

### Ràng buộc cho mọi lane

- Commit local, không push, merge hay amend. Không thêm dependency; chỉ dùng .NET Framework 4.7.2+ và các DLL có sẵn trong Windows.
- Chỉ stage file mình sở hữu, và quét secret trước mỗi commit.
- **Spike không đụng dữ liệu thật.**
  - Mỗi spike làm việc trong `%TEMP%\harness-spike\<Sx>\`, hoặc trong profile thử dưới `%USERPROFILE%\.codex-profiles\spike-*` / `%LOCALAPPDATA%\AgyProfile-spike-*`.
  - Đọc DB thật chỉ qua bản sao. Không ghi vào `~\.codex`, `~\.claude`, `~\.gemini` hay thư mục Claude-Data.
  - Dọn profile thử khi xong, trừ khi spike sau còn cần.
- Script spike nằm trong `tools/spikes/` và được commit cùng kết quả, vì chúng làm bằng chứng tái lập được. Script spike không phải mã sản phẩm.
- Kết quả spike ghi vào `docs/specs/261111-1200-multi-harness-spike-results.md`. File này do lane SP sở hữu; mỗi spike có một mục riêng gồm: **Đạt / Không đạt / Một phần**, lệnh đã chạy, bằng chứng, hệ quả cho spec.

### Token báo cáo

Báo `SẴN SÀNG CHUYẾN`, gửi cho người duyệt trước. Báo cáo gồm sha, nhánh, file đã đổi, kiểm tra đã chạy kèm kết quả, câu hỏi mở.

## 1. Tổng quan lane và thứ tự

```
GĐ0  lane SP-A (không cần user):  S6 → S2a → S3 → S5 → S7          (tuần tự, một session)
     lane SP-B (USER ACTION):     S1 → [chờ user] → S2b → S4 → [chờ user]
GĐ1  lane C (lõi):                C1 → C2 → C3 → C4 → C5 → C6 → C7   (tuần tự, một session)
```

- **SP-A và SP-B chạy song song được.**
  - Hai lane chỉ chung một file kết quả. Cách tránh: SP-B ghi vào `docs/specs/261111-1200-multi-harness-spike-results-user.md`, rồi orchestra nối vào file chính khi land.
  - SP-B chỉ cần một session đứng chờ user, nên dùng model rẻ.
- **Lane C bắt đầu song song với GĐ0 được.** C1–C4 và C6 không phụ thuộc kết quả spike.
  - C5 dùng `winsqlite3`, nên chờ S6 đạt.
  - C7 là điểm móc và handoff, không phụ thuộc spike.
- GĐ0 không có file chung với lane C: SP chỉ ghi `tools/spikes/**` và `docs/specs/*spike-results*`.

## 2. GĐ0: spike

### Lane SP-A (tự chạy, không cần user)

Lane này sở hữu `tools/spikes/S2a-*`, `S3-*`, `S5-*`, `S6-*`, `S7-*` và `docs/specs/261111-1200-multi-harness-spike-results.md`.

**S6: đọc SQLite qua `winsqlite3.dll`** (làm trước tiên, vì C5 cần kết quả này)

- Script `tools/spikes/S6-WinSqlite.ps1`: `Add-Type` P/Invoke các hàm `sqlite3_open_v2` (cờ `SQLITE_OPEN_READONLY`), `sqlite3_prepare_v2`, `sqlite3_step`, `sqlite3_column_text16`, `sqlite3_column_blob`, `sqlite3_column_bytes`, `sqlite3_finalize`, `sqlite3_close`.
- Chạy trên bản sao `state_5.sqlite` (cùng `-wal`/`-shm`) và một `.db` của Antigravity, chép vào `%TEMP%\harness-spike\S6`.
- **Đạt khi:** đọc được `select id,title,cwd from threads limit 5` và đọc được blob `steps.step_payload` trên PS 5.1.
- Ghi chú phụ: kiểm lại trên PS 7 nếu sau này có `pwsh`. Cách gọi convention `Cdecl` và chuỗi UTF-16 phải chạy được trên cả hai.

**S2a: chép rollout Codex sang `CODEX_HOME` khác, cùng account, không cần user**

- Tạo `CODEX_HOME` thử `%TEMP%\harness-spike\S2\home`. Chép vào đó `auth.json` của Default, chỉ trong thư mục tạm, xóa ngay sau spike; tuyệt đối không commit file này. Chép thêm `config.toml`.
- Chép 1 rollout `.jsonl` và 1 rollout `.jsonl.zst` vào `home\sessions\YYYY\MM\DD\`.
- Chạy `codex resume --all` dưới `CODEX_HOME` thử (dùng CLI, không mở app) và xem thread có hiện ra không. Sau đó thử `codex resume <id> "ping"` chỉ với prompt `ping`, để kiểm resume.
  - Nếu không hiện: thử chèn dòng `threads` vào `state_5.sqlite` trong home thử bằng `sqlite3.exe` có sẵn trên máy, chỉ để làm spike.
- Ghi lại: cơ chế nào làm thread hiện ra (tự lập chỉ mục, cần dòng `threads`, hay không được); resume có lỗi `encrypted_content` không.
- **Dừng:** trước khi chạy `codex resume … "ping"`, kiểm tra không có `-c` nào trỏ về `~\.codex`. Lệnh chỉ dùng mức sandbox `read-only`.

**S3: Claude → Codex qua `externalAgentConfig/import`**

- Dùng lại home thử của S2. Chạy `codex app-server` (stdio) với `CODEX_HOME` thử, gửi JSON-RPC `initialize`, rồi `externalAgentConfig/detect` (`includeHome:false`, `cwds:[<thư mục tạm>]`). Sau đó gọi `externalAgentConfig/import` với một mục `SESSIONS` trỏ vào **bản sao** của một `~\.claude\projects\…\<id>.jsonl` đặt trong thư mục tạm.
- Lấy chữ ký message từ `codex app-server generate-json-schema --out %TEMP%\harness-spike\S3\schema`.
- **Đạt khi:** `external_agent_session_imports.json` trong home thử có bản ghi mới, và `codex resume --all` liệt kê thread đó.
- Ghi thêm: `detect` có tự quét `~\.claude` thật không. Nếu có, phải truyền `cwds` hoặc `includeHome` thế nào để chỉ nhập đúng file mình chọn.

**S5: transcript Antigravity và chép native**

- Script `tools/spikes/S5-AgyDecode.ps1`: giải mã protobuf chung theo wire format (varint, length-delimited, đệ quy khi phần con parse được) từ `steps.step_payload` của bản sao `.db`. In ra theo `step_type` các chuỗi UTF-8 dài ≥ 20 ký tự.
- Lập bảng `step_type` → vai trò (user, model, tool) bằng cách so với nội dung `brain\<id>\*.md` của cùng conversation.
- Phần chép native chỉ ghi nhận cấu trúc, chưa chạy: đọc schema bản sao `conversation_summaries.db` và xem có bảng chỉ mục cần cập nhật không. Thử chép thật là việc của S4, khi đã có profile Antigravity thử.
- **Đạt khi:** dựng được transcript user/model đọc được cho 1 conversation, kèm bảng `step_type`.

**S7: deep link mở phiên mới kèm prompt**

- Chỉ đọc. Grep bundle của từng app (`app.asar` của Claude và Codex; `app.asar` và `out/main.js` của Antigravity) tìm các route của protocol handler: `claude://`, `codex://`, `antigravity-ide://` và route tương ứng của app Antigravity.
- Tìm các route có tham số dạng `prompt`, `q`, `text`, `cwd` hoặc `folder`.
- Không mở link thật vào profile đang dùng. Muốn thử thì chỉ mở trong profile thử của SP-B, sau S1.
- **Đạt khi:** mỗi app có cú pháp link xác định, hoặc kết luận rõ là không có link, để rơi về clipboard.

### Lane SP-B (USER ACTION)

Lane này sở hữu `tools/spikes/S1-*`, `S2b-*`, `S4-*` và `docs/specs/261111-1200-multi-harness-spike-results-user.md`.

**S1: hai account Codex song song** (USER ACTION)

- `tools/spikes/S1-CodexProfile.ps1 -Name spike1`:
  - tạo `%USERPROFILE%\.codex-profiles\spike1\` và `...\spike1\electron\`;
  - đặt `CODEX_HOME` và `CODEX_ELECTRON_USER_DATA_PATH` chỉ cho process con;
  - chạy `ChatGPT.exe --user-data-dir=<electron>` từ InstallLocation của package.
- **DỪNG, gửi orchestra:** "S1 cần user đăng nhập account Codex thứ hai trong cửa sổ vừa mở". Chờ user báo xong.
- Sau khi user đăng nhập, kiểm tra:
  - hai cửa sổ cùng chạy;
  - `spike1\auth.json` khác Default (so hash, không in nội dung);
  - có ghi nào bị chuyển vào `Packages\OpenAI.Codex_*\LocalCache` không;
  - `Win32_Process` có phân biệt được hai instance qua `--user-data-dir` không.
- Giữ profile `spike1` cho S2b.

**S2b: rollout sang account khác.** Chờ S1 xong.

- Lặp lại S2a với `CODEX_HOME = spike1`, nhưng giữ `auth.json` của chính spike1.
- Ghi lại: resume có lỗi `encrypted_content` hay lỗi quyền không.
- Nếu lỗi: thử bỏ các item `reasoning` có `encrypted_content` trong một bản sao rollout rồi resume lại.
- Kết luận: native Codex khác account là Đạt, Không đạt, hoặc chỉ đạt sau khi bỏ reasoning.

**S4: hai account Antigravity** (USER ACTION)

- `tools/spikes/S4-AgyProfile.ps1 -Name spike1`: chạy `Antigravity.exe --user-data-dir=%LOCALAPPDATA%\AgyProfile-spike1`, với env `ANTIGRAVITY_GEMINI_DIR=%USERPROFILE%\.gemini-profiles\spike1` và `ANTIGRAVITY_APP_DATA_DIR` trỏ vào cùng gốc đó.
- **DỪNG, gửi orchestra:** "S4 cần user đăng nhập account Google thứ hai trong Antigravity vừa mở và tạo 1 chat ngắn".
- Sau khi user làm xong, kiểm tra:
  - chat mới nằm trong `.gemini-profiles\spike1\…\conversations` chứ không phải `~\.gemini`;
  - hai instance chạy song song được.
- Thử chép native: chép một bản sao `.db` và `brain\<id>` từ Default sang spike1 khi app spike1 đã đóng, mở lại app, rồi xem chat có hiện và tiếp tục được không.
- Lặp lại phần launch với `Antigravity IDE.exe`, để trả lời Q2: hai app có dùng chung `~\.gemini\antigravity` không.

### Điểm dừng GĐ0

- Mỗi spike xong thì commit kết quả. Mỗi lane gửi `SẴN SÀNG CHUYẾN` khi xong toàn bộ.
- Spike nào cho kết quả "Không đạt" làm đổi spec: lane gửi `BLOCKED: spec §x cần đổi vì …` cho orchestra rồi làm tiếp spike khác.

## 3. GĐ1: lõi (lane C)

Lane C sở hữu `src/Harness.Core.ps1`, `src/Harness.Claude.ps1`, `src/Ui.Harness.ps1`, `tools/Build-SingleFile.ps1`, `tools/Invoke-Gate.ps1`, `tests/_TestHelper.ps1`, `tests/HarnessCore.Tests.ps1`, `tests/HarnessBundle.Tests.ps1`, `tests/HarnessClaude.Tests.ps1`, `tests/BuildSingleFile.Tests.ps1`, và **chỉ 3 khối điểm móc** trong `ClaudeSwitcher.ps1` cùng `.github/workflows/lint.yml`, theo task C7.

### C1: helper nạp hàm cho test

- Tạo `tests/_TestHelper.ps1` với hàm `Import-TestFunctions -Files <path[]> -Names <string[]>`. Hàm parse AST nhiều file và dot-source đúng các hàm được nêu tên, giống cách mỗi test đang tự làm.
- Không sửa các test cũ, vì chúng vẫn chạy được như hiện nay. Test mới bắt buộc dùng helper này.
- Kiểm tra: parse check, cộng `tests\HarnessCore.Tests.ps1` (tạo ở C2) gọi helper.
- Commit: `test: shared helper to load functions from several scripts`.

### C2: `Harness.Core`, phần registry và kiểu dữ liệu

- Viết test trước:
  - `Register-Harness` / `Get-Harness` / `Get-Harnesses`;
  - kiểm tra adapter có đủ năng lực bắt buộc (`Detect`, `GetProfiles`, `Launch`, `ListChats`, `Export`, `ImportHandoff`) còn `ImportNative` là tùy chọn;
  - `Resolve-TransferMode` (cùng harness và có native → `native`; khác harness → `handoff`; Claude→Codex khi adapter Codex có `ImportExternalClaude` → `codex-import`).
- Kiểm tra: `tests\HarnessCore.Tests.ps1`.
- Commit: `feat(core): harness registry and transfer mode rules`.

### C3: bundle v1

- Viết test trước:
  - `New-HarnessBundle` (manifest, `files[]` có `sha256`, zip tạo bằng `System.IO.Compression`);
  - `Read-HarnessBundle` (kiểm sha256, từ chối `format` hay `version` lạ, từ chối entry zip có `..` hoặc đường dẫn tuyệt đối);
  - `ConvertTo-CwdRef` / `Resolve-CwdRef` với `pathRoots` (khớp gốc dài nhất, không phân biệt hoa thường, đúng ranh giới thư mục).
- Kiểm tra: `tests\HarnessBundle.Tests.ps1`.
- Commit: `feat(core): versioned harness bundle and cwd mapping`.

### C4: redaction và transcript

- Viết test trước:
  - `Protect-TranscriptText` che đúng bộ regex ở spec §8 và giữ nguyên text thường;
  - `Measure-SecretFindings` chỉ đếm, không sửa;
  - `ConvertTo-HandoffMarkdown` nhận `transcript.jsonl` chuẩn hóa (phần đầu, rút gọn tool call, cắt output ở 2 KB, giữ trọn N=40 lượt cuối, tóm tắt cơ học phần trước).
- Fixture chỉ dùng secret giả dạng `sk-ant-TEST…`. Đặt nó trong chuỗi ghép lúc chạy để trình quét secret không bắt nhầm.
- Kiểm tra: `tests\HarnessCore.Tests.ps1`.
- Commit: `feat(core): secret redaction and handoff transcript`.

### C5: lớp SQLite chỉ đọc (cần S6 đạt)

- `Open-SqliteReadOnly` / `Invoke-SqliteQuery` / `Close-Sqlite` trên `winsqlite3.dll`, theo đúng kết quả S6.
- Luôn chép DB (cùng `-wal`/`-shm`) vào `%TEMP%` trước khi mở, bằng `Copy-SqliteSnapshot`.
- Test tạo DB fixture bằng chính `winsqlite3` (mở chế độ read-write, chỉ trong `%TEMP%`), rồi đọc lại.
- Kiểm tra: `tests\HarnessCore.Tests.ps1`.
- Commit: `feat(core): read-only SQLite access through winsqlite3`.
- **Dừng:** nếu S6 không đạt thì gửi `BLOCKED` cho orchestra và bỏ qua C5. Adapter Codex khi đó đọc `session_index.jsonl` và rollout `.jsonl` thường.

### C6: adapter Claude, build single-file, gate

- `src/Harness.Claude.ps1`: adapter bọc `Find-ClaudeInstall`, `Get-ProfileList`, `Start-ClaudeProfile`, `Get-CodeSessions` và `Copy-CodeSession`, **không đổi hành vi**.
  - `Export`: đọc `local_*.json` theo `cliSessionId`, kèm `~\.claude\projects\<slug>\<cli>.jsonl` và thư mục `<cli>\` vào `native/`.
  - `transcript.jsonl` dựng từ các dòng `user` và `assistant` của jsonl.
  - Hàm `ConvertTo-ClaudeProjectSlug`: test với ví dụ `H:\AI_Software\Claude-Code-Desktop-Switcher` → `H--AI-Software-Claude-Code-Desktop-Switcher`.
- `tools/Build-SingleFile.ps1`: thay khối giữa `# >>> harness-src` và `# <<< harness-src` trong một bản sao `ClaudeSwitcher.ps1` bằng nội dung `src\*.ps1` theo thứ tự cố định, ghi ra `dist\ClaudeSwitcher.ps1`.
  - `dist\` được thêm vào `.gitignore`. Thay đổi này nằm trong commit của C6, vì `.gitignore` thuộc lane C.
- `tools/Invoke-Gate.ps1`: parse cộng mọi `tests/*.Tests.ps1` trên PS 5.1. Có `pwsh` thì chạy thêm PS 7, có PSScriptAnalyzer thì chạy thêm phần phân tích. Exit khác 0 khi có lỗi.
- Test:
  - `tests\HarnessClaude.Tests.ps1`: fixture giống `ChatTransfer.Tests.ps1`, thêm jsonl. Export rồi Import native sang profile giả ra kết quả byte-identical với `Copy-CodeSession` cũ.
  - `tests\BuildSingleFile.Tests.ps1`: file `dist` parse được, chứa đủ hàm, và không còn dòng dot-source `src\`.
- Kiểm tra: `tests\HarnessClaude.Tests.ps1`, `tests\BuildSingleFile.Tests.ps1`, `tests\ChatTransfer.Tests.ps1`, `tests\ChatUpdate.Tests.ps1`.
- Commit: `feat(claude): Claude adapter, single-file build and local gate`.

### C7: 3 điểm móc, handoff chung, CI

- Thêm vào `ClaudeSwitcher.ps1` đúng 3 khối, mỗi khối nằm giữa marker `# >>> harness-…` / `# <<< harness-…`, tổng **≤ 25 dòng**:
  1. dot-source `src\*.ps1` khi thư mục `src\` có cạnh script; bản `dist` đã có sẵn khối đã ghép;
  2. `Register-Harnesses` sau khi phát hiện Claude;
  3. menu chuột phải của profile và tray có thêm mục "Export chat for handoff…", gọi `Show-HarnessExportDialog` trong `src/Ui.Harness.ps1`.
     - Dialog tối giản: chọn chat, xuất bundle cùng file handoff vào `.switcher\handoff\`, chép câu mở đầu vào clipboard.
     - Dialog transfer cũ giữ nguyên.
- `Install-Switcher` chép thêm `src\`. Phần này cũng nằm trong khối 1 và được tính vào ngân sách 25 dòng.
- Thêm vào `.github/workflows/lint.yml` các bước PS 5.1 / PS 7 cho 4 test mới.
- Kiểm tra:
  - gate đầy đủ qua `tools\Invoke-Gate.ps1`;
  - thử tay: `powershell -File .\ClaudeSwitcher.ps1 -List` vẫn in danh sách như cũ.
- **Dừng:** không được mở UI để thử bằng cách launch profile thật. Muốn chụp UI thì chỉ dùng `-List` và chạy test.
- Commit: `feat(ui): harness hooks and handoff export entry`.

### Điểm dừng GĐ1

- Xong mỗi task thì commit. Xong C7 thì gửi `SẴN SÀNG CHUYẾN` cho người duyệt.
- Orchestra land toàn bộ lane C thành một chuyến, hoặc hai chuyến (C1–C5 và C6–C7) nếu lane muốn land sớm phần lõi.

## 4. Song song và phụ thuộc

| Task | Phụ thuộc | Chạy song song với |
|---|---|---|
| S6 | không | SP-B, C1–C4 |
| S2a, S3, S5, S7 | S6 (chỉ để dùng chung công cụ đọc) | SP-B, lane C |
| S1 (USER) | user đăng nhập | SP-A, lane C |
| S2b | S1 | SP-A, lane C |
| S4 (USER) | user đăng nhập | SP-A, lane C |
| C1–C4 | không | GĐ0 |
| C5 | S6 đạt | các spike còn lại |
| C6 | C1–C4 (C5 nếu có) | các spike còn lại |
| C7 | C6 | các spike còn lại |

GĐ2 (Codex) và GĐ3 (Antigravity) chỉ được viết plan sau khi: GĐ0 có kết quả cho S1, S2, S3 (GĐ2) và S4, S5 (GĐ3), và C2–C3 đã land.

## 5. Việc cần user làm

1. **S1**: đăng nhập account Codex thứ hai trong cửa sổ Codex thử mà script mở ra.
2. **S4**: đăng nhập account Google thứ hai trong Antigravity thử, rồi tạo một chat ngắn.
3. Không còn việc nào khác trong GĐ0–GĐ1.

## 6. Cần quyết (orchestra)

- **PS 7 và PSScriptAnalyzer:** máy chưa có `pwsh`, cũng chưa cài PSScriptAnalyzer. Hai lựa chọn:
  - (a) cài `pwsh` qua winget và cài PSScriptAnalyzer (`Install-Module -Scope CurrentUser`) để gate local giống CI;
  - (b) chấp nhận hai phần này chỉ được kiểm trên CI sau khi push.
  - Đề xuất (a). Đây là việc cài đặt, thuộc thẩm quyền của orchestra.
- **S2a dùng bản sao `auth.json` của Default trong `%TEMP%`:** cần orchestra đồng ý. Phương án thay thế là chỉ kiểm việc rollout có hiện trong danh sách hay không (`codex resume --all` không gọi model), bỏ bước `ping`.
