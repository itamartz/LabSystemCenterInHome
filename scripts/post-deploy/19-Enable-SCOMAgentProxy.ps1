<#
.SYNOPSIS
    Enables HealthService proxying (`ProxyingEnabled = True`) on every
    SCOM agent in LAB-SCOM-MG. Re-runs are idempotent - new agents picked
    up automatically.

.NOTES
    Must run ON HOST B (uses Hyper-V direct PowerShell to B-SCOMMS).

    DSC-style (per the "SCOM Configuration Convention" in CLAUDE.md):
    For each agent, Test (`Get-SCOMAgent | ... ProxyingEnabled.Value`)
    decides whether Set (`Enable-SCOMAgentProxy`) runs. Re-Test summary
    at the end.

    Why proxying matters: an agent with proxying disabled refuses to submit
    discovery data on behalf of any entity other than itself. That breaks
    many MPs (Active Directory, SQL AlwaysOn / FCI, IIS app pools that
    appear under "logical" computer names, clustered roles, etc.). For a
    lab where one VM often plays multiple roles, proxying-on by default
    is the safer baseline.

    Note about "set a global default for future agents":
    Modern SCOM (2019/2022/2025) does NOT expose a management-group-wide
    "default ProxyingEnabled" setting - the old `Set-DefaultSetting -Name
    HealthService\ProxyingEnabled` was a legacy snap-in cmdlet that was
    removed when SCOM moved to the OperationsManager PS module. Proxying
    is strictly per-agent in modern SCOM. The "future-proof" pattern is
    to re-run this script after script 15 (which discovers and pushes
    agents from AD); both are idempotent so the typical onboarding
    sequence for a new domain VM is:

        Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\15-Install-SCOMAgents.ps1' }
        Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\19-Enable-SCOMAgentProxy.ps1' }
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SCOMMS',
    [string]$DomainAdminPassword = 'LabAdmin@2026!'
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][SCOM-Proxy] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

Write-Stage "Reconciling HealthService proxying on $VMName ..."

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {

    Import-Module OperationsManager -ErrorAction Stop
    New-SCOMManagementGroupConnection -ComputerName 'B-SCOMMS.sadab.pri' | Out-Null

    # DSC-style Test/Set helpers around the OperationsManager cmdlets.
    # ProxyingEnabled is exposed as SettablePropertyValue<bool>; .Value is the
    # actual boolean. Casting the wrapper to [bool] returns $true for any
    # populated wrapper (object exists), which is why we explicitly read .Value.
    function Test-AgentProxyEnabled {
        param($Agent)
        [bool]$Agent.ProxyingEnabled.Value
    }
    function Set-AgentProxyEnabled {
        param($Agent)
        Enable-SCOMAgentProxy -Agent $Agent -ErrorAction Stop | Out-Null
    }

    $agents = Get-SCOMAgent | Sort-Object DisplayName
    foreach ($a in $agents) {
        if (Test-AgentProxyEnabled -Agent $a) {
            Write-Host ("[TEST PASS] {0,-22} ProxyingEnabled=True - no action" -f $a.DisplayName)
        } else {
            Write-Host ("[SET]       {0,-22} ProxyingEnabled <- True" -f $a.DisplayName)
            Set-AgentProxyEnabled -Agent $a
        }
    }

    # Re-test summary (re-fetch fresh state from SCOM)
    Write-Host "`n--- Final agent state ---" -ForegroundColor Cyan
    Get-SCOMAgent | Sort-Object DisplayName |
        Select-Object DisplayName, @{N='ProxyingEnabled';E={$_.ProxyingEnabled.Value}}, HealthState |
        Format-Table -AutoSize | Out-String | Write-Host
}

Write-Stage "Done."
