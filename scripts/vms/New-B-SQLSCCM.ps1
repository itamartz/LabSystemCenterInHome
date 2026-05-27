<#
.SYNOPSIS
    Creates B-SQLSCCM nested VM on Host B. Skips if already exists. Run on Host B.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'B-SQLSCCM' -IP '10.20.0.4' -Gateway '10.20.0.1' -SwitchName 'Lab' `
          -RamGB 8 -VCPU 4 -DataDiskGB 150 -AutoStartDelay 90 -AdminPassword $AdminPassword
