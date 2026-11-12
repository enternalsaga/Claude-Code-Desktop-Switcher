# Plan GĐ5: cửa sổ chính có tab, trạng thái chat và sync trực quan

- Base: `a6feb09` trên `desktop-4.29-patches`. Giai đoạn 4 đã land xong.
- Nguồn: user yêu cầu ngày 2026-11-12, rằng ba thao tác (bật sync và Push, Pull trên máy khác, xử lý chat phân kỳ) phải hiện trực quan trong app.
- User đã chọn:
  - Cửa sổ chính có các tab Claude, Codex, Antigravity và Drive.
  - Mỗi chat hiện 4 loại trạng thái: đã lên Drive hay chưa, Drive có bản mới hơn, phân kỳ (báo trước khi Pull), thiếu thư mục làm việc.
  - Viết plan rồi code luôn, không làm mockup.
- Spec: `docs/specs/261111-1200-multi-harness-manager-and-drive-sync-spec.md` §9 và §11 (GĐ5).
- Người viết và người duyệt: `switcher-think-multiharness`. Người land: orchestra.
- Quy tắc chung giữ như §0 của plan GĐ4:
  - TDD.
  - Kiểm tra nhẹ theo từng file test.
  - Không đụng dữ liệu thật.
  - Không hardcode thông tin cá nhân.
  - Mã nguồn chỉ ASCII.
  - Mỗi file `src` không quá 500 dòng, mỗi hàm không quá 100 dòng.

## 0. Hiện trạng (vì sao phải làm lại)

- Sync và chuyển chat chỉ đi qua một hộp thoại "Move or hand off a chat" (3 ô thả xuống, một danh sách, nút Go). Hộp thoại đó được mở từ mục menu chuột phải "Export chat for handoff..." hoặc từ tray.
- Không nơi nào cho thấy chat nào đã lên Drive, chat nào có bản mới hơn trên Drive, hay thư mục làm việc nào bị thiếu.
- Chat phân kỳ được tự nhập thành chat mới. User chỉ nhận một thông báo chữ sau khi việc đã xong.
- Codex và Antigravity chỉ có mục trong tray, không có chỗ nào trong cửa sổ chính.
- `Show-HarnessExportDialog` dài 125 dòng, vượt trần 100 dòng.

## 1. Thiết kế

### 1.1 Khung cửa sổ

```
+-----------------------------------------------------------------------------------------+
| Profile Switcher                                                                  _ [] X |
| [ Claude ] [ Codex ] [ Antigravity ] [ Drive (o) ]                                        |
|-----------------------------------------------------------------------------------------|
|  Claude accounts                          (phần hiện có của switcher, giữ nguyên)        |
|  +------------------------------------------------------------------------------------+ |
|  | Profile          Status        Last used                                          | |
|  +------------------------------------------------------------------------------------+ |
|  [Launch] [Add account] [Shortcuts] [Transfer chats]                       [Delete]     |
|-----------------------------------------------------------------------------------------|
|  Chats of <profile đang chọn>                         [Search.......]   (Refresh)       |
|  +------------------------------------------------------------------------------------+ |
|  |    Title                     Folder          Last active    Drive                  | |
|  | o  Fix login redirect        web-app         10:42          (v) On Drive, 10:45    | |
|  | o  Refactor tray menu        switcher        yesterday      (!) Changed on both    | |
|  | o  Notes import              notes      (x)  2 days         (^) Newer on Drive      | |
|  | o  Draft spec                docs            3 days         ( ) Not on Drive        | |
|  +------------------------------------------------------------------------------------+ |
|  [Continue here]  [Move to...]  [Push to Drive]  [Pull from Drive]  [Choose folder...]  |
|  status line: Pushed "Fix login redirect" to Drive.                                     |
+-----------------------------------------------------------------------------------------+
```

- **Tab Claude:** nửa trên là toàn bộ giao diện hiện có, chép nguyên vẹn bằng cách chuyển các control sang tab (§1.4). Nửa dưới là **khung chat** của profile đang chọn.
- **Tab Codex / Antigravity:** nửa trên là danh sách profile (cột: tên, trạng thái đang chạy hay không, tài khoản hoặc loại app) với các nút `Launch`, `Add account`, `Shortcuts`. Antigravity không có `Add account` vì bị khóa một tài khoản. Nửa dưới dùng chung khung chat.
- **Tab Drive:** thẻ trạng thái, catalog trên Drive và bảng thư mục gốc (§1.3).
- Nhãn tab Drive có chấm báo `(o)` khi catalog có chat "Newer on Drive" hoặc "Changed on both" cho máy này.
- Kích thước cửa sổ mặc định 900×720, tối thiểu 820×620. Vị trí và tab đang mở được nhớ trong settings (`Ui.LastTab`).
- Chuỗi giao diện bằng tiếng Anh, như phần còn lại của app.

### 1.2 Trạng thái chat (cột Drive và cột Folder)

| Trạng thái | Biểu tượng + chữ | Khi nào | Nút được làm nổi |
|---|---|---|---|
| `NotOnDrive` | vòng xám, "Not on Drive" | Không có row nào trong catalog cho `chatKey` của chat | Push to Drive |
| `Synced` | dấu tick xanh, "On Drive, <giờ>" | Row mới nhất là `lastBundleId` của sync-state, và chat local không đổi kể từ lần sync | (không nút nào) |
| `LocalNewer` | mũi tên lên, "Changed here, push to update" | Row mới nhất là `lastBundleId`, nhưng chat local đã đổi sau lần sync | Push to Drive |
| `DriveNewer` | mũi tên xuống xanh dương, "Newer on Drive (from <máy>)" | Row mới nhất khác `lastBundleId`, và chat local không đổi kể từ lần sync | Pull from Drive |
| `Diverged` | tam giác cam, "Changed on both machines" | Row mới nhất khác `lastBundleId`, và chat local cũng đã đổi | Pull from Drive (mở hộp chọn, §1.5) |
| `CwdMissing` (cột Folder) | biểu tượng thư mục gạch chéo, tooltip có đường dẫn | Thư mục làm việc của chat không tồn tại trên máy này | Choose folder... |

- Cách tính phải khớp với `Get-SyncDivergence`. Hàm `Get-HarnessChatSyncStatus` là hàm thuần, chỉ đọc catalog đã tải, sync-state và chat local.
- Catalog chỉ được tải khi mở tab, khi bấm Refresh, hoặc sau một lần Push hay Pull. Không đọc Drive trong lúc vẽ danh sách.
- Chưa thiết lập sync: cột Drive hiện "Set up Drive sync" màu xám, và các nút Push/Pull mở trình thiết lập (§1.6).

### 1.3 Tab Drive

```
+-----------------------------------------------------------------------------------------+
|  Drive sync                                                                             |
|  [card] Google Drive: <nhãn account>   Folder: HarnessSync   This machine: <tên máy>     |
|         Key: remembered on this machine   Last refresh: 10:45       [Refresh] [Settings] |
|-----------------------------------------------------------------------------------------|
|  Chats on Drive                                       Show: (All) (Needs action)         |
|  +------------------------------------------------------------------------------------+ |
|  |    Title              Harness      From        Last active   On this machine      | |
|  | o  Fix login redirect  Claude       Laptop      10:45         (v) Up to date       | |
|  | o  Notes import        Codex        Laptop      09:10         (^) Newer on Drive   | |
|  | o  Market research     Antigravity  Laptop      yesterday     ( ) Not here         | |
|  +------------------------------------------------------------------------------------+ |
|  [Pull to...]                                                                           |
|-----------------------------------------------------------------------------------------|
|  Folder roots (where project folders live on this machine)                              |
|  | Name        | Path on this machine          |                  [Add] [Change] [Remove]|
+-----------------------------------------------------------------------------------------+
```

- **Chưa thiết lập:** thẻ trạng thái thay bằng một khối lớn gồm 3 dòng giải thích và nút `Set up Drive sync...`.
- **Cột "On this machine":** `Not here` (chưa có ở profile nào), `Up to date`, `Newer on Drive`, `Changed on both`. Dùng cùng hàm trạng thái ở §1.2.
- **`Pull to...`:** chọn profile đích. Mặc định là profile của cùng harness đã từng nhận chat này (lấy từ sync-state), nếu không có thì là Default.
- **Folder roots:** đọc và ghi qua `Get-SyncPathRoots` / `Set-SyncPathRoot`. Kiểm tên và đường dẫn bằng các hàm có sẵn. Thêm một gốc thì chọn thư mục bằng `FolderBrowserDialog`.

### 1.4 Chuyển giao diện cũ vào tab mà không sửa code upstream

- **Khối hook mới `# >>> harness-ui-main`,** đặt ngay trước `$script:ExitRequested = $false` gần cuối `ClaudeSwitcher.ps1`. Khối chỉ có một dòng: `if (Get-Command Convert-SwitcherToTabs ...) { Convert-SwitcherToTabs -Form $form -RefreshClaude { Update-List } }`.
- **`Convert-SwitcherToTabs`:**
  1. Lấy mọi control đang nằm trực tiếp trên `$form`.
  2. Chuyển chúng vào một `Panel` cao đúng bằng vùng client cũ, đặt ở đầu tab Claude. Vị trí và anchor giữ nguyên, nên các nút neo `Bottom` vẫn đúng chỗ.
  3. Thêm khung chat bên dưới.
  4. Tạo `TabControl` (Dock Fill), chứa tab Claude và các tab còn lại.
  5. Tăng kích thước form.
- Không có hàm này, hoặc hàm ném lỗi, thì cửa sổ cũ vẫn chạy y như trước. Hook được bọc `try/catch` và ghi lỗi bằng `Write-HarnessLog`.
- **Menu cũ:** "Export chat for handoff..." trong menu chuột phải và trong tray đổi thành "Chats and Drive...". Mục này mở cửa sổ ở tab của harness tương ứng, với chat đang chọn. Việc này sửa đúng hai khối `harness-ui-menu` và `harness-ui-tray`, mỗi khối một dòng.
- **Ngân sách hook:** hiện có 15 dòng code. Lane này thêm 1 dòng (`harness-ui-main`), sửa 2 dòng và không thêm dòng nào trong `harness-ui-menu` / `harness-ui-tray`. Tổng không quá 30.

### 1.5 Hộp chọn khi phân kỳ (thay cho tự động handoff)

Khi bấm Pull trên một chat ở trạng thái `Diverged`, hộp `Show-SyncDivergedDialog` hiện ra:

```
  This chat changed on this machine and on <máy> since they last synced.
  [ Bring theirs in as a new chat ]   -> handoff, tiêu đề + " (from <máy>)"  (mặc định, theo D4)
  [ Push mine as the latest ]         -> Push bản local; máy kia sẽ thấy "Changed on both"
  [ Cancel ]
```

- Hàm thuần `Resolve-SyncDivergedChoice` trả `handoff`, `push` hoặc `cancel`. `Invoke-SyncPull` nhận tham số `-OnDiverged` (scriptblock), mặc định là handoff như hiện nay. Nhờ vậy CLI và test không đổi.

### 1.6 Trình thiết lập sync 3 bước (thay `Show-SyncSetupDialog`)

```
  (1) Where  ->  (2) Passphrase  ->  (3) This machine
```

1. **Where:** mỗi account Drive là một thẻ, hiện nhãn volume và trạng thái "Sync already set up here" nếu đã có `sync.json`. Thêm một thẻ "Another folder...".
2. **Passphrase:**
   - Folder mới: nhập hai lần, kèm cảnh báo đậm và ô tick bắt buộc (giữ nguyên câu chữ của U4). Có thanh độ dài với mức tối thiểu 12 ký tự.
   - Folder đã có `sync.json`: chỉ nhập một lần, nhãn "Join the sync folder", sai thì báo ngay.
3. **This machine:** tên máy (chỉ đọc) và danh sách gốc thư mục gợi ý. `Get-SuggestedPathRoots` lấy thư mục cha chung của cwd các chat gần đây trên cả 3 harness, mỗi gốc có một ô tick. Bấm Finish thì ghi các gốc đã tick.

- Logic dùng lại `Test-SyncSetupInput` và `Invoke-SyncSetup`. Phần mới chỉ là vỏ giao diện cùng hàm thuần `Get-SuggestedPathRoots`.

### 1.7 Khung chat: hành động

| Nút | Hành động | Khi nào bật |
|---|---|---|
| Continue here | Gọi `Launch` của adapter cho profile đang chọn | Luôn bật |
| Move to... | Hộp `Show-HarnessMoveDialog` chỉ có danh sách đích (mọi profile của mọi harness đã cài), kèm một dòng giải thích native hay handoff theo `Resolve-TransferMode`, rồi gọi `Invoke-HarnessTransfer` | Có chat được chọn |
| Push to Drive | Gọi `Invoke-SyncPush` | Đã thiết lập sync và có chat được chọn |
| Pull from Drive | Gọi `Invoke-SyncPull`. Với `Diverged` thì mở hộp ở §1.5. Với `needs-root` thì hỏi thư mục, gọi `Set-SyncPathRoot` rồi thử lại | Trạng thái là `DriveNewer` hoặc `Diverged` |
| Choose folder... | `FolderBrowserDialog`, rồi `Set-SyncPathRoot` cho gốc của chat. Nếu chat không có gốc thì chỉ mở thư mục cha gần nhất còn tồn tại | Trạng thái `CwdMissing` |

- Mọi hành động chạy đồng bộ: con trỏ chờ, các nút bị khóa trong lúc chạy, kết quả hiện ở status line dưới khung chat bằng `Get-HarnessTransferMessage`. Không dùng hộp thông báo, trừ khi có lỗi.
- Có ô tìm kiếm lọc theo tiêu đề và thư mục, thực hiện trên danh sách đã tải.
- Nhấp đúp vào chat bằng với "Continue here".

## 2. Hợp đồng giữa các lane

**Lane V1: `src/Ui.ChatStatus.ps1` (mới).** Toàn bộ là hàm thuần, không WinForms.

```
Get-HarnessChatSyncStatus -Chat -Harness -Catalog -State   -> [pscustomobject]@{ Sync = 'NotOnDrive'|'Synced'|'LocalNewer'|'DriveNewer'|'Diverged'|'NoSync'; Row; FromMachine; CwdMissing = [bool] }
Get-SyncCatalogRowStatus -Row -State -LocalChatLookup      -> 'NotHere'|'UpToDate'|'DriveNewer'|'Diverged'
Get-SuggestedPathRoots -Cwds [string[]]                     -> @( @{ Name; Path } )   (tên chỉ [A-Za-z0-9_-], không trùng gốc đã có)
Get-HarnessChatKey -Harness -Chat                           -> '<harness>:<chatId>'   (khớp chatKey của New-HarnessBundle)
Format-SyncWhen -UnixMs                                     -> '10:42' | 'yesterday' | '3 days' | ngày
```

**Lane V2: `src/Ui.Main.ps1` (mới).** Phần WinForms.

```
Convert-SwitcherToTabs -Form -RefreshClaude
New-HarnessProfilePanel -Harness            (Codex, Antigravity)
New-HarnessChatPanel -Harness -GetProfile   (dùng chung cho 3 tab)
New-SyncDriveTab
Show-SwitcherTab -Harness -ChatId           (để menu và tray mở đúng tab và chat)
```

**Lane V3: hộp thoại.** File `src/Ui.Sync.ps1` và `src/Ui.Harness.ps1`.

```
Show-SyncSetupWizard                (thay Show-SyncSetupDialog)
Show-SyncDivergedDialog -Row -Chat  -> 'handoff'|'push'|'cancel'
Invoke-SyncPull ... -OnDiverged { param($row, $chat) ... }
Show-HarnessMoveDialog -Chat -SourceHarness
```

Lane V3 cũng **xóa** `Show-HarnessExportDialog` sau khi hai menu đã trỏ sang `Show-SwitcherTab`.

## 3. Lane, file sở hữu và thứ tự

| Lane | File sở hữu (ghi) | Phụ thuộc |
|---|---|---|
| **V1** trạng thái + gợi ý | `src/Ui.ChatStatus.ps1` (mới), `tests/HarnessUiStatus.Tests.ps1` (mới) | không |
| **V3** hộp thoại | `src/Ui.Sync.ps1`, `src/Ui.Harness.ps1`, `tests/HarnessSyncUi.Tests.ps1` | V1 (chỉ `Get-SuggestedPathRoots`, theo hợp đồng) |
| **V2** cửa sổ tab | `src/Ui.Main.ps1` (mới), `src/Ui.Tray.ps1`, `ClaudeSwitcher.ps1` (chỉ khối `harness-*`: thêm `harness-ui-main`, sửa `harness-ui-menu` và `harness-ui-tray`), `.github/workflows/lint.yml` (chỉ thêm), `tests/HarnessUiMain.Tests.ps1` (mới) | V1, V3 |

- **Đợt 1, song song:**
  - V1.
  - V3, chạy với `Get-SuggestedPathRoots` giả cho tới khi V1 land.
- **Đợt 2:** V2, cắt nhánh sau khi V1 và V3 đã land.
- **Bước cuối:** nghiệm thu bằng mắt (§5).
- `Harness.Core.ps1` đã chạm trần 500 dòng, nên **không lane nào** được thêm code vào đó.

## 4. Task theo lane

### Lane V1

| # | Việc | Test (viết trước) |
|---|---|---|
| V1a | `Get-HarnessChatSyncStatus` theo bảng §1.2 | Bảng 7 trường hợp: không có catalog (`NoSync`), không có row, `Synced`, `LocalNewer`, `DriveNewer`, `Diverged`, và state thuộc profile khác không được tính. `CwdMissing` đúng với cwd có và không có trên đĩa |
| V1b | `Get-SyncCatalogRowStatus` cho tab Drive | 4 trạng thái. Lookup giả trả chat hoặc `$null` |
| V1c | `Get-SuggestedPathRoots`: nhóm các cwd theo thư mục cha cấp 1 dưới gốc ổ hoặc UNC (`H:\AI_Software\x\y` cho ra `AI_Software = H:\AI_Software`). Bỏ thư mục hệ thống và profile (`C:\Windows`, `C:\Users\<user>` khi đứng một mình). Tên trùng thì thêm hậu tố ổ (`Work_D`). Bỏ gốc đã có | 5 cwd thuộc 2 gốc cho ra 2 gợi ý. Có gốc đã có thì không gợi ý lại. Tên chứa ký tự lạ được làm sạch |
| V1d | `Get-HarnessChatKey` và `Format-SyncWhen` | Khóa của Claude, Codex và Antigravity khớp `chatKey` trong bundle thật mà test tạo bằng `New-HarnessBundle`. Thời điểm hôm nay, hôm qua, vài ngày trước, xa hơn |

Kiểm tra: `tests\HarnessUiStatus.Tests.ps1` và `tests\HarnessSyncStore.Tests.ps1`.

### Lane V3

| # | Việc | Test |
|---|---|---|
| V3a | `Invoke-SyncPull -OnDiverged`: mặc định giữ handoff. `push` thì gọi `Invoke-SyncPush` cho chat local và trả `Status='pushed-mine'`. `cancel` thì không làm gì và trả `Status='cancelled'`. File tạm luôn được xóa | 3 nhánh với adapter giả. Test cũ vẫn pass |
| V3b | `Show-SyncDivergedDialog` (vỏ) và `Resolve-SyncDivergedChoice` (thuần, map nút sang kết quả) | Hàm thuần. Dựng form không gọi `ShowDialog`: kiểm có 3 nút và nút mặc định là handoff |
| V3c | `Show-SyncSetupWizard` 3 bước: một form, 3 panel, nút Back/Next/Finish. Logic bước nằm trong `Get-SyncWizardStep -State` (thuần), trả bước kế tiếp và việc có cho Next hay không | `Get-SyncWizardStep`: bước 1 chưa chọn thì không Next. Folder đã có `sync.json` thì bước 2 chỉ một ô passphrase. Bước 3 Finish gọi `Invoke-SyncSetup` rồi `Set-SyncPathRoot` cho các gốc đã tick (dùng hàm giả) |
| V3d | `Show-HarnessMoveDialog -Chat -SourceHarness`: danh sách đích cùng dòng giải thích lấy từ `Get-HarnessMoveHint` (thuần: native, codex-import hay handoff, kèm câu tiếng Anh) | `Get-HarnessMoveHint` với 4 cặp nguồn và đích |
| V3e | Xóa `Show-HarnessExportDialog` và các hàm chỉ nó dùng, sau khi V2 đã đổi menu. V3 land trước V2 nên V3 **giữ lại** hàm cũ. Việc xóa là commit cuối của V2, theo ngoại lệ có giới hạn: V2 chỉ được xóa đúng hàm đó trong `Ui.Harness.ps1` | Test cũ của hàm này (nếu có) bị xóa cùng |

Kiểm tra: `tests\HarnessSyncUi.Tests.ps1`, `tests\HarnessCodexChats.Tests.ps1` và `tests\HarnessAntigravity.Tests.ps1`.

### Lane V2

| # | Việc | Test (dựng form trong bộ nhớ, **không** gọi `Show`/`ShowDialog`) |
|---|---|---|
| V2a | `Convert-SwitcherToTabs`: chuyển control cũ vào tab Claude, thêm `TabControl` và các tab, tăng kích thước form. Lỗi thì giữ form cũ nguyên vẹn | Form giả có 5 control: sau khi chuyển nằm trong tab Claude, vị trí tương đối và anchor giữ nguyên, form có `TabControl` với 4 tab. Ném lỗi giữa chừng thì form giả giữ đúng 5 control ban đầu |
| V2b | `New-HarnessChatPanel`: ListView có các cột như §1.1. Biểu tượng trạng thái vẽ bằng `System.Drawing` vào `ImageList`, không cần file ảnh. Có ô tìm kiếm, các nút theo §1.7, status line. Dữ liệu lấy từ `ListChats` và V1 | Adapter giả có 3 chat ở 3 trạng thái: cột Drive đúng chữ và đúng khóa ảnh, nút bật hoặc tắt đúng theo trạng thái, ô tìm kiếm lọc đúng |
| V2c | `New-HarnessProfilePanel` cho Codex và Antigravity: danh sách profile cùng các nút, gọi qua adapter (`Launch`, `NewProfile`, `NewShortcut`) | Adapter giả. Nút `Add account` ẩn với Antigravity |
| V2d | `New-SyncDriveTab`: thẻ trạng thái (chưa và đã thiết lập), catalog với bộ lọc "Needs action", bảng folder roots | Catalog giả có 3 row: cột trạng thái đúng. Bộ lọc chỉ giữ `DriveNewer` và `Diverged` |
| V2e | Chấm báo trên nhãn tab Drive, nhớ tab đang mở (`Ui.LastTab`), `Show-SwitcherTab` | Hàm `Get-DriveTabBadge` (thuần). Đặt và đọc lại `Ui.LastTab` qua settings giả |
| V2f | Hook: thêm `harness-ui-main`, đổi `harness-ui-menu` và `harness-ui-tray` sang "Chats and Drive..." (`Show-SwitcherTab`). `Ui.Tray.ps1`: "Sync: Push..." và "Sync: Pull..." mở tab Drive | Test ngân sách hook không quá 30 dòng code. Parse ổn. `BuildSingleFile` pass |
| V2g | Ảnh để duyệt: script `tools/Render-UiPreview.ps1` dựng form với adapter và catalog giả, rồi `DrawToBitmap` ra PNG trong `%TEMP%` (4 tab và 3 hộp thoại), không hiện cửa sổ | Script chạy không lỗi. Lane gửi đường dẫn các PNG kèm báo cáo |
| V2h | Xóa `Show-HarnessExportDialog` (V3e) và thêm `lint.yml` cho 2 file test mới | Diff `lint.yml` chỉ có dòng `+` |

Detect trên UI thread (mục hoãn từ GĐ4): V2 gọi `Detect` một lần lúc dựng tab và cache lại. Chỉ gọi lại khi bấm Refresh.

Kiểm tra: `tests\HarnessUiMain.Tests.ps1`, `tests\HarnessUiStatus.Tests.ps1`, `tests\HarnessSyncUi.Tests.ps1`, `tests\BuildSingleFile.Tests.ps1` và `tests\HarnessCodexProfiles.Tests.ps1`.

## 5. Nghiệm thu (USER ACTION)

| # | User làm gì |
|---|---|
| UV1 | Mở switcher. Có 4 tab. Tab Claude giữ đúng giao diện cũ ở nửa trên, nửa dưới là danh sách chat của profile đang chọn |
| UV2 | Tab Drive, khi chưa thiết lập: bấm `Set up Drive sync...` và đi qua 3 bước với thư mục thử `HarnessSync-test`. Tick các gốc thư mục được gợi ý |
| UV3 | Push một chat từ mỗi tab Claude, Codex, Antigravity. Cột Drive chuyển sang "On Drive" |
| UV4 | Máy thứ hai: tab Drive liệt kê 3 chat là "Not here". `Pull to...` từng chat. Chat Claude thiếu gốc thì được hỏi thư mục |
| UV5 | Tiếp tục cùng một chat trên hai máy. Máy B hiện "Changed on both" cùng chấm báo trên tab Drive. Pull mở hộp chọn, và cả hai lựa chọn chạy đúng |
| UV6 | Đổi tên thư mục dự án của một chat. Cột Folder hiện biểu tượng thiếu thư mục, và `Choose folder...` sửa được |

## 6. Tiêu chí hoàn thành

- Mọi lane đều có `LAND OK`, và gate của orchestra xanh.
- Không còn đường nào trong menu hoặc tray mở `Show-HarnessExportDialog`.
- Cửa sổ cũ vẫn chạy khi không có `src\Ui.Main.ps1` (test V2a).
- UV1 đến UV6 đạt trên máy thật.
