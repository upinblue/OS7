<div align="center">

# OS/7

**A Linux that speaks Microsoft.**
PowerShell as the shell you actually type in, Entra ID for sign-in, Intune and Azure Arc for management,
ZFS boot environments so an update can be undone — on top of Ubuntu 26.04 LTS.

[![Base](https://img.shields.io/badge/base-Ubuntu%2026.04%20LTS-E95420?logo=ubuntu&logoColor=white)](https://documentation.ubuntu.com/release-notes/26.04/)
[![Shell](https://img.shields.io/badge/shell-PowerShell%207.6-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Root](https://img.shields.io/badge/root-ZFS%20on%20LUKS2-0057ad)](installer/SETUP-PLAN.md)
[![Arch](https://img.shields.io/badge/arch-x86--64%20%7C%20arm64-555555)](#system-requirements)
[![Status](https://img.shields.io/badge/status-in%20development-ff6912)](#status)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Made by [up in blue GmbH](https://github.com/upinblue)

</div>

> [!WARNING]
> **OS/7 is in active development and has not been released.** It installs and boots
> on arm64 today; the x86-64 half — which is the half with the desktop, Edge and Intune —
> has never been installed on any machine. Please don't put this on hardware you care
> about. [What actually works](#status) is kept honest below.

---

## What it is

Plenty of shops run Microsoft end to end — Entra ID for identity, Intune for devices,
Azure Arc for servers, PowerShell for everything else — and then hit a workload that
wants Linux. That usually means a second set of tools, a second way to prove
compliance, and a second thing to explain to an auditor.

OS/7 is Ubuntu, unmodified where it counts, arranged so that it fits the tooling those
teams already have:

- 🐚 **PowerShell 7 is the interactive shell.** Log in and you land at a `PS /home/you>` prompt.
  bash is still the *system* shell underneath, so cron, systemd, dpkg hooks and Intune's
  bash-based compliance scripts all keep working.
- 🔐 **Entra ID sign-in** through `authd` + `authd-msentraid`, with a local
  break-glass account for when the tenant is unreachable.
- 🛡️ **Intune** on the x86-64 desktop product, **Azure Arc** on servers. Microsoft's own
  compliance rules were the design input, not an afterthought — encryption is LUKS2
  because Intune only recognises `dm-crypt`, and `/etc/os-release` stays
  Ubuntu-identifiable so the *Allowed distributions* rule still matches.
- 🧊 **ZFS root on LUKS2, with boot environments.** Every update happens in a clone.
  If it goes wrong, you boot yesterday's system from the GRUB menu.
- 📀 **A text-mode installer of our own**, `os7-setup` — styled after MS-DOS 6.22 Setup
  and the Windows 2000 text phase, because a 4.4 MB keyboard-driven binary with no .NET
  runtime behind it serves a headless arm64 server and a desktop workstation equally well.
- 🪟 **OS/7 Classic** on the desktop: GNOME wearing a Windows 2000 surface, built from
  GNOME's own Classic extensions rather than third-party shell hacks.

It is aimed at IT admins, MSPs and Microsoft-centric organisations — not at consumers
looking for a daily driver.

## Status

Every "yes" below was measured on a real (virtual) machine, and the evidence is linked
from [docs/HANDOFF.md](docs/HANDOFF.md). Every "no" is a thing nobody has tried yet.

|  | **arm64** — server only | **x86-64** — desktop or server |
|---|---|---|
| ISO builds | ✅ locally *and* in CI | ⚙️ in CI only — Docker's x86 emulation on Apple Silicon cannot unpack a Debian rootfs |
| Medium boots | ✅ | ✅ firmware → GRUB → OS/7's menu |
| Setup runs | ✅ the whole flow, by keypress, to the Complete screen | ⚠️ starts, then loses tty1 to GNOME. The one-line fix is measured by hand; no ISO has been built with it yet |
| Installs to a disk | ✅ ESP + LUKS2 + `bpool`/`rpool` + datasets + account + bootloader | ❌ never attempted — there is no x86_64 test harness here |
| Installed disk boots alone | ✅ verified with **no setup medium attached** | ❌ |
| Network, wired and Wi-Fi | ✅ static and DHCP, WPA2-PSK associates | ❌ |
| Secure Boot + TPM2 auto-unlock | ✅ on the installed disk | ❌ |
| GNOME · Edge · Intune portal | — (arm64 is server-only by design) | 📦 in the image, never launched |
| `Update-OS7` / `Restore-OS7` | 🚧 designed in full, not implemented | 🚧 |

**The two architectures are different products.** Microsoft ships no arm64 build of Edge,
`intune-portal` or `microsoft-identity-broker`, so arm64 is server-only and managed by
Azure Arc. That is a decision, not a gap. See [docs/DECISIONS.md](docs/DECISIONS.md).

**Two honest caveats about the setup medium.** Its GRUB is unsigned on both
architectures, so you must turn **Secure Boot off to install** and can turn it back on
afterwards — the *installed* system boots with shim and a Canonical-signed GRUB. And
the Entra broker is a Canonical snap that cannot yet be seeded into a live-build image,
so **no OS/7 build can sign in with Entra ID today**. Both are tracked as open questions.

## System requirements

OS/7 inherits Ubuntu 26.04's requirements and then adds its own: a UEFI-only boot path,
a ZFS root that likes memory, and a LUKS2 header whose Argon2id unlock is pinned at
512 MiB so that install time and boot time agree.

|  | **Minimum** | **Recommended** |
|---|---|---|
| **x86-64 (amd64)**<br><sub>desktop or server</sub> | 64-bit x86 CPU, 2 GHz dual-core<br>**6 GB** RAM<br>**32 GB** disk<br>UEFI firmware | 4 cores at 2 GHz or better<br>**16 GB** RAM<br>**128 GB** SSD / NVMe<br>UEFI + TPM 2.0 + Secure Boot |
| **arm64 (AArch64)**<br><sub>server only</sub> | ARMv8-A, 2 cores<br>**4 GB** RAM<br>**24 GB** disk<br>UEFI firmware | 4 cores<br>**8 GB** RAM<br>**64 GB** SSD / NVMe<br>UEFI + TPM 2.0 + Secure Boot |

**Required on both, regardless of size:**

| | |
|---|---|
| **UEFI** | Mandatory. OS/7 boots via shim + Canonical-signed GRUB and ships no BIOS/CSM path at all. |
| **Secure Boot** | Supported on the installed system; **switch it off to install**, because the setup medium's GRUB is unsigned. |
| **TPM 2.0** | Optional but wanted. Without it, OS/7 asks for the LUKS2 passphrase on every boot instead of unlocking itself. |
| **Setup medium** | A USB stick of **4 GB** or more (arm64 ISO ≈ 2.2 GB, x86-64 ≈ 3.3 GB); 8 GB is comfortable. |
| **Disk** | One whole disk. The installer refuses anything under **16 GB** outright — that is the floor at which the layout can be laid down at all, not a recommendation. |
| **Intune enrolment** | Microsoft supports **Ubuntu Desktop 26.04 LTS on x86-64 only**, physical or Hyper-V. GNOME and Microsoft Edge are mandatory for enrolment, not optional extras. |

<details>
<summary><b>Where these numbers come from</b></summary>

<br>

Nothing here is a round number picked for looking sensible.

- **6 GB RAM on x86-64** is [Ubuntu Desktop 26.04's own figure](https://ubuntu.com/download/desktop)
  (2 GHz dual-core, 6 GB, 25 GB), and x86-64 is the product that carries GNOME, Edge and
  the Intune portal — 1528 packages against arm64's 549.
- **4 GB RAM on arm64.** [Ubuntu Server's floor](https://ubuntu.com/server/docs/reference/installation/system-requirements/)
  is 1.5 GB for an ISO install, with 3 GB suggested. OS/7 adds two appetites on top: ZFS
  caches in ARC, which by default may grow to half of RAM and which OS/7 does not cap,
  and unlocking the LUKS2 header costs 512 MiB inside the initramfs on every boot
  (`--pbkdf argon2id --pbkdf-memory 524288`, pinned so the initramfs can reproduce what
  the live installer did). 4 GB is also the only figure that has actually installed and
  booted OS/7 here — every VM in `installer/testing/` runs `-m 4096` with 4 vCPUs.
  **Less than 4 GB is untested, not known-bad.**
- **The disk floor of 16 GB** is enforced in code, and the comment beside it says why:
  ESP + `bpool` + somewhere to install into. 512 MB comes off the top for the EFI System
  Partition and 2 GB for the boot pool before a single package is unpacked, and boot
  environments need room to clone. The test harnesses install into a 24 GB target;
  32 GB is the smallest disk on which the x86-64 desktop product is not immediately
  cramped.
- **TPM 2.0 and Secure Boot** were measured together by spikes S4 and S6: the installed
  disk boots with Secure Boot on against the Microsoft UEFI CA, auto-unlock works,
  a TPM-less machine still prompts, and a Secure Boot policy change breaks auto-unlock
  *detectably and recoverably*.
- **ISO sizes** are the built artefacts: `OS7-1.0.0.46-arm64.iso` is 2148 MB and
  `OS7-1.0.0.48-amd64.iso` is 3254 MB.

</details>

## Building an ISO

Everything is built in a privileged Docker container, so the only prerequisite is a
working Docker and GNU make. **Always build through the Makefile** — it asks git on the
host for the three facts the version number is made of, which a container inside a git
worktree cannot answer for itself.

### On an Apple Silicon Mac → arm64

```bash
make build-arm64
```

Roughly five minutes. The ISO lands in `out/OS7-<version>-arm64.iso`. You need Docker
Desktop running; nothing else. Then ask the image what it actually is, in seconds and
without booting it:

```bash
./installer/testing/check-image.py
```

### On a Windows 11 x64 PC → x86-64

The build is a Linux toolchain — `debootstrap`, `chroot`, loop devices, live-build — so
it runs inside WSL 2, natively and at full speed on x64 hardware. One-time setup:

```powershell
wsl --install -d Ubuntu
```

Then install [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/),
and under **Settings → Resources → WSL Integration** enable it for that Ubuntu distro.
From then on, inside the WSL 2 shell:

```bash
sudo apt update && sudo apt install -y make git
git clone https://github.com/upinblue/OS7.git ~/OS7 && cd ~/OS7
make build-amd64
```

> [!IMPORTANT]
> Clone into the **Linux** filesystem (`~/OS7`), never into `/mnt/c/...`. The Windows
> drive is mounted without POSIX ownership or case sensitivity, and `debootstrap` fails
> on it. `uname -m` inside WSL 2 reports `x86_64`, so `make build-amd64` runs native and
> fast — the same code path CI uses.
>
> **Not yet proven:** no amd64 ISO has ever been produced on a local machine. Every one
> that exists came off a hosted x86_64 CI runner. The route above is the documented one
> and it is the one CI takes, but nobody has walked it on Windows yet.

### Any machine → let CI do it

```bash
gh workflow run build-iso.yml
```

Dispatch-only, deliberately: `arm64` on the free native ARM runners, `amd64` on the
standard x86_64 ones, and nothing under emulation.

### The other combinations

| Your machine | arm64 ISO | x86-64 ISO |
|---|---|---|
| **Apple Silicon Mac** | `make build-arm64` — native, ~5 min | `make build-amd64-vm` — a whole QEMU x86 VM, hours |
| **Windows x64 (WSL 2) · Linux x86_64 · Intel Mac** | `make build-arm64` — emulated, untested on an x86 host | `make build-amd64` — native |

`make build-amd64` refuses early on a non-x86_64 host rather than letting you spend
twenty minutes reaching a known failure.

## What's in the box

| Tier | Components |
|---|---|
| **Core, everywhere** | PowerShell 7.6.5 · .NET 10 SDK · ZFS 2.4.1 on Linux 7.0 · `authd` — its `authd-msentraid` broker is a Canonical snap and is **not in the image yet** |
| **Desktop installs (x86-64)** | GNOME 50 in OS/7 Classic · Microsoft Edge · Intune portal + `microsoft-identity-broker` |
| **Server installs** | Azure Connected Machine agent (Azure Arc) — x86-64 *and* arm64 |
| **Recommended additions** | Azure CLI · VSCodium (the official VS Code build is opt-in) |
| **Out of scope for v1** | OneDrive sync · Microsoft Defender for Endpoint |

Component versions are not written here twice: they live in
[`build/config/os7-release.conf`](build/config/os7-release.conf), the single pin that
also fixes the Ubuntu archive to one timestamp, and every image carries the resulting
bill of materials at `/usr/lib/os7/release.json`.

## PowerShell on the inside

Two modules ship, and the direction between them is deliberate. `Zfs` is a generic
OpenZFS layer that knows nothing about OS/7 and would run on any ZFS host; `OS7` is the
product layer on top of it and reaches ZFS only through it.

```powershell
Import-Module Zfs        # staged into the image's module path, so it resolves by name

Get-Zpool                                     # sizes are [uint64] bytes, not "1.4T"
Get-ZfsDataset | Where-Object { $_.Used -gt 1TB }
(Get-ZpoolStatus rpool).Vdevs                 # a real object tree, not indented text
```

23 cmdlets, read and write, checked against 18 recordings of real ZFS output:

```bash
pwsh -c 'Import-Module ./powershell/Zfs/Zfs.psd1 -Force; Test-ZfsModule'
```

## Documentation

| If you want to know… | Read |
|---|---|
| What works today, and what to do next | [docs/HANDOFF.md](docs/HANDOFF.md) |
| What is locked and what is still open | [docs/DECISIONS.md](docs/DECISIONS.md) |
| The installer: screens, decisions, limitations | [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md) |
| Versioning, the update train, rollback | [docs/RELEASE-AND-UPDATE-PLAN.md](docs/RELEASE-AND-UPDATE-PLAN.md) |
| ZFS from PowerShell | [docs/ZFS-POWERSHELL-PLAN.md](docs/ZFS-POWERSHELL-PLAN.md) |
| Every trap found so far, numbered | [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) |
| How to work in this repository | [CLAUDE.md](CLAUDE.md) |

`docs/SESSION-*.md` are the lab notebooks: what one session measured, what it did *not*,
and what that changed.

## Repository layout

```
build/          the ISO — live-build config, hooks, and the release pin
installer/      os7-setup: the design, the C# source, the spikes, the VM harness
powershell/     the Zfs module, and the OS7 module on top of it
docs/           plans, decisions, handoff, build notes, session results
scripts/        host-side helpers the Makefile calls
```

## How we work here

Two habits, both learned the expensive way, and both worth knowing before you send a
patch:

**Measure, don't assert.** Every claim in `docs/` has a number behind it and says how it
was obtained. The recurring shape of the costly bugs in this project is *a program
reported success and the thing it was meant to change did not change* — so an exit code
is a diagnostic, not evidence. Ask the thing itself.

**A diagnostic must not depend on the subsystem it is diagnosing,** and it must be
checked against the thing it claims to check. Both rules are in
[docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) because both were learned by getting a
confident, wrong answer.

## Licence

[MIT](LICENSE) for OS/7's own tooling, installer, scripts and modules —
© 2026 up in blue GmbH. Ubuntu and every upstream component keep their own licences;
two of them ship their notices inside the image alongside the files they cover
(Cascadia Mono under OFL 1.1, the classic UI font under LGPL-2.1+).

<div align="center">
<br>
<sub>Built in the open by <a href="https://github.com/upinblue">up in blue GmbH</a></sub>
</div>
