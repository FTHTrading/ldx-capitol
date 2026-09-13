#Requires -Version 5.1
<#
.SYNOPSIS
    Builds 30_DOCS: the developer documentation hub. Scans every repository under 10_PLATFORMS for READMEs,
    docs folders and ADRs, writes INDEX.md linking all of it with last-change dates, and seeds the docs repo
    with the ADR and runbook templates if they are missing.

.PARAMETER Root
    Workstation root from workstation.json (override with -Root).

.EXAMPLE
    .\New-DocsIndex.ps1
#>
[CmdletBinding()]
param(
    [string]$Config = (Join-Path $PSScriptRoot 'workstation.json'),
    [string]$Root,
    [string[]]$ExtraRepoRoot = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$onWindows = $true; if (Test-Path variable:IsWindows) { $onWindows = [bool]$IsWindows }

$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Root) { $Root = [string]$cfg.root }
if (-not $onWindows -and $Root -match '^[A-Za-z]:') { $Root = Join-Path $HOME 'Unykorn' }
$Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
$docs = Join-Path $Root '30_DOCS'
$platforms = Join-Path $Root ([string]$cfg.repoDest)
foreach ($d in @('architecture', 'adr', 'runbooks', 'playbooks')) { [void][System.IO.Directory]::CreateDirectory((Join-Path $docs $d)) }

# seed templates once
$tpl = Join-Path $PSScriptRoot 'templates'
foreach ($t in @(Get-ChildItem -LiteralPath $tpl -File -ErrorAction SilentlyContinue)) {
    $target = switch -Wildcard ($t.Name) { 'ADR-*' { Join-Path (Join-Path $docs 'adr') $t.Name } 'RUNBOOK-*' { Join-Path (Join-Path $docs 'runbooks') $t.Name } default { Join-Path $docs $t.Name } }
    if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $t.FullName -Destination $target }
}

function Get-Title { param([string]$Path) foreach ($line in [System.IO.File]::ReadLines($Path)) { if ($line -match '^\s*#\s+(.+)$') { return $Matches[1].Trim() } }; return [System.IO.Path]::GetFileNameWithoutExtension($Path) }
function Rel { param([string]$From, [string]$To) $u1 = New-Object System.Uri(($From.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar)); $u2 = New-Object System.Uri($To); return [System.Uri]::UnescapeDataString($u1.MakeRelativeUri($u2).ToString()) }

$gitOk = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
$repoDirs = @()
foreach ($r in @($platforms) + $ExtraRepoRoot) { if (Test-Path -LiteralPath $r -PathType Container) { $repoDirs += @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue) } }

$sb = New-Object System.Text.StringBuilder
$L = { param($t) [void]$sb.AppendLine($t) }
& $L "# Developer documentation index"
& $L ""
& $L ("Generated {0} UTC by New-DocsIndex.ps1. Re-run after adding docs to any repository." -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm'))
& $L ""
& $L "## Hub"
& $L ""
& $L "| Section | Purpose |"
& $L "|---|---|"
& $L "| [architecture/](architecture/) | system diagrams, data flows, trust boundaries per platform |"
& $L "| [adr/](adr/) | architecture decision records, one file per decision, never edited after acceptance |"
& $L "| [runbooks/](runbooks/) | how to operate: deploy, rotate, restore, verify, anchor |"
& $L "| [playbooks/](playbooks/) | how to sell and deliver: onboarding, pricing, deal flow |"
& $L ""
foreach ($d in @('architecture', 'adr', 'runbooks', 'playbooks')) {
    $items = @(Get-ChildItem -LiteralPath (Join-Path $docs $d) -File -Filter *.md -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($items.Count) {
        & $L ("### {0}" -f $d); & $L ""
        foreach ($it in $items) { & $L ("- [{0}]({1}/{2}) · {3}" -f (Get-Title $it.FullName), $d, $it.Name, $it.LastWriteTimeUtc.ToString('yyyy-MM-dd')) }
        & $L ""
    }
}
& $L "## Repositories"
& $L ""
$total = 0
foreach ($repo in ($repoDirs | Sort-Object Name)) {
    $mdFiles = @(Get-ChildItem -LiteralPath $repo.FullName -File -Recurse -Include *.md, *.mdx -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git|dist|build|target|vendor)[\\/]' } | Sort-Object FullName)
    if ($mdFiles.Count -eq 0) { continue }
    $last = ''
    if ($gitOk) { try { $last = (& git -C $repo.FullName log -1 --format=%cs 2>$null | Select-Object -First 1) } catch { } }
    & $L ("### {0}{1}" -f $repo.Name, $(if ($last) { "  ·  last commit $last" } else { '' }))
    & $L ""
    foreach ($m in $mdFiles) {
        $rel = $m.FullName.Substring($repo.FullName.Length).TrimStart('\', '/').Replace('\', '/')
        & $L ("- [{0}]({1}) `{2}` · {3}" -f (Get-Title $m.FullName), (Rel $docs $m.FullName).Replace('\', '/'), $rel, $m.LastWriteTimeUtc.ToString('yyyy-MM-dd'))
        $total++
    }
    & $L ""
}
[System.IO.File]::WriteAllText((Join-Path $docs 'INDEX.md'), $sb.ToString(), $utf8)
if (-not (Test-Path -LiteralPath (Join-Path $docs 'README.md'))) {
    [System.IO.File]::WriteAllText((Join-Path $docs 'README.md'), "# 30_DOCS`n`nDeveloper documentation hub. Start at [INDEX.md](INDEX.md). Keep this folder as its own git repository.`n", $utf8)
}
Write-Host ("INDEX.md: {0} document(s) across {1} repositories -> {2}" -f $total, $repoDirs.Count, (Join-Path $docs 'INDEX.md')) -ForegroundColor Green
exit 0
