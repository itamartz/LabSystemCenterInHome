<#
.SYNOPSIS
    Installs SQL Server 2019 Developer silently on A-SQLSCCM, B-SQLSCCM, and A-SQLSCOM.
    Extracts ISO with 7-Zip, applies CU32, configures memory, firewall, SPNs.

.NOTES
    Author  : SADAB Lab
    Version : 2.0
    SQL     : SQL Server 2019 Developer (not 2022) with CU32
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

$MediaShareA = $Global:LabConfig.MediaShareA
$DomainName  = $Global:LabConfig.DomainName
$NetBIOS     = $Global:LabConfig.NetBIOSName

# SQL 2019 config for SCCM SQL servers - gMSA placeholder replaced per-VM
$SqlConfigSCCMTemplate = @'
[OPTIONS]
ACTION="Install"
FEATURES=SQLENGINE,REPLICATION,CONN,SNAC_SDK
INSTANCENAME="MSSQLSERVER"
INSTANCEID="MSSQLSERVER"
SQLCOLLATION="SQL_Latin1_General_CP1_CI_AS"
SQLSVCACCOUNT="{{SQLSVCACCOUNT}}"
AGTSVCACCOUNT="{{AGTSVCACCOUNT}}"
SQLSYSADMINACCOUNTS="SADAB\Administrator" "SADAB\Domain Admins"
SQLTEMPDBFILECOUNT=4
SQLTEMPDBFILESIZE=64
SQLTEMPDBFILEGROWTH=64
SQLTEMPDBLOGFILESIZE=8
SQLTEMPDBLOGFILEGROWTH=64
INSTALLSQLDATADIR="C:\SQLData"
SQLUSERDBLOGDIR="C:\SQLLogs"
SQLBACKUPDIR="C:\SQLBackup"
BROWSERSVCSTARTUPTYPE="Automatic"
TCPENABLED=1
NPENABLED=0
IAcceptSQLServerLicenseTerms="True"
QUIET="True"
INDICATEPROGRESS="False"
UPDATEENABLED="False"
'@

# SQL 2019 config for SCOM SQL server (A-SQLSCOM) - lighter config
$SqlConfigSCOM = @'
[OPTIONS]
ACTION="Install"
FEATURES=SQLENGINE,CONN,SNAC_SDK
INSTANCENAME="MSSQLSERVER"
INSTANCEID="MSSQLSERVER"
SQLCOLLATION="SQL_Latin1_General_CP1_CI_AS"
SQLSVCACCOUNT="NT AUTHORITY\SYSTEM"
AGTSVCACCOUNT="NT AUTHORITY\SYSTEM"
SQLSYSADMINACCOUNTS="SADAB\Administrator" "SADAB\Domain Admins"
SQLTEMPDBFILECOUNT=2
SQLTEMPDBFILESIZE=32
SQLSVCINSTANTFILEINIT="True"
BROWSERSVCSTARTUPTYPE="Automatic"
TCPENABLED=1
NPENABLED=0
IAcceptSQLServerLicenseTerms="True"
QUIET="True"
INDICATEPROGRESS="False"
UPDATEENABLED="False"
'@

function Install-SQLOnVM {
    param(
        [string]$IP,
        [string]$VMName,
        [string]$MediaShare,
        [string]$ConfigContent,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$DomainFQDN,
        [string]$DomainNetBIOS,
        [string]$gMSAName = ''
    )

    # If gMSA specified, install it on the target VM first
    if ($gMSAName) {
        # Determine gMSA principals group from naming convention: A-gMSA -> SQLServersA, B-gMSA -> SQLServersB
        $msaGroup = if ($gMSAName -like 'A-*') { 'SQLServersA' } else { 'SQLServersB' }

        # 1. Add the target computer to the gMSA principals group on A-DC.
        #    Step 3 ran before step 5 (domain join), so $env:COMPUTERNAME wasn't in AD yet.
        Write-LabLog "Ensuring $VMName`$ is in $msaGroup on A-DC..." -Step 'SQL'
        $added = Invoke-LabRemote -IPAddress '10.10.0.2' -Credential $Credential -ScriptBlock {
            param($cn, $grp)
            $PSDefaultParameterValues = @{ '*-AD*:Server' = 'localhost' }
            $comp = Get-ADComputer -Filter "Name -eq '$cn'" -ErrorAction Stop
            $isMember = Get-ADGroupMember -Identity $grp -ErrorAction SilentlyContinue |
                Where-Object { $_.SamAccountName -eq "$cn`$" }
            if (-not $isMember) {
                Add-ADGroupMember -Identity $grp -Members $comp
                Write-Host "Added $cn`$ to $grp"
                return $true
            }
            Write-Host "$cn`$ already in $grp"
            return $false
        } -ArgumentList $VMName, $msaGroup

        # 2. Only restart if we actually added the computer just now (Kerberos ticket refresh).
        if ($added) {
            Write-LabLog "Rebooting $VMName so new group membership lands in Kerberos ticket..." -Step 'SQL'
            Invoke-LabRemote -IPAddress $IP -Credential $Credential -ScriptBlock {
                shutdown /r /t 5 /c 'Reboot for gMSA group membership' | Out-Null
            }
            Start-Sleep -Seconds 60
            Wait-LabVMReady -IPAddress $IP -Credential $Credential -TimeoutSec 240
            # Give AD a moment to settle before the gMSA call
            Start-Sleep -Seconds 30
        } else {
            Write-LabLog "Group membership already in place - skipping reboot." -Step 'SQL'
        }

        # 3. Install the gMSA on the local machine. MUST use Hyper-V direct connect
        #    (-VMName) instead of network WinRM (-ComputerName) because the gMSA
        #    install does a second hop to A-DC to retrieve the password, and NTLM
        #    credentials from network WinRM can't be delegated. Hyper-V direct gives
        #    an interactive Kerberos token that supports delegation.
        Write-LabLog "Installing gMSA '$gMSAName' on $VMName (via Hyper-V direct)..." -Step 'SQL'
        Invoke-Command -VMName $VMName -Credential $Credential -ErrorAction Stop -ScriptBlock {
            param($msaName)
            if (-not (Get-Command Install-ADServiceAccount -ErrorAction SilentlyContinue)) {
                Write-Host "Installing RSAT-AD-PowerShell (needed for gMSA install)..."
                Install-WindowsFeature -Name RSAT-AD-PowerShell -IncludeManagementTools -ErrorAction Stop | Out-Null
                Import-Module ActiveDirectory -Force
            }
            $lastErr = $null
            for ($i = 1; $i -le 5; $i++) {
                try {
                    Install-ADServiceAccount -Identity $msaName -ErrorAction Stop
                    $test = Test-ADServiceAccount -Identity $msaName
                    if (-not $test) { throw "gMSA '$msaName' failed validation on $env:COMPUTERNAME" }
                    Write-Host "gMSA '$msaName' installed and validated (attempt $i)."
                    return
                } catch {
                    $lastErr = $_
                    Write-Host "  attempt ${i}: $($_.Exception.Message)"
                    Start-Sleep -Seconds 20
                }
            }
            throw "gMSA install failed after 5 attempts: $lastErr"
        } -ArgumentList $gMSAName
    }

    Write-LabLog "Installing SQL Server 2019 on $VMName (via Hyper-V direct)..." -Step 'SQL'

    # Hyper-V direct: interactive token preserves access to cmdkey-cached SMB creds
    # and supports delegation for any AD operations during install.
    Invoke-Command -VMName $VMName -Credential $Credential -ErrorAction Stop -ScriptBlock {
        param($Share, $Config, $DomFQDN, $DomNB, $gMSA)

        # Check if already installed
        $sqlSvc = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
        if ($sqlSvc) {
            Write-Host "SQL Server already installed on this VM."
            return
        }

        # Extract SQL ISO with 7-Zip
        $isoFile = Get-ChildItem -Path "$Share\SQL" -Filter '*.iso' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $extractPath = 'C:\SQLInstall'

        if (-not (Test-Path "$extractPath\setup.exe")) {
            if (-not $isoFile) { throw "SQL ISO not found in $Share\SQL" }
            New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

            # Try 7-Zip first, fall back to mounting ISO
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

        # Write config file
        $configPath = 'C:\SQLConfig.ini'
        Set-Content -Path $configPath -Value $Config -Encoding Ascii

        # Run SQL setup
        $setupExe = Join-Path $extractPath 'setup.exe'
        if (-not (Test-Path $setupExe)) { throw "SQL setup.exe not found at: $setupExe" }

        $result = Start-Process -FilePath $setupExe `
                                -ArgumentList "/ConfigurationFile=`"$configPath`"" `
                                -Wait -PassThru -NoNewWindow
        if ($result.ExitCode -notin @(0, 3010)) {
            $logPath = 'C:\Program Files\Microsoft SQL Server\150\Setup Bootstrap\Log\Summary.txt'
            if (Test-Path $logPath) { Get-Content $logPath -Tail 30 | ForEach-Object { Write-Host "  $_" } }
            throw "SQL install failed with exit code: $($result.ExitCode)"
        }

        # Apply CU32 if available
        $cuExe = Get-ChildItem -Path "$Share\SQL" -Filter 'SQLServer2019-KB*.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cuExe) {
            Write-Host "Applying SQL CU: $($cuExe.Name)..."
            $cuResult = Start-Process -FilePath $cuExe.FullName `
                                      -ArgumentList "/quiet /IAcceptSQLServerLicenseTerms /Action=Patch /AllInstances" `
                                      -Wait -PassThru -NoNewWindow
            if ($cuResult.ExitCode -notin @(0, 3010)) {
                Write-Host "WARNING: CU install returned exit code: $($cuResult.ExitCode)"
            } else {
                Write-Host "SQL CU applied successfully."
            }
        }

        # Configure max memory (leave 4 GB for OS)
        $totalMemGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $maxMemMB   = ($totalMemGB - 4) * 1024
        Invoke-Sqlcmd -Query "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;" `
                      -ServerInstance 'localhost' -ErrorAction SilentlyContinue
        Invoke-Sqlcmd -Query "EXEC sp_configure 'max server memory', $maxMemMB; RECONFIGURE;" `
                      -ServerInstance 'localhost' -ErrorAction SilentlyContinue

        # Enable TCP/IP and Named Pipes via registry (SQL 2019 = MSSQL15)
        $regBase = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\SuperSocketNetLib'
        if (Test-Path "$regBase\Tcp") {
            Set-ItemProperty -Path "$regBase\Tcp" -Name 'Enabled' -Value 1
        }
        if (Test-Path "$regBase\Np") {
            Set-ItemProperty -Path "$regBase\Np" -Name 'Enabled' -Value 1
        }

        # Firewall rules for SQL
        $fwRules = @(
            @{ Name = 'SQL Server';         Port = 1433; Protocol = 'TCP' }
            @{ Name = 'SQL Server Browser'; Port = 1434; Protocol = 'UDP' }
            @{ Name = 'SQL Server DAC';     Port = 1434; Protocol = 'TCP' }
            @{ Name = 'SQL AG Endpoint';    Port = 5022; Protocol = 'TCP' }
        )
        foreach ($rule in $fwRules) {
            if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound `
                    -Protocol $rule.Protocol -LocalPort $rule.Port -Action Allow | Out-Null
            }
        }

        # Register SPNs (on gMSA if used, otherwise computer account)
        $computerName = $env:COMPUTERNAME
        $fqdn = "$computerName.$DomFQDN"
        $spnTarget = if ($DomNB -and $gMSA) { "$DomNB\$gMSA" } else { "$computerName`$" }
        foreach ($spn in @("MSSQLSvc/${fqdn}", "MSSQLSvc/${fqdn}:1433", "MSSQLSvc/${computerName}", "MSSQLSvc/${computerName}:1433")) {
            & setspn -s $spn $spnTarget 2>&1 | Out-Null
        }

        # Enable Always On (needed for AG later)
        Enable-SqlAlwaysOn -ServerInstance 'localhost' -Force -ErrorAction SilentlyContinue

        # Ensure services auto-start
        Set-Service -Name 'MSSQLSERVER' -StartupType Automatic
        Set-Service -Name 'SQLSERVERAGENT' -StartupType Automatic
        Start-Service -Name 'SQLSERVERAGENT' -ErrorAction SilentlyContinue

        # Restart SQL to apply protocol changes
        Restart-Service -Name 'MSSQLSERVER' -Force
        Start-Service -Name 'SQLSERVERAGENT' -ErrorAction SilentlyContinue

        Write-Host "SQL Server 2019 installed and configured."

    } -ArgumentList $MediaShare, $ConfigContent, $DomainFQDN, $DomainNetBIOS, $gMSAName

    Write-LabLog "SQL installed on $VMName." -Level SUCCESS -Step 'SQL'
}

# Build per-site configs with gMSA accounts
$SqlConfigA = $SqlConfigSCCMTemplate -replace '{{SQLSVCACCOUNT}}', 'SADAB\A-gMSA$' -replace '{{AGTSVCACCOUNT}}', 'SADAB\A-gMSA$'
$SqlConfigB = $SqlConfigSCCMTemplate -replace '{{SQLSVCACCOUNT}}', 'SADAB\B-gMSA$' -replace '{{AGTSVCACCOUNT}}', 'SADAB\B-gMSA$'

# Only install SQL on reachable VMs. B-SQLSCCM (Host B not yet built) and
# A-SQLSCOM (SCOM is Phase 2) are skipped automatically.
function Test-IPReachable($ip) {
    try { (New-Object System.Net.NetworkInformation.Ping).Send($ip, 1500).Status -eq 'Success' } catch { $false }
}

if (Test-IPReachable '10.10.0.4') {
    Install-SQLOnVM -IP '10.10.0.4'  -VMName 'A-SQLSCCM'  -MediaShare "$MediaShareA" -ConfigContent $SqlConfigA    -Credential $DomainCred -DomainFQDN $DomainName -DomainNetBIOS $NetBIOS -gMSAName 'A-gMSA'
} else { Write-LabLog 'A-SQLSCCM (10.10.0.4) unreachable - skipping' -Level WARN -Step 'SQL' }

if (Test-IPReachable '10.20.0.4') {
    Install-SQLOnVM -IP '10.20.0.4'  -VMName 'B-SQLSCCM'  -MediaShare "$MediaShareA" -ConfigContent $SqlConfigB    -Credential $DomainCred -DomainFQDN $DomainName -DomainNetBIOS $NetBIOS -gMSAName 'B-gMSA'
} else { Write-LabLog 'B-SQLSCCM (10.20.0.4) unreachable - skipping (Host B not yet built)' -Level WARN -Step 'SQL' }

if (Test-IPReachable '10.10.0.41') {
    Install-SQLOnVM -IP '10.10.0.41' -VMName 'A-SQLSCOM'  -MediaShare "$MediaShareA" -ConfigContent $SqlConfigSCOM -Credential $DomainCred -DomainFQDN $DomainName -DomainNetBIOS $NetBIOS
} else { Write-LabLog 'A-SQLSCOM (10.10.0.41) unreachable - skipping (Phase 2)' -Level WARN -Step 'SQL' }
