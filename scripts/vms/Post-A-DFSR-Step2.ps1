<#
.SYNOPSIS
    Step 2: Install DFS-Replication role on A-DFSR. Run on Host A.
    Note: DFSR replication group is configured later (cross-VM operation).
    Prereqs: A-DFSR domain-joined.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$DomainAdminPassword
)

. "$PSScriptRoot\PostDeployHelpers.ps1"

$creds = New-LabCredentials -AdminPassword $DomainAdminPassword -DomainAdminPassword $DomainAdminPassword
$IP    = '10.10.0.7'

Write-LabLog 'Installing DFS-Replication role...' -Step 'A-DFSR'
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -ScriptBlock {
    Install-WindowsFeature FS-DFS-Replication -IncludeManagementTools | Out-Null
    New-Item -ItemType Directory -Path 'C:\DFSRData' -Force | Out-Null
    Write-Host 'DFS-Replication role installed, C:\DFSRData created.'
}

Write-LabLog 'A-DFSR Step 2 complete.' -Level SUCCESS -Step 'A-DFSR'
