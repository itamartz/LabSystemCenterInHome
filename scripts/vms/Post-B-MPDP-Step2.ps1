<#
.SYNOPSIS
    Step 2: Install SCCM prereqs and WSUS on B-MPDP. Run on Host A.
    Note: MP/DP/SUP roles are added later from A-SCCM console (cross-VM operation).
    Prereqs: B-MPDP domain-joined.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$DomainAdminPassword
)

. "$PSScriptRoot\PostDeployHelpers.ps1"

$creds = New-LabCredentials -AdminPassword $DomainAdminPassword -DomainAdminPassword $DomainAdminPassword
$IP    = '10.20.0.5'

# ── Install SCCM prerequisite features ────────────────────────────────────────
Write-LabLog 'Installing SCCM prerequisite features...' -Step 'B-MPDP'

$SccmFeatures = @(
    'NET-Framework-Core','NET-Framework-45-Core','NET-Framework-45-ASPNET'
    'NET-WCF-TCP-Activation45','NET-WCF-HTTP-Activation45','NET-WCF-TCP-PortSharing45'
    'RDC','BITS','BITS-IIS-Ext'
    'Web-Server','Web-Common-Http','Web-Default-Doc','Web-Dir-Browsing','Web-Http-Errors'
    'Web-Static-Content','Web-Http-Redirect','Web-Http-Logging','Web-Log-Libraries'
    'Web-Request-Monitor','Web-Http-Tracing','Web-Stat-Compression','Web-Filtering'
    'Web-Basic-Auth','Web-Windows-Auth','Web-Net-Ext','Web-Net-Ext45'
    'Web-Asp-Net','Web-Asp-Net45','Web-ISAPI-Ext','Web-ISAPI-Filter'
    'Web-Mgmt-Console','Web-Mgmt-Compat','Web-Metabase','Web-Lgcy-Mgmt-Console'
    'Web-WMI','Web-Scripting-Tools','Web-Mgmt-Service'
    'RSAT-AD-Tools','RSAT-AD-PowerShell','FS-Data-Deduplication'
)

Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -TimeoutSec 600 -ScriptBlock {
    param($Features, $Share)
    $sxsPath = Join-Path $Share 'SxS'
    if (Test-Path $sxsPath) {
        Install-WindowsFeature NET-Framework-Core -Source $sxsPath -ErrorAction SilentlyContinue | Out-Null
    }
    Install-WindowsFeature $Features -IncludeManagementTools | Out-Null
} -ArgumentList (,$SccmFeatures), '\\10.10.0.1\LabMedia'

# ── Install WSUS ─────────────────────────────────────────────────────────────
Write-LabLog 'Installing WSUS...' -Step 'B-MPDP'
Invoke-LabRemote -IPAddress $IP -Credential $creds.Domain -TimeoutSec 600 -ScriptBlock {
    Install-WindowsFeature UpdateServices, UpdateServices-Services, UpdateServices-DB `
                           -IncludeManagementTools | Out-Null
    & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall SQL_INSTANCE_NAME=localhost CONTENT_DIR='C:\WSUS'
}

Write-LabLog 'B-MPDP Step 2 complete.' -Level SUCCESS -Step 'B-MPDP'
