# Session — boot environments, spike S5, the first TPM enrolment, and a smaller image

**2026-08-25.** Three things were asked for in one sitting and they are related
by one fixture — an installed machine — rather than by subject:

1. **Spike S5**, the last open gate in [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md)
   §10: *does the clone-update-activate-rollback cycle work at all.* With it, the
   boot-environment primitives §4.2 needs (steps 1, 2 and 9).
2. **TPM2 enrolment, actually performed.** `TpmEnrolStep` has existed since Phase
   3 and had never run: every VM so far had no TPM, so the step took its "no TPM
   on this machine" path and every run reported success for a path it never
   entered.
3. **C2 and §4.2 of [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md)** —
   the .NET SDK out, `linux-generic` → `linux-image-generic` — which were decided
   and measured on paper and never built.

---

## 1. Verdict

| | |
|---|---|
| **S5 — does the clone-update-activate-rollback cycle work** | **PASS**, arm64, on a machine `os7-setup` installed. Nine checks, three boots, `hello` present in the clone and gone after the rollback (§5, run 5). The last open gate in [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §10 closes. |
| **The design it took to get there** | **OS/7 writes its own boot menu.** `10_linux_zfs` lists ONE environment per machine without `zsys`, so activation could not have worked on top of it and a rollback could not have been chosen from the console at all ([BUILD-NOTES.md](BUILD-NOTES.md) #67). Four runs to find; §3 and §5. |
| **TPM2 enrolment** | **Performed for the first time, and it does not unlock — for a reason now known exactly.** Token in key slot 1 sealed to PCR 7, handler and libtss2 in the initramfs, `os7-tpm2` ordered ahead of `cryptroot` (read out of the ORDER file, not assumed). `cryptsetup` refuses with *"TPM policy does not match current system state"*: the installer seals against the **installer's** PCR 7, and the installed machine boots through shim, which measures differently. Enrolment belongs on first boot ([BUILD-NOTES.md](BUILD-NOTES.md) #69), which is why spike S4 worked. Three separate bugs were fixed on the way to that sentence (#64, #66, and a busybox `sed` dialect). |
| **C2 / §4.2 — the image** | **DONE and measured on a booted machine.** 554 → 518 packages, −1 089.3 MiB installed, −300 MiB on the ISO, and the prebuilt ZFS module survived the kernel swap. The first attempt at the kernel half changed nothing at all and the build was green (#62). §6. |

---

## 2. What was measured BEFORE any code was written

The design of an activation depends on facts that no document in this repository
held, and three of them are not what a reading of the plan would suggest. A
throwaway probe booted the machine `run-phase3.py` had left behind (ISO
1.0.0.78, arm64) and asked it thirteen questions. The six answers that changed
the code:

**M1 — `10_linux_zfs` is the generator, and `10_linux` emits nothing.**
`grub.cfg` contains the `### BEGIN /etc/grub.d/10_linux ###` marker immediately
followed by its `### END ###`. Every entry comes from the boot-environment-aware
generator, which ships in `grub2-common` (42 690 bytes) and is not something
OS/7 installs.

**M2 — a menu entry decides everything by itself.**

```
menuentry 'OS/7 1.0.0.78, with Linux 7.0.0-30-generic' … 'gnulinux-rpool/ROOT/os7_1.0.0.78_202608251731-7.0.0-30-generic' {
    linux  "/BOOT/os7_1.0.0.78_202608251731@/vmlinuz-7.0.0-30-generic" root=ZFS="rpool/ROOT/os7_1.0.0.78_202608251731" ro boot=zfs
```

The kernel is addressed by a **dataset-qualified path inside bpool** and the root
by `root=ZFS=`. No mount takes part in choosing either, which is why a boot
environment can be booted without being mounted first — and why the entry id
carries the kernel version, so it **must be read out of `grub.cfg` rather than
constructed**.

**M3 — the ESP stub names the boot environment. This is the finding.**
Both `/boot/efi/EFI/BOOT/grub.cfg` and `/boot/efi/EFI/OS7/grub.cfg` contain:

```
search.fs_uuid 070e2a888e6adac8 root
set prefix=($root)'/BOOT/os7_1.0.0.78_202608251731@/grub'
configfile $prefix/grub.cfg
```

So GRUB reads the menu belonging to **exactly one** boot environment, chosen by
a file on the ESP. Nothing in ZFS decides this. An activation that did not
rewrite those two files would change nothing GRUB ever sees — and would have
looked completely correct from inside the running system.

**M4 — `next_entry` is honoured even though `GRUB_DEFAULT=0`.** The generated
menu carries `set default="${next_entry}"` before `set default="0"`, so
`grub-reboot` works today. It is deliberately not used; see M5.

**M5 — the machine mounts with `zfs mount -a`, and there is no mount generator.**
`zfs-mount.service` is enabled and `/etc/zfs/zfs-list.cache/` does not exist. So
every dataset with `canmount=on` and a mountpoint is mounted, and a second boot
environment is not special to anything: its `/var/lib/dpkg` would be mounted
straight over the running system's. The BE children on this machine are
`var/cache`, `var/lib/apt`, `var/lib/dpkg`, all `canmount=on`.

**M6 — nothing else is deciding what boots.** `bootfs` is unset on both pools and
no `com.ubuntu.zsys:*` property exists on any dataset.

Two more, taken at the same time because they belonged to the other two topics:

**M7 — `hello` is installable** on the installed machine against the pinned
archive (`Ubuntu:26.04/resolute`), which is what the S5 cycle uses to make the
two environments genuinely differ.

**M8 — `zfs.ko` is at `/lib/modules/<v>/ubuntu/dkms/zfs/zfs.ko.zst`**, a path
that says DKMS and is shipped by the prebuilt `linux-main-modules-zfs-…` package.
Worth writing down because the obvious location, `kernel/zfs/`, does not exist and
a check looking there reports a missing module on a machine running from ZFS.

---

## 3. What the design became, and the mistake it made first

**Activation is a GRUB-environment operation, not a ZFS one.**

The first design set the ESP stub and stopped, which is wrong in a way that would
have passed a careless test: pointing the stub at another environment changes
*which* `grub.cfg` is read, and both copies are the same file, so the default
entry would still have been the environment that generated it. `10_linux_zfs`
sorts the menu by `last_used` and hands **the running system `date +%s`**, so
whatever is running is first in any menu it generates and no ZFS property can
outrank it.

The default therefore has to be *named*, and the only place GRUB takes a name is
`saved_entry` — which it reads only under `GRUB_DEFAULT=saved`. Hence:

* `BootloaderStep` now writes **`GRUB_DEFAULT=saved`** and names the installed
  environment in `grubenv` at install time. Set at install rather than repaired
  at the first rollback, because the first rollback happens on a machine that has
  just stopped working and that is the wrong moment to be editing
  `/etc/default/grub`.
* `Set-OS7BootEnvironment` repairs it anyway, for machines installed before this
  existed.

**An entry inside a submenu needs its full path.** `10_linux_zfs` emits one
top-level entry per machine-id and files every other environment of that machine
under `History for …` — and the environment being rolled back to is, by
construction, one of those. `saved_entry` must therefore contain
`<submenu id>><submenu id>><entry id>`. The menu is parsed rather than
pattern-matched (`Find-OS7MenuEntryPath`), and the parser tracks `menuentry`
braces as well as `submenu` ones: popping only on submenus lets an entry's own
closing brace close the submenu around it, and every following entry is then
reported at the wrong depth.

**An inactive environment carries `canmount=noauto` on everything that would
mount** (M5), and activation flips the whole pair-tree in one operation. This is
also why **there is no one-shot "boot it once" switch**, even though M4 says
`grub-reboot` would work: an environment booted without being activated gets the
*activated* environment's `/boot` and `/var/lib/dpkg` — precisely the
half-activated pair [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §4.3
forbids.

### The order of an activation, and why

This is the order **after run 3**, which added steps 1 and 2 — see §5.

```
0  GRUB_DEFAULT=saved              or naming a default writes to a file nothing reads
1  WRITE OS/7'S OWN MENU           one entry per environment; the stock generator
                                   emits only one (#67)
2  update-grub                     so the fragment is in the menu that is read
3  FIND THE TARGET'S ENTRY         ← the guard: no entry means no boot
4  flip canmount across all pairs  M5
5  copy the menu into the target's own boot dataset
6  saved_entry into BOTH grubenvs  the running one and the target's
7  rewrite both ESP stubs          M3 — the line that decides which menu is read
8  record com.ubuntu.zsys:last-used
```

Step 3 is the one the ordering exists for, and it earned its place twice: it
refused an activation in run 1 because the clone had no `mountpoint=/` and was not
a boot environment at all, and again in run 3 because the stock generator does not
list a second one. Both times, pointing the ESP at that environment would have
produced a GRUB prompt on a machine that was working a minute earlier.

Step 5 copies rather than regenerating: the generated menu addresses every kernel
by an absolute path inside bpool (M2), so it is correct from whichever
environment reads it.

---

## 4. What was tested without a VM

`pwsh` runs on the Mac, and that turned out to matter more than expected — see
run 2 below. Two layers of check exist now, and neither needs a machine.

**`installer/testing/check-be-logic.py`** runs the real module against a fake
`zfs` and a temporary machine — a grub.cfg with the shape a measured one has, an
ESP stub, an `/etc/default/grub` — and checks what the module actually does:
seven clones with the properties they should carry, nothing created
`canmount=on`, a menu fragment with **one entry per environment**, the template's
`search --fs-uuid` line intact in each, the ESP stub repointed, and
`GRUB_DEFAULT` repaired. Three seconds.

It exists because **six** bugs found on 2026-08-25 would each have cost a
twenty-five-minute VM run to reach, and it caught the last four of them in
minutes. It is explicitly **not** a test of ZFS or of GRUB — the fake models
exactly the behaviours under test (a clone does not carry local properties;
`update-grub` is the grub.d scripts concatenated) and nothing else. `run-s5.py`
is the test of the machine.

Making it possible changed the module slightly and for the better: `/boot`,
`/etc/default/grub`, the ESP stubs and the scratch mount point are `$script:`
variables now instead of literals, so the activation path can be pointed at a
temporary tree. A path that cannot be redirected is a path that can only be
tested by installing a machine.

**And the regexes.** The two that decide everything, and the menu parser, were
tested against **the exact strings the probe brought back**, before the ISO was
built:

* the ESP stub is read and rewritten with its quoting intact
* the entry id is found and its kernel version extracted
* an environment with **no** entry returns nothing (the guard)
* a boot-environment name that is a *prefix* of a real one does not match it
* an environment two submenus deep gets the full `>`-joined path

That last one is the case that only exists when there are two boot environments,
which is to say the case no machine in this repository had ever been in.

---

## 5. The runs

Three, and the first two are worth keeping because each found something that the
next could not have found. Every one is `./installer/testing/run-s5.py`, arm64,
against an ISO built from this tree.

### Run 1 — the guard did its job

The clone was created and `Set-OS7BootEnvironment` **refused to activate it**:

```
Found linux image: … in rpool/ROOT/os7_1.0.0.95_202608251919
Found linux image: … in rpool/ROOT/os7_1.0.0.95_202608251919@os7_1.0.1.0_202608252123
```

`update-grub` listed the origin **snapshot** and never the clone, so the menu had
no entry for it and step 2 threw. `zfs clone` does not carry the origin's local
properties and `canmount` does not inherit, so the clone came out
`canmount=on mountpoint=none`: mountable over the running root and invisible to
`10_linux_zfs`, which finds boot environments by `mountpoint=/`
([BUILD-NOTES.md](BUILD-NOTES.md) #63).

**Without the guard this would have pointed the ESP at a dataset GRUB cannot
boot**, and the next start would have been a GRUB prompt on a machine that had
been working a minute earlier. The step exists for exactly that and it is the
reason this cost a run rather than a machine.

The same run measured TPM enrolment for the first time. It enrolled correctly —
`New TPM2 token enrolled as key slot 1`, sealed to PCR 7, handler and libtss2 in
the initramfs, `os7-tpm2` ordered ahead of `cryptroot` — and the machine asked
for the passphrase anyway. The handler tested
`/usr/lib/systemd/systemd-cryptsetup`; resolute has it at `/usr/bin/`
([BUILD-NOTES.md](BUILD-NOTES.md) #64).

**And one of the harness's own checks was worse than either bug.** "No dataset in
the clone is `canmount=on`" was written as a regex anchored with `$` under
`re.MULTILINE`, against text from a serial console, which ends every line with
CR LF. It never matched, so it never failed, and the clone had three such
datasets. `body_of()` strips CR once for the whole file now, and the check counts
and prints the offending lines instead of testing for absence.

### Run 2 — the fixes hold, and the next layer shows

C2 and §4.2 came out green **on the booted machine**: no .NET SDK, the runtime
present, no kernel headers, `linux-main-modules-zfs` present, `zfs.ko` on disk,
and 19 wireless-driver directories — the same 19 the machine before the swap had.

The TPM handler now ran past its first test and printed, on the console:

```
OS/7 TPM: no os7_root line in /cryptroot/crypttab
```

which is the point of making every `exit 0` say why. The read used
`sed -n 's/^os7_root[[:space:]]\+…'`; the initramfs's sed is busybox's and `\+`
is a GNU extension. It is a `while read` loop now, which has no dialect.

And `New-OS7BootEnvironment` died after its snapshots with

```
Cannot convert value "mountpoint" to type "System.Int32"
```

— `$from` is `$From`, the `[string]` parameter ([BUILD-NOTES.md](BUILD-NOTES.md)
#65). That one is three lines of decision logic and it took twenty-five minutes
of VM to reach, which is why `installer/testing/check-be-logic.py` now exists:
the real module, a fake `zfs`, three seconds, and it finds both that bug and the
`.Value`-of-a-collection one beside it.

### Run 3 — the design breaks, in the one place a spike is for

The two fixes held: the clone came out with `mountpoint=/` and `canmount=noauto`
on every dataset, `zfs mount -a` moved nothing, `hello` went into the clone and
not into the running system, and the pair was assembled and taken apart cleanly.
The image checks were green on the booted machine — no .NET SDK, no headers, the
ZFS module present, 19 wireless-driver directories, the same 19 as before.

Then the activation refused again, and this time the guard was right for a reason
the whole design had assumed away:

```
Found linux image: … in rpool/ROOT/os7_1.0.0.95_202608252004
Found linux image: … in rpool/ROOT/os7_1.0.0.95_202608252004@os7_1.0.1.0_202608252207
Found linux image: … in rpool/ROOT/os7_1.0.1.0_202608252207     ← the clone WAS found
OperationStopped: the menu has no entry for rpool/ROOT/os7_1.0.1.0_202608252207
```

**`10_linux_zfs` emits entries for exactly one boot environment per machine-id
unless `zsys` is installed** — its whole `history` section is gated on it — and
the running environment always sorts first because the generator hands it
`date +%s`. So a second environment can never appear in a menu generated from the
first, and *everything* the design had built on top — the ESP stub, `saved_entry`,
the submenu path parser — is correct and cannot help, because none of it can point
GRUB at an entry that is not in the file. [BUILD-NOTES.md](BUILD-NOTES.md) #67.

**OS/7 therefore generates its own menu**: `Set-OS7BootEnvironment` writes
`/etc/os7/grub-boot-environments.cfg` and a two-line
`/etc/grub.d/09_os7-boot-environments` that emits it, with **one entry per
complete environment, built by substitution into the running one's entry**. That
is not only what makes activation possible; it is what makes a rollback possible
from the console at all. With the stock generator the menu holds only the active
environment, so an environment that fails to boot leaves the operator no way to
choose the other one — and a rollback that requires a working system is not a
rollback.

This is what the spike was for. The design was measured, unit-tested, and wrong
in a way that only a machine could show.

### Run 4 — the machine boots the clone

The menu, read off the framebuffer at the reboot:

```
  OS/7 1.0.0.95  os7_1.0.0.95_202608252028
* OS/7 1.0.1.0  os7_1.0.1.0_202608252231      ← the default, from saved_entry
  OS/7 1.0.0.95                               ← 10_linux_zfs's single entry
  Advanced options for OS/7 1.0.0.95
  UEFI Firmware Settings
```

The first two are OS/7's, and the second one is the one that could not exist
before. Seven of the nine checks passed, including the one the spike is named
for:

```
ok  1/9  Get-OS7BootEnvironment sees the installed environment
ok  2/9  cloned: os7_1.0.1.0_202608252231
ok  3/9  the clone is inert: nothing of it mounted itself
ok  4/9  the clone is assembled at /mnt/be
ok  5/9  the clone has the package and the running system does not
ok  6/9  the ESP stub and grubenv name os7_1.0.1.0_202608252231
ok  7/9  THE MACHINE BOOTED THE CLONE — / is os7_1.0.1.0_202608252231
ok       /boot and /var/lib/dpkg are the CLONE's, not the old pair's
ok       hello is installed here — the change came with it
```

`Restore-OS7`, given no argument, then named the right environment on its own —
"rolling back to the previous boot environment: os7_1.0.0.95_202608252028",
which is §6's "the panic path is one word" — and refused:

```
no menu entry for rpool/ROOT/os7_1.0.1.0_202608252231 to use as a template.
The running system has no entry of its own.
```

**True of the id shape, false of the menu.** After the first activation the
running environment is one OS/7 created, so `10_linux_zfs` has no
`gnulinux-<dataset>-…` entry for it and its only entry is OS/7's own
`os7-be-…`. `Find-OS7MenuEntryPath` had been taught both shapes; the template
lookup beside it had not. One function, one line — and `check-be-logic.py` now
performs the **second** activation as well, because a check that activates once
passes while a rollback cannot run at all.

### Run 5 — the cycle closes

```
ok  1/9  Get-OS7BootEnvironment sees the installed environment: os7_1.0.0.95_202608252045
ok  2/9  cloned: os7_1.0.1.0_202608252248
ok  3/9  the clone is inert: nothing of it mounted itself
ok  4/9  the clone is assembled at /mnt/be
ok  5/9  the clone has the package and the running system does not
ok       activation mounted nothing of the target
ok  6/9  the ESP stub and grubenv name os7_1.0.1.0_202608252248
ok       the machine powered off cleanly
ok  7/9  THE MACHINE BOOTED THE CLONE — / is os7_1.0.1.0_202608252248
ok       /boot and /var/lib/dpkg are the CLONE's, not the old pair's
ok       hello is installed here — the change came with it
ok  8/9  Restore-OS7 chose os7_1.0.0.95_202608252045 and the ESP stub names it
ok       the machine powered off cleanly
ok  9/9  THE ROLLBACK TOOK — / is the original environment again
ok       hello is gone: the rollback un-said the change
ok       both environments are still there and both are complete
```

`cycle PASS`. Three boots of one machine, two of them into an environment chosen
by `Set-OS7BootEnvironment`, and the third back again after `Restore-OS7` was
given no argument at all.

**S5 is answered.** The clone-update-activate-rollback cycle works, on arm64, on
a machine `os7-setup` installed, with the change visible in `/var/lib/dpkg` on
the way out and gone again on the way back.

---

## 6. The image — what C2 and §4.2 actually cost

Two decisions from [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md)
were built here because the S5 machine had to be installed from a fresh ISO
anyway: **C2** (the .NET SDK leaves, the runtime stays) and **§4.2**
(`linux-generic` → `linux-image-generic`). They were made in **two separate
builds**, which turned out to matter.

| | packages | ISO |
|---|---|---|
| before (1.0.0.78 / 1.0.0.95 as built) | 554 | 2 149 740 544 |
| after C2 alone | 548 | 2 008 494 080 |
| after §4.2 as well | **518** | **1 835 249 664** |

**−36 packages, −1 089.3 MiB installed** (priced against the pinned archive's own
`Installed-Size` fields), **−300 MiB on the ISO**.

### The first attempt at §4.2 removed nothing, and the build was green

Editing `os7-base.list.chroot` from `linux-generic` to `linux-image-generic`
changed the shipped manifest not at all: both metapackages and all three header
packages were still in it. **Live-build installs a kernel of its own**, beside
the package lists, and in `--mode ubuntu` the value it derives is `linux` against
flavour `generic`. The fix is `--linux-packages "linux-image"` in
`build/config/auto/config`, read back out of the generated `config/chroot` the
way BUILD-NOTES #36 requires of every other flag. Full note:
[BUILD-NOTES.md](BUILD-NOTES.md) #62.

**This is only visible because two manifests were diffed.** The build exited 0,
`check-image.py` was green — it had nothing to say about kernel packages at the
time — and every number in the plan was a correct statement about a dependency
graph that was not the thing deciding.

### And the 216 MiB of llvm belonged to the kernel, not to .NET

The plan attributed `libllvm21`, `libclang-cpp21` and `libclang1-21` — 216.0 MiB
— to `dotnet-sdk-aot-10.0`, which the SDK Recommends. The two builds separate the
question cleanly:

* build 1 removed the SDK **including `dotnet-sdk-aot-10.0`**, and all three llvm
  packages were still there;
* build 2 stopped `linux-generic` being installed, and all three left.

They came in behind `linux-generic` Recommends `linux-tools-<abi>-generic` and
`ubuntu-kernel-accessories`, which reach `bpftrace`, which links LLVM. The size
was right and the cause was wrong — and the same chain brought `linux-perf`,
`bpftool`, `bpfcc-tools`, `libc6-dev` and the C development headers.

### What is asserted from now on

`check-image.py` gained six assertions against the shipped manifest: no
`dotnet-sdk*`, the .NET runtime present, no `linux-headers*`, no `linux-generic`,
`linux-image-generic` present, and **`linux-main-modules-zfs-*` present** — the
one that decides whether a machine with this kernel can mount its own root. All
six are green, and `run-s5.py boot` asks a booted machine the same questions.

---

## 7. What this leaves

**Everything here is arm64, in QEMU.** No amd64 machine has ever run any of it,
for the same reason as every other result in this repository: there is no
harness that can drive an x86_64 machine here (HANDOFF §2, §3).

**`Update-OS7` is still a stub, and now for a different reason.** It is no longer
waiting on boot environments; it is waiting on there being an OS/7 release to
apply. There is no package repository, no signing key and no release index
([CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) C7, C7a). Until
that exists it could only apply plain Ubuntu updates and call them an OS/7
release, which §5 of that document says is worse than no version number at all.
§4.2's steps 3 to 8 — assemble the clone, point it at the new archive, apply,
re-assert os-release, rebuild the initramfs, regenerate the menu — were performed
by hand in `run-s5.py` and belong in that cmdlet when there is something to
point them at.

**A new KERNEL in the clone is untested.** The release plan's S5 asks for
`apt full-upgrade` against a pinned snapshot; against the snapshot the machine
was built from that is a no-op, so the change applied here is one small package.
The pair hazard §4.3 describes is at its sharpest when the two halves hold
different kernels, and that case is still only reasoned about.

**The window between activation and the reboot is real.** Activation sets the
target's datasets to `canmount=on` while the old environment is still running, so
anything that runs `zfs mount -a` in that gap would mount the target's
`/var/lib/dpkg` over the running system's. It is inherent to §4.2, whose step 10
is "reboot on the operator's schedule"; what is asserted is the narrower claim
that activation does not trigger it itself. Closing it properly means making the
mounts belong to the environment rather than to the pool — `mountpoint=legacy`
plus an `/etc/fstab` line per environment — which is a change to the layout
Setup creates, not to these cmdlets.

**`Remove-OS7BootEnvironment` has never destroyed anything on a machine.** It
refuses the running environment and the one the ESP names, and that is all that
has been exercised. Retention policy — how many environments a machine keeps —
is not decided anywhere (CURATION-AND-DELIVERY-PLAN open question 5).

**There is no one-shot "try this environment once".** `grub-reboot` would work —
`next_entry` is honoured whatever `GRUB_DEFAULT` says, measured — but an
environment booted without being activated gets the activated one's `/boot` and
`/var/lib/dpkg`. Offering it would mean offering the half-activated pair §4.3
forbids.

**U8 is untouched.** The escrowed recovery passphrase that unattended
re-enrolment needs after a Secure Boot policy change is still a key-management
design and still open.
