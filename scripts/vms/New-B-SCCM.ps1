<#
.SYNOPSIS
    Creates B-SCCM nested VM on Host B. Skips if already exists. Run on Host B.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'B-SCCM' -IP '10.20.0.3' -Gateway '10.20.0.1' -SwitchName 'Lab' `
          -RamGB 12 -VCPU 4 -AutoStartDelay 150 -AdminPassword $AdminPassword
