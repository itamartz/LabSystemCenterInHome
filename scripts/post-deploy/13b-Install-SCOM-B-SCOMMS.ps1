<#
.SYNOPSIS
    Installs SCOM 2025 Management Server on B-SCOMMS, using B-SQLSCOM for the
    OperationsManager + OperationsManagerDW databases.
    Must run ON HOST B (uses Hyper-V direct to the VM).

.NOTES
    Adapted from scripts/post-deploy/13-Install-SCOM.ps1 (A-side version).
    SCOM media is expected at \\10.20.0.1\LabMedia\SCOM\extracted\Setup.exe
    (copied + extracted from the user's Dropbox SCOM_2025.zip).
    Single-account simplification: SADAB\Administrator for Action/DAS/Reader/Writer.
    Mgmt group name from lab-config.json (defaults to LAB-SCOM-MG).
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SCOMMS',
    [string]$SqlServer           = 'B-SQLSCOM',
    [string]$MediaShare          = '\\10.20.0.1\LabMedia',
    [string]$DomainAdminPassword = 'LabAdmin@2026!',
    [string]$MgmtGroup           = 'LAB-SCOM-MG'
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][SCOM-B-SCOMMS] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

# ----------------------------------------------------------------------------
# 1. Install Windows feature prereqs + VC++ Redist on B-SCOMMS
# ----------------------------------------------------------------------------
Write-Stage "Installing Windows feature prereqs on $VMName..."
Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    param($Share, $AdminPassword)
    cmdkey /add:10.20.0.1 /user:labadmin /pass:$AdminPassword | Out-Null

    # NET-Framework-Core is 3.5; needs -Source pointing at WS2025 SxS payload
    $features = @(
        'NET-Framework-45-Core',
        'Web-Server',
        'Web-Asp-Net45',
        'Web-Windows-Auth',
        'Web-Mgmt-Console',
        'Web-Mgmt-Compat'
    )
    $needed = $features | Where-Object { (Get-WindowsFeature -Name $_).Installed -eq $false }
    if ($needed) {
        Write-Host "Installing: $($needed -join ', ')"
        Install-WindowsFeature -Name $needed -IncludeManagementTools | Out-Null
    } else { Write-Host "All required Windows features already installed." }

    # VC++ Redist x64 (SCOM setup needs it)
    $vc = Get-ChildItem "$Share\VCRedist" -Filter 'vc_redist.x64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vc) {
        $installed = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Microsoft Visual C++ 2015*x64*' -or $_.DisplayName -like 'Microsoft Visual C++ 2017*x64*' -or $_.DisplayName -like 'Microsoft Visual C++ 20*Redistributable*x64*' }
        if (-not $installed) {
            Write-Host "Installing VC++ Redist x64..."
            $p = Start-Process -FilePath $vc.FullName -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru -NoNewWindow
            Write-Host "VC Redist exit code: $($p.ExitCode)"
        } else { Write-Host "VC++ Redist x64 already installed." }
    }
} -ArgumentList $MediaShare, $DomainAdminPassword

# ----------------------------------------------------------------------------
# 2. Add SADAB\Administrator as sysadmin on B-SQLSCOM (lab uses single account)
# ----------------------------------------------------------------------------
Write-Stage "Ensuring SADAB\Administrator has sysadmin on $SqlServer (should already from SQL install config)..."
Invoke-Command -VMName 'B-SQLSCOM' -Credential $cred -ScriptBlock {
    Add-Type -AssemblyName System.Data
    $conn = New-Object System.Data.SqlClient.SqlConnection 'Server=localhost;Integrated Security=true;Encrypt=false'
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='SADAB\Administrator') CREATE LOGIN [SADAB\Administrator] FROM WINDOWS; EXEC sp_addsrvrolemember 'SADAB\Administrator','sysadmin';"
    $cmd.ExecuteNonQuery() | Out-Null
    $conn.Close()
    "SQL login + sysadmin OK"
}

# ----------------------------------------------------------------------------
# 3. Run SCOM 2025 Management Server silent install
# ----------------------------------------------------------------------------
Write-Stage "Running SCOM 2025 Management Server install on $VMName (this takes 20-40 min)..."
$installResult = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    param($Share, $MgmtGroup, $Sql, $DomCred, $AdminPassword)

    # Idempotency: already installed?
    if (Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue) {
        Write-Host "HealthService present - SCOM appears installed. Skipping."
        return 0
    }

    # Make sure SMB cred is cached for the share
    cmdkey /add:10.20.0.1 /user:labadmin /pass:$AdminPassword | Out-Null

    $setupExe = Join-Path $Share 'SCOM\extracted\Setup.exe'
    if (-not (Test-Path $setupExe)) { throw "SCOM setup.exe not found: $setupExe" }

    $user = $DomCred.UserName
    $pwd  = $DomCred.GetNetworkCredential().Password

    # SCOM 2025 syntax: /install /components:OMServer (the older
    # `/install:ManagementServer` form silently fails with
    # "Invalid command line switches - no components switch found" / 0x80004005.
    $scomArgs = @(
        '/silent'
        '/install'
        '/components:OMServer'
        "/ManagementGroupName:$MgmtGroup"
        '/InstallPath:C:\Program Files\Microsoft System Center\Operations Manager'
        "/SqlServerInstance:$Sql"
        '/DatabaseName:OperationsManager'
        "/DWSqlServerInstance:$Sql"
        '/DWDatabaseName:OperationsManagerDW'
        "/ActionAccountUser:$user"
        "/ActionAccountPassword:$pwd"
        "/DASAccountUser:$user"
        "/DASAccountPassword:$pwd"
        "/DataReaderUser:$user"
        "/DataReaderPassword:$pwd"
        "/DataWriterUser:$user"
        "/DataWriterPassword:$pwd"
        '/AcceptEndUserLicenseAgreement:1'
        '/EnableErrorReporting:Never'
        '/SendCEIPReports:0'
        '/UseMicrosoftUpdate:0'
    )

    Write-Host "Setup.exe args (passwords masked): $((($scomArgs | ForEach-Object { if ($_ -match 'Password|/silent|Account|Reader|Writer') { '<MASKED>' } else { $_ } }) -join ' '))"

    $proc = Start-Process -FilePath $setupExe -ArgumentList $scomArgs `
                          -Wait -PassThru -NoNewWindow `
                          -RedirectStandardOutput 'C:\scom-setup.out' `
                          -RedirectStandardError 'C:\scom-setup.err'
    Write-Host "Setup exit code: $($proc.ExitCode)"
    if (Test-Path 'C:\scom-setup.out') {
        $out = Get-Content 'C:\scom-setup.out' -Tail 50 -ErrorAction SilentlyContinue
        if ($out) { Write-Host "--- setup stdout tail ---"; $out | ForEach-Object { Write-Host "  $_" } }
    }
    if (Test-Path 'C:\scom-setup.err') {
        $err = Get-Content 'C:\scom-setup.err' -ErrorAction SilentlyContinue
        if ($err) { Write-Host "--- setup stderr ---"; $err | ForEach-Object { Write-Host "  $_" } }
    }
    return $proc.ExitCode
} -ArgumentList $MediaShare, $MgmtGroup, $SqlServer, $cred, $DomainAdminPassword

Write-Stage "SCOM setup completed with exit code: $installResult"

# ----------------------------------------------------------------------------
# 4. Verify HealthService running and Mgmt Group registered
# ----------------------------------------------------------------------------
Write-Stage "Verifying SCOM..."
Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    "=== SCOM-related services ==="
    Get-Service -Name HealthService, 'OMSDK', 'cshost', 'System Center Management Configuration' `
        -ErrorAction SilentlyContinue |
        Format-Table Name, Status, StartType -AutoSize | Out-String

    "=== SCOM install path ==="
    $sp = 'C:\Program Files\Microsoft System Center\Operations Manager\Server'
    if (Test-Path $sp) { Get-ChildItem $sp -Filter '*.exe' | Select-Object -First 5 Name | Format-Table -AutoSize | Out-String }
    else { "Install path not present yet" }

    "=== Operations Manager PowerShell module + Mgmt Group ==="
    try {
        Import-Module OperationsManager -ErrorAction Stop
        $mg = Get-SCOMManagementGroup -ErrorAction Stop
        "Management Group: $($mg.Name)   ID: $($mg.Id)"
        $ms = Get-SCOMManagementServer -ErrorAction Stop
        $ms | Select-Object Name, IsRootManagementServer, HealthState, IsGateway | Format-List | Out-String
    } catch { "PowerShell verify failed: $($_.Exception.Message)" }
}

Write-Stage "Done."
