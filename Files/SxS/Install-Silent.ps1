<#
.SYNOPSIS
    Install .NET Framework 3.5 from SxS source (offline, no Windows Update)
#>
$ErrorActionPreference = 'Stop'

$feature = Get-WindowsFeature -Name NET-Framework-Core -ErrorAction SilentlyContinue
if ($feature -and $feature.Installed) { Write-Host '.NET 3.5 already installed - skipping.'; return }

Write-Host "Installing .NET Framework 3.5 from $PSScriptRoot..."
Install-WindowsFeature -Name NET-Framework-Core -Source $PSScriptRoot -ErrorAction Stop
Write-Host '.NET Framework 3.5 installed.'
