<#
.SYNOPSIS
    Connection helpers for the local SCCM lab Hyper-V host. Dot-source this script
    from your session, then use Invoke-LabHost / Invoke-LabVM to run commands.

.EXAMPLE
    . .\scripts\lib\Connect-LabHost.ps1
    Invoke-LabHost { Get-VM | Select-Object Name, State }

.EXAMPLE
    Invoke-LabVM -VMName 'A-DC' -ScriptBlock { Get-ADDomain }

.NOTES
    - Credentials are loaded once per session from .\.secrets\hyperv-host.cred.xml
      (DPAPI-encrypted, per-user/per-machine — won't decrypt on other machines).
    - Host IP defaults from .\lab-config.json (hostA.ip). Override with -ComputerName.
    - Authentication is Negotiate (NTLM) — no Kerberos / domain needed.
#>

$Script:LabConfigPath = Join-Path $PSScriptRoot '..\..\lab-config.json'
$Script:LabCredPath   = Join-Path $PSScriptRoot '..\..\.secrets\hyperv-host.cred.xml'

function Get-LabConfig {
    <#
    .SYNOPSIS
        Returns the parsed lab-config.json. Cached for the session.
    #>
    if (-not $Script:LabConfigCache) {
        if (-not (Test-Path $Script:LabConfigPath)) {
            throw "lab-config.json not found at $Script:LabConfigPath"
        }
        $Script:LabConfigCache = Get-Content $Script:LabConfigPath -Raw | ConvertFrom-Json
    }
    return $Script:LabConfigCache
}

function Get-LabHostCredential {
    <#
    .SYNOPSIS
        Returns the cached PSCredential for the Hyper-V host. Loads from
        .secrets\hyperv-host.cred.xml on first call.
    #>
    if (-not $Script:LabHostCred) {
        if (-not (Test-Path $Script:LabCredPath)) {
            throw "Cred file not found at $Script:LabCredPath. Create it with: Get-Credential | Export-Clixml -Path $Script:LabCredPath"
        }
        $Script:LabHostCred = Import-Clixml -Path $Script:LabCredPath
    }
    return $Script:LabHostCred
}

function Invoke-LabHost {
    <#
    .SYNOPSIS
        Runs a script block on the lab Hyper-V host via WinRM.

    .PARAMETER ScriptBlock
        Commands to execute on the host.

    .PARAMETER ComputerName
        Override the host IP. Defaults to lab-config.json hostA.ip.

    .PARAMETER ArgumentList
        Arguments to pass into the script block.

    .EXAMPLE
        Invoke-LabHost { Get-VM | Where-Object State -eq 'Running' }

    .EXAMPLE
        Invoke-LabHost -ScriptBlock { param($n) Get-VM -Name $n } -ArgumentList 'A-DC'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [scriptblock]$ScriptBlock,

        [string]$ComputerName,

        [object[]]$ArgumentList
    )

    if (-not $ComputerName) {
        $cfg = Get-LabConfig
        $ComputerName = $cfg.hostA.ip
    }

    $params = @{
        ComputerName   = $ComputerName
        Credential     = Get-LabHostCredential
        Authentication = 'Negotiate'
        ScriptBlock    = $ScriptBlock
        ErrorAction    = 'Stop'
    }
    if ($ArgumentList) { $params.ArgumentList = $ArgumentList }

    Invoke-Command @params
}

function Invoke-LabHostScript {
    <#
    .SYNOPSIS
        Runs a local .ps1 file on the lab Hyper-V host via WinRM. The script's text
        is sent over the wire (Invoke-Command -FilePath) — no need to pre-stage it.

    .PARAMETER FilePath
        Path to the local .ps1 file (relative or absolute).

    .PARAMETER ArgumentList
        Positional arguments passed to the script's param() block.

    .PARAMETER ComputerName
        Override the host IP. Defaults to lab-config.json hostA.ip.

    .EXAMPLE
        Invoke-LabHostScript -FilePath '.\scripts\setup\Configure-Host.ps1' -ArgumentList 'A'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$FilePath,

        [object[]]$ArgumentList,

        [string]$ComputerName
    )

    if (-not (Test-Path $FilePath)) {
        throw "Script not found: $FilePath"
    }
    $resolved = (Resolve-Path $FilePath).Path

    if (-not $ComputerName) {
        $cfg = Get-LabConfig
        $ComputerName = $cfg.hostA.ip
    }

    $params = @{
        ComputerName   = $ComputerName
        Credential     = Get-LabHostCredential
        Authentication = 'Negotiate'
        FilePath       = $resolved
        ErrorAction    = 'Stop'
    }
    if ($ArgumentList) { $params.ArgumentList = $ArgumentList }

    Invoke-Command @params
}

function Invoke-LabVM {
    <#
    .SYNOPSIS
        Runs a script block on a nested lab VM via Hyper-V direct connect
        from the host (Invoke-Command -VMName). Bypasses VM network WinRM.

    .PARAMETER VMName
        Name of the nested VM (e.g. 'A-DC').

    .PARAMETER ScriptBlock
        Commands to execute inside the VM.

    .PARAMETER UseDomainCredential
        If set, use the SADAB\Administrator domain credential (for domain-joined VMs).
        Otherwise uses the local Administrator credential.

    .PARAMETER LocalAdminPassword
        Password for nested-VM local Administrator. Defaults to lab-config.json
        defaults.localAdminPassword.

    .PARAMETER DomainAdminPassword
        Password for SADAB\Administrator after domain promotion. Defaults to
        lab-config.json defaults.domainAdminPassword.

    .EXAMPLE
        Invoke-LabVM -VMName 'A-DC' -ScriptBlock { hostname }

    .EXAMPLE
        Invoke-LabVM -VMName 'A-SQLSCCM' -UseDomainCredential -ScriptBlock { Get-Service MSSQLSERVER }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [switch]$UseDomainCredential,
        [string]$LocalAdminPassword,
        [string]$DomainAdminPassword
    )

    $cfg = Get-LabConfig
    if (-not $LocalAdminPassword)  { $LocalAdminPassword  = $cfg.defaults.localAdminPassword  }
    if (-not $DomainAdminPassword) { $DomainAdminPassword = $cfg.defaults.domainAdminPassword }

    # Execute on host: the host runs Invoke-Command -VMName which bypasses VM networking
    Invoke-LabHost -ScriptBlock {
        param($Name, $UseDomain, $LocalPwd, $DomainPwd, $InnerSb)

        $user = if ($UseDomain) { 'SADAB\Administrator' } else { 'Administrator' }
        $pwd  = if ($UseDomain) { $DomainPwd } else { $LocalPwd }
        $cred = New-Object PSCredential($user, (ConvertTo-SecureString $pwd -AsPlainText -Force))

        $sessionOpt = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 60000
        $sb = [scriptblock]::Create($InnerSb)
        Invoke-Command -VMName $Name -Credential $cred -ScriptBlock $sb `
                       -SessionOption $sessionOpt -ErrorAction Stop
    } -ArgumentList @($VMName, [bool]$UseDomainCredential, $LocalAdminPassword, $DomainAdminPassword, $ScriptBlock.ToString())
}

# Friendly status banner when dot-sourced interactively
if ($MyInvocation.InvocationName -eq '.') {
    try {
        $cfg = Get-LabConfig
        Write-Host "Lab connection helpers loaded." -ForegroundColor Green
        Write-Host "  Host A : $($cfg.hostA.hostname) @ $($cfg.hostA.ip)" -ForegroundColor Cyan
        Write-Host "  Cmds   : Invoke-LabHost { ... }   Invoke-LabVM -VMName 'A-DC' { ... }" -ForegroundColor Cyan
    } catch {
        Write-Host "Lab helpers loaded (config not yet present)." -ForegroundColor Yellow
    }
}
