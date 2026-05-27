<#
.SYNOPSIS
    Installs MP, DP, and SUP roles on A-MPDP and B-MPDP via SCCM PowerShell module.

.NOTES
    Author  : SADAB Lab
    Version : 2.0
    Requires: SCCM Primary Site must be installed (Step 8).
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

$SccmAIP = '10.10.0.3'
$MpDpServers = @(
    @{ FQDN = 'A-MPDP.sadab.pri'; SiteCode = 'PR1' }
    @{ FQDN = 'B-MPDP.sadab.pri'; SiteCode = 'PR1' }
)

Write-LabLog 'Installing MP/DP/SUP roles via SCCM PowerShell module...' -Step 'SCCMRoles'

Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    param($Servers)

    $modulePath = 'C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1'
    if (-not (Test-Path $modulePath)) {
        $modulePath = (Get-ChildItem 'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1' -ErrorAction SilentlyContinue).FullName
    }
    Import-Module $modulePath

    $siteCode = (Get-PSDrive | Where-Object { $_.Provider -like '*CM*' }).Name
    Push-Location "$($siteCode):"

    foreach ($server in $Servers) {
        $fqdn = $server.FQDN

        if (-not (Get-CMSiteSystemServer -SiteSystemServerName $fqdn -ErrorAction SilentlyContinue)) {
            New-CMSiteSystemServer -SiteSystemServerName $fqdn -SiteCode $server.SiteCode
        }

        if (-not (Get-CMManagementPoint -SiteSystemServerName $fqdn -ErrorAction SilentlyContinue)) {
            Add-CMManagementPoint -SiteSystemServerName $fqdn -SiteCode $server.SiteCode `
                                  -CommunicationClientType HttpsOrHttp
        }

        if (-not (Get-CMDistributionPoint -SiteSystemServerName $fqdn -ErrorAction SilentlyContinue)) {
            Add-CMDistributionPoint -SiteSystemServerName $fqdn -SiteCode $server.SiteCode
        }

        if (-not (Get-CMSoftwareUpdatePoint -SiteSystemServerName $fqdn -ErrorAction SilentlyContinue)) {
            Add-CMSoftwareUpdatePoint -SiteSystemServerName $fqdn -SiteCode $server.SiteCode `
                                      -WsusIisPort 8530 -WsusIisSslPort 8531
        }
    }

    Pop-Location
} -ArgumentList (,$MpDpServers) -TimeoutSec 1800

Write-LabLog 'MP/DP/SUP roles installed on A-MPDP and B-MPDP.' -Level SUCCESS -Step 'SCCMRoles'
