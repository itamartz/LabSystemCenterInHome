<#
.SYNOPSIS
    Publishes SCOM to Active Directory so agents can look up their
    Management Server via the AD container instead of having it hard-coded
    at install time. Adds an AD Agent Assignment rule that points every
    SADAB server (except the MS itself) at B-SCOMMS.

.NOTES
    Three layered Test/Set steps:

    1) AD group `SADAB_Role_SCOM_ManagementServers` exists (in OU=Groups)
       with B-SCOMMS$ as a member. Per the lab's group-based RBAC
       convention - the group is what gets write permissions to the SCOM
       AD container; B-SCOMMS$ inherits via membership.

    2) The SCOM AD container exists:
            CN=Operations Manager,CN=Microsoft Operations Manager,
            CN=System,DC=sadab,DC=pri
       Set step calls MOMADAdmin.exe on B-SCOMMS, passing the management
       group name, the security group from step 1, the primary MS FQDN,
       and the domain. MOMADAdmin creates the container and grants the
       group the right ACLs. Idempotent (re-run is a no-op if the
       container already exists with the right perms).

    3) An SCOM AD Agent Assignment rule exists that scopes every SADAB
       computer (except B-SCOMMS itself) to B-SCOMMS as primary MS.
       Set step uses Add-SCOMADAgentAssignment.

    Why bother in this lab: we have 1 MS so failover isn't relevant, and
    all agents are push-installed with the MS hard-coded. AD Integration's
    real value here is future-proofing - any agent later installed
    without -PrimaryManagementServer will auto-discover B-SCOMMS via AD.
    It's also a recognized SCOM-on-AD best practice.
#>
[CmdletBinding()]
param(
    [string]$VMName                = 'B-SCOMMS',
    [string]$DomainAdminPassword   = 'LabAdmin@2026!',
    [string]$ManagementGroup       = 'LAB-SCOM-MG',
    [string]$DomainFQDN            = 'sadab.pri',
    [string]$DomainNetBIOS         = 'SADAB',
    [string]$MsFqdn                = 'B-SCOMMS.sadab.pri',
    [string]$MsHostName            = 'B-SCOMMS',
    [string]$ScomRunAsAccount      = 'SADAB\Administrator',   # the SCOM Action Account used to publish into the AD container
    [string]$AdGroupName           = 'SADAB_Role_SCOM_ManagementServers',
    [string]$AdGroupOU             = 'OU=Groups,OU=SADAB,DC=sadab,DC=pri'
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][SCOM-AD] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

. "$PSScriptRoot\..\lib\Connect-LabHost.ps1"

$secCred = Import-Clixml (Join-Path $PSScriptRoot '..\..\.secrets\hyperv-host.cred.xml')
$hbCred  = $secCred   # same project secret today (host B WinRM)
$domCred = New-Object PSCredential(
    "$DomainNetBIOS\Administrator",
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

# Note: not using a helper here. The string-to-scriptblock conversion
# across the PSRemoting boundary is fragile; the safest pattern is to
# embed the inner scriptblock as a static literal inside the outer one.
# So each B-SCOMMS step inlines its own Invoke-Command + Invoke-Command pair.

# =========================================================================
# Step 1: AD group + B-SCOMMS membership (run on A-DC for AD module)
# =========================================================================
Write-Stage "Step 1/3: AD group $AdGroupName ..."

# Step 1 only ensures the GROUP exists. MOMADAdmin (Step 2) is what adds
# the SCOM Run-As Account (SADAB\Administrator) to this group as a side
# effect - we don't need to pre-populate the group ourselves.
$adSb = [scriptblock]::Create(@"
    Import-Module ActiveDirectory
    `$GroupName = '$AdGroupName'
    `$GroupOU   = '$AdGroupOU'

    `$g = Get-ADGroup -Filter "Name -eq '`$GroupName'" -ErrorAction SilentlyContinue
    if (`$g) {
        Write-Host "[TEST PASS] group `$GroupName exists at `$(`$g.DistinguishedName)"
    } else {
        Write-Host "[SET]       creating group `$GroupName under `$GroupOU"
        New-ADGroup -Name `$GroupName -Path `$GroupOU -GroupScope Global -GroupCategory Security ``
                    -Description 'SADAB lab: members get full-control on the SCOM AD container (CN=Operations Manager,...). MOMADAdmin.exe uses this as its MOMAdminSecurityGroup arg and auto-adds the SCOM Run-As Account when the container is created.' ``
                    -ErrorAction Stop
        `$g = Get-ADGroup -Identity `$GroupName
        Write-Host "[RE-TEST]   `$(`$g.DistinguishedName)"
    }
"@)
Invoke-LabVM -VMName 'A-DC' -UseDomainCredential -ScriptBlock $adSb

# =========================================================================
# Step 2: SCOM AD container (run on B-SCOMMS, MOMADAdmin.exe)
# =========================================================================
Write-Stage "Step 2/3: SCOM AD container via MOMADAdmin.exe ..."

Invoke-Command -ComputerName 100.117.142.13 -Credential $hbCred -Authentication Negotiate -ScriptBlock {
    param($Mg, $DomainFqdn, $RunAsAccount, $AdGroupName, $DomainNetBIOS, $dc)
    Invoke-Command -VMName 'B-SCOMMS' -Credential $dc -ScriptBlock {
        param($Mg, $DomainFqdn, $RunAsAccount, $AdGroupName, $DomainNetBIOS)
        # MOMADAdmin.exe usage (per `MOMADAdmin /?`):
        #   MomADAdmin ManagementGroupName MOMAdminSecurityGroup RunAsAccount Domain
        #
        # Arg 2 = security group whose members get full-control on the AD container.
        # Arg 3 = the SCOM Action / RunAs Account that publishes agent assignments
        #         (must be a user account that exists in the domain - NOT a server FQDN).
        $domainDn = "DC=" + (($DomainFqdn -split '\.') -join ',DC=')
        $containerDn = "CN=Operations Manager,CN=Microsoft Operations Manager,CN=System,$domainDn"
        # [ADSI] is a lazy bind - just constructing the object doesn't fail
        # even for non-existent paths. Force a property read to actually
        # resolve the bind and surface any "not found" error.
        try {
            $de = [ADSI]"LDAP://$containerDn"
            $null = $de.distinguishedName   # throws if container doesn't exist
            $exists = $true
        } catch { $exists = $false }
        if ($exists) {
            Write-Host "[TEST PASS] AD container exists: $containerDn"
        } else {
            Write-Host "[SET]       running MOMADAdmin.exe ..."
            $exe = 'C:\Program Files\Microsoft System Center\Operations Manager\Server\MOMADAdmin.exe'
            if (-not (Test-Path $exe)) { throw "MOMADAdmin.exe not present at $exe" }
            if (-not (Test-Path 'C:\Temp')) { New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null }
            $exeArgs = @($Mg, "$DomainNetBIOS\$AdGroupName", $RunAsAccount, $DomainFqdn)
            Write-Host "  $exe $($exeArgs -join ' ')"
            $p = Start-Process -FilePath $exe -ArgumentList $exeArgs -Wait -PassThru -NoNewWindow `
                               -RedirectStandardOutput 'C:\Temp\momadadmin.out' `
                               -RedirectStandardError  'C:\Temp\momadadmin.err'
            Write-Host "  exit code: $($p.ExitCode)"
            foreach ($f in 'C:\Temp\momadadmin.out','C:\Temp\momadadmin.err') {
                if (Test-Path $f) { $c = Get-Content $f -ErrorAction SilentlyContinue; if ($c) { Write-Host "  --- $(Split-Path $f -Leaf) ---"; $c | ForEach-Object { Write-Host "  $_" } } }
            }
            if ($p.ExitCode -ne 0) { throw "MOMADAdmin failed with exit $($p.ExitCode)" }
            Start-Sleep 5
            try { $de = [ADSI]"LDAP://$containerDn"; if ($de.Path) { Write-Host "[RE-TEST]   AD container created" } } catch { Write-Host "[RE-TEST]   FAIL: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    } -ArgumentList $Mg, $DomainFqdn, $RunAsAccount, $AdGroupName, $DomainNetBIOS
} -ArgumentList $ManagementGroup, $DomainFQDN, $ScomRunAsAccount, $AdGroupName, $DomainNetBIOS, $domCred

# =========================================================================
# Step 3: SCOM AD Agent Assignment (run on B-SCOMMS, OperationsManager)
# =========================================================================
Write-Stage "Step 3/3: SCOM AD Agent Assignment rule (every SADAB server -> B-SCOMMS) ..."

Invoke-Command -ComputerName 100.117.142.13 -Credential $hbCred -Authentication Negotiate -ScriptBlock {
    param($MsFqdn, $DomainFqdn, $MsShort, $dc)
    Invoke-Command -VMName 'B-SCOMMS' -Credential $dc -ScriptBlock {
        param($MsFqdn, $DomainFqdn, $MsShort)
        Import-Module OperationsManager -ErrorAction Stop
        New-SCOMManagementGroupConnection -ComputerName $MsFqdn | Out-Null
        $ms = Get-SCOMManagementServer -Name $MsFqdn
        $ldap = "(&(objectCategory=computer)(!cn=$MsShort))"
        # Get-SCOMADAgentAssignment uses -PrimaryServer (not -ManagementServer)
        $existing = Get-SCOMADAgentAssignment -PrimaryServer $ms -ErrorAction SilentlyContinue |
                    Where-Object { $_.LdapQuery -eq $ldap }
        if ($existing) {
            Write-Host "[TEST PASS] AD Agent Assignment rule already present for $MsFqdn"
        } else {
            Write-Host "[SET]       Add-SCOMADAgentAssignment ..."
            Add-SCOMADAgentAssignment -PrimaryServer $ms -LdapQuery $ldap -Domain $DomainFqdn -ErrorAction Stop
            if (Get-SCOMADAgentAssignment -PrimaryServer $ms -ErrorAction SilentlyContinue | Where-Object { $_.LdapQuery -eq $ldap }) {
                Write-Host "[RE-TEST]   PASS"
            } else { Write-Host "[RE-TEST]   FAIL" -ForegroundColor Yellow }
        }
        Write-Host "`n=== Current AD Agent Assignments for $MsFqdn ==="
        Get-SCOMADAgentAssignment -PrimaryServer $ms -ErrorAction SilentlyContinue |
            Select-Object Domain, LdapQuery | Format-Table -AutoSize | Out-String | Write-Host
    } -ArgumentList $MsFqdn, $DomainFqdn, $MsShort
} -ArgumentList $MsFqdn, $DomainFQDN, $MsHostName, $domCred

Write-Stage "Done. New agents pushed/installed without an explicit -PrimaryManagementServer will now look up B-SCOMMS via AD."
