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
| Installer (`os7-setup`) | not started — **designed and decided**: [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md) |
| Installing to a disk | **works on arm64** — the install sequence is proven end to end by spike S3, ahead of any Setup code: [docs/SESSION-S3-ZFS-LUKS.md](docs/SESSION-S3-ZFS-LUKS.md) |
| Secure Boot + TPM2 unlock | **works on arm64** — spike S4: boots against the Microsoft UEFI CA, TPM2 auto-unlock, TPM-less fallback intact: [docs/SESSION-S4-SECUREBOOT-TPM.md](docs/SESSION-S4-SECUREBOOT-TPM.md) |
| `.devcontainer` / VS Code dev environment | stub, untested |
| CI (`.github/workflows`) | stub — never run; now the only way to build amd64 (see [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) #12) |
| Bootable ISO | **arm64: builds and boots** to a live session (bare Ubuntu, no OS/7 content yet). amd64: blocked on Apple Silicon, needs a native runner |

## Locked decisions

Treated as fixed. Do not re-architect without discussion — see "Open questions" for what's still genuinely undecided.

- **Base:** Ubuntu 26.04 LTS, codename `resolute` ("Resolute Raccoon"), x86_64 + arm64 — but the two are **different products**, see below.
- **GUI vs. headless:** one shared package base per architecture. On **x86_64**, the **installer** asks at setup time whether to install a GUI (GNOME) or stay headless — a setup-time choice, not just a runtime toggle.
  - GUI mode → GNOME, with dash-to-panel + arc-menu for a familiar feel (**not** a retro skin). Required for Microsoft Intune enrollment. **x86_64 only.**
  - Headless mode → no desktop packages. Not eligible for Intune (Linux enrollment requires GNOME); managed via Azure Arc-enabled Servers instead.
- **arm64 is server-only** (decided 2026-08-22). No GUI target, so no GNOME, no Calamares and no Microsoft desktop stack in the arm64 image — Azure Arc is its only management path. This also matches upstream reality: Microsoft ships no arm64 Linux Edge, and `intune-portal` / `microsoft-identity-broker` are x86_64-only, so an arm64 GUI could never have been Intune-enrolled.
  - **Consequence, resolved 2026-08-22:** Calamares is a GUI installer and could not install arm64. It has been replaced by `os7-setup`, a text-mode installer that serves both architectures — see Installer below and [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md).
- **Intune compatibility is a hard requirement, not a feature** (decided 2026-08-22). On the x86_64 GUI product, a design that cannot pass Intune compliance is not shippable, and **Intune's constraints outrank OS/7's technical preferences** wherever the two collide. Verified against [Microsoft's Linux compliance settings reference](https://learn.microsoft.com/en-us/intune/device-security/compliance/ref-linux-settings) on 2026-08-22. What it currently dictates:
  - **Ubuntu Desktop 26.04 LTS is officially supported**, x86/64 only, physical or Hyper-V. The base choice is confirmed from Microsoft's side, and so is arm64-is-server-only.
  - **Disk encryption must go through `dm-crypt`.** Microsoft: *"Intune recognizes any encryption system that uses the underlying dm-crypt subsystem […] The preferred method […] is to use the LUKS format with the cryptsetup tool."* ZFS **native** encryption is therefore disqualified — it would report every managed device as unencrypted. See Storage below.
  - **`/boot` and `/boot/efi` are explicitly exempt** from the encryption check, which is what makes an unencrypted ESP and boot pool acceptable.
  - **`/etc/os-release` must stay Ubuntu-identifiable.** Intune's *Allowed distributions* rule matches on distribution type and version. Brand `NAME` / `PRETTY_NAME` / `HOME_URL`; keep `ID=ubuntu`, `ID_LIKE=ubuntu`, `VERSION_ID="26.04"`. Rebranding `ID` would make every device fail the rule.
  - **GNOME and Microsoft Edge stay mandatory** for GUI installs — Microsoft requires both for enrollment; they are not optional extras.
  - **Rule for future changes:** anything touching disk layout, encryption, OS identity, desktop or browser is checked against Intune's live docs *first*. Do not discover a compliance failure at a customer.
- **Storage:** ZFS root everywhere, using the GA-kernel-matched prebuilt ZFS module (not `zfs-dkms`), so kernel and ZFS ship in lockstep. **ZFS is the only filesystem OS/7 installs** — the sole non-ZFS filesystem on disk is the FAT32 EFI System Partition, which UEFI firmware mandates.
  - **Encryption: LUKS2 *underneath* ZFS** (decided 2026-08-22), forced by the Intune requirement above. LUKS is a block layer, not a filesystem: the stack is `partition -> LUKS2 -> zpool -> datasets`, and ZFS keeps snapshots, rollback, compression, checksums and boot environments unchanged. Trade-off accepted: no per-dataset encryption and no raw encrypted `zfs send`. Do **not** also enable ZFS native encryption — that is double encryption for no gain.
  - **Boot layout:** shim + Canonical-signed GRUB, so Secure Boot works out of the box. GRUB reads ZFS read-only, which requires the standard unencrypted `bpool` for `/boot` alongside the encrypted `rpool`. Both are ZFS. Full reasoning and the ZFSBootMenu alternative: [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md).
  - **Swap is never on ZFS** — swap-on-zvol still deadlocks upstream. Default is zram (RAM only, nothing on disk); a plain swap partition is opt-in for hibernation.
  - **Known risk:** OpenZFS on the Linux 7.0 kernel (Ubuntu 26.04's default) has been logging an "EXPERIMENTAL / SERIOUS DATA LOSS may occur" warning — see upstream issue [openzfs/zfs#18488](https://github.com/openzfs/zfs/issues/18488). Validated 2026-08-22 — not a real defect, ZFS root confirmed safe to build on: [docs/SESSION-0-ZFS-VALIDATION.md](docs/SESSION-0-ZFS-VALIDATION.md).
- **Shell:** bash stays the actual system/login shell (cron, systemd, dpkg hooks, and Intune's bash-based custom compliance scripts all assume it's there and working). PowerShell 7 auto-launches as the visible, interactive shell for every human session — the lived experience is "PowerShell by default" without breaking anything that expects bash underneath.
  - PowerShell itself updates through the **same** OS7 release train as the rest of the system (`Update-OS7`, new ZFS boot environment), not a standalone `apt upgrade powershell` — keeps the whole system atomically rollback-safe.
- **Identity:**
  - `authd` + `authd-msentraid` for native Microsoft Entra ID login. **Correction (verified 2026-08-22):** `authd` is in the Ubuntu archive, but `authd-msentraid` is **not** — it is a Canonical-verified **snap** (0.4.1, both architectures). No PPA is needed either way, but the delivery mechanism differs; see [installer/README.md](installer/README.md).
  - GUI installs: Microsoft Intune enrollment (requires GNOME + Microsoft Edge — both mandatory per Microsoft's current docs, not optional extras). Compliance is a hard requirement — see "Intune compatibility" above.
  - Headless installs: Azure Arc-enabled Servers as the management path. Verify current Ubuntu 26.04 support against Microsoft's live Arc prerequisites page before treating this as locked.
- **Updates:** curated release train over ZFS boot environments, driven by the OS7 PowerShell module: `Set-OS7Mode`, `Update-OS7`, `Restore-OS7`.
- **Target audience:** IT admins, MSPs, and organizations running a Microsoft-centric stack — not a consumer desktop distro.
- **Branding:** classic/retro visual identity (logo, boot splash, website) in up in blue Orange `#ff6912` — applies to marketing/branding only, **not** to the GNOME desktop itself.
- **Console font: [Fixedsys Excelsior](https://github.com/kika/fixedsys)** (decided 2026-08-22) — the default font for `os7-setup` **and** for the installed system in **non-GUI mode**. Public domain / CC0, so it ships inside the ISO with no obligation. It is a deliberate simulation of the 8×16 bitmap font DOS and Windows used, drawn to be rendered without antialiasing at 16 px, which is what makes the text-mode look reproduce rather than approximate.
  - The console cannot read TTF, so the image build converts it to **PSF** (`otf2bdf` → `bdf2psf`) and ships two sizes: 8×16 and a pixel-doubled 16×32 for modern panels. Toolchain lives in the build container, not in the image.
  - **Pinned**, fetched at build time rather than vendored, the same shape as PowerShell in hook 0020: `v3.09.10` / `FSEX302.ttf` / 580 724 bytes / SHA256 `842f8fbf80f57d867aeb1d2988140d3ea8b4718e5f687035b0a3b66756df3899`.
  - **Verified 2026-08-22:** its cmap carries Box Drawing `U+2500–257F` complete (128/128) and Block Elements `U+2580–259F` complete (32/32). That was the real risk — upstream advertises only the windows-125x codepages, which contain no box-drawing characters, and the entire installer UI is built from them.
  - PSF caps at 512 glyphs against the font's 6 193 codepoints, so the shipped subset is Latin-focused (English + German). Does **not** apply to the GNOME desktop.
- **Dev environment:** VS Code Dev Container wrapping the Docker-based build container; `.vscode/tasks.json` wires up `docker build`, `lb config`, `make build-amd64` / `make build-arm64`. Note that the *native* architecture is the fast one on any given machine — see "Building" below; on Apple Silicon the amd64 ISO is built in a QEMU x86 VM instead of under Docker emulation.
- **CI:** GitHub Actions — `amd64` on standard hosted runners, `arm64` on the free native arm64 hosted runners (public repo), so nothing builds under QEMU emulation.
- **Installer: `os7-setup`** (decided 2026-08-22, replacing Calamares) — an OS/7-authored, keyboard-driven **text-mode** installer written in C#/.NET and published as a NativeAOT binary, styled after MS-DOS 6.22 Setup and the Windows 2000 text-mode Setup phase. Field colour `#0057ad` (up in blue `#1289ff` darkened to WCAG AAA against white text), with `#1289ff` as the title stripe and progress fill on every screen.
  - **One installer serves both architectures**, which is why Calamares went: it is a Qt GUI application and could never have installed the desktop-less arm64 image. Subiquity is no longer needed either.
  - Nothing is implemented yet. Design, limitations, decisions and the phased plan — including the spikes that must pass before any installer code is written: [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md).
  - **Spikes S3 and S4 passed 2026-08-23:** the install sequence Setup's storage step will drive is written and proven end to end on arm64, and the installed system boots under Secure Boot with TPM2 auto-unlock — [installer/spikes/](installer/spikes/), [docs/SESSION-S3-ZFS-LUKS.md](docs/SESSION-S3-ZFS-LUKS.md), [docs/SESSION-S4-SECUREBOOT-TPM.md](docs/SESSION-S4-SECUREBOOT-TPM.md).

## Microsoft technology scope (v1 draft)

| Tier | Components | GUI-mode only? |
|---|---|---|
| Core (non-negotiable) | PowerShell 7 (installed from the pinned upstream tarball — Microsoft ships no arm64 `.deb`), .NET SDK/Runtime (`dotnet-sdk-10.0`, from the **Ubuntu** archive — resolute has .NET 10, not 9), `authd` + `authd-msentraid` | No |
| Core for GUI installs | Microsoft Edge, Microsoft Intune app (+ `microsoft-identity-broker`, which brokers the Entra sign-in enrollment needs) — **x86_64 only, no arm64 builds exist** | Yes |
| Core for headless installs | Azure Connected Machine agent (Azure Arc) — available for x86_64 **and** arm64 | Headless only |
| Recommended addition | Azure CLI | No |
| Recommended addition, GUI only | VS Code — default to **VSCodium** (MIT, no proprietary MS additions); official MS build optional/opt-in | Yes |
| Deliberately excluded from v1 | OneDrive sync (no official Linux client, only a community GPLv3 client), Microsoft Defender for Endpoint (own tenant licensing) | — |

## Open questions

Genuinely undecided — flag before making irreversible choices in a Claude Code session:

1. ~~**ZFS-on-kernel-7.0 risk**~~ — **RESOLVED 2026-08-22, proceed.** Validated hands-on on both architectures: the warning is present (kernel `7.0.0-28-generic`, ZFS `2.4.1-1ubuntu5`), but it marks build *provenance*, not a defect — confirmed by the OpenZFS and Ubuntu ZFS maintainers on the upstream issue. A real pool passed create / write / export / import / scrub / snapshot / rollback with zero errors. Upstream fixed this in ZFS 2.4.2; 26.04 has not received the SRU yet. Full evidence and caveats: [docs/SESSION-0-ZFS-VALIDATION.md](docs/SESSION-0-ZFS-VALIDATION.md).
2. **Azure Arc-enabled Servers + Ubuntu 26.04** — exact current support status should be checked against Microsoft's live prerequisites page before it's treated as a locked decision.
3. ~~**Calamares ZFS module maturity**~~ — **MOOT 2026-08-22.** Calamares was replaced by `os7-setup` ([installer/SETUP-PLAN.md](installer/SETUP-PLAN.md)). The underlying hard part moved to spike S3 — a ZFS-on-LUKS root that actually boots — which was the project's highest-risk unknown. ~~**S3**~~ — **RESOLVED 2026-08-23 on arm64.** OS/7 now installs to a disk and boots from it: LUKS2 passphrase prompt, then a login prompt served from `rpool/ROOT/os7_*`, with the designed dataset layout intact. Sequence, harness and findings: [docs/SESSION-S3-ZFS-LUKS.md](docs/SESSION-S3-ZFS-LUKS.md). **amd64 remains uninstalled and unvalidated**, because no amd64 ISO has been built yet.
   - **Newly open, from the Intune work:** does Intune's encryption check treat the unencrypted `bpool` partition as a non-compliant fixed writable disk? Microsoft exempts `/boot`, but `bpool` is a ZFS pool member rather than a directly mounted partition, so the exemption may not be recognised. Verify in the first real enrollment test, before it becomes a customer's discovery.
   - **Newly open, from the Intune work:** `/etc/os-release` branding vs. the *Allowed distributions* rule (see "Intune compatibility").
4. **License** — this README currently assumes MIT for OS7's own tooling/scripts (matching up in blue's other public repos); Ubuntu/upstream components keep their own licenses regardless. Confirm before the first public commit.

## Repository layout

```
os7/
├── build/config/auto/config   # live-build configuration (DISTRIBUTION=resolute)
├── powershell/OS7/            # OS7 PowerShell module (Set-OS7Mode, Update-OS7, Restore-OS7)
├── installer/                 # os7-setup design (SETUP-PLAN.md) + Phase 0 spikes
├── docs/                      # handoff, build notes, session results
├── .devcontainer/             # VS Code Dev Container definition
├── .vscode/                   # tasks.json for the local build workflow
└── .github/workflows/         # CI: amd64 + arm64 ISO builds
```

## Building

**Which command depends on your host architecture.** This is not a preference —
Docker's amd64 emulation on Apple Silicon cannot unpack a Debian rootfs
(`tar: Cannot mkdir: Function not implemented`), so the x86 build has to happen
somewhere that runs real x86 code. See
[docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) #12.

| Your machine | arm64 ISO | amd64 ISO |
|---|---|---|
| **x64 Windows / Intel Mac / x86_64 Linux** | `make build-arm64` — emulated; **untested on an x86 host** (different emulation path than the broken one, so it may well work) | **`make build-amd64`** — native, fast |
| **Apple Silicon Mac** | **`make build-arm64`** — native, fast | `make build-amd64-vm` — full QEMU x86 VM, takes hours |

In short: **each architecture is fast on its own kind of hardware.** Build the
one that matches your machine for day-to-day work; reach for the slow path only
when you need the other architecture's ISO.

`make build-amd64` refuses early on a non-x86_64 host and tells you to use
`build-amd64-vm`, so you cannot lose 20 minutes reaching a known failure.
`make build-amd64-vm-reset` throws the builder VM away.

Prerequisites: Docker Desktop (or Docker Engine) running. On Apple Silicon, the
VM path additionally needs QEMU (`brew install qemu`).

Output lands in `out/`. See [docs/HANDOFF.md](docs/HANDOFF.md) for what works
today and what to do next, and `installer/SETUP-PLAN.md` for the installer.

---

Maintained by [up in blue GmbH](https://github.com/upinblue).
