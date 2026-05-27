<#
.SYNOPSIS
    DSC-backed Software Update Point on A-MPDP over HTTPS (port 8531), syncing from
    Microsoft Update with Security + Critical classifications only. Idempotent,
    Test -> Set. Run from the Hyper-V host. PS 5.1 only. Use Write-LabLog.

.DESCRIPTION
    Per the project convention (see CLAUDE.md), SCCM config is DSC-backed via
    ConfigMgrCBDsc, Test -> Set in-process on the site server. This adds the SUP that
    Phase 1 deferred:

      WSUS (host-OS prereq, NOT DSC):
        * UpdateServices + WID + RSAT on A-MPDP, postinstall CONTENT_DIR=C:\WSUS.
        * WSUS over SSL on 8531: a WebServer cert from the domain CA (SADAB-Root-CA,
          stood up by Configure-SCCMReporting.ps1) bound to the "WSUS Administration"
          IIS site, Require-SSL + Ignore-client-certs on the five web-service vdirs
          (ApiRemoting30, ClientWebService, DSSAuthWebService, ServerSyncWebService,
          SimpleAuthWebService - NOT the site root, content stays HTTP), then
          `WsusUtil.exe configuressl A-MPDP.sadab.pri`.

      SUP role + sync (DSC, ConfigMgrCBDsc 4.0.0):
        * CMSoftwareUpdatePoint          - role on A-MPDP, Intranet, WsusSsl=$true,
                                            WsusIisPort 8530 / WsusIisSslPort 8531.
        * CMSoftwareUpdatePointComponent - SynchronizeFromMicrosoftUpdate, classifications
                                            Critical + Security ONLY, daily sync schedule;
                                            products added after the first (category) sync.

    STAGES (re-runnable; default 'All' runs WSUS->SSL->Role->SyncSource, then triggers an
    initial sync. Run -Stage Products after that sync completes; it discovers the real
    product category names and triggers the full sync):
        WSUS        install + postinstall WSUS on A-MPDP
        SSL         cert + IIS bindings + configuressl on A-MPDP (8531)
        Role        DSC CMSoftwareUpdatePoint (SSL)
        SyncSource  DSC CMSoftwareUpdatePointComponent (source/classifications/schedule) + sync
        Products    discover product categories, DSC component products + full sync
        Status      print SUP + sync status (no changes)

    WHY classifications are Critical + Security only: the goal pins them. Note this means
    Microsoft Defender *definition* updates (classification "Definition Updates") are NOT
    synced even though the Defender AV product is selected - only Defender updates that
    ship as Security/Critical will flow. Selecting the product is harmless and future-proof.

    GOTCHAS (encoded below):
      * Products are unknown until the first sync downloads categories - that is why
        product selection is a separate stage run AFTER SyncSource's sync completes.
      * Machine-context cert enrollment (UseMachineContext=$true, no -Credential) needs
        'Domain Computers' to have Enroll on the WebServer template - already granted by
        Configure-SCCMReporting.ps1. gpupdate first so the root CA is trusted.
      * Don't set Require-SSL on the WSUS Administration site root; content/selfupdate
        must stay HTTP. Only the five web-service vdirs require SSL.
      * Invoke-DscResource is unusable on the site server; we import each DSC_*.psm1 and
        call Test/Set in-process under SADAB\Administrator with the PR1: drive pre-created.

.NOTES
    Author  : SADAB Lab
    Version : 1.0 (DSC-backed SUP over SSL).
    Requires: SCCM PR1 + MP/DP on A-MPDP; SADAB-Root-CA on A-DC; ConfigMgrCBDsc on A-SCCM.
#>
[CmdletBinding()]
param(
    [ValidateSet('All','WSUS','SSL','Role','SyncSource','Products','Status')]
    [string]$Stage = 'All',

    [string]$SiteCode      = 'PR1',
    [string]$SiteServer    = 'A-SCCM.sadab.pri',
    [string]$SupServer     = 'A-MPDP.sadab.pri',
    [string]$SupShort      = 'A-MPDP',
    [string]$DcFqdn        = 'A-DC.sadab.pri',
    [string]$CaCommonName  = 'SADAB-Root-CA',
    [int]   $WsusPort      = 8530,
    [int]   $WsusSslPort   = 8531,
    [string[]]$Classifications = @('Critical Updates','Security Updates'),
    # EXACT WSUS product titles (verified against the synced catalog). Server 2025 ships its
    # OS updates under "Microsoft Server Operating System-24H2".
    [string[]]$ProductMatch    = @('Microsoft Server Operating System-24H2','Windows 11','Microsoft Defender Antivirus'),
    [bool]  $EnsureModule  = $true,

    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force
$SccmIP = '10.10.0.3'
$SupIP  = '10.10.0.5'

if (-not $DomainCred) {
    if (-not $DomainAdminPassword) { throw "Provide -DomainCred or -DomainAdminPassword." }
    $DomainCred = New-Object System.Management.Automation.PSCredential('SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

# ─────────────────────────────────────────────────────────────────────────────
function Invoke-WSUSInstall {
    Write-LabLog "Installing WSUS (WID) on $SupServer..." -Step 'SUP/WSUS'
    Invoke-LabRemote -IPAddress $SupIP -Credential $DomainCred -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $r = Install-WindowsFeature UpdateServices, UpdateServices-WidDB, UpdateServices-Services -IncludeManagementTools
        New-Item -ItemType Directory -Force 'C:\WSUS' | Out-Null
        $tool = 'C:\Program Files\Update Services\Tools\WsusUtil.exe'
        # True "configured" check: postinstall creates the WSUS Administration site, the
        # WsusService, and the content dir. The Setup\ContentDir reg value alone is a FALSE
        # positive (it carries a default before postinstall runs). Re-running postinstall is
        # safe (idempotent) but slow, so gate on the real artifacts.
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $configured = (Get-Service WsusService -EA SilentlyContinue) -and
                      (Get-Website -Name 'WSUS Administration' -EA SilentlyContinue) -and
                      (Test-Path 'C:\WSUS\WsusContent')
        if (-not $configured) {
            & $tool postinstall CONTENT_DIR=C:\WSUS 2>&1 | Out-String | Write-Output
        } else { "WSUS already configured (Admin site + content present)." }
        "WSUS feature Success=$($r.Success) RestartNeeded=$($r.RestartNeeded); svc=$((Get-Service WsusService -EA SilentlyContinue).Status)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
function Invoke-WSUSSsl {
    Write-LabLog "Configuring WSUS SSL on $SupServer ($WsusSslPort)..." -Step 'SUP/SSL'
    Invoke-LabRemote -IPAddress $SupIP -Credential $DomainCred -ScriptBlock {
        param($SupFqdn,$SupShort,$DcFqdn,$CaCommonName,$SslPort)
        $ErrorActionPreference = 'Stop'

        # 1. Trust the root CA + enroll a WebServer cert in MACHINE context (computer acct).
        gpupdate /target:computer /force | Out-Null; Start-Sleep 5
        if (-not (Get-Module -ListAvailable CertificateDsc)) {
            # Bootstrap the NuGet provider EXPLICITLY first - letting Install-Module auto-
            # bootstrap it prompts (ShouldContinue) and dies in NonInteractive remoting.
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module CertificateDsc -Scope AllUsers -Force -AllowClobber -Confirm:$false
        }
        $cdsc = (Get-Module -ListAvailable CertificateDsc | Sort-Object Version -Descending | Select-Object -First 1).ModuleBase
        Import-Module (Join-Path $cdsc 'DSCResources\DSC_CertReq\DSC_CertReq.psm1') -Force
        $cp = @{ Subject="CN=$SupFqdn"; CAServerFQDN=$DcFqdn; CARootName=$CaCommonName; CertificateTemplate='WebServer'
                 SubjectAltName="dns=$SupFqdn&dns=$SupShort"; KeyLength='2048'; KeyUsage='0xa0'; OID='1.3.6.1.5.5.7.3.1'
                 FriendlyName='WSUS CA HTTPS'; AutoRenew=$true; UseMachineContext=$true }
        if (-not (Test-TargetResource @cp)) { Set-TargetResource @cp }
        $thumb = (Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$SupFqdn" -and $_.Issuer -match $CaCommonName } |
                  Sort-Object NotBefore -Descending | Select-Object -First 1).Thumbprint
        if (-not $thumb) { throw "WebServer cert for $SupFqdn not found after enrollment." }

        # 2. Bind cert to the WSUS Administration site https binding (keep HTTP for content).
        Import-Module WebAdministration -Force
        $site = 'WSUS Administration'
        $b = Get-WebBinding -Name $site -Protocol https -ErrorAction SilentlyContinue
        if (-not $b) { New-WebBinding -Name $site -Protocol https -Port $SslPort -IPAddress '*' | Out-Null; $b = Get-WebBinding -Name $site -Protocol https }
        $b.AddSslCertificate($thumb, 'My')

        # 3. Require SSL (+ ignore client certs) on the five WSUS web-service vdirs only.
        # The system.webServer/security/access section is locked at the parent by default,
        # so Set-WebConfigurationProperty on the vdir web.config fails ("cannot be used at
        # this path"). appcmd ... /commit:apphost writes to applicationHost.config at the
        # location path, which is permitted despite the lock. sslFlags=Ssl = Require SSL;
        # omitting SslNegotiateCert/SslRequireCert leaves client certs = Ignore.
        $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
        foreach ($v in 'ApiRemoting30','ClientWebService','DSSAuthWebService','ServerSyncWebService','SimpleAuthWebService') {
            & $appcmd set config "$site/$v" /section:access /sslFlags:Ssl /commit:apphost | Out-Null
        }

        # 4. Tell the WSUS application to use SSL.
        $out = & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' configuressl $SupFqdn 2>&1 | Out-String
        Restart-WebItem "IIS:\Sites\$site" -ErrorAction SilentlyContinue
        "cert=$thumb`nconfiguressl: $out"
    } -ArgumentList $SupServer,$SupShort,$DcFqdn,$CaCommonName,$WsusSslPort
}

# ─────────────────────────────────────────────────────────────────────────────
# Shared DSC Test->Set helper text, run in-process on the site server (A-SCCM).
$DscHelper = {
    function Invoke-CMResource {
        param([string]$Resource, [hashtable]$Property)
        $psm1 = Join-Path $script:dscRoot "DSC_$Resource\DSC_$Resource.psm1"
        Get-Module DSC_CM* | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module $psm1 -Force
        $before = [bool](Test-TargetResource @Property)
        if (-not $before) { Set-TargetResource @Property | Out-Null; $after = [bool](Test-TargetResource @Property) } else { $after = $true }
        [pscustomobject]@{ Resource=$Resource; WasCompliant=$before; Action=$(if($before){'none'}else{'Set'}); NowCompliant=$after }
    }
}

function Connect-SiteServerScript {
    # Prologue text dot-sourced INSIDE the remote scriptblock (shares its scope), so it
    # references the remote $SiteCode/$SiteServer/$EnsureModule params directly - NOT
    # $using:, which is invalid in a dynamically created+dot-sourced scriptblock.
    @'
    $ErrorActionPreference = 'Stop'; $CMPSSuppressFastNotUsedCheck = $true
    $mod = Get-Module -ListAvailable ConfigMgrCBDsc | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod -and $EnsureModule) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -EA SilentlyContinue
        Install-Module ConfigMgrCBDsc -Scope AllUsers -Force -AllowClobber
        $mod = Get-Module -ListAvailable ConfigMgrCBDsc | Sort-Object Version -Descending | Select-Object -First 1
    }
    $script:dscRoot = Join-Path $mod.ModuleBase 'DSCResources'
    $uiPath = $env:SMS_ADMIN_UI_PATH
    if (-not $uiPath) { $uiPath = 'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\i386' }
    Import-Module (Join-Path (Split-Path $uiPath) 'ConfigurationManager.psd1')
    if (-not (Get-PSDrive -Name $SiteCode -EA SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null
    }
'@
}

# ─────────────────────────────────────────────────────────────────────────────
function Invoke-SupRole {
    # PREREQ: WCM runs on the SITE server and remotely administers WSUS via the
    # Microsoft.UpdateServices.Administration assembly. That assembly ships with the WSUS
    # Administration Console (UpdateServices-RSAT), which therefore MUST be installed on the
    # site server A-SCCM - even though WSUS itself lives on A-MPDP. Without it WCM logs
    # "Did not find supported version of assembly ... 0x80131701 / Supported WSUS version
    # not found" and the SUP stays WSUS_CONFIG_FAILED. Then bounce SMS_EXECUTIVE so WCM
    # re-reads the now-present console instead of waiting out its retry timer.
    Write-LabLog "Ensuring WSUS Administration Console (RSAT) on the site server A-SCCM..." -Step 'SUP/Role'
    Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
        $f = Get-WindowsFeature UpdateServices-RSAT, UpdateServices-API, UpdateServices-UI
        if ($f | Where-Object { -not $_.Installed }) {
            $r = Install-WindowsFeature UpdateServices-RSAT
            "WSUS console installed Success=$($r.Success) RestartNeeded=$($r.RestartNeeded)"
        } else { "WSUS console already present." }
    }

    Write-LabLog "Installing SUP role on $SupServer (DSC, SSL/$WsusSslPort)..." -Step 'SUP/Role'
    $results = Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
        param($SiteCode,$SiteServer,$SupServer,$WsusPort,$WsusSslPort,$EnsureModule,$DscHelperText,$PrologueText)
        $ErrorActionPreference = 'Stop'; $CMPSSuppressFastNotUsedCheck = $true
        . ([scriptblock]::Create($PrologueText))
        . ([scriptblock]::Create($DscHelperText))
        Invoke-CMResource -Resource 'CMSoftwareUpdatePoint' -Property @{
            SiteCode=$SiteCode; SiteServerName=$SupServer; ClientConnectionType='Intranet'
            WsusIisPort=[uint32]$WsusPort; WsusIisSslPort=[uint32]$WsusSslPort; WsusSsl=$true
            AnonymousWsusAccess=$true; Ensure='Present' }
    } -ArgumentList $SiteCode,$SiteServer,$SupServer,$WsusPort,$WsusSslPort,$EnsureModule,$DscHelper.ToString(),(Connect-SiteServerScript)
    $results | Format-Table Resource, WasCompliant, Action, NowCompliant -AutoSize

    # Nudge WCM to reconfigure WSUS now (it would otherwise wait out a 23-60 min retry).
    Write-LabLog "Bouncing SMS_EXECUTIVE on A-SCCM so WCM reconfigures WSUS immediately..." -Step 'SUP/Role'
    Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
        Restart-Service SMS_EXECUTIVE -Force
        "SMS_EXECUTIVE: " + (Get-Service SMS_EXECUTIVE).Status
    }
    Write-LabLog "SUP role requested. WCM reconfigures WSUS over SSL (watch WCM.log / SUPSetup.log)." -Level SUCCESS -Step 'SUP/Role'
}

# ─────────────────────────────────────────────────────────────────────────────
function Invoke-SyncSource {
    Write-LabLog "Setting SUP sync source (Microsoft) + classifications (Security+Critical) + schedule..." -Step 'SUP/Sync'
    $results = Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
        param($SiteCode,$SiteServer,$Classifications,$EnsureModule,$DscHelperText,$PrologueText)
        $ErrorActionPreference = 'Stop'; $CMPSSuppressFastNotUsedCheck = $true
        . ([scriptblock]::Create($PrologueText))
        . ([scriptblock]::Create($DscHelperText))
        # DSC for sync SOURCE + classifications (proven on this build). Use *ToInclude on a
        # fresh SUP so the selection is exactly Critical + Security ("only").
        $r = Invoke-CMResource -Resource 'CMSoftwareUpdatePointComponent' -Property @{
            SiteCode=$SiteCode; SynchronizeAction='SynchronizeFromMicrosoftUpdate'
            UpdateClassificationsToInclude=$Classifications
            EnableSyncFailureAlert=$true; ContentFileOption='FullFilesOnly' }

        # DSC EXCEPTION (build mismatch): DSC_CMSoftwareUpdatePointComponent 4.0.0 enables
        # scheduled sync by calling Set-CMSoftwareUpdatePointComponent -EnableSynchronization,
        # but our build (5.00.9141) dropped that param in favour of -Schedule. So set the
        # daily sync schedule via the cmdlet directly (providing -Schedule enables it).
        # Raw CM cmdlets require the session to be ON the site drive (DSC is cwd-agnostic).
        Set-Location "$($SiteCode):"
        $sched = 'cmdlet n/a'
        try {
            Set-CMSoftwareUpdatePointComponent -SiteCode $SiteCode -Schedule (New-CMSchedule -RecurInterval Days -RecurCount 1) -ErrorAction Stop
            $sched = 'daily schedule set'
        } catch { $sched = "schedule WARN: $($_.Exception.Message)" }

        # Trigger the initial sync so SCCM downloads the category list (products become known).
        try { Sync-CMSoftwareUpdate -FullSync $true -ErrorAction Stop; $sync='triggered' } catch { $sync = "sync WARN: $($_.Exception.Message)" }
        [pscustomobject]@{ Dsc=$r; Schedule=$sched; Sync=$sync }
    } -ArgumentList $SiteCode,$SiteServer,$Classifications,$EnsureModule,$DscHelper.ToString(),(Connect-SiteServerScript)
    $results.Dsc | Format-Table Resource, WasCompliant, Action, NowCompliant -AutoSize
    "Schedule: $($results.Schedule)"; "Sync: $($results.Sync)"
    Write-LabLog "Sync source set + initial sync triggered. Poll with -Stage Status until LastSuccessfulSyncTime advances, then run -Stage Products." -Level SUCCESS -Step 'SUP/Sync'
}

# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Products {
    Write-LabLog "Discovering product categories + selecting products, then full sync..." -Step 'SUP/Products'
    $results = Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
        param($SiteCode,$SiteServer,$ProductMatch,$EnsureModule,$DscHelperText,$PrologueText)
        $ErrorActionPreference = 'Stop'; $CMPSSuppressFastNotUsedCheck = $true
        . ([scriptblock]::Create($PrologueText))
        . ([scriptblock]::Create($DscHelperText))
        Set-Location "$($SiteCode):"   # raw CM cmdlets require the site drive as cwd

        # Map requested products to synced category names. Match EXACTLY first (a loose
        # substring match wrongly grabs sub-products like "Azure File Sync ... for Windows
        # Server 2025" or "Windows 11 Dynamic Update"). Fall back to "exactly one startswith"
        # only when there is no ambiguity.
        $cats = (Get-CMSoftwareUpdateCategory -Fast | Where-Object { $_.CategoryTypeName -eq 'Product' }).LocalizedCategoryInstanceName
        if (-not $cats) { throw "No product categories yet - the category sync has not populated products. Re-run after -Stage Status shows a successful sync." }
        $selected = @(); $missed = @()
        foreach ($m in $ProductMatch) {
            $exact = $cats | Where-Object { $_ -eq $m }
            if ($exact) { $selected += $exact; continue }
            $starts = @($cats | Where-Object { $_ -like "$m*" })
            if ($starts.Count -eq 1) { $selected += $starts[0] } else { $missed += $m }
        }
        $selected = $selected | Sort-Object -Unique
        if ($missed) { Write-Warning "No unambiguous product category for: $($missed -join ', ')" }
        if (-not $selected) { throw "None of [$($ProductMatch -join ', ')] matched a synced product category." }

        # Exact set (Products, not ProductsToInclude) so any wrongly-subscribed products are
        # also removed - the selection ends up EXACTLY the requested base products.
        $r = Invoke-CMResource -Resource 'CMSoftwareUpdatePointComponent' -Property @{
            SiteCode=$SiteCode; Products=$selected }
        Set-Location "$($SiteCode):"   # DSC resets cwd; raw cmdlet needs the site drive again
        try { Sync-CMSoftwareUpdate -FullSync $true -ErrorAction Stop; $sync='triggered' } catch { $sync = "sync WARN: $($_.Exception.Message)" }
        [pscustomobject]@{ MatchedProducts = ($selected -join '; '); DscResult = $r; Sync = $sync }
    } -ArgumentList $SiteCode,$SiteServer,$ProductMatch,$EnsureModule,$DscHelper.ToString(),(Connect-SiteServerScript)
    "Matched products: $($results.MatchedProducts)"
    $results.DscResult | Format-Table Resource, WasCompliant, Action, NowCompliant -AutoSize
    "Sync: $($results.Sync)"
    Write-LabLog "Products selected + full sync triggered. Poll -Stage Status; then run Deploy-SCCMUpdatesADR.ps1." -Level SUCCESS -Step 'SUP/Products'
}

# ─────────────────────────────────────────────────────────────────────────────
function Show-Status {
    Invoke-LabRemote -IPAddress $SccmIP -Credential $DomainCred -ScriptBlock {
        param($SiteCode,$SiteServer)
        $ErrorActionPreference = 'Stop'; $CMPSSuppressFastNotUsedCheck = $true
        Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1')
        if (-not (Get-PSDrive -Name $SiteCode -EA SilentlyContinue)) { New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null }
        Set-Location "$($SiteCode):"
        "=== SUP role ==="
        Get-CMSoftwareUpdatePoint -SiteSystemServerName 'A-MPDP.sadab.pri' -SiteCode $SiteCode -EA SilentlyContinue |
            Select-Object NetworkOSPath, @{n='SSL';e={$_.SslWsusServer}}, RoleName | Format-List
        "=== Sync status ==="
        Get-CMSoftwareUpdateSyncStatus | Select-Object WSUSServerName, LastSuccessfulSyncTime, LastSyncState, LastSyncStateID, LastSyncErrorCode | Format-List
        "=== Counts ==="
        "Products selected : " + (@(Get-CMSoftwareUpdateCategory -Fast | Where-Object { $_.CategoryTypeName -eq 'Product' -and $_.IsSubscribed }).Count)
        "Update CIs total  : " + (@(Get-CMSoftwareUpdate -Fast -EA SilentlyContinue).Count)
    } -ArgumentList $SiteCode,$SiteServer
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
switch ($Stage) {
    'WSUS'       { Invoke-WSUSInstall }
    'SSL'        { Invoke-WSUSSsl }
    'Role'       { Invoke-SupRole }
    'SyncSource' { Invoke-SyncSource }
    'Products'   { Invoke-Products }
    'Status'     { Show-Status }
    'All'        { Invoke-WSUSInstall; Invoke-WSUSSsl; Invoke-SupRole; Invoke-SyncSource;
                   Write-LabLog "WSUS+SUP up and initial sync triggered. When -Stage Status shows a successful sync, run -Stage Products." -Level SUCCESS -Step 'SUP' }
}
