<#
.SYNOPSIS
    Creates B-SCOMMS (SCOM Management Server) nested VM on Host B.
    Skips if already exists. Run on Host B.
#>
param([string]$AdminPassword = 'LabAdmin@2026!')

. "$PSScriptRoot\LabVMHelpers.ps1"

New-LabVM -Name 'B-SCOMMS' -IP '10.20.0.40' -Gateway '10.20.0.1' -SwitchName 'Lab' `
          -RamGB 6 -StartupGB 4 -VCPU 4 -AutoStartDelay 150 -AdminPassword $AdminPassword
