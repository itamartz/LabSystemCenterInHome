<#
.SYNOPSIS
    DSC-backed configuration of SCCM boundaries and boundary groups for site PR1,
    using the ConfigMgrCBDsc module in a Test -> Set-if-not-compliant pattern.
    Run AFTER step 8 (SCCM Primary installed). Idempotent by design.

.DESCRIPTION
    Per the project convention, ALL SCCM configuration is DSC-backed via ConfigMgrCBDsc
    (see CLAUDE.md "SCCM Configuration Convention"). This script creates:

      * Boundary "Site A - 10.10.0.0/24"  - IP range 10.10.0.1-10.10.0.254
      * Boundary "Site B - 10.20.0.0/24"  - IP range 10.20.0.1-10.20.0.254
      * Boundary group "BG-Site-A"         - contains the Site A range boundary
      * Boundary group "BG-Site-B"         - contains the Site B range boundary

    IP RANGE boundaries are used (Microsoft recommends ranges over IP-subnet boundaries).
    Site B's boundary/group are defined now even though Host B is not built yet -
    boundaries are just metadata and this keeps the hierarchy ready.

    SITE SYSTEMS: left empty. No MP/DP roles exist yet (deliberately out of scope in
    Phase 1). Add site systems to these groups once those roles are installed.

    NOT MANAGED HERE: the "enable this boundary group for site assignment / assigned
    site code" flag is NOT exposed by the ConfigMgrCBDsc CMBoundaryGroups resource, so
    it is outside the DSC-backed surface. Enable it manually if/when needed.

    Resources/cmdlets, console import, and the in-process Test/Set rationale are the
    same as Configure-SCCMDiscovery.ps1 - Invoke-DscResource is avoided on the site
    server (it runs MOF resources out-of-process without $env:SMS_ADMIN_UI_PATH).

.PARAMETER SiteCode      ConfigMgr site code. Default 'PR1'.
.PARAMETER SiteServer    SMS provider FQDN. Default 'A-SCCM.sadab.pri'.
.PARAMETER SiteARange    Site A IP range boundary value. Default '10.10.0.1-10.10.0.254'.
.PARAMETER SiteBRange    Site B IP range boundary value. Default '10.20.0.1-10.20.0.254'.
.PARAMETER EnsureModule  Install ConfigMgrCBDsc from PSGallery if missing. Default $true.

.NOTES
    Author  : SADAB Lab
    Version : 1.0  (DSC-backed)
    Requires: SCCM Primary site PR1 installed; ConfigMgrCBDsc on the site server
              (auto-installed when -EnsureModule, the default). Run from the Hyper-V
              host (Invoke-LabRemote prefers Hyper-V direct to A-SCCM).
    PS 5.1 only. Use Write-LabLog, never Write-Log (PowerCLI clash).
#>
[CmdletBinding()]
param(
    [string]$SiteCode     = 'PR1',
    [string]$SiteServer   = 'A-SCCM.sadab.pri',
    [string]$SiteARange   = '10.10.0.1-10.10.0.254',
    [string]$SiteBRange   = '10.20.0.1-10.20.0.254',
    [bool]  $EnsureModule = $true,

    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force

$SccmAIP = '10.10.0.3'

if (-not $DomainCred) {
    if (-not $DomainAdminPassword) {
        throw "Provide -DomainCred or -DomainAdminPassword so the script can reach A-SCCM as SADAB\Administrator."
    }
    $DomainCred = New-Object System.Management.Automation.PSCredential(
        'SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

Write-LabLog "DSC-backed boundaries/boundary-groups config on $SiteServer (site $SiteCode)..." -Step 'Boundaries'

$results = Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    param($SiteCode,$SiteServer,$SiteARange,$SiteBRange,$EnsureModule)

    $ErrorActionPreference = 'Stop'

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

    # --- Pre-load console + site drive so resources' console-import short-circuits
    $uiPath = $env:SMS_ADMIN_UI_PATH
    if (-not $uiPath) { $uiPath = 'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\i386' }
    Import-Module (Join-Path (Split-Path $uiPath) 'ConfigurationManager.psd1') -ErrorAction Stop
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
    }

    # --- Test -> Set helper -------------------------------------------------
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
            Item         = if ($Property.ContainsKey('DisplayName')) { $Property.DisplayName } else { $Property.BoundaryGroup }
            WasCompliant = $before
            Action       = if ($before) { 'none (already compliant)' } else { 'Set applied' }
            NowCompliant = $after
        }
    }

    # Boundary + boundary-group model (one IP-range boundary + one group per site).
    $sites = @(
        @{ DisplayName = 'Site A - 10.10.0.0/24'; Value = $SiteARange; Group = 'BG-Site-A' }
        @{ DisplayName = 'Site B - 10.20.0.0/24'; Value = $SiteBRange; Group = 'BG-Site-B' }
    )

    $out = @()

    # 1) Boundaries first (groups reference them by Value + Type).
    foreach ($s in $sites) {
        $out += Invoke-CMResource -Resource 'CMBoundaries' -Property @{
            SiteCode    = $SiteCode
            DisplayName = $s.DisplayName
            Type        = 'IPRange'
            Value       = $s.Value
            Ensure      = 'Present'
        }
    }

    # 2) Boundary groups, each containing its site's range boundary. No site systems.
    foreach ($s in $sites) {
        $member = New-CimInstance -ClassName DSC_CMBoundaryGroupsBoundaries `
            -Namespace 'root/microsoft/windows/desiredstateconfiguration' -ClientOnly `
            -Property @{ Value = $s.Value; Type = 'IPRange' }

        $out += Invoke-CMResource -Resource 'CMBoundaryGroups' -Property @{
            SiteCode       = $SiteCode
            BoundaryGroup  = $s.Group
            Boundaries     = @($member)
            BoundaryAction = 'Match'
            Ensure         = 'Present'
        }
    }

    $out
} -ArgumentList $SiteCode,$SiteServer,$SiteARange,$SiteBRange,$EnsureModule

$results | Format-Table Resource, Item, WasCompliant, Action, NowCompliant -AutoSize

if ($results | Where-Object { -not $_.NowCompliant }) {
    Write-LabLog 'One or more boundary resources are NOT compliant after Set - review output.' -Level ERROR -Step 'Boundaries'
} else {
    Write-LabLog 'Boundaries DSC-compliant (Site A + Site B IP ranges; groups BG-Site-A / BG-Site-B; no site systems).' -Level SUCCESS -Step 'Boundaries'
}
