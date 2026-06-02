<#
.SYNOPSIS
    Installs SQL Server 2019 Developer + CU32 on B-SQLSCOM (Site B SCOM database server).
    SCOM-style config: NT AUTHORITY\SYSTEM service account (no gMSA needed).
    Must run ON HOST B (uses Hyper-V direct to the VM).

.NOTES
    - Patterned after scripts/post-deploy/06-Install-SQL.ps1 SCOM block.
    - SQL data goes to D:\SQLData (the 100 GB data disk attached to B-SQLSCOM).
    - Idempotent: skips if MSSQLSERVER service already exists on the VM.
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SQLSCOM',
    [string]$MediaShare          = '\\10.20.0.1\LabMedia',
    [string]$DomainAdminPassword = 'LabAdmin@2026!'
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][SQL-B-SQLSCOM] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

$SqlConfigSCOM = @'
[OPTIONS]
ACTION="Install"
FEATURES=SQLENGINE,FULLTEXT,CONN,SNAC_SDK
INSTANCENAME="MSSQLSERVER"
INSTANCEID="MSSQLSERVER"
SQLCOLLATION="SQL_Latin1_General_CP1_CI_AS"
SQLSVCACCOUNT="NT AUTHORITY\SYSTEM"
AGTSVCACCOUNT="NT AUTHORITY\SYSTEM"
SQLSYSADMINACCOUNTS="SADAB\Administrator" "SADAB\Domain Admins" "NT AUTHORITY\SYSTEM"
SQLTEMPDBFILECOUNT=2
SQLTEMPDBFILESIZE=32
SQLSVCINSTANTFILEINIT="True"
BROWSERSVCSTARTUPTYPE="Automatic"
TCPENABLED=1
NPENABLED=0
INSTALLSQLDATADIR="D:\SQLData"
SQLUSERDBLOGDIR="D:\SQLLogs"
SQLBACKUPDIR="D:\SQLBackup"
IAcceptSQLServerLicenseTerms="True"
QUIET="True"
INDICATEPROGRESS="False"
UPDATEENABLED="False"
'@

Write-Stage "Preparing data disk D: on $VMName..."
Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    # Bring the 100 GB data disk online + format if not done already
    $offlineDisks = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Offline' }
    foreach ($d in $offlineDisks) {
        Set-Disk -Number $d.Number -IsReadOnly $false -ErrorAction SilentlyContinue
        Set-Disk -Number $d.Number -IsOffline $false -ErrorAction SilentlyContinue
    }
    $rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' }
    foreach ($d in $rawDisks) {
        Initialize-Disk -Number $d.Number -PartitionStyle GPT -ErrorAction SilentlyContinue
        $part = New-Partition -DiskNumber $d.Number -UseMaximumSize -DriveLetter D -ErrorAction SilentlyContinue
        Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel 'SQLData' -Confirm:$false -Force | Out-Null
    }
    # If disk already initialised but volume not letter-assigned
    if (-not (Test-Path 'D:\')) {
        $unassigned = Get-Partition | Where-Object { -not $_.DriveLetter -and $_.Type -eq 'Basic' } | Select-Object -First 1
        if ($unassigned) {
            Set-Partition -InputObject $unassigned -NewDriveLetter D | Out-Null
        }
    }
    foreach ($f in 'D:\SQLData','D:\SQLLogs','D:\SQLBackup') {
        if (-not (Test-Path $f)) { New-Item -ItemType Directory -Path $f -Force | Out-Null }
    }
    Get-Volume D | Select-Object DriveLetter, FileSystem,
        @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
        @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}} | Format-Table -AutoSize | Out-String | Write-Host
}

Write-Stage "Running SQL install scriptblock inside $VMName via Hyper-V direct..."
Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    param($Share, $Config, $AdminPassword)

    # Idempotency: already done?
    if (Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue) {
        Write-Host "MSSQLSERVER service already present - SQL is installed."

        # SCOM 2025 setup checks for Full Text Search and refuses to install if it's
        # missing ("Sql Server does not have Full Text Search installed."). Add the
        # feature in-place via /Action=Install /Features=FullText if it's not there.
        $ftKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\Setup' -ErrorAction SilentlyContinue
        $hasFullText = $ftKey -and ($ftKey.'FeatureList' -match 'FullText' -or (Get-Service -Name MSSQLFDLauncher -ErrorAction SilentlyContinue))
        if (-not $hasFullText) {
            Write-Host "Full Text Search missing - adding via /Action=Install /Features=FullText..."
            $setup = 'C:\SQLInstall\setup.exe'
            if (-not (Test-Path $setup)) { throw "SQL extracted setup.exe not found at $setup - cannot add feature" }
            $addArgs = "/Q /ACTION=Install /FEATURES=FullText /INSTANCENAME=MSSQLSERVER /IAcceptSQLServerLicenseTerms /UPDATEENABLED=False"
            $p = Start-Process -FilePath $setup -ArgumentList $addArgs -Wait -PassThru -NoNewWindow
            Write-Host "Add-FullText exit code: $($p.ExitCode)"
            if ($p.ExitCode -notin @(0, 3010)) {
                $log = 'C:\Program Files\Microsoft SQL Server\150\Setup Bootstrap\Log\Summary.txt'
                if (Test-Path $log) { Get-Content $log -Tail 30 | ForEach-Object { Write-Host "  $_" } }
                throw "Add-Feature FullText failed with $($p.ExitCode)"
            }
        } else { Write-Host "Full Text Search already installed." }
        return
    }

    # Cache SMB cred for the local host share so the install can read the ISO
    cmdkey /add:10.20.0.1 /user:labadmin /pass:$AdminPassword | Out-Null

    $isoFile = Get-ChildItem -Path "$Share\SQL" -Filter '*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $isoFile) { throw "SQL ISO not found in $Share\SQL" }
    Write-Host "Found SQL ISO: $($isoFile.Name)"

    $extractPath = 'C:\SQLInstall'
    if (-not (Test-Path "$extractPath\setup.exe")) {
        New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
        $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
        if (Test-Path $sevenZip) {
            Write-Host "Extracting ISO via 7-Zip..."
            & $sevenZip x $isoFile.FullName "-o$extractPath" -y -bso0 -bsp0 | Out-Null
        } else {
            Write-Host "Mounting ISO + copying (no 7-Zip)..."
            $mount = Mount-DiskImage -ImagePath $isoFile.FullName -PassThru
            Start-Sleep 2
            $dl = ($mount | Get-Volume).DriveLetter
            Copy-Item -Path "${dl}:\*" -Destination $extractPath -Recurse -Force
            Dismount-DiskImage -ImagePath $isoFile.FullName | Out-Null
        }
    }
    if (-not (Test-Path "$extractPath\setup.exe")) { throw "setup.exe missing after extraction" }

    Set-Content -Path 'C:\SQLConfig.ini' -Value $Config -Encoding Ascii

    Write-Host "Running SQL setup..."
    $proc = Start-Process -FilePath "$extractPath\setup.exe" `
                          -ArgumentList "/ConfigurationFile=`"C:\SQLConfig.ini`"" `
                          -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -notin @(0, 3010)) {
        $log = 'C:\Program Files\Microsoft SQL Server\150\Setup Bootstrap\Log\Summary.txt'
        if (Test-Path $log) { Get-Content $log -Tail 40 | ForEach-Object { Write-Host "  $_" } }
        throw "SQL setup failed with exit code $($proc.ExitCode)"
    }
    Write-Host "SQL setup exit code: $($proc.ExitCode)"

    # CU32
    $cu = Get-ChildItem -Path "$Share\SQL" -Filter 'SQLServer2019-KB*.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cu) {
        Write-Host "Applying CU: $($cu.Name)..."
        $cup = Start-Process -FilePath $cu.FullName `
                             -ArgumentList "/quiet /IAcceptSQLServerLicenseTerms /Action=Patch /AllInstances" `
                             -Wait -PassThru -NoNewWindow
        Write-Host "CU exit code: $($cup.ExitCode)"
    } else { Write-Host "No CU found - skipping" }

    # Memory cap: TotalRAM - 2 GB for OS (SCOM SQL is lighter than SCCM SQL)
    $totalMemGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $maxMemMB   = [math]::Max(2048, ($totalMemGB - 2) * 1024)
    Invoke-Sqlcmd -Query "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;" -ServerInstance localhost -ErrorAction SilentlyContinue | Out-Null
    Invoke-Sqlcmd -Query "EXEC sp_configure 'max server memory', $maxMemMB; RECONFIGURE;" -ServerInstance localhost -ErrorAction SilentlyContinue | Out-Null
    Write-Host "SQL max memory set to $maxMemMB MB"

    # Network protocols
    $regBase = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\SuperSocketNetLib'
    if (Test-Path "$regBase\Tcp") { Set-ItemProperty -Path "$regBase\Tcp" -Name Enabled -Value 1 }
    if (Test-Path "$regBase\Np")  { Set-ItemProperty -Path "$regBase\Np"  -Name Enabled -Value 1 }

    # Firewall
    foreach ($r in @(
        @{ Name='SQL Server';          Port=1433; Protocol='TCP' },
        @{ Name='SQL Server Browser';  Port=1434; Protocol='UDP' })) {
        if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $r.Name -Direction Inbound `
                -Protocol $r.Protocol -LocalPort $r.Port -Action Allow | Out-Null
        }
    }

    # SPNs - service runs as LocalSystem so SPN goes on the computer account
    $computerName = $env:COMPUTERNAME
    $fqdn = "$computerName.sadab.pri"
    foreach ($spn in @("MSSQLSvc/${fqdn}", "MSSQLSvc/${fqdn}:1433",
                       "MSSQLSvc/${computerName}", "MSSQLSvc/${computerName}:1433")) {
        & setspn -s $spn "$computerName`$" 2>&1 | Out-Null
    }

    Set-Service -Name MSSQLSERVER       -StartupType Automatic
    Set-Service -Name SQLSERVERAGENT    -StartupType Automatic
    Restart-Service -Name MSSQLSERVER -Force
    # SQLSERVERAGENT stops when MSSQLSERVER restarts (dependency); explicitly
    # restart it AFTER the engine is back up. -ErrorAction Stop so a failure
    # surfaces - previously SilentlyContinue masked a real "agent never
    # started" state and SCOM later raised SQL Agent Stopped alert.
    Start-Service   -Name SQLSERVERAGENT -ErrorAction Stop

    # SCOM SQL MP on the agent (running as LocalSystem) needs sysadmin to
    # query securables. Without this, SCOM raises:
    #   "MSSQL on Windows: Some Database Engine securables are inaccessible".
    # The config file's SQLSYSADMINACCOUNTS already includes "NT AUTHORITY\SYSTEM"
    # for clean installs; this idempotent T-SQL fixes any pre-existing instance
    # that was installed before this change.
    $sysAdminCheck = Invoke-Sqlcmd -ServerInstance localhost -Query @"
SELECT COUNT(*) AS HasIt FROM sys.server_role_members rm
JOIN sys.server_principals p ON rm.member_principal_id = p.principal_id
JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
WHERE r.name = 'sysadmin' AND p.name = 'NT AUTHORITY\SYSTEM'
"@ -ErrorAction SilentlyContinue
    if (-not $sysAdminCheck -or $sysAdminCheck.HasIt -eq 0) {
        Write-Host "Granting NT AUTHORITY\SYSTEM sysadmin (for SCOM agent)..."
        Invoke-Sqlcmd -ServerInstance localhost -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='NT AUTHORITY\SYSTEM')
    CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;
EXEC sp_addsrvrolemember 'NT AUTHORITY\SYSTEM','sysadmin';
"@ -ErrorAction Stop
    }

    Write-Host "SQL Server 2019 + CU installed on $env:COMPUTERNAME (data on D:)."
} -ArgumentList $MediaShare, $SqlConfigSCOM, $DomainAdminPassword

Write-Stage "Verifying SQL is responding..."
Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    try {
        $v = Invoke-Sqlcmd -ServerInstance localhost -Query "SELECT @@VERSION AS V, SERVERPROPERTY('ProductLevel') AS PL" -ErrorAction Stop
        "$($v.V.Substring(0,80))..."
        "ProductLevel: $($v.PL)"
        "DBs: " + ((Invoke-Sqlcmd -ServerInstance localhost -Query "SELECT name FROM sys.databases").name -join ', ')
    } catch { "Verify failed: $($_.Exception.Message)" }
}

Write-Stage "Done."
