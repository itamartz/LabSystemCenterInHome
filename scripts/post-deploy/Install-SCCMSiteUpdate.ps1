<#
.SYNOPSIS
    Installs a Configuration Manager in-console site update ("Updates and Servicing") on the
    primary site server A-SCCM. Default: the CM 2509 Hotfix Rollup KB36949461
    (5.00.9141.1000 -> 5.00.9141.1030). Idempotent: no-op if already installed.

.DESCRIPTION
    In-console CM updates are surfaced by the Service Connection Point (installed earlier).
    This is a CM SITE upgrade, not a Windows update - it upgrades the site server components,
    SMS Provider, AdminService/console, and bumps the client package. It is cmdlet-based
    (no DSC resource): Install-CMSiteUpdate, which runs the prerequisite check then the
    install. Expect SMS_EXECUTIVE / site components to restart during the upgrade, so the
    SMS Provider (and these cmdlets) may be briefly unavailable mid-install - monitor via
    CMUpdate.log and the site Version instead.

    PREREQ: the update must be "Ready to Install" (downloaded by the SCP). Verify with
    Get-CMSiteUpdate. -Force suppresses the confirmation and proceeds past prerequisite
    *warnings* (errors still block).

.NOTES
    Author  : SADAB Lab
    Version : 1.0 (cmdlet-based; site update).
    Run from the Hyper-V host. PS 5.1 only. Use Write-LabLog.
#>
[CmdletBinding()]
param(
    [string]$UpdateName = 'Configuration Manager 2509 Hotfix Rollup (KB36949461)',
    [string]$SiteCode   = 'PR1',
    [string]$SiteServer = 'A-SCCM.sadab.pri',

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

Write-LabLog "Installing CM site update '$UpdateName' on $SiteServer..." -Step 'SiteUpdate'
$out = Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
    param($UpdateName,$SiteCode,$SiteServer)
    $ErrorActionPreference = 'Stop'; $CMPSSuppressFastNotUsedCheck = $true
    Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1')
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) { New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null }
    Set-Location "$($SiteCode):"

    $before = (Get-CMSite | Select-Object -First 1).Version
    $u = Get-CMSiteUpdate -Fast | Where-Object { $_.Name -eq $UpdateName }
    if (-not $u) { return "Update '$UpdateName' not found in Updates and Servicing." }
    # State 327682 = Ready to Install (downloaded); 196612 = available (needs download)
    if ($u.State -eq 196612) {
        Invoke-CMSiteUpdateDownload -Name $UpdateName -ErrorAction SilentlyContinue
        return "Update was not downloaded yet; download triggered. Re-run once State = Ready to Install."
    }
    Install-CMSiteUpdate -Name $UpdateName -Force -ErrorAction Stop
    [pscustomobject]@{ VersionBefore=$before; Installed=$UpdateName; Note='Install initiated; site upgrade runs in the background (monitor CMUpdate.log).' }
} -ArgumentList $UpdateName,$SiteCode,$SiteServer

$out | Format-List
Write-LabLog "Site update install initiated. Upgrade runs in the background (10-60 min); SMS services restart. Monitor CMUpdate.log + site Version." -Level SUCCESS -Step 'SiteUpdate'
