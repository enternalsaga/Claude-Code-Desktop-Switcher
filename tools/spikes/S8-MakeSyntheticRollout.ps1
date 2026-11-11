# Spike S8 helper: copy a real rollout under a NEW thread id (rewriting the id inside) into %TEMP%\harness-spike\S8\synth,
# so a spike can drop "a thread the target home has never seen" even when every real candidate is already registered.
param(
  [Parameter(Mandatory)][string]$SourceRollout,   # full path of a .jsonl rollout (read-only)
  [string]$OutRoot = (Join-Path $env:TEMP 'harness-spike\S8\synth')
)
$ErrorActionPreference = 'Stop'
if ($SourceRollout -notmatch '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$') { throw 'need a plain .jsonl rollout named ...-<threadId>.jsonl' }
$old = $Matches[1]
$new = [guid]::NewGuid().ToString()
$text = [IO.File]::ReadAllText($SourceRollout, [Text.Encoding]::UTF8).Replace($old, $new)
$rel = '2026\11\11\' + ((Split-Path $SourceRollout -Leaf).Replace($old, $new))
$dst = Join-Path $OutRoot $rel
New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
[IO.File]::WriteAllText($dst, $text, (New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{ NewId = $new; Rel = $rel; Root = $OutRoot }
