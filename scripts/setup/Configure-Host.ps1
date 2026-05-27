<#
.SYNOPSIS
    Configures a Hyper-V host for the SADAB lab — paths, vSwitch ("Lab"), NAT, firewall.
    Idempotent: every step checks current state before acting. Re-running is safe.

.DESCRIPTION
    This script does HOST PLUMBING only. Media downloads (WS2025 VHDX, SCCM, SQL, etc.)
    are handled by scripts\Download-LabFiles.ps1 — keep them separate so this script
    finishes in <1 minute and can be re-run freely.

    Steps:
      1. Verify Hyper-V feature is enabled
      2. Create C:\HyperV-Lab\{Base, VHDs, VMs, Snapshots, Files, Media} directories
      3. Set Hyper-V default VirtualMachinePath + VirtualHardDiskPath
      4. Create the 'Lab' Internal vSwitch if missing
      5. Assign the host IP (e.g. 10.10.0.1/24) to the vSwitch adapter
      6. Configure a NAT rule for outbound internet from VMs
      7. Open firewall: ICMP echo + WinRM (5985) inbound on the lab subnet

.PARAMETER Site
    'A' or 'B'. Determines which subnet/host IP is used.
       A → 10.10.0.0/24, host gateway 10.10.0.1
       B → 10.20.0.0/24, host gateway 10.20.0.1

.PARAMETER StoragePath
    Lab root directory. Default: C:\HyperV-Lab

.PARAMETER SwitchName
    Hyper-V virtual switch name. Default: 'Lab'

.PARAMETER NatName
    Name for the NAT object. Default: 'Lab-NAT-Site<Site>'

.EXAMPLE
    # Run locally on Host A
    .\Configure-Host.ps1 -Site A

.EXAMPLE
    # Run remotely from PC via the Invoke-LabHostScript helper
    . .\scripts\lib\Connect-LabHost.ps1
    Invoke-LabHostScript -FilePath '.\scripts\setup\Configure-Host.ps1' -ArgumentList 'A'

.NOTES
    Requires: PowerShell 5.1+, Hyper-V role enabled, Admin elevation.
    Uses Write-LabLog (NOT Write-Log — collides with PowerCLI).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('A', 'B')]
    [string]$Site,

    [string]$StoragePath = 'C:\HyperV-Lab',

    [string]$SwitchName = 'Lab',

    [string]$NatName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------
# Site-derived values
# -------------------------------------------------------------------
$SiteSubnetPrefix = if ($Site -eq 'A') { '10.10.0' } else { '10.20.0' }
$HostIPOnSwitch   = "$SiteSubnetPrefix.1"
$SubnetCidr       = "$SiteSubnetPrefix.0/24"
if (-not $NatName) { $NatName = "Lab-NAT-Site$Site" }

$LogFile = Join-Path $StoragePath 'configure-host.log'

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
function Write-LabLog {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','SUCCESS','WARN','ERROR','STEP')] [string]$Level = 'INFO'
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts][$Level] $Message"
    $color = switch ($Level) {
        'INFO'    { 'Cyan' }
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'STEP'    { 'Magenta' }
    }
    Write-Host $entry -ForegroundColor $color
    try { Add-Content -Path $LogFile -Value $entry -ErrorAction Stop } catch { }
}

# -------------------------------------------------------------------
# Step 1 — Verify Hyper-V
# -------------------------------------------------------------------
function Test-HyperVEnabled {
    Write-LabLog 'Step 1: Verify Hyper-V is enabled' -Level STEP
    $feat = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
    if (-not $feat -or $feat.State -ne 'Enabled') {
        throw 'Hyper-V is not enabled. Enable it manually (this script does not reboot the host).'
    }
    if (-not (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue)) {
        throw 'Hyper-V PowerShell module not available. Install RSAT / Hyper-V tools first.'
    }
    Write-LabLog "Hyper-V OK ($($feat.State))" -Level SUCCESS
}

# -------------------------------------------------------------------
# Step 2 — Storage paths
# -------------------------------------------------------------------
function New-LabStoragePaths {
    Write-LabLog 'Step 2: Create lab storage paths' -Level STEP
    $subdirs = @('Base', 'VHDs', 'VMs', 'Snapshots', 'Files', 'Media')
    foreach ($d in $subdirs) {
        $p = Join-Path $StoragePath $d
        if (Test-Path $p) {
            Write-LabLog "Exists:  $p" -Level INFO
        } else {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            Write-LabLog "Created: $p" -Level SUCCESS
        }
    }
}

# -------------------------------------------------------------------
# Step 3 — Hyper-V default paths
# -------------------------------------------------------------------
function Set-LabVMHostPaths {
    Write-LabLog 'Step 3: Set Hyper-V default VM and VHD paths' -Level STEP
    $vmPath  = Join-Path $StoragePath 'VMs'
    $vhdPath = Join-Path $StoragePath 'VHDs'
    $cur = Get-VMHost
    if ($cur.VirtualMachinePath -eq $vmPath -and $cur.VirtualHardDiskPath -eq $vhdPath) {
        Write-LabLog 'VMHost paths already configured.' -Level INFO
        return
    }
    Set-VMHost -VirtualMachinePath $vmPath -VirtualHardDiskPath $vhdPath
    Write-LabLog "VMHost paths -> VM=$vmPath  VHD=$vhdPath" -Level SUCCESS
}

# -------------------------------------------------------------------
# Step 4 — Internal vSwitch named 'Lab'
# -------------------------------------------------------------------
function New-LabVSwitch {
    Write-LabLog "Step 4: Ensure vSwitch '$SwitchName' (Internal)" -Level STEP
    $sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($sw) {
        if ($sw.SwitchType -ne 'Internal') {
            throw "vSwitch '$SwitchName' exists but is of type '$($sw.SwitchType)' — expected 'Internal'. Remove or rename it before re-running."
        }
        Write-LabLog "vSwitch '$SwitchName' already present (Internal)" -Level INFO
        return
    }
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Write-LabLog "Created vSwitch '$SwitchName' (Internal)" -Level SUCCESS
}

# -------------------------------------------------------------------
# Step 5 — Host IP on the vSwitch adapter
# -------------------------------------------------------------------
function Set-LabVSwitchHostIP {
    Write-LabLog "Step 5: Ensure host IP $HostIPOnSwitch/24 on vSwitch adapter" -Level STEP

    # Hyper-V creates a NetAdapter named "vEthernet ($SwitchName)" for an Internal switch
    $adapterName = "vEthernet ($SwitchName)"
    $adapter = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
    if (-not $adapter) {
        throw "NetAdapter '$adapterName' not found. Was the vSwitch created in Step 4?"
    }

    $existing = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq $HostIPOnSwitch }
    if ($existing) {
        Write-LabLog "Host IP $HostIPOnSwitch already assigned to '$adapterName'" -Level INFO
        return
    }

    # Remove any other IPv4 addresses on this adapter (defensive — Hyper-V sometimes auto-assigns 169.254/16)
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
        ForEach-Object {
            Write-LabLog "Removing stale IP $($_.IPAddress) on $adapterName" -Level WARN
            Remove-NetIPAddress -InputObject $_ -Confirm:$false -ErrorAction SilentlyContinue
        }

    New-NetIPAddress -InterfaceIndex $adapter.ifIndex `
                     -IPAddress $HostIPOnSwitch -PrefixLength 24 -ErrorAction Stop | Out-Null
    Write-LabLog "Assigned $HostIPOnSwitch/24 to '$adapterName'" -Level SUCCESS
}

# -------------------------------------------------------------------
# Step 6 — NAT for outbound VM internet
# -------------------------------------------------------------------
function Set-LabNat {
    Write-LabLog "Step 6: Ensure NAT '$NatName' for $SubnetCidr" -Level STEP

    $existing = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.InternalIPInterfaceAddressPrefix -eq $SubnetCidr) {
            Write-LabLog "NAT '$NatName' already configured for $SubnetCidr" -Level INFO
            return
        }
        Write-LabLog "NAT '$NatName' exists with wrong prefix '$($existing.InternalIPInterfaceAddressPrefix)' — recreating" -Level WARN
        Remove-NetNat -Name $NatName -Confirm:$false
    }

    # Only one NetNat per address-prefix is allowed on a host. Check for conflicts.
    $conflict = Get-NetNat | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $SubnetCidr -and $_.Name -ne $NatName }
    if ($conflict) {
        throw "Another NetNat ('$($conflict.Name)') already owns prefix $SubnetCidr. Remove it or rename this one before re-running."
    }

    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $SubnetCidr | Out-Null
    Write-LabLog "Created NAT '$NatName' for $SubnetCidr" -Level SUCCESS
}

# -------------------------------------------------------------------
# Step 7a — Route override: beat the Tailscale subnet route for our lab subnet
# (the Azure lab advertises the same 10.10.0.0/24 via Tailscale and otherwise wins
# the routing decision, making host->VM traffic disappear into Tailscale).
# This is temporary — once the Azure lab is decommissioned the conflict is gone.
# -------------------------------------------------------------------
function Set-LabRouteOverride {
    Write-LabLog "Step 7a: Route override so vEthernet ($SwitchName) beats Tailscale for $SubnetCidr" -Level STEP
    $adapter = Get-NetAdapter -Name "vEthernet ($SwitchName)" -ErrorAction Stop
    $idx     = $adapter.ifIndex

    # 1. Lower vEthernet (Lab) InterfaceMetric so all its routes are cheap
    Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -InterfaceMetric 1 -ErrorAction Stop
    Write-LabLog "Set InterfaceMetric=1 on vEthernet ($SwitchName)" -Level SUCCESS

    # 2. Ensure the directly-connected route exists (Remove-NetRoute earlier can wipe it)
    $myRoute = Get-NetRoute -DestinationPrefix $SubnetCidr -InterfaceIndex $idx -ErrorAction SilentlyContinue |
               Where-Object { $_.NextHop -eq '0.0.0.0' }
    if (-not $myRoute) {
        New-NetRoute -DestinationPrefix $SubnetCidr -InterfaceIndex $idx -NextHop '0.0.0.0' -RouteMetric 1 -ErrorAction Stop | Out-Null
        Write-LabLog "Added directly-connected route $SubnetCidr via vEthernet ($SwitchName), metric 1" -Level SUCCESS
    } else {
        Set-NetRoute -DestinationPrefix $SubnetCidr -InterfaceIndex $idx -NextHop '0.0.0.0' -RouteMetric 1 -ErrorAction SilentlyContinue
        Write-LabLog "vEthernet ($SwitchName) route to $SubnetCidr already present (metric set to 1)" -Level INFO
    }

    # 3. Raise the Tailscale route metric for the same prefix so it loses
    $tailRoutes = Get-NetRoute -DestinationPrefix $SubnetCidr -InterfaceAlias 'Tailscale' -ErrorAction SilentlyContinue
    if ($tailRoutes) {
        $tailRoutes | Set-NetRoute -RouteMetric 9000 -ErrorAction SilentlyContinue
        Write-LabLog "Raised Tailscale route metric for $SubnetCidr to 9000" -Level SUCCESS
    } else {
        Write-LabLog "No Tailscale route for $SubnetCidr - nothing to deprioritise" -Level INFO
    }

    # 4. Verify the kernel picks our route
    $best = Find-NetRoute -RemoteIPAddress ("$SiteSubnetPrefix.2") -ErrorAction SilentlyContinue |
            Where-Object { $_.AddressFamily -eq 'IPv4' } | Select-Object -First 1
    if ($best -and $best.InterfaceAlias -eq "vEthernet ($SwitchName)") {
        Write-LabLog "Verified: best route to ${SiteSubnetPrefix}.2 = vEthernet ($SwitchName)" -Level SUCCESS
    } else {
        Write-LabLog "WARN: best route for ${SiteSubnetPrefix}.2 went to '$($best.InterfaceAlias)' - check Tailscale state" -Level WARN
    }
}

# -------------------------------------------------------------------
# Step 7 — Firewall: allow ICMP echo + WinRM from the lab subnet
# -------------------------------------------------------------------
function Set-LabFirewallRules {
    Write-LabLog "Step 7: Allow ICMP + WinRM from $SubnetCidr to host" -Level STEP

    $rules = @(
        @{
            Name        = "Lab-Allow-ICMPv4-In-Site$Site"
            DisplayName = "Lab Allow ICMPv4 In (Site $Site)"
            Protocol    = 'ICMPv4'
            LocalPort   = $null
            IcmpType    = 8
        },
        @{
            Name        = "Lab-Allow-WinRM-In-Site$Site"
            DisplayName = "Lab Allow WinRM In (Site $Site, 5985)"
            Protocol    = 'TCP'
            LocalPort   = 5985
            IcmpType    = $null
        }
    )

    foreach ($r in $rules) {
        $cur = Get-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
        if ($cur) {
            Write-LabLog "Firewall rule '$($r.Name)' already present" -Level INFO
            continue
        }
        $params = @{
            Name        = $r.Name
            DisplayName = $r.DisplayName
            Direction   = 'Inbound'
            Action      = 'Allow'
            Protocol    = $r.Protocol
            RemoteAddress = $SubnetCidr
            Enabled     = 'True'
            Profile     = 'Any'
        }
        if ($r.LocalPort) { $params.LocalPort = $r.LocalPort }
        if ($r.IcmpType -ne $null) { $params.IcmpType = $r.IcmpType }
        New-NetFirewallRule @params | Out-Null
        Write-LabLog "Created firewall rule '$($r.Name)'" -Level SUCCESS
    }
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
if (-not (Test-Path $StoragePath)) {
    New-Item -ItemType Directory -Path $StoragePath -Force | Out-Null
}

Write-LabLog ('=' * 70) -Level STEP
Write-LabLog "Configure-Host.ps1 — Site $Site (subnet $SubnetCidr, gateway $HostIPOnSwitch)" -Level STEP
Write-LabLog ('=' * 70) -Level STEP

Test-HyperVEnabled
New-LabStoragePaths
Set-LabVMHostPaths
New-LabVSwitch
Set-LabVSwitchHostIP
Set-LabNat
Set-LabRouteOverride
Set-LabFirewallRules

Write-LabLog ('=' * 70) -Level SUCCESS
Write-LabLog "Configure-Host.ps1 complete for Site $Site." -Level SUCCESS
Write-LabLog "Next: run Download-LabFiles.ps1 to populate parent VHDX + installers." -Level INFO
Write-LabLog ('=' * 70) -Level SUCCESS

# Return a summary object for callers
[PSCustomObject]@{
    Site         = $Site
    SwitchName   = $SwitchName
    HostIP       = $HostIPOnSwitch
    Subnet       = $SubnetCidr
    NatName      = $NatName
    StoragePath  = $StoragePath
    Hostname     = $env:COMPUTERNAME
    Timestamp    = (Get-Date)
}
