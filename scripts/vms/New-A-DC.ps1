<#
.SYNOPSIS
    Creates A-DC nested VM on Host A. Skips if already exists. Run on Host A.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'A-DC' -IP '10.10.0.2' -Gateway '10.10.0.1' -SwitchName 'Lab' `
          -RamGB 4 -VCPU 2 -DnsServer '10.10.0.1' -AutoStartDelay 30 -AdminPassword $AdminPassword
