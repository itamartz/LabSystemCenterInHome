<#
.SYNOPSIS
    Shared helper functions for per-VM post-deploy scripts. Dot-source from Post-*.ps1 scripts.
#>

$ErrorActionPreference = 'Stop'

# Import core lab helpers (logging, remote execution)
Import-Module "$PSScriptRoot\..\post-deploy\LabHelpers.psm1" -Force

function New-LabCredentials {
    param(
        [Parameter(Mandatory)] [string]$AdminPassword,
        [Parameter(Mandatory)] [string]$DomainAdminPassword
    )
    $localCred = New-Object System.Management.Automation.PSCredential(
        '.\Administrator',
        (ConvertTo-SecureString $AdminPassword -AsPlainText -Force)
    )
    $domainCred = New-Object System.Management.Automation.PSCredential(
        'SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force)
    )
    return @{ Local = $localCred; Domain = $domainCred }
}

function Join-LabDomain {
    param(
        [Parameter(Mandatory)] [string]$IP,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$LocalCred,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$DomainCred
    )

    $DcIP   = '10.10.0.2'
    $Domain = 'sadab.pri'

    # Check if already domain-joined
    $joined = Invoke-LabRemote -IPAddress $IP -Credential $LocalCred -ScriptBlock {
        param($Domain)
        try {
            $cs = Get-CimInstance Win32_ComputerSystem
            return ($cs.PartOfDomain -and $cs.Domain -eq $Domain)
        } catch { return $false }
    } -ArgumentList $Domain -MaxRetries 3 -RetryDelaySec 10

    if ($joined) {
        Write-LabLog "$VMName already joined to $Domain - skipping." -Level SUCCESS -Step $VMName
        return
    }

    Write-LabLog "Joining $VMName ($IP) to domain $Domain..." -Step $VMName

    Invoke-LabRemote -IPAddress $IP -Credential $LocalCred -ScriptBlock {
        param($DnsIP, $Domain, $DomCred)

        $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $DnsIP

        Add-Computer -DomainName $Domain -Credential $DomCred -Restart -Force
    } -ArgumentList $DcIP, $Domain, $DomainCred

    Write-LabLog "$VMName rebooting after domain join..." -Step $VMName
    Start-Sleep -Seconds 60
    Wait-LabVMReady -IPAddress $IP -Credential $DomainCred -TimeoutSec 240
    Write-LabLog "$VMName joined and back online." -Level SUCCESS -Step $VMName
}
