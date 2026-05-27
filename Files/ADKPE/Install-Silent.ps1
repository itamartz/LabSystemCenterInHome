<#
.SYNOPSIS
    Silent install: Windows PE addon for ADK
    Prereq: Windows ADK must be installed first.
#>
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'adkwinpesetup.exe'
if (-not (Test-Path $exe)) { throw "Not found: $exe" }

Write-Host 'Installing WinPE addon...'
$p = Start-Process -FilePath $exe -ArgumentList '/quiet /norestart /features OptionId.WindowsPreinstallationEnvironment' -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "Install failed: exit $($p.ExitCode)" }
Write-Host "WinPE addon installed (exit: $($p.ExitCode))."
