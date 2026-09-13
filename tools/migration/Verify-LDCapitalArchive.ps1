#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies an LD Capital / LDX archive produced by Migrate-LDCapitalArchive.ps1.

.DESCRIPTION
    Re-hashes every file listed in manifest.json against the bytes on the drive and validates the
    append-only chain in migration-log.jsonl (each line's prev must equal the previous line's hash, and
    each line's hash must equal SHA-256 of the line without its hash field).

    Exit codes: 0 all good, 2 drift found (missing / modified files), 5 log chain broken, 3 manifest missing.

.PARAMETER Archive
    Archive root containing manifest.json. Default: auto-detects <removable>:\LD_Capital_Complete_Archive.

.PARAMETER SkipLog
    Skip the chain-log validation.

.EXAMPLE
    .\Verify-LDCapitalArchive.ps1 -Archive "D:\LD_Capital_Complete_Archive"
#>
[CmdletBinding()]
param(
    [string]$Archive,
    [string[]]$ArchiveFolderName = @("MASTER_LD_CAPITAL_AUDIT_VAULT", "LD_Capital_Complete_Archive"),
    [switch]$SkipLog
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$onWindows = $true
if (Test-Path variable:IsWindows) { $onWindows = [bool]$IsWindows }

function Get-Sha256 {
    param([string]$LiteralPath)
    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
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
    if (-not $Archive) {
        Write-Host "No archive found on a removable volume. Pass -Archive 'E:\$($ArchiveFolderName[0])'." -ForegroundColor Red
        exit 3
    }
}

$manifestPath = Join-Path $Archive 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Host "manifest.json not found at $manifestPath" -ForegroundColor Red
    exit 3
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$files = @($manifest.files | Where-Object { $_.Status -in @('Copied', 'Moved', 'Duplicate', 'Indexed', 'Archived') })
Write-Host ("Verifying {0} archived file(s) from run {1} ({2})" -f $files.Count, $manifest.runId, $manifest.generated) -ForegroundColor White

$ok = 0; $missing = @(); $modified = @(); $unhashed = 0
$i = 0
foreach ($f in $files) {
    $i++
    Write-Progress -Activity 'Verifying archive' -Status $f.ArchivePath -PercentComplete ([int](100 * $i / [math]::Max(1, $files.Count)))
    $p = Join-Path $Archive $f.ArchivePath
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing += $f.ArchivePath; continue }
    if (-not $f.Sha256) {
        $unhashed++
        if ((Get-Item -LiteralPath $p).Length -ne [long]$f.SizeBytes) { $modified += $f.ArchivePath }
        else { $ok++ }
        continue
    }
    if ((Get-Sha256 $p) -ne $f.Sha256) { $modified += $f.ArchivePath } else { $ok++ }
}
Write-Progress -Activity 'Verifying archive' -Completed

Write-Host ("  OK        {0}" -f $ok) -ForegroundColor Green
if ($unhashed) { Write-Host ("  size-only {0} (archived with -NoHash)" -f $unhashed) -ForegroundColor Yellow }
if ($missing.Count)  { Write-Host ("  MISSING   {0}" -f $missing.Count)  -ForegroundColor Red; $missing  | ForEach-Object { Write-Host "    $_" -ForegroundColor Red } }
if ($modified.Count) { Write-Host ("  MODIFIED  {0}" -f $modified.Count) -ForegroundColor Red; $modified | ForEach-Object { Write-Host "    $_" -ForegroundColor Red } }

$chainOk = $true
if (-not $SkipLog) {
    $logPath = Join-Path $Archive 'migration-log.jsonl'
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $prev = ('0' * 64)
        $lineNo = 0
        foreach ($line in [System.IO.File]::ReadLines($logPath)) {
            $lineNo++
            if (-not $line.Trim()) { continue }
            $expectedHashField = '"hash":"'
            $idx = $line.LastIndexOf(',' + $expectedHashField)
            if ($idx -lt 0) { $chainOk = $false; Write-Host "  chain: line $lineNo has no hash field" -ForegroundColor Red; break }
            $body = $line.Substring(0, $idx) + '}'
            $declared = $line.Substring($idx + 1 + $expectedHashField.Length).TrimEnd('}', '"')
            $obj = $line | ConvertFrom-Json
            if ($obj.prev -ne $prev) { $chainOk = $false; Write-Host "  chain: line $lineNo prev mismatch" -ForegroundColor Red; break }
            if ((Get-StringSha256 $body) -ne $declared) { $chainOk = $false; Write-Host "  chain: line $lineNo hash mismatch (line altered)" -ForegroundColor Red; break }
            $prev = $declared
        }
        if ($chainOk) { Write-Host ("  chain     intact ({0} entries)" -f $lineNo) -ForegroundColor Green }
    } else {
        Write-Host "  chain     no migration-log.jsonl present" -ForegroundColor Yellow
    }
}

if (-not $chainOk) { exit 5 }
if ($missing.Count -or $modified.Count) { exit 2 }
exit 0
