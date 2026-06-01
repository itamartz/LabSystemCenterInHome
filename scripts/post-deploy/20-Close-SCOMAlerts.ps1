<#
.SYNOPSIS
    Closes every active SCOM alert (ResolutionState != 255) in LAB-SCOM-MG.
    Idempotent - re-running on a clean dashboard is a TEST PASS no-op.

.NOTES
    Must run ON HOST B (uses Hyper-V direct PowerShell to B-SCOMMS).

    DSC-style (per the "SCOM Configuration Convention" in CLAUDE.md):
    Test (Get-SCOMAlert ... where ResolutionState != 255) -> Set
    (Set-SCOMAlert -ResolutionState Closed -Comment ...).

    What "closed" means depends on the alert kind:
    - Rule-based alerts: closing is the final state. They re-fire only if the
      rule fires again (e.g. event re-arrives).
    - Monitor-based alerts: closing while the monitor is still Unhealthy will
      cause the monitor to re-raise the alert on its next eval. Use the
      companion script 21-Apply-SADABOverrides.ps1 to permanently silence the
      noise sources first if you want a truly quiet dashboard.

    For the SADAB lab the typical sequence is:
        21 (apply overrides for lab-noise monitors)
        20 (close everything currently open)
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SCOMMS',
    [string]$DomainAdminPassword = 'LabAdmin@2026!',
    [string]$Comment             = 'SADAB lab clear (script 20)'
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][SCOM-Alerts] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

Write-Stage "Closing active alerts on $VMName ..."

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    param($Comment)

    Import-Module OperationsManager -ErrorAction Stop
    New-SCOMManagementGroupConnection -ComputerName 'B-SCOMMS.sadab.pri' | Out-Null

    function Test-NoActiveAlerts {
        [bool]((Get-SCOMAlert | Where-Object { $_.ResolutionState -ne 255 } | Measure-Object).Count -eq 0)
    }
    function Set-AllAlertsClosed {
        param([string]$Comment)
        # -ErrorAction SilentlyContinue so a per-alert refusal (e.g. SCOM
        # blocks closing a monitor-based alert while the monitor is still
        # Unhealthy) doesn't halt the whole pipe. We capture per-alert
        # failures to a stash for the caller to inspect.
        $script:CloseFailures = [System.Collections.Generic.List[object]]::new()
        Get-SCOMAlert | Where-Object { $_.ResolutionState -ne 255 } | ForEach-Object {
            $a = $_
            try {
                $a | Set-SCOMAlert -ResolutionState 255 -Comment $Comment -ErrorAction Stop
            } catch {
                $script:CloseFailures.Add([PSCustomObject]@{
                    Alert  = $a.Name
                    Target = $a.MonitoringObjectDisplayName
                    Error  = $_.Exception.Message
                })
            }
        }
    }

    if (Test-NoActiveAlerts) {
        Write-Host "[TEST PASS] no active alerts (ResolutionState != 255) - no action"
    } else {
        $active = Get-SCOMAlert | Where-Object { $_.ResolutionState -ne 255 }
        Write-Host ("[SET]       closing {0} active alerts..." -f $active.Count)
        $active | Group-Object Name | Sort-Object Count -Descending |
            Select-Object Count, Name | Format-Table -AutoSize | Out-String | Write-Host
        Set-AllAlertsClosed -Comment $Comment
        if ($script:CloseFailures.Count) {
            Write-Host ("`n  Could not close {0} alert(s) (SCOM blocks closing monitor-based alerts while monitor is still Unhealthy):" -f $script:CloseFailures.Count) -ForegroundColor Yellow
            $script:CloseFailures | Group-Object Alert | Sort-Object Count -Descending |
                Select-Object Count, Name | Format-Table -AutoSize | Out-String | Write-Host
        }
        # Re-Test
        if (Test-NoActiveAlerts) {
            Write-Host "[RE-TEST]   PASS (0 active alerts)"
        } else {
            $remaining = (Get-SCOMAlert | Where-Object { $_.ResolutionState -ne 255 }).Count
            Write-Host ("[RE-TEST]   {0} alerts still active. Fix root cause for those monitors, or apply a scoped override." -f $remaining) -ForegroundColor Yellow
        }
    }
} -ArgumentList $Comment

Write-Stage "Done."
