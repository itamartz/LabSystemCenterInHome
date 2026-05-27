<#
.SYNOPSIS
    DSC-backed client push installation settings (ConfigMgrCBDsc CMClientPushSettings),
    then triggers client push to the discovered servers. Run AFTER the MP+DP roles
    exist (Configure-SCCMRoles.ps1). Idempotent.

.DESCRIPTION
    Configures automatic, site-wide client push for servers (DSC), then kicks an
    explicit push at the named devices so the agent installs promptly.

      * CMClientPushSettings - EnableAutomaticClientPushInstallation, push to servers +
        site systems, NOT workstations, NOT domain controllers. InstallationProperty
        'SMSSITECODE=PR1'. No push account is configured: client push falls back to the
        site server machine account A-SCCM$, which is local admin on every target (via
        the SCCM_Site_Servers group / direct membership) - so machine-account push works.

      * Trigger: Install-CMClient -DeviceName <each> -AlwaysInstallClient.

    GOTCHAS (2026-05-24):
      * ccmsetup needs the client package (PR100004) on a DP the client can reach. If
        the DP just finished installing, the client package may not be distributed yet
        and ccmsetup loops with 0x87d00215 ("Failed to get DP locations"). Fix: force
        PR100004 distribution (RefreshNow - see Configure-SCCMRoles.ps1 comment).
      * ccmsetup returns code 7 (reboot required) but the client is operational; the
        device registers and shows healthy (Client=Yes, Active=Yes).
      * A-DC is NOT discovered (DCs live in OU=Domain Controllers, outside the discovery
        scope) so it is intentionally not a push target.

.NOTES
    Author  : SADAB Lab
    Version : 1.0 (DSC-backed). Run from the Hyper-V host. PS 5.1 only.
#>
[CmdletBinding()]
param(
    [string]$SiteCode    = 'PR1',
    [string]$SiteServer  = 'A-SCCM.sadab.pri',
    [string[]]$Targets   = @('A-SQLSCCM','A-SCCM','A-MPDP','A-DFSR'),
    [bool]  $EnsureModule = $true,
    [bool]  $TriggerPush = $true,

    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force
$SccmAIP = '10.10.0.3'
if (-not $DomainCred) {
    if (-not $DomainAdminPassword) { throw "Provide -DomainCred or -DomainAdminPassword." }
    $DomainCred = New-Object System.Management.Automation.PSCredential('SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

Write-LabLog "Configuring client push settings (DSC) + triggering push..." -Step 'ClientPush'
$results = Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    param($SiteCode,$SiteServer,$Targets,$EnsureModule,$TriggerPush)
    $ErrorActionPreference = 'Stop'
    $mod = Get-Module -ListAvailable ConfigMgrCBDsc | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod -and $EnsureModule) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module ConfigMgrCBDsc -Scope AllUsers -Force -AllowClobber
        $mod = Get-Module -ListAvailable ConfigMgrCBDsc | Sort-Object Version -Descending | Select-Object -First 1
    }
    $dscRoot = Join-Path $mod.ModuleBase 'DSCResources'
    $uiPath = $env:SMS_ADMIN_UI_PATH; if (-not $uiPath) { $uiPath = 'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\i386' }
    Import-Module (Join-Path (Split-Path $uiPath) 'ConfigurationManager.psd1') -ErrorAction Stop
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) { New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null }

    $psm1 = Join-Path $dscRoot 'DSC_CMClientPushSettings\DSC_CMClientPushSettings.psm1'
    Import-Module $psm1 -Force
    $p = @{ SiteCode=$SiteCode; EnableAutomaticClientPushInstallation=$true; EnableSystemTypeServer=$true
            EnableSystemTypeConfigurationManager=$true; EnableSystemTypeWorkstation=$false
            InstallClientToDomainController=$false; InstallationProperty='SMSSITECODE=PR1' }
    $before = [bool](Test-TargetResource @p)
    if (-not $before) { Set-TargetResource @p | Out-Null; $after = [bool](Test-TargetResource @p) } else { $after = $true }
    $out = @([pscustomobject]@{ Resource='CMClientPushSettings'; WasCompliant=$before; Action=if($before){'none'}else{'Set'}; NowCompliant=$after })

    if ($TriggerPush) {
        Set-Location "$($SiteCode):"
        foreach ($d in $Targets) {
            try { Install-CMClient -DeviceName $d -AlwaysInstallClient $true -IncludeDomainController $false -SiteCode $SiteCode -ErrorAction Stop; $out += "pushed: $d" }
            catch { $out += "push err ${d}: $($_.Exception.Message)" }
        }
    }
    $out
} -ArgumentList $SiteCode,$SiteServer,$Targets,$EnsureModule,$TriggerPush

$results
Write-LabLog "Client push configured + triggered. Agents install over the next several minutes." -Level SUCCESS -Step 'ClientPush'
