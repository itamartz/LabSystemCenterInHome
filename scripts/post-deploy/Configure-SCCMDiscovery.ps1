<#
.SYNOPSIS
    DSC-backed configuration of SCCM discovery methods for site PR1, using the
    ConfigMgrCBDsc module's resources in a Test -> Set-if-not-compliant pattern.
    Run AFTER step 8 (SCCM Primary installed). Idempotent by design.

.DESCRIPTION
    Project convention (2026-05-24): ALL SCCM configuration is DSC-backed via the
    ConfigMgrCBDsc module rather than raw Set-CM* cmdlets. This script configures:

      * CMSystemDiscovery    - delta 5 min; 60-day logon + computer-password
                               filters; full poll 7 days; OU=Servers + OU=Endpoints.
      * CMUserDiscovery      - delta 5 min; full poll 7 days; OU=Users.
                               (No stale filters - the resource/cmdlet has none.)
      * CMGroupDiscovery     - delta 5 min; 60-day logon + password filters;
                               full poll 7 days; scope "SADAB Groups" = OU=Groups.
      * CMForestDiscovery    - enabled; AD-site + subnet boundary creation OFF.
      * CMHeartbeatDiscovery - every 60 min (resource granularity is whole hours).
      * CMNetworkDiscovery   - disabled.

    WHY NOT Invoke-DscResource? On a site server it runs MOF resources out-of-process
    (the SYSTEM/WMI host) where $env:SMS_ADMIN_UI_PATH is not visible, so the module
    can't locate the console and fails with "Cannot bind argument to parameter 'Path'".
    Instead this script imports each DSC_<resource>.psm1 and calls Test-TargetResource
    / Set-TargetResource directly, in-process, as SADAB\Administrator (which has the
    console, the env var, and SCCM Full Administrator rights). Same module logic, no
    LCM, no .mof. Pre-loading the PR1 site drive makes the resources' own console-import
    short-circuit, so $env:SMS_ADMIN_UI_PATH is never even needed.

.PARAMETER SiteCode          ConfigMgr site code. Default 'PR1'.
.PARAMETER SiteServer        SMS provider FQDN. Default 'A-SCCM.sadab.pri'.
.PARAMETER BaseOU            Parent OU DN. Default 'OU=SADAB,DC=sadab,DC=pri'.
.PARAMETER DeltaMins         Delta interval (min) for the AD methods. Default 5.
.PARAMETER StaleLogonDays    Logon-recency filter (System+Group). Default 60.
.PARAMETER StalePasswordDays Computer-password filter (System+Group). Default 60.
.PARAMETER FullPollDays      Full discovery poll (days). Default 7.
.PARAMETER HeartbeatMins     Heartbeat interval (min); must be whole hours. Default 60.
.PARAMETER EnsureModule      Install ConfigMgrCBDsc from PSGallery if missing. Default $true.

.NOTES
    Author  : SADAB Lab
    Version : 2.0  (DSC-backed; supersedes the cmdlet-based v1)
    Requires: SCCM Primary site PR1 installed; ConfigMgrCBDsc on the site server
              (auto-installed when -EnsureModule, the default). Run from the Hyper-V
              host (Invoke-LabRemote prefers Hyper-V direct to A-SCCM).
    PS 5.1 only. Use Write-LabLog, never Write-Log (PowerCLI clash).
#>
[CmdletBinding()]
param(
    [string]$SiteCode          = 'PR1',
    [string]$SiteServer        = 'A-SCCM.sadab.pri',
    [string]$BaseOU            = 'OU=SADAB,DC=sadab,DC=pri',
    [int]   $DeltaMins         = 5,
    [int]   $StaleLogonDays    = 60,
    [int]   $StalePasswordDays = 60,
    [int]   $FullPollDays      = 7,
    [int]   $HeartbeatMins     = 60,
    [bool]  $EnsureModule      = $true,

    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force

$SccmAIP = '10.10.0.3'

# Build a domain credential if one wasn't supplied (standalone host runs).
if (-not $DomainCred) {
    if (-not $DomainAdminPassword) {
        throw "Provide -DomainCred or -DomainAdminPassword so the script can reach A-SCCM as SADAB\Administrator."
    }
    $DomainCred = New-Object System.Management.Automation.PSCredential(
        'SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

Write-LabLog "DSC-backed discovery config on $SiteServer (site $SiteCode) via ConfigMgrCBDsc..." -Step 'Discovery'

$results = Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    param($SiteCode,$SiteServer,$BaseOU,$DeltaMins,$StaleLogonDays,$StalePasswordDays,$FullPollDays,$HeartbeatMins,$EnsureModule)

    $ErrorActionPreference = 'Stop'

    if (($HeartbeatMins % 60) -ne 0) {
        throw "CMHeartbeatDiscovery granularity is whole hours; $HeartbeatMins min is not representable."
    }

    # --- Ensure ConfigMgrCBDsc is present ----------------------------------
    $mod = Get-Module -ListAvailable ConfigMgrCBDsc | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod) {
        if (-not $EnsureModule) {
            throw "ConfigMgrCBDsc not installed. Run 'Install-Module ConfigMgrCBDsc -Scope AllUsers' or pass -EnsureModule `$true."
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module ConfigMgrCBDsc -Scope AllUsers -Force -AllowClobber
        $mod = Get-Module -ListAvailable ConfigMgrCBDsc | Sort-Object Version -Descending | Select-Object -First 1
    }
    $dscRoot = Join-Path $mod.ModuleBase 'DSCResources'

    # --- Pre-load console + site drive so each resource's console-import
    #     short-circuits (it checks Test-Path "<SiteCode>:\") ----------------
    $uiPath = $env:SMS_ADMIN_UI_PATH
    if (-not $uiPath) { $uiPath = 'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\i386' }
    Import-Module (Join-Path (Split-Path $uiPath) 'ConfigurationManager.psd1') -ErrorAction Stop
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
    }

    # --- Test -> Set helper: only writes when not already compliant ---------
    function Invoke-CMResource {
        param([string]$Resource, [hashtable]$Property)
        $psm1 = Join-Path $dscRoot "DSC_$Resource\DSC_$Resource.psm1"
        Get-Module DSC_CM* | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module $psm1 -Force
        $before = [bool](Test-TargetResource @Property)
        if (-not $before) {
            Set-TargetResource @Property | Out-Null
            $after = [bool](Test-TargetResource @Property)
        } else {
            $after = $true
        }
        [pscustomobject]@{
            Resource     = $Resource
            WasCompliant = $before
            Action       = if ($before) { 'none (already compliant)' } else { 'Set applied' }
            NowCompliant = $after
        }
    }

    # Group discovery scope is an embedded-instance type; build it client-side.
    $scope = New-CimInstance -ClassName DSC_CMGroupDiscoveryScope `
        -Namespace 'root/microsoft/windows/desiredstateconfiguration' -ClientOnly `
        -Property @{ Name = 'SADAB Groups'; LdapLocation = "LDAP://OU=Groups,$BaseOU"; Recurse = $true }

    $out = @()

    $out += Invoke-CMResource -Resource 'CMSystemDiscovery' -Property @{
        SiteCode = $SiteCode; Enabled = $true
        EnableDeltaDiscovery = $true; DeltaDiscoveryMins = $DeltaMins
        EnableFilteringExpiredLogon = $true; TimeSinceLastLogonDays = $StaleLogonDays
        EnableFilteringExpiredPassword = $true; TimeSinceLastPasswordUpdateDays = $StalePasswordDays
        ScheduleInterval = 'Days'; ScheduleCount = $FullPollDays
        ADContainers = @("LDAP://OU=Servers,$BaseOU", "LDAP://OU=Endpoints,$BaseOU")
    }

    $out += Invoke-CMResource -Resource 'CMUserDiscovery' -Property @{
        SiteCode = $SiteCode; Enabled = $true
        EnableDeltaDiscovery = $true; DeltaDiscoveryMins = $DeltaMins
        ScheduleInterval = 'Days'; ScheduleCount = $FullPollDays
        ADContainers = @("LDAP://OU=Users,$BaseOU")
    }

    $out += Invoke-CMResource -Resource 'CMGroupDiscovery' -Property @{
        SiteCode = $SiteCode; Enabled = $true
        EnableDeltaDiscovery = $true; DeltaDiscoveryMins = $DeltaMins
        EnableFilteringExpiredLogon = $true; TimeSinceLastLogonDays = $StaleLogonDays
        EnableFilteringExpiredPassword = $true; TimeSinceLastPasswordUpdateDays = $StalePasswordDays
        ScheduleType = 'Days'; RecurInterval = $FullPollDays
        GroupDiscoveryScope = @($scope)
        DiscoverDistributionGroupMembership = $false
    }

    $out += Invoke-CMResource -Resource 'CMForestDiscovery' -Property @{
        SiteCode = $SiteCode; Enabled = $true
        EnableActiveDirectorySiteBoundaryCreation = $false
        EnableSubnetBoundaryCreation = $false
        ScheduleInterval = 'Days'; ScheduleCount = $FullPollDays
    }

    $out += Invoke-CMResource -Resource 'CMHeartbeatDiscovery' -Property @{
        SiteCode = $SiteCode; Enabled = $true
        ScheduleInterval = 'Hours'; ScheduleCount = ($HeartbeatMins / 60)
    }

    $out += Invoke-CMResource -Resource 'CMNetworkDiscovery' -Property @{
        SiteCode = $SiteCode; Enabled = $false
    }

    $out
} -ArgumentList $SiteCode,$SiteServer,$BaseOU,$DeltaMins,$StaleLogonDays,$StalePasswordDays,$FullPollDays,$HeartbeatMins,$EnsureModule

$results | Format-Table Resource, WasCompliant, Action, NowCompliant -AutoSize

if ($results | Where-Object { -not $_.NowCompliant }) {
    Write-LabLog 'One or more discovery resources are NOT compliant after Set - review output.' -Level ERROR -Step 'Discovery'
} else {
    Write-LabLog 'All discovery methods DSC-compliant (System/User/Group delta 5m + 60d logon/pwd filters, OU-scoped; Forest on/no-boundaries; Heartbeat 60m; Network off).' -Level SUCCESS -Step 'Discovery'
}
