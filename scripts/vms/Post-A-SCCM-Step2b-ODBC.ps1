<#
.SYNOPSIS
    Install ODBC Driver 18 for SQL Server on A-SCCM. Run on VM directly.
#>
$ErrorActionPreference = 'Stop'
$MediaShare = '\\10.10.0.1\LabMedia'

$odbcKey = 'HKLM:\SOFTWARE\Microsoft\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server'
if (Test-Path $odbcKey) {
    Write-Host 'ODBC 18 already installed - skipping.'
    return
}

$odbcMsi = Join-Path $MediaShare 'ODBC18\msodbcsql18.msi'
if (-not (Test-Path $odbcMsi)) { throw "ODBC 18 MSI not found: $odbcMsi" }

Write-Host "Installing ODBC 18 from $odbcMsi..."
$p = Start-Process -FilePath 'msiexec.exe' `
    -ArgumentList "/i `"$odbcMsi`" /quiet /norestart IACCEPTMSODBCSQLLICENSETERMS=YES" `
    -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin @(0, 3010)) { throw "ODBC 18 install failed: exit $($p.ExitCode)" }
Write-Host 'ODBC 18 installed.'
