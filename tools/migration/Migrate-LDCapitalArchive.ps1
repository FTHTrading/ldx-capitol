#Requires -Version 5.1
<#
.SYNOPSIS
    Consolidates every LD Capital / LDX asset into one hash-verified archive on removable media (SanDisk).

.DESCRIPTION
    Sweeps the OneDrive download tree (including _QUARANTINE_LD, _INTERNAL_ARCHIVE and sravan1), any local
    LDX repositories, and any explicit repo paths, then copies (or moves) every in-scope file into

        <SanDisk>:\LD_Capital_Complete_Archive\<Category>\<original sub-path>\<file>

    Categories: Business_Plans, Operating_Manuals, Data_Room, Decks, Legal_and_RegD, SmartContracts,
    FinancialModels, Media, Architecture_Docs, Archives, Documents, Repos, Other.

    Every file is SHA-256 hashed at the source and re-hashed at the destination before it is counted as
    archived. In -Mode Move the source is deleted only after that verification passes. Re-running is
    idempotent: an identical file already in the archive is skipped, a same-named different file is stored
    with a short hash suffix.

    Outputs written to the archive root:
        manifest.txt         human-readable manifest (date, size, SHA-256, category, archive path, source path)
        manifest.csv         same rows, machine-readable
        manifest.json        same rows plus run metadata (input to Verify-LDCapitalArchive.ps1)
        SHA256SUMS.txt       sha256sum-compatible digest list for the whole archive
        README.txt           layout and provenance notes for whoever opens the drive later
        migration-log.jsonl  append-only, hash-chained run log (one line per file event, never rewritten)

.PARAMETER SourcePath
    Root folders to sweep. Default: the OneDrive 11-Downloads tree.

.PARAMETER IncludeFolder
    Folder names whose entire contents are in-scope regardless of file name (default: _QUARANTINE_LD,
    _INTERNAL_ARCHIVE, sravan1).

.PARAMETER Pattern
    Case-insensitive regexes matched against file names and path segments to decide scope.

.PARAMETER Priority
    Regexes for must-have assets. Each is added to the scope match, and the manifest header reports FOUND or
    MISSING for every entry so a gap in the archive is visible before the drive leaves the desk.

.PARAMETER RepoRoot
    Folders scanned (3 levels deep) for git repositories that look like LDX repositories.

.PARAMETER Repo
    Explicit repository paths to archive (skips the discovery heuristics).

.PARAMETER RepoFullCopy
    Archive whole repository trees (minus -ExcludeDir) instead of only markdown / docs / office files.

.PARAMETER Destination
    Archive root. Default: auto-detected SanDisk (or any USB removable volume) + "\LD_Capital_Complete_Archive".

.PARAMETER Mode
    Copy (default) leaves sources in place. Move deletes each source only after hash verification.

.PARAMETER SkipCloudOnly
    Skip OneDrive placeholders that are not hydrated locally instead of triggering a download.

.PARAMETER NoHash
    Skip SHA-256 (size + timestamp verification only). Not recommended for Move.

.PARAMETER Preset
    MachineSweep: sweep the whole user profile (Desktop, Documents, Downloads, every OneDrive folder, dev/source/
    repos and client folders) instead of the default download tree, with AppData and package caches excluded, and
    land the result under <Destination>\09_MACHINE_ONE_SWEEP_<stamp>\<Category>\... . Combine with -CaseFile to
    add the case search terms to the scope patterns. Copy mode only; nothing is deleted.

.PARAMETER CaseFile
    Optional case.json (see case\README.md). Its searchTerms are added, escaped, to -Pattern.

.PARAMETER IndexOnly
    Adopt an existing archive in place: no sources are read or copied. Every file already under -Destination
    is hashed and recorded (Status "Indexed", Category = its top-level folder) so manifest.json, SHA256SUMS.txt
    and the chain log describe the tree exactly as it is. Use this on a vault assembled by other means before
    running Verify-, Build-LDCapitalMerkle- and Mirror-LDCapitalArchive.ps1.

.PARAMETER DryRun
    Enumerate, classify and write the manifest to a temp folder; the destination is never touched.

.EXAMPLE
    .\Migrate-LDCapitalArchive.ps1 -DryRun

.EXAMPLE
    .\Migrate-LDCapitalArchive.ps1 -Destination "E:\LD_Capital_Complete_Archive" -Repo "C:\Users\Kevan\source\ldx-capitol"

.EXAMPLE
    .\Migrate-LDCapitalArchive.ps1 -Mode Move -RepoFullCopy

.EXAMPLE
    .\Migrate-LDCapitalArchive.ps1 -Destination "D:\MASTER_LD_CAPITAL_AUDIT_VAULT" -IndexOnly
#>
[CmdletBinding()]
param(
    [string[]]$SourcePath = @("C:\Users\Kevan\OneDrive - FTH Trading\11-Downloads"),

    [string[]]$IncludeFolder = @("_QUARANTINE_LD", "_INTERNAL_ARCHIVE", "sravan1"),

    [string[]]$Pattern = @(
        '(?<![A-Za-z])LDX',
        'LD[ _\-]?Capital',
        'LD[ _\-]?Realty',
        '(?<![A-Za-z])LDRC',
        'ldxcore',
        'Kiwi',
        'Mulligan',
        'M[ _.\-]?Helen',
        'Centrifuge',
        'TD[ _\-]?SYNNEX',
        'UNYKORN[ _\-]?LDX'
    ),

    [string[]]$Priority = @(
        'LDX[ _\-]?Capital[ _\-]?Business[ _\-]?Plan',
        'LDX[ _\-]?ENTERPRISE[ _\-]?OPERATING[ _\-]?MANUAL',
        'LD[ _\-]?Capital[ _\-]?Build[ _\-]?Verification[ _\-]?Deck',
        'LD[ _\-]?Capital[ _\-]?M[ _\-]?Helen[ _\-]?Data[ _\-]?Room[ _\-]?Master[ _\-]?Index',
        'LD[ _\-]?Capital[ _\-]?Language[ _\-]?Compliance[ _\-]?Addendum',
        'M[ _\-]?Helen[ _\-]?Hotel[ _\-]?SPV',
        'UNYKORN[ _\-]?LLC[ _\-]?Executive[ _\-]?Overview[ _\-]?Deck',
        'Unykorn[ _\-]?Monetization[ _\-]?Architecture[ _\-]?Deck',
        'Unykorn[ _\-]?7777[ _\-]?Institutional[ _\-]?Bank[ _\-]?Presentation',
        'LDX[ _\-]?MASTER[ _\-]?SYSTEM',
        'UNYKORN[ _\-]?LDX[ _\-]?WhiteLabel[ _\-]?Command[ _\-]?Pack',
        'ldxcore',
        'BUILD[ _\-]?PROOF'
    ),

    [string[]]$RepoRoot = @(
        "C:\Users\Kevan\source",
        "C:\Users\Kevan\source\repos",
        "C:\Users\Kevan\repos",
        "C:\Users\Kevan\Documents\GitHub",
        "C:\Users\Kevan\OneDrive - FTH Trading\Documents\GitHub"
    ),

    [string[]]$Repo = @(),

    [switch]$RepoFullCopy,

    [string[]]$ExcludeDir = @('.git', 'node_modules', '.wrangler', 'dist', 'build', '.next', '__pycache__',
                              '.venv', 'venv', 'target', 'bin', 'obj', '.cache', '.idea', '.vscode'),

    [string]$Destination,

    [string]$ArchiveFolderName = "LD_Capital_Complete_Archive",

    [ValidateSet("Copy", "Move")]
    [string]$Mode = "Copy",

    [switch]$SkipCloudOnly,

    [switch]$NoHash,

    [switch]$IndexOnly,

    [ValidateSet('None', 'MachineSweep')]
    [string]$Preset = 'None',

    [string]$CaseFile,

    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- presets and case terms (applied before anything is compiled)
if ($CaseFile) {
    if (-not (Test-Path -LiteralPath $CaseFile -PathType Leaf)) { Write-Host "Case file not found: $CaseFile" -ForegroundColor Red; exit 3 }
    $caseObj = Get-Content -LiteralPath $CaseFile -Raw | ConvertFrom-Json
    $caseTerms = @($caseObj.PSObject.Properties['searchTerms'].Value | Where-Object { $_ })
    foreach ($t in $caseTerms) { $Pattern += [regex]::Escape([string]$t).Replace('\ ', '[ _\-]?') }
}
if ($Preset -eq 'MachineSweep') {
    if ($Mode -ne 'Copy') { Write-Host "MachineSweep runs in Copy mode only; deletion is a separate, deliberate step." -ForegroundColor Red; exit 3 }
    $profileRoot = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    if (-not $PSBoundParameters.ContainsKey('SourcePath')) {
        $SourcePath = @()
        foreach ($sub in @('Desktop', 'Documents', 'Downloads', 'Videos', 'Pictures', 'dev', 'source', 'repos', 'src', 'projects', 'Client_Deals', 'legal-repo')) {
            $p = Join-Path $profileRoot $sub
            if (Test-Path -LiteralPath $p -PathType Container) { $SourcePath += $p }
        }
        foreach ($od in @(Get-ChildItem -LiteralPath $profileRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OneDrive*' })) { $SourcePath += $od.FullName }
    }
    $ExcludeDir += @('AppData', 'Application Data', '.nuget', '.cargo', '.rustup', '.npm', '.gradle', '.m2', 'Packages', 'WindowsApps', '$RECYCLE.BIN', 'System Volume Information')
    $Pattern += @('BitGo', 'FalconX', 'PAXG', 'LDCRE', 'Edelweiss', 'Loan[ _\-]?Depot', 'Waterpark', 'Persona')
    if (-not $PSBoundParameters.ContainsKey('ArchiveFolderName')) { $ArchiveFolderName = 'MASTER_LD_CAPITAL_AUDIT_VAULT' }
    $script:SweepSubfolder = '09_MACHINE_ONE_SWEEP_' + (Get-Date).ToString('yyyyMMdd-HHmm')
} else {
    $script:SweepSubfolder = $null
}

# ---------------------------------------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------------------------------------

$script:OnWindows = $true
if (Test-Path variable:IsWindows) { $script:OnWindows = [bool]$IsWindows }
$script:Sep = [System.IO.Path]::DirectorySeparatorChar
$script:PathCompare = if ($script:OnWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:ExcludeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($d in $ExcludeDir) { [void]$script:ExcludeSet.Add($d) }
$script:IncludeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($d in $IncludeFolder) { [void]$script:IncludeSet.Add($d) }
$script:PatternRegex = New-Object System.Text.RegularExpressions.Regex(
    ('(' + ((@($Pattern) + @($Priority)) -join ')|(') + ')'),
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$script:PriorityRegex = @()
foreach ($pr in $Priority) {
    $script:PriorityRegex += New-Object System.Text.RegularExpressions.Regex($pr, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

$script:ControlFiles = @('manifest.txt', 'manifest.csv', 'manifest.json', 'SHA256SUMS.txt', 'README.txt',
                         'migration-log.jsonl', 'merkle.json', 'merkle-root.txt', 'anchor-payload.json',
                         'anchor-receipt.json', 'mirror-receipt.json')

function Write-Status {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Message -ForegroundColor $Color
}

function Get-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Add-TrailingSeparator {
    param([string]$Path)
    if ($Path.EndsWith([string]$script:Sep) -or $Path.EndsWith('/')) { return $Path }
    return $Path + $script:Sep
}

function Get-RelativePathTo {
    param([string]$Root, [string]$Full)
    $r = Add-TrailingSeparator (Get-FullPath $Root)
    $f = Get-FullPath $Full
    if ($f.StartsWith($r, $script:PathCompare)) { return $f.Substring($r.Length) }
    return [System.IO.Path]::GetFileName($f)
}

function Split-PathSegments {
    param([string]$Path)
    return @($Path -split '[\\/]+' | Where-Object { $_ -ne '' })
}

function Test-ExcludedPath {
    param([string]$RelativePath)
    foreach ($seg in (Split-PathSegments $RelativePath)) {
        if ($script:ExcludeSet.Contains($seg)) { return $true }
    }
    return $false
}

function Test-InScope {
    param([string]$RelativePath)
    foreach ($seg in (Split-PathSegments $RelativePath)) {
        if ($script:IncludeSet.Contains($seg)) { return $true }
        if ($script:PatternRegex.IsMatch($seg)) { return $true }
    }
    return $false
}

function Test-CloudOnly {
    param([System.IO.FileInfo]$File)
    # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (0x400000) and FILE_ATTRIBUTE_OFFLINE (0x1000) mark OneDrive
    # Files-On-Demand placeholders whose bytes are not on local disk.
    $attr = [int]$File.Attributes
    return (($attr -band 0x400000) -ne 0) -or (($attr -band 0x1000) -ne 0)
}

function Get-Sha256 {
    param([string]$LiteralPath)
    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Confirm-Directory {
    param([string]$Path)
    [void][System.IO.Directory]::CreateDirectory($Path)
}

function ConvertTo-Iso { param($v) if ($v -is [datetime]) { return $v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }; if ($null -eq $v) { return '' }; return [string]$v }
function Get-SumBytes {
    param([object[]]$Items, [string]$Property)
    $sum = [long]0
    foreach ($i in $Items) { $sum += [long]$i.$Property }
    return $sum
}

# ---------------------------------------------------------------------------------------------------------
# Destination resolution (SanDisk / USB removable auto-detect)
# ---------------------------------------------------------------------------------------------------------

function Find-RemovableArchiveRoot {
    if (-not $script:OnWindows) { return $null }

    $candidates = @()
    try {
        $drives = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)
        foreach ($drive in $drives) {
            $isSanDisk = ($drive.Model -match 'SanDisk') -or ($drive.Caption -match 'SanDisk') -or ($drive.PNPDeviceID -match 'SanDisk')
            $isUsb = ($drive.InterfaceType -eq 'USB') -or ($drive.MediaType -match 'Removable|External')
            if (-not ($isSanDisk -or $isUsb)) { continue }

            $partitions = @(Get-CimAssociatedInstance -InputObject $drive -ResultClassName Win32_DiskPartition -ErrorAction SilentlyContinue)
            foreach ($part in $partitions) {
                $logical = @(Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)
                foreach ($ld in $logical) {
                    if (-not $ld.DeviceID) { continue }
                    $candidates += [pscustomobject]@{
                        Root      = ($ld.DeviceID + '\')
                        Label     = $ld.VolumeName
                        Model     = $drive.Model
                        IsSanDisk = [bool]$isSanDisk
                        FreeBytes = [long]$ld.FreeSpace
                    }
                }
            }
        }
    } catch {
        Write-Verbose "Win32_DiskDrive enumeration failed: $($_.Exception.Message)"
    }

    if ($candidates.Count -eq 0) {
        try {
            $removable = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2" -ErrorAction Stop)
            foreach ($ld in $removable) {
                $candidates += [pscustomobject]@{
                    Root      = ($ld.DeviceID + '\')
                    Label     = $ld.VolumeName
                    Model     = 'Removable'
                    IsSanDisk = ($ld.VolumeName -match 'SanDisk')
                    FreeBytes = [long]$ld.FreeSpace
                }
            }
        } catch {
            Write-Verbose "Win32_LogicalDisk enumeration failed: $($_.Exception.Message)"
        }
    }

    if ($candidates.Count -eq 0) { return $null }
    $pick = $candidates |
        Sort-Object -Property @{ Expression = 'IsSanDisk'; Descending = $true }, @{ Expression = 'FreeBytes'; Descending = $true } |
        Select-Object -First 1
    Write-Status ("Detected removable volume {0} [{1}] ({2}, {3} free)" -f $pick.Root, $pick.Label, $pick.Model, (Format-Bytes $pick.FreeBytes)) Cyan
    return $pick.Root
}

# ---------------------------------------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------------------------------------

$script:ExtDeck      = @('.pptx', '.ppt', '.pptm', '.key', '.odp')
$script:ExtSheet     = @('.xlsx', '.xlsm', '.xls', '.csv', '.numbers', '.ods')
$script:ExtCode      = @('.sol', '.rs', '.c', '.h', '.wasm', '.wat', '.move', '.vy', '.abi', '.cairo')
$script:ExtMedia     = @('.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm', '.mp3', '.wav', '.m4a', '.aac',
                         '.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.heic', '.psd', '.ai', '.tif', '.tiff')
$script:ExtArchive   = @('.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.xz')
$script:ExtDocText   = @('.md', '.mdx', '.txt', '.rtf', '.adoc')
$script:ExtDocData   = @('.json', '.yaml', '.yml', '.toml')
$script:ExtDocOffice = @('.pdf', '.docx', '.doc', '.odt', '.pages')

$script:RxPlan   = [regex]'(?i)business[ _\-]?plan|strategic[ _\-]?plan|executive[ _\-]?summary'
$script:RxManual = [regex]'(?i)operating[ _\-]?manual|operations[ _\-]?manual|\bmanual\b|handbook|\bsop\b|standard[ _\-]?operating'
$script:RxRoom   = [regex]'(?i)data[ _\-]?room|master[ _\-]?index|due[ _\-]?diligence|\bdd[ _\-]?(pack|package|index|checklist)|diligence'
$script:RxLegal = [regex]'(?i)reg[ _\-]?d\b|506\(?c\)?|\bppm\b|private[ _\-]?placement|subscription|operating[ _\-]?agreement|\bnda\b|non[ _\-]?disclosure|term[ _\-]?sheet|\bloi\b|\bmou\b|agreement|contract(?!s?\.(sol|rs|c)\b)|legal|\bkyc\b|\baml\b|accredit|offering|memorandum|counsel|compliance|indemn|engagement[ _\-]?letter|articles|bylaws|resolution|\bw-?9\b|form[ _\-]?d\b'
$script:RxModel = [regex]'(?i)model|waterfall|pro[ _\-]?forma|underwrit|\bdscr\b|\bltv\b|\bltc\b|budget|cap[ _\-]?table|financial|projection|forecast|sources[ _\-]?(and|&)[ _\-]?uses|rent[ _\-]?roll|\bnoi\b|amort|sizing|pricing'
$script:RxCode  = [regex]'(?i)hook|smart[ _\-]?contract|\berc[ _\-]?\d|3643|t-?rex|onchainid|\bmpt\b|solidity|hardhat|foundry|wasm'
$script:RxDeck  = [regex]'(?i)deck|pitch|presentation|overview|one[ _\-]?pager|teaser|investor[ _\-]?(update|pres)|keynote|slides'
$script:RxArch  = [regex]'(?i)architect|system|spec|design|whitepaper|white[ _\-]?paper|command[ _\-]?pack|master|blueprint|runbook|playbook|roadmap|schema|readme|manifest'

function Get-ArchiveCategory {
    param([string]$Name, [string]$RelativePath)
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()

    if ($script:ExtCode -contains $ext)          { return 'SmartContracts' }
    if ($script:ExtMedia -contains $ext)         { return 'Media' }
    if ($script:ExtArchive -contains $ext)       { return 'Archives' }

    if ($script:RxPlan.IsMatch($RelativePath))   { return 'Business_Plans' }
    if ($script:RxManual.IsMatch($RelativePath)) { return 'Operating_Manuals' }
    if ($script:RxRoom.IsMatch($RelativePath))   { return 'Data_Room' }

    if ($script:ExtSheet -contains $ext)         { return 'FinancialModels' }
    if ($script:ExtDeck -contains $ext)          { return 'Decks' }
    if ($script:RxLegal.IsMatch($RelativePath))  { return 'Legal_and_RegD' }
    if ($script:RxModel.IsMatch($RelativePath))  { return 'FinancialModels' }
    if ($script:RxCode.IsMatch($RelativePath))   { return 'SmartContracts' }
    if ($script:RxDeck.IsMatch($RelativePath))   { return 'Decks' }
    if ($script:RxArch.IsMatch($RelativePath))   { return 'Architecture_Docs' }

    if ($script:ExtDocText -contains $ext)       { return 'Architecture_Docs' }
    if ($script:ExtDocData -contains $ext)       { return 'Architecture_Docs' }
    if ($script:ExtDocOffice -contains $ext)     { return 'Documents' }
    return 'Other'
}

# ---------------------------------------------------------------------------------------------------------
# Enumeration
# ---------------------------------------------------------------------------------------------------------

function Get-CandidateFiles {
    param([string]$Root, [string]$Origin, [switch]$AllInScope, [scriptblock]$Filter)
    $rootFull = Get-FullPath $Root
    $items = @()
    $enumErrors = @()
    try {
        $items = @(Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable enumErrors)
    } catch {
        Write-Warning "Enumeration failed under ${rootFull}: $($_.Exception.Message)"
        return @()
    }
    foreach ($e in $enumErrors) { Write-Warning ("Access error: {0}" -f $e.Exception.Message) }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($fi in $items) {
        $rel = Get-RelativePathTo -Root $rootFull -Full $fi.FullName
        if (Test-ExcludedPath $rel) { continue }
        if (-not $AllInScope) {
            if (-not (Test-InScope $rel)) { continue }
        }
        if ($Filter -and -not (& $Filter $fi $rel)) { continue }
        $out.Add([pscustomobject]@{
            File     = $fi
            Root     = $rootFull
            Relative = $rel
            Origin   = $Origin
        })
    }
    return $out.ToArray()
}

function Test-LooksLikeLdxRepo {
    param([string]$RepoPath)
    $name = [System.IO.Path]::GetFileName($RepoPath.TrimEnd('\', '/'))
    if ($script:PatternRegex.IsMatch($name)) { return $true }
    $docs = @(Get-ChildItem -LiteralPath $RepoPath -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.md', '.txt') -or $_.Name -eq 'package.json' } | Select-Object -First 25)
    foreach ($d in $docs) {
        if ($script:PatternRegex.IsMatch($d.Name)) { return $true }
        if (Select-String -LiteralPath $d.FullName -Pattern $script:PatternRegex.ToString() -Quiet -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Find-LdxRepositories {
    param([string[]]$Roots, [string[]]$Explicit)
    $found = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($p in $Explicit) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Container)) {
            $full = (Get-FullPath $p).TrimEnd('\', '/')
            $found[$full] = [System.IO.Path]::GetFileName($full)
        } else {
            Write-Warning "Repo path not found, skipping: $p"
        }
    }

    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $gitDirs = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq '.git' })
        foreach ($g in $gitDirs) {
            $repoPath = $g.Parent.FullName.TrimEnd('\', '/')
            if ($found.ContainsKey($repoPath)) { continue }
            if (Test-LooksLikeLdxRepo $repoPath) {
                $found[$repoPath] = $g.Parent.Name
            }
        }
    }
    return $found
}

$script:RepoDocFilter = {
    param($fi, $rel)
    $ext = $fi.Extension.ToLowerInvariant()
    if ($ext -in @('.md', '.mdx', '.txt', '.adoc', '.pdf', '.docx', '.doc', '.pptx', '.xlsx', '.csv', '.drawio', '.puml', '.mmd')) { return $true }
    foreach ($seg in (Split-PathSegments $rel)) {
        if ($seg -match '^(docs?|documentation|architecture|specs?|design|adr|wiki)$') { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------------------------------------
# Copy / verify / move
# ---------------------------------------------------------------------------------------------------------

function Copy-FileRobust {
    param([string]$Source, [string]$Target)
    $targetDir = [System.IO.Path]::GetDirectoryName($Target)
    Confirm-Directory $targetDir
    try {
        Copy-Item -LiteralPath $Source -Destination $Target -Force -ErrorAction Stop
        return
    } catch {
        $needsRobocopy = $script:OnWindows -and (
            ($_.Exception -is [System.IO.PathTooLongException]) -or
            ($Source.Length -ge 248) -or ($Target.Length -ge 248) -or
            ($_.Exception.Message -match 'too long'))
        if (-not $needsRobocopy) { throw }
    }
    # Long-path fallback: robocopy handles > MAX_PATH natively. Copy the single file, then rename if needed.
    $srcDir  = [System.IO.Path]::GetDirectoryName($Source)
    $srcName = [System.IO.Path]::GetFileName($Source)
    $dstName = [System.IO.Path]::GetFileName($Target)
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }
    try {
        $null = & robocopy.exe $srcDir $targetDir $srcName /NJH /NJS /NFL /NDL /NP /R:2 /W:1 /COPY:DAT
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedEap
    }
    if ($rc -ge 8) { throw "robocopy failed with exit code $rc for $Source" }
    if ($srcName -ne $dstName) {
        Rename-Item -LiteralPath (Join-Path $targetDir $srcName) -NewName $dstName -Force
    }
}

function Resolve-UniqueTarget {
    param([string]$Target, [string]$SourceHash, [long]$SourceLength, [datetime]$SourceWrite)
    # Returns @{ Path = <final path>; Duplicate = <bool> }
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
        return @{ Path = $Target; Duplicate = $false }
    }
    $existing = Get-Item -LiteralPath $Target
    $same = $false
    if ($SourceHash) {
        $same = ((Get-Sha256 $Target) -eq $SourceHash)
    } else {
        $same = ($existing.Length -eq $SourceLength) -and ([math]::Abs(($existing.LastWriteTimeUtc - $SourceWrite).TotalSeconds) -lt 2)
    }
    if ($same) { return @{ Path = $Target; Duplicate = $true } }

    $dir  = [System.IO.Path]::GetDirectoryName($Target)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Target)
    $ext  = [System.IO.Path]::GetExtension($Target)
    $tag  = if ($SourceHash) { $SourceHash.Substring(0, 8) } else { ('{0:x8}' -f ([int]($SourceLength -band 0x7fffffff))) }
    $alt  = Join-Path $dir ("{0}~{1}{2}" -f $stem, $tag, $ext)
    if (Test-Path -LiteralPath $alt -PathType Leaf) {
        $altSame = if ($SourceHash) { (Get-Sha256 $alt) -eq $SourceHash } else { (Get-Item -LiteralPath $alt).Length -eq $SourceLength }
        if ($altSame) { return @{ Path = $alt; Duplicate = $true } }
        $i = 2
        while (Test-Path -LiteralPath (Join-Path $dir ("{0}~{1}-{2}{3}" -f $stem, $tag, $i, $ext))) { $i++ }
        $alt = Join-Path $dir ("{0}~{1}-{2}{3}" -f $stem, $tag, $i, $ext)
    }
    return @{ Path = $alt; Duplicate = $false }
}

# ---------------------------------------------------------------------------------------------------------
# Append-only, hash-chained log
# ---------------------------------------------------------------------------------------------------------

$script:LogPath = $null
$script:LogPrev = ('0' * 64)

function Initialize-ChainLog {
    param([string]$Path)
    $script:LogPath = $Path
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $last = Get-Content -LiteralPath $Path -Tail 1 -ErrorAction SilentlyContinue
        if ($last) {
            try {
                $obj = $last | ConvertFrom-Json
                $script:LogPrev = [string]$obj.hash
            } catch { Write-Warning "Could not parse last log line; chain restarts from genesis." }
        }
    }
}

function Write-ChainLog {
    param([hashtable]$Event)
    if (-not $script:LogPath) { return }
    $ordered = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); prev = $script:LogPrev }
    foreach ($k in ($Event.Keys | Sort-Object)) { $ordered[$k] = $Event[$k] }
    $body = ($ordered | ConvertTo-Json -Compress -Depth 4)
    $hash = Get-StringSha256 $body
    $ordered['hash'] = $hash
    $line = ($ordered | ConvertTo-Json -Compress -Depth 4)
    [System.IO.File]::AppendAllText($script:LogPath, $line + "`n", $script:Utf8NoBom)
    $script:LogPrev = $hash
}

# ---------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------

$runStart = Get-Date
$runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
Write-Status ("LD Capital / LDX archive migration  run={0}  mode={1}{2}{3}" -f $runId, $Mode, $(if ($IndexOnly) { '  INDEX-ONLY' } else { '' }), $(if ($DryRun) { '  DRY-RUN' } else { '' })) White

# --- destination
if (-not $Destination) {
    $root = Find-RemovableArchiveRoot
    if (-not $root) {
        if ($DryRun) {
            $root = [System.IO.Path]::GetTempPath()
            Write-Status "No removable volume detected; dry-run will plan against $root" Yellow
        } else {
            Write-Status "No SanDisk / USB removable volume detected. Plug the drive in or pass -Destination 'E:\$ArchiveFolderName'." Red
            exit 3
        }
    }
    $Destination = Join-Path $root $ArchiveFolderName
}
if ($script:SweepSubfolder) { $Destination = Join-Path $Destination $script:SweepSubfolder }
$Destination = Get-FullPath $Destination
$destFull = Add-TrailingSeparator $Destination

if ($DryRun) {
    $manifestDir = Join-Path ([System.IO.Path]::GetTempPath()) 'LD_Capital_Archive_DryRun'
    Confirm-Directory $manifestDir
    Write-Status "Archive root (planned): $Destination" Cyan
    Write-Status "Dry-run manifest folder: $manifestDir" Cyan
} else {
    $manifestDir = $Destination
    Confirm-Directory $Destination
    Initialize-ChainLog (Join-Path $Destination 'migration-log.jsonl')
    Write-ChainLog @{ event = 'run-start'; run = $runId; mode = $Mode; sources = @($SourcePath); host = [System.Environment]::MachineName }
    Write-Status "Archive root: $Destination" Cyan
}

# --- collect candidates
$candidates = New-Object System.Collections.Generic.List[object]
$repos = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)

if ($IndexOnly) {
    Write-Status "Index-only: adopting every file already under $Destination" Gray
    $SourcePath = @($Destination)
    $found = @(Get-CandidateFiles -Root $Destination -Origin 'index' -AllInScope -Filter {
        param($fi, $rel)
        -not (($rel -notmatch '[\\/]') -and ($script:ControlFiles -contains $fi.Name))
    })
    Write-Status ("  {0} file(s) in place" -f $found.Count) Gray
    foreach ($c in $found) { $candidates.Add($c) }
}

foreach ($src in $(if ($IndexOnly) { @() } else { $SourcePath })) {
    if (-not (Test-Path -LiteralPath $src -PathType Container)) {
        Write-Warning "Source not found, skipping: $src"
        continue
    }
    if ((Get-FullPath $src).StartsWith($destFull, $script:PathCompare)) {
        Write-Warning "Source is inside the destination, skipping: $src"
        continue
    }
    Write-Status "Scanning $src" Gray
    $found = @(Get-CandidateFiles -Root $src -Origin 'downloads')
    Write-Status ("  {0} in-scope file(s)" -f $found.Count) Gray
    foreach ($c in $found) { $candidates.Add($c) }
}

if (-not $IndexOnly) { $repos = Find-LdxRepositories -Roots $RepoRoot -Explicit $Repo }
foreach ($repoPath in @($repos.Keys)) {
    if ((Add-TrailingSeparator $repoPath).StartsWith($destFull, $script:PathCompare)) { continue }
    $repoName = $repos[$repoPath]
    Write-Status "Repository: $repoName  ($repoPath)" Gray
    $filter = if ($RepoFullCopy) { $null } else { $script:RepoDocFilter }
    $found = @(Get-CandidateFiles -Root $repoPath -Origin ("repo:" + $repoName) -AllInScope -Filter $filter)
    Write-Status ("  {0} file(s)" -f $found.Count) Gray
    foreach ($c in $found) { $candidates.Add($c) }
}

# de-dupe by full path (a repo living inside a source root would otherwise be listed twice)
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$work = New-Object System.Collections.Generic.List[object]
foreach ($c in $candidates) {
    if ($seen.Add($c.File.FullName)) { $work.Add($c) }
}
$needBytes = [long]0
foreach ($w in $work) { $needBytes += [long]$w.File.Length }
Write-Status ("{0} unique file(s) to process, {1} total" -f $work.Count, (Format-Bytes $needBytes)) White

# --- free space check
if (-not $DryRun -and -not $IndexOnly) {
    try {
        $driveInfo = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($Destination))
        $free = [long]$driveInfo.AvailableFreeSpace
        if ($free -lt [long]($needBytes * 1.02)) {
            Write-Status ("Insufficient space on {0}: need {1}, free {2}" -f $driveInfo.Name, (Format-Bytes $needBytes), (Format-Bytes $free)) Red
            exit 4
        }
    } catch {
        Write-Verbose "Free-space check skipped: $($_.Exception.Message)"
    }
}

# --- process
$rows = New-Object System.Collections.Generic.List[object]
$counts = [ordered]@{ Copied = 0; Moved = 0; Duplicate = 0; Indexed = 0; Archived = 0; Planned = 0; SkippedCloudOnly = 0; Failed = 0 }
$n = 0
$total = $work.Count

foreach ($item in $work) {
    $n++
    $fi = $item.File
    $rel = $item.Relative
    $isRepo = $item.Origin.StartsWith('repo:')
    $isIndex = ($item.Origin -eq 'index')

    if ($isIndex) {
        $segs = @(Split-PathSegments $rel)
        $category = if ($segs.Count -gt 1) { $segs[0] } else { '(root)' }
        $archiveRel = $rel
    } elseif ($isRepo) {
        $category = 'Repos'
        $archiveRel = Join-Path (Join-Path 'Repos' $item.Origin.Substring(5)) $rel
    } else {
        $category = Get-ArchiveCategory -Name $fi.Name -RelativePath $rel
        $archiveRel = Join-Path $category $rel
    }
    $target = Join-Path $Destination $archiveRel

    Write-Progress -Activity "Archiving ($Mode)" -Status ("{0}/{1}  {2}" -f $n, $total, $fi.Name) -PercentComplete ([int](100 * $n / [math]::Max(1, $total)))

    $row = [ordered]@{
        Status      = ''
        Category    = $category
        ArchivePath = $archiveRel
        SourcePath  = $fi.FullName
        Origin      = $item.Origin
        SizeBytes   = [long]$fi.Length
        LastWrite   = $fi.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Sha256      = ''
        Note        = ''
    }

    try {
        if ($script:OnWindows -and (Test-CloudOnly $fi)) {
            if ($SkipCloudOnly) {
                $row.Status = 'SkippedCloudOnly'
                $row.Note = 'OneDrive placeholder not hydrated'
                $counts.SkippedCloudOnly++
                $rows.Add([pscustomobject]$row)
                continue
            }
            Write-Verbose "Hydrating OneDrive placeholder: $($fi.FullName)"
        }

        if ($DryRun) {
            $row.Status = 'Planned'
            $counts.Planned++
            $rows.Add([pscustomobject]$row)
            continue
        }

        $srcHash = $null
        if (-not $NoHash) { $srcHash = Get-Sha256 $fi.FullName; $row.Sha256 = $srcHash }

        if ($isIndex) {
            $row.Status = 'Indexed'
            $counts.Indexed++
            Write-ChainLog @{
                event = 'file'; run = $runId; status = 'Indexed'; category = $category
                archive = $archiveRel; source = $fi.FullName; size = [long]$fi.Length
                sha256 = $row.Sha256; lastWrite = $row.LastWrite
            }
            $rows.Add([pscustomobject]$row)
            continue
        }

        $resolved = Resolve-UniqueTarget -Target $target -SourceHash $srcHash -SourceLength $fi.Length -SourceWrite $fi.LastWriteTimeUtc
        $finalTarget = $resolved.Path
        $row.ArchivePath = Get-RelativePathTo -Root $Destination -Full $finalTarget

        $status = ''
        if ($resolved.Duplicate) {
            $status = 'Duplicate'
            $row.Note = 'identical file already archived'
        } else {
            Copy-FileRobust -Source $fi.FullName -Target $finalTarget
            $dst = Get-Item -LiteralPath $finalTarget
            try {
                $dst.CreationTimeUtc  = $fi.CreationTimeUtc
                $dst.LastWriteTimeUtc = $fi.LastWriteTimeUtc
            } catch { Write-Verbose "Timestamp preservation failed for $finalTarget" }

            if ($NoHash) {
                $dst.Refresh()
                if ($dst.Length -ne $fi.Length) { throw "size mismatch after copy ($($dst.Length) != $($fi.Length))" }
            } else {
                $dstHash = Get-Sha256 $finalTarget
                if ($dstHash -ne $srcHash) {
                    Remove-Item -LiteralPath $finalTarget -Force -ErrorAction SilentlyContinue
                    throw "SHA-256 mismatch after copy"
                }
            }
            $status = 'Copied'
        }

        if ($Mode -eq 'Move') {
            Remove-Item -LiteralPath $fi.FullName -Force
            if ($resolved.Duplicate) { $row.Note = 'source removed; identical copy already archived' }
            $status = 'Moved'
        }

        $row.Status = $status
        $counts[$status]++

        Write-ChainLog @{
            event = 'file'; run = $runId; status = $status; category = $category
            archive = $row.ArchivePath; source = $fi.FullName; size = [long]$fi.Length
            sha256 = $row.Sha256; lastWrite = $row.LastWrite
        }
    } catch {
        $row.Status = 'Failed'
        $row.Note = $_.Exception.Message
        $counts.Failed++
        Write-Warning ("FAILED {0}: {1}" -f $fi.FullName, $_.Exception.Message)
        if (-not $DryRun) {
            Write-ChainLog @{ event = 'file'; run = $runId; status = 'Failed'; source = $fi.FullName; error = $_.Exception.Message }
        }
    }
    $rows.Add([pscustomobject]$row)
}
Write-Progress -Activity "Archiving ($Mode)" -Completed

# --- manifests
$runEnd = Get-Date
$manifestTxt  = Join-Path $manifestDir 'manifest.txt'
$manifestCsv  = Join-Path $manifestDir 'manifest.csv'
$manifestJson = Join-Path $manifestDir 'manifest.json'

# The manifest is cumulative: rows archived by earlier runs that this run did not touch are carried
# forward, so manifest.json always describes the whole archive (and the verifier checks all of it).
$carried = 0
if (-not $DryRun -and (Test-Path -LiteralPath $manifestJson -PathType Leaf)) {
    try {
        $prior = Get-Content -LiteralPath $manifestJson -Raw | ConvertFrom-Json
        $current = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($r in $rows) { [void]$current.Add([string]$r.ArchivePath) }
        foreach ($pf in @($prior.files)) {
            if ($pf.Status -notin @('Copied', 'Moved', 'Duplicate', 'Indexed')) { continue }
            if ($current.Contains([string]$pf.ArchivePath)) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $Destination $pf.ArchivePath) -PathType Leaf)) { continue }
            $rows.Add([pscustomobject][ordered]@{
                Status      = 'Archived'
                Category    = [string]$pf.Category
                ArchivePath = [string]$pf.ArchivePath
                SourcePath  = [string]$pf.SourcePath
                Origin      = [string]$pf.Origin
                SizeBytes   = [long]$pf.SizeBytes
                LastWrite   = (ConvertTo-Iso $pf.LastWrite)
                Sha256      = [string]$pf.Sha256
                Note        = ('archived in run ' + [string]$prior.runId)
            })
            $carried++
        }
    } catch {
        Write-Warning "Prior manifest.json could not be merged: $($_.Exception.Message)"
    }
}
$archivedRows = @($rows | Where-Object { $_.Status -in @('Copied', 'Moved', 'Duplicate', 'Indexed', 'Planned', 'Archived') })
$archivedBytes = Get-SumBytes -Items $archivedRows -Property 'SizeBytes'
$sortedRows = @($rows | Sort-Object Category, ArchivePath)

$counts.Archived = $carried
$countsLine = (($counts.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join '  ')
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("LD Capital / LDX Complete Archive - manifest")
[void]$sb.AppendLine(("=" * 100))
[void]$sb.AppendLine(("Run id     : {0}" -f $runId))
[void]$sb.AppendLine(("Generated  : {0} UTC" -f $runEnd.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')))
[void]$sb.AppendLine(("Host       : {0}" -f [System.Environment]::MachineName))
[void]$sb.AppendLine(("Mode       : {0}{1}" -f $Mode, $(if ($DryRun) { ' (dry-run)' } else { '' })))
[void]$sb.AppendLine(("Archive    : {0}" -f $Destination))
[void]$sb.AppendLine(("Sources    : {0}" -f ($SourcePath -join '; ')))
[void]$sb.AppendLine(("Repos      : {0}" -f $(if ($repos.Count) { (@($repos.Values) -join ', ') } else { '(none found)' })))
[void]$sb.AppendLine(("Files      : {0} total, {1} archived bytes ({2})" -f $rows.Count, $archivedBytes, (Format-Bytes $archivedBytes)))
[void]$sb.AppendLine(("Counts     : {0}" -f $countsLine))
[void]$sb.AppendLine(("Hashing    : {0}" -f $(if ($NoHash) { 'disabled' } else { 'SHA-256 source+destination' })))
[void]$sb.AppendLine("")

$byCat = @($sortedRows | Group-Object Category)
foreach ($g in $byCat) {
    $catBytes = Get-SumBytes -Items @($g.Group) -Property 'SizeBytes'
    [void]$sb.AppendLine(("[{0}]  {1} file(s), {2}" -f $g.Name, $g.Count, (Format-Bytes $catBytes)))
    [void]$sb.AppendLine(("{0,-16} {1,15}  {2,-64}  {3,-10}  {4}" -f 'LastWrite(UTC)', 'Bytes', 'SHA-256', 'Status', 'Archive path  <=  Source path'))
    foreach ($r in $g.Group) {
        $hash = if ($r.Sha256) { $r.Sha256 } else { '-' }
        $note = if ($r.Note) { "  [$($r.Note)]" } else { '' }
        [void]$sb.AppendLine(("{0,-16} {1,15:N0}  {2,-64}  {3,-10}  {4}  <=  {5}{6}" -f
            $r.LastWrite.Substring(0, 16).Replace('T', ' '), $r.SizeBytes, $hash, $r.Status, $r.ArchivePath, $r.SourcePath, $note))
    }
    [void]$sb.AppendLine("")
}
# priority checklist
$priorityReport = @()
foreach ($rx in $script:PriorityRegex) {
    $hits = @($sortedRows | Where-Object { $_.Status -ne 'Failed' -and $rx.IsMatch([System.IO.Path]::GetFileName($_.ArchivePath)) })
    $priorityReport += [pscustomobject]@{ Pattern = $rx.ToString(); Found = $hits.Count; Example = $(if ($hits.Count) { $hits[0].ArchivePath } else { '' }) }
}
if ($priorityReport.Count) {
    [void]$sb.AppendLine("[Priority checklist]")
    foreach ($pr in $priorityReport) {
        $mark = if ($pr.Found) { 'FOUND  ' } else { 'MISSING' }
        [void]$sb.AppendLine(("  {0}  {1,-70}  {2}" -f $mark, $pr.Pattern, $(if ($pr.Found) { "{0} file(s), e.g. {1}" -f $pr.Found, $pr.Example } else { '' })))
    }
    [void]$sb.AppendLine("")
}
[System.IO.File]::WriteAllText($manifestTxt, $sb.ToString(), $script:Utf8NoBom)

# sha256sum-compatible digest list (verify on any platform with: sha256sum -c SHA256SUMS.txt)
$sums = New-Object System.Text.StringBuilder
foreach ($r in $sortedRows) {
    if ($r.Status -in @('Copied', 'Moved', 'Duplicate', 'Indexed', 'Archived') -and $r.Sha256) {
        [void]$sums.Append($r.Sha256).Append('  ').Append(([string]$r.ArchivePath).Replace('\', '/')).Append("`n")
    }
}
[System.IO.File]::WriteAllText((Join-Path $manifestDir 'SHA256SUMS.txt'), $sums.ToString(), $script:Utf8NoBom)

# archive README
$readme = @"
LD Capital / LDX Complete Archive
=================================

Consolidated record set for LD Capital, LDX, M Helen and Kiwi's Mulligan, assembled from the
FTH Trading OneDrive download tree and local LDX repositories by Migrate-LDCapitalArchive.ps1
(FTHTrading/ldx-capitol, tools/migration). Files are byte-identical to their sources; nothing is
renamed except same-name collisions, which carry a ~<8-char-sha256> suffix.

Last run   : $runId  ($($runEnd.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC, host $([System.Environment]::MachineName))
Files      : $($archivedRows.Count)  ($(Format-Bytes $archivedBytes))

Layout
  Business_Plans/      business and strategic plans, executive summaries
  Operating_Manuals/   operating manuals, handbooks, SOPs
  Data_Room/           data-room indexes and due-diligence packages
  Decks/               investor, bank and partner presentations
  Legal_and_RegD/      Reg D 506(c), PPM, subscription, operating agreements, NDAs, term sheets, compliance
  SmartContracts/      Solidity, Rust, XRPL Hook sources and contract-related documents
  FinancialModels/     spreadsheets, waterfalls, pro formas, underwriting, cap tables
  Media/               video, audio, images, design sources
  Architecture_Docs/   markdown, specs, whitepapers, command packs, system documents
  Archives/            zip / 7z / tar bundles
  Documents/           other PDF and Word documents
  Repos/<name>/        repository files with their original tree
  Other/               in-scope files with no better home
  Inside each folder the original sub-path under the source root is preserved.

Integrity
  manifest.txt         human-readable inventory: date, size, SHA-256, status, archive path, source path
  manifest.csv         the same rows for Excel
  manifest.json        the same rows plus run metadata; cumulative across runs
  SHA256SUMS.txt       verify anywhere:  sha256sum -c SHA256SUMS.txt   (from this folder)
  migration-log.jsonl  append-only, hash-chained log of every run; do not edit
  Verify-LDCapitalArchive.ps1 (in the repo) re-hashes everything and validates the chain.

Keep a second copy of this folder on cloud storage. The SHA-256 list is what makes the two copies
provably identical.
"@
if (-not ($IndexOnly -and (Test-Path -LiteralPath (Join-Path $manifestDir 'README.txt') -PathType Leaf))) {
    [System.IO.File]::WriteAllText((Join-Path $manifestDir 'README.txt'), $readme, $script:Utf8NoBom)
}

$sortedRows | Export-Csv -LiteralPath $manifestCsv -NoTypeInformation -Encoding UTF8

$manifestObj = [ordered]@{
    schema     = 'ldx-archive-manifest/1'
    runId      = $runId
    generated  = $runEnd.ToUniversalTime().ToString('o')
    host       = [System.Environment]::MachineName
    mode       = $Mode
    dryRun     = [bool]$DryRun
    hashing    = (-not $NoHash)
    archive    = $Destination
    sources    = @($SourcePath)
    repos      = @($repos.Keys)
    counts     = $counts
    totalBytes = $archivedBytes
    files      = $sortedRows
}
[System.IO.File]::WriteAllText($manifestJson, ($manifestObj | ConvertTo-Json -Depth 6), $script:Utf8NoBom)

if (-not $DryRun) {
    Write-ChainLog @{ event = 'run-end'; run = $runId; counts = $counts; totalBytes = $archivedBytes
                      manifestSha256 = (Get-Sha256 $manifestJson); durationSec = [int]($runEnd - $runStart).TotalSeconds }
}

# --- summary
Write-Status ""
Write-Status ("Done in {0:N0}s" -f ($runEnd - $runStart).TotalSeconds) White
foreach ($k in @($counts.Keys)) {
    if ($counts[$k] -gt 0) {
        $color = if ($k -eq 'Failed') { 'Red' } elseif ($k -eq 'SkippedCloudOnly') { 'Yellow' } else { 'Green' }
        Write-Status ("  {0,-18} {1}" -f $k, $counts[$k]) $color
    }
}
Write-Status ("  {0,-18} {1}" -f 'Archived bytes', (Format-Bytes $archivedBytes)) Green
$missingPriority = @($priorityReport | Where-Object { -not $_.Found })
if ($missingPriority.Count) {
    Write-Status ("  {0,-18} {1} of {2} priority pattern(s) not found:" -f 'Priority', $missingPriority.Count, $priorityReport.Count) Yellow
    foreach ($m in $missingPriority) { Write-Status ("      {0}" -f $m.Pattern) Yellow }
} elseif ($priorityReport.Count) {
    Write-Status ("  {0,-18} all {1} present" -f 'Priority', $priorityReport.Count) Green
}
Write-Status "Manifest: $manifestTxt" Cyan
if (-not $DryRun) { Write-Status "Chain log: $($script:LogPath)" Cyan }

if ($counts.Failed -gt 0) { exit 2 }
exit 0
