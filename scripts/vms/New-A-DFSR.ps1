<#
.SYNOPSIS
    Creates A-DFSR nested VM on Host A. Skips if already exists. Run on Host A.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'A-DFSR' -IP '10.10.0.7' -Gateway '10.10.0.1' -SwitchName 'Lab' `
          -RamGB 4 -VCPU 2 -AutoStartDelay 210 -AdminPassword $AdminPassword
