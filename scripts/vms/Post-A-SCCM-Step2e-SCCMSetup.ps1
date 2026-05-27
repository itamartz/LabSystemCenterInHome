<#
.SYNOPSIS
    Install SCCM Primary Site PR1 on A-SCCM. Run on VM directly.
    Prereqs: Features, VCRedist, ODBC, ADK, AD schema extended, SQL on A-SQLSCCM,
             and SCCM prereq files pre-downloaded on the host at
             \\10.10.0.1\LabMedia\SCCM\PreReq (see scripts/Download-SCCMPrereqs.ps1).
    This takes 45-90 minutes. Runs setup via scheduled task to avoid timeout.
#>
$ErrorActionPreference = 'Stop'
$MediaShare    = '\\10.10.0.1\LabMedia'
$PrereqShare   = Join-Path $MediaShare 'SCCM\PreReq'
$LocalPrereqs  = 'C:\SCCMPrereqs'

# Check if SCCM already installed
$svc = Get-Service -Name 'SMS_Executive' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "SCCM already installed (SMS_Executive: $($svc.Status)) - skipping."
    return
}

$setupExe = Join-Path $MediaShare 'SCCM\SMSSETUP\BIN\X64\setup.exe'
if (-not (Test-Path $setupExe)) { throw "SCCM setup.exe not found: $setupExe" }

# Stage setup INI
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
PrerequisitePath=C:\SCCMPrereqs
AdminConsole=1
JoinCEIP=0

[SQLConfigOptions]
SQLServerName=A-SQLSCCM.sadab.pri
DatabaseName=CM_PR1
SQLSSBPort=4022

[CloudConnectorOptions]
CloudConnector=0
'@

Set-Content -Path 'C:\SCCMSetup.ini' -Value $SetupIni -Encoding Ascii
Write-Host 'Setup INI staged at C:\SCCMSetup.ini'

# Copy SCCM prereqs from host share (host pre-downloads them via Download-SCCMPrereqs.ps1)
if (-not (Test-Path $PrereqShare)) {
    throw "SCCM prereqs not found on host share: $PrereqShare. Run scripts/Download-SCCMPrereqs.ps1 on Host A first."
}
$shareCount = (Get-ChildItem -Path $PrereqShare -File -ErrorAction SilentlyContinue).Count
if ($shareCount -lt 20) {
    throw "SCCM prereq share appears incomplete ($shareCount files at $PrereqShare). Re-run Download-SCCMPrereqs.ps1 on Host A."
}
New-Item -ItemType Directory -Path $LocalPrereqs -Force | Out-Null
Write-Host "Copying SCCM prerequisites from $PrereqShare to $LocalPrereqs ($shareCount files)..."
$rc = Start-Process -FilePath 'robocopy.exe' `
    -ArgumentList "`"$PrereqShare`" `"$LocalPrereqs`" /E /NFL /NDL /NJH /NJS /NP /R:2 /W:5" `
    -Wait -PassThru -NoNewWindow
# robocopy exit codes 0-7 are success; 8+ indicate failure
if ($rc.ExitCode -ge 8) { throw "robocopy failed copying SCCM prereqs: exit $($rc.ExitCode)" }
Write-Host "Prerequisites staged locally (robocopy exit: $($rc.ExitCode))."

# Run setup via scheduled task (long-running, avoids session timeout)
$batchFile = 'C:\tmp\run-sccm-setup.cmd'
New-Item -ItemType Directory -Path 'C:\tmp' -Force | Out-Null
Set-Content -Path $batchFile -Value @"
"$setupExe" /SCRIPT "C:\SCCMSetup.ini" /NOUSERINPUT
echo %ERRORLEVEL% > "C:\tmp\sccm-setup-result.txt"
"@ -Encoding Ascii

schtasks /Create /TN "SCCMSetup" /TR $batchFile /SC ONCE /ST 00:00 /RU SADAB\Administrator /RP LabAdmin@2026! /RL HIGHEST /F
schtasks /Run /TN "SCCMSetup"
Start-Sleep -Seconds 5
schtasks /Delete /TN "SCCMSetup" /F 2>$null | Out-Null

Write-Host 'SCCM setup started as scheduled task.'
Write-Host 'Monitor progress: Get-Content C:\ConfigMgrSetup.log -Tail 5'
Write-Host 'Check completion: Get-Service SMS_Executive'
