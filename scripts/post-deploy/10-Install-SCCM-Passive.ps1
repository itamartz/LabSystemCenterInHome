<#
.SYNOPSIS
    Installs SCCM Primary Site Server in Passive mode on B-SCCM.
    Uses the SCCM console on A-SCCM to add B-SCCM as a passive site server.

.NOTES
    Author  : SADAB Lab
    Version : 2.0
    Note    : Passive site server is added via the ConfigMgr console PowerShell,
              not by running setup.exe with /SCRIPT on B-SCCM directly.
#>
[CmdletBinding()]
param(
    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force

$SccmAIP    = '10.10.0.3'
$SccmBIP    = '10.20.0.3'
$MediaShare = $Global:LabConfig.MediaShareA

# Step 1: Install prerequisites on B-SCCM (ADK, ODBC, etc.)
Write-LabLog 'Installing ADK on B-SCCM...' -Step 'SCCMPassive'
Invoke-LabRemote -IPAddress $SccmBIP -Credential $DomainCred -TimeoutSec 600 -ScriptBlock {
    param($Share)
    $adkSetup = Join-Path $Share 'ADK\adksetup.exe'
    $peSetup  = Join-Path $Share 'ADKPE\adkwinpesetup.exe'

    if (Test-Path $adkSetup) {
        Start-Process -FilePath $adkSetup `
                      -ArgumentList '/quiet /norestart /features OptionId.DeploymentTools OptionId.UserStateMigrationTool OptionId.ImagingAndConfigurationDesigner' `
                      -Wait -NoNewWindow
    }
    if (Test-Path $peSetup) {
        Start-Process -FilePath $peSetup `
                      -ArgumentList '/quiet /norestart /features OptionId.WindowsPreinstallationEnvironment' `
                      -Wait -NoNewWindow
    }
} -ArgumentList $MediaShare

# Step 2: Add B-SCCM as passive site server via ConfigMgr PowerShell on A-SCCM
Write-LabLog 'Adding B-SCCM as passive site server via A-SCCM console...' -Step 'SCCMPassive'
Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -TimeoutSec 1800 -ScriptBlock {
    param($Share)

    $modulePath = 'C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1'
    if (-not (Test-Path $modulePath)) {
        $modulePath = (Get-ChildItem 'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1' -ErrorAction SilentlyContinue).FullName
    }
    if (-not $modulePath) { throw "ConfigMgr PowerShell module not found." }
    Import-Module $modulePath

    $siteCode = (Get-PSDrive | Where-Object { $_.Provider -like '*CM*' }).Name
    Push-Location "$($siteCode):"

    $bSccmFQDN = 'B-SCCM.sadab.pri'
    $sourceFilePath = Join-Path $Share 'SCCM'

    # Check if already added
    $existing = Get-CMSiteRole -SiteSystemServerName $bSccmFQDN -RoleName 'SMS Site Server' -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "B-SCCM is already a site server — skipping."
        Pop-Location
        return
    }

    # Add as site system server first
    if (-not (Get-CMSiteSystemServer -SiteSystemServerName $bSccmFQDN -ErrorAction SilentlyContinue)) {
        New-CMSiteSystemServer -SiteSystemServerName $bSccmFQDN -SiteCode $siteCode
    }

    # Add passive site server role
    New-CMPassiveSite -SiteSystemServerName $bSccmFQDN -InstallDirectory 'C:\Program Files\Microsoft Configuration Manager' `
                      -SourceFilePathOption CopySourceFileFromActiveSite

    Pop-Location

    Write-Host 'Passive site server role added. SCCM will install automatically on B-SCCM.'
} -ArgumentList $MediaShare

Write-LabLog 'SCCM Passive site server configured on B-SCCM.' -Level SUCCESS -Step 'SCCMPassive'
