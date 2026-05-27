# LabSystemCenterInHome

A Microsoft **System Center (SCCM/Configuration Manager + SCOM)** lab built on **physical
mini-PC Hyper-V hosts**, provisioned and configured end-to-end by **PowerShell over WinRM**
from a workstation. Guest VMs run **directly on Hyper-V** (no nesting), isolated on a NAT
vSwitch with outbound internet for Windows Update / installers.

> **Domain:** `sadab.pri` (NetBIOS `SADAB`) · **Site code:** `PR1`

Everything that *can* be configured declaratively is **DSC-backed** (the `ConfigMgrCBDsc`
module, `Test` → `Set`, idempotent). The few operations with no DSC resource are
implemented as idempotent cmdlet scripts and are explicitly documented as exceptions.

---

## Status at a glance

**Phase 1 (single host, Site A) is built and operational.** A second physical host for
Site B / SQL Always-On / SCOM has not been acquired yet, so those pieces are deferred.

| Area | State |
|---|---|
| Site A VMs (5) | ✅ created, WS2025 Datacenter, domain-joined to `sadab.pri` |
| SQL Server 2019 + CU32 | ✅ on `A-SQLSCCM` |
| SCCM Primary site `PR1` | ✅ on `A-SCCM` (build 5.00.9141, hotfix rollup applied → 5.00.9141.1030) |
| Management Point + Distribution Point | ✅ on `A-MPDP` |
| Discovery / Boundaries / Collections | ✅ DSC-backed |
| Client push + Applications + Client settings | ✅ (7-Zip, Notepad++) |
| Role-Based Access Control (group-based) | ✅ |
| Reporting Services Point (SSRS over **HTTPS**, CA cert) | ✅ on `A-SCCM` |
| Domain PKI — Enterprise Root CA `SADAB-Root-CA` | ✅ on `A-DC` |
| Software Update Point (WSUS over **SSL/8531**) + ADR | ✅ on `A-MPDP` |
| Service Connection Point (Online) | ✅ on `A-SCCM` |
| In-console site update **KB36949461** (2509 Hotfix Rollup) | ✅ installed |
| Client **PKI / HTTPS** communication (agent uses a client cert) | ✅ verified on a client |
| Site B · SQL Always-On · SCOM | ⏸️ deferred (needs a second host) |

---

## Architecture

The lab runs on physical mini-PC hosts with a deliberately simple, isolated topology:

- **No nested virtualization** — VMs run directly on the physical Hyper-V host.
- **NAT vSwitch named `Lab`** on each host — Site A VMs sit on `10.10.0.0/24`, Site B on
  `10.20.0.0/24`, each host doing NAT so the VMs get outbound internet while staying
  isolated. A host route simulates inter-site connectivity.
- **Remote management via WinRM over the LAN** — no provisioning agent on the host beyond
  WinRM; everything is driven from a workstation with PowerShell (Hyper-V PowerShell Direct
  into the guests, network WinRM to the host).
- **PowerShell 5.1 only** in anything that runs on the hosts/VMs (Windows Server 2025
  default), so the scripts stay portable across the hosts.
- Stable **domain and paths** (`sadab.pri`, `C:\HyperV-Lab\`) keep the per-VM and post-deploy
  scripts reusable across rebuilds.

---

## Hardware

| | Host A (deployed) | Host B (planned) |
|---|---|---|
| Model / hostname | GMKtec **NucBox K12** / `NUCBOX_K12` | TBD |
| CPU | 16 logical | ~16 logical |
| RAM | 2× 16 GB DDR5-5600 SODIMM = **32 GB** (28.8 GB usable; rest reserved for the AMD iGPU) — 2/2 SODIMM slots used, firmware max 64 GB | ~32 GB+ |
| Disk | ~930 GB | TBD |
| OS | Windows 11 Pro 26200, Hyper-V enabled | Win 11 Pro / Server 2025 |

---

## VM inventory

**Phase 1** = built now; **Deferred** = scripts exist but not deployed (needs a second host
or a RAM upgrade).

| VM | IP | Site | Role | RAM | Phase |
|---|---|---|---|---|---|
| `A-DC` | 10.10.0.2 | A | Domain Controller (`sadab.pri`) + Enterprise Root CA | 4 GB | **1** |
| `A-SCCM` | 10.10.0.3 | A | SCCM Primary (site `PR1`), SSRS/RSP, SCP | 12 GB (boots at 6) | **1** |
| `A-SQLSCCM` | 10.10.0.4 | A | SQL 2019 (SCCM DB + SSRS catalog) | 8 GB | **1** |
| `A-MPDP` | 10.10.0.5 | A | Management Point + Distribution Point + Software Update Point (WSUS) | 6 GB | **1** |
| `A-DFSR` | 10.10.0.7 | A | DFSR member / general managed client | 4 GB | **1** |
| `A-SCOM` / `A-SQLSCOM` | 10.10.0.40 / .41 | A | SCOM management + SQL | 8 GB ea. | Deferred |
| `B-*` (SCCM/SQL/MPDP/DFSR) | 10.20.0.x | B | Site B (passive SCCM, AG secondary, etc.) | — | Deferred |

**RAM strategy** (single-host constraint): VMs use Hyper-V **Dynamic Memory** (min 512 MB),
are **booted sequentially** smallest→largest with a wait between each so idle VMs balloon
down, and `A-SCCM` boots at 6 GB but may grow to 12 GB under load.

---

## Software stack

| Component | Version / source |
|---|---|
| Guest OS (parent VHDX) | Windows Server 2025 Eval → auto-converted to **Datacenter** on first boot (DISM `/Set-Edition` + KMS client key) |
| SQL Server | **2019 Developer + CU32**, collation `SQL_Latin1_General_CP1_CI_AS` |
| SCCM | Current Branch, site `PR1`, build 5.00.9141 (+ 2509 Hotfix Rollup KB36949461 → .1030) |
| WSUS | Windows Internal Database (WID) on `A-MPDP`, HTTPS on **8531** |
| SSRS | 2022, on `A-SCCM`, catalog DB on `A-SQLSCCM`, HTTPS with CA cert |
| PKI | Enterprise Root CA `SADAB-Root-CA` on `A-DC` |
| DSC | `ConfigMgrCBDsc` (+ `SqlServerDsc`, `CertificateDsc`, `ActiveDirectoryDsc`, `ActiveDirectoryCSDsc`) |

---

## What's been built (the SCCM configuration)

All of the following is **DSC-backed** unless noted as an exception. Each item has a
dedicated, idempotent script under `scripts/post-deploy/`.

### Core site
- **Primary site `PR1`** on `A-SCCM` with the SQL DB on `A-SQLSCCM`.
- **Management Point + Distribution Point** on `A-MPDP` (`Configure-SCCMRoles.ps1`).
- **Discovery** — AD System / User / Group / Forest / Heartbeat, scoped to the SADAB OUs;
  **no Network Discovery** (`Configure-SCCMDiscovery.ps1`).
- **Boundaries & Boundary Groups** — IP-range boundaries for Site A (10.10.0.0/24) and
  Site B (10.20.0.0/24) → `BG-Site-A` / `BG-Site-B` (`Configure-SCCMBoundaries.ps1`).
- **Client push** to all discovered servers + **`All Servers`** device collection
  (`Configure-SCCMClientPush.ps1`, `Configure-SCCMCollections.ps1`).
- **Applications** — 7-Zip + Notepad++ deployed Required to `All Servers`
  (`Deploy-SCCMApplications.ps1`).
- **Client settings** — a `Servers` device policy (hardware inventory hourly, policy poll
  5 min) (`Configure-SCCMClientSettings.ps1`).
- **RBAC** — roles assigned to AD groups (`<System>_Role_<Role>`), never to individual
  users (`Configure-SCCMRBAC.ps1`, `Configure-SCCMSiteServerRights.ps1`).

### Reporting + PKI
- **Domain Enterprise Root CA** `SADAB-Root-CA` on `A-DC`.
- **Reporting Services Point** on the Primary, SSRS served over **HTTPS** with a CA-issued
  Server-Auth cert (`Configure-SCCMReporting.ps1`).

### Software Updates
- **Software Update Point** on `A-MPDP` over **HTTPS port 8531** (WSUS on WID), syncing from
  **Microsoft Update**, **Security + Critical classifications only**, products *Windows
  Server 2025 (24H2) + Windows 11 + Microsoft Defender Antivirus*
  (`Configure-SCCMSoftwareUpdatePoint.ps1`).
- **Automatic Deployment Rule** → last-month Security/Critical updates deployed **Required**
  to `All Servers` (`Deploy-SCCMUpdatesADR.ps1`); a last-month update was verified installed
  on a client.
- **Specific-update deployment** — KB5087539 (Server 2025 24H2 cumulative) assigned Required
  to `All Servers` (`Deploy-SCCMUpdateToCollection.ps1`).

### Servicing + cloud + client security
- **Service Connection Point** (Online) on `A-SCCM` (`Configure-SCCMServiceConnectionPoint.ps1`).
- **In-console site update** — CM 2509 Hotfix Rollup **KB36949461** installed
  (5.00.9141.1000 → .1030) (`Install-SCCMSiteUpdate.ps1`).
- **Client PKI / HTTPS communication** — the SCCM **agent connects to the MP over HTTPS
  using a PKI client-authentication certificate**: Workstation-Auth certs autoenrolled to
  domain computers from `SADAB-Root-CA`, MP set to HTTPS, site set to *HTTPS or HTTP* with
  *Use PKI client certificate* (`Configure-SCCMClientPKI.ps1`).

---

## The DSC-backed convention (and its exceptions)

> **All SCCM configuration is DSC-backed via `ConfigMgrCBDsc`.** Because `Invoke-DscResource`
> fails on a site server, scripts import each `DSC_<resource>.psm1` and call
> `Test-TargetResource` / `Set-TargetResource` **in-process** under `SADAB\Administrator`,
> with the `PR1:` drive pre-created. Re-runs are no-ops when compliant and self-heal drift.

**Documented exceptions** (no DSC resource exists; implemented as idempotent cmdlet scripts):
applications, the ADR, software-update groups / specific-update deployments, the in-console
**site update install**, the CA certificate-template ACL + autoenrollment GPO, and IIS HTTPS
cert bindings.

---

## Repository layout

```
LabSystemCenterInHome/
├── README.md                      # this file
├── CLAUDE.md                      # full living design + build log + every gotcha (source of truth)
├── DEPLOY.md                      # sequential rebuild-from-scratch procedure
├── lab-config.json                # host IPs, paths, SCCM site, lab-only default creds
├── .secrets/                      # DPAPI-encrypted host cred (GITIGNORED — never published)
├── scripts/
│   ├── lib/Connect-LabHost.ps1    # Invoke-LabHost / Invoke-LabVM WinRM helpers
│   ├── post-deploy/               # orchestrated post-VM config (01–14 + Configure-* / Deploy-* / Install-*)
│   │   ├── LabHelpers.psm1         #   Write-LabLog, Invoke-LabRemote, Wait-LabVMReady
│   │   └── Invoke-LabDeploy.ps1    #   step orchestrator
│   ├── vms/                       # per-VM create (New-*) + in-guest post-config (Post-*) + LabVMHelpers.ps1
│   ├── sccm-roles/                # manual MP/DP/SUP role helpers
│   ├── setup/                     # host preparation
│   ├── Download-LabFiles.ps1      # fetch WS2025 VHDX + media
│   └── manual-fixes.md            # chronological "why" trail of every fix (folded into the scripts)
└── Files/                         # silent-install wrappers only (binaries are gitignored)
```

---

## Connecting & deploying

Everything is driven from a workstation over **WinRM** (no agent on the host beyond WinRM).

```powershell
# Load the helpers (creds come from .\.secrets\hyperv-host.cred.xml, DPAPI-encrypted)
. .\scripts\lib\Connect-LabHost.ps1

# Run something on the Hyper-V host
Invoke-LabHost { Get-VM | Select-Object Name, State }

# Run something inside a guest VM (Hyper-V PowerShell Direct, from the host)
Invoke-LabHost {
  $cred = New-Object PSCredential('SADAB\Administrator', (ConvertTo-SecureString '<lab-pwd>' -AsPlainText -Force))
  Invoke-Command -VMName 'A-SCCM' -Credential $cred -ScriptBlock { hostname }
}
```

- **Rebuild from scratch:** follow [`DEPLOY.md`](DEPLOY.md) (sequential, idempotent).
- **Post-deploy config scripts** run from the host and use `Invoke-LabRemote` (prefers
  Hyper-V Direct, falls back to network WinRM). Most are staged to
  `C:\HyperV-Lab\scripts\post-deploy\` on the host and invoked there.
- **Documentation map:** `CLAUDE.md` (design + complete build log + gotchas) is the source of
  truth; `DEPLOY.md` is the step-by-step procedure; `scripts/manual-fixes.md` is the detailed
  per-fix rationale.

---

## Credentials & secrets

- This is a **lab** — the default credentials in `lab-config.json` are throwaway and the
  environment is isolated.
- The only real credential (the Hyper-V host login) lives **DPAPI-encrypted** in
  `.secrets\hyperv-host.cred.xml`, which is **git-ignored** and per-user/per-machine
  (cannot be decrypted on any other machine).
- `.gitignore` also excludes keys/certs/tokens, `.env`, large media binaries, logs, and
  temp/backup artifacts.

---

## Roadmap

- **Phase 2 (needs a second host / 64 GB RAM):** Site B VMs, SQL Server Always-On
  Availability Group, passive SCCM site server, DFSR replication across sites, and SCOM
  (management server + SQL + SCCM management-pack import).
- A RAM upgrade to **64 GB** (2× 32 GB DDR5-5600 SODIMM) on Host A would allow the full
  Phase-2 footprint without aggressive ballooning.

---

*Built and operated as a learning lab. Not production guidance — several choices (e.g. the CA
on a domain controller) are deliberate single-host compromises noted in `CLAUDE.md`.*
