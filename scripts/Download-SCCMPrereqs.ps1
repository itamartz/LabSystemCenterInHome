<#
.SYNOPSIS
    Download all SCCM prerequisite binaries on Host A using setupdl.exe.
    Runs on the host (nested VMs have no internet) and outputs to the media share
    so A-SCCM setup can reference them locally.

.NOTES
    - Takes ~15-30 minutes depending on internet speed (~300-600 MB).
    - Run as a scheduled task to avoid blocking MCP.
    - Idempotent: skips if the output folder already contains files.

.EXAMPLE
    # Run directly (blocking)
    powershell -File C:\HyperV-Lab\scripts\Download-SCCMPrereqs.ps1

    # Run as scheduled task (non-blocking, preferred)
    schtasks /Create /TN "DownloadSCCMPrereqs" /TR "powershell -File C:\HyperV-Lab\scripts\Download-SCCMPrereqs.ps1" /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F
    schtasks /Run /TN "DownloadSCCMPrereqs"
#>
[CmdletBinding()]
param(
    [string]$SetupDl   = 'C:\HyperV-Lab\Media\SCCM\Extracted\SMSSETUP\BIN\X64\setupdl.exe',
    [string]$OutputDir = 'C:\HyperV-Lab\Media\SCCM\PreReq',
    [string]$LogFile   = 'C:\HyperV-Lab\download-sccm-prereqs.log'
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param($msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

Write-Log "=== Starting SCCM prereq download ==="
Write-Log "SetupDl:   $SetupDl"
Write-Log "OutputDir: $OutputDir"

if (-not (Test-Path $SetupDl)) {
    throw "setupdl.exe not found at: $SetupDl. Extract the SCCM ISO first."
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Log "Created output directory."
}

# Idempotency: skip if already populated
$existing = Get-ChildItem -Path $OutputDir -File -ErrorAction SilentlyContinue
if ($existing.Count -gt 20) {
    $sizeMB = [math]::Round(($existing | Measure-Object Length -Sum).Sum / 1MB, 1)
    Write-Log "SCCM prereqs already downloaded ($($existing.Count) files, $sizeMB MB) - skipping."
    Write-Log "Delete $OutputDir to force re-download."
    return
}

Write-Log "Running setupdl.exe /NOUI $OutputDir ..."
$p = Start-Process -FilePath $SetupDl `
    -ArgumentList "/NOUI `"$OutputDir`"" `
    -Wait -PassThru -NoNewWindow
Write-Log "setupdl.exe exited with code $($p.ExitCode)"

if ($p.ExitCode -ne 0) {
    throw "setupdl.exe failed: exit $($p.ExitCode). Check $OutputDir\ConfigMgrPrereq.log"
}

$final = Get-ChildItem -Path $OutputDir -File
$finalMB = [math]::Round(($final | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Log "Download complete: $($final.Count) files, $finalMB MB."
Write-Log "=== SCCM prereq download finished ==="
