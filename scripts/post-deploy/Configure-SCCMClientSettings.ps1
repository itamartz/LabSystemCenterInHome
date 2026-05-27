<#
.SYNOPSIS
    DSC-backed custom client settings "Servers" (ConfigMgrCBDsc, Test -> Set), deployed
    to the "All Servers" collection. Hardware Inventory every 1 hour, Client Policy
    polling every 5 minutes. Idempotent. Run AFTER the All Servers collection exists.

.DESCRIPTION
    Per the project convention, SCCM config is DSC-backed via ConfigMgrCBDsc:

      * CMClientSettings            - creates the device client-settings object "Servers".
      * CMClientSettingsHardware    - enables Hardware Inventory, schedule = Hours/N.
      * CMClientSettingsClientPolicy - sets the client policy polling interval (minutes).

    DSC EXCEPTION: ConfigMgrCBDsc has NO resource to DEPLOY a client-settings object to a
    collection, so the "attach to All Servers" step is cmdlet-based
    (New-CMClientSettingDeployment), made idempotent with a Get-CMClientSettingDeployment
    check. This is the same kind of documented exception as application deployment.

    NOTE: custom client settings only OVERRIDE the categories you explicitly enable here
    (Hardware Inventory + Client Policy); everything else inherits from Default Client
    Settings by the priority order.

.PARAMETER SettingName            Client settings object name. Default 'Servers'.
.PARAMETER CollectionName         Collection to deploy to. Default 'All Servers'.
.PARAMETER HardwareIntervalHours  Hardware Inventory interval in hours. Default 1.
.PARAMETER PolicyPollingMins      Client policy polling interval in minutes. Default 5.

.NOTES
    Author  : SADAB Lab
    Version : 1.0 (DSC-backed; deployment is the documented cmdlet exception).
    Run from the Hyper-V host. PS 5.1 only. Use Write-LabLog.
#>
[CmdletBinding()]
param(
    [string]$SiteCode             = 'PR1',
    [string]$SiteServer           = 'A-SCCM.sadab.pri',
    [string]$SettingName          = 'Servers',
    [string]$CollectionName       = 'All Servers',
    [int]   $HardwareIntervalHours = 1,
    [int]   $PolicyPollingMins    = 5,
    [bool]  $EnsureModule         = $true,

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

Write-LabLog "Configuring client settings '$SettingName' (DSC) + deploying to '$CollectionName'..." -Step 'ClientSettings'
$results = Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    param($SiteCode,$SiteServer,$SettingName,$CollectionName,$HwHours,$PolicyMins,$EnsureModule)
    $ErrorActionPreference = 'Stop'; $CMPSSuppressFastNotUsedCheck = $true

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

    function Invoke-CMResource {
        param([string]$Resource, [hashtable]$Property)
        $psm1 = Join-Path $dscRoot "DSC_$Resource\DSC_$Resource.psm1"
        Get-Module DSC_CM* | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module $psm1 -Force
        $before = [bool](Test-TargetResource @Property)
        if (-not $before) { Set-TargetResource @Property | Out-Null; $after = [bool](Test-TargetResource @Property) } else { $after = $true }
        [pscustomobject]@{ Resource=$Resource; WasCompliant=$before; Action=if($before){'none'}else{'Set'}; NowCompliant=$after }
    }

    $out = @()
    $out += Invoke-CMResource -Resource 'CMClientSettings' -Property @{
        SiteCode=$SiteCode; ClientSettingName=$SettingName; Type='Device'
        Description="Server client settings (SADAB lab): HW inventory ${HwHours}h, policy ${PolicyMins}min"; Ensure='Present' }
    $out += Invoke-CMResource -Resource 'CMClientSettingsHardware' -Property @{
        SiteCode=$SiteCode; ClientSettingName=$SettingName; Enable=$true; ScheduleType='Hours'; RecurInterval=$HwHours }
    $out += Invoke-CMResource -Resource 'CMClientSettingsClientPolicy' -Property @{
        SiteCode=$SiteCode; ClientSettingName=$SettingName; PolicyPollingMins=$PolicyMins }

    # Deploy to the collection (cmdlet - no DSC resource for client-settings deployment).
    Set-Location "$($SiteCode):"
    $dep = Get-CMClientSettingDeployment -Name $SettingName -CollectionName $CollectionName -ErrorAction SilentlyContinue
    if (-not $dep) {
        New-CMClientSettingDeployment -Name $SettingName -CollectionName $CollectionName | Out-Null
        $out += "deployment: created ($CollectionName)"
    } else { $out += "deployment: exists ($CollectionName)" }
    $out
} -ArgumentList $SiteCode,$SiteServer,$SettingName,$CollectionName,$HardwareIntervalHours,$PolicyPollingMins,$EnsureModule

$results | Format-Table -AutoSize
Write-LabLog "Client settings '$SettingName' configured (HW ${HardwareIntervalHours}h, policy ${PolicyPollingMins}min) + deployed to '$CollectionName'." -Level SUCCESS -Step 'ClientSettings'
