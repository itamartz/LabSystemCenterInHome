<#
.SYNOPSIS
    Assigns specific software update(s) by KB ArticleID as a REQUIRED deployment to a
    collection: builds a Software Update Group, downloads the content to a deployment
    package, distributes to the DP, and deploys Required. Idempotent (check-exists).
    Default target: KB5087539 (Server 2025 24H2 cumulative) -> 'All Servers'.

.DESCRIPTION
    DSC GAP / EXCEPTION: ConfigMgrCBDsc has NO software-update-group or update-deployment
    resource (same family as the ADR/applications). So this is cmdlet-based, made
    idempotent with Get-CM* checks - the documented exception to the DSC-backed convention.

    Stages (default 'All' = Group -> Download -> Distribute -> Deploy, then prints Status):
      Group      New-CMSoftwareUpdateGroup with the ArticleId update(s) (ensure membership)
      Download   Save-CMSoftwareUpdate -> deployment package (downloads content, async/slow)
      Distribute Start-CMContentDistribution of the package to the DP
      Deploy     New-CMSoftwareUpdateDeployment Required to the collection
      Status     SUG membership, content provisioning, DP state, deployment, per-device

    SERVERS don't auto-reboot: deployment uses -RestartServer:$false so the deadline install
    won't force a reboot (verify, reboot on your own schedule).

    DISK: a Server 2025 24H2 "checkpoint" cumulative is ~12-13 GB of full-file content. The
    package source is on A-SCCM (C: ~100 GB) and the DP is A-MPDP (~35 GB free) - both fit
    one CU. Watch free space if you add more large updates.

.NOTES
    Author  : SADAB Lab
    Version : 1.0 (cmdlet-based; documented DSC exception).
    Run from the Hyper-V host. PS 5.1 only. Needs internet on A-SCCM (NAT switch).
#>
[CmdletBinding()]
param(
    [ValidateSet('All','Group','Download','Distribute','Deploy','Status')]
    [string]$Stage = 'All',

    [string[]]$ArticleId      = @('5087539'),
    [string]$SiteCode         = 'PR1',
    [string]$SiteServer       = 'A-SCCM.sadab.pri',
    [string]$CollectionName   = 'All Servers',
    [string]$DistributionPoint= 'A-MPDP.sadab.pri',
    [string]$GroupName        = 'All Servers - Server 2025 24H2 CU (KB5087539)',
    [string]$PackageName      = 'Monthly Server Updates',
    [string]$DeploymentName   = 'All Servers - KB5087539 (Required)',

    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force
$SccmIP = '10.10.0.3'
if (-not $DomainCred) {
    if (-not $DomainAdminPassword) { throw "Provide -DomainCred or -DomainAdminPassword." }
    $DomainCred = New-Object System.Management.Automation.PSCredential('SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

$body = {
    param($Stage,$ArticleId,$SiteCode,$SiteServer,$CollectionName,$DistributionPoint,$GroupName,$PackageName,$DeploymentName)
    $ErrorActionPreference = 'Stop'; $CMPSSuppressFastNotUsedCheck = $true
    Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1')
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) { New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null }
    Set-Location "$($SiteCode):"

    function Resolve-Updates {
        $u = foreach ($a in $ArticleId) { Get-CMSoftwareUpdate -ArticleId $a -Fast | Where-Object { -not $_.IsExpired -and -not $_.IsSuperseded } }
        if (-not $u) { throw "No non-expired/non-superseded update found for ArticleId(s): $($ArticleId -join ', ')" }
        $u
    }

    function Do-Group {
        $ups = Resolve-Updates
        $sug = Get-CMSoftwareUpdateGroup -Name $GroupName -ErrorAction SilentlyContinue
        if (-not $sug) {
            New-CMSoftwareUpdateGroup -Name $GroupName -SoftwareUpdate $ups | Out-Null
            "SUG created with $(@($ups).Count) update(s)"
        } else {
            # ensure each update is a member (idempotent add)
            Add-CMSoftwareUpdateToGroup -SoftwareUpdateGroupName $GroupName -SoftwareUpdate $ups -ErrorAction SilentlyContinue | Out-Null
            "SUG exists; membership ensured"
        }
    }

    function Do-Download {
        $sug = Get-CMSoftwareUpdateGroup -Name $GroupName
        # Save-CMSoftwareUpdate skips already-downloaded content; downloads the rest to the package.
        Save-CMSoftwareUpdate -SoftwareUpdateGroupName $GroupName -DeploymentPackageName $PackageName `
            -SoftwareUpdateLanguage 'English' -ErrorAction Stop | Out-Null
        "Save-CMSoftwareUpdate invoked (content download to '$PackageName' is async)"
    }

    function Do-Distribute {
        try { Start-CMContentDistribution -DeploymentPackageName $PackageName -DistributionPointName $DistributionPoint -ErrorAction Stop; "distribution started" }
        catch { "distribution already/pending: $($_.Exception.Message)" }
    }

    function Do-Deploy {
        # Get-CMSoftwareUpdateDeployment has no -SoftwareUpdateGroupName in this build; match by -Name.
        if (Get-CMSoftwareUpdateDeployment -Name $DeploymentName -ErrorAction SilentlyContinue) {
            "deployment already exists"
        } else {
            New-CMSoftwareUpdateDeployment -SoftwareUpdateGroupName $GroupName -CollectionName $CollectionName `
                -DeploymentName $DeploymentName -DeploymentType Required `
                -AvailableDateTime (Get-Date).AddMinutes(-5) -DeadlineDateTime (Get-Date).AddMinutes(-5) `
                -UserNotification DisplaySoftwareCenterOnly -RestartServer $false -RestartWorkstation $false `
                -ProtectedType RemoteDistributionPoint | Out-Null
            "Required deployment created -> $CollectionName"
        }
    }

    function Do-Status {
        $sug = Get-CMSoftwareUpdateGroup -Name $GroupName -ErrorAction SilentlyContinue
        "=== SUG ==="
        if ($sug) { "$($sug.LocalizedDisplayName) = $($sug.NumberOfUpdates) update(s)" } else { "SUG not present" }
        "=== Update content provisioning ==="
        foreach ($a in $ArticleId) { Get-CMSoftwareUpdate -ArticleId $a -Fast | Select-Object ArticleID, IsContentProvisioned, IsDeployed }
        "=== Deployment package DP state ==="
        $pkg = Get-CMSoftwareUpdateDeploymentPackage -Name $PackageName -ErrorAction SilentlyContinue
        if ($pkg) {
            Get-WmiObject -Namespace "root\sms\site_$SiteCode" -Class SMS_PackageStatusDistPointsSummarizer -Filter "PackageID='$($pkg.PackageID)'" |
                Select-Object PackageID, @{n='State';e={switch($_.State){0{'INSTALLED/OK'}1{'PENDING'}2{'RETRYING'}3{'FAILED'}default{$_.State}}}}
        }
        "=== Deployment ==="
        Get-CMSoftwareUpdateDeployment -Name $DeploymentName -ErrorAction SilentlyContinue | Select-Object AssignmentName, CollectionName, DeploymentIntent, EnforcementDeadline
    }

    switch ($Stage) {
        'Group'      { Do-Group }
        'Download'   { Do-Download }
        'Distribute' { Do-Distribute }
        'Deploy'     { Do-Deploy }
        'Status'     { Do-Status }
        # NOTE: this build's New-CMSoftwareUpdateDeployment refuses a SUG whose content
        # isn't downloaded yet ("objects ... are not yet downloaded"). So Deploy must come
        # AFTER Download completes. 'All' triggers the download but you must re-run -Stage
        # Deploy once -Stage Status shows IsContentProvisioned = True (the ~12.7 GB CU takes
        # a while). Order: Group -> Download -> Distribute -> (wait) -> Deploy.
        'All'        { Do-Group; Do-Download; Do-Distribute; "---"; Do-Status }
    }
}

Write-LabLog "Update->collection stage '$Stage': KB $($ArticleId -join ',') -> '$CollectionName' (Required)..." -Step 'UpdDeploy'
$out = Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock $body `
        -ArgumentList $Stage,$ArticleId,$SiteCode,$SiteServer,$CollectionName,$DistributionPoint,$GroupName,$PackageName,$DeploymentName
$out
Write-LabLog "Stage '$Stage' done. Content download + DP distribution are async; re-run -Stage Status to watch." -Level SUCCESS -Step 'UpdDeploy'
