# Plan sửa sau milestone review GĐ6

- Review chạy trên `git diff ad06409..4412748`, chia 3 vùng không chồng file: A (xóa và ghi dữ liệu), B (kiểm kê, quét, Drive), C (cắt, tóm tắt, UI). Mỗi vùng một subagent code-reviewer, chỉ đọc.
- Reviewer `switcher-think-multiharness` đã đọc lại từng finding trong code thật trước khi đưa vào plan này.
- Base cho mọi lane: tip hiện tại, `2ab04ae` hoặc mới hơn.
- Quy tắc chung giống plan GĐ6 §0:
  - TDD: test phải đỏ trước khi sửa.
  - Test chỉ dùng cây giả trong `%TEMP%`.
  - Kiểm nhẹ theo đường dẫn test.
  - Chỉ commit local.
  - Gửi `READY FOR REVIEW` cho reviewer.

## 1. Lỗi thật, theo lane

### Lane R1: an toàn dữ liệu ở backend

**File sở hữu:** `src/Storage.Archive.ps1`, `src/Storage.Harness.ps1`, `src/Storage.Guard.ps1`, `src/Storage.DriveArchive.ps1`, cùng các test tương ứng. **Giữ nguyên chữ ký hàm công khai.**

| # | Mức | Lỗi (finding gốc) | Kịch bản | Sửa | Test đỏ trước |
|---|---|---|---|---|---|
| R1-1 | Cao | Archive mới **ghi đè** archive cũ cùng key. Trên local là cùng tháng; trên Drive là luôn luôn. Index chỉ giữ một dòng mỗi key. (A4, C1) | Trim lần hai, Summarize hoặc Archive cùng phiên làm mất archive chứa output gốc. Placeholder "full output in archive <key>" trỏ tới một archive không còn output. Nếu verify trên Drive lỗi sau khi ghi đè, Remove-StorageDriveArchive xóa luôn bản tốt cũ. | Mỗi lần archive có `archiveId` riêng, dạng `yyyyMMddTHHmmssfff`. Tên file thành `<keySafe>.<archiveId>.harchive.zip`, và tương ứng `.zip.enc` trên Drive. Index **không** dedupe theo key nữa; Remove theo archiveId hoặc entry/path. Test-StorageDriveRow và Resolve-StorageDrivePath chấp nhận hình dạng mới, đồng thời vẫn đọc được dòng cũ không có archiveId. Khi Save trên Drive lỗi, chỉ xóa đúng file mới vừa ghi. | Archive cùng key hai lần (local và Drive) thì cả hai zip còn nguyên và index có 2 dòng; Drive verify lỗi thì archive cũ vẫn restore được |
| R1-2 | Cao | Delete xóa **cả thư mục** part bằng `Remove-Item -Recurse`, trong khi zip chỉ có những file đã liệt kê được. Get-StorageEntries nuốt lỗi liệt kê (đường dẫn dài, thư mục bị từ chối quyền), và file sinh ra sau khi liệt kê cũng bị xóa. (A1, A9) | File chưa từng được archive bị xóa hẳn. Transcript ghi thêm trong lúc upload lên Drive thì bản dài bị xóa, còn zip chỉ có bản ngắn. | Remove-StorageSessionOriginal (Claude và Antigravity) nhận manifest, **chỉ xóa đúng các file trong manifest**. Trước khi xóa, kiểm size và mtime (hoặc sha khi size khớp) của từng file với manifest; lệch thì dừng phiên đó, không xóa gì. Thư mục chỉ xóa khi đã rỗng, không đệ quy, không đi theo junction. File ngoài manifest được giữ lại kèm cảnh báo. Codex: trước `thread/delete`, kiểm rollout khớp manifest. | Thư mục có thêm file sau khi build zip thì file đó còn; file trong manifest bị đổi thì không xóa gì; có junction trong thư mục thì target không bị đụng |
| R1-3 | Trung bình | Guard dùng mtime từ lúc quét, có thể đã cũ hàng giờ. (A2) | User vừa resume thread Codex hoặc chat Claude sau lần quét, rồi bấm Archive: phiên vẫn được coi là idle và bị gỡ. | Test-StorageSessionSafe stat lại các part `file` (và mtime mới nhất trong part `dir`, có giới hạn) **tại thời điểm thao tác** để tính recent. | Part có MTimeTicks cũ nhưng file thật vừa ghi thì kết quả là recent |
| R1-4 | Trung bình | Restore không giới hạn `rel` theo role. (A3) | Một zip lạ có part role `rollout` với `rel=config.toml` sẽ ghi vào gốc CODEX_HOME; với Antigravity là `mcp_config.json`. | Kiểm `rel` theo đúng hình dạng mà Get-StoragePartRel tạo ra cho từng role (`sessions\yyyy\mm\dd\rollout-*.jsonl[.zst]`, `<slug>\<id>.jsonl`, `conversations\<id>.(db\|pb)[-wal\|-shm]`, `brain\<id>\...`, `<account>\<org>\local_*.json`). | Mỗi role có một `rel` độc hại và đều bị từ chối; restore không ghi gì |
| R1-5 | Trung bình | Restore không chặn khi Claude CLI đang chạy ở thư mục của phiên. (A6) | File transcript đang được CLI ghi bị đổi tên thành `.bak`, còn CLI tiếp tục ghi vào handle của file `.bak`. | Get-StorageRestorePlan dùng `Running['cli']` (cwd, so theo thư mục gốc như Guard, cộng token `'*'`) với `manifest.cwd` cho phiên Claude. | Running.cli có thư mục của phiên thì restore bị từ chối và không ghi gì |
| R1-6 | Trung bình | Recycle không kiểm kết quả. Đường dẫn dài hơn MAX_PATH có thể bị Windows xóa hẳn không báo gì. (A8, câu hỏi của orchestra) | Recycler trả về OK nhưng file vẫn còn hoặc đã mất hẳn; phiên chỉ bị gỡ một nửa. | Trước khi gọi: Test-StorageRecyclable từ chối khi có đường dẫn dài ≥ 250 ký tự. Sau mỗi path: kiểm path đã biến mất; nếu còn thì ném `recycle-failed`. Thứ tự: kiểm mọi path trước, rồi mới recycle. | Recycler giả không xóa file thì kết quả là lỗi; path dài thì bị từ chối trước khi gọi recycler |
| R1-7 | Trung bình thấp | `MaxManifestBytes` 1 MB không đủ cho 20.000 mục, và manifest không nén JSON. (A5) | Phiên có khoảng 2.500 file trở lên: chính lần đọc lại zip vừa tạo thất bại, báo `archive-verify-failed`, nghe như zip bị hỏng. | `ConvertTo-Json -Compress`; MaxManifestBytes = 16 MB. | Phiên 5.000 file giả: archive đạt |
| R1-8 | Trung bình | Khi ghi lại index trên Drive, các dòng không qua kiểm tra bị **bỏ luôn**. (B5) | Một dòng bị Drive cắt dở, hoặc do app bản mới ghi: lần save hoặc remove sau xóa mất dòng đó, file .enc thành mồ côi, không restore được nữa. | Khi ghi lại, giữ nguyên các dòng hỏng hoặc lạ, chỉ bỏ dòng mình thay hoặc xóa. Việc đọc để hiển thị vẫn bỏ qua các dòng đó. | Index có 1 dòng lạ, sau Save thì dòng đó vẫn còn nguyên |
| R1-9 | Thấp | Receive-StorageDriveArchive dựng tên zip từ `Entry.key` mà không kiểm. (B7) | Một caller truyền Entry không đến từ index có thể ghi ra ngoài OutDir. | Kiểm key theo pattern, và kiểm key khớp path. | Key `x:..\..\evil` bị từ chối |

### Lane R2: cắt và tóm tắt

**File sở hữu:** `src/Storage.Compact.ps1`, `src/Storage.Summarize.ps1`, cùng test.

| # | Mức | Lỗi | Kịch bản | Sửa | Test |
|---|---|---|---|---|---|
| R2-1 | Trung bình | File trong `tool-results` luôn bị cắt như text UTF-8. (C7) | File nhị phân (ảnh, pdf), file JSON hoặc file không phải UTF-8 bị cắt thành file hỏng mà vẫn giữ đuôi cũ. | Chỉ cắt file `.txt` (hoặc `.log`). Mở bằng decoder UTF-8 strict; có byte NUL hoặc lỗi decode thì bỏ qua file đó. | File .png, .json và .txt không phải UTF-8 giữ nguyên từng byte; file .txt UTF-8 lớn thì bị cắt |
| R2-2 | Thấp trung bình | Trim tại chỗ vẫn archive và ghi trim.json khi không có gì để cắt. (C6) | Archive vô ích. Trước khi có R1-1, còn có thể ghi đè archive thật. | Cắt ra file tmp **trước**. Nếu không có mục nào bị cắt thì dừng: không archive, Ok kèm "nothing to trim". Nếu có thì archive, kiểm lại file gốc không đổi từ lúc tạo tmp, rồi mới thay. | Phiên không có output lớn: không có zip, không có dòng index, file gốc giữ nguyên từng byte |
| R2-3 | Trung bình | Bấm Stop trong lúc Summarize không kill được process claude. (C3, nửa thuộc R2) | Token tiếp tục bị tốn tới hết timeout 300 s. | Invoke-StorageProcessWithTimeout ghi PID con vào `$Progress['ChildPids']` khi được truyền Progress, và chuyển Progress xuống runner. Hợp đồng với R3: `Progress.ChildPids` là list PID; Stop gọi `taskkill /T /F` cho từng PID. | Runner giả ghi PID vào ChildPids; process con (powershell giả) bị kill khi gọi hàm kill của R3 |

### Lane R3: UI, quét và kiểm kê

**File sở hữu:** `src/Ui.Storage.ps1`, `src/Ui.StorageActions.ps1`, `src/Storage.Scan.ps1`, `src/Storage.Inventory.ps1`, `src/Harness.Sqlite.ps1` (chỉ Copy-SqliteSnapshot), cùng test.

| # | Mức | Lỗi | Kịch bản | Sửa | Test |
|---|---|---|---|---|---|
| R3-1 | Trung bình cao | Restore bị tắt khi key vẫn còn trong inventory. (C2) | Không khôi phục được output gốc sau Trim hoặc Summarize, dù hộp xác nhận hứa "can be brought back". | Restore luôn bật. Nhãn "Restored" đổi thành "Live" (chỉ để thông tin). Khi key còn sống, hộp xác nhận ghi thêm "The current files of this session are kept as .bak". Mỗi dòng archive restore độc lập; R1-1 có thể có nhiều dòng cho một key. | Dòng archive của một phiên đang live: nút Restore bật, có câu .bak |
| R3-2 | Trung bình | Close-StorageScan gọi `PowerShell.Stop()` đồng bộ trên UI thread sau một lần hard stop; Stop không kill process con. (B9, C3) | UI treo trong lúc VACUUM của DB lớn, hoặc trong lúc claude chạy tới hết 300 s. | Sau hard stop, Close **không** gọi Stop() đồng bộ: chỉ BeginStop rồi Dispose khi hoàn tất (callback hoặc timer). Stop-StorageScan kill các PID trong `Progress.ChildPids` (hợp đồng với R2-3). Sau hard stop của một action, đánh dấu inventory là cũ và hiện "Scan again". | Job giả treo 30 s: Stop và Close trả về dưới 2 s; PID con giả bị kill |
| R3-3 | Trung bình | Bảng Running (app, CLI) được chụp trước các hộp thoại và dùng cho cả lô. (C4, A2 phần UI) | Mở Desktop hoặc CLI trong lúc hộp xác nhận đang mở, rồi bấm xác nhận: phiên vẫn bị gỡ hoặc cắt. | Job script tính lại `$A.Running = Get-StorageRunningIds -Roots $A.Roots` ngay đầu job (runspace đã có đủ hàm). | Job script chứa lời gọi tính lại Running |
| R3-4 | Trung bình | Lỗi đọc `local_*.json` bị cache thành metadata rỗng. (B2) | Desktop đang ghi file đó: phiên bị coi là CLI-only; archive bỏ sót profile-meta, delete để lại local json treo. | Read-StorageLocalMeta ném lỗi khi đọc hoặc parse thất bại (đọc bằng FileShare.ReadWrite). Phía gọi không cache lỗi đó, gắn `Flags.DbUnreadable` cho phiên tương ứng nếu xác định được, và ghi một dòng Warnings. | File local khóa hoặc hỏng: không có entry cache, có cảnh báo; lần quét sau đọc được |
| R3-5 | Thấp | Vòng đọc tail giữ title **cũ nhất** thay vì mới nhất. (B1) | Phiên đổi tên 2 lần hiện tên đầu tiên. | Duyệt tail từ cuối và chỉ nhận title đầu tiên gặp cho mỗi loại (đã có rồi thì không ghi đè). | 2 dòng custom-title thì tên mới nhất thắng |
| R3-6 | Thấp | Dòng ở mép đầu hoặc cuối file dài hơn 64 KB làm mất cwd hoặc timestamp. (B11) | Phiên CLI-only không có LastActivity và cwd. | Không tìm thấy timestamp hoặc cwd thì đọc lại với cửa sổ gấp đôi, tối đa 1 MB. | Dòng cuối 200 KB vẫn lấy được timestamp |
| R3-7 | Thấp | Copy-SqliteSnapshot để lại thư mục `sqlite-snap-*` khi bước copy dự phòng lỗi. (B10) | Bản sao DB (tiêu đề, cwd) nằm lại trong %TEMP%. | Bước copy dự phòng bọc try/catch, lỗi thì xóa thư mục rồi ném lỗi lại. | Copy giả lỗi thì không còn thư mục snap |
| R3-8 | Thấp | Kho Drive bị từ chối Summarize và Trim ReadOnlyCopy **sau** khi đã xác nhận. (C5) | Mọi phiên báo Failed. | Get-StorageActionBlock chặn trước khi Target là drive và thao tác cần sidecar. Hộp xác nhận Trim ghi đúng mode cho từng phiên, kể cả sub-agent (C12). | Target drive thì nút Summarize tắt, có lý do |
| R3-9 | Thấp | Get-Command và dò PATH chạy cho từng dòng ở mỗi lần refresh nút. (C8) | Tick 200 dòng làm UI lag. | Tính khả năng một lần cho mỗi lần Update-StorageButtons. | Gọi giả: Get-Command chạy một lần cho mỗi lần refresh |
| R3-10 | Thấp | Sau Restore, inventory không đổi. (C11) | Vẫn hiện như cũ cho tới khi Scan lại. | Sau Restore, hiện "Scan again to see restored sessions" và đánh dấu dòng archive vừa restore. | Có status text |
| R3-11 | Thấp | AppDataBytes đo sai thư mục khi SessionRoot nằm ngoài DataDir (Default MSIX). (B4) | Chỉ sai số liệu thống kê. | Đo thêm SessionRoot, và trừ các part nằm trong cả hai thư mục. | SessionRoot ngoài DataDir: số đúng |

## 2. Finding bị loại hoặc chấp nhận, kèm lý do

| Finding | Lý do |
|---|---|
| B3: junction trong profile root | Cấu trúc profile của Claude không dùng junction. Sau R1-2, việc xóa chỉ đụng các file trong manifest, nên kể cả có junction cũng không mất dữ liệu |
| B6: thứ tự ghi file trước index trên Drive | Sau R1-1, mỗi archive có tên riêng, nên không còn chuyện ghi đè làm lệch sha |
| B8: blob không gắn với key | Invoke-StorageRestore đã so `entry.key` với `manifest.key`; muốn đổi tráo thì phải có quyền ghi Drive **và** có khóa sync |
| B12: chữ ký DB cũ khi app đang mở | Chỉ là suy đoán, không có kịch bản tái hiện; Inventory chỉ hiển thị, không phải guard |
| C9: khe nhỏ giữa lần kiểm cuối và File.Replace | Rủi ro còn lại được chấp nhận. R2-2 thu hẹp khe này; Codex đang chạy đã bị chặn qua Running.codex |
| C10: file tool-results không qua lock probe | Nếu file bị khóa, Replace thất bại thành cảnh báo, không mất dữ liệu |
| A7: Codex có nhiều rollout cho một id | Không mất dữ liệu (đều đã nằm trong zip); để vào danh sách việc sau |
| A10: node.exe có CommandLine null | Process nâng quyền có CommandLine null; coi chúng là '*' sẽ chặn mọi thứ mỗi khi có node chạy quyền admin. Cwd rỗng của phiên vẫn được guard xử lý qua '*' |
| A11: các điểm nhỏ (conversation-pb, Codex NoFile zip rỗng, thread/archive trước khi vào bin, presence lock, PathMap chồng prefix) | Không mất dữ liệu; để vào danh sách việc sau của plan GĐ6 |

## 3. Đề xuất chia lane và thứ tự

- **R1** cho work-3, vì work-3 đã viết A1 và A1-6.
- **R3** cho work-1, vì work-1 đã viết U1 và C1.
- **R2** cho work-2 (đang rảnh trong lúc chờ S19 Codex), hoặc nối tiếp sau work-1.
- Ba lane không chung file, nên chạy song song được. Hợp đồng chung duy nhất là `Progress.ChildPids` giữa R2-3 và R3-2.
- **Thứ tự land:** R1, rồi R2, rồi R3. Lane land sau cherry-pick lên tip.
- Sau khi cả ba land: chạy full gate một lần, rồi push.
