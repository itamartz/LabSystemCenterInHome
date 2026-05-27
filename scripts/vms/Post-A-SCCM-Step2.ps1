<#
.SYNOPSIS
    Step 2: Install SCCM prereqs, ADK, ODBC, extend AD schema, install SCCM Primary Site PR1. Run on Host A.
    Prereqs: A-SCCM domain-joined, A-SQLSCCM with SQL installed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$DomainAdminPassword
)

. "$PSScriptRoot\PostDeployHelpers.ps1"

$creds      = New-LabCredentials -AdminPassword $DomainAdminPassword -DomainAdminPassword $DomainAdminPassword
$IP         = '10.10.0.3'
$MediaShare = '\\10.10.0.1\LabMedia'

# ── Install SCCM prerequisite features ────────────────────────────────────────
Write-LabLog 'Installing SCCM prerequisite features...' -Step 'A-SCCM'

# Site server only — no MP/DP/IIS needed (those go on MPDP VMs)
$SccmFeatures = @(
    'NET-Framework-Core','NET-Framework-45-Core','NET-Framework-45-ASPNET'
    'NET-WCF-TCP-Activation45','NET-WCF-HTTP-Activation45','NET-WCF-TCP-PortSharing45'
    'RDC'
    'RSAT-AD-Tools','RSAT-AD-PowerShell'
)

Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -TimeoutSec 600 -ScriptBlock {
    param($Features, $Share)
    $sxsPath = Join-Path $Share 'SxS'
    if (Test-Path $sxsPath) {
        Install-WindowsFeature NET-Framework-Core -Source $sxsPath -ErrorAction SilentlyContinue | Out-Null
    }
    Install-WindowsFeature $Features -IncludeManagementTools | Out-Null
} -ArgumentList (,$SccmFeatures), $MediaShare

Write-LabLog 'Features installed.' -Level SUCCESS -Step 'A-SCCM'

# ── Install ODBC Driver 18 ───────────────────────────────────────────────────
Write-LabLog 'Installing ODBC Driver 18...' -Step 'A-SCCM'
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -ScriptBlock {
    param($Share)
    $odbcKey = 'HKLM:\SOFTWARE\Microsoft\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server'
    if (Test-Path $odbcKey) { Write-Host 'ODBC 18 already installed.'; return }
    $odbcMsi = Join-Path $Share 'ODBC18\msodbcsql18.msi'
    if (-not (Test-Path $odbcMsi)) { throw "ODBC 18 MSI not found: $odbcMsi" }
    $p = Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList "/i `"$odbcMsi`" /quiet /norestart IACCEPTMSODBCSQLLICENSETERMS=YES" `
        -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -notin @(0, 3010)) { throw "ODBC 18 install failed: exit $($p.ExitCode)" }
} -ArgumentList $MediaShare

# ── Install Windows ADK ──────────────────────────────────────────────────────
Write-LabLog 'Installing Windows ADK...' -Step 'A-SCCM'
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -TimeoutSec 600 -ScriptBlock {
    param($Share)
    $adkSetup = Join-Path $Share 'ADK\adksetup.exe'
    $peSetup  = Join-Path $Share 'ADKPE\adkwinpesetup.exe'
    if (-not (Test-Path $adkSetup)) { throw "ADK setup not found: $adkSetup" }

    Start-Process -FilePath $adkSetup `
        -ArgumentList '/quiet /norestart /features OptionId.DeploymentTools OptionId.UserStateMigrationTool OptionId.ImagingAndConfigurationDesigner' `
        -Wait -NoNewWindow
    if (Test-Path $peSetup) {
        Start-Process -FilePath $peSetup `
            -ArgumentList '/quiet /norestart /features OptionId.WindowsPreinstallationEnvironment' `
            -Wait -NoNewWindow
    }
} -ArgumentList $MediaShare

# ── Extend AD schema for SCCM ───────────────────────────────────────────────
Write-LabLog 'Extending AD schema...' -Step 'A-SCCM'
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -ScriptBlock {
    param($Share)
    $extender = Join-Path $Share 'SCCM\SMSSETUP\BIN\X64\extadsch.exe'
    if (-not (Test-Path $extender)) { throw "extadsch.exe not found: $extender" }
    $result = Start-Process -FilePath $extender -Wait -PassThru -NoNewWindow
    if ($result.ExitCode -ne 0) { throw "Schema extension failed: exit $($result.ExitCode)" }
} -ArgumentList $MediaShare

# ── Install SCCM Primary Site PR1 ───────────────────────────────────────────
Write-LabLog 'Installing SCCM Primary Site PR1 (45-90 min)...' -Step 'A-SCCM'

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

# Stage INI and download prereqs
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -ScriptBlock {
    param($Share, $IniContent)
    Set-Content -Path 'C:\SCCMSetup.ini' -Value $IniContent -Encoding Ascii
    New-Item -ItemType Directory -Path 'C:\SCCMPrereqs' -Force | Out-Null
    $setupExe = Join-Path $Share 'SCCM\SMSSETUP\BIN\X64\setup.exe'
    if (-not (Test-Path $setupExe)) { throw "SCCM setup.exe not found: $setupExe" }
    Start-Process -FilePath $setupExe -ArgumentList '/DOWNLOAD C:\SCCMPrereqs' -Wait -NoNewWindow
} -ArgumentList $MediaShare, $SetupIni

# Run setup via scheduled task (avoids WinRM timeout)
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -ScriptBlock {
    param($Share, $DomUser, $DomPass)
    $setupExe  = Join-Path $Share 'SCCM\SMSSETUP\BIN\X64\setup.exe'
    $batchFile = 'C:\tmp\run-sccm-setup.cmd'
    New-Item -ItemType Directory -Path 'C:\tmp' -Force | Out-Null
    Set-Content -Path $batchFile -Value @"
"$setupExe" /SCRIPT "C:\SCCMSetup.ini" /NOUSERINPUT
echo %ERRORLEVEL% > "C:\tmp\sccm-setup-result.txt"
"@ -Encoding Ascii
    schtasks /Create /TN "SCCMSetup" /TR $batchFile /SC ONCE /ST 00:00 /RU $DomUser /RP $DomPass /RL HIGHEST /F
    schtasks /Run /TN "SCCMSetup"
    Start-Sleep -Seconds 10
    schtasks /Delete /TN "SCCMSetup" /F 2>$null | Out-Null
} -ArgumentList $MediaShare, $creds.Domain.UserName, $creds.Domain.GetNetworkCredential().Password

# Poll for completion
$maxWait = 5400; $elapsed = 0; $interval = 60
while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds $interval; $elapsed += $interval
    $status = Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -ScriptBlock {
        $result = @{ Complete = $false; Failed = $false; LastLine = '' }
        $setupLog = 'C:\ConfigMgrSetup.log'
        if (Test-Path $setupLog) {
            $tail = Get-Content $setupLog -Tail 10 -ErrorAction SilentlyContinue | Out-String
            $result.LastLine = (Get-Content $setupLog -Tail 1 -ErrorAction SilentlyContinue)
            if ($tail -match 'Setup has completed') { $result.Complete = $true }
            if ($tail -match 'FATAL ERROR|Setup failed|Failed Configuration Manager Server Setup') { $result.Failed = $true }
        }
        $svc = Get-Service -Name 'SMS_Executive' -ErrorAction SilentlyContinue
        if ($svc -and ($svc.Status -eq 'Running')) { $result.Complete = $true }
        return $result
    }
    if ($status.Failed) { throw 'SCCM setup failed. Check C:\ConfigMgrSetup.log on A-SCCM.' }
    if ($status.Complete) { break }
    if ($elapsed % 300 -eq 0) {
        Write-LabLog "SCCM setup running ($([math]::Round($elapsed/60)) min)... $($status.LastLine)" -Step 'A-SCCM'
    }
}
if ($elapsed -ge $maxWait) { throw 'SCCM setup timed out after 90 minutes.' }

Write-LabLog 'A-SCCM Step 2 complete.' -Level SUCCESS -Step 'A-SCCM'
