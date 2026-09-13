#Requires -Version 5.1
<#
.SYNOPSIS
    Makes a byte-verified second copy of an LD Capital / LDX archive, tree preserved exactly.

.DESCRIPTION
    Copies every file listed in the archive's manifest.json (plus the control files: manifests, SHA256SUMS,
    README, chain log, merkle and anchor records) to -Mirror, keeping the same relative paths. Each copy is
    re-hashed and compared with the manifest SHA-256; a mismatch is deleted and reported. Re-runs skip files
    whose mirror copy already matches. Writes mirror-receipt.json in the mirror root.

    Use it for the second copy that makes a USB stick survivable: a OneDrive / Drive sync folder, a NAS share,
    or a second removable drive.

.PARAMETER Archive
    Archive root containing manifest.json. Default: auto-detect on a removable volume.

.PARAMETER Mirror
    Destination root (created if missing). Must not be inside -Archive.

.PARAMETER DryRun
    List what would be copied; write nothing.

.EXAMPLE
    .\Mirror-LDCapitalArchive.ps1 -Archive "D:\MASTER_LD_CAPITAL_AUDIT_VAULT" -Mirror "C:\Users\Kevan\OneDrive - FTH Trading\MASTER_LD_CAPITAL_AUDIT_VAULT"
#>
[CmdletBinding()]
param(
    [string]$Archive,
    [string[]]$ArchiveFolderName = @("MASTER_LD_CAPITAL_AUDIT_VAULT", "LD_Capital_Complete_Archive"),
    [Parameter(Mandatory = $true)][string]$Mirror,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$onWindows = $true
if (Test-Path variable:IsWindows) { $onWindows = [bool]$IsWindows }
$cmp = if ($onWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$controlFiles = @('manifest.txt', 'manifest.csv', 'manifest.json', 'SHA256SUMS.txt', 'README.txt', 'README.md', 'INDEX.html',
                  'migration-log.jsonl', 'merkle.json', 'merkle-root.txt', 'anchor-payload.json', 'anchor-receipt.json')

function Get-Sha256 { param([string]$LiteralPath) return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant() }
function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

if (-not $Archive) {
    if ($onWindows) {
        $removable = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2" -ErrorAction SilentlyContinue)
        foreach ($ld in $removable) {
            foreach ($name in $ArchiveFolderName) {
                $cand = Join-Path ($ld.DeviceID + '\') $name
                if (Test-Path -LiteralPath (Join-Path $cand 'manifest.json')) { $Archive = $cand; break }
            }
            if ($Archive) { break }
        }
    }
    if (-not $Archive) { Write-Host "No archive found on a removable volume. Pass -Archive." -ForegroundColor Red; exit 3 }
}
$Archive = [System.IO.Path]::GetFullPath($Archive).TrimEnd('\', '/')
$Mirror  = [System.IO.Path]::GetFullPath($Mirror).TrimEnd('\', '/')
if (($Mirror + [System.IO.Path]::DirectorySeparatorChar).StartsWith($Archive + [System.IO.Path]::DirectorySeparatorChar, $cmp)) {
    Write-Host "Mirror must not be inside the archive." -ForegroundColor Red; exit 4
}
$manifestPath = Join-Path $Archive 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Host "manifest.json not found at $manifestPath. Run Migrate-LDCapitalArchive.ps1 -IndexOnly -Destination '$Archive' first." -ForegroundColor Red; exit 3
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$files = @($manifest.files | Where-Object { $_.Status -in @('Copied', 'Moved', 'Duplicate', 'Indexed', 'Archived') })

# work list: manifest rows (with expected hash) + control files present at the archive root (hashed on the fly)
$work = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $work.Add([pscustomobject]@{ Rel = [string]$f.ArchivePath; Expected = [string]$f.Sha256; Size = [long]$f.SizeBytes })
}
$listed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($w in $work) { [void]$listed.Add($w.Rel.Replace('\\', '/')) }
foreach ($c in $controlFiles) {
    $p = Join-Path $Archive $c
    if ($listed.Contains($c)) { continue }
    if (Test-Path -LiteralPath $p -PathType Leaf) { $work.Add([pscustomobject]@{ Rel = $c; Expected = ''; Size = (Get-Item -LiteralPath $p).Length }) }
}
$totalBytes = [long]0; foreach ($w in $work) { $totalBytes += $w.Size }
Write-Host ("Mirroring {0} file(s), {1}  {2}  ->  {3}{4}" -f $work.Count, (Format-Bytes $totalBytes), $Archive, $Mirror, $(if ($DryRun) { '  (dry-run)' } else { '' })) -ForegroundColor White

if (-not $DryRun) {
    [void][System.IO.Directory]::CreateDirectory($Mirror)
    try {
        $free = [long](New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($Mirror))).AvailableFreeSpace
        if ($free -lt [long]($totalBytes * 1.02)) { Write-Host ("Insufficient space at mirror: need {0}, free {1}" -f (Format-Bytes $totalBytes), (Format-Bytes $free)) -ForegroundColor Red; exit 4 }
    } catch { Write-Verbose "Free-space check skipped: $($_.Exception.Message)" }
}

$copied = 0; $skipped = 0; $missing = @(); $failed = @(); $i = 0
foreach ($w in $work) {
    $i++
    Write-Progress -Activity 'Mirroring' -Status $w.Rel -PercentComplete ([int](100 * $i / [math]::Max(1, $work.Count)))
    $src = Join-Path $Archive $w.Rel
    $dst = Join-Path $Mirror  $w.Rel
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { $missing += $w.Rel; continue }
    $expected = if ($w.Expected) { $w.Expected } else { Get-Sha256 $src }
    if ((Test-Path -LiteralPath $dst -PathType Leaf) -and ((Get-Sha256 $dst) -eq $expected)) { $skipped++; continue }
    if ($DryRun) { Write-Host ("  would copy  {0}" -f $w.Rel); $copied++; continue }
    try {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $got = Get-Sha256 $dst
        if ($got -ne $expected) {
            Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
            throw "hash mismatch after copy"
        }
        try { (Get-Item -LiteralPath $dst).LastWriteTimeUtc = (Get-Item -LiteralPath $src).LastWriteTimeUtc } catch { }
        $copied++
    } catch {
        $failed += ("{0}: {1}" -f $w.Rel, $_.Exception.Message)
    }
}
Write-Progress -Activity 'Mirroring' -Completed

Write-Host ("  copied    {0}" -f $copied) -ForegroundColor Green
Write-Host ("  unchanged {0}" -f $skipped) -ForegroundColor Green
if ($missing.Count) { Write-Host ("  MISSING at source {0}" -f $missing.Count) -ForegroundColor Red; $missing | ForEach-Object { Write-Host "    $_" -ForegroundColor Red } }
if ($failed.Count)  { Write-Host ("  FAILED {0}" -f $failed.Count) -ForegroundColor Red; $failed | ForEach-Object { Write-Host "    $_" -ForegroundColor Red } }

if (-not $DryRun) {
    $receipt = [ordered]@{
        schema = 'ldx-mirror-receipt/1'
        archive = $Archive
        mirror = $Mirror
        manifestRunId = [string]$manifest.runId
        manifestSha256 = (Get-Sha256 $manifestPath)
        files = $work.Count
        copied = $copied
        unchanged = $skipped
        missing = $missing
        failed = $failed
        completed = (Get-Date).ToUniversalTime().ToString('o')
        host = [System.Environment]::MachineName
    }
    [System.IO.File]::WriteAllText((Join-Path $Mirror 'mirror-receipt.json'), ($receipt | ConvertTo-Json -Depth 4), $utf8)
    Write-Host ("receipt   : {0}" -f (Join-Path $Mirror 'mirror-receipt.json')) -ForegroundColor Cyan
    Write-Host ("Verify the mirror any time with: Verify-LDCapitalArchive.ps1 -Archive '{0}'" -f $Mirror) -ForegroundColor Gray
}
if ($missing.Count -or $failed.Count) { exit 2 }
exit 0
