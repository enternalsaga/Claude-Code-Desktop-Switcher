# Plan GĐ6: quản lý phiên và dung lượng

- Spec: `docs/specs/261115-1332-session-storage-manager-spec.md`.
- Base: `ad06409` (`desktop-4.29-patches`).
- Người duyệt từng lane: `switcher-think-multiharness`. Lane đạt thì nhận `LAND OK <branch> <range>`, gửi về orchestra.

## 0. Quy tắc chung cho mọi lane

- PowerShell 5.1, không thêm phụ thuộc, source chỉ dùng ASCII.
- Giới hạn kích thước: file ≤500 dòng, hàm ≤100 dòng.
- `Harness.Core.ps1` đã đủ 500 dòng: **không thêm gì vào đó**.
- Code mới nằm trong `src\Storage.*.ps1` / `src\Ui.Storage.ps1`. `tools/Build-SingleFile.ps1` tự gộp các file này.
- Chỉ sửa các file mình sở hữu. Ngoại lệ có giới hạn được ghi trong từng lane.
- **Test trước** (TDD): mỗi task có một test trong `tests\Storage.*.Tests.ps1`. Test phải đỏ trên base và xanh sau khi sửa.
  - Test chỉ dùng cây giả trong `$env:TEMP\storage-test-*`. Không bao giờ chạm `~\.claude`, `CODEX_HOME` thật hay thư mục Antigravity thật.
  - Gốc dữ liệu được truyền vào qua tham số. Không có hàm nào tự đọc đường dẫn thật mà không cho phép ghi đè.
- **Kiểm nhẹ của worker**: parse các file đã sửa, chạy các test đã chạm theo đường dẫn, chạy PSScriptAnalyzer trên các file đã sửa. Worker không chạy cả bộ test.
- **Dữ liệu cá nhân**: không đưa email, ổ đĩa, đường dẫn cá nhân, token Drive hay hash của chúng vào repo. Quét secret trước mọi commit.
- Chỉ commit local, chỉ stage file của mình, không push, không đổi branch trong checkout chung.
- **Báo cáo ready** gửi tới `switcher-think-multiharness`, gồm:
  - branch, base sha, dải sha;
  - danh sách file;
  - kết quả kiểm nhẹ (lệnh và số test đạt);
  - các thay đổi so với plan, nếu có;
  - token `READY FOR REVIEW`.

## 1. Lane và thứ tự

| Đợt | Lane | File sở hữu | Phụ thuộc |
|---|---|---|---|
| 1 | **SP** (spike) | `tools/spikes/Spike-S14..S20*.ps1`, `docs/specs/261115-HHMM-storage-spike-results.md` | không |
| 1 | **I1** (kiểm kê và quét) | `src/Storage.Inventory.ps1`, `src/Storage.Scan.ps1`, `tests/Storage.Inventory.Tests.ps1`, `tests/Storage.Scan.Tests.ps1` | không |
| 2 | **A1** (archive, restore, delete, guard) | `src/Storage.Guard.ps1`, `src/Storage.Archive.ps1`, `src/Storage.Harness.ps1`, các test tương ứng | I1, SP (S16, S17, S18) |
| 2 | **D1** (kho trên Drive) | `src/Storage.DriveArchive.ps1`, `tests/Storage.DriveArchive.Tests.ps1` | A1 (giao diện `New-StorageArchive` / `Read-StorageArchive`); code song song được nhờ khóa giao diện ở §3 |
| 2 | **C1** (trim và summarize) | `src/Storage.Compact.ps1`, `src/Storage.Summarize.ps1`, các test tương ứng | I1, SP (S14, S15, S19); gọi `New-StorageArchive` của A1 |
| 3 | **U1** (tab Storage) | `src/Ui.Storage.ps1`, `src/Ui.StorageActions.ps1`, `tests/Ui.Storage.Tests.ps1`; ngoại lệ: `src/Ui.Main.ps1` **≤3 dòng** ở chỗ đăng ký tab, `tools/Render-UiPreview.ps1` **≤15 dòng** cho preview tab Storage | I1, A1, C1, D1 |

- **Thứ tự land**: SP → I1 → A1 → D1 → C1 → U1.
- D1 và C1 cùng gọi A1 nhưng không sửa file của A1. Nếu D1 hoặc C1 xong trước khi A1 land, lane đó cắt branch mới từ tip đã land rồi cherry-pick commit của mình sang (không merge, không rebase).
- Hai lane không bao giờ cùng sửa một file. Nếu cần thêm hook marker trong `ClaudeSwitcher.ps1`, lane xin orchestra một ngoại lệ có giới hạn: chỉ U1, ≤2 dòng.

## 2. Lane SP: spike (chỉ trên bản sao)

Mỗi spike là một script trong `tools/spikes/`. Kết quả được ghi vào `docs/specs/261115-HHMM-storage-spike-results.md`, gồm lệnh đã chạy, đầu ra đã che dữ liệu cá nhân, và kết luận đạt hay không đạt kèm hệ quả cho spec.

| Task | Nội dung | Cách làm an toàn |
|---|---|---|
| SP-1 S16 | Gọi `initialize` + liệt kê method qua Codex app-server. Thử `thread/archive`, `thread/unarchive`, `thread/delete` trên một thread tạo trong `CODEX_HOME=%TEMP%\spike-codex-*` | Home tạm, chép từ một rollout mẫu tự tạo. Không chép `auth.json` của Default; spike tự `codex login` vào home tạm nếu cần, hoặc dừng và ghi `USER ACTION` |
| SP-2 S15 | Cắt một rollout trong home tạm, sau đó `thread/read`. Ghi lại xem `thread/resume` có gửi request tới model không (theo dõi event stream; không gửi `turn/start`) | Như trên |
| SP-3 S17 | Antigravity: chép toàn bộ thư mục dữ liệu vào `%TEMP%`. Thử bỏ một `.db` và `brain\<id>` rồi đọc `conversation_summaries.db` của bản sao. Kiểm tra giao diện app được để `USER ACTION` | Chỉ trên bản sao. Phần kiểm bằng app là **USER ACTION**: user tự làm trên một conversation thử, theo các bước có sẵn trong file kết quả |
| SP-4 S18 | Tạo file thử trong `%TEMP%` rồi `SendToRecycleBin`. Đọc quota `BitBucket` của ổ hệ thống. Với ổ DriveFS, chỉ dùng thư mục `HarnessSync-test` | Dùng file rác do spike tự tạo. Không xóa gì khác |
| SP-5 S19 | `claude -p` và `codex exec` trong một thư mục tạm rỗng, với một transcript giả khoảng 20k và khoảng 400k ký tự. Chốt cờ tắt tool, xuất text, đọc stdin. Đo thời gian | Transcript giả, không phải dữ liệu thật. Lời gọi thật tốn token: tối đa 2 lần mỗi CLI, ghi rõ trong kết quả |
| SP-6 S20 | Đo `EnumerateFiles` + đọc 64 KB đầu và cuối trên `~\.claude\projects` thật, **chỉ đọc**. Ghi số đo khi chưa có cache và khi cache đã nóng (cache đặt trong `%TEMP%`) | Chỉ đọc. Không ghi gì vào thư mục dữ liệu |
| SP-7 S14 | Dựng một jsonl đã cắt từ một phiên thử do user tạo trong profile `spike*`, rồi ghi hướng dẫn **USER ACTION**: mở profile đó, xác nhận phiên hiện, mở được và chat tiếp được | Chỉ trên profile `spike*`. Bản gốc được giữ trong `%TEMP%` |

**Xong khi**: file kết quả có kết luận cho S14–S20 (S14 và S17 có thể ở trạng thái "chờ USER ACTION"), và mỗi kết luận ghi rõ dòng nào của spec phải đổi. Think sẽ cập nhật spec theo kết quả trước khi đợt 2 bắt đầu code các phần bị ảnh hưởng.

## 3. Giao diện được khóa (để code song song)

```powershell
# I1
Get-StorageInventory -Roots <hashtable> [-Cache <obj>] [-Progress <synchronized hashtable>] [-CancelToken <ref>]  -> @{ Sessions=@(StorageSession); Profiles=@(...); Totals=@{...}; ScannedAt; Files }
Get-StorageStats -Inventory <obj>  -> @{ ByHarness; ByProfile; CliOnly; Archive }
# Roots = @{ ClaudeProjects; ClaudeProfiles=@(@{Id;Name;SessionRoot;DataDir;IsDefault}); CodexHomes=@(@{Id;Name;Home}); AgyDirs=@(@{Id;Name;DataDir}) }
Get-StorageRootsFromConfig -Config <obj>   # dựng Roots thật từ adapter; chỉ dùng ở UI, không dùng trong test

# A1
Test-StorageSessionSafe -Session <obj> [-RecentMinutes 30] [-Running <obj>] -> @{ Safe; State; Reason }
New-StorageArchive   -Session <obj> -OutDir <path>  -> @{ ZipPath; Sha256; Manifest }      # không gỡ bản gốc
Read-StorageArchive  -ZipPath <path>               -> @{ Manifest; Verified }
Remove-StorageSessionOriginal -Session <obj> -Mode 'Delete'|'Recycle' -> @{ Removed=@(); Skipped=@() }
Invoke-StorageArchive -Sessions <obj[]> -Target <obj> [-Progress] [-CancelToken] -> @(@{ Key; Ok; Reason; ZipPath })
Invoke-StorageRestore -Entries <obj[]> -Target <obj> -> @(@{ Key; Ok; Reason })   # Target = @{ Kind='local'|'drive'; Path; PathMap (tùy chọn, dùng khi restore từ máy khác) }
Invoke-StorageRecycle -Sessions <obj[]> -> @(@{ Key; Ok; Reason })
Get-StorageArchiveIndex / Add-StorageArchiveIndex / Remove-StorageArchiveIndex -Target <obj>

# D1
Save-StorageArchiveToDrive -ZipPath <path> -Entry <obj> -SyncRoot <path> -MachineId <id> -Key <bytes>
Get-StorageDriveArchiveIndex -SyncRoot <path> -Key <bytes> [-AllMachines]
Receive-StorageDriveArchive -Entry <obj> -SyncRoot <path> -Key <bytes> -OutDir <path> -> ZipPath

# C1
ConvertTo-TrimmedClaudeJsonl -InPath -OutPath [-ThresholdBytes 16384] [-HeadBytes 2048] [-TailBytes 1024] -> @{ Before; After; Trimmed }
ConvertTo-TrimmedCodexRollout -InPath -OutPath [...] -> same
Invoke-StorageTrim -Sessions <obj[]> -Target <obj> -Mode 'InPlace'|'ReadOnlyCopy'
Get-StorageSummaryPlan -Sessions <obj[]> -> @(@{ Key; Tool; InputChars; EstTokens })
Invoke-StorageSummarize -Sessions <obj[]> -Target <obj> -Confirmed:$true [-Runner <scriptblock>]   # -Runner để test thay CLI thật
```

Đổi một chữ ký nào ở trên thì phải báo think trước. Think xác nhận rồi mới đổi.

## 4. Lane I1: kiểm kê và quét

| Task | Test đỏ trước | Việc |
|---|---|---|
| I1-1 | Cây giả có 3 jsonl Claude, một jsonl kèm thư mục `<cli>\subagents`, và 2 profile có `local_*.json` trỏ tới cùng một `cliSessionId` | `Get-ClaudeStorageSessions`: mỗi phiên một bản ghi, `Profiles` có cả 2 profile, `Parts` gồm jsonl, thư mục `<cli>` và cả 2 file `local_*.json`. Phiên không có metadata thì `IsCliOnly=$true` |
| I1-2 | Đọc tiêu đề, cwd và timestamp cuối từ đầu và cuối file mà không đọc giữa file (file giả 5 MB, test đo số byte đã đọc qua một stream bọc) | `Read-JsonlHeadTail` (64 KB + 64 KB). Bỏ dòng cuối dở dang và dòng đầu bị cắt |
| I1-3 | Codex: home giả có `state_5.sqlite` (tạo bằng `System.Data.SQLite` như các test GĐ2) với 2 thread, một thread `archived=1`, một rollout `.zst` | `Get-CodexStorageSessions`: liệt kê cả thread đã archive nhưng gắn cờ, `HasZst`, `Trimmable=$false` cho `.zst` |
| I1-4 | Antigravity: thư mục giả có `.db`, `-wal`, `brain\<id>` và summaries db | `Get-AgyStorageSessions`: `Parts` đủ 4 loại, `Trimmable=$false` |
| I1-5 | Thống kê: 2 profile cùng tham chiếu một phiên 10 MB, cộng 1 phiên CLI-only 5 MB. Tổng harness = 15 MB, profile A = 10 MB với `SharedBytes` = 10 MB, `CliOnly` = 5 MB | `Get-StorageStats`, cộng `AppDataBytes` (thư mục profile trừ các mảnh phiên nằm bên trong) |
| I1-6 | Cache: lần quét thứ hai không mở lại file nào nếu size và mtime không đổi (đếm lời gọi đọc). Đổi mtime một file thì chỉ file đó bị đọc lại | `.switcher\storage-cache.json`, ghi tmp rồi rename, có `version`. Cache hỏng thì bỏ và quét lại |
| I1-7 | Quét nền: `Start-StorageScan` trả về ngay; `Progress.Done` tăng dần; `Stop-StorageScan` dừng trong 1 giây; lỗi trong runspace được trả qua `Progress.Error`, không ném ra UI thread | `Storage.Scan.ps1`: runspace + hashtable đồng bộ. Hàm của runspace được nạp bằng cách dot-source chính các file `src\Storage.*.ps1` (bản build một file: truyền định nghĩa hàm vào qua `InitialSessionState`) |
| I1-8 | Bỏ qua reparse point và thư mục không có quyền mà không dừng quét (junction giả trong cây tạm) | Liệt kê bằng `EnumerateFiles` có `try`/`catch` theo từng thư mục |

Kiểm nhẹ:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Storage.Inventory.Tests.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Storage.Scan.Tests.ps1
```

## 5. Lane A1: guard, archive, restore, delete

| Task | Test đỏ trước | Việc |
|---|---|---|
| A1-1 | File bị mở với `FileShare.None` trong test → `State=live`. mtime 5 phút trước → `recent`. Profile đang chạy (truyền `-Running` giả) → `protected` | `Storage.Guard.ps1` `Test-StorageSessionSafe`. Không có tham số nào lấy process thật trong test |
| A1-2 | `New-StorageArchive` cho phiên Claude giả (jsonl, `<cli>\`, 2 `local_*.json`): zip có `archive.json` với sha của từng mục; `Read-StorageArchive` báo `Verified`. Sửa 1 byte trong zip thì `Verified=$false` | Zip qua `System.IO.Compression`, ghi ra tmp rồi move. Tuân theo giới hạn của bundle (1 GiB, 20k mục) và cap 512 MiB. Phiên lớn hơn cap thì báo lỗi rõ ràng (Q mở: tăng cap riêng cho archive, xem §9) |
| A1-3 | Archive rồi restore trên cây giả cho ra cây giống hệt từng byte, với cả 3 harness | `Invoke-StorageArchive` + `Invoke-StorageRestore`, có `Test-StoragePathAllowed` (thử `..` và đường dẫn ngoài gốc → bị từ chối) |
| A1-4 | Restore khi file đích đã có và khác sha → đổi tên thành `.bak-<ts>`. Profile không còn → ghi vào Default và có cảnh báo trong kết quả | |
| A1-5 | Codex: theo S16. Phương án đã chốt được test bằng một app-server giả (scriptblock thay cho RPC, giống test GĐ2) hoặc bằng SQLite trên DB giả: `archived=1` sau khi archive, `archived=0` sau khi restore | `Storage.Harness.ps1` |
| A1-6 | Antigravity: theo S17, test trên thư mục giả | `Storage.Harness.ps1` |
| A1-7 | Recycle: hàm thật được bọc sau `-Recycler <scriptblock>`. Test xác nhận rằng ổ không có thùng rác hoặc file vượt quota bị **từ chối trước** khi gọi recycler (dùng `-VolumeInfo` giả). Gọi thật chỉ trong một test đánh dấu `-Tag Live` trên file rác ở `%TEMP%`; mặc định test này được bỏ qua | `Invoke-StorageRecycle` |
| A1-8 | Index: thêm, đọc và xóa dòng trong `archive-index.jsonl`, ghi atomic. Dòng hỏng thì bỏ qua và ghi cảnh báo | |
| A1-9 | Lô: phiên `recent` bị bỏ qua với lý do; phiên lỗi ở giữa lô không chặn các phiên sau; Cancel dừng giữa các phiên, không dừng giữa chừng một phiên | |

Kiểm nhẹ: `tests/Storage.Guard.Tests.ps1`, `tests/Storage.Archive.Tests.ps1`, `tests/Storage.Harness.Tests.ps1`.

## 6. Lane D1: kho lưu trữ trên Drive

| Task | Test đỏ trước | Việc |
|---|---|---|
| D1-1 | Lưu zip vào `HarnessSync-test\archives\<machine>\...` dạng `.enc` (`Protect-SyncFile`); đọc lại bằng `Unprotect-SyncFile` và sha khớp | `Save-StorageArchiveToDrive` dùng `Copy-SyncFileAtomic` / `Write-SyncFileAtomic` của GĐ4 |
| D1-2 | Index theo máy, tiêu đề được mã hóa. Máy B đọc được index của máy A nhưng không ghi vào đó | `Get-StorageDriveArchiveIndex -AllMachines` |
| D1-3 | `Receive-StorageDriveArchive`: tải về `%TEMP%`, giải mã, kiểm sha. Sai khóa thì báo lỗi rõ ràng, không để lại file | |
| D1-4 | Restore từ máy khác: ánh xạ cwd theo C1 của GĐ4. Riêng Claude, slug của thư mục `projects` được dựng lại từ cwd mới | Gọi `Invoke-StorageRestore` với `-PathMap` (A1 phải hỗ trợ tham số này, đã khóa ở §3 dưới dạng thuộc tính `Target.PathMap`) |

Test chỉ dùng `HarnessSync-test` trong `%TEMP%`, không dùng thư mục Drive thật.

## 7. Lane C1: trim và summarize

| Task | Test đỏ trước | Việc |
|---|---|---|
| C1-1 | jsonl Claude giả có một `tool_result` 50 KB, một ảnh base64 và các dòng thường: sau khi cắt, các dòng thường giống hệt từng byte; `tool_result` còn 2 KB đầu + placeholder + 1 KB cuối; ảnh thành `[image trimmed]`; mọi dòng vẫn là JSON hợp lệ; các trường `uuid`/`parentUuid` không đổi | `ConvertTo-TrimmedClaudeJsonl`, xử lý theo dòng (stream), không nạp cả file vào bộ nhớ |
| C1-2 | Rollout Codex giả: `function_call_output` lớn bị cắt, các dòng khác không đổi. `.zst` bị từ chối | `ConvertTo-TrimmedCodexRollout` |
| C1-3 | `Invoke-StorageTrim -Mode InPlace` luôn gọi `New-StorageArchive` trước, rồi thay bản gốc bằng tmp + rename. Archive lỗi thì không đụng bản gốc. `-Mode ReadOnlyCopy` thì bản gốc giữ nguyên byte và có `<key>.trimmed.md` trong kho | Mode mặc định cho mỗi harness theo kết quả S14/S15, được ghi thành hằng số `$script:StorageTrimInPlace = @{ claude=$?; codex=$? }` |
| C1-4 | `Get-StorageSummaryPlan`: chọn đúng tool theo harness và theo CLI có trên máy (truyền `-Available` giả), ước lượng token = số ký tự / 4 | |
| C1-5 | `Invoke-StorageSummarize` không có `-Confirmed` thì ném lỗi, không gọi runner. Có `-Confirmed` thì: archive trước; đầu vào đã qua `Protect-TranscriptEntries` (test cài một chuỗi giống secret và xác nhận runner không nhận được chuỗi đó); runner chạy trong thư mục tạm rỗng; đầu ra là `<key>.summary.md` | Runner thật dùng cờ từ S19, có timeout và kill cây process khi hết giờ. Không lưu khóa nào |
| C1-6 | Lô summarize: một phiên lỗi không chặn các phiên khác; Cancel dừng giữa các phiên | |

Kiểm nhẹ: `tests/Storage.Compact.Tests.ps1`, `tests/Storage.Summarize.Tests.ps1`.

## 8. Lane U1: tab Storage

| Task | Test đỏ trước | Việc |
|---|---|---|
| U1-1 | `Get-StorageSessionRows` (hàm thuần): lọc theo harness, size ≥, ngày idle ≥, state và tìm kiếm; sắp theo từng cột; mặc định size giảm dần | `Ui.Storage.ps1` |
| U1-2 | Dựng form ẩn: tab thứ 5 tên `Storage` tồn tại; lúc đầu hiện "Not scanned yet"; **không** quét khi mở tab (đếm lời gọi `Start-StorageScan`) | Đăng ký tab trong `Ui.Main.ps1`, ≤3 dòng |
| U1-3 | Kiểm bố cục như V4: mọi control neo bên phải nằm trong `ClientRectangle` ở 1000×700 và 1400×900 | `Set-MainRightEdge` hoặc tương đương |
| U1-4 | Bảng profile có dòng "CLI / no profile" và ghi chú "shared counted once" | |
| U1-5 | Chọn nhiều phiên → nhãn "Selected: N sessions, X". Các nút bị tắt khi không có phiên nào chọn, hoặc khi mọi phiên chọn đều không an toàn | `Ui.StorageActions.ps1` |
| U1-6 | Hộp xác nhận của từng thao tác: nội dung có số phiên, dung lượng, danh sách profile, câu về khả năng phục hồi; với summarize thì có tool, số token ước lượng, câu về chi phí. Nút mặc định là `Cancel` | Hàm dựng nội dung là hàm thuần và có test. Hộp thoại thật không mở trong test |
| U1-7 | View `Archived`: đọc index local và Drive; có các nút Restore, Delete archive, Open summary | |
| U1-8 | Lần archive đầu khi chưa có `Storage.ArchiveTarget`: hỏi chọn thư mục, gợi ý `%USERPROFILE%\HarnessArchive`, hoặc chọn Drive nếu đã thiết lập sync | |
| U1-9 | Preview PNG của tab Storage với dữ liệu giả qua `tools/Render-UiPreview.ps1` (≤15 dòng thêm), đính kèm đường dẫn PNG trong báo cáo ready | |

Kiểm nhẹ: `tests/Ui.Storage.Tests.ps1`, và các test của `Ui.Main` đã có liên quan tới tab.

## 9. Câu hỏi mở cho orchestra (có mặc định, không chặn)

Q1–Q11 nằm trong spec §9. Thêm các câu sau:

- **Q12:** Archive có cap 512 MiB, kế thừa cap export của bundle, nhưng có jsonl tới 294 MB và phiên kèm thư mục `<cli>\` có thể lớn hơn. Mặc định đề xuất: cap riêng cho archive là 4 GiB, giữ giới hạn số mục, bỏ giới hạn tỉ lệ nén khi **tạo** zip (giới hạn tỉ lệ vẫn áp khi **đọc** zip từ Drive).
- **Q13:** Lệnh CLI (`-cli`) cho storage, ví dụ `-StorageScan -Json`, có cần ở GĐ6 không? Mặc định: không (YAGNI).

## 10. USER ACTION (nghiệm thu)

| # | Khi nào | Việc user làm |
|---|---|---|
| US1 | Sau SP-7 | Mở profile `spike*`. Xác nhận phiên đã cắt hiện, mở được và gửi tiếp được một tin (S14) |
| US2 | Sau SP-3 | Theo các bước trong file kết quả spike: mở Antigravity với conversation thử đã bị gỡ và được khôi phục, rồi báo app hiện gì (S17) |
| US3 | Sau U1 land và cài | Mở tab Storage, bấm Scan. Kiểm tra số liệu hợp lý so với Explorer và thời gian quét |
| US4 | Sau U1 | Chọn thư mục archive (local hoặc Drive) |
| US5 | Sau U1 | Archive 1–2 phiên cũ của mỗi app, kiểm tra chúng biến khỏi app. Restore lại, kiểm tra chúng hiện lại trong Claude Desktop, Codex và Antigravity |
| US6 | Sau U1 | Delete một phiên rác, kiểm tra phiên đó nằm trong Recycle Bin |
| US7 | Sau U1 | Summarize một phiên: đọc hộp xác nhận chi phí, đồng ý, mở `summary.md`, thử "Start a new chat from this summary" |
| US8 | Sau U1, nếu trim tại chỗ được bật | Trim một phiên lớn, mở lại và chat tiếp |

## 11. Gate và land

- **Orchestra land từng lane** bằng cherry-pick + squash, kèm kiểm per-commit.
- **Gate đầy đủ** chạy một lần sau đợt 3:

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/Invoke-Gate.ps1
  ```

- **Build một file** (`tools/Build-SingleFile.ps1`) phải parse được và có đủ các file `Storage.*`.
- **Install**: một work session thực hiện, theo pipeline §7 của quy tắc vai trò.
