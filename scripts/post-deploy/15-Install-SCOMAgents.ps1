<#
.SYNOPSIS
    Pushes the SCOM 2025 agent to every enabled domain computer in sadab.pri,
    excluding the management server itself, and confirms each one is
    registered Healthy in LAB-SCOM-MG.

.NOTES
    Must run ON HOST B (uses Hyper-V direct PowerShell to B-SCOMMS).

    DSC-style (per the "SCOM Configuration Convention" in CLAUDE.md):
    Targets are *discovered* from Active Directory (every enabled computer
    object), so adding a new VM and joining it to sadab.pri is enough - no
    script edit needed. For each target, Test (`Get-SCOMAgent`) decides
    whether Set (`Install-SCOMAgent`) runs. Re-Test runs at the end.

    The `OperationsManager` PowerShell module ships with the management server,
    not with any maintained DSC module (xSCOM is deprecated and not SCOM 2025
    tested). So the Test/Set helpers wrap the in-product cmdlets directly.

    AD discovery is via [adsisearcher] so we don't depend on the RSAT
    ActiveDirectory module being installed on B-SCOMMS.

    Exclusions (encoded in the script):
        - B-SCOMMS itself - it's the Management Server. Its HealthService is
          installed as part of the MS bootstrap and SCOM tracks it via
          Get-SCOMManagementServer, not Get-SCOMAgent. It already shows up as
          a managed `Microsoft.Windows.Computer` instance.
        - Any FQDN passed via -ExcludeFqdn.

    Prerequisites encoded in the Test step:
        - DNS resolution of each FQDN from B-SCOMMS (sadab.pri zone serves both subnets)
        - TCP 445 / RPC reachable from 10.20.0.40 to each target
        - The action account (here SADAB\Administrator) is local Administrator on every target
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SCOMMS',
    [string]$DomainAdminPassword = 'LabAdmin@2026!',
    [string[]]$ExcludeFqdn       = @('B-SCOMMS.sadab.pri'),
    # Override target list (skip AD discovery). Useful for narrow runs.
    [string[]]$Targets
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][SCOM-Agents] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

# Pass a CSV through to dodge the array-marshalling quirks of Invoke-Command.
$TargetsCSV = if ($Targets) { $Targets -join ';' } else { '' }
$ExcludeCSV = $ExcludeFqdn -join ';'

Write-Stage "Reconciling SCOM agents from $VMName ..."

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    param([string]$TargetsCSV, [string]$ExcludeCSV, [pscredential]$DomCred)

    $exclude = @($ExcludeCSV -split ';' | Where-Object { $_ })

    # Discover from AD if no -Targets was supplied.
    if ($TargetsCSV) {
        $Targets = $TargetsCSV -split ';'
        Write-Host "Targets (caller-supplied): $($Targets -join ', ')"
    } else {
        # Enabled computer objects only:
        # - objectCategory=computer  (NOT objectClass=computer - that also matches
        #   msDS-GroupManagedServiceAccount because gMSAs inherit from computer.
        #   objectCategory points at the actual class definition.)
        # - NOT userAccountControl bit 2 (ACCOUNTDISABLE).
        $searcher = [adsisearcher]'(&(objectCategory=computer)(!userAccountControl:1.2.840.113556.1.4.803:=2))'
        $searcher.PageSize = 1000
        $searcher.PropertiesToLoad.AddRange(@('dNSHostName','cn','operatingSystem')) | Out-Null
        $found = $searcher.FindAll()
        $Targets = foreach ($r in $found) {
            $dns = $r.Properties['dnshostname'][0]
            if ($dns) { [string]$dns }
        }
        $Targets = $Targets | Sort-Object -Unique
        Write-Host "Discovered $($Targets.Count) enabled domain computers via AD"
    }

    if ($exclude.Count) {
        $beforeCount = $Targets.Count
        $Targets = $Targets | Where-Object { $_ -notin $exclude }
        Write-Host "Excluded $($beforeCount - $Targets.Count): $($exclude -join ', ')"
    }
    Write-Host "Final target list ($($Targets.Count)): $($Targets -join ', ')"

    Import-Module OperationsManager -ErrorAction Stop
    New-SCOMManagementGroupConnection -ComputerName 'B-SCOMMS.sadab.pri' -ErrorAction Stop | Out-Null
    $ms = Get-SCOMManagementServer -Name 'B-SCOMMS.sadab.pri'
    if (-not $ms) { throw "No SCOM management server B-SCOMMS.sadab.pri" }

    function Test-SCOMAgentDeployed {
        param([string]$FQDN)
        [bool](Get-SCOMAgent -DNSHostName $FQDN -ErrorAction SilentlyContinue)
    }
    function Set-SCOMAgentDeployed {
        param([string]$FQDN, $ManagementServer, [pscredential]$ActionAccount)
        Install-SCOMAgent -DNSHostName $FQDN -PrimaryManagementServer $ManagementServer `
                          -ActionAccount $ActionAccount -ErrorAction Stop
    }

    $didSet = $false
    foreach ($t in $Targets) {
        if (Test-SCOMAgentDeployed -FQDN $t) {
            Write-Host "[TEST PASS] $t already an SCOM agent - no action"
        } else {
            try {
                Set-SCOMAgentDeployed -FQDN $t -ManagementServer $ms -ActionAccount $DomCred | Out-Null
                Write-Host "[SET]       $t - push task submitted"
                $didSet = $true
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

    # Re-Test loop only if we actually pushed something; otherwise just print state once.
    $waitMin = if ($didSet) { 5 } else { 0 }
    $deadline = (Get-Date).AddMinutes($waitMin)
    do {
        if ($waitMin -gt 0) { Start-Sleep -Seconds 15 }
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
        if ($waitMin -gt 0) {
            Write-Host ("  unregistered: {0} / {1}   (now {2:HH:mm:ss})" -f $missing, $Targets.Count, (Get-Date))
        }
    } while ($waitMin -gt 0 -and $missing -gt 0 -and (Get-Date) -lt $deadline)

    $report | Format-Table -AutoSize | Out-String | Write-Host
} -ArgumentList $TargetsCSV, $ExcludeCSV, $cred

Write-Stage "Done."
