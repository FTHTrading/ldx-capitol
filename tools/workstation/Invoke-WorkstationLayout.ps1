#Requires -Version 5.1
<#
.SYNOPSIS
    Creates the canonical workstation tree and plans (then, with -Apply, executes) the moves that put every
    repository and every loose project folder where it belongs. Never deletes anything.

.DESCRIPTION
    Reads workstation.json (tree, routing rules, protected folders) and the audit output (repos.csv,
    folders.csv). Produces <Audit>\moves.csv with one row per proposed move and the reason. Review it. Then
    -Apply performs exactly the rows marked Move, one at a time, logging each to <Root>\layout-log.jsonl
    (hash-chained). Same-volume moves are renames; cross-volume moves copy, verify file count and bytes, then
    remove the source.

    Routing:
        git repository                      -> <Root>\10_PLATFORMS\<repo name>
        top-level folder matching a rule    -> <Root>\<rule dest>\<folder>
        other folder untouched > staleDays  -> <Root>\90_ARCHIVE\<yyyy-MM>\<folder>
        anything else                       -> Hold (listed, not moved; decide by hand or add a rule)
    Protected folders (Windows profile folders, OneDrive, AppData, dotfolders) are never moved.

.PARAMETER Audit
    Folder produced by Invoke-WorkstationAudit.ps1.

.PARAMETER Root
    Overrides "root" from workstation.json (e.g. D:\Unykorn on a machine whose C: is small).

.PARAMETER Apply
    Execute the Move rows. Without it, only moves.csv is written.

.EXAMPLE
    .\Invoke-WorkstationLayout.ps1 -Audit "$env:USERPROFILE\WORKSTATION_AUDIT"
    .\Invoke-WorkstationLayout.ps1 -Audit "$env:USERPROFILE\WORKSTATION_AUDIT" -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Audit,
    [string]$Config = (Join-Path $PSScriptRoot 'workstation.json'),
    [string]$ProfileRoot = $(if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }),
    [string]$Root,
    [switch]$Apply
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$onWindows = $true; if (Test-Path variable:IsWindows) { $onWindows = [bool]$IsWindows }
$cmp = if ($onWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

function Test-Wild { param([string]$Name, [string[]]$Patterns) foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }; return $false }
function Get-StringSha256 { param([string]$Text) $sha = [System.Security.Cryptography.SHA256]::Create(); try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() } }
function Get-TreeStats { param([string]$Path) $f = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue); $b = [long]0; foreach ($x in $f) { $b += $x.Length }; return @{ Files = $f.Count; Bytes = $b } }
function Test-Under { param([string]$Path, [string]$Parent) return ($Path.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar).StartsWith($Parent.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, $cmp) }

$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Root) { $Root = [string]$cfg.root }
if (-not $onWindows -and $Root -match '^[A-Za-z]:') { $Root = Join-Path $ProfileRoot 'Unykorn' }
$Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
$ProfileRoot = [System.IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\', '/')
$protected = @($cfg.protected)
$staleDays = [int]$cfg.staleDays
$rules = @($cfg.rules)
$treeNames = @($cfg.tree.PSObject.Properties | ForEach-Object { $_.Name })

$reposCsv = Join-Path $Audit 'repos.csv'; $foldersCsv = Join-Path $Audit 'folders.csv'
if (-not (Test-Path -LiteralPath $reposCsv) -or -not (Test-Path -LiteralPath $foldersCsv)) { Write-Host "repos.csv / folders.csv not found in $Audit. Run Invoke-WorkstationAudit.ps1 first." -ForegroundColor Red; exit 3 }
$repos = @(Import-Csv -LiteralPath $reposCsv -Encoding UTF8)
$folders = @(Import-Csv -LiteralPath $foldersCsv -Encoding UTF8)

# --- tree
Write-Host ("Root: {0}{1}" -f $Root, $(if ($Apply) { '' } else { '  (plan only)' })) -ForegroundColor Cyan
foreach ($n in $treeNames) {
    $p = Join-Path $Root $n
    if (-not (Test-Path -LiteralPath $p)) { if ($Apply) { [void][System.IO.Directory]::CreateDirectory($p); Write-Host "  created $n" -ForegroundColor Green } else { Write-Host "  would create $n" -ForegroundColor Gray } }
}

# --- plan
$plan = New-Object System.Collections.Generic.List[object]
$repoPaths = @()
foreach ($r in $repos) {
    $src = [string]$r.Path
    if (Test-Under $src $Root) { continue }                      # already home
    $seg = $src.Substring($ProfileRoot.Length).TrimStart('\', '/') -split '[\\/]+'
    if ($seg.Count -gt 0 -and (Test-Wild $seg[0] $protected) -and $seg[0] -notlike 'OneDrive*') { }  # repos under Documents etc. still move
    if ($seg.Count -gt 0 -and $seg[0] -like 'OneDrive*') { $plan.Add([pscustomobject]@{ Action = 'Hold'; Kind = 'repo'; Source = $src; Dest = ''; Reason = 'repository inside OneDrive: clone it fresh into 10_PLATFORMS, then remove the OneDrive copy; do not sync a .git folder'; Files = ''; Bytes = ''; LastWrite = $r.LastCommit }); continue }
    $dest = Join-Path (Join-Path $Root ([string]$cfg.repoDest)) $r.Repo
    $reason = 'git repository'
    if (-not $r.Remote) { $reason += '; NO REMOTE, push before moving' }
    if ([int]$r.DirtyFiles -gt 0) { $reason += ('; {0} uncommitted change(s)' -f $r.DirtyFiles) }
    $repoPaths += $src
    $plan.Add([pscustomobject]@{ Action = 'Move'; Kind = 'repo'; Source = $src; Dest = $dest; Reason = $reason; Files = ''; Bytes = ''; LastWrite = $r.LastCommit })
}
foreach ($f in $folders) {
    $src = [string]$f.Path
    if ($f.Protected -eq 'True' -or $f.IsOneDrive -eq 'True') { continue }
    if (Test-Under $src $Root) { continue }
    $name = [string]$f.Folder
    $matched = $null
    foreach ($rule in $rules) { if ($name -match [string]$rule.match) { $matched = $rule; break } }
    $containsRepos = @($repoPaths | Where-Object { Test-Under $_ $src }).Count
    if ($matched -and [string]$matched.dest -eq [string]$cfg.repoDest) {
        # a code container: its repos move individually; whatever is left goes to Hold for a decision
        $plan.Add([pscustomobject]@{ Action = 'Hold'; Kind = 'folder'; Source = $src; Dest = ''; Reason = ("code container with {0} repo(s) relocating individually; review the remainder after -Apply" -f $containsRepos); Files = $f.Files; Bytes = $f.Bytes; LastWrite = $f.Newest })
        continue
    }
    if ($containsRepos -gt 0) {
        $plan.Add([pscustomobject]@{ Action = 'Hold'; Kind = 'folder'; Source = $src; Dest = ''; Reason = ("contains {0} repo(s) that relocate individually; review the remainder after -Apply" -f $containsRepos); Files = $f.Files; Bytes = $f.Bytes; LastWrite = $f.Newest })
        continue
    }
    if ($matched) {
        $plan.Add([pscustomobject]@{ Action = 'Move'; Kind = 'folder'; Source = $src; Dest = (Join-Path (Join-Path $Root ([string]$matched.dest)) $name); Reason = [string]$matched.reason; Files = $f.Files; Bytes = $f.Bytes; LastWrite = $f.Newest })
        continue
    }
    $ageDays = if ($f.Newest) { ((Get-Date) - [datetime]$f.Newest).TotalDays } else { 9999 }
    if ($ageDays -gt $staleDays) {
        $plan.Add([pscustomobject]@{ Action = 'Move'; Kind = 'folder'; Source = $src; Dest = (Join-Path (Join-Path (Join-Path $Root '90_ARCHIVE') (Get-Date).ToString('yyyy-MM')) $name); Reason = ("untouched for {0:N0} days" -f $ageDays); Files = $f.Files; Bytes = $f.Bytes; LastWrite = $f.Newest })
    } else {
        $plan.Add([pscustomobject]@{ Action = 'Hold'; Kind = 'folder'; Source = $src; Dest = ''; Reason = 'no rule matched and recently active; decide by hand or add a rule to workstation.json'; Files = $f.Files; Bytes = $f.Bytes; LastWrite = $f.Newest })
    }
}
# destination collisions
$seenDest = @{}
foreach ($p in $plan) { if ($p.Action -eq 'Move') { if ($seenDest.ContainsKey($p.Dest) -or (Test-Path -LiteralPath $p.Dest)) { $p.Action = 'Hold'; $p.Reason = 'destination already exists: ' + $p.Dest }; $seenDest[$p.Dest] = $true } }

$planPath = Join-Path $Audit 'moves.csv'
$plan | Export-Csv -LiteralPath $planPath -NoTypeInformation -Encoding UTF8
$moves = @($plan | Where-Object { $_.Action -eq 'Move' }); $holds = @($plan | Where-Object { $_.Action -eq 'Hold' })
Write-Host ("Plan: {0} move(s), {1} hold(s) -> {2}" -f $moves.Count, $holds.Count, $planPath) -ForegroundColor White
foreach ($m in $moves) { Write-Host ("  MOVE  {0}  ->  {1}   [{2}]" -f $m.Source, $m.Dest, $m.Reason) -ForegroundColor Gray }
foreach ($h in $holds) { Write-Host ("  HOLD  {0}   [{1}]" -f $h.Source, $h.Reason) -ForegroundColor Yellow }
if (-not $Apply) { Write-Host "Review moves.csv, then re-run with -Apply." -ForegroundColor Cyan; exit 0 }

# --- apply
$logPath = Join-Path $Root 'layout-log.jsonl'
$prev = ('0' * 64)
if (Test-Path -LiteralPath $logPath) { $last = Get-Content -LiteralPath $logPath -Tail 1 -Encoding UTF8 -ErrorAction SilentlyContinue; if ($last) { try { $prev = [string](($last | ConvertFrom-Json).hash) } catch { } } }
function Write-Log { param([hashtable]$Event) $o = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); prev = $script:prev }; foreach ($k in ($Event.Keys | Sort-Object)) { $o[$k] = $Event[$k] }; $body = ($o | ConvertTo-Json -Compress -Depth 4); $o['hash'] = Get-StringSha256 $body; [System.IO.File]::AppendAllText($logPath, ($o | ConvertTo-Json -Compress -Depth 4) + "`n", $utf8); $script:prev = $o['hash'] }

$done = 0; $failed = 0
foreach ($m in $moves) {
    $src = $m.Source; $dst = $m.Dest
    if (-not (Test-Path -LiteralPath $src -PathType Container)) { Write-Warning "gone: $src"; continue }
    $before = Get-TreeStats $src
    try {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
        $sameVolume = ([System.IO.Path]::GetPathRoot($src) -eq [System.IO.Path]::GetPathRoot($dst))
        if ($sameVolume) {
            Move-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
        } else {
            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction Stop
            $after = Get-TreeStats $dst
            if ($after.Files -ne $before.Files -or $after.Bytes -ne $before.Bytes) { throw ("copy verification failed: {0}/{1} files, {2}/{3} bytes" -f $after.Files, $before.Files, $after.Bytes, $before.Bytes) }
            Remove-Item -LiteralPath $src -Recurse -Force
        }
        $after = Get-TreeStats $dst
        Write-Log @{ event = 'move'; kind = $m.Kind; source = $src; dest = $dst; files = $after.Files; bytes = $after.Bytes; reason = $m.Reason }
        Write-Host ("  moved {0} -> {1}  ({2} files)" -f $src, $dst, $after.Files) -ForegroundColor Green
        $done++
    } catch {
        Write-Log @{ event = 'move-failed'; kind = $m.Kind; source = $src; dest = $dst; error = $_.Exception.Message }
        Write-Warning ("FAILED {0}: {1}" -f $src, $_.Exception.Message)
        $failed++
    }
}
Write-Host ("Applied {0} move(s), {1} failed. Log: {2}" -f $done, $failed, $logPath) -ForegroundColor $(if ($failed) { 'Yellow' } else { 'Green' })
if ($failed) { exit 2 }
exit 0
