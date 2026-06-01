<#
.SYNOPSIS
    Installs the SCOM 2025 Operations console on B-SCOMMS (co-located with the
    Management Server, so an admin RDP'd to B-SCOMMS can open the console
    directly without a separate admin workstation).

.NOTES
    Must run ON HOST B (uses Hyper-V direct PowerShell to the VM).

    DSC-style (per the "SCOM Configuration Convention" in CLAUDE.md):
    A Test step probes for the Console install footprint (registry key +
    Console exe). A Set step runs `setup.exe /silent /install /components:OMConsole`.
    Re-Test confirms.

    Why not use xSCOM's `xSCOMConsoleSetup` DSC resource directly: that module
    targets older SCOM (it calls `setup.exe /silent /install:OMConsole`, the
    legacy syntax which SCOM 2025 rejects with "Invalid command line switches -
    no components switch found / 0x80004005"). The current syntax is
    `/install /components:OMConsole`. Wrapping the supported cmdlet/installer
    keeps us aligned with the project convention.

    Reference: https://learn.microsoft.com/system-center/scom/deploy-install-ops-console?view=sc-om-2025#install-the-operations-console-from-the-command-prompt
#>
[CmdletBinding()]
param(
    [string]$VMName              = 'B-SCOMMS',
    [string]$MediaShare          = '\\10.20.0.1\LabMedia',
    [string]$DomainAdminPassword = 'LabAdmin@2026!'
)

$ErrorActionPreference = 'Stop'

function Write-Stage([string]$msg) {
    Write-Host ("[{0}][SCOM-Console] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan
}

$cred = New-Object PSCredential(
    'SADAB\Administrator',
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))

Write-Stage "Reconciling SCOM Console on $VMName ..."

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    param($Share, $AdminPassword)

    cmdkey /add:10.20.0.1 /user:labadmin /pass:$AdminPassword | Out-Null

    # DSC-style Test/Set wrappers.
    function Test-SCOMConsoleInstalled {
        $exe = 'C:\Program Files\Microsoft System Center\Operations Manager\Console\Microsoft.EnterpriseManagement.Monitoring.Console.exe'
        $reg = 'HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0\Setup\Console'
        [bool]((Test-Path $exe) -or (Test-Path $reg))
    }
    function Set-SCOMConsoleInstalled {
        param([string]$SetupExe)

        $consoleArgs = @(
            '/silent'
            '/install'
            '/components:OMConsole'
            '/InstallPath:C:\Program Files\Microsoft System Center\Operations Manager'
            '/AcceptEndUserLicenseAgreement:1'
            '/EnableErrorReporting:Never'
            '/SendCEIPReports:0'
            '/UseMicrosoftUpdate:0'
        )

        Write-Host "setup.exe args: $($consoleArgs -join ' ')"
        $proc = Start-Process -FilePath $SetupExe -ArgumentList $consoleArgs `
                              -Wait -PassThru -NoNewWindow `
                              -RedirectStandardOutput 'C:\scom-console-setup.out' `
                              -RedirectStandardError  'C:\scom-console-setup.err'
        Write-Host "setup.exe exit code: $($proc.ExitCode)"

        foreach ($p in 'C:\scom-console-setup.out','C:\scom-console-setup.err') {
            if (Test-Path $p) {
                $c = Get-Content $p -Tail 25 -ErrorAction SilentlyContinue
                if ($c) { Write-Host "--- $(Split-Path $p -Leaf) tail ---"; $c | ForEach-Object { Write-Host "  $_" } }
            }
        }

        if ($proc.ExitCode -notin @(0, 3010)) {
            $wiz = 'C:\Users\Administrator.SADAB\AppData\Local\SCOM\LOGS\OpsMgrSetupWizard.log'
            if (Test-Path $wiz) {
                Write-Host '--- OpsMgrSetupWizard.log tail ---'
                Get-Content $wiz -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
            }
            throw "setup.exe (console) failed with exit code $($proc.ExitCode)"
        }
    }

    if (Test-SCOMConsoleInstalled) {
        Write-Host "[TEST PASS] SCOM Console already installed - no action"
    } else {
        $setupExe = Join-Path $Share 'SCOM\extracted\Setup.exe'
        if (-not (Test-Path $setupExe)) { throw "Setup.exe missing at $setupExe" }
        Write-Host "[SET]       Installing SCOM Console..."
        Set-SCOMConsoleInstalled -SetupExe $setupExe
        if (-not (Test-SCOMConsoleInstalled)) {
            throw "Set ran but Test still negative - install did not produce expected footprint"
        }
        Write-Host "[RE-TEST]   PASS"
    }

    Write-Host "`n=== Console install footprint ==="
    $exe = 'C:\Program Files\Microsoft System Center\Operations Manager\Console\Microsoft.EnterpriseManagement.Monitoring.Console.exe'
    if (Test-Path $exe) {
        $i = Get-Item $exe
        '{0,-12} {1}' -f 'Console.exe', $i.FullName
        '{0,-12} {1} ({2} KB)' -f 'Version', $i.VersionInfo.FileVersion, [math]::Round($i.Length/1KB,0)
    }
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0\Setup' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -in 'Console','Server' } |
        Select-Object @{N='Subkey';E={$_.PSChildName}} | Format-Table -AutoSize | Out-String | Write-Host

    $shortcut = Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Recurse -Filter 'Operations Console*.lnk' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($shortcut) { Write-Host "Start menu shortcut: $($shortcut.FullName)" }
} -ArgumentList $MediaShare, $DomainAdminPassword

Write-Stage "Done."
