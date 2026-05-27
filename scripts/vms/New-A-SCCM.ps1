<#
.SYNOPSIS
    Creates A-SCCM nested VM on Host A. Skips if already exists. Run on Host A.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'A-SCCM' -IP '10.10.0.3' -Gateway '10.10.0.1' -SwitchName 'Lab' `
          -RamGB 12 -StartupGB 6 -VCPU 4 -AutoStartDelay 150 -AdminPassword $AdminPassword
