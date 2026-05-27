<#
.SYNOPSIS
    Silent install: Visual C++ 2015-2022 Redistributable (x64)
    Run from media share or copy locally first.
#>
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'vc_redist.x64.exe'
if (-not (Test-Path $exe)) { throw "Not found: $exe" }

# Check if already installed
$installed = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64' -ErrorAction SilentlyContinue
if ($installed) { Write-Host "VC++ Redist already installed (v$($installed.Version)) - skipping."; return }

Write-Host 'Installing VC++ Redistributable...'
$p = Start-Process -FilePath $exe -ArgumentList '/install /quiet /norestart' -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "Install failed: exit $($p.ExitCode)" }
Write-Host "VC++ Redistributable installed (exit: $($p.ExitCode))."
