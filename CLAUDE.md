# Working on OS/7

OS/7 is a Microsoft-admin-friendly Linux built on Ubuntu 26.04 LTS: PowerShell as
the interactive shell, Entra ID / Intune / Azure Arc as the management path, ZFS
root with rollback-safe updates, and an OS/7-authored text-mode installer styled
after MS-DOS 6.22 Setup and the Windows 2000 text phase.

Everything runs **locally on an Apple Silicon Mac**. No cloud, no CI, no paid
services. Builds are Docker; VMs are QEMU.

---

## Where authority lives

Do not decide something these files have already decided. Do not restate them
here either — this file points, they rule.

| Question | The file that answers it |
|---|---|
| What version this is, what archive it was built against, what is in it | [build/config/os7-release.conf](build/config/os7-release.conf) — the pin. **The only place a version number or an archive URL may live.** |
| What is locked, what is still open | [docs/DECISIONS.md](docs/DECISIONS.md) — "Locked decisions" and "Open questions". Moved out of README.md on 2026-08-25; the README is now the public front page and decides nothing |
| The installer: design, screens, decisions D1–D10, limitations L1–L22, phases | [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md) — **authoritative** |
| Versioning, the update train, rollback, `/var` | [docs/RELEASE-AND-UPDATE-PLAN.md](docs/RELEASE-AND-UPDATE-PLAN.md) |
| What the machine calls itself and to whom, the friendly `1.x.x`, `Get-OS7Version`, decisions I1–I10 | [docs/IDENTITY-PLAN.md](docs/IDENTITY-PLAN.md) — **it supersedes the `NAME=` row of the release plan's §3.5** |
| What works today and what to do next | [docs/HANDOFF.md](docs/HANDOFF.md) — **read this first** |
| ZFS from PowerShell: the two layers, decisions Z1–Z14, the v1 surface | [docs/ZFS-POWERSHELL-PLAN.md](docs/ZFS-POWERSHELL-PLAN.md) |
| Backup: what is snapshotted, where copies go, how it is verified, B1–B15 | [docs/BACKUP-PLAN.md](docs/BACKUP-PLAN.md) |
| Every trap found so far, numbered | [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) — **read before debugging** |
| What a past session actually measured | `docs/SESSION-*.md` |

**Intune's constraints outrank OS/7's technical preferences** wherever the two
collide (DECISIONS, "Intune compatibility is a hard requirement"). Anything touching
disk layout, encryption, OS identity, desktop or browser gets checked against
Microsoft's live docs *first*.

---

## The commands that work

```bash
make build-arm64                          # the ISO. ~5 min. Docker, privileged.
make build-amd64                          # x86_64 hosts only - refuses elsewhere
make build-amd64-vm                       # on Apple Silicon: a QEMU x86 VM, hours

./installer/testing/check-image.py        # ask a built ISO what it is - no boot
./installer/testing/run-phase1.py all     # walk os7-setup in a VM and check it
./installer/testing/run-phase3.py all     # install, BOOT THE DISK ALONE, then
                                          #   install again BY KEYPRESS (walk)
./installer/spikes/run-s1.py all          # the look: palette, font, glyphs, keys
./installer/spikes/run-s3.py all          # install to a disk and boot from it
./installer/spikes/run-s4.py all          # Secure Boot + TPM2 unlock (budget 1h)
./installer/spikes/run-s6.py all          # TPM2 unlock across an update
./installer/spikes/run-s7.py all          # is the version number true (two builds)
./installer/testing/run-s5.py all         # S5: install WITH A TPM, boot with no
                                          #   passphrase typed, then clone a boot
                                          #   environment, activate it, roll back
./installer/testing/check-be-logic.py     # the BE cmdlets' decisions, no VM, 3s
./installer/testing/check-home-logic.py   # Get-/Move-OS7Home's decisions: a fake
                                          #   zfs whose datasets are real tmpfs
                                          #   mounts. No VM, no ZFS, ~4s. Runs
                                          #   itself in a container (#74, #78)

./installer/testing/run-zfs.py capture    # real ZFS output -> test fixtures
./installer/testing/run-zfs.py test       # Test-ZfsModule -Live, on a booted VM
./installer/testing/check-layering.py     # Z1: does OS7 still reach ZFS directly
./installer/testing/check-version-rule.py # the version DISPLAY RULE, in both
                                          #   languages: 82 checks, no VM, ~10s.
                                          #   --docker os7-build:<arch> for the
                                          #   C# half off a Mac or Windows box

./installer/testing/run-backup.py all     # backup, against real ZFS and real
                                          #   sanoid. NEVER RUN - it is the gate
                                          #   docs/BACKUP-PLAN.md B-5 names
```

The two self-tests need no VM, no ZFS and no ISO, and both are green:

```bash
pwsh -c 'Import-Module ./powershell/Zfs/Zfs.psd1 -Force; Test-ZfsModule'   # 75
pwsh -c 'Import-Module ./powershell/OS7/OS7.psd1 -Force; Test-OS7Backup'   # 63
```

**Boot environments are real since 2026-08-25**, and none of it is a ZFS
operation. `Get-/New-/Set-/Remove-OS7BootEnvironment` and `Restore-OS7` live in
`powershell/OS7/`. Three facts decide what a machine boots, all measured:
**OS/7 writes its own menu** (`/etc/grub.d/09_os7-boot-environments`, one entry
per environment) because `10_linux_zfs` emits only one without `zsys` (#67); a
file on the **ESP** names which environment's menu is read
(`set prefix=($root)'/BOOT/<be>@/grub'`); and `saved_entry` in that
environment's `grubenv` names the entry. No ZFS property takes part.
[docs/SESSION-BOOT-ENVIRONMENTS.md](docs/SESSION-BOOT-ENVIRONMENTS.md).

**Two PowerShell modules, and the direction between them matters.**
`powershell/Zfs/` is the generic ZFS layer — it knows nothing about OS/7 and
would run on any OpenZFS host. `powershell/OS7/` is the product layer on top of
it. Z1 says OS7 reaches ZFS only through Zfs; `check-layering.py` holds that
line at a baseline that may fall and may not rise. The Zfs module checks itself
against **recorded real ZFS output** shipped beside it:

```bash
pwsh -c 'Import-Module ./powershell/Zfs/Zfs.psd1 -Force; Test-ZfsModule'
```
**Backups are sanoid and syncoid, wrapped — not reimplemented.** `powershell/OS7`
decides which datasets, which targets and *whether it actually worked*; the
snapshot policy, the retention thinning and the `zfs send`/`receive` are the
`sanoid` package's, shelled out to (GPL-3.0+, never vendored). The wrapper
exists because **both tools report success in cases where nothing happened** —
sanoid exits 0 after a failed `zfs snapshot`, and its `--monitor-snapshots`
answers from a cache deliberately allowed to be five hours old (#73). So
`Get-OS7BackupStatus` asks ZFS, on the source and over ssh on the target, and
never asks either tool. [docs/BACKUP-PLAN.md](docs/BACKUP-PLAN.md).


**One file defines the release:**
[build/config/os7-release.conf](build/config/os7-release.conf) — the version, the
archive snapshot, and every component version and hash. Nothing else in the repo
may carry a version number or an archive URL. The build turns it into
`/usr/lib/os7/release.json`, `IMAGE_VERSION` in `/etc/os-release`, the ISO
filename and the boot-environment name, so those four cannot disagree. What a
built ISO actually contains is beside it:

```bash
./installer/testing/check-image.py        # seconds, no VM
```

That last one is the check nothing else can make: it reads
`/etc/apt/sources.list` out of the **shipped** image and fails if a single source
escaped the pin. Hook 0075 runs mid-build and cannot see what live-build does to
apt afterwards.

**A person is shown three fields, a machine four** (2026-08-26,
[docs/IDENTITY-PLAN.md](docs/IDENTITY-PLAN.md) §5). `1.0.0 (development)` is
chrome — the title row, `PRETTY_NAME`, `/etc/issue`, the MOTD,
`Get-OS7Version`; `1.0.0.95` is anything that has to tell two builds apart —
dataset names, `IMAGE_VERSION`, the ISO filename, `--version`, the
boot-environment menu, the Complete screen. It is a **display rule, not a second
number**, implemented **four times** — `Model/Release.cs` `Short`/`Full`,
`Get-OS7Version`, `installer/testing/os7version.py` and
`build/lib/version-rule.sh` — so `check-version-rule.py` owns the case table and
drives all four, and says which ones a given run reached. `Get-OS7Version` reads
the same `/usr/lib/os7/release.json` os7-setup and `New-OS7BootEnvironmentName`
read, and its `Drift` is **empty until `-CheckDrift`, never `$false`**.

**And the machine says OS/7 where a person looks, Ubuntu where software does.**
`PRETTY_NAME`, `/etc/issue`, the MOTD header and the GRUB menu are branded;
`NAME`, `ID`, `ID_LIKE`, `VERSION`, `VERSION_ID`, `VERSION_CODENAME`,
`/etc/lsb-release` and `uname` are not, and **`NAME` is on that list because
Microsoft's Arc onboarding script reads it and exits 133 on anything without
`buntu` in it** (#80). Every branded surface reads
`/usr/lib/os7/product` — OS/7's own file — so if `PRETTY_NAME` ever has to be
given back, nothing else changes.

Building `os7-setup` alone, without an ISO:

```bash
docker run --rm --platform linux/arm64 -v "$PWD":/work os7-build:arm64 bash -c \
  'cd /work/installer/src/OS7.Setup && dotnet publish -c Release -r linux-arm64 \
   -p:PublishAot=true -o /tmp/pub && /tmp/pub/os7-setup --self-test'
```

`--self-test` is the first thing to run when anything about Setup looks wrong. It
also runs **inside the chroot during the ISO build** (hook 0080), so a missing
font or palette fails the build rather than a boot.

---

## How work is done here

This is not a style preference; the repo is built on it and the docs assume it.

**Measure, do not assert.** Every claim in `docs/` has a number behind it and
says how it was obtained. When a session finds something, it writes a
`docs/SESSION-*.md` with what was measured, what was *not*, and what it changes
in the plan. Commit messages are long-form: what was found, what it means, what
it changed.

**A diagnostic must not depend on the subsystem it is diagnosing**, and **a
diagnostic must be checked against the thing it claims to check.** Both rules are
in BUILD-NOTES because both were learned by getting a confident, wrong answer.
The recurring shape of the expensive bugs in this repo is: *a program reported
success and the thing it was meant to change did not change.* An exit code is a
diagnostic. So is a log line. Ask the thing itself.

**Spikes are evidence, not templates.** `installer/spikes/` records what was
done and what it taught. Do not "fix" a spike to match a later decision —
`s3-zfs-luks.sh` predates D10 and is meant to.

**`os7-setup` installs a machine that boots** (Phase 3, 2026-08-24). From screen
10 onwards it writes to the disk, and screen 6 is the gate before that. The
proof is `run-phase3.py boot`: a VM with **no ISO attached**, starting the disk
Setup installed. Any claim about the installer that has not been through that is
a claim about code, not about a computer.

---

## The traps that cost the most

Full list and evidence in [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md). These are
the ones a fresh session hits first.

- **#13 — hooks must be at `config/hooks/*.chroot`, FLAT.** Wrong layout and
  live-build runs nothing, prints "Begin executing hooks…", and **exits 0**.
  Never conclude a hook ran because the build succeeded.
- **#12 / #23 — amd64 ISOs cannot be built on Apple Silicon** (ENOSYS in
  debootstrap's tar under Docker emulation), but amd64 **.NET binaries can**. Do
  not generalise the first into the second.
- **#80 — `/etc/os-release` is a folk convention, not a contract.** Three
  Microsoft consumers read three different field sets: Arc's onboarding script
  keys on **`NAME`** and exits 133 without ever reading `ID`; `intune-agent`
  reads `ID`, `VERSION`, `VERSION_ID` **and** `PRETTY_NAME`. D8 branded `NAME`
  because "Intune matches on `ID`" — never verified, and wrong for at least one
  tool. Never protect "the field they match on"; make the brand independent of
  all of them ([docs/IDENTITY-PLAN.md](docs/IDENTITY-PLAN.md) I1).
- **#85 — a theme can be installed, verified, and never loaded.** Hook 0090
  reported the classic desktop verified and every statement was true; the screen
  was Ubuntu's, because `00-os7-classic` set sixty keys and not
  `org.gnome.desktop.session session-name`, and `modes/ubuntu.json` carries its
  own `stylesheetName` that no user theme beats. Same shape as #62: every
  declaration satisfied, and the thing they were about decided elsewhere. The
  second half of the fix is checking that the session the key names **exists** —
  dconf stores any string and GDM falls back silently.
- **#84 — GNOME 50 will not draw 1-bit text.** `font-antialiasing='none'` was a
  deliberate Windows-2000 choice against a GNOME that no longer honours it: GTK 4
  loses vertical stems, GTK 3 on the same screen at the same size does not.
  Twelve renderings outside the desktop say the font is fine. Never conclude a
  font is at fault before rendering it somewhere the toolkit is not.
- **#15 — a ZFS root needs `boot=zfs` on the kernel command line**, and nothing
  generates it for you.
- **#16 — driving a serial console:** Enter is `\r`; an unanswered terminal query
  kills PowerShell; and never expect a marker the typed command itself contains,
  or the shell's echo reports success for a command that never ran.
- **#25 — Ubuntu's `setvtrgb.service` replaces the console palette** set on the
  kernel command line, before anything is ever displayed and without an error.
  Ship `/etc/vtrgb` or apply it yourself.
- **#31 — fbcon DEFERS taking the console over** and completes it only when
  something *writes*. Until then tty1 is the dummy device and `KDFONTOP` returns
  ENOSYS. `fbcon=nodefer`.
- **#33 — `Conflicts=` is resolved when systemd builds the transaction;
  `Condition…=` when the job runs.** An enabled unit with a failing condition has
  already conflicted its target away.
- **#43 — in a git WORKTREE, `.git` is a FILE pointing outside the bind mount**,
  so git in the build container cannot answer and every ISO came out `1.0.0.0`,
  commit "unknown". Build through the **Makefile**, which asks git on the host
  (`scripts/os7-source-facts.sh`) and hands the three facts in; `build.sh` now
  refuses rather than inventing a version. Claude Code sessions run in a
  worktree by default, so this is hit on the first build, not the tenth.
- **#45 — a screen must validate only what IT collected.** Screen 6 checked the
  whole plan, including an account nobody had been asked for yet, and screen 7
  was unreachable for a whole commit. `--unattend`, `--storage-only` and the
  screen-walking harness each missed it for a different reason. The whole plan is
  checked once, at `ExecuteScreen.Start`.
- **#74 — `/home/<user>` was NOT on a USERDATA dataset unless the account was
  called `os7`.** `New-OS7Storage`'s `-UserName` defaulted to `os7` and
  `os7-setup` never passed it, so the machine this repo has booted has an empty
  dataset at `/home/os7` and the real home inside the boot environment — where
  `Restore-OS7` rolls it back and no snapshot policy may follow. **Fixed in code
  2026-08-26 and NOT YET VERIFIED**: the fix changes the storage step and the
  account step of the only path that produces a machine that boots, so it needs
  `run-phase3.py all`, which needs the Mac. Nothing in `installer/testing/`
  looked at `/home` — which is why an installer that passed `run-phase3.py all`
  still had it — and checks 9 and 10 are now what stop that recurring.
- **#78 — `useradd -m` does NOTHING when the home directory already exists.**
  It warns, **exits 0**, copies no `/etc/skel` and changes no ownership
  (measured on this image's `passwd`). Since #74's fix the home is always there
  first, so this is the only path an OS/7 install takes: the naive one-parameter
  fix yields a correctly-placed home that is `root:root`, empty, and unwritable
  by its owner. `AccountStep` finishes the job and proves it from `stat`.
- **#79 — the setup medium boots a DESKTOP's background workload while it
  installs, and `loglevel=0` does not keep the kernel off Setup's screen.**
  Both halves measured out of the shipped amd64 squashfs after a 6 GB VM's
  install died at the pool step: the Install entry's `multi-user.target` pulls
  in **39** units and **15** timers — `unattended-upgrades`, six `snapd` units,
  `apt-daily.timer` — onto a medium whose writable root is RAM and which has no
  swap, with `zfs_arc_max` at its default half of memory; and
  `/usr/lib/sysctl.d/55-console-messages.conf` sets `kernel.printk = 4 4 1 7`,
  so `systemd-sysctl` undoes the command line before the first frame. Fixed by
  `os7-setup-quiesce` (a *generator*, so nothing is started and then stopped;
  keyed to `os7.setup=1`, so the live entry is untouched),
  `InstallerEnvironmentStep` (caps the ARC and reads it back), and
  `Terminal.QuietTheKernel`. **Not verified on a machine.**
- **#66 — code that replaces a spike must be DIFFED against it.** The installer's
  TPM step was written from the same notes as `s4-tpm-enroll.sh` and took a
  different route: no LUKS2 token handler in the initramfs, and
  `systemd-cryptsetup attach` instead of `cryptsetup open --token-only`. The
  spike boots; the paraphrase never had.
- **#69 — sealing to PCR 7 from the installer seals against the INSTALLER's
  PCR 7.** The live session boots with `-kernel`; the installed machine boots
  through shim, which extends PCR 7. Same TPM, different measurement, and
  `cryptsetup` says "TPM policy does not match current system state". Enrolment
  belongs on FIRST BOOT, which is why spike S4 worked and the install step does
  not.
- **#67 — `10_linux_zfs` lists ONE boot environment per machine without zsys.**
  Its `history` section is zsys-only, and the running environment always sorts
  first, so a second one can never appear in a menu generated from the first.
  OS/7 writes its own entries (`/etc/grub.d/09_os7-boot-environments`), built by
  substitution into the running entry.
- **#65 — `$from` IS the `-From` parameter.** PowerShell variable names are
  case-insensitive and a typed parameter coerces silently, so a hashtable
  assigned to `$from` became the string "System.Collections.Hashtable". Never
  reuse a parameter name for a local. `installer/testing/check-be-logic.py`
  finds this class in seconds instead of a VM cycle.
- **#64 — an early `exit 0` in an initramfs script is invisible.** The TPM
  handler asked for `/usr/lib/systemd/systemd-cryptsetup`, which is
  `/usr/bin/systemd-cryptsetup` on resolute, and gave up silently on every boot
  while three checks reported it present. Search for a binary, never name it,
  and say why you gave up.
- **#63 — a `zfs clone` does not carry the origin's local properties**, and
  `canmount` does not inherit at all, so a cloned boot environment comes out
  `canmount=on mountpoint=none` — mountable over the running root, and invisible
  to `10_linux_zfs`, which finds boot environments by `mountpoint=/`. Set both
  explicitly and ask ZFS back.
- **#62 — the package lists do not decide which kernel is installed.** In
  `--mode ubuntu` live-build derives `LB_LINUX_PACKAGES="linux"` and installs
  `linux-generic` beside whatever the lists name, so swapping the list entry
  removed nothing and the build was green. Set `--linux-packages` in
  `auto/config`, and read `config/chroot` back — the same rule as #36.

---

## Repository layout

```
build/                      the ISO: live-build config, hooks, and build.sh
  config/auto/config        live-build configuration (DISTRIBUTION=resolute)
  config/hooks/             common hooks, FLAT (trap #13); hooks-amd64/ for x86
  config/package-lists/     common; -amd64/ and -arm64/ for the split
  config/includes.chroot/   files copied verbatim into the image
  lib/build-console-font.sh Fixedsys TTF -> two PSFs, coverage and shape asserted
                            (os7-setup's font, D9)
  lib/build-installed-console-font.sh
                            Cascadia Mono .deb -> two PSFs (the INSTALLED
                            console, D15). A second route because otf2bdf
                            cannot reach an 8x16 cell from that font (#52)
  lib/cellfont.py           rasterise an outline font into an EXACT console
                            cell and write PSF2; skips what the cmap lacks (#57)
  lib/psf.py                the font subset table, the fixes, and the guard -
                            shared by both fonts, deliberately
  lib/palette.py            the palette, and D5's contrast check
  config/os7-release.conf   THE PIN: version, archive snapshot, component hashes
  config/hooks/0075-*       turns the pin into os-release, release.json and the
                            package manifest - and checks what it wrote
  lib/efi-remaster.sh       neither arch gets a usable bootloader out of
                            live-build; this makes the ISO boot, and owns
                            and owns the ISO's GRUB menu
installer/
  SETUP-PLAN.md             the installer design. Authoritative.
  src/OS7.Setup/            os7-setup itself
  assets/                   the systemd unit
  spikes/                   Phase 0 spikes: evidence, not templates
  testing/                  the VM harness: vmconsole (serial), vmscreen
                            (framebuffer, QMP, reading the screen back through
                            the console font), run-phase1.py
powershell/OS7/             the OS7 module - ONE source, staged by build.sh
  OS7.Backup*.ps1           backup: policy, targets, restore, self-test. Four
                            files DOT-SOURCED by OS7.psm1, so a staging that
                            copied the .psm1 alone is a real failure mode -
                            hook 0060 checks all five
  OS7.Home.ps1              where a home directory lives, and the migration for
                            machines installed before Setup passed -UserName
                            (#74). Dot-sourced too, hence "five"
build/config/includes.chroot/
                            files copied verbatim into the image: the console
                            defaults, and the os7-backup units and their scripts
docs/                       plans, handoff, build notes, session results
out/, .vm/                  artefacts and VM state. Both gitignored.
```

**arm64 and amd64 are different products** (DECISIONS): arm64 is server-only — no
GNOME, no Edge, no Intune — because Microsoft ships no arm64 desktop stack.
Everything proven so far is **arm64 only**; no amd64 ISO has ever been built.
