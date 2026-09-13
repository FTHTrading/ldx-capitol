#Requires -Version 5.1
<#
.SYNOPSIS
    Exports the Microsoft 365 evidence set for the LD Capital / LDX matter into the vault: raw emails with full
    headers, every OneDrive item you shared out, every item shared with you, and SharePoint search hits.

.DESCRIPTION
    Runs under your own Microsoft 365 login (delegated Graph permissions, device-code sign-in). It reads only
    what your account can already see and never writes to the tenant.

    Search terms, date window and counterparty domains come from a case file you keep outside the repository
    (see -CaseFile). The script itself carries no names or addresses.

    Output folder:  <Vault>\09_M365_EXPORT_<yyyyMMdd-HHmm>\
        Mail\*.eml               raw RFC 5322 messages (headers, DKIM/ARC signatures, attachments intact)
        EMAIL_INDEX.csv          one row per message: Message-ID, date, direction, from, to, cc, subject, folder, sha256, eml file
        SHARED_OUT.csv           your OneDrive items that carry a sharing permission: who, link scope, roles, expiry
        SHARED_WITH_ME.csv       items other people shared with you: owner, URL, last modified
        SITES.csv                SharePoint sites visible to you
        SITE_HITS.csv            items in those sites matching the search terms
        export-receipt.json      counts, terms, account, timestamps

    Afterwards run Migrate-LDCapitalArchive.ps1 -IndexOnly and Build-LDCapitalMerkle.ps1 so the export is hashed,
    logged and covered by the Merkle root, then New-LDCapitalCaseReport.ps1 for the breakdown.

.PARAMETER CaseFile
    JSON file:
        {
          "searchTerms": ["LD Capital", "LDX", "M Helen", "Kiwi's Mulligan", "BitGo", "FalconX", "<counterparty domain>"],
          "counterpartyDomains": ["<their-domain.com>"],
          "since": "2026-01-01",
          "until": null
        }
    Default: .\case\case.json next to this script (the case\ folder is git-ignored).

.PARAMETER Vault
    Archive root. Default: auto-detect the vault on a removable volume.

.PARAMETER SkipMail / SkipDrive / SkipSites
    Skip a phase.

.EXAMPLE
    .\Export-LDCapitalM365Evidence.ps1 -Vault "D:\MASTER_LD_CAPITAL_AUDIT_VAULT"

.NOTES
    Requires the Microsoft.Graph.Authentication module:  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
    Scopes requested: Mail.Read, Files.Read.All, Sites.Read.All, User.Read.
#>
[CmdletBinding()]
param(
    [string]$CaseFile = (Join-Path $PSScriptRoot 'case\case.json'),
    [string]$Vault,
    [string[]]$VaultFolderName = @("MASTER_LD_CAPITAL_AUDIT_VAULT", "LD_Capital_Complete_Archive"),
    [switch]$SkipMail,
    [switch]$SkipDrive,
    [switch]$SkipSites
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-Sha256 { param([string]$LiteralPath) return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant() }
function ConvertTo-SafeName {
    param([string]$Text, [int]$Max = 80)
    $bad = [System.IO.Path]::GetInvalidFileNameChars() + @('#', '%', '&', '{', '}', '$', '!', '@', '+', '`', '=')
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) { if ($bad -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) } }
    $s = ($sb.ToString() -replace '\s+', ' ').Trim()
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max).Trim() }
    if (-not $s) { $s = 'untitled' }
    return $s
}
function Get-Prop { param($Obj, [string]$Name) if ($null -eq $Obj) { return $null }; if ($Obj -is [hashtable]) { return $Obj[$Name] }; $p = $Obj.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $null }
function Get-Addr { param($Recipient) $e = Get-Prop $Recipient 'emailAddress'; if ($null -eq $e) { return '' }; $a = [string](Get-Prop $e 'address'); $n = [string](Get-Prop $e 'name'); if ($n -and $n -ne $a) { return "$n <$a>" }; return $a }
function Get-AddrList { param($List) return (@($List | ForEach-Object { Get-Addr $_ }) -join '; ') }

function Invoke-GraphPaged {
    param([string]$Uri, [int]$MaxPages = 500)
    $out = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    $pages = 0
    while ($next -and $pages -lt $MaxPages) {
        $pages++
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        foreach ($v in @(Get-Prop $resp 'value')) { $out.Add($v) }
        $next = Get-Prop $resp '@odata.nextLink'
        $delta = Get-Prop $resp '@odata.deltaLink'
        if (-not $next -and $delta) { break }
    }
    return $out.ToArray()
}

# --- case file
if (-not (Test-Path -LiteralPath $CaseFile -PathType Leaf)) {
    Write-Host "Case file not found: $CaseFile" -ForegroundColor Red
    Write-Host "Create it (outside git) with searchTerms, counterpartyDomains, since, until. See the script header." -ForegroundColor Yellow
    exit 3
}
$case = Get-Content -LiteralPath $CaseFile -Raw | ConvertFrom-Json
$SearchTerm = @(Get-Prop $case 'searchTerms' | Where-Object { $_ })
$CounterpartyDomain = @(Get-Prop $case 'counterpartyDomains' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
$Since = if (Get-Prop $case 'since') { [datetime](Get-Prop $case 'since') } else { [datetime]'2026-01-01' }
$Until = if (Get-Prop $case 'until') { [datetime](Get-Prop $case 'until') } else { (Get-Date).AddDays(1) }
if ($SearchTerm.Count -eq 0) { Write-Host "case file has no searchTerms" -ForegroundColor Red; exit 3 }

# --- module + sign-in
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "Microsoft.Graph.Authentication is not installed. Run:  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" -ForegroundColor Red
    exit 3
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Connect-MgGraph -Scopes 'Mail.Read', 'Files.Read.All', 'Sites.Read.All', 'User.Read' -UseDeviceCode -NoWelcome
$me = Invoke-MgGraphRequest -Method GET -Uri '/me?$select=displayName,mail,userPrincipalName' -OutputType PSObject
$myAddress = [string]$(if (Get-Prop $me 'mail') { Get-Prop $me 'mail' } else { Get-Prop $me 'userPrincipalName' })
$myDomain = ($myAddress -split '@')[-1].ToLowerInvariant()
Write-Host ("Signed in as {0}" -f $myAddress) -ForegroundColor Cyan

# --- vault
if (-not $Vault) {
    $removable = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2" -ErrorAction SilentlyContinue)
    foreach ($ld in $removable) {
        foreach ($name in $VaultFolderName) {
            $cand = Join-Path ($ld.DeviceID + '\') $name
            if (Test-Path -LiteralPath $cand -PathType Container) { $Vault = $cand; break }
        }
        if ($Vault) { break }
    }
    if (-not $Vault) { Write-Host "No vault found on a removable volume. Pass -Vault." -ForegroundColor Red; exit 3 }
}
$stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
$out = Join-Path $Vault ("09_M365_EXPORT_" + $stamp)
$mailDir = Join-Path $out 'Mail'
[void][System.IO.Directory]::CreateDirectory($mailDir)
Write-Host "Export folder: $out" -ForegroundColor Cyan

$receipt = [ordered]@{
    schema = 'ldx-m365-export/1'; account = $myAddress; started = (Get-Date).ToUniversalTime().ToString('o')
    searchTerms = $SearchTerm; since = $Since.ToString('o'); until = $Until.ToString('o')
    mail = 0; mailFailed = 0; sharedOut = 0; sharedWithMe = 0; sites = 0; siteHits = 0
}

# =====================================================================================================
# 1. Mail: every message matching any term, exported once as raw MIME
# =====================================================================================================
if (-not $SkipMail) {
    Write-Host "Mail: searching $($SearchTerm.Count) term(s) ..." -ForegroundColor White
    $seen = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $select = 'id,internetMessageId,subject,receivedDateTime,sentDateTime,from,toRecipients,ccRecipients,parentFolderId,hasAttachments,isDraft,webLink'
    foreach ($term in $SearchTerm) {
        $q = [uri]::EscapeDataString(('"' + $term.Replace('"', '') + '"'))
        $uri = "/me/messages?`$search=$q&`$top=100&`$select=$select"
        try {
            $hits = @(Invoke-GraphPaged -Uri $uri)
        } catch {
            Write-Warning ("search '{0}' failed: {1}" -f $term, $_.Exception.Message); continue
        }
        $new = 0
        foreach ($m in $hits) {
            $id = [string](Get-Prop $m 'id')
            $when = Get-Prop $m 'receivedDateTime'; if (-not $when) { $when = Get-Prop $m 'sentDateTime' }
            if ($when) { $dt = [datetime]$when; if ($dt -lt $Since -or $dt -gt $Until) { continue } }
            if (-not $seen.ContainsKey($id)) { $seen[$id] = $m; $new++ }
        }
        Write-Host ("  {0,-24} {1,5} hit(s), {2,4} new" -f $term, $hits.Count, $new) -ForegroundColor Gray
    }
    Write-Host ("Mail: {0} unique message(s); exporting raw MIME ..." -f $seen.Count) -ForegroundColor White

    $folderNames = @{}
    $index = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($id in @($seen.Keys)) {
        $i++
        $m = $seen[$id]
        $subject = [string](Get-Prop $m 'subject')
        $when = Get-Prop $m 'receivedDateTime'; if (-not $when) { $when = Get-Prop $m 'sentDateTime' }
        $dt = if ($when) { ([datetime]$when).ToUniversalTime() } else { [datetime]::MinValue }
        Write-Progress -Activity 'Exporting mail' -Status $subject -PercentComplete ([int](100 * $i / [math]::Max(1, $seen.Count)))
        $fid = [string](Get-Prop $m 'parentFolderId')
        if ($fid -and -not $folderNames.ContainsKey($fid)) {
            try { $folderNames[$fid] = [string](Get-Prop (Invoke-MgGraphRequest -Method GET -Uri "/me/mailFolders/$fid`?`$select=displayName" -OutputType PSObject) 'displayName') }
            catch { $folderNames[$fid] = '' }
        }
        $fname = "{0}_{1}_{2}.eml" -f $dt.ToString('yyyyMMdd-HHmmss'), (ConvertTo-SafeName $subject 60), $id.Substring([math]::Max(0, $id.Length - 8))
        $path = Join-Path $mailDir $fname
        $sha = ''
        $status = 'Exported'
        try {
            Invoke-MgGraphRequest -Method GET -Uri "/me/messages/$id/`$value" -OutputFilePath $path | Out-Null
            $sha = Get-Sha256 $path
        } catch {
            $status = 'Failed: ' + $_.Exception.Message
            $receipt.mailFailed++
        }
        $fromAddr = Get-Addr (Get-Prop $m 'from')
        $index.Add([pscustomobject]@{
            Date           = $(if ($dt -ne [datetime]::MinValue) { $dt.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' })
            Direction      = $(if ($fromAddr -match [regex]::Escape($myAddress)) { 'Sent' } else { 'Received' })
            From           = $fromAddr
            To             = Get-AddrList (Get-Prop $m 'toRecipients')
            Cc             = Get-AddrList (Get-Prop $m 'ccRecipients')
            Subject        = $subject
            Folder         = $(if ($fid) { $folderNames[$fid] } else { '' })
            HasAttachments = [bool](Get-Prop $m 'hasAttachments')
            IsDraft        = [bool](Get-Prop $m 'isDraft')
            MessageId      = [string](Get-Prop $m 'internetMessageId')
            GraphId        = $id
            EmlFile        = 'Mail/' + $fname
            Sha256         = $sha
            WebLink        = [string](Get-Prop $m 'webLink')
            Status         = $status
        })
    }
    Write-Progress -Activity 'Exporting mail' -Completed
    $index | Sort-Object Date | Export-Csv -LiteralPath (Join-Path $out 'EMAIL_INDEX.csv') -NoTypeInformation -Encoding UTF8
    $receipt.mail = $index.Count
    Write-Host ("Mail: {0} exported, {1} failed -> EMAIL_INDEX.csv" -f ($index.Count - $receipt.mailFailed), $receipt.mailFailed) -ForegroundColor Green
}

# =====================================================================================================
# 2. OneDrive: everything you shared out (with whom), and everything shared with you
# =====================================================================================================
if (-not $SkipDrive) {
    Write-Host "Drive: enumerating your OneDrive ..." -ForegroundColor White
    $items = @(Invoke-GraphPaged -Uri '/me/drive/root/delta?$select=id,name,size,webUrl,lastModifiedDateTime,createdDateTime,parentReference,shared,file,folder')
    $sharedItems = @($items | Where-Object { $null -ne (Get-Prop $_ 'shared') })
    Write-Host ("Drive: {0} item(s), {1} carry a sharing facet; reading permissions ..." -f $items.Count, $sharedItems.Count) -ForegroundColor Gray
    $sharedOut = New-Object System.Collections.Generic.List[object]
    $j = 0
    foreach ($it in $sharedItems) {
        $j++
        Write-Progress -Activity 'Reading share permissions' -Status (Get-Prop $it 'name') -PercentComplete ([int](100 * $j / [math]::Max(1, $sharedItems.Count)))
        $id = [string](Get-Prop $it 'id')
        $perms = @()
        try { $perms = @(Invoke-GraphPaged -Uri "/me/drive/items/$id/permissions") } catch { Write-Warning "permissions failed for $(Get-Prop $it 'name'): $($_.Exception.Message)" }
        $pref = Get-Prop $it 'parentReference'
        $ppath = [string](Get-Prop $pref 'path'); if ($ppath) { $ppath = $ppath -replace '^/drive/root:', '' }
        foreach ($p in $perms) {
            $link = Get-Prop $p 'link'
            $grantees = @()
            foreach ($g in @(Get-Prop $p 'grantedToIdentitiesV2') + @(Get-Prop $p 'grantedToV2')) {
                if ($null -eq $g) { continue }
                $u = Get-Prop $g 'user'; if ($null -eq $u) { $u = Get-Prop $g 'siteUser' }
                if ($null -ne $u) { $e = [string](Get-Prop $u 'email'); $d = [string](Get-Prop $u 'displayName'); $grantees += $(if ($e) { $e } else { $d }) }
            }
            $inv = Get-Prop $p 'invitation'; if ($null -ne $inv -and (Get-Prop $inv 'email')) { $grantees += [string](Get-Prop $inv 'email') }
            $scope = if ($null -ne $link) { [string](Get-Prop $link 'scope') } else { 'direct' }
            $linkType = if ($null -ne $link) { [string](Get-Prop $link 'type') } else { '' }
            $isOwnerPerm = (($grantees -join ';') -match [regex]::Escape($myAddress)) -and ($null -eq $link)
            if ($isOwnerPerm) { continue }
            $external = ($scope -eq 'anonymous') -or (@($grantees | Where-Object { $_ -match '@' -and ($_ -split '@')[-1].ToLowerInvariant() -ne $myDomain }).Count -gt 0)
            $toCounterparty = $false
            foreach ($g in $grantees) { foreach ($d in $CounterpartyDomain) { if ($g.ToLowerInvariant() -match ('@' + [regex]::Escape($d) + '$')) { $toCounterparty = $true } } }
            $sharedOut.Add([pscustomobject]@{
                Path           = ($ppath + '/' + [string](Get-Prop $it 'name')).TrimStart('/')
                Kind           = $(if ($null -ne (Get-Prop $it 'folder')) { 'folder' } else { 'file' })
                SizeBytes      = [long]$(if (Get-Prop $it 'size') { Get-Prop $it 'size' } else { 0 })
                LastModified   = [string](Get-Prop $it 'lastModifiedDateTime')
                Created        = [string](Get-Prop $it 'createdDateTime')
                Scope          = $scope
                LinkType       = $linkType
                Roles          = (@(Get-Prop $p 'roles') -join ',')
                GrantedTo      = ($grantees -join '; ')
                External       = $external
                ToCounterparty = $toCounterparty
                Expires        = [string](Get-Prop $p 'expirationDateTime')
                HasPassword    = [bool]$(if ($null -ne $link) { Get-Prop $p 'hasPassword' } else { $false })
                WebUrl         = [string](Get-Prop $it 'webUrl')
                ShareUrl       = $(if ($null -ne $link) { [string](Get-Prop $link 'webUrl') } else { '' })
                PermissionId   = [string](Get-Prop $p 'id')
            })
        }
    }
    Write-Progress -Activity 'Reading share permissions' -Completed
    $sharedOut | Sort-Object ToCounterparty, External, Path -Descending | Export-Csv -LiteralPath (Join-Path $out 'SHARED_OUT.csv') -NoTypeInformation -Encoding UTF8
    $receipt.sharedOut = $sharedOut.Count
    Write-Host ("Drive: {0} share grant(s) -> SHARED_OUT.csv  ({1} to counterparty, {2} external)" -f $sharedOut.Count,
        @($sharedOut | Where-Object { $_.ToCounterparty }).Count, @($sharedOut | Where-Object { $_.External }).Count) -ForegroundColor Green

    $swm = @()
    try { $swm = @(Invoke-GraphPaged -Uri '/me/drive/sharedWithMe') } catch { Write-Warning "sharedWithMe failed: $($_.Exception.Message)" }
    $swmRows = foreach ($it in $swm) {
        $r = Get-Prop $it 'remoteItem'; if ($null -eq $r) { $r = $it }
        $sh = Get-Prop $r 'shared'; $owner = $null
        if ($null -ne $sh) { $o = Get-Prop $sh 'owner'; if ($null -ne $o) { $u = Get-Prop $o 'user'; if ($null -ne $u) { $owner = [string]$(if (Get-Prop $u 'email') { Get-Prop $u 'email' } else { Get-Prop $u 'displayName' }) } } }
        [pscustomobject]@{
            Name         = [string](Get-Prop $r 'name')
            Kind         = $(if ($null -ne (Get-Prop $r 'folder')) { 'folder' } else { 'file' })
            SizeBytes    = [long]$(if (Get-Prop $r 'size') { Get-Prop $r 'size' } else { 0 })
            Owner        = $owner
            SharedOn     = [string]$(if ($null -ne $sh) { Get-Prop $sh 'sharedDateTime' } else { '' })
            LastModified = [string](Get-Prop $r 'lastModifiedDateTime')
            WebUrl       = [string](Get-Prop $r 'webUrl')
        }
    }
    @($swmRows) | Export-Csv -LiteralPath (Join-Path $out 'SHARED_WITH_ME.csv') -NoTypeInformation -Encoding UTF8
    $receipt.sharedWithMe = @($swmRows).Count
    Write-Host ("Drive: {0} item(s) shared with you -> SHARED_WITH_ME.csv" -f @($swmRows).Count) -ForegroundColor Green
}

# =====================================================================================================
# 3. SharePoint sites you can see, and matching items in them
# =====================================================================================================
if (-not $SkipSites) {
    Write-Host "Sites: listing ..." -ForegroundColor White
    $sites = @()
    try { $sites = @(Invoke-GraphPaged -Uri '/sites?search=*&$select=id,displayName,webUrl,createdDateTime') } catch { Write-Warning "sites failed: $($_.Exception.Message)" }
    $siteRows = foreach ($s in $sites) { [pscustomobject]@{ Site = [string](Get-Prop $s 'displayName'); WebUrl = [string](Get-Prop $s 'webUrl'); Id = [string](Get-Prop $s 'id'); Created = [string](Get-Prop $s 'createdDateTime') } }
    @($siteRows) | Export-Csv -LiteralPath (Join-Path $out 'SITES.csv') -NoTypeInformation -Encoding UTF8
    $receipt.sites = @($siteRows).Count
    $hits = New-Object System.Collections.Generic.List[object]
    $shortTerms = @($SearchTerm | Where-Object { $_ -notmatch '\.' })   # domain-style terms are mail-only
    foreach ($s in $sites) {
        $sid = [string](Get-Prop $s 'id')
        foreach ($t in $shortTerms) {
            $q = [uri]::EscapeDataString($t.Replace("'", "''"))
            try { $found = @(Invoke-GraphPaged -Uri "/sites/$sid/drive/root/search(q='$q')?`$select=id,name,size,webUrl,lastModifiedDateTime,parentReference,createdBy,lastModifiedBy") }
            catch { continue }
            foreach ($f in $found) {
                $lm = Get-Prop $f 'lastModifiedBy'; $lmu = if ($null -ne $lm) { Get-Prop $lm 'user' } else { $null }
                $hits.Add([pscustomobject]@{
                    Site = [string](Get-Prop $s 'displayName'); Term = $t; Name = [string](Get-Prop $f 'name')
                    Path = [string](Get-Prop (Get-Prop $f 'parentReference') 'path'); SizeBytes = [long]$(if (Get-Prop $f 'size') { Get-Prop $f 'size' } else { 0 })
                    LastModified = [string](Get-Prop $f 'lastModifiedDateTime'); LastModifiedBy = [string]$(if ($null -ne $lmu) { Get-Prop $lmu 'displayName' } else { '' })
                    WebUrl = [string](Get-Prop $f 'webUrl'); ItemId = [string](Get-Prop $f 'id')
                })
            }
        }
    }
    $uniqueHits = @($hits | Sort-Object ItemId -Unique)
    $uniqueHits | Sort-Object Site, Path, Name | Export-Csv -LiteralPath (Join-Path $out 'SITE_HITS.csv') -NoTypeInformation -Encoding UTF8
    $receipt.siteHits = $uniqueHits.Count
    Write-Host ("Sites: {0} site(s), {1} matching item(s) -> SITES.csv, SITE_HITS.csv" -f @($siteRows).Count, $uniqueHits.Count) -ForegroundColor Green
}

$receipt.completed = (Get-Date).ToUniversalTime().ToString('o')
[System.IO.File]::WriteAllText((Join-Path $out 'export-receipt.json'), ($receipt | ConvertTo-Json -Depth 4), $utf8)
Disconnect-MgGraph | Out-Null
Write-Host ""
Write-Host "Export complete: $out" -ForegroundColor Cyan
Write-Host "Next: Migrate-LDCapitalArchive.ps1 -Destination '$Vault' -IndexOnly ; Build-LDCapitalMerkle.ps1 -Archive '$Vault' ; New-LDCapitalCaseReport.ps1 -Archive '$Vault'" -ForegroundColor Gray
exit 0
