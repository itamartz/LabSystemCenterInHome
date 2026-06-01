<#
.SYNOPSIS
    Downloads and imports Kevin Holman's community-maintained MCM (Microsoft
    Configuration Manager) management pack into LAB-SCOM-MG.

.NOTES
    Must run ON HOST B (uses Hyper-V direct PowerShell to B-SCOMMS).

    DSC-style (per the "SCOM Configuration Convention" in CLAUDE.md):
    Test (Get-SCOMManagementPack -Name 'Microsoft.SystemCenter.MicrosoftConfigurationManager'
    matches >= the catalog version?) -> Set (BITS-download MECM.mp from
    GitHub raw, Import-SCOMManagementPack).

    Source: https://github.com/thekevinholman/MCM
        Single sealed MP file: MECM.mp (~258 KB)
        Catalog version 5.0.2303.2 (8/3/2023)

    Why this MP and not the Microsoft-shipped one: Microsoft deleted the
    legacy SCCM MP page from MS Download Center (id=34709 returns 404), and
    SCCM Current Branch 2509 doesn't ship a SCOM MP. Kevin Holman published
    a refreshed community version based on the SC 2012 ConfigMgr MP -
    rebranded for MCM / MECM, with the deprecated roles + manual-reset
    monitors removed and SMSExec disabled on Site Database Computers (so
    SQL DB servers don't get flagged).

    What it discovers in our lab (auto-discovery, takes up to 24h for full
    coverage, ~60 min for site systems):
        - Site object (PR1)
        - Site Database (CM_PR1 on A-SQLSCCM)
        - Site System Server roles on A-SCCM / A-MPDP / B-MPDP
        - Management Point + Distribution Point on A-MPDP / B-MPDP
        - MECM Clients (the 4 SCCM-managed servers)

    Per the README, the MP defaults to monitoring SccmPxe (not wdsserver)
    for PXE role. If our lab ever turns on PXE via WDS, swap the default
    override.
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SCOMMS',
    [string]$DomainAdminPassword = 'LabAdmin@2026!'
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][MCM-MP] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

Write-Stage "Reconciling MCM management pack on $VMName ..."

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {

    Import-Module OperationsManager -ErrorAction Stop
    New-SCOMManagementGroupConnection -ComputerName 'B-SCOMMS.sadab.pri' | Out-Null

    # The MP's actual Name (post-import) is 'MECM' with DisplayName
    # 'Microsoft Configuration Manager'. Kept short by the author rather
    # than the conventional Microsoft.SystemCenter.* prefix.
    $mpName       = 'MECM'
    $requiredVer  = [version]'5.0.2303.2'
    $downloadUrl  = 'https://raw.githubusercontent.com/thekevinholman/MCM/main/MECM.mp'
    $downloadDest = 'C:\HyperV-Lab-Local\MPs-Download\MECM.mp'

    function Test-McmMpImported {
        param([version]$Required)
        $mp = Get-SCOMManagementPack -Name $mpName -ErrorAction SilentlyContinue
        if (-not $mp) { return $false }
        return ([version]$mp.Version -ge $Required)
    }
    function Set-McmMpImported {
        param([string]$Url, [string]$Dest)
        $dir = Split-Path $Dest -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (-not (Test-Path $Dest)) {
            Write-Host "  download: $Url"
            $ProgressPreference = 'SilentlyContinue'
            Start-BitsTransfer -Source $Url -Destination $Dest -ErrorAction Stop
            Write-Host "  saved: $Dest ($([math]::Round((Get-Item $Dest).Length/1KB,1)) KB)"
        } else {
            Write-Host "  download: already on disk ($Dest)"
        }
        Write-Host "  Import-SCOMManagementPack ..."
        Import-SCOMManagementPack -FullName $Dest -ErrorAction Stop
    }

    if (Test-McmMpImported -Required $requiredVer) {
        Write-Host "[TEST PASS] MCM MP already imported at version >= $requiredVer - no action"
    } else {
        Write-Host "[SET]       importing MCM MP (Kevin Holman v$requiredVer) ..."
        Set-McmMpImported -Url $downloadUrl -Dest $downloadDest
        if (Test-McmMpImported -Required $requiredVer) {
            Write-Host "[RE-TEST]   PASS"
        } else {
            Write-Host "[RE-TEST]   FAIL - investigate manually" -ForegroundColor Yellow
        }
    }

    Write-Host "`n=== MCM-related MPs in management group ===" -ForegroundColor Cyan
    Get-SCOMManagementPack | Where-Object { $_.Name -match 'ConfigurationManager|MECM|MCM\.' } |
        Sort-Object Name | Select-Object Name, DisplayName, Version, Sealed |
        Format-Table -AutoSize | Out-String -Width 220 | Write-Host

    Write-Host "=== MCM classes (samples) ===" -ForegroundColor Cyan
    Get-SCOMClass | Where-Object { $_.Name -match 'MECM\.|MicrosoftConfigurationManager' } |
        Sort-Object Name | Select-Object -First 25 Name |
        Format-Table -AutoSize | Out-String -Width 220 | Write-Host
}

Write-Stage 'Done. Discoveries populate over the next ~60 min for site systems and ~24 h for clients.'
