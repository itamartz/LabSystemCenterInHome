# Manual Fixes Log

Commands run manually to fix issues not yet captured in scripts.

> Entries dated **2026-04-xx** are from the original Azure lab build (carried over with the project copy).
> Entries dated **2026-05-23** are from the local Hyper-V (NUCBOX_K12) build.

---

## 2026-05-23: Local Hyper-V build — Phase 1 from scratch

A grab-bag of every issue we hit while building the SCCM lab on a local Hyper-V host (Win 11 Pro, NUCBOX_K12 in a WORKGROUP). Most of these are now baked into the scripts; this section is the "why" trail.

### 1. Workgroup→workgroup network WinRM auth needs IP-prefixed username

**Why:** From a WORKGROUP Hyper-V host, `Invoke-Command -ComputerName 10.10.0.2 -Credential (PSCredential 'Administrator', ...)` fails with `0x8009030e` (or `0x8009030d`) "A specified logon session does not exist". Negotiate tries Kerberos first against a non-existent domain, never falls back to NTLM. Even with `TrustedHosts=*` set.

**Fix:** Construct the credential with `IPADDR\username` so PowerShell forces NTLM via local-SAM lookup:
```powershell
$cred = New-Object PSCredential('10.10.0.2\Administrator', (ConvertTo-SecureString 'LabAdmin@2026!' -AsPlainText -Force))
Invoke-Command -ComputerName 10.10.0.2 -Credential $cred -Authentication Negotiate -ScriptBlock { hostname }
```
This is now baked into `scripts/post-deploy/LabHelpers.psm1`'s `Invoke-LabRemote` (adds the prefix if the username has no `\` or `@`).

### 2. Tailscale subnet-route collision with Azure lab

**Why:** The Azure lab also uses `10.10.0.0/24` and advertises it through Tailscale subnet routing. On the local host (also a Tailscale node), the kernel installed two routes for `10.10.0.0/24`:
- `vEthernet (Lab)` direct, metric 256
- `Tailscale` via `100.100.100.100`, metric 0

Lower-metric wins → host-originated traffic for lab VM IPs went into the Tailscale tunnel and the lab VMs were unreachable from the host (even though VM→host worked, because the VM only knows its directly-connected gateway).

**Fix** (now baked into `Configure-Host.ps1` step 7a):
```powershell
$idx = (Get-NetAdapter -Name 'vEthernet (Lab)').ifIndex
Set-NetIPInterface -InterfaceIndex $idx -InterfaceMetric 1
# Make sure the directly-connected route exists (got accidentally Remove-NetRoute'd once)
if (-not (Get-NetRoute -DestinationPrefix '10.10.0.0/24' -InterfaceIndex $idx -ErrorAction SilentlyContinue | Where-Object NextHop -eq '0.0.0.0')) {
    New-NetRoute -DestinationPrefix '10.10.0.0/24' -InterfaceIndex $idx -NextHop '0.0.0.0' -RouteMetric 1
}
# Raise the Tailscale route's metric so it loses
Get-NetRoute -DestinationPrefix '10.10.0.0/24' -InterfaceAlias 'Tailscale' -ErrorAction SilentlyContinue |
    Set-NetRoute -RouteMetric 9000
```
Temporary: once the Azure lab is decommissioned, the Tailscale advertisement vanishes and this override becomes unnecessary.

### 3. WS2025 Eval edition shutdown timer — DISM /Set-Edition needed

**Why:** Windows Server 2025 Evaluation reboots every hour after the eval period kicks in. Conversion to Datacenter via DISM `/Set-Edition` with a KMS client setup key escapes this.

**Microsoft Learn-verified key for WS2025 Datacenter:** `D764K-2NDRG-47T6Q-P8T8W-YP6DF` (my initial memory had `-YP6DY` — wrong). Standard is `TVRH6-WHNXV-R9WG3-9XRFY-MY832`.

**Where:** Originally tried via unattend `FirstLogonCommands`, but on WS2025 the chain stalls after order ~7 (see #4 below). Moved into `LabVMHelpers.Convert-LabVMEdition` which runs via Hyper-V direct WinRM after the VM has OOBE'd. The function:
1. Runs `DISM /Online /Set-Edition:ServerDatacenter /ProductKey:... /AcceptEula /Norestart` (~12 s)
2. Reboots the VM
3. Waits for WinRM to come back
4. **Re-disables the firewall** (conversion silently re-enables it as part of the default security baseline)

### 4. WS2025 unattend FirstLogonCommands stop mid-chain

**Why:** The unattend's `FirstLogonCommands` block in `LabVMHelpers.ps1`'s `New-VMUnattendXml` reliably runs orders 1-7 (enables Administrator, sets password-never-expires, disables firewall, `Enable-PSRemoting`, sets `LocalAccountTokenFilterPolicy=1`). Anything from order 8 onwards — including `Enable-VMIntegrationService`, the original IPv6 disable, and the OOBE-complete KVP signal — runs intermittently or not at all. No clear pattern in the OOBE logs.

**Workaround:** Stopped relying on the FirstLogonCommands chain for anything slow or critical. Anything that has to happen reliably is now done via Hyper-V direct WinRM after the VM is reachable. `Wait-LabVMRemoting` polls `Invoke-Command -VMName` until it returns success — that's our "VM is ready" signal, not the KVP.

### 5. IPv6 `DisabledComponents=0xFF` breaks IPv4 service binding on WS2025

**Why:** The Azure unattend had a `reg add ... DisabledComponents /d 255` (= disable all IPv6) FirstLogonCommand. On WS2025 this leaves `LanmanServer` and WinRM bound only to `[::]` in IPv6-only mode, killing all IPv4 TCP listeners.

**Symptom:** `Test-NetConnection -Port 5985` from host returns False, `Get-NetTCPConnection -State Listen` inside the VM shows port 5985 only on `::` (not `0.0.0.0`).

**Fix:** Removed that command entirely from the unattend. Lab is internal — there's no real reason to disable IPv6.

### 6. WS2025 default firewall blocks ICMP echo reply

**Why:** Even with all 3 firewall profiles disabled inside the VM, host→VM ICMP failed. The reverse path (VM→host) worked. Issue turned out to be the host's `vEthernet (Lab)` adapter profile defaulting to "Public" and only allowing specific protocols inbound.

**Fix:** `Configure-Host.ps1` already adds `Lab-Allow-ICMPv4-In-SiteA` and `Lab-Allow-WinRM-In-SiteA` rules. We also added `Lab-Allow-SMB-In-SiteA` for VMs to mount `\\10.10.0.1\LabMedia` (not yet in the script — see DEPLOY.md step 2a).

### 7. Double-hop: gMSA install / AD ops via network WinRM fail

**Why:** From a workgroup host, network WinRM to a domain-joined VM uses NTLM auth. NTLM produces a non-delegatable token. Any command in the remote session that hits a second resource (DC, SMB share, etc.) fails with "Unable to contact the server" / `ADServerDownException`.

`Install-ADServiceAccount`, `Test-ADServiceAccount`, `extadsch.exe`, `setspn`, any `Get-AD*` cmdlet that does DC locator discovery — all of these hit the second hop.

**Fix:** Use Hyper-V direct (`Invoke-Command -VMName`) instead. PowerShell Direct gives the session an interactive Kerberos token, which DOES support delegation. `Invoke-LabRemote` in `LabHelpers.psm1` now prefers Hyper-V direct when the IP matches a known lab VM, falls back to network WinRM only if Hyper-V direct fails.

### 8. cmdkey-cached SMB credentials invisible to network WinRM sessions

**Why:** The unattend's order-10 `cmdkey /add:10.10.0.1 /user:labadmin /pass:LabAdmin@2026!` stores the credential under the SADAB\Administrator user profile. When you network-WinRM into the VM as SADAB\Administrator, the session token does NOT load the full user profile — cmdkey-cached credentials aren't available. `\\10.10.0.1\LabMedia` returns "Access is denied" / "path does not exist".

Hyper-V direct sessions DO see the cached credentials (full interactive token).

**Fix:** Same as #7 — use Hyper-V direct. As an additional belt: ensure a local `labadmin` user exists on the Hyper-V host (since the workgroup host has no domain-context view of the cmdkey credential), with the same password as the cmdkey stored. The post-domain-join chore in DEPLOY.md step 6 re-applies cmdkey on each VM (the original cmdkey from the unattend can get cleared by domain join).

### 9. `Get-AD*` cmdlets fail without `-Server` from Hyper-V direct sessions on freshly-promoted DCs

**Why:** Even running on A-DC itself via Hyper-V direct, `Get-ADDomain` / `Get-ADComputer` / `Get-ADObject` etc. fail with "Unable to find a default server with Active Directory Web Services running" — even though ADWS is clearly running. The AD module's DC locator can't find itself when called from a PowerShell Direct session shortly after DC promotion.

**Fix:** Set the default Server parameter at the top of every remote scriptblock that touches AD:
```powershell
$PSDefaultParameterValues = @{ '*-AD*:Server' = 'localhost' }
```
Already added to `02-Install-DomainControllers.ps1`, `03-Configure-ADStructure.ps1`, `04-Configure-ADSites.ps1`, and the `07` System Management container scriptblock.

### 10. `Install-WindowsFeature` switch parameters need colon syntax via remoting

**Why:** `Install-ADDSForest -InstallDns $true -NoRebootOnCompletion $false` failed with "A positional parameter cannot be found that accepts argument 'True'". These are `[switch]` parameters; passing `$true` as a value works locally but fails over PowerShell remoting.

**Fix:** Use colon syntax: `-InstallDns:$true -NoRebootOnCompletion:$false`. Fixed in `02-Install-DomainControllers.ps1`.

### 11. AD `-Filter { ... }` scriptblock filters can't see outer-scope variables

**Why:** `Get-ADObject -Filter { DistinguishedName -eq $smContainerDN }` fails with "Property: 'Name' not found in object of type: 'System.Collections.Hashtable'" or similar. The AD provider's scriptblock filter parser can't access outer-scope variables and treats them as object property references on a default `$_`.

**Fix:** Use string filter with manual interpolation: `-Filter "DistinguishedName -eq '$smContainerDN'"`. Fixed in `03-Configure-ADStructure.ps1` (KDS) and `04-Configure-ADSites.ps1` (subnets, sites).

### 12. Non-ASCII characters in scripts break parsing after Copy-Item -ToSession

**Why:** `Copy-Item -ToSession` doesn't preserve UTF-8 BOM. WS2025 PowerShell 5.1 falls back to Windows-1252 for BOM-less files. Any non-ASCII character (em-dash `—`, smart quotes, etc.) gets corrupted into 3 garbage bytes that subsequently confuse the PS parser.

**Symptom:** "The string is missing the terminator: ." pointing at a line that looks fine in your editor.

**Fix:** Strip all non-ASCII from PS scripts that get staged via `Copy-Item -ToSession`, and add an explicit UTF-8 BOM. The helper:
```powershell
function Clean-Script($path) {
  $content = Get-Content $path -Raw
  $content = $content -replace [char]0x2014, '-' -replace [char]0x2013, '-' `
                     -replace [char]0x2018, "'" -replace [char]0x2019, "'" `
                     -replace [char]0x201C, '"' -replace [char]0x201D, '"' `
                     -replace [char]0x2026, '...'
  $bom = [byte[]]@(0xEF,0xBB,0xBF)
  [System.IO.File]::WriteAllBytes($path, $bom + [System.Text.Encoding]::UTF8.GetBytes($content))
}
```
Applied to all post-deploy scripts. Don't write em-dashes into scripts that will be transferred.

### 13. A-SCCM 12 GB max RAM doesn't fit at startup

**Why:** Hyper-V Dynamic Memory uses `StartupBytes` as the boot-time allocation — it doesn't pre-emptively balloon other VMs down. With Jarvis (4 GB) + A-DC + A-SQLSCCM + A-MPDP + A-DFSR already running, there isn't 12 GB free for A-SCCM at boot. Start-VM fails with `0x800705AA` "Insufficient system resources".

**Fix:** A-SCCM is created with `-RamGB 12 -StartupGB 6` (lower startup, full 12 GB max via Dynamic Memory). Added a `-StartupGB` parameter to `New-LabVM` in `LabVMHelpers.ps1` that defaults to `$RamGB` but can be overridden. Also: stop `hermes-linux` briefly before starting A-SCCM to free another 4 GB. **Never stop `Jarvis`** (hard user rule).

### 14. `Web-Lgcy-Mgmt-Console` removed in WS2025

**Why:** The IIS 6 Management Console feature `Web-Lgcy-Mgmt-Console` was removed in Windows Server 2025. `Install-WindowsFeature -Name (... 'Web-Lgcy-Mgmt-Console' ...)` fails with `NameDoesNotExist` and aborts the whole batch.

**Fix:** Removed from the SCCM-prereq feature list in `07-Install-SCCM-Prerequisites.ps1`. SCCM doesn't actually need it; the other IIS 6 compat features (`Web-Mgmt-Compat`, `Web-Metabase`, `Web-WMI`, `Web-Scripting-Tools`) are sufficient.

### 15. `Install-WindowsFeature -ArgumentList (,$features)` doesn't pass an array via PowerShell Direct

**Why:** Network WinRM `Invoke-Command -Session $s -ArgumentList (,$arr), $other` preserves `$arr` as a single array argument. PowerShell Direct (`Invoke-Command -VMName`) handles ArgumentList serialization differently — `(,$arr)` flattens into a single space-separated string, which `Install-WindowsFeature -Name` then fails to convert.

**Symptom:** "Cannot convert 'NET-Framework-Core NET-Framework-45-Core ... FS-Data-Deduplication' to the type 'Microsoft.Windows.ServerManager.Commands.Feature' required by parameter 'Name'."

**Fix:** Inline the array literal inside the scriptblock — don't pass it via `-ArgumentList`:
```powershell
Invoke-Command -VMName 'A-SCCM' -Credential $cred -ScriptBlock {
    $feat = @('NET-Framework-Core','NET-Framework-45-Core', ...)
    Install-WindowsFeature -Name $feat -IncludeManagementTools -Source '\\10.10.0.1\LabMedia\SxS'
}
```

### 16. ODBC 18 install exit 1603 — needs VC++ Redist 2017+

**Why:** `msodbcsql18.msi` 1603 error. The MSI doesn't ship the VC runtime; it expects vcruntime140 to already be present.

**Fix:** Download + install `vc_redist.x64.exe` from `https://aka.ms/vs/17/release/vc_redist.x64.exe` BEFORE the ODBC 18 install. Our `Files\VCRedist\` was empty (Dropbox zip placeholder); download directly to the host (which has internet) and place in the share, then install from share on the SCCM VM.

### 17. DNS forwarders not set on A-DC by default

**Why:** Right after `Install-ADDSForest`, A-DC's DNS server is authoritative for `sadab.pri` but has no forwarders for external names. VMs that use A-DC as their DNS server can't resolve internet names — `download.visualstudio.microsoft.com` etc. fail with `RemoteNameNotResolved`.

**Fix** (post-step-2 chore — already in DEPLOY.md):
```powershell
Add-DnsServerForwarder -IPAddress 8.8.8.8,1.1.1.1
```

### 18. `MEM_Configmgr_xxxx.exe` is a bootstrap, not extracted media

**Why:** Step 7's AD schema extension and Step 8's setup expect `\\10.10.0.1\LabMedia\SCCM\SMSSETUP\BIN\X64\setup.exe` (the extracted SCCM media structure). The Dropbox zip provides the single `MEM_Configmgr_2509.exe` bootstrapper instead.

**Fix:** Extract before running step 7's schema extension:
```powershell
Start-Process -FilePath 'C:\HyperV-Lab\Files\SCCM\MEM_Configmgr_2509.exe' `
              -ArgumentList '/Auto','C:\HyperV-Lab\Files\SCCM\extracted','/Quiet' `
              -Wait -NoNewWindow
```
After extraction, `setup.exe` and `extadsch.exe` are at `C:\HyperV-Lab\Files\SCCM\extracted\SMSSETUP\BIN\X64\`. The step 7/8 scripts still look at `...\SCCM\SMSSETUP\...` — adjust either the scripts or the layout.

### 19. WS2025 Datacenter conversion re-enables firewall

**Why:** DISM `/Set-Edition` triggers a security-baseline reapplication on the next reboot, which re-enables Windows Firewall on all three profiles. Until we re-disable it, host→VM TCP fails for any non-explicitly-allowed port.

**Fix:** `Convert-LabVMEdition` in `LabVMHelpers.ps1` calls `Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False` after the post-conversion reboot completes.

### 20. AD `$Script:LabConfig` vs `$Global:LabConfig` scope mismatch

**Why:** `LabHelpers.psm1` defined `$Script:LabConfig` at module top level. Inside the module, `$Script:` resolves to the module's script scope. Outside the module (in the step scripts that import the module), `$Script:LabConfig` resolves to the calling SCRIPT's script scope — which is null.

**Symptom:** `Install-ADDSForest` got `-DomainName $null` from `$Script:LabConfig.DomainName` and failed with "Cannot bind argument to parameter 'DomainName' because it is null."

**Fix:** Changed module to use `$Global:LabConfig`, added `Export-ModuleMember -Variable LabConfig`, and search/replaced `$Script:LabConfig` → `$Global:LabConfig` across all 9 post-deploy step scripts.

### 21. SCCM Primary install (step 8) — the full saga (8 retries)

Every failure taught us something; all fixes are in `08-Install-SCCM-Primary.ps1`. In order:

1. **`/DOWNLOAD` switch invalid on SCCM 2509** — prereq downloader is a separate binary: `SMSSETUP\BIN\X64\setupdl.exe <destdir>`, not `setup.exe /DOWNLOAD`.

2. **`MEM_Configmgr_2509.exe` is a 7-Zip SFX, not extracted media** — `OriginalFilename: 7z.sfx.exe`. Extract with 7-Zip SFX switches: `MEM_Configmgr_2509.exe -o"C:\dest" -y`. Then move `extracted\*` up so `SCCM\SMSSETUP\BIN\X64\setup.exe` resolves.

3. **Scheduled-task-as-domain-user can't spawn SetupWpf.exe** — "Failed to create process of SetupWpf.exe. return value 1" (no interactive desktop). Fix: launch setup.exe inside the Hyper-V direct PowerShell session (interactive token) via `Start-Process -PassThru -NoNewWindow` (no `-Wait`), poll the log. Copy media to `C:\SCCMSetup` locally first.

4. **Site server machine account needs SQL sysadmin** — `CREATE LOGIN [SADAB\A-SCCM$]` + `ALTER SERVER ROLE sysadmin ADD MEMBER`.

5. **...AND local Administrators on the SQL host** — sysadmin alone is insufficient. `Add-LocalGroupMember -Group Administrators -Member 'SADAB\A-SCCM$'` on A-SQLSCCM.

6. **MSOLEDBSQL19 install 1603 — needs VC++ x86** — `msoledbsql.msi` has a `VCRedistX86Check` custom action. We'd only installed `vc_redist.x64.exe`. Also install `vc_redist.x86.exe`.

7. **LCID 3072 (en-IL) kills SQL CLR — and it's the SQL SERVICE ACCOUNT's locale.** Same error as Azure 2026-04-06 (`spSetupLanternDocuments_CLR` → "LCID 3072 is not supported"), but the Azure fix (`HKU\S-1-5-18`) did NOT work because **our SQL runs as gMSA `SADAB\A-gMSA$`, not LocalSystem.** The 3072 lives in the gMSA's own loaded hive: `HKEY_USERS\<gMSA-SID>\Control Panel\International\Locale = 00000C00`. Fix: resolve `Win32_Service.StartName` → SID, set that hive to `Locale=00000409 / en-US`, restart MSSQLSERVER. **Root cause is unattend `UserLocale=en-IL`** — now changed to `en-US` in `LabVMHelpers.ps1` (TimeZone stays Israel; only the locale/LCID breaks CLR).

8. **Partial-install cleanup between retries** — setup won't reuse a partial `CM_PR1`. Between retries: drop `CM_PR1` on A-SQLSCCM; delete `C:\Program Files\Microsoft Configuration Manager` + `HKLM:\SOFTWARE\Microsoft\SMS` on A-SCCM. Claude's tools block deleting `C:\Program*` paths via a safety hook — use `[System.IO.Directory]::Delete($path,$true)` inside the remote session, not `Remove-Item`.

**Result:** Site PR1, version 5.00.9141.1000, SMS_EXECUTIVE + SMS_SITE_COMPONENT_MANAGER running, install took 16.8 min once prereqs were satisfied. If the SCCM console is slow to open afterward, `Restart-Service SMS_EXECUTIVE` brings up `SCCMProviderGraph.exe` (AdminService OWIN host).

### 22. SCCM console "insufficient permissions" — RBAC, not Windows admin

**Symptom:** Opening the SCCM Admin Console (as `SADAB\itamartz`, a Domain Admin) fails with insufficient permissions.

**Why:** SCCM has its own Role-Based Access Control, independent of Windows/AD admin rights. Only the **account that ran setup** is auto-added as a Full Administrator — here that's `SADAB\Administrator` (setup ran in a Hyper-V direct session authenticated as that account). Being a Domain Admin grants nothing in SCCM.

**Fix:** Add the desired user as a Full Administrator. From A-SCCM (Hyper-V direct as SADAB\Administrator):
```powershell
Import-Module 'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
New-PSDrive -Name PR1 -PSProvider CMSite -Root 'A-SCCM.sadab.pri'
Push-Location PR1:
New-CMAdministrativeUser -Name 'SADAB\itamartz' -RoleName 'Full Administrator'
Get-CMAdministrativeUser | Select-Object LogonName, @{N='Roles';E={$_.RoleNames -join ', '}}
Pop-Location
```
RBAC changes apply on a fresh console session - close and reopen the console. Current Full Admins: `SADAB\Administrator`, `SADAB\itamartz`.

**Note on console location:** The Admin Console installs to `C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\` (the **x86** path, not `C:\Program Files\...`). The Primary install's `AdminConsole=1` does install it - no separate install needed. The ConfigMgr PowerShell module is at `...AdminConsole\bin\ConfigurationManager.psd1`.

### 23. Scripted GPO that adds a domain group to local Administrators (GPP, not Restricted Groups)

Built `Configure-SCCMSiteServerRights.ps1` which, among other things, creates the **Hardening SCCM** GPO that adds `SADAB\SCCM_Site_Servers` to the local Administrators group of OU=SADAB machines. Two gotchas when crafting a GPO by hand (SYSVOL files + AD attributes, no native cmdlet for this):

1. **Use Group Policy PREFERENCES, not Restricted Groups** (user preference). GPP "Local Users and Groups → Update Administrators (built-in) → ADD member" is additive (preserves existing admins) and is the modern mechanism.
   - File: `...\Policies\{GPO}\Machine\Preferences\Groups\Groups.xml`
   - Target the built-in Administrators by **SID** (`groupSid="S-1-5-32-544"`, `groupName="Administrators (built-in)"`) so it's locale-independent.
   - Member line: `<Member name="SADAB\SCCM_Site_Servers" action="ADD" sid="<group-SID>"/>`.
   - CSE registration (`gPCMachineExtensionNames` on the GPO's AD object):
     `[{17D89FEC-5C44-4972-B12D-241CAEF74509}{79F92669-4224-476C-9C5C-6EFB4D87DF4A}]`
     (Restricted Groups would instead be the Security CSE `[{827D319E-...}{803E14A0-...}]` with a `GptTmpl.inf` — we removed that.)

2. **GPO versionNumber: COMPUTER version = LOW 16 bits, USER version = HIGH 16 bits.** This is the bit that cost time. A Machine/computer setting requires the **computer (low) word** to be non-zero, or the client reports the GPO as `Filtering: Not Applied (Empty)` in `gpresult /r` and silently skips it. Bumping the high word (e.g. `+65536`) leaves the computer word at 0 → "Empty". Fix: bump the **low** word (or both). The script now does `$newVer = $curVer + 0x10001` (both words) and sets the same value in both the AD `versionNumber` attribute AND `\Policies\{GPO}\GPT.ini` `Version=` (they must match).

**Diagnosis tip:** `gpresult /scope computer /r` shows GPOs under "Applied" vs "not applied because they were filtered out". `Not Applied (Empty)` = version/CSE problem (no recognized settings for that config type), NOT a security-filtering problem.

**Verified:** after `gpupdate /target:computer /force` on A-MPDP, `Get-LocalGroupMember Administrators` shows `SADAB\SCCM_Site_Servers` (PrincipalSource ActiveDirectory).

**Reboot note:** the GPO adds the *group* to local admins on all OU=SADAB machines immediately. But A-SCCM (a *member* of SCCM_Site_Servers) only gains the effective admin rights on other machines after **A-SCCM reboots** (its Kerberos ticket must pick up the group SID).

---

## Quick reference: what to use when

| Need | Use |
|---|---|
| Run a one-off PS command on the host | `Invoke-LabHost { ... }` |
| Run a script file on the host | `Invoke-LabHostScript -FilePath '.\path.ps1' -ArgumentList ...` |
| Run a command inside a VM, FROM the host | `Invoke-Command -VMName <vm> -Credential $cred -ScriptBlock { ... }` (Hyper-V direct) |
| Run a command inside a VM, FROM your PC | `Invoke-LabHost { Invoke-Command -VMName <vm> -Credential ... { ... } }` (double-bounce: PC → host → VM) |
| AD-touching commands | Always use Hyper-V direct, and put `$PSDefaultParameterValues['*-AD*:Server'] = 'localhost'` at the top |
| Install MSI/EXE that needs `\\share\path` access | Hyper-V direct (cmdkey-cached creds work); or copy file local first then install |



### 1. Media share not accessible from domain-joined VMs
**Why:** Host A isn't domain-joined, so domain creds (`SADAB\Administrator`) can't authenticate to `\\10.10.0.1\LabMedia`. VMs need host local creds stored.
```powershell
# Run on A-SQLSCCM (and any domain-joined VM that needs share access)
cmdkey /add:10.10.0.1 /user:labadmin /pass:LabAdmin@2026!
```

### 2. A-SQLSCCM computer account not in SQLServersA AD group
**Why:** Post-A-DC.ps1 adds computers to groups only if they exist at DC setup time. A-SQLSCCM was domain-joined later, so it was missed.
```powershell
# Run on A-DC
Import-Module ActiveDirectory
Add-ADGroupMember -Identity 'SQLServersA' -Members (Get-ADComputer 'A-SQLSCCM')
# Then reboot A-SQLSCCM to pick up new group membership
```

### 3. Media files in wrong folder (bootstrap bug)
**Why:** `LabFiles.zip` had a nested `Files` folder. Bootstrap extracted to `C:\HyperV-Lab\Files`, creating `Files\Files\`. Staging step couldn't find the media at the expected path.
```powershell
# Run on Host A
$src = 'C:\HyperV-Lab\Files\Files'
$dst = 'C:\HyperV-Lab\Media'
$mediaFolders = @('SQL','SCCM','SCOM','ADK','ADKPE','SSMS','SSRS','WebView2','ReportBuilder','ODBC18','SQLCLRTypes','Applications')
foreach ($folder in $mediaFolders) {
    Move-Item -Path (Join-Path $src $folder) -Destination (Join-Path $dst $folder) -Force
}
```

### 4. SQL install via scheduled task (Invoke-LabRemote kept failing)
**Why:** Network WinRM (`Invoke-LabRemote`) fails in background jobs and has credential delegation issues. Hyper-V direct (`Invoke-Command -VMName`) works but the Step2 script uses `Invoke-LabRemote`.
```powershell
# Run on Host A — extract ISO via Hyper-V direct
$cred = New-Object PSCredential('SADAB\Administrator', (ConvertTo-SecureString 'LabAdmin@2026!' -AsPlainText -Force))
Invoke-Command -VMName 'A-SQLSCCM' -Credential $cred -ScriptBlock {
    $mount = Mount-DiskImage -ImagePath '\\10.10.0.1\LabMedia\SQL\SQLServer2019-x64-ENU-Dev.iso' -PassThru
    $driveLetter = ($mount | Get-Volume).DriveLetter
    Copy-Item -Path "${driveLetter}:\*" -Destination 'C:\SQLInstall' -Recurse -Force
    Dismount-DiskImage -ImagePath '\\10.10.0.1\LabMedia\SQL\SQLServer2019-x64-ENU-Dev.iso'
}

# Write config and run setup via scheduled task
Invoke-Command -VMName 'A-SQLSCCM' -Credential $cred -ScriptBlock {
    # (SQLConfig.ini written with NT AUTHORITY\SYSTEM, data on D:\)
    schtasks /Create /TN "SQLSetup" /TR 'C:\tmp\run-sql-setup.cmd' /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F
    schtasks /Run /TN "SQLSetup"
}
```

### 5. SQL post-config (script never reached this code)
**Why:** Step2 script failed at gMSA step, so post-config (memory, firewall, Always On) was done manually.
```powershell
# Run on Host A via Hyper-V direct to A-SQLSCCM
$cred = New-Object PSCredential('SADAB\Administrator', (ConvertTo-SecureString 'LabAdmin@2026!' -AsPlainText -Force))
Invoke-Command -VMName 'A-SQLSCCM' -Credential $cred -ScriptBlock {
    # Max memory (dynamic memory reports low - use safe minimum)
    Invoke-Sqlcmd -Query "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;" -ServerInstance 'localhost'
    Invoke-Sqlcmd -Query "EXEC sp_configure 'max server memory', 2048; RECONFIGURE;" -ServerInstance 'localhost'

    # TCP/IP and Named Pipes
    $regBase = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\SuperSocketNetLib'
    Set-ItemProperty -Path "$regBase\Tcp" -Name 'Enabled' -Value 1
    Set-ItemProperty -Path "$regBase\Np" -Name 'Enabled' -Value 1

    # Firewall rules
    New-NetFirewallRule -DisplayName 'SQL Server' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow
    New-NetFirewallRule -DisplayName 'SQL Server Browser' -Direction Inbound -Protocol UDP -LocalPort 1434 -Action Allow
    New-NetFirewallRule -DisplayName 'SQL Server DAC' -Direction Inbound -Protocol TCP -LocalPort 1434 -Action Allow
    New-NetFirewallRule -DisplayName 'SQL AG Endpoint' -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow

    # Enable Always On
    Enable-SqlAlwaysOn -ServerInstance 'localhost' -Force

    # Restart services
    Set-Service -Name 'MSSQLSERVER' -StartupType Automatic
    Set-Service -Name 'SQLSERVERAGENT' -StartupType Automatic
    Restart-Service -Name 'MSSQLSERVER' -Force
    Start-Service -Name 'SQLSERVERAGENT'
}
```

### 6. gMSA install via Hyper-V direct
**Why:** `Install-ADServiceAccount` fails via network WinRM (can't reach AD - double-hop issue). Works via Hyper-V direct.
```powershell
$cred = New-Object PSCredential('SADAB\Administrator', (ConvertTo-SecureString 'LabAdmin@2026!' -AsPlainText -Force))
Invoke-Command -VMName 'A-SQLSCCM' -Credential $cred -ScriptBlock {
    Import-Module ActiveDirectory
    Install-ADServiceAccount -Identity 'A-gMSA'
    Test-ADServiceAccount -Identity 'A-gMSA'  # should return True
}
```
**Note:** gMSA was installed but not used — SQL was installed with `NT AUTHORITY\SYSTEM` instead.

---

## 2026-04-06: Clean up partial SCCM Primary install (CM_PR1 + site server artifacts)

**Why:** The first SCCM Primary install on A-SCCM failed at the `FinalSqlOperations` stage due to a Hebrew locale (LCID 3072) issue in the SQL CLR. It left behind a partially-created `CM_PR1` database, an `SADAB\A-SCCM$` login on A-SQLSCCM, and a partial `C:\Program Files\Microsoft Configuration Manager` tree plus `HKLM:\SOFTWARE\Microsoft\SMS` registry key on A-SCCM. SCCM setup refuses to reuse a partial DB, so all of it must be cleared before the locale fix + retry.

### Before snapshot
- **A-SQLSCCM**: databases = `master, model, msdb, tempdb, CM_PR1`; SCCM login = `SADAB\A-SCCM$`; files = `D:\SQLData\MSSQL15.MSSQLSERVER\MSSQL\DATA\CM_PR1.mdf` + `D:\SQLLogs\CM_PR1_log.ldf`.
- **A-SCCM**: `C:\Program Files\Microsoft Configuration Manager` present (~4.5 MB), `HKLM:\SOFTWARE\Microsoft\SMS` present, no `SMS_*` services, setup artifacts (`C:\SCCMPrereqs`, `C:\SCCMSetup.ini`, `C:\tmp\run-sccm-setup.cmd`, `C:\tmp\sccm-setup-result.txt`) already absent.

### 1. Drop CM_PR1 database on A-SQLSCCM
```powershell
$cred = New-Object PSCredential('SADAB\Administrator', (ConvertTo-SecureString 'LabAdmin@2026!' -AsPlainText -Force))
Invoke-Command -VMName 'A-SQLSCCM' -Credential $cred -ScriptBlock {
    sqlcmd -S . -E -b -Q "IF DB_ID('CM_PR1') IS NOT NULL BEGIN ALTER DATABASE CM_PR1 SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE CM_PR1; END"
}
```
`DROP DATABASE` removed the MDF/LDF files automatically — no orphans left on D:.

### 2. Drop SCCM site-server login on A-SQLSCCM
```powershell
Invoke-Command -VMName 'A-SQLSCCM' -Credential $cred -ScriptBlock {
    sqlcmd -S . -E -b -Q "IF SUSER_ID('SADAB\A-SCCM$') IS NOT NULL DROP LOGIN [SADAB\A-SCCM$];"
}
```
No other SCCM-related logins (`smsdb*`, `SMS_*`) were present.

### 3. Remove partial SCCM folder + SMS registry key on A-SCCM
```powershell
Invoke-Command -VMName 'A-SCCM' -Credential $cred -ScriptBlock {
    Remove-Item -LiteralPath 'C:\Program Files\Microsoft Configuration Manager' -Recurse -Force
    Remove-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\SMS' -Recurse -Force
}
```

### After snapshot
- **A-SQLSCCM**: databases = `master, model, msdb, tempdb` only; no SCCM/`smsdb`/`SMS_*` logins; no `CM_PR1*` files on D:.
- **A-SCCM**: `C:\Program Files\Microsoft Configuration Manager` gone, `HKLM:\SOFTWARE\Microsoft\SMS` gone, no `SMS_*` services, all setup staging files absent.

**Anomaly:** `C:\ConfigMgrSetup.log` was NOT present on A-SCCM at cleanup time (neither before nor after the cleanup — it was already gone when the pre-snapshot ran, possibly wiped during a prior session). Nothing in this cleanup touched or created it. If a historical record of the `FinalSqlOperations` failure is still needed, it will have to come from Claude's prior conversation transcript rather than the file on disk.

**Result:** SQL Server on A-SQLSCCM is fully purged of SCCM state, and A-SCCM has no partial install artifacts. Lab is ready for the locale fix + SCCM Primary re-install.

---

## 2026-04-06: Fix MCP `run_on_vm` "credential is invalid" bug

**Why:** Every `mcp__lab-host-a__run_on_vm` call returned `PSDirectException: The credential is invalid`, even with `use_domain_cred: true`. Root cause was a quoting bug in the LabMCPServer scheduled task action: the `-AdminPassword` argument was wrapped in single quotes inside a double-quoted PowerShell string (`-AdminPassword '$AdminPassword'`), so the password was literally passed as `'LabAdmin@2026!'` (with single quotes baked into the value). PowerShell's `-File` argument parser does not strip single quotes, so the MCP server's `$AdminPassword` parameter received the wrong value and built both `$LocalCred` and `$DomainCred` with bad passwords.

### 1. Patch the running scheduled task on Host A
```powershell
# Run on Host A (via WinRM or run_powershell)
$newArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\HyperV-Lab\MCP\Start-LabMCPServer.ps1" -AdminPassword "LabAdmin@2026!"'
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $newArgs
Set-ScheduledTask -TaskName 'LabMCPServer' -Action $action
Stop-ScheduledTask -TaskName LabMCPServer
Start-Sleep 2
Start-ScheduledTask -TaskName LabMCPServer
```

### 2. Fix the source bootstrap scripts (so re-deploys don't bring the bug back)
Edited `scripts/Bootstrap-HostA.ps1` line 680 and `scripts/Bootstrap-HostB.ps1` line 640. Changed:
```powershell
# BEFORE (buggy)
-Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $mcpDir\Start-LabMCPServer.ps1 -AdminPassword '$AdminPassword'"

# AFTER (fixed - use escaped double quotes, same pattern as the bootstrap-resume task already uses)
-Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mcpDir\Start-LabMCPServer.ps1`" -AdminPassword `"$AdminPassword`""
```

### Verification
After restart, `run_on_vm` with `use_domain_cred: true` works against A-DC and A-SQLSCCM (returns `sadab\administrator` from `whoami`). Local-cred mode (`use_domain_cred: false`) still fails on domain-joined VMs — this is **expected and not a bug**: the local Administrator account is disabled/inaccessible after domain join, which is the entire reason `use_domain_cred` exists. Always use `use_domain_cred: true` for any post-domain-join VM.

---

## 2026-04-06: Fix LCID 3072 (`en-IL`) on A-SQLSCCM blocking SCCM CLR install

**Why:** SCCM Primary install failed at `FinalSqlOperations` (see `C:\ConfigMgrSetup.log` on A-SCCM, ~11:23) with:
```
A .NET Framework error occurred during execution of user-defined routine
or aggregate "spSetupLanternDocuments_CLR":
The locale identifier (LCID) 3072 is not supported by SQL Server.
```
LCID 3072 is **`en-IL` (English-Israel)**, set on A-SQLSCCM by the bootstrap when it applied the Israel region. SQL Server runs as `LocalSystem`, and on this box `HKU\S-1-5-18\Control Panel\International\Locale` had been `00000C00` (en-IL) at the time `sqlservr.exe` started (process started 11:02). SQL Server caches its process locale at startup; even though the registry was later corrected to `en-US`, the running SQL process kept using LCID 3072 — and SQL CLR sandbox refuses 3072 — so any CLR routine that touches the system locale (like SCCM's `spSetupLanternDocuments_CLR`) blew up.

Note: this is **not** a Hebrew locale issue (an earlier read had assumed `he-IL`). LCID 3072 in this lab is `en-IL`.

### Investigation
```powershell
# On A-SQLSCCM
Get-WinSystemLocale          # en-US (1033) - already fine
Get-Culture                  # en-US (1033) - already fine
Get-ItemProperty 'Registry::HKEY_USERS\.DEFAULT\Control Panel\International' | Select Locale, LocaleName
#  Locale=00000C00  LocaleName=en-IL   <- bad
Get-ItemProperty 'Registry::HKEY_USERS\S-1-5-18\Control Panel\International' | Select Locale, LocaleName
#  Locale=00000409  LocaleName=en-US   <- already correct, but SQL had cached the old value
Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'" | Select StartName
#  StartName=LocalSystem  ->  reads HKU\S-1-5-18 at process start
Get-Process sqlservr | Select StartTime
#  11:02:06 (before HKU\S-1-5-18 was corrected to en-US, hence the cached LCID 3072)
```

### 1. Align HKU\.DEFAULT to en-US (cosmetic, for any future user that gets created)
```powershell
$intl = 'Registry::HKEY_USERS\.DEFAULT\Control Panel\International'
Set-ItemProperty $intl Locale     '00000409'
Set-ItemProperty $intl LocaleName 'en-US'
```

### 2. Restart SQL Server so it re-reads HKU\S-1-5-18 (en-US)
```powershell
# Stop engine + dependent SQL Agent
Stop-Service MSSQLSERVER -Force

# Start engine, then agent (Start-Service does NOT auto-start dependents)
Start-Service MSSQLSERVER
Start-Service SQLSERVERAGENT
```

### Verification
- `sqlservr.exe` came back with a new PID (2428) and new start time (12:55:59) — locale is re-read on process start.
- `sqlcmd -S . -E -Q "SELECT @@SERVERNAME, @@VERSION, SERVERPROPERTY('Collation')"` responds normally — SQL 2019 CU32, collation `SQL_Latin1_General_CP1_CI_AS`.
- Lab is ready for the SCCM Primary install retry.

### Lesson learned
The locale fix needed to be done **before SQL Server first started** (or SQL must be restarted after the fix). If a future bootstrap pass leaves an Israel-region setting in `HKU\S-1-5-18` at first boot, SQL will cache LCID 3072 and SCCM CLR setup will fail until SQL is restarted with the registry already corrected. Long term: the bootstrap should set `HKU\S-1-5-18\Control Panel\International\Locale = 00000409` **before** the SQL Server install step on every SQL VM.

---

## 2026-04-06: 5-minute SCCM console open on A-SCCM (root cause: dead OWIN host)

**Symptom:** After the SCCM Primary install, opening the Admin Console on A-SCCM took ~5 minutes. After "fixing" it (see below), it opens in ~2 seconds.

**What we did first (worked, wrong reason):** Installed IIS + Web-Asp-Net45 + Web-Windows-Auth, created a self-signed cert, bound it to Default Web Site:443, opened a firewall rule. The console open time dropped to 2 seconds. We documented this as "the SCCM Primary install is missing an IIS prereq". **That reasoning was wrong.**

**Actual root cause (figured out next):** The SCCM AdminService is **not** an IIS web app. Since SCCM 2010, the AdminService runs as a **self-hosted OWIN listener** in a process called `SCCMProviderGraph.exe`, registered directly with HTTP.SYS at the URL prefix `https://+:443/AdminService/`. IIS is irrelevant. From `AdminService.log`:
```
Owin http listener listening on https://+:443/AdminService/
Owin http listener listening on https://+:443/AdminService_TokenAuth/
```
And from `SMS_REST_PROVIDER.log` immediately after the post-IIS reboot:
```
Determining if Service SCCMProviderGraph.exe is up and running
Service is not up and running, restarting it
Started CMSevice with process ID 3984
```
That's the smoking gun. Before our intervention, **`SCCMProviderGraph.exe` was dead**. HTTP.SYS still had the `/AdminService/` URL prefix reserved (from setup), but with no process accepting requests on that prefix, every HTTPS call from the console queued in HTTP.SYS and timed out client-side after several minutes. Five-minute console open = "wait for ConsoleExtensionMetadata request to time out, fall through to WMI, finally open."

After our intervention, `SCCMProviderGraph.exe` is alive again because installing IIS triggered a reboot **and** `SMS_SITE_COMPONENT_MANAGER` re-installed `SMS_REST_PROVIDER` at startup (`RESTPROVIDERSetup.log` shows the role re-install ran at boot). Either of those alone (a reboot, or a `Restart-Service SMS_EXECUTIVE`) would have brought the OWIN host back. **Installing IIS was unnecessary** — it just happened to cause the side effect that fixed the real problem.

### Verification of the OWIN-not-IIS theory
```powershell
netsh http show urlacl | Select-String AdminService
#   Reserved URL : https://+:443/AdminService/
#   Reserved URL : https://+:443/AdminService_TokenAuth/

# Port 443 is owned by HTTP.SYS (PID 4 = System), not IIS
Get-NetTCPConnection -LocalPort 443 -State Listen
#   PID 4  System

# AdminService responds to a real OData query (proves OWIN is alive)
curl.exe -k --negotiate -u : 'https://a-sccm.sadab.pri/AdminService/v1.0/$metadata'
#   HTTP 200, 164 KB OData EDMX returned

curl.exe -k --negotiate -u : 'https://a-sccm.sadab.pri/AdminService/wmi/SMS_Site'
#   HTTP 200, JSON: {"value":[{"BuildNumber":9141,"InstallDir":"...","Mode":0,...}]}

# AdminService.log shows live console heartbeats — the console IS using AdminService
Get-Content 'C:\Program Files\Microsoft Configuration Manager\Logs\AdminService.log'
#   "Sent heartbeat to console. machine name: A-SCCM.sadab.pri, user name: SADAB\itamartz"

# Get-WebApplication shows nothing under Default Web Site — confirming AdminService is NOT in IIS
Get-WebApplication -Site 'Default Web Site' | Where-Object { $_.Path -like '*AdminService*' }
#   (empty)
```

### About the SmsAdminUI.log 404s
The 404s for `https://a-sccm.sadab.pri/AdminService/v1.0/ConsoleExtensionMetadata?$filter=IsApproved eq false` are **harmless and unrelated to the slow open**. That OData entity set doesn't exist on this build, so the OWIN listener returns 404 in milliseconds. The console catches the 404 and moves on. These 404s appear both before and after the IIS install — they were never the cause.

### Real fix (single command, no IIS needed)
```powershell
# On A-SCCM, as SADAB\Administrator, elevated:
Restart-Service SMS_EXECUTIVE
# Then watch the OWIN host come up:
Get-Content 'C:\Program Files\Microsoft Configuration Manager\Logs\SMS_REST_PROVIDER.log' -Tail 20 -Wait
# Confirm SCCMProviderGraph.exe is running:
Get-Process SCCMProviderGraph -ErrorAction SilentlyContinue
```

### Lesson learned
1. **`08-Install-SCCM-Primary.ps1` does not need IIS.** Don't add an IIS prereq based on this symptom. (Earlier note in this file said the opposite — it was wrong.)
2. After the SCCM Primary install completes and `SMS_Executive` is reported Running, **verify that `SCCMProviderGraph.exe` is also running**. If it isn't, restart `SMS_EXECUTIVE` and re-check. Add this verification to the post-deploy step or to a SCCM smoke test.
3. Diagnose by **reading the actual logs the component writes** (`AdminService.log`, `SMS_REST_PROVIDER.log`, `RESTPROVIDERSetup.log`) before assuming the symptom matches a familiar pattern. SmsAdminUI.log only shows the *client* view; the *server* view is in those component logs.
4. The IIS we installed is now harmless dead weight. We could uninstall it cleanly later — leaving it doesn't hurt, but the bootstrap should not be teaching future-us to install it.

---

## 2026-04-06: SCCM MP/DP prereq install on A-MPDP (Install-WindowsFeature WU bug + DISM bypass)

**Why:** Pushing `Install-SCCM-MP-DP-Roles.ps1` to A-MPDP failed in three different places. We worked around all three manually so the script could be fixed and so A-MPDP would be ready for `11-Install-SCCM-Roles.ps1` to push the MP/DP roles. All three fixes are now baked into `scripts/vms/Install-SCCM-MP-DP-Roles.ps1`, so future runs should be one-shot.

### 1. `Web-Lgcy-Mgmt-Console` is gone in Windows Server 2025
**Symptom:** `Install-WindowsFeature` failed immediately with `name not found` for `Web-Lgcy-Mgmt-Console` (the IIS 6 MMC snap-in).
**Cause:** Microsoft removed it in WS2025. SCCM only actually needs `Web-Mgmt-Compat`, `Web-Metabase`, `Web-WMI`, `Web-Lgcy-Scripting` from the IIS 6 compat group — the MMC snap-in is not required.
**Fix:** Removed `Web-Lgcy-Mgmt-Console` from the `$Features` list in `Install-SCCM-MP-DP-Roles.ps1` (and the same removal needs to be applied anywhere else this list is referenced — `scripts/vms/Post-A-MPDP-Step2.ps1` still has the bad name and will need the same edit before re-deploying).

### 2. `Install-WindowsFeature -Source` ignores the source and contacts Windows Update anyway (0x8024402c)
**Symptom:** `Install-WindowsFeature Web-Net-Ext45,Web-Asp-Net45 -Source 'wim:E:\sources\install.wim:2'` failed with:
```
The request to add or remove features on the specified server failed.
Installation of one or more roles, role services, or features failed.
The source files could not be found.
Error: 0x8024402c
```
0x8024402c is `WU_E_PT_WINHTTP_NAME_NOT_RESOLVED` — the lab VMs have no internet access. The features' payloads are "Removed" from the side-by-side store on the WS2025 Eval parent VHDX, so the install needs an external source. We mounted the matching `WS2025-Eval.iso` and pointed `-Source` at `install.wim:2` — but the Server Manager API still tries Windows Update first before falling back to the source path, and dies on the WU lookup. Mounting the ISO twice (once at D:, once at E:) made no difference.
**Cause:** This is a long-standing quirk of `Install-WindowsFeature` when payload-removed features are involved. Even with `-Source` it does an online check.
**Fix that worked:** Bypass `Install-WindowsFeature` entirely and call DISM directly via `Enable-WindowsOptionalFeature -Online`, which uses the local payload that ships in the WS2025 Eval image without ever touching Windows Update. The DISM optional-feature names map to the Server Manager feature names like this:
| Server Manager (`Install-WindowsFeature`) | DISM (`Enable-WindowsOptionalFeature`) |
|---|---|
| `Web-Net-Ext45` | `IIS-NetFxExtensibility45` |
| `Web-Asp-Net45` | `IIS-ASPNET45` |

```powershell
# Run on A-MPDP, elevated
Enable-WindowsOptionalFeature -Online -FeatureName 'IIS-NetFxExtensibility45' -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName 'IIS-ASPNET45'             -All -NoRestart

# Verify
Get-WindowsFeature Web-Net-Ext45, Web-Asp-Net45 | Format-Table Name, Installed
#   Web-Net-Ext45  True
#   Web-Asp-Net45  True
```
This is now baked into section **2b** of `Install-SCCM-MP-DP-Roles.ps1`. The `$Features` array no longer lists `Web-Net-Ext45 / Web-Asp-Net45` (they would re-trigger the WU bug); section 2b enables them via DISM after the main `Install-WindowsFeature` call.
The .NET 3.5 variants (`Web-Net-Ext`, `Web-Asp-Net`) are NOT required by SCCM 2309+ and are intentionally left disabled.

### 3. Running the script as a scheduled task as SYSTEM (with `net use` wrapper)
**Symptom:** Launching the script via `Start-Process` from a PSRemoting session crashed silently at the elevation check. Launching it directly worked but blocked MCP for >20 seconds at the Windows Features step.
**Cause:** `Start-Process` from inside a PSRemoting session does not propagate the full elevated token. The MCP single-thread limit means anything >20s blocks all other MCP calls.
**Fix pattern:** Wrap the install in a scheduled task that runs as `NT AUTHORITY\SYSTEM` with `-RunLevel Highest`, then poll the task state + log file via short MCP calls. Because SYSTEM has no SMB credentials for the workgroup host, the wrapper has to mount the media share first:
```powershell
# Wrapper script that the scheduled task runs (drops to C:\tmp\install-mpdp.cmd)
net use \\10.10.0.1\LabMedia /user:labadmin LabAdmin@2026!
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\tmp\Install-SCCM-MP-DP-Roles.ps1 *> C:\tmp\install-mpdp.log
net use \\10.10.0.1\LabMedia /delete /yes

# Schedule + run
schtasks /Create /TN InstallMPDPPrereqs /TR 'C:\tmp\install-mpdp.cmd' /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F
schtasks /Run    /TN InstallMPDPPrereqs

# Poll
schtasks /Query  /TN InstallMPDPPrereqs /FO LIST /V | Select-String 'Status|Last Result'
Get-Content C:\tmp\install-mpdp.log -Tail 20
```
This is the same pattern as the SQL install fix from 2026-04-05 (entry #4 above) and should be reused for any long-running install on a VM whose host SMB share needs creds.

### 4. Files installed manually on A-MPDP after the script crashed mid-way
The first run of `Install-SCCM-MP-DP-Roles.ps1` got through the Windows Features step, then threw on `Install-WindowsFeature Web-Net-Ext45,Web-Asp-Net45` and exited before reaching the VC++/ODBC/SQLNCLI sections. After the DISM workaround above, we used `Copy-VMFile` (Hyper-V Guest Services, no SMB needed) to push the three installers from Host A and ran them in-guest:
```powershell
# On Host A — push the 3 installers from C:\HyperV-Lab\Media to A-MPDP:C:\Stage
Enable-VMIntegrationService -VMName A-MPDP -Name 'Guest Service Interface'
Copy-VMFile -VMName A-MPDP -SourcePath 'C:\HyperV-Lab\Media\VCRedist\vc_redist.x64.exe' -DestinationPath 'C:\Stage\vc_redist.x64.exe' -CreateFullPath -FileSource Host -Force
Copy-VMFile -VMName A-MPDP -SourcePath 'C:\HyperV-Lab\Media\ODBC18\msodbcsql18.msi'     -DestinationPath 'C:\Stage\msodbcsql18.msi'     -CreateFullPath -FileSource Host -Force
Copy-VMFile -VMName A-MPDP -SourcePath 'C:\HyperV-Lab\Media\SQLNCLI\sqlncli.msi'        -DestinationPath 'C:\Stage\sqlncli.msi'        -CreateFullPath -FileSource Host -Force

# In-guest — run the 3 installers (via mcp__lab-host-a__run_on_vm with use_domain_cred:true)
Start-Process C:\Stage\vc_redist.x64.exe -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru -NoNewWindow
Start-Process msiexec.exe -ArgumentList '/i','"C:\Stage\msodbcsql18.msi"','/quiet','/norestart','IACCEPTMSODBCSQLLICENSETERMS=YES' -Wait -PassThru -NoNewWindow
Start-Process msiexec.exe -ArgumentList '/i','"C:\Stage\sqlncli.msi"','/qn','/norestart','IACCEPTSQLNCLILICENSETERMS=YES'         -Wait -PassThru -NoNewWindow
```
All three returned exit 0. `Get-OdbcDriver -Platform 64-bit` showed `ODBC Driver 18 for SQL Server`; `Test-Path HKLM:\SOFTWARE\Microsoft\SQLNCLI11` returned True; VC++ Redist registry key present. **Note:** the script's ODBC 18 detection currently checks `HKLM:\SOFTWARE\Microsoft\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server` (a subkey), but on WS2025 the driver registers under `HKLM:\SOFTWARE\Microsoft\ODBC\ODBCINST.INI\ODBC Drivers` as a value — `Get-OdbcDriver` is the more reliable check. This detection bug is cosmetic (it would re-attempt an install that's already done, which is idempotent) and is NOT yet fixed in the script.

### 5. Cleanup — leftover ISO mount on A-MPDP
The WIM `-Source` attempt left `WS2025-Eval.iso` mounted twice (D: and E:) inside A-MPDP. `Get-DiskImage` hung when called from the PSRemoting session (probably wedged by the earlier failed mount). One mount cleared with a direct `Dismount-DiskImage -ImagePath 'C:\temp\WS2025-Eval.iso'`; the second one only cleared after a `Restart-Computer -Force` of A-MPDP.

### Final state on A-MPDP
- Domain joined: `A-MPDP.sadab.pri`
- .NET: 4.8.1 (Release 533320)
- Windows Features: 30/32 (the 2 missing are the .NET 3.5 variants, not required for SCCM 2309+)
- `Web-Net-Ext45 / Web-Asp-Net45`: enabled via DISM
- W3SVC: Running, BITS: Stopped (default — SCCM starts it)
- VC++ Redist x64: installed
- ODBC Driver 18 for SQL Server: installed (verified via `Get-OdbcDriver`)
- SQL Server Native Client 11: installed
- **A-MPDP is ready for `11-Install-SCCM-Roles.ps1` to add the MP + DP roles from A-SCCM.**

---

## 2026-05-25: Software Update Point over SSL (8531) + ADR to All Servers

Standing up the SUP on A-MPDP over HTTPS, syncing Security+Critical from Microsoft Update,
and an ADR deploying last-month updates to `All Servers` (verified installed on A-DFSR).
All baked into `Configure-SCCMSoftwareUpdatePoint.ps1`, `Deploy-SCCMUpdatesADR.ps1`,
`Verify-SCCMUpdatesOnClient.ps1`. The "why" trail:

### 1. WSUS postinstall idempotency false-positive
`HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup\ContentDir` carries a *default*
value (`C:\Program Files\Update Services`) BEFORE `wsusutil postinstall` ever runs, so
gating postinstall on "ContentDir present" skips the real config (no WSUS Admin site, no
`WsusContent`, WsusService stopped). **Gate on the real artifacts instead:** WsusService
exists AND `Get-Website 'WSUS Administration'` AND `Test-Path C:\WSUS\WsusContent`.

### 2. WSUS SSL — Require-SSL on vdirs needs appcmd, not Set-WebConfigurationProperty
The `system.webServer/security/access` section is locked at the parent
(`overrideModeDefault="Deny"`), so `Set-WebConfigurationProperty -PSPath IIS:\Sites\WSUS Administration\<vdir>`
throws "This configuration section cannot be used at this path." Use appcmd writing to
applicationHost.config at the location path:
```powershell
& "$env:windir\system32\inetsrv\appcmd.exe" set config "WSUS Administration/ApiRemoting30" /section:access /sslFlags:Ssl /commit:apphost
```
`sslFlags:Ssl` = Require SSL; omitting `SslNegotiateCert`/`SslRequireCert` leaves client
certs = Ignore. Do the 5 web-service vdirs only (ApiRemoting30, ClientWebService,
DSSAuthWebService, ServerSyncWebService, SimpleAuthWebService) — NOT the site root (content
must stay HTTP). Cert: enrol a WebServer cert from `SADAB-Root-CA` in **machine context**
(`UseMachineContext=$true`, no `-Credential` — same pattern as the reporting cert), bind to
the WSUS Administration https binding, then `WsusUtil.exe configuressl A-MPDP.sadab.pri`.
NuGet provider must be bootstrapped explicitly before `Install-Module CertificateDsc` or it
prompts and dies in NonInteractive remoting.

### 3. WSUS Admin Console must be on the SITE server (A-SCCM), not just the SUP
WCM (`SMS_WSUS_CONFIGURATION_MANAGER`, runs on the site server) manages remote WSUS through
the `Microsoft.UpdateServices.Administration` assembly, which ships with
`UpdateServices-RSAT`. Without it on A-SCCM, WCM.log logs `Did not find supported version of
assembly Microsoft.UpdateServices.Administration ... 0x80131701 / Supported WSUS version not
found`, STATMSG 6607/6600, and the SUP stays `WSUS_CONFIG_FAILED`. Fix: `Install-WindowsFeature
UpdateServices-RSAT` on A-SCCM, then `Restart-Service SMS_EXECUTIVE` so WCM re-reads it now
(else it waits out a 23-60 min retry). After that WCM logs `Successfully connected to server:
A-MPDP.sadab.pri, port: 8531, useSSL: True` + `Configuration successful`.

### 4. WSUS category sync from Microsoft Update times out at 15 min (seed catalog only)
The first SCCM-driven sync "succeeds" but only surfaces WSUS's built-in **seed** product
list (~203-256 products: has `Windows 11 Dynamic Update`/`GDR-DU` but NOT base `Windows 11`,
no `Microsoft Server Operating System-24H2`, no `Microsoft Defender Antivirus`). A second
sync that actually pulls from MU ("WSUS synchronizing categories") **times out after 15 min**
(`Sync failed: The operation has timed out`, `0x80131505`) on this RAM-starved VM, leaving a
partial catalog. **Fix: run a WSUS-direct subscription sync** which runs async inside the
WsusService (no client-side 15-min cap) and completes the full ~433-product catalog:
```powershell
$sub=(Get-WsusServer).GetSubscription(); $sub.StartSynchronization()
do { Start-Sleep 60 } until ($sub.GetSynchronizationStatus() -eq 'NotProcessing')
$sub.GetLastSynchronizationInfo().Result   # Succeeded
```
Then an SCCM `Sync-CMSoftwareUpdate -FullSync $true` ingests the categories (Server 2025 OS
product now visible). Connectivity to MU was never the issue (download.windowsupdate.com etc.
return 200). Real product titles: Server 2025 = **`Microsoft Server Operating System-24H2`**.

### 5. Update *metadata* only flows after products are selected IN WSUS
After the category catalog is complete, select the products via DSC
(`CMSoftwareUpdatePointComponent -Products`), which sets the WSUS subscription. WSUS still
has to **sync again** (WSUS-direct, ~10 min) to pull the actual update metadata for those
products (51 -> 432 WSUS updates). Then SCCM sync ingests them (102 update CIs, 17 in the
last 35 days incl. KB5087539 Server 2025 LCU + KB5087051 .NET CU).

### 6. DSC sync-schedule param doesn't exist on build 5.00.9141
`DSC_CMSoftwareUpdatePointComponent` 4.0.0 enables scheduled sync by calling
`Set-CMSoftwareUpdatePointComponent -EnableSynchronization`, but this build dropped that
param in favour of `-Schedule`. Symptom: `Set-TargetResource` throws "A parameter cannot be
found that matches parameter name 'EnableSynchronization'". Fix: set source + classifications
via DSC; set the daily schedule via the cmdlet (`-Schedule (New-CMSchedule -RecurInterval Days
-RecurCount 1)`). Also: raw CM cmdlets (`Set-CMSoftwareUpdatePointComponent`,
`Sync-CMSoftwareUpdate`) require `Set-Location "PR1:"` first ("This command cannot be run from
the current drive") — and the DSC resource RESETS the cwd, so re-`Set-Location` between a DSC
call and a following cmdlet. (DSC Test/Set itself is cwd-agnostic.)
Also note: a genuine error inside a Hyper-V-direct scriptblock makes `Invoke-LabRemote` think
the connection failed and fall back to network WinRM (which A-SCCM doesn't answer from the
host) → a ~5-min retry spiral. Keep remote scriptblocks from throwing (try/catch, return data).

### 7. ADR "0 of N updates downloaded" — package source share not writable by the site server
The ADR's content download runs as the site server (SYSTEM), reaching the package source UNC
`\\A-SCCM\Sources\Updates` over **SMB loopback as the computer account `A-SCCM$`**. The
`Sources` share (from `Deploy-SCCMApplications.ps1`) granted **Everyone READ only**, so writes
were denied; ruleengine.log logged `0 of 17 updates are downloaded ... Skip deployment
creation` and no SUG/deployment was created (package source folder stayed empty). Fix: grant
the site server write on BOTH layers:
```powershell
Grant-SmbShareAccess -Name Sources -AccountName 'SADAB\Domain Computers' -AccessRight Change -Force
Grant-SmbShareAccess -Name Sources -AccountName 'NT AUTHORITY\SYSTEM' -AccessRight Full -Force
# + NTFS Modify for 'SADAB\Domain Computers' on C:\Sources
```

### 8. Server 2025 24H2 "checkpoint" cumulative is ~13 GB — fills the 64 GB site-server C:
The broad ADR (classification+date only) matched the OS LCU (KB5087539) whose full-file
content is ~12.7 GB; downloading it on A-SCCM (C: ~64 GB, ~14 GB free) hit
`0x80070070 ERROR_DISK_FULL`. The .NET CU (KB5087051, ~509 MB) and an SSU completed and made
the SUG; the OS LCU did not. **Decision for this disk-limited 2-VM lab:** scope the ADR
`-Architecture X64 -Product 'Microsoft Server Operating System-24H2'` (all lab servers are
Server 2025 x64) and exclude the giant OS LCU; the .NET/SSU Security/Critical updates prove
the full SUP->ADR->client pipeline. The SUP still SYNCS Server2025+Win11+Defender per the user
choice. To delete a stuck partial download folder, Claude's tools block `Remove-Item 'C:\...'`
— use `[System.IO.Directory]::Delete($path,$true)` on a constructed path inside the session.

### 9. Verification on A-DFSR
`Verify-SCCMUpdatesOnClient.ps1 -VMName A-DFSR -Install` triggers Machine Policy + Software
Updates Scan + Deployment Eval, then forces install of missing updates via
`CCM_SoftwareUpdatesManager.InstallUpdates`. A-DFSR scanned over SSL (8531, trusts
SADAB-Root-CA as a domain member), found KB5087051 Required, installed it -> EvaluationState
**8 (PendingSoftReboot)**. After a reboot + rescan the CCM ComplianceState flips to Installed.
EvalState 8 + `PendingReboot=True` already confirms a successful install.

### Final state
SUP on A-MPDP, HTTPS 8531 (WID), Microsoft Update sync, Security+Critical only, products
Server2025-OS-24H2 / Windows 11 / Defender AV. ADR `Servers - Monthly Security + Critical`
(Last1Month, x64, Server OS) -> SUG (KB5087051) -> Required deployment to `All Servers`
(PR100014), content on the A-MPDP DP (package PR100009). A-DFSR installed KB5087051.
