<#
.SYNOPSIS
    Creates B-MPDP nested VM on Host B. Skips if already exists. Run on Host B.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'B-MPDP' -IP '10.20.0.5' -Gateway '10.20.0.1' -SwitchName 'Lab' `
          -RamGB 6 -VCPU 2 -AutoStartDelay 210 -AdminPassword $AdminPassword
