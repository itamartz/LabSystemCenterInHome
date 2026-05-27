<#
.SYNOPSIS
    Shared helper functions for creating lab nested VMs. Dot-source from per-VM scripts.
#>

$ErrorActionPreference = 'Stop'

$Script:StoragePath  = 'C:\HyperV-Lab'
$Script:ParentVhdx   = "$StoragePath\Base\WS2025-Eval.vhdx"

# --- Unattend XML generation ---------------------------------------------------

function New-VMUnattendXml {
    param(
        [Parameter(Mandatory)] [string]$ComputerName,
        [Parameter(Mandatory)] [string]$IPAddress,
        [Parameter(Mandatory)] [string]$Gateway,
        [Parameter(Mandatory)] [string]$AdminPassword,
        [string]$DnsServer = $Gateway
    )

    $encodedPwd = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes("${AdminPassword}AdministratorPassword")
    )

    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>Israel Standard Time</TimeZone>
    </component>
    <component name="Microsoft-Windows-TCPIP" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <Interfaces>
        <Interface wcm:action="add">
          <Identifier>Ethernet</Identifier>
          <Ipv4Settings><DhcpEnabled>false</DhcpEnabled></Ipv4Settings>
          <UnicastIpAddresses>
            <IpAddress wcm:action="add" wcm:keyValue="1">$IPAddress/24</IpAddress>
          </UnicastIpAddresses>
          <Routes>
            <Route wcm:action="add">
              <Identifier>1</Identifier>
              <Prefix>0.0.0.0/0</Prefix>
              <NextHopAddress>$Gateway</NextHopAddress>
            </Route>
          </Routes>
        </Interface>
      </Interfaces>
    </component>
    <component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <Interfaces>
        <Interface wcm:action="add">
          <Identifier>Ethernet</Identifier>
          <DNSServerSearchOrder>
            <IpAddress wcm:action="add" wcm:keyValue="1">$DnsServer</IpAddress>
          </DNSServerSearchOrder>
        </Interface>
      </Interfaces>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <NetworkLocation>Work</NetworkLocation>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$encodedPwd</Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>labadmin</Name>
            <Group>Administrators</Group>
            <Password>
              <Value>$AdminPassword</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Password><Value>$encodedPwd</Value><PlainText>false</PlainText></Password>
        <Username>Administrator</Username>
        <LogonCount>5</LogonCount>
        <Enabled>true</Enabled>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd /c net user Administrator /active:yes</CommandLine>
          <Description>Enable built-in Administrator account</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <CommandLine>cmd /c wmic useraccount where "name='Administrator'" set PasswordExpires=FALSE</CommandLine>
          <Description>Set Administrator password never expires</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <CommandLine>cmd /c wmic useraccount where "name='labadmin'" set PasswordExpires=FALSE</CommandLine>
          <Description>Set labadmin password never expires</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>4</Order>
          <CommandLine>cmd /c net accounts /maxpwage:unlimited</CommandLine>
          <Description>Disable password expiration policy</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>5</Order>
          <CommandLine>powershell -NoProfile -Command "Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False"</CommandLine>
          <Description>Disable Windows Firewall (lab only)</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>6</Order>
          <CommandLine>powershell -NoProfile -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck; Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force; Set-Item WSMan:\localhost\Service\Auth\Basic -Value `$true; Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value `$true"</CommandLine>
          <Description>Enable WinRM with permissive settings (lab only)</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>7</Order>
          <CommandLine>powershell -NoProfile -Command "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -Value 1 -Type DWord -Force"</CommandLine>
          <Description>Allow remote admin for local accounts (UAC token filter)</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>8</Order>
          <CommandLine>powershell -NoProfile -Command "Enable-VMIntegrationService -Name 'Guest Service Interface' -ErrorAction SilentlyContinue"</CommandLine>
          <Description>Enable Hyper-V Guest Service Interface (ignore if not applicable)</Description>
        </SynchronousCommand>
        <!-- Order 9: IPv6 disable removed - DisabledComponents=255 on WS2025 binds services
             only to [::] and breaks IPv4 TCP listeners (WinRM, SMB). Leave IPv6 enabled. -->
        <SynchronousCommand wcm:action="add">
          <Order>10</Order>
          <CommandLine>cmdkey /add:10.10.0.1 /user:labadmin /pass:LabAdmin@2026!</CommandLine>
          <Description>Store Host A SMB credentials for media share access (all VMs use Host A share)</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>11</Order>
          <CommandLine>powershell -NoProfile -Command "Start-Sleep -Seconds 30; reg add 'HKLM\SOFTWARE\Microsoft\Virtual Machine\Auto' /v OOBEComplete /d `$env:COMPUTERNAME /f"</CommandLine>
          <Description>Wait 30s then signal host via KVP that OOBE is complete</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>he-IL</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <!-- UserLocale MUST be en-US, not en-IL. en-IL = LCID 3072 which SQL Server's
           CLR rejects, breaking SCCM's spSetupLanternDocuments_CLR during install.
           Keyboard stays Hebrew (InputLocale he-IL); only the locale/LCID is en-US. -->
      <UserLocale>en-US</UserLocale>
    </component>
  </settings>
</unattend>
"@
}

# --- Unattend injection into VHDX ---------------------------------------------

function Add-UnattendToVhdx {
    param(
        [Parameter(Mandatory)] [string]$VhdxPath,
        [Parameter(Mandatory)] [string]$UnattendContent
    )

    Write-Host "  Mounting: $VhdxPath"
    try {
        $vhd    = Mount-VHD -Path $VhdxPath -Passthru
        $diskNo = $vhd.DiskNumber
        $disk   = Get-Disk -Number $diskNo

        $partition = $disk | Get-Partition |
                     Where-Object { $_.Type -eq 'Basic' } |
                     Sort-Object -Property Size -Descending |
                     Select-Object -First 1

        if (-not $partition.DriveLetter -or $partition.DriveLetter -eq "`0") {
            $partition | Add-PartitionAccessPath -AssignDriveLetter
            $partition = Get-Partition -DiskNumber $diskNo -PartitionNumber $partition.PartitionNumber
        }

        $drive       = $partition.DriveLetter
        $pantherPath = "${drive}:\Windows\Panther"

        if (-not (Test-Path $pantherPath)) {
            New-Item -ItemType Directory -Path $pantherPath -Force | Out-Null
        }

        Set-Content -Path "$pantherPath\unattend.xml" -Value $UnattendContent -Encoding UTF8
        Write-Host "  Injected unattend.xml -> ${drive}:\Windows\Panther\"
    } finally {
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
    }
}

# --- Nested VM creation (idempotent) ------------------------------------------

function New-LabVM {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$IP,
        [Parameter(Mandatory)] [string]$Gateway,
        [Parameter(Mandatory)] [string]$SwitchName,
        [Parameter(Mandatory)] [int]$RamGB,           # MaximumBytes for Dynamic Memory
        [Parameter(Mandatory)] [int]$VCPU,
        [int]$StartupGB       = 0,                    # 0 = use RamGB; lower to fit on a constrained host
        [string]$DnsServer    = '10.10.0.2',
        [int]$DataDiskGB      = 0,
        [int]$AutoStartDelay  = 30,
        [string]$AdminPassword = 'LabAdmin@2026!'
    )
    if ($StartupGB -le 0) { $StartupGB = $RamGB }

    # Idempotent: skip if VM already exists
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        Write-Host "VM '$Name' already exists - skipping."
        Get-VM $Name | Select-Object Name, State, Uptime, @{N='MemoryMB';E={$_.MemoryAssigned/1MB}} | Format-Table -AutoSize
        return
    }

    $diffDisk = "$Script:StoragePath\VHDs\$Name-OS.vhdx"
    $dataDisk = "$Script:StoragePath\VHDs\$Name-Data.vhdx"

    Write-Host "Creating VM: $Name | $IP | ${RamGB}GB RAM | $VCPU vCPU"

    # 1. Differencing OS disk
    Write-Host "Creating differencing OS disk..."
    New-VHD -Path $diffDisk -ParentPath $Script:ParentVhdx -Differencing | Out-Null

    # 2. Inject unattend.xml
    $xml = New-VMUnattendXml -ComputerName $Name -IPAddress $IP -Gateway $Gateway -AdminPassword $AdminPassword -DnsServer $DnsServer
    Add-UnattendToVhdx -VhdxPath $diffDisk -UnattendContent $xml
    Start-Sleep -Seconds 2

    # 3. Data disk (if requested)
    if ($DataDiskGB -gt 0) {
        Write-Host "Creating dynamic data disk (${DataDiskGB} GB)..."
        New-VHD -Path $dataDisk -SizeBytes ($DataDiskGB * 1GB) -Dynamic | Out-Null
    }

    # 4. Create VM (startup memory may be lower than max for constrained hosts)
    Write-Host "Creating $Name VM..."
    New-VM -Name $Name -MemoryStartupBytes ($StartupGB * 1GB) -Generation 2 -SwitchName $SwitchName -Path "$Script:StoragePath\VMs" -NoVHD | Out-Null

    # 5. Attach OS disk
    Add-VMHardDiskDrive -VMName $Name -Path $diffDisk -ControllerType SCSI

    # 6. Attach data disk (if created)
    if ($DataDiskGB -gt 0) {
        Add-VMHardDiskDrive -VMName $Name -Path $dataDisk -ControllerType SCSI
    }

    # 7. CPU
    Set-VMProcessor -VMName $Name -Count $VCPU

    # 8. Dynamic memory (min 512 MB, startup may be lower than max so VM fits on constrained host)
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true -MinimumBytes 512MB -StartupBytes ($StartupGB * 1GB) -MaximumBytes ($RamGB * 1GB)

    # 9. Disable Secure Boot (eval VHDX not signed)
    Set-VMFirmware -VMName $Name -EnableSecureBoot Off

    # 10. Boot from OS disk
    Set-VMFirmware -VMName $Name -FirstBootDevice (Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1)

    # 11. Disable automatic checkpoints
    Set-VM -VMName $Name -AutomaticCheckpointsEnabled $false

    # 12. Auto-start when host boots (staggered by dependency order)
    Set-VM -VMName $Name -AutomaticStartAction Start -AutomaticStartDelay $AutoStartDelay

    # 13. Start VM
    Start-VM -Name $Name
    Write-Host "$Name started. Waiting for VM to accept Hyper-V direct WinRM..."
    Wait-LabVMRemoting -VMName $Name -AdminPassword $AdminPassword

    # 14. Convert Eval -> Datacenter (self-contained: reboots + waits for WinRM
    #     to come back + re-disables the firewall that conversion re-enables).
    Convert-LabVMEdition -VMName $Name -AdminPassword $AdminPassword

    Get-VM $Name | Select-Object Name, State, Uptime, @{N='MemoryMB';E={$_.MemoryAssigned/1MB}} | Format-Table -AutoSize
}

# --- Wait until Hyper-V direct WinRM responds (means FirstLogonCommands set up auth) ---

function Wait-LabVMRemoting {
    param(
        [Parameter(Mandatory)] [string]$VMName,
        [string]$AdminPassword = 'LabAdmin@2026!',
        [int]$TimeoutSec = 900
    )
    $cred = New-Object PSCredential('Administrator', (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $attempts = 0
    while ((Get-Date) -lt $deadline) {
        $attempts++
        $vm = Get-VM $VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -eq 'Running' -and $vm.Heartbeat -like 'Ok*') {
            try {
                $hn = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
                if ($hn) {
                    Write-Host "  $VMName WinRM ready (hostname=$hn, $attempts attempts)"
                    return
                }
            } catch {
                # WinRM not yet available, keep polling
            }
        }
        Start-Sleep -Seconds 15
    }
    throw "Timeout waiting for $VMName WinRM after $TimeoutSec sec ($attempts attempts)"
}

# --- Edition conversion: Evaluation -> retail (escapes eval shutdown timer) ---

function Convert-LabVMEdition {
    param(
        [Parameter(Mandatory)] [string]$VMName,
        [string]$Edition       = 'ServerDatacenter',
        [string]$ProductKey    = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF',  # WS2025 Datacenter KMS client setup key
        [string]$AdminPassword = 'LabAdmin@2026!'
    )
    $cred = New-Object PSCredential('Administrator', (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))

    $current = Invoke-Command -VMName $VMName -Credential $cred -ErrorAction Stop -ScriptBlock {
        $line = (DISM /online /Get-CurrentEdition 2>&1) | Select-String 'Current Edition' | Select-Object -First 1
        if ($line) { ($line.Line -split ':')[-1].Trim() }
    }

    if ($current -eq $Edition) {
        Write-Host "$VMName already $Edition - skipping conversion."
        return
    }
    Write-Host "Converting $VMName from $current -> $Edition (DISM /Set-Edition)..."

    $exitCode = Invoke-Command -VMName $VMName -Credential $cred -ArgumentList $Edition, $ProductKey -ErrorAction Stop -ScriptBlock {
        param($Ed, $Key)
        $out = & DISM /Online /Set-Edition:$Ed /ProductKey:$Key /AcceptEula /Norestart 2>&1
        $code = $LASTEXITCODE
        $out | Set-Content 'C:\Windows\Temp\set-edition.log' -Encoding ASCII
        $code
    }
    if ($exitCode -ne 0 -and $exitCode -ne 3010) {
        throw "DISM /Set-Edition on $VMName returned exit $exitCode (expected 0 or 3010)"
    }
    Write-Host "  DISM exit $exitCode (3010 = success, reboot required)"

    Write-Host "  Rebooting $VMName to finalize edition change..."
    try {
        Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
            & shutdown /r /t 3 /c "Edition conversion reboot"
        } -ErrorAction Stop
    } catch {
        Write-Host "  In-VM reboot failed ($($_.Exception.Message)) - using host-side Restart-VM" -ForegroundColor Yellow
        Restart-VM -Name $VMName -Force -Confirm:$false
    }
    # Give Windows time to actually start shutting down before we begin polling
    Start-Sleep -Seconds 30

    # Wait for WinRM to be reachable again after the post-conversion boot
    Wait-LabVMRemoting -VMName $VMName -AdminPassword $AdminPassword

    # Edition conversion re-enables Windows Firewall (default security baseline reapplied).
    # Disable it again so the lab subnet stays freely reachable.
    Write-Host "  Re-disabling firewall on $VMName (conversion re-enabled it)..."
    Invoke-Command -VMName $VMName -Credential $cred -ErrorAction Stop -ScriptBlock {
        Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    }
    Write-Host "  $VMName conversion complete and firewall re-disabled."
}

# --- Wait for VM to be reachable after a reboot or boot ---

function Wait-LabVMReady {
    param(
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$IP,
        [int]$TimeoutSec = 600
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-Host "  Waiting for $VMName ($IP) to be reachable..."
    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM $VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -eq 'Running' -and $vm.Heartbeat -like 'Ok*') {
            if (Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                Write-Host "  $VMName ready (heartbeat=$($vm.Heartbeat), ping OK)"
                return
            }
        }
        Start-Sleep -Seconds 10
    }
    Write-Host "  Timeout waiting for $VMName after $TimeoutSec sec" -ForegroundColor Yellow
}

# --- Wait for VM OOBE completion (via KVP) ------------------------------------

function Wait-LabVMOOBE {
    param(
        [Parameter(Mandatory)] [string]$VMName,
        [int]$TimeoutSec = 600
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $kvpItems = (Get-WmiObject -Namespace 'root\virtualization\v2' `
            -Query "SELECT GuestExchangeItems FROM Msvm_KvpExchangeComponent WHERE SystemName = '$((Get-VM $VMName).Id)'" `
            -ErrorAction SilentlyContinue).GuestExchangeItems

        if ($kvpItems) {
            foreach ($item in $kvpItems) {
                $xml = [xml]$item
                $kvpName  = ($xml.INSTANCE.PROPERTY | Where-Object { $_.NAME -eq 'Name' }).VALUE
                $kvpValue = ($xml.INSTANCE.PROPERTY | Where-Object { $_.NAME -eq 'Data' }).VALUE
                if ($kvpName -eq 'OOBEComplete' -and $kvpValue -eq $VMName) {
                    Write-Host "$VMName OOBE complete - VM is ready."
                    return
                }
            }
        }
        Start-Sleep -Seconds 10
    }
    Write-Host "WARNING: Timeout waiting for $VMName OOBE after $TimeoutSec seconds." -ForegroundColor Yellow
}
