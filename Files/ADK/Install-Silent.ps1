<#
.SYNOPSIS
    Silent install: Windows ADK (Deployment Tools, USMT, ICD)
#>
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'adksetup.exe'
if (-not (Test-Path $exe)) { throw "Not found: $exe" }

$adkReg = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{cedb9b1c-f498-4834-ad4a-244cdecb604c}'
if (Test-Path $adkReg) { Write-Host 'ADK already installed - skipping.'; return }

Write-Host 'Installing Windows ADK (Deployment Tools, USMT, ICD)...'
$p = Start-Process -FilePath $exe -ArgumentList '/quiet /norestart /features OptionId.DeploymentTools OptionId.UserStateMigrationTool OptionId.ImagingAndConfigurationDesigner' -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "Install failed: exit $($p.ExitCode)" }
Write-Host "ADK installed (exit: $($p.ExitCode))."
