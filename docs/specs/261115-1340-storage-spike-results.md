

## S17: Antigravity gỡ rồi khôi phục một conversation — **ĐẠT, nhưng phức tạp hơn spec giả định**

Script: `tools\spikes\Spike-S17-AgyRemoveRestore.ps1 -Action Prepare|Launch|Inspect|Remove|Restore|RemoveRow|RemoveOtherStores|RemoveHubCache|Cleanup`. Chạy một bản Antigravity thử riêng (`--user-data-dir` riêng và HOME giả như S4); dữ liệu thật chỉ được đọc (một conversation nhỏ, `.db` 256 KB và `brain` 21 file, chép ra bằng snapshot). Người dùng nhìn giao diện (US2). Mọi thứ đã dọn, kể cả 14 process phụ (`cmd.exe`, `Antigravity.exe` sidecar) mà cửa sổ thử để lại sau khi đóng và có đường dẫn thư mục thử trên command line.

Bản app: Antigravity mới ("Welcome to the new Antigravity", có nút Open IDE). Lần đầu mở có hộp "Download the Antigravity IDE" đang tick sẵn; người dùng đã bỏ tick.

Quan sát, theo thứ tự:

1. **Chép `.db` + `brain` vào thư mục dữ liệu rồi mở lần đầu:** danh sách trống, `conversation_summaries.db` mới tạo 0 dòng. App **không quét `conversations\` ở lần mở đầu của một thư mục dữ liệu mới**. Đồng thời app tự tạo `antigravity-backup\` và `antigravity-ide\` bên cạnh `antigravity\` và chép conversation vào cả hai (migration của bản mới).
2. **Mở lần thứ hai:** conversation hiện (dưới project theo cwd), mở được, `conversation_summaries.db` có 1 dòng (`status=CASCADE_RUN_STATUS_IDLE`, `step_count`=7, `killed=0`), 2 dòng chỉ mục tìm kiếm (FTS). Cũng có `agyhub_summaries_proto.pb`, `annotations\<id>.pbtxt`, `presence\<id>.lock`.
3. **Gỡ `.db`, `-wal`, `-shm` và `brain\<id>`, giữ dòng tóm tắt (đúng câu hỏi của spec):** conversation **vẫn nằm trong danh sách**; bấm vào thì hộp "Conversation unavailable: The conversation could not be loaded because its data was not found." Không có thông báo nào khác.
4. **Khôi phục `.db` + `brain` từ bản sao (dòng tóm tắt giữ nguyên):** chat quay lại, đủ nội dung. Không cần sửa `conversation_summaries.db`.
5. **Gỡ file + xóa dòng trong `conversation_summaries.db`:** conversation **vẫn hiện** và dòng tóm tắt được **dựng lại** (cùng `step_count`) ngay lần mở tiếp theo. Bấm vào thì vẫn báo "data was not found".
6. **Gỡ thêm bản chép trong `antigravity-ide\` và `antigravity-backup\`, xóa dòng:** **vẫn hiện lại**, nguồn dựng lại không phải hai thư mục đó.
7. **Gỡ file + xóa dòng + xóa `agyhub_summaries_proto.pb` (bộ đệm tóm tắt của "hub"): conversation BIẾN MẤT khỏi danh sách**, không lỗi, dòng không được dựng lại. Vậy `agyhub_summaries_proto.pb` là nguồn mà app dùng để dựng lại `conversation_summaries.db`. (Trong thư mục thật file này nặng khoảng 0,9 MB.) Chưa tách riêng được việc hai bản chép `antigravity-ide\`/`antigravity-backup\` có cần gỡ không; ở bước 7 chúng đã bị gỡ sẵn.
8. **Chép `.db` + `brain` về khi không còn dòng tóm tắt và không còn `.pb`:** lần mở **đầu tiên** conversation hiện lại và mở được, không lỗi. App tự lập chỉ mục lại từ `conversations\` trong trường hợp này (khác bước 1, nơi thư mục chưa có `conversation_summaries.db`).
9. Cũng quan sát: app **không tự xóa** dòng tóm tắt mồ côi, và bản chạy thử không thấy gì khác khi `conversation_summaries.db` có dòng mà không có file ngoài hộp lỗi ở bước 3.

- **Hệ quả cho spec §5.1/§5.2 (Antigravity):**
  - Gỡ `.db` + `brain` **không đủ**: conversation vẫn hiện như một mục lỗi. Muốn nó biến mất khỏi app phải xóa **cả** dòng trong `conversation_summaries.db` (và dòng FTS/`conversation_parents` của nó) **và** mục của nó trong `agyhub_summaries_proto.pb`. Spec phải thêm bước sửa `agyhub_summaries_proto.pb` (protobuf nhị phân, nặng ~0,9 MB, không có test nào cho định dạng này); hoặc cách rẻ hơn mà chưa kiểm: xóa cả file `agyhub_summaries_proto.pb` và để app dựng lại, chưa biết nó dựng lại đủ cho các conversation còn lại hay không (spike chỉ có một conversation). **Đây là rủi ro lớn nhất của lane A1 cho Antigravity**; cần một spike nhỏ với 2 conversation nếu muốn chọn cách xóa cả file.
  - Restore **không cần** tạo lại dòng tóm tắt: chép `.db` (+`-wal`) và `brain\<id>` về `conversations\` là đủ, app tự lập chỉ mục lại ở lần mở sau (bước 8) và chat mở bình thường. Nếu dòng tóm tắt mồ côi còn đó thì khôi phục file cũng đủ (bước 4).
  - Nên cho `Test-StorageSessionSafe` coi Antigravity đang chạy là `protected` như spec (app giữ `.db` và ghi `conversation_summaries.db`/`.pb`), vì cả hai file chỉ mục đều bị app ghi lúc chạy.
  - Cần ghi nhớ: lần đầu app mở một thư mục dữ liệu chưa có `conversation_summaries.db` thì không quét `conversations\`; điều này không ảnh hưởng thư mục thật đã có chỉ mục.
  - Chưa kiểm: `antigravity-ide\` thật (trên máy chính có hàng nghìn conversation, là kho của app IDE, không phải của app mới) có liên quan đến danh sách của app mới hay không.


## S15: rollout Codex đã cắt tool output có còn mở và resume được không — **ĐẠT**

Script: `tools\spikes\Spike-S15-CodexTrimmedRollout.ps1 -SourceRollout <rollout không phải sub-agent>`. Dùng `CODEX_HOME` thử dưới `%TEMP%\harness-spike\S15` (không `auth.json`), `codex app-server`, không gửi `turn/start`. Rollout nguồn thật (549 dòng, ~1,4 MB) chỉ đọc; bản thử đổi id, cwd và `model_provider`/`model_provider_id` thành `openai`; 3 tool output được thổi lên ~330 KB mỗi cái (tổng 2,5 MB) làm bản "trước"; bản "sau" cắt theo spec §5.3 (output > 16 KB giữ 2 KB đầu + marker + 1 KB cuối): 3 dòng bị cắt, 546 dòng giữ nguyên từng byte, còn 1,4 MB. Đã dọn thư mục thử.

| | Trước cắt | Sau cắt |
|---|---|---|
| `thread/read` (includeTurns) | OK | OK |
| `thread/resume` | OK, status `idle` | OK, status `idle` |
| `thread/items/list` | 147 item | 147 item |
| `thread/turns/list` | 2 | 2 |

- Kết quả hai bản **giống hệt nhau**: cắt tool output không làm app-server từ chối rollout, và số turn/item không đổi.
- **Tìm marker không thấy trong `thread/items/list`** ở cả hai bản (chuỗi `BIGOUTPUT-0` cũng không xuất hiện ở bản trước): danh sách item không chứa nguyên văn tool output đã thổi lên, nên spike không chứng minh được nội dung tool output hiện ra trong UI. Điều chứng minh được là file hợp lệ và resume bình thường. Nếu spec cần "marker hiện trong UI" thì phải xem bằng app thật (S14 làm việc này cho Claude, Codex chưa có).
- **`thread/resume` không gửi lượt nào nhưng có thử kết nối model:** stderr của app-server ghi `failed to connect to Responses WebSocket` (kết nối tạo sẵn; máy này không tới được cổng model). Resume vẫn thành công, nên resume **không cần** model sống, nhưng người dùng có mạng thì app-server sẽ mở một kết nối tới model khi resume (không phát sinh token).
- Hai điều kiện suýt làm spike hỏng, spec/C1 cần biết: (1) resume bị từ chối `modelProviderNotConfigured` nếu `model_provider`/`model_provider_id` trong rollout trỏ tới provider không có trong `config.toml` đang chạy; (2) resume bị từ chối cho rollout của sub-agent ("resume the parent first"). Với rollout đã cắt, giữ nguyên hai trường này là đúng, không đụng tới.
- **Hệ quả:** spec §5.3 cho Codex đứng vững: một rollout đã cắt vẫn là rollout hợp lệ. Chỉ cần chỉnh một dòng: dòng cắt phải được JSON-serialize lại (đã làm trong prototype) nên **thứ tự khóa và khoảng trắng của riêng dòng bị cắt có thể đổi** so với bản gốc; các dòng khác giữ nguyên byte.

## S19: gọi tóm tắt headless qua `claude -p` / `codex exec` — **Claude ĐẠT; Codex BỊ CHẶN bởi môi trường**

**Kết quả Claude (sau khi người dùng đăng nhập lại CLI):** một lần gọi thật với lệnh dưới đây, transcript giả ~20 000 ký tự (~5 000 token), model mặc định: **22 giây, exit 0, 811 ký tự output**, bản tóm tắt **có nhắc** yêu cầu cuối ("rename to Download"). Không có stderr. Một lần gọi trước đó lúc phiên đăng nhập hết hạn thất bại sau 5 giây với "OAuth session expired" (exit 1, 73 ký tự), nên UI phải coi "CLI chưa đăng nhập" là lỗi thường gặp và hiện thông báo rõ. Dùng 1 trong 2 lần gọi thật cho phép với Claude (lần lỗi đăng nhập không tới model).

Script: `tools\spikes\Spike-S19-HeadlessSummarize.ps1 -Tool claude|codex [-Chars] [-TimeoutSec] [-Model] [-Run]` (không có `-Run` thì chỉ in lệnh). Transcript giả ~20 000 ký tự (~5 000 token), chạy trong thư mục tạm rỗng, prompt qua stdin, timeout tự giết cả cây process.

- Lệnh Claude đã chọn: `claude -p --tools "" --output-format text --no-session-persistence --disable-slash-commands --max-turns 1` (prompt từ stdin; **không** dùng `--bare` vì nó tắt OAuth/keychain, hỏng với đăng nhập gói thuê bao).
- Lệnh Codex đã chọn: `codex exec --skip-git-repo-check --ephemeral -s read-only --color never -C <thư mục rỗng> -o <file> -` (prompt từ stdin).
- **Claude:** lần đầu phiên OAuth hết hạn nên chưa gọi được; sau khi người dùng đăng nhập lại đã đo được (xem đầu mục).
- **Codex:** `codex exec` chạy 601 giây không ra kết quả (exit: bị giết do timeout, 0 ký tự output): stderr dừng ở banner rồi kẹt vòng thử lại "waiting for network"; cổng model cục bộ mà cấu hình Codex đang dùng không tới được lúc này (cùng nguyên nhân với `failed to connect to Responses WebSocket` ở S15). 1 lần gọi thật đã tiêu, không có token đầu ra.
- **Chưa biết:** số đo cho Codex. Tính năng tóm tắt headless đã khả thi với Claude (22 s cho ~5 000 token); với Codex chờ cổng model chạy lại rồi chạy `-Tool codex -Run`.
- Quan sát có ích dù bị chặn: tóm tắt headless phụ thuộc đăng nhập/mạng của chính CLI, nên UI phải xử lý "CLI chưa đăng nhập / không có mạng" như lỗi bình thường (hết giờ, thông báo rõ, không treo), và phải có timeout cứng + giết cả cây process (script đã dùng `taskkill /T /F`).


## S14 (US1): chat Claude đã cắt tool result có còn hiện, mở và nhận tin mới không — **ĐẠT**

Script: `tools\spikes\Spike-S14-ClaudeTrimmedJsonl.ps1 -Action Setup|Cleanup -ProfileName <profile đã đăng nhập> [-ThresholdKB 4]`. Nguồn là một chat thật nhỏ (jsonl ~169 KB, đọc chứ không sửa); Setup thêm hai chat mới vào profile thử, mỗi chat có id mới, thư mục dự án rỗng mới và `cwd` viết lại: **CONTROL** (bản chép nguyên) và **TRIMMED** (mọi text của tool result vượt ngưỡng cắt còn 2 KB đầu + marker + 1 KB cuối, cả trong khối `tool_result` lẫn bản lặp `toolUseResult`: 4 giá trị bị cắt, 166 KB -> 155 KB; các dòng còn lại không đổi). Ngưỡng thử là 4 KB vì chat nhỏ không có kết quả nào tới 16 KB; cấu trúc cắt không phụ thuộc ngưỡng. Người dùng mở từng chat trong app, gửi một tin vào mỗi chat. Đã chạy Cleanup, các file thêm vào đã bị xóa (kiểm).

- Người dùng báo: **cả hai chat hiện trong danh sách, mở được, hiển thị nội dung và nhận tin mới bình thường** (profile Account 2, app đã đăng nhập).
- Bài học khi viết bản cắt: nội dung tool result có **ba dạng**: mảng khối `{type:text,text}` (trong `message.content[*].content` và lặp lại trong `toolUseResult`), chuỗi trơn trong `tool_result.content`, và `toolUseResult.stdout` (kết quả Bash). C1 phải xử lý cả ba; bản đầu của spike chỉ xử lý dạng đầu nên không cắt gì trên chat này.
- Dòng bị cắt đi qua `ConvertTo-Json` của PS 5.1 nên khóa giữ nguyên thứ tự nhưng `<`, `>`, `'`, `&` bị escape thành `\uXXXX` (JSON hợp lệ, app vẫn đọc). Nếu muốn giữ từng byte của dòng bị cắt, thay chuỗi trực tiếp thay vì parse lại.
- Chưa kiểm: chat có `<cli>\` thư mục con (sub-agent) và một chat thật lớn tới 16 KB mỗi output.

## S20: thời gian quét kho kiểm kê trên `~\.claude\projects` thật — **ĐẠT, nhanh hơn nhiều so với mục tiêu**

Script: `tools\spikes\Spike-S20-ScanTiming.ps1` (chỉ đọc; bộ nhớ đệm đặt trong `%TEMP%` rồi xóa). Dữ liệu thật: 11 133 file `*.jsonl`, 17,9 GB, file lớn nhất 295 MB, không lỗi liệt kê.

| Bước | Thời gian |
|---|---|
| Chỉ liệt kê (EnumerateFiles, bỏ reparse point) | 0,4 s |
| Lượt 1: chưa có cache, đọc 64 KB đầu + 64 KB cuối mỗi file (1 365 MB) | 7,4 s (184 MB/s) |
| Lượt 2: cache nóng (nạp cache 0,34 s, so size + mtime, không đọc file) | 0,9 s |
| Lượt 3: 1% (112 file) đọc lại | +0,1 s |

- Cache JSON tối thiểu (`cwd`, thời điểm cuối, size, mtime mỗi file) nặng 2,8 MB.
- **Mục tiêu spec** (cache nóng dưới 15 s cho ~11k file; quét đầu dưới 2 phút): đạt xa, lượt 2 dưới 1 s, lượt 1 dưới 10 s.
- **Lưu ý:** lượt 1 không phải "đĩa nguội": hệ điều hành đã giữ phần lớn dữ liệu trong bộ nhớ đệm file vì lần chạy đầu của chính spike này đã đọc cả kho (xem dưới). Số 184 MB/s là thấp so với đọc từ RAM nên có thể một phần vẫn lấy từ đĩa NVMe; chưa đo đĩa hoàn toàn nguội. Dù nguội thì với 1,4 GB cần đọc và vài chục MB/s tối thiểu vẫn dưới 2 phút.
- **Bài học cho scanner:** bản đầu của script dùng regex tham lam `(?s).*"timestamp":"..."` trên 128 KB mỗi file và chạy hơn 35 phút (CPU 1 760 s, không xong); sửa bằng `LastIndexOf` thì chỉ còn 7,4 s. Scanner phải tìm thời điểm cuối bằng `LastIndexOf`/`IndexOf` trên chuỗi, không dùng regex có `.*` tham lam trên khối lớn.
