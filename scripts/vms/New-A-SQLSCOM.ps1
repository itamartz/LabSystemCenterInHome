<#
.SYNOPSIS
    Creates A-SQLSCOM nested VM on Host A. Skips if already exists. Run on Host A.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'A-SQLSCOM' -IP '10.10.0.41' -Gateway '10.10.0.1' -SwitchName 'Lab' `
          -RamGB 8 -VCPU 2 -DataDiskGB 100 -AutoStartDelay 90 -AdminPassword $AdminPassword
