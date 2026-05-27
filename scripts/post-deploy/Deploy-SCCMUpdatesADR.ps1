<#
.SYNOPSIS
    Creates an update Deployment Package + an Automatic Deployment Rule (ADR) that deploys
    the LAST MONTH's Security + Critical updates as REQUIRED to the 'All Servers'
    collection, runs the rule, and distributes content to the DP (A-MPDP). Idempotent
    (check-exists). Run AFTER the SUP has synced (Configure-SCCMSoftwareUpdatePoint.ps1).

.DESCRIPTION
    DSC GAP / EXCEPTION: ConfigMgrCBDsc 4.0.0 has NO Automatic Deployment Rule resource, so
    the ADR (like applications) is the cmdlet-based, documented exception to the
    "all SCCM config is DSC-backed" convention. It is still made idempotent via Get-CM*
    checks before create.

    Steps (on A-SCCM):
      1. Deployment package on \\A-SCCM\Sources\Updates (reuses the 'Sources' share created
         by Deploy-SCCMApplications.ps1; the site server writes downloaded content here).
      2. New-CMSoftwareUpdateAutoDeploymentRule -> CollectionName 'All Servers',
         DateReleasedOrRevised Last1Month, UpdateClassification Critical+Security,
         Superseded $false, Required + available/deadline immediately, servers don't reboot.
      3. Invoke-CMSoftwareUpdateAutoDeploymentRule -> evaluates updates into a Software
         Update Group, downloads content into the package, queues distribution.
      4. Start-CMContentDistribution of the package to A-MPDP (ensures the DP has content).

    STAGES (default 'All' = Create -> Run -> Status):
      Create  package + ADR (no content yet)
      Run     invoke the rule + distribute package to the DP
      Status  print ADR, SUG membership, package download + distribution state

    GOTCHAS:
      * Servers: AllowRestart $false + SuppressRestartServer $true so the deadline install
        does NOT auto-reboot A-DFSR et al. (verify install, reboot on your own schedule).
      * DeployWithoutLicense $true so license-gated updates still deploy unattended.
      * Content download + DP distribution is async (patchdownloader.log / distmgr) - a
        month of Server 2025 Security/Critical content can be several GB. Re-run -Stage
        Status to watch it converge.

.NOTES
    Author  : SADAB Lab
    Version : 1.0 (cmdlet-based ADR; documented DSC exception).
    Run from the Hyper-V host. PS 5.1 only. Needs internet on A-SCCM (NAT switch).
#>
[CmdletBinding()]
param(
    [ValidateSet('All','Create','Run','Status')]
    [string]$Stage = 'All',

    [string]$SiteCode        = 'PR1',
    [string]$SiteServer      = 'A-SCCM.sadab.pri',
    [string]$CollectionName  = 'All Servers',
    [string]$DistributionPoint = 'A-MPDP.sadab.pri',
    [string]$RuleName        = 'Servers - Monthly Security + Critical',
    [string]$PackageName     = 'Monthly Server Updates',
    [string]$PackageSourceUNC= '\\A-SCCM.sadab.pri\Sources\Updates',
    [string[]]$Classifications = @('Critical Updates','Security Updates'),
    [string]$DateFilter      = 'Last1Month',
    # Scope the ADR to what the 'All Servers' collection can actually consume. Every lab
    # server is Windows Server 2025 (x64), so deploying Windows 11 / arm64 cumulatives would
    # be wasted multi-GB downloads on a disk-constrained site server (A-SCCM C: is ~64 GB).
    # The SUP still SYNCS the broader product set; only this deployment is narrowed.
    [string[]]$Architecture  = @('X64'),
    [string[]]$Product       = @('Microsoft Server Operating System-24H2'),

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
    param($Stage,$SiteCode,$SiteServer,$CollectionName,$DistributionPoint,$RuleName,$PackageName,$PackageSourceUNC,$Classifications,$DateFilter,$Architecture,$Product)
    $ErrorActionPreference = 'Stop'; $CMPSSuppressFastNotUsedCheck = $true

    # Local content-source folder behind the UNC share (site server == A-SCCM).
    # CRITICAL: the ADR content download runs as the site server (SYSTEM), which reaches the
    # UNC \\A-SCCM\Sources over SMB *loopback* as the computer account A-SCCM$. The original
    # 'Sources' share (from Deploy-SCCMApplications.ps1) granted Everyone READ only, so the
    # download was denied and the ADR reported "0 of N updates are downloaded" -> no
    # deployment. Grant the site server write on BOTH the share and NTFS (A-SCCM$ is a
    # Domain Computer; SYSTEM over loopback presents as the computer account).
    $local = 'C:\Sources\Updates'
    New-Item -ItemType Directory -Force $local | Out-Null
    if (-not (Get-SmbShare -Name 'Sources' -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name 'Sources' -Path 'C:\Sources' -FullAccess 'SADAB\Administrator' -ReadAccess 'Everyone' | Out-Null
    }
    Grant-SmbShareAccess -Name 'Sources' -AccountName 'SADAB\Domain Computers' -AccessRight Change -Force | Out-Null
    Grant-SmbShareAccess -Name 'Sources' -AccountName 'NT AUTHORITY\SYSTEM' -AccessRight Full -Force | Out-Null
    $hasNtfs = @((Get-Acl 'C:\Sources').Access | Where-Object { $_.IdentityReference -like '*Domain Computers' -and $_.FileSystemRights -match 'Modify|Write|FullControl' }).Count -gt 0
    if (-not $hasNtfs) {
        $acl = Get-Acl 'C:\Sources'
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('SADAB\Domain Computers','Modify','ContainerInherit,ObjectInherit','None','Allow')))
        Set-Acl 'C:\Sources' $acl
    }

    Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1')
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) { New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null }
    Set-Location "$($SiteCode):"

    function New-Stage-Create {
        $log = [ordered]@{}
        $pkg = Get-CMSoftwareUpdateDeploymentPackage -Name $PackageName -ErrorAction SilentlyContinue
        if (-not $pkg) { New-CMSoftwareUpdateDeploymentPackage -Name $PackageName -Path $PackageSourceUNC | Out-Null; $log.Package='created' } else { $log.Package='exists' }

        $adr = Get-CMSoftwareUpdateAutoDeploymentRule -Name $RuleName -Fast -ErrorAction SilentlyContinue
        if (-not $adr) {
            New-CMSoftwareUpdateAutoDeploymentRule -Name $RuleName -CollectionName $CollectionName `
                -DeploymentPackageName $PackageName -AddToExistingSoftwareUpdateGroup $false `
                -DateReleasedOrRevised $DateFilter -UpdateClassification $Classifications -Superseded $false `
                -Architecture $Architecture -Product $Product `
                -DeployWithoutLicense $true -DownloadFromMicrosoftUpdate $true -EnabledAfterCreate $true `
                -AvailableImmediately $true -DeadlineImmediately $true -UserNotification DisplaySoftwareCenterOnly `
                -AllowRestart $false -SuppressRestartServer $true -SuppressRestartWorkstation $true `
                -RunType DoNotRunThisRuleAutomatically -VerboseLevel OnlySuccessAndErrorMessages | Out-Null
            $log.ADR='created'
        } else { $log.ADR='exists' }
        [pscustomobject]$log
    }

    function New-Stage-Run {
        $log = [ordered]@{}
        Invoke-CMSoftwareUpdateAutoDeploymentRule -Name $RuleName -ErrorAction Stop
        $log.RuleRun='invoked'
        try { Start-CMContentDistribution -DeploymentPackageName $PackageName -DistributionPointName $DistributionPoint -ErrorAction Stop; $log.Distribute='started' }
        catch { $log.Distribute='already/pending' }
        [pscustomobject]$log
    }

    function New-Stage-Status {
        "=== ADR ==="
        Get-CMSoftwareUpdateAutoDeploymentRule -Name $RuleName -Fast | Select-Object Name, Enabled, LastRunTime, LastErrorCode | Format-List
        "=== Software Update Groups (from ADR) ==="
        $sugs = Get-CMSoftwareUpdateGroup -Fast | Where-Object { $_.LocalizedDisplayName -like "$RuleName*" }
        foreach ($s in $sugs) { "{0} : {1} updates" -f $s.LocalizedDisplayName, $s.NumberOfUpdates }
        "=== Deployment package distribution ==="
        Get-CMDistributionPointGroup -ErrorAction SilentlyContinue | Out-Null
        $pkg = Get-CMSoftwareUpdateDeploymentPackage -Name $PackageName -ErrorAction SilentlyContinue
        if ($pkg) {
            Get-WmiObject -Namespace "root\sms\site_$SiteCode" -Class SMS_PackageStatusDistPointsSummarizer -Filter "PackageID='$($pkg.PackageID)'" |
                Select-Object PackageID, @{n='State';e={switch($_.State){0{'INSTALLED'}1{'INSTALL_PENDING'}2{'INSTALL_RETRYING'}3{'INSTALL_FAILED'}4{'REMOVAL_PENDING'}5{'REMOVAL_RETRYING'}6{'REMOVAL_FAILED'}default{$_.State}}}}, SourceNALPath | Format-List
        }
        "=== Deployments to $CollectionName ==="
        Get-CMUpdateGroupDeployment -ErrorAction SilentlyContinue | Where-Object { $_.AssignmentName -like "$RuleName*" } | Select-Object AssignmentName, CollectionName, EnforcementDeadline | Format-List
    }

    switch ($Stage) {
        'Create' { New-Stage-Create }
        'Run'    { New-Stage-Run }
        'Status' { New-Stage-Status }
        'All'    { New-Stage-Create; New-Stage-Run; New-Stage-Status }
    }
}

Write-LabLog "ADR stage '$Stage' -> '$RuleName' (Required to $CollectionName, $DateFilter, $($Classifications -join '+'))..." -Step 'ADR'
$out = Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock $body `
        -ArgumentList $Stage,$SiteCode,$SiteServer,$CollectionName,$DistributionPoint,$RuleName,$PackageName,$PackageSourceUNC,$Classifications,$DateFilter,$Architecture,$Product
$out
Write-LabLog "ADR stage '$Stage' done. Content download + DP distribution are async; re-run -Stage Status to watch." -Level SUCCESS -Step 'ADR'
