<#
.SYNOPSIS
    Creates A-SQLSCCM nested VM on Host A. Skips if already exists. Run on Host A.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'A-SQLSCCM' -IP '10.10.0.4' -Gateway '10.10.0.1' -SwitchName 'Lab' `
          -RamGB 8 -VCPU 4 -DataDiskGB 150 -AutoStartDelay 90 -AdminPassword $AdminPassword
