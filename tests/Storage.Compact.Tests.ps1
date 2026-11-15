$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_TestHelper.ps1')
$root = Split-Path $PSScriptRoot -Parent
. (Import-TestFunctions -Files @((Join-Path $root 'ClaudeSwitcher.ps1')) -Names @('Get-Setting', 'Set-Setting', 'Set-JsonTopLevelString'))
. (Join-Path $root 'src\Harness.Core.ps1')
. (Join-Path $root 'src\Harness.Sqlite.ps1')
. (Join-Path $root 'src\Harness.Claude.ps1')
. (Join-Path $root 'src\Harness.Codex.Chats.ps1')
. (Join-Path $root 'src\Harness.Sync.Crypto.ps1')
. (Join-Path $root 'src\Harness.Sync.Config.ps1')
. (Join-Path $root 'src\Harness.Sync.Store.ps1')
. (Join-Path $root 'src\Storage.Scan.ps1')
. (Join-Path $root 'src\Storage.Inventory.ps1')
. (Join-Path $root 'src\Storage.DriveArchive.ps1')
. (Join-Path $root 'src\Storage.Guard.ps1')
. (Join-Path $root 'src\Storage.Archive.ps1')
. (Join-Path $root 'src\Storage.Harness.ps1')
. (Join-Path $root 'src\Storage.Compact.ps1')

# Fake files under %TEMP%\storage-compact-* only. No real session, profile or store is read or changed.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('storage-compact-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-Bytes($path, [byte[]]$b) { New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null; [IO.File]::WriteAllBytes($path, $b) }
function Get-Lines([byte[]]$b) {   # raw lines as byte arrays, terminators included
    $out = New-Object Collections.Generic.List[object]; $start = 0
    for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -eq 10) { $out.Add([byte[]]($b[$start..$i])); $start = $i + 1 } }
    if ($start -lt $b.Length) { $out.Add([byte[]]($b[$start..($b.Length - 1)])) }
    return $out.ToArray()
}
function Same-Bytes([byte[]]$a, [byte[]]$b) { return ([Convert]::ToBase64String($a) -ceq [Convert]::ToBase64String($b)) }
function Get-Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
$serializer = New-Object Web.Script.Serialization.JavaScriptSerializer; $serializer.MaxJsonLength = [int]::MaxValue
try {
    # ---- limits and the text rule ----------------------------------------------------------------------------------------------------
    $lim = Get-StorageTrimLimits
    Assert ($lim.Threshold -eq 16KB -and $lim.Head -eq 2KB -and $lim.Tail -eq 1KB) 'limits: over 16 KB keeps 2 KB first and 1 KB last'
    $small = 'x' * 16384
    Assert ((Get-StorageTrimmedText -Text $small -Key 'claude:c1').Cut -eq $false) 'exactly 16 KB is left alone'
    $t = ('A' * 2048) + ('m' * 40000) + ('Z' * 1024)
    $r = Get-StorageTrimmedText -Text $t -Key 'claude:c1'
    Assert ($r.Cut -and $r.Text.StartsWith('A' * 2048) -and $r.Text.EndsWith('Z' * 1024) -and $r.Text -like '*[[]... 39 KB trimmed; full output in archive claude:c1 ...]*' -and $r.Text.Length -lt 3300) "over 16 KB: 2 KB + marker + 1 KB ($($r.Text.Length))"

    # ---- C1-1: Claude jsonl --------------------------------------------------------------------------------------------------------------
    $big = 'B' * 50000
    $imgData = 'QUJD' * 8000   # 32000 chars of base64
    $n1 = '{"type":"user","uuid":"u1","parentUuid":null,"sessionId":"s1","cwd":"C:\\work","timestamp":"2026-10-01T08:00:00.000Z","message":{"role":"user","content":"caf' + [char]0xE9 + ' hello"}}' + "`n"
    $n2 = '{"type":"assistant","uuid":"u2","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}' + "`r`n"
    $tr = '{"type":"user","uuid":"u3","parentUuid":"u2","sessionId":"s1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"' + $big + '"}]}}' + "`n"
    $im = '{"type":"user","uuid":"u4","parentUuid":"u3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"shot"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"' + $imgData + '"}}]}]}}' + "`n"
    $n5 = '{"type":"assistant","uuid":"u5","parentUuid":"u4","message":{"role":"assistant","content":"done"}}' + "`n"
    $src = Join-Path $tmp 'claude.jsonl'; $dst = Join-Path $tmp 'claude.out.jsonl'
    Write-Bytes $src ($utf8.GetBytes($n1 + $n2 + $tr + $im + $n5))
    $st = ConvertTo-TrimmedClaudeJsonl -Path $src -OutPath $dst -Key 'claude:c1'
    $in = Get-Lines ([IO.File]::ReadAllBytes($src)); $out = Get-Lines ([IO.File]::ReadAllBytes($dst))
    Assert ($out.Count -eq 5 -and $in.Count -eq 5) 'five lines in, five lines out'
    foreach ($i in 0, 1, 4) { Assert (Same-Bytes $in[$i] $out[$i]) "ordinary line $($i + 1) is identical byte for byte (the CRLF one too)" }
    $o3 = $serializer.DeserializeObject($utf8.GetString($out[2]).TrimEnd())
    $c3 = $o3['message']['content'][0]['content']
    Assert ($c3.StartsWith('B' * 2048) -and $c3.EndsWith('B' * 1024) -and $c3 -like '*KB trimmed; full output in archive claude:c1*' -and $c3.Length -lt 3300) 'tool_result: 2 KB + marker + 1 KB'
    Assert ($o3['uuid'] -eq 'u3' -and $o3['parentUuid'] -eq 'u2' -and $o3['sessionId'] -eq 's1' -and $o3['type'] -eq 'user') 'uuid, parentUuid and the other fields are unchanged'
    $o4 = $serializer.DeserializeObject($utf8.GetString($out[3]).TrimEnd())
    $blocks = $o4['message']['content'][0]['content']
    Assert ($blocks[0]['text'] -eq 'shot' -and $blocks[1]['type'] -eq 'text' -and $blocks[1]['text'] -eq '[image trimmed]' -and $o4['uuid'] -eq 'u4') 'an image becomes [image trimmed]; the text next to it stays'
    foreach ($l in $out) { [void]$serializer.DeserializeObject($utf8.GetString($l).TrimEnd()) }
    Assert ($st.Lines -eq 5 -and $st.Changed -eq 2 -and $st.Items -eq 2) 'the stats count lines, changed lines and cut items'
    Assert ($st.BytesBefore -eq (Get-Item $src).Length -and $st.BytesAfter -eq (Get-Item $dst).Length -and $st.BytesAfter -lt 12000) 'bytes before and after match the files'
    # nothing to cut: the output is the input
    $dst2 = Join-Path $tmp 'claude.same.jsonl'
    $st2 = ConvertTo-TrimmedClaudeJsonl -Path $dst -OutPath $dst2 -Key 'claude:c1'
    Assert ((Get-Sha $dst) -eq (Get-Sha $dst2) -and $st2.Changed -eq 0) 'a file with nothing big comes out identical'
    # a damaged big line is left alone, not lost
    $junk = '{"type":"user","message":' + ('x' * 20000) + "`n"
    Write-Bytes (Join-Path $tmp 'junk.jsonl') ($utf8.GetBytes($junk + $n5))
    [void](ConvertTo-TrimmedClaudeJsonl -Path (Join-Path $tmp 'junk.jsonl') -OutPath (Join-Path $tmp 'junk.out.jsonl') -Key 'claude:c1')
    Assert ((Get-Sha (Join-Path $tmp 'junk.jsonl')) -eq (Get-Sha (Join-Path $tmp 'junk.out.jsonl'))) 'a big line that is not valid JSON is copied as it is'
    # a text file under tool-results
    $tf = Join-Path $tmp 'tool-results\out.txt'; Write-Bytes $tf ($utf8.GetBytes(('L' * 30000)))
    $st3 = ConvertTo-TrimmedTextFile -Path $tf -OutPath (Join-Path $tmp 'out.trim.txt') -Key 'claude:c1'
    $tt = [IO.File]::ReadAllText((Join-Path $tmp 'out.trim.txt'))
    Assert ($st3.Items -eq 1 -and $tt -like '*KB trimmed; full output in archive claude:c1*' -and $tt.Length -lt 3300) 'a big text file of tool-results is cut by the same rule'

    # ---- C1-2: Codex rollout ----------------------------------------------------------------------------------------------------------------
    $m1 = '{"timestamp":"2026-10-01T08:00:00Z","type":"session_meta","payload":{"id":"x1","cwd":"C:\\work","model_provider":"openai"}}' + "`n"
    $f1 = '{"timestamp":"t1","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"' + ('F' * 40000) + '"}}' + "`n"
    $f2 = '{"timestamp":"t2","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c2","output":"' + ('G' * 20000) + '"}}' + "`n"
    $f3 = '{"timestamp":"t3","type":"response_item","payload":{"type":"function_call_output","call_id":"c3","output":"short"}}' + "`n"
    $f4 = '{"timestamp":"t4","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"' + ('U' * 30000) + '"}]}}' + "`n"
    $rsrc = Join-Path $tmp 'rollout.jsonl'; $rdst = Join-Path $tmp 'rollout.out.jsonl'
    Write-Bytes $rsrc ($utf8.GetBytes($m1 + $f1 + $f2 + $f3 + $f4))
    $rs = ConvertTo-TrimmedCodexRollout -Path $rsrc -OutPath $rdst -Key 'codex:x1.11223344'
    $ri = Get-Lines ([IO.File]::ReadAllBytes($rsrc)); $ro = Get-Lines ([IO.File]::ReadAllBytes($rdst))
    foreach ($i in 0, 3, 4) { Assert (Same-Bytes $ri[$i] $ro[$i]) "rollout line $($i + 1) is identical byte for byte (a big user message is not an output)" }
    $p1 = $serializer.DeserializeObject($utf8.GetString($ro[1]).TrimEnd())['payload']; $p2 = $serializer.DeserializeObject($utf8.GetString($ro[2]).TrimEnd())['payload']
    Assert ($p1['output'].StartsWith('F' * 2048) -and $p1['output'] -like '*trimmed; full output in archive codex:x1.11223344*' -and $p1['call_id'] -eq 'c1' -and $p2['output'] -like '*trimmed*' -and $p2['call_id'] -eq 'c2') 'function_call_output and custom_tool_call_output are cut, their call ids stay'
    Assert ($rs.Items -eq 2 -and $rs.Changed -eq 2) 'two outputs were cut'
    Assert-Throws { [void](ConvertTo-TrimmedCodexRollout -Path (Join-Path $tmp 'rollout.jsonl.zst') -OutPath $rdst -Key 'codex:x1.11223344') } 'a .zst rollout is refused'
    $zr = ''; try { [void](ConvertTo-TrimmedCodexRollout -Path (Join-Path $tmp 'rollout.jsonl.zst') -OutPath $rdst -Key 'k:1') } catch { $zr = $_.Exception.Message }
    Assert ($zr -like 'trim-unsupported*') "the refusal says why: $zr"

    # ---- C1-3: Invoke-StorageTrim -------------------------------------------------------------------------------------------------------------
    Assert ($script:StorageTrimInPlace.codex -eq $true -and $script:StorageTrimInPlace.claude -eq $true) 'the constant: Codex (S15) and Claude (S14) are cut in place'
    $old = [DateTime]::UtcNow.AddDays(-40); $oldMs = ([DateTimeOffset]$old).ToUnixTimeMilliseconds()
    $store = Join-Path $tmp 'store'; $target = @{ Kind = 'local'; Path = $store; PathMap = @{} }
    $machine = 'aaaaaaaa-0000-4000-8000-000000000001'
    function New-ClaudeFiles($name, [switch]$WithCli) {
        $dir = Join-Path $tmp "w-$name\projects\C--work-alpha"; $jsonl = Join-Path $dir "$name.jsonl"
        Write-Bytes $jsonl ($utf8.GetBytes($n1 + $n2 + $tr + $im + $n5)); (Get-Item $jsonl).LastWriteTimeUtc = $old
        $parts = @(@{ Role = 'transcript'; Path = $jsonl; Kind = 'file'; Bytes = (Get-Item $jsonl).Length; MTimeTicks = $old.Ticks; ProfileId = ''; Files = 1 })
        if ($WithCli) {
            $cd = Join-Path $dir $name; Write-Bytes (Join-Path $cd 'tool-results\out.txt') ($utf8.GetBytes('T' * 30000)); Write-Bytes (Join-Path $cd 'subagents\agent-1.jsonl') ($utf8.GetBytes($tr))
            foreach ($f in Get-ChildItem $cd -Recurse -File) { $f.LastWriteTimeUtc = $old }
            $parts += @{ Role = 'cli-dir'; Path = $cd; Kind = 'dir'; Bytes = 40000; MTimeTicks = $old.Ticks; ProfileId = ''; Files = 2 }
        }
        return [pscustomobject]@{ Harness = 'claude'; Key = "claude:$name"; Id = $name; Title = "Chat $name"; Cwd = 'C:\work\alpha'; Profiles = @([pscustomobject]@{ Id = 'Default'; Name = 'Default' }); Parts = $parts
            Bytes = [long]60000; State = 'idle'; LastActivity = $oldMs; Created = $null; Flags = @{ Trimmable = $true; HasZst = $false; Subagent = $false; IsCliOnly = $false } }
    }
    function New-CodexFiles($name, [switch]$Subagent) {
        $rp = Join-Path $tmp "w-$name\sessions\2026\11\15\rollout-$name.jsonl"
        Write-Bytes $rp ($utf8.GetBytes($m1 + $f1 + $f2 + $f3 + $f4)); (Get-Item $rp).LastWriteTimeUtc = $old
        return [pscustomobject]@{ Harness = 'codex'; Key = "codex:$name.11223344"; Id = $name; Title = "Codex $name"; Cwd = 'C:\work'; Profiles = @([pscustomobject]@{ Id = 'P1'; Name = 'P1' })
            Parts = @(@{ Role = 'rollout'; Path = $rp; Kind = 'file'; Bytes = (Get-Item $rp).Length; MTimeTicks = $old.Ticks; ProfileId = 'P1'; Files = 1 }); Bytes = (Get-Item $rp).Length; State = 'idle'; LastActivity = $oldMs; Created = $null
            Flags = @{ Trimmable = $true; HasZst = $false; Subagent = [bool]$Subagent; CodexArchived = $false } }
    }
    $cx = New-CodexFiles 'x1'; $cpath = $cx.Parts[0].Path; $cBefore = Get-Sha $cpath; $cLen = (Get-Item $cpath).Length
    $res = @(Invoke-StorageTrim -Sessions @($cx) -Target $target -Mode InPlace -MachineId $machine)
    Assert ($res.Count -eq 1 -and $res[0].Ok -and $res[0].Mode -eq 'InPlace') "Codex InPlace works: $($res[0].Reason)"
    Assert ((Get-Item $cpath).Length -lt $cLen / 2 -and (Get-Item $cpath).LastWriteTimeUtc -eq $old) 'the rollout is smaller and keeps its modified time'
    $zip = @(Get-ChildItem (Join-Path $store 'codex') -Recurse -Filter 'codex_x1.11223344.*.harchive.zip')[0].FullName   # R1-1: the file name has an archiveId
    $chk = Read-StorageArchive -ZipPath $zip
    Assert ($chk.Verified -and $chk.Manifest.parts[0].sha256 -eq $cBefore) 'the archive in the store holds the file as it was before the cut'
    Assert (@(Get-StorageArchiveIndex -Target $target | Where-Object { $_.key -eq 'codex:x1.11223344' }).Count -eq 1) 'the archive is in the index'
    $tj = Get-Content -LiteralPath (Join-Path (Split-Path $zip) 'codex_x1.11223344.trim.json') -Raw | ConvertFrom-Json
    Assert ($tj.mode -eq 'InPlace' -and $tj.items -eq 2 -and $tj.bytesBefore -eq $cLen -and $tj.bytesAfter -eq (Get-Item $cpath).Length) 'trim.json: mode, items, bytes before and after'
    Assert (@(Get-ChildItem (Split-Path $cpath) -Filter '*.trim-*').Count -eq 0) 'no tmp file is left'
    # the archive fails: the original is not touched
    $cx2 = New-CodexFiles 'x2'; $b2 = Get-Sha $cx2.Parts[0].Path
    $res = @(& { function New-StorageArchive { throw 'archive-verify-failed: boom' }; Invoke-StorageTrim -Sessions @($cx2) -Target $target -Mode InPlace -MachineId $machine })
    Assert (-not $res[0].Ok -and $res[0].Reason -like 'archive-verify-failed*' -and (Get-Sha $cx2.Parts[0].Path) -eq $b2) 'an archive that fails leaves the original byte for byte'
    Assert (-not (Test-Path (Join-Path $store ('codex\' + (Get-Date -Format 'yyyy-MM') + '\codex_x2.11223344.trim.json')))) 'and writes no trim.json'
    # the store check fails (the copy in the store is damaged): the original is not touched either
    $cx3 = New-CodexFiles 'x3'; $b3 = Get-Sha $cx3.Parts[0].Path
    $res = @(& { function Copy-StorageArchiveToStore { throw 'store-verify-failed: damaged' }; Invoke-StorageTrim -Sessions @($cx3) -Target $target -Mode InPlace -MachineId $machine })
    Assert (-not $res[0].Ok -and (Get-Sha $cx3.Parts[0].Path) -eq $b3) 'a store that fails leaves the original byte for byte'
    # Codex sub-agent: never in place
    $cs = New-CodexFiles 's1' -Subagent; $bs = Get-Sha $cs.Parts[0].Path
    $res = @(Invoke-StorageTrim -Sessions @($cs) -Target $target -Mode InPlace -MachineId $machine)
    Assert ($res[0].Ok -and $res[0].Mode -eq 'ReadOnlyCopy' -and (Get-Sha $cs.Parts[0].Path) -eq $bs -and @($res[0].Warnings).Count -ge 1) 'a sub-agent rollout falls back to a read-only copy and says so'
    # Claude: InPlace asked, the constant says no -> read-only copy
    $cl = New-ClaudeFiles 'c1'; $bl = Get-Sha $cl.Parts[0].Path
    $script:StorageTrimInPlace.claude = $false   # the gate closed: InPlace is only a request
    try { $res = @(Invoke-StorageTrim -Sessions @($cl) -Target $target -Mode InPlace -MachineId $machine) } finally { $script:StorageTrimInPlace.claude = $true }
    $md = Join-Path $store ('claude\' + (Get-Date -Format 'yyyy-MM') + '\claude_c1.trimmed.md')
    Assert ($res[0].Ok -and $res[0].Mode -eq 'ReadOnlyCopy' -and (Get-Sha $cl.Parts[0].Path) -eq $bl) 'with the gate closed Claude stays untouched and gets a read-only copy'
    $mdText = [IO.File]::ReadAllText($md)
    Assert ($mdText -like '*Chat c1*' -and $mdText -like '*KB trimmed; full output in archive claude:c1*' -and $mdText -notlike '*' + ('B' * 5000) + '*') 'claude_c1.trimmed.md reads the chat with the big output cut'
    Assert (Test-Path (Join-Path (Split-Path $md) 'claude_c1.trim.json')) 'and has its trim.json'
    $res = @(Invoke-StorageTrim -Sessions @($cl) -Target $target -Mode ReadOnlyCopy -MachineId $machine)
    Assert ($res[0].Ok -and (Get-Sha $cl.Parts[0].Path) -eq $bl) 'ReadOnlyCopy keeps the original byte for byte'
    # Claude in place (S14 passed), with a tool-results file and a sub-agent file
    $cl2 = New-ClaudeFiles 'c2' -WithCli; $cliDir = $cl2.Parts[1].Path; $subBefore = Get-Sha (Join-Path $cliDir 'subagents\agent-1.jsonl')
    $res = @(Invoke-StorageTrim -Sessions @($cl2) -Target $target -Mode InPlace -MachineId $machine)
    Assert ($res[0].Ok -and $res[0].Mode -eq 'InPlace') "Claude InPlace: $($res[0].Reason)"
    Assert ((Get-Item (Join-Path $cliDir 'tool-results\out.txt')).Length -lt 4000 -and (Get-Item $cl2.Parts[0].Path).Length -lt 12000 -and (Get-Sha (Join-Path $cliDir 'subagents\agent-1.jsonl')) -eq $subBefore) 'the transcript and the tool-results file are cut; other files of the folder are not'
    Assert ((Read-StorageArchive -ZipPath @(Get-ChildItem (Join-Path $store 'claude') -Recurse -Filter 'claude_c2.*.harchive.zip')[0].FullName).Verified) 'with an archive made first'
    Assert (@(Get-StorageArchiveIndex -Target $target | Where-Object { $_.key -eq 'claude:c2' })[0].archiveId -match '\A\d{8}T\d{9}\z') 'R1-1: the safety archive row has its archiveId'
    # the guard for a Claude session: recent, open file, running app, running CLI in its folder
    $cg = New-ClaudeFiles 'g1'; $bg = Get-Sha $cg.Parts[0].Path
    $r1 = @(Invoke-StorageTrim -Sessions @($cg) -Target $target -Mode InPlace -MachineId $machine -LockProbe { param($p) $true })
    Assert ($r1[0].Skipped -and $r1[0].Reason -like '*open in another program*' -and (Get-Sha $cg.Parts[0].Path) -eq $bg) 'Claude: a file open elsewhere (live) is skipped and untouched'
    $r2 = @(Invoke-StorageTrim -Sessions @($cg) -Target $target -Mode InPlace -MachineId $machine -Running @{ claude = @('Default') })
    Assert ($r2[0].Skipped -and $r2[0].Reason -like 'Close Default first*' -and (Get-Sha $cg.Parts[0].Path) -eq $bg) 'Claude: a running app of the profile (protected) is skipped and untouched'
    $r3 = @(Invoke-StorageTrim -Sessions @($cg) -Target $target -Mode InPlace -MachineId $machine -CliCwds @('C:\work\alpha'))
    Assert ($r3[0].Skipped -and $r3[0].Reason -like '*Claude CLI is running*' -and (Get-Sha $cg.Parts[0].Path) -eq $bg) 'Claude: a CLI running in the folder of the session is skipped and untouched'
    $cg.Parts[0].MTimeTicks = [DateTime]::UtcNow.Ticks; $cg.LastActivity = ([DateTimeOffset][DateTime]::UtcNow).ToUnixTimeMilliseconds()
    $r4 = @(Invoke-StorageTrim -Sessions @($cg) -Target $target -Mode InPlace -MachineId $machine)
    Assert ($r4[0].Skipped -and $r4[0].Reason -like 'Used in the last*' -and (Get-Sha $cg.Parts[0].Path) -eq $bg) 'Claude: a recent session is skipped and untouched'
    # a recent session is skipped in place (not for a read-only copy)
    $cr = New-CodexFiles 'r1'; $cr.Parts[0].MTimeTicks = [DateTime]::UtcNow.Ticks; $cr.LastActivity = ([DateTimeOffset][DateTime]::UtcNow).ToUnixTimeMilliseconds(); $br = Get-Sha $cr.Parts[0].Path
    $res = @(Invoke-StorageTrim -Sessions @($cr) -Target $target -Mode InPlace -MachineId $machine)
    Assert ($res[0].Skipped -and $res[0].Reason -like 'Used in the last*' -and (Get-Sha $cr.Parts[0].Path) -eq $br) 'the guard skips a session in use, with its reason'
    # Codex app of that home is running: a trim in place writes the rollout directly, so it waits
    $co = New-CodexFiles 'o1'; $bo = Get-Sha $co.Parts[0].Path
    $res = @(Invoke-StorageTrim -Sessions @($co) -Target $target -Mode InPlace -MachineId $machine -Running @{ codex = @('P1'); claude = @() })
    Assert ($res[0].Skipped -and $res[0].Reason -eq 'Close Codex (P1) first: trimming in place writes the rollout directly.' -and (Get-Sha $co.Parts[0].Path) -eq $bo) 'Codex running: skipped with the reason, the rollout is untouched'
    $res = @(Invoke-StorageTrim -Sessions @($co) -Target $target -Mode InPlace -MachineId $machine -Running @{ codex = @('Other'); claude = @() })
    Assert ($res[0].Ok -and (Get-Sha $co.Parts[0].Path) -ne $bo) 'another Codex profile running: the trim goes ahead'
    $co2 = New-CodexFiles 'o2'; $bo2 = Get-Sha $co2.Parts[0].Path
    $res = @(Invoke-StorageTrim -Sessions @($co2) -Target $target -Mode ReadOnlyCopy -MachineId $machine -Running @{ codex = @('P1') })
    Assert ($res[0].Ok -and (Get-Sha $co2.Parts[0].Path) -eq $bo2) 'a read-only copy does not need Codex closed'
    # what cannot be trimmed, and a failure in the middle of a batch
    $cz = New-CodexFiles 'z1'; $cz.Flags.HasZst = $true
    $ag = [pscustomobject]@{ Harness = 'antigravity'; Key = 'antigravity:g1.aabbccdd'; Id = 'g1'; Title = 'agy'; Cwd = ''; Profiles = @(); Parts = @(); Bytes = 1; State = 'idle'; LastActivity = $oldMs; Flags = @{ Trimmable = $false; HasZst = $false } }
    $gone = New-CodexFiles 'gone1'; Remove-Item $gone.Parts[0].Path; $ok = New-CodexFiles 'ok1'
    $prog = [hashtable]::Synchronized(@{ Done = 0; Total = 4 })
    $res = @(Invoke-StorageTrim -Sessions @($cz, $ag, $gone, $ok) -Target $target -Mode InPlace -MachineId $machine -Progress $prog)
    Assert ($res.Count -eq 4 -and $res[0].Skipped -and $res[0].Reason -like '*cannot be trimmed*' -and $res[1].Skipped -and $res[1].Reason -like '*Antigravity*' -and -not $res[2].Ok -and $res[3].Ok) 'a .zst, an Antigravity session and a missing file do not stop the batch'
    Assert ($prog.Done -eq 4) 'progress counts every session'
    $res = @(Invoke-StorageTrim -Sessions @((New-CodexFiles 'k1'), (New-CodexFiles 'k2')) -Target $target -Mode InPlace -MachineId $machine -CancelToken @{ Cancel = $true })
    Assert ($res.Count -eq 0) 'Cancel stops before the next session'
    # a Drive store cannot hold a read-only copy yet
    $dr = @(Invoke-StorageTrim -Sessions @((New-ClaudeFiles 'c9')) -Target @{ Kind = 'drive'; SyncRoot = $tmp; MachineId = $machine; Key = [byte[]](1..32); PathMap = @{} } -Mode ReadOnlyCopy -MachineId $machine)
    Assert (-not $dr[0].Ok -and $dr[0].Reason -like 'store-unsupported*') 'a Drive store is refused for the read-only copy, with a reason'

    # ---- R2-1: only a UTF-8 .txt/.log file of tool-results is cut as text ------------------------------------------------------------
    $bigBin = New-Object byte[] 30000; for ($i = 0; $i -lt $bigBin.Length; $i++) { $bigBin[$i] = [byte](($i * 7 + 3) % 251 + 1) }   # no NUL, but not a text file
    $latin = New-Object byte[] 30000; for ($i = 0; $i -lt $latin.Length; $i++) { $latin[$i] = 0x41 }; $latin[100] = 0xE9; $latin[101] = 0xFF   # invalid UTF-8
    $withNul = New-Object byte[] 30000; for ($i = 0; $i -lt $withNul.Length; $i++) { $withNul[$i] = 0x41 }; $withNul[5000] = 0
    $jsonBig = $utf8.GetBytes('{"a":"' + ('J' * 30000) + '"}')
    $rdir = Join-Path $tmp 'w-r21\projects\C--work-alpha\r21\tool-results'
    Write-Bytes (Join-Path $rdir 'shot.png') $bigBin; Write-Bytes (Join-Path $rdir 'data.json') $jsonBig; Write-Bytes (Join-Path $rdir 'latin.txt') $latin
    Write-Bytes (Join-Path $rdir 'zero.txt') $withNul; Write-Bytes (Join-Path $rdir 'doc.pdf') $bigBin; Write-Bytes (Join-Path $rdir 'good.txt') ($utf8.GetBytes('G' * 30000)); Write-Bytes (Join-Path $rdir 'run.log') ($utf8.GetBytes('H' * 30000))
    $r21 = [pscustomobject]@{ Harness = 'claude'; Parts = @(@{ Role = 'cli-dir'; Path = (Split-Path $rdir); Kind = 'dir'; Bytes = 1; MTimeTicks = 1; ProfileId = ''; Files = 7 }) }
    $names = @(Get-StorageTrimTargets -Session $r21 | ForEach-Object { Split-Path -Leaf $_.Path } | Sort-Object)
    Assert (($names -join ',') -eq 'good.txt,latin.txt,run.log,zero.txt') "only .txt and .log files are candidates, not images, pdf or json: $($names -join ',')"
    foreach ($nm in 'latin.txt', 'zero.txt') {
        $o = Join-Path $tmp "r21-$nm"; $st = ConvertTo-TrimmedTextFile -Path (Join-Path $rdir $nm) -OutPath $o -Key 'claude:r21'
        Assert ($st.Items -eq 0 -and (Get-Sha (Join-Path $rdir $nm)) -eq (Get-Sha $o)) "$nm (not UTF-8, or has a NUL) is not cut and comes out byte for byte"
    }
    foreach ($nm in 'shot.png') {   # a binary file does not decode as UTF-8 text, so it is not cut even if handed over (json is kept out by the extension filter above)
        $o = Join-Path $tmp "r21-$nm"; $st = ConvertTo-TrimmedTextFile -Path (Join-Path $rdir $nm) -OutPath $o -Key 'claude:r21'
        Assert ($st.Items -eq 0 -and (Get-Sha (Join-Path $rdir $nm)) -eq (Get-Sha $o)) "$nm keeps every byte"
    }
    $g = ConvertTo-TrimmedTextFile -Path (Join-Path $rdir 'good.txt') -OutPath (Join-Path $tmp 'r21-good.txt') -Key 'claude:r21'
    Assert ($g.Items -eq 1 -and (Get-Item (Join-Path $tmp 'r21-good.txt')).Length -lt 3300) 'a big UTF-8 .txt file is cut'

    # ---- R2-2: nothing to cut means no archive, no trim.json, no index row, an untouched file ------------------------------------------
    $smallLines = $n1 + $n2 + $n5
    $ns = New-ClaudeFiles 'ns1'; Write-Bytes $ns.Parts[0].Path ($utf8.GetBytes($smallLines)); (Get-Item $ns.Parts[0].Path).LastWriteTimeUtc = $old; $nsBefore = Get-Sha $ns.Parts[0].Path
    $res = @(Invoke-StorageTrim -Sessions @($ns) -Target $target -Mode InPlace -MachineId $machine)
    Assert ($res[0].Ok -and $res[0].Mode -eq 'InPlace' -and $res[0].Items -eq 0 -and $res[0].Reason -like '*nothing to trim*') "no big output: Ok, with 'nothing to trim': $($res[0].Reason)"
    $zdir = Join-Path $store ('claude\' + (Get-Date -Format 'yyyy-MM'))
    Assert (-not (Test-Path (Join-Path $zdir 'claude_ns1.*.harchive.zip')) -and -not (Test-Path (Join-Path $zdir 'claude_ns1.trim.json'))) 'no zip and no trim.json were made'
    Assert (@(Get-StorageArchiveIndex -Target $target | Where-Object { $_.key -eq 'claude:ns1' }).Count -eq 0) 'and no index row'
    Assert ((Get-Sha $ns.Parts[0].Path) -eq $nsBefore -and (Get-Item $ns.Parts[0].Path).LastWriteTimeUtc -eq $old -and @(Get-ChildItem (Split-Path $ns.Parts[0].Path) -Filter '*.trim-*').Count -eq 0) 'the file is the same bytes with the same time, and no tmp is left'
    # a real archive of the session already in the store is not overwritten by a nothing-to-trim run
    $cdone = New-ClaudeFiles 'ns2'; $res = @(Invoke-StorageTrim -Sessions @($cdone) -Target $target -Mode InPlace -MachineId $machine)
    $zip2 = @(Get-ChildItem $zdir -Filter 'claude_ns2.*.harchive.zip')[0].FullName; $zipBefore = Get-Sha $zip2
    $res = @(Invoke-StorageTrim -Sessions @($cdone) -Target $target -Mode InPlace -MachineId $machine)
    Assert ($res[0].Ok -and $res[0].Items -eq 0 -and (Get-Sha $zip2) -eq $zipBefore) 'a second trim of an already cut session leaves the first archive as it is'
    # the file changes between the cut and the swap: it is left alone and the archive still exists
    $cx4 = New-ClaudeFiles 'ns3'; $path4 = $cx4.Parts[0].Path
    $res = @(& { function Save-StorageSafetyArchive { [IO.File]::AppendAllText($path4, "`n"); return @{ ZipPath = 'x'; Dir = $null } }; Invoke-StorageTrim -Sessions @($cx4) -Target $target -Mode InPlace -MachineId $machine })
    Assert (-not $res[0].Ok -and $res[0].Reason -like '*changed-while-trimming*' -and @(Get-ChildItem (Split-Path $path4) -Filter '*.trim-*').Count -eq 0) 'a file written to after the cut is not replaced, and no tmp is left'

    Write-Output 'PASS: Storage.Compact - limits, Claude jsonl, text files, Codex rollout, Invoke-StorageTrim.'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
