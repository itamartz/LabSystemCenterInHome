<#
.SYNOPSIS
    Silent install: Microsoft Report Builder
#>
$ErrorActionPreference = 'Stop'
$msi = Join-Path $PSScriptRoot 'ReportBuilder.msi'
if (-not (Test-Path $msi)) { throw "Not found: $msi" }

Write-Host 'Installing Report Builder...'
$p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "Install failed: exit $($p.ExitCode)" }
Write-Host "Report Builder installed (exit: $($p.ExitCode))."
