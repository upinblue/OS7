# OS/7 installer — Calamares + ZFS

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
2. **Ask GUI vs. headless at setup time** and diverge:
   - **GUI** → keep GNOME, keep the Microsoft desktop stack, Intune enrollment.
   - **Headless** → remove the desktop packages, onboard to Azure Arc instead.

   Because the ISO ships one shared package base, headless is a **removal** step
   after unpacking, not a different image. Calamares' `packages` module can do
   this via a `try_remove` operation driven by the user's choice.
3. **Onboard the management agent.** `azcmagent` is installed by hook 0040 but
   deliberately left un-onboarded and disabled — onboarding needs tenant
   credentials and is per-machine, so it belongs here.

## Open problems, in order of how much they hurt

### 1. arm64 GUI mode cannot be Intune-enrolled — needs a product decision

Microsoft does not build Edge for arm64 Linux, and `intune-portal` +
`microsoft-identity-broker` are published for amd64 only. The root README
requires GNOME **and** Edge for supported Intune enrollment and does **not**
split by architecture — but the June-2026 README did split, calling arm64
"server-leaning," for precisely this reason.

Hook 0030 logs the gap rather than pretending. The installer needs a decided
answer before it can offer a coherent set of choices. Options:

- Re-introduce the arch split: arm64 is headless/Arc-only, GUI mode is amd64.
- Offer GUI on arm64 but state plainly that it is not Intune-manageable.
- Drop arm64 from the GUI target entirely.

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
