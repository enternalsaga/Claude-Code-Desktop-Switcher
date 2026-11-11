# Harness.Claude.ps1 - Claude adapter. Wraps the functions that already live in ClaudeSwitcher.ps1
# (Find-ClaudeInstall, Get-ProfileList, Start-ClaudeProfile, Get-CodeSessions, Copy-CodeSession,
# Get-CodeSessionStore) without changing their behaviour. Needs Harness.Core.ps1.

# Claude Code keeps a chat's transcript under ~\.claude\projects\<slug of cwd>\; the slug turns every
# character that is not a letter or digit into '-'. H:\AI_Software\X becomes H--AI-Software-X.
function ConvertTo-ClaudeProjectSlug {
    param([Parameter(Mandatory)][string]$Path)
    return ($Path -replace '[^A-Za-z0-9]', '-')
}

function Get-ClaudeHomePath {
    return (Join-Path $env:USERPROFILE '.claude')
}

# The one-line argument shown for a tool call in the transcript.
function Get-ClaudeToolArg {
    param($ToolInput)
    if (-not $ToolInput) { return '' }
    foreach ($name in 'command', 'file_path', 'path', 'pattern', 'url', 'query', 'description', 'prompt') {
        $prop = $ToolInput.PSObject.Properties[$name]
        if ($prop -and $prop.Value -is [string] -and $prop.Value) { return $prop.Value }
    }
    $first = @($ToolInput.PSObject.Properties | Where-Object { $_.Value -is [string] }) | Select-Object -First 1
    if ($first) { return [string]$first.Value }
    return ''
}

function ConvertTo-ClaudeResultText {
    param($Content)
    if ($Content -is [string]) { return $Content }
    return ((@($Content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n")
}

# Normalizes Claude Code's jsonl into {role, text, ts, tool{name,arg,output}} entries. Reasoning,
# queue and attachment lines are dropped; a tool result is attached to its tool call.
function ConvertFrom-ClaudeJsonl {
    param([Parameter(Mandatory)][string]$Path)
    $entries = New-Object Collections.Generic.List[object]
    $toolById = @{}
    foreach ($line in [IO.File]::ReadLines($Path, [Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (($o.type -ne 'user' -and $o.type -ne 'assistant') -or $o.isMeta -or -not $o.message) { continue }
        $content = $o.message.content
        if ($content -is [string]) { $entries.Add(@{ role = $o.type; text = $content; ts = $o.timestamp }); continue }
        $text = New-Object Collections.Generic.List[string]
        $tools = New-Object Collections.Generic.List[object]
        foreach ($part in @($content)) {
            switch ($part.type) {
                'text' { $text.Add([string]$part.text) }
                'tool_use' {
                    $t = @{ role = 'tool'; text = ''; ts = $o.timestamp; tool = @{ name = $part.name; arg = (Get-ClaudeToolArg $part.input); output = '' } }
                    $toolById[$part.id] = $t; $tools.Add($t)
                }
                'tool_result' { if ($toolById.ContainsKey($part.tool_use_id)) { $toolById[$part.tool_use_id].tool.output = ConvertTo-ClaudeResultText $part.content } }
            }
        }
        if ($text.Count) { $entries.Add(@{ role = $o.type; text = ($text -join "`n"); ts = $o.timestamp }) }
        foreach ($t in $tools) { $entries.Add($t) }
    }
    return $entries.ToArray()
}

# The project folder that holds <cli>.jsonl. Claude Code shortens long slugs (adding a hash) and the cwd can change
# after a chat starts, so when the slug folder has no transcript any project folder with that session id counts
# (the id is a UUID, so it cannot clash). With no transcript anywhere, the slug folder is returned.
function Find-ClaudeProjectDir {
    param([string]$ClaudeHome, [string]$Cwd, [string]$Cli)
    $projects = Join-Path $ClaudeHome 'projects'
    $byCwd = Join-Path $projects (ConvertTo-ClaudeProjectSlug $Cwd)
    if (Test-Path -LiteralPath (Join-Path $byCwd "$Cli.jsonl")) { return $byCwd }
    if (Test-Path -LiteralPath $projects) {
        $hit = Get-ChildItem -LiteralPath $projects -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "$Cli.jsonl") } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $byCwd
}

# Every file under $Dir, without following junctions or symlinks (a link inside a chat folder could point anywhere).
function Get-ClaudeFolderFiles {
    param([Parameter(Mandatory)][string]$Dir)
    foreach ($item in Get-ChildItem -LiteralPath $Dir) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($item.PSIsContainer) { Get-ClaudeFolderFiles -Dir $item.FullName } else { $item }
    }
}

# Files that belong to one chat, as @{Role; Path (inside the bundle); SourcePath}.
function Get-ClaudeNativeFiles {
    param([Parameter(Mandatory)]$Session, $Data, [Parameter(Mandatory)][string]$ClaudeHome)
    $files = @(@{ Role = 'native'; Path = "native/$($Session.File.Name)"; SourcePath = $Session.File.FullName })
    $cwd = Get-FirstValue $Data 'cwd', 'originCwd', 'workingDirectory'
    $cli = Get-FirstValue $Data 'cliSessionId'
    if (-not $cwd -or -not $cli) { return $files }
    $project = Find-ClaudeProjectDir -ClaudeHome $ClaudeHome -Cwd $cwd -Cli $cli
    $jsonl = Join-Path $project "$cli.jsonl"
    if (Test-Path -LiteralPath $jsonl) { $files += @{ Role = 'native'; Path = "native/$cli.jsonl"; SourcePath = $jsonl } }
    $dir = Join-Path $project $cli
    if (Test-Path -LiteralPath $dir -PathType Container) {
        $prefix = (Get-Item -LiteralPath $dir).FullName.TrimEnd('\') + '\'
        foreach ($f in Get-ClaudeFolderFiles -Dir $dir) {
            $files += @{ Role = 'native'; Path = ("native/$cli/" + $f.FullName.Substring($prefix.Length).Replace('\', '/')); SourcePath = $f.FullName }
        }
    }
    return $files
}

# Builds <OutPath> (a .hbundle.zip) for one chat from Get-CodeSessions. Native files are copied as they are;
# only transcript.md and transcript.jsonl are redacted. Secret findings in native files are counted, not fixed.
function Export-ClaudeChat {
    param(
        [Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$OutPath,
        [string]$ClaudeHome = (Get-ClaudeHomePath), [string]$HarnessVersion = '', [string]$ProfileLabel = '',
        [string]$MachineId = '', [string]$MachineName = $env:COMPUTERNAME, [hashtable]$PathRoots = @{}, $PreviousBundleId = $null
    )
    $data = Read-ChatJson $Session.File.FullName
    $native = @(Get-ClaudeNativeFiles -Session $Session -Data $data -ClaudeHome $ClaudeHome)
    $findings = 0
    foreach ($n in $native) { if ($n.SourcePath -match '\.(jsonl?|txt|md|log)$') { $findings += Measure-SecretFindings -Path $n.SourcePath } }
    $jsonl = $native | Where-Object { $_.Path -match '^native/[^/]+\.jsonl$' } | Select-Object -First 1
    $entries = @(); if ($jsonl) { $entries = @(Protect-TranscriptEntries -Entries (ConvertFrom-ClaudeJsonl -Path $jsonl.SourcePath)) }
    $cwd = Get-FirstValue $data 'cwd', 'originCwd', 'workingDirectory'
    $title = $(if ($Session.Title) { $Session.Title } else { $Session.Id })
    $md = ConvertTo-HandoffMarkdown -Entries $entries -Harness 'claude' -Title $title -Cwd $cwd
    $jsonLines = ($entries | ForEach-Object { $_ | ConvertTo-Json -Depth 5 -Compress }) -join "`n"
    $source = @{
        harness = 'claude'; harnessVersion = $HarnessVersion; profileLabel = $ProfileLabel; machineId = $MachineId; machineName = $MachineName
        chatId = $Session.Id; parentChatId = $Session.Parent; title = $title
        cwd = $(if ($cwd) { ConvertTo-CwdRef -Path $cwd -PathRoots $PathRoots } else { @{ absolute = $null; root = $null; relative = $null } })
        createdAt = $data.createdAt; lastActivityAt = $Session.Activity
        claude = @{ account = $Session.Account; org = $Session.Org; cliSessionId = (Get-FirstValue $data 'cliSessionId') }
    }
    $files = $native + @(@{ Role = 'transcript'; Path = 'transcript.md'; Content = $md }, @{ Role = 'transcript'; Path = 'transcript.jsonl'; Content = $jsonLines })
    return New-HarnessBundle -OutPath $OutPath -Source $source -Files $files -PreviousBundleId $PreviousBundleId `
        -Redaction @{ scanned = $true; findings = $findings; transcriptRedacted = $true }
}

# The working folder on this machine for a chat that came from another one: the bundle's cwd ref resolved
# through the named folder roots. Returns $null when the ref has no folder, @{ Root } when the root is not
# set up here yet (the caller asks the user), and throws when what comes out is not an absolute path.
function Resolve-ClaudeImportCwd {
    param($Ref, [hashtable]$PathRoots)
    if (-not $Ref -or -not ($Ref.root -or $Ref.absolute)) { return $null }
    $cwd = Resolve-CwdRef -Ref $Ref -PathRoots $PathRoots
    if (-not $cwd -and $Ref.root -and -not $PathRoots.ContainsKey($Ref.root)) { return @{ Root = [string]$Ref.root } }
    if (-not $cwd -or $cwd -notmatch '^(?:[A-Za-z]:\\|\\\\)') { throw 'The working folder in the bundle is not valid on this machine' }
    return $cwd
}

# Native import into a Claude profile. The chat's local json goes through the existing Copy-CodeSession
# (same account/org rewrite, same duplicate rules). On the same machine the transcript jsonl and its folder
# are only added when missing (accounts there share ~\.claude\projects) and the result is Copy-CodeSession's
# string. A bundle from another machine gets its working folder mapped through -PathRoots: the chat json's
# cwd fields are rewritten, the transcript goes under the new folder's project (a newer one replaces the old,
# kept as .bak-<time>), and the result is @{ Status; CwdMissing; Cwd } or @{ Status = 'needs-root'; Root }.
function Import-ClaudeNative {
    param(
        [Parameter(Mandatory)][string]$BundlePath, [Parameter(Mandatory)]$Store,
        [string]$ClaudeHome = (Get-ClaudeHomePath), [hashtable]$PathRoots = (Get-HarnessPathRoots)
    )
    $work = Join-Path ([IO.Path]::GetTempPath()) ('claude-import-' + [guid]::NewGuid().ToString('N'))
    try {
        $m = Read-HarnessBundle -Path $BundlePath -ExtractTo $work
        if ($m.source.harness -ne 'claude') { throw "Not a Claude bundle: $($m.source.harness)" }
        $localRow = @($m.files | Where-Object { $_.path -match '^native/local_[^/]+\.json$' }) | Select-Object -First 1
        if (-not $localRow) { throw 'Bundle has no Claude chat file' }
        $localPath = Join-Path $work ($localRow.path -replace '/', '\')
        $thisMachine = (Get-HarnessMachineInfo).Id
        $cross = [bool]($m.source.machineId -and $thisMachine -and $m.source.machineId -ne $thisMachine)
        if ($cross) {
            # another machine's bundle is untrusted: ids are checked before anything is written
            $cliIn = [string]$m.source.claude.cliSessionId
            if ($cliIn -and $cliIn -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') { throw 'Claude session id in bundle is not a UUID' }
            if ($localRow.path -notmatch '\Anative/local_[A-Za-z0-9_-]+\.json\z') { throw 'Chat file name in bundle is not valid' }
            $newCwd = Resolve-ClaudeImportCwd -Ref $m.source.cwd -PathRoots $PathRoots
            if ($newCwd -is [hashtable]) { return @{ Status = 'needs-root'; Root = $newCwd.Root } }
            if ($newCwd) {
                $text = [IO.File]::ReadAllText($localPath)
                foreach ($key in 'cwd', 'originCwd', 'workingDirectory') { $t = Set-JsonTopLevelString $text $key $newCwd; if ($t) { $text = $t } }
                [IO.File]::WriteAllText($localPath, $text, (New-Object Text.UTF8Encoding($false)))
            }
        }
        $local = Get-Item -LiteralPath $localPath
        $session = [pscustomobject]@{ File = $local; Account = $m.source.claude.account; Org = $m.source.claude.org; Activity = $(if ($null -ne $m.source.lastActivityAt) { [double]$m.source.lastActivityAt } else { $null }) }
        $cwd = Get-FirstValue (Read-ChatJson $local.FullName) 'cwd', 'originCwd', 'workingDirectory'
        $cli = $m.source.claude.cliSessionId
        $replace = $false
        if ($cross) {
            $have = Join-Path $Store.FullName $local.Name
            $replace = ($null -ne $session.Activity) -and (Test-Path -LiteralPath $have) -and ($session.Activity -gt (Get-SessionActivityAt $have))
        }
        if ($cwd) {
            $project = Find-ClaudeProjectDir -ClaudeHome $ClaudeHome -Cwd $cwd -Cli $cli
            foreach ($f in @($m.files | Where-Object { $_.path -ne $localRow.path -and $_.role -eq 'native' })) {
                $dest = Join-Path $project (($f.path -replace '^native/', '') -replace '/', '\')
                if (Test-Path -LiteralPath $dest) {
                    if (-not ($replace -and $f.path -eq "native/$cli.jsonl")) { continue }
                    Move-Item -LiteralPath $dest -Destination ($dest + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
                }
                New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
                Copy-Item -LiteralPath (Join-Path $work ($f.path -replace '/', '\')) -Destination $dest
            }
        }
        $status = Copy-CodeSession -Session $session -Store $Store
        if (-not $cross) { return $status }
        return @{ Status = $status; CwdMissing = [bool]($cwd -and -not (Test-Path -LiteralPath $cwd -PathType Container)); Cwd = $cwd }
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}

function Register-ClaudeHarness {
    Register-Harness -Name 'claude' -Adapter @{
        Detect        = { $i = Find-ClaudeInstall; [pscustomobject]@{ Installed = [bool]$i; Kind = $i.Kind; Exe = $i.Exe; Version = $i.Version; Aumid = $i.AppUserModelId } }
        GetProfiles   = { Get-ProfileList }
        Launch        = { param($Profile) Start-ClaudeProfile -Id $Profile.Id }
        ListChats     = {
            param($Profile)
            Get-CodeSessions -Source $Profile | ForEach-Object {
                $cwd = Get-FirstValue (Read-ChatJson $_.File.FullName) 'cwd', 'originCwd', 'workingDirectory'
                [pscustomobject]@{ ChatId = $_.Id; Title = $_.Title; Cwd = $cwd; Updated = $_.Updated; Activity = $_.Activity; Parent = $_.Parent; Session = $_ }
            }
        }
        Export        = { param($Chat, $OutPath) Export-ClaudeChat -Session $Chat.Session -OutPath $OutPath }
        ImportNative  = { param($BundlePath, $Profile) Import-ClaudeNative -BundlePath $BundlePath -Store (Get-CodeSessionStore -Target $Profile) }
        ImportHandoff = { param($BundlePath, $Profile) Start-HarnessHandoff -BundlePath $BundlePath -TargetHarness 'claude' -Profile $Profile }
        ImportNeedsClose = { $false }
    }
}
