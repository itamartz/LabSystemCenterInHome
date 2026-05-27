<#
.SYNOPSIS
    Step 1: Join B-SCCM to domain. Run on Host A.
    Prereqs: A-DC promoted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$AdminPassword,
    [Parameter(Mandatory)] [string]$DomainAdminPassword
)

. "$PSScriptRoot\PostDeployHelpers.ps1"

$creds = New-LabCredentials -AdminPassword $AdminPassword -DomainAdminPassword $DomainAdminPassword
Join-LabDomain -IP '10.20.0.3' -VMName 'B-SCCM' -LocalCred $creds.Local -DomainCred $creds.Domain
