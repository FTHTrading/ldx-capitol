#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the dated case breakdown from everything in the vault: what we have, what they have, the timeline,
    the workstreams, the contacts, and the integrity record. Also emits CRM-ready contact and activity exports.

.DESCRIPTION
    Inputs (all read-only, all inside the vault):
        manifest.json                          every archived file with hash and last-write date
        09_M365_EXPORT_*\EMAIL_INDEX.csv       exported mail (from Export-LDCapitalM365Evidence.ps1)
        09_M365_EXPORT_*\SHARED_OUT.csv        OneDrive items shared out, with grantees
        09_M365_EXPORT_*\SHARED_WITH_ME.csv    items shared with you
        09_M365_EXPORT_*\SITE_HITS.csv         SharePoint hits
        migration-log.jsonl, merkle.json, anchor-receipt.json   integrity record

    Outputs to <Archive>\10_CASE_BREAKDOWN\:
        CASE_BREAKDOWN.md      the narrative-free breakdown: inventories, counts, dates, references
        CASE_TIMELINE.csv      every dated event (email, file, share, integrity) in one chronological table
        WHAT_WE_HAVE.csv       vault inventory with hashes
        WHAT_THEY_HAVE.csv     items shared to counterparty domains + attachments emailed to them
        CRM_CONTACTS.csv       one row per email address: name, domain, first/last contact, counts, workstreams
        CRM_ACTIVITIES.csv     one row per email / share event, ready for HubSpot, Pipedrive or a custom CRM import

    Workstream tags come from the case file's "workstreams" map (regex per workstream) applied to subjects and
    file paths. Counterparty and own domains come from the same file. No names live in this script.

.PARAMETER Archive
    Vault root. Default: auto-detect on a removable volume.

.PARAMETER CaseFile
    JSON case file (see case\README.md). Default: .\case\case.json next to this script.

.EXAMPLE
    .\New-LDCapitalCaseReport.ps1 -Archive "D:\MASTER_LD_CAPITAL_AUDIT_VAULT"
#>
[CmdletBinding()]
param(
    [string]$Archive,
    [string[]]$ArchiveFolderName = @("MASTER_LD_CAPITAL_AUDIT_VAULT", "LD_Capital_Complete_Archive"),
    [string]$CaseFile = (Join-Path $PSScriptRoot 'case\case.json'),
    [string]$OutputFolderName = '10_CASE_BREAKDOWN'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$onWindows = $true
if (Test-Path variable:IsWindows) { $onWindows = [bool]$IsWindows }

function Get-Prop { param($Obj, [string]$Name) if ($null -eq $Obj) { return $null }; if ($Obj -is [hashtable]) { return $Obj[$Name] }; $p = $Obj.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $null }
function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}
function Get-Addresses {
    # "Name <a@b.com>; c@d.com" -> @(@{Email; Name})
    param([string]$Field)
    $out = @()
    foreach ($part in ($Field -split ';')) {
        $p = $part.Trim(); if (-not $p) { continue }
        if ($p -match '^(?<name>.*?)\s*<(?<email>[^>]+)>\s*$') { $out += @{ Email = $Matches.email.Trim().ToLowerInvariant(); Name = $Matches.name.Trim().Trim('"') } }
        elseif ($p -match '@') { $out += @{ Email = $p.ToLowerInvariant(); Name = '' } }
    }
    return ,$out
}
function ConvertTo-Iso { param($v) if ($v -is [datetime]) { return $v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }; if ($null -eq $v) { return '' }; return [string]$v }
function Get-Domain { param([string]$Email) if ($Email -match '@') { return ($Email -split '@')[-1].ToLowerInvariant() }; return '' }
function Get-Workstream {
    param([string]$Text)
    $tags = @()
    foreach ($k in $script:WorkstreamMap.Keys) { if ($Text -match $script:WorkstreamMap[$k]) { $tags += $k } }
    if ($tags.Count -eq 0) { return 'Unclassified' }
    return ($tags -join ' | ')
}
function Import-CsvIfPresent { param([string]$Path) if (Test-Path -LiteralPath $Path -PathType Leaf) { return @(Import-Csv -LiteralPath $Path -Encoding UTF8) }; return @() }
function Md-Escape { param([string]$s) return ([string]$s).Replace('|', '\|').Replace("`r", '').Replace("`n", ' ') }

# --- locate archive
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
    if (-not $Archive) { Write-Host "No archive with manifest.json found. Pass -Archive." -ForegroundColor Red; exit 3 }
}
$Archive = [System.IO.Path]::GetFullPath($Archive).TrimEnd('\', '/')
$manifestPath = Join-Path $Archive 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Write-Host "manifest.json not found. Run Migrate-LDCapitalArchive.ps1 -IndexOnly first." -ForegroundColor Red; exit 3 }

# --- case file (optional; defaults keep the report useful without it)
$counterparty = @(); $ourDomains = @()
$script:WorkstreamMap = [ordered]@{
    'Custody onboarding'     = '(?i)bitgo|custody|kyc|persona|enterprise id|beneficial owner'
    'Prime broker facility'  = '(?i)falconx|paxg|credit line|\bltv\b'
    'M Helen Hotel SPV'      = '(?i)helen|waterpark|edelweiss|\bspv\b|apprais|proforma|pro forma'
    "Kiwi's Mulligan"        = '(?i)kiwi|mulligan'
    'LDX platform and brand' = '(?i)\bldx\b|logo|brand|platform|deck|business plan'
    'Legal and offering'     = '(?i)\bppm\b|reg d|506|subscription|operating agreement|compliance'
    'Software'               = '(?i)rust|crate|cargo|solidity|contract|hook|wasm'
}
if (Test-Path -LiteralPath $CaseFile -PathType Leaf) {
    $case = Get-Content -LiteralPath $CaseFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $counterparty = @(Get-Prop $case 'counterpartyDomains' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    $ourDomains = @(Get-Prop $case 'ourDomains' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    $ws = Get-Prop $case 'workstreams'
    if ($null -ne $ws) {
        $script:WorkstreamMap = [ordered]@{}
        foreach ($p in $ws.PSObject.Properties) { $script:WorkstreamMap[$p.Name] = '(?i)' + [string]$p.Value }
    }
} else {
    Write-Warning "No case file at $CaseFile; counterparty and own domains are empty, default workstreams apply."
}

$outDir = Join-Path $Archive $OutputFolderName
[void][System.IO.Directory]::CreateDirectory($outDir)
$now = (Get-Date).ToUniversalTime()

# =====================================================================================================
# Load inputs
# =====================================================================================================
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$files = @($manifest.files | Where-Object { $_.Status -in @('Copied', 'Moved', 'Duplicate', 'Indexed', 'Archived') })
$exports = @(Get-ChildItem -LiteralPath $Archive -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '09_M365_EXPORT_*' } | Sort-Object Name)
$emails = @(); $sharedOut = @(); $sharedWithMe = @(); $siteHits = @()
foreach ($e in $exports) {
    $emails       += Import-CsvIfPresent (Join-Path $e.FullName 'EMAIL_INDEX.csv')
    $sharedOut    += Import-CsvIfPresent (Join-Path $e.FullName 'SHARED_OUT.csv')
    $sharedWithMe += Import-CsvIfPresent (Join-Path $e.FullName 'SHARED_WITH_ME.csv')
    $siteHits     += Import-CsvIfPresent (Join-Path $e.FullName 'SITE_HITS.csv')
}
# de-duplicate mail across multiple exports by Message-ID
$emailById = [ordered]@{}
foreach ($m in $emails) { $k = if ($m.MessageId) { $m.MessageId } else { $m.GraphId }; if ($k -and -not $emailById.Contains($k)) { $emailById[$k] = $m } }
$emails = @($emailById.Values)

$chain = @(); $logPath = Join-Path $Archive 'migration-log.jsonl'
if (Test-Path -LiteralPath $logPath -PathType Leaf) { foreach ($line in [System.IO.File]::ReadLines($logPath)) { if ($line.Trim()) { try { $chain += ($line | ConvertFrom-Json) } catch { } } } }
$merkle = $null; $mp = Join-Path $Archive 'merkle.json'; if (Test-Path -LiteralPath $mp -PathType Leaf) { $merkle = Get-Content -LiteralPath $mp -Raw -Encoding UTF8 | ConvertFrom-Json }
$anchor = $null; $ap = Join-Path $Archive 'anchor-receipt.json'; if (Test-Path -LiteralPath $ap -PathType Leaf) { $anchor = Get-Content -LiteralPath $ap -Raw -Encoding UTF8 | ConvertFrom-Json }

# =====================================================================================================
# 1. What we have
# =====================================================================================================
$weHave = foreach ($f in $files) {
    [pscustomobject]@{
        Folder = $f.Category; ArchivePath = $f.ArchivePath; SizeBytes = [long]$f.SizeBytes; LastWrite = (ConvertTo-Iso $f.LastWrite)
        Sha256 = $f.Sha256; Workstream = Get-Workstream ([string]$f.ArchivePath); SourcePath = $f.SourcePath
    }
}
$weHave = @($weHave | Sort-Object Folder, ArchivePath)
$weHave | Export-Csv -LiteralPath (Join-Path $outDir 'WHAT_WE_HAVE.csv') -NoTypeInformation -Encoding UTF8
$byFolder = @($weHave | Group-Object Folder | Sort-Object Name)

# =====================================================================================================
# 2. What they have (shares to counterparty + attachments we sent them)
# =====================================================================================================
function Test-Counterparty { param([string]$Addresses) foreach ($a in (Get-Addresses $Addresses)) { if ($counterparty -contains (Get-Domain $a.Email)) { return $true } }; return $false }
$theyHave = New-Object System.Collections.Generic.List[object]
foreach ($s in $sharedOut) {
    if ([string]$s.ToCounterparty -eq 'True' -or ([string]$s.Scope -eq 'anonymous')) {
        $theyHave.Add([pscustomobject]@{ Date = $s.LastModified; Channel = 'OneDrive share'; Item = $s.Path; Recipients = $s.GrantedTo; Scope = $s.Scope; Roles = $s.Roles; Expires = $s.Expires; Reference = $s.WebUrl; Workstream = Get-Workstream ([string]$s.Path) })
    }
}
foreach ($m in $emails) {
    if ($m.Direction -eq 'Sent' -and [string]$m.HasAttachments -eq 'True' -and (Test-Counterparty ($m.To + ';' + $m.Cc))) {
        $theyHave.Add([pscustomobject]@{ Date = $m.Date; Channel = 'Email attachment'; Item = $m.Subject; Recipients = ($m.To + $(if ($m.Cc) { '; ' + $m.Cc } else { '' })); Scope = 'email'; Roles = ''; Expires = ''; Reference = $m.EmlFile; Workstream = Get-Workstream ([string]$m.Subject) })
    }
}
$theyHave = @($theyHave | Sort-Object Date)
$theyHave | Export-Csv -LiteralPath (Join-Path $outDir 'WHAT_THEY_HAVE.csv') -NoTypeInformation -Encoding UTF8

# =====================================================================================================
# 3. Timeline
# =====================================================================================================
$timeline = New-Object System.Collections.Generic.List[object]
foreach ($m in $emails) {
    $timeline.Add([pscustomobject]@{ Date = $m.Date; Type = 'Email'; Direction = $m.Direction; Workstream = Get-Workstream ([string]$m.Subject); Summary = $m.Subject; Parties = ($m.From + ' -> ' + $m.To); Reference = $m.EmlFile; Sha256 = $m.Sha256 })
}
foreach ($f in $weHave) {
    if ($f.Folder -like '09_M365_EXPORT_*' -or $f.Folder -eq $OutputFolderName) { continue }
    $timeline.Add([pscustomobject]@{ Date = $f.LastWrite; Type = 'File'; Direction = ''; Workstream = $f.Workstream; Summary = $f.ArchivePath; Parties = ''; Reference = $f.ArchivePath; Sha256 = $f.Sha256 })
}
foreach ($s in $sharedOut) {
    $timeline.Add([pscustomobject]@{ Date = $s.LastModified; Type = 'Share'; Direction = 'Out'; Workstream = Get-Workstream ([string]$s.Path); Summary = $s.Path; Parties = $s.GrantedTo; Reference = $s.WebUrl; Sha256 = '' })
}
foreach ($s in $sharedWithMe) {
    $timeline.Add([pscustomobject]@{ Date = $(if ($s.SharedOn) { $s.SharedOn } else { $s.LastModified }); Type = 'Share'; Direction = 'In'; Workstream = Get-Workstream ([string]$s.Name); Summary = $s.Name; Parties = $s.Owner; Reference = $s.WebUrl; Sha256 = '' })
}
foreach ($c in $chain) {
    $ev = [string](Get-Prop $c 'event')
    if ($ev -in @('run-start', 'run-end', 'merkle')) {
        $sum = switch ($ev) { 'run-start' { 'archive run started (' + (Get-Prop $c 'mode') + ')' } 'run-end' { 'archive run completed' } 'merkle' { 'merkle root ' + (Get-Prop $c 'root') } }
        $timeline.Add([pscustomobject]@{ Date = (ConvertTo-Iso (Get-Prop $c 'ts')); Type = 'Integrity'; Direction = ''; Workstream = 'Vault'; Summary = $sum; Parties = ''; Reference = 'migration-log.jsonl'; Sha256 = [string](Get-Prop $c 'hash') })
    }
}
if ($null -ne $anchor) {
    $timeline.Add([pscustomobject]@{ Date = (ConvertTo-Iso $anchor.submittedAt); Type = 'Integrity'; Direction = ''; Workstream = 'Vault'; Summary = 'XRPL anchor of root ' + $anchor.merkleRoot; Parties = $anchor.account; Reference = $anchor.txHash; Sha256 = '' })
}
$timeline = @($timeline | Sort-Object Date)
$timeline | Export-Csv -LiteralPath (Join-Path $outDir 'CASE_TIMELINE.csv') -NoTypeInformation -Encoding UTF8

# =====================================================================================================
# 4. Contacts and CRM exports
# =====================================================================================================
$contacts = @{}
function Touch-Contact {
    param([hashtable]$A, [string]$Date, [string]$Dir, [string]$Ws)
    $e = $A.Email; if (-not $e) { return }
    if (-not $contacts.ContainsKey($e)) { $contacts[$e] = @{ Email = $e; Name = $A.Name; Domain = (Get-Domain $e); First = $Date; Last = $Date; From = 0; To = 0; Ws = @{} } }
    $c = $contacts[$e]
    if ($A.Name -and -not $c.Name) { $c.Name = $A.Name }
    if ($Date -and ($Date -lt $c.First -or -not $c.First)) { $c.First = $Date }
    if ($Date -and $Date -gt $c.Last) { $c.Last = $Date }
    if ($Dir -eq 'From') { $c.From++ } else { $c.To++ }
    foreach ($w in ($Ws -split ' \| ')) { $c.Ws[$w] = $true }
}
$activities = New-Object System.Collections.Generic.List[object]
foreach ($m in $emails) {
    $ws = Get-Workstream ([string]$m.Subject)
    foreach ($a in (Get-Addresses $m.From)) { Touch-Contact $a $m.Date 'From' $ws }
    foreach ($a in (Get-Addresses ($m.To + ';' + $m.Cc))) { Touch-Contact $a $m.Date 'To' $ws }
    $others = @((Get-Addresses ($m.From + ';' + $m.To + ';' + $m.Cc)) | Where-Object { $ourDomains -notcontains (Get-Domain $_.Email) } | ForEach-Object { $_.Email } | Sort-Object -Unique)
    $activities.Add([pscustomobject]@{ Date = $m.Date; Type = 'Email'; Direction = $m.Direction; Contacts = ($others -join '; '); Subject = $m.Subject; Workstream = $ws; HasAttachments = $m.HasAttachments; Reference = $m.EmlFile; MessageId = $m.MessageId })
}
foreach ($s in $sharedOut) {
    $ws = Get-Workstream ([string]$s.Path)
    foreach ($a in (Get-Addresses $s.GrantedTo)) { Touch-Contact $a $s.LastModified 'To' $ws }
    $activities.Add([pscustomobject]@{ Date = $s.LastModified; Type = 'Share'; Direction = 'Out'; Contacts = $s.GrantedTo; Subject = $s.Path; Workstream = $ws; HasAttachments = 'True'; Reference = $s.WebUrl; MessageId = '' })
}
$contactRows = foreach ($e in ($contacts.Keys | Sort-Object)) {
    $c = $contacts[$e]
    $side = if ($ourDomains -contains $c.Domain) { 'Us' } elseif ($counterparty -contains $c.Domain) { 'Counterparty' } else { 'Third party' }
    [pscustomobject]@{ Email = $c.Email; Name = $c.Name; Company = $c.Domain; Side = $side; FirstContact = $c.First; LastContact = $c.Last; MessagesFrom = $c.From; MessagesTo = $c.To; Workstreams = (($c.Ws.Keys | Sort-Object) -join ' | ') }
}
$contactRows = @($contactRows | Sort-Object Side, Company, Email)
$contactRows | Export-Csv -LiteralPath (Join-Path $outDir 'CRM_CONTACTS.csv') -NoTypeInformation -Encoding UTF8
@($activities | Sort-Object Date) | Export-Csv -LiteralPath (Join-Path $outDir 'CRM_ACTIVITIES.csv') -NoTypeInformation -Encoding UTF8

# =====================================================================================================
# 5. Workstream summary
# =====================================================================================================
$wsRows = foreach ($k in @($script:WorkstreamMap.Keys) + @('Unclassified')) {
    $em = @($timeline | Where-Object { $_.Type -eq 'Email' -and $_.Workstream -match [regex]::Escape($k) })
    $fl = @($weHave | Where-Object { $_.Workstream -match [regex]::Escape($k) })
    $dates = @(($em | ForEach-Object { $_.Date }) + ($fl | ForEach-Object { $_.LastWrite }) | Where-Object { $_ } | Sort-Object)
    [pscustomobject]@{ Workstream = $k; Emails = $em.Count; Files = $fl.Count; Bytes = (($fl | ForEach-Object { [long]$_.SizeBytes } | Measure-Object -Sum).Sum); First = $(if ($dates.Count) { $dates[0] } else { '' }); Last = $(if ($dates.Count) { $dates[-1] } else { '' }) }
}

# =====================================================================================================
# 6. CASE_BREAKDOWN.md
# =====================================================================================================
$sb = New-Object System.Text.StringBuilder
$L = { param($t) [void]$sb.AppendLine($t) }
& $L "# LD Capital / LDX case breakdown"
& $L ""
& $L ('Generated {0} UTC from `{1}`' -f $now.ToString('yyyy-MM-dd HH:mm'), $Archive)
& $L ""
& $L "Every row below points at a file in this vault by path and SHA-256, or at an exported message by its Message-ID and .eml file. Nothing here is a paraphrase."
& $L ""
& $L "## 1. Integrity record"
& $L ""
& $L ('- Manifest run: `{0}`, {1} file(s), {2}' -f $manifest.runId, $files.Count, (Format-Bytes (($files | ForEach-Object { [long]$_.SizeBytes } | Measure-Object -Sum).Sum)))
if ($null -ne $merkle) { & $L ('- Merkle root: `{0}` over {1} leaves ({2})' -f $merkle.root, $merkle.leafCount, (ConvertTo-Iso $merkle.generated)) } else { & $L "- Merkle root: not built yet (run Build-LDCapitalMerkle.ps1)" }
if ($null -ne $anchor) { & $L ('- XRPL anchor: tx `{0}` ledger {1} on {2} ({3})' -f $anchor.txHash, $anchor.ledgerIndex, $anchor.network, (ConvertTo-Iso $anchor.submittedAt)) } else { & $L "- XRPL anchor: not submitted yet" }
& $L ("- Chain log: {0} entries" -f $chain.Count)
& $L ("- Mail exports: {0} folder(s), {1} unique message(s), {2} share grant(s), {3} item(s) shared with us, {4} SharePoint hit(s)" -f $exports.Count, $emails.Count, $sharedOut.Count, $sharedWithMe.Count, $siteHits.Count)
& $L ""
& $L "## 2. What we have (vault inventory)"
& $L ""
& $L "| Folder | Files | Size | Earliest | Latest |"
& $L "|---|---:|---:|---|---|"
foreach ($g in $byFolder) {
    $d = @($g.Group | ForEach-Object { $_.LastWrite } | Where-Object { $_ } | Sort-Object)
    & $L ("| {0} | {1} | {2} | {3} | {4} |" -f (Md-Escape $g.Name), $g.Count, (Format-Bytes (($g.Group | ForEach-Object { [long]$_.SizeBytes } | Measure-Object -Sum).Sum)), $(if ($d.Count) { $d[0].Substring(0, 10) } else { '' }), $(if ($d.Count) { $d[-1].Substring(0, 10) } else { '' }))
}
& $L ""
& $L 'Full list with hashes: `WHAT_WE_HAVE.csv`.'
& $L ""
& $L "## 3. What they have"
& $L ""
if ($counterparty.Count -eq 0) { & $L "_No counterparty domains in the case file; this section lists anonymous links only._" ; & $L "" }
& $L ('{0} item(s): OneDrive shares granted to counterparty addresses or anonymous links, plus attachments emailed to them. Full list: `WHAT_THEY_HAVE.csv`.' -f $theyHave.Count)
& $L ""
& $L "| Date | Channel | Item | Recipients | Scope | Reference |"
& $L "|---|---|---|---|---|---|"
foreach ($t in $theyHave) { & $L ("| {0} | {1} | {2} | {3} | {4} | {5} |" -f $t.Date, $t.Channel, (Md-Escape $t.Item), (Md-Escape $t.Recipients), $t.Scope, (Md-Escape $t.Reference)) }
& $L ""
& $L "## 4. Workstreams"
& $L ""
& $L "| Workstream | Emails | Files | Size | First | Last |"
& $L "|---|---:|---:|---:|---|---|"
foreach ($w in $wsRows) { & $L ("| {0} | {1} | {2} | {3} | {4} | {5} |" -f (Md-Escape $w.Workstream), $w.Emails, $w.Files, (Format-Bytes ([long]$(if ($w.Bytes) { $w.Bytes } else { 0 }))), $(if ($w.First) { ([string]$w.First).Substring(0, 10) } else { '' }), $(if ($w.Last) { ([string]$w.Last).Substring(0, 10) } else { '' })) }
& $L ""
& $L "## 5. Contacts"
& $L ""
& $L "| Side | Company | Email | Name | First | Last | From them | To them | Workstreams |"
& $L "|---|---|---|---|---|---|---:|---:|---|"
foreach ($c in $contactRows) { & $L ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |" -f $c.Side, $c.Company, $c.Email, (Md-Escape $c.Name), $(if ($c.FirstContact) { ([string]$c.FirstContact).Substring(0, 10) } else { '' }), $(if ($c.LastContact) { ([string]$c.LastContact).Substring(0, 10) } else { '' }), $c.MessagesFrom, $c.MessagesTo, (Md-Escape $c.Workstreams)) }
& $L ""
& $L 'CRM imports: `CRM_CONTACTS.csv`, `CRM_ACTIVITIES.csv`.'
& $L ""
& $L "## 6. Timeline"
& $L ""
& $L ('{0} dated event(s). Full table: `CASE_TIMELINE.csv`.' -f $timeline.Count)
& $L ""
& $L "| Date | Type | Dir | Workstream | Summary | Parties | Reference |"
& $L "|---|---|---|---|---|---|---|"
foreach ($t in $timeline) { & $L ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f $(if ($t.Date) { ([string]$t.Date).Substring(0, [math]::Min(16, ([string]$t.Date).Length)).Replace('T', ' ') } else { '' }), $t.Type, $t.Direction, (Md-Escape $t.Workstream), (Md-Escape $t.Summary), (Md-Escape $t.Parties), (Md-Escape $t.Reference)) }
& $L ""
[System.IO.File]::WriteAllText((Join-Path $outDir 'CASE_BREAKDOWN.md'), $sb.ToString(), $utf8)

Write-Host ("Case breakdown written to {0}" -f $outDir) -ForegroundColor Green
Write-Host ("  files {0}  emails {1}  they-have {2}  contacts {3}  timeline {4}" -f $files.Count, $emails.Count, $theyHave.Count, $contactRows.Count, $timeline.Count)
Write-Host "Re-run Migrate-LDCapitalArchive.ps1 -IndexOnly and Build-LDCapitalMerkle.ps1 so the breakdown itself is hashed and anchored." -ForegroundColor Gray
exit 0
