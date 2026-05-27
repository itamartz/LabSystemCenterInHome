<#
.SYNOPSIS
    Silent install: SQL Server CLR Types
#>
$ErrorActionPreference = 'Stop'
$msi = Join-Path $PSScriptRoot 'SQLSysClrTypes.msi'
if (-not (Test-Path $msi)) { throw "Not found: $msi" }

Write-Host 'Installing SQL CLR Types...'
$p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "Install failed: exit $($p.ExitCode)" }
Write-Host "SQL CLR Types installed (exit: $($p.ExitCode))."
