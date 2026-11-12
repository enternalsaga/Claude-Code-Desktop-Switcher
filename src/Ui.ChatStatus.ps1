# Ui.ChatStatus.ps1 - pure functions behind the chat list of the main window: where a chat stands against Drive,
# whether its folder is missing, which path roots to suggest, how to print a time (phase 5, lane V1).
# No WinForms and no Drive access: the caller loads the catalog (Get-SyncCatalog) and the state (Get-SyncState) once and
# passes them in. The status rule is the one of Get-SyncDivergence, split a little finer for the screen. ASCII only.

# '<harness>:<chatId>', the chatKey New-HarnessBundle writes into a bundle of this chat.
function Get-HarnessChatKey {
    param([Parameter(Mandatory)][string]$Harness, [Parameter(Mandatory)]$Chat)
    return ('{0}:{1}' -f $Harness.ToLowerInvariant(), $Chat.ChatId)
}

# The sync-state entry of a chat, unless it was made for another profile (then it says nothing about this chat).
function Get-ChatSyncStateEntry {
    param($State, [Parameter(Mandatory)][string]$ChatKey, $Chat)
    $entry = $null
    if ($State -is [System.Collections.IDictionary]) { if ($State.Contains($ChatKey)) { $entry = $State[$ChatKey] } }
    elseif ($State -is [pscustomobject]) { $p = $State.PSObject.Properties[$ChatKey]; if ($p) { $entry = $p.Value } }
    if (-not $entry) { return $null }
    $profileId = $(if ($Chat -and $Chat.Profile) { [string]$Chat.Profile.Id } else { '' })
    if ($entry.profileId -and $profileId -and [string]$entry.profileId -ne $profileId) { return $null }
    return $entry
}

# True when the chat has not moved since the last sync. Unknown activity cannot be called unchanged.
function Test-ChatUnchangedSinceSync {
    param($Chat, $Entry)
    return [bool]($Entry -and $null -ne $Entry.localActivityAtSync -and $null -ne $Chat.Activity -and $Chat.Activity -le $Entry.localActivityAtSync)
}

# NoSync (no catalog: sync is not set up or not loaded) | NotOnDrive | Synced | LocalNewer | DriveNewer | Diverged,
# plus the Drive row, the machine it came from and whether the chat's folder is missing on this machine.
function Get-HarnessChatSyncStatus {
    param([Parameter(Mandatory)]$Chat, [Parameter(Mandatory)][string]$Harness, $Catalog, $State)
    $cwdMissing = $false
    if ($Chat.Cwd) { try { $cwdMissing = -not (Test-Path -LiteralPath ([string]$Chat.Cwd) -PathType Container) } catch { $cwdMissing = $true } }
    $result = [pscustomobject]@{ Sync = 'NoSync'; Row = $null; FromMachine = $null; CwdMissing = $cwdMissing }
    if ($null -eq $Catalog) { return $result }
    $key = Get-HarnessChatKey -Harness $Harness -Chat $Chat
    $row = @($Catalog | Where-Object { $_.chatKey -eq $key }) | Select-Object -First 1
    if (-not $row) { $result.Sync = 'NotOnDrive'; return $result }
    $entry = Get-ChatSyncStateEntry -State $State -ChatKey $key -Chat $Chat
    $same = [bool]($entry -and [string]$row.bundleId -eq [string]$entry.lastBundleId)
    $unchanged = Test-ChatUnchangedSinceSync -Chat $Chat -Entry $entry
    $result.Row = $row
    $result.FromMachine = $row.MachineName
    $result.Sync = $(if ($same -and $unchanged) { 'Synced' } elseif ($same) { 'LocalNewer' } elseif ($unchanged) { 'DriveNewer' } else { 'Diverged' })
    return $result
}

# For a row of the Drive tab: NotHere | UpToDate | DriveNewer | Diverged. LocalChatLookup is { param($row) -> chat or $null }.
function Get-SyncCatalogRowStatus {
    param([Parameter(Mandatory)]$Row, $State, [Parameter(Mandatory)][scriptblock]$LocalChatLookup)
    $chat = & $LocalChatLookup $Row
    if (-not $chat) { return 'NotHere' }
    $entry = Get-ChatSyncStateEntry -State $State -ChatKey ([string]$Row.chatKey) -Chat $chat
    if ($entry -and [string]$Row.bundleId -eq [string]$entry.lastBundleId) { return 'UpToDate' }
    if (Test-ChatUnchangedSinceSync -Chat $chat -Entry $entry) { return 'DriveNewer' }
    return 'Diverged'
}

# ---- suggested path roots -----------------------------------------------------------------------------------------------

function Test-PathCoveredByRoot {
    param([string]$Path, [string]$Root)
    $r = $Root.TrimEnd('\')
    return ($Path -ieq $r -or $Path.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase))
}

# The folder to name as a root for one working folder, or $null when it is not worth naming: the first folder under a
# drive or a share ('H:\AI_Software\x\y' -> 'H:\AI_Software'); inside 'C:\Users\<user>' the folder under the user folder.
function Get-PathRootCandidate {
    param([string]$Cwd)
    if (-not $Cwd -or $Cwd -match '[\x00-\x1f]') { return $null }
    $parts = $null
    if ($Cwd -match '\A([A-Za-z]:)\\(.+)\z') { $head = $Matches[1]; $parts = @($Matches[2].TrimEnd('\') -split '\\' | Where-Object { $_ }) }
    elseif ($Cwd -match '\A(\\\\[^\\]+\\[^\\]+)\\(.+)\z') { $head = $Matches[1]; $parts = @($Matches[2].TrimEnd('\') -split '\\' | Where-Object { $_ }) }
    else { return $null }
    if (-not $parts.Count) { return $null }
    $system = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', '$Recycle.Bin', 'System Volume Information')
    if ($parts[0] -in $system -or $parts -contains '..') { return $null }
    if ($head.Length -eq 2 -and $parts[0] -ieq 'Users') {
        # Never name a root after the user (the name differs between machines and would reach Drive): take the folder
        # right under the user folder, unless it is AppData or hidden.
        if ($parts.Count -lt 3 -or $parts[2] -ieq 'AppData' -or $parts[2].StartsWith('.')) { return $null }
        return ('{0}\{1}\{2}\{3}' -f $head, $parts[0], $parts[1], $parts[2])
    }
    return ('{0}\{1}' -f $head, $parts[0])
}

function ConvertTo-PathRootName {
    param([string]$Path)
    $name = ((Split-Path -Leaf $Path) -replace '[^A-Za-z0-9_-]+', '_').Trim('_')
    if (-not $name) { $name = 'Root' }
    if ($name.Length -gt 40) { $name = $name.Substring(0, 40) }
    return $name
}

# Roots worth naming for a set of working folders: @( @{ Name; Path } ). Folders already under an existing root are left
# out; a name that is taken (by another suggestion or an existing root) gets the drive letter as a suffix.
function Get-SuggestedPathRoots {
    param([string[]]$Cwds, [hashtable]$ExistingRoots)
    if ($null -eq $ExistingRoots) { $ExistingRoots = $(if (Get-Command Get-SyncPathRoots -CommandType Function -ErrorAction SilentlyContinue) { Get-SyncPathRoots } else { @{} }) }
    $taken = @{}
    foreach ($k in $ExistingRoots.Keys) { $taken[([string]$k).ToLowerInvariant()] = $true }
    $existingPaths = @($ExistingRoots.Values | ForEach-Object { [string]$_ })
    $seen = @{}
    $out = New-Object Collections.Generic.List[object]
    foreach ($cwd in @($Cwds)) {
        if (-not $cwd) { continue }
        if (@($existingPaths | Where-Object { Test-PathCoveredByRoot -Path $cwd -Root $_ }).Count) { continue }
        $path = Get-PathRootCandidate -Cwd $cwd
        if (-not $path -or $seen.ContainsKey($path.ToLowerInvariant())) { continue }
        if (@($existingPaths | Where-Object { $_.TrimEnd('\') -ieq $path }).Count) { continue }
        $seen[$path.ToLowerInvariant()] = $true
        $name = ConvertTo-PathRootName -Path $path
        if ($taken.ContainsKey($name.ToLowerInvariant())) {
            $suffix = $(if ($path -match '\A([A-Za-z]):') { $Matches[1].ToUpperInvariant() } else { 'Net' })
            $name = "${name}_$suffix"
            for ($i = 2; $taken.ContainsKey($name.ToLowerInvariant()); $i++) { $name = ('{0}_{1}{2}' -f (ConvertTo-PathRootName -Path $path), $suffix, $i) }
        }
        $taken[$name.ToLowerInvariant()] = $true
        $out.Add(@{ Name = $name; Path = $path })
    }
    return $out.ToArray()
}

# ---- time -------------------------------------------------------------------------------------------------------------------

# '10:42' (today) | 'yesterday' | '3 days' (up to 6) | '2026-11-05'. Empty for a missing or unreadable time.
function Format-SyncWhen {
    param($UnixMs, [datetime]$Now = (Get-Date))
    $ms = 0.0
    if ($null -eq $UnixMs -or $UnixMs -is [string] -or -not [double]::TryParse([string]$UnixMs, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ms)) { return '' }
    $when = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).LocalDateTime
    $days = ($Now.Date - $when.Date).Days
    if ($days -eq 0) { return $when.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
    if ($days -eq 1) { return 'yesterday' }
    if ($days -ge 2 -and $days -le 6) { return "$days days" }
    return $when.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}
