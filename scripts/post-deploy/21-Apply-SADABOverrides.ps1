<#
.SYNOPSIS
    Applies lab-specific SCOM overrides for monitors that are noise in the
    SADAB environment. Overrides are stored in unsealed MPs named
    `SADAB_<source>_Overrides`, one per source MP family being overridden.

.NOTES
    Must run ON HOST B (uses Hyper-V direct PowerShell to B-SCOMMS).

    Naming convention (from the goal):
        SADAB_<source>_Overrides
    where <source> is a short identifier for the source MP (e.g. WindowsDefender,
    AD_DS_2016). One override MP per source MP family keeps the relationships
    clean - the unsealed MP only needs to reference the one sealed MP it's
    overriding into.

    DSC-style (per the "SCOM Configuration Convention" in CLAUDE.md):
    - Test (override MP exists AND has an override for the target monitor) ->
      Set (create/import the unsealed MP if missing, then Disable-SCOMMonitor
      against it to add the override).
    - Each (Source MP, Monitor name) pair is its own Test/Set unit.

    Catalogue of overrides being applied (extend by adding entries):

    | Source MP                       | Monitor disabled (FQN)                                                              | Why noise in lab        |
    |---------------------------------|-------------------------------------------------------------------------------------|-------------------------|
    | Microsoft.SQLServer.ReportingServices | Microsoft.SQLServer.ReportingServices.Windows.Monitor.Instance.MemoryUsageOnServer | Lab A-SCCM runs SCCM + SSRS + console on one ~4.6 GB VM. The MP's "non-SSRS processes consume too much memory" threshold is unrealistic for a single-VM lab; can't be fixed by adding RAM (host is RAM-constrained). |

    The Defender and AD-DS-NetworkAdapters monitors that used to be in this
    catalogue have been REMOVED - their root causes are fixed by script
    22-Fix-SCOMAlertRootCauses.ps1 (daily QuickScan + correct DC DNS).
    Keeping override-and-fix in lockstep avoids "monitor disabled even though
    it would now be Healthy" drift.

    The override creates a *class-level disable* (Enabled = false) on the
    monitor, which silences it for every targeted instance.
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SCOMMS',
    [string]$DomainAdminPassword = 'LabAdmin@2026!'
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][SADAB-Overrides] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

Write-Stage "Reconciling SADAB override MPs on $VMName ..."

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {

    Import-Module OperationsManager -ErrorAction Stop
    New-SCOMManagementGroupConnection -ComputerName 'B-SCOMMS.sadab.pri' | Out-Null

    # -------- helpers --------
    function Test-OverrideMpExists {
        param([string]$MpName)
        [bool](Get-SCOMManagementPack -Name $MpName -ErrorAction SilentlyContinue)
    }
    function Set-OverrideMpCreated {
        param([string]$MpName, [string]$Display, [string]$Description)
        # Build the minimal unsealed MP XML in %TEMP%, then import it.
        # An unsealed MP can be created via raw XML import; once present,
        # Disable-SCOMMonitor will add MonitorPropertyOverride elements into it.
        $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<ManagementPack ContentReadable="true" SchemaVersion="2.0" OriginalSchemaVersion="1.1" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <Manifest>
    <Identity>
      <ID>$MpName</ID>
      <Version>1.0.0.0</Version>
    </Identity>
    <Name>$Display</Name>
    <References />
  </Manifest>
  <LanguagePacks>
    <LanguagePack ID="ENU" IsDefault="true">
      <DisplayStrings>
        <DisplayString ElementID="$MpName">
          <Name>$Display</Name>
          <Description>$Description</Description>
        </DisplayString>
      </DisplayStrings>
    </LanguagePack>
  </LanguagePacks>
</ManagementPack>
"@
        $xmlPath = Join-Path $env:TEMP "$MpName.xml"
        Set-Content -Path $xmlPath -Value $xml -Encoding UTF8
        Import-SCOMManagementPack -FullName $xmlPath -ErrorAction Stop
    }
    function Test-MonitorDisabledInMp {
        param([string]$MonitorName, [string]$MpName)
        $mp = Get-SCOMManagementPack -Name $MpName -ErrorAction SilentlyContinue
        if (-not $mp) { return $false }
        # Get-SCOMOverride doesn't accept -ManagementPack in SCOM 2025;
        # use the SDK's GetOverrides() method on the MP object directly.
        $ovs = $mp.GetOverrides()
        if (-not $ovs) { return $false }
        [bool]($ovs | Where-Object {
            $_.Monitor -and
            $_.Monitor.GetElement().Name -eq $MonitorName -and
            $_.Property -eq 'Enabled' -and
            ([string]$_.Value -eq 'false' -or [string]$_.Value -eq 'False')
        })
    }
    function Set-MonitorDisabledInMp {
        param([string]$MonitorName, [string]$MpName)
        $mp = Get-SCOMManagementPack -Name $MpName
        $monitor = Get-SCOMMonitor -Name $MonitorName -ErrorAction Stop
        if (-not $monitor) { throw "Monitor not found: $MonitorName" }
        Disable-SCOMMonitor -Monitor $monitor -ManagementPack $mp -ErrorAction Stop
    }

    # -------- catalogue --------
    $catalogue = @(
        [PSCustomObject]@{
            OverrideMp   = 'SADAB_SSRS_Overrides'
            DisplayName  = 'SADAB SQL Server Reporting Services Overrides'
            Description  = 'Lab overrides for Microsoft.SQLServer.ReportingServices. Disables the MemoryUsageOnServer monitor that flags "non-SSRS processes use too much memory" - unavoidable on the single-VM lab A-SCCM that hosts SCCM + SSRS + Console with limited RAM.'
            MonitorNames = @('Microsoft.SQLServer.ReportingServices.Windows.Monitor.Instance.MemoryUsageOnServer')
        }
    )

    foreach ($entry in $catalogue) {
        Write-Host ("`n=== {0} ===" -f $entry.OverrideMp) -ForegroundColor Cyan

        # Step 1: ensure the unsealed override MP exists
        if (Test-OverrideMpExists -MpName $entry.OverrideMp) {
            Write-Host "[TEST PASS] MP exists - no create"
        } else {
            Write-Host "[SET]       creating unsealed MP..."
            Set-OverrideMpCreated -MpName $entry.OverrideMp -Display $entry.DisplayName -Description $entry.Description
            if (Test-OverrideMpExists -MpName $entry.OverrideMp) {
                Write-Host "[RE-TEST]   PASS"
            } else {
                Write-Host "[RE-TEST]   FAIL" -ForegroundColor Yellow ; continue
            }
        }

        # Step 2: ensure each named monitor is disabled in this MP
        foreach ($mName in $entry.MonitorNames) {
            if (Test-MonitorDisabledInMp -MonitorName $mName -MpName $entry.OverrideMp) {
                Write-Host ("  [TEST PASS] monitor disabled: {0}" -f $mName)
            } else {
                Write-Host ("  [SET]       disabling monitor: {0}" -f $mName)
                try {
                    Set-MonitorDisabledInMp -MonitorName $mName -MpName $entry.OverrideMp
                    if (Test-MonitorDisabledInMp -MonitorName $mName -MpName $entry.OverrideMp) {
                        Write-Host ("  [RE-TEST]   PASS")
                    } else {
                        Write-Host ("  [RE-TEST]   FAIL - override didn't land in {0}" -f $entry.OverrideMp) -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host ("  [SET FAIL]  {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                }
            }
        }
    }

    # -------- summary --------
    Write-Host "`n=== SADAB override MPs in management group ===" -ForegroundColor Cyan
    Get-SCOMManagementPack | Where-Object { $_.Name -like 'SADAB_*_Overrides' } |
        Sort-Object Name | Select-Object Name, Version, Sealed |
        Format-Table -AutoSize | Out-String | Write-Host

    Write-Host "=== Overrides in those MPs ===" -ForegroundColor Cyan
    $sadabMps = Get-SCOMManagementPack | Where-Object { $_.Name -like 'SADAB_*_Overrides' }
    foreach ($mp in $sadabMps) {
        Write-Host ("--- {0} ---" -f $mp.Name)
        $mp.GetOverrides() |
            Select-Object @{N='Monitor';E={if($_.Monitor){$_.Monitor.GetElement().Name}}}, Property, Value |
            Format-Table -AutoSize | Out-String | Write-Host
    }
}

Write-Stage "Done."
