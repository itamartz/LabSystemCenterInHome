<#
.SYNOPSIS
    Silent install: SQL Server Reporting Services (SSRS)
#>
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'SQLServerReportingServices.exe'
if (-not (Test-Path $exe)) { throw "Not found: $exe" }

Write-Host 'Installing SQL Server Reporting Services...'
$p = Start-Process -FilePath $exe -ArgumentList '/quiet /norestart /IAcceptLicenseTerms /Edition=Dev' -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "Install failed: exit $($p.ExitCode)" }
Write-Host "SSRS installed (exit: $($p.ExitCode))."
