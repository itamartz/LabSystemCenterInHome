<#
.SYNOPSIS
    Install Windows ADK and WinPE addon on A-SCCM. Run on VM directly.
#>
$ErrorActionPreference = 'Stop'
$MediaShare = '\\10.10.0.1\LabMedia'

# Check if ADK already installed
$adkReg = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{cedb9b1c-f498-4834-ad4a-244cdecb604c}'
if (Test-Path $adkReg) {
    Write-Host 'ADK already installed - skipping.'
} else {
    $adkSetup = Join-Path $MediaShare 'ADK\adksetup.exe'
    if (-not (Test-Path $adkSetup)) { throw "ADK setup not found: $adkSetup" }

    Write-Host 'Installing Windows ADK (Deployment Tools, USMT, ICD)...'
    $p = Start-Process -FilePath $adkSetup `
        -ArgumentList '/quiet /norestart /features OptionId.DeploymentTools OptionId.UserStateMigrationTool OptionId.ImagingAndConfigurationDesigner' `
        -Wait -PassThru -NoNewWindow
    Write-Host "ADK exit code: $($p.ExitCode)"
}

# WinPE addon
$peSetup = Join-Path $MediaShare 'ADKPE\adkwinpesetup.exe'
if (Test-Path $peSetup) {
    Write-Host 'Installing WinPE addon...'
    $p = Start-Process -FilePath $peSetup `
        -ArgumentList '/quiet /norestart /features OptionId.WindowsPreinstallationEnvironment' `
        -Wait -PassThru -NoNewWindow
    Write-Host "WinPE exit code: $($p.ExitCode)"
} else {
    Write-Host 'WinPE setup not found - skipping.'
}

Write-Host 'ADK installation complete.'
