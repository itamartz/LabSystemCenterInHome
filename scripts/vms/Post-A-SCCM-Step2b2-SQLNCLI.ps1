<#
.SYNOPSIS
    Install SQL Server 2012 Native Client (SQLNCLI11) on A-SCCM. Run on VM directly.
#>
$ErrorActionPreference = 'Stop'
$MediaShare = '\\10.10.0.1\LabMedia'

$ncliKey = 'HKLM:\SOFTWARE\Microsoft\SQLNCLI11'
if (Test-Path $ncliKey) {
    Write-Host 'SQL Server Native Client 11 already installed - skipping.'
    return
}

$ncliMsi = Join-Path $MediaShare 'SQLNCLI\sqlncli.msi'
if (-not (Test-Path $ncliMsi)) { throw "SQLNCLI MSI not found: $ncliMsi" }

Write-Host "Installing SQL Server Native Client from $ncliMsi..."
$p = Start-Process -FilePath 'msiexec.exe' `
    -ArgumentList "/i `"$ncliMsi`" /qn /norestart IACCEPTSQLNCLILICENSETERMS=YES" `
    -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "SQLNCLI install failed: exit $($p.ExitCode)" }
Write-Host 'SQL Server Native Client installed.'
