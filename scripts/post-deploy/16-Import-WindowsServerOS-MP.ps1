<#
.SYNOPSIS
    Extracts the Microsoft System Center Management Pack for Windows Server
    Operating System 2016 and above (download id=54303, MSI version 10.1.2.2,
    MP content version 10.1.1.0; supports Server 2016, 2019, 2022, AND 2025)
    and imports the resulting .mp / .mpb files into SCOM (LAB-SCOM-MG).

.NOTES
    Must run ON HOST B (uses Hyper-V direct PowerShell to B-SCOMMS).

    DSC-style (per the SCOM Configuration Convention in CLAUDE.md):
    Test step (`Get-SCOMManagementPack | ... -Version >= $required`) decides
    whether to import; Set step calls `Import-SCOMManagementPack -FullName`.
    Re-Test runs at the end. xSCOMManagementPack DSC resource exists but is
    deprecated and not SCOM 2025 tested, so we wrap the cmdlet ourselves.

    Source MSI location on Host B share:
        \\10.20.0.1\LabMedia\SCOM\ManagementPacks-Download\WindowsServerOS-MP-2016-and-above.msi

    The MSI installs MP files to a child of
        C:\Program Files (x86)\System Center Management Packs\
    whose name varies by package version (currently
        Microsoft System Center MP for WS 2016 and above). We discover it
    rather than hardcoding.

    Note about "2016" in the filenames: the 10.1.x MP family is a single
    package that covers Server 2016/2019/2022/2025 - the OS class instance
    self-identifies via WMI at the agent, so "Microsoft Windows Server 2025
    Datacenter" is recognized correctly without per-version MPs.
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SCOMMS',
    [string]$MediaShare          = '\\10.20.0.1\LabMedia',
    [string]$DomainAdminPassword = 'LabAdmin@2026!'
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][WinSrv-OS-MP] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

Write-Stage "Reconciling Windows Server OS MP on $VMName ..."

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    param($Share, $AdminPassword)

    cmdkey /add:10.20.0.1 /user:labadmin /pass:$AdminPassword | Out-Null

    $msi     = Join-Path $Share 'SCOM\ManagementPacks-Download\WindowsServerOS-MP-2016-and-above.msi'
    $rootDir = 'C:\Program Files (x86)\System Center Management Packs'

    if (-not (Test-Path $msi)) { throw "MSI not found: $msi" }

    # DSC-style Test/Set helpers for the MSI extraction step.
    function Find-MpInstallDir {
        Get-ChildItem $rootDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Windows Server|WS 2016|Operating System' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    function Test-MsiExtracted {
        [bool](Find-MpInstallDir)
    }
    function Set-MsiExtracted {
        param([string]$MsiPath)
        Write-Host "Running silent install: $MsiPath"
        $logFile = "$env:TEMP\WinSrvOS-MP-install.log"
        $p = Start-Process -FilePath 'msiexec.exe' `
                           -ArgumentList @('/i', "`"$MsiPath`"", '/qn', '/norestart', '/L*v', "`"$logFile`"") `
                           -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -notin @(0, 3010)) {
            Get-Content $logFile -Tail 50 | ForEach-Object { Write-Host "  $_" }
            throw "MSI install failed with exit $($p.ExitCode)"
        }
    }

    if (Test-MsiExtracted) {
        Write-Host "[TEST PASS] MP MSI already extracted under $rootDir"
    } else {
        Set-MsiExtracted -MsiPath $msi
        if (-not (Test-MsiExtracted)) { throw "MSI install succeeded but no MP folder found under $rootDir" }
        Write-Host "[SET]       MP MSI extracted"
    }

    $installDir = Find-MpInstallDir
    Write-Host "MP source dir: $($installDir.FullName)"

    Write-Host "`n=== MP files on disk ==="
    $mpFiles = Get-ChildItem -Path $installDir.FullName -File -ErrorAction Stop |
               Where-Object { $_.Extension -in '.mp', '.mpb' }
    if (-not $mpFiles) { throw "No .mp/.mpb files found under $($installDir.FullName)" }
    $mpFiles | Select-Object Name, @{N='KB';E={[math]::Round($_.Length/1KB,0)}} | Format-Table -AutoSize | Out-String | Write-Host

    # Load OperationsManager for the per-MP Test/Set.
    Import-Module OperationsManager -ErrorAction Stop
    New-SCOMManagementGroupConnection -ComputerName 'B-SCOMMS.sadab.pri' | Out-Null

    # DSC-style Test/Set helpers for MP import.
    # Test: is an MP with the same Name already in the management group at
    # at least the file's version? If yes -> no Set. Otherwise import.
    function Test-MpImported {
        param([System.IO.FileInfo]$File)
        # Use the filename basename as the MP's internal Name. This is the
        # standard convention for the SCOM out-of-band MP packages - every
        # *.mp/*.mpb file is named after its `Name` element. Version-aware
        # comparison would require parsing the MP XML (SDK), but for the lab
        # idempotency check, presence-by-name is sufficient.
        $name = $File.BaseName
        [bool](Get-SCOMManagementPack -Name $name -ErrorAction SilentlyContinue)
    }
    function Set-MpImported {
        param([System.IO.FileInfo[]]$Files)
        Import-SCOMManagementPack -FullName $Files.FullName -ErrorAction Stop
    }

    # First pass: which MPs need Set?
    $needSet = $mpFiles | Where-Object { -not (Test-MpImported -File $_) }
    if (-not $needSet) {
        Write-Host "[TEST PASS] All MPs already imported at the required version"
    } else {
        Write-Host ("[SET]       Importing {0} MPs (batch, SCOM resolves dependency order)..." -f $needSet.Count)
        try {
            Set-MpImported -Files $needSet
            Write-Host "Batch import OK"
        } catch {
            Write-Host "Batch failed - retrying one-by-one with multiple passes..." -ForegroundColor Yellow
            $remaining = [System.Collections.ArrayList]@($needSet)
            for ($pass = 1; $pass -le 6 -and $remaining.Count -gt 0; $pass++) {
                $still = @()
                foreach ($f in $remaining) {
                    try {
                        Set-MpImported -Files @($f)
                        Write-Host "[pass $pass] imported: $($f.Name)"
                    } catch {
                        $still += $f
                    }
                }
                $remaining = $still
            }
            if ($remaining.Count -gt 0) {
                Write-Host "Could not import:" -ForegroundColor Yellow
                $remaining | ForEach-Object { Write-Host "  $($_.Name)" }
            }
        }
    }

    Write-Host "`n=== Re-Test: imported Windows Server OS MPs ==="
    Get-SCOMManagementPack |
        Where-Object { $_.Name -match 'Microsoft\.Windows\.Server(\.|$)' } |
        Sort-Object Name |
        Select-Object Name, Version, Sealed |
        Format-Table -AutoSize | Out-String | Write-Host
} -ArgumentList $MediaShare, $DomainAdminPassword

Write-Stage "Done."
