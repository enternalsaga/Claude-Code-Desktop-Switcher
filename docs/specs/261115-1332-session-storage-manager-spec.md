# Spec GĐ6: quản lý phiên và dung lượng (Claude, Codex, Antigravity)

- Base: `ad06409` trên `desktop-4.29-patches`.
- Người viết: `switcher-think-multiharness`. Người duyệt plan: orchestra.

**Yêu cầu của user (2026-11-15), nguyên văn:** "app này có quản lý toàn bô các session của profile nó ko? kẻ cả phiên trong CLI, có cách nào quản lý để xoá các session cũ và nặng, hoặc advanced hơn thì compacted hoặc lưu trữ (archived) nó trong thư mục để đỡ phải gọi lại làm nặng phần load? thêm phần thống kê dung lượng cho cả Profile và session nhé"

**User đã chọn:**
- Phạm vi: cả 3 app. Claude gồm cả phiên CLI chỉ có jsonl.
- Compact: làm cả ba kiểu, gồm lưu trữ nén, cắt output lớn, tóm tắt AI.
- Thư mục lưu trữ: user chọn, có thể là thư mục local hoặc Drive đã thiết lập.
- Xóa: đưa vào Recycle Bin, có xác nhận.
- Thống kê theo profile và theo phiên.

**Số đo thật (2026-11-15):**
- `~\.claude\projects`: 11.132 jsonl, 18,3 GB, file lớn nhất 294 MB.
- Codex sessions: 3,1 GB.
- Antigravity: conversations 1,3 GB, brain 0,5 GB.

## 1. Mục tiêu và không mục tiêu

**Mục tiêu:**
1. Kiểm kê mọi phiên của cả 3 harness. Với Claude, kiểm kê cả phiên CLI không có metadata Desktop.
2. Thống kê dung lượng theo harness, profile và phiên, không đếm trùng.
3. Bốn thao tác trên phiên, mỗi thao tác chạy đơn lẻ hoặc hàng loạt:
   - **Archive:** nén, chuyển vào thư mục lưu trữ, gỡ khỏi app. Khôi phục nguyên vẹn được.
   - **Trim:** cắt output lớn của tool. Bản gốc luôn được archive trước.
   - **Summarize:** tóm tắt bằng CLI AI có sẵn trên máy. Bản gốc luôn được archive trước.
   - **Delete:** đưa vào Recycle Bin.
4. Khôi phục phiên đã archive về đúng chỗ cũ, sao cho app thấy lại phiên đó.
5. Quét nhanh, chạy nền và có cache. Chỉ quét khi user bấm nút, theo tinh thần V4.

**Không mục tiêu ở GĐ6:**
- Dọn cache của ứng dụng (Electron cache, GPU cache...) trong thư mục profile. Phần này chỉ được thống kê, không dọn.
- Tự động archive theo lịch.
- Sửa transcript Antigravity, vì nó nằm trong `.db` protobuf.
- Cắt rollout Codex dạng `.zst`.

## 2. Mô hình dữ liệu

### 2.1 Bản ghi phiên (`StorageSession`)

```
Harness        'claude' | 'codex' | 'antigravity'
Key            Claude: 'claude:<cliSessionId hoặc tên jsonl>'. Codex / Agy: '<harness>:<id>.<p8>', p8 = 8 hex đầu SHA-256 của profile Id viết thường,
               vì import native GĐ2 giữ nguyên id nên cùng id có thể ở nhiều profile (review I1, 2026-11-15). Khớp pattern key của D1.
Title, Cwd, LastActivity (unix ms), Created
Profiles       @( @{ Id; Name } )  profile nào tham chiếu tới phiên này (Claude có thể nhiều; rỗng = CLI / không thuộc profile)
Parts          @( @{ Role; Path; Bytes; Kind = 'file'|'dir' } )   mọi mảnh dữ liệu của phiên (§2.2)
Bytes          tổng Parts (không tính metadata nhỏ của profile khác hai lần)
State          'live' | 'recent' | 'idle' | 'protected'   (§4)
Flags          IsCliOnly, HasZst, Trimmable, ArchivedRef (nếu là bản ghi trong kho lưu trữ)
```

### 2.2 Mảnh dữ liệu theo harness

| Harness | Thuộc phiên | Ghi chú |
|---|---|---|
| Claude | `~\.claude\projects\<slug>\<cli>.jsonl`, thư mục `<slug>\<cli>\` (subagents, tool-results), mọi `local_<id>.json` có `cliSessionId = <cli>` trong `claude-code-sessions\<account>\<org>\` của **mọi** profile | Transcript dùng chung giữa các profile. Metadata nằm riêng trong từng profile. Phiên chỉ có jsonl mà không có `local_*.json` nào là **CLI-only** |
| Codex | `sessions\yyyy\mm\dd\rollout-*.jsonl[.zst]` (hoặc `archived_sessions\...`), dòng `threads` trong `state_5.sqlite` | Mỗi profile là một `CODEX_HOME` riêng, nên không trùng |
| Antigravity | `conversations\<id>.db`, `-wal`, `-shm`, `brain\<id>\`, dòng trong `conversation_summaries.db` | Có hai app (Antigravity và Antigravity IDE) với hai thư mục dữ liệu riêng |

### 2.3 Thống kê

- **Theo phiên:** `Bytes` = tổng các mảnh.
- **Theo profile:**
  - `Sessions` = số phiên mà profile tham chiếu. `SessionBytes` = tổng `Bytes` của các phiên đó.
  - `SharedBytes` = phần thuộc các phiên mà profile khác cũng tham chiếu.
  - `AppDataBytes` = dung lượng thư mục profile, trừ đi các mảnh phiên nằm bên trong nó. Với Codex là `CODEX_HOME` trừ `sessions`. Với Claude là thư mục profile Electron.
- **Nhóm "CLI / no profile"** (chỉ có ở Claude): tổng các phiên CLI-only.
- **Tổng của harness:** mỗi phiên đếm đúng một lần. Vì thế tổng của harness ≤ tổng các profile, và UI ghi rõ "shared counted once".
- **Kho lưu trữ:** số phiên và dung lượng đã nén trong thư mục archive, cộng phần dung lượng đã giải phóng, tính bằng tổng `Bytes` gốc trừ dung lượng zip.

## 3. Quét và cache

- **Chạy ở runspace nền.** UI gửi yêu cầu, nhận tiến độ qua một hashtable đồng bộ mà timer của UI đọc mỗi 250 ms. Có nút **Stop**.
- **Chỉ chạy khi user bấm** `Scan` trong tab Storage. Lần mở tab đầu hiện "Not scanned yet" và nút Scan.
- **Liệt kê** bằng `[IO.Directory]::EnumerateFiles` / `EnumerateDirectories`, có bắt `UnauthorizedAccess` và bỏ qua reparse point. Không dùng `Get-ChildItem -Recurse`.
- **Cache** `.switcher\storage-cache.json`, mỗi mục gồm `{ path, size, mtimeTicks, meta }`.
  - `meta` là tiêu đề, cwd, `cliSessionId`, hoạt động cuối, đã đọc từ file.
  - Chỉ đọc lại nội dung khi `size` hoặc `mtime` đổi.
  - Ghi cache qua file tmp rồi rename.
- **Đọc metadata nhanh:**
  - jsonl Claude và rollout Codex: đọc tối đa 64 KB đầu file (cwd, title, id, created) và 64 KB cuối file (timestamp cuối), không bao giờ đọc cả file.
  - `.zst`: chỉ lấy size và mtime. Thông tin còn lại lấy từ dòng `threads`.
  - DB của Codex và Antigravity: chỉ đọc qua `Copy-SqliteSnapshot` (`VACUUM INTO`).
- **Mục tiêu hiệu năng:** quét lại khi cache còn nóng với 11k file dưới 15 giây. Quét lần đầu dưới 2 phút trên máy này. Số đo thật được ghi vào báo cáo của lane.

## 4. An toàn: phiên đang chạy hoặc vừa hoạt động

Mọi thao tác ghi (archive, trim, summarize với archive trước, delete, restore) đi qua `Test-StorageSessionSafe`. Phiên không an toàn bị loại khỏi lô và hiện kèm lý do.

| Điều kiện | State | Hệ quả |
|---|---|---|
| Có file của phiên đang bị khóa: mở thử với `FileShare.None` thất bại | `live` | Chặn mọi thao tác |
| `LastActivity` hoặc mtime của bất kỳ mảnh nào mới hơn 30 phút (đổi được, Q2) | `recent` | Chặn, có nút "Include anyway" cho từng phiên. Không bao giờ áp hàng loạt |
| Claude: profile có tham chiếu đang chạy (`Get-RunningProfileMap`) và thao tác cần sửa `local_*.json` của profile đó | `protected` | Chặn, nhắc đóng profile |
| Codex: app của `CODEX_HOME` đó đang chạy (`Get-CodexRunningMap`), và thao tác cần ghi `state_5.sqlite` mà không qua app-server | `protected` | Theo S16, mọi thao tác đều đi qua app-server (`thread/delete`, `thread/archive`, `thread/read`) nên không còn bước nào ghi thẳng DB. Điều kiện này chỉ áp cho đường dự phòng `Register-CodexThread` |
| Antigravity: app của thư mục dữ liệu đó đang chạy (`Find-AgyMainProcessId`) | `protected` | Chặn |
| Phiên Claude có `claude.exe` CLI đang chạy với cwd trùng cwd của phiên (đọc command line và cwd của process nếu được) | `live` | Chặn |

## 5. Thao tác

### 5.1 Archive (lưu trữ nén)

1. Kiểm an toàn (§4).
2. Dựng `<sessionKey>.harchive.zip` trong `%TEMP%`. Nội dung gồm mọi mảnh ở §2.2 và `archive.json`:

   ```
   { format:'harness-archive', version:1, key, harness, title, cwd, lastActivity, archivedAt, machineId,
     parts:[ { role, originalPath, entry, size, sha256, kind } ],
     restore:{ claude:{ profiles:[{ profileId, storeRel }] } | codex:{ codexHome, threadsRow } | agy:{ dataDir, summaryRow } } }
   ```

   Đường dẫn gốc được ghi dạng tuyệt đối. Khi restore, đường dẫn đó phải đi qua `Test-StoragePathAllowed`: nằm dưới gốc dữ liệu đã biết của harness, không có `..`.
3. Đọc lại zip và so sha256 của từng mục. Sai thì dừng, không xóa gì.
4. Chuyển zip vào kho lưu trữ (§6) bằng tmp + rename, kiểm lại sha của cả file.
5. Gỡ bản gốc khỏi app:
   - **Claude:** xóa jsonl, `<cli>\` và các `local_*.json` ở mọi profile tham chiếu. Profile tham chiếu đang chạy thì chặn từ bước 1.
   - **Codex (chốt theo S16, 2026-11-15):** zip lấy rollout từ `rollout_path` hiện tại của dòng `threads`. Chỉ sau khi bước 3 và 4 đạt mới gọi `thread/delete` qua app-server. Lệnh này xóa hẳn cả dòng `threads` lẫn file, và đúng là cái ta cần, vì zip đã kiểm sha là bản sao lưu. Không dùng `thread/archive` để giải phóng dung lượng: lệnh đó chỉ chuyển file sang `archived_sessions\`, file vẫn nằm trên đĩa. Không ghi thẳng vào `state_5.sqlite`.
   - **Antigravity (phương án A theo S17, orchestra chốt 2026-11-15; phương án B xóa `.pb` để danh sách sạch hẳn thì làm sau nếu user muốn):** chỉ gỡ khi app đã đóng **và** mọi file của phiên đều không bị khóa. Kiểm khóa bằng LockProbe của Guard, vì sau khi đóng cửa sổ vẫn còn process phụ giữ file, nên `Find-AgyMainProcessId` không đủ. Xóa `.db`, `-wal`, `-shm` và `brain\<id>`.
     - **Không** sửa `conversation_summaries.db`. **Không** đụng `agyhub_summaries_proto.pb`, vì đó là protobuf không có tài liệu, và app tự dựng lại dòng summary từ file này.
     - Hệ quả mà người dùng thấy: conversation vẫn còn trong danh sách của Antigravity, nhưng mở ra thì báo "Conversation unavailable". Hộp xác nhận phải nói rõ điều này.
     - Restore chỉ cần chép lại `.db` (cùng `-wal`) và `brain\<id>`. S17 đã xác nhận chat quay lại đủ nội dung.
6. Bản gốc bị xóa hẳn hay qua Recycle Bin: theo Q1, mặc định xóa hẳn sau khi bước 3 và 4 đạt. Có hộp xác nhận.
7. Ghi một dòng vào `archive-index.jsonl` của kho: `{ key, harness, title, bytes, zipBytes, archivedAt, machineId, entry }`.

### 5.2 Restore (khôi phục)

1. Đọc `archive.json` và kiểm sha của mọi mục trước khi ghi (dùng lại giới hạn kích thước của `Read-HarnessBundle`).
2. App đích phải đóng: Claude với các profile trong `restore.claude.profiles`, Codex với `CODEX_HOME`, Antigravity với thư mục dữ liệu.
3. Ghi từng mảnh về đúng `originalPath`.
   - File đã tồn tại và khác sha thì đổi tên file đang có thành `.bak-<ts>` trước.
   - Profile Claude không còn thì ghi vào Default và cảnh báo (Q6).
4. Đăng ký lại:
   - **Codex (chốt theo S16):** chép rollout về đúng `sessions\yyyy\mm\dd\<tên gốc>`, rồi gọi `thread/read` qua app-server. Codex tự đăng ký lại phiên, mọi cột giống bản gốc trừ `recency_at_ms`. Nếu `thread/read` không đăng ký lại được thì dùng `Register-CodexThread` như GĐ2.
   - **Antigravity:** chép lại `.db`, `-wal` và `brain\<id>`, khi app đóng. Không cần ghi DB nào, vì app tự lập chỉ mục lại (S17).
   - **Claude:** chỉ cần ghi file. Desktop đọc `local_*.json` khi khởi động.
5. Xóa dòng khỏi `archive-index.jsonl` và giữ zip lại. Chỉ xóa zip khi user chọn "Delete archive".

### 5.3 Trim (cắt output lớn)

- **Luôn archive trước** (§5.1, bước 1 đến 4, nhưng không gỡ bản gốc). Sau đó thay bản gốc bằng bản đã cắt.
- **Claude jsonl:** với mỗi `tool_result` có nội dung text lớn hơn 16 KB (Q3), giữ 2 KB đầu và 1 KB cuối, ở giữa chèn `[... N KB trimmed; full output in archive <key> ...]`. Mọi trường khác (`uuid`, `parentUuid`, `sessionId`, `cwd`, `timestamp`) giữ nguyên byte. Ảnh base64 trong `tool_result` được thay bằng `[image trimmed]`. Các file trong `<cli>\tool-results\` lớn hơn ngưỡng được rút gọn theo cùng quy tắc.
- **Codex rollout (`.jsonl`):** dòng `response_item` loại `function_call_output` hoặc `custom_tool_call_output` có `output` lớn hơn ngưỡng thì cắt như trên. `.zst` thì không cắt được (`Trimmable=$false`).
  - **S14 đạt (2026-11-15, user xem trực tiếp):** jsonl Claude đã cắt vẫn hiện, mở được và nhận tin mới, nên Claude được **cắt tại chỗ**. Bản thử của S14 cắt cả `toolUseResult` (stdout và bản sao của khối text); cắt ít hơn mức đó cũng an toàn. Cắt thêm `toolUseResult` để giải phóng nhiều hơn là việc tiếp theo.
  - **S15 đạt (2026-11-15):** rollout đã cắt vẫn `thread/read` và `thread/resume` y như bản gốc, nên Codex được **cắt tại chỗ**. Chỉ dòng bị cắt được phép đổi thứ tự khóa hoặc khoảng trắng; mọi dòng khác phải giữ nguyên từng byte.
  - Không cắt rollout của sub-agent (`Flags.Subagent`), vì resume loại này bị từ chối ngay từ bản gốc.
- **Antigravity:** không hỗ trợ.
- **Điều kiện bắt buộc trước khi bật cho từng harness:** spike S14 (Claude) và S15 (Codex) phải chứng minh phiên đã cắt vẫn mở và tiếp tục được. Harness nào không đạt thì Trim chỉ tạo **bản đọc** `<key>.trimmed.md` trong kho lưu trữ, còn phiên gốc giữ nguyên. Trong trường hợp đó, user muốn giải phóng dung lượng thì dùng Archive.
- Ghi vào kho `<key>.trim.json`, gồm số byte trước và sau, và số mục đã cắt.

### 5.4 Summarize (tóm tắt bằng AI)

- **Archive trước** (§5.1, không gỡ bản gốc).
- **Đầu vào:** transcript chuẩn hóa của adapter (`ConvertFrom-ClaudeJsonl`, `Get-CodexTranscriptEntries`, `ConvertFrom-AgyTranscriptJsonl`/`ConvertFrom-AgyDb`), đi qua `Protect-TranscriptEntries`, rồi `ConvertTo-HandoffMarkdown` với giới hạn ký tự (mặc định 400k ký tự, khoảng 100k token). Phần vượt giới hạn được cắt từ đầu, giữ phần cuối.
- **Công cụ:** CLI có sẵn trên máy, chạy headless trong một thư mục tạm rỗng để không đọc `CLAUDE.md` hay `AGENTS.md` của dự án.
  - Ưu tiên CLI của chính harness đó: `claude -p` cho Claude, `codex exec` cho Codex.
  - Antigravity thì dùng CLI nào có sẵn, ưu tiên `claude` (Q5).
  - Cờ cụ thể (không tool, chỉ xuất text, timeout) do S19 chốt.
  - **Không lưu API key**, chỉ dùng phiên đăng nhập sẵn có của CLI.
- **Xác nhận bắt buộc:** hộp thoại ghi rõ công cụ, ước lượng token đầu vào (số ký tự / 4), số phiên trong lô, câu "This sends the redacted transcript to <provider> using your <tool> sign-in and uses tokens", và nút `Summarize` không phải nút mặc định.
- **Đầu ra:** `<key>.summary.md` trong kho, gồm tiêu đề, cwd, các quyết định, việc còn dở, file đã chạm. Từ bản tóm tắt có hai lựa chọn:
  - "Start a new chat from this summary": dùng `ImportHandoff` của harness như GĐ2 và GĐ3.
  - "Archive the original": thực hiện bước 5 và 6 của §5.1.
- Lô nhiều phiên chạy tuần tự, có Stop. Phiên lỗi được ghi vào kết quả và không chặn các phiên còn lại.

### 5.5 Delete (xóa vào Recycle Bin)

- Dùng `Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile` / `DeleteDirectory` với `RecycleOption.SendToRecycleBin` và `UIOption.OnlyErrorDialogs`.
- **Chặn trước** mọi trường hợp Windows sẽ xóa hẳn mà không vào thùng rác. Theo S18 (2026-11-15), file lớn hơn hạn mức thùng rác bị xóa hẳn **im lặng**: không có ngoại lệ, không có hộp thoại. Chỉ cho xóa khi **mọi** mảnh của phiên thỏa cả bốn điều kiện:
  1. Ổ đĩa kiểu `Fixed` (ổ mạng thì luôn chặn).
  2. Ổ không phải ổ Drive for desktop. Ổ này có `$Recycle.Bin` riêng nhưng không có khóa hạn mức, và từng có mục bị tự mất, nên luôn chặn.
  3. Có khóa `HKCU\...\BitBucket\Volume\<id>` với `NukeOnDelete = 0` và `MaxCapacity` (MB). Không đọc được khóa thì chặn.
  4. Tổng dung lượng phiên trên ổ đó nhỏ hơn `MaxCapacity`.
  
  Không thỏa thì báo "cannot go to the Recycle Bin, archive it instead", và không xóa gì.
- **Codex:** không dùng `thread/delete`, vì lệnh này xóa hẳn. Thay vào đó gọi `thread/archive` để app tự chuyển rollout sang `archived_sessions\` và đặt `archived=1`, rồi đưa file ở đó vào Recycle Bin. Dòng `archived=1` còn lại thành mồ côi. S16 đã thử: vô hại, app-server không lỗi, và phiên không hiện trong danh sách vì danh sách lọc `archived = 0`. Cách này không cần ghi DB, kể cả khi app đang mở.
- **Antigravity:** đưa `.db`, `-wal`, `-shm` và `brain\<id>` vào Recycle Bin, không đụng DB nào, giống §5.1. Conversation vẫn hiện trong danh sách của Antigravity ở trạng thái "unavailable" cho tới khi user xóa nó trong chính app, hoặc khôi phục file từ thùng rác.
- **Hộp xác nhận** ghi số phiên, tổng dung lượng, danh sách profile bị ảnh hưởng, và câu "Recoverable from the Recycle Bin until it is emptied".

## 6. Kho lưu trữ

- **Setting** `Storage.ArchiveTarget`:
  - `{ kind:'local', path }`: đường dẫn tuyệt đối, kiểm bằng `Test-SyncAbsolutePath`.
  - `{ kind:'drive' }`: dùng thư mục sync của GĐ4.
  - Chưa đặt thì lần archive đầu hỏi user. Gợi ý `%USERPROFILE%\HarnessArchive`.
- **Kho local:** `<path>\<harness>\<yyyy-MM>\<keySafe>.harchive.zip`, kèm `<path>\archive-index.jsonl`. Chỉ máy này ghi.
- **Kho Drive:**
  - `HarnessSync\archives\<machineId>\<harness>\<keySafe>.harchive.zip.enc`, mã hóa bằng `Protect-SyncFile`, ghi bằng `Write-SyncFileAtomic` hoặc `Copy-SyncFileAtomic`, tuân theo các quy tắc của S10.
  - Mỗi máy chỉ ghi vào thư mục của mình và `archives\<machineId>.jsonl` của mình, với tiêu đề mã hóa như D3.
  - Restore từ máy khác: tải về `%TEMP%`, kiểm sha, giải mã, rồi đi tiếp như §5.2 với ánh xạ cwd của C1. Riêng Claude: đường dẫn transcript được dựng lại theo slug của cwd đã ánh xạ.

## 7. Giao diện: tab "Storage"

```
[ Claude ] [ Codex ] [ Antigravity ] [ Drive ] [ Storage ]
 Storage                                   Archive to: D:\HarnessArchive  [Change]   [Scan] [Stop]
 Last scan 13:40 (11,132 files, 12 s)        ███████░░ scanning projects... 7,400 / 11,132
 +----------------------+----------+---------+----------+-----------+
 | Profile              | Harness  | Sessions| Size     | App data  |   (bảng profile; dòng "CLI / no profile")
 +----------------------+----------+---------+----------+-----------+
 Sessions   Harness:[All v]  Size >= [Any|1 MB|10 MB|100 MB]  Idle for >= [Any|7|30|90 days]  State:[Idle v]  [search...]
 +--+-------------------------+---------+-------------+--------+-------------+---------+--------+
 |[]| Title                   | Harness | Profiles    | Size v | Last active | Folder  | State  |
 +--+-------------------------+---------+-------------+--------+-------------+---------+--------+
 Selected: 37 sessions, 4.2 GB      [Archive...] [Trim...] [Summarize...] [Delete...]      View: (Live) (Archived)
```

- **View "Archived"** liệt kê `archive-index.jsonl`, với các nút `Restore...`, `Delete archive...`, `Open summary`.
- Có ô tick để chọn nhiều phiên. Mặc định sắp theo `Size` giảm dần. Bộ lọc và cách sắp được nhớ trong `Ui.StorageView`.
- Mọi thao tác chạy nền, có thanh tiến độ và Stop. Kết quả hiện trong một danh sách gọn (thành công, bỏ qua kèm lý do, lỗi).
- Các tab chat hiện có không đổi. Chỉ cột `Size` có thể thêm sau (ngoài phạm vi).

## 8. Spike cần trước khi code (chỉ trên bản sao)

| Spike | Câu hỏi | Đạt khi | Ảnh hưởng |
|---|---|---|---|
| S14 (**USER ACTION**, nhìn) | Phiên Claude có jsonl đã cắt (§5.3) có hiện, mở và tiếp tục được trong một profile thử không? | Hiện, mở được, gửi một tin thì chat tiếp bình thường | Không đạt thì Trim Claude chỉ ra bản đọc |
| S15 | Rollout Codex đã cắt có `thread/read` được trong một home `spike*` không? `thread/resume` qua app-server có tốn lượt gọi model không? | `thread/read` đọc đủ turn, và có xác nhận rằng resume không gọi model | Không đạt thì Trim Codex chỉ ra bản đọc |
| S16 | Codex app-server có `thread/archive` / `thread/unarchive` (và `thread/delete`) không? Chúng làm gì với rollout và cột `archived`? Ghi trực tiếp `archived=1` khi app đóng có an toàn không? | Biết phương thức nào dùng được và trạng thái sau đó | Chọn phương án A hoặc B ở §5.1 |
| S17 | Antigravity: xóa `conversations\<id>.db` và `brain\<id>` mà giữ dòng summary thì app hiện gì? Khôi phục `.db` thì chat có quay lại không? | Biết có cần sửa `conversation_summaries.db` không | Quy tắc xử lý Antigravity ở §5.1 và §5.2 |
| S18 | Recycle Bin: `SendToRecycleBin` với file lớn hơn quota, với ổ DriveFS và với ổ mạng thì xảy ra gì khi dùng `OnlyErrorDialogs`? | Biết chính xác trường hợp nào bị xóa hẳn | Quy tắc chặn ở §5.5 |
| S19 | Headless: `claude -p` và `codex exec` cần cờ gì để tắt tool, chỉ xuất text và nhận stdin lớn? Thời gian và lỗi với 400k ký tự là bao nhiêu? | Có một lệnh chạy được, kèm số đo | Chốt §5.4 |
| S20 | Quét thật bằng `EnumerateFiles` cộng đọc đầu và cuối file trên **bản sao danh sách** (chỉ đọc, không ghi gì vào `~\.claude`) | Số đo khi chưa có cache và khi cache đã nóng | Xác nhận mục tiêu hiệu năng ở §3 |

S20 chỉ đọc dữ liệu thật, không ghi. Mọi spike còn lại chạy trên bản sao trong `%TEMP%` hoặc trên profile `spike*`.

## 9. Câu hỏi mở và mặc định đề xuất

| # | Câu hỏi | Mặc định đề xuất |
|---|---|---|
| Q1 | Sau khi archive đạt, bản gốc bị xóa hẳn hay qua Recycle Bin? | Xóa hẳn, vì archive đã là bản sao lưu có kiểm sha và mục tiêu là giải phóng dung lượng. Có setting `Storage.ArchiveRecycleOriginals` để chọn qua thùng rác |
| Q2 | Ngưỡng "vừa hoạt động" | 30 phút, đổi được trong settings |
| Q3 | Ngưỡng cắt output | Output lớn hơn 16 KB thì giữ 2 KB đầu và 1 KB cuối. Ảnh base64 luôn bị thay |
| Q4 | Archive lên Drive có mã hóa không? | Có, bắt buộc, giống GĐ4 |
| Q5 | Tóm tắt dùng CLI nào? | CLI của chính harness đó. Antigravity dùng `claude`, không có thì dùng `codex` |
| Q6 | Khôi phục khi profile cũ không còn | Ghi vào Default và cảnh báo |
| Q7 | Phiên Claude được nhiều profile tham chiếu | Archive hoặc delete gỡ khỏi mọi profile. Hộp xác nhận liệt kê các profile đó |
| Q8 | Thư mục archive mặc định | Chưa đặt thì hỏi ở lần đầu, gợi ý `%USERPROFILE%\HarnessArchive` |
| Q9 | Rollout `.zst` | Không cắt được, chỉ archive và delete |
| Q10 | Dọn dữ liệu ứng dụng (cache) của profile | Chỉ thống kê ở GĐ6 |
| Q11 | Giữ zip sau khi restore? | Giữ, chỉ xóa khỏi index. User tự chọn "Delete archive" |

## 10. Tiêu chí hoàn thành

- Thống kê không đếm trùng: tổng của harness bằng tổng `Bytes` các phiên duy nhất (có test).
- Không thao tác nào chạm vào phiên `live`, `recent` (trừ khi user cho phép từng phiên) hoặc `protected` (có test cho từng điều kiện).
- Archive rồi restore một phiên trên bản sao cho ra cây file giống hệt từng byte (có test cho cả 3 harness).
- Delete chỉ đi vào Recycle Bin. Trường hợp sẽ bị xóa hẳn thì bị chặn (theo S18).
- Summarize không bao giờ chạy khi chưa có xác nhận, và không lưu khóa nào.
- Quét không chặn UI, có cache, và chỉ chạy khi bấm nút.
