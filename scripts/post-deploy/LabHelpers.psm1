<#
.SYNOPSIS
    Shared helper functions for SADAB Lab post-deploy installation scripts.
.NOTES
    Author  : SADAB Lab
    Version : 1.0
    Import  : Import-Module .\LabHelpers.psm1
    DO NOT  : Use Write-Log - conflicts with PowerCLI.
#>

# ── Lab-wide constants ────────────────────────────────────────────────────────

$Global:LabConfig = @{
    DomainName      = 'sadab.pri'
    NetBIOSName     = 'SADAB'
    SiteCodeA       = 'SA1'
    SiteCodeB       = 'SB1'
    SCOMManageMent  = 'LAB-SCOM-MG'
    MediaShareA     = '\\10.10.0.1\LabMedia'
    MediaShareB     = '\\10.20.0.1\LabMedia'

    AllVMs = @(
        @{ Name = 'A-DC';       IP = '10.10.0.2';  Site = 'A' }
        @{ Name = 'A-SCCM';     IP = '10.10.0.3';  Site = 'A' }
        @{ Name = 'A-SQLSCCM';  IP = '10.10.0.4';  Site = 'A' }
        @{ Name = 'A-MPDP';     IP = '10.10.0.5';  Site = 'A' }
        @{ Name = 'A-DFSR';     IP = '10.10.0.7';  Site = 'A' }
        @{ Name = 'A-SCOM';     IP = '10.10.0.40'; Site = 'A' }
        @{ Name = 'A-SQLSCOM';  IP = '10.10.0.41'; Site = 'A' }
        @{ Name = 'B-SCCM';     IP = '10.20.0.3';  Site = 'B' }
        @{ Name = 'B-SQLSCCM';  IP = '10.20.0.4';  Site = 'B' }
        @{ Name = 'B-MPDP';     IP = '10.20.0.5';  Site = 'B' }
        @{ Name = 'B-DFSR';     IP = '10.20.0.7';  Site = 'B' }
    )
}

# ── Logging ───────────────────────────────────────────────────────────────────

function Write-LabLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','SUCCESS','WARN','ERROR')]
        [string]$Level = 'INFO',
        [string]$Step  = ''
    )
    $ts     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = if ($Step) { "[$Step]" } else { '' }
    $entry  = "[$ts][$Level]$prefix $Message"
    $color  = switch ($Level) {
        'INFO'    { 'Cyan'   }
        'SUCCESS' { 'Green'  }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
    }
    Write-Host $entry -ForegroundColor $color
}

# ── Remote execution ──────────────────────────────────────────────────────────

function Invoke-LabRemote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$IPAddress,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList   = @(),
        [int]$MaxRetries          = 10,
        [int]$RetryDelaySec       = 30,
        [int]$TimeoutSec          = 300
    )

    # If we're running on the Hyper-V host AND the IP belongs to a known lab VM,
    # prefer Hyper-V direct (PowerShell Direct via VMBUS). It gives an interactive
    # token that supports credential delegation (no double-hop issue) and has access
    # to cmdkey-cached SMB credentials. Network WinRM (NTLM) is used as fallback.
    $vmEntry = $Global:LabConfig.AllVMs | Where-Object { $_.IP -eq $IPAddress } | Select-Object -First 1
    if ($vmEntry -and (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        $hvVm = Get-VM -Name $vmEntry.Name -ErrorAction SilentlyContinue
        if ($hvVm -and $hvVm.State -eq 'Running') {
            try {
                return Invoke-Command -VMName $vmEntry.Name -Credential $Credential `
                                      -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList `
                                      -ErrorAction Stop
            } catch {
                Write-LabLog "Hyper-V direct to $($vmEntry.Name) failed ($($_.Exception.Message)) - falling back to network WinRM" -Level WARN
            }
        }
    }

    # Fallback: network WinRM with workgroup-friendly NTLM cred format
    $cred = $Credential
    if ($Credential.UserName -notmatch '[\\@]') {
        $cred = New-Object System.Management.Automation.PSCredential(
            "$IPAddress\$($Credential.UserName)", $Credential.Password)
    }

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            $session = New-PSSession -ComputerName $IPAddress -Credential $cred `
                           -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) `
                           -ErrorAction Stop
            try {
                return Invoke-Command -Session $session -ScriptBlock $ScriptBlock `
                                      -ArgumentList $ArgumentList
            } finally {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }
        } catch {
            $attempt++
            if ($attempt -ge $MaxRetries) {
                Write-LabLog "WinRM failed on $IPAddress after $MaxRetries attempts: $_" -Level ERROR
                throw
            }
            Write-LabLog "WinRM not ready on $IPAddress ($attempt/$MaxRetries) - waiting $RetryDelaySec s..." -Level WARN
            Start-Sleep -Seconds $RetryDelaySec
        }
    }
}

function Wait-LabVMReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$IPAddress,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSec = 300
    )
    # Same NTLM-local-account fix as Invoke-LabRemote
    $cred = $Credential
    if ($Credential.UserName -notmatch '[\\@]') {
        $cred = New-Object System.Management.Automation.PSCredential(
            "$IPAddress\$($Credential.UserName)", $Credential.Password)
    }

    Write-LabLog "Waiting for WinRM on $IPAddress..." -Level INFO
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $null = New-PSSession -ComputerName $IPAddress -Credential $cred `
                        -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) `
                        -ErrorAction Stop
            Write-LabLog "$IPAddress is ready." -Level SUCCESS
            return
        } catch {
            Start-Sleep -Seconds 15
        }
    }
    throw "Timeout waiting for WinRM on $IPAddress"
}

Export-ModuleMember -Function Write-LabLog, Invoke-LabRemote, Wait-LabVMReady
Export-ModuleMember -Variable LabConfig
