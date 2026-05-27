$ErrorActionPreference = 'Stop'
$StoragePath = 'C:\HyperV-Lab'
$LogFile = "$StoragePath\download-labfiles.log"
$ParentVhdxPath = "$StoragePath\Base\WS2025-Eval.vhdx"
$MediaPath = "$StoragePath\Media"
$FilesPath = "$StoragePath\Files"
$DropboxUrl = 'https://www.dropbox.com/scl/fo/v4apolfdhoy68bsbox771/ADClA8fZTTJuc1Iq4lSCS4Y?rlkey=63zgx1alcuthas53xgoo89dst&dl=1'

function Write-Log {
    param($msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

Write-Log "=== Starting lab files download ==="

# Download
$zipPath = "$StoragePath\LabFiles.zip"
if (Test-Path $zipPath) {
    $existingSize = (Get-Item $zipPath).Length
    if ($existingSize -lt 1GB) {
        Write-Log "Existing zip too small ($([math]::Round($existingSize/1MB,1)) MB) - removing and re-downloading"
        Remove-Item $zipPath -Force
    } else {
        Write-Log "Zip already exists: $([math]::Round($existingSize/1MB,1)) MB - skipping download"
    }
}

if (-not (Test-Path $zipPath)) {
    Write-Log "Downloading from Dropbox (~20 GB)..."
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $DropboxUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 14400
        $dlSize = (Get-Item $zipPath).Length
        Write-Log "Download complete: $([math]::Round($dlSize/1MB,1)) MB"
    } catch {
        Write-Log "ERROR: Download failed: $_"
        throw
    }
}

# Extract
Write-Log "Extracting zip to $FilesPath ..."
if (-not (Test-Path $FilesPath)) { New-Item -ItemType Directory -Path $FilesPath -Force | Out-Null }
Expand-Archive -Path $zipPath -DestinationPath $FilesPath -Force
Write-Log "Extraction complete."

# Flatten Dropbox subfolder if needed (Dropbox zips often add a top-level folder)
$topItems = Get-ChildItem -Path $FilesPath
$topDirs = $topItems | Where-Object { $_.PSIsContainer }
if ($topDirs.Count -eq 1 -and (Test-Path "$($topDirs[0].FullName)\Base")) {
    $innerPath = $topDirs[0].FullName
    Write-Log "Flattening Dropbox subfolder: $($topDirs[0].Name)"
    $innerItems = Get-ChildItem -Path $innerPath
    foreach ($item in $innerItems) {
        $dest = Join-Path $FilesPath $item.Name
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Move-Item -Path $item.FullName -Destination $dest -Force
    }
    Remove-Item $innerPath -Force -ErrorAction SilentlyContinue
    Write-Log "Flatten complete."
}

Write-Log "Contents of FilesPath after extract:"
Get-ChildItem -Path $FilesPath | ForEach-Object {
    Write-Log "  $($_.Name)"
}

# Move VHDX to Base
$vhdxSrc = "$FilesPath\Base\WS2025-Eval.vhdx"
if (Test-Path $vhdxSrc) {
    $baseDir = Split-Path $ParentVhdxPath -Parent
    if (-not (Test-Path $baseDir)) { New-Item -ItemType Directory -Path $baseDir -Force | Out-Null }
    Write-Log "Moving VHDX to $ParentVhdxPath ..."
    Move-Item -Path $vhdxSrc -Destination $ParentVhdxPath -Force
    Write-Log "Validating VHDX..."
    Test-VHD -Path $ParentVhdxPath -ErrorAction Stop | Out-Null
    Set-ItemProperty -Path $ParentVhdxPath -Name IsReadOnly -Value $true
    Write-Log "VHDX staged and validated: $ParentVhdxPath ($([math]::Round((Get-Item $ParentVhdxPath).Length/1GB,2)) GB)"
} else {
    Write-Log "ERROR: VHDX not found at $vhdxSrc after extraction"
    Write-Log "Checking for VHDX elsewhere..."
    $found = Get-ChildItem -Path $FilesPath -Recurse -Filter '*.vhdx' -ErrorAction SilentlyContinue
    if ($found) {
        foreach ($f in $found) { Write-Log "  Found VHDX: $($f.FullName)" }
    } else {
        Write-Log "  No VHDX files found anywhere under $FilesPath"
    }
}

# Copy media folders
$mediaFolders = @('SQL', 'SCCM', 'SCOM', 'ADK', 'ADKPE', 'SSMS', 'SSRS', 'WebView2', 'ReportBuilder', 'ODBC18', 'SQLCLRTypes', 'Applications')
foreach ($folder in $mediaFolders) {
    $src = "$FilesPath\$folder"
    if (Test-Path $src) {
        $dst = "$MediaPath\$folder"
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        Copy-Item -Path "$src\*" -Destination $dst -Recurse -Force
        $itemCount = (Get-ChildItem -Path $dst -Recurse -File).Count
        Write-Log "Staged media: $folder ($itemCount files)"
    } else {
        Write-Log "WARNING: Media folder not found in extract: $folder"
    }
}

# Cleanup
Write-Log "Cleaning up..."
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $FilesPath -Recurse -Force -ErrorAction SilentlyContinue
Write-Log "=== DONE - All lab files staged successfully ==="
