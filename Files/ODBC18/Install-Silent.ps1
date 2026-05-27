<#
.SYNOPSIS
    Silent install: ODBC Driver 18 for SQL Server
    Prereq: VC++ Redistributable must be installed first.
#>
$ErrorActionPreference = 'Stop'
$msi = Join-Path $PSScriptRoot 'msodbcsql18.msi'
if (-not (Test-Path $msi)) { throw "Not found: $msi" }

$odbcKey = 'HKLM:\SOFTWARE\Microsoft\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server'
if (Test-Path $odbcKey) { Write-Host 'ODBC 18 already installed - skipping.'; return }

Write-Host 'Installing ODBC Driver 18...'
$p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msi`" /quiet /norestart IACCEPTMSODBCSQLLICENSETERMS=YES" -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "Install failed: exit $($p.ExitCode)" }
Write-Host "ODBC 18 installed (exit: $($p.ExitCode))."
