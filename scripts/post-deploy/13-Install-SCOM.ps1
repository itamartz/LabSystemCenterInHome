<#
.SYNOPSIS
    Installs SCOM 2025 Management Server on A-SCOM using A-SQLSCOM for databases.

.NOTES
    Author  : SADAB Lab
    Version : 1.0
    Note    : SCOM install takes 20-40 minutes.
#>
[CmdletBinding()]
param(
    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force

$ScomIP     = '10.10.0.40'
$MediaShare = $Global:LabConfig.MediaShareA
$MgmtGroup  = $Global:LabConfig.SCOMManageMent

Write-LabLog 'Installing SCOM prerequisites on A-SCOM...' -Step 'SCOM'
Invoke-LabRemote -IPAddress $ScomIP -Credential $DomainCred -ScriptBlock {
    Install-WindowsFeature NET-Framework-Core, NET-Framework-45-Core, `
                           Web-Server, Web-Asp-Net45, Web-Windows-Auth, `
                           Web-Mgmt-Console, Web-Mgmt-Compat `
                           -IncludeManagementTools | Out-Null
}

Write-LabLog "Installing SCOM Management Server (group: $MgmtGroup)..." -Step 'SCOM'
Invoke-LabRemote -IPAddress $ScomIP -Credential $DomainCred -ScriptBlock {
    param($Share, $MgmtGroup, $SqlServer, $DomCred)

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
} -ArgumentList $MediaShare, $MgmtGroup, 'A-SQLSCOM', $DomainCred

Write-LabLog 'SCOM installed on A-SCOM.' -Level SUCCESS -Step 'SCOM'
