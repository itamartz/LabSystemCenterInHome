<#
.SYNOPSIS
    Installs the PowershellBGInfo module on B-SCOMMS and renders a desktop
    wallpaper that says "this is the SCOM Management Server" - so anyone
    RDP'd in immediately knows which lab VM they're on.

.NOTES
    Must run ON HOST B (uses Hyper-V direct PowerShell to B-SCOMMS).

    DSC-style (per the "SCOM Configuration Convention" in CLAUDE.md):
    Test (module installed AND wallpaper path matches what we'd generate) ->
    Set (Install-Module + render image + Set-BGInfoImage).

    Source module: https://www.powershellgallery.com/packages/PowershellBGInfo/1.3.2
    Author: Itamar Tziger. Cmdlets used (actual signatures from the module):
        New-BGInfoRow   -RowText '...' [-FontFamily -FontSize -FontStyle]
        New-BGInfoImage -BGInfoRows @(...) -ImagePath '...' [-BackgroundColor -TextColor -Position]
        Set-BGInfoImage -BGinfoImageOutput '...'

    Wallpaper is set per-user (HKCU). For the lab, SADAB\Administrator is the
    typical RDP login - the wallpaper appears next time they sign in. If we
    later want it visible to all users, switch to a logon scheduled task that
    runs this script (or a generated cached image) at every login.
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SCOMMS',
    [string]$DomainAdminPassword = 'LabAdmin@2026!',
    [string]$WallpaperPath       = 'C:\HyperV-Lab-Local\SCOM-Wallpaper.bmp'
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][SCOM-BGInfo] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

Write-Stage "Reconciling SCOM-server BGInfo wallpaper on $VMName ..."

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    param([string]$WallpaperPath)

    # ---- Test/Set 1: PowershellBGInfo module installed ----
    function Test-BGInfoModuleInstalled {
        [bool](Get-Module -ListAvailable -Name PowershellBGInfo -ErrorAction SilentlyContinue)
    }
    function Set-BGInfoModuleInstalled {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -Scope AllUsers -ErrorAction Stop | Out-Null
        }
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue | Where-Object InstallationPolicy -eq 'Trusted')) {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
        Install-Module -Name PowershellBGInfo -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
    }

    if (Test-BGInfoModuleInstalled) {
        Write-Host "[TEST PASS] PowershellBGInfo module already installed"
    } else {
        Write-Host "[SET]       installing PowershellBGInfo from PSGallery..."
        Set-BGInfoModuleInstalled
    }
    Import-Module PowershellBGInfo -ErrorAction Stop

    # ---- Test/Set 2: SCOM-themed wallpaper rendered + applied ----
    function Get-WallpaperRows {
        Import-Module OperationsManager -ErrorAction SilentlyContinue
        $mgName  = try { (Get-SCOMManagementGroup).Name } catch { 'LAB-SCOM-MG' }
        $hs      = Get-Service HealthService -ErrorAction SilentlyContinue
        $sdk     = Get-Service OMSDK -ErrorAction SilentlyContinue
        $cs      = Get-Service cshost -ErrorAction SilentlyContinue
        $os      = (Get-CimInstance Win32_OperatingSystem).Caption
        $ip      = (Get-NetIPAddress -AddressFamily IPv4 |
                    Where-Object { $_.PrefixOrigin -in 'Manual','Dhcp' -and $_.IPAddress -notmatch '^127\.' } |
                    Select-Object -First 1).IPAddress
        $fqdn    = [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
        $up      = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $upStr   = "{0:D}d {1:D2}h {2:D2}m" -f [int]$up.TotalDays, $up.Hours, $up.Minutes

        # The module uses one RowText per row; format label+value ourselves.
        # Default font is fine. Heading rows get a slightly bigger/bold style.
        $headerArgs = @{ FontSize = 16; FontStyle = 'Bold' }
        $bodyArgs   = @{ FontSize = 12 }

        @(
            New-BGInfoRow -RowText '====== SADAB Lab : SCOM ======' @headerArgs
            New-BGInfoRow -RowText ('Role             : SCOM 2025 Management Server') @bodyArgs
            New-BGInfoRow -RowText ('Host             : ' + $env:COMPUTERNAME)         @bodyArgs
            New-BGInfoRow -RowText ('FQDN             : ' + $fqdn)                     @bodyArgs
            New-BGInfoRow -RowText ('IP               : ' + $ip)                       @bodyArgs
            New-BGInfoRow -RowText ('Management Group : ' + $mgName)                   @bodyArgs
            New-BGInfoRow -RowText ('OS               : ' + $os)                       @bodyArgs
            New-BGInfoRow -RowText '----- SCOM services -----'                         @headerArgs
            New-BGInfoRow -RowText ('HealthService    : ' + "$($hs.Status)")           @bodyArgs
            New-BGInfoRow -RowText ('OMSDK            : ' + "$($sdk.Status)")          @bodyArgs
            New-BGInfoRow -RowText ('cshost           : ' + "$($cs.Status)")           @bodyArgs
            New-BGInfoRow -RowText ('Uptime           : ' + $upStr)                    @bodyArgs
            New-BGInfoRow -RowText ('Generated        : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) @bodyArgs
        )
    }

    # Per the module's Example.txt: in "Color" mode do NOT pass -ImagePath
    # (it's only meaningful in BackgroundImage mode where it must be a
    # DIRECTORY). The cmdlet writes the BMP to %TEMP%\BGinfoImage.bmp and
    # returns a BGinfoImageOutput object whose .ToString() is the source path.
    Write-Host "Rendering wallpaper..."
    $rows = Get-WallpaperRows
    $generated = New-BGInfoImage -BGInfoRows $rows `
                                 -BackgroundColor 'Black' `
                                 -TextColor 'White' -ErrorAction Stop
    # The cmdlet's output is an object; the actual file path it wrote to is
    # available as a property OR by convention at $env:TEMP\BGinfoImage.bmp.
    $sourcePath = Join-Path $env:TEMP 'BGinfoImage.bmp'
    if (-not (Test-Path $sourcePath)) { throw "Generated BMP not found at $sourcePath" }
    Write-Host "Generated: $sourcePath ($([math]::Round((Get-Item $sourcePath).Length/1KB,1)) KB)"

    # Move to a stable, machine-wide path so the registry pointer doesn't
    # break if %TEMP% gets cleaned.
    $dir = Split-Path $WallpaperPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -Path $sourcePath -Destination $WallpaperPath -Force
    Write-Host "Staged at: $WallpaperPath"

    # Update HKCU directly. Set-BGInfoImage uses a Win32 API
    # (SystemParametersInfo SPI_SETDESKWALLPAPER) that needs an interactive
    # desktop session - in a PSDirect remote session there's no active
    # desktop, so the call is a no-op against the registry. Writing the
    # value ourselves means it's picked up on next login.
    Write-Host "Updating HKCU\Control Panel\Desktop wallpaper registry..."
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper      -Value $WallpaperPath -Force
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '0'           -Force    # 0 = Centered
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper  -Value '0'           -Force

    # Also write to .DEFAULT (Default User profile) so this is the wallpaper
    # for newly-created user sessions on B-SCOMMS too. Anyone RDP'ing in for
    # the first time gets the SCOM wallpaper immediately.
    if (Test-Path 'HKU:\') {
        # No-op, already mapped
    } else {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
    }
    if (Test-Path 'HKU:\.DEFAULT\Control Panel\Desktop') {
        Set-ItemProperty -Path 'HKU:\.DEFAULT\Control Panel\Desktop' -Name Wallpaper      -Value $WallpaperPath -Force
        Set-ItemProperty -Path 'HKU:\.DEFAULT\Control Panel\Desktop' -Name WallpaperStyle -Value '0'           -Force
        Set-ItemProperty -Path 'HKU:\.DEFAULT\Control Panel\Desktop' -Name TileWallpaper  -Value '0'           -Force
    }

    # Best-effort: also tell the running session to refresh. Only succeeds if
    # there's a logged-on user; otherwise it's a no-op which is fine - the
    # wallpaper still applies on next login via the registry.
    try { Set-BGInfoImage -BGinfoImageOutput $generated -ErrorAction Stop } catch {}

    Write-Host "[OK] wallpaper applied. RDP back in to see it (or sign out + sign in)."
} -ArgumentList $WallpaperPath

Write-Stage 'Done.'
