<#
.SYNOPSIS
    Downloads and imports every management pack that's relevant to the SADAB
    lab environment (AD DS, AD CS, DNS, SQL Server, SSRS, IIS, WSUS, MSDTC,
    Windows Defender). The Windows Server OS MP family (script 16) is the
    prerequisite for almost every one of these.

.NOTES
    Must run ON HOST B (uses Hyper-V direct PowerShell to B-SCOMMS).

    DSC-style (per the "SCOM Configuration Convention" in CLAUDE.md):
    For each MP family, Test (`Get-SCOMManagementPack | Where Name -like ...`)
    decides whether to download + install + import. Per-MP Import-SCOMManagementPack
    handles dependency order (batch with one-by-one retry fallback).

    Why URLs are hardcoded: the Microsoft Download Center stopped exposing
    direct download.microsoft.com URLs in raw HTML; resolving them requires
    a JS-aware browser. The URLs below were captured by browser automation
    on 2026-06-01 and HEAD-verified. If a URL goes stale, refresh it via the
    same browser-automation approach (navigate the details.aspx page and walk
    the React fiber tree for downloads), or - failing that - download the
    MSI manually from the download details.aspx page and drop it into
    C:\HyperV-Lab-Local\MPs-Download\ on B-SCOMMS (the script picks it up).

    Not included (gaps documented):
    - SCCM Configuration Manager MP: the legacy id=34709 page was removed
      from MS Download Center (returns 404). SCCM Current Branch 2509 doesn't
      ship a SCOM MP either. The A-SCCM site server still gets monitored via
      the Windows Server OS + IIS + SQL (CM_PR1 DB on A-SQLSCCM) + WSUS MPs.
    - MSDTC MP (id=54271): the MP itself imports with "The requested management
      pack is not valid" on SCOM 2025 (unresolved dependency on its 10.0.0.1
      build). And the lab doesn't actually exercise MSDTC - SCCM CB and SQL AG
      don't use it - so the dedicated MP would add no real coverage. The MSDTC
      *service* still gets baseline state monitoring via the Windows Server OS MP.
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SCOMMS',
    [string]$DomainAdminPassword = 'LabAdmin@2026!'
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][MPs] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

Write-Stage "Reconciling relevant MPs on $VMName ..."

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {

    $downloadRoot = 'C:\HyperV-Lab-Local\MPs-Download'   # MSI downloads (per-VM, NOT on share - keeps copies local)
    if (-not (Test-Path $downloadRoot)) { New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null }

    $extractRoot = 'C:\Program Files (x86)\System Center Management Packs'

    # ---------------------- DSC-style helpers ----------------------
    function Test-MpFamilyImported {
        param([string[]]$NamePatterns)
        $mps = Get-SCOMManagementPack
        foreach ($p in $NamePatterns) {
            if ($mps | Where-Object { $_.Name -like $p }) { return $true }
        }
        return $false
    }
    function Set-MpFamilyImported {
        param(
            [string]$Slug,
            [string]$DownloadUrl,
            [string]$MsiTargetName,
            [string]$ExpectedDirName       # substring/wildcard of the dir name the MSI creates
        )
        $msiDest = Join-Path $downloadRoot $MsiTargetName
        if (-not (Test-Path $msiDest)) {
            Write-Host "  download: $DownloadUrl"
            $ProgressPreference = 'SilentlyContinue'
            Start-BitsTransfer -Source $DownloadUrl -Destination $msiDest -ErrorAction Stop
            Write-Host "  saved: $msiDest ($([math]::Round((Get-Item $msiDest).Length/1MB,2)) MB)"
        } else {
            Write-Host "  download: already on disk ($msiDest)"
        }

        $installStart = Get-Date
        Write-Host "  msiexec install: $msiDest"
        $logFile = "$env:TEMP\$Slug-install.log"
        $p = Start-Process -FilePath 'msiexec.exe' `
                           -ArgumentList @('/i', "`"$msiDest`"", '/qn', '/norestart', '/L*v', "`"$logFile`"") `
                           -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -notin @(0, 3010)) {
            Get-Content $logFile -Tail 50 | ForEach-Object { Write-Host "    $_" }
            throw "msiexec failed for $MsiTargetName : exit $($p.ExitCode)"
        }

        # Find this MP's install dir by name pattern, with last-write-time as a
        # tiebreaker. The previous "snapshot dirs before, diff after" approach
        # fell back to the most-recently-touched dir, which would be a *prior*
        # MP's dir on a re-run after a partial failure - causing the script to
        # then re-import the wrong MP's files.
        $candidates = Get-ChildItem $extractRoot -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "*$ExpectedDirName*" }
        if (-not $candidates) {
            throw "No install dir matching '*$ExpectedDirName*' found under $extractRoot (msiexec exit was $($p.ExitCode))"
        }
        # If multiple candidates match (rare), prefer ones modified during this install.
        $touched = $candidates | Where-Object { $_.LastWriteTime -ge $installStart.AddSeconds(-5) }
        $newDirs = if ($touched) { $touched } else { $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
        Write-Host "  install dir: $($newDirs.FullName -join ', ')"
        # RECURSIVE - some MPs (SQL 7.12, SSRS 7.8) put .mp/.mpb in a version
        # subfolder like 'Microsoft System Center MP for SQL Server on Windows\7.12.1619\'.
        $mpFiles = $newDirs | ForEach-Object { Get-ChildItem $_.FullName -File -Recurse -ErrorAction SilentlyContinue } |
                   Where-Object { $_.Extension -in '.mp', '.mpb' }
        if (-not $mpFiles) { throw "No .mp/.mpb files under: $($newDirs.FullName -join ', ')" }

        Write-Host "  import: $($mpFiles.Count) MP files"
        try {
            Import-SCOMManagementPack -FullName $mpFiles.FullName -ErrorAction Stop
            Write-Host "  imported in one batch"
        } catch {
            Write-Host "  batch failed - one-by-one with retries" -ForegroundColor Yellow
            $remaining = [System.Collections.ArrayList]@($mpFiles)
            for ($pass = 1; $pass -le 6 -and $remaining.Count -gt 0; $pass++) {
                $still = @()
                foreach ($f in $remaining) {
                    try {
                        Import-SCOMManagementPack -FullName $f.FullName -ErrorAction Stop
                        Write-Host "    [pass $pass] $($f.Name)"
                    } catch {
                        if ($pass -eq 6) {
                            $inner = $_.Exception.InnerException
                            $msg = if ($inner) { "$($_.Exception.Message) / inner: $($inner.Message)" } else { $_.Exception.Message }
                            Write-Host "      $($f.Name) -> $msg" -ForegroundColor Yellow
                        }
                        $still += $f
                    }
                }
                $remaining = $still
            }
            if ($remaining.Count) {
                Write-Host "  could not import:" -ForegroundColor Yellow
                $remaining | ForEach-Object { Write-Host "    $($_.Name)" }
            }
        }
    }

    Import-Module OperationsManager -ErrorAction Stop
    New-SCOMManagementGroupConnection -ComputerName 'B-SCOMMS.sadab.pri' | Out-Null

    # ---------------------- the MP catalogue ----------------------
    # URLs verified live on 2026-06-01. NamePatterns are -like wildcards used in Test.
    $mpCatalog = @(
        [PSCustomObject]@{
            Slug            = 'ADDS-2016-Plus'
            DownloadUrl     = 'https://download.microsoft.com/download/A/5/E/A5E87602-FA1F-45EE-A1AE-CF55294934C1/Microsoft System Center Management Pack for ADDS.msi'
            MsiTargetName   = 'SCMP-ADDS-2016-Plus.msi'
            ExpectedDirName = 'ADDS'
            NamePatterns    = @('Microsoft.Windows.Server.AD.*', 'Microsoft.Windows.Server.ADDS*')
            Reason          = 'A-DC AD DS monitoring'
        }
        [PSCustomObject]@{
            Slug            = 'ADCS-2016-Plus'
            DownloadUrl     = 'https://download.microsoft.com/download/2/5/6/2568934E-788D-47D1-A830-46A7A3A77DA3/Microsoft System Center Management Pack for AD CS.msi'
            MsiTargetName   = 'SCMP-ADCS-2016-Plus.msi'
            ExpectedDirName = 'AD CS'
            NamePatterns    = @('Microsoft.Windows.CertificateServices*', 'Microsoft.Windows.Server.ADCS*')
            Reason          = 'A-DC SADAB-Root-CA'
        }
        [PSCustomObject]@{
            Slug            = 'DNS-2016-Plus'
            DownloadUrl     = 'https://download.microsoft.com/download/0/1/A/01ACE577-201D-4D17-98CD-3A3F093F0C49/Microsoft System Center MP for DNS 2016 and 1709 Plus.msi'
            MsiTargetName   = 'SCMP-DNS-2016-Plus.msi'
            ExpectedDirName = 'DNS 2016'
            NamePatterns    = @('Microsoft.Windows.DNSServer*', 'Microsoft.Windows.Server.DNS.*')
            Reason          = 'A-DC DNS'
        }
        [PSCustomObject]@{
            Slug            = 'SQL-Server-Generic-Windows'
            DownloadUrl     = 'https://download.microsoft.com/download/08241789-5147-4047-bfae-ef97b00c4bab/SQLServerMP.Windows.msi'
            MsiTargetName   = 'SCMP-SQLServer-Windows.msi'
            ExpectedDirName = 'SQL Server on Windows'
            NamePatterns    = @('Microsoft.SQLServer.Core.*', 'Microsoft.SQLServer.Windows.*', 'Microsoft.SQLServer.Visualization.*')
            Reason          = 'A-SQLSCCM + B-SQLSCOM (SQL 2019 on Windows)'
        }
        [PSCustomObject]@{
            Slug            = 'SSRS-Generic'
            DownloadUrl     = 'https://download.microsoft.com/download/a/1/6/a16c66cf-b841-43bb-85ef-d28b695bd7a6/20250121_SSRS_RTM_7.8.3/Microsoft.SQLServer.ReportingServices.ManagementPack.msi'
            MsiTargetName   = 'SCMP-SSRS-Generic.msi'
            ExpectedDirName = 'SQL Server Reporting Services'
            NamePatterns    = @('Microsoft.SQLServer.ReportingServices*', 'Microsoft.SQLServer.RS*')
            Reason          = 'A-SCCM SSRS (RSP)'
        }
        [PSCustomObject]@{
            Slug            = 'IIS-2016-Plus'
            DownloadUrl     = 'https://download.microsoft.com/download/4/9/A/49A9DD6B-3ECC-46DD-9115-9DB60C052DA7/Microsoft System Center MP for IIS 2016 and 1709 Plus.msi'
            MsiTargetName   = 'SCMP-IIS-2016-Plus.msi'
            ExpectedDirName = 'IIS 2016'
            NamePatterns    = @('Microsoft.Windows.InternetInformationServices.*', 'Microsoft.Windows.IIS.*')
            Reason          = 'A-MPDP / A-SCCM / B-MPDP IIS'
        }
        [PSCustomObject]@{
            Slug            = 'WSUS-2016'
            DownloadUrl     = 'https://download.microsoft.com/download/F/5/4/F54B3501-9A61-422B-BE6B-07155231A6D8/Microsoft System Center 2016 Management Pack for WSUS.msi'
            MsiTargetName   = 'SCMP-WSUS-2016.msi'
            ExpectedDirName = 'WSUS'
            NamePatterns    = @('Microsoft.Windows.Server.UpdateServices*', 'Microsoft.WindowsServerUpdateServices*', 'Microsoft.Windows.WSUS*', 'Microsoft.SystemCenter.WSUS*')
            Reason          = 'A-MPDP WSUS'
        }
        # MSDTC MP (id=54271) intentionally NOT in the catalogue:
        # - SADAB doesn't exercise distributed transactions (SCCM CB doesn't
        #   heavily use MSDTC; SQL AG uses its own sync, not MSDTC).
        # - The MSDTC MP itself ("not valid" on import in SCOM 2025) appears
        #   to be missing/mismatched dependencies on 2025 - keeping it out
        #   avoids a documented import error in every run.
        # - The MSDTC *service* still gets baseline service-state monitoring
        #   via the Windows Server OS MP.
        [PSCustomObject]@{
            Slug            = 'Defender'
            DownloadUrl     = 'https://download.microsoft.com/download/A/1/3/A1395129-1E4D-4332-AB15-665371C9E40C/System Center 2016 Management Pack for Windows Defender.msi'
            MsiTargetName   = 'SCMP-Defender.msi'
            ExpectedDirName = 'Windows Defender'
            NamePatterns    = @('Microsoft.WindowsDefender', 'Microsoft.WindowsDefender.*', 'Microsoft.Antimalware*')
            Reason          = 'Windows Defender on all servers'
        }
    )

    foreach ($mp in $mpCatalog) {
        Write-Host ("`n=== {0} ({1}) ===" -f $mp.Slug, $mp.Reason) -ForegroundColor Cyan
        if (Test-MpFamilyImported -NamePatterns $mp.NamePatterns) {
            Write-Host "  [TEST PASS] family already imported - no action"
        } else {
            Write-Host "  [SET]       installing family..."
            try {
                Set-MpFamilyImported -Slug $mp.Slug -DownloadUrl $mp.DownloadUrl -MsiTargetName $mp.MsiTargetName -ExpectedDirName $mp.ExpectedDirName
                if (Test-MpFamilyImported -NamePatterns $mp.NamePatterns) {
                    Write-Host "  [RE-TEST]   PASS"
                } else {
                    Write-Host "  [RE-TEST]   FAIL - imported MPs do not match expected patterns" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  [SET FAIL]  $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    # ---------------------- summary ----------------------
    Write-Host "`n=== Imported MP families (summary) ===" -ForegroundColor Cyan
    Get-SCOMManagementPack |
        Where-Object {
            $_.Name -match 'Windows\.Server\.(AD|UpdateServices)|CertificateServices|DNSServer|SQLServer|InternetInformationServices|WindowsDefender|Antimalware'
        } |
        Sort-Object Name |
        Select-Object Name, Version, Sealed |
        Format-Table -AutoSize | Out-String | Write-Host
}

Write-Stage "Done."
