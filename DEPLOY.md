# DEPLOY.md — Build the local SCCM lab from scratch

> Sequential "if you had to rebuild from zero" procedure. Captures only the **working** path — every gotcha, dead-end, and workaround is detailed in `scripts/manual-fixes.md`.
>
> Target topology: 1× physical Hyper-V host running 5 Phase-1 VMs (A-DC, A-DFSR, A-MPDP, A-SQLSCCM, A-SCCM). Site B + SCOM are Phase 2 (when host #2 arrives).

---

## 0. Prerequisites — your PC and the Hyper-V host

**On the workstation you're driving from (this PC):**
- Windows 10/11 with PowerShell 5.1+
- TrustedHosts set to `*` (or specifically the host's IP)
  ```powershell
  Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
  ```
- Project cloned to a local folder (e.g. `C:\Users\you\Dropbox\System\_FORWORK\LabSystemCenterInHome`)

**On the Hyper-V host (your physical mini-PC):**
- Windows 11 Pro (or any modern Hyper-V-capable Windows SKU)
- Hyper-V feature enabled
- WinRM service running, port 5985 open inbound from your PC
- A local admin account whose creds we'll save

> **First, make it your environment:** edit `lab-config.json` and set `hostA.hostname`,
> `hostA.ip` (your host's reachable IP/FQDN), and the `defaults.*Password` values. Every
> example below derives the host address from that file:
> ```powershell
> $hostIp = (Get-Content .\lab-config.json -Raw | ConvertFrom-Json).hostA.ip
> ```
> `Connect-LabHost.ps1` already reads `hostA.ip` automatically, so `Invoke-LabHost { ... }`
> needs no IP. Only the raw `New-PSSession` examples below use `$hostIp`. The internal VM
> subnet (`10.10.0.0/24`) and VM IPs are fixed by design and don't change per environment.

---

## 1. Save host credentials locally (one-time)

DPAPI-encrypted under the project folder, per-user/per-machine.

```powershell
# Run on your PC, in the project root
New-Item -ItemType Directory -Path '.\.secrets' -Force | Out-Null
Get-Credential -Message 'Hyper-V host admin' | Export-Clixml -Path '.\.secrets\hyperv-host.cred.xml'
```

After this, `scripts\lib\Connect-LabHost.ps1` exposes `Invoke-LabHost { ... }` which auto-loads the cred.

---

## 2. Configure the Hyper-V host

Sets up storage paths, the `Lab` Internal vSwitch (10.10.0.0/24), NAT, firewall rules
(ICMP + WinRM + SMB), the local `labadmin` share user, and the **Tailscale route override**
(only needed if a Tailscale node on the network advertises an overlapping `10.10.0.0/24`).

```powershell
. .\scripts\lib\Connect-LabHost.ps1
Invoke-LabHostScript -FilePath '.\scripts\setup\Configure-Host.ps1' -ArgumentList 'A'
```

Idempotent — safe to re-run. (The SMB-445 firewall rule and the `labadmin` local user are
now created by `Configure-Host.ps1` itself — no separate manual step needed.)

---

## 3. Stage the parent VHDX and lab scripts on the host

**Parent VHDX** (`WS2025-Eval.vhdx`, ~11 GB Datacenter eval) — copy from wherever you have it:

```powershell
$hostIp = (Get-Content .\lab-config.json -Raw | ConvertFrom-Json).hostA.ip
$cred = Import-Clixml '.\.secrets\hyperv-host.cred.xml'
$sess = New-PSSession -ComputerName $hostIp -Credential $cred -Authentication Negotiate

$src = 'C:\path\to\WS2025-Eval.vhdx'   # adjust to your local copy
Copy-Item -Path $src -Destination 'C:\HyperV-Lab\Base\WS2025-Eval.vhdx' -ToSession $sess -Force

# Mark read-only — required for use as a differencing-disk parent
Invoke-Command -Session $sess -ScriptBlock {
  Set-ItemProperty -Path 'C:\HyperV-Lab\Base\WS2025-Eval.vhdx' -Name IsReadOnly -Value $true
}
Remove-PSSession $sess
```

At ~5-7 MB/s over Tailscale, expect ~25-30 min for 11 GB.

**Lab scripts** — push `scripts\vms\`, `scripts\post-deploy\`, `scripts\sccm-roles\` and `lab-config.json`:

```powershell
$hostIp = (Get-Content .\lab-config.json -Raw | ConvertFrom-Json).hostA.ip
$cred = Import-Clixml '.\.secrets\hyperv-host.cred.xml'
$sess = New-PSSession -ComputerName $hostIp -Credential $cred -Authentication Negotiate
foreach ($d in 'scripts\vms','scripts\post-deploy','scripts\sccm-roles') {
  Invoke-Command -Session $sess -ScriptBlock { param($p) New-Item -ItemType Directory -Path "C:\HyperV-Lab\$p" -Force | Out-Null } -ArgumentList $d
  Get-ChildItem $d -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination "C:\HyperV-Lab\$d\$($_.Name)" -ToSession $sess -Force
  }
}
Copy-Item -Path '.\lab-config.json' -Destination 'C:\HyperV-Lab\lab-config.json' -ToSession $sess -Force
Remove-PSSession $sess
```

---

## 4. Stage media binaries (~8 GB) for SQL/SCCM/ADK installs

The `Files\<Tool>\Install-Silent.ps1` wrappers are versioned in the repo; **the actual
binaries are not** (they're gitignored). You must supply them yourself. The repo does NOT
and cannot redistribute Microsoft media.

### Media you must supply yourself (free eval/community sources)

Place each under `Files\<Tool>\` (then stage to the host — Option A below):

| Tool dir | What | Where to get it |
|---|---|---|
| `Base` (VHDX) | **Windows Server 2025** Eval — parent VHDX (or build one from the ISO) | Microsoft Evaluation Center |
| `SQL` | **SQL Server 2019** Developer/Eval ISO **+ CU32** | Microsoft (SQL 2019 Developer is free) + Latest CU |
| `SCCM` | **Configuration Manager** `MEM_Configmgr_<ver>.exe` | Microsoft **Evaluation** download (or VLSC) |
| `ADK` + `ADKPE` | **Windows ADK** + **WinPE add-on** (matching the OS) | Microsoft (free) |
| `SSMS` | SQL Server Management Studio | Microsoft (free) |
| `SSRS` | `SQLServerReportingServices.exe` (SSRS 2022) | Microsoft (free) — also auto-downloaded by `Configure-SCCMReporting.ps1` |
| `ODBC18` | `msodbcsql18.msi` | Microsoft (free) |
| `SQLNCLI` | SQL Server Native Client 11 `sqlncli.msi` | Microsoft (free) |
| `SQLCLRTypes` | SQL CLR Types | Microsoft (free) |
| `VCRedist` | `vc_redist.x64.exe` **and** `vc_redist.x86.exe` (2015-2022) | `https://aka.ms/vs/17/release/vc_redist.x64.exe` / `.x86.exe` |
| `ReportBuilder` | Report Builder | Microsoft (free) |
| `SxS` | the WS2025 `\sources\sxs` folder (for .NET 3.5 / feature payloads) | from the WS2025 ISO |

> The earlier convenience option (a personal Dropbox zip via `Download-LabFiles.ps1`) is
> **not portable** to another environment — its URL points at the original author's Dropbox.
> Gather the media above instead.

### Stage the gathered media to the host

```powershell
$hostIp = (Get-Content .\lab-config.json -Raw | ConvertFrom-Json).hostA.ip
$src = 'C:\path\to\media\Files'   # your local Files\ folder, populated per the table above
$sess = New-PSSession -ComputerName $hostIp -Credential (Import-Clixml .\.secrets\hyperv-host.cred.xml) -Authentication Negotiate
$dirs = 'ADK','ADKPE','ODBC18','ReportBuilder','SCCM','SQL','SQLCLRTypes','SQLNCLI','SSMS','SSRS','SxS','VCRedist','WebView2'
foreach ($d in $dirs) {
  Copy-Item -Path (Join-Path $src $d '*') -Destination "C:\HyperV-Lab\Files\$d" -ToSession $sess -Recurse -Force
}
Remove-PSSession $sess
```

**VC++ Redistributable** can also be pulled directly on the host (it has internet):

```powershell
# VC++ Redistributable 2015-2022 (needed for ODBC 18) — Host A has internet
Invoke-LabHost {
  $u = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
  $d = 'C:\HyperV-Lab\Files\VCRedist\vc_redist.x64.exe'
  if (-not (Test-Path $d)) {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $u -OutFile $d -UseBasicParsing -TimeoutSec 300
  }
}
```

`MEM_Configmgr_<version>.exe` for SCCM Current Branch is available from the **Microsoft Evaluation Center** (free 180-day eval) or VLSC/M365 Admin Center. Place it at `C:\HyperV-Lab\Files\SCCM\MEM_Configmgr_2509.exe` (or current version). It then needs extracting before step 7's AD schema extension can find `extadsch.exe`:

```powershell
Invoke-LabHost {
  $exe = 'C:\HyperV-Lab\Files\SCCM\MEM_Configmgr_2509.exe'
  $dst = 'C:\HyperV-Lab\Files\SCCM\extracted'
  if (-not (Test-Path "$dst\SMSSETUP\BIN\X64\setup.exe")) {
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Start-Process -FilePath $exe -ArgumentList '/Auto',$dst,'/Quiet' -Wait -NoNewWindow
  }
}
```

---

## 5. Create the Phase 1 VMs (sequential, ~10 min total)

Each `New-A-*.ps1` creates a differencing disk from the parent VHDX, injects unattend.xml, starts the VM, and converts it from Datacenter Eval to Datacenter (via `LabVMHelpers.Convert-LabVMEdition`). It also re-disables the firewall that the conversion silently re-enables.

```powershell
. .\scripts\lib\Connect-LabHost.ps1

# Sequential creation — each takes ~2 min end-to-end on this hardware
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\vms\New-A-DC.ps1'      -AdminPassword 'LabAdmin@2026!' }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\vms\New-A-DFSR.ps1'    -AdminPassword 'LabAdmin@2026!' }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\vms\New-A-MPDP.ps1'    -AdminPassword 'LabAdmin@2026!' }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\vms\New-A-SQLSCCM.ps1' -AdminPassword 'LabAdmin@2026!' }

# A-SCCM at 12 GB max is bigger than the host's free RAM at boot —
# stop hermes-linux briefly to free 4 GB, then restart it once SCCM has ballooned down.
Invoke-LabHost { Stop-VM hermes-linux -Confirm:$false }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\vms\New-A-SCCM.ps1'    -AdminPassword 'LabAdmin@2026!' }   # -StartupGB 6 set inside the script
Invoke-LabHost { Start-VM hermes-linux }   # safe to start once A-SCCM has ballooned down
# (Jarvis must NEVER be stopped — that's a hard user rule.)
```

After step 5 you have **5 Phase 1 VMs running as Windows Server 2025 Datacenter** with static IPs, firewall off, WinRM open. They're not yet domain-joined.

---

## 6. Post-deploy steps 1-8 (build the domain + SQL + SCCM Primary)

Each step is in `scripts\post-deploy\NN-*.ps1` and is invoked individually for visibility/recovery. All step scripts now use `Invoke-LabRemote` which auto-routes through Hyper-V direct (PowerShell Direct) when running from the host — avoids workgroup→domain NTLM issues, double-hop, and SMB-cred visibility problems.

```powershell
$LocalCred  = New-Object PSCredential('Administrator',       (ConvertTo-SecureString 'LabAdmin@2026!' -AsPlainText -Force))
$DomainCred = New-Object PSCredential('SADAB\Administrator', (ConvertTo-SecureString 'LabAdmin@2026!' -AsPlainText -Force))

# Step 1: SMB share \\10.10.0.1\LabMedia
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\01-Set-MediaShare.ps1' -AdminPassword 'LabAdmin@2026!' -DomainAdminPassword 'LabAdmin@2026!' -DSRMPassword 'LabAdmin@2026!' -LocalCred $using:LocalCred -DomainCred $using:DomainCred }

# Step 2: promote A-DC to forest root DC (sadab.pri) — ~4 min including reboot
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\02-Install-DomainControllers.ps1' -AdminPassword 'LabAdmin@2026!' -DomainAdminPassword 'LabAdmin@2026!' -DSRMPassword 'LabAdmin@2026!' -LocalCred $using:LocalCred -DomainCred $using:DomainCred }

# Step 3: AD structure (OUs, gMSAs, security groups, itamartz user) — <1 min
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\03-Configure-ADStructure.ps1' -AdminPassword 'LabAdmin@2026!' -DomainAdminPassword 'LabAdmin@2026!' -DSRMPassword 'LabAdmin@2026!' -LocalCred $using:LocalCred -DomainCred $using:DomainCred }

# Step 4: AD Sites & Services (Site-A, Site-B, subnets, SiteLink-A-B) — <1 min
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\04-Configure-ADSites.ps1' -AdminPassword 'LabAdmin@2026!' -DomainAdminPassword 'LabAdmin@2026!' -DSRMPassword 'LabAdmin@2026!' -LocalCred $using:LocalCred -DomainCred $using:DomainCred }

# Step 5: domain-join A-SQLSCCM, A-SCCM, A-MPDP, A-DFSR — ~2 min
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\05-Join-AllVMsToDomain.ps1' -AdminPassword 'LabAdmin@2026!' -DomainAdminPassword 'LabAdmin@2026!' -DSRMPassword 'LabAdmin@2026!' -LocalCred $using:LocalCred -DomainCred $using:DomainCred }

# Post-step-5 chore: cmdkey on each domain-joined VM so they can reach the SMB share
$DomainCred = New-Object PSCredential('SADAB\Administrator', (ConvertTo-SecureString 'LabAdmin@2026!' -AsPlainText -Force))
foreach ($vm in 'A-SCCM','A-MPDP','A-DFSR','A-SQLSCCM') {
  Invoke-LabHost {
    Invoke-Command -VMName $using:vm -Credential $using:DomainCred -ScriptBlock {
      & cmdkey /add:10.10.0.1 /user:labadmin /pass:'LabAdmin@2026!' | Out-Null
    }
  }
}

# Post-step-5 chore: add DNS forwarders on A-DC (so VMs can resolve internet names)
Invoke-LabHost {
  Invoke-Command -VMName 'A-DC' -Credential $using:DomainCred -ScriptBlock {
    Add-DnsServerForwarder -IPAddress 8.8.8.8,1.1.1.1 -ErrorAction SilentlyContinue
  }
}

# Step 6: SQL Server 2019 + CU32 on A-SQLSCCM — ~10-15 min
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\06-Install-SQL.ps1' -AdminPassword 'LabAdmin@2026!' -DomainAdminPassword 'LabAdmin@2026!' -DSRMPassword 'LabAdmin@2026!' -LocalCred $using:LocalCred -DomainCred $using:DomainCred }

# Step 7: SCCM prerequisites on A-SCCM (features + VCRedist + ODBC18 + ADK + AD schema + System Mgmt container) — ~15-25 min
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\07-Install-SCCM-Prerequisites.ps1' -AdminPassword 'LabAdmin@2026!' -DomainAdminPassword 'LabAdmin@2026!' -DSRMPassword 'LabAdmin@2026!' -LocalCred $using:LocalCred -DomainCred $using:DomainCred }

# Step 8: SCCM Primary site install on A-SCCM — ~45-90 min
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\08-Install-SCCM-Primary.ps1' -AdminPassword 'LabAdmin@2026!' -DomainAdminPassword 'LabAdmin@2026!' -DSRMPassword 'LabAdmin@2026!' -LocalCred $using:LocalCred -DomainCred $using:DomainCred }
```

After step 8 you have a working **SCCM Primary site**. The full lab configuration (MP/DP,
discovery, updates, PKI, etc.) follows in **section 7** below.

**Deferred to Phase 2 (need Host B):**
- Step 9 (SQL Always On AG) — needs Host B's SQL secondary
- Step 10 (SCCM passive node) — needs B-SCCM
- Step 12 (DFS-R) — single-site, no replica yet
- Steps 13, 14 (SCOM) — Phase 2

> Note: the legacy `11-Install-SCCM-Roles.ps1` is superseded by `Configure-SCCMRoles.ps1`
> (DSC-backed) in section 7.

---

## 7. Configure SCCM — the full lab

Run these from your PC after step 8 (they use `Invoke-LabRemote` and execute on the host).
**All are idempotent** (DSC `Test`→`Set`, or `Get-CM*` checks) and take `-DomainAdminPassword`.
**Order matters where noted** — the three hard dependencies:
> the **CA** (stood up by the reporting step) must exist **before** the SUP's SSL and before
> client PKI · the **SUP must finish syncing** before the ADR · the **SCP** must exist before
> installing in-console site updates.

Full per-script detail + every gotcha is in `CLAUDE.md` (the matching `## SCCM …` sections).
Throughout, `$pw = 'LabAdmin@2026!'` (= `lab-config.json` `defaults.domainAdminPassword`).

### 7.1 RBAC + site-server rights  (prereq: lets `A-SCCM$` push roles/clients)
```powershell
. .\scripts\lib\Connect-LabHost.ps1
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMRBAC.ps1'             -DomainAdminPassword 'LabAdmin@2026!' }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMSiteServerRights.ps1' -DomainAdminPassword 'LabAdmin@2026!' }
# A-SCCM must REBOOT to pick up its SCCM_Site_Servers group SID (manual-fixes #23), then wait for SMS_EXECUTIVE:
Invoke-LabHost { Restart-VM -Name 'A-SCCM' -Force }
```

### 7.2 Discovery + boundaries
```powershell
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMDiscovery.ps1'  -DomainAdminPassword 'LabAdmin@2026!' }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMBoundaries.ps1' -DomainAdminPassword 'LabAdmin@2026!' }   # creates BG-Site-A (needed by the DP join next)
```

### 7.3 Management Point + Distribution Point
```powershell
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMRoles.ps1' -DomainAdminPassword 'LabAdmin@2026!' }
# DP install is async (~5-15 min); re-run to converge. If content sticks at 2302, see CLAUDE.md (RefreshNow).
```

### 7.4 Client push + collection + client settings + apps
```powershell
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMClientPush.ps1'     -DomainAdminPassword 'LabAdmin@2026!' }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMCollections.ps1'    -DomainAdminPassword 'LabAdmin@2026!' }   # 'All Servers'
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMClientSettings.ps1' -DomainAdminPassword 'LabAdmin@2026!' }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Deploy-SCCMApplications.ps1'      -DomainAdminPassword 'LabAdmin@2026!' }   # 7-Zip + Notepad++
```

### 7.5 Reporting + the domain CA  (**stands up `SADAB-Root-CA` — gate for 7.6 SSL and 7.10 PKI**)
```powershell
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMReporting.ps1' -DomainAdminPassword 'LabAdmin@2026!' }
```

### 7.6 Software Update Point over HTTPS/8531 + sync
```powershell
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMSoftwareUpdatePoint.ps1' -Stage All -DomainAdminPassword 'LabAdmin@2026!' }
```
> **Gotcha (encoded in the script + CLAUDE.md):** the SCCM-driven WSUS category sync **times
> out at ~15 min** on this hardware and only lands a seed catalog. To fully populate, run a
> **WSUS-direct sync** on A-MPDP — `(Get-WsusServer).GetSubscription().StartSynchronization()`
> (async; wait for `Succeeded`) — then select products and full-sync:
> ```powershell
> Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMSoftwareUpdatePoint.ps1' -Stage Products -DomainAdminPassword 'LabAdmin@2026!' }
> # poll until updates appear:
> Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMSoftwareUpdatePoint.ps1' -Stage Status   -DomainAdminPassword 'LabAdmin@2026!' }
> ```
> Products must be selected **in WSUS** before the update-metadata sync pulls actual updates.

### 7.7 ADR (and optionally a specific update) → All Servers, Required
```powershell
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Deploy-SCCMUpdatesADR.ps1' -Stage Create -DomainAdminPassword 'LabAdmin@2026!' }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Deploy-SCCMUpdatesADR.ps1' -Stage Run    -DomainAdminPassword 'LabAdmin@2026!' }   # downloads content, deploys
# optional — deploy one specific KB Required to All Servers:
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Deploy-SCCMUpdateToCollection.ps1' -ArticleId 5087539 -DomainAdminPassword 'LabAdmin@2026!' }
```

### 7.8 Service Connection Point (Online)
```powershell
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMServiceConnectionPoint.ps1' -DomainAdminPassword 'LabAdmin@2026!' }
```

### 7.9 In-console site update (needs the SCP)
The SCP fetches the update **list** but not the payload — download it first, then install:
```powershell
# (download the in-console update so EasySetupPayload\<guid> is populated, then:)
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Install-SCCMSiteUpdate.ps1' -DomainAdminPassword 'LabAdmin@2026!' }
# Verify by the component binary version (cmupdate.exe → e.g. 5.00.9141.1030) + Update History — the
# base Get-CMSite.Version stays at the baseline for a hotfix rollup (see CLAUDE.md).
```

### 7.10 Client PKI / HTTPS  (do LAST — flips the MP to HTTPS)
```powershell
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMClientPKI.ps1' -Stage All -DomainAdminPassword 'LabAdmin@2026!' }
# verify a client selects its PKI cert and reaches the MP over HTTPS:
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMClientPKI.ps1' -Stage Verify -ClientVM A-DFSR -DomainAdminPassword 'LabAdmin@2026!' }
```

---

## 8. Verify

```powershell
# All Phase 1 VMs running and in the domain
Invoke-LabHost {
  $cred = New-Object PSCredential('SADAB\Administrator', (ConvertTo-SecureString 'LabAdmin@2026!' -AsPlainText -Force))
  foreach ($v in 'A-DC','A-DFSR','A-MPDP','A-SQLSCCM','A-SCCM') {
    $r = Invoke-Command -VMName $v -Credential $cred -ScriptBlock {
      $cs = Get-CimInstance Win32_ComputerSystem
      [PSCustomObject]@{ VM=$cs.Name; Domain=$cs.Domain; PartOfDomain=$cs.PartOfDomain }
    }
    $r
  }
}

# SCCM Primary site service alive
Invoke-LabHost {
  $cred = New-Object PSCredential('SADAB\Administrator', (ConvertTo-SecureString 'LabAdmin@2026!' -AsPlainText -Force))
  Invoke-Command -VMName 'A-SCCM' -Credential $cred -ScriptBlock {
    Get-Service SMS_EXECUTIVE, SMS_NOTIFICATION_SERVER -ErrorAction SilentlyContinue | Select-Object Name, Status
    Get-Process SCCMProviderGraph -ErrorAction SilentlyContinue | Select-Object ProcessName, Id
  }
}
```

---

## Lab credentials (lab-only — never reuse outside this lab)

| Account | Where | Password |
|---|---|---|
| `homelab` | Hyper-V host local admin | (your choice) |
| `labadmin` | Hyper-V host local user, AND inside each VM until domain join | `LabAdmin@2026!` |
| `Administrator` | Each VM (local, pre-domain) | `LabAdmin@2026!` |
| `SADAB\Administrator` | Each VM (post-domain) | `LabAdmin@2026!` |
| `SADAB\itamartz` | Domain Admin user | `LabAdmin@2026!` |

DSRM (Directory Services Restore Mode) password on A-DC is also `LabAdmin@2026!`.

---

## Troubleshooting

Every gotcha we hit during this build is documented in `scripts/manual-fixes.md`. The most common ones:

- **"WinRM cannot process the request" / 0x8009030e / 0x8009030d** — credential needs `IPADDR\user` format for NTLM local-account auth (already handled inside `Invoke-LabRemote`).
- **"Unable to contact the server" from `Get-AD*` cmdlets** — use `-Server localhost` on the DC or `-Server 10.10.0.2` from a member. The post-deploy scripts set this via `$PSDefaultParameterValues`.
- **"Access is denied" on `\\10.10.0.1\LabMedia\...`** — the VM is calling via network WinRM (NTLM token can't see the user's cmdkey). Run via Hyper-V direct instead (`Invoke-LabRemote` does this automatically now).
- **VM can't ping host even with firewall off** — Tailscale is hijacking the lab subnet's route. Re-run `Configure-Host.ps1` (it lowers `vEthernet (Lab)` InterfaceMetric and raises the Tailscale route metric).
- **`Web-Lgcy-Mgmt-Console` not found** — removed in WS2025; drop it from the feature list.
- **ODBC 18 install exit 1603** — needs VC++ Redistributable 2017+. Install `vc_redist.x64.exe` first.
- **"Cannot convert string to Feature"** — `Install-WindowsFeature -ArgumentList (,$features)` doesn't pass an array correctly via PowerShell Direct. Inline the array inside the scriptblock instead.

---

## File map

```
scripts\setup\Configure-Host.ps1          host plumbing: paths, vSwitch, NAT, route override, firewall (ICMP/WinRM/SMB), labadmin user
scripts\lib\Connect-LabHost.ps1           Invoke-LabHost / Invoke-LabHostScript / Invoke-LabVM helpers (reads hostA.ip from lab-config.json)
scripts\vms\New-A-*.ps1                   per-VM creation (one wrapper per VM)
scripts\vms\LabVMHelpers.ps1              New-LabVM, Convert-LabVMEdition, Wait-LabVMRemoting
scripts\post-deploy\NN-*.ps1 (01-08)      base post-deploy steps used here (1=share, 2=DC, 3=AD, 4=Sites, 5=join, 6=SQL, 7=prereqs, 8=Primary); 09-14 are Phase-2/legacy
scripts\post-deploy\Configure-*.ps1       SCCM config (section 7): Roles(MP/DP), Discovery, Boundaries, Collections, ClientPush, ClientSettings, RBAC, SiteServerRights, Reporting, SoftwareUpdatePoint, ServiceConnectionPoint, ClientPKI
scripts\post-deploy\Deploy-*.ps1          Applications, UpdatesADR, UpdateToCollection
scripts\post-deploy\Install-SCCMSiteUpdate.ps1   in-console site update (Updates and Servicing)
scripts\post-deploy\Verify-SCCMUpdatesOnClient.ps1   client-side update scan/install verification
scripts\post-deploy\LabHelpers.psm1       $Global:LabConfig, Write-LabLog, Invoke-LabRemote (Hyper-V direct preference), Wait-LabVMReady
scripts\post-deploy\Invoke-LabDeploy.ps1  orchestrator that chains the base 14 steps
scripts\sccm-roles\*.ps1                  manual MP / DP / SUP role helpers (the Configure-* DSC scripts are preferred)
Files\<Tool>\Install-Silent.ps1           silent-install wrappers (binaries supplied separately — see section 4)
lab-config.json                           host IP/hostname, paths, domain name, SCCM site code, lab default creds
CLAUDE.md                                 live reference doc (state, conventions, design decisions, every SCCM gotcha)
DEPLOY.md                                 this file — from-scratch build procedure
scripts\manual-fixes.md                   every gotcha and one-off command we hit
```
