<#
.SYNOPSIS
    Extend AD schema for SCCM. Run on VM directly.
    Must run as domain admin (Schema Admins membership required).
#>
$ErrorActionPreference = 'Stop'
$MediaShare = '\\10.10.0.1\LabMedia'

# Check if schema already extended
$schemaCheck = Get-ADObject -SearchBase "CN=Schema,CN=Configuration,DC=sadab,DC=pri" `
    -Filter "Name -eq 'MS-SMS-Site-Code'" -ErrorAction SilentlyContinue
if ($schemaCheck) {
    Write-Host 'AD schema already extended for SCCM - skipping.'
    return
}

$extender = Join-Path $MediaShare 'SCCM\SMSSETUP\BIN\X64\extadsch.exe'
if (-not (Test-Path $extender)) { throw "extadsch.exe not found: $extender" }

Write-Host 'Extending AD schema for SCCM...'
$result = Start-Process -FilePath $extender -Wait -PassThru -NoNewWindow
if ($result.ExitCode -ne 0) { throw "Schema extension failed: exit $($result.ExitCode)" }

# Verify
$logFile = "$env:SystemRoot\ExtADSch.log"
if (Test-Path $logFile) {
    $tail = Get-Content $logFile -Tail 5
    $tail | ForEach-Object { Write-Host $_ }
}
Write-Host 'AD schema extended.'
