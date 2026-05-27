<#
.SYNOPSIS
    Installs SCCM Primary Site on A-SCCM using an unattended setup ini file.
    Site code: PR1, points to A-SQLSCCM directly (no AG listener).

.NOTES
    Author  : SADAB Lab
    Version : 2.0
    Note    : SCCM install takes 45-90 minutes. Uses scheduled task to avoid
              WinRM timeout issues.
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

$MediaShare = $Global:LabConfig.MediaShareA
$SccmAIP    = '10.10.0.3'

$SetupIni = @'
[Identification]
Action=InstallPrimarySite

[Options]
ProductID=EVAL
SiteCode=PR1
SiteName=SADAB Lab
SMSInstallDir=C:\Program Files\Microsoft Configuration Manager
SDKServer=A-SCCM.sadab.pri
RoleCommunicationProtocol=HTTPorHTTPS
ClientsUsePKICertificate=0
PrerequisiteComp=1
PrerequisitePath=C:\SCCMPrereqs
AdminConsole=1
JoinCEIP=0

[SQLConfigOptions]
SQLServerName=A-SQLSCCM.sadab.pri
DatabaseName=CM_PR1
SQLSSBPort=4022

[CloudConnectorOptions]
CloudConnector=0
'@

Write-LabLog 'Starting SCCM Primary Site install on A-SCCM (this takes ~25-30 min)...' -Step 'SCCMPrimary'

# Step -1: Fix LCID 3072 (en-IL) on A-SQLSCCM if present. The Israel UserLocale
# in the unattend leaves HKU\.DEFAULT and HKU\S-1-5-18 set to LCID 3072 which is
# not supported by SQL Server's CLR. SCCM's spSetupLanternDocuments_CLR fails
# during FinalSqlOperations. Force en-US on both, then restart SQL so it
# re-reads the locale at process start.
Write-LabLog 'Pre-fix: ensure SQL on A-SQLSCCM runs with LCID 1033 (en-US)...' -Step 'SCCMPrimary'
Invoke-LabRemote -IPAddress '10.10.0.4' -Credential $DomainCred -ScriptBlock {
    $changed = $false

    # Build list of HKU hives to fix: .DEFAULT, SYSTEM, AND the SQL service
    # account's own hive (the SQL CLR thread locale comes from whatever account
    # the engine runs as - on this lab that's the gMSA SADAB\A-gMSA$, whose
    # profile inherited en-IL/LCID 3072 from the unattend UserLocale).
    $hives = @('.DEFAULT', 'S-1-5-18')
    try {
        $startName = (Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'").StartName  # e.g. SADAB\A-gMSA$
        if ($startName -and $startName -match '\\') {
            $parts = $startName.Split('\')
            $sid = (New-Object System.Security.Principal.NTAccount($parts[0], $parts[1])).Translate([System.Security.Principal.SecurityIdentifier]).Value
            if ($sid) { $hives += $sid; Write-Host "SQL service account $startName -> SID $sid" }
        }
    } catch { Write-Host "Could not resolve SQL service account SID: $($_.Exception.Message)" }

    foreach ($h in $hives) {
        $key = "Registry::HKEY_USERS\$h\Control Panel\International"
        try {
            $cur = (Get-ItemProperty $key -Name Locale -ErrorAction Stop).Locale
            if ($cur -ne '00000409') {
                Set-ItemProperty $key Locale     '00000409'
                Set-ItemProperty $key LocaleName 'en-US'
                Set-ItemProperty $key sLanguage  'ENU' -ErrorAction SilentlyContinue
                Write-Host "Fixed locale on HKU\$h (was $cur, now en-US)"
                $changed = $true
            }
        } catch { }  # hive may not be loaded; skip
    }

    if ($changed) {
        Write-Host 'Restarting SQL so the engine re-reads its thread locale...'
        Stop-Service MSSQLSERVER -Force
        Start-Sleep -Seconds 3
        Start-Service MSSQLSERVER
        Start-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    } else {
        Write-Host 'All locales already en-US, no SQL restart needed.'
    }
}

# Step 0: SCCM Primary install requires the site server's machine account
# (SADAB\A-SCCM$) to be BOTH (a) a SQL sysadmin AND (b) in the local
# Administrators group on the SQL Server machine. Both are required - setup loops
# forever on the "machine account does not have Administrator's privileges" check
# even when only one is set.
Write-LabLog 'Granting SADAB\A-SCCM$ sysadmin + local Administrators on A-SQLSCCM...' -Step 'SCCMPrimary'
Invoke-LabRemote -IPAddress '10.10.0.4' -Credential $DomainCred -ScriptBlock {
    # (a) SQL sysadmin
    $tsql = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'SADAB\A-SCCM$')
    CREATE LOGIN [SADAB\A-SCCM$] FROM WINDOWS;
IF NOT EXISTS (SELECT 1 FROM sys.server_role_members rm
               JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
               JOIN sys.server_principals p ON p.principal_id = rm.member_principal_id
               WHERE r.name = 'sysadmin' AND p.name = 'SADAB\A-SCCM$')
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [SADAB\A-SCCM$];
"@
    Set-Content -Path 'C:\Windows\Temp\grant-sccm.sql' -Value $tsql -Encoding ASCII
    & sqlcmd -S localhost -E -i 'C:\Windows\Temp\grant-sccm.sql' -b | Out-Null
    Write-Host '[a] SADAB\A-SCCM$ granted sysadmin in SQL'

    # (b) BUILTIN\Administrators on this machine
    $member = 'SADAB\A-SCCM$'
    $already = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
               Where-Object Name -eq $member
    if (-not $already) {
        Add-LocalGroupMember -Group 'Administrators' -Member $member
        Write-Host "[b] Added $member to local Administrators group"
    } else {
        Write-Host "[b] $member already in local Administrators"
    }
}

# Step 1: Stage the INI and download prereqs
Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    param($Share, $IniContent)

    # Use ASCII encoding - SCCM setup cannot parse UTF-8 BOM
    $iniPath = 'C:\SCCMSetup.ini'
    Set-Content -Path $iniPath -Value $IniContent -Encoding Ascii
    New-Item -ItemType Directory -Path 'C:\SCCMPrereqs' -Force | Out-Null

    $setupExe = Join-Path $Share 'SCCM\SMSSETUP\BIN\X64\setup.exe'
    $setupDl  = Join-Path $Share 'SCCM\SMSSETUP\BIN\X64\setupdl.exe'
    if (-not (Test-Path $setupExe)) { throw "SCCM setup.exe not found: $setupExe" }
    if (-not (Test-Path $setupDl))  { throw "SCCM setupdl.exe not found: $setupDl" }

    # Idempotent: skip download if prereqs already present
    $existing = Get-ChildItem 'C:\SCCMPrereqs' -ErrorAction SilentlyContinue
    if (-not $existing -or $existing.Count -lt 50) {
        Write-Host 'Downloading SCCM prerequisites via setupdl.exe (~5-10 min)...'
        Start-Process -FilePath $setupDl -ArgumentList 'C:\SCCMPrereqs' -Wait -NoNewWindow
        $dlSize = (Get-ChildItem 'C:\SCCMPrereqs' -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
        Write-Host ("Prereq download done: {0:N1} MB" -f $dlSize)
    } else {
        Write-Host "Prereqs already present ($($existing.Count) items) - skipping download"
    }
} -ArgumentList $MediaShare, $SetupIni

# Step 2: Launch setup.exe in the background on A-SCCM (Hyper-V direct interactive
# session can spawn SetupWpf.exe; scheduled task as domain user cannot - it fails
# with "Failed to create process of SetupWpf.exe. return value 1"). We use
# Start-Process WITHOUT -Wait so the remote call returns quickly, then poll the log.
Write-LabLog 'Launching SCCM setup directly via Hyper-V direct WinRM (no scheduled task)...' -Step 'SCCMPrimary'

# Copy SCCM media + ini locally on A-SCCM first - running setup from a UNC share is fragile
Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    param($Share)
    $localDir = 'C:\SCCMSetup'
    if (-not (Test-Path "$localDir\SMSSETUP\BIN\X64\setup.exe")) {
        Write-Host 'Copying SCCM media from share to C:\SCCMSetup locally (~1.5 GB)...'
        New-Item -ItemType Directory -Path $localDir -Force | Out-Null
        # Use robocopy for resumability/perf
        & robocopy "$Share\SCCM" $localDir /E /R:2 /W:5 /NJH /NJS /NDL /NFL | Out-Null
        Write-Host "Copy complete: $((Get-ChildItem $localDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB | ForEach-Object { '{0:N0} MB' -f $_ })"
    } else {
        Write-Host 'SCCM media already local at C:\SCCMSetup'
    }
} -ArgumentList $MediaShare

# Now start setup.exe in the background (Start-Process WITHOUT -Wait), capture PID
$setupPid = Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    $localSetup = 'C:\SCCMSetup\SMSSETUP\BIN\X64\setup.exe'
    $iniPath    = 'C:\SCCMSetup.ini'
    Write-Host "Launching: $localSetup /SCRIPT $iniPath /NOUSERINPUT"
    # Run in current interactive session (Hyper-V direct provides this).
    # -PassThru returns the Process object; -NoNewWindow keeps it in our session.
    $p = Start-Process -FilePath $localSetup `
                       -ArgumentList '/SCRIPT', $iniPath, '/NOUSERINPUT' `
                       -PassThru -NoNewWindow
    $p.Id
}
Write-LabLog "SCCM setup launched (PID $setupPid on A-SCCM)" -Step 'SCCMPrimary'

# Step 3: Poll for completion (setup runs async, we monitor the log)
Write-LabLog 'Monitoring SCCM setup progress...' -Step 'SCCMPrimary'
$maxWait  = 3600   # 60 min - user reports 25-30 min is typical
$elapsed  = 0
$interval = 30

while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds $interval
    $elapsed += $interval

    $status = Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
        $setupLog = 'C:\ConfigMgrSetup.log'
        $result = @{ Complete = $false; Failed = $false; LastLine = ''; SetupRunning = $false }

        if (Test-Path $setupLog) {
            $tail = Get-Content $setupLog -Tail 30 -ErrorAction SilentlyContinue | Out-String
            $result.LastLine = (Get-Content $setupLog -Tail 1 -ErrorAction SilentlyContinue)
            if ($tail -match 'Setup has completed|Configuration Manager Setup has completed|Installation was successful') {
                $result.Complete = $true
            }
            if ($tail -match 'FATAL ERROR|Setup failed|Failed Configuration Manager Server Setup|Configuration Manager Setup failed') {
                $result.Failed = $true
            }
        }

        $svc = Get-Service -Name 'SMS_Executive' -ErrorAction SilentlyContinue
        if ($svc -and ($svc.Status -eq 'Running')) { $result.Complete = $true }

        $result.SetupRunning = [bool](Get-Process setup, SetupWpf, configmgrsetup -ErrorAction SilentlyContinue)

        return $result
    }

    if ($status.Failed) {
        Write-LabLog 'SCCM Setup FAILED. Check C:\ConfigMgrSetup.log on A-SCCM.' -Level ERROR -Step 'SCCMPrimary'
        throw "SCCM setup failed. See C:\ConfigMgrSetup.log on A-SCCM."
    }
    if ($status.Complete) {
        Write-LabLog 'SCCM setup completed successfully.' -Level SUCCESS -Step 'SCCMPrimary'
        break
    }
    if (-not $status.SetupRunning -and $elapsed -gt 60) {
        Write-LabLog 'Setup process has exited but log does not show success - check ConfigMgrSetup.log' -Level WARN -Step 'SCCMPrimary'
        throw "Setup exited prematurely. Last log line: $($status.LastLine)"
    }

    $minutes = [math]::Round($elapsed / 60, 1)
    if ($elapsed % 120 -eq 0) {
        Write-LabLog "SCCM setup still running ($minutes min)... $($status.LastLine)" -Step 'SCCMPrimary'
    }
}

if ($elapsed -ge $maxWait) {
    throw "SCCM setup timed out after $($maxWait/60) minutes."
}

Write-LabLog 'SCCM Primary Site installed on A-SCCM.' -Level SUCCESS -Step 'SCCMPrimary'
