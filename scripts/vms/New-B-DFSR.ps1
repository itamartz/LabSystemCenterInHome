<#
.SYNOPSIS
    Creates B-DFSR nested VM on Host B. Skips if already exists. Run on Host B.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'B-DFSR' -IP '10.20.0.7' -Gateway '10.20.0.1' -SwitchName 'Lab' `
          -RamGB 4 -VCPU 2 -AutoStartDelay 210 -AdminPassword $AdminPassword
