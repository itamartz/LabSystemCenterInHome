<#
.SYNOPSIS
    Stands up domain PKI + SCCM reporting over HTTPS, DSC-backed: an Enterprise Root CA,
    the SCCM_Reports account, SSRS on the PRIMARY site server (A-SCCM) running as a
    virtual account with a CA-issued HTTPS cert, and the Reporting Services Point role on
    A-SCCM using SCCM_Reports. Idempotent. Run AFTER the site + SQL are up.

.DESCRIPTION
    The RSP role MUST be co-located with SSRS, so to satisfy "role on the Primary server"
    SSRS is installed on A-SCCM (its ReportServer catalog DB lives on the remote SQL,
    A-SQLSCCM). SSRS's default service account is the VIRTUAL account
    'NT SERVICE\SQLServerReportingServices'. The HTTPS cert is issued by the domain CA
    (reused later for SCCM Agent PKI), NOT self-signed.

    DSC modules / resources:
      * ActiveDirectoryCSDsc AdcsCertificationAuthority - Enterprise Root CA on A-DC.
      * ActiveDirectoryDsc    ADUser                    - SCCM_Reports account.
      * SqlServerDsc 15.2.0   DSC_SqlRSSetup / DSC_SqlRS - install + configure SSRS.
      * CertificateDsc        DSC_CertReq               - enroll the CA Server-Auth cert.
      * ConfigMgrCBDsc        CMAccounts / CMReportingServicePoint - CM account + RSP role.

    GOTCHAS (learned 2026-05-25 - all encoded below):
      * Enterprise Root CA on A-DC auto-publishes its root to AD; run `gpupdate` on the
        target so it lands in LocalMachine\Root before enrolling/serving HTTPS.
      * MACHINE-context cert enrollment: do NOT pass DSC_CertReq -Credential (it does
        CreateProcessAsUser -> error 1314 in a remote session). Use UseMachineContext=$true
        so the COMPUTER account enrolls - which means the computer needs Enroll on the
        template. Grant 'Domain Computers' Enroll on the **WebServer** template (done here
        via the template AD object ACL + the Enroll extended-right GUID
        0e10c968-78fb-11d2-90d4-00c04f79dc55).
      * SqlServerDsc 17.x is class-based and fails Invoke-DscResource on PS 5.1 - use
        **15.2.0** (MOF DSC_SqlRSSetup/DSC_SqlRS) with import-psm1 + Test/Set. Install SSRS
        via a SYSTEM scheduled task (long install survives the session); BITS downloads
        must also run as SYSTEM (in-session BITS gives 0x800704DD).
      * DSC_SqlRS needs a SqlServer/SQLPS PS module on the node. On A-SCCM (no SQL) install
        **SqlServer 21.x** - the 22.x client forces connection encryption and rejects the
        SQL self-signed cert ("target principal name is incorrect").
      * HTTPS cert binding is via RS WMI (MSReportServer_ConfigurationSetting,
        namespace ...\RS_SSRS\V16\Admin) - the DSC exception. A stale/orphaned http.sys
        SSL binding on 0.0.0.0:443 must be cleared with `netsh http delete sslcert` before
        CreateSSLCertificateBinding will take the new cert. SetSecureConnectionLevel(1).
      * The RSP account (SCCM_Reports) must be a CM account (CMAccounts) before the RSP.

.NOTES
    Author  : SADAB Lab
    Version : 2.0 (CA-issued cert; role on the Primary server A-SCCM).
    Run from the Hyper-V host. PS 5.1 only. Needs internet (SSRS + module downloads).
#>
[CmdletBinding()]
param(
    [string]$SiteCode    = 'PR1',
    [string]$PrimaryFqdn = 'A-SCCM.sadab.pri',
    [string]$PrimaryShort= 'A-SCCM',
    [string]$SqlFqdn     = 'A-SQLSCCM.sadab.pri',
    [string]$DcFqdn      = 'A-DC.sadab.pri',
    [string]$CaCommonName= 'SADAB-Root-CA',
    [string]$ReportsUser = 'SADAB\SCCM_Reports',
    [string]$SsrsUrl     = 'https://download.microsoft.com/download/8/3/2/832616ff-af64-42b5-a0b1-5eb07f71dec9/SQLServerReportingServices.exe',

    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force
$DcIP='10.10.0.2'; $SqlIP='10.10.0.4'; $SccmIP='10.10.0.3'
if (-not $DomainCred) {
    if (-not $DomainAdminPassword) { throw "Provide -DomainCred or -DomainAdminPassword." }
    $DomainCred = New-Object System.Management.Automation.PSCredential('SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

# ── 1. Enterprise Root CA on A-DC + grant Domain Computers Enroll on WebServer ──
Write-LabLog "Installing Enterprise Root CA '$CaCommonName' on A-DC (DSC)..." -Step 'PKI'
Invoke-LabRemote -IPAddress $DcIP -Credential $DomainCred -ScriptBlock {
    param($dpw,$CaCommonName)
    $ErrorActionPreference='Stop'
    Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools | Out-Null
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if(-not (Get-Module -ListAvailable ActiveDirectoryCSDsc)){ Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force|Out-Null; Set-PSRepository PSGallery -InstallationPolicy Trusted -EA SilentlyContinue; Install-Module ActiveDirectoryCSDsc -Scope AllUsers -Force -AllowClobber }
    $mb=(Get-Module -ListAvailable ActiveDirectoryCSDsc|Sort-Object Version -Descending|Select-Object -First 1).ModuleBase
    Import-Module (Join-Path $mb 'DSCResources\DSC_AdcsCertificationAuthority\DSC_AdcsCertificationAuthority.psm1') -Force
    $ea=New-Object System.Management.Automation.PSCredential('SADAB\Administrator',(ConvertTo-SecureString $dpw -AsPlainText -Force))
    $p=@{ IsSingleInstance='Yes'; CAType='EnterpriseRootCA'; Credential=$ea; CACommonName=$CaCommonName; HashAlgorithmName='SHA256'; KeyLength=2048; ValidityPeriod='Years'; ValidityPeriodUnits=10; Ensure='Present' }
    if(-not (Test-TargetResource @p)){ Set-TargetResource @p }
    # Grant Domain Computers Enroll on the WebServer template (machine enrollment)
    $de=[ADSI]"LDAP://CN=WebServer,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=sadab,DC=pri"
    $sid=(New-Object System.Security.Principal.NTAccount('SADAB\Domain Computers')).Translate([System.Security.Principal.SecurityIdentifier])
    $enroll=[GUID]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
    $de.ObjectSecurity.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,'ExtendedRight','Allow',$enroll)))
    $de.ObjectSecurity.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,'GenericRead','Allow')))
    $de.CommitChanges(); Restart-Service CertSvc -Force
    "CA: " + (Get-Service CertSvc).Status
} -ArgumentList $DomainAdminPassword,$CaCommonName

# ── 2. SCCM_Reports account (ActiveDirectoryDsc, on A-DC) ──────────────────────
Write-LabLog 'Creating SCCM_Reports account (DSC ADUser)...' -Step 'Reporting'
Invoke-LabRemote -IPAddress $DcIP -Credential $DomainCred -ScriptBlock {
    param($dpw)
    $m=Get-Module -ListAvailable ActiveDirectoryDsc|Sort-Object Version -Descending|Select-Object -First 1
    if(-not $m){ Install-Module ActiveDirectoryDsc -Scope AllUsers -Force -AllowClobber; $m=Get-Module -ListAvailable ActiveDirectoryDsc|Sort-Object Version -Descending|Select-Object -First 1 }
    Import-Module (Join-Path $m.ModuleBase 'DSCResources\MSFT_ADUser\MSFT_ADUser.psm1') -Force
    $pwd=New-Object System.Management.Automation.PSCredential('SCCM_Reports',(ConvertTo-SecureString $dpw -AsPlainText -Force))
    $p=@{ DomainName='sadab.pri'; UserName='SCCM_Reports'; Path='OU=Users,OU=SADAB,DC=sadab,DC=pri'; Description='SCCM Reporting Services Point connection / data-source account (SADAB lab)'; Password=$pwd; PasswordNeverExpires=$true; Enabled=$true; Ensure='Present' }
    if(-not (Test-TargetResource @p)){ Set-TargetResource @p|Out-Null }
    "SCCM_Reports present: " + (Test-TargetResource @p)
} -ArgumentList $DomainAdminPassword

# ── 3. Install SSRS on A-SCCM (SqlRSSetup via SYSTEM task; SqlServer 21.x module) ──
Write-LabLog 'Installing SSRS on A-SCCM (DSC SqlRSSetup, SYSTEM task)...' -Step 'Reporting'
Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
    param($SsrsUrl)
    $ErrorActionPreference='Stop'
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if(-not (Get-Module -ListAvailable SqlServerDsc|Where-Object{$_.Version -eq '15.2.0'})){ Install-Module SqlServerDsc -RequiredVersion 15.2.0 -Scope AllUsers -Force -AllowClobber }
    if(-not (Get-Module -ListAvailable SqlServer|Where-Object{$_.Version -lt [version]'22.0'})){ Install-Module SqlServer -RequiredVersion 21.1.18256 -Scope AllUsers -Force -AllowClobber }
    New-Item -ItemType Directory -Force 'C:\Temp'|Out-Null
    if(-not (Test-Path 'C:\Temp\SQLServerReportingServices.exe')){
        Set-Content 'C:\Temp\dl.ps1' -Encoding UTF8 -Value "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Import-Module BitsTransfer; Start-BitsTransfer -Source '$SsrsUrl' -Destination 'C:\Temp\SQLServerReportingServices.exe'"
        Register-ScheduledTask -TaskName DL-SSRS -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Temp\dl.ps1') -User SYSTEM -RunLevel Highest -Force|Out-Null
        Start-ScheduledTask DL-SSRS; $d=(Get-Date).AddMinutes(6); do{Start-Sleep 20}until((Test-Path 'C:\Temp\SQLServerReportingServices.exe' -PathType Leaf) -and (Get-Item 'C:\Temp\SQLServerReportingServices.exe').Length -gt 100MB -or (Get-Date) -gt $d)
    }
    if(-not (Get-Service SQLServerReportingServices -EA SilentlyContinue)){
        Set-Content 'C:\Temp\inst.ps1' -Encoding UTF8 -Value 'Import-Module "C:\Program Files\WindowsPowerShell\Modules\SqlServerDsc\15.2.0\DSCResources\DSC_SqlRSSetup\DSC_SqlRSSetup.psm1" -Force; $p=@{InstanceName="SSRS";IAcceptLicenseTerms="Yes";SourcePath="C:\Temp\SQLServerReportingServices.exe";Action="Install";Edition="Development";SuppressRestart=$true}; if(-not (Test-TargetResource @p)){Set-TargetResource @p}'
        Register-ScheduledTask -TaskName Install-SSRS -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Temp\inst.ps1') -User SYSTEM -RunLevel Highest -Force|Out-Null
        Start-ScheduledTask Install-SSRS; $d=(Get-Date).AddMinutes(7); do{Start-Sleep 20}until((Get-Service SQLServerReportingServices -EA SilentlyContinue) -or (Get-Date) -gt $d)
    }
    "SSRS: " + (Get-Service SQLServerReportingServices).Status + " as " + (Get-CimInstance Win32_Service -Filter "Name='SQLServerReportingServices'").StartName
} -ArgumentList $SsrsUrl

# ── 4. SSRS catalog (remote A-SQLSCCM) + gpupdate + CA cert + HTTPS bind ────────
Write-LabLog 'Configuring SSRS catalog + CA cert + HTTPS on A-SCCM...' -Step 'Reporting'
Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
    param($SqlFqdn,$DcFqdn,$CaCommonName,$PrimaryFqdn,$PrimaryShort)
    $ErrorActionPreference='Stop'
    # catalog DB on remote SQL + http (DSC_SqlRS, in-session as SADAB\Administrator sysadmin)
    Import-Module 'C:\Program Files\WindowsPowerShell\Modules\SqlServerDsc\15.2.0\DSCResources\DSC_SqlRS\DSC_SqlRS.psm1' -Force
    $p=@{ InstanceName='SSRS'; DatabaseServerName=($SqlFqdn -split '\.')[0]; DatabaseInstanceName='MSSQLSERVER'; ReportServerReservedUrl=@('http://+:80'); ReportsReservedUrl=@('http://+:80'); UseSsl=$false; SuppressRestart=$false }
    if(-not (Test-TargetResource @p)){ Set-TargetResource @p }
    # trust the root CA + enroll a WebServer cert in MACHINE context (no -Credential)
    gpupdate /target:computer /force | Out-Null; Start-Sleep 5
    if(-not (Get-Module -ListAvailable CertificateDsc)){ Install-Module CertificateDsc -Scope AllUsers -Force -AllowClobber }
    Import-Module (Join-Path (Get-Module -ListAvailable CertificateDsc|Sort-Object Version -Descending|Select-Object -First 1).ModuleBase 'DSCResources\DSC_CertReq\DSC_CertReq.psm1') -Force
    $cp=@{ Subject="CN=$PrimaryFqdn"; CAServerFQDN=$DcFqdn; CARootName=$CaCommonName; CertificateTemplate='WebServer'; SubjectAltName="dns=$PrimaryFqdn&dns=$PrimaryShort"; KeyLength='2048'; KeyUsage='0xa0'; OID='1.3.6.1.5.5.7.3.1'; FriendlyName='SSRS CA HTTPS'; AutoRenew=$true; UseMachineContext=$true }
    if(-not (Test-TargetResource @cp)){ Set-TargetResource @cp }
    $ca=(Get-ChildItem Cert:\LocalMachine\My|Where-Object{$_.Subject -eq "CN=$PrimaryFqdn" -and $_.Issuer -match $CaCommonName}|Sort-Object NotBefore -Descending|Select-Object -First 1).Thumbprint.ToLower()
    # HTTPS via RS WMI (clear any orphaned http.sys binding first)
    & netsh http delete sslcert ipport=0.0.0.0:443 2>&1 | Out-Null
    $base='root\Microsoft\SqlServer\ReportServer\RS_SSRS'; $ver=((Get-WmiObject -Namespace $base -Class __NAMESPACE).Name|Select-Object -First 1)
    $rs=Get-WmiObject -Namespace "$base\$ver\Admin" -Class MSReportServer_ConfigurationSetting; $lcid=1033
    foreach($app in 'ReportServerWebService','ReportServerWebApp'){ $rs.ReserveURL($app,'https://+:443',$lcid)|Out-Null; $rs.CreateSSLCertificateBinding($app,$ca,'0.0.0.0',443,$lcid)|Out-Null }
    $rs.SetSecureConnectionLevel(1)|Out-Null
    # HTTPS-only: remove the default http://+:80 URL reservations that SSRS Setup
    # created. Otherwise the SCOM SSRS MP probes them first, gets back the
    # "rsSecureConnectionRequired" error, and raises a noisy
    # "Microsoft.SQLServer.ReportingServices.Windows.Monitor.Instance.WebServiceAccessible" alert.
    $existing = $rs.ListReservedUrls()
    foreach($app in 'ReportServerWebService','ReportServerWebApp'){
        for($i=0;$i -lt $existing.Application.Count;$i++){
            if($existing.Application[$i] -eq $app -and $existing.UrlString[$i] -like 'http://*:80'){
                $rs.RemoveURL($app, $existing.UrlString[$i], $lcid) | Out-Null
            }
        }
    }
    Restart-Service SQLServerReportingServices -Force; Start-Sleep 20
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    try{ "HTTPS test: " + (Invoke-WebRequest -UseBasicParsing "https://$PrimaryShort/ReportServer" -UseDefaultCredentials -TimeoutSec 15).StatusCode }catch{ "HTTPS: $($_.Exception.Message)" }
} -ArgumentList $SqlFqdn,$DcFqdn,$CaCommonName,$PrimaryFqdn,$PrimaryShort

# ── 5. CM account + Reporting Services Point role on the PRIMARY (A-SCCM) ───────
Write-LabLog 'Registering CM account + adding RSP role on A-SCCM (DSC)...' -Step 'Reporting'
$results = Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
    param($SiteCode,$PrimaryFqdn,$SqlFqdn,$ReportsUser,$dpw)
    $ErrorActionPreference='Stop'; $CMPSSuppressFastNotUsedCheck=$true
    $mod=Get-Module -ListAvailable ConfigMgrCBDsc|Sort-Object Version -Descending|Select-Object -First 1; $dscRoot=Join-Path $mod.ModuleBase 'DSCResources'
    Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1')
    if(-not (Get-PSDrive -Name $SiteCode -EA SilentlyContinue)){ New-PSDrive -Name $SiteCode -PSProvider CMSite -Root 'A-SCCM.sadab.pri'|Out-Null }
    function Invoke-CMResource{param([string]$Resource,[hashtable]$Property)
        Get-Module DSC_CM*|Remove-Module -Force -EA SilentlyContinue; Import-Module (Join-Path $dscRoot "DSC_$Resource\DSC_$Resource.psm1") -Force
        $b=[bool](Test-TargetResource @Property); if(-not $b){Set-TargetResource @Property|Out-Null;$a=[bool](Test-TargetResource @Property)}else{$a=$true}
        [pscustomobject]@{Resource=$Resource;WasCompliant=$b;Action=if($b){'none'}else{'Set'};NowCompliant=$a} }
    $out=@()
    $rcred=New-Object System.Management.Automation.PSCredential($ReportsUser,(ConvertTo-SecureString $dpw -AsPlainText -Force))
    $out+=Invoke-CMResource 'CMAccounts' @{ SiteCode=$SiteCode; Account=$ReportsUser; AccountPassword=$rcred; Ensure='Present' }
    $out+=Invoke-CMResource 'CMReportingServicePoint' @{ SiteCode=$SiteCode; SiteServerName=$PrimaryFqdn; DatabaseServerName=$SqlFqdn; DatabaseName="CM_$SiteCode"; ReportServerInstance='SSRS'; Username=$ReportsUser; Ensure='Present' }
    $out
} -ArgumentList $SiteCode,$PrimaryFqdn,$SqlFqdn,$ReportsUser,$DomainAdminPassword

$results | Format-Table Resource, WasCompliant, Action, NowCompliant -AutoSize
Write-LabLog 'Reporting: RSP on the Primary (A-SCCM) over HTTPS with a CA-issued cert, SCCM_Reports account, SSRS as virtual account. Reports deploy over the next several minutes.' -Level SUCCESS -Step 'Reporting'
