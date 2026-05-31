<#
.SYNOPSIS
    Creates B-SQLSCOM nested VM on Host B. Skips if already exists. Run on Host B.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'B-SQLSCOM' -IP '10.20.0.41' -Gateway '10.20.0.1' -SwitchName 'Lab' `
          -RamGB 8 -StartupGB 6 -VCPU 4 -DataDiskGB 100 -AutoStartDelay 90 -AdminPassword $AdminPassword
