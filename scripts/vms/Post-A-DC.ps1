<#
.SYNOPSIS
    Post-deploy for A-DC: promote to forest root DC, configure AD structure, sites.
    Run on Host A. Requires media share (01-Set-MediaShare.ps1) to be done first.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$AdminPassword,
    [Parameter(Mandatory)] [string]$DomainAdminPassword,
    [Parameter(Mandatory)] [string]$DSRMPassword
)

. "$PSScriptRoot\PostDeployHelpers.ps1"

$creds      = New-LabCredentials -AdminPassword $AdminPassword -DomainAdminPassword $DomainAdminPassword
$IP         = '10.10.0.2'
$DomainName = 'sadab.pri'
$NetBIOS    = 'SADAB'
$DSRMSecure = ConvertTo-SecureString $DSRMPassword -AsPlainText -Force

# ── Step 1: Promote to forest root DC ──────────────────────────────────────────
Write-LabLog 'Promoting A-DC to forest root domain controller...' -Step 'A-DC'

$alreadyDC = Invoke-LabRemote -IPAddress $IP -Credential $creds.Local -MaxRetries 3 -RetryDelaySec 10 -ScriptBlock {
    $svc = Get-Service -Name 'NTDS' -ErrorAction SilentlyContinue
    return ($null -ne $svc)
}

if ($alreadyDC) {
    Write-LabLog 'A-DC is already a domain controller - skipping promotion.' -Level SUCCESS -Step 'A-DC'
} else {
    Invoke-LabRemote -IPAddress $IP -Credential $creds.Local -ScriptBlock {
        param($Domain, $NetBIOS, $DSRM)

        Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
        Install-WindowsFeature AD-Domain-Services, RSAT-AD-AdminCenter, RSAT-ADDS-Tools | Out-Null

        Import-Module ADDSDeployment
        $params = @{
            DomainName                    = $Domain
            DomainNetbiosName             = $NetBIOS
            ForestMode                    = 'WinThreshold'
            DomainMode                    = 'WinThreshold'
            DatabasePath                  = 'C:\Windows\NTDS'
            LogPath                       = 'C:\Windows\NTDS'
            SysvolPath                    = 'C:\Windows\SYSVOL'
            SafeModeAdministratorPassword = $DSRM
            InstallDns                    = $true
            NoRebootOnCompletion          = $false
            Force                         = $true
        }
        Install-ADDSForest @params
    } -ArgumentList $DomainName, $NetBIOS, $DSRMSecure

    Write-LabLog 'A-DC rebooting after promotion...' -Step 'A-DC'
    Start-Sleep -Seconds 90
    Wait-LabVMReady -IPAddress $IP -Credential $creds.Domain -TimeoutSec 300
    Write-LabLog 'A-DC is back. Forest root DC operational.' -Level SUCCESS -Step 'A-DC'
}

# ── Step 2: Configure AD structure (OUs, gMSA, users, groups) ─────────────────
Write-LabLog 'Configuring AD structure...' -Step 'A-DC'

Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -ScriptBlock {
    param($Password)

    Import-Module ActiveDirectory

    $adDomain    = Get-ADDomain
    $domainDn    = $adDomain.DistinguishedName
    $domain      = $adDomain.DNSRoot
    $usersAdPath = "CN=Users,$domainDn"
    $securePass  = ConvertTo-SecureString -AsPlainText $Password -Force

    $parentOuName = 'SADAB'
    $childOUs     = @('Servers', 'Endpoints', 'Users', 'Groups', 'Installation')

    # Parent OU
    $parentOuDn = "OU=$parentOuName,$domainDn"
    if (-not (Get-ADOrganizationalUnit -Filter "distinguishedName -eq '$parentOuDn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $parentOuName -Path $domainDn -ProtectedFromAccidentalDeletion $true
        Write-Host "Created parent OU: $parentOuName"
    }

    # Child OUs
    foreach ($ouName in $childOUs) {
        $ouDn = "OU=$ouName,$parentOuDn"
        if (-not (Get-ADOrganizationalUnit -Filter "distinguishedName -eq '$ouDn'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ouName -Path $parentOuDn -ProtectedFromAccidentalDeletion $true
            Write-Host "Created child OU: $parentOuName\$ouName"
        }
    }

    # Redirect default computer OU to Endpoints
    $endpointsOuDn = "OU=Endpoints,$parentOuDn"
    & redircmp $endpointsOuDn

    # KDS root key for gMSA
    if (-not (Get-KdsRootKey -ErrorAction SilentlyContinue)) {
        Add-KdsRootKey -EffectiveTime (Get-Date).AddHours(-10) | Out-Null
        Write-Host 'KDS root key created.'
    }

    # gMSA: whoami$
    $msaAdPath = "CN=Managed Service Accounts,$domainDn"
    if (-not (Get-ADServiceAccount -Filter "Name -eq 'whoami'" -ErrorAction SilentlyContinue)) {
        New-ADServiceAccount -Path $msaAdPath -DNSHostName $domain -Name 'whoami'
        Set-ADServiceAccount -Identity 'whoami' -PrincipalsAllowedToRetrieveManagedPassword @(
            "CN=Domain Controllers,$usersAdPath"
            "CN=Domain Computers,$usersAdPath"
        )
        Write-Host 'Created gMSA: whoami$'
    }

    # Security groups for SQL
    $groupsOuDn = "OU=Groups,$parentOuDn"
    $sqlGroups = @(
        @{ Name = 'SQLServersA'; Description = 'Computers allowed to use A-gMSA (Site A SQL)' }
        @{ Name = 'SQLServersB'; Description = 'Computers allowed to use B-gMSA (Site B SQL)' }
        @{ Name = 'SQLgMSAs';    Description = 'All SQL gMSA accounts - used for AG endpoint grants' }
    )
    foreach ($grp in $sqlGroups) {
        if (-not (Get-ADGroup -Filter "Name -eq '$($grp.Name)'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $grp.Name -GroupScope Global -GroupCategory Security `
                        -Path $groupsOuDn -Description $grp.Description
            Write-Host "Created group: $($grp.Name)"
        }
    }

    # Add SQL computer accounts to groups (if they exist yet)
    foreach ($pair in @(@{Computer='A-SQLSCCM'; Group='SQLServersA'}, @{Computer='B-SQLSCCM'; Group='SQLServersB'})) {
        $comp = Get-ADComputer -Filter "Name -eq '$($pair.Computer)'" -ErrorAction SilentlyContinue
        if ($comp) {
            Add-ADGroupMember -Identity $pair.Group -Members $comp -ErrorAction SilentlyContinue
            Write-Host "Added $($pair.Computer)$ to $($pair.Group)"
        }
    }

    # gMSA: A-gMSA$ and B-gMSA$
    foreach ($msa in @(
        @{ Name = 'A-gMSA'; Desc = 'SQL Server service account for Site A (A-SQLSCCM)'; Group = 'SQLServersA' }
        @{ Name = 'B-gMSA'; Desc = 'SQL Server service account for Site B (B-SQLSCCM)'; Group = 'SQLServersB' }
    )) {
        if (-not (Get-ADServiceAccount -Filter "Name -eq '$($msa.Name)'" -ErrorAction SilentlyContinue)) {
            New-ADServiceAccount -Name $msa.Name -Path $msaAdPath `
                -DNSHostName "$($msa.Name).$domain" `
                -Description $msa.Desc `
                -PrincipalsAllowedToRetrieveManagedPassword $msa.Group
            Write-Host "Created gMSA: $($msa.Name)$"
        }
    }

    # Add gMSAs to SQLgMSAs group
    foreach ($msaAcct in @('A-gMSA', 'B-gMSA')) {
        $msaObj = Get-ADServiceAccount -Filter "Name -eq '$msaAcct'" -ErrorAction SilentlyContinue
        if ($msaObj) {
            Add-ADGroupMember -Identity 'SQLgMSAs' -Members $msaObj -ErrorAction SilentlyContinue
        }
    }

    # User: itamartz
    $usersOuDn = "OU=Users,$parentOuDn"
    if (-not (Get-ADUser -Filter "SamAccountName -eq 'itamartz'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Path $usersOuDn -Name 'itamartz' `
            -UserPrincipalName "itamartz@$domain" -EmailAddress "itamartz@$domain" `
            -GivenName 'Itamar' -Surname 'Tziger' -DisplayName 'Itamar Tziger' `
            -AccountPassword $securePass -Enabled $true -PasswordNeverExpires $true `
            -Description 'Lab Administrator'
        Write-Host 'Created user: itamartz'
    }

    foreach ($group in @('Domain Admins', 'Enterprise Admins', 'Schema Admins')) {
        $isMember = Get-ADGroupMember -Identity $group -ErrorAction SilentlyContinue |
            Where-Object { $_.SamAccountName -eq 'itamartz' }
        if (-not $isMember) {
            Add-ADGroupMember -Identity $group -Members 'itamartz'
        }
    }

    # Set Administrator password never expires
    Set-ADAccountPassword -Identity "CN=Administrator,$usersAdPath" -Reset -NewPassword $securePass
    Set-ADUser -Identity "CN=Administrator,$usersAdPath" -PasswordNeverExpires $true

    Write-Host 'AD structure configured.'
} -ArgumentList $DomainAdminPassword

Write-LabLog 'AD structure done.' -Level SUCCESS -Step 'A-DC'

# ── Step 3: Configure AD Sites ────────────────────────────────────────────────
Write-LabLog 'Configuring AD Sites...' -Step 'A-DC'

Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -ScriptBlock {
    Import-Module ActiveDirectory

    if (Get-ADReplicationSite -Filter { Name -eq 'Default-First-Site-Name' } -ErrorAction SilentlyContinue) {
        Get-ADReplicationSite 'Default-First-Site-Name' | Rename-ADObject -NewName 'Site-A'
        Write-Host 'Renamed Default-First-Site-Name to Site-A'
    }

    if (-not (Get-ADReplicationSite -Filter { Name -eq 'Site-B' } -ErrorAction SilentlyContinue)) {
        New-ADReplicationSite -Name 'Site-B'
        Write-Host 'Created Site-B'
    }

    foreach ($subnet in @(
        @{ Name = '10.10.0.0/24'; Site = 'Site-A'; Desc = 'SCCM Lab Site A' }
        @{ Name = '10.20.0.0/24'; Site = 'Site-B'; Desc = 'SCCM Lab Site B' }
    )) {
        if (-not (Get-ADReplicationSubnet -Filter "Name -eq '$($subnet.Name)'" -ErrorAction SilentlyContinue)) {
            New-ADReplicationSubnet -Name $subnet.Name -Site $subnet.Site -Location $subnet.Desc
            Write-Host "Created subnet: $($subnet.Name) -> $($subnet.Site)"
        }
    }

    if (-not (Get-ADReplicationSiteLink -Filter { Name -eq 'SiteLink-A-B' } -ErrorAction SilentlyContinue)) {
        New-ADReplicationSiteLink -Name 'SiteLink-A-B' -SitesIncluded 'Site-A','Site-B' `
            -Cost 100 -ReplicationFrequencyInMinutes 15 -InterSiteTransportProtocol IP
        Write-Host 'Created site link: SiteLink-A-B'
    }
}

# ── Step 4: Create System Management container ────────────────────────────────
Write-LabLog 'Creating System Management container...' -Step 'A-DC'

Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -ScriptBlock {
    Import-Module ActiveDirectory

    $systemContainerDN = 'CN=System,' + (Get-ADDomain).DistinguishedName
    $smContainerDN     = "CN=System Management,$systemContainerDN"

    if (-not (Get-ADObject -Filter { DistinguishedName -eq $smContainerDN } -ErrorAction SilentlyContinue)) {
        New-ADObject -Name 'System Management' -Type Container -Path $systemContainerDN
    }

    # Grant A-SCCM full control (if already domain-joined)
    $sccmA = Get-ADComputer 'A-SCCM' -ErrorAction SilentlyContinue
    if ($sccmA) {
        $acl      = Get-Acl "AD:$smContainerDN"
        $identity = [System.Security.Principal.SecurityIdentifier]$sccmA.SID
        $rule     = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $identity,
            [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
            [System.Security.AccessControl.AccessControlType]::Allow,
            [DirectoryServices.ActiveDirectorySecurityInheritance]::All
        )
        $acl.AddAccessRule($rule)
        Set-Acl "AD:$smContainerDN" $acl
        Write-Host 'Granted A-SCCM full control on System Management container.'
    } else {
        Write-Host 'A-SCCM not yet joined - re-run after domain join to grant permissions.'
    }
}

Write-LabLog 'A-DC post-deploy complete.' -Level SUCCESS -Step 'A-DC'
