# OS/7 — handoff

**Written 2026-08-24.** State of the repo and the next steps, in order.
Everything here runs **locally on an Apple Silicon Mac**. No cloud, no CI, no
paid services.

New here? [../CLAUDE.md](../CLAUDE.md) is the shorter door: which document
decides what, the commands that work, and the traps that cost the most.

---

## 1. What works today

| Thing | State |
|---|---|
| `make build-arm64` | **Works.** Produces `out/os7-arm64.iso`, **1.83 GB / 518 packages** since 2026-08-25 (was 2.15 GB / 554): the .NET SDK and the kernel headers are gone, C2 and §4.2 of [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md). Note that the package list did not decide the kernel — live-build installs one of its own, BUILD-NOTES #62. |
| That ISO boots | **Yes.** UEFI → GRUB → casper → systemd → login prompt, in QEMU. |
| **Installing to a disk** | **Works on arm64, proven end to end.** ZFS-on-LUKS root, installed from the live ISO and booted from the disk alone. See [SESSION-S3-ZFS-LUKS.md](SESSION-S3-ZFS-LUKS.md). |
| **Secure Boot + TPM2** | **Works on arm64.** Boots with SB enabled against the Microsoft UEFI CA; TPM2 auto-unlock works and a TPM-less machine still prompts. See [SESSION-S4-SECUREBOOT-TPM.md](SESSION-S4-SECUREBOOT-TPM.md). |
| **NativeAOT for `os7-setup`** | **Works on both arches.** 3.2–3.4 MB static-ish ELF, zero warnings, runs in the ISO with .NET deleted. See [SESSION-S2-NATIVEAOT.md](SESSION-S2-NATIVEAOT.md). The SDK is now in the Dockerfile. |
| **The text-mode look** | **Works on arm64, measured.** Field exactly `#0057ad`, stripe exactly `#1289ff`, 126 test-card cells matching the console font pixel for pixel, all 16 arrow/F-keys decoding, 80×25 at 1280×800. See [SESSION-S1-LOOK.md](SESSION-S1-LOOK.md). |
| **The console font** | **Two fonts, both built by the ISO build, neither displayed yet for the second.** `build/lib/build-console-font.sh` converts the pinned Fixedsys Excelsior TTF for **os7-setup** (D9), asserting coverage *and shape*. `build/lib/build-installed-console-font.sh` converts Cascadia Mono for the **installed console** (D15, 2026-08-25), from the .deb already in the pinned snapshot. Both stage into `/usr/share/consolefonts` with a matching `/etc/default/console-setup`, which selects Cascadia. **Proven on a booted machine 2026-08-25** by `./installer/testing/verify-console-font.py`: the installed disk with no ISO attached, 107 of 107 cells matching the shipped PSF bitmap for bitmap. Getting there cost two kernel rejections nothing here could see (BUILD-NOTES #59). See [SESSION-CASCADIA-CONSOLE.md](SESSION-CASCADIA-CONSOLE.md). |
| PowerShell | **Works.** Login lands at `PS /home/…>`, on the live ISO and on the installed system. `Import-Module OS7` resolves by name. The count in this row used to be five and is now **34**: storage, boot environments, rollback, backup, home directories and — since 2026-08-27 — the update train. `Set-OS7Mode` is the one function that still throws by design. `bash` is still the login shell; `pwsh` is deliberately *not* in `/etc/shells`. |
| ZFS | **Works and is safe.** `zfs.target` reached on boot. See [SESSION-0-ZFS-VALIDATION.md](SESSION-0-ZFS-VALIDATION.md). |
| **Boot environments** | **Real since 2026-08-25, and activation is a BOOTLOADER operation.** `Get-`/`New-`/`Set-`/`Remove-OS7BootEnvironment` and a real `Restore-OS7` in `powershell/OS7/`. Three measured facts shape all of it: `10_linux_zfs` emits entries for exactly ONE environment per machine without `zsys` (BUILD-NOTES #67), so **OS/7 writes its own menu**; a file on the **ESP** names whose menu GRUB reads; and `saved_entry` names the entry. `zfs clone` carries none of the origin's local properties, so both `canmount` and `mountpoint` are set explicitly (#63). `installer/testing/check-be-logic.py` checks the decisions in three seconds without a VM; `run-s5.py` checks the machine. [SESSION-BOOT-ENVIRONMENTS.md](SESSION-BOOT-ENVIRONMENTS.md). |
| **ZFS from PowerShell** | **v1 READ surface exists and is checked against real ZFS output.** `powershell/Zfs/` — `Get-Zpool`, `Get-ZpoolStatus`, `Get-ZfsDataset`, `Get-ZfsSnapshot`, `Get-ZfsProperty`, `Get-ZfsSpace`. Sizes are `[uint64]` bytes, dates are `[datetime]`, and `zpool status` comes back as a **vdev object tree**. **23 cmdlets**, read and write. `Test-ZfsModule` replays 18 captures taken from a VM where ZFS is loaded (**56 checks**) and `-LiveWrite` exercises create/snapshot/clone/promote/rollback/destroy against real pools. `New-OS7Storage` now goes through it — `check-layering.py` reports 0 direct `zfs`/`zpool` calls in `powershell/OS7`, and **`run-phase3.py all` passed on that code**: install, boot-with-no-ISO-attached, and a second install by keypress. The shipped OS7 module contains no `zfs`/`zpool` invocation at all, so the pools on that disk were created through the Zfs layer and no other. [ZFS-POWERSHELL-PLAN.md](ZFS-POWERSHELL-PLAN.md), [SESSION-ZFS-POWERSHELL.md](SESSION-ZFS-POWERSHELL.md), [SESSION-POWERSHELL-MODULES.md](SESSION-POWERSHELL-MODULES.md). |
| `./installer/testing/run-zfs.py` | **New.** `capture` builds a ZFS world on file-backed vdevs in a VM and brings its output home as fixtures; `test` runs `Test-ZfsModule -Live` against real ZFS. A VM and not a chroot, because **the chroot has no ZFS kernel module** and a probe run there answered ten questions confidently and wrongly (BUILD-NOTES §M-Z1 in the plan). |
| `./installer/testing/check-layering.py` | **New.** Holds ZFS-POWERSHELL-PLAN Z1 — `powershell/OS7` must reach ZFS only through `powershell/Zfs` — at a measured baseline of 3 direct invocations, all inside `New-OS7Storage`. The number may fall and may not rise. |
| arm64 server-only split | **Works.** No GNOME/gdm3/Edge/Intune in the arm64 image. |
| `make build-amd64` | **Builds on an x86_64 host, and the artefact is now all-green.** "Blocked locally" was always about Apple Silicon — ENOSYS in debootstrap's tar under Docker's x86 emulation (§3, BUILD-NOTES #12/#23). On a **native x86_64 host it is native and fast**, and on 2026-08-26 one was used: `OS7-1.0.0.109-amd64.iso`, **1514 packages, 2.9 GB** (was 3.1 GB), built from a clean tree on an x64 Windows box through Docker Desktop in about twenty minutes. `check-image.py amd64` is **green on every check**, which the 1.0.0.95 image was not — that one still carried `dotnet-sdk`, `linux-headers-*` and `linux-generic`, and shipped without `sanoid`/`syncoid` and the backup units, because it predates the curation (`f110421`, 22:55) and the backup feature (`3a25763`, 00:17) by hours. Getting there cost two build-stopping bugs that nothing had caught because **nothing had been built since either landed**: BUILD-NOTES #82 (the OS7 module's import crossed #38's line, so hook 0060 failed on every build after 00:17) and #83 (`ldconfig -p | grep -q` under `pipefail`, a SIGPIPE race that failed hook 0080 over a library that was present). The medium BOOTS on amd64 ([SESSION-AMD64-EFI-REMASTER.md](SESSION-AMD64-EFI-REMASTER.md)), and the host itself is written up in [SESSION-AMD64-ON-WINDOWS.md](SESSION-AMD64-ON-WINDOWS.md). **Past the menu, amd64 is OPERATOR-verified rather than harness-verified**: Setup has been run to the Complete screen in GUI mode several times on a Hyper-V VM, the disk it wrote boots to GDM, and the account it created logs in to a desktop with the Intune portal on it. No script asserts any of that, because every harness in `installer/testing/` is `qemu-system-aarch64 -machine virt,accel=hvf` and needs the Mac — so amd64 has no regression detector, only a person. The one failure on record is `1.0.0.95` dying at the pool step, BUILD-NOTES #79 and [SESSION-INSTALLER-MEMORY.md](SESSION-INSTALLER-MEMORY.md), fixed by the quiesce generator in `467f2ee`. |
| `os7-setup` | **Phases 1, 2 and 3 done — an installed machine BOOTS, from `--unattend` and from the keyboard.** `run-phase3.py all` installs unattended, starts the disk with no ISO attached (LUKS prompt, pool import, login as the account Setup created, `/` from `rpool/ROOT/os7_<version>_<stamp>`, `boot=zfs`), and then installs a second machine **by keypress alone** — screens 1–7 to the Complete screen. See [SESSION-PHASE3-SYSTEM.md](SESSION-PHASE3-SYSTEM.md) and [SESSION-SCREEN6-GATE.md](SESSION-SCREEN6-GATE.md). Screen 9 (network) is the one part of 7–11 not delivered. **The log of the install is now on the installed machine** at `/var/log/os7-setup/install.log`, mode 0600, with every step's self-proof in it — L31, [SESSION-INSTALL-LOG.md](SESSION-INSTALL-LOG.md). |
| **The version number** | **Exists, and is true.** [`build/config/os7-release.conf`](../build/config/os7-release.conf) is the single pin — version, archive snapshot, every component hash. The build resolves against `snapshot.ubuntu.com`, writes `/usr/lib/os7/release.json` and brands `/etc/os-release`, and Setup shows the release on every screen. **Spike S7 passed:** two builds from one pin hold identical package sets, 549 packages, same manifest hash. See [SESSION-RELEASE-IDENTITY.md](SESSION-RELEASE-IDENTITY.md). |
| `./installer/testing/check-image.py` | **New.** Asks a built ISO what it is, in seconds, without booting: the shipped `sources.list`, the branded os-release, the ISO volume label, and `os7-setup --version` / `--self-test` run by chrooting into the image. It is the only check that sees the artefact after live-build's binary stage. |
| **Backup** | **Written and self-tested; NEVER RUN ON A MACHINE.** `powershell/OS7/OS7.Backup*.ps1` — 17 cmdlets over `sanoid` (snapshot policy and retention) and `syncoid` (`zfs send`/`receive` replication, local or over ssh), both GPL-3.0+ and both shelled out to rather than vendored. OS/7 owns which datasets, which targets, and the verification: `Get-OS7BackupStatus` asks ZFS on the source and, through the `Zfs` module over ssh (Z14), on the target — comparing snapshot **GUIDs**, because neither tool's exit code is evidence (BUILD-NOTES #73). `Assert-OS7DatasetSafe` keeps a snapshot policy away from `rpool/ROOT` and `bpool/BOOT`. `Test-OS7Backup` is **63 checks, green**, and `check-layering.py` still reports **0**. What has never happened: a snapshot taken, a stream sent, or a file restored by this code. [BACKUP-PLAN.md](BACKUP-PLAN.md), [SESSION-BACKUP.md](SESSION-BACKUP.md). |
| **The PowerShell system surface** | **Five generic modules and 101 exported OS/7 functions as of 2026-08-29** (95 on 2026-08-28, four modules and 58 on 2026-08-27) — and since the manual and the scheduled-task feature, parts of it HAVE run on a booted machine (typed at one, which is what found #112–#113). [POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md) is authoritative: P1 (the `OS7` prefix), P2 (a generic module per subsystem, `check-layering.py` holds **five** rules since the directory one landed), P3 (the netplan renderer moves to PowerShell in two steps). `powershell/Net/`, `powershell/Time/`, `powershell/Systemd/` and `powershell/Directory/` join `powershell/Zfs/` as layers that know nothing about OS/7; `OS7.Network/Time/Remoting/Service/ScheduledTask/Management/Directory/DirectoryObject/Domain.ps1` are the product on top. Self-tests: Zfs 75, Net 57, Time 33, Systemd 68 (32 before the timer surface), Directory 40, Backup 63 — all green, all against RECORDED REAL output. The no-VM checks that go with them are listed in §2; `check-scheduledtask-logic.py` is the newest. |
| **What that surface found** | **Entra sign-in cannot work on an OS/7 image as built today.** `/etc/authd/brokers.d` is EMPTY in the shipped ISO — authd installed, PAM wired to it, no broker to bridge to — so a sign-in fails as though the password were wrong. That is C8a measured on the artefact rather than reasoned about, and `Get-OS7EntraStatus` is the first thing on a machine that says so. Also: `Enter-PSSession` did not work at all (`sshd -T` listed only `sftp`); an interactive `ssh` DOES land in PowerShell and had never been tested until `check-ssh-login.py`. |
| **Active Directory** | **Stage 1 is proven against a directory that answers; stage 2 has never run on a machine.** An administrator signs in to AD **from** an OS/7 machine with their own AD admin account and works as themselves — the machine is **not** a member of the domain and does not need to be. `powershell/Directory/` is the fifth generic layer (**36** functions, `Test-DirectoryModule` **51/51**—both numbers were 25 and 40 here and were already stale before the merge;—the module was asked) over `System.DirectoryServices.Protocols`, which ships *inside* pwsh 7.6.5 on Linux and needs **no new package on either architecture**; `OS7.Directory.ps1`, `OS7.DirectoryObject.ps1` and `OS7.Domain.ps1` are the product on top. `check-ad.py` drives all of it against a real **Samba 4.23.6** AD DC in a container (realm `OS7.TEST`) and reads every write back with `ldbsearch` **inside the DC** — a tool that shares no code with the client under test — and it is **all green**; `check-directory-logic.py` is the no-DC, no-VM half, **15/15**. What that leaves: **no OS/7 machine has ever joined a domain**, `adcli` is on no ISO built so far (so screen 9D is skipped on every medium that exists), **a real Windows Server DC is owed**, and **arm64 is unmeasured for all of it**. [AD-PLAN.md](AD-PLAN.md) is the authority. |
| `./installer/testing/run-backup.py` | **New, and never executed.** The tier-2 gate for the backup feature: builds two file-backed pools in a booted VM, enables the policy, snapshots, replicates to the second pool, ruins a file and restores it — with every assertion asked of ZFS or the filesystem. `all` is the gate BACKUP-PLAN B-5 names. Ported to `vmarch.py` on 2026-08-28 and still unrun — on either host. |
| **The VM harness on x86_64** | **Works since 2026-08-28, measured on the x64 Windows host.** `installer/testing/vmarch.py` is the one place machine/accelerator/firmware/vehicle come from: arm64 stays a host process on HVF (byte-identical to the pre-port construction, held by `check-vm-arch.py` — 41 checks, no QEMU, both hosts); amd64 is `q35,accel=kvm` with OVMF inside the `os7-vm:amd64` container, serial over the docker client's stdio, QMP on TCP, swtpm in-container. `boot` measured #69 for the first time (#100): the install-time TPM seal does not open through shim, and S6's one-command recovery restores it. The arm64 branch was NOT executed (no Mac in the session). [SESSION-VM-HARNESS-PORT.md](SESSION-VM-HARNESS-PORT.md) |
| **The update train, delivered end to end** | **The full `run-s5.py all` gate — install, TPM boot, cycle, `Update-OS7` against a served repository, and the unattended timer — has RUN ON THIS HOST (amd64/KVM), repeatedly, on fully packaged ISOs.** The ISO installs the nine OS/7 .debs through hook 0022 (`check-image.py`: 105 checks, `dpkg -S` attributes pwsh, the modules, os7-setup, the console font, release.json and the apt source to packages); releases have channels and a hotfix form (`check-os7-repo.py` 123, `check-update-logic.py` 32); firstboot migrations have a runner shipped in os7-release, and UL1's TPM2 re-seal plus #104's fstab-ordering retrofit are its first two real migrations; §6's unattended check ships as `os7-update-check.timer` with a measured exit-code contract (0 nothing/no channel, 2 staged, 1 failed). Four gate runs each converted a FAIL into a numbered defect — #104 (the ESP buried under the ZFS /boot by a boot-ordering race), #105 (saved_entry written before activation's point of no return), #106 (update.conf's missing trailing newline), #107 (Restore-OS7's "previous" — age, then promote-rotated origins, now the `org.os7:previous` property) — and the final verdict table is in [SESSION-UPDATE-DELIVERY.md](SESSION-UPDATE-DELIVERY.md). |

### Phase 0 is done — the gate is open

`installer/SETUP-PLAN.md` §10 gates every line of installer code on four spikes.
All four have passed:

| | | |
|---|---|---|
| **S1** | does the look actually work | `./installer/spikes/run-s1.py all` — [SESSION-S1-LOOK.md](SESSION-S1-LOOK.md) |
| **S2** | does NativeAOT build here | `./installer/spikes/run-s2.sh all` — [SESSION-S2-NATIVEAOT.md](SESSION-S2-NATIVEAOT.md) |
| **S3** | does a ZFS-on-LUKS root boot | `./installer/spikes/run-s3.py all` — [SESSION-S3-ZFS-LUKS.md](SESSION-S3-ZFS-LUKS.md) |
| **S4** | Secure Boot and TPM2 unlock | `./installer/spikes/run-s4.py all` — [SESSION-S4-SECUREBOOT-TPM.md](SESSION-S4-SECUREBOOT-TPM.md) |

S3 was the one that mattered most, because the repo had never installed OS/7 to
a disk by any means. It has now:

```bash
./installer/spikes/run-s3.py all
```

partitions a blank disk (ESP + `bpool` + LUKS2), creates `bpool` and `rpool`,
lays down the §4.4 datasets, `unsquashfs`es the live filesystem into them,
configures the target and installs GRUB — then reboots **from the disk alone**,
asks for the passphrase, and reaches a login prompt with `/` served from
`rpool/ROOT/os7_2026.08.1_202608230935`. Roughly 15 minutes on Apple Silicon.

* the sequence: [`installer/spikes/s3-zfs-luks.sh`](../installer/spikes/s3-zfs-luks.sh)
  — throwaway in quality, load-bearing in **order**; `os7-setup`'s storage
  executor is meant to be a front-end over exactly this
* the harness: [`installer/spikes/run-s3.py`](../installer/spikes/run-s3.py)
* the findings: [SESSION-S3-ZFS-LUKS.md](SESSION-S3-ZFS-LUKS.md)

**The one thing to carry into every later boot problem:** a ZFS root needs
**`boot=zfs`** on the kernel command line and *nothing generates it for you* —
not `initramfs-tools`, not `grub.d/10_linux_zfs`. Without it the machine drops
to an initramfs prompt. BUILD-NOTES #15.

## 2. Do this next

**THERE IS A WORKBENCH SINCE 2026-08-30, AND IT CHANGES WHAT "GO AND LOOK" COSTS.**
`installer/testing/os7lab.py` runs a VM that outlives the process that started
it, so asking a booted machine a question costs a command instead of a boot —
and `snapshot`/`restore` are **0.6 s and 0.7 s** against the 25 minutes an
install takes. Three channels, and which one answered is part of the answer:
the serial line (needs only a kernel, and is the only one that can watch a boot
fail), ssh (a real exit code and no quoting limit), QMP (the screen, the
keyboard and the tablet). `run-surface.py` types every Get- and Test- cmdlet at
that machine and writes [SURFACE-MATRIX.md](SURFACE-MATRIX.md).

It found three defects in its first hour, and **none of them was reachable by
the checks that existed** — they ask a build host or a container about an
image, and these needed an installed machine:

* **#117 — 27 world-writable paths in the shipped ISO**, `/usr/lib/systemd/system`
  and `…/system-generators` among them. Docker Desktop presents the Windows
  bind mount as 0777 and `cp -a` preserved it. **FIXED**, and the ISO is
  measured at 0 by two new `check-image.py` assertions that were red against
  1.0.0.159 before the fix existed.
* **#118 — no installed machine can accept an SSH connection. STILL OPEN.**
  `/etc/ssh/ssh_host_*` does not exist and `ssh.service` dies on every attempt
  with `no hostkeys available`. `sshd-keygen.service` is enabled and its
  condition (`ConditionFirstBoot=yes`) was never met, although `os7-setup`
  correctly writes an empty machine-id and the ISO ships one. **Why the
  installation's first boot did not count as a first boot is the open
  question**, and the bench can reproduce it: install, snapshot, watch boot one.
* **#112/#119 — FIXED**, see above.

[SESSION-WORKBENCH.md](SESSION-WORKBENCH.md) is the measurement; the arm64 half
of the bench is written and **unrun**.

**ACTIVE DIRECTORY WORKS OUTBOUND SINCE 2026-08-28, AND THE MACHINE IS NOT IN
THE DOMAIN.** An administrator signs in to AD **from** an OS/7 machine with their
own AD admin account and works as themselves — users, groups, computers, OUs, a
password reset, a raw search. No domain join, no machine account, and **no new
package on either architecture**: `System.DirectoryServices.Protocols` ships
inside pwsh 7.6.5 on Linux and reaches `libldap`, which is guaranteed because
`libldap2` is a `Depends` of `libcurl4t64` and `curl` is in
`os7-base.list.chroot`. That is **stage 1**, and it is proven against a
directory that answers. **Stage 2 — the domain join, `sssd`, and the installer's
screen 9D — is code that has never run on a machine.** Keep those two sentences
apart; the whole feature's honesty is in the gap between them.
[AD-PLAN.md](AD-PLAN.md) is the authority, and it is where A/AL/M-A numbers live.

```bash
./installer/testing/check-directory-logic.py   # the DECISIONS, no DC, no VM — 15/15 GREEN
./installer/testing/check-ad.py                # a REAL Samba 4.23.6 DC in a container — ALL GREEN
pwsh -c 'Import-Module ./powershell/Directory/Directory.psd1 -Force; Test-DirectoryModule'  # 51/51
./installer/testing/check-layering.py          # FIVE rules now: P2-directory, baseline 1
```

`check-ad.py` builds the DC itself (`installer/testing/Dockerfile.ad-dc`, realm
`OS7.TEST`), and two things about it are worth copying rather than repeating:
every OS/7 write is read back with `ldbsearch` **inside the DC**, which shares no
code with the client under test; and the stage-1 section runs a second time with
`adcli`, `kinit`, `klist` and `sssctl` moved out of `PATH`, so "stage 1 needs
none of stage 2's packages" is a measurement rather than an intention.

**BOTH CMDLET DEFECTS FOUND ON 2026-08-29 ARE NOW CLOSED** — #113 on the day,
#112 on 2026-08-30 — and both were found the same way: **by typing the commands
at a machine rather than by a check.** Writing the administrator manual
([docs/manual/](manual/README.md)) required every example to be run and
photographed on an installed disk, and that was a use of this surface nothing
here had made before. `installer/testing/run-surface.py` now makes it routine:
it types every Get- and Test- cmdlet at a booted machine in one pass, which is
how #112 was found a second time after its own note recommended a fix that was
never applied.

* ~~**#112 — `Get-OS7BackupStatus` throws on an ordinary machine. STILL OPEN.**~~
  **FIXED 2026-08-30, together with the idiom behind it (#119).** No
  replication target meant `$targets` was empty, `Select-Object -Last 1` was
  `$null`, and `Set-StrictMode` turned the property read into a terminating
  error — on *every* machine that had not opted into replication (B4), and
  unconditionally under `-SkipTargets`. Four sites now take the selection in
  two steps, and the nine `Get-ZfsProperty … .Value` occurrences of the same
  idiom became one private helper. **Verified on a booted machine**, not by a
  self-test: `Test-OS7Backup` was 63 green before and after and covers neither
  state. Two things this note should be read for now: the fix sat here as a
  RECOMMENDATION for a day and nothing was watching the difference, and what
  found it again was `run-surface.py` asking a machine. The manual's picture of
  this cmdlet (`docs/manual/transcripts/92-backup-status.txt`) still shows the
  exception and needs re-shooting from an image built after the fix.
* ~~**#113 — the cmdlet surface cannot see a timer.**~~ **FIXED 2026-08-29 as
  a NOUN** — POWERSHELL-SURFACE-PLAN **P9**: `Get-OS7Service` stays
  deliberately services-only (Windows' own services.msc/taskschd.msc split),
  and `Get-/Enable-/Disable-/Start-/Register-/Unregister-OS7ScheduledTask`
  is where timers live, over the Systemd layer's new
  `Get-/New-/Remove-SystemdTimer`. `Get-OS7ScheduledTask
  os7-update-check.timer` answers, and its `Healthy` names the
  enable-without-start trap (#115) and keeps disabled tasks listed (#116).
  Gates: `check-scheduledtask-logic.py` 64 checks, `Test-SystemdModule` 32→76
  on newly recorded systemd 259 fixtures, the cmdlets run end to end against
  real systemd as PID 1 in a container, `check-os7-repo.py` 123 with the file
  that made the dot-source list FIFTEEN in the .deb (27 required paths, was
  26; OS7.Update.ps1 stays last), and the machine evidence in
  [SESSION-SCHEDULED-TASKS.md](SESSION-SCHEDULED-TASKS.md).

[SESSION-ADMIN-MANUAL.md](SESSION-ADMIN-MANUAL.md) has the original
measurements, and #114 there is the harness lesson that cost three VM runs.

**What is owed, in order, and none of it is small:**

1. **A real Windows Server domain controller.** Samba exercises the protocol; it
   does not reproduce LDAP channel binding, signing enforcement, Windows
   password-policy sub-codes, `msDS-*` constructed attributes, LAPS or
   cross-forest referrals. A green `check-ad.py` is the gate for the protocol. It
   is not a fleet.
2. **A machine that has actually joined.** `Join-OS7Domain`, `Test-OS7Domain` and
   `Repair-OS7Domain` are code plus a container test. And `adcli` is on **no ISO
   this repository has built** — measured against
   `out/OS7-1.0.0.116-amd64.packages.manifest`, 1 491 packages — so screen 9D
   skips itself on every medium that exists today and records that nobody was
   asked. Putting the join tooling in a package list is the first step, and
   rebuilding is the second.
3. **arm64, for all of it.** There is no arm64 packages manifest in `out/` at all,
   so even the package half of the join is an inference on that architecture.
4. **Screen 12 does not print the join's outcome.** The join is best-effort by
   design — a wrong password must not destroy an otherwise complete install — so
   the one thing that must not happen is that it is quiet. It is logged and it is
   in the plan; it is not yet on the screen the operator reads.

**Writing it found four traps, three of them now numbered.** BUILD-NOTES **#94**
(`[datetime]::TryParseExact` handed a plain `@(...)` binds the single-format
overload and joins the array into one format string — every timestamp comes back
`$null`, which reads as "this DC does not send `whenCreated`"), **#95**
(`catch [T]` matches the *inner* exception while `$_.Exception` inside the handler
is still the `MethodInvocationException` wrapper, so reading `.ErrorCode` off it
throws under `Set-StrictMode` **inside the handler that was supposed to explain
the failure** — the operator gets a PowerShell property error where a password
message belonged), and **#96** (`.GetNewClosure()` breaks a test seam that has to
reach *module* state: it rebinds the block to a fresh closure scope where
`$script:` no longer resolves to the module's session state, and every recorded
call becomes `$null` — measured both ways in one run). The fourth is not a
PowerShell trap but a directory one, and it is in the surface rather than in the
notes: **`userAccountControl`'s `LOCKOUT` bit (`0x10`) is not maintained by Active
Directory**, so `Get-OS7ADUser` computes `LockedOut` from **`lockoutTime`**
— a surface that read the flag would tell an administrator a locked-out account is
fine, and send them to look at the password.

**Two things it leaves undecided, and both are layout questions rather than code
ones** — [DECISIONS.md](DECISIONS.md) open questions **9** and **10**. `/etc` is
inside the boot environment, so `/etc/krb5.keytab` is: roll back across a machine
account password rotation (30 days by default) and the keytab goes back while the
DC does not, while sssd's cache under `/var/lib/sss` is *outside* the BE by D10
and does not roll back — the two halves of one identity disagree by construction.
And domain users' homes are under `/var/lib/os7/domain-homes` via sssd's
`fallback_homedir`, deliberately outside the BE where `Restore-OS7` would roll
them back (BUILD-NOTES #74's shape in a second place), but that is not a
`rpool/USERDATA` dataset and the default backup policy does not reach it.

**And one thing it deliberately does not do**, which belongs here so nobody
re-opens it as a gap: no Group Policy (no GPO engine exists for Linux; sssd
enforces logon-right GPOs only, which is consumption and not administration),
nothing over RPC/DCOM (`repadmin`, `dcdiag`, `netdom`, DNS server, DHCP,
certificate enrolment), nothing through `[ADSI]` (it loads on Linux and then
throws "not supported on this platform"), and no WinRM (measured dead: "no
supported WSMan client library was found"). A domain join also does **not** make
a machine Intune-manageable — enrolment goes through Entra and there is no hybrid
join for Linux.

---

**THE POWERSHELL SURFACE IS WRITTEN AND HAS NEVER RUN ON A BOOTED MACHINE.**
Everything in it was measured against a container and, for the facts that
decide behaviour, re-checked against the shipped ISO's squashfs — but a
container is not a machine, and BUILD-NOTES **#93** is the session where that
distinction nearly put a false product defect into this file. What is owed:

```bash
./installer/testing/check-layering.py         # 5 rules — GREEN
./installer/testing/check-netplan-rule.py     # both languages, byte-exact — GREEN
./installer/testing/check-network-logic.py    # GREEN
./installer/testing/check-service-logic.py    # GREEN
./installer/testing/check-management-logic.py # GREEN  (needs an os7img:* image)
./installer/testing/check-ssh-login.py        # GREEN  (real sshd, in a container)
# and on a BOOTED machine, which nothing above replaces:
#   Get-OS7NetworkAdapter / Set-OS7NetworkAdapter with a real netplan apply
#   Get-OS7TimeSynchronization against a real chronyd on real hardware
#   Get-OS7Log against a real journal that has survived a reboot
#     (possible at all only since #109: until 2026-08-28 the installed
#      machine had NO journal on any boot — the flush beat zfs-mount and
#      the real /var/log buried what it wrote)
```

**P3 step 2 needs the Mac.** The netplan document is generated in two languages
— `NetworkPlan.ToNetplanYaml` in C# and `New-NetplanDocument` in PowerShell —
and `check-netplan-rule.py` requires them to agree byte for byte. Collapsing
them into one means `os7-setup` calling the module, which changes the only code
path proven to produce a machine that boots, so it is gated on
`run-phase3.py all`.

**Two things the surface reports that somebody has to decide about.**
`/etc/authd/brokers.d` is empty, so Entra sign-in cannot work (C8a); and
`powershell/OS7/os7-endpoints.json` carries `verified: null` because none of its
hosts has been checked against Microsoft's live documentation, which CLAUDE.md
says is the FIRST thing to do for anything touching identity.


**`Update-OS7` HAS RUN ON A MACHINE — the full gate runs on THIS host since
2026-08-28** ([SESSION-UPDATE-DELIVERY.md](SESSION-UPDATE-DELIVERY.md)): the
packaged ISO installs, boots by TPM alone, cycles, applies a served release
end to end (N → N+1, firstboot migrations, conffile-kept channel, prune) and
honours the unattended exit-code contract. What the update train still OWES,
by host:

**The Mac owes:**

```bash
./installer/testing/run-s5.py all      # the SAME gate on arm64/HVF — the ported
                                       #   branch is byte-identical (check-vm-arch)
                                       #   and has never been EXECUTED
./installer/testing/run-phase3.py all  # still the #74 gate. `walk` PASSES on
                                       #   amd64 since 2026-08-28 (the FIRST
                                       #   amd64 interactive install ever), but
                                       #   `boot` cannot see an amd64 machine at
                                       #   all (#99), and #74 checks 9 and 10 are
                                       #   IN `boot`. So walk green != #74 shown.
                                       #   arm64 owes the whole of `all`
make build-arm64                       # no arm64 ISO has been built with hook
                                       #   0022 (the packaged install) — then
./installer/testing/check-image.py     #   over it
./installer/testing/run-backup.py all  # B-5's gate, never run on ANY host
```

**Either host owes: a serial console for `run-phase3.py boot` on amd64.**
`run-s5.py` grew a `serialize` phase for BUILD-NOTES #99 — x86 has no
device-tree console, os7-setup correctly writes no `console=`, and the
installed machine talks to tty0. run-phase3 has no equivalent, so its `boot`
phase times out for 599 seconds on a machine that boots perfectly.

~~Until it does, #74 cannot be discharged on this host either, because its two
/home checks live in that phase.~~ **Not true since 2026-08-30**: the two /home
checks live in that phase, but the QUESTION does not. `os7lab.py install` built
a machine on this host and `Get-OS7Home` answered it directly —
`rpool/USERDATA/os7admin_8caded3b`, `OwnDataset: True`, `Agrees: True`. What
run-phase3 still owes is its own coverage of the installer walk, not this.

**Either host owes:** a hotfix applied through `Update-OS7` on a booted
machine (the form is container-proven, `check-os7-repo.py` walks a real one;
the machine gate applies full releases only — wired, not run); and P3 step 2
(collapsing the two netplan renderers) stays gated on `run-phase3.py all`.

**The merge with the Directory/identity branch is DONE (2026-08-28, `fdb00f9`).**
The checklist that stood here was followed and it was right about all three
things. The module list resolved toward main's (six modules), pkg_finish took
the union, and the .deb content check was re-run rather than trusted:
`make repo-amd64` reports `os7-module — 26 required paths present` (27 since
2026-08-29, when OS7.ScheduledTask.ps1 joined the list), read back out
of the built package by `dpkg-deb -c`, and `check-os7-repo.py` is **123/123**.
`check-installer-cmdlets.py` was the first thing run on the merged tree and
passes across 157 cmdlets.

What the checklist did NOT anticipate, and what a second pass found:

* **`build.sh` carried the same module list a second time**, and it was the
  half nobody was looking at. update-train had replaced `stage_ps_module`
  with `stage_ps_fixtures` over a `for _mod in Zfs Net Time Systemd OS7` loop;
  main's entire `build.sh` diff was adding Directory to the function
  update-train deleted. Two lists, one entry apart, no conflict between them.
* **pkg_finish named three of the fourteen files `OS7.psm1` dot-sources.**
  Each branch had added files the other could not see. All of them are named
  now — fourteen then, fifteen since OS7.ScheduledTask.ps1 (2026-08-29) — and
  the set is diffed against the `.psm1`'s own `foreach`, not `ls`.
* **BUILD-NOTES #108 was claimed twice** by two already-committed branches.
  main had it; the missing-journal note became **#109** and its references
  moved with it. The file's reservation convention only works between
  sessions that share a branch.

See [SESSION-MERGE-CONSOLIDATION.md](SESSION-MERGE-CONSOLIDATION.md) for what
was measured on the merged tree and what was not.

---

**OS/7 IS SOMETHING dpkg KNOWS ABOUT (2026-08-26).** Until this week every OS/7-specific file on a running
OS/7 system was unowned by a package — the PowerShell tarball, both modules,
`os7-setup`, the release manifest, the console fonts, the os-release branding —
so the update train could have reached Ubuntu's half of the product and nothing
that makes it OS/7. C7 is built:
[SESSION-OS7-REPOSITORY.md](SESSION-OS7-REPOSITORY.md).

```bash
make repo-amd64                           # nine .debs + a SIGNED suite os7-1.0
./installer/testing/check-os7-repo.py     # install from it in a plain Ubuntu
                                          #   container, then swap the key and
                                          #   require apt to REFUSE. ~4 min
```

What that left has been done:

1. ~~**`Update-OS7`**~~ and ~~**`Get-OS7Release -Available`**~~ — written
   2026-08-27, and the gate has now run (above).
2. ~~**Switch the ISO over.**~~ — **Done 2026-08-28** (hook 0022 installs the
   nine .debs, os7-release first; hooks 0020/0085 deleted; 0050/0075 verify
   the packages' work). The two-release.json seam resolved as C9 implies:
   `/usr/lib/os7/release.json` is what os7-release DECLARES, the build's
   measurement moved to `/usr/lib/os7/image.json`, and `check-image.py`
   requires the two to agree where they overlap.

**C7a is still open and was kept open on purpose.** The repository is signed by
a development key whose user ID reads `NOT FOR RELEASE` and which the descriptor
declares as such. Where a release key lives and who holds it is a decision to
make deliberately, not on the day the first repository is published.

**And this box can run KVM after all — and since 2026-08-28 the harnesses
USE it.** `docker run --device /dev/kvm` on the x64 Windows host gives
`query-kvm → {"enabled": true}` — no elevation, no Hyper-V by hand. The port
(`installer/testing/vmarch.py`) is done for every harness; `run-s5.py` has
run its full gate here repeatedly; the other harnesses are ported and UNRUN
on this host. See [../CLAUDE.md](../CLAUDE.md) and
[SESSION-VM-HARNESS-PORT.md](SESSION-VM-HARNESS-PORT.md).


**THE amd64 DESKTOP WAS LOOKED AT ON A SCREEN FOR THE FIRST TIME ON
2026-08-26, AND IT WAS UBUNTU'S.** `1.0.0.109` booted into the **Ubuntu
session**, not OS/7 Classic, so the theme that hook 0090 verified was never
loaded — `00-os7-classic` never set `org.gnome.desktop.session session-name`
and `modes/ubuntu.json` carries its own Shell stylesheet (BUILD-NOTES **#85**).
On the same screen, `font-antialiasing='none'` was tearing vertical stems out of
every GTK 4 surface while GTK 3 stayed crisp (**#84**). Both are fixed in
`1.0.0.114`, together with the removal of `gnome-initial-setup`, the telemetry,
the crash reporters, Firefox and the Ubuntu boot logo — and VS Code beside Edge
and Intune. **None of it has been seen on a booted machine.**

`OS7-1.0.0.116-amd64.iso` is that build — **1491 packages, 3.1 GB**, and
`check-image.py amd64` is green on all of it, including the eleven new checks
and the one that matters most:

```
ok  an interactive login lands in PowerShell 7.6.5 — PS /> … 7.6.5
```

So **boot it and look at the panel.** It is `#d4d0c8` or the session default is
still not taking, and that is a two-second answer nothing here can give.
[SESSION-DESKTOP-DEBRAND.md](SESSION-DESKTOP-DEBRAND.md) says what was measured
and — at greater length — what was not. Since 2026-08-28 this box CAN run the
harnesses (`vmarch.py`, amd64/KVM in Docker) — `run-phase3.py` is ported and
merely unrun here — so the amd64 VM work is no longer Hyper-V by hand.

**THE BACKUP FEATURE LANDED ON 2026-08-26 AND HAS NEVER TOUCHED A MACHINE.**
That is the first thing to do next, and it is one command on the Mac:

```bash
./installer/testing/run-backup.py all
```

It boots the live ISO, builds two file-backed pools, enables a policy, snapshots,
replicates, ruins a file and restores it — asking ZFS and the filesystem for
every answer. Until it passes, `Get-OS7BackupStatus` is a claim about code.
[BACKUP-PLAN.md](BACKUP-PLAN.md) B-5 is the gate; §12 is the honest limitation
list, and BL1 is at the top of it.

**#74 — MEASURED ON A MACHINE 2026-08-30, ON THIS HOST, AND IT LANDED.**
`os7lab.py install` produced an OS/7 1.0.0.161 machine and `Get-OS7Home` on it
said `Dataset: rpool/USERDATA/os7admin_8caded3b`, `OwnDataset: True`,
`OwnFilesystem: True`, `Agrees: True` — ZFS and `stat(2)` asked separately and
agreeing — with `findmnt` and `zfs list` saying the same. The home an OS/7
install produces is outside the boot environment. **`Move-OS7Home`, the
migration for machines installed before the fix, is still unverified**, and
`run-phase3.py all` still owes its own coverage of the installer walk. The
paragraph below is what the question WAS, and it is kept because the reasoning
in it is still how the defect is explained.

**~~#74 IS WRITTEN AND UNVERIFIED, AND IT IS THE FIRST THING TO RUN ON THE MAC.~~**
`New-OS7Storage`'s `-UserName` defaulted to `os7` and `os7-setup` never passed
it, so on the machine this repository has actually booted the account's home is
an ordinary directory **inside the boot environment** and `/home/os7` is an
empty dataset — `Restore-OS7` rolls a user's files back with the system, the one
thing SETUP-PLAN §4.4's layout exists to prevent. On 2026-08-26 all of it was
written, from Windows, and **the gate was not run**:

```bash
./installer/testing/run-phase3.py all
```

That is what decides whether this landed. It changes the storage step and the
account step of the only code path in this repository proven to produce a
machine that boots, so `install`, `boot` and `walk` all have to pass — and
checks **9 and 10 are new**: `/home/<account>` must be a `rpool/USERDATA`
dataset on a machine that has BOOTED, owned by the account and furnished from
`/etc/skel`. `run-s5.py cycle` gained the other half: a file written into the
home from the clone must still be there after the rollback that removes the
clone's package.

What is already checked, and what it does not cover:

```bash
./installer/testing/check-home-logic.py    # 45 checks, ~4s, no VM and no ZFS
pwsh -c 'Import-Module ./powershell/OS7/OS7.psd1 -Force; Test-OS7Backup'   # 63
```

`check-home-logic.py` runs `Get-OS7Home` and `Move-OS7Home` — the migration for
machines already installed — against a fake `zfs` whose datasets are real tmpfs
mounts, inside a container it builds itself from the PowerShell
`build/config/os7-release.conf` pins. It checks OS/7's DECISIONS: that the
dataset is never created at the home directly (`overlay=on` would hide the
files), that the original is renamed and not deleted, that a bad copy is caught
and undone. **It is not a test of ZFS and not a test of a machine** — see
BACKUP-PLAN B-6, which is the gate `Move-OS7Home` has never been through.

Also new, and worth reading before touching any of it: BUILD-NOTES **#78** —
`useradd -m` warns, **exits 0**, copies no `/etc/skel` and changes no ownership
when the home directory already exists, which it now always does. The
one-parameter fix on its own would have produced a correctly-placed home that
its owner cannot write to.

docs/DECISIONS.md open question 8, BUILD-NOTES #74 and #78, BACKUP-PLAN B-Q1,
docs/SESSION-HOME-DATASET.md.

**SPIKE S5 PASSED on 2026-08-25** — the last open gate in
[RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §10. A machine
`os7-setup` installed cloned its boot environment, took a change into the clone,
booted it, and rolled back with the change un-said. Nine checks, three boots:
`./installer/testing/run-s5.py`.

**Read [SESSION-BOOT-ENVIRONMENTS.md](SESSION-BOOT-ENVIRONMENTS.md) first if you
are anywhere near the bootloader.** The one-sentence version: **activation is a
bootloader operation, not a ZFS one**, and OS/7 writes its own GRUB entries
because the stock generator lists exactly one environment per machine without
`zsys`. Five spike runs, eight new BUILD-NOTES entries (#62–#69), and a check
that runs the module without a VM (`installer/testing/check-be-logic.py`).


Two pieces landed on 2026-08-25 and each leaves a different next step.

**The amd64 EFI remaster is DONE**, and both halves are proved separately:
`build/lib/efi-remaster.sh` re-masters both architectures, the boot line works
(shown in a VM) and the built ISO carries it (read out of the artefact with
`xorriso`) — [SESSION-AMD64-EFI-REMASTER.md](SESSION-AMD64-EFI-REMASTER.md).
What it leaves: **the first amd64 INSTALLATION**, which needs an x86_64 harness
that does not exist — `run-phase1/2/3` are `qemu-system-aarch64` with
`accel=hvf` throughout — and **a Secure-Boot-capable medium**: the GRUB on the
ISO is unsigned, on both architectures, and always has been.

**Phase 3b — the network — is DONE on arm64 and measured**, below. What it
leaves is amd64 (same missing harness), 802.1X, and M2.

**So every Phase 1–3b result is still arm64-only.** The two next steps share one
blocker, and it is the same one: there is no way to drive an x86_64 machine here.
An amd64 harness that synchronises on markers the way `vmconsole`/`vmscreen` do —
rather than on wall-clock time, which cost a peer session two wrong diagnoses in
one afternoon — is the single piece that unblocks both.

Otherwise: **Phase 4 — Authenticity and polish**, or the release plan's **S5**.
Phase 3 is done (below); what it leaves is:

* **Screen 9, the network screen — Phase 3b, WRITTEN and NOT OPTIONAL. M1 is
  measured and it is worse than the image suggested.** An installed arm64 machine
  booted alone with a NIC attached comes up with:

  ```
  2: enp0s2: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN
  ip -o addr show    1: lo  inet 127.0.0.1/8   (and nothing else)
  ip route show      (empty)
  systemd-networkd   disabled, inactive     networkd-dispatcher  enabled
  ```

  Not "DHCP did not answer" — the link was never brought up, there is no route,
  and nothing on the machine reports a problem. Every headless arm64 machine this
  installer has produced needed a keyboard and a monitor to be reached. Screen 9
  was left out of Phase 3 on the premise that "DHCP is the default on a fresh
  Ubuntu install"; that default comes from `cloud-init` on Ubuntu Server and this
  image has none. amd64-GUI is masked by NetworkManager.

  Plan, screens, L23–L28 and D11–D14 are in
  [../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md) §3, §7.2, §7.3, §8, §9
  and Phase 3b; the reasoning and the M1 transcript are in
  [SESSION-NETWORK-ACCOUNTS-PLAN.md](SESSION-NETWORK-ACCOUNTS-PLAN.md).
  Run it with `./installer/testing/run-phase3b-network.py`.

  **PROVED 2026-08-25 on ISO 1.0.0.65**, from a machine booted with no ISO
  attached: the interface has `10.0.2.99/24` — the address that was typed — the
  default route goes via `10.0.2.2`, `systemd-networkd` is *running*, the netplan
  file is mode 0600 and names `networkd`. Wi-Fi associates over `mac80211_hwsim`
  (`wlan0` to `OS7-TEST-AP` with `10.99.0.5/24`), and the interactive walk reaches
  screen 9, finds the NIC, and takes a real DHCP lease with `F4`.
  `./installer/testing/run-phase3b-network.py all` is **green end to end** — the
  install, the boot from the disk alone, and the WPA2-PSK association in one
  sitting. Three of its assertions could not fail, or could not pass, until that
  run: [SESSION-INSTALL-LOG.md](SESSION-INSTALL-LOG.md) §7 and BUILD-NOTES #16.

  **L30 is the finding to read first.** The interface name *changes* between
  installing and running — `enp0s5` with the setup medium attached, `enp0s2`
  without, same MAC — because the medium is a PCI device and predictable names
  come from the PCI topology. netplan accepts a match that matches nothing in
  silence, so the first version of this screen produced exactly the machine it
  was built to prevent. It matches on the MAC now. BUILD-NOTES #56.

  **Still owed: M2, M3, 802.1X, and any real radio.** M1 is one machine, arm64,
  in QEMU. On amd64 `network-manager` is installed on the GUI product and would
  have brought the link up by itself — which is exactly why nobody saw this. The
  Wi-Fi test runs on `mac80211_hwsim`, which simulates the hardware layer away
  and loads no firmware: not one of the 19 firmware packages or 197 wireless
  drivers on the image has been exercised.
* **The account model is decided and needs no code (D11).** Root stays locked and
  the first account stays in `sudo`, which is what `SystemSteps` already does.
  What is owed is one sentence on screen 7 naming the role — the local account is
  the *break-glass* credential for when Entra is unreachable — plus L26, found on
  the way: `/etc/shadow` is inside the boot environment, so **a rollback un-says a
  local password change.**
* ~~**TPM2 enrolment has never actually enrolled.**~~ **It has, on 2026-08-25.**
  `./installer/testing/run-s5.py install` attaches `swtpm` and checks the guest
  can see `/sys/class/tpm/tpm0` BEFORE trusting the run — every Phase 3 run
  before this took the step's "no TPM on this machine" path and reported success
  for a path it never entered. What the first real run found:
  **the enrolment is correct and the boot was not.** Token in key slot 1, sealed
  to PCR 7, handler and libtss2 in the initramfs, `os7-tpm2` ordered ahead of
  `cryptroot` — and the machine asked for the passphrase anyway, because the
  handler looked for `systemd-cryptsetup` at a path resolute does not use
  (BUILD-NOTES #64). Fixed and re-run; see
  [SESSION-BOOT-ENVIRONMENTS.md](SESSION-BOOT-ENVIRONMENTS.md) for the verdict.
* **The GUI half of screen 8 has still never RUN on a machine** — but it is no
  longer unexamined. Since 2026-08-25 `check-image.py` generates it out of the
  SHIPPED binary in a second `--dry-run` with `"mode":"Gui"`, parses it with
  `bash -n`, and asserts that it proves its own result; until then no bash had
  ever seen that branch, and `systemctl enable gdm3` in it was a no-op whose
  failure was printed as a note (BUILD-NOTES #72). `InstallModeStep`'s
  desktop-removal branch is in the same position, and so is screen 8's own
  ENTER — the arm64 flow skips the screen entirely. What is missing is an amd64
  install, not the code.
* **The interactive flow could not reach screen 7 at all until 2026-08-25**, and
  three automated paths passed throughout: `--unattend` is handed a plan that
  already contains an account, `--storage-only` skips the account check by
  design, and the screen-walking harness still expected Phase 2's flow.
  [SESSION-SCREEN6-GATE.md](SESSION-SCREEN6-GATE.md), BUILD-NOTES #45. **Anything
  that changes the screen order has to be walked by hand:**
  `./installer/testing/run-phase3.py walk`.
* **U8** — the escrowed recovery passphrase — is still open, and still on the
  layout screen where the operator can see it.
* **The install log now survives the restart (L31), done 2026-08-25.** It used to
  not: `os7-setup` wrote to `/var/log/os7-setup/setup.log` on casper's RAM
  overlay, so screen 12's reboot discarded every step's self-proof — and screen 12
  printed *that* path on the way out. `InstallLogStep` writes the whole log to
  `/var/log/os7-setup/install.log` **on the target**, mode 0600, before the pools
  are exported. Two things found while fixing it, both of which had been true for
  a while: the log was a **200-entry ring** and a dry run writes **284 lines**, so
  a copy would have arrived complete-looking with the storage phase already
  dropped; and `--self-test` runs in the chroot during the ISO build, so **every
  image shipped a build-time `setup.log`** into the very directory screen 12 sends
  the operator to. [SESSION-INSTALL-LOG.md](SESSION-INSTALL-LOG.md).
  **Still Phase 4's:** the export to removable media, which is the case where the
  machine will not start at all.

### What Phase 3 was (done 2026-08-24)

**Phase 3 — System configuration.** SETUP-PLAN §10: `unsquashfs` with real
progress; chroot configuration (locale, timezone, hostname, users,
`zgenhostid`, `update-initramfs`); bootloader install and the `grub.d` boot-
environment generator; screens 7–11; the GUI/headless split.
*Deliverable: a machine installed by Setup boots into OS/7.*

**Three things were decided into Phase 3 on 2026-08-24** and are in SETUP-PLAN
§10 in full:

* **TPM2 enrolment is in it.** The layout screen already tells the operator that
  Setup will seal the passphrase to the TPM if it can, and Phase 3 builds the
  initramfs anyway. It is not `systemd-cryptenroll` alone — BUILD-NOTES #19, #20,
  and `installer/spikes/s4-tpm-enroll.sh` is the working version. U8, the
  escrowed recovery passphrase, stays open.
* **Every chroot step takes the target root as a PARAMETER**, not
  `StorageSteps.Target` as a constant. `Update-OS7` runs the same sequence from
  step 3 onwards against a cloned boot environment mounted elsewhere (release
  plan §4.2). It costs nothing now and cannot be retrofitted without
  re-validating all of Phase 3.
* **The identity goes onto the target.** `/etc/os-release` (D8) and the GRUB menu
  title (L4) come from the manifest Phase 3 copies in with the system.
  `build/config/hooks/0075-release-identity.hook.chroot` does exactly this for
  the image and is the model.

**And the release-engineering half is now done**, ahead of Phase 3 rather than
after it, because Phase 3 writes the version in three places and the version did
not exist. Read [SESSION-RELEASE-IDENTITY.md](SESSION-RELEASE-IDENTITY.md)
before touching the build: the pin takes **fourteen** mirror flags, not five
(BUILD-NOTES #36), and `unsquashfs` exits 0 for a file that is not there
(BUILD-NOTES #39).

**Where it starts.** Phase 2 leaves the pools created with `-R /target` and the
boot environment mounted, so Phase 3 begins on a mounted, empty
`rpool/ROOT/os7_<release>_<stamp>` at `/target`. The first step is
`unsquashfs` of `/cdrom/casper/filesystem.squashfs` into it; the last is
`grub-install` and a menu that lists the boot environment.
`installer/spikes/s3-zfs-luks.sh` did all of it once, by hand, and booted — its
steps 6 onwards are the sequence to be a front-end over, exactly as steps 1–5
were for Phase 2.

**How to know it worked.** Extend `installer/testing/run-phase2.py` rather than
starting a new harness: it already installs, and the check Phase 3 needs is the
one Phase 2 could not make — **reboot the VM from the disk alone and reach a
login prompt.** `installer/spikes/run-s3.py`'s `boot` phase is that check, and
it is where to copy it from.

That is the phase where the disk Phase 2 prepares becomes a system, so the
things to carry into it are the ones that decide whether it boots:

* **`boot=zfs` is mandatory** on the kernel command line and nothing generates
  it. Without it the machine drops to an initramfs prompt. BUILD-NOTES #15.
* **Never pin `root=ZFS=` in `GRUB_CMDLINE_LINUX`.** `10_linux_zfs` emits one
  per boot environment and anything appended there wins, so every menu entry
  would boot the same dataset.
* **Copy the live system's `/etc/hostid` into the target.** Phase 2 generated it
  *before* creating the pools, which is the only safe order (L13) — Phase 3 owes
  the other half, and it must happen before `update-initramfs`.
* **Setup cannot set a password through PAM in the chroot**, and the squashfs
  has no users at all. BUILD-NOTES #17.
* **Do the chroot's bind mounts inside `unshare --mount --propagation
  private`**, or the pool will not export. BUILD-NOTES #18.
* **A cloned or fresh BE must be ASSEMBLED, not just mounted**: the
  `rpool/DATA` datasets have to be mounted into it before chrooting, or `apt`
  runs against a `/var` with holes in it (§4.4, release plan §4.2 step 3).
* **TPM2 enrolment is more than `systemd-cryptenroll`.** It writes a valid token
  and changes nothing at boot; Setup must also install an initramfs hook
  carrying the token handler *and the libtss2 libraries systemd dlopens*, plus a
  `local-top` script that runs before `cryptroot`. BUILD-NOTES #19 and #20;
  `installer/spikes/s4-tpm-enroll.sh` is the working version.

### What Phases 1 and 2 leave for whoever picks this up

* **`os7-setup --self-test` is the first thing to run** when anything looks
  wrong. Hook 0080 runs it inside the chroot at BUILD time, so a missing PSF or
  an invalid plan model fails the ISO build rather than a boot.
* **The two harnesses are the contract.** `run-phase1.py all` walks the flow and
  reads every screen back through the console font; `run-phase2.py all` installs
  four different ways and reads the DISK back with `sgdisk`, `cryptsetup
  luksDump`, `zpool` and `zfs`. Keep both passing.
* **The ZFS layer is in the OS7 PowerShell module**, not in C# — §6.3, because
  `Update-OS7` needs the identical logic. Phase 3's boot-environment work
  belongs beside `New-OS7Storage`, not in the installer.
* **Debts, all Phase 4 or later:** `F1` help, an `F3` quit confirmation, the
  log-export target picker, and the 24-bit SGR serial surface (§2.7).

### What Phases 1 and 2 measured

Full detail in the two session documents. The ones that will bite again:

* **fbcon defers taking the console over** and completes it only when something
  *writes* to it; until then `KDFONTOP` returns ENOSYS. `fbcon=nodefer`, and
  `setfont` exiting 0 does not mean the font loaded. BUILD-NOTES #31.
* **`SIGWINCH` does not break a blocking `read`** and neither does `ESC`. Use
  `poll(2)`, not `VMIN`/`VTIME`. BUILD-NOTES #32.
* **`Conflicts=` is resolved when systemd BUILDS the transaction; `Condition…=`
  when the job RUNS.** Start a cmdline-gated unit with `systemd.wants=`, never
  with `[Install]`. BUILD-NOTES #33.
* **A screen validates what it collected, never the whole plan.** §6.6 has the
  plan incomplete for most of the flow by design.
* **Ask the disk, not the log.** Every Phase 2 check reads the device back.

### What S2, S3 and S4 changed about what Setup has to do

(S1's are above, because they change Phase 1 rather than Phase 2.)

* **`boot=zfs` is mandatory** on the kernel command line and nothing generates
  it. BUILD-NOTES #15.
* **Never pin `root=ZFS=` in `GRUB_CMDLINE_LINUX`.** `10_linux_zfs` emits one
  per boot environment and anything appended there wins, so every entry in the
  menu would boot the same dataset.
* **L4 may be smaller than SETUP-PLAN assumes.** `10_linux_zfs` still ships and
  generated correct entries unassisted — but it emits zsys-era "Revert" entries
  OS/7 has no `zsys` to serve, and titles the menu **"Ubuntu 26.04 LTS"** from
  `/etc/os-release`. Menu branding is entangled with D8/L16.
* **Setup cannot set a password through PAM in the chroot**, and the squashfs
  has no users at all. BUILD-NOTES #17.
* **Do the chroot's bind mounts inside `unshare --mount --propagation
  private`**, or the pool will not export. BUILD-NOTES #18.
* **`Native/Termios.cs` must use a `fixed byte c_cc[32]`**, not a `byte[]` with
  `[MarshalAs(ByValArray)]` — `LibraryImport` marshals blittable types only, and
  the project needs `AllowUnsafeBlocks`. BUILD-NOTES #22.
* **amd64 `os7-setup` can be built here**, even though the amd64 ISO cannot:
  the `ENOSYS` in BUILD-NOTES #12 is specific to debootstrap's tar, not to
  compilation. Phase 1 is not blocked by §3. BUILD-NOTES #23.
* **TPM2 enrolment is more than `systemd-cryptenroll`.** It writes a valid
  token and changes nothing at boot; Setup must also install an initramfs hook
  carrying the token handler **and the libtss2 libraries systemd dlopens**, plus
  a `local-top` script that runs before `cryptroot`. BUILD-NOTES #19 and #20;
  `installer/spikes/s4-tpm-enroll.sh` is the working version.

### The two open risks S4 and S6 leave behind

* ~~**PCR 7 sealing has no recovery story.**~~ **Measured 2026-08-23 by S6**
  ([SESSION-S6-UPDATE-CYCLE.md](SESSION-S6-UPDATE-CYCLE.md)). Sealing does
  survive kernel and initramfs updates — PCR 7 came back byte-identical across a
  from-scratch rebuild — and it does **not** survive a Secure Boot policy change,
  as expected. What S4 could not know is that the failure is benign in shape:
  `cryptsetup` names the cause, the passphrase path is intact, and one
  `systemd-cryptenroll` against the new PCR 7 restores auto-unlock without
  touching the initramfs. On a managed fleet a shim or dbx update is therefore
  one bad morning, not a rebuild. **The remaining gap is the escrowed recovery
  passphrase** that unattended re-enrolment needs — U8 in
  [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md), and a
  key-management question rather than a boot one.
* **L18 is still untouched.** Whether Intune's encryption check accepts the
  unencrypted `bpool` needs a real enrolment, not a VM.

### The product identity — planned 2026-08-26, and one line of it is wrong in the shipped ISO

[IDENTITY-PLAN.md](IDENTITY-PLAN.md) is new and is now the authority for what
the machine calls itself and for the friendly `1.x.x` version. **Nothing in it
is implemented.** Two things from it belong here:

* **`NAME="OS/7"` in `/etc/os-release` is a defect, not a preference**, and
  `out/OS7-1.0.0.95-amd64.iso` has it. Microsoft's Azure Arc onboarding script
  reads `NAME`, matches `*buntu*` and exits 133 without ever looking at
  `ID=ubuntu` — measured from the script's own source, BUILD-NOTES #80. It does
  not block OS/7 today (hook 0040 caches the `.deb`; and that script rejects
  26.04 outright anyway), but it breaks the path Microsoft's documentation
  tells an administrator to take, and it will keep breaking it after they add
  26.04. Hook 0075 currently *asserts* the wrong value, so this is a two-line
  change plus a read-back that has to be inverted.
* **Phase A is done — `Get-OS7Version` exists and the display rule is live.**
  `Release.Short`/`Full`/`DisplayFull`, `Get-OS7Version` + `OS7.format.ps1xml`,
  and `installer/testing/check-version-rule.py` — **82 checks, green**, both
  languages compared:

  ```bash
  ./installer/testing/check-version-rule.py --docker os7-build:amd64
  ```

  `os7-setup --self-test` grew six checks for the same rule and passes
  (`failures=10 image-files-absent=10`, i.e. no logic failures) on a linux-x64
  AOT build. `Test-OS7Backup` is still 63/0 and `check-layering.py` still 0.
  What has NOT happened: none of it has been in an ISO or on a screen —
  `run-phase1.py` reads the title row off a framebuffer and needs the Mac.
* **Phase B is written and has NEVER BEEN IN AN ISO.** Hook 0075 now leaves
  `NAME` alone, brands `PRETTY_NAME` with the friendly form, adds the URL /
  `LOGO` / `ANSI_COLOR` fields, drops `PRIVACY_POLICY_URL`, and writes
  `/usr/lib/os7/product`, `/etc/issue` and `/etc/issue.net`; it disables
  Ubuntu's MOTD drop-ins by a keep-list and installs `00-os7-header`.
  `check-image.py` reads all of it back off the artefact. **The next step is one
  command on the Mac:**

  ```bash
  make build-arm64 && ./installer/testing/check-image.py
  ```

  Verified so far *without* an ISO, by running the hook's identity sections
  against a real Ubuntu 26.04 root in a container: the branded fields changed,
  the seven untouchable ones did not, and `run-parts` produced the two-line
  login header. That says nothing about whether live-build runs the hook or
  whether `00-os7-header` reaches the image — which is exactly what the command
  above is for.
* **Phases C–E of the identity plan are untouched.** C is the installed machine
  (`ReleaseIdentityStep` becomes the one re-assert function), D is the boot
  (crypttab naming, then Plymouth), E is the tenant.

## 3. amd64 — why it fails here, what a native runner already got past, and the two local options

**Read this first, because three documents used to say the opposite.** amd64 has
been attempted on a native x86_64 machine, once, on 2026-06-24, by the session
this repository harvested rather than inherited — the run is in GitHub Actions
and not in git (BUILD-NOTES #44,
[run 28103636078](https://github.com/upinblue/OS7/actions/runs/28103636078)). On
`ubuntu-24.04` it debootstrapped, built the chroot and ran the package stages
with none of the trouble below, then died assembling the medium:

```
P: Begin installing memtest...
cp: cannot stat 'chroot/boot/.bin': No such file or directory
```

That is a live-build defect in `lb_binary_memtest`, it is amd64-only by
construction, and `--memtest none` disables the stage. The same run built an
**arm64** ISO successfully on `ubuntu-24.04-arm` in 15m2s, so the free native
arm64 runner is real. What none of this says is that amd64 now builds: nothing
in either history has run past that line. It is the next blocker removed, not
the last one.

The rest of this section is about **this Mac**, where the failure is earlier and
different.

`make build-amd64` dies unpacking the base system:

```
E: Tried to extract package, but tar failed. Exit...
tar: ./etc/default: Cannot mkdir: Function not implemented
```

`Function not implemented` is `ENOSYS`. It is **not** an OS/7 bug and not the
VirtioFS problem in BUILD-NOTES #3 — it happens in a container-local path.
Docker Desktop's *syscall-translation* emulation lacks a syscall GNU tar 1.35
uses. Proven by A/B: the identical extraction exits 0 on native arm64 and 2
under amd64 emulation, while coreutils and Python's `tarfile` both work.

Still present on Docker **29.7.2**.

**Do not** work around it by swapping the extractor. That mishandles ownership,
device nodes and xattrs — you get a subtly broken rootfs instead of an honest
failure.

**Which command to run depends on the host:**

| Host | Command |
|---|---|
| **x86_64** — Intel/AMD Mac, x64 Windows, x86_64 Linux | `make build-amd64` — native and fast |
| **arm64** — Apple Silicon | `make build-amd64-vm` — full QEMU x86 VM, hours |

`make build-amd64` refuses early on a non-x86_64 host and points at the VM
target, so you cannot accidentally spend 20 minutes reaching a known failure.

The VM works because QEMU emulates a whole x86 machine rather than translating
syscalls. `scripts/build-amd64-vm.sh` does everything: fetches and
checksum-verifies the cloud image, provisions it with cloud-init, copies the
repo in over SSH, builds, and copies the ISO back to `out/`.
`make build-amd64-vm-reset` discards the VM.

Worth one minute first: Docker Desktop → Settings → General → "Use Rosetta for
x86_64/amd64 emulation on Apple Silicon" is at its default (no key in
`settings-store.json`). Flipping it selects a different emulator which may
implement the missing syscall; if it does, plain `make build-amd64` works here
again.

Until an amd64 ISO is actually built, **amd64 is unvalidated** — and since GUI
mode is amd64-only, the entire GUI path is unvalidated with it. **S3 is an arm64
result only**, for the same reason. The cheapest attempt available today is a
`workflow_dispatch` of `.github/workflows/build-iso.yml`, which is the only path
that has ever reached the binary stage on amd64.

## 4. Traps that already cost time — read before debugging

Full detail in [BUILD-NOTES.md](BUILD-NOTES.md). The ones that bite hardest:

- **#13 — hooks must be at `config/hooks/*.chroot`, FLAT.** The older
  `config/hooks/normal/` layout does not match; live-build then runs nothing,
  prints "Begin executing hooks...", and **exits 0**. `build.sh` now hard-fails
  if hooks are authored but none stage. Never conclude a hook ran because the
  build succeeded — check the image for its effect.
- **#14 — PowerShell module discovery is broken inside `chroot(2)`.** It probes
  `PSModulePath` with the character at index 1 dropped (`/opt/...` → `/pt/...`).
  Build-time only; the shipped image is fine. So no hook can test anything
  needing discovery — `Write-Host`, `Get-Module -ListAvailable`, or
  `Import-Module <name>`. Import **by path** works and is what hooks check.
- **#15 — a ZFS root needs `boot=zfs`, and nothing puts it there for you.**
- **#16 — driving a serial console:** Enter is `\r`, not `\n`, and an
  *unanswered* terminal query kills PowerShell outright. Also: never expect a
  marker that the typed command itself contains, or the shell's echo will match
  it and report success for a command that never ran.
- **#17 — `chpasswd` cannot work in a chroot on this image**, and the squashfs
  contains no users at all.
- **#18 — `mount --make-private --rbind` is not enough for an installer
  chroot.** The bind propagates to other namespaces before it is made private,
  and `zpool export` then says *"pool is busy"* with nothing mounted and `-f`
  powerless. Do the binds and the chroot inside
  `unshare --mount --propagation private`.
- **#19 — `systemd-cryptenroll` alone does nothing at boot**, and fails
  silently: `cryptsetup-initramfs` has no concept of LUKS2 tokens.
- **#20 — `copy_exec` cannot see a dlopen.** systemd dlopens the whole TPM
  stack, so an initramfs built by walking ELF `NEEDED` gets the token handler
  and no libtss2 at all.
- **#21 — Homebrew's QEMU has no Secure-Boot aarch64 firmware.** `run-s4.py`
  pulls Ubuntu's `qemu-efi-aarch64` out of the build container instead. Expect
  10–15 minutes per boot: AAVMF renders GRUB's countdown on a 238-column serial
  console.
- **#22 — `LibraryImport` marshals blittable types only.** `termios` needs a
  `fixed` buffer, not a `byte[]`.
- **#23 — amd64 .NET builds work under emulation** even though amd64 ISO builds
  do not. Do not generalise #12 into "nothing amd64 builds here".
- **#24 — `otf2bdf` exits 8 on Fixedsys** at every point size while writing a
  perfectly correct BDF. Assert the artefact, not the status.
- **#25 — `setvtrgb.service` replaces the console palette** set on the kernel
  command line, before the console is ever displayed and without an error. It is
  the single most expensive trap in this list, because the symptom — a screen in
  *a* palette that is not yours — points straight at the parameters.
- **#26 — `bdf2psf`'s stock equivalences hand `═` the glyph of `─`** and collapse
  the entire double-line box onto the single-line one. No coverage check can see
  it: the codepoint is mapped, to the wrong picture.
- **#27 — Fixedsys draws 15 pixels of ink in a 16-pixel cell**, so every vertical
  box border comes out dashed until the seam is closed. It is also not
  monospaced across its cmap, which `bdf2psf` refuses outright.
- **#28 — `hdiutil makehybrid` keeps only one dot per filename.**
  `x.psf.gz` arrives in the guest as `xpsf.gz`, and the error names the path you
  asked for.
- **#29 — .NET's `Console` input stream cannot be used for raw-mode reading.**
  It returned one byte and then reported end of input on an open tty.
- **#31 — fbcon DEFERS taking the console over**, and completes it only when
  something WRITES to it. Until then tty1 is the dummy device and `KDFONTOP`
  returns ENOSYS, so no font loads and no palette applies. `fbcon=nodefer`.
  And `setfont` exiting 0 does not mean the font loaded — check the geometry.
- **#32 — `read(2)` needs a deadline.** `SIGWINCH` will not break it (.NET uses
  `SA_RESTART`) and neither will `ESC`. Use `poll(2)`, not `VMIN`/`VTIME`.
- **#33 — `Conflicts=` is transaction-time, `Condition…=` is run-time.** Start a
  cmdline-gated unit with `systemd.wants=`, never with `[Install]`.
- **#34 — QEMU's `send-key` holds a key for 100 ms by default**, so keys sent
  faster overlap and all but one are lost. Set `hold-time` and leave more than
  that between calls.
- **#35 — `-cdrom` makes the live medium a ROM device**, invisible to an
  installer's disk list — so "the setup medium is refused" cannot be tested with
  it. Attach the ISO as a block device, which is also how a USB install looks.
- **`pwsh --version` is not a health check.** The banner, `Import-Module` by
  path and `Get-Command` are compiled into the binary and succeed while the
  whole on-disk module tree is unusable.

And the rule the whole episode argues for:

> **A diagnostic must not depend on the subsystem it is diagnosing.**

Three diagnostics broke that rule; two produced a confident but **false** "the
directory is empty" reading that sent the investigation after a filesystem bug
that did not exist. Filesystem facts come from `bash`; PowerShell facts use pure
.NET.

S3 added its sibling, and it is just as expensive:

> **A diagnostic must be checked against the thing it claims to check.**

The S3 script asserts that the generated initramfs can really unlock and import.
It reported `MISSING conf/conf.d/cryptroot` on an image that was perfectly fine:
that is the pre-2.x path, and `/lib/cryptsetup/functions` sets
`TABFILE=/cryptroot/crypttab` at initramfs stage. The check now uses the real
path **and prints what the initramfs actually contains**, so a wrong expectation
shows as a mismatch instead of a verdict. Keep that assertion — it is the
difference between "the boot failed" and "the boot failed *because the unlock
config never made it in*", and it costs seconds instead of a boot cycle.

## 5. Verifying a built ISO — the fast way

Do **not** drive the boot over QEMU's serial console by hand. Bytes sent faster
than the console consumes arrive corrupted, and PSReadLine's rendering makes
capture worse; several attempts produced garbage. `installer/spikes/run-s3.py`
shows what it takes to do it reliably anyway (BUILD-NOTES #16) — read freely,
type one character at a time, re-send a step whose acknowledgement never
arrives, and answer the terminal's queries.

For everything that is not "does it boot", mount the squashfs and run the
image's own binaries — fast, clean, quotable:

```bash
docker run --rm --privileged --platform linux/arm64 -v "$PWD/out":/iso os7-build:arm64 bash -c '
  mkdir -p /mnt/iso /mnt/sq
  mount -o loop,ro /iso/os7-arm64.iso /mnt/iso
  mount -t squashfs -o loop,ro /mnt/iso/casper/filesystem.squashfs /mnt/sq
  # inspect /mnt/sq, or run /mnt/sq/opt/microsoft/powershell/7/pwsh directly
'
```

## 6. Open items not decided anywhere

- **The live ISO and the setup ISO are the same image, and that now looks
  settled rather than undecided.** One medium carries two GRUB entries — *Install
  OS/7* (which sets `os7.setup=1` and `systemd.wants=os7-setup.service`) and a
  plain live session — and `run-phase1.py live` is the regression test that the
  second one stays a live session. Nothing has argued for two images since.
- ~~**dash-to-panel / ArcMenu have no GNOME 50 build** in the resolute archive, so
  the "familiar desktop" goal is unmet on amd64. Hook 0070 logs the gap.~~ —
  **CLOSED 2026-08-25, from the other side.** They are still absent, and always
  will be for some window after each generation: a third-party Shell extension
  chases GNOME, it does not ship with it. The taskbar and start menu now come
  from **GNOME's own Classic extensions** (`window-list`, `apps-menu`,
  `places-menu`, `user-theme` — all `50.0-1`, all `Depends: gnome-shell (>= 50~),
  (<< 51~)`), which Ubuntu updates together with `gnome-shell` 50.1. Hook 0070
  is replaced by `0090-desktop-theme-verify.hook.chroot`, which verifies instead
  of recording. The desktop also carries OS/7 Classic, a Windows 2000 theme. Its
  **GTK half is measured from rendered pixels** (`build/testing/render-theme.sh`);
  its ~~**GNOME Shell half — panel, taskbar, black desktop — has never been
  seen**, because that needs a session and no amd64 ISO has been built with
  it.~~ **SEEN 2026-08-30**, on a machine `os7lab.py install gui --mode Gui`
  produced and a session logged into through the HID keyboard and tablet:
  `.vm/gui/shots/` holds the greeter (OS/7 blue, the OS/7 mark, no Ubuntu
  orange), the desktop (panel with Apps and Places, window-list taskbar along
  the bottom, black desktop, Home icon) and the Apps menu opened BY MOUSE,
  listing Microsoft Edge, Files, Terminal and Microsoft Intune in the classic
  grey. What was missing was never the ISO — it was a way to log in and look.
  [SESSION-CLASSIC-DESKTOP.md](SESSION-CLASSIC-DESKTOP.md) §7 lists exactly what
  that leaves unproven.
- **D8/L16 — `/etc/os-release` identity.** D8 is *decided* (`IMAGE_ID` /
  `IMAGE_VERSION`, leaving `ID` alone for Intune) but **nothing writes it yet**,
  so the GRUB menu entry is still titled from `PRETTY_NAME` and reads "Ubuntu
  26.04 LTS". It belongs to Phase 3, which is the phase that configures the
  installed system.
- **`/var` mounts via `zfs-mount.service`, not `zfs-mount-generator`.** It
  worked in S3, and the datasets all landed on their real mountpoints with no
  altroot leakage — but there is no `zfs-list.cache`, so ordering under load has
  not been tested. Phase 2 created many more `rpool/DATA` datasets than S3 did,
  which makes this more worth checking, not less.
- ~~**No TPM2 enrolment in the installer.**~~ **Wrong since Phase 3, and
  MEASURED for the first time on 2026-08-25.** `TpmEnrolStep` exists, it runs,
  and on a VM with a TPM attached it enrols correctly: `New TPM2 token enrolled
  as key slot 1`, sealed to PCR 7, with the handler and the libtss2 libraries in
  the initramfs. What it did *not* do was unlock the disk, because the handler
  asked for `/usr/lib/systemd/systemd-cryptsetup` and resolute has it at
  `/usr/bin/` — an early `exit 0` that is indistinguishable at boot from a
  machine with no TPM. BUILD-NOTES #64;
  [SESSION-BOOT-ENVIRONMENTS.md](SESSION-BOOT-ENVIRONMENTS.md).

## 7. Repo orientation

```
build/config/auto/config          live-build config (DISTRIBUTION=resolute)
build/build.sh                    staging + orchestration; read its comments first
build/config/package-lists/       common packages
build/config/package-lists-{amd64,arm64}/   arch-specific
build/config/hooks/               common hooks, FLAT (see trap #13)
build/config/hooks-amd64/         amd64-only hooks
build/lib/efi-remaster.sh         neither arch gets a usable bootloader from
                                  live-build; this makes the ISO boot (both)
powershell/OS7/                   the OS7 module - ONE source of truth, staged by build.sh
installer/SETUP-PLAN.md           the installer design and decisions. Authoritative.
installer/src/OS7.Setup/          os7-setup itself. SETUP-PLAN is its design.
installer/assets/                 the systemd unit
installer/testing/                the VM harness: vmconsole, vmscreen,
                                  run-phase1, run-phase2
build/lib/build-console-font.sh   Fixedsys TTF -> two PSFs, asserted (S1)
build/lib/psf.py                  the subset table, the fixes and the guard
build/config/includes.chroot/     files copied verbatim into the image
installer/spikes/s1-look/         the S1 painter: renderer, key table, termios
installer/spikes/s2-nativeaot/    the NativeAOT smoke-test project (S2)
installer/spikes/s3-zfs-luks.sh   the proven install sequence (S3)
installer/spikes/s4-tpm-enroll.sh TPM2 enrolment + the initramfs pieces (S4)
installer/spikes/run-s2.sh        S2: build in the container, run in the ISO
installer/spikes/run-s3.py        QEMU harness for S3
installer/spikes/run-s4.py        QEMU harness for S4 (Secure Boot + swtpm)
installer/spikes/vmconsole.py     serial-console driving, shared by both
docs/SESSION-PHASE2-STORAGE.md    what Phase 2 built, and how the disk is checked
docs/SESSION-PHASE1-SETUP.md      what Phase 1 built, and the four things it found
docs/SESSION-S1-LOOK.md           what S1 measured, and the three plan corrections
docs/SESSION-S2-NATIVEAOT.md      what S2 proved, and what the container still needs
docs/SESSION-S3-ZFS-LUKS.md       what S3 proved, and the nine things it depends on
docs/SESSION-S4-SECUREBOOT-TPM.md what S4 proved, and what it deliberately does not
docs/BUILD-NOTES.md               every trap found so far. Read before debugging.
installer/spikes/run-s1.py        QEMU harness for S1 (framebuffer + QMP)
.vm/s1/shots/                     S1 screendumps, as PNGs
.vm/s3/, .vm/s4/, .vm/firmware/   VM state, serial logs, AAVMF (all gitignored)
```
