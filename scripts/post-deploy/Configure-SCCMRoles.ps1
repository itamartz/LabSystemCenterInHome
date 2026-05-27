<#
.SYNOPSIS
    DSC-backed install of the Management Point + Distribution Point roles on A-MPDP
    (ConfigMgrCBDsc, Test -> Set), plus the OS prerequisites. Run AFTER step 8.
    Idempotent.

.DESCRIPTION
    Per the project convention, SCCM config is DSC-backed via ConfigMgrCBDsc. This adds
    the client-facing roles that Phase 1 deliberately skipped, so clients can register
    (MP) and receive content (DP):

      1. OS prereqs on A-MPDP via Install-WindowsFeature (idempotent): IIS + BITS + RDC.
         The MP requires IIS/BITS pre-installed; the DP installs IIS itself but we
         pre-stage it anyway.
      2. CMSiteSystemServer  - registers A-MPDP as a site system (site server account).
      3. CMManagementPoint   - MP on A-MPDP, intranet, HTTP.
      4. CMDistributionPoint - DP on A-MPDP, HTTP, anonymous, joined to BG-Site-A.

    PREREQ already satisfied by the lab: the site server account A-SCCM$ (member of the
    AD group SCCM_Site_Servers) is a local Administrator on A-MPDP, so the site can push
    the role install. The same group/right also lets machine-account client push work.

    TIMING GOTCHAS (learned 2026-05-24):
      * The DP install is asynchronous (distmgr installs IIS config + content library
        over several minutes). The CMDistributionPoint Test returns $false immediately
        after Set until the DP finishes - that is expected, not a failure.
      * Packages that distmgr tries to send to the DP *while it is still installing*
        fail (status 2302) and then sleep for 3600s. Force them with the
        SMS_DistributionPoint RefreshNow WMI flag rather than waiting an hour (see
        Repair-SCCMContentDistribution in the comment block below).

.NOTES
    Author  : SADAB Lab
    Version : 1.0 (DSC-backed)
    Requires: SCCM Primary site PR1 installed; ConfigMgrCBDsc on A-SCCM (auto-installed).
              Run from the Hyper-V host. PS 5.1 only. Use Write-LabLog.
#>
[CmdletBinding()]
param(
    [string]$SiteCode      = 'PR1',
    [string]$SiteServer    = 'A-SCCM.sadab.pri',
    [string]$RoleServer    = 'A-MPDP.sadab.pri',
    [string]$BoundaryGroup = 'BG-Site-A',
    [bool]  $EnsureModule  = $true,

    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force
$SccmAIP   = '10.10.0.3'
$RoleIP    = '10.10.0.5'

if (-not $DomainCred) {
    if (-not $DomainAdminPassword) { throw "Provide -DomainCred or -DomainAdminPassword." }
    $DomainCred = New-Object System.Management.Automation.PSCredential('SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

# --- 1. OS prerequisites on the role server (idempotent) ---------------------
Write-LabLog "Installing IIS/BITS/RDC prerequisites on $RoleServer..." -Step 'Roles'
Invoke-LabRemote -IPAddress $RoleIP -Credential $DomainCred -ScriptBlock {
    $features = @('BITS','BITS-IIS-Ext','RDC','Web-Server','Web-Common-Http','Web-Default-Doc',
        'Web-Static-Content','Web-Http-Errors','Web-Net-Ext','Web-Net-Ext45','Web-Asp-Net',
        'Web-Asp-Net45','Web-ISAPI-Ext','Web-ISAPI-Filter','Web-Windows-Auth','Web-Metabase',
        'Web-WMI','Web-Mgmt-Console','Web-Mgmt-Compat','Web-Scripting-Tools')
    $r = Install-WindowsFeature -Name $features
    "Prereqs Success=$($r.Success) RestartNeeded=$($r.RestartNeeded)"
}

# --- 2-4. DSC roles on the site server ---------------------------------------
Write-LabLog "Installing site system + MP + DP on $RoleServer via ConfigMgrCBDsc..." -Step 'Roles'
$results = Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    param($SiteCode,$SiteServer,$RoleServer,$BoundaryGroup,$EnsureModule)
    $ErrorActionPreference = 'Stop'

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
    $uiPath = $env:SMS_ADMIN_UI_PATH
    if (-not $uiPath) { $uiPath = 'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\i386' }
    Import-Module (Join-Path (Split-Path $uiPath) 'ConfigurationManager.psd1') -ErrorAction Stop
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
    }

    function Invoke-CMResource {
        param([string]$Resource, [hashtable]$Property)
        $psm1 = Join-Path $dscRoot "DSC_$Resource\DSC_$Resource.psm1"
        Get-Module DSC_CM* | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module $psm1 -Force
        $before = [bool](Test-TargetResource @Property)
        if (-not $before) { Set-TargetResource @Property | Out-Null; $after = [bool](Test-TargetResource @Property) } else { $after = $true }
        [pscustomobject]@{ Resource=$Resource; WasCompliant=$before; Action=if($before){'none'}else{'Set'}; NowCompliant=$after }
    }

    $out = @()
    $out += Invoke-CMResource -Resource 'CMSiteSystemServer' -Property @{
        SiteCode=$SiteCode; SiteSystemServer=$RoleServer; UseSiteServerAccount=$true; Ensure='Present' }
    $out += Invoke-CMResource -Resource 'CMManagementPoint' -Property @{
        SiteCode=$SiteCode; SiteServerName=$RoleServer; ClientConnectionType='Intranet'; EnableSsl=$false; Ensure='Present' }
    $out += Invoke-CMResource -Resource 'CMDistributionPoint' -Property @{
        SiteCode=$SiteCode; SiteServerName=$RoleServer; ClientCommunicationType='Http'; EnableAnonymous=$true
        CertificateExpirationTimeUtc=((Get-Date).AddYears(10)); BoundaryGroups=@($BoundaryGroup); BoundaryGroupStatus='Add'; Ensure='Present' }
    # NOTE: CMDistributionPoint NowCompliant may be $false on first run - the DP install
    # is async (distmgr). Re-run after a few minutes; it converges once the DP is up.
    $out
} -ArgumentList $SiteCode,$SiteServer,$RoleServer,$BoundaryGroup,$EnsureModule

$results | Format-Table Resource, WasCompliant, Action, NowCompliant -AutoSize
Write-LabLog "MP + DP roles requested on $RoleServer. DP install is async (~5-15 min)." -Level SUCCESS -Step 'Roles'

<#
  --- Repair-SCCMContentDistribution (run on A-SCCM if packages are stuck) ---
  Packages distmgr tried to push while the DP was still installing fail with status
  2302 then sleep 3600s. Force redistribution immediately with the RefreshNow flag:

      foreach ($pkg in 'PR100004','PR100005') {   # client pkg + client upgrade pkg
          Get-WmiObject -Namespace 'root\sms\site_PR1' -Class SMS_DistributionPoint -Filter "PackageID='$pkg'" |
              ForEach-Object { $_.RefreshNow = $true; $_.Put() }
      }
#>
