<#
.SYNOPSIS
    Fixes the *root causes* of the noisy SCOM alerts in the SADAB lab rather
    than disabling the monitors. After this runs, the two monitors that fire
    in the fresh lab (Defender "no recent scan" on every server, AD DS
    NetworkAdapters DNS on A-DC) flip back to Healthy on their own.

.NOTES
    Must run on the local Windows machine (it loads Connect-LabHost.ps1's
    Invoke-LabVM helper for Site-A VMs and uses Hyper-V direct via Host B
    for the Site-B VMs).

    DSC-style (per the "SCOM Configuration Convention" in CLAUDE.md):
    Per-VM Test (Get-DnsClientServerAddress / Get-MpPreference) -> Set, with
    a final immediate Start-MpScan to flip the Defender monitor without
    waiting for the next schedule.

    1. NIC DNS on A-DC: 10.10.0.2 (DC self IP) then 127.0.0.1 (loopback).
       The Microsoft-recommended single-DC pattern. Having the routable IP
       first avoids the startup race condition the monitor flags when only
       loopback is configured.
       ref: https://learn.microsoft.com/troubleshoot/windows-server/active-directory/configure-dns-domain-controller
    2. Defender:
       - schedule a daily quick scan (Set-MpPreference)
       - run one immediate scan now (Start-MpScan -ScanType QuickScan)
       Note: long-term Defender management for the SCCM-managed servers
       should be done via the SCCM Endpoint Protection antimalware policy
       (see Configure-SCCMEndpointProtection.ps1) - this script's
       Set-MpPreference is the fallback for the 4 non-SCCM-managed VMs
       (A-DC + B-MPDP + B-SCOMMS + B-SQLSCOM).
#>
[CmdletBinding()]
param(
    [string]$DomainAdminPassword = 'LabAdmin@2026!'
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\lib\Connect-LabHost.ps1"

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][SCOM-RootFix] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$hbCred  = Import-Clixml (Join-Path $PSScriptRoot '..\..\.secrets\hyperv-host.cred.xml')
$domCred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

# --- Defender targets (all 8 SCOM-monitored servers, including MS) ---
$siteAvms = 'A-DC','A-DFSR','A-MPDP','A-SCCM','A-SQLSCCM'
$siteBvms = 'B-MPDP','B-SCOMMS','B-SQLSCOM'

# Generic scriptblock used per VM for Defender reconcile + immediate scan.
$defenderSb = {
    $pref = Get-MpPreference -ErrorAction SilentlyContinue
    if (-not $pref) { Write-Host "  Defender not present - skipping"; return }
    $currentDay  = "$($pref.ScanScheduleDay)"
    $currentTime = "$($pref.ScanScheduleQuickScanTime)"
    if ($currentDay -eq 'Everyday' -and $currentTime.StartsWith('02:00')) {
        Write-Host "  [TEST PASS] schedule already Everyday/02:00 - no action"
    } else {
        Write-Host "  [SET]       schedule: day=$currentDay/time=$currentTime -> Everyday/02:00"
        Set-MpPreference -ScanScheduleDay Everyday -ScanScheduleQuickScanTime '02:00:00' -ErrorAction Stop
    }
    Write-Host "  Start-MpScan -ScanType QuickScan ..."
    Start-MpScan -ScanType QuickScan -ErrorAction Stop
    $status = Get-MpComputerStatus
    Write-Host ("  scan done. QuickScanEndTime={0}  sig-age-days={1}" -f $status.QuickScanEndTime, $status.AntivirusSignatureAge)
}

# --- 1) A-DC NIC DNS ---
Write-Stage 'Reconciling A-DC NIC DNS (10.10.0.2, 127.0.0.1) ...'

Invoke-LabVM -VMName 'A-DC' -UseDomainCredential -ScriptBlock {
    $nic = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -eq '10.10.0.2' } | Select-Object -First 1
    if (-not $nic) { throw "No NIC with IP 10.10.0.2 on A-DC" }
    $alias = $nic.InterfaceAlias
    $desired = @('10.10.0.2','127.0.0.1')
    $current = (Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4).ServerAddresses
    $compliant = $current.Count -eq $desired.Count -and
                 ($current[0] -eq $desired[0]) -and ($current[1] -eq $desired[1])
    if ($compliant) {
        Write-Host "[TEST PASS] $alias DNS already $($current -join ', ') - no action"
    } else {
        Write-Host "[SET]       $alias DNS: [$($current -join ', ')] -> [$($desired -join ', ')]"
        Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $desired -ErrorAction Stop
        $verify = (Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4).ServerAddresses
        Write-Host "[RE-TEST]   $alias DNS now: $($verify -join ', ')"
        ipconfig /flushdns | Out-Null
    }
}

# --- 2) Defender on Site A VMs (via Host A direct path) ---
Write-Stage 'Reconciling Defender schedule + immediate scan on Site A VMs ...'
foreach ($vm in $siteAvms) {
    Write-Host ("`n--- {0} ---" -f $vm) -ForegroundColor Cyan
    try { Invoke-LabVM -VMName $vm -UseDomainCredential -ScriptBlock $defenderSb }
    catch { Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Yellow }
}

# --- 3) Defender on Site B VMs (via Host B direct path) ---
# Embed the Defender block as a static literal inside the outer ScriptBlock so
# no string-to-scriptblock conversion crosses the PSRemoting boundary - that
# conversion was returning a string in the remote session and binding errors
# back to -ScriptBlock.
Write-Stage 'Reconciling Defender schedule + immediate scan on Site B VMs ...'
foreach ($vm in $siteBvms) {
    Write-Host ("`n--- {0} ---" -f $vm) -ForegroundColor Cyan
    try {
        Invoke-Command -ComputerName 100.117.142.13 -Credential $hbCred -Authentication Negotiate -ScriptBlock {
            param($vmName, $dc)
            Invoke-Command -VMName $vmName -Credential $dc -ScriptBlock {
                $pref = Get-MpPreference -ErrorAction SilentlyContinue
                if (-not $pref) { Write-Host "  Defender not present - skipping"; return }
                $currentDay  = "$($pref.ScanScheduleDay)"
                $currentTime = "$($pref.ScanScheduleQuickScanTime)"
                if ($currentDay -eq 'Everyday' -and $currentTime.StartsWith('02:00')) {
                    Write-Host "  [TEST PASS] schedule already Everyday/02:00 - no action"
                } else {
                    Write-Host "  [SET]       schedule: day=$currentDay/time=$currentTime -> Everyday/02:00"
                    Set-MpPreference -ScanScheduleDay Everyday -ScanScheduleQuickScanTime '02:00:00' -ErrorAction Stop
                }
                Write-Host "  Start-MpScan -ScanType QuickScan ..."
                Start-MpScan -ScanType QuickScan -ErrorAction Stop
                $status = Get-MpComputerStatus
                Write-Host ("  scan done. QuickScanEndTime={0}  sig-age-days={1}" -f $status.QuickScanEndTime, $status.AntivirusSignatureAge)
            }
        } -ArgumentList $vm, $domCred
    } catch { Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Yellow }
}

Write-Stage 'Done. SCOM monitors should flip Healthy in a few minutes; existing alerts will auto-close. Run script 20 to force-close any residual.'
