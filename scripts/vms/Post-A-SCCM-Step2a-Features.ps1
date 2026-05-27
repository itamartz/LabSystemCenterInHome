<#
.SYNOPSIS
    Install SCCM prerequisite Windows features on A-SCCM. Run on VM directly.
    Prereqs: A-SCCM domain-joined, media share accessible.
#>
$ErrorActionPreference = 'Stop'
$MediaShare = '\\10.10.0.1\LabMedia'

$SccmFeatures = @(
    'NET-Framework-Core','NET-Framework-45-Core','NET-Framework-45-ASPNET'
    'NET-WCF-TCP-Activation45','NET-WCF-HTTP-Activation45','NET-WCF-TCP-PortSharing45'
    'RDC'
    'RSAT-AD-Tools','RSAT-AD-PowerShell'
)

# .NET 3.5 needs SxS source from media
$sxsPath = Join-Path $MediaShare 'SxS'
if (Test-Path $sxsPath) {
    Write-Host 'Installing .NET 3.5 from SxS source...'
    Install-WindowsFeature NET-Framework-Core -Source $sxsPath -ErrorAction SilentlyContinue | Out-Null
}

Write-Host "Installing features: $($SccmFeatures -join ', ')"
$result = Install-WindowsFeature $SccmFeatures -IncludeManagementTools
Write-Host "Result: $($result.ExitCode) | RestartNeeded: $($result.RestartNeeded)"
if ($result.RestartNeeded -eq 'Yes') { Write-Host 'REBOOT REQUIRED' }
Write-Host 'SCCM prerequisite features installed.'
