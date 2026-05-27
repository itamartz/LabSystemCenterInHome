<#
.SYNOPSIS
    Silent install: SQL Server Management Studio (SSMS)
#>
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'SSMS-Setup-ENU.exe'
if (-not (Test-Path $exe)) { throw "Not found: $exe" }

$installed = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server Management Studio\*' -ErrorAction SilentlyContinue
if ($installed) { Write-Host "SSMS already installed - skipping."; return }

Write-Host 'Installing SSMS (this takes several minutes)...'
$p = Start-Process -FilePath $exe -ArgumentList '/install /quiet /norestart' -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "Install failed: exit $($p.ExitCode)" }
Write-Host "SSMS installed (exit: $($p.ExitCode))."
