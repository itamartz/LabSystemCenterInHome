<#
.SYNOPSIS
    Install local prerequisites for the SCCM Management Point + Distribution Point
    roles. Run this directly on A-MPDP / B-MPDP BEFORE adding the MP/DP roles
    from the SCCM site server (A-SCCM).

.DESCRIPTION
    Self-contained, idempotent. This script does NOT add the MP or DP role to
    the SCCM site - that is still done from A-SCCM via Add-CMManagementPoint /
    Add-CMDistributionPoint (see scripts\post-deploy\11-Install-SCCM-Roles.ps1).

    What this script DOES install on the local VM:
      1. Windows features required by both roles:
         - BITS + BITS-IIS-Ext   (DP content download)
         - RDC                   (DP content distribution)
         - IIS (Web-Server) with the role services SCCM mandates
         - ISAPI Extensions / Filters
         - IIS 6 Metabase + WMI compatibility shims (Web-Metabase, Web-WMI)
      2. Visual C++ 2015-2022 Redistributable (x64) - prereq for ODBC 18
      3. Microsoft ODBC Driver 18 for SQL Server - mandatory since SCCM 2309
      4. SQL Server Native Client 11 (SQLNCLI11) - still used by some SCCM
         components on MP servers

    .NET / ASP.NET 4.5 IIS extensions (DISM bypass):
      The Management Point role REQUIRES Web-Asp-Net45. On WS2025 the
      payloads for Web-Net-Ext45 / Web-Asp-Net45 are "Removed" from the
      side-by-side store, AND Install-WindowsFeature -Source ... still
      contacts Windows Update before falling back to the source path
      (it fails with 0x8024402c on lab VMs that have no WU access).
      Workaround: call Enable-WindowsOptionalFeature -Online directly,
      which targets DISM and uses the local payload that ships in WS2025
      Eval without ever touching Windows Update. Section 2b below installs
      the IIS-NetFxExtensibility45 + IIS-ASPNET45 optional features this
      way. (Web-Net-Ext / Web-Asp-Net are the .NET 3.5 variants and are
      NOT required by SCCM 2309+.)

    All media is pulled from the lab media share \\10.10.0.1\LabMedia.

    After this script completes, run scripts\post-deploy\11-Install-SCCM-Roles.ps1
    from A-SCCM (or run Add-CMManagementPoint / Add-CMDistributionPoint by hand)
    to actually push the MP + DP roles onto this server.

.NOTES
    Target VMs : A-MPDP (10.10.0.5) and B-MPDP (10.20.0.5)
    Site Code  : PR1
    Run As     : SADAB\Administrator (elevated)
    Reboot     : Usually not required, but Install-WindowsFeature may request one.

    HTTP verbs reminder:
        SCCM MP needs: GET, POST, CCM_POST, HEAD, PROPFIND
        SCCM DP needs: GET, HEAD, PROPFIND
    These are configured automatically by SCCM when the role is pushed - this
    script only ensures the IIS request filtering module is present (via
    Web-Filtering) so that SCCM can edit applicationHost.config later.
#>
[CmdletBinding()]
param(
    [string]$MediaShare = '\\10.10.0.1\LabMedia'
)

$ErrorActionPreference = 'Stop'

# -- Banner ------------------------------------------------------------------
Write-Host ''
Write-Host '=== SCCM MP+DP Role Prereqs ===' -ForegroundColor Cyan
Write-Host "  Target  : $env:COMPUTERNAME"
Write-Host "  Media   : $MediaShare"
Write-Host ''

# -- 0. Elevation check ------------------------------------------------------
$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($id)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must be run from an elevated PowerShell session.'
}

# -- 1. Pre-flight checks ----------------------------------------------------

# 1a. Media share reachable?
if (-not (Test-Path $MediaShare)) {
    throw "Media share not reachable: $MediaShare"
}
Write-Host "  [OK] media share reachable"

# 1b. .NET 4.8 or later present?
$ndpKey = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
$release = (Get-ItemProperty -Path $ndpKey -Name Release -ErrorAction SilentlyContinue).Release
if (-not $release -or $release -lt 528040) {
    Write-Host "  [WARN] .NET 4.8 not detected (Release=$release). SCCM 2309+ requires .NET 4.6.2+; .NET 4.8 recommended." -ForegroundColor Yellow
} else {
    Write-Host "  [OK] .NET 4.8 present (Release=$release)"
}
Write-Host ''

# -- 2. Install Windows features --------------------------------------------
# Curated list - matches Microsoft Learn "Site and site system prerequisites"
# for Management Point and Distribution Point roles. Order matters less here
# than completeness; all are pulled in one Install-WindowsFeature call.
$Features = @(
    # BITS + RDC (DP)
    'BITS','BITS-IIS-Ext','RDC'

    # IIS core
    'Web-Server','Web-WebServer'
    'Web-Common-Http','Web-Default-Doc','Web-Static-Content'
    'Web-Http-Errors','Web-Http-Redirect'

    # IIS health/diagnostics + perf
    'Web-Http-Logging','Web-Log-Libraries','Web-Request-Monitor','Web-Http-Tracing'
    'Web-Stat-Compression','Web-Dyn-Compression'

    # IIS security
    'Web-Filtering','Web-Windows-Auth','Web-Basic-Auth'

    # IIS app dev (ISAPI only)
    # NOTE: Web-Net-Ext45 / Web-Asp-Net45 are intentionally OMITTED here -
    # Install-WindowsFeature fails for them on WS2025 (0x8024402c, see
    # synopsis). Section 2b enables them via DISM under their optional-
    # feature names IIS-NetFxExtensibility45 + IIS-ASPNET45.
    # Web-Net-Ext / Web-Asp-Net are the .NET 3.5 variants and are NOT
    # required by SCCM 2309+.
    'Web-ISAPI-Ext','Web-ISAPI-Filter'

    # IIS 6 management compatibility (REQUIRED by SCCM)
    # Note: Web-Lgcy-Mgmt-Console (IIS 6 MMC snap-in) was removed in WS2025;
    # SCCM only actually needs Web-Metabase + Web-WMI from this group.
    'Web-Mgmt-Compat','Web-Metabase','Web-WMI','Web-Lgcy-Scripting'

    # IIS management tools
    'Web-Mgmt-Console','Web-Mgmt-Service','Web-Scripting-Tools'
)

# Idempotency: skip the Install if everything is already present.
$missing = @()
foreach ($f in $Features) {
    $state = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
    if (-not $state -or -not $state.Installed) { $missing += $f }
}

if ($missing.Count -eq 0) {
    Write-Host "  [SKIP] all $($Features.Count) Windows features already installed" -ForegroundColor Yellow
} else {
    Write-Host "  Installing $($missing.Count) missing features (of $($Features.Count) required)..."
    $result = Install-WindowsFeature -Name $missing -IncludeManagementTools
    if (-not $result.Success) {
        throw "Install-WindowsFeature failed. ExitCode=$($result.ExitCode)"
    }
    Write-Host "  [OK] features installed (ExitCode=$($result.ExitCode))"
    if ($result.RestartNeeded -eq 'Yes') {
        Write-Host "  [WARN] reboot recommended (RestartNeeded=Yes) - reboot after this script finishes" -ForegroundColor Yellow
    }
}
Write-Host ''

# -- 2b. Enable IIS .NET 4.5 extensibility via DISM (WS2025 workaround) ------
# Install-WindowsFeature Web-Net-Ext45 / Web-Asp-Net45 fails on WS2025 with
# 0x8024402c because the Server Manager API contacts Windows Update before
# falling back to the local payload, even when the payload is present.
# Enable-WindowsOptionalFeature talks to DISM directly and uses the local
# WS2025 payload without ever touching WU. Names are the DISM equivalents
# of the Server Manager features:
#     Web-Net-Ext45  ==  IIS-NetFxExtensibility45
#     Web-Asp-Net45  ==  IIS-ASPNET45
$dismFeatures = @('IIS-NetFxExtensibility45','IIS-ASPNET45')
foreach ($df in $dismFeatures) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $df -ErrorAction SilentlyContinue).State
    if ($state -eq 'Enabled') {
        Write-Host "  [SKIP] $df already enabled" -ForegroundColor Yellow
    } else {
        Write-Host "  Enabling $df via DISM (state was: $state)..."
        $r = Enable-WindowsOptionalFeature -Online -FeatureName $df -All -NoRestart -ErrorAction Stop
        Write-Host "  [OK] $df enabled (RestartNeeded=$($r.RestartNeeded))"
    }
}
Write-Host ''

# -- 3. Install Visual C++ 2015-2022 Redistributable (x64) -------------------
# Required by ODBC Driver 18 for SQL Server.
$vcKey = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64'
if (Test-Path $vcKey) {
    $vcVer = (Get-ItemProperty $vcKey -ErrorAction SilentlyContinue).Version
    Write-Host "  [SKIP] VC++ Redist already installed ($vcVer)" -ForegroundColor Yellow
} else {
    $vcExe = Join-Path $MediaShare 'VCRedist\vc_redist.x64.exe'
    if (-not (Test-Path $vcExe)) { throw "VC++ Redist not found: $vcExe" }
    Write-Host "  Installing VC++ Redistributable from $vcExe ..."
    $p = Start-Process -FilePath $vcExe `
        -ArgumentList '/install','/quiet','/norestart' `
        -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -notin @(0, 3010)) { throw "VC++ Redist install failed: exit $($p.ExitCode)" }
    Write-Host "  [OK] VC++ Redist installed (exit=$($p.ExitCode))"
}
Write-Host ''

# -- 4. Install Microsoft ODBC Driver 18 for SQL Server ----------------------
# Hard requirement since SCCM 2309. SCCM client + MP both need it.
$odbcKey = 'HKLM:\SOFTWARE\Microsoft\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server'
if (Test-Path $odbcKey) {
    Write-Host "  [SKIP] ODBC 18 already installed" -ForegroundColor Yellow
} else {
    $odbcMsi = Join-Path $MediaShare 'ODBC18\msodbcsql18.msi'
    if (-not (Test-Path $odbcMsi)) { throw "ODBC 18 MSI not found: $odbcMsi" }
    Write-Host "  Installing ODBC 18 from $odbcMsi ..."
    $p = Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList "/i","`"$odbcMsi`"","/quiet","/norestart","IACCEPTMSODBCSQLLICENSETERMS=YES" `
        -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -notin @(0, 3010)) { throw "ODBC 18 install failed: exit $($p.ExitCode)" }
    Write-Host "  [OK] ODBC 18 installed (exit=$($p.ExitCode))"
}
Write-Host ''

# -- 5. Install SQL Server Native Client 11 (SQLNCLI11) ----------------------
# Legacy native client. Some SCCM components on the MP still expect it.
# It is no longer shipped with SQL Server, but the standalone MSI still
# installs cleanly on Windows Server 2025.
$ncliKey = 'HKLM:\SOFTWARE\Microsoft\SQLNCLI11'
if (Test-Path $ncliKey) {
    Write-Host "  [SKIP] SQL Server Native Client 11 already installed" -ForegroundColor Yellow
} else {
    $ncliMsi = Join-Path $MediaShare 'SQLNCLI\sqlncli.msi'
    if (-not (Test-Path $ncliMsi)) { throw "SQLNCLI MSI not found: $ncliMsi" }
    Write-Host "  Installing SQL Native Client from $ncliMsi ..."
    $p = Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList "/i","`"$ncliMsi`"","/qn","/norestart","IACCEPTSQLNCLILICENSETERMS=YES" `
        -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -notin @(0, 3010)) { throw "SQLNCLI install failed: exit $($p.ExitCode)" }
    Write-Host "  [OK] SQL Native Client installed (exit=$($p.ExitCode))"
}
Write-Host ''

# -- 6. Sanity checks --------------------------------------------------------
Write-Host '=== Post-install verification ===' -ForegroundColor Cyan

# 6a. IIS service running?
$w3svc = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
if ($w3svc -and $w3svc.Status -eq 'Running') {
    Write-Host "  [OK] W3SVC running"
} else {
    Write-Host "  [WARN] W3SVC not running ($($w3svc.Status)) - start it before adding the MP role" -ForegroundColor Yellow
}

# 6b. BITS service present?
$bits = Get-Service -Name BITS -ErrorAction SilentlyContinue
if ($bits) {
    Write-Host "  [OK] BITS service installed ($($bits.Status))"
} else {
    Write-Host "  [WARN] BITS service missing - DP role will fail" -ForegroundColor Yellow
}

# 6c. ODBC 18 driver listed?
try {
    $odbcDrivers = (Get-OdbcDriver -Platform 64-bit -ErrorAction Stop).Name
    if ($odbcDrivers -contains 'ODBC Driver 18 for SQL Server') {
        Write-Host "  [OK] ODBC Driver 18 visible to ODBC subsystem"
    } else {
        Write-Host "  [WARN] ODBC Driver 18 not in Get-OdbcDriver output" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [SKIP] Get-OdbcDriver not available - registry check only"
}

Write-Host ''
Write-Host '=== Prereqs complete ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Next steps (run from A-SCCM as SADAB\Administrator):' -ForegroundColor Yellow
Write-Host "   Import-Module 'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'"
Write-Host '   Set-Location PR1:'
Write-Host "   New-CMSiteSystemServer  -SiteSystemServerName '$env:COMPUTERNAME.sadab.pri' -SiteCode PR1"
Write-Host "   Add-CMManagementPoint   -SiteSystemServerName '$env:COMPUTERNAME.sadab.pri' -SiteCode PR1 -CommunicationClientType HttpsOrHttp"
Write-Host "   Add-CMDistributionPoint -SiteSystemServerName '$env:COMPUTERNAME.sadab.pri' -SiteCode PR1"
Write-Host ''
Write-Host 'Or run scripts\post-deploy\11-Install-SCCM-Roles.ps1 from the lab orchestrator.'
Write-Host ''
