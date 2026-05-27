<#
.SYNOPSIS
    Installs all SCCM prerequisites on A-SCCM and B-SCCM.
    Installs ADK on A-SCCM, WSUS on MP-DP servers.
    Extends AD schema and creates the System Management container.
    Installs ODBC Driver 18 on SCCM servers.

.NOTES
    Author  : SADAB Lab
    Version : 2.0
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

$MediaShare  = $Global:LabConfig.MediaShareA

# Skip VMs that aren't built yet (Site B not in Phase 1). Ping-test before targeting.
function Test-IPReachable($ip) {
    try { (New-Object System.Net.NetworkInformation.Ping).Send($ip, 1500).Status -eq 'Success' } catch { $false }
}
$SccmVMs = @('10.10.0.3','10.20.0.3') | Where-Object { Test-IPReachable $_ }
# MP/DP roles are out of scope for the "SCCM Primary on A-SCCM only" goal.
# WSUS install on A-MPDP needs local SQL (not installed) — skip MP/DP prereqs entirely.
$MpDpVMs = @()
Write-LabLog "Reachable SCCM targets: $($SccmVMs -join ', ')" -Step 'SCCMPrereqs'
Write-LabLog "MP/DP targets: (skipped - out of Phase 1 goal scope)" -Step 'SCCMPrereqs'

$SccmFeatures = @(
    'NET-Framework-Core'
    'NET-Framework-45-Core'
    'NET-Framework-45-ASPNET'
    'NET-WCF-TCP-Activation45'
    'NET-WCF-HTTP-Activation45'
    'NET-WCF-TCP-PortSharing45'
    'RDC'
    'BITS'
    'BITS-IIS-Ext'
    'Web-Server'
    'Web-Common-Http'
    'Web-Default-Doc'
    'Web-Dir-Browsing'
    'Web-Http-Errors'
    'Web-Static-Content'
    'Web-Http-Redirect'
    'Web-Http-Logging'
    'Web-Log-Libraries'
    'Web-Request-Monitor'
    'Web-Http-Tracing'
    'Web-Stat-Compression'
    'Web-Filtering'
    'Web-Basic-Auth'
    'Web-Windows-Auth'
    'Web-Net-Ext'
    'Web-Net-Ext45'
    'Web-Asp-Net'
    'Web-Asp-Net45'
    'Web-ISAPI-Ext'
    'Web-ISAPI-Filter'
    'Web-Mgmt-Console'
    'Web-Mgmt-Compat'
    'Web-Metabase'
    'Web-Lgcy-Mgmt-Console'
    'Web-WMI'
    'Web-Scripting-Tools'
    'Web-Mgmt-Service'
    'RSAT-AD-Tools'
    'RSAT-AD-PowerShell'
    'FS-Data-Deduplication'
)

# ── Install features on SCCM servers ─────────────────────────────────────────
foreach ($ip in $SccmVMs) {
    Write-LabLog "Installing SCCM prerequisite features on $ip..." -Step 'SCCMPrereqs'
    Invoke-LabRemote -IPAddress $ip -Credential $DomainCred -TimeoutSec 600 -ScriptBlock {
        param($Features, $Share)

        # Install .NET 3.5 with SxS source if available
        $sxsPath = Join-Path $Share 'SxS'
        if (Test-Path $sxsPath) {
            Install-WindowsFeature NET-Framework-Core -Source $sxsPath -ErrorAction SilentlyContinue | Out-Null
        }

        Install-WindowsFeature $Features -IncludeManagementTools | Out-Null
    } -ArgumentList (,$SccmFeatures), $MediaShare
    Write-LabLog "Features installed on $ip." -Level SUCCESS -Step 'SCCMPrereqs'
}

# ── Install ODBC Driver 18 on SCCM servers (required by SCCM 2509+) ─────────
foreach ($ip in $SccmVMs) {
    Write-LabLog "Installing ODBC Driver 18 on $ip..." -Step 'ODBC18'
    Invoke-LabRemote -IPAddress $ip -Credential $DomainCred -ScriptBlock {
        param($Share)
        $odbcKey = 'HKLM:\SOFTWARE\Microsoft\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server'
        if (Test-Path $odbcKey) {
            Write-Host "ODBC Driver 18 already installed."
            return
        }
        $odbcMsi = Join-Path $Share 'ODBC18\msodbcsql18.msi'
        if (-not (Test-Path $odbcMsi)) { throw "ODBC 18 MSI not found: $odbcMsi" }
        $p = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList "/i `"$odbcMsi`" /quiet /norestart IACCEPTMSODBCSQLLICENSETERMS=YES" `
            -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -notin @(0, 3010)) { throw "ODBC 18 install failed: exit $($p.ExitCode)" }
        Write-Host "ODBC Driver 18 installed."
    } -ArgumentList $MediaShare
    Write-LabLog "ODBC 18 installed on $ip." -Level SUCCESS -Step 'ODBC18'
}

# ── Install ADK on A-SCCM ────────────────────────────────────────────────────
Write-LabLog 'Installing Windows ADK on A-SCCM...' -Step 'ADK'
Invoke-LabRemote -IPAddress '10.10.0.3' -Credential $DomainCred -TimeoutSec 600 -ScriptBlock {
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
Write-LabLog 'ADK installed on A-SCCM.' -Level SUCCESS -Step 'ADK'

# ── Install WSUS on MP-DP servers ─────────────────────────────────────────────
foreach ($ip in $MpDpVMs) {
    Write-LabLog "Installing WSUS on $ip..." -Step 'WSUS'
    Invoke-LabRemote -IPAddress $ip -Credential $DomainCred -TimeoutSec 600 -ScriptBlock {
        Install-WindowsFeature UpdateServices, UpdateServices-Services, UpdateServices-DB `
                               -IncludeManagementTools | Out-Null
        & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall SQL_INSTANCE_NAME=localhost CONTENT_DIR='C:\WSUS'
    }
    Write-LabLog "WSUS installed on $ip." -Level SUCCESS -Step 'WSUS'
}

# ── Extend AD schema for SCCM ────────────────────────────────────────────────
Write-LabLog 'Extending AD schema for SCCM...' -Step 'ADSchema'
Invoke-LabRemote -IPAddress '10.10.0.3' -Credential $DomainCred -ScriptBlock {
    param($Share)
    $extender = Join-Path $Share 'SCCM\SMSSETUP\BIN\X64\extadsch.exe'
    if (-not (Test-Path $extender)) { throw "extadsch.exe not found at: $extender" }
    $result = Start-Process -FilePath $extender -Wait -PassThru -NoNewWindow
    if ($result.ExitCode -ne 0) { throw "Schema extension failed: exit $($result.ExitCode)" }
} -ArgumentList $MediaShare
Write-LabLog 'AD schema extended.' -Level SUCCESS -Step 'ADSchema'

# ── Create System Management container ────────────────────────────────────────
Write-LabLog 'Creating System Management container in AD...' -Step 'SysManContainer'
Invoke-LabRemote -IPAddress '10.10.0.2' -Credential $DomainCred -ScriptBlock {
    Import-Module ActiveDirectory
    $PSDefaultParameterValues = @{ '*-AD*:Server' = 'localhost' }

    $systemContainerDN = 'CN=System,' + (Get-ADDomain).DistinguishedName
    $smContainerDN     = "CN=System Management,$systemContainerDN"

    if (-not (Get-ADObject -Filter "DistinguishedName -eq '$smContainerDN'" -ErrorAction SilentlyContinue)) {
        New-ADObject -Name 'System Management' -Type Container -Path $systemContainerDN
        Write-Host "Created System Management container at $smContainerDN"
    } else {
        Write-Host "System Management container already exists"
    }

    $sccmA    = Get-ADComputer 'A-SCCM'
    $acl      = Get-Acl "AD:$smContainerDN"
    $identity = [System.Security.Principal.SecurityIdentifier]$sccmA.SID
    $rule     = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $identity,
        [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
        [System.Security.AccessControl.AccessControlType]::Allow,
        [DirectoryServices.ActiveDirectorySecurityInheritance]::All
    )
    $acl.AddAccessRule($rule)
    Set-Acl "AD:$smContainerDN" $acl
}
Write-LabLog 'System Management container ready.' -Level SUCCESS -Step 'SysManContainer'
