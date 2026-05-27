<#
.SYNOPSIS
    DSC-backed device collection 'All Servers' (ConfigMgrCBDsc CMCollections, Test -> Set).
    Idempotent. Run AFTER step 8.

.DESCRIPTION
    Creates a device collection 'All Servers' limited to 'All Systems', refreshed daily,
    with a query rule that matches server operating systems. This is the target for the
    Required app deployments (7-Zip, Notepad++).

    IDEMPOTENCY GOTCHA (2026-05-24): SCCM normalizes/expands a collection query when it
    stores it - it uppercases SMS_R_SYSTEM and adds the standard columns ResourceType,
    SMSUniqueIdentifier, ResourceDomainORWorkgroup. If you feed CMCollections the short
    query you typed, Test never matches (it compares strings) and the resource is never
    "compliant". So the QueryExpression below is the EXACT normalized form SCCM stores -
    do not "tidy" it or Test will flip to non-compliant on every run.

.NOTES
    Author  : SADAB Lab
    Version : 1.0 (DSC-backed). Run from the Hyper-V host. PS 5.1 only.
#>
[CmdletBinding()]
param(
    [string]$SiteCode       = 'PR1',
    [string]$SiteServer     = 'A-SCCM.sadab.pri',
    [string]$CollectionName = 'All Servers',
    [bool]  $EnsureModule   = $true,

    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force
$SccmAIP = '10.10.0.3'
if (-not $DomainCred) {
    if (-not $DomainAdminPassword) { throw "Provide -DomainCred or -DomainAdminPassword." }
    $DomainCred = New-Object System.Management.Automation.PSCredential('SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

Write-LabLog "Configuring device collection '$CollectionName' (DSC)..." -Step 'Collections'
$results = Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    param($SiteCode,$SiteServer,$CollectionName,$EnsureModule)
    $ErrorActionPreference = 'Stop'
    $mod = Get-Module -ListAvailable ConfigMgrCBDsc | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod -and $EnsureModule) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module ConfigMgrCBDsc -Scope AllUsers -Force -AllowClobber
        $mod = Get-Module -ListAvailable ConfigMgrCBDsc | Sort-Object Version -Descending | Select-Object -First 1
    }
    $dscRoot = Join-Path $mod.ModuleBase 'DSCResources'
    $uiPath = $env:SMS_ADMIN_UI_PATH; if (-not $uiPath) { $uiPath = 'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\i386' }
    Import-Module (Join-Path (Split-Path $uiPath) 'ConfigurationManager.psd1') -ErrorAction Stop
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) { New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null }

    # EXACT normalized query string SCCM stores (see header gotcha).
    $query = 'select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client from SMS_R_System where SMS_R_System.OperatingSystemNameandVersion like "%Server%"'
    $q = New-CimInstance -ClassName DSC_CMCollectionQueryRules -Namespace 'root/microsoft/windows/desiredstateconfiguration' -ClientOnly -Property @{ RuleName='All Servers by OS'; QueryExpression=$query }

    Import-Module (Join-Path $dscRoot 'DSC_CMCollections\DSC_CMCollections.psm1') -Force
    $p = @{ SiteCode=$SiteCode; CollectionName=$CollectionName; CollectionType='Device'; LimitingCollectionName='All Systems'
            Comment='All server-OS devices (SADAB lab)'; RefreshType='Periodic'; ScheduleType='Days'; RecurInterval=1
            QueryRules=@($q); Ensure='Present' }
    $before = [bool](Test-TargetResource @p)
    if (-not $before) { Set-TargetResource @p | Out-Null; $after = [bool](Test-TargetResource @p) } else { $after = $true }
    [pscustomobject]@{ Resource='CMCollections'; Collection=$CollectionName; WasCompliant=$before; Action=if($before){'none'}else{'Set'}; NowCompliant=$after }
} -ArgumentList $SiteCode,$SiteServer,$CollectionName,$EnsureModule

$results | Format-Table -AutoSize
Write-LabLog "Collection '$CollectionName' configured (server-OS query)." -Level SUCCESS -Step 'Collections'
