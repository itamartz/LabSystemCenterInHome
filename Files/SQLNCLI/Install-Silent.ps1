<#
.SYNOPSIS
    Silent install: SQL Server 2012 Native Client (SQLNCLI11)
#>
$ErrorActionPreference = 'Stop'
$msi = Join-Path $PSScriptRoot 'sqlncli.msi'
if (-not (Test-Path $msi)) { throw "Not found: $msi" }

$ncliKey = 'HKLM:\SOFTWARE\Microsoft\SQLNCLI11'
if (Test-Path $ncliKey) { Write-Host 'SQL Server Native Client 11 already installed - skipping.'; return }

Write-Host 'Installing SQL Server Native Client 11...'
$p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msi`" /qn /norestart IACCEPTSQLNCLILICENSETERMS=YES" -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "Install failed: exit $($p.ExitCode)" }
Write-Host "SQL Server Native Client installed (exit: $($p.ExitCode))."
