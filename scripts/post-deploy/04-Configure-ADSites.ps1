<#
.SYNOPSIS
    Configures AD Sites and Services for the 2-site lab topology.
    Creates Site-A and Site-B, site subnets, and site link between them.

.NOTES
    Author  : SADAB Lab
    Version : 1.0
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

Invoke-LabRemote -IPAddress '10.10.0.2' -Credential $DomainCred -ScriptBlock {

    Import-Module ActiveDirectory

    # Force AD cmdlets to target the local DC explicitly (auto-discovery is flaky
    # over remote sessions on a freshly-promoted DC)
    $PSDefaultParameterValues = @{
        '*-AD*:Server' = 'localhost'
    }

    $defaultSite = 'Default-First-Site-Name'

    # Rename default site to Site-A
    if (Get-ADReplicationSite -Filter "Name -eq '$defaultSite'" -ErrorAction SilentlyContinue) {
        Get-ADReplicationSite $defaultSite | Rename-ADObject -NewName 'Site-A'
        Write-Host 'Renamed Default-First-Site-Name to Site-A'
    }

    # Create Site-B
    if (-not (Get-ADReplicationSite -Filter "Name -eq 'Site-B'" -ErrorAction SilentlyContinue)) {
        New-ADReplicationSite -Name 'Site-B'
        Write-Host 'Created Site-B'
    }

    # Create subnets
    $subnets = @(
        @{ Name = '10.10.0.0/24'; Site = 'Site-A'; Description = 'SCCM Lab Site A' }
        @{ Name = '10.20.0.0/24'; Site = 'Site-B'; Description = 'SCCM Lab Site B' }
    )
    foreach ($subnet in $subnets) {
        $subName = $subnet.Name
        if (-not (Get-ADReplicationSubnet -Filter "Name -eq '$subName'" -ErrorAction SilentlyContinue)) {
            New-ADReplicationSubnet -Name $subName `
                                    -Site $subnet.Site `
                                    -Location $subnet.Description
            Write-Host "Created subnet: $subName -> $($subnet.Site)"
        }
    }

    # Create site link
    if (-not (Get-ADReplicationSiteLink -Filter "Name -eq 'SiteLink-A-B'" -ErrorAction SilentlyContinue)) {
        New-ADReplicationSiteLink -Name 'SiteLink-A-B' `
                                  -SitesIncluded 'Site-A','Site-B' `
                                  -Cost 100 `
                                  -ReplicationFrequencyInMinutes 15 `
                                  -InterSiteTransportProtocol IP
        Write-Host 'Created site link: SiteLink-A-B'
    }

    Write-Host 'AD Sites and Services configured.' -ForegroundColor Green
}

Write-LabLog 'AD Sites and Services configured.' -Level SUCCESS -Step 'ADSites'
