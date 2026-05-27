<#
.SYNOPSIS
    Full bootstrap for Hyper-V Host A (Site A). Runs via Azure Custom Script Extension.

.DESCRIPTION
    Executes in phases, surviving a mandatory reboot after Hyper-V install:

    Phase Init         : Disable firewall, configure WinRM, install Tailscale,
                         install Hyper-V, register post-reboot scheduled task, reboot.
    Phase PostReboot   : Create vSwitches, download VHDX + media, create SMB share,
                         create + start all VMs, deploy MCP server + shutdown timer.

    Each VM gets a differencing disk from a shared parent VHDX, with an injected
    unattend.xml that sets hostname, static IP, admin password, and Israel timezone.
    VMs boot directly to desktop with no OOBE wizard.

.PARAMETER AdminPassword
    Password injected into all nested VMs via unattend.xml.

.PARAMETER TailscaleAuthKey
    Pre-auth key for Tailscale registration. Generate at https://login.tailscale.com/admin/settings/keys

.NOTES
    Author   : SADAB Lab
    Version  : 2.0
    Requires : Windows Server 2022 Datacenter host, internet access, Hyper-V capable VM size
    DO NOT   : Use Write-Log - conflicts with PowerCLI. Use Write-LabLog.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdminPassword,

    [Parameter(Mandatory = $true)]
    [string]$TailscaleAuthKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Site configuration -------------------------------------------------------

$SiteName       = 'A'
$SiteSubnet     = '10.10.0'          # Nested VMs: $SiteSubnet.<IPOctet>
$HostVswitchIP  = '10.10.0.1'        # IP assigned to host on internal vSwitch
$SwitchName     = "Lab"
$StoragePath    = 'C:\HyperV-Lab'
$LogFile        = "$StoragePath\bootstrap.log"
$StateFile      = "$StoragePath\.bootstrap-phase"
$ParentVhdxPath = "$StoragePath\Base\WS2025-Eval.vhdx"
$MediaPath      = "$StoragePath\Media"
$FilesPath      = "$StoragePath\Files"
$DropboxUrl     = 'https://www.dropbox.com/scl/fo/v4apolfdhoy68bsbox771/ADClA8fZTTJuc1Iq4lSCS4Y?rlkey=63zgx1alcuthas53xgoo89dst&dl=1'
$DnsServer      = '168.63.129.16'    # Azure DNS - update to DC-A IP after DC promotion

$VmDefinitions = @(
    [PSCustomObject]@{ Name = 'A-DC';       RamGB = 4;  VCPU = 2; DiskGB = 60;  IPOctet = '2'  }
    [PSCustomObject]@{ Name = 'A-SCCM';     RamGB = 12; VCPU = 4; DiskGB = 150; IPOctet = '3'  }
    [PSCustomObject]@{ Name = 'A-SQLSCCM';  RamGB = 8;  VCPU = 4; DiskGB = 150; IPOctet = '4'  }
    [PSCustomObject]@{ Name = 'A-MPDP';     RamGB = 6;  VCPU = 2; DiskGB = 100; IPOctet = '5'  }
    [PSCustomObject]@{ Name = 'A-DFSR';     RamGB = 4;  VCPU = 2; DiskGB = 150; IPOctet = '7'  }
    [PSCustomObject]@{ Name = 'A-SCOM';     RamGB = 8;  VCPU = 4; DiskGB = 100; IPOctet = '40' }
    [PSCustomObject]@{ Name = 'A-SQLSCOM';  RamGB = 8;  VCPU = 2; DiskGB = 100; IPOctet = '41' }
)

# --- No individual download URLs needed - all files come from Dropbox zip ---

# --- Logging ------------------------------------------------------------------

function Write-LabLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts][$Level] $Message"
    $color = switch ($Level) {
        'INFO'    { 'Cyan'   }
        'SUCCESS' { 'Green'  }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
    }
    Write-Host $entry -ForegroundColor $color
    Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
}

# --- Storage paths ------------------------------------------------------------

function Initialize-LabStoragePaths {
    [CmdletBinding()]
    param()

    foreach ($path in @("$StoragePath\Base", "$StoragePath\VMs", "$StoragePath\VHDs", "$StoragePath\Snapshots", $MediaPath)) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write-LabLog "Created: $path" -Level SUCCESS
        }
    }
    if (Get-Command Set-VMHost -ErrorAction SilentlyContinue) {
        Set-VMHost -VirtualMachinePath "$StoragePath\VMs" `
                   -VirtualHardDiskPath "$StoragePath\VHDs" `
                   -ErrorAction SilentlyContinue
    }
}

# --- Hyper-V install ----------------------------------------------------------

function Install-HyperVWithRebootTask {
    [CmdletBinding()]
    param()

    if ((Get-WindowsFeature -Name Hyper-V).InstallState -eq 'Installed') {
        Write-LabLog 'Hyper-V already installed.' -Level SUCCESS
        return $false
    }

    Write-LabLog 'Installing Hyper-V role + management tools...'
    Install-WindowsFeature -Name Hyper-V, Hyper-V-PowerShell -IncludeManagementTools -Restart:$false | Out-Null

    $scriptPath = $MyInvocation.PSCommandPath
    $action     = New-ScheduledTaskAction -Execute 'powershell.exe' `
                      -Argument "-NonInteractive -ExecutionPolicy Unrestricted -File `"$scriptPath`" -AdminPassword `"$AdminPassword`" -TailscaleAuthKey `"$TailscaleAuthKey`""
    $trigger    = New-ScheduledTaskTrigger -AtStartup
    $principal  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

    Register-ScheduledTask -TaskName 'LabBootstrap-Continue' `
                           -Action $action -Trigger $trigger -Principal $principal `
                           -Description 'SADAB Lab: continue Hyper-V bootstrap after reboot' `
                           -Force | Out-Null

    Set-Content -Path $StateFile -Value 'PostReboot'
    Write-LabLog 'Hyper-V installed. Rebooting host...' -Level WARN
    Restart-Computer -Force
    return $true
}

# --- Tailscale install --------------------------------------------------------

function Install-Tailscale {
    [CmdletBinding()]
    param()

    if (Get-Command tailscale -ErrorAction SilentlyContinue) {
        Write-LabLog 'Tailscale already installed.' -Level SUCCESS
    } else {
        Write-LabLog 'Downloading and installing Tailscale...'
        $installer = "$env:TEMP\tailscale-setup.msi"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' `
                          -OutFile $installer -UseBasicParsing
        $ProgressPreference = 'Continue'
        Start-Process msiexec.exe -ArgumentList "/i `"$installer`" /quiet /norestart" -Wait
        # Add to PATH for this session
        $env:PATH += ';C:\Program Files\Tailscale'
        Write-LabLog 'Tailscale installed.' -Level SUCCESS
    }

    # Authenticate and advertise nested VM subnets for direct access from PC
    $tsStatus = & tailscale status --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $tsStatus -or $tsStatus.BackendState -ne 'Running') {
        Write-LabLog "Joining tailnet with subnet routing for $SiteSubnet.0/24..."
        & tailscale up --authkey $TailscaleAuthKey --advertise-routes="$SiteSubnet.0/24" --accept-routes --unattended
        Write-LabLog "Tailscale connected. Advertising $SiteSubnet.0/24" -Level SUCCESS
    } else {
        Write-LabLog 'Tailscale already connected.' -Level SUCCESS
    }
}

# --- Chocolatey + tools -------------------------------------------------------

function Install-HostTools {
    [CmdletBinding()]
    param()

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-LabLog 'Chocolatey already installed.' -Level SUCCESS
    } else {
        Write-LabLog 'Installing Chocolatey...'
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = "$env:ProgramData\chocolatey\bin;$env:Path"
        Write-LabLog 'Chocolatey installed.' -Level SUCCESS
    }

    foreach ($pkg in @('7zip', 'notepadplusplus', 'git.install', 'claude-code')) {
        $chocoOut = cmd /c "choco install $pkg -y --no-progress 2>&1"
        Write-LabLog "Installed: $pkg" -Level SUCCESS
    }
}

# --- Virtual switch -----------------------------------------------------------

function New-LabInternalSwitch {
    [CmdletBinding()]
    param()

    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $SwitchName -SwitchType Internal
        Write-LabLog "Created vSwitch: $SwitchName" -Level SUCCESS
    }

    $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$SwitchName*" }
    if ($adapter) {
        $existing = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $HostVswitchIP -PrefixLength 24 | Out-Null
            Write-LabLog "Assigned $HostVswitchIP/24 to vSwitch host adapter" -Level SUCCESS
        }
    }
}

# --- VHDX download ------------------------------------------------------------

# --- Download all lab files from Dropbox --------------------------------------

function Get-LabFiles {
    [CmdletBinding()]
    param()

    # Check if files already extracted (VHDX is the largest/last file)
    if (Test-Path $ParentVhdxPath) {
        $sizeMB = (Get-Item $ParentVhdxPath).Length / 1MB
        if ($sizeMB -gt 3000) {
            try {
                Test-VHD -Path $ParentVhdxPath -ErrorAction Stop | Out-Null
                Write-LabLog "Lab files already present (VHDX valid, $([math]::Round($sizeMB)) MB) - skipping download." -Level SUCCESS
                return
            } catch {
                Write-LabLog "Existing VHDX is invalid - re-downloading all files." -Level WARN
            }
        }
    }

    $zipPath = "$StoragePath\LabFiles.zip"

    # Download zip from Dropbox (~20 GB)
    if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 1GB) {
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Write-LabLog 'Downloading lab files from Dropbox (~20 GB)...'
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $DropboxUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 14400
        } catch {
            Write-LabLog "Dropbox download failed: $_" -Level ERROR
            throw
        } finally {
            $ProgressPreference = 'Continue'
        }
        Write-LabLog "Downloaded: $zipPath ($([math]::Round((Get-Item $zipPath).Length / 1MB)) MB)" -Level SUCCESS
    } else {
        Write-LabLog "Zip already downloaded ($([math]::Round((Get-Item $zipPath).Length / 1MB)) MB) - skipping." -Level SUCCESS
    }

    # Extract to Files folder
    Write-LabLog 'Extracting lab files...'
    if (-not (Test-Path $FilesPath)) {
        New-Item -ItemType Directory -Path $FilesPath -Force | Out-Null
    }
    Expand-Archive -Path $zipPath -DestinationPath $FilesPath -Force
    Write-LabLog 'Extraction complete.' -Level SUCCESS

    # Dropbox wraps in a subfolder - find and flatten if needed
    $extracted = Get-ChildItem -Path $FilesPath -Directory | Select-Object -First 1
    if ($extracted -and (Test-Path "$($extracted.FullName)\Base")) {
        $innerPath = $extracted.FullName
        Write-LabLog "Moving files from $($extracted.Name) to $FilesPath..."
        Get-ChildItem -Path $innerPath | ForEach-Object {
            $dest = Join-Path $FilesPath $_.Name
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            Move-Item -Path $_.FullName -Destination $dest -Force
        }
        Remove-Item $innerPath -Force -ErrorAction SilentlyContinue
    }

    # Move VHDX to Base folder
    $vhdxSrc = "$FilesPath\Base\WS2025-Eval.vhdx"
    if (Test-Path $vhdxSrc) {
        $baseDir = Split-Path $ParentVhdxPath -Parent
        if (-not (Test-Path $baseDir)) { New-Item -ItemType Directory -Path $baseDir -Force | Out-Null }
        if ($vhdxSrc -ne $ParentVhdxPath) {
            Move-Item -Path $vhdxSrc -Destination $ParentVhdxPath -Force
        }
        Test-VHD -Path $ParentVhdxPath -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $ParentVhdxPath -Name IsReadOnly -Value $true
        Write-LabLog "VHDX validated: $ParentVhdxPath" -Level SUCCESS
    }

    # Copy media folders to Media path
    $mediaFolders = @('SQL', 'SCCM', 'SCOM', 'ADK', 'ADKPE', 'SSMS', 'SSRS', 'WebView2', 'ReportBuilder', 'ODBC18', 'SQLCLRTypes', 'Applications')
    foreach ($folder in $mediaFolders) {
        $src = "$FilesPath\$folder"
        if (Test-Path $src) {
            $dst = "$MediaPath\$folder"
            if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
            Copy-Item -Path "$src\*" -Destination $dst -Recurse -Force
            Write-LabLog "Staged media: $folder" -Level SUCCESS
        }
    }

    # Clean up zip and extracted files to free disk space
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $FilesPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-LabLog 'Lab files staging complete. Temp files cleaned up.' -Level SUCCESS
}

# --- SMB share ----------------------------------------------------------------

function New-LabMediaShare {
    [CmdletBinding()]
    param()

    $shareName = 'LabMedia'
    if (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue) {
        Write-LabLog "SMB share '$shareName' already exists." -Level SUCCESS
        return
    }

    New-SmbShare -Name $shareName -Path $MediaPath -FullAccess 'Everyone' | Out-Null
    Write-LabLog "Created SMB share: \\$env:COMPUTERNAME\$shareName -> $MediaPath" -Level SUCCESS

    # Share Base folder so Host B can copy the VHDX instead of downloading
    $baseShareName = 'LabBase'
    if (-not (Get-SmbShare -Name $baseShareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $baseShareName -Path "$StoragePath\Base" -FullAccess 'Everyone' | Out-Null
        Write-LabLog "Created SMB share: \\$env:COMPUTERNAME\$baseShareName -> $StoragePath\Base" -Level SUCCESS
    }
}

# --- Unattend.xml generation --------------------------------------------------

function New-VMUnattendXml {
    [CmdletBinding()]
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
        <LogonCount>1</LogonCount>
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
          <CommandLine>powershell -NoProfile -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck; Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force; Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true; Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true"</CommandLine>
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
      </FirstLogonCommands>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>he-IL</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-IL</UserLocale>
    </component>
  </settings>
</unattend>
"@
}

# --- Unattend injection into VHDX ---------------------------------------------

function Add-UnattendToVhdx {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VhdxPath,
        [Parameter(Mandatory)] [string]$UnattendContent
    )

    Write-LabLog "  Mounting: $VhdxPath"
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
        Write-LabLog "  Injected unattend.xml -> ${drive}:\Windows\Panther\" -Level SUCCESS
    } finally {
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
    }
}

# --- Nested VM creation -------------------------------------------------------

function New-LabNestedVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Definition
    )

    $name   = $Definition.Name
    $ip     = "$SiteSubnet.$($Definition.IPOctet)"
    $gw     = $HostVswitchIP
    $diff   = "$StoragePath\VHDs\$name-OS.vhdx"

    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
        Write-LabLog "VM '$name' already exists - skipping." -Level WARN
        return
    }

    Write-LabLog "Creating VM: $name | $ip | $($Definition.RamGB)GB | $($Definition.VCPU) vCPU"

    # 1. Differencing disk
    New-VHD -Path $diff -ParentPath $ParentVhdxPath -Differencing | Out-Null

    # 2. Inject unattend.xml
    $xml = New-VMUnattendXml -ComputerName $name -IPAddress $ip -Gateway $gw -AdminPassword $AdminPassword
    Add-UnattendToVhdx -VhdxPath $diff -UnattendContent $xml

    # 3. Create VM shell (Generation 2, no disk - attach differencing disk next)
    New-VM -Name $name `
           -MemoryStartupBytes ($Definition.RamGB * 1GB) `
           -Generation 2 `
           -SwitchName $SwitchName `
           -Path "$StoragePath\VMs" `
           -NoVHD | Out-Null

    # 4. Attach differencing disk on SCSI controller
    Add-VMHardDiskDrive -VMName $name -Path $diff -ControllerType SCSI

    # 5. vCPU count
    Set-VMProcessor -VMName $name -Count $Definition.VCPU

    # 6. Dynamic memory - min 512 MB, max = startup (prevents host OOM)
    Set-VMMemory -VMName $name `
                 -DynamicMemoryEnabled $true `
                 -MinimumBytes 512MB `
                 -StartupBytes ($Definition.RamGB * 1GB) `
                 -MaximumBytes ($Definition.RamGB * 1GB)

    # 7. Expose nested virt extensions on SQL + SCCM VMs
    if ($name -like 'SQL-*' -or $name -like 'SCCM-*') {
        Set-VMProcessor -VMName $name -ExposeVirtualizationExtensions $true
    }

    # 8. Disable Secure Boot - eval VHDX is not signed
    Set-VMFirmware -VMName $name -EnableSecureBoot Off

    # 9. Set boot device to SCSI disk
    Set-VMFirmware -VMName $name -FirstBootDevice (Get-VMHardDiskDrive -VMName $name)

    # 10. Disable automatic checkpoints
    Set-VM -VMName $name -AutomaticCheckpointsEnabled $false

    # 11. Auto-start when host boots (for Start-Lab / Stop-Lab cycle)
    Set-VM -VMName $name -AutomaticStartAction Start -AutomaticStartDelay 30

    # 12. Start VM
    Start-VM -Name $name
    Write-LabLog "Started: $name ($ip)" -Level SUCCESS
}

# --- Main ---------------------------------------------------------------------

# Ensure log directory exists before anything else
New-Item -ItemType Directory -Path $StoragePath -Force | Out-Null

Write-LabLog '================================================================'
Write-LabLog "Bootstrap-HostA.ps1 started - Site $SiteName"

$phase = if (Test-Path $StateFile) { (Get-Content $StateFile -Raw).Trim() } else { 'Init' }
Write-LabLog "Bootstrap phase: $phase"

switch ($phase) {

    'Init' {
        Initialize-LabStoragePaths

        # 1. Disable firewall (host reachable immediately after Tailscale)
        Write-LabLog 'Disabling Windows Firewall (all profiles)...'
        Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled False
        Write-LabLog 'Firewall disabled.' -Level SUCCESS

        # 2. Configure WinRM (host accepts remote commands via Tailscale)
        Write-LabLog 'Configuring WinRM...'
        Enable-PSRemoting -Force -SkipNetworkProfileCheck
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
        Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
        Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
        Write-LabLog 'WinRM configured.' -Level SUCCESS

        # 3. Install Tailscale (host appears on tailnet before Hyper-V reboot)
        Install-Tailscale

        # 3b. Register Ensure-Tailscale task (re-auths on every boot if logged out)
        $ensureScript = "$StoragePath\Ensure-Tailscale.ps1"
        Copy-Item -Path (Join-Path $PSScriptRoot 'Ensure-Tailscale.ps1') -Destination $ensureScript -Force
        # Save auth key + subnet for future boots
        Set-Content -Path "$StoragePath\.ts-authkey" -Value "$TailscaleAuthKey|$SiteSubnet.0/24" -Force

        $tsAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                         -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $ensureScript"
        $tsTrigger   = New-ScheduledTaskTrigger -AtStartup
        $tsPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $tsSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName 'EnsureTailscale' -Action $tsAction -Trigger $tsTrigger `
                     -Principal $tsPrincipal -Settings $tsSettings `
                     -Description 'Ensures Tailscale is authenticated on every boot' -Force | Out-Null
        Write-LabLog 'EnsureTailscale scheduled task registered (at startup).' -Level SUCCESS

        # 4. Chocolatey + tools (7zip, notepad++, git, claude-code)
        Install-HostTools

        # 5. Install Hyper-V + reboot
        $rebooting = Install-HyperVWithRebootTask
        if (-not $rebooting) {
            Set-Content -Path $StateFile -Value 'PostReboot'
            & $PSCommandPath -AdminPassword $AdminPassword -TailscaleAuthKey $TailscaleAuthKey
        }
    }

    'PostReboot' {
        Write-LabLog 'Continuing after Hyper-V reboot...'
        Unregister-ScheduledTask -TaskName 'LabBootstrap-Continue' -Confirm:$false -ErrorAction SilentlyContinue
        Set-TimeZone -Id 'Israel Standard Time'
        Set-ItemProperty -Path 'Registry::HKEY_USERS\.DEFAULT\Control Panel\International' -Name 'sShortTime' -Value 'HH:mm'
        Set-ItemProperty -Path 'Registry::HKEY_USERS\.DEFAULT\Control Panel\International' -Name 'sTimeFormat' -Value 'HH:mm:ss'
        Write-LabLog 'Timezone set to Israel Standard Time (24H clock).'
        Initialize-LabStoragePaths

        # CSE downloads files to same dir as bootstrap script
        $cseDir = $PSScriptRoot

        # -- 1. Deploy MCP server (reachable ASAP after reboot) ----------------
        Write-LabLog 'Deploying MCP server...'

        $mcpDir = "$StoragePath\MCP"
        New-Item -ItemType Directory -Path $mcpDir -Force | Out-Null
        Copy-Item -Path (Join-Path $cseDir 'Start-LabMCPServer.ps1') -Destination "$mcpDir\Start-LabMCPServer.ps1" -Force

        # URL ACL for HTTP listener on all interfaces
        & netsh http add urlacl url=http://+:3100/ user=Everyone 2>&1 | Out-Null
        Write-LabLog 'URL ACL registered for port 3100'

        # Register MCP server task - runs at startup, restarts on failure
        $mcpAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                          -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mcpDir\Start-LabMCPServer.ps1`" -AdminPassword `"$AdminPassword`""
        $mcpTrigger   = New-ScheduledTaskTrigger -AtStartup
        $mcpPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $mcpSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName 'LabMCPServer' -Action $mcpAction -Trigger $mcpTrigger `
                     -Principal $mcpPrincipal -Settings $mcpSettings `
                     -Description 'MCP server for Claude Code (HTTP on port 3100 via Tailscale)' -Force | Out-Null

        # Start MCP server immediately
        Start-ScheduledTask -TaskName 'LabMCPServer'
        Write-LabLog 'LabMCPServer scheduled task registered and started.' -Level SUCCESS

        # -- 2. Deploy shutdown timer with PSADT deferral UI -------------------
        Write-LabLog 'Deploying PSADT-based shutdown timer...'

        # Copy shutdown timer script
        Copy-Item -Path (Join-Path $cseDir 'Start-ShutdownTimer.ps1') -Destination "$StoragePath\Start-ShutdownTimer.ps1" -Force

        # Extract PSADT package
        $labShutdownPath = "$StoragePath\LabShutdown"
        New-Item -ItemType Directory -Path $labShutdownPath -Force | Out-Null
        Expand-Archive -Path (Join-Path $cseDir 'LabShutdown.zip') -DestinationPath $labShutdownPath -Force
        Write-LabLog 'PSADT package extracted to C:\HyperV-Lab\LabShutdown'

        # Register shutdown timer task - runs every 5 minutes
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                       -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\HyperV-Lab\Start-ShutdownTimer.ps1'
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName 'LabShutdownTimer' -Action $action -Trigger $trigger `
                     -Principal $principal -Settings $settings `
                     -Description 'Lab auto-shutdown timer with PSADT deferral UI (polls every 5 min)' -Force | Out-Null
        Write-LabLog 'LabShutdownTimer scheduled task registered (every 5 min).' -Level SUCCESS

        # -- 3. vSwitch, downloads, VMs ----------------------------------------
        New-LabInternalSwitch
        Get-LabFiles
        New-LabMediaShare

        Write-LabLog "Creating $($VmDefinitions.Count) nested VMs..."
        foreach ($def in $VmDefinitions) {
            New-LabNestedVM -Definition $def
        }

        Set-Content -Path $StateFile -Value 'Complete'
        Write-LabLog '================================================================' -Level SUCCESS
        Write-LabLog 'Bootstrap complete. All VMs created and started.'             -Level SUCCESS
        Write-LabLog "Access via Tailscale. Nested VMs at $SiteSubnet.x"            -Level INFO
        Write-LabLog "Media share: \\$env:COMPUTERNAME\LabMedia"                    -Level INFO
        Write-LabLog '================================================================' -Level SUCCESS

        Get-VM | Select-Object Name, State,
            @{N='RAM(GB)';  E={ [math]::Round($_.MemoryAssigned / 1GB, 1) }},
            @{N='vCPU';     E={ $_.ProcessorCount }} |
            Format-Table -AutoSize
    }

    'Complete' {
        Write-LabLog 'Bootstrap already complete.' -Level SUCCESS
        Get-VM | Select-Object Name, State | Format-Table -AutoSize
    }

    default {
        Write-LabLog "Unknown phase '$phase' - resetting to Init." -Level WARN
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        & $PSCommandPath -AdminPassword $AdminPassword -TailscaleAuthKey $TailscaleAuthKey
    }
}
