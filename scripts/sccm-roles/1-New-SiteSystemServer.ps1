<#
.SYNOPSIS
    Step 1 of 4 - Register A-MPDP as an SCCM site system server.
.DESCRIPTION
    Calls New-CMSiteSystemServer to create the site system entry in the
    SCCM database. This does NOT install any role - it just tells SCCM
    "this server exists, you can put roles on it".
    Idempotent: skips if already a site system.

    This is the manual / step-by-step counterpart to
    scripts\post-deploy\11-Install-SCCM-Roles.ps1, which runs all four
    role cmdlets in one shot. Run from A-SCCM as SADAB\Administrator,
    elevated. The deploy workflow stages this folder onto A-SCCM at
    C:\Temp\ (see scripts\sccm-roles\README.md).
#>
$ErrorActionPreference = 'Stop'

$Server = 'A-MPDP.sadab.pri'
$Site   = 'PR1'

Write-Host ''
Write-Host '=== Step 1/4: New-CMSiteSystemServer ===' -ForegroundColor Cyan
Write-Host "  Target : $Server"
Write-Host "  Site   : $Site"
Write-Host ''

$mod = 'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
if (-not (Test-Path $mod)) { throw "ConfigMgr module not found: $mod" }
Import-Module $mod

Push-Location "${Site}:"
try {
    $existing = Get-CMSiteSystemServer -SiteSystemServerName $Server -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  [SKIP] $Server is already a site system" -ForegroundColor Yellow
    } else {
        Write-Host "  Creating site system entry for $Server ..."
        New-CMSiteSystemServer -SiteSystemServerName $Server -SiteCode $Site | Out-Null
        Write-Host '  [OK] site system created' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Verification:'
    Get-CMSiteSystemServer -SiteSystemServerName $Server |
        Select-Object NetworkOSPath, SiteCode, RoleName |
        Format-Table -AutoSize
} finally {
    Pop-Location
}

Write-Host ''
Write-Host '=== Step 1/4 complete ===' -ForegroundColor Cyan
Write-Host 'Next: C:\Temp\2-Add-ManagementPoint.ps1'
Write-Host ''
