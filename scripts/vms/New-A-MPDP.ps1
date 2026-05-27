<#
.SYNOPSIS
    Creates A-MPDP nested VM on Host A. Skips if already exists. Run on Host A.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'A-MPDP' -IP '10.10.0.5' -Gateway '10.10.0.1' -SwitchName 'Lab' `
          -RamGB 6 -VCPU 2 -AutoStartDelay 210 -AdminPassword $AdminPassword
