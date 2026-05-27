<#
.SYNOPSIS
    Updates DNS on all non-DC VMs to point to A-DC, then joins all to the domain.
    Excludes A-DC (already domain member). No DC-B in this lab.

.NOTES
    Author  : SADAB Lab
    Version : 2.0
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

$DcAIP   = '10.10.0.2'
$domain  = $Global:LabConfig.DomainName

# Only attempt to join VMs that are actually online (ping responds). Skips VMs
# that don't exist yet - Phase 1 doesn't include B-* or SCOM VMs.
$joinVMs = $Global:LabConfig.AllVMs |
           Where-Object { $_.Name -ne 'A-DC' } |
           Where-Object {
               $ip = $_.IP
               $reachable = (New-Object System.Net.NetworkInformation.Ping).Send($ip, 1500).Status -eq 'Success'
               if (-not $reachable) { Write-LabLog "Skipping $($_.Name) ($ip) - not reachable" -Level WARN -Step 'DomainJoin' }
               $reachable
           }

foreach ($vm in $joinVMs) {
    $ip     = $vm.IP
    $name   = $vm.Name

    Write-LabLog "Processing: $name ($ip)" -Step 'DomainJoin'

    Invoke-LabRemote -IPAddress $ip -Credential $LocalCred -ScriptBlock {
        param($DnsIP, $Domain, $DomCred)

        # All VMs use A-DC as DNS (only DC in lab)
        $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $DnsIP

        Add-Computer -DomainName $Domain -Credential $DomCred -Restart -Force
    } -ArgumentList $DcAIP, $domain, $DomainCred

    Write-LabLog "$name joined domain - rebooting..." -Level SUCCESS -Step 'DomainJoin'
}

Write-LabLog 'Waiting for all VMs to reboot and rejoin...'
Start-Sleep -Seconds 60

foreach ($vm in $joinVMs) {
    Wait-LabVMReady -IPAddress $vm.IP -Credential $DomainCred -TimeoutSec 240
    Write-LabLog "$($vm.Name) back online." -Level SUCCESS -Step 'DomainJoin'
}
