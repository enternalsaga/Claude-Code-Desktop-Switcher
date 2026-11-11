# Plan GĐ4: đồng bộ chat qua Google Drive

- Base: `6244d7f` trên `desktop-4.29-patches`.
- Spec: `docs/specs/261111-1200-multi-harness-manager-and-drive-sync-spec.md`, các mục §4, §7, §8, Q5, Q7, Q8.
- Bao gồm các mục "Hoãn sang GĐ4" của `docs/plans/261111-1742-milestone-review-fixes.md`. Từ giai đoạn này, bundle có thể đến từ một máy khác.
- Người viết và người duyệt: `switcher-think-multiharness`. Người land: orchestra. Lane gửi `SẴN SÀNG CHUYẾN` cho người duyệt.

## 0. Quy tắc chung cho mọi lane

- **TDD.** Mỗi task viết test trước và thấy test đó fail, rồi mới sửa. Mỗi lỗi bảo mật phải có một test tái hiện.
- **Kiểm tra nhẹ của lane:**
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\<file>.Tests.ps1` cho từng file test mà lane chạm.
  - Kiểm parse cho các file đã sửa.
  - Quét secret trên phần đã stage.
  - Không chạy full suite; gate là việc của orchestra.
- **Không đụng dữ liệu thật.**
  - Test chỉ dùng thư mục tạm dưới `%TEMP%`, gồm "ổ Drive giả", registry giả qua hook và profile giả.
  - Spike chỉ ghi vào `<My Drive>\HarnessSync-test\` hoặc vào `%TEMP%`. Không bao giờ ghi vào `HarnessSync\`, `~\.claude`, `~\.codex` hay `~\.gemini` thật.
  - Không mở UI và không chạy `ClaudeSwitcher.ps1` trên desktop của user. Hộp thoại được test qua hàm thuần và hook.
- **Không hardcode thông tin cá nhân.**
  - Không hardcode ổ Drive, email hay account token, kể cả trong test, spike, fixture hay repo.
  - Spike nhận `-DriveRoot` hoặc `-AccountToken` làm tham số.
- **Mã nguồn:** chỉ ASCII. Mỗi file `src` không quá 500 dòng. Mỗi hàm không quá 100 dòng.
- **Ngoài phạm vi GĐ4, để GĐ5:**
  - Profile Claude không phải Default với bộ nhập của Codex.
  - JSON-RPC bỏ qua dòng hỏng.
  - Tray chạy `Detect` trên UI thread.
  - Đăng nhập Codex bằng keyring.
  - Protobuf nhận nhầm tag in được là text.
  - Đồng bộ nền theo lịch (Q10).

## 1. Quyết định của plan (mặc định, orchestra có thể đổi)

| # | Quyết định | Lý do |
|---|---|---|
| D1 | Mã hóa luôn bật ở v1, không có công tắc tắt | Q5 đã chốt bật mặc định. Một công tắc tắt mở thêm một đường lộ secret mà chưa ai cần (YAGNI) |
| D2 | DPAPI cache **khóa dẫn xuất** (64 byte, gắn với `salt` của `sync.json`) thay vì passphrase thô | Độ nhạy tương đương, vì cả hai đều chỉ nằm trên máy này. Bù lại, không phải chạy lại PBKDF2 600k vòng mỗi lần Push/Pull. Đổi salt thì cache tự mất hiệu lực |
| D3 | Tiêu đề trong `index/*.jsonl` được mã hóa (`titleEnc`). Index chỉ để trần các trường kỹ thuật | Index đọc được khi không có passphrase. Một tiêu đề chat có thể lộ thông tin |
| D4 | Chat phân kỳ (Q7) được nhập thành **chat mới bằng handoff** cho cả 3 harness. Bản native trên máy giữ nguyên | Nhập native thành bản sao mới đòi hỏi đổi id bên trong file gốc (local json, `session_meta` của rollout, `.db` của Antigravity). Chưa có spike nào chứng minh làm vậy an toàn. Handoff đã tạo đúng một "bản sao mới" và không ghi đè gì |
| D5 | Native khác máy: Claude ánh xạ cwd và viết lại cwd. Codex và Antigravity chép native nguyên bản, chỉ cảnh báo khi cwd nguồn không tồn tại trên máy này | Spec §7.4 bắt buộc ánh xạ cho Claude. Rollout và `.db` mang cwd ở bên trong file, và sửa nó cần spike S12 |
| D6 | Giới hạn: xuất tối đa 512 MiB mỗi bundle. Khi đọc: tối đa 1 GiB dữ liệu đã giải nén, 20.000 mục, `manifest.json` ≤ 1 MiB, tỉ lệ nén mỗi mục ≤ 200:1 | Chặn zip bomb và thư mục lớn bất thường. Là hằng số, không cấu hình được |
| D7 | Hậu tố tiêu đề khi phân kỳ là ` (from <machineName>)` | Chuỗi UI của app là tiếng Anh. Spec viết ` (từ <máy>)` |
| D8 | `index/<machineId>.jsonl` được ghi lại toàn bộ qua file tmp rồi rename, không nối thêm dòng | Nối dòng trên DriveFS không nguyên tử. Mỗi file chỉ có một máy ghi, nên ghi lại cả file vẫn an toàn |

## 2. Hợp đồng giữa các lane

Các lane viết theo đúng chữ ký dưới đây. Lane đến sau gọi hàm của lane trước bằng tên, không chép code của nhau.

**Lane D: `src/Harness.Sync.Config.ps1`**

```
Get-DriveFsAccounts                 -> @( [pscustomobject]@{ Token; MountPoint; Label; MyDrive } )
Resolve-SyncRoot                    -> [pscustomobject]@{ Path; Source = 'drive'|'custom'; Reason }
                                       Path = $null khi không tìm thấy; Reason = 'no-settings'|'token-not-mounted'|'custom-missing'
Get-SyncMachine                     -> [pscustomobject]@{ Id; Name }        (Id là GUID sinh một lần, lưu trong settings)
Get-SyncPathRoots / Set-SyncPathRoot -Name -Path
Get-SyncSetting / Set-SyncSetting   bọc Get-Setting và Set-Setting; khóa 'Sync.*'
```

**Lane K: `src/Harness.Sync.Crypto.ps1`**

```
New-SyncKdf                         -> @{ salt = <base64 32B>; iterations = 600000; keyCheck = <hex> }   (cần passphrase)
Get-SyncKey -Passphrase -Kdf        -> byte[64]  (32 byte khóa AES | 32 byte khóa HMAC); throw 'wrong-passphrase' khi keyCheck lệch
Save-SyncKeyCache -Key -Kdf / Get-SyncKeyCache -Kdf -> byte[64] hoặc $null   (DPAPI CurrentUser, entropy = salt)
Protect-SyncFile -In -Out -Key / Unprotect-SyncFile -In -Out -Key            (throw 'mac-mismatch')
Protect-SyncString / Unprotect-SyncString                                    (dùng cho titleEnc)
```

**Lane S: `src/Harness.Sync.Store.ps1`**

```
Initialize-SyncFolder -Root -Passphrase       -> kdf          (máy đầu tiên tạo sync.json; máy sau đọc nó)
Push-SyncBundle -Root -BundlePath -Key -Chat  -> index row
Get-SyncCatalog -Root -Key                    -> các row đã gộp theo chatKey (mới nhất), kèm MachineName
Receive-SyncBundle -Root -Row -Key            -> đường dẫn zip đã giải mã trong %TEMP% (người gọi tự xóa)
Remove-SyncOldBundles -Root -Keep 3           -> chỉ xóa bundle của máy mình
Get-SyncDivergence -Row -LocalChat            -> 'new' | 'update' | 'same' | 'diverged'
Set-SyncState / Get-SyncState                 (.switcher\sync-state.json, chỉ trên máy này)
```

**Lane H1: `src/Harness.Core.ps1`**

```
Get-HarnessMachineInfo / Get-HarnessPathRoots
    gọi Get-SyncMachine / Get-SyncPathRoots nếu hai hàm đó tồn tại; nếu không trả giá trị rỗng
New-HarnessBundle
    tự điền source.machineId và source.machineName khi rỗng
ConvertTo-CwdRef
    dùng Get-HarnessPathRoots khi PathRoots rỗng
```

Vì vậy, adapter không phải đổi chữ ký `Export $Chat $OutPath`.

**Lane U: `src/Ui.Harness.ps1`**

Tách `Invoke-HarnessTransfer` thành hai bước, và `Invoke-HarnessTransfer` cũ gọi lại hai hàm này nên hành vi giữ nguyên:

```
Export-HarnessChatBundle -Chat -SourceHarness -BundleDir -> bundle path + manifest
Invoke-HarnessImport -BundlePath -Manifest -Target       -> giống kết quả của Invoke-HarnessTransfer
```

## 3. Lane, file sở hữu và thứ tự

| Lane | Phiên đề xuất | File sở hữu (ghi) | Phụ thuộc |
|---|---|---|---|
| **SP** spike | work (Sonnet) | `tools/spikes/S9-*.ps1` … `S13-*.ps1`, `docs/specs/261111-1200-multi-harness-spike-results.md` (chỉ thêm mục mới) | không |
| **H1** lõi | work | `src/Harness.Core.ps1`, `src/Harness.Sqlite.ps1`, `tests/HarnessCore.Tests.ps1`, `tests/HarnessBundle.Tests.ps1` | không |
| **K** mã hóa | work | `src/Harness.Sync.Crypto.ps1` (mới), `tests/HarnessSyncCrypto.Tests.ps1` (mới) | không |
| **D** dò Drive + settings | work | `src/Harness.Sync.Config.ps1` (mới), `tests/HarnessSyncConfig.Tests.ps1` (mới) | không |
| **C** Claude khác máy | work | `src/Harness.Claude.ps1`, `tests/HarnessClaude.Tests.ps1` | H1 (hợp đồng `Resolve-CwdRef`); kết quả S11 |
| **A** Antigravity xuất | work | `src/Harness.Antigravity.Chats.ps1`, `tests/HarnessAntigravity.Tests.ps1` | không |
| **S** kho trên Drive | work | `src/Harness.Sync.Store.ps1` (mới), `tests/HarnessSyncStore.Tests.ps1` (mới) | K, D (theo hợp đồng); kết quả S10 |
| **U** UI + CLI | work | `src/Ui.Sync.ps1` (mới), `src/Ui.Harness.ps1`, `src/Ui.Tray.ps1`, `ClaudeSwitcher.ps1` (chỉ khối `harness-*`, gồm hai khối mới), `.github/workflows/lint.yml`, `tests/HarnessSyncUi.Tests.ps1` (mới) | S, C, H1 |

- **Đợt 1, song song:** SP, H1, K, D, A. Không có hai lane nào ghi cùng một file.
- **Đợt 2:**
  - C bắt đầu khi H1 đã land.
  - S bắt đầu khi K và D đã land, hoặc chạy song song với hàm giả theo hợp đồng §2 rồi cherry-pick lên tip sau khi K và D land.
- **Đợt 3:** U bắt đầu khi S, C và H1 đã land.
- **Bước cuối:** nghiệm thu với USER ACTION (§5).
- **`lint.yml`:** chỉ lane U được sửa. U thêm bước PS 5.1 và PS 7 cho mọi file test mới (Crypto, Config, Store, Ui), theo kiểu chỉ thêm, không sửa dòng có sẵn.

## 4. Task theo lane

### Lane SP: spike (chỉ đọc hoặc chỉ ghi vào thư mục thử)

Mỗi spike ghi kết quả đạt hoặc không đạt vào spike-results, kèm số đo. Không có thông tin cá nhân. Đường dẫn được rút gọn thành `<My Drive>`.

| Spike | Câu hỏi | Cách thử | Đạt khi | Ảnh hưởng nếu không đạt |
|---|---|---|---|---|
| S9 (**USER ACTION**, máy thứ hai) | Account token trong `PerAccountPreferences` có giống nhau giữa hai máy không? | Script `S9-DriveAccounts.ps1` in danh sách token kèm nhãn volume đã che email (chỉ giữ 3 ký tự đầu). User chạy script trên cả hai máy rồi so | Cùng account cho ra cùng token | Lane D giữ phương án dự phòng: hộp chọn ổ một lần trên máy mới. Hợp đồng không đổi |
| S10 | Trên DriveFS: (a) ghi tmp rồi rename có nguyên tử với bên đọc trên cùng máy không; (b) mở file khi đang tải có bị khóa hay trả về dữ liệu dở không; (c) với file 50 MB, thời gian chép về `%TEMP%` và sha có khớp không; (d) ghi trùng tên thì có sinh `name (1).ext` không | `S10-DriveFsSemantics.ps1 -DriveRoot <My Drive>`, chỉ ghi dưới `HarnessSync-test\s10\`, xóa sạch khi xong | (a) bên đọc không bao giờ thấy file dở; (c) sha khớp | Lane S thêm bước thử lại có thời hạn và kiểm sha sau khi chép |
| S11 (**USER ACTION**, nhìn) | Chat Claude được nhập với cwd đã ánh xạ sang thư mục khác (jsonl đặt dưới slug mới, cwd trong local json đã viết lại) có hiện và mở tiếp được trong Claude Desktop không? Các trường `cwd` bên trong từng dòng jsonl có phải viết lại không? | `S11-ClaudeCwdRemap.ps1` dựng profile Claude thử và một thư mục dự án giả có bản chép. User mở profile thử để xem | Chat hiện ra và resume được, với hoặc không với việc viết lại cwd trong jsonl | Lane C dừng ở mức "chép native, cảnh báo cwd". UI thêm lựa chọn handoff |
| S12 | `thread/read` trên rollout có cwd không tồn tại có đăng ký được dòng `threads` không, và cột `cwd` khi đó nhận giá trị gì? | Profile Codex `spike*` trong thư mục tạm và rollout tổng hợp (S8) | Dòng được đăng ký | Codex khác máy rơi về handoff khi cwd nguồn không có trên máy |
| S13 | Snapshot SQLite nhất quán: `VACUUM INTO` từ kết nối chỉ đọc (winsqlite3, PS 5.1) trên một DB WAL đang được ghi | Script ghi liên tục vào DB thử trong `%TEMP%`, song song chụp 50 lần, `PRAGMA integrity_check` từng bản | 50/50 bản `ok` | H1 dùng `sqlite3_backup_*` thay thế |

### Lane H1: lõi cứng hóa (mục hoãn)

| # | Việc | Test tái hiện (viết trước) |
|---|---|---|
| H1a | `Read-HarnessBundle`: áp giới hạn D6, đọc từng mục qua stream kèm bộ đếm byte (không tin `Length` trong header), không đọc cả bundle vào RAM. Ghi từng mục ra `<ExtractTo>`, tính sha trong lúc chép, chỉ đưa vào chỗ cuối khi mọi mục hợp lệ (giải nén vào `<ExtractTo>.part` rồi rename) | Zip bomb (1 mục 10 MB toàn số 0 khai báo hợp lệ nhưng vượt tỉ lệ) → throw `bundle-limit`. 20.001 mục → throw. Manifest 2 MiB → throw. Mọi trường hợp throw đều không để lại file trong `ExtractTo` |
| H1b | `New-HarnessBundle`: ghi `<OutPath>.tmp` rồi `Move-Item` sang `<OutPath>`. Lỗi giữa chừng thì xóa tmp. Tổng kích thước > 512 MiB thì throw `bundle-too-large` trước khi ghi | Giả lỗi ở mục thứ hai (SourcePath không tồn tại) → không có `OutPath`, không còn tmp. File lớn giả (dùng hook `MaxBytes` trong test) → throw |
| H1c | `Resolve-CwdRef`: từ chối `relative` chứa segment `..`, đường dẫn tuyệt đối, ký tự điều khiển hoặc `:`. `absolute` phải là đường dẫn tuyệt đối không chứa ký tự điều khiển; nếu không trả `$null` | `relative='..\..\Windows'`, `'a\..\..\b'`, `'C:\x'`, `"a`nb"`, `absolute='rel\path'` → `$null` |
| H1d | `Copy-SqliteSnapshot`: dùng `VACUUM INTO` (hoặc backup API theo S13) vào thư mục tạm. Lỗi thì quay về cách chép cũ và ghi log. Giữ chữ ký cũ | DB WAL đang mở ghi trong test → snapshot qua được `integrity_check` và thấy dòng đã commit nằm trong WAL |
| H1e | `Get-HarnessMachineInfo`, `Get-HarnessPathRoots`, điền `machineId` trong `New-HarnessBundle`, `ConvertTo-CwdRef` dùng roots mặc định (hợp đồng §2) | Không có hàm Sync: giá trị rỗng như hiện nay. Có hàm giả: manifest mang `machineId` và `cwd.root` |

Kiểm tra: `tests\HarnessCore.Tests.ps1` và `tests\HarnessBundle.Tests.ps1`. Thêm kiểm `tests\HarnessCodexChats.Tests.ps1` và `tests\HarnessAntigravity.Tests.ps1`, vì hai file này dùng `Copy-SqliteSnapshot` và `Read-HarnessBundle`.

### Lane K: mã hóa

| # | Việc | Test |
|---|---|---|
| K1 | PBKDF2-SHA256 600.000 vòng qua `Rfc2898DeriveBytes(byte[], byte[], int, HashAlgorithmName)`. Không có overload này (.NET < 4.7.2) thì throw rõ ràng. `keyCheck = HMAC-SHA256(macKey, 'harness-sync-keycheck-v1')` | Vector cố định với 1.000 vòng (tham số `-Iterations` chỉ dùng trong test) khớp giá trị tính trước. Sai passphrase → `wrong-passphrase`. Đo thời gian 600k vòng và ghi vào báo cáo |
| K2 | Định dạng file `.enc`: `magic 'HSE1'`, `ver=1`, `iv` 16 byte, ciphertext AES-256-CBC PKCS7, `mac` 32 byte = HMAC-SHA256 trên mọi byte đứng trước. Mã hóa và giải mã theo stream, không đọc cả file vào RAM. Kiểm mac (lượt 1) xong mới giải mã (lượt 2) | Round-trip với 0 byte, 1 byte, 5 MB. Lật một bit ở iv, ciphertext, mac hoặc magic → `mac-mismatch`, không ghi `Out`. File cụt → `mac-mismatch` |
| K3 | DPAPI cache theo D2, đặt ở `.switcher\sync-key.bin`, entropy = salt. Salt khác thì trả `$null` | Round-trip; salt khác → `$null`; file hỏng → `$null` |
| K4 | `Protect-SyncString` / `Unprotect-SyncString`: base64 của định dạng K2, dùng cho `titleEnc` | Round-trip chuỗi Unicode; chuỗi bị sửa → throw |

Kiểm tra: `tests\HarnessSyncCrypto.Tests.ps1` chạy trên PS 5.1. PS 7 chạy ở CI, hiện chưa chạy được. Lane ghi rõ trong báo cáo nếu `ProtectedData` cần `Add-Type -AssemblyName System.Security`.

### Lane D: dò Drive + settings

| # | Việc | Test |
|---|---|---|
| D1 | `Get-DriveFsAccounts` đọc `HKCU:\Software\Google\DriveFS\PerAccountPreferences` (JSON trong value `value`, theo cấu trúc mà spike S9 xác nhận) và nhãn volume qua `[IO.DriveInfo]`. `MyDrive = <mount>\My Drive`. Tìm thư mục tên `My Drive` hoặc `Drive của tôi` theo ngôn ngữ, chưa có thì lấy thư mục con đầu tiên có thư mục `.shortcut-targets-by-id` bên cạnh; bước này S9 xác nhận | Registry giả qua hook `$script:SyncHooks.ReadRegistry`. Hai account → hai dòng. Không có key → mảng rỗng |
| D2 | `Resolve-SyncRoot`: ưu tiên `Sync.CustomPath`, sau đó `Sync.DriveAccountToken` + `Sync.Folder` (mặc định `HarnessSync`). Không tìm thấy thì trả `Path=$null` kèm `Reason` | Bốn trường hợp: custom có thư mục, custom mất thư mục, token có mount, token không mount |
| D3 | `Get-SyncMachine`: GUID trong `Sync.MachineId`, sinh một lần. `Name = $env:COMPUTERNAME` | Gọi hai lần → cùng Id |
| D4 | `Get-SyncPathRoots` / `Set-SyncPathRoot`: tên gốc chỉ gồm `[A-Za-z0-9_-]`, đường dẫn phải tuyệt đối | Tên xấu và đường dẫn tương đối → throw |

`Sync.Folder` dùng trong test và spike là `HarnessSync-test`. Kiểm tra: `tests\HarnessSyncConfig.Tests.ps1`. Settings giả ghi vào file trong `%TEMP%` qua `$script:SettingsPath`.

### Lane C: Claude native giữa hai máy

| # | Việc | Test |
|---|---|---|
| C1 | `Import-ClaudeNative` nhận `-PathRoots`, mặc định là `Get-HarnessPathRoots`. Khi `source.machineId` khác máy này:<br>- cwd lấy từ `Resolve-CwdRef`.<br>- `$null` vì chưa biết gốc → trả `@{ Status='needs-root'; Root=<tên> }` và không ghi gì.<br>- Có cwd → jsonl và thư mục `<cli>\` đặt dưới `Find-ClaudeProjectDir` của cwd mới. Các trường `cwd`, `originCwd`, `workingDirectory` trong local json được viết lại bằng `Set-JsonTopLevelString`. Viết lại cwd trong jsonl hay không thì theo S11. | Bundle giả với `machineId` khác và `cwd.root='Proj'`:<br>- roots không có `Proj` → `needs-root`, không có file nào.<br>- roots có `Proj` → jsonl nằm dưới slug của đường dẫn mới, local json mang cwd mới. |
| C2 | Cập nhật khác máy: bản bundle mới hơn (theo cùng quy tắc với `Copy-CodeSession`) thì thay cả jsonl, sau khi đổi tên bản cũ thành `.bak-<ts>`. Bản cũ hơn thì giữ nguyên | jsonl cũ hơn → bị thay và có `.bak`. jsonl mới hơn → giữ nguyên |
| C3 | Giới hạn khi xuất: `Get-ClaudeNativeFiles` bỏ qua reparse point (junction, symlink) trong `<cli>\`. Tổng vượt 512 MiB thì để `New-HarnessBundle` (H1b) throw | Thư mục `<cli>\` có junction trỏ ra ngoài → không có file nào từ junction trong bundle |
| C4 | Cảnh báo khi thư mục cwd đích không tồn tại: vẫn nhập, kết quả mang `CwdMissing=$true` | Kiểm cờ trong kết quả |

Kiểm tra: `tests\HarnessClaude.Tests.ps1` và `tests\ChatTransfer.Tests.ps1`. Cái sau để chắc rằng `Copy-CodeSession` không đổi.

### Lane A: Antigravity xuất

| # | Việc | Test |
|---|---|---|
| A1 | `Get-AgyBrainFiles` bỏ qua reparse point. `brain\<id>` có junction thì không theo vào | Có junction trong `brain\<id>` → bundle không chứa file nào từ junction |
| A2 | `stepCount` và transcript lấy từ cùng một nguồn: ưu tiên `transcript.jsonl`, không có thì giải mã `.db`. Manifest ghi `source.antigravity.transcriptSource` | Có jsonl: `stepCount` bằng số dòng đã chuẩn hóa. Chỉ có `.db`: `stepCount` lấy từ `.db` |

Kiểm tra: `tests\HarnessAntigravity.Tests.ps1`.

### Lane S: kho trên Drive

| # | Việc | Test (dùng một "Drive" giả là thư mục trong `%TEMP%`) |
|---|---|---|
| S1 | `Initialize-SyncFolder`:<br>- Chưa có `sync.json` thì tạo `{format:'harness-sync', version:1, kdf}` qua tmp rồi rename.<br>- Đã có thì đọc kdf và kiểm passphrase.<br>- Có `sync (1).json` với salt khác thì throw `sync-conflict`, kèm hướng dẫn | Lần đầu → tạo file. Lần hai với passphrase sai → `wrong-passphrase`. Có file xung đột → `sync-conflict` |
| S2 | `Write-SyncFileAtomic`: ghi `<name>.tmp-<guid>` cùng thư mục, `Move-Item`, rồi đọc lại và so sha. Bên đọc bỏ qua `*.tmp-*` và `* (n).*` | File tmp còn sót không xuất hiện trong catalog |
| S3 | `Push-SyncBundle`:<br>- Mã hóa bundle vào `bundles/<harness>/<chatKeySafe>/<bundleId>.hbundle.zip.enc`. `chatKeySafe` thay `:` bằng `_` và chỉ gồm `[A-Za-z0-9_.-]`.<br>- Thêm row `{bundleId, chatKey, previousBundleId, contentSha256, harness, titleEnc, lastActivityAt, path, size, sha256, machineId, pushedAt}` vào `index/<machineId>.jsonl` theo D8.<br>- Ghi `machines/<machineId>.json` gồm `name`, `lastSeen`, `harnesses`, `pathRoots`.<br>- `previousBundleId` lấy từ sync-state | Push hai lần cùng một chat → hai row, row sau trỏ `previousBundleId` về row trước. Index không chứa tiêu đề trần (grep) |
| S4 | `Get-SyncCatalog`:<br>- Đọc mọi `index/*.jsonl`, bỏ dòng hỏng và ghi log.<br>- `path` phải nằm dưới `bundles/` sau `GetFullPath`, `bundleId` phải là UUID.<br>- Gộp theo `chatKey`, lấy `lastActivityAt` lớn nhất, giải mã `titleEnc`, gắn `MachineName` từ `machines/` | Hai máy giả, ba chat → đúng ba mục mới nhất. Row có `path='../../x'` → bị bỏ. Dòng JSON hỏng → bị bỏ |
| S5 | `Receive-SyncBundle`:<br>- Chép file `.enc` về `%TEMP%` (thử lại có hạn theo S10).<br>- So sha với row, `Unprotect-SyncFile` ra zip tạm, rồi trả đường dẫn.<br>- File mất thì throw `bundle-missing` | sha lệch → throw, không có zip. mac lệch → throw |
| S6 | `Get-SyncDivergence`, theo D4 và sync-state:<br>- Không có chat local → `new`.<br>- `row.bundleId` bằng `state.lastBundleId` → `same`.<br>- Chat local không đổi kể từ lần sync trước (`localActivity <= state.localActivityAtSync`) → `update`.<br>- Có chat local nhưng không có state, hoặc chat local đã đổi kể từ lần sync trước → `diverged` | Bảng 5 trường hợp |
| S7 | `Remove-SyncOldBundles`: chỉ xử lý row của máy mình, giữ 3 bản mới nhất mỗi `chatKey`. Ghi index mới trước rồi mới xóa file | Năm bản của máy A và hai bản của máy B → A còn 3, B không đổi. Index của A không còn trỏ tới file đã xóa |
| S8 | Sync-state ở `.switcher\sync-state.json`: `{chatKey: {lastBundleId, localChatId, harness, profileId, localActivityAtSync}}`. Cập nhật sau mỗi lần Push và Pull thành công | Round-trip; file hỏng → trạng thái rỗng kèm cảnh báo |

Kiểm tra: `tests\HarnessSyncStore.Tests.ps1` và `tests\HarnessSyncCrypto.Tests.ps1`.

### Lane U: UI, tray, CLI

| # | Việc | Test (hàm thuần và hook, không mở form) |
|---|---|---|
| U1 | Tách `Invoke-HarnessTransfer` thành `Export-HarnessChatBundle` và `Invoke-HarnessImport` (hợp đồng §2). Hành vi cũ giữ nguyên | Test cũ trong `HarnessCodexChats.Tests.ps1` và `HarnessAntigravity.Tests.ps1` vẫn pass, không sửa test |
| U2 | `Invoke-SyncPush -Chat -SourceHarness`: export → `Push-SyncBundle` → cập nhật state → `Remove-SyncOldBundles` | Drive giả: một bundle `.enc` và một row |
| U3 | `Invoke-SyncPull -Row -Target`:<br>- Gọi `Receive-SyncBundle` rồi `Get-SyncDivergence`.<br>- `new` hoặc `update` → `Invoke-HarnessImport`, với native theo D5.<br>- `diverged` → `ImportHandoff`, tiêu đề có hậu tố D7.<br>- `needs-root` → trả trạng thái để UI hỏi thư mục, gọi `Set-SyncPathRoot`, rồi thử lại.<br>- Luôn xóa file tạm | Đủ 4 nhánh với adapter giả |
| U4 | Bật sync lần đầu (`Show-SyncSetupDialog`):<br>- Chọn Drive theo nhãn từ `Get-DriveFsAccounts`, hoặc chọn thư mục tùy ý.<br>- Passphrase nhập hai lần. Nhãn cảnh báo: "Losing the passphrase means losing the bundles on Drive (the chats on this machine are kept)." Ô tick bắt buộc.<br>- Máy sau chỉ hỏi passphrase một lần rồi cache theo D2.<br>- Logic tách ra hàm `Test-SyncSetupInput`, dialog chỉ là vỏ | `Test-SyncSetupInput`: hai passphrase lệch, ngắn hơn 12 ký tự, chưa tick → lỗi. Hợp lệ → ok |
| U5 | Dialog Transfer: thêm đích "Google Drive" (Push) và nguồn "Google Drive" (Pull, danh sách từ `Get-SyncCatalog` kèm tên máy và thời gian). Thông báo cho các trạng thái mới (`needs-root`, `diverged`, `bundle-missing`, `sync-conflict`) | `Get-HarnessTransferMessage` cho từng trạng thái mới |
| U6 | Tray: thêm `Sync: Push...` và `Sync: Pull...` trong `Add-HarnessTrayItems`. Chỉ hiện khi đã thiết lập sync, nếu chưa thì hiện `Set up Drive sync...` | Hàm chọn mục tray trả đúng danh sách theo trạng thái thiết lập |
| U7 | CLI:<br>- Khối mới `# >>> harness-params` ở **cuối** param block, mỗi dòng bắt đầu bằng dấu phẩy: `, [string]$SyncPush, [string]$SyncPull, [string]$SyncTarget`. Không sửa dòng `$OpenLinksIn` có sẵn.<br>- Khối `# >>> harness-cli` ngay trước khối `if ($Launch)` gọi `Invoke-SyncCli`.<br>- `-SyncPush <harness>:<profile>:<chatId>`, `-SyncPull <chatKey|bundleId> [-SyncTarget <harness>:<profile>]`.<br>- Không có key trong DPAPI cache thì báo lỗi "open the switcher once to set up sync", không hỏi passphrase trong console | Parse ổn. `ClaudeSwitcher.ps1 Work` vẫn bind vào `-Launch` (test vị trí). `Test-HandleLinkAlone` vẫn từ chối khi đi kèm `-SyncPush`. Ngân sách hook ≤ 30 dòng, test BuildSingleFile pass |
| U8 | `lint.yml`: thêm bước PS 5.1 và PS 7 cho `HarnessSyncCrypto`, `HarnessSyncConfig`, `HarnessSyncStore`, `HarnessSyncUi`. Chỉ thêm | Diff của `lint.yml` chỉ có dòng `+` |

Kiểm tra: `tests\HarnessSyncUi.Tests.ps1`, `tests\HarnessCodexChats.Tests.ps1`, `tests\HarnessAntigravity.Tests.ps1`, `tests\BuildSingleFile.Tests.ps1` và `tests\HarnessCore.Tests.ps1`.

## 5. USER ACTION

| # | Khi nào | User làm gì |
|---|---|---|
| UA1 | Lane SP, S9 | Chạy `tools\spikes\S9-DriveAccounts.ps1` trên **máy thứ hai** rồi gửi lại danh sách token. Danh sách đã che email |
| UA2 | Lane SP, S11 | Mở profile Claude thử do spike dựng, xem chat đã ánh xạ cwd có hiện và mở tiếp được không, rồi đóng app |
| UA3 | Nghiệm thu, máy này, sau khi U land | Bật sync lần đầu: chọn ổ Drive của account đã chọn (hộp chọn theo nhãn), đặt passphrase và tick cảnh báo. Thư mục nghiệm thu là `HarnessSync-test` (đặt `Sync.Folder`). Push một chat Claude, một chat Codex và một chat Antigravity |
| UA4 | Nghiệm thu, máy thứ hai | Cài switcher, bật sync với cùng account và nhập passphrase. Pull ba chat ở UA3. Claude: chọn thư mục gốc khi được hỏi (`needs-root`). Kiểm từng chat mở tiếp được |
| UA5 | Nghiệm thu phân kỳ | Tiếp tục cùng một chat trên cả hai máy, Push từ máy A, rồi Pull trên máy B → chat mới có ` (from <máy A>)`, và chat cũ trên B còn nguyên |
| UA6 | Sau nghiệm thu | Xác nhận xóa `HarnessSync-test`, rồi đặt `Sync.Folder` về `HarnessSync` cho dùng thật |

## 6. Tiêu chí hoàn thành GĐ4

- Mọi lane đều có `LAND OK`, và gate đầy đủ của orchestra xanh.
- Trên Drive, mỗi file chỉ có một máy ghi. Bundle và tiêu đề đều mã hóa. Index không chứa tiêu đề trần.
- Mọi đầu vào đến từ Drive đều được kiểm trước khi dùng: zip, manifest, index row, `cwdRef`, id.
- UA3, UA4 và UA5 đạt.
- Repo không chứa email, token, ổ Drive hay đường dẫn cá nhân.
