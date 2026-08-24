# installer/

`os7-setup` — OS/7's own keyboard-driven text-mode installer, in C#/.NET,
styled after MS-DOS 6.22 Setup and the Windows 2000 text-mode Setup phase.

**[SETUP-PLAN.md](SETUP-PLAN.md) is the design and it is authoritative.** Screen
inventory, decisions D1–D10, limitations L1–L22 and the phase plan all live
there; this file only says what is in this directory and how to run it.

## Where things are

```
SETUP-PLAN.md     the design. Read it before changing anything here.
src/OS7.Setup/    the installer
  Tui/            Frame, Terminal, Input, Geometry, Theme, Widgets/
  Screens/        one file per §3 screen, plus SetupFlow
  Model/          InstallPlan (source-generated JSON), Disks, SystemLists
  Steps/          the executor and the storage steps
  Native/         Termios, Ioctl, Poll, Tty — LibraryImport into libc
  Diagnostics/    the log: a file, and a ring in memory for the error screen
assets/           os7-setup.service
spikes/           Phase 0. Evidence of what worked, NOT templates — see its README
testing/          the VM harness: vmconsole (serial), vmscreen (framebuffer,
                  QMP, reading the screen back through the console font),
                  run-phase1.py, run-phase2.py
```

The ZFS layer is deliberately **not** here: pool and dataset creation live in
`New-OS7Storage` in [`../powershell/OS7/`](../powershell/OS7/), because
`Update-OS7` needs the identical logic and the hierarchy it creates cannot be
corrected after the fact (SETUP-PLAN §6.3, §4.4).

## State

Phase 0 (four spikes) and Phases 1 and 2 are done. `os7-setup` boots from the
ISO's *Install OS/7* entry, walks Welcome → Licence → Regional → Disk → Layout →
Confirm, and **writes to the disk**: partition table, ESP, LUKS2 container, both
ZFS pools and the §4.4 datasets.

**The result does not boot yet.** Copying the system, creating accounts and
installing the bootloader are Phase 3. Screen 12 says so on the screen.

## Running it

```bash
./testing/run-phase1.py all      # the flow, read back through the console font
./testing/run-phase2.py all      # installs four ways, then reads the DISK back
```

Building and self-testing without an ISO:

```bash
docker run --rm --platform linux/arm64 -v "$PWD/..":/work os7-build:arm64 bash -c \
  'cd /work/installer/src/OS7.Setup && dotnet publish -c Release -r linux-arm64 \
   -p:PublishAot=true -o /tmp/pub && /tmp/pub/os7-setup --self-test'
```

`--self-test` checks what has no visible symptom until a screen is already on a
console — the key table, both fonts and palettes, the licence text, the plan
model, the system lists, and every screen rendering off-screen. Hook 0080 runs
it **inside the chroot during the ISO build**, so a missing PSF or an invalid
plan model fails the build rather than a boot.

## What is still open here

**`authd-msentraid` is not in the archive.** `authd` is, but its Entra broker is
a Canonical-verified **snap** (0.4.1, both architectures) — the root README's
"no PPA needed" is right and its "in the archive" is not. Seeding a snap into a
live-build image is its own unsolved task (`snap download` + `snap ack` into
`/var/lib/snapd/seed` plus a seed manifest, none of which plain live-build
supports). Until it is solved **no OS/7 build can log in with Entra ID**, which
is a headline feature. It is not an installer problem — it is an image problem —
but it was found here and it is tracked as open question 4 in the root
[README.md](../README.md).

**Onboarding is deliberately not done at install time.** `azcmagent` is in the
image (hook 0040) and left un-onboarded and disabled: onboarding needs tenant
credentials, which do not belong in an installer log. SETUP-PLAN Phase 6 collects
the intent at install and executes it on first boot.
