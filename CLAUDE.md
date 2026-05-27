# CLAUDE.md

This file guides Claude Code when working with this repository.

## Project Overview

A 2-site **SCCM + SCOM lab** running on physical Hyper-V hardware you own, provisioned and configured end-to-end by PowerShell over WinRM.

**Status:** **Phase 1 SCCM Primary is INSTALLED and running on Host A (2026-05-23).** All 5 Site A VMs created, converted to Datacenter, domain-joined to sadab.pri. SQL 2019 + CU32 on A-SQLSCCM. SCCM Primary site **PR1** (version 5.00.9141.1000) installed on A-SCCM — SMS_EXECUTIVE + SMS_SITE_COMPONENT_MANAGER running, SMS Provider responds. **MP + DP now installed on A-MPDP (2026-05-24)** — the SCCM agent is pushed to all 4 discovered Site A servers (A-SCCM, A-SQLSCCM, A-MPDP, A-DFSR; all healthy/active), an `All Servers` device collection exists, and 7-Zip + Notepad++ are deployed as Required and verified installed (see "SCCM Client Management..." below). Host #2 not yet acquired — Site B, SCOM, SQL AG, DFSR deferred.

Remaining Phase 1 (optional): step 12 (DFSR). Phase 2 (needs Host B): SQL AG, passive SCCM, SCOM.

**Rebuild from scratch:** See `DEPLOY.md` for the sequential procedure. Every gotcha hit during the build is captured in `scripts/manual-fixes.md`.

**Domain:** `sadab.pri` (NetBIOS: `SADAB`) — stable domain/site naming keeps the post-deploy scripts reusable across rebuilds.

## Current Hardware

| | Host A (deployed) | Host B (planned) |
|---|---|---|
| Hostname | `NUCBOX_K12` | TBD |
| IP | `100.100.71.55` | TBD |
| OS | Windows 11 Pro 26200 | Windows 11 Pro or Server 2025 |
| CPU | 16 logical | ~16 logical |
| RAM | 28.8 GB | ~32 GB |
| Disk | 930 GB (829 GB free) | TBD |
| Domain | WORKGROUP | TBD |
| Hyper-V | Enabled | TBD |

**Existing non-lab VMs on Host A:**
- `Jarvis` (4 GB) — **always running, never stopped**. Treat its RAM as permanently reserved.
- `hermes-linux` (4 GB) — OK to stop briefly (a few minutes) during lab boot to free headroom, then restart. Don't leave it stopped long-term.

Effective lab budget on Host A: `28.8 GB physical - ~3 GB OS - 4 GB Jarvis - [4 GB hermes if running] = 14-18 GB`.

## Architecture

| Concern | This lab |
|---|---|
| Provisioning | Manual / scripted on existing Hyper-V hosts (PowerShell over WinRM) |
| Hosts | 2x physical mini-PCs (NUC-class) |
| VM placement | **Direct on Hyper-V host** (no nesting) |
| Networking | Hyper-V NAT vSwitch named `Lab` on each host — Host A's `Lab` is 10.10.0.0/24, Host B's `Lab` is 10.20.0.0/24, peering simulated via host route |
| Remote access | Direct WinRM over LAN (host is on `100.100.71.0/24`) |
| Internet for VMs | NAT switch gives VMs internet for Windows Update / installers |
| Lifecycle | Local `Start-VM` / `Stop-VM` wrappers (no per-minute billing, no auto-shutdown needed) |

## VM Inventory

`Phase 1` = build now. `Deferred` = scripts exist (in `scripts\vms\`) but not deployed yet; add when Host A RAM is upgraded.

| VM | IP | Site | Role | RAM | vCPU | Phase |
|---|---|---|---|---|---|---|
| A-DC | 10.10.0.2 | A | Domain Controller (sadab.pri) | 4 GB | 2 | **1** |
| A-SCCM | 10.10.0.3 | A | SCCM Primary (active, site PR1) | 12 GB | 4 | **1** |
| A-SQLSCCM | 10.10.0.4 | A | SQL 2019 (AG primary) | 8 GB | 4 | **1** |
| A-MPDP | 10.10.0.5 | A | SCCM MP + DP | 6 GB | 2 | **1** |
| A-DFSR | 10.10.0.7 | A | DFSR | 4 GB | 2 | **1** |
| A-SCOM | 10.10.0.40 | A | SCOM Management Server | 8 GB | 4 | Deferred |
| A-SQLSCOM | 10.10.0.41 | A | SQL for SCOM | 8 GB | 2 | Deferred |
| B-SCCM | 10.20.0.3 | B | SCCM Primary (passive node) | 12 GB | 4 | **1** |
| B-SQLSCCM | 10.20.0.4 | B | SQL 2019 (AG secondary) | 8 GB | 4 | **1** |
| B-MPDP | 10.20.0.5 | B | SCCM MP + DP | 6 GB | 2 | **1** |
| B-DFSR | 10.20.0.7 | B | DFSR | 4 GB | 2 | **1** |

Phase 1 total startup RAM: **64 GB** across both hosts. Phase 2 (add SCOM) brings it to 80 GB.

## RAM Strategy (Scenario 2: sequential boot + aggressive Dynamic Memory)

Physical lab budget: ~18 GB Host A + ~29 GB Host B. Phase 1 startup RAM (no SCOM) is 34 GB on Host A and 30 GB on Host B. Still exceeds simultaneous capacity — we close the gap with **(a)** sequential VM startup (small → large) and **(b)** Dynamic Memory ballooning idle VMs to ~512 MB.

`LabVMHelpers.ps1` already configures every VM as:

```powershell
Set-VMMemory -DynamicMemoryEnabled $true `
             -MinimumBytes 512MB `
             -StartupBytes <RamGB> `
             -MaximumBytes <RamGB>
```

### Boot order — Host A (Phase 1)

VMs are started one at a time, **waiting ~60–90 seconds between each** so Dynamic Memory has time to balloon the just-booted VM down before the next allocation. Jarvis stays running throughout.

| # | VM | Startup | Free after wait (hermes running) | Free after wait (hermes stopped) |
|---|---|---|---|---|
| 1 | A-DC | 4 GB | ~17 GB | ~21 GB |
| 2 | A-DFSR | 4 GB | ~16 GB | ~20 GB |
| 3 | A-MPDP | 6 GB | ~14.5 GB | ~18.5 GB |
| 4 | A-SQLSCCM | 8 GB | ~12.5 GB | ~16.5 GB |
| 5 | A-SCCM | 12 GB | ~0.5 GB **TIGHT** | ~4.5 GB ✓ |

**Recommendation:** stop `hermes-linux` briefly before the final A-SCCM boot — gives a 4 GB cushion exactly when it's needed. Restart hermes-linux as soon as A-SCCM is up and ballooned down (typically 2–3 minutes). Jarvis stays running throughout — never stop it.

### Boot order — Host B (Phase 1)

Host B has plenty of headroom (29 GB budget vs 30 GB startup), but B-SCCM's 12 GB cap should be lowered to 10 GB to leave a margin:

| # | VM | Startup | Note |
|---|---|---|---|
| 1 | B-DFSR | 4 GB | |
| 2 | B-MPDP | 6 GB | |
| 3 | B-SQLSCCM | 8 GB | |
| 4 | B-SCCM | 10 GB | cap MaximumBytes at 10 GB (down from 12) |

### Behavior

- **Idle**: Hyper-V balloons each VM toward 512 MB. Phase 1 total lab footprint ~8–10 GB.
- **Under load**: VMs grow back up to their `MaximumBytes` cap. Aggregate can exceed physical RAM if many spike at once.

**Known risk** — if SCCM Primary + SQL AG seeding all run simultaneously, Host A will swap and slow down. Acceptable for a learning lab; don't expect production timings.

### Phase 2 (when Host A RAM is upgraded to 64 GB+)

Add A-SCOM (8 GB) and A-SQLSCOM (8 GB) to Host A's sequence at the end:

| # | VM | Startup |
|---|---|---|
| 6 | A-SQLSCOM | 8 GB |
| 7 | A-SCOM | 8 GB |

Then run post-deploy steps 13 (Install-SCOM) and 14 (Import-SCCM-ManagementPack).

## Software Stack

Versions are pinned in the install scripts. Don't change without updating both the script and this table.

| Component | Version | Source / Script |
|---|---|---|
| Guest OS (parent VHDX) | Windows Server 2025 Eval (Datacenter) → auto-converted to **Datacenter** on first boot | `C:\HyperV-Lab\Base\WS2025-Eval.vhdx`, downloaded by `Download-LabFiles.ps1`. Each VM runs DISM `/Set-Edition:ServerDatacenter` with KMS key `D764K-2NDRG-47T6Q-P8T8W-YP6DF` via unattend FirstLogonCommands (orders 11-12) then reboots — escapes the Eval hourly-shutdown behavior. |
| Host OS | Windows 11 Pro 26200 | Existing on NUCBOX_K12 |
| SQL Server | **2019 Developer + CU32** | `scripts\post-deploy\06-Install-SQL.ps1` — ISO extracted with 7-Zip, applied via `/UPDATESOURCE` |
| SQL collation | `SQL_Latin1_General_CP1_CI_AS` | Set in ConfigurationFile.ini in step 06 |
| SSMS | Latest (silent install) | `Files\SSMS\Install-Silent.ps1` |
| SCCM | Current Branch | `scripts\post-deploy\08-Install-SCCM-Primary.ps1`, site code PR1 |
| SCOM (deferred) | TBD when Phase 2 runs | `scripts\post-deploy\13-Install-SCOM.ps1` |
| ADK + WinPE | Latest (silent) | `Files\ADK\Install-Silent.ps1`, `Files\ADKPE\Install-Silent.ps1` |
| SQL prereqs | ODBC 18, SQLNCLI, SQLCLR Types, VCRedist, SxS | One dir per tool under `Files\` |
| Reporting | Report Builder, SSRS | `Files\ReportBuilder\`, `Files\SSRS\` |

## Repository Layout

```
LabSystemCenterInHome\
├── CLAUDE.md                          # this file
├── lab-config.json                    # local lab config (host IPs, paths, SCCM site)
├── .secrets\                          # DPAPI-encrypted cred files (per-user/per-machine)
│   └── hyperv-host.cred.xml           # creds for 100.100.71.55
├── scripts\
│   ├── lib\
│   │   └── Connect-LabHost.ps1        # cred-load + Invoke-Command helper
│   ├── post-deploy\                   # 14-step orchestrated post-VM-creation + Configure-*/Deploy-*/Install-*
│   ├── vms\                           # Per-VM creation + post-config (LabVMHelpers.ps1)
│   ├── sccm-roles\                    # MP / DP / SUP role configuration
│   ├── setup\Configure-Host.ps1       # one-shot host prep (vSwitch, paths, firewall)
│   ├── Download-LabFiles.ps1          # Download WS2025 VHDX + SCCM/SCOM/SQL/ADK media
│   ├── Download-SCCMPrereqs.ps1       # Download SCCM prereq installers
│   └── manual-fixes.md                # Log of one-off manual commands run on hosts
└── Files\                             # Silent-install scripts only — binaries fetched via download scripts
    ├── ADK\Install-Silent.ps1
    └── SQL\... (etc., 11 dirs)
```

## Script Inventory

**Host-agnostic (runs inside guest VMs):**
- All `scripts\post-deploy\01-14*.ps1` — orchestrated post-VM-creation deploy (DC promotion → SQL AG → SCCM → SCOM)
- `scripts\post-deploy\Invoke-LabDeploy.ps1` + `LabHelpers.psm1`
- `scripts\vms\Post-*.ps1` — per-VM post-config inside the guest
- `scripts\vms\LabVMHelpers.ps1` — VM creation helpers (already uses `C:\HyperV-Lab`)
- `scripts\vms\New-*.ps1` — per-VM creation wrappers
- `scripts\sccm-roles\*.ps1` — MP/DP/SUP role config
- `Files\*\Install-Silent.ps1` — silent installers

**Host preparation:**
- `scripts\setup\Configure-Host.ps1` — one-shot, idempotent host prep (the `Lab` NAT vSwitch + parent VHDX + diff disk + unattend + VM creation prerequisites), run against a host via WinRM.
- VM lifecycle is handled with local `Get-VM | Start-VM` / `Stop-VM` (sequential boot, smallest→largest).

## Connection / Remote Access

Host A (`NUCBOX_K12` at `100.100.71.55`) is reachable via WinRM over LAN. Local-machine prerequisites are already met (TrustedHosts = `*`, WinRM service running, port 5985 open on the host).

**Credentials:** DPAPI-encrypted in `.\.secrets\hyperv-host.cred.xml` — load via `Import-Clixml`.

**Helper:** `scripts\lib\Connect-LabHost.ps1` provides `Invoke-LabHost { ... }` so you don't repeat the cred + Invoke-Command boilerplate. Example:

```powershell
. .\scripts\lib\Connect-LabHost.ps1
Invoke-LabHost { Get-VM | Select-Object Name, State }
```

For guest-VM access from the host, use Hyper-V direct connect (`Invoke-Command -VMName`). The helper exposes `Invoke-LabVM -VMName 'A-DC' -ScriptBlock { ... }` once VMs exist.

## Key Design Decisions

- **No nested virtualization** — VMs run directly on the physical Hyper-V host.
- **NAT vSwitch for VM isolation** — VMs sit on 10.10.0.0/24 (Site A) and 10.20.0.0/24 (Site B), with the host doing NAT to give them internet — isolation plus outbound access without an SMB media-share dependency.
- **Stable domain/path names** — `sadab.pri`, `C:\HyperV-Lab\` keep scripts reusable. The NAT vSwitch is named `Lab` on each host (each host's `Lab` is its own subnet's NAT); the per-VM `New-*.ps1` scripts reference that name.
- **Plan now, build later** — design is locked; building begins when Host B arrives (target ~32 GB). Until then we can validate parts on Host A (e.g., parent VHDX download, vSwitch creation, A-DC alone).
- **Cred storage** — project-local `.secrets\*.cred.xml`, DPAPI-encrypted, per-user/per-machine. Dropbox sync of the file is harmless (can't decrypt elsewhere).
- **PowerShell 5.1 only** — no PS7 syntax in scripts that target Host A (Win11 default is 5.1). Use `Bash` tool / `pwsh` only when explicitly on PS7.
- **Use `Write-LabLog` (not `Write-Log`)** — `Write-Log` conflicts with PowerCLI if it's ever installed.

## Roadmap (Build Phases)

### Phase 1 — Build now (or when Host B arrives)

1. **Host A prep**: Configure `Lab` NAT vSwitch, create `C:\HyperV-Lab\` paths, download WS2025 Evaluation VHDX (~11 GB), download SCCM/SQL/ADK media (~18 GB — skip SCOM media for now). Run via WinRM from this PC. **Jarvis stays running throughout — never stop it.** Stop hermes-linux briefly during the final A-SCCM boot, restart it as soon as A-SCCM has ballooned down.
2. **Host A — create Site A VMs sequentially** (no SCOM yet): A-DC → A-DFSR → A-MPDP → A-SQLSCCM → A-SCCM. Run `scripts\vms\New-A-*.ps1` one at a time. Skip `New-A-SCOM.ps1` and `New-A-SQLSCOM.ps1`.
3. **Host B prep** (when hardware arrives): Same as Host A.
4. **Host B — create Site B VMs sequentially**: B-DFSR → B-MPDP → B-SQLSCCM → B-SCCM (cap at 10 GB). Add cross-host AD Sites & Services site link.
5. **Run post-deploy steps 1–12**: `Invoke-LabDeploy.ps1 -SkipSteps 13,14` (or pass `-EndAtStep 12`) — covers media share, DC promotion, AD, domain join, SQL, SCCM Primary, AG, SCCM Passive, roles, DFSR. **Skip step 13 (SCOM) and step 14 (SCCM MP import)** until Phase 2.

### Phase 2 — Add SCOM (when Host A RAM ≥ 64 GB)

6. Run `scripts\vms\New-A-SQLSCOM.ps1`, then `New-A-SCOM.ps1`.
7. Run post-deploy steps 13 and 14.

## Build Learnings (Phase 1 — 2026-05-23)

Discoveries while standing up Phase 1 — encoded in scripts already, kept here as the "why":

- **Eval edition shutdown:** WS2025 Eval reboots every hour after the eval expires. Conversion to Datacenter via `DISM /Online /Set-Edition:ServerDatacenter /ProductKey:D764K-2NDRG-47T6Q-P8T8W-YP6DF /AcceptEula` (KMS client setup key from Microsoft Learn) escapes this. The conversion needs a reboot to finalize. After the reboot, **Windows re-enables the firewall** as part of the security baseline — `Convert-LabVMEdition` re-disables it.
- **DISM in unattend FirstLogonCommands is unreliable on WS2025.** The chain processes Orders 1-7 (enough to enable WinRM) but stalls before reaching slow commands. **Solution:** do the heavy lifting via Hyper-V direct WinRM after boot. See `Convert-LabVMEdition` + `Wait-LabVMRemoting` in `LabVMHelpers.ps1`.
- **Don't disable IPv6 in the unattend.** `DisabledComponents=255` on WS2025 leaves services bound to `[::]` in IPv6-only mode, killing TCP listeners for SMB/WinRM on IPv4. The unattend has this command removed (Order 9).
- **Tailscale subnet-route collision:** if a Tailscale node on the network advertises `10.10.0.0/24`, on the host that route can win over `vEthernet (Lab)` (`RouteMetric 0` < `256`) and host-to-VM traffic disappears into Tailscale. **Fix** (part of `Configure-Host.ps1` step 7a): drop `vEthernet (Lab)` `InterfaceMetric` to 1 and raise the conflicting Tailscale 10.10.0.0/24 route's `RouteMetric` to 9000. Only relevant while such an overlapping advertisement exists.
- **A-SCCM needs lower StartupBytes than MaximumBytes.** Hyper-V allocates the full `StartupBytes` at boot — it doesn't pre-emptively balloon other VMs. On a 28.8 GB host with Jarvis (4 GB), 4 idle Site A VMs and SQL holding ~8 GB just-rebooted, there isn't 12 GB to spare. **Solution** in `New-A-SCCM.ps1`: `-RamGB 12 -StartupGB 6` (boots at 6 GB, grows up to 12 GB under load via Dynamic Memory). `New-LabVM` accepts `-StartupGB` as an explicit lower-than-max override.
- **Per-VM creation time on the new flow: ~2 minutes end-to-end** (smaller VMs). DISM `/Set-Edition` is fast (~12 sec); the bulk is OOBE + WinRM-ready wait + the conversion reboot.
- **Boot order observation (matches plan):** A-DC → A-DFSR → A-MPDP → A-SQLSCCM → A-SCCM. For A-SCCM only: stop `hermes-linux` before starting it, restart hermes-linux after A-SCCM has ballooned down (~30 sec). **Never stop Jarvis** at any point.

## Current Lab State (Phase 1 complete — 2026-05-23)

| VM | IP | Edition | Boot RAM | After balloon |
|---|---|---|---|---|
| A-DC | 10.10.0.2 | Datacenter | 4 GB | ~1 GB |
| A-DFSR | 10.10.0.7 | Datacenter | 4 GB | ~1.2 GB |
| A-MPDP | 10.10.0.5 | Datacenter | 6 GB | ~1.2 GB |
| A-SQLSCCM | 10.10.0.4 | Datacenter | 8 GB | ~2 GB (under idle) |
| A-SCCM | 10.10.0.3 | Datacenter | 6 GB (max 12) | ~3 GB |

All VMs reachable via host network ICMP, TCP 5985 (WinRM), and Hyper-V direct WinRM. Domain not yet promoted; OS is local-workgroup only. **Next:** run `Invoke-LabDeploy.ps1 -StartAtStep 2 -EndAtStep 12` (skipping step 1 media-share if not needed, and steps 13-14 since SCOM is deferred).

## SCCM Configuration Convention — DSC-backed (decided 2026-05-24)

**All SCCM configuration in this lab is DSC-backed**, using the **`ConfigMgrCBDsc`**
module (PowerShell Gallery; installed on the site server A-SCCM) rather than raw
`Set-CM*` cmdlets. Every config script follows a **Test → Set-if-not-compliant** loop,
so runs are idempotent, drift is detected, and re-runs self-heal.

Because `Invoke-DscResource` fails on a site server (see gotcha below), scripts import
each `DSC_<resource>.psm1` and call `Test-TargetResource` / `Set-TargetResource`
**directly, in-process**, under `SADAB\Administrator` (which has the console, the
`SMS_ADMIN_UI_PATH` env var, and SCCM Full Administrator rights). New SCCM config work
should extend this pattern — do not add cmdlet-only configuration scripts.

## SCCM Discovery Configuration (site PR1 — applied 2026-05-24)

Configured by `scripts\post-deploy\Configure-SCCMDiscovery.ps1` — **DSC-backed (v2)**,
per the convention above. Re-running is a no-op when already compliant and self-heals
drift. All discovery is scoped to the SADAB OUs — **no Network Discovery**.

| Method | Enabled | Delta | Full sync | Stale filters (logon + pwd) | OU scope (recursive) |
|---|---|---|---|---|---|
| AD System | ✓ | 5 min | 7 days | logon 60 d + pwd 60 d | `OU=Servers` + `OU=Endpoints` |
| AD User | ✓ | 5 min | 7 days | n/a (none for users) | `OU=Users` |
| AD Group | ✓ | 5 min | 7 days | logon 60 d + pwd 60 d | `OU=Groups` (scope "SADAB Groups") |
| Forest | ✓ | — | 7 days | — | discovers AD sites/subnets; **boundary auto-creation OFF** |
| Heartbeat | ✓ | — | — | — | every **60 min** |
| Network | ✗ off | — | — | — | — |

**Why Forest is on but boundary auto-creation is off:** Forest Discovery finds AD
sites/subnets (it does *not* discover computers/users/groups). In this single-site lab
the boundary is defined by hand, so site/subnet boundary auto-creation stays disabled.

**Gotchas (encoded in the script):**
- **Don't use `Invoke-DscResource` on the site server.** It runs MOF resources
  out-of-process (the SYSTEM/WMI host) without `$env:SMS_ADMIN_UI_PATH`, so the console
  can't be located → "Cannot bind argument to parameter 'Path'". Call
  `Test`/`Set-TargetResource` directly in-process; pre-creating the `PR1:` drive makes
  the resources' own console-import short-circuit.
- **`CMHeartbeatDiscovery` / `CMForestDiscovery` only support `Days`/`Hours`** (no
  minutes). 60-min heartbeat = `Hours`/1; the script rejects a non-whole-hour value.
- **`CMGroupDiscovery` scope** is an embedded instance (`DSC_CMGroupDiscoveryScope`:
  Name/LdapLocation/Recurse) — build it with `New-CimInstance -ClientOnly`. Group's full
  poll uses `ScheduleType`/`RecurInterval`, not `ScheduleInterval`/`ScheduleCount`.
- **`ConfigMgrCBDsc` must be on the site server** (auto-installed from PSGallery when
  `-EnsureModule`, the default). Our build (5.00.9141.1000) is newer than the module's
  tested range (1902–2006), but the discovery/boundary resources work.
- AD System/Group support both stale filters (logon + computer-password); AD User has
  neither.

Re-run / verify from the host (DSC Test → Set; prints a per-resource compliance table):
```powershell
. .\scripts\lib\Connect-LabHost.ps1
# Configure-SCCMDiscovery.ps1 uses Invoke-LabRemote internally — run it on the host
# with the repo present (it auto-installs ConfigMgrCBDsc on A-SCCM if missing).
```

## SCCM Boundaries & Boundary Groups (site PR1 — applied 2026-05-24)

Configured by `scripts\post-deploy\Configure-SCCMBoundaries.ps1` — DSC-backed
(`ConfigMgrCBDsc` `CMBoundaries` + `CMBoundaryGroups`), Test → Set, idempotent.
**IP range** boundaries are used (Microsoft recommends ranges over IP-subnet boundaries).

| Boundary | Type | Value | Boundary group |
|---|---|---|---|
| Site A - 10.10.0.0/24 | IP Range | `10.10.0.1-10.10.0.254` | `BG-Site-A` |
| Site B - 10.20.0.0/24 | IP Range | `10.20.0.1-10.20.0.254` | `BG-Site-B` |

- **Site B is defined now** even though Host B isn't built — boundaries are just metadata.
- **No site systems** on the groups yet (no MP/DP roles installed). Add them to the
  boundary groups once those roles exist (Phase 1 step 11).
- **Site assignment is NOT managed by DSC**: the `CMBoundaryGroups` resource doesn't
  expose the "enable for site assignment / assigned site code" flag. Set it by hand if
  needed (`Set-CMBoundaryGroup ... -DefaultSiteCode PR1`), then record it as a known
  non-DSC exception.
- Gotcha: `CMBoundaries` `Set-TargetResource` emits the created boundary object — the
  Test→Set helper pipes `Set` to `Out-Null` so it doesn't pollute the results table.

## SCCM Client Management, Collection & App Deployment (PR1 — 2026-05-24)

Goal delivered: SCCM agent on all discovered servers (healthy), an `All Servers`
collection, and 7-Zip + Notepad++ deployed Required and verified on the SQL server.
DSC-backed (ConfigMgrCBDsc) except applications (no DSC resource — see exception).

| Piece | Script | DSC resource | Notes |
|---|---|---|---|
| MP + DP on A-MPDP | `Configure-SCCMRoles.ps1` | `CMSiteSystemServer`, `CMManagementPoint`, `CMDistributionPoint` | + IIS/BITS/RDC prereqs via `Install-WindowsFeature`; DP joined to `BG-Site-A`. |
| Client push | `Configure-SCCMClientPush.ps1` | `CMClientPushSettings` | Auto push to servers; `SMSSITECODE=PR1`; machine-account push (A-SCCM$ is local admin on targets). Then `Install-CMClient` per device. |
| All Servers collection | `Configure-SCCMCollections.ps1` | `CMCollections` | Device collection, server-OS query, daily refresh. |
| 7-Zip + Notepad++ apps | `Deploy-SCCMApplications.ps1` | **none (cmdlet, idempotent)** | Downloads latest installers → content source `\\A-SCCM\Sources` → script DT (`/S`, file detection) → distribute to DP → Required deploy to `All Servers`. |
| 'Servers' client settings | `Configure-SCCMClientSettings.ps1` | `CMClientSettings`, `CMClientSettingsHardware`, `CMClientSettingsClientPolicy` | Device settings: **Hardware Inventory every 1 h** (`Hours`/1), **Client Policy polling 5 min** (`PolicyPollingMins`). Deployment to `All Servers` is cmdlet (`New-CMClientSettingDeployment`) — no DSC resource. |

**Targets:** the 4 discovered servers (A-SCCM, A-SQLSCCM, A-MPDP, A-DFSR). **A-DC is not
discovered** — DCs live in `OU=Domain Controllers`, outside System Discovery's scope —
so it is intentionally excluded.

**DSC exceptions:** ConfigMgrCBDsc has **no application resource** and **no client-
settings *deployment* resource**. So (a) app creation/deployment and (b) attaching a
client-settings object to a collection (`New-CMClientSettingDeployment`) are cmdlet-based
(made idempotent with `Get-CM*` checks). Everything else stays DSC-backed. Creating and
*configuring* client settings IS DSC (`CMClientSettings` + the `CMClientSettings*`
category resources) — only the collection deployment is the cmdlet step.

**Gotchas (encoded in the scripts):**
- **DP install is async** (~5-15 min). `CMDistributionPoint` Test returns `$false` right
  after Set until distmgr finishes — re-run to converge.
- **Content stuck at status 2302**: packages distmgr tried to push *while the DP was still
  installing* fail and then sleep 3600s. Force them with the `SMS_DistributionPoint`
  **`RefreshNow`** WMI flag (snippet in `Configure-SCCMRoles.ps1`). The **client package
  PR100004 must be on a DP** or ccmsetup loops with `0x87d00215`.
- **Client install returns ccmsetup rc=7** (reboot required) but the client is
  operational and registers (Client=Yes, Active=Yes).
- **App auto-evaluation can stall** on freshly-pushed clients (CCM_Application stays
  `Unknown`, no `AppIntentEval.log`) even with policy present. Force via the client
  **`CCM_Application` SDK `Install`** method (snippet in `Deploy-SCCMApplications.ps1`).
  Clients only get the app assignment after a **collection update + machine policy
  retrieval**.
- **Collection query normalization**: feed `CMCollections` the EXACT query string SCCM
  stores (uppercased `SMS_R_SYSTEM` + standard columns) or Test never converges.

## Domain PKI + SCCM Reporting — RSP over HTTPS with a CA cert (PR1 — 2026-05-25)

Configured by `scripts\post-deploy\Configure-SCCMReporting.ps1` — DSC-backed. There is now
a **domain Enterprise Root CA, `SADAB-Root-CA`, on A-DC** (reused later for SCCM Agent PKI).
The **RSP role is on the PRIMARY server (A-SCCM)** — the role must be co-located with SSRS,
so SSRS is installed on A-SCCM (its ReportServer catalog DB lives on the remote SQL,
A-SQLSCCM). SSRS serves **HTTPS** at `https://a-sccm/ReportServer` with a **CA-issued**
Server-Auth cert (not self-signed); the RSP uses the **SCCM_Reports** account; the SSRS
service runs as the **virtual account** `NT SERVICE\SQLServerReportingServices`.

| Piece | DSC resource (module) | Notes |
|---|---|---|
| Enterprise Root CA | `AdcsCertificationAuthority` (ActiveDirectoryCSDsc) | on A-DC; `SADAB-Root-CA`, auto-trusted by domain members. |
| `SCCM_Reports` account | `ADUser` (ActiveDirectoryDsc) | OU=Users; data-source/connection account, with description. |
| SSRS install | `DSC_SqlRSSetup` (SqlServerDsc **15.2.0**) | on **A-SCCM**, SSRS 2022, Edition=Development. |
| SSRS catalog + URLs | `DSC_SqlRS` (SqlServerDsc 15.2.0) | ReportServer DB on **remote** A-SQLSCCM SQL. |
| HTTPS cert | `DSC_CertReq` (CertificateDsc) | WebServer template, machine context, SAN = FQDN + short. |
| CM account + RSP role | `CMAccounts` + `CMReportingServicePoint` (ConfigMgrCBDsc) | RSP `SiteServerName=A-SCCM`, DB=CM_PR1, instance=SSRS. |
| HTTPS SSL binding | **RS WMI (not DSC)** | `CreateSSLCertificateBinding` — documented exception. |

**Gotchas (encoded in the script):**
- **CA on a DC** is a lab compromise (only spare server); production prefers a member-server CA.
- **Machine-context cert enrollment**: do NOT pass `DSC_CertReq -Credential` (→ CreateProcessAsUser
  error 1314 in a remote session). Use `UseMachineContext=$true` so the **computer account** enrolls,
  which means **Domain Computers need Enroll on the WebServer template** (granted via the template AD
  object ACL + Enroll extended-right GUID `0e10c968-78fb-11d2-90d4-00c04f79dc55`). `gpupdate` first so
  the root CA lands in LocalMachine\Root.
- **SqlServerDsc 17.x is class-based and fails `Invoke-DscResource` on PS 5.1** → use **15.2.0** (MOF
  `DSC_SqlRSSetup`/`DSC_SqlRS`) with import-psm1 + `Test/Set`. Install SSRS via a SYSTEM scheduled task;
  BITS downloads must run as SYSTEM (in-session BITS = 0x800704DD).
- **DSC_SqlRS needs a SqlServer/SQLPS module on the node.** On A-SCCM (no SQL) install **SqlServer 21.x** —
  22.x forces connection encryption and rejects SQL's self-signed cert ("target principal name is incorrect").
- **HTTPS binding**: clear any orphaned http.sys binding with `netsh http delete sslcert ipport=0.0.0.0:443`
  before `CreateSSLCertificateBinding` (RS WMI namespace `...\RS_SSRS\V16\Admin`), then `SetSecureConnectionLevel(1)`.
  The cert SAN must cover the **short name** (srsrp's health check hits `https://<short>/ReportServer`).
- The RSP account must be a **CM account** (`CMAccounts`) before adding the RSP. Reports (~470) deploy over
  several minutes once srsrp reports SRS healthy.

## SCCM Software Updates — SUP over SSL + ADR (site PR1 — 2026-05-25)

The Software Update Point is on **A-MPDP** over **HTTPS port 8531** (WSUS uses the local
**WID** database), syncing from **Microsoft Update** with **Security + Critical
classifications only**. Products synced: **Microsoft Server Operating System-24H2**
(Server 2025), **Windows 11**, **Microsoft Defender Antivirus**. An **Automatic Deployment
Rule** deploys the **last month's** Security/Critical updates **Required** to the **All
Servers** collection. Verified end-to-end: A-DFSR scanned over SSL, installed
**KB5087051** (2026-05 .NET CU for Server 2025), then rebooted to finalize.

Built by (run from the host, in order):

| Script | Stages | DSC? |
|---|---|---|
| `Configure-SCCMSoftwareUpdatePoint.ps1` | WSUS, SSL, Role, SyncSource, Products, Status | SUP role + sync = DSC; WSUS/SSL = host-OS prereq |
| `Deploy-SCCMUpdatesADR.ps1` | Create, Run, Status | no — ADR has no DSC resource (documented cmdlet exception) |
| `Verify-SCCMUpdatesOnClient.ps1` | (`-Install`) | no — client-side scan/eval/install via CCM SDK WMI |

**DSC-backed** (ConfigMgrCBDsc 4.0.0): `CMSoftwareUpdatePoint` (role, `WsusSsl`, 8530/8531)
+ `CMSoftwareUpdatePointComponent` (source/classifications/products). **Cmdlet exceptions:**
the ADR, plus the sync *schedule* (build mismatch — see gotcha).

**WSUS SSL on 8531** (on A-MPDP): WebServer cert from the domain CA `SADAB-Root-CA` bound to
the *WSUS Administration* IIS site; **Require SSL + Ignore client certs on the 5 web-service
vdirs only** (ApiRemoting30, ClientWebService, DSSAuthWebService, ServerSyncWebService,
SimpleAuthWebService — content/root stay HTTP); `WsusUtil.exe configuressl A-MPDP.sadab.pri`.

**Gotchas (encoded in scripts + manual-fixes.md 2026-05-25):**
- **WSUS Admin Console (`UpdateServices-RSAT`) MUST be on the SITE server (A-SCCM)** — WCM
  manages remote WSUS via `Microsoft.UpdateServices.Administration`. Missing it = WCM
  "Supported WSUS version not found" / `WSUS_CONFIG_FAILED`. Install it, then bounce
  `SMS_EXECUTIVE` so WCM reconfigures immediately instead of waiting out its retry timer.
- **WSUS vdir Require-SSL via `appcmd ... /commit:apphost`** — `system.webServer/security/access`
  is locked at the parent, so `Set-WebConfigurationProperty` on the vdir fails.
- **The SCCM-driven WSUS category sync from Microsoft Update times out at ~15 min** on this
  RAM-constrained VM (only WSUS's ~256-product *seed* list lands; no Windows 11 / Server
  OS 24H2 / Defender). Fix: run a **WSUS-direct subscription sync**
  (`(Get-WsusServer).GetSubscription().StartSynchronization()` — async in the WsusService,
  no client timeout) to fully populate the ~430-product catalog, then an SCCM `Sync-CMSoftwareUpdate`
  ingests it. Products must be selected **in WSUS** before the update-metadata sync pulls
  the actual updates.
- **DSC `CMSoftwareUpdatePointComponent` can't enable a sync schedule on build 5.00.9141** —
  it calls `Set-CMSoftwareUpdatePointComponent -EnableSynchronization`, a param this build
  dropped for `-Schedule`. So: classifications/source/products via DSC; daily **schedule via
  the cmdlet** (`-Schedule (New-CMSchedule -RecurInterval Days -RecurCount 1)`). Raw CM
  cmdlets also need `Set-Location PR1:` first (DSC is cwd-agnostic; cmdlets are not).
- **ADR content downloads as the site server (SYSTEM → computer account over SMB loopback)** —
  the deployment-package source share needs **write for the site server** (`Domain Computers`
  Change on the share + Modify NTFS). The original `Sources` share was Everyone-read-only, so
  the ADR reported "0 of N updates downloaded" and created no deployment.
- **Server 2025 24H2 cumulative ("checkpoint CU") full content is ~13 GB** — too big for the
  64 GB site-server C:. The ADR is scoped `-Architecture X64 -Product 'Microsoft Server
  Operating System-24H2'` (all lab servers are Server 2025 x64); the giant OS LCU is
  intentionally not deployed in this disk-limited lab — the lighter .NET/SSU Security/Critical
  updates prove the full pipeline. The SUP still *syncs* the broader product set.

Re-run / verify from the host (each stage is idempotent):
```powershell
. .\scripts\lib\Connect-LabHost.ps1
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Configure-SCCMSoftwareUpdatePoint.ps1' -Stage Status -DomainAdminPassword 'LabAdmin@2026!' }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Deploy-SCCMUpdatesADR.ps1'           -Stage Status -DomainAdminPassword 'LabAdmin@2026!' }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Verify-SCCMUpdatesOnClient.ps1' -VMName A-DFSR -DomainAdminPassword 'LabAdmin@2026!' }
```

## SCCM client PKI / HTTPS communication (PR1 — 2026-05-26)

The SCCM **agent connects to the MP over HTTPS using a PKI client-authentication
certificate**. Built by `Configure-SCCMClientPKI.ps1` (stages Template / ClientCerts /
MPCert / SCCM / Verify / Status). Verified on A-DFSR: ClientIDManagerStartup.log shows
*">>> Client selected the PKI Certificate [B3EDEBF5...] issued to A-DFSR.sadab.pri / Client
PKI cert is available"* and LocationServices.log shows *"A-MPDP.sadab.pri HTTPS: 'Y' ...
retrieve default management points via HTTPS"*.

End state:
- **Client cert:** every domain computer autoenrolls a **Workstation Authentication**
  (Client Auth EKU) cert from `SADAB-Root-CA`. Granted Domain Computers Enroll+**Autoenroll**
  on the template + published it to the CA; autoenrollment driven by a GPO
  *SADAB Computer Certificate AutoEnrollment* (AEPolicy=7, set via `Set-GPRegistryValue`).
- **MP HTTPS:** A-MPDP's Web Server cert (the same SADAB-Root-CA cert used for WSUS 8531)
  bound to **Default Web Site:443**; `CMManagementPoint -EnableSsl $true`.
- **Site:** `CMSiteConfiguration -ClientComputerCommunicationType HttpsOrHttp
  -UsePkiClientCertificate $true -ClientCertificateSelectionCriteriaType ClientAuthentication`.

DSC-backed: `CMManagementPoint` (EnableSsl) + `CMSiteConfiguration` (the PKI/comm props).
Non-DSC (documented exceptions): the CA template ACL + autoenrollment GPO + the IIS 443
cert binding — AD/GPO/IIS operations with no DSC resource.

**Gotchas (encoded in the script):**
- **A single MP is HTTP *or* HTTPS, not both.** With one MP, flipping it to HTTPS removes
  the HTTP MP, so **every managed server must already hold a Client-Auth cert** or it loses
  its MP. The script's `ClientCerts` stage autoenrolls all servers (gpupdate + `certutil
  -pulse`) **before** the `SCCM` stage flips the MP. `HttpsOrHttp` (not `HttpsOnly`) keeps a
  safety margin.
- **Cert-less probe of the HTTPS MP returns 403** (`https://a-mpdp/SMS_MP/.sms_aut?MPLIST`) —
  that's expected (it wants a client cert). The same request **with** a Client-Auth cert
  returns **HTTP 200** + the MP list. Don't mistake the 403 for a broken MP.
- Workstation Authentication certs have an **empty Subject** (identity is the FQDN in the
  SAN) — normal; the SCCM client selects them by the Client Authentication EKU.
- Verify on the client via `ClientIDManagerStartup.log` ("Client selected the PKI
  Certificate") + `LocationServices.log` ("HTTPS: 'Y'"), not by probing the MP URL.

## SCCM specific-update deployment + Updates and Servicing (PR1 — 2026-05-26)

Two more cmdlet-based exceptions (no DSC resource for either — same family as the ADR /
apps / software update groups):

**Deploy a specific update Required to a collection** — `Deploy-SCCMUpdateToCollection.ps1`
(stages Group / Download / Distribute / Deploy / Status). Used to put **KB5087539** (the
2026-05 Server 2025 24H2 OS cumulative) as a **Required** deployment on **All Servers**.
Gotchas learned:
- `New-CMSoftwareUpdateDeployment` on this build **refuses a SUG whose content isn't
  downloaded yet** ("objects ... are not yet downloaded") — order must be Group -> Download
  -> Distribute -> Deploy.
- `Get-CMSoftwareUpdateDeployment` has **no `-SoftwareUpdateGroupName`** (use `-Name`);
  `New-CMSoftwareUpdateDeployment` **does** have `-SoftwareUpdateGroupName`.
- `Save-CMSoftwareUpdate` from the remote (Hyper-V direct) session returned **"Access is
  denied"** at the SMS-Provider level (no PatchDownloader.log produced) — the console-
  download path didn't work in this context. The reliable path is the **ADR's** download
  (runs as the site server / SYSTEM): re-invoking the ADR with ample disk pulled KB5087539
  (~12.7 GB) into package `Monthly Server Updates` and produced a Required deployment to
  All Servers. A-SCCM C: had since been expanded to 100 GB, so the OS checkpoint CU fit.
- The Server 2025 24H2 cumulative is a ~12.7 GB "checkpoint" CU; the .NET CU is ~0.5 GB.

**Install an in-console site update ("Updates and Servicing")** — `Install-SCCMSiteUpdate.ps1`.
Used to install **KB36949461** (CM 2509 Hotfix Rollup, 5.00.9141.1000 -> .1030). NOT
DSC-backable: ConfigMgrCBDsc has **no** site-update/servicing resource (`xSccmInstall` is a
composite for the *initial* CM install only), and a version upgrade is a one-time servicing
action, not declarative config. Gotchas:
- The SCP downloads the update **list** (metadata) quickly but NOT the **payload**. You must
  `Invoke-CMSiteUpdateDownload` first and wait for the content to land in
  `...\EasySetupPayload\<guid>\` (KB36949461 = guid 945cbfe2..., ~274 MB). `Install-CMSiteUpdate`
  on a not-yet-downloaded update fails with "Cannot perform an update at this time ... package
  state is valid". State lifecycle observed: **327682** (available) -> **262146** (downloaded/
  ready) -> **65537** (installing) -> **196612** (installed).
- A **hotfix rollup does NOT change the base `Get-CMSite.Version`** (stays at the 2509
  baseline 5.00.9141.1000, `CULevel`=0). Verify success by the **component binary versions**
  (`cmupdate.exe` / `setupcore.dll` / SMS Provider report **5.0.9141.1030** in CMUpdate.log)
  and **Update History** (KB36949461 shows FullVersion 5.00.9141.1030, State 196612). Don't
  poll the base version for completion — it never moves for a rollup.
- The upgrade stops/restarts SMS_EXECUTIVE + SMS_SITE_COMPONENT_MANAGER. The CMUpdate.log
  "Failed to CoCreateInstance ... SCOM/MOM maintenance mode (0x80040154)" lines are **benign**
  (no SCOM agent present) - not an install failure. Post-upgrade both services + the
  AdminService (SCCMProviderGraph.exe) come back healthy.

## SCCM Service Connection Point (site PR1 — 2026-05-26)

The **Service Connection Point** (internal role name *SMS Dmp Connector*) is installed on
the **Primary server A-SCCM** in **Online** mode (A-SCCM has internet via the Lab NAT
switch). There is one SCP per hierarchy; on a standalone primary it goes on the primary.
DSC-backed via `Configure-SCCMServiceConnectionPoint.ps1` (ConfigMgrCBDsc
`CMServiceConnectionPoint`, Test → Set). Verify: `Get-CMServiceConnectionPoint` (mode =
Online means `OfflineMode` prop = 0). The role runs as threads under SMS_EXECUTIVE
(SMS_DMP_DOWNLOADER/UPLOADER) — there is no standalone Windows service, so an empty
`Get-Service SMS_SERVICE_CONNECTION_POINT` is normal. Clean install, no gotchas.

## Memory & Conventions

- This project uses Claude Code auto-memory at `C:\Users\Itamartz\.claude\projects\C--Users-Itamartz-Dropbox-System--FORWORK-LabSystemCenterInHome\memory\`. Read `MEMORY.md` for user/project preferences captured across sessions.
