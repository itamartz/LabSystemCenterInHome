<#
.SYNOPSIS
    Imports the SCCM Management Pack into SCOM.

.NOTES
    Author  : SADAB Lab
    Version : 1.0
    Requires: SCOM installed (Step 13), SCCM Primary installed (Step 8)
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

Write-LabLog 'Importing SCCM Management Pack into SCOM...' -Step 'SCOM-MP'

Invoke-LabRemote -IPAddress $ScomIP -Credential $DomainCred -ScriptBlock {
    param($Share)

    Import-Module OperationsManager -ErrorAction Stop

    $mgServer = 'A-SCOM.sadab.pri'
    New-SCOMManagementGroupConnection -ComputerName $mgServer

    $mpPath = Join-Path $Share 'SCOM\ManagementPacks\Microsoft.SystemCenter.ConfigurationManager*.mp'
    $mpFiles = Get-Item $mpPath -ErrorAction SilentlyContinue

    if (-not $mpFiles) {
        $mpPath = '\\A-SCCM\C$\Program Files\Microsoft Configuration Manager\tools\*.mp'
        $mpFiles = Get-Item $mpPath -ErrorAction SilentlyContinue
    }

    if ($mpFiles) {
        foreach ($mp in $mpFiles) {
            Import-SCOMManagementPack -FullName $mp.FullName
            Write-Host "Imported MP: $($mp.Name)"
        }
    } else {
        Write-Host 'SCCM MP files not found — import manually from SCCM media.' -ForegroundColor Yellow
    }

    Start-Sleep -Seconds 30
} -ArgumentList $MediaShare

Write-LabLog 'SCCM Management Pack imported.' -Level SUCCESS -Step 'SCOM-MP'
Write-LabLog 'Lab deployment complete.' -Level SUCCESS
