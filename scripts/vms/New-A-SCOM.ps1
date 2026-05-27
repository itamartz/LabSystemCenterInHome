<#
.SYNOPSIS
    Creates A-SCOM nested VM on Host A. Skips if already exists. Run on Host A.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'A-SCOM' -IP '10.10.0.40' -Gateway '10.10.0.1' -SwitchName 'Lab' `
          -RamGB 8 -VCPU 4 -AutoStartDelay 150 -AdminPassword $AdminPassword
