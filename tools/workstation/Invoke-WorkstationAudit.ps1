#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only inventory of the workstation: folders, git repositories, largest files, duplicates, reclaimable
    build output, OneDrive state and installed tooling. The "what is on this machine" step before any reorg.

.DESCRIPTION
    Writes <Output>\WORKSTATION_AUDIT.md plus folders.csv, repos.csv, largest.csv, duplicates.csv, tools.csv,
    onedrive.csv. Touches nothing else. Safe to run any time.

.PARAMETER ProfileRoot
    Default: the user profile.

.PARAMETER Output
    Default: <ProfileRoot>\WORKSTATION_AUDIT.

.PARAMETER MinDupBytes
    Files smaller than this are not considered for duplicate detection (default 5 MB).

.PARAMETER SkipHash
    Skip duplicate detection (fastest run).

.EXAMPLE
    .\Invoke-WorkstationAudit.ps1
#>
[CmdletBinding()]
param(
    [string]$ProfileRoot = $(if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }),
    [string]$Output,
    [string]$Config = (Join-Path $PSScriptRoot 'workstation.json'),
    [long]$MinDupBytes = 5MB,
    [int]$RepoDepth = 4,
    [switch]$SkipHash,
    [switch]$NoProgress
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($NoProgress -or $Host.Name -notmatch 'ConsoleHost|Visual Studio Code Host' -or -not [Environment]::UserInteractive) { $ProgressPreference = 'SilentlyContinue' }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$onWindows = $true; if (Test-Path variable:IsWindows) { $onWindows = [bool]$IsWindows }

function Format-Bytes { param([long]$Bytes) if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }; if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }; if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }; return "$Bytes B" }
function Test-Wild { param([string]$Name, [string[]]$Patterns) foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }; return $false }
function Get-Sha256 { param([string]$LiteralPath) return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant() }
function ConvertTo-MdCell { param([string]$s) return ([string]$s).Replace('|', '\|') }

$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
$protected = @($cfg.protected)
$reclaimNames = @($cfg.reclaimable)
$ProfileRoot = [System.IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\', '/')
if (-not $Output) { $Output = Join-Path $ProfileRoot 'WORKSTATION_AUDIT' }
[void][System.IO.Directory]::CreateDirectory($Output)
$stamp = (Get-Date).ToUniversalTime()
Write-Host "Auditing $ProfileRoot -> $Output" -ForegroundColor Cyan

# ---------------------------------------------------------------- folders
$topDirs = @(Get-ChildItem -LiteralPath $ProfileRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not (Test-Wild $_.Name @('AppData', 'Application Data', '.*', 'WORKSTATION_AUDIT*')) })
$allFiles = New-Object System.Collections.Generic.List[object]
$folderRows = @()
$i = 0
foreach ($d in $topDirs) {
    $i++
    Write-Progress -Activity 'Scanning folders' -Status $d.Name -PercentComplete ([int](100 * $i / [math]::Max(1, $topDirs.Count)))
    $files = @(Get-ChildItem -LiteralPath $d.FullName -File -Recurse -Force -ErrorAction SilentlyContinue)
    $bytes = [long]0; $reclaim = [long]0; $newest = [datetime]::MinValue; $cloudOnly = 0
    foreach ($f in $files) {
        $bytes += $f.Length
        if ($f.LastWriteTimeUtc -gt $newest) { $newest = $f.LastWriteTimeUtc }
        $rel = $f.FullName.Substring($d.FullName.Length)
        foreach ($seg in ($rel -split '[\\/]+')) { if ($reclaimNames -contains $seg) { $reclaim += $f.Length; break } }
        if ($onWindows -and ((([int]$f.Attributes) -band 0x400000) -ne 0)) { $cloudOnly++ }
        $allFiles.Add($f)
    }
    $folderRows += [pscustomobject]@{
        Folder = $d.Name; Path = $d.FullName; Files = $files.Count; Bytes = $bytes; Size = (Format-Bytes $bytes)
        ReclaimableBytes = $reclaim; Reclaimable = (Format-Bytes $reclaim); CloudOnlyFiles = $cloudOnly
        Newest = $(if ($newest -ne [datetime]::MinValue) { $newest.ToString('yyyy-MM-dd') } else { '' })
        Protected = (Test-Wild $d.Name $protected)
        IsOneDrive = ($d.Name -like 'OneDrive*')
    }
}
Write-Progress -Activity 'Scanning folders' -Completed
$folderRows = @($folderRows | Sort-Object Bytes -Descending)
$folderRows | Export-Csv -LiteralPath (Join-Path $Output 'folders.csv') -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------- repos
$gitOk = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
$repoRows = @()
$gitDirs = @(Get-ChildItem -LiteralPath $ProfileRoot -Directory -Recurse -Depth $RepoDepth -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq '.git' -and $_.FullName -notmatch '[\\/](AppData|node_modules)[\\/]' })
foreach ($g in $gitDirs) {
    $repo = $g.Parent.FullName
    $remote = ''; $branch = ''; $dirty = ''; $last = ''; $subject = ''
    if ($gitOk) {
        try { $remote = (& git -C $repo remote get-url origin 2>$null | Select-Object -First 1) } catch { }
        try { $branch = (& git -C $repo rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1) } catch { }
        try { $dirty = @(& git -C $repo status --porcelain 2>$null).Count } catch { }
        try { $last = (& git -C $repo log -1 --format=%cI 2>$null | Select-Object -First 1) } catch { }
        try { $subject = (& git -C $repo log -1 --format=%s 2>$null | Select-Object -First 1) } catch { }
    }
    $repoRows += [pscustomobject]@{
        Repo = $g.Parent.Name; Path = $repo; Remote = [string]$remote; Branch = [string]$branch
        DirtyFiles = $dirty; LastCommit = $(if ($last) { ([string]$last).Substring(0, 10) } else { '' }); LastSubject = [string]$subject
        NoRemote = (-not $remote)
    }
}
$repoRows = @($repoRows | Sort-Object Path)
$repoRows | Export-Csv -LiteralPath (Join-Path $Output 'repos.csv') -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------- largest files
$largest = @($allFiles | Sort-Object Length -Descending | Select-Object -First 60 | ForEach-Object {
    [pscustomobject]@{ Size = (Format-Bytes $_.Length); Bytes = $_.Length; LastWrite = $_.LastWriteTimeUtc.ToString('yyyy-MM-dd'); Path = $_.FullName } })
$largest | Export-Csv -LiteralPath (Join-Path $Output 'largest.csv') -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------- duplicates (size bucket, then hash)
$dupRows = @(); $dupWasted = [long]0
if (-not $SkipHash) {
    $bySize = @($allFiles | Where-Object {
            $_.Length -ge $MinDupBytes -and
            $_.FullName -notmatch '[\\/](\.git|node_modules|target|\.venv|venv|dist|build|\.cache|__pycache__)[\\/]' -and
            -not ($onWindows -and ((([int]$_.Attributes) -band 0x400000) -ne 0)) } |
        Group-Object Length | Where-Object { $_.Count -gt 1 })
    $n = 0
    foreach ($grp in $bySize) {
        $n++
        Write-Progress -Activity 'Hashing size collisions' -Status ("{0} of {1}" -f $n, $bySize.Count) -PercentComplete ([int](100 * $n / [math]::Max(1, $bySize.Count)))
        $byHash = @{}
        foreach ($f in $grp.Group) {
            try { $h = Get-Sha256 $f.FullName } catch { continue }
            if (-not $byHash.ContainsKey($h)) { $byHash[$h] = @() }
            $byHash[$h] += $f
        }
        foreach ($h in $byHash.Keys) {
            $set = @($byHash[$h])
            if ($set.Count -lt 2) { continue }
            $dupWasted += ($set.Count - 1) * $set[0].Length
            $k = 0
            foreach ($f in ($set | Sort-Object LastWriteTimeUtc)) { $k++; $dupRows += [pscustomobject]@{ Sha256 = $h; Copy = $k; Of = $set.Count; Size = (Format-Bytes $f.Length); Bytes = $f.Length; LastWrite = $f.LastWriteTimeUtc.ToString('yyyy-MM-dd'); Path = $f.FullName } }
        }
    }
    Write-Progress -Activity 'Hashing size collisions' -Completed
}
$dupRows | Export-Csv -LiteralPath (Join-Path $Output 'duplicates.csv') -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------- tools
$toolChecks = @(
    @{ Name = 'git';      Args = '--version' }, @{ Name = 'node';   Args = '--version' }, @{ Name = 'npm';    Args = '--version' },
    @{ Name = 'pnpm';     Args = '--version' }, @{ Name = 'python'; Args = '--version' }, @{ Name = 'py';     Args = '--version' },
    @{ Name = 'rustc';    Args = '--version' }, @{ Name = 'cargo';  Args = '--version' }, @{ Name = 'wrangler'; Args = '--version' },
    @{ Name = 'docker';   Args = '--version' }, @{ Name = 'ollama'; Args = '--version' }, @{ Name = 'pwsh';   Args = '--version' },
    @{ Name = 'code';     Args = '--version' }, @{ Name = 'gh';     Args = '--version' }, @{ Name = 'az';     Args = 'version' },
    @{ Name = 'gcloud';   Args = '--version' }, @{ Name = 'forge';  Args = '--version' }, @{ Name = 'solc';   Args = '--version' }
)
$toolRows = foreach ($t in $toolChecks) {
    $cmd = Get-Command $t.Name -ErrorAction SilentlyContinue
    $ver = ''
    if ($cmd) { try { $ver = (& $t.Name $t.Args 2>&1 | Select-Object -First 1) } catch { $ver = 'present' } }
    [pscustomobject]@{ Tool = $t.Name; Installed = [bool]$cmd; Version = ([string]$ver).Trim(); Path = $(if ($cmd) { $cmd.Source } else { '' }) }
}
@($toolRows) | Export-Csv -LiteralPath (Join-Path $Output 'tools.csv') -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------- OneDrive
$odRows = @($folderRows | Where-Object { $_.IsOneDrive } | ForEach-Object { [pscustomobject]@{ Folder = $_.Folder; Files = $_.Files; Size = $_.Size; CloudOnlyFiles = $_.CloudOnlyFiles; LocalFiles = ($_.Files - $_.CloudOnlyFiles); Path = $_.Path } })
$odRows | Export-Csv -LiteralPath (Join-Path $Output 'onedrive.csv') -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------- report
$totalBytes = [long]0; $totalReclaim = [long]0; $totalFiles = 0
foreach ($r in $folderRows) { $totalBytes += $r.Bytes; $totalReclaim += $r.ReclaimableBytes; $totalFiles += $r.Files }
$sb = New-Object System.Text.StringBuilder
$L = { param($t) [void]$sb.AppendLine($t) }
& $L "# Workstation audit"
& $L ""
& $L ("Profile `{0}`  ·  {1} UTC  ·  host {2}" -f $ProfileRoot, $stamp.ToString('yyyy-MM-dd HH:mm'), [System.Environment]::MachineName)
& $L ""
& $L ("- Files under profile (AppData excluded): {0:N0} in {1} top-level folders, {2}" -f $totalFiles, $folderRows.Count, (Format-Bytes $totalBytes))
& $L ("- Reclaimable build output (node_modules, target, dist, venv, caches): {0}" -f (Format-Bytes $totalReclaim))
& $L ("- Git repositories: {0}  ·  without a remote: {1}  ·  with uncommitted changes: {2}" -f $repoRows.Count, @($repoRows | Where-Object { $_.NoRemote }).Count, @($repoRows | Where-Object { $_.DirtyFiles -gt 0 }).Count)
if (-not $SkipHash) { & $L ("- Duplicate files >= {0}: {1} copies in {2} sets, {3} wasted" -f (Format-Bytes $MinDupBytes), $dupRows.Count, @($dupRows | Group-Object Sha256).Count, (Format-Bytes $dupWasted)) }
& $L ""
& $L "## Top-level folders"
& $L ""
& $L "| Folder | Files | Size | Reclaimable | Newest | Cloud-only | Protected |"
& $L "|---|---:|---:|---:|---|---:|---|"
foreach ($r in $folderRows) { & $L ("| {0} | {1:N0} | {2} | {3} | {4} | {5} | {6} |" -f (ConvertTo-MdCell $r.Folder), $r.Files, $r.Size, $r.Reclaimable, $r.Newest, $r.CloudOnlyFiles, $(if ($r.Protected) { 'yes' } else { '' })) }
& $L ""
& $L "## Git repositories"
& $L ""
& $L "| Repo | Branch | Dirty | Last commit | Remote | Path |"
& $L "|---|---|---:|---|---|---|"
foreach ($r in $repoRows) { & $L ("| {0} | {1} | {2} | {3} | {4} | {5} |" -f (ConvertTo-MdCell $r.Repo), $r.Branch, $r.DirtyFiles, $r.LastCommit, (ConvertTo-MdCell $r.Remote), (ConvertTo-MdCell $r.Path)) }
& $L ""
& $L "Repositories with no remote are one disk failure from gone. Push them before anything else."
& $L ""
& $L "## Largest files (top 25)"
& $L ""
& $L "| Size | Last write | Path |"
& $L "|---:|---|---|"
foreach ($r in ($largest | Select-Object -First 25)) { & $L ("| {0} | {1} | {2} |" -f $r.Size, $r.LastWrite, (ConvertTo-MdCell $r.Path)) }
& $L ""
if (-not $SkipHash) {
    & $L "## Duplicate sets (largest first)"
    & $L ""
    & $L "| Size | Copies | Oldest copy | Newest copy |"
    & $L "|---:|---:|---|---|"
    foreach ($g in (@($dupRows | Group-Object Sha256) | Sort-Object { [long]$_.Group[0].Bytes } -Descending | Select-Object -First 30)) {
        $set = @($g.Group | Sort-Object LastWrite)
        & $L ("| {0} | {1} | {2} | {3} |" -f $set[0].Size, $set.Count, (ConvertTo-MdCell $set[0].Path), (ConvertTo-MdCell $set[-1].Path))
    }
    & $L ""
}
& $L "## Tooling"
& $L ""
& $L "| Tool | Installed | Version |"
& $L "|---|---|---|"
foreach ($r in $toolRows) { & $L ("| {0} | {1} | {2} |" -f $r.Tool, $(if ($r.Installed) { 'yes' } else { 'no' }), (ConvertTo-MdCell $r.Version)) }
& $L ""
& $L "## OneDrive"
& $L ""
if ($odRows.Count) {
    & $L "| Folder | Files | Size | Local | Cloud-only |"
    & $L "|---|---:|---:|---:|---:|"
    foreach ($r in $odRows) { & $L ("| {0} | {1:N0} | {2} | {3:N0} | {4:N0} |" -f (ConvertTo-MdCell $r.Folder), $r.Files, $r.Size, $r.LocalFiles, $r.CloudOnlyFiles) }
} else { & $L "_No OneDrive folders under the profile._" }
& $L ""
& $L "CSV detail: folders.csv, repos.csv, largest.csv, duplicates.csv, tools.csv, onedrive.csv. Next: Invoke-WorkstationLayout.ps1 -Audit `"$Output`" to plan the moves."
[System.IO.File]::WriteAllText((Join-Path $Output 'WORKSTATION_AUDIT.md'), $sb.ToString(), $utf8)
Write-Host ("Audit written: {0}" -f (Join-Path $Output 'WORKSTATION_AUDIT.md')) -ForegroundColor Green
Write-Host ("  {0} folders, {1} repos, {2} reclaimable, {3} duplicate copies" -f $folderRows.Count, $repoRows.Count, (Format-Bytes $totalReclaim), $dupRows.Count)
exit 0
