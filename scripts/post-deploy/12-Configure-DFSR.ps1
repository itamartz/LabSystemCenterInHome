<#
.SYNOPSIS
    Installs DFS Replication role on A-DFSR and B-DFSR and configures
    a replication group between Site A and Site B.

.NOTES
    Author  : SADAB Lab
    Version : 2.0
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

$DfsrVMs   = @('10.10.0.7','10.20.0.7')
$DfsrFQDNs = @('A-DFSR.sadab.pri','B-DFSR.sadab.pri')
$ReplicatedFolder = 'C:\DFSRData'
$GroupName        = 'LabDFSRGroup'

foreach ($ip in $DfsrVMs) {
    Write-LabLog "Installing DFSR role on $ip..." -Step 'DFSR'
    Invoke-LabRemote -IPAddress $ip -Credential $DomainCred -ScriptBlock {
        Install-WindowsFeature FS-DFS-Replication -IncludeManagementTools | Out-Null
        New-Item -ItemType Directory -Path 'C:\DFSRData' -Force | Out-Null
    }
    Write-LabLog "DFSR installed on $ip." -Level SUCCESS -Step 'DFSR'
}

Write-LabLog "Configuring DFSR replication group '$GroupName'..." -Step 'DFSR'
Invoke-LabRemote -IPAddress '10.10.0.2' -Credential $DomainCred -ScriptBlock {
    param($GroupName, $Members, $Folder)

    Import-Module DFSR -ErrorAction SilentlyContinue

    if (-not (Get-DfsReplicationGroup -GroupName $GroupName -ErrorAction SilentlyContinue)) {
        New-DfsReplicationGroup -GroupName $GroupName | Out-Null

        foreach ($member in $Members) {
            Add-DfsrMember -GroupName $GroupName -ComputerName $member | Out-Null
        }

        Add-DfsrConnection -GroupName $GroupName `
                           -SourceComputerName $Members[0] `
                           -DestinationComputerName $Members[1] | Out-Null

        foreach ($member in $Members) {
            Set-DfsrMembership -GroupName $GroupName `
                               -FolderName 'LabData' `
                               -ContentPath $Folder `
                               -ComputerName $member `
                               -PrimaryMember ($member -eq $Members[0]) `
                               -Force | Out-Null
        }
    }
} -ArgumentList $GroupName, $DfsrFQDNs, $ReplicatedFolder

Write-LabLog 'DFSR replication configured.' -Level SUCCESS -Step 'DFSR'
