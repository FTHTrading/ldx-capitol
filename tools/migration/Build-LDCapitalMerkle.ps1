#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a Merkle tree over an LD Capital / LDX archive and emits the XRPL anchor payload.

.DESCRIPTION
    Reads manifest.json (written by Migrate-LDCapitalArchive.ps1), takes every archived row that carries a
    SHA-256, and builds a deterministic Merkle tree:

        leaf  = SHA-256( 0x00 || UTF8(archive path, '/' separators) || 0x00 || SHA-256 bytes of the file )
        node  = SHA-256( 0x01 || left || right )
        leaves sorted by archive path (ordinal); an unpaired node at any level is promoted unchanged.

    Outputs (in the archive root unless -OutputDir is given):
        merkle.json          root, algorithm, every leaf with its inclusion proof
        merkle-root.txt      the root alone
        anchor-payload.json  what goes on-chain: root, collection, leaf count, manifest run id, memo hex
    and appends a hash-chained "merkle" event to migration-log.jsonl.

    Nothing about the documents themselves leaves the drive. The root is a 32-byte commitment; the proofs
    let any single file be shown to belong to the anchored set later without revealing the rest.

.PARAMETER Archive
    Archive root containing manifest.json. Default: auto-detects <removable>:\LD_Capital_Complete_Archive.

.PARAMETER Collection
    Label recorded in the anchor payload (default "LD Capital Complete Archive").

.PARAMETER VerifyProof
    Archive-relative path of one file: recompute its leaf from the bytes on disk, walk the proof in
    merkle.json, and confirm it reaches the recorded root.

.PARAMETER VerifyAll
    Re-hash every file on disk and re-derive the root; exit 2 if it differs from merkle.json.

.EXAMPLE
    .\Build-LDCapitalMerkle.ps1 -Archive "D:\LD_Capital_Complete_Archive"

.EXAMPLE
    .\Build-LDCapitalMerkle.ps1 -Archive "D:\LD_Capital_Complete_Archive" -VerifyProof "Business_Plans/misc/LDXCapitalBusinessPlan.pdf"
#>
[CmdletBinding()]
param(
    [string]$Archive,
    [string]$ArchiveFolderName = "LD_Capital_Complete_Archive",
    [string]$Collection = "LD Capital Complete Archive",
    [string]$OutputDir,
    [string]$VerifyProof,
    [switch]$VerifyAll
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$onWindows = $true
if (Test-Path variable:IsWindows) { $onWindows = [bool]$IsWindows }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$sha = [System.Security.Cryptography.SHA256]::Create()

function ConvertTo-Hex { param([byte[]]$Bytes) return ([System.BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant() }
function ConvertFrom-Hex {
    param([string]$Hex)
    $out = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $out.Length; $i++) { $out[$i] = [System.Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return ,$out
}
function Get-LeafHash {
    param([string]$Path, [string]$FileSha256)
    $p = $utf8.GetBytes($Path.Replace('\', '/'))
    $h = ConvertFrom-Hex $FileSha256
    $buf = New-Object byte[] (1 + $p.Length + 1 + $h.Length)
    $buf[0] = 0
    [System.Array]::Copy($p, 0, $buf, 1, $p.Length)
    $buf[1 + $p.Length] = 0
    [System.Array]::Copy($h, 0, $buf, 2 + $p.Length, $h.Length)
    return ,$sha.ComputeHash($buf)
}
function Get-NodeHash {
    param([byte[]]$Left, [byte[]]$Right)
    $buf = New-Object byte[] (1 + $Left.Length + $Right.Length)
    $buf[0] = 1
    [System.Array]::Copy($Left, 0, $buf, 1, $Left.Length)
    [System.Array]::Copy($Right, 0, $buf, 1 + $Left.Length, $Right.Length)
    return ,$sha.ComputeHash($buf)
}
function Get-FileSha256 { param([string]$LiteralPath) return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-StringSha256 { param([string]$Text) return ConvertTo-Hex ($sha.ComputeHash($utf8.GetBytes($Text))) }

function Build-Tree {
    # $Leaves: array of byte[] in final order. Returns @{ Root = byte[]; Proofs = array of arrays of @{hash;side} }
    param([object[]]$Leaves)
    $n = $Leaves.Count
    $proofs = New-Object 'object[]' $n
    for ($i = 0; $i -lt $n; $i++) { $proofs[$i] = New-Object System.Collections.Generic.List[object] }
    if ($n -eq 0) { return @{ Root = $sha.ComputeHash([byte[]]@()); Proofs = $proofs } }

    $level = New-Object System.Collections.Generic.List[object]
    $owners = New-Object System.Collections.Generic.List[object]   # which leaf indexes sit under each node
    for ($i = 0; $i -lt $n; $i++) { $level.Add($Leaves[$i]); $owners.Add(@($i)) }

    while ($level.Count -gt 1) {
        $next = New-Object System.Collections.Generic.List[object]
        $nextOwners = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $level.Count; $i += 2) {
            if ($i + 1 -lt $level.Count) {
                $l = $level[$i]; $r = $level[$i + 1]
                foreach ($idx in $owners[$i])     { $proofs[$idx].Add(@{ hash = (ConvertTo-Hex $r); side = 'right' }) }
                foreach ($idx in $owners[$i + 1]) { $proofs[$idx].Add(@{ hash = (ConvertTo-Hex $l); side = 'left' }) }
                $next.Add((Get-NodeHash -Left $l -Right $r))
                $nextOwners.Add(@($owners[$i]) + @($owners[$i + 1]))
            } else {
                $next.Add($level[$i])
                $nextOwners.Add($owners[$i])
            }
        }
        $level = $next
        $owners = $nextOwners
    }
    return @{ Root = $level[0]; Proofs = $proofs }
}

function Test-Proof {
    param([byte[]]$Leaf, [object[]]$Proof, [string]$RootHex)
    $cur = $Leaf
    foreach ($step in $Proof) {
        $sib = ConvertFrom-Hex ([string]$step.hash)
        if ([string]$step.side -eq 'right') { $cur = Get-NodeHash -Left $cur -Right $sib }
        else { $cur = Get-NodeHash -Left $sib -Right $cur }
    }
    return ((ConvertTo-Hex $cur) -eq $RootHex)
}

# --- chain log (same format as Migrate-LDCapitalArchive.ps1)
function Add-ChainLogEvent {
    param([string]$LogPath, [hashtable]$Event)
    $prev = ('0' * 64)
    if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
        $last = Get-Content -LiteralPath $LogPath -Tail 1 -ErrorAction SilentlyContinue
        if ($last) { try { $prev = [string](($last | ConvertFrom-Json).hash) } catch { } }
    }
    $ordered = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); prev = $prev }
    foreach ($k in ($Event.Keys | Sort-Object)) { $ordered[$k] = $Event[$k] }
    $body = ($ordered | ConvertTo-Json -Compress -Depth 4)
    $ordered['hash'] = Get-StringSha256 $body
    [System.IO.File]::AppendAllText($LogPath, ($ordered | ConvertTo-Json -Compress -Depth 4) + "`n", $utf8)
}

# --- locate archive
if (-not $Archive) {
    if ($onWindows) {
        $removable = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2" -ErrorAction SilentlyContinue)
        foreach ($ld in $removable) {
            $cand = Join-Path ($ld.DeviceID + '\') $ArchiveFolderName
            if (Test-Path -LiteralPath (Join-Path $cand 'manifest.json')) { $Archive = $cand; break }
        }
    }
    if (-not $Archive) { Write-Host "No archive found on a removable volume. Pass -Archive 'E:\$ArchiveFolderName'." -ForegroundColor Red; exit 3 }
}
$Archive = [System.IO.Path]::GetFullPath($Archive)
if (-not $OutputDir) { $OutputDir = $Archive }
[void][System.IO.Directory]::CreateDirectory($OutputDir)
$manifestPath = Join-Path $Archive 'manifest.json'
$merklePath   = Join-Path $OutputDir 'merkle.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Write-Host "manifest.json not found at $manifestPath" -ForegroundColor Red; exit 3 }

# --- verify modes
if ($VerifyProof -or $VerifyAll) {
    if (-not (Test-Path -LiteralPath $merklePath -PathType Leaf)) { Write-Host "merkle.json not found at $merklePath; build first." -ForegroundColor Red; exit 3 }
    $m = Get-Content -LiteralPath $merklePath -Raw | ConvertFrom-Json
    if ($VerifyProof) {
        $key = $VerifyProof.Replace('\', '/')
        $entry = @($m.leaves | Where-Object { $_.path -eq $key })
        if ($entry.Count -ne 1) { Write-Host "Path not in merkle.json: $key" -ForegroundColor Red; exit 2 }
        $entry = $entry[0]
        $disk = Join-Path $Archive $key
        if (-not (Test-Path -LiteralPath $disk -PathType Leaf)) { Write-Host "File missing on disk: $disk" -ForegroundColor Red; exit 2 }
        $fileHash = Get-FileSha256 $disk
        $leaf = Get-LeafHash -Path $key -FileSha256 $fileHash
        $ok = Test-Proof -Leaf $leaf -Proof @($entry.proof) -RootHex ([string]$m.root)
        Write-Host ("file sha256 : {0}" -f $fileHash)
        Write-Host ("leaf        : {0}{1}" -f (ConvertTo-Hex $leaf), $(if ((ConvertTo-Hex $leaf) -eq $entry.leaf) { '' } else { '  (differs from merkle.json)' }))
        Write-Host ("root        : {0}" -f $m.root)
        if ($ok) { Write-Host "PROOF OK  -  $key is a member of the anchored set" -ForegroundColor Green; exit 0 }
        Write-Host "PROOF FAILED  -  file bytes or proof do not match the anchored root" -ForegroundColor Red; exit 2
    }
    $leaves = @()
    $bad = 0
    $i = 0
    foreach ($e in @($m.leaves)) {
        $i++
        Write-Progress -Activity 'Re-hashing archive' -Status $e.path -PercentComplete ([int](100 * $i / [math]::Max(1, @($m.leaves).Count)))
        $disk = Join-Path $Archive ([string]$e.path)
        if (-not (Test-Path -LiteralPath $disk -PathType Leaf)) { Write-Host "MISSING  $($e.path)" -ForegroundColor Red; $bad++; $leaves += ,(ConvertFrom-Hex ([string]$e.leaf)); continue }
        $h = Get-FileSha256 $disk
        if ($h -ne $e.sha256) { Write-Host "MODIFIED $($e.path)" -ForegroundColor Red; $bad++ }
        $leaves += ,(Get-LeafHash -Path ([string]$e.path) -FileSha256 $h)
    }
    Write-Progress -Activity 'Re-hashing archive' -Completed
    $tree = Build-Tree -Leaves $leaves
    $root = ConvertTo-Hex $tree.Root
    Write-Host ("recorded root : {0}" -f $m.root)
    Write-Host ("recomputed    : {0}" -f $root)
    if ($bad -eq 0 -and $root -eq $m.root) { Write-Host ("ROOT OK  -  {0} file(s) match the anchored set" -f @($m.leaves).Count) -ForegroundColor Green; exit 0 }
    Write-Host "ROOT MISMATCH" -ForegroundColor Red; exit 2
}

# --- build
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$rows = @($manifest.files | Where-Object { $_.Status -in @('Copied', 'Moved', 'Duplicate', 'Archived') -and $_.Sha256 })
$byPath = @{}
foreach ($r in $rows) {
    $key = ([string]$r.ArchivePath).Replace('\', '/')
    if ($byPath.ContainsKey($key)) { continue }
    $byPath[$key] = [string]$r.Sha256
}
$paths = [string[]]@($byPath.Keys)
[System.Array]::Sort($paths, [System.StringComparer]::Ordinal)

Write-Host ("Building Merkle tree over {0} archived file(s) from run {1}" -f $paths.Count, $manifest.runId) -ForegroundColor White
$leafBytes = @()
foreach ($p in $paths) { $leafBytes += ,(Get-LeafHash -Path $p -FileSha256 $byPath[$p]) }
$tree = Build-Tree -Leaves $leafBytes
$rootHex = ConvertTo-Hex $tree.Root
$now = (Get-Date).ToUniversalTime()

$leafRecords = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $paths.Count; $i++) {
    $proof = @()
    foreach ($step in $tree.Proofs[$i]) { $proof += [pscustomobject]@{ hash = $step.hash; side = $step.side } }
    $leafRecords.Add([pscustomobject]@{
        path   = $paths[$i]
        sha256 = $byPath[$paths[$i]]
        leaf   = ConvertTo-Hex $leafBytes[$i]
        proof  = $proof
    })
}

$manifestSha = Get-FileSha256 $manifestPath
$merkle = [ordered]@{
    schema          = 'ldx-archive-merkle/1'
    algorithm       = 'sha256; leaf=H(0x00||path||0x00||fileSha256); node=H(0x01||L||R); ordinal path order; odd node promoted'
    collection      = $Collection
    generated       = $now.ToString('o')
    manifestRunId   = [string]$manifest.runId
    manifestSha256  = $manifestSha
    leafCount       = $paths.Count
    root            = $rootHex
    leaves          = $leafRecords
}
[System.IO.File]::WriteAllText($merklePath, ($merkle | ConvertTo-Json -Depth 8), $utf8)
[System.IO.File]::WriteAllText((Join-Path $OutputDir 'merkle-root.txt'), $rootHex + "`n", $utf8)

# anchor payload: compact JSON that rides in an XRPL memo (MemoData), plus the hex forms xrpl.js expects
$memoObj = [ordered]@{
    v    = 1
    kind = 'ldx-archive-anchor'
    root = $rootHex
    n    = $paths.Count
    run  = [string]$manifest.runId
    col  = $Collection
    ts   = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$memoJson = ($memoObj | ConvertTo-Json -Compress)
$memoBytes = $utf8.GetBytes($memoJson)
if ($memoBytes.Length -gt 1000) { Write-Host "Memo payload is $($memoBytes.Length) bytes; XRPL memos are capped at 1 KB. Shorten -Collection." -ForegroundColor Red; exit 4 }
$anchor = [ordered]@{
    schema      = 'ldx-anchor/1'
    collection  = $Collection
    merkleRoot  = $rootHex
    leafCount   = $paths.Count
    manifestRunId = [string]$manifest.runId
    manifestSha256 = $manifestSha
    generated   = $now.ToString('o')
    memo        = [ordered]@{
        json       = $memoJson
        MemoType   = (ConvertTo-Hex ($utf8.GetBytes('ldx/archive-anchor/v1'))).ToUpperInvariant()
        MemoFormat = (ConvertTo-Hex ($utf8.GetBytes('application/json'))).ToUpperInvariant()
        MemoData   = (ConvertTo-Hex $memoBytes).ToUpperInvariant()
    }
}
[System.IO.File]::WriteAllText((Join-Path $OutputDir 'anchor-payload.json'), ($anchor | ConvertTo-Json -Depth 4), $utf8)

$logPath = Join-Path $Archive 'migration-log.jsonl'
Add-ChainLogEvent -LogPath $logPath -Event @{ event = 'merkle'; root = $rootHex; leafCount = $paths.Count; manifestRunId = [string]$manifest.runId; manifestSha256 = $manifestSha; collection = $Collection }

Write-Host ("root        : {0}" -f $rootHex) -ForegroundColor Green
Write-Host ("leaves      : {0}" -f $paths.Count)
Write-Host ("merkle.json : {0}" -f $merklePath) -ForegroundColor Cyan
Write-Host ("anchor      : {0}" -f (Join-Path $OutputDir 'anchor-payload.json')) -ForegroundColor Cyan
Write-Host "Next: node tools/migration/anchor/xrpl-anchor.mjs submit --payload <anchor-payload.json> --network testnet" -ForegroundColor Gray
exit 0
