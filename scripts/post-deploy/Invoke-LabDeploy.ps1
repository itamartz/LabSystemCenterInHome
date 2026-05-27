<#
.SYNOPSIS
    Master orchestrator for SADAB Lab post-infrastructure installation.
    Run this from Hyper-V Host A after all 11 VMs are running.

.DESCRIPTION
    Runs all post-deploy scripts in order. Each step is idempotent.
    Re-running is safe — each script checks if its work is already done.

.PARAMETER AdminPassword
    Local Administrator password on all nested VMs.

.PARAMETER DomainAdminPassword
    Password to set for the domain Administrator account (used after DC promotion).

.PARAMETER DSRMPassword
    Directory Services Restore Mode password for A-DC.

.PARAMETER StartAtStep
    Step number to start from (useful for resuming after a failure). Default 1.

.EXAMPLE
    .\Invoke-LabDeploy.ps1 -AdminPassword 'NestedP@ssw0rd123!' `
                           -DomainAdminPassword 'DomainP@ss123!' `
                           -DSRMPassword 'DSRM@Pass123!'

.EXAMPLE
    # Resume from step 5 (SQL install) after fixing a failure
    .\Invoke-LabDeploy.ps1 -AdminPassword 'NestedP@ssw0rd123!' `
                           -DomainAdminPassword 'DomainP@ss123!' `
                           -DSRMPassword 'DSRM@Pass123!' `
                           -StartAtStep 5

.NOTES
    Author  : SADAB Lab
    Version : 1.0
    Requires: Run from Hyper-V Host A as Administrator
    DO NOT  : Use Write-Log — conflicts with PowerCLI.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$AdminPassword,
    [Parameter(Mandatory)] [string]$DomainAdminPassword,
    [Parameter(Mandatory)] [string]$DSRMPassword,
    [string]$ScriptRoot  = $PSScriptRoot,
    [int]$StartAtStep    = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$ScriptRoot\LabHelpers.psm1" -Force

function Write-LabLog {
    param([string]$Message, [string]$Level = 'INFO', [string]$Step = '')
    $ts     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = if ($Step) { "[$Step]" } else { '' }
    Write-Host "[$ts][$Level]$prefix $Message" -ForegroundColor $(
        switch ($Level) { 'INFO'{'Cyan'} 'SUCCESS'{'Green'} 'WARN'{'Yellow'} 'ERROR'{'Red'} })
}

$LocalCred  = New-Object System.Management.Automation.PSCredential(
    'Administrator',
    (ConvertTo-SecureString $AdminPassword -AsPlainText -Force)
)
$DomainCred = New-Object System.Management.Automation.PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force)
)

$Steps = @(
    @{ N = 1;  Name = 'Media Share';          Script = '01-Set-MediaShare.ps1'              }
    @{ N = 2;  Name = 'Domain Controller';    Script = '02-Install-DomainControllers.ps1'   }
    @{ N = 3;  Name = 'AD Structure (OUs/Users/gMSA)'; Script = '03-Configure-ADStructure.ps1' }
    @{ N = 4;  Name = 'AD Sites';             Script = '04-Configure-ADSites.ps1'           }
    @{ N = 5;  Name = 'Domain Join';          Script = '05-Join-AllVMsToDomain.ps1'         }
    @{ N = 6;  Name = 'SQL Install';          Script = '06-Install-SQL.ps1'                 }
    @{ N = 7;  Name = 'SCCM Prerequisites';   Script = '07-Install-SCCM-Prerequisites.ps1'  }
    @{ N = 8;  Name = 'SCCM Primary';         Script = '08-Install-SCCM-Primary.ps1'        }
    @{ N = 9;  Name = 'SQL AG (CLUSTER_TYPE=NONE)'; Script = '09-Configure-SQLAlwaysOn.ps1' }
    @{ N = 10; Name = 'SCCM Passive';         Script = '10-Install-SCCM-Passive.ps1'        }
    @{ N = 11; Name = 'SCCM Roles';           Script = '11-Install-SCCM-Roles.ps1'          }
    @{ N = 12; Name = 'DFSR';                 Script = '12-Configure-DFSR.ps1'              }
    @{ N = 13; Name = 'SCOM';                 Script = '13-Install-SCOM.ps1'                }
    @{ N = 14; Name = 'SCCM MP for SCOM';     Script = '14-Import-SCCM-ManagementPack.ps1'  }
)

Write-LabLog '================================================================'
Write-LabLog "SADAB Lab — Post-Deploy Orchestrator"
Write-LabLog "Starting from Step $StartAtStep"
Write-LabLog '================================================================'

foreach ($step in $Steps | Where-Object { $_.N -ge $StartAtStep }) {
    $scriptPath = Join-Path $ScriptRoot $step.Script
    Write-LabLog "--- Step $($step.N): $($step.Name) ---" -Level INFO

    if (-not (Test-Path $scriptPath)) {
        Write-LabLog "Script not found: $scriptPath" -Level ERROR
        throw "Missing script: $($step.Script)"
    }

    & $scriptPath `
        -AdminPassword       $AdminPassword `
        -DomainAdminPassword $DomainAdminPassword `
        -DSRMPassword        $DSRMPassword `
        -LocalCred           $LocalCred `
        -DomainCred          $DomainCred

    Write-LabLog "Step $($step.N) complete." -Level SUCCESS
}

Write-LabLog '================================================================' -Level SUCCESS
Write-LabLog 'All installation steps complete!'                                -Level SUCCESS
Write-LabLog 'Lab is ready. Connect to SCCM console on A-SCCM (10.10.0.3)'   -Level SUCCESS
Write-LabLog '================================================================' -Level SUCCESS
