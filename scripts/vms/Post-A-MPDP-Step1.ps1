<#
.SYNOPSIS
    Step 1: Join A-MPDP to domain. Run on Host A.
    Prereqs: A-DC promoted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$AdminPassword,
    [Parameter(Mandatory)] [string]$DomainAdminPassword
)

. "$PSScriptRoot\PostDeployHelpers.ps1"

$creds = New-LabCredentials -AdminPassword $AdminPassword -DomainAdminPassword $DomainAdminPassword
Join-LabDomain -IP '10.10.0.5' -VMName 'A-MPDP' -LocalCred $creds.Local -DomainCred $creds.Domain
