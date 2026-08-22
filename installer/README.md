# OS/7 installer — Calamares + ZFS

> **SUPERSEDED 2026-08-22 by [SETUP-PLAN.md](SETUP-PLAN.md).**
>
> The installer is now planned as **`os7-setup`** — an OS/7-authored,
> keyboard-driven **text-mode** installer in C#/.NET, styled after MS-DOS 6.22
> Setup and the Windows 2000 text-mode Setup phase, in up in blue blue
> `#1289ff`. It serves **both** architectures, which closes open problem #1
> below (arm64 had no install path because Calamares is a Qt GUI app), and
> removes the need for Subiquity.
>
> Read [SETUP-PLAN.md](SETUP-PLAN.md) first. The Calamares material below is
> kept because its **ZFS**, **Entra** and **encryption** findings (open problems
> #2 and #3) are unaffected by the change of installer — only the Calamares
> parts are obsolete.

**Status: not started.** No Calamares configuration exists yet. What follows is
what has been *established* about the problem, so the next pass doesn't
re-derive it.

## What is now known (verified 2026-08-22)

The single biggest unknown in README Open Question #3 — whether Calamares can
even do ZFS on 26.04 — is answered, and favourably:

| Fact | Detail |
|---|---|
| Calamares is in `resolute` | `calamares 3.3.14-0ubuntu25`, both architectures |
| Ubuntu maintains settings for it | `calamares-settings-ubuntu 1:26.04.12` published for resolute |
| **It ships a ZFS module** | `modules/zfs/libcalamares_job_zfs.so` + `modules/zfshostid/` in the packaged build |
| ZFS itself is safe to target | [docs/SESSION-0-ZFS-VALIDATION.md](../docs/SESSION-0-ZFS-VALIDATION.md) |

So this is an *integration* job against packaged, distro-supported components —
not a port, and not a build-from-source exercise. That is a much smaller risk
than the README assumed.

Calamares is already installed into the live image by
`build/config/package-lists/os7-desktop.list.chroot`.

## What the installer still has to do

1. **Install to a ZFS root**, laid out so `Update-OS7` / `Restore-OS7` can
   create and activate boot environments. The `zfs` module handles pool and
   dataset creation; the boot-environment *layout* is OS/7's design decision and
   is not something Calamares will decide for you.
2. **Ask GUI vs. headless at setup time** — **x86_64 only**, since arm64 has
   no GUI to offer:
   - **GUI** → keep GNOME, keep the Microsoft desktop stack, Intune enrollment.
   - **Headless** → remove the desktop packages, onboard to Azure Arc instead.

   Because the x86_64 ISO ships one shared package base, headless is a
   **removal** step after unpacking, not a different image. Calamares' `packages`
   module can do this via a `try_remove` operation driven by the user's choice.

   On arm64 there is no question to ask: it is always headless.
3. **Onboard the management agent.** `azcmagent` is installed by hook 0040 but
   deliberately left un-onboarded and disabled — onboarding needs tenant
   credentials and is per-machine, so it belongs here.

## Open problems, in order of how much they hurt

### 1. arm64 has no install path yet — Calamares cannot serve it

**Decided 2026-08-22: arm64 is server-only, no GUI target.** That closes the
old question (an arm64 GUI could never have been Intune-enrolled anyway — no
arm64 Linux Edge, and `intune-portal` / `microsoft-identity-broker` are
x86_64-only) but opens a new one.

Calamares is a Qt **GUI** application. The arm64 image ships no desktop, so
Calamares cannot run there at all. The README's Calamares decision therefore
covers **x86_64 only**, and arm64 needs its own install path. Options:

1. **Subiquity autoinstall.** Ubuntu's server installer, text-based, and it
   already understands ZFS root via `storage: layout: {name: zfs}`. Note the
   June-2026 session had a draft profile for exactly this — dropped when
   Calamares was locked in, but now relevant again *for arm64 specifically*.
   Best fit for bare-metal servers.
2. **Ship arm64 as a preinstalled disk image** (raw/qcow2) rather than an
   installer ISO, the way ARM server and edge estates are usually provisioned.
   Cheapest to build, but no bare-metal install story.
3. **A scripted console installer.** Full control, but it means owning
   partitioning, ZFS layout and bootloader code that Subiquity already has.

(1) for bare metal and (2) alongside it for cloud/edge is the combination that
covers the realistic arm64 deployment shapes. Nothing is built yet.

### 2. Entra ID login is not in the image yet

`authd` is in the archive, but its Entra broker **`authd-msentraid` is not** —
it is a Canonical-verified **snap** (0.4.1, both architectures). The root README
says it is in the archive with no PPA needed; the "no PPA" half is right, the
"archive" half is not.

Seeding a snap into a live-build image is its own unsolved task
(`snap download` + `snap ack` into `/var/lib/snapd/seed` plus a seed manifest,
none of which plain live-build supports). It was deferred rather than half-done.
Until it is solved, **no OS/7 build can actually log in with Entra ID**, which
is a headline feature.

### 3. Encryption is undecided

ZFS native encryption vs. LUKS underneath. This interacts with Intune
disk-encryption compliance reporting on managed amd64 desktops — confirm what
Intune actually detects before choosing.

### 4. Calamares branding

Untouched. README wants a classic/retro identity in up in blue Orange `#ff6912`
for branding surfaces — note that this explicitly does **not** extend to the
GNOME desktop itself.

## Prerequisite reading

- [docs/BUILD-NOTES.md](../docs/BUILD-NOTES.md) — build system findings,
  including why amd64 cannot currently be built on Apple Silicon.
- [docs/SESSION-0-ZFS-VALIDATION.md](../docs/SESSION-0-ZFS-VALIDATION.md) — the
  ZFS risk assessment this all rests on.
