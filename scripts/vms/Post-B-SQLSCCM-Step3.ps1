<#
.SYNOPSIS
    Step 3: Install SSMS on B-SQLSCCM. Run on Host A.
    Prereqs: B-SQLSCCM domain-joined, media share accessible.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$DomainAdminPassword
)

. "$PSScriptRoot\PostDeployHelpers.ps1"

$creds = New-LabCredentials -AdminPassword $DomainAdminPassword -DomainAdminPassword $DomainAdminPassword
$IP    = '10.20.0.4'

Write-LabLog 'Installing SSMS on B-SQLSCCM...' -Step 'B-SQLSCCM'
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -TimeoutSec 600 -ScriptBlock {
    param($Share)

    $ssmsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{*SSMS*}'
    if (Get-Item $ssmsKey -ErrorAction SilentlyContinue) { Write-Host 'SSMS already installed.'; return }

    $ssmsExe = Join-Path $Share 'SSMS\SSMS-Setup-ENU.exe'
    if (-not (Test-Path $ssmsExe)) { throw "SSMS setup not found: $ssmsExe" }

    $result = Start-Process -FilePath $ssmsExe -ArgumentList '/install /quiet /norestart' -Wait -PassThru -NoNewWindow
    if ($result.ExitCode -notin @(0, 3010)) { throw "SSMS install failed: exit $($result.ExitCode)" }

    Write-Host 'SSMS installed.'
} -ArgumentList '\\10.10.0.1\LabMedia'

Write-LabLog 'B-SQLSCCM Step 3 complete.' -Level SUCCESS -Step 'B-SQLSCCM'
