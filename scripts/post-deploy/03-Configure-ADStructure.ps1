<#
.SYNOPSIS
    Creates the SADAB OU structure, KDS root key for gMSA, user accounts,
    and redirects default computer OU. Runs on A-DC after forest promotion.

.DESCRIPTION
    OU Structure:
        OU=SADAB,DC=sadab,DC=pri
            OU=Servers
            OU=Endpoints      ← default computer OU (redircmp)
            OU=Users
            OU=Groups
            OU=Installation

    Creates:
        - itamartz user (Domain Admins, Enterprise Admins, Schema Admins)
        - KDS root key for gMSA
        - whoami$ gMSA account
        - SQLServersA / SQLServersB security groups
        - A-gMSA$ / B-gMSA$ gMSA accounts for SQL Server services

.NOTES
    Author  : SADAB Lab
    Version : 1.0
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

Write-LabLog 'Configuring AD structure on A-DC...' -Step 'ADStructure'

Invoke-LabRemote -IPAddress $DcAIP -Credential $DomainCred -ScriptBlock {
    param($Password)

    Import-Module ActiveDirectory

    # AD auto-discovery is unreliable when running via a remote session on a
    # freshly-promoted DC. Force all AD cmdlets to use the local DC explicitly.
    $PSDefaultParameterValues = @{
        '*-AD*:Server' = 'localhost'
    }

    $adDomain    = Get-ADDomain
    if (-not $adDomain -or -not $adDomain.DistinguishedName) {
        throw "Get-ADDomain returned no result - DC not reachable. ADWS state: $((Get-Service ADWS).Status)"
    }
    $domainDn    = $adDomain.DistinguishedName
    $domain      = $adDomain.DNSRoot
    $usersAdPath = "CN=Users,$domainDn"
    $securePass  = ConvertTo-SecureString -AsPlainText $Password -Force

    $parentOuName = 'SADAB'
    $childOUs     = @('Servers', 'Endpoints', 'Users', 'Groups', 'Installation')

    # ── Create parent OU ──────────────────────────────────────────────────
    $parentOuDn = "OU=$parentOuName,$domainDn"
    if (-not (Get-ADOrganizationalUnit -Filter "distinguishedName -eq '$parentOuDn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $parentOuName -Path $domainDn -ProtectedFromAccidentalDeletion $true
        Write-Host "Created parent OU: $parentOuName"
    }

    # ── Create child OUs ──────────────────────────────────────────────────
    foreach ($ouName in $childOUs) {
        $ouDn = "OU=$ouName,$parentOuDn"
        if (-not (Get-ADOrganizationalUnit -Filter "distinguishedName -eq '$ouDn'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ouName -Path $parentOuDn -ProtectedFromAccidentalDeletion $true
            Write-Host "Created child OU: $parentOuName\$ouName"
        }
    }

    # ── Redirect default computer OU to Endpoints ─────────────────────────
    $endpointsOuDn = "OU=Endpoints,$parentOuDn"
    if (Get-ADOrganizationalUnit -Filter "distinguishedName -eq '$endpointsOuDn'" -ErrorAction SilentlyContinue) {
        & redircmp $endpointsOuDn
        Write-Host "Default computer OU set to: $endpointsOuDn"
    }

    # ── KDS root key for gMSA ─────────────────────────────────────────────
    $existingKey = Get-KdsRootKey -ErrorAction SilentlyContinue
    if (-not $existingKey) {
        Add-KdsRootKey -EffectiveTime (Get-Date).AddHours(-10) | Out-Null
        Write-Host 'KDS root key created (immediate).'
    }

    # ── Create gMSA: whoami$ ──────────────────────────────────────────────
    $msaAdPath = "CN=Managed Service Accounts,$domainDn"
    $msaName   = 'whoami'
    if (-not (Get-ADServiceAccount -Filter "Name -eq '$msaName'" -ErrorAction SilentlyContinue)) {
        New-ADServiceAccount -Path $msaAdPath -DNSHostName $domain -Name $msaName
        Set-ADServiceAccount -Identity $msaName -PrincipalsAllowedToRetrieveManagedPassword @(
            "CN=Domain Controllers,$usersAdPath"
            "CN=Domain Computers,$usersAdPath"
        )
        Write-Host "Created gMSA: $msaName"
    }

    # ── Create security groups for SQL gMSAs ─────────────────────────────
    $groupsOuDn = "OU=Groups,$parentOuDn"
    $sqlGroups = @(
        @{ Name = 'SQLServersA'; Description = 'Computers allowed to use A-gMSA (Site A SQL)' }
        @{ Name = 'SQLServersB'; Description = 'Computers allowed to use B-gMSA (Site B SQL)' }
        @{ Name = 'SQLgMSAs';    Description = 'All SQL gMSA accounts — used for AG endpoint grants' }
    )
    foreach ($grp in $sqlGroups) {
        if (-not (Get-ADGroup -Filter "Name -eq '$($grp.Name)'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $grp.Name -GroupScope Global -GroupCategory Security `
                        -Path $groupsOuDn -Description $grp.Description
            Write-Host "Created group: $($grp.Name)"
        }
    }

    # Add SQL server computer accounts to their groups
    $aSQL = Get-ADComputer -Filter "Name -eq 'A-SQLSCCM'" -ErrorAction SilentlyContinue
    if ($aSQL) {
        Add-ADGroupMember -Identity 'SQLServersA' -Members $aSQL -ErrorAction SilentlyContinue
        Write-Host 'Added A-SQLSCCM$ to SQLServersA'
    }
    $bSQL = Get-ADComputer -Filter "Name -eq 'B-SQLSCCM'" -ErrorAction SilentlyContinue
    if ($bSQL) {
        Add-ADGroupMember -Identity 'SQLServersB' -Members $bSQL -ErrorAction SilentlyContinue
        Write-Host 'Added B-SQLSCCM$ to SQLServersB'
    }

    # ── Create gMSA: A-gMSA$ (SQL service account for Site A) ────────────
    if (-not (Get-ADServiceAccount -Filter "Name -eq 'A-gMSA'" -ErrorAction SilentlyContinue)) {
        New-ADServiceAccount -Name 'A-gMSA' `
            -Path $msaAdPath `
            -DNSHostName "A-gMSA.$domain" `
            -Description 'SQL Server service account for Site A (A-SQLSCCM)' `
            -PrincipalsAllowedToRetrieveManagedPassword 'SQLServersA'
        Write-Host 'Created gMSA: A-gMSA$'
    }

    # ── Create gMSA: B-gMSA$ (SQL service account for Site B) ────────────
    if (-not (Get-ADServiceAccount -Filter "Name -eq 'B-gMSA'" -ErrorAction SilentlyContinue)) {
        New-ADServiceAccount -Name 'B-gMSA' `
            -Path $msaAdPath `
            -DNSHostName "B-gMSA.$domain" `
            -Description 'SQL Server service account for Site B (B-SQLSCCM)' `
            -PrincipalsAllowedToRetrieveManagedPassword 'SQLServersB'
        Write-Host 'Created gMSA: B-gMSA$'
    }

    # ── Add both gMSAs to SQLgMSAs group (for AG endpoint grants) ────────
    foreach ($msaAcct in @('A-gMSA', 'B-gMSA')) {
        $msa = Get-ADServiceAccount -Filter "Name -eq '$msaAcct'" -ErrorAction SilentlyContinue
        if ($msa) {
            Add-ADGroupMember -Identity 'SQLgMSAs' -Members $msa -ErrorAction SilentlyContinue
            Write-Host "Added $msaAcct`$ to SQLgMSAs"
        }
    }

    # ── Create user: itamartz ─────────────────────────────────────────────
    $usersOuDn = "OU=Users,$parentOuDn"
    $userName   = 'itamartz'
    $existingUser = Get-ADUser -Filter "SamAccountName -eq '$userName'" -ErrorAction SilentlyContinue

    if (-not $existingUser) {
        New-ADUser `
            -Path $usersOuDn `
            -Name $userName `
            -UserPrincipalName "$userName@$domain" `
            -EmailAddress "$userName@$domain" `
            -GivenName 'Itamar' `
            -Surname 'Tziger' `
            -DisplayName 'Itamar Tziger' `
            -AccountPassword $securePass `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -Description 'Lab Administrator'
        Write-Host "Created user: $userName"
    } else {
        # Move to proper OU if still in CN=Users
        if ($existingUser.DistinguishedName -like "CN=$userName,CN=Users,*") {
            Move-ADObject -Identity $existingUser.DistinguishedName -TargetPath $usersOuDn
            Write-Host "Moved $userName to $usersOuDn"
        }
    }

    # ── Add itamartz to admin groups ──────────────────────────────────────
    foreach ($group in @('Domain Admins', 'Enterprise Admins', 'Schema Admins')) {
        $isMember = Get-ADGroupMember -Identity $group -ErrorAction SilentlyContinue |
            Where-Object { $_.SamAccountName -eq $userName }
        if (-not $isMember) {
            Add-ADGroupMember -Identity $group -Members $userName
            Write-Host "Added $userName to $group"
        }
    }

    # ── Set Administrator password and ensure it never expires ─────────────
    Set-ADAccountPassword -Identity "CN=Administrator,$usersAdPath" -Reset -NewPassword $securePass
    Set-ADUser -Identity "CN=Administrator,$usersAdPath" -PasswordNeverExpires $true

    Write-Host 'AD structure configured.' -ForegroundColor Green

} -ArgumentList $DomainAdminPassword

Write-LabLog 'AD structure configured: OUs, users, gMSA, redircmp.' -Level SUCCESS -Step 'ADStructure'
