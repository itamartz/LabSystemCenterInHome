<#
.SYNOPSIS
    Step 2: Install SCCM prereqs, ADK, ODBC on B-SCCM. Run on Host A.
    Note: Passive site server role is added later via cross-VM operation.
    Prereqs: B-SCCM domain-joined.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$DomainAdminPassword
)

. "$PSScriptRoot\PostDeployHelpers.ps1"

$creds      = New-LabCredentials -AdminPassword $DomainAdminPassword -DomainAdminPassword $DomainAdminPassword
$IP         = '10.20.0.3'
$MediaShare = '\\10.10.0.1\LabMedia'

# ── Install SCCM prerequisite features ────────────────────────────────────────
Write-LabLog 'Installing SCCM prerequisite features...' -Step 'B-SCCM'

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

# ── Install ODBC Driver 18 ───────────────────────────────────────────────────
Write-LabLog 'Installing ODBC Driver 18...' -Step 'B-SCCM'
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
Write-LabLog 'Installing Windows ADK...' -Step 'B-SCCM'
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -TimeoutSec 600 -ScriptBlock {
    param($Share)
    $adkSetup = Join-Path $Share 'ADK\adksetup.exe'
    $peSetup  = Join-Path $Share 'ADKPE\adkwinpesetup.exe'
    if (Test-Path $adkSetup) {
        Start-Process -FilePath $adkSetup `
            -ArgumentList '/quiet /norestart /features OptionId.DeploymentTools OptionId.UserStateMigrationTool OptionId.ImagingAndConfigurationDesigner' `
            -Wait -NoNewWindow
    }
    if (Test-Path $peSetup) {
        Start-Process -FilePath $peSetup `
            -ArgumentList '/quiet /norestart /features OptionId.WindowsPreinstallationEnvironment' `
            -Wait -NoNewWindow
    }
} -ArgumentList $MediaShare

Write-LabLog 'B-SCCM Step 2 complete.' -Level SUCCESS -Step 'B-SCCM'
