<#
.SYNOPSIS
    Step 2: Install SCOM prereqs and Management Server on A-SCOM. Run on Host A.
    Prereqs: A-SCOM domain-joined, A-SQLSCOM with SQL installed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$DomainAdminPassword
)

. "$PSScriptRoot\PostDeployHelpers.ps1"

$creds      = New-LabCredentials -AdminPassword $DomainAdminPassword -DomainAdminPassword $DomainAdminPassword
$IP         = '10.10.0.40'
$MediaShare = '\\10.10.0.1\LabMedia'
$MgmtGroup  = 'LAB-SCOM-MG'

# ── Install SCOM prerequisites ───────────────────────────────────────────────
Write-LabLog 'Installing SCOM prerequisites...' -Step 'A-SCOM'
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -ScriptBlock {
    Install-WindowsFeature NET-Framework-Core, NET-Framework-45-Core, `
                           Web-Server, Web-Asp-Net45, Web-Windows-Auth, `
                           Web-Mgmt-Console, Web-Mgmt-Compat `
                           -IncludeManagementTools | Out-Null
}

# ── Install SCOM Management Server ──────────────────────────────────────────
Write-LabLog "Installing SCOM Management Server (group: $MgmtGroup)..." -Step 'A-SCOM'
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -TimeoutSec 1800 -ScriptBlock {
    param($Share, $MgmtGroup, $SqlServer, $DomCred)

    # Check if already installed
    $svc = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue
    if ($svc) { Write-Host 'SCOM already installed.'; return }

    $setupExe = Join-Path $Share 'SCOM\setup.exe'
    if (-not (Test-Path $setupExe)) { throw "SCOM setup.exe not found: $setupExe" }

    $scomArgs = @(
        '/silent'
        "/install:ManagementServer"
        "/ManagementGroupName:$MgmtGroup"
        "/SqlServerInstance:$SqlServer"
        "/DatabaseName:OperationsManager"
        "/DWSqlServerInstance:$SqlServer"
        "/DWDatabaseName:OperationsManagerDW"
        "/ActionAccountUser:$($DomCred.UserName)"
        "/ActionAccountPassword:$($DomCred.GetNetworkCredential().Password)"
        "/DASAccountUser:$($DomCred.UserName)"
        "/DASAccountPassword:$($DomCred.GetNetworkCredential().Password)"
        "/DataReaderUser:$($DomCred.UserName)"
        "/DataReaderPassword:$($DomCred.GetNetworkCredential().Password)"
        "/DataWriterUser:$($DomCred.UserName)"
        "/DataWriterPassword:$($DomCred.GetNetworkCredential().Password)"
        '/AcceptEndUserLicenseAgreement:1'
        '/EnableErrorReporting:Never'
        '/SendCEIPReports:0'
        '/UseMicrosoftUpdate:0'
    )

    $result = Start-Process -FilePath $setupExe -ArgumentList $scomArgs -Wait -PassThru -NoNewWindow
    if ($result.ExitCode -notin @(0, 3010)) {
        throw "SCOM install failed. Exit: $($result.ExitCode)"
    }

    Write-Host 'SCOM Management Server installed.'
} -ArgumentList $MediaShare, $MgmtGroup, 'A-SQLSCOM', $creds.Domain

Write-LabLog 'A-SCOM Step 2 complete.' -Level SUCCESS -Step 'A-SCOM'
