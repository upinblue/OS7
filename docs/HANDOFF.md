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
| PowerShell | **Works.** Login lands at `PS /home/…>`, on the live ISO and on the installed system. `Import-Module OS7` resolves by name and exports all five functions — `New-OS7Storage` and `New-OS7BootEnvironmentName` are real and are what `os7-setup` calls; the other three still throw by design. `bash` is still the login shell; `pwsh` is deliberately *not* in `/etc/shells`. |
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
| `./installer/testing/run-backup.py` | **New, and never executed.** The tier-2 gate for the backup feature: builds two file-backed pools in a booted VM, enables the policy, snapshots, replicates to the second pool, ruins a file and restores it — with every assertion asked of ZFS or the filesystem. `all` is the gate BACKUP-PLAN B-5 names. It is `qemu-system-aarch64 -machine virt,accel=hvf` like every other harness here, so it needs the Apple Silicon host. |

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

**`Update-OS7` IS WRITTEN (2026-08-27) AND HAS NEVER RUN ON A MACHINE. THAT IS
THE FIRST THING TO DO ON THE MAC.** The update train is the §4.2 sequence as C10
corrects it, in `powershell/OS7/OS7.Update.ps1`, with `Get-OS7Release`,
`Set-OS7UpdateChannel` and `Test-OS7Update` beside it. It is checked without a
VM and the gate has not been run:

```bash
./installer/testing/check-update-logic.py    # ~3 min, no VM — GREEN
./installer/testing/check-ps-traps.py        # seconds — GREEN
./installer/testing/run-s5.py all            # THE GATE. Needs the Mac. NOT RUN
```

`run-s5.py` already installs a machine, clones its boot environment, changes the
clone, boots it and rolls back — steps 3 to 8 **by hand**, because the cmdlet did
not exist. Pointing it at `Update-OS7` instead is what turns "a machine updated
by this cmdlet boots" from a claim about code into a measurement.
[SESSION-UPDATE-TRAIN.md](SESSION-UPDATE-TRAIN.md) is what was decided, what was
found and — at greater length — what was not checked.

**Writing it found four defects, three of them already in the tree**, which is
the argument for the two no-VM checks above: BUILD-NOTES **#89** (the kernel
picker chose the older kernel, and only an update could ever reveal it), **#90**
(a freshness check that could not read its date, and warned), **#91**
(`@('a', $b, $c + $d)` is four elements) and **#65 twice**.

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

What that leaves, in order:

1. ~~**`Update-OS7`**~~ and ~~**`Get-OS7Release -Available`**~~ — **both written
   2026-08-27**, above. What they leave is the gate.
2. **Switch the ISO over.** `build.sh` still stages the same files through
   `includes.chroot`, so the packages are correct and the image does not use
   them. That change resolves the one seam this left, which
   [SESSION-OS7-REPOSITORY.md](SESSION-OS7-REPOSITORY.md) §5 names: two
   `release.json` files, one authored by the release and one measured from the
   image.

**C7a is still open and was kept open on purpose.** The repository is signed by
a development key whose user ID reads `NOT FOR RELEASE` and which the descriptor
declares as such. Where a release key lives and who holds it is a decision to
make deliberately, not on the day the first repository is published.

**And this box can run KVM after all.** `docker run --device /dev/kvm` on the
x64 Windows host gives `query-kvm → {"enabled": true}` — no elevation, no
Hyper-V by hand. Every harness here is still `qemu-system-aarch64` and would
need an x86_64 arm, so §3's blocker is now a **port** rather than an
impossibility. See [../CLAUDE.md](../CLAUDE.md).


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
and — at greater length — what was not. Note that this box cannot run
`run-phase3.py`: the harnesses are `qemu-system-aarch64 -machine virt,accel=hvf`
and need the Mac, so the amd64 VM work is Hyper-V by hand.

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

**#74 IS WRITTEN AND UNVERIFIED, AND IT IS THE FIRST THING TO RUN ON THE MAC.**
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
  its **GNOME Shell half — panel, taskbar, black desktop — has never been seen**,
  because that needs a session and no amd64 ISO has been built with it.
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
