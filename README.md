# OS/7

**A Microsoft-admin-friendly Linux: PowerShell-first management, Entra ID / Intune enrollment, Azure Arc for servers — built on Ubuntu 26.04 LTS.**

Maintained by [up in blue GmbH](https://github.com/upinblue).

## What is OS/7?

OS/7 is an Ubuntu 26.04 LTS ("Resolute Raccoon") based operating system for IT admins and organizations that already run a Microsoft-centric stack (Entra ID, Intune, Azure) and want a Linux option that speaks the same language: PowerShell-controlled, Entra-joinable, Intune- or Azure-Arc-manageable, with ZFS-backed, rollback-safe updates.

It is **not** aimed at desktop consumers. Two primary targets, chosen at install time:

- **GUI mode** — admin/developer workstations, GNOME desktop, Intune-enrolled.
- **Headless mode** — servers hosting Microsoft-adjacent workloads, no desktop packages, managed via Azure Arc-enabled Servers instead of Intune.

## Status

This repository is freshly scaffolded. Nothing here is a working build yet — treat everything below as documented intent, not implemented reality. Read this table before assuming any command in this repo actually works.

| Component | Status |
|---|---|
| Repo scaffold / README | done (this commit) |
| `build/config/auto/config` (live-build config) | **validated** — `lb config` passes and an arm64 ISO builds from it; still has no package lists, hooks or includes |
| `powershell/OS7/` module | stub — function signatures only, no logic |
| Installer (Calamares + ZFS) | not started |
| `.devcontainer` / VS Code dev environment | stub, untested |
| CI (`.github/workflows`) | stub — never run; now the only way to build amd64 (see [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) #12) |
| Bootable ISO | **arm64: builds and boots** to a live session (bare Ubuntu, no OS/7 content yet). amd64: blocked on Apple Silicon, needs a native runner |

## Locked decisions

Treated as fixed. Do not re-architect without discussion — see "Open questions" for what's still genuinely undecided.

- **Base:** Ubuntu 26.04 LTS, codename `resolute` ("Resolute Raccoon"), x86_64 + arm64.
- **GUI vs. headless:** one shared package base per architecture. The **installer** asks at setup time whether to install a GUI (GNOME) or stay headless — a setup-time choice, not just a runtime toggle.
  - GUI mode → GNOME, with dash-to-panel + arc-menu for a familiar feel (**not** a retro skin). Required for Microsoft Intune enrollment.
  - Headless mode → no desktop packages. Not eligible for Intune (Linux enrollment requires GNOME); managed via Azure Arc-enabled Servers instead.
- **Storage:** ZFS root everywhere, using the GA-kernel-matched prebuilt ZFS module (not `zfs-dkms`), so kernel and ZFS ship in lockstep.
  - **Known risk:** OpenZFS on the Linux 7.0 kernel (Ubuntu 26.04's default) has been logging an "EXPERIMENTAL / SERIOUS DATA LOSS may occur" warning — see upstream issue [openzfs/zfs#18488](https://github.com/openzfs/zfs/issues/18488). Validated 2026-08-22 — not a real defect, ZFS root confirmed safe to build on: [docs/SESSION-0-ZFS-VALIDATION.md](docs/SESSION-0-ZFS-VALIDATION.md).
- **Shell:** bash stays the actual system/login shell (cron, systemd, dpkg hooks, and Intune's bash-based custom compliance scripts all assume it's there and working). PowerShell 7 auto-launches as the visible, interactive shell for every human session — the lived experience is "PowerShell by default" without breaking anything that expects bash underneath.
  - PowerShell itself updates through the **same** OS7 release train as the rest of the system (`Update-OS7`, new ZFS boot environment), not a standalone `apt upgrade powershell` — keeps the whole system atomically rollback-safe.
- **Identity:**
  - `authd` + `authd-msentraid` for native Microsoft Entra ID login (in the Ubuntu archive as of 26.04, no PPA needed).
  - GUI installs: Microsoft Intune enrollment (requires GNOME + Microsoft Edge — both mandatory per Microsoft's current docs, not optional extras).
  - Headless installs: Azure Arc-enabled Servers as the management path. Verify current Ubuntu 26.04 support against Microsoft's live Arc prerequisites page before treating this as locked.
- **Updates:** curated release train over ZFS boot environments, driven by the OS7 PowerShell module: `Set-OS7Mode`, `Update-OS7`, `Restore-OS7`.
- **Target audience:** IT admins, MSPs, and organizations running a Microsoft-centric stack — not a consumer desktop distro.
- **Branding:** classic/retro visual identity (logo, boot splash, website) in up in blue Orange `#ff6912` — applies to marketing/branding only, **not** to the GNOME desktop itself.
- **Dev environment:** VS Code Dev Container wrapping the Docker-based build container; `.vscode/tasks.json` wires up `docker build`, `lb config`, `make build-amd64` / `make build-arm64`.
- **CI:** GitHub Actions — `amd64` on standard hosted runners, `arm64` on the free native arm64 hosted runners (public repo), so nothing builds under QEMU emulation.
- **Installer:** Calamares + its ZFS module — best available option for a customizable, brandable installer on a ZFS-root Ubuntu derivative. Not yet validated hands-on; this is the project's known hard part (live-build <-> installer <-> ZFS-root integration).

## Microsoft technology scope (v1 draft)

| Tier | Components | GUI-mode only? |
|---|---|---|
| Core (non-negotiable) | PowerShell 7, .NET SDK/Runtime, `authd` + `authd-msentraid` | No |
| Core for GUI installs | Microsoft Edge, Microsoft Intune app | Yes |
| Core for headless installs | Azure Connected Machine agent (Azure Arc) | Headless only |
| Recommended addition | Azure CLI | No |
| Recommended addition, GUI only | VS Code — default to **VSCodium** (MIT, no proprietary MS additions); official MS build optional/opt-in | Yes |
| Deliberately excluded from v1 | OneDrive sync (no official Linux client, only a community GPLv3 client), Microsoft Defender for Endpoint (own tenant licensing) | — |

## Open questions

Genuinely undecided — flag before making irreversible choices in a Claude Code session:

1. ~~**ZFS-on-kernel-7.0 risk**~~ — **RESOLVED 2026-08-22, proceed.** Validated hands-on on both architectures: the warning is present (kernel `7.0.0-28-generic`, ZFS `2.4.1-1ubuntu5`), but it marks build *provenance*, not a defect — confirmed by the OpenZFS and Ubuntu ZFS maintainers on the upstream issue. A real pool passed create / write / export / import / scrub / snapshot / rollback with zero errors. Upstream fixed this in ZFS 2.4.2; 26.04 has not received the SRU yet. Full evidence and caveats: [docs/SESSION-0-ZFS-VALIDATION.md](docs/SESSION-0-ZFS-VALIDATION.md).
2. **Azure Arc-enabled Servers + Ubuntu 26.04** — exact current support status should be checked against Microsoft's live prerequisites page before it's treated as a locked decision.
3. **Calamares ZFS module maturity** — how far it gets with a ZFS-root, dual-mode (GUI/headless) install is untested. This is the project's known hard part.
4. **License** — this README currently assumes MIT for OS7's own tooling/scripts (matching up in blue's other public repos); Ubuntu/upstream components keep their own licenses regardless. Confirm before the first public commit.

## Repository layout

```
os7/
├── build/config/auto/config   # live-build configuration (DISTRIBUTION=resolute)
├── powershell/OS7/            # OS7 PowerShell module (Set-OS7Mode, Update-OS7, Restore-OS7)
├── installer/                 # Calamares configuration (planned)
├── .devcontainer/             # VS Code Dev Container definition
├── .vscode/                   # tasks.json for the local build workflow
└── .github/workflows/         # CI: amd64 + arm64 ISO builds
```

## Getting started (once implemented)

1. Clone the repo, open it in VS Code, accept the "Reopen in Container" prompt.
2. Inside the container: `make build-amd64` or `make build-arm64`.
3. See `installer/README.md` for installer status.

---

Maintained by [up in blue GmbH](https://github.com/upinblue).
