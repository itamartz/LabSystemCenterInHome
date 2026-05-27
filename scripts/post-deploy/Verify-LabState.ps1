<#
.SYNOPSIS
    Read-only verification that the live lab matches the documented state in CLAUDE.md.
    Run from the Hyper-V host. PS 5.1 only. Use Write-LabLog. Makes NO changes.

.DESCRIPTION
    Probes the running Site A VMs over Hyper-V direct (via Invoke-LabRemote) and asserts the
    facts CLAUDE.md claims, printing a per-check PASS/FAIL table plus a summary. Idempotent
    and side-effect free - safe to run any time to confirm the lab still reflects the docs.

    Stages (select with -Stage; default 'All'):
      Infra     - 5 Site A VMs are Datacenter, joined to sadab.pri, on their documented IP.
      Identity  - A-DC: domain, Enterprise Root CA 'SADAB-Root-CA', SCCM_Reports account.
      Sql       - A-SQLSCCM: SQL 2019 CU32 (15.0.4430.x), collation, CM_PR1 + ReportServer DBs.
      Site      - A-SCCM: site PR1, services, KB36949461 hotfix (bins at 5.00.9141.1030), SCP Online.
      Roles     - MP/DP/SUP + RSP/SCP role placement, 4 healthy clients, All Servers (4), 2 apps.
      Discovery - 4 AD discovery methods ACTIVE + Network off, IP-range boundaries + BGs, Servers settings.
      Updates   - SUP classifications/products, ADR, WSUS 8531 SSL, SSRS HTTPS cert, MP+site PKI, client cert.

    Why this exists: the project convention is "document everything in scripts; the repo must
    recreate AND validate the lab." This is the validation half - the executable form of the
    CLAUDE.md state tables.

.PARAMETER Stage
    Which group of checks to run. Default 'All'.
.PARAMETER SiteCode
    SCCM site code (drives the root\sms\site_<code> namespace). Default 'PR1'.

.EXAMPLE
    . .\scripts\lib\Connect-LabHost.ps1
    Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Verify-LabState.ps1' -DomainAdminPassword 'LabAdmin@2026!' }

.EXAMPLE
    Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Verify-LabState.ps1' -Stage Updates -DomainAdminPassword 'LabAdmin@2026!' }

.NOTES
    Author  : SADAB Lab
    Version : 1.0 (read-only). PS 5.1 only.
    Requires: Site A VMs running; SADAB\Administrator domain credential.
#>
[CmdletBinding()]
param(
    [ValidateSet('All','Infra','Identity','Sql','Site','Roles','Discovery','Updates')]
    [string]$Stage    = 'All',
    [string]$SiteCode = 'PR1',

    [string]$DomainAdminPassword = '',
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force
if (-not $DomainCred) {
    if (-not $DomainAdminPassword) { throw "Provide -DomainCred or -DomainAdminPassword." }
    $DomainCred = New-Object System.Management.Automation.PSCredential('SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

# Inline result-row factory, injected into each remote block so PASS/FAIL is decided where
# the data lives. Returns objects: Area / Check / Expected / Actual / Status.
$RowFn = @'
function Row([string]$Area,[string]$Check,[string]$Expected,$Actual,[bool]$Ok) {
    [PSCustomObject]@{ Area=$Area; Check=$Check; Expected=$Expected; Actual=("$Actual"); Status=$(if($Ok){'PASS'}else{'FAIL'}) }
}
'@

$NS  = "root\sms\site_$SiteCode"
$all = New-Object System.Collections.Generic.List[object]
function Add-Rows($rows) { foreach ($r in @($rows)) { if ($r) { $all.Add($r) } } }

$run = { param($name) $Stage -eq 'All' -or $Stage -eq $name }

# -- Infra: edition / domain / IP across the 5 Site A VMs --
if (& $run 'Infra') {
    Write-LabLog "Stage Infra: VM edition / domain / IP..." -Step 'Verify'
    $expect = @(
        @{ Name='A-DC'; IP='10.10.0.2' }, @{ Name='A-DFSR'; IP='10.10.0.7' },
        @{ Name='A-MPDP'; IP='10.10.0.5' }, @{ Name='A-SQLSCCM'; IP='10.10.0.4' },
        @{ Name='A-SCCM'; IP='10.10.0.3' }
    )
    foreach ($vm in $expect) {
        try {
            $rows = Invoke-LabRemote -IPAddress $vm.IP -Credential $DomainCred -ArgumentList @($RowFn,$vm.IP) -ScriptBlock {
                param($RowFn,$ExpectIP)
                Invoke-Expression $RowFn
                $os = Get-CimInstance Win32_OperatingSystem
                $cs = Get-CimInstance Win32_ComputerSystem
                $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '10.10.*' } | Select-Object -First 1).IPAddress
                Row $env:COMPUTERNAME 'Edition'      'Datacenter (SKU 8)' "$($os.OperatingSystemSKU)" ($os.OperatingSystemSKU -eq 8)
                Row $env:COMPUTERNAME 'Domain'        'sadab.pri'         $cs.Domain ($cs.Domain -eq 'sadab.pri' -and $cs.PartOfDomain)
                Row $env:COMPUTERNAME 'IP'            $ExpectIP           $ip ($ip -eq $ExpectIP)
            }
            Add-Rows $rows
        } catch { Add-Rows ([PSCustomObject]@{ Area=$vm.Name; Check='reachable'; Expected='Hyper-V direct OK'; Actual=$_.Exception.Message; Status='FAIL' }) }
    }
}

# -- Identity: DC, CA, reporting account --
if (& $run 'Identity') {
    Write-LabLog "Stage Identity: DC / CA / SCCM_Reports..." -Step 'Verify'
    Add-Rows (Invoke-LabRemote -IPAddress '10.10.0.2' -Credential $DomainCred -ArgumentList @($RowFn) -ScriptBlock {
        param($RowFn)
        Invoke-Expression $RowFn
        try { $d = Get-ADDomain -ErrorAction Stop } catch { $d = $null }
        Row 'A-DC' 'AD domain'   'sadab.pri'        $d.DNSRoot     ($d.DNSRoot -eq 'sadab.pri')
        $svc = Get-Service CertSvc -ErrorAction SilentlyContinue
        Row 'A-DC' 'CertSvc'     'Running'          $svc.Status    ($svc.Status -eq 'Running')
        $cn = (certutil -getreg CA\CommonName 2>$null | Select-String 'CommonName REG_SZ\s*=\s*(.+)$').Matches.Groups[1].Value
        Row 'A-DC' 'Enterprise CA' 'SADAB-Root-CA'  $cn            ($cn -match 'SADAB-Root-CA')
        $u = Get-ADUser -Filter "SamAccountName -eq 'SCCM_Reports'" -ErrorAction SilentlyContinue
        Row 'A-DC' 'SCCM_Reports user' 'present+enabled' $(if($u){"$($u.SamAccountName)/$($u.Enabled)"}else{'missing'}) ([bool]$u -and $u.Enabled)
    })
}

# -- Sql: version / collation / databases --
if (& $run 'Sql') {
    Write-LabLog "Stage Sql: SQL 2019 CU32 / collation / DBs..." -Step 'Verify'
    Add-Rows (Invoke-LabRemote -IPAddress '10.10.0.4' -Credential $DomainCred -ArgumentList @($RowFn) -ScriptBlock {
        param($RowFn)
        Invoke-Expression $RowFn
        $svc = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
        Row 'A-SQLSCCM' 'MSSQLSERVER' 'Running' $svc.Status ($svc.Status -eq 'Running')
        try {
            $r  = Invoke-Sqlcmd -ServerInstance 'localhost' -ErrorAction Stop -Query `
                  "SELECT SERVERPROPERTY('ProductVersion') V, SERVERPROPERTY('Collation') C"
            $db = (Invoke-Sqlcmd -ServerInstance 'localhost' -ErrorAction Stop -Query `
                  "SELECT name FROM sys.databases WHERE name IN ('CM_PR1','ReportServer','ReportServerTempDB')").name
        } catch { $r = $null; $db = @() }
        Row 'A-SQLSCCM' 'SQL version (CU32)' '15.0.4430.x' $r.V ("$($r.V)" -like '15.0.4430.*')
        Row 'A-SQLSCCM' 'Collation' 'SQL_Latin1_General_CP1_CI_AS' $r.C ($r.C -eq 'SQL_Latin1_General_CP1_CI_AS')
        Row 'A-SQLSCCM' 'CM_PR1 DB' 'present' $($db -join ',') ($db -contains 'CM_PR1')
        Row 'A-SQLSCCM' 'ReportServer DB' 'present' $($db -join ',') ($db -contains 'ReportServer')
    })
}

# -- Site: services / version / hotfix / SCP --
if (& $run 'Site') {
    Write-LabLog "Stage Site: services / version / KB36949461 / SCP..." -Step 'Verify'
    Add-Rows (Invoke-LabRemote -IPAddress '10.10.0.3' -Credential $DomainCred -ArgumentList @($RowFn,$NS) -ScriptBlock {
        param($RowFn,$NS)
        Invoke-Expression $RowFn
        foreach ($s in 'SMS_EXECUTIVE','SMS_SITE_COMPONENT_MANAGER') {
            $svc = Get-Service $s -ErrorAction SilentlyContinue
            Row 'A-SCCM' $s 'Running' $svc.Status ($svc.Status -eq 'Running')
        }
        try { $site = Get-CimInstance -Namespace $NS -ClassName SMS_Site -ErrorAction Stop } catch { $site = $null }
        Row 'A-SCCM' 'Site code'    'PR1'            $site.SiteCode ($site.SiteCode -eq 'PR1')
        Row 'A-SCCM' 'Site version' '5.00.9141.1000' $site.Version  ($site.Version -eq '5.00.9141.1000')
        $inst = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -ErrorAction SilentlyContinue).'Installation Directory'
        $ver  = (Get-Item (Join-Path $inst 'bin\x64\cmupdate.exe') -ErrorAction SilentlyContinue).VersionInfo.FileVersion
        Row 'A-SCCM' 'Hotfix KB36949461 (cmupdate.exe)' '5.00.9141.1030' $ver ($ver -eq '5.00.9141.1030')
        $scp = Get-CimInstance -Namespace $NS -ClassName SMS_SCI_SysResUse -Filter "RoleName='SMS Dmp Connector'" -ErrorAction SilentlyContinue
        $off = ($scp.Props | Where-Object { $_.PropertyName -eq 'OfflineMode' }).Value
        Row 'A-SCCM' 'Service Connection Point' 'present, Online (Offline=0)' $(if($scp){"present, Offline=$off"}else{'missing'}) ([bool]$scp -and $off -eq 0)
    })
}

# -- Roles: site roles / clients / collection / apps --
if (& $run 'Roles') {
    Write-LabLog "Stage Roles: MP/DP/SUP/RSP + clients + collection + apps..." -Step 'Verify'
    Add-Rows (Invoke-LabRemote -IPAddress '10.10.0.3' -Credential $DomainCred -ArgumentList @($RowFn,$NS) -ScriptBlock {
        param($RowFn,$NS)
        Invoke-Expression $RowFn
        $roles = Get-CimInstance -Namespace $NS -ClassName SMS_SCI_SysResUse
        function HasRole($server,$role) { [bool]($roles | Where-Object { $_.NetworkOSPath -match $server -and $_.RoleName -eq $role }) }
        Row 'A-MPDP' 'Management Point'   'present' (HasRole 'A-MPDP' 'SMS Management Point')   (HasRole 'A-MPDP' 'SMS Management Point')
        Row 'A-MPDP' 'Distribution Point' 'present' (HasRole 'A-MPDP' 'SMS Distribution Point') (HasRole 'A-MPDP' 'SMS Distribution Point')
        Row 'A-MPDP' 'Software Update Pt' 'present' (HasRole 'A-MPDP' 'SMS Software Update Point') (HasRole 'A-MPDP' 'SMS Software Update Point')
        Row 'A-SCCM' 'Reporting Svc Pt'   'present' (HasRole 'A-SCCM' 'SMS SRS Reporting Point') (HasRole 'A-SCCM' 'SMS SRS Reporting Point')

        $dev = Get-CimInstance -Namespace $NS -ClassName SMS_R_System | Where-Object { $_.Name -match '^A-' }
        $clients = @($dev | Where-Object { $_.Client -eq 1 })
        Row 'Clients' 'Discovered servers as client' '4 (A-SCCM,A-SQLSCCM,A-MPDP,A-DFSR)' (($clients.Name | Sort-Object) -join ',') ($clients.Count -eq 4)
        Row 'Clients' 'A-DC excluded'                'not a client'                      $(if($dev|?{$_.Name -eq 'A-DC'}){'present'}else{'absent'}) (-not ($dev | Where-Object { $_.Name -eq 'A-DC' }))

        $coll = Get-CimInstance -Namespace $NS -ClassName SMS_Collection -Filter "Name='All Servers'"
        Row 'Collection' 'All Servers member count' '4' $coll.MemberCount ($coll.MemberCount -eq 4)

        $apps = (Get-CimInstance -Namespace $NS -ClassName SMS_ApplicationLatest)
        foreach ($a in '7-Zip','Notepad++') {
            $app = $apps | Where-Object { $_.LocalizedDisplayName -eq $a }
            Row 'Apps' "$a deployed" 'IsDeployed + 1 deployment' $(if($app){"$($app.IsDeployed)/$($app.NumberOfDeployments)"}else{'missing'}) ([bool]$app -and $app.IsDeployed -and $app.NumberOfDeployments -ge 1)
        }
        $asg = Get-CimInstance -Namespace $NS -ClassName SMS_ApplicationAssignment
        Row 'Apps' 'Deployments target All Servers (Required)' '7-Zip + Notepad++ Required' (($asg | ForEach-Object { "$($_.ApplicationName):$($_.OfferTypeID)" }) -join ',') (@($asg | Where-Object { $_.CollectionName -eq 'All Servers' -and $_.OfferTypeID -eq 0 }).Count -ge 2)
    })
    # Apps actually installed on a client (A-SQLSCCM)
    Add-Rows (Invoke-LabRemote -IPAddress '10.10.0.4' -Credential $DomainCred -ArgumentList @($RowFn) -ScriptBlock {
        param($RowFn)
        Invoke-Expression $RowFn
        $inst = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        Row 'Apps' '7-Zip installed on A-SQLSCCM'    'present' (($inst | Where-Object { $_.DisplayName -match '7-Zip' }).DisplayName)   ([bool]($inst | Where-Object { $_.DisplayName -match '7-Zip' }))
        Row 'Apps' 'Notepad++ installed on A-SQLSCCM' 'present' (($inst | Where-Object { $_.DisplayName -match 'Notepad' }).DisplayName) ([bool]($inst | Where-Object { $_.DisplayName -match 'Notepad' }))
    })
}

# -- Discovery: methods / boundaries / client settings --
if (& $run 'Discovery') {
    Write-LabLog "Stage Discovery: methods / boundaries / client settings..." -Step 'Verify'
    Add-Rows (Invoke-LabRemote -IPAddress '10.10.0.3' -Credential $DomainCred -ArgumentList @($RowFn,$NS) -ScriptBlock {
        param($RowFn,$NS)
        Invoke-Expression $RowFn
        function DiscState($comp) {
            $c = Get-CimInstance -Namespace $NS -ClassName SMS_SCI_Component -Filter "ComponentName='$comp'" -ErrorAction SilentlyContinue
            if (-not $c) { return '(missing)' }
            ($c.Props | Where-Object { $_.PropertyName -eq 'SETTINGS' }).Value1
        }
        $map = @{
            'AD System' = 'SMS_AD_SYSTEM_DISCOVERY_AGENT'; 'AD User' = 'SMS_AD_USER_DISCOVERY_AGENT'
            'AD Group'  = 'SMS_AD_SECURITY_GROUP_DISCOVERY_AGENT'; 'Forest' = 'SMS_AD_FOREST_DISCOVERY_MANAGER'
        }
        foreach ($k in $map.Keys) { $s = DiscState $map[$k]; Row 'Discovery' "$k discovery" 'ACTIVE' $s ($s -eq 'ACTIVE') }
        $net = DiscState 'SMS_NETWORK_DISCOVERY'
        Row 'Discovery' 'Network discovery' 'OFF (blank)' $net ($net -ne 'ACTIVE')

        $b = Get-CimInstance -Namespace $NS -ClassName SMS_Boundary
        $ipr = @($b | Where-Object { $_.BoundaryType -eq 3 })
        Row 'Boundaries' 'IP-range boundaries' '2 (Site A + Site B)' (($b.DisplayName) -join ',') ($ipr.Count -eq 2)
        $bg = Get-CimInstance -Namespace $NS -ClassName SMS_BoundaryGroup
        Row 'Boundaries' 'Boundary groups' 'BG-Site-A + BG-Site-B' (($bg.Name | Sort-Object) -join ',') (($bg.Name -contains 'BG-Site-A') -and ($bg.Name -contains 'BG-Site-B'))
        $cs = Get-CimInstance -Namespace $NS -ClassName SMS_ClientSettings -Filter "Name='Servers'"
        Row 'ClientSettings' "'Servers' device settings" 'present (Type=1)' $(if($cs){"Type=$($cs.Type)"}else{'missing'}) ([bool]$cs -and $cs.Type -eq 1)
    })
}

# -- Updates: SUP / ADR / WSUS SSL / reporting cert / PKI / client cert --
if (& $run 'Updates') {
    Write-LabLog "Stage Updates: SUP / ADR / WSUS SSL / SSRS cert / PKI..." -Step 'Verify'
    # SUP config + ADR + reporting cert + MP/site PKI (A-SCCM SMS provider + local cert store)
    Add-Rows (Invoke-LabRemote -IPAddress '10.10.0.3' -Credential $DomainCred -ArgumentList @($RowFn,$NS) -ScriptBlock {
        param($RowFn,$NS)
        Invoke-Expression $RowFn
        Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1')
        if (-not (Get-PSDrive PR1 -ErrorAction SilentlyContinue)) { New-PSDrive -Name PR1 -PSProvider CMSite -Root 'A-SCCM.sadab.pri' | Out-Null }
        Set-Location 'PR1:'   # CM cmdlets require the CM drive as the current location
        $cls = @(Get-CMSoftwareUpdateCategory -Fast -TypeName UpdateClassification | Where-Object IsSubscribed | Select-Object -ExpandProperty LocalizedCategoryInstanceName)
        Row 'SUP' 'Classifications' 'Critical + Security' ($cls -join ',') (($cls -contains 'Critical Updates') -and ($cls -contains 'Security Updates') -and $cls.Count -eq 2)
        $prod = @(Get-CMSoftwareUpdateCategory -Fast -TypeName Product | Where-Object IsSubscribed | Select-Object -ExpandProperty LocalizedCategoryInstanceName)
        Row 'SUP' 'Products' 'Defender + Server OS 24H2 + Windows 11' ($prod -join ',') (($prod -contains 'Microsoft Defender Antivirus') -and ($prod -contains 'Microsoft Server Operating System-24H2') -and ($prod -contains 'Windows 11'))
        $adr = Get-CimInstance -Namespace $NS -ClassName SMS_AutoDeployment -ErrorAction SilentlyContinue
        Row 'SUP' 'ADR -> All Servers' 'exists, last run error 0' $(if($adr){"$($adr.Name) err=$($adr.LastErrorCode)"}else{'missing'}) ([bool]$adr -and $adr.LastErrorCode -eq 0)

        $mp = Get-CimInstance -Namespace $NS -ClassName SMS_SCI_SysResUse -Filter "RoleName='SMS Management Point'"
        $ssl = ($mp.Props | Where-Object { $_.PropertyName -eq 'SslState' }).Value
        Row 'PKI' 'MP SslState (HTTPS)' '63' $ssl ($ssl -eq 63)
        $iis = (Get-CimInstance -Namespace $NS -ClassName SMS_SCI_SCProperty -Filter "PropertyName='IISSSLState'").Value
        Row 'PKI' 'Site IISSSLState (HttpsOrHttp+PKI)' '1504' $iis ($iis -eq 1504)
        $csc = (Get-CimInstance -Namespace $NS -ClassName SMS_SCI_SCProperty -Filter "PropertyName='Certificate Selection Criteria'").Value
        Row 'PKI' 'Cert selection criteria' '0 = ClientAuthentication' $csc ($csc -eq 0)

        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -match 'CN=A-SCCM' -and $_.Issuer -match 'SADAB-Root-CA' } | Select-Object -First 1
        Row 'Reporting' 'SSRS HTTPS cert (CA-issued)' 'CN=A-SCCM, issuer SADAB-Root-CA' $(if($cert){$cert.Issuer}else{'none'}) ([bool]$cert)
    })
    # WSUS 8531 SSL on A-MPDP
    Add-Rows (Invoke-LabRemote -IPAddress '10.10.0.5' -Credential $DomainCred -ArgumentList @($RowFn) -ScriptBlock {
        param($RowFn)
        Invoke-Expression $RowFn
        $wsus = Get-Service WsusService -ErrorAction SilentlyContinue
        Row 'SUP' 'WsusService' 'Running' $wsus.Status ($wsus.Status -eq 'Running')
        $b = netsh http show sslcert 2>$null | Select-String '8531'
        Row 'SUP' 'WSUS 8531 SSL binding' 'present' $(if($b){'present'}else{'none'}) ([bool]$b)
    })
    # Client PKI cert on A-DFSR
    Add-Rows (Invoke-LabRemote -IPAddress '10.10.0.7' -Credential $DomainCred -ArgumentList @($RowFn) -ScriptBlock {
        param($RowFn)
        Invoke-Expression $RowFn
        $c = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
            ($_.EnhancedKeyUsageList.FriendlyName -match 'Client Authentication') -and ($_.Issuer -match 'SADAB-Root-CA')
        } | Select-Object -First 1
        Row 'PKI' 'A-DFSR client-auth cert' 'issued by SADAB-Root-CA, SAN A-DFSR.sadab.pri' $(if($c){($c.DnsNameList -join ',')}else{'none'}) ([bool]$c -and ($c.DnsNameList -join ',') -match 'A-DFSR.sadab.pri')
    })
}

# -- Report --
""
$all | Format-Table Area, Check, Expected, Actual, Status -AutoSize | Out-String -Width 200 | Write-Host
$pass = @($all | Where-Object Status -eq 'PASS').Count
$fail = @($all | Where-Object Status -eq 'FAIL').Count
if ($fail -eq 0) {
    Write-LabLog "Lab matches docs: $pass/$($all.Count) checks PASS." -Level SUCCESS -Step 'Verify'
} else {
    Write-LabLog "$fail FAIL, $pass PASS of $($all.Count) checks - lab DIVERGES from docs (see table)." -Level ERROR -Step 'Verify'
}

