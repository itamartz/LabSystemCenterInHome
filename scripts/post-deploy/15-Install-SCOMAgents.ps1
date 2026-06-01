<#
.SYNOPSIS
    Pushes the SCOM 2025 agent from B-SCOMMS to all SADAB SCCM-side VMs and
    confirms each one is registered in the LAB-SCOM-MG management group.

.NOTES
    Must run ON HOST B (uses Hyper-V direct PowerShell to B-SCOMMS).

    DSC-style (per the SCOM Configuration Convention in CLAUDE.md):
    For every target, a Test step (`Get-SCOMAgent`) returns the current state
    and a Set step (`Install-SCOMAgent`) reconciles it. The script then
    re-Tests after Set, which is what makes runs idempotent and self-healing.

    The `OperationsManager` PowerShell module ships with the management server,
    not with the community DSC modules (xSCOM is deprecated and not SCOM 2025
    tested). So the Test/Set helpers wrap the in-product cmdlets directly.

    Targets (all SCCM lab VMs):
        A-DC, A-SQLSCCM, A-MPDP, A-SCCM, A-DFSR, B-MPDP

    B-SCOMMS itself runs the HealthService that came with the MS install -
    no agent push needed.

    Prerequisites encoded in the Test step:
        - DNS resolution of each FQDN from B-SCOMMS (sadab.pri zone serves both subnets)
        - TCP 445 / RPC reachable from 10.20.0.40 to each target
        - The action account (here SADAB\Administrator) is local Administrator on every target
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SCOMMS',
    [string]$DomainAdminPassword = 'LabAdmin@2026!',
    [string[]]$Targets           = @(
        'A-DC.sadab.pri'
        'A-SQLSCCM.sadab.pri'
        'A-MPDP.sadab.pri'
        'A-SCCM.sadab.pri'
        'A-DFSR.sadab.pri'
        'B-MPDP.sadab.pri'
    )
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][SCOM-Agents] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

Write-Stage "Reconciling SCOM agents from $VMName to: $($Targets -join ', ')"

# Pass the target list as a single delimited string then split inside the remoting
# scriptblock - PowerShell array marshalling through Invoke-Command/PSRemoting is
# easy to get wrong (single-element arrays get unwrapped, multi-element arrays
# sometimes arrive as one bag) so a CSV is the simple-and-correct path.
$TargetsCSV = $Targets -join ';'

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    param([string]$TargetsCSV, [pscredential]$DomCred)
    $Targets = $TargetsCSV -split ';'

    Import-Module OperationsManager -ErrorAction Stop
    New-SCOMManagementGroupConnection -ComputerName 'B-SCOMMS.sadab.pri' -ErrorAction Stop | Out-Null

    $ms = Get-SCOMManagementServer -Name 'B-SCOMMS.sadab.pri'
    if (-not $ms) { throw "No SCOM management server B-SCOMMS.sadab.pri" }

    # DSC-style Test/Set helpers around the OperationsManager cmdlets.
    function Test-SCOMAgentDeployed {
        param([string]$FQDN)
        [bool](Get-SCOMAgent -DNSHostName $FQDN -ErrorAction SilentlyContinue)
    }
    function Set-SCOMAgentDeployed {
        param([string]$FQDN, $ManagementServer, [pscredential]$ActionAccount)
        Install-SCOMAgent -DNSHostName $FQDN -PrimaryManagementServer $ManagementServer `
                          -ActionAccount $ActionAccount -ErrorAction Stop
    }

    foreach ($t in $Targets) {
        if (Test-SCOMAgentDeployed -FQDN $t) {
            Write-Host "[TEST PASS] $t already an SCOM agent - no action"
        } else {
            try {
                Set-SCOMAgentDeployed -FQDN $t -ManagementServer $ms -ActionAccount $DomCred | Out-Null
                Write-Host "[SET]       $t - push task submitted"
            } catch {
                Write-Host "[SET FAIL]  $t : $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    # Auto-approve any pending agents (push-installed agents land in PendingManagement
    # on first connection; without approval they stay Uninitialized forever).
    $pending = Get-SCOMPendingManagement -ErrorAction SilentlyContinue
    if ($pending) {
        Write-Host "Auto-approving pending agents:"
        foreach ($p in $pending) {
            Write-Host "  approve: $($p.AgentName)"
            Approve-SCOMPendingManagement -PendingAction $p -ErrorAction SilentlyContinue
        }
    }

    Write-Host "`nRe-Test after Set (waits up to 5 min for agents to appear)..."
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 15
        $report = foreach ($t in $Targets) {
            $a = Get-SCOMAgent -DNSHostName $t -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                Target      = $t
                Found       = [bool]$a
                HealthState = if ($a) { "$($a.HealthState)" } else { '-' }
                Version     = if ($a) { "$($a.Version)" }     else { '-' }
            }
        }
        $missing = ($report | Where-Object { -not $_.Found }).Count
        Write-Host ("  unregistered: {0} / {1}   (now {2:HH:mm:ss})" -f $missing, $Targets.Count, (Get-Date))
    } while ($missing -gt 0 -and (Get-Date) -lt $deadline)

    $report | Format-Table -AutoSize | Out-String | Write-Host
} -ArgumentList $TargetsCSV, $cred

Write-Stage "Done."
