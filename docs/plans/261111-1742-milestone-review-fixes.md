# Sửa lỗi sau review mốc GĐ1–GĐ3 (trước khi push)

- Base: `5682276` trên `desktop-4.29-patches`.
- Nguồn: 3 reviewer độc lập chỉ đọc (lõi, Codex, Antigravity), 2026-11-11. Orchestra đã đối chiếu các mục ghi "đã xác nhận" với code thật.
- Mỗi lỗi phải có một test tái hiện: viết test trước và thấy nó fail, rồi mới sửa.
- Người duyệt: `switcher-think-multiharness`. Người land: orchestra.

## Lane F1: lõi + Claude (`switcher-work-3`)

Sở hữu: `src/Harness.Core.ps1`, `src/Harness.Claude.ps1`, `tests/HarnessCore.Tests.ps1`, `tests/HarnessClaude.Tests.ps1`, và chỉ các khối `# >>> harness-*` trong `ClaudeSwitcher.ps1`.

| # | Vị trí | Lỗi | Sửa |
|---|---|---|---|
| C1 | `Harness.Core.ps1` `ConvertTo-HandoffMarkdown`, `Protect-TranscriptEntries` | `-Entries` bắt buộc và không nhận mảng rỗng, nên xuất chat Claude chưa có transcript thì throw (đã xác nhận) | Thêm `[AllowEmptyCollection()]`/`[AllowNull()]`; transcript rỗng vẫn ra bundle |
| C4 | `ClaudeSwitcher.ps1` khối `harness-src`, `harness-register`; `Register-Harnesses` | Không có `try/catch` ở cả hai chỗ, và script đặt `$ErrorActionPreference='Stop'`. Một file trong `src` hỏng là cả switcher Claude không mở được (đã xác nhận) | Bọc từng lần dot-source và từng `Register-*Harness` trong `try/catch`, ghi lỗi vào `switcher-error.log`, rồi chạy tiếp |
| C5 | `ClaudeSwitcher.ps1` khối `harness-install` | Vẫn chép đè `src` khi user đã chọn giữ bản script đã cài. Xóa `src` xong mà chép lỗi thì mất `src` | Bỏ qua khi `Update-InstalledScript` cho biết user giữ bản cũ. Chép vào `src.new` trước rồi mới đổi tên |
| C6 | `Harness.Claude.ps1` khoảng dòng 113 | `native/*.jsonl` khớp cả `native/<cli>/subagents/*.jsonl`, nên có thể dựng transcript từ file của subagent | Chỉ khớp file jsonl ở cấp `native/`, không khớp file trong thư mục con |
| C7 | `Harness.Core.ps1` redaction và manifest | `title`, `cwd` trong manifest không được che. `KEY=value` chỉ khớp ở đầu dòng | Che `source.title` và `cwd`. Mở rộng mẫu: khớp cả giữa dòng (`&& TOKEN=x`), `"password": "x"`, `--password=x` |

## Lane F2: Codex (`switcher-work-1`)

Sở hữu: `src/Harness.Codex.Chats.ps1`, `src/Harness.Codex.AppServer.ps1`, `src/Ui.Harness.ps1`, `tests/HarnessCodexChats.Tests.ps1`.

| # | Vị trí | Lỗi | Sửa |
|---|---|---|---|
| X1 | `Ui.Harness.ps1` danh sách target; `Test-CodexImportNeedsClose` | `Pid` của target chỉ lấy một lần lúc mở dialog. Mở Codex sau đó thì import vẫn ghi vào home đang chạy (đã xác nhận) | Lúc bấm Go, phân giải lại profile đích (`GetProfiles` hoặc `ResolveProfile`). `Test-CodexImportNeedsClose` tự dò process, không dựa vào `Pid` cũ |
| X2 | `Import-CodexNative` | Bỏ qua kết quả `$false` của `Register`, vẫn trả `copied`. Thử lại thì rơi vào `exists` và không bao giờ đăng ký lại (đã xác nhận) | Trả `copied-unregistered` khi đăng ký thất bại. Nhánh `exists` thử đăng ký lại nếu chưa có dòng `threads`. UI báo rõ |
| X3 | `Start-CodexHandoff` | Deep link không giới hạn độ dài | Nếu URL dài hơn 2000 ký tự thì chuyển sang clipboard |
| X4 | `Import-CodexNative` | Có `.zst` cùng tên mà bundle chở `.jsonl` thì sinh ra 2 rollout cho cùng một thread | Nếu đã có file anh em khác đuôi thì thay thế file đó, không đặt thêm file cạnh nó |
| X5 | `Ui.Harness.ps1` danh sách target | Không kiểm `Detect.Installed`. Codex chưa cài vẫn hiện target Default và ghi vào `~\.codex` | Ẩn harness chưa cài khỏi danh sách nguồn và đích |
| X6 | `Import-CodexNative` regex `rolloutRelPath` và UUID | Cho phép `:` (thành alternate data stream của NTFS); `$` nhận cả `\n` ở cuối (đã xác nhận) | Tên file chỉ gồm `[0-9A-Za-z_.-]`; dùng `\A...\z` |

## Lane F3: Antigravity (`switcher-work-2`)

Sở hữu: `src/Harness.Antigravity.*.ps1`, `tests/HarnessAntigravity.Tests.ps1`.

| # | Vị trí | Lỗi | Sửa |
|---|---|---|---|
| A1 | `Harness.Antigravity.Profiles.ps1` `ImportNeedsClose = { $true }` | Chép native giữa hai Antigravity luôn dừng ở `close-first`, kể cả khi app đã đóng (đã xác nhận) | Trả `[bool](Find-AgyMainProcessId ...)`. Thêm test đi qua `Invoke-HarnessTransfer` khi app đóng |
| A2 | `Import-AgyNative`, nhánh `updated` | Xóa cả thư mục `brain\<id>`, kể cả `browser_recordings` không có trong bundle và các file chỉ có ở máy local (đã xác nhận) | Ghi đè từng file, không xóa thư mục. Hoặc dựng trong thư mục tạm rồi hoán đổi, và giữ lại `browser_recordings` |
| A3 | `Import-AgyNative`, chỗ so thời gian | Chỉ so với mtime của `.db`, bỏ qua `-wal`, rồi xóa `-wal`/`-shm` mà không sao lưu | Lấy mtime mới nhất trong `.db` và `-wal`. Đổi tên các file cũ thành `.bak-<ts>` trước khi thay |
| A4 | `Find-AgyMainProcessId` | Chỉ nhận process có đường dẫn nằm dưới `Programs\Antigravity\` | Nhận theo tên exe và đường dẫn đã cài thực tế. Không xác định được thì coi là đang chạy |
| A8 | Regex UUID của chatId | `$` nhận cả `\n` ở cuối | `\A...\z` |
| A10 | `Start-AgyHandoff` | `cwd` lấy từ bundle được chèn thẳng vào prompt | Chỉ nhận đường dẫn tuyệt đối không có ký tự điều khiển, nếu không thì bỏ trống |

## Hoãn sang GĐ4 (Drive, bundle từ máy khác)

- Giới hạn kích thước khi đọc zip (zip bomb); hoán đổi bundle một cách nguyên tử; lọc `..` trong `Resolve-CwdRef`; ánh xạ cwd khi nhập Claude native từ máy khác.
- Snapshot SQLite chép `.db`, `-wal`, `-shm` từng file một nên có thể lệch nhau; nguồn của `stepCount` và transcript chưa thống nhất.
- Giới hạn kích thước khi xuất (`brain` có junction, thư mục `<cli>\` lớn).
- Profile Claude không phải Default với bộ nhập của Codex; client JSON-RPC bỏ qua dòng hỏng; tray chạy `Detect` trên UI thread; đăng nhập Codex dùng keyring (chưa xác nhận); protobuf nhận nhầm tag in được là text.
