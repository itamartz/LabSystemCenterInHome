<#
.SYNOPSIS
    Configures SCCM clients (agents) to connect to the site over HTTPS using PKI
    certificates: a Client-Authentication cert (autoenrolled to domain computers from the
    domain CA SADAB-Root-CA) + an HTTPS Management Point with a server-auth cert. Idempotent.
    Run from the Hyper-V host. PS 5.1 only. Use Write-LabLog.

.DESCRIPTION
    End state: the MP on A-MPDP serves HTTPS with a PKI Web Server cert; every domain
    computer autoenrolls a Workstation-Authentication (Client Auth EKU) cert; the site is set
    to "HTTPS or HTTP" so the agent presents its PKI client cert and connects to the MP over
    HTTPS. Reuses SADAB-Root-CA (stood up by Configure-SCCMReporting.ps1).

    DSC-backed where a resource exists (ConfigMgrCBDsc CMManagementPoint EnableSsl,
    CMSiteConfiguration; CertificateDsc CertReq). The CA template ACL + autoenrollment GPO
    are AD/GPO operations (no DSC) - the documented exception, same as the reporting CA setup.

    STAGES (re-runnable; default 'All' = Template -> ClientCerts -> MPCert -> SCCM, then Status.
    Run -Stage Verify against a client afterwards):
      Template    A-DC: grant Domain Computers Enroll+Autoenroll on the Workstation template,
                  publish it to the CA, and create+link an autoenrollment GPO (AEPolicy=7).
      ClientCerts gpupdate + certutil -pulse on each server so it autoenrolls a Client-Auth
                  cert BEFORE the MP flips to HTTPS (so no server loses MP connectivity).
      MPCert      A-MPDP: ensure a Web Server (server-auth) cert + bind it to Default Web
                  Site:443 (the MP's IIS site).
      SCCM        DSC CMManagementPoint EnableSsl=$true + CMSiteConfiguration
                  ClientComputerCommunicationType='HttpsOrHttp'.
      Verify      -ClientVM <name>: confirm the client has a Client-Auth PKI cert and that it
                  talks to the MP over HTTPS (LocationServices / ClientIDManagerStartup logs).
      Status      print MP SslState + site comm mode.

    WHY HttpsOrHttp (not HttpsOnly): graceful - a client that hasn't enrolled a cert yet can
    still fall back, and it avoids locking the lab out of the MP if PKI is misconfigured.

    GOTCHAS (encoded):
      * A single MP is either HTTP or HTTPS - it can't serve both. So every managed server
        must have a Client-Auth cert BEFORE EnableSsl flips the MP to HTTPS, or it loses its
        MP. Hence ClientCerts runs before SCCM. All lab servers are domain members and trust
        SADAB-Root-CA, so autoenrollment covers them.
      * Machine-context enrollment: clients autoenroll via the GPO (AEPolicy=7) + the template
        Autoenroll permission for Domain Computers. The Workstation template has the Client
        Authentication EKU - exactly what the SCCM client selects from LocalMachine\My.
      * Set-GPRegistryValue writes the Registry.pol for AEPolicy - no hand-crafted .pol.

.NOTES
    Author  : SADAB Lab
    Version : 1.0.
    Requires: SADAB-Root-CA on A-DC; SCCM PR1 + MP on A-MPDP; ConfigMgrCBDsc + CertificateDsc.
#>
[CmdletBinding()]
param(
    [ValidateSet('All','Template','ClientCerts','MPCert','SCCM','Verify','Status')]
    [string]$Stage = 'All',

    [string]$SiteCode      = 'PR1',
    [string]$SiteServer    = 'A-SCCM.sadab.pri',
    [string]$MpServer      = 'A-MPDP.sadab.pri',
    [string]$MpShort       = 'A-MPDP',
    [string]$DcFqdn        = 'A-DC.sadab.pri',
    [string]$CaCommonName  = 'SADAB-Root-CA',
    [string]$ClientTemplate= 'Workstation',     # built-in Workstation Authentication (Client Auth EKU)
    [string]$ClientVM      = 'A-DFSR',
    [string]$ClientVMIP    = '10.10.0.7',
    # servers to pre-enroll client certs on (members of All Servers)
    [hashtable]$Servers    = @{ 'A-SCCM'='10.10.0.3'; 'A-SQLSCCM'='10.10.0.4'; 'A-MPDP'='10.10.0.5'; 'A-DFSR'='10.10.0.7' },
    [bool]  $EnsureModule  = $true,

    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force
$DcIP='10.10.0.2'; $MpIP='10.10.0.5'; $SccmIP='10.10.0.3'
if (-not $DomainCred) {
    if (-not $DomainAdminPassword) { throw "Provide -DomainCred or -DomainAdminPassword." }
    $DomainCred = New-Object System.Management.Automation.PSCredential('SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

# ── Template + autoenrollment GPO (A-DC) ───────────────────────────────────────
function Invoke-Template {
    Write-LabLog "Granting Domain Computers Enroll+Autoenroll on '$ClientTemplate' + autoenrollment GPO (A-DC)..." -Step 'PKI/Template'
    Invoke-LabRemote -IPAddress $DcIP -Credential $DomainCred -ScriptBlock {
        param($ClientTemplate)
        $ErrorActionPreference='Stop'
        $de=[ADSI]"LDAP://CN=$ClientTemplate,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=sadab,DC=pri"
        $sid=(New-Object System.Security.Principal.NTAccount('SADAB\Domain Computers')).Translate([System.Security.Principal.SecurityIdentifier])
        $enroll=[GUID]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
        $autoenroll=[GUID]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
        $de.ObjectSecurity.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,'ExtendedRight','Allow',$enroll)))
        $de.ObjectSecurity.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,'ExtendedRight','Allow',$autoenroll)))
        $de.ObjectSecurity.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,'GenericRead','Allow')))
        $de.CommitChanges()
        # publish the template to the CA (idempotent)
        Import-Module ADCSAdministration -ErrorAction SilentlyContinue
        if (-not (Get-CATemplate | Where-Object Name -eq $ClientTemplate)) { try { Add-CATemplate -Name $ClientTemplate -Force -ErrorAction Stop } catch { & certutil -SetCATemplates "+$ClientTemplate" | Out-Null } }
        # autoenrollment GPO (Set-GPRegistryValue writes Registry.pol; no hand-crafted .pol)
        Import-Module GroupPolicy -ErrorAction Stop
        $gpoName='SADAB Computer Certificate AutoEnrollment'
        $g=Get-GPO -Name $gpoName -ErrorAction SilentlyContinue; if (-not $g) { $g=New-GPO -Name $gpoName }
        Set-GPRegistryValue -Name $gpoName -Key 'HKLM\Software\Policies\Microsoft\Cryptography\AutoEnrollment' -ValueName AEPolicy -Type DWord -Value 7 | Out-Null
        try { New-GPLink -Name $gpoName -Target 'DC=sadab,DC=pri' -LinkEnabled Yes -ErrorAction Stop | Out-Null } catch { }   # already linked
        "Template '$ClientTemplate' enroll/autoenroll granted + published; GPO '$gpoName' set (AEPolicy=7) + linked."
    } -ArgumentList $ClientTemplate
}

# ── Pre-enroll Client-Auth certs on each server (before MP goes HTTPS) ──────────
function Invoke-ClientCerts {
    foreach ($name in $Servers.Keys) {
        $ip=$Servers[$name]
        Write-LabLog "Autoenrolling Client-Auth cert on $name ($ip)..." -Step 'PKI/ClientCerts'
        Invoke-LabRemote -IPAddress $ip -Credential $DomainCred -ScriptBlock {
            param($CaCommonName)
            gpupdate /target:computer /force | Out-Null
            & certutil -pulse | Out-Null
            Start-Sleep 5
            $c = Get-ChildItem Cert:\LocalMachine\My | Where-Object { ($_.EnhancedKeyUsageList.FriendlyName -contains 'Client Authentication') -and ($_.Issuer -match $CaCommonName) } | Select-Object -First 1
            if ($c) { "client-auth cert present: $($c.Thumbprint) (subject $($c.Subject))" } else { "NO client-auth cert yet (autoenroll may be pending - re-run after a minute)" }
        } -ArgumentList $CaCommonName
    }
}

# ── MP server cert + HTTPS 443 binding (A-MPDP) ────────────────────────────────
function Invoke-MPCert {
    Write-LabLog "Ensuring Web Server cert + HTTPS/443 binding on $MpServer (Default Web Site)..." -Step 'PKI/MPCert'
    Invoke-LabRemote -IPAddress $MpIP -Credential $DomainCred -ScriptBlock {
        param($MpFqdn,$MpShort,$DcFqdn,$CaCommonName)
        $ErrorActionPreference='Stop'
        gpupdate /target:computer /force | Out-Null; Start-Sleep 3
        # reuse an existing A-MPDP WebServer cert if present (e.g. the WSUS cert), else enroll
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$MpFqdn" -and $_.Issuer -match $CaCommonName -and ($_.EnhancedKeyUsageList.FriendlyName -contains 'Server Authentication') } | Sort-Object NotBefore -Descending | Select-Object -First 1
        if (-not $cert) {
            if (-not (Get-Module -ListAvailable CertificateDsc)) { Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force|Out-Null; Set-PSRepository PSGallery -InstallationPolicy Trusted -EA SilentlyContinue; Install-Module CertificateDsc -Scope AllUsers -Force -AllowClobber -Confirm:$false }
            $cdsc=(Get-Module -ListAvailable CertificateDsc|Sort-Object Version -Descending|Select-Object -First 1).ModuleBase
            Import-Module (Join-Path $cdsc 'DSCResources\DSC_CertReq\DSC_CertReq.psm1') -Force
            $cp=@{ Subject="CN=$MpFqdn"; CAServerFQDN=$DcFqdn; CARootName=$CaCommonName; CertificateTemplate='WebServer'; SubjectAltName="dns=$MpFqdn&dns=$MpShort"; KeyLength='2048'; KeyUsage='0xa0'; OID='1.3.6.1.5.5.7.3.1'; FriendlyName='MP HTTPS'; AutoRenew=$true; UseMachineContext=$true }
            if (-not (Test-TargetResource @cp)) { Set-TargetResource @cp }
            $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$MpFqdn" -and $_.Issuer -match $CaCommonName } | Sort-Object NotBefore -Descending | Select-Object -First 1
        }
        $thumb=$cert.Thumbprint
        Import-Module WebAdministration -Force
        if (-not (Get-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -ErrorAction SilentlyContinue)) {
            New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -IPAddress '*' | Out-Null
        }
        (Get-WebBinding -Name 'Default Web Site' -Protocol https -Port 443).AddSslCertificate($thumb,'My')
        "MP cert bound to Default Web Site:443 thumb=$thumb"
    } -ArgumentList $MpServer,$MpShort,$DcFqdn,$CaCommonName
}

# ── MP -> HTTPS + site -> HttpsOrHttp (DSC on A-SCCM) ──────────────────────────
function Invoke-SCCM {
    Write-LabLog "Setting MP EnableSsl + site ClientComputerCommunicationType=HttpsOrHttp (DSC)..." -Step 'PKI/SCCM'
    $results = Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
        param($SiteCode,$SiteServer,$MpServer,$EnsureModule)
        $ErrorActionPreference='Stop'; $CMPSSuppressFastNotUsedCheck=$true
        $mod=Get-Module -ListAvailable ConfigMgrCBDsc|Sort-Object Version -Descending|Select-Object -First 1
        $dscRoot=Join-Path $mod.ModuleBase 'DSCResources'
        Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1')
        if (-not (Get-PSDrive -Name $SiteCode -EA SilentlyContinue)) { New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer|Out-Null }
        function Invoke-CMResource{param([string]$Resource,[hashtable]$Property)
            Get-Module DSC_CM*|Remove-Module -Force -EA SilentlyContinue; Import-Module (Join-Path $dscRoot "DSC_$Resource\DSC_$Resource.psm1") -Force
            $b=[bool](Test-TargetResource @Property); if(-not $b){Set-TargetResource @Property|Out-Null;$a=[bool](Test-TargetResource @Property)}else{$a=$true}
            [pscustomobject]@{Resource=$Resource;WasCompliant=$b;Action=$(if($b){'none'}else{'Set'});NowCompliant=$a} }
        $out=@()
        $out+=Invoke-CMResource 'CMManagementPoint' @{ SiteCode=$SiteCode; SiteServerName=$MpServer; ClientConnectionType='Intranet'; EnableSsl=$true; Ensure='Present' }
        # UsePkiClientCertificate=$true is the core "agent uses a PKI cert" setting; HttpsOrHttp
        # keeps HTTP fallback; ClientAuthentication selection picks the Client-Auth cert.
        $out+=Invoke-CMResource 'CMSiteConfiguration' @{ SiteCode=$SiteCode; ClientComputerCommunicationType='HttpsOrHttp'; UsePkiClientCertificate=$true; UseSmsGeneratedCert=$true; ClientCertificateSelectionCriteriaType='ClientAuthentication' }
        $out
    } -ArgumentList $SiteCode,$SiteServer,$MpServer,$EnsureModule
    $results | Format-Table Resource, WasCompliant, Action, NowCompliant -AutoSize
    Write-LabLog "MP set to HTTPS + site to HttpsOrHttp. MP reconfig is async (watch MPSetup/MPControl.log)." -Level SUCCESS -Step 'PKI/SCCM'
}

# ── Verify a client connects to the MP over HTTPS with its PKI cert ────────────
function Invoke-Verify {
    Write-LabLog "Verifying $ClientVM uses a PKI cert to connect to the MP over HTTPS..." -Step 'PKI/Verify'
    Invoke-LabRemote -IPAddress $ClientVMIP -Credential $DomainCred -ScriptBlock {
        param($CaCommonName)
        gpupdate /target:computer /force | Out-Null; & certutil -pulse | Out-Null; Start-Sleep 5
        $c = Get-ChildItem Cert:\LocalMachine\My | Where-Object { ($_.EnhancedKeyUsageList.FriendlyName -contains 'Client Authentication') -and ($_.Issuer -match $CaCommonName) } | Select-Object -First 1
        "Client-Auth PKI cert: " + $(if($c){"$($c.Thumbprint) ($($c.Subject))"}else{'MISSING'})
        # nudge the SCCM client to re-evaluate MP + policy
        '{00000000-0000-0000-0000-000000000021}','{00000000-0000-0000-0000-000000000101}' | ForEach-Object { try { Invoke-WmiMethod -Namespace root\ccm -Class SMS_Client -Name TriggerSchedule -ArgumentList $_ | Out-Null } catch {} }
        Start-Sleep 30
        "--- LocationServices.log (MP + HTTPS) ---"
        Get-Content 'C:\Windows\CCM\Logs\LocationServices.log' -Tail 60 -EA SilentlyContinue | ForEach-Object { ($_ -split '\]LOG')[0] } | Where-Object { $_ -match 'HTTPS|https://|MP |Management Point|Capabilities|SSL' } | Select-Object -Last 8
        "--- ClientIDManagerStartup.log (PKI cert selection) ---"
        Get-Content 'C:\Windows\CCM\Logs\ClientIDManagerStartup.log' -Tail 60 -EA SilentlyContinue | ForEach-Object { ($_ -split '\]LOG')[0] } | Where-Object { $_ -match 'certificate|PKI|Client cert|thumbprint|Set .*cert' } | Select-Object -Last 8
    } -ArgumentList $CaCommonName
}

function Show-Status {
    Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
        param($SiteCode,$SiteServer,$MpServer)
        $CMPSSuppressFastNotUsedCheck=$true
        Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1')
        if (-not (Get-PSDrive -Name $SiteCode -EA SilentlyContinue)) { New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer|Out-Null }
        Set-Location "$($SiteCode):"
        "MP SslState (1=HTTPS): " + (Get-CMManagementPoint -SiteSystemServerName $MpServer | Select-Object -ExpandProperty SslState)
    } -ArgumentList $SiteCode,$SiteServer,$MpServer
}

switch ($Stage) {
    'Template'    { Invoke-Template }
    'ClientCerts' { Invoke-ClientCerts }
    'MPCert'      { Invoke-MPCert }
    'SCCM'        { Invoke-SCCM }
    'Verify'      { Invoke-Verify }
    'Status'      { Show-Status }
    'All'         { Invoke-Template; Invoke-ClientCerts; Invoke-MPCert; Invoke-SCCM;
                    Write-LabLog "PKI client comms configured. Run -Stage Verify once clients have refreshed policy." -Level SUCCESS -Step 'PKI' }
}
