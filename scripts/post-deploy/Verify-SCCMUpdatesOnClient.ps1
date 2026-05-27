<#
.SYNOPSIS
    Drives the SCCM software-update cycle on a client VM (default A-DFSR): triggers machine
    policy + update scan + deployment evaluation, optionally forces install of any required
    updates, then reports detected/installed state. Use to verify the ADR reached the client.

.DESCRIPTION
    Run from the Hyper-V host. Targets a lab VM by IP via Invoke-LabRemote (Hyper-V direct).
    Software-update verification on an SCCM client is done through the client SDK WMI:
      * root\ccm SMS_Client.TriggerSchedule for the standard cycles.
      * root\ccm\clientsdk CCM_SoftwareUpdate    - per-update state on the client.
      * root\ccm\clientsdk CCM_SoftwareUpdatesManager.InstallUpdates - force install.

    -Install forces installation of all missing (ComplianceState=0) updates and polls until
    they finish. Servers are configured (by the ADR) NOT to auto-reboot, so updates may end
    in a "pending reboot" state - that still counts as installed for verification.

.PARAMETER VMName / TargetIP
    Which client to verify (default A-DFSR / 10.10.0.7).
.PARAMETER Install
    Force-install missing required updates (the 'Full' pipeline). Without it, scan+report only.
.PARAMETER TimeoutMin
    How long to poll for scan results / installation (default 40).

.NOTES
    Author  : SADAB Lab
    Version : 1.0. PS 5.1 only. Use Write-LabLog.
#>
[CmdletBinding()]
param(
    [string]$VMName   = 'A-DFSR',
    [string]$TargetIP = '10.10.0.7',
    [switch]$Install,
    [int]   $TimeoutMin = 40,

    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force
if (-not $DomainCred) {
    if (-not $DomainAdminPassword) { throw "Provide -DomainCred or -DomainAdminPassword." }
    $DomainCred = New-Object System.Management.Automation.PSCredential('SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

Write-LabLog "Verifying software updates on $VMName (Install=$Install, timeout ${TimeoutMin}m)..." -Step 'Verify'
$result = Invoke-LabRemote -IPAddress $TargetIP -Credential $DomainCred -ScriptBlock {
    param($Install,$TimeoutMin)
    $ErrorActionPreference = 'Stop'

    function Invoke-CcmCycle($guid) { Invoke-WmiMethod -Namespace root\ccm -Class SMS_Client -Name TriggerSchedule -ArgumentList $guid | Out-Null }
    # Machine policy, then scan, then deployment evaluation.
    '{00000000-0000-0000-0000-000000000021}','{00000000-0000-0000-0000-000000000113}','{00000000-0000-0000-0000-000000000108}','{00000000-0000-0000-0000-000000000114}' |
        ForEach-Object { try { Invoke-CcmCycle $_ } catch {} }

    # Wait for a scan to surface required updates (or confirm none are applicable).
    $deadline = (Get-Date).AddMinutes([Math]::Min($TimeoutMin,15))
    do {
        Start-Sleep 20
        $ups = @(Get-CimInstance -Namespace root\ccm\clientsdk -ClassName CCM_SoftwareUpdate -ErrorAction SilentlyContinue)
    } until ($ups.Count -gt 0 -or (Get-Date) -gt $deadline)

    $report = {
        @(Get-CimInstance -Namespace root\ccm\clientsdk -ClassName CCM_SoftwareUpdate -ErrorAction SilentlyContinue) |
            Select-Object ArticleID, Name,
                @{n='Compliance';e={ if($_.ComplianceState -eq 1){'Installed'}elseif($_.ComplianceState -eq 0){'Missing'}else{$_.ComplianceState} }},
                @{n='EvalState';e={$_.EvaluationState}}, PercentComplete
    }

    if ($Install) {
        $mgr = Get-CimInstance -Namespace root\ccm\clientsdk -ClassName CCM_SoftwareUpdatesManager -ErrorAction SilentlyContinue
        $missing = @(Get-CimInstance -Namespace root\ccm\clientsdk -ClassName CCM_SoftwareUpdate | Where-Object { $_.ComplianceState -eq 0 })
        if ($missing.Count -gt 0 -and $mgr) {
            Invoke-CimMethod -Namespace root\ccm\clientsdk -ClassName CCM_SoftwareUpdatesManager -MethodName InstallUpdates -Arguments @{ CCMUpdates = [ciminstance[]]$missing } | Out-Null
        }
        # Poll until nothing is left in an active (installing/missing) state, or timeout.
        $deadline = (Get-Date).AddMinutes($TimeoutMin)
        do {
            Start-Sleep 30
            $active = @(Get-CimInstance -Namespace root\ccm\clientsdk -ClassName CCM_SoftwareUpdate |
                        Where-Object { $_.EvaluationState -in 0,1,2,3,4,5,6,7,8,9,10,11,12 -and $_.ComplianceState -eq 0 })
        } until ($active.Count -eq 0 -or (Get-Date) -gt $deadline)
    }

    [pscustomobject]@{
        Host          = $env:COMPUTERNAME
        UpdatesSeen   = (& $report)
        InstalledHotfixLast45d = @(Get-HotFix | Where-Object { $_.InstalledOn -gt (Get-Date).AddDays(-45) } | Select-Object HotFixID, InstalledOn)
        PendingReboot = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                        [bool](Get-CimInstance -Namespace root\ccm\clientsdk -ClassName CCM_ClientUtilities -ErrorAction SilentlyContinue | ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName DetermineIfRebootPending -ErrorAction SilentlyContinue).RebootPending })
    }
} -ArgumentList ([bool]$Install),$TimeoutMin

"=== $($result.Host): updates known to the SCCM client ==="
$result.UpdatesSeen | Format-Table -AutoSize
"=== Hotfixes installed in the last 45 days ==="
$result.InstalledHotfixLast45d | Format-Table -AutoSize
"PendingReboot: $($result.PendingReboot)"
Write-LabLog "Verify on $VMName complete." -Level SUCCESS -Step 'Verify'
