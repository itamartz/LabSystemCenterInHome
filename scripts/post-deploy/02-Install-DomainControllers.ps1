<#
.SYNOPSIS
    Installs AD DS on A-DC and promotes it as the forest root domain controller.

.NOTES
    Author  : SADAB Lab
    Version : 2.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$AdminPassword,
    [Parameter(Mandatory)] [string]$DomainAdminPassword,
    [Parameter(Mandatory)] [string]$DSRMPassword,
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force

$DomainName  = $Global:LabConfig.DomainName
$NetBIOS     = $Global:LabConfig.NetBIOSName
$DcAIP       = '10.10.0.2'
$DSRMSecure  = ConvertTo-SecureString $DSRMPassword -AsPlainText -Force

# ── Promote A-DC — Create forest ────────────────────────────────────────────
Write-LabLog 'Promoting A-DC to forest root domain controller...' -Step 'A-DC'

Invoke-LabRemote -IPAddress $DcAIP -Credential $LocalCred -ScriptBlock {
    param($Domain, $NetBIOS, $DSRM)

    # Idempotency guard: if Install-ADDSForest already completed (ADWS service
    # exists and is running), don't re-run. Lets Invoke-LabRemote's retry loop
    # be safe on the post-reboot reconnection that follows DC promotion.
    $adws = Get-Service ADWS -ErrorAction SilentlyContinue
    if ($adws -and $adws.Status -eq 'Running') {
        Write-Host "ADWS already running on $env:COMPUTERNAME - DC already promoted, skipping."
        return
    }
    if (-not $Domain -or -not $NetBIOS) {
        throw "Domain='$Domain' NetBIOS='$NetBIOS' came in null - LabConfig wasn't loaded correctly"
    }

    # Disable firewall for all profiles (lab only)
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

    Install-WindowsFeature AD-Domain-Services, RSAT-AD-AdminCenter, RSAT-ADDS-Tools | Out-Null

    Import-Module ADDSDeployment
    Install-ADDSForest `
        -DomainName                    $Domain `
        -DomainNetbiosName             $NetBIOS `
        -ForestMode                    WinThreshold `
        -DomainMode                    WinThreshold `
        -DatabasePath                  'C:\Windows\NTDS' `
        -LogPath                       'C:\Windows\NTDS' `
        -SysvolPath                    'C:\Windows\SYSVOL' `
        -SafeModeAdministratorPassword $DSRM `
        -InstallDns:$true `
        -NoRebootOnCompletion:$false `
        -Force
} -ArgumentList $DomainName, $NetBIOS, $DSRMSecure

Write-LabLog 'A-DC reboot initiated. Waiting for it to come back...' -Step 'A-DC'
Start-Sleep -Seconds 90

$domCred = New-Object System.Management.Automation.PSCredential(
    "$NetBIOS\Administrator",
    (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force)
)

Wait-LabVMReady -IPAddress $DcAIP -Credential $domCred -TimeoutSec 300
Write-LabLog 'A-DC is back and responding. Forest root DC operational.' -Level SUCCESS -Step 'A-DC'
