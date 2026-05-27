<#
.SYNOPSIS
    Install SCCM Primary Site PR1 on A-SCCM. Self-contained, run directly on the VM.

.DESCRIPTION
    Pre-staged install - assumes the SCCM media + prereqs are already on disk:
      - SCCM media at C:\temp\SCCM\Extracted  (setup.exe under SMSSETUP\BIN\X64)
      - SCCM prereqs at C:\temp\SCCM\PreReq   (already downloaded by setup /DOWNLOAD)

    Launches setup.exe with Start-Process and returns immediately. Setup runs in
    its own window and survives RDP disconnect (only logoff would kill it).
    Setup takes 45-90 minutes.

    Monitor progress with:
        Get-Content C:\ConfigMgrSetup.log -Tail 5 -Wait

    Done when 'Get-Service SMS_Executive' returns Running.

.NOTES
    Site Code   : PR1
    Site Name   : SADAB Lab
    Database    : A-SQLSCCM.sadab.pri / CM_PR1
    Install Dir : C:\Program Files\Microsoft Configuration Manager
    SQL SSB     : 4022
    Comm        : HTTPorHTTPS + ClientsUsePKICertificate=0  (enable Enhanced HTTP
                  in the console after install: Administration -> Site Configuration
                  -> Sites -> [PR1] -> Properties -> Communication Security)

    Run from an elevated PowerShell on A-SCCM as SADAB\Administrator.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# -- Paths -------------------------------------------------------------------
$SccmRoot  = 'C:\temp\SCCM'
$SetupExe  = "$SccmRoot\Extracted\SMSSETUP\BIN\X64\setup.exe"
$PrereqDir = "$SccmRoot\PreReq"
$IniPath   = 'C:\SCCMSetup.ini'

Write-Host ''
Write-Host '=== SCCM Primary Site Install (PR1) ===' -ForegroundColor Cyan
Write-Host ''

# -- 1. Pre-flight checks ----------------------------------------------------

# 1a. Already installed?
$svc = Get-Service -Name 'SMS_Executive' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "SCCM already installed (SMS_Executive: $($svc.Status)). Nothing to do." -ForegroundColor Yellow
    return
}

# 1b. setup.exe present?
if (-not (Test-Path $SetupExe)) {
    throw "SCCM setup.exe not found at $SetupExe"
}
Write-Host "  [OK] setup.exe at $SetupExe"

# 1c. Prereqs present?
if (-not (Test-Path $PrereqDir)) {
    throw "Prereq folder not found at $PrereqDir"
}
$prereqCount = (Get-ChildItem $PrereqDir -File -ErrorAction SilentlyContinue).Count
Write-Host "  [OK] $prereqCount prereq files in $PrereqDir"

# 1d. SQL reachable?
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect('A-SQLSCCM.sadab.pri', 1433)
    $tcp.Close()
    Write-Host '  [OK] A-SQLSCCM.sadab.pri:1433 reachable'
} catch {
    throw "Cannot reach A-SQLSCCM.sadab.pri:1433 - is the SQL service running on A-SQLSCCM?"
}

# 1e. Existing partial install? (cleanup safety net)
$cmDir = 'C:\Program Files\Microsoft Configuration Manager'
if (Test-Path $cmDir) {
    throw "Existing SCCM install folder at $cmDir - clean it up before re-running."
}
$cmReg = 'HKLM:\SOFTWARE\Microsoft\SMS'
if (Test-Path $cmReg) {
    throw "Existing SCCM registry key at $cmReg - clean it up before re-running."
}
Write-Host '  [OK] no existing SCCM install artifacts on this server'

# 1f. CM_PR1 database absent on A-SQLSCCM? (won't reuse a partial DB)
try {
    $dbCheck = Invoke-Expression 'sqlcmd -S A-SQLSCCM.sadab.pri -E -h-1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = ''CM_PR1''"' 2>$null
    if ($dbCheck -match '1') {
        throw "CM_PR1 database already exists on A-SQLSCCM - drop it before re-running (ALTER DATABASE CM_PR1 SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE CM_PR1)"
    }
    Write-Host '  [OK] CM_PR1 database does not exist on A-SQLSCCM'
} catch [System.Management.Automation.CommandNotFoundException] {
    Write-Host '  [SKIP] sqlcmd not installed - cannot pre-check CM_PR1 (setup will fail later if it exists)'
}

Write-Host ''

# -- 2. Write the setup INI --------------------------------------------------
# IMPORTANT: ASCII encoding (no UTF-8 BOM) - SCCM setup chokes on BOMs.
$SetupIni = @'
[Identification]
Action=InstallPrimarySite

[Options]
ProductID=EVAL
SiteCode=PR1
SiteName=SADAB Lab
SMSInstallDir=C:\Program Files\Microsoft Configuration Manager
SDKServer=A-SCCM.sadab.pri
RoleCommunicationProtocol=HTTPorHTTPS
ClientsUsePKICertificate=0
PrerequisiteComp=1
PrerequisitePath=C:\temp\SCCM\PreReq
AdminConsole=1
JoinCEIP=0

[SQLConfigOptions]
SQLServerName=A-SQLSCCM.sadab.pri
DatabaseName=CM_PR1
SQLSSBPort=4022

[CloudConnectorOptions]
CloudConnector=0
'@

Set-Content -Path $IniPath -Value $SetupIni -Encoding Ascii
Write-Host "  [OK] wrote $IniPath"

# -- 3. Launch setup ---------------------------------------------------------
# Start-Process returns immediately; setup.exe runs in its own window and
# survives RDP disconnect (only logoff would kill it).
$proc = Start-Process -FilePath $SetupExe `
                      -ArgumentList '/SCRIPT', "`"$IniPath`"", '/NOUSERINPUT' `
                      -PassThru
Write-Host "  [OK] setup.exe launched (PID $($proc.Id))"
Write-Host ''
Write-Host '=== Setup is running ===' -ForegroundColor Cyan
Write-Host '   Expected duration: 45-90 minutes'
Write-Host ''
Write-Host 'Monitor progress (live tail):'
Write-Host '   Get-Content C:\ConfigMgrSetup.log -Tail 5 -Wait' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Check completion (returns Running when install is done):'
Write-Host '   Get-Service SMS_Executive' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Check setup process is still running:'
Write-Host "   Get-Process -Id $($proc.Id) -ErrorAction SilentlyContinue" -ForegroundColor Yellow
Write-Host ''
