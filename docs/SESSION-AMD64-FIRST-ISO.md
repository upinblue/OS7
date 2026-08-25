# The first amd64 ISO — four stale stages, and a medium that cannot boot

**Date:** 2026-08-25. Against `main`, ending at `c85c783`. Built by **GitHub
Actions**, not on this Mac: `make build-amd64` is still blocked here
(BUILD-NOTES #12), and `make build-amd64-vm` has still never produced anything.

**`OS7-1.0.0.45-amd64.iso` exists.** 3196 MB, 1528 packages, and `check-image.py`
passes every check on it. **It does not boot, and nothing here claims it does.**

---

## What was actually asked

The repository said, in four places, that amd64 had never been attempted. It had
— on 2026-06-24, in the history this one replaced, and GitHub still had the run
(BUILD-NOTES #44). That single fact is what started this: a native x86_64 runner
does not hit the ENOSYS that stops Docker's emulation on Apple Silicon, so CI is
not a nice-to-have for amd64, it is **the only route that has ever worked at
all**.

Four dispatches followed. Each bought exactly one stage.

| run | died in | because |
|---|---|---|
| (June, replaced history) | `lb_binary_memtest` | `cp chroot/boot/.bin` — an unassigned variable, #44 |
| [32830869552](https://github.com/upinblue/OS7/actions/runs/32830869552) | `lb_binary_syslinux` | `syslinux-themes-ubuntu-oneiric` — a package from Ubuntu **11.10** |
| [32833370939](https://github.com/upinblue/OS7/actions/runs/32833370939) | `lb_binary_syslinux` | `vesamenu.c32` not where the stage looks |
| [32835838228](https://github.com/upinblue/OS7/actions/runs/32835838228) | `lb_binary_iso` | `isohybrid` — in `syslinux-utils`, and `syslinux` is what gets installed. Exit **127**, no message |
| [32838033581](https://github.com/upinblue/OS7/actions/runs/32838033581) | — | **green, both architectures** |

## The one finding under all four

Three live-build settings differ per architecture, and every time, amd64 gets the
BIOS-flavoured default while arm64 gets the plain one:

```
LB_MEMTEST        amd64 "memtest86+"   arm64 "memtest86+"  (stage is arch-guarded to amd64/i386)
LB_BOOTLOADER     amd64 "syslinux"     arm64 ""
LB_BINARY_IMAGES  amd64 "iso-hybrid"   arm64 "iso"
```

**arm64 has been building with no bootloader stage since the first ISO, and that
empty string is the entire reason `build/lib/efi-remaster.sh` exists.** It
had been sitting in the configuration the whole time, saying that OS/7 already
owns its medium's boot path on one architecture. Three of the four fixes are the
same edit: give amd64 arm64's value.

And what was being switched off could never have shipped. syslinux is a **BIOS**
bootloader; OS/7 boots UEFI with shim and a Canonical-signed GRUB; this
live-build has **no grub-efi stage at all** (`grub`, `grub2`, `syslinux`,
`yaboot`, `silo`). Three more fixes inside `lb_binary_syslinux` would have
produced a boot path the product had already decided against.

## What the artefact says when asked

`./installer/testing/check-image.py amd64`, reading the CI ISO — apt sources out
of the **shipped** image, os-release, the volume name, and `os7-setup` run by
chrooting into the image:

```
ok    the image knows its version — 1.0.0.45
ok    the image knows what source it was built from — BUILD=45 commit=c85c783f0bdd
ok    built from a clean source tree
ok    the package manifest is populated — 1528 packages
ok    IMAGE_ID — os7          ok  ID is left as ubuntu (Intune) — ubuntu
ok    every apt source in the image is pinned — all on snapshot.ubuntu.com
ok    os7-setup --version agrees with the manifest — OS/7 1.0.0.45 (development)
ok    os7-setup --self-test passes in the image — failures=0 image-files-absent=0
ok    the ISO volume carries the version — OS7-1.0.0.45-amd64
```

`--self-test` there is not a rerun of the arm64 one: it is an **x86_64 NativeAOT
binary executing inside the amd64 image's own root**, and `image-files-absent=0`
says every asset it draws with shipped. Spike S2 predicted this; this is the
first time it has been true of a real amd64 medium.

### The half of the product that only exists here

arm64 is server-only by design. This is the first look at the other half:

| | |
|---|---|
| packages | **1528** (arm64: 549) |
| GNOME | `gnome-shell` 50.1, `gdm3` 50.1, `ubuntu-desktop-minimal` 1.570.3, 33 `gnome-*` |
| Edge | `microsoft-edge-stable` **151.0.4129.107-1** |
| Intune | `intune-portal` **1.2607.4-resolute** |
| Azure | `azure-cli` 2.89.1-**1~noble** |
| Entra | `authd` 0.6.1ubuntu0.1 — the msentraid broker is still absent (README open question 4) |
| Secure Boot | `shim-signed` 1.59+15.8, `grub-efi-amd64-signed` 1.215+2.14 |
| PowerShell | `/usr/bin/pwsh` → `/opt/microsoft/powershell/7/pwsh`, plus the `OS7` module |

Two things worth carrying out of that table. **`intune-portal` is packaged for
`resolute`** — the Microsoft prod repo has a 26.04 suite and the agent is in it,
which is the first hard evidence that the management path has a package to
install at all. And **`azure-cli` is a `~noble` build**: the `repos/azure-cli`
suite is 24.04's, not 26.04's. It installs; whether Microsoft supports that
combination is a question for the Arc prerequisites page (README open question 2)
and not something an ISO can answer.

The Secure Boot chain being *in the image* also means an amd64 remaster has the
pieces it needs, exactly as arm64 did.

## What was NOT measured

* **It does not boot. Nothing has tried.** `--bootloader none` means live-build
  writes no El Torito entry, and with no bootloader case matching, no `-r` either
  — genisoimage said so: *Joliet extensions but without Rock Ridge*. This is an
  artefact to **read**, and `check-image.py` reads it whole without booting.
* **No amd64 machine has been installed**, so nothing in Phases 1–3 is an amd64
  result. Screen 8's GUI half is still unwalked, and `InstallModeStep`'s
  desktop-removal branch with it.
* **GNOME, Edge and Intune are present, not proven.** A package in a manifest is
  a package in a manifest.
* **This did not build locally.** `make build-amd64-vm` is still unexercised, and
  the ENOSYS in #12 is untouched.
* **The four fixes were not re-tested on the June failure's terms.** They were
  each measured by `lb config` before the dispatch and confirmed by the next
  run's log; no attempt was made to reproduce the old failures afterwards.

## What it changes in the plan

1. **An amd64 EFI remaster is now the next amd64 task** — *done the same day;
   see [SESSION-AMD64-EFI-REMASTER.md](SESSION-AMD64-EFI-REMASTER.md)* — and it is
   a known shape: `build/lib/arm64-efi-remaster.sh` (now `efi-remaster.sh`) is the sibling, `shim-signed` and
   `grub-efi-amd64-signed` are already in the image, and the GRUB menu it must
   write is the same two entries.
2. **CI is load-bearing, not decoration.** It is the only way an amd64 ISO can be
   produced at all today. A `push:` trigger is now defensible — both jobs are
   green — but it stays `workflow_dispatch` until the medium boots, because a
   green build of an unbootable ISO is exactly the kind of signal this repository
   distrusts.
3. **README's amd64 rows change from "never built" to "built, cannot boot".**
   Those are different claims and the second one is worth more.
