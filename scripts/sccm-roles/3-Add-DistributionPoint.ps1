<#
.SYNOPSIS
    Step 3 of 4 - Add the Distribution Point role to A-MPDP.
.DESCRIPTION
    Pushes the DP role onto A-MPDP. After this runs, SMS_DISTRIBUTION_MANAGER
    on A-SCCM remotely runs distmgr against A-MPDP, which provisions the IIS
    virtual directories /SMS_DP_SMSPKG$ and /SMS_DP_SMSSIG$, builds the
    SMSPKGD$ content library on the largest local disk, generates the DP
    self-signed cert, and turns on BITS. Watch progress in
    C:\SMS_DP$\sms\logs\smsdpprov.log on A-MPDP.
    Idempotent: skips if DP already exists.

    Manual / step-by-step counterpart to 11-Install-SCCM-Roles.ps1.
    Run from A-SCCM as SADAB\Administrator, elevated.
#>
$ErrorActionPreference = 'Stop'

$Server = 'A-MPDP.sadab.pri'
$Site   = 'PR1'

Write-Host ''
Write-Host '=== Step 3/4: Add-CMDistributionPoint ===' -ForegroundColor Cyan
Write-Host "  Target : $Server"
Write-Host "  Site   : $Site"
Write-Host ''

$mod = 'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
if (-not (Test-Path $mod)) { throw "ConfigMgr module not found: $mod" }
Import-Module $mod

Push-Location "${Site}:"
try {
    if (-not (Get-CMSiteSystemServer -SiteSystemServerName $Server -ErrorAction SilentlyContinue)) {
        throw "$Server is not a site system yet. Run 1-New-SiteSystemServer.ps1 first."
    }

    $dp = Get-CMDistributionPoint -SiteSystemServerName $Server -ErrorAction SilentlyContinue
    if ($dp) {
        Write-Host "  [SKIP] DP already exists on $Server" -ForegroundColor Yellow
    } else {
        Write-Host '  Adding Distribution Point role ...'
        Add-CMDistributionPoint -SiteSystemServerName $Server -SiteCode $Site | Out-Null
        Write-Host '  [OK] DP role queued (SMS_DISTRIBUTION_MANAGER will install it)' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Verification:'
    Get-CMDistributionPoint -SiteSystemServerName $Server |
        Select-Object NetworkOSPath, SiteCode, RoleName |
        Format-Table -AutoSize
} finally {
    Pop-Location
}

Write-Host ''
Write-Host '=== Step 3/4 complete ===' -ForegroundColor Cyan
Write-Host 'Watch the DP install progress on A-MPDP:'
Write-Host '  Get-Content "C:\SMS_DP$\sms\logs\smsdpprov.log" -Tail 30 -Wait'
Write-Host 'Or on A-SCCM:'
Write-Host '  Get-Content "C:\Program Files\Microsoft Configuration Manager\Logs\distmgr.log" -Tail 30 -Wait'
Write-Host 'Next: C:\Temp\4-Add-SoftwareUpdatePoint.ps1   (requires WSUS on A-MPDP - see precheck inside)'
Write-Host ''
