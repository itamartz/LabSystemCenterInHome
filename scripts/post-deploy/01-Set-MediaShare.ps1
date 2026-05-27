<#
.SYNOPSIS
    Creates an SMB share on each Hyper-V host so nested VMs can access installation media.
    Also enables WinRM on all nested VMs so Invoke-Command works for subsequent steps.

.NOTES
    Author  : SADAB Lab
    Version : 1.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$AdminPassword,
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force

# Create media share on this host. Points at C:\HyperV-Lab\Files which holds
# the actual installers (SQL ISO, ADK, SCCM setup, etc.) - the empty 'Media'
# subdir was a layout leftover.
$mediaPath = 'C:\HyperV-Lab\Files'
if (-not (Test-Path $mediaPath)) {
    New-Item -ItemType Directory -Path $mediaPath -Force | Out-Null
}

$existing = Get-SmbShare -Name 'LabMedia' -ErrorAction SilentlyContinue
if (-not $existing) {
    New-SmbShare -Name 'LabMedia' -Path $mediaPath -ReadAccess 'Everyone' | Out-Null
    Write-LabLog 'Created SMB share: \\localhost\LabMedia' -Level SUCCESS
} elseif ($existing.Path -ne $mediaPath) {
    Write-LabLog "Existing LabMedia share path is $($existing.Path); re-creating to point at $mediaPath" -Level WARN
    Remove-SmbShare -Name 'LabMedia' -Force -Confirm:$false
    New-SmbShare -Name 'LabMedia' -Path $mediaPath -ReadAccess 'Everyone' | Out-Null
    Write-LabLog 'Re-created SMB share: \\localhost\LabMedia' -Level SUCCESS
} else {
    Write-LabLog 'SMB share LabMedia already correctly configured.' -Level INFO
}

# ── Enable WinRM on all nested VMs (via Hyper-V direct VM session) ────────────
Write-LabLog 'Enabling WinRM on all nested VMs via Hyper-V direct connection...'

$allVMs = Get-VM | Where-Object { $_.State -eq 'Running' }
foreach ($vm in $allVMs) {
    try {
        Invoke-Command -VMName $vm.Name -Credential $LocalCred -ScriptBlock {
            Set-Service WinRM -StartupType Automatic
            Start-Service WinRM -ErrorAction SilentlyContinue
            Enable-PSRemoting -Force -SkipNetworkProfileCheck
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
            Enable-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction SilentlyContinue
        } -ErrorAction Stop
        Write-LabLog "WinRM enabled: $($vm.Name)" -Level SUCCESS
    } catch {
        Write-LabLog "WinRM setup failed on $($vm.Name): $_" -Level WARN
    }
}
