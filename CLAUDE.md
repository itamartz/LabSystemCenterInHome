# CLAUDE.md

This file guides Claude Code when working with this repository.

## Project Overview

A 2-site **SCCM + SCOM lab** running on physical Hyper-V hardware you own, provisioned and configured end-to-end by PowerShell over WinRM.

**Status:** Phase 1 SCCM Primary is INSTALLED and running on Host A (2026-05-23). All 5 Site A VMs created, converted to Datacenter, domain-joined to sadab.pri. SQL 2019 + CU32 on A-SQLSCCM. SCCM Primary site **PR1** (version 5.00.9141.1000) installed on A-SCCM — SMS_EXECUTIVE + SMS_SITE_COMPONENT_MANAGER running, SMS Provider responds. **MP + DP now installed on A-MPDP (2026-05-24)** — the SCCM agent is pushed to all 4 discovered Site A servers (A-SCCM, A-SQLSCCM, A-MPDP, A-DFSR; all healthy/active), an `All Servers` device collection exists, and 7-Zip + Notepad++ are deployed as Required and verified installed (see "SCCM Client Management..." below).

**Phase 2 partial (2026-05-31 / 2026-06-01):** Host B (`MS-A2`) onboarded, cross-host networking validated, and the SCOM stack is now LIVE — **B-SCOMMS + B-SQLSCOM** built, **SCOM 2025 Management Server installed** with management group `LAB-SCOM-MG`, **SCOM agent deployed to all 6 SCCM-side VMs** (A-DC, A-SQLSCCM, A-MPDP, A-SCCM, A-DFSR, B-MPDP — all `HealthState=Success`, agent build 10.25.10079.0), and the **Windows Server Operating System 2016+ Management Pack** imported (the 10.1.x family covers Server 2016/2019/2022/2025; "Microsoft Windows Server 2025 Datacenter" is the discovered class instance). Remaining Phase 2: B-SCCM passive node + B-SQLSCCM AG secondary + B-DFSR (need more Host B RAM / project priority).

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

**Pre-existing non-lab workloads on Host A:** Host A already runs some unrelated VMs. Treat
their RAM as reserved — assume **~4–8 GB** is permanently spoken for and is not available to
the lab. The lab tooling must never stop, pause, or restart any VM it did not create.

Effective lab budget on Host A: `28.8 GB physical - ~3 GB OS - ~4–8 GB reserved non-lab workloads = 14-18 GB`.

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
| B-SCCM | 10.20.0.3 | B | SCCM Primary (passive node) | 12 GB | 4 | **2** (Host B + RAM) |
| B-SQLSCCM | 10.20.0.4 | B | SQL 2019 (AG secondary) | 8 GB | 4 | **2** (Host B + RAM) |
| B-MPDP | 10.20.0.5 | B | SCCM MP + DP | 6 GB | 2 | **2** |
| B-DFSR | 10.20.0.7 | B | DFSR | 4 GB | 2 | **2** (Host B + RAM) |
| B-SCOMMS | 10.20.0.40 | B | SCOM Management Server (LAB-SCOM-MG) | 6 GB | 4 | **2** |
| B-SQLSCOM | 10.20.0.41 | B | SQL 2019 for SCOM (Operational + DW DBs) | 8 GB | 4 | **2** |

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

VMs are started one at a time, **waiting ~60–90 seconds between each** so Dynamic Memory has time to balloon the just-booted VM down before the next allocation.

| # | VM | Startup | Free after wait |
|---|---|---|---|
| 1 | A-DC | 4 GB | ~17 GB |
| 2 | A-DFSR | 4 GB | ~16 GB |
| 3 | A-MPDP | 6 GB | ~14.5 GB |
| 4 | A-SQLSCCM | 8 GB | ~12.5 GB |
| 5 | A-SCCM | 12 GB | ~0.5 GB **TIGHT** |

**Recommendation:** A-SCCM is created with a reduced `-StartupGB 6` (boots at 6 GB, grows to 12 GB under load via Dynamic Memory) so it fits the available headroom at the final boot. If headroom is still tight, free RAM by temporarily quiescing other non-lab workloads on the host *before* starting A-SCCM, then restore them once it has ballooned down. The lab tooling must never stop, pause, or restart any VM it did not create.

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
| SQL Server | **2019 Developer + CU32 (KB5068404)** | `scripts\post-deploy\06-Install-SQL.ps1` — ISO extracted with 7-Zip; CU applied as a standalone patch (first `SQLServer2019-KB*.exe` in the SQL media folder, `/Action=Patch`) |
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

1. **Host A prep**: Configure `Lab` NAT vSwitch, create `C:\HyperV-Lab\` paths, download WS2025 Evaluation VHDX (~11 GB), download SCCM/SQL/ADK media (~18 GB — skip SCOM media for now). Run via WinRM from this PC. The lab tooling must never stop, pause, or restart any pre-existing non-lab VM; if headroom is tight at the final A-SCCM boot, the operator may temporarily quiesce other non-lab workloads, then restore them once A-SCCM has ballooned down.
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
- **A-SCCM needs lower StartupBytes than MaximumBytes.** Hyper-V allocates the full `StartupBytes` at boot — it doesn't pre-emptively balloon other VMs. On a 28.8 GB host with ~4–8 GB reserved for non-lab workloads, 4 idle Site A VMs and SQL holding ~8 GB just-rebooted, there isn't 12 GB to spare. **Solution** in `New-A-SCCM.ps1`: `-RamGB 12 -StartupGB 6` (boots at 6 GB, grows up to 12 GB under load via Dynamic Memory). `New-LabVM` accepts `-StartupGB` as an explicit lower-than-max override.
- **Per-VM creation time on the new flow: ~2 minutes end-to-end** (smaller VMs). DISM `/Set-Edition` is fast (~12 sec); the bulk is OOBE + WinRM-ready wait + the conversion reboot.
- **Boot order observation (matches plan):** A-DC → A-DFSR → A-MPDP → A-SQLSCCM → A-SCCM. For A-SCCM only, if the host is short on RAM at the final boot, the operator may temporarily quiesce a non-lab workload to free headroom, then restore it after A-SCCM has ballooned down (~30 sec). The lab tooling itself never stops VMs it did not create.

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

## SCOM Configuration Convention — DSC-style Test/Set (decided 2026-06-01)

**All SCOM configuration in this lab follows the same Test → Set idempotency pattern
as SCCM.** Each config script defines explicit `Test-<thing>` / `Set-<thing>` helpers
around the in-product `OperationsManager` PowerShell cmdlets, runs Test, runs Set only
on drift, then Re-Tests. Re-runs are no-ops when in compliance.

**Why we wrap cmdlets ourselves instead of using a DSC module:** the only published
SCOM DSC module — `xSCOM` (dsccommunity) — is **deprecated**, hasn't been updated to
target SCOM 2022 or 2025, and its MOF resources call deprecated cmdlet aliases
(`Get-SCManagementPack` / `Import-SCManagementPack`) that aren't guaranteed in SCOM 2025.
Wrapping the supported cmdlets directly is more durable and keeps idempotency explicit
in the script. We follow the same in-process Test→Set pattern as the SCCM scripts; new
SCOM config work should extend this pattern, not introduce cmdlet-only scripts.

**Documented one-shot exceptions** (parallel to SCCM's `xSccmInstall` composite):
- `13b-Install-SCOM-B-SCOMMS.ps1` — the SCOM 2025 `Setup.exe` Management Server bootstrap
  install is a one-shot bootstrap, not declarative configuration. Idempotency comes
  from a single "is HealthService installed?" check at the top.
- `06b-Install-SQL-B-SQLSCOM.ps1` — likewise the SQL 2019 install is one-shot; the
  script does check for MSSQLSERVER service presence and only adds Full-Text Search
  in-place when needed (idempotent add-feature path).

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

## SCOM 2025 Management Server install (LAB-SCOM-MG — 2026-06-01)

The SCOM stack lives on Site B (Host B):

| VM | IP | Role | RAM / vCPU | Notes |
|---|---|---|---|---|
| **B-SCOMMS** | 10.20.0.40 | SCOM 2025 Management Server (Root MS) | 6 GB / 4 | LAB-SCOM-MG; HealthService + OMSDK + cshost running |
| **B-SQLSCOM** | 10.20.0.41 | SQL 2019 Dev + CU32 + **FullText** | 8 GB / 4 | `OperationsManager` + `OperationsManagerDW` databases; data on `D:\SQLData`, +100 GB data disk |

Built by (run from the host, in order):

| Script | Purpose | DSC? |
|---|---|---|
| `06b-Install-SQL-B-SQLSCOM.ps1` | SQL 2019 + CU32 + FullText | one-shot bootstrap (documented exception) |
| `13b-Install-SCOM-B-SCOMMS.ps1` | SCOM 2025 MS via setup.exe | one-shot bootstrap (documented exception) |
| `15-Install-SCOMAgents.ps1` | Push agent to all SCCM-side VMs | Yes — DSC-style Test→Set wrappers around `Install-SCOMAgent` |
| `16-Import-WindowsServerOS-MP.ps1` | Extract + import the Server-OS MP family | Yes — DSC-style Test→Set wrappers around `msiexec` and `Import-SCOMManagementPack` |
| `17-Install-SCOMConsole-B-SCOMMS.ps1` | SCOM 2025 Operations Console (co-located with MS) | Yes — DSC-style Test (exe + registry probe) → Set (`setup.exe /install /components:OMConsole`) |
| `18-Import-RelevantMPs.ps1` | All MPs relevant to the SADAB environment (ADDS, ADCS, DNS, IIS, SQL, SSRS, WSUS, Defender) | Yes — per-family DSC-style Test (`Get-SCOMManagementPack` by name pattern) → Set (BITS download → msiexec extract → `Import-SCOMManagementPack`) |
| `19-Enable-SCOMAgentProxy.ps1` | Enables `ProxyingEnabled=True` on every agent (required by many MPs — AD, SQL clusters, IIS app pools, clustered roles) | Yes — per-agent DSC-style Test (`Get-SCOMAgent.ProxyingEnabled.Value`) → Set (`Enable-SCOMAgentProxy`). Re-run after script 15 for newly-pushed agents. |
| `20-Close-SCOMAlerts.ps1` | Force-closes active alerts (ResolutionState != 255). Reports per-alert refusals from SCOM (it blocks closing a monitor-based alert while the monitor is still Unhealthy). | Yes — DSC-style Test (`Get-SCOMAlert | Where ResolutionState -ne 255`) → Set (`Set-SCOMAlert -ResolutionState 255`). |
| `21-Apply-SADABOverrides.ps1` | Authors lab-specific SCOM overrides in unsealed `SADAB_<source>_Overrides` MPs (the naming convention) when a monitor genuinely needs suppressing. **Not used in the current build** — root-cause fixes (script 22) cleared all noise. Kept as the documented mechanism if a future situation demands suppression. | Yes — per (source MP, monitor) DSC-style Test (override exists? property `Enabled=false`?) → Set (build unsealed MP + `Disable-SCOMMonitor -ManagementPack <unsealed>`). |
| `22-Fix-SCOMAlertRootCauses.ps1` | Fixes the actual conditions the noise monitors flag rather than suppressing them: A-DC NIC DNS set to `10.10.0.2,127.0.0.1` (Microsoft single-DC recommended pattern), daily Defender QuickScan schedule + immediate scan on all 8 monitored servers. After running, every "Defender scan" and "NetworkAdapters DNS" monitor flips Healthy and the alerts auto-close. | Yes — per-VM DSC-style Test (`Get-DnsClientServerAddress` / `Get-MpPreference`) → Set (`Set-DnsClientServerAddress` / `Set-MpPreference`) + a one-shot `Start-MpScan` to flip the monitor immediately. |
| `23-Install-MCM-ManagementPack.ps1` | Imports Kevin Holman's community MCM (Microsoft Configuration Manager) management pack — the replacement for the deprecated Microsoft SCCM MP that MS removed from the Download Center. Source: https://github.com/thekevinholman/MCM. The single sealed `MECM.mp` file is downloaded directly from the GitHub raw URL. | Yes — DSC-style Test (`Get-SCOMManagementPack -Name 'MECM' \| version >= 5.0.2303.2`) → Set (BITS download MECM.mp → `Import-SCOMManagementPack`). |

**Lab simplifications:** Action / DAS / DataReader / DataWriter accounts all run as
`SADAB\Administrator` (single-account lab; in production these should be four separate
service accounts). Management group name is sourced from `lab-config.json`
(`scom.managementGroup = LAB-SCOM-MG`).

**Gotchas (encoded in scripts + `scripts/manual-fixes.md` 2026-06-01):**
- **SCOM 2025 silent install syntax changed.** The legacy `/install:ManagementServer`
  fails immediately with `Invalid command line switches - no components switch found.
  Error : 0x80004005` (see `Setup<N>.log` in `C:\Users\<acct>\AppData\Local\SCOM\LOGS`).
  SCOM 2025 splits these into two switches: `/install` (verb) plus
  `/components:OMServer` (role). Other roles: `OMConsole`, `OMWebConsole`, `OMReporting`.
  [Reference](https://learn.microsoft.com/system-center/scom/install-using-cmdline?view=sc-om-2025#command-line-parameters).
- **SCOM 2025 requires SQL Full-Text Search** on every SQL instance hosting an
  OperationsManager database. The Setup wizard fails fast (exit `-17`) with
  `OpsMgrSetupWizard.log` showing "Sql Server does not have Full Text Search
  installed.". `06b` now installs `FEATURES=SQLENGINE,FULLTEXT,CONN,SNAC_SDK` and its
  idempotency branch adds FullText in-place via
  `setup.exe /Action=Install /Features=FullText /InstanceName=MSSQLSERVER` if missing
  (~30s on this lab VM).
- **Health states right after install.** `Get-SCOMAgent` reports `Uninitialized` for
  the first 5-10 min after push — the agent has to complete its first connect, request
  initial config, download MPs, and send a heartbeat before the MS marks it Healthy.
  In the meantime, the agent's local Operations Manager event log will show event 20070
  "OpsMgr Connector connected to ... but the connection was closed immediately after
  authentication" — this is benign while pending approval; the script auto-runs
  `Approve-SCOMPendingManagement`. Final state on this lab: all 6 agents Success
  with agent build `10.25.10079.0`.

Re-run / verify from the host (each script is idempotent — all-`[TEST PASS]` on a healthy run):
```powershell
. .\scripts\lib\Connect-LabHost.ps1
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\15-Install-SCOMAgents.ps1' }
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\16-Import-WindowsServerOS-MP.ps1' }
```

## SCOM Windows Server OS Management Pack — Server 2025 (LAB-SCOM-MG — 2026-06-01)

Imported by `Configure-SCOM`'s `16-Import-WindowsServerOS-MP.ps1` from
[Microsoft System Center Management Pack for Windows Server Operating System 2016 and
above](https://www.microsoft.com/en-us/download/details.aspx?id=54303) (MSI version
10.1.2.2 dated 5/12/2025; MP content version 10.1.1.0). **The same package covers
Server 2016, 2019, 2022, AND 2025** — there is no separate "2025" MP, the OS class
self-identifies via WMI at the agent. The discovered display name is "Microsoft Windows
Server 2025 Datacenter" with HealthState `Success`.

| MP imported | Version | Sealed |
|---|---|---|
| Microsoft.Windows.Server.Library | 10.1.1.0 | yes |
| Microsoft.Windows.Server.2016.Discovery | 10.1.1.0 | yes |
| Microsoft.Windows.Server.2016.Monitoring | 10.1.1.0 | yes |
| Microsoft.Windows.Server.2016.ProcessPortMonitoring | 10.1.1.0 | yes |
| Microsoft.Windows.Server.ClusterSharedVolumeMonitoring | 10.1.1.0 | yes |
| Microsoft.Windows.Server.Html5.Dashboard | 10.1.1.0 | yes |
| Microsoft.Windows.Server.NetworkDiscovery | 10.25.10132.0 | yes (ships with SCOM 2025 media) |
| Microsoft.Windows.Server.Reports | 10.1.1.0 | yes |

**Gotchas (encoded in `16-Import-WindowsServerOS-MP.ps1`):**
- **The MSI install path label changes between MP versions** ("Microsoft System Center
  MP for WS 2016 and above" today; expect renames). The script discovers it via
  `Get-ChildItem` filtered by name pattern rather than hardcoding.
- **Sealed `.mpb` files don't expose Name/Version via simple XML reads.** The DSC-style
  Test step uses the file's BaseName as the SCOM `Name` (the package files are named
  after the MP's `Name` element, so this match works for the out-of-band catalog MPs).
  Version comparison is deferred — presence-by-name is sufficient for lab idempotency.
- **Batch import vs. one-by-one passes.** `Import-SCOMManagementPack -FullName <array>`
  lets SCOM resolve dependency order on its own; if the batch fails (typically due to
  a dependency timing issue) the script falls back to one-by-one with retry passes.

## SCOM environment-relevant Management Packs (2026-06-01)

`18-Import-RelevantMPs.ps1` downloads and imports the Microsoft management pack family that
maps to every server role actually installed in SADAB. Re-runs are `[TEST PASS]` no-ops.

| MP family | DL id | Component covered | Sub-MPs imported |
|---|---|---|---|
| Windows Server OS 2016+ | 54303 | Server 2025 base OS on all 8 VMs | 8 (incl. Server.Library, 2016.Discovery/Monitoring, NetworkDiscovery from SCOM media) |
| AD DS 2016+ | 54525 | A-DC AD DS | 8 (`Microsoft.Windows.Server.AD.*`) |
| AD CS 2016+ | 56671 | A-DC `SADAB-Root-CA` | 3 (`Microsoft.Windows.*CertificateServices.*`) |
| DNS 2016+ | 54524 | A-DC DNS server | 3 (`Microsoft.Windows.DNSServer.*`) |
| IIS 2016+ | 54445 | A-MPDP / A-SCCM / B-MPDP IIS | 2 (`Microsoft.Windows.InternetInformationServices.*`) |
| SQL Server (any version) | 108512 | A-SQLSCCM + B-SQLSCOM (SQL 2019) | 9 (`Microsoft.SQLServer.Core/Windows/IS/Visualization`) |
| SQL Reporting Services | 57381 | A-SCCM SSRS (SCCM RSP) | 4 (`Microsoft.SQLServer.ReportingServices.*`) |
| WSUS 2016 | 54509 | A-MPDP WSUS | 1 (`Microsoft.Windows.Server.UpdateServices.2016`) |
| Windows Defender | 54081 | Defender on all servers | 1 (`Microsoft.WindowsDefender`) |

**Documented gaps (deliberately excluded):**
- **SCCM Configuration Manager MP** — the legacy id=34709 page was removed from the
  Microsoft Download Center (returns 404) and SCCM Current Branch 2509 doesn't ship a
  SCOM MP either. The A-SCCM site server is still covered by the OS + IIS + SQL (CM_PR1
  DB on A-SQLSCCM) + WSUS MPs above.
- **MSDTC 2016+ MP** (id=54271) — the published MP file imports with `The requested
  management pack is not valid` on SCOM 2025 (broken dependency for the 10.0.0.1 build),
  and SADAB doesn't actually exercise distributed transactions (SCCM CB doesn't, SQL AG
  doesn't). The MSDTC *service* still gets baseline state monitoring via the Windows
  Server OS MP.

**Gotchas (encoded in the script):**
- **MS Download Center hides direct `download.microsoft.com` URLs from raw HTML** — the
  pages emit URLs only via JavaScript-rendered React state. The script therefore
  hardcodes URLs that were captured once via a JS-aware browser tool (legacyupdate.net
  mirror for older MPs, MS Download Center via Chrome React-fiber walk for the newer
  SQL/SSRS). If a URL goes stale, refresh it the same way (see the comment block at the
  top of script 18) or drop the new MSI into `C:\HyperV-Lab-Local\MPs-Download\` on
  B-SCOMMS manually; the script picks it up if the filename matches.
- **MSI install dir name varies between MP versions, and some MPs (SQL 7.12, SSRS 7.8)
  extract into a version subfolder** under the install root. The script doesn't snapshot
  "new dirs since msiexec" — that's fragile when a prior partial run left dirs in place.
  Instead each catalogue entry carries an `ExpectedDirName` substring that names the
  install dir to look in, and `.mp/.mpb` collection recurses into subfolders.
- **Test patterns must exactly match imported MP names** (PowerShell `-like` wildcards,
  so use `.*` between segments but `.` is literal). Mismatches cause silent "RE-TEST
  FAIL" + a needless re-import next run. Imported names live in
  `Get-SCOMManagementPack | Sort Name`.
- **Re-importing a same-version MP throws `The requested management pack is not valid`**
  with inner message `Cannot import management pack [...] This version of the MP is
  already imported in the database`. That's why Test-MpFamilyImported runs *first* —
  but if the family's MP name doesn't match the patterns, Set fires and you'll see this
  benign error. Fix the pattern, don't retry the import.

Re-run / verify from the host (idempotent):
```powershell
. .\scripts\lib\Connect-LabHost.ps1
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\18-Import-RelevantMPs.ps1' }
```

## MCM (SCCM) Management Pack — Kevin Holman community MP (2026-06-01)

The Microsoft-shipped SCCM MP for SCOM was deleted from the Download Center
(id=34709 returns 404) and SCCM Current Branch 2509 doesn't ship a SCOM MP
either, so the gap in script 18 is filled by **Kevin Holman's MCM MP**:

| | |
|---|---|
| Source | https://github.com/thekevinholman/MCM |
| File | `MECM.mp` — single sealed MP, ~258 KB |
| Version | 5.0.2303.2 (8/3/2023) |
| Imports as | `Name=MECM`, `DisplayName="Microsoft Configuration Manager"`, `Sealed=True` |
| Script | `scripts/post-deploy/23-Install-MCM-ManagementPack.ps1` (DSC-style Test→Set) |

**Lab discoveries within minutes of import (auto-discovered via WMI on the
SCCM-managed agents):**

| Class | Instance(s) | Members |
|---|---|---|
| `MECM.SiteSystem` | 2 | A-SCCM, A-MPDP |
| `MECM.Client` | 4 | A-SCCM, A-SQLSCCM, A-MPDP, A-DFSR |
| `MECM.SiteServerComputers.Group` | 1 (A-SCCM) | site server |
| `MECM.SiteDatabaseComputers.Group` | 1 (A-SQLSCCM) | site DB (CM_PR1) |
| `MECM.ManagementPointComputers.Group` | 1 (A-MPDP) | MP role |
| `MECM.DistributionPointComputers.Group` | 1 (A-MPDP) | DP role |
| `MECM.SoftwareUpdatePointComputers.Group` | 1 (A-MPDP) | SUP role |
| `MECM.PrimarySiteComputers.Group` | 1 (A-SCCM) | primary site |
| `MECM.Hierarchy.Root` | 1 | the PR1 hierarchy |

B-MPDP appears as a SCOM agent but **not** in any MECM group — by design, since
Site B's SCCM stack isn't built yet (Phase 2 still pending for B-SCCM /
B-SQLSCCM).

**Lab-relevant defaults the MP ships with (from the author's release notes):**
- SMSExec service monitor **disabled** on Site Database Computers Group (so SQL
  DB servers don't get flagged for not running SMSExec). Matches our setup -
  A-SQLSCCM hosts CM_PR1 but isn't a site server.
- PXE role monitor checks **`SccmPxe`** service (not `wdsserver`). Switch the
  override if you ever enable PXE via WDS instead.
- Aggregate/dependency rollup alerts are intentionally disabled - real noise
  comes from the unit monitors only.

Re-run / verify from the host:
```powershell
. .\scripts\lib\Connect-LabHost.ps1
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\23-Install-MCM-ManagementPack.ps1' }
```

## SCOM alert hygiene — fix-the-root-cause + override naming convention (2026-06-01)

The fresh-install SCOM lab raised 9 active alerts after MPs imported. **All 9
were cleared via root-cause fixes, with zero overrides used.** The convention
documented here for future noise:

**Naming convention for lab-specific override MPs:** `SADAB_<source>_Overrides`,
one unsealed MP per source sealed MP being overridden. Example: an override
into `Microsoft.WindowsDefender` lives in `SADAB_WindowsDefender_Overrides`.
This is what `21-Apply-SADABOverrides.ps1` produces if it's ever needed - it
authors unsealed MPs and calls `Disable-SCOMMonitor -ManagementPack <unsealed>`
to add `MonitorPropertyOverride` entries with `Enabled=false`.

**Why overrides go in an unsealed MP at all:** SCOM physically refuses to save
an override into a sealed (vendor) MP. The unsealed MP holds the override and
references the sealed MP it modifies - removing the sealed MP cleanly removes
its overrides MP too.

**Where SCOM fights you when closing alerts:** monitor-based alerts cannot be
closed via `Set-SCOMAlert -ResolutionState 255` while the underlying monitor is
still Unhealthy - SCOM returns "the alert ... cannot be closed in SCOM as the
monitor which generated this alert is still unhealthy.". So the sequence is
always (a) make the monitor Healthy first (root-cause fix OR override OR force
re-eval via `ResetMonitoringState($monitor)`), then (b) script 20 to mop up
anything that didn't auto-close.

**What the 9 lab alerts actually were, and how they cleared:**

| Alert / Source monitor | Count | Root cause | Fix applied |
|---|---|---|---|
| `Microsoft.WindowsDefender.ProtectedServer.AntimalwareScan.Monitor` | 8 | Defender installed on every server but never ran a periodic scan; monitor stays Unhealthy on its first eval | Script 22: `Set-MpPreference -ScanScheduleDay Everyday -ScanScheduleQuickScanTime 02:00`, plus one-shot `Start-MpScan -ScanType QuickScan` per VM. Then `ResetMonitoringState` on the 8 affected instances to force immediate re-eval. |
| `Microsoft.Windows.Server.2016.AD.Configuration.NetworkAdapters.DNS.Monitor` | 1 (on A-DC) | DC's only DNS server was `127.0.0.1` - the documented Microsoft anti-pattern for single-DC startup race condition | Script 22: `Set-DnsClientServerAddress -ServerAddresses '10.10.0.2','127.0.0.1'` on A-DC's primary NIC. Monitor flips Healthy and the alert auto-closes. |
| `Microsoft.SQLServer.ReportingServices.Windows.Monitor.Instance.WebServiceAccessible` | 1 (on A-SCCM\SSRS) | SSRS still had `http://+:80` URL reservations alongside the HTTPS-only `https://+:443` ones we'd added in `Configure-SCCMReporting.ps1`. The MP probed HTTP first; SSRS responded "rsSecureConnectionRequired" because `SecureConnectionLevel=1`; monitor went Unhealthy. | Removed both `http://+:80` reservations via `MSReportServer_ConfigurationSetting.RemoveURL(...)`, restarted SSRS, `ResetMonitoringState` on the SSRS instance. **This removal is now also encoded in `Configure-SCCMReporting.ps1` for clean rebuilds.** |

After all three fixes: `(Get-SCOMAlert | Where ResolutionState -ne 255).Count == 0`.

## Verifying Lab State (read-only — 2026-05-27)

`scripts\post-deploy\Verify-LabState.ps1` is a **read-only, side-effect-free** check that the
live lab still matches the state tables in this file. It is the executable form of the docs —
the validation half of the "repo must recreate AND validate the lab" convention. Host-run via
`Invoke-LabRemote` (Hyper-V direct), `Write-LabLog`, PS 5.1; ASCII-only so it survives
`Copy-Item -ToSession` staging. Stage-selectable (`Infra`, `Identity`, `Sql`, `Site`, `Roles`,
`Discovery`, `Updates`, or `All`); prints a per-check PASS/FAIL table + summary. Last full run:
**60/60 PASS**.

```powershell
. .\scripts\lib\Connect-LabHost.ps1
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Verify-LabState.ps1' -DomainAdminPassword 'LabAdmin@2026!' }
# one stage only:
Invoke-LabHost { & 'C:\HyperV-Lab\scripts\post-deploy\Verify-LabState.ps1' -Stage Updates -DomainAdminPassword 'LabAdmin@2026!' }
```

## Memory & Conventions

- This project uses Claude Code auto-memory at `C:\Users\Itamartz\.claude\projects\C--Users-Itamartz-Dropbox-System--FORWORK-LabSystemCenterInHome\memory\`. Read `MEMORY.md` for user/project preferences captured across sessions.
