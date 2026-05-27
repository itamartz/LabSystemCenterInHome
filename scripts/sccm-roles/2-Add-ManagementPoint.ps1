<#
.SYNOPSIS
    Step 2 of 4 - Add the Management Point role to A-MPDP.
.DESCRIPTION
    Pushes the MP role onto A-MPDP. After this runs, SMS_SITE_COMPONENT_MANAGER
    on A-SCCM will remotely run MPSetup.exe against A-MPDP, which creates the
    IIS virtual directories /CCM_System, /CCM_Incoming, /SMS_MP and lays down
    C:\SMS_CCM\. Watch progress in C:\SMS_CCM\Logs\MPSetup.log on A-MPDP.
    Idempotent: skips if MP already exists.

    Manual / step-by-step counterpart to 11-Install-SCCM-Roles.ps1.
    Run from A-SCCM as SADAB\Administrator, elevated.
#>
$ErrorActionPreference = 'Stop'

$Server = 'A-MPDP.sadab.pri'
$Site   = 'PR1'

Write-Host ''
Write-Host '=== Step 2/4: Add-CMManagementPoint ===' -ForegroundColor Cyan
Write-Host "  Target : $Server"
Write-Host "  Site   : $Site"
Write-Host '  Comm   : HttpsOrHttp (accepts both HTTP and HTTPS clients)'
Write-Host ''

$mod = 'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
if (-not (Test-Path $mod)) { throw "ConfigMgr module not found: $mod" }
Import-Module $mod

Push-Location "${Site}:"
try {
    if (-not (Get-CMSiteSystemServer -SiteSystemServerName $Server -ErrorAction SilentlyContinue)) {
        throw "$Server is not a site system yet. Run 1-New-SiteSystemServer.ps1 first."
    }

    $mp = Get-CMManagementPoint -SiteSystemServerName $Server -ErrorAction SilentlyContinue
    if ($mp) {
        Write-Host "  [SKIP] MP already exists on $Server" -ForegroundColor Yellow
    } else {
        Write-Host '  Adding Management Point role ...'
        Add-CMManagementPoint -SiteSystemServerName $Server -SiteCode $Site -CommunicationClientType HttpsOrHttp | Out-Null
        Write-Host '  [OK] MP role queued (SMS_SITE_COMPONENT_MANAGER will install it)' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Verification:'
    Get-CMManagementPoint -SiteSystemServerName $Server |
        Select-Object NetworkOSPath, SiteCode, RoleName |
        Format-Table -AutoSize
} finally {
    Pop-Location
}

Write-Host ''
Write-Host '=== Step 2/4 complete ===' -ForegroundColor Cyan
Write-Host 'Watch the MP install progress on A-MPDP:'
Write-Host '  Get-Content C:\SMS_CCM\Logs\MPSetup.log -Tail 30 -Wait'
Write-Host 'Next: C:\Temp\3-Add-DistributionPoint.ps1'
Write-Host ''
