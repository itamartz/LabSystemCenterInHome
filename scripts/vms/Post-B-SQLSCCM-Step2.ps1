<#
.SYNOPSIS
    Step 2: Install SQL 2019 on B-SQLSCCM. Run on Host A.
    Prereqs: B-SQLSCCM domain-joined, media share accessible (cmdkey for host creds).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$DomainAdminPassword
)

. "$PSScriptRoot\PostDeployHelpers.ps1"

$creds = New-LabCredentials -AdminPassword $DomainAdminPassword -DomainAdminPassword $DomainAdminPassword
$IP    = '10.20.0.4'

# ── Format data disk ───────────��─────────────────────────────────────────────
Write-LabLog 'Initializing data disk as D:...' -Step 'B-SQLSCCM'
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -ScriptBlock {
    if (Test-Path 'D:\') { Write-Host 'D: drive already exists.'; return }
    $rawDisk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Select-Object -First 1
    if (-not $rawDisk) { throw 'No raw data disk found.' }
    $rawDisk | Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -UseMaximumSize -DriveLetter D |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel 'SQLData' -Confirm:$false | Out-Null
    Write-Host "Data disk initialized: D: ($([math]::Round($rawDisk.Size / 1GB)) GB)"
}

# ── Install SQL 2019 ──────────────────────────────���──────────────────────────
Write-LabLog 'Installing SQL Server 2019 on B-SQLSCCM...' -Step 'B-SQLSCCM'

$SqlConfig = @'
[OPTIONS]
ACTION="Install"
FEATURES=SQLENGINE,REPLICATION,CONN,SNAC_SDK
INSTANCENAME="MSSQLSERVER"
INSTANCEID="MSSQLSERVER"
SQLCOLLATION="SQL_Latin1_General_CP1_CI_AS"
SQLSVCACCOUNT="NT AUTHORITY\SYSTEM"
AGTSVCACCOUNT="NT AUTHORITY\SYSTEM"
SQLSYSADMINACCOUNTS="SADAB\Administrator" "SADAB\Domain Admins"
SQLTEMPDBFILECOUNT=4
SQLTEMPDBFILESIZE=64
SQLTEMPDBFILEGROWTH=64
SQLTEMPDBLOGFILESIZE=8
SQLTEMPDBLOGFILEGROWTH=64
INSTALLSQLDATADIR="D:\SQLData"
SQLUSERDBLOGDIR="D:\SQLLogs"
SQLBACKUPDIR="D:\SQLBackup"
BROWSERSVCSTARTUPTYPE="Automatic"
TCPENABLED=1
NPENABLED=0
IAcceptSQLServerLicenseTerms="True"
QUIET="True"
INDICATEPROGRESS="False"
UPDATEENABLED="False"
'@

Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -TimeoutSec 1800 -ScriptBlock {
    param($Share, $Config)

    $sqlSvc = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
    if ($sqlSvc) { Write-Host 'SQL Server already installed.'; return }

    $isoFile = Get-ChildItem -Path "$Share\SQL" -Filter '*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1
    $extractPath = 'C:\SQLInstall'

    if (-not (Test-Path "$extractPath\setup.exe")) {
        if (-not $isoFile) { throw "SQL ISO not found in $Share\SQL" }
        New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
        $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
        if (Test-Path $sevenZip) {
            & $sevenZip x $isoFile.FullName "-o$extractPath" -y -bso0 -bsp0
        } else {
            $mount = Mount-DiskImage -ImagePath $isoFile.FullName -PassThru
            $driveLetter = ($mount | Get-Volume).DriveLetter
            Copy-Item -Path "${driveLetter}:\*" -Destination $extractPath -Recurse -Force
            Dismount-DiskImage -ImagePath $isoFile.FullName
        }
    }

    Set-Content -Path 'C:\SQLConfig.ini' -Value $Config -Encoding Ascii

    $result = Start-Process -FilePath "$extractPath\setup.exe" `
        -ArgumentList '/ConfigurationFile="C:\SQLConfig.ini"' -Wait -PassThru -NoNewWindow
    if ($result.ExitCode -notin @(0, 3010)) {
        $logPath = 'C:\Program Files\Microsoft SQL Server\150\Setup Bootstrap\Log\Summary.txt'
        if (Test-Path $logPath) { Get-Content $logPath -Tail 30 | ForEach-Object { Write-Host "  $_" } }
        throw "SQL install failed with exit code: $($result.ExitCode)"
    }

    $cuExe = Get-ChildItem -Path "$Share\SQL" -Filter 'SQLServer2019-KB*.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cuExe) {
        Write-Host "Applying SQL CU: $($cuExe.Name)..."
        Start-Process -FilePath $cuExe.FullName `
            -ArgumentList '/quiet /IAcceptSQLServerLicenseTerms /Action=Patch /AllInstances' `
            -Wait -PassThru -NoNewWindow | Out-Null
    }

    $totalMemGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $maxMemMB   = ($totalMemGB - 4) * 1024
    Invoke-Sqlcmd -Query "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;" -ServerInstance 'localhost' -ErrorAction SilentlyContinue
    Invoke-Sqlcmd -Query "EXEC sp_configure 'max server memory', $maxMemMB; RECONFIGURE;" -ServerInstance 'localhost' -ErrorAction SilentlyContinue

    $regBase = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\SuperSocketNetLib'
    if (Test-Path "$regBase\Tcp") { Set-ItemProperty -Path "$regBase\Tcp" -Name 'Enabled' -Value 1 }
    if (Test-Path "$regBase\Np")  { Set-ItemProperty -Path "$regBase\Np"  -Name 'Enabled' -Value 1 }

    foreach ($rule in @(
        @{ Name = 'SQL Server';         Port = 1433; Protocol = 'TCP' }
        @{ Name = 'SQL Server Browser'; Port = 1434; Protocol = 'UDP' }
        @{ Name = 'SQL Server DAC';     Port = 1434; Protocol = 'TCP' }
        @{ Name = 'SQL AG Endpoint';    Port = 5022; Protocol = 'TCP' }
    )) {
        if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Protocol $rule.Protocol -LocalPort $rule.Port -Action Allow | Out-Null
        }
    }

    Enable-SqlAlwaysOn -ServerInstance 'localhost' -Force -ErrorAction SilentlyContinue

    Set-Service -Name 'MSSQLSERVER' -StartupType Automatic
    Set-Service -Name 'SQLSERVERAGENT' -StartupType Automatic
    Restart-Service -Name 'MSSQLSERVER' -Force
    Start-Service -Name 'SQLSERVERAGENT' -ErrorAction SilentlyContinue

    Write-Host 'SQL Server 2019 installed and configured.'
} -ArgumentList '\\10.10.0.1\LabMedia', $SqlConfig

Write-LabLog 'B-SQLSCCM Step 2 complete.' -Level SUCCESS -Step 'B-SQLSCCM'
