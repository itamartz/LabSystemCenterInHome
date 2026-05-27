<#
.SYNOPSIS
    DSC-backed install of the Service Connection Point (SCP) role on the PRIMARY site
    server A-SCCM (ConfigMgrCBDsc CMServiceConnectionPoint, Test -> Set). Idempotent.
    Run from the Hyper-V host. PS 5.1 only. Use Write-LabLog.

.DESCRIPTION
    The Service Connection Point is the site's single bridge to the Microsoft cloud
    (servicing/update packages for Configuration Manager itself, cloud-attach, telemetry).
    There can be only ONE SCP per hierarchy and it lives on the CAS or the top-level
    primary - here the standalone primary A-SCCM.

    Mode 'Online' (the lab default): A-SCCM has internet via the Lab NAT switch, so the
    SCP keeps a live connection to Microsoft and can auto-download CM update packages.
    Use 'Offline' only on an isolated site (then ServiceConnectionTool.exe moves data
    by hand).

    Per the project convention, this is DSC-backed: import DSC_CMServiceConnectionPoint
    and call Test/Set-TargetResource in-process under SADAB\Administrator with the PR1:
    drive pre-created (Invoke-DscResource is unusable on a site server - see CLAUDE.md).

    PREREQ: A-SCCM is already an SMS Site System (it is - it's the primary). No extra OS
    prerequisites for the SCP role.

.NOTES
    Author  : SADAB Lab
    Version : 1.0 (DSC-backed).
    Requires: SCCM Primary PR1; ConfigMgrCBDsc on A-SCCM (auto-installed if -EnsureModule).
#>
[CmdletBinding()]
param(
    [string]$SiteCode      = 'PR1',
    [string]$SiteServer    = 'A-SCCM.sadab.pri',
    [ValidateSet('Online','Offline')]
    [string]$Mode          = 'Online',
    [bool]  $EnsureModule  = $true,

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

Write-LabLog "Installing Service Connection Point on $SiteServer (DSC, Mode=$Mode)..." -Step 'SCP'
$results = Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
    param($SiteCode,$SiteServer,$Mode,$EnsureModule)
    $ErrorActionPreference = 'Stop'; $CMPSSuppressFastNotUsedCheck = $true

    $mod = Get-Module -ListAvailable ConfigMgrCBDsc | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod) {
        if (-not $EnsureModule) { throw "ConfigMgrCBDsc not installed." }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module ConfigMgrCBDsc -Scope AllUsers -Force -AllowClobber
        $mod = Get-Module -ListAvailable ConfigMgrCBDsc | Sort-Object Version -Descending | Select-Object -First 1
    }
    $dscRoot = Join-Path $mod.ModuleBase 'DSCResources'
    Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1')
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null
    }

    function Invoke-CMResource {
        param([string]$Resource, [hashtable]$Property)
        $psm1 = Join-Path $dscRoot "DSC_$Resource\DSC_$Resource.psm1"
        Get-Module DSC_CM* | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module $psm1 -Force
        $before = [bool](Test-TargetResource @Property)
        if (-not $before) { Set-TargetResource @Property | Out-Null; $after = [bool](Test-TargetResource @Property) } else { $after = $true }
        [pscustomobject]@{ Resource=$Resource; WasCompliant=$before; Action=$(if($before){'none'}else{'Set'}); NowCompliant=$after }
    }

    Invoke-CMResource -Resource 'CMServiceConnectionPoint' -Property @{
        SiteCode=$SiteCode; SiteServerName=$SiteServer; Mode=$Mode; Ensure='Present' }
} -ArgumentList $SiteCode,$SiteServer,$Mode,$EnsureModule

$results | Format-Table Resource, WasCompliant, Action, NowCompliant -AutoSize
Write-LabLog "Service Connection Point requested on $SiteServer (Mode=$Mode). Role install is brief; watch SMS_SERVICE_CONNECTION_POINT in the console." -Level SUCCESS -Step 'SCP'
