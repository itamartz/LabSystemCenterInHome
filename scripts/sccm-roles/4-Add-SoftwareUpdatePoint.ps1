<#
.SYNOPSIS
    Step 4 of 4 - Add the Software Update Point role to A-MPDP.
.DESCRIPTION
    The SUP is SCCM bridge to WSUS. Prerequisite: WSUS must already be
    installed on A-MPDP. This script first checks the WSUS feature on
    the target server, and bails with clear instructions if it is missing.
    If WSUS is present, calls Add-CMSoftwareUpdatePoint with the standard
    WSUS ports (8530 HTTP, 8531 HTTPS).
    Idempotent: skips if SUP already exists.

    Manual / step-by-step counterpart to 11-Install-SCCM-Roles.ps1.
    Run from A-SCCM as SADAB\Administrator, elevated.
#>
$ErrorActionPreference = 'Stop'

$Server = 'A-MPDP.sadab.pri'
$Site   = 'PR1'

Write-Host ''
Write-Host '=== Step 4/4: Add-CMSoftwareUpdatePoint ===' -ForegroundColor Cyan
Write-Host "  Target : $Server"
Write-Host "  Site   : $Site"
Write-Host '  Ports  : 8530 (HTTP) / 8531 (HTTPS)'
Write-Host ''

# Precheck: WSUS feature on A-MPDP
Write-Host 'Pre-check: Windows Server Update Services on the target ...'
try {
    $wsus = Invoke-Command -ComputerName $Server -ScriptBlock {
        Get-WindowsFeature UpdateServices | Select-Object -ExpandProperty Installed
    } -ErrorAction Stop
} catch {
    throw "Could not query $Server for WSUS state: $($_.Exception.Message)"
}

if (-not $wsus) {
    Write-Host ''
    Write-Host '  [BLOCKED] WSUS is NOT installed on A-MPDP.' -ForegroundColor Red
    Write-Host '  Add-CMSoftwareUpdatePoint requires the WSUS role on the target.'
    Write-Host ''
    Write-Host '  To install WSUS on A-MPDP, run THIS on A-MPDP (elevated):'
    Write-Host '    Install-WindowsFeature UpdateServices -IncludeManagementTools'
    Write-Host '    New-Item C:\WSUS -ItemType Directory -Force | Out-Null'
    Write-Host "    & 'C:\Program Files\Update Services\Tools\wsusutil.exe' postinstall CONTENT_DIR=C:\WSUS"
    Write-Host ''
    Write-Host '  Then re-run this script.'
    throw 'WSUS missing on target - SUP install aborted'
}
Write-Host '  [OK] WSUS is installed on A-MPDP'
Write-Host ''

$mod = 'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
if (-not (Test-Path $mod)) { throw "ConfigMgr module not found: $mod" }
Import-Module $mod

Push-Location "${Site}:"
try {
    if (-not (Get-CMSiteSystemServer -SiteSystemServerName $Server -ErrorAction SilentlyContinue)) {
        throw "$Server is not a site system yet. Run 1-New-SiteSystemServer.ps1 first."
    }

    $sup = Get-CMSoftwareUpdatePoint -SiteSystemServerName $Server -ErrorAction SilentlyContinue
    if ($sup) {
        Write-Host "  [SKIP] SUP already exists on $Server" -ForegroundColor Yellow
    } else {
        Write-Host '  Adding Software Update Point role ...'
        Add-CMSoftwareUpdatePoint -SiteSystemServerName $Server -SiteCode $Site -WsusIisPort 8530 -WsusIisSslPort 8531 | Out-Null
        Write-Host '  [OK] SUP role queued (SMS_WSUS_CONFIGURATION_MANAGER will configure it)' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Verification:'
    Get-CMSoftwareUpdatePoint -SiteSystemServerName $Server |
        Select-Object NetworkOSPath, SiteCode, RoleName |
        Format-Table -AutoSize
} finally {
    Pop-Location
}

Write-Host ''
Write-Host '=== Step 4/4 complete ===' -ForegroundColor Cyan
Write-Host 'Watch the SUP install/sync progress on A-SCCM:'
Write-Host '  Get-Content "C:\Program Files\Microsoft Configuration Manager\Logs\SUPSetup.log" -Tail 30 -Wait'
Write-Host '  Get-Content "C:\Program Files\Microsoft Configuration Manager\Logs\WCM.log"      -Tail 30 -Wait'
Write-Host 'First WSUS sync after SUP install can take 30+ minutes depending on classifications.'
Write-Host ''
