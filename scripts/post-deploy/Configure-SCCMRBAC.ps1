<#
.SYNOPSIS
    Group-based SCCM RBAC: creates AD security groups for SCCM roles, adds members,
    and assigns each group an SCCM administrative role. Run AFTER step 8 (SCCM
    Primary installed). Idempotent - safe to re-run.

.DESCRIPTION
    Best practice is to assign SCCM roles to AD GROUPS, not individual users, so
    access is managed via group membership. This script:
      1. On A-DC: creates each role group (OU=Groups,OU=SADAB) and adds its members
      2. On A-SCCM: grants each group its SCCM role (New-CMAdministrativeUser)

    To grant someone SCCM access afterwards, just add them to the AD group - no
    SCCM change needed.

.NOTES
    Author  : SADAB Lab
    Version : 1.0
    Requires: SCCM Primary site PR1 installed, run from Hyper-V host.
    Module  : ConfigMgr console at C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1
#>
[CmdletBinding()]
param(
    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force

$DcAIP   = '10.10.0.2'
$SccmAIP = '10.10.0.3'

# --- Role group definitions -------------------------------------------------
# Group name -> SCCM role -> initial AD members. Add more groups/roles as needed.
$RoleGroups = @(
    @{ Group = 'SCCM_Role_Full_Administrators'; Role = 'Full Administrator'; Members = @('itamartz') }
    # Example additions:
    # @{ Group = 'SCCM_Role_ReadOnly';          Role = 'Read-only Analyst';        Members = @() }
    # @{ Group = 'SCCM_Role_SoftwareUpdateMgr'; Role = 'Software Update Manager';   Members = @() }
)

# --- 1. Create AD groups + add members (on A-DC) ----------------------------
Write-LabLog 'Creating SCCM role groups in AD...' -Step 'SCCMRBAC'
Invoke-LabRemote -IPAddress $DcAIP -Credential $DomainCred -ScriptBlock {
    param($Groups)
    Import-Module ActiveDirectory
    $PSDefaultParameterValues = @{ '*-AD*:Server' = 'localhost' }
    $ou = 'OU=Groups,OU=SADAB,DC=sadab,DC=pri'

    foreach ($g in $Groups) {
        $name = $g.Group
        $desc = "SCCM RBAC role group | Grants the '$($g.Role)' security role in Configuration Manager site PR1 (SADAB Lab) | " +
                "Access is managed by membership of THIS group - add/remove users here, not in the SCCM console | " +
                "Mapped in SCCM via New-CMAdministrativeUser -Name 'SADAB\$name' -RoleName '$($g.Role)' | " +
                "Maintained by scripts\post-deploy\Configure-SCCMRBAC.ps1"
        if (-not (Get-ADGroup -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $name -SamAccountName $name -GroupScope Global -GroupCategory Security `
                        -Path $ou -Description $desc
            Write-Host "Created group: $name"
        } else {
            Set-ADGroup -Identity $name -Description $desc
            Write-Host "Group exists: $name (description refreshed)"
        }
        foreach ($m in $g.Members) {
            try {
                Add-ADGroupMember -Identity $name -Members $m -ErrorAction Stop
                Write-Host "  added member: $m"
            } catch {
                if ($_.Exception.Message -match 'already a member') { Write-Host "  $m already a member" }
                else { Write-Host "  WARN adding ${m}: $($_.Exception.Message)" }
            }
        }
    }
} -ArgumentList (,$RoleGroups)

# --- 2. Assign each group its SCCM role (on A-SCCM) -------------------------
Write-LabLog 'Assigning SCCM roles to groups...' -Step 'SCCMRBAC'
Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    param($Groups, $NetBIOS)
    Import-Module 'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1' -ErrorAction Stop
    if (-not (Get-PSDrive -Name PR1 -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name PR1 -PSProvider CMSite -Root 'A-SCCM.sadab.pri' -ErrorAction Stop | Out-Null
    }
    Push-Location 'PR1:'
    try {
        foreach ($g in $Groups) {
            $principal = "$NetBIOS\$($g.Group)"
            if (-not (Get-CMAdministrativeUser -Name $principal -ErrorAction SilentlyContinue)) {
                New-CMAdministrativeUser -Name $principal -RoleName $g.Role -ErrorAction Stop | Out-Null
                Write-Host "Granted '$($g.Role)' to $principal"
            } else {
                Write-Host "$principal already an SCCM admin"
            }
        }
        Write-Host '--- SCCM administrative users ---'
        Get-CMAdministrativeUser | Select-Object LogonName, @{N='Roles';E={$_.RoleNames -join ', '}} | Format-Table -AutoSize
    } finally { Pop-Location }
} -ArgumentList (,$RoleGroups), $Global:LabConfig.NetBIOSName

Write-LabLog 'SCCM RBAC configured. Grant access by adding users to the AD role groups.' -Level SUCCESS -Step 'SCCMRBAC'
