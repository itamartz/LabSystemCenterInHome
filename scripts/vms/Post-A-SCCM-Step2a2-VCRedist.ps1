<#
.SYNOPSIS
    Install Visual C++ 2015-2022 Redistributable (x64) on A-SCCM. Run on VM directly.
    Prereq for ODBC Driver 18 and several SCCM components.
#>
$ErrorActionPreference = 'Stop'
$MediaShare = '\\10.10.0.1\LabMedia'

$vcKey = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64'
if (Test-Path $vcKey) {
    $ver = (Get-ItemProperty $vcKey -ErrorAction SilentlyContinue).Version
    Write-Host "VC++ Redist already installed ($ver) - skipping."
    return
}

$vcExe = Join-Path $MediaShare 'VCRedist\vc_redist.x64.exe'
if (-not (Test-Path $vcExe)) { throw "VC++ Redist not found: $vcExe" }

Write-Host "Installing VC++ Redistributable from $vcExe..."
$p = Start-Process -FilePath $vcExe `
    -ArgumentList '/install /quiet /norestart' `
    -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "VC++ Redist install failed: exit $($p.ExitCode)" }
Write-Host "VC++ Redistributable installed (exit: $($p.ExitCode))."
