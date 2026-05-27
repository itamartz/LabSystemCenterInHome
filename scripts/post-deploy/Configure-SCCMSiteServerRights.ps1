<#
.SYNOPSIS
    Sets up the SCCM_Site_Servers group and the rights an SCCM site server needs:
      1. AD group 'SCCM_Site_Servers' (member: A-SCCM$ computer account)
      2. GenericAll on the AD 'System Management' container (so the group can
         publish/read SCCM site data in AD)
      3. GPO 'Hardening SCCM' that adds the group to the local Administrators
         group of machines in OU=SADAB (Restricted Groups, additive)

    Group-based by design (see also Configure-SCCMRBAC.ps1) - grant a server the
    site-server rights by adding its computer account to SCCM_Site_Servers.

.NOTES
    Author  : SADAB Lab
    Version : 1.0
    Requires: A-DC promoted, System Management container present (step 7), GPMC.
    Run     : from the Hyper-V host, after step 8.

    NOTE on Kerberos token: a computer only gets the group's rights after the
    computer REBOOTS (its Kerberos ticket must pick up the new group SID). A-SCCM
    keeps its pre-existing direct GenericAll ACE on the container so nothing breaks
    before its next reboot; the group ACE is the long-term holder.
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

$DcAIP = '10.10.0.2'

Write-LabLog 'Configuring SCCM_Site_Servers group, container rights, and Hardening SCCM GPO...' -Step 'SiteServerRights'

Invoke-LabRemote -IPAddress $DcAIP -Credential $DomainCred -ScriptBlock {
    Import-Module ActiveDirectory
    $PSDefaultParameterValues = @{ '*-AD*:Server' = 'localhost' }

    # GPMC / GroupPolicy module is required for the GPO part
    if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
        Write-Host 'Installing GPMC (GroupPolicy module)...'
        Install-WindowsFeature GPMC -ErrorAction Stop | Out-Null
    }
    Import-Module GroupPolicy

    $domainDN  = (Get-ADDomain).DistinguishedName
    $domainDNS = (Get-ADDomain).DNSRoot
    $netbios   = (Get-ADDomain).NetBIOSName

    # ---------------------------------------------------------------------
    # 1. AD group SCCM_Site_Servers + member A-SCCM$
    # ---------------------------------------------------------------------
    $groupName = 'SCCM_Site_Servers'
    $groupDesc = "SCCM site servers group | Members are Configuration Manager site system servers for site PR1 (SADAB Lab) | " +
                 "Holds GenericAll on the AD 'System Management' container (CN=System Management,CN=System,$domainDN) so site servers can publish site data to AD | " +
                 "Added to local Administrators on OU=SADAB machines via the 'Hardening SCCM' GPO | " +
                 "Grant a server site-server rights by adding its computer account here (then reboot that server) | " +
                 "Maintained by scripts\post-deploy\Configure-SCCMSiteServerRights.ps1"
    if (-not (Get-ADGroup -Filter "Name -eq '$groupName'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $groupName -SamAccountName $groupName -GroupScope Global -GroupCategory Security `
                    -Path "OU=Groups,OU=SADAB,$domainDN" -Description $groupDesc
        Write-Host "Created group $groupName"
    } else {
        Set-ADGroup -Identity $groupName -Description $groupDesc
        Write-Host "Group $groupName exists (description refreshed)"
    }
    $sccmComputer = Get-ADComputer 'A-SCCM'
    try { Add-ADGroupMember -Identity $groupName -Members $sccmComputer -ErrorAction Stop; Write-Host 'Added A-SCCM$ to SCCM_Site_Servers' }
    catch { if ($_.Exception.Message -match 'already a member') { Write-Host 'A-SCCM$ already a member' } else { throw } }

    $groupSid = (Get-ADGroup $groupName).SID.Value
    Write-Host "Group SID: $groupSid"

    # ---------------------------------------------------------------------
    # 2. Grant the group GenericAll on the System Management container
    # ---------------------------------------------------------------------
    $smContainer = "CN=System Management,CN=System,$domainDN"
    if (-not (Get-ADObject -Filter "DistinguishedName -eq '$smContainer'" -ErrorAction SilentlyContinue)) {
        throw "System Management container not found ($smContainer) - run step 7 first"
    }
    $acl  = Get-Acl "AD:$smContainer"
    $sid  = [System.Security.Principal.SecurityIdentifier](Get-ADGroup $groupName).SID
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid,
        [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
        [System.Security.AccessControl.AccessControlType]::Allow,
        [DirectoryServices.ActiveDirectorySecurityInheritance]::All
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:$smContainer" $acl
    Write-Host "Granted SCCM_Site_Servers GenericAll on $smContainer"

    # ---------------------------------------------------------------------
    # 3. GPO 'Hardening SCCM' - add group to local Administrators (Restricted Groups, additive)
    # ---------------------------------------------------------------------
    $gpoName = 'Hardening SCCM'
    $gpoComment = "Hardens/configures SCCM site systems in SADAB Lab. Currently: adds SADAB\$groupName to the local Administrators group of computers in OU=SADAB (Restricted Groups 'Member Of', additive - existing local admins are preserved). Maintained by scripts\post-deploy\Configure-SCCMSiteServerRights.ps1."
    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $gpoName -Comment $gpoComment
        Write-Host "Created GPO '$gpoName'"
    } else {
        $gpo.Description = $gpoComment
        Write-Host "GPO '$gpoName' exists"
    }
    $gpoId = $gpo.Id.Guid

    # Use Group Policy PREFERENCES (Local Users and Groups), NOT Restricted Groups.
    # GPP "Update Administrators (built-in), ADD member" is additive and preserves
    # existing local admins, and is the modern/preferred mechanism.
    # Clean up any prior Restricted Groups attempt:
    $secEditInf = "\\$domainDNS\SYSVOL\$domainDNS\Policies\{$gpoId}\Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf"
    if (Test-Path $secEditInf) { Remove-Item $secEditInf -Force -ErrorAction SilentlyContinue }

    $prefDir = "\\$domainDNS\SYSVOL\$domainDNS\Policies\{$gpoId}\Machine\Preferences\Groups"
    New-Item -ItemType Directory -Path $prefDir -Force | Out-Null
    $uid     = '{' + ([guid]::NewGuid().ToString().ToUpper()) + '}'
    $changed = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    # Target the built-in Administrators by SID (locale-independent); ADD our group as a member.
    $groupsXml = @"
<?xml version="1.0" encoding="utf-8"?>
<Groups clsid="{3125E937-EB16-4b4c-9934-544FC6D24D26}"><Group clsid="{6D4A79E4-529C-4481-ABD0-F5BD7EA93BA7}" name="Administrators (built-in)" image="2" changed="$changed" uid="$uid"><Properties action="U" newName="" description="" deleteAllUsers="0" deleteAllGroups="0" removeAccounts="0" groupSid="S-1-5-32-544" groupName="Administrators (built-in)"><Members><Member name="$netbios\$groupName" action="ADD" sid="$groupSid"/></Members></Properties></Group></Groups>
"@
    Set-Content -Path "$prefDir\Groups.xml" -Value $groupsXml -Encoding UTF8
    Write-Host 'Wrote GPP Groups.xml (ADD SCCM_Site_Servers to local Administrators)'

    # Register the GPP Local Users and Groups CSE so clients process the preference, bump version
    $gpoDN = "CN={$gpoId},CN=Policies,CN=System,$domainDN"
    $gppCse = '[{17D89FEC-5C44-4972-B12D-241CAEF74509}{79F92669-4224-476C-9C5C-6EFB4D87DF4A}]'
    Set-ADObject -Identity $gpoDN -Replace @{ gPCMachineExtensionNames = $gppCse }

    # GPO versionNumber: low 16 bits = COMPUTER version, high 16 bits = USER version.
    # Our preference is a COMPUTER (Machine) setting, so the computer/low word MUST be
    # non-zero or the client treats the GPO as "Empty" and skips it. Bump both words by 1
    # each run (0x10001) so the computer word is always non-zero and changes are detected.
    $curVer = [int](Get-ADObject -Identity $gpoDN -Properties versionNumber).versionNumber
    $newVer = $curVer + 0x10001
    Set-ADObject -Identity $gpoDN -Replace @{ versionNumber = $newVer }
    $gptIni = "\\$domainDNS\SYSVOL\$domainDNS\Policies\{$gpoId}\GPT.ini"
    Set-Content -Path $gptIni -Value @('[General]', "Version=$newVer") -Encoding Ascii
    Write-Host "Set GPP CSE + version $newVer (computer word = $($newVer -band 0xFFFF))"

    # Link to OU=SADAB (covers member servers; deliberately NOT the Domain Controllers OU)
    $linkTarget = "OU=SADAB,$domainDN"
    $linked = (Get-GPInheritance -Target $linkTarget).GpoLinks | Where-Object { $_.DisplayName -eq $gpoName }
    if (-not $linked) {
        New-GPLink -Name $gpoName -Target $linkTarget -LinkEnabled Yes | Out-Null
        Write-Host "Linked '$gpoName' to $linkTarget"
    } else {
        Write-Host "'$gpoName' already linked to $linkTarget"
    }

    Write-Host 'SCCM site-server rights + Hardening SCCM GPO configured.'
}

Write-LabLog 'Done. Reboot A-SCCM (and any other SCCM_Site_Servers member) for the GPO local-admin + token to take effect.' -Level SUCCESS -Step 'SiteServerRights'
