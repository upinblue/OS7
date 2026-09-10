# Session: the device manager

**2026-08-27.** A device manager for OS/7 — the thing a Windows administrator
opens first and does not find on Linux. Not a hardware inspector: a translation
of Linux's driver model into the small number of states an admin actually acts
on, with a next step for each.

Everything below was measured on an Apple Silicon Mac, in containers, on
2026-08-27. Nothing here has run on OS/7 hardware, and §7 says exactly which
claims that leaves open.

---

## 1. What was measured, and what it changed

Seven measurements. Every one of them changed a design decision, and four of
them killed an implementation that would have looked correct and been wrong.

### 1.1 `dkms status` has three words and none of them is "failed"

The most important measurement in this session. Three modules were put into
three states in a container (dkms 3.2.2, ubuntu:26.04, aarch64) — one built and
installed, one built and never installed, one whose source **cannot compile**:

```
$ dkms build -m bad -v 3.0 -k 7.0.0-30-generic
Building module(s)...(bad exit status: 2)
Error! Bad return status for module build on kernel: 7.0.0-30-generic (aarch64)
$ echo $?
10

$ dkms status
bad/3.0: added
good/1.0, 7.0.0-30-generic, aarch64: installed
half/2.0, 7.0.0-30-generic, aarch64: built
```

`bad/3.0: added` is **byte for byte** what dkms says about a module nobody has
ever tried to build. Confirmed from the other end by grepping `/usr/sbin/dkms`
for every status string it can emit: `added`, `built`, `installed`. There is no
`failed` and no `broken`.

**So the question "did the rebuild fail" cannot be asked of dkms.** Every piece
of code in this feature asks a different one: *does an `installed` row exist for
the kernel in question?* Absence is the answer. Nothing looks for a bad word,
because there is no bad word to look for.

This is also the whole explanation of the failure mode the feature exists for.
A driver disappears after a kernel update and nothing says so, because the tool
that knows has no vocabulary for it.

### 1.2 `dkms status -k <kernel>` does not filter, and does not answer

The same machine, asked about a kernel it has no builds for at all:

```
$ dkms status -k 9.9.9-99-generic
bad/3.0: added
good/1.0: added
half/2.0: added
$ echo $?
0
```

`-k` dropped the kernel and architecture columns from every row and left three
modules reading `added` — including `good`, which *is* installed for
7.0.0-30-generic. **A gate written as "run `dkms status -k $newKernel` and look
for something wrong" finds nothing here, on a machine where nothing has been
built for `$newKernel` at all.**

`Get-DkmsModule` therefore never passes `-k` to dkms. It parses the plain
output and filters the rows itself.

### 1.3 `built` is not `installed`, and `built` sounds like good news

`half/2.0 … : built` compiled and was never copied into
`/lib/modules/<k>/updates/dkms`. It will not load. The word reads as success.
`InstalledFor` is the only field in this feature that means the driver works.

### 1.4 `dkms autoinstall` partially succeeds and reports one exit code

```
Autoinstall on 7.0.0-30-generic succeeded for module(s) good half.
Autoinstall on 7.0.0-30-generic failed for module(s) bad(10).
Error! One or more modules failed to install during autoinstall.
$ echo $?
11
```

Two modules installed, one failed, one exit code for the run. 21 is the separate
case of no kernel headers. So the exit code names the run and never a module,
and `Invoke-DkmsBuild` re-reads the status per module afterwards and reports
`Installed` from that.

### 1.5 `modprobe -R` fails identically for two different questions

On a machine whose running kernel has no modules directory:

```
$ modprobe -R pci:v00001AF4d00001041sv00001AF4sd00000041bc02sc00i00
modprobe: FATAL: Module pci:v00001AF4d00001041sv... not found in
          directory /lib/modules/7.0.12-linuxkit
```

"There is no module index to consult" and "nothing claims this alias" are the
same exit code and nearly the same sentence. Reading the first as the second
reports **every device on such a machine as having no driver available**, which
is the report that sends somebody looking for hardware faults on a working
computer.

`Resolve-KernelModule` returns `$null` for "could not be asked" and an empty
array for "asked, nothing claims it". They are different values and every caller
has to choose. Making them survive the function boundary needed the comma
operator — see §3.

### 1.6 `ubuntu-drivers` can decline to answer, in prose, on stdout

```
$ ubuntu-drivers list
Your running kernel (7.0.12-linuxkit) requires DKMS modules, and
ubuntu-drivers was unable to determine if Secure Boot is enabled. If you
have SB enabled, you will need to enroll a MOK to proceed... Please use
--include-dkms if you want to proceed.
```

Parsed as a device list that is zero devices, which from this command means "no
better driver exists for anything on this machine". The tool declining to answer
would have become a confident answer of no.
`ConvertFrom-UbuntuDriversDevices` throws on text with no `==` header. An empty
string is still a real empty list — a machine with no proprietary-driver
candidates prints nothing, and that was measured too.

The output format itself was taken from `ubuntu-drivers`' **own source** —
`command_devices()`, its `"%-9s: %s -%s"` and its flag order — rather than
guessed. That is weaker than a recording and is labelled as such in the fixture.

### 1.7 lspci is not the authority; sysfs is

```
$ lspci -mm -vkn
lspci: Unable to load libkmod resources: error -2
Slot:   00:01.0
...
Driver: virtio-pci
```

Exit code 0, `Driver:` present, and **every `Module:` line — the half that says
which drivers *could* handle a device — silently absent.** pciutils is also a
package, and a minimal image does not have it. `/sys/bus/pci` is the kernel
itself and needs nothing installed.

So devices are enumerated from sysfs. `pci.ids` is used only for the human name,
which is cosmetic and allowed to be missing (`usb.ids` is not shipped by
`usbutils` on resolute at all — `find / -name usb.ids` after installing it finds
nothing; a USB device names itself in sysfs instead, which is better anyway).

### 1.8 And one about USB: the driver binds to the interface

`/sys/bus/usb/devices` holds two kinds of entry carrying different halves of the
answer:

```
usb1      idVendor=1d6b idProduct=0002 driver=usb  (modalias absent)
1-0:1.0   bInterfaceClass=09            driver=hub
```

Read only devices and every USB device reports `driver=usb` — the bus driver,
bound to every USB device that exists, which says nothing. Read only interfaces
and there is no vendor to show. And **a root hub is named `usb1` while its
interface is `1-0:1.0`**, so the obvious prefix join misses exactly the
controllers.

---

## 2. The surface

Six cmdlets, plus one the update train calls.

| | |
|---|---|
| `Get-OS7Device` | The devices that need attention. **`-All` for the rest.** |
| `Get-OS7Driver` | The compiled (DKMS) drivers, and whether each is built for the kernel that matters. Separate because a DKMS module need not have a visible device. |
| `Get-OS7DeviceStatus` | The one-screen report. |
| `Install-OS7Driver` | `ubuntu-drivers install`, wrapped, then asked of dpkg. |
| `Repair-OS7Driver` | The rebuild — and the "module exists and is not loaded" repair. |
| `Send-OS7HardwareProbe` | The only cmdlet in this product that transmits anything to a third party. |
| `Get-OS7DriverRegression` | The comparison `Update-OS7` makes before it activates a boot environment. |

### The default view is the feature

`Get-OS7Device` with no arguments returns **only** what needs attention. That is
the whole product decision. `lspci -k` prints every device in the same weight and
leaves the reader to know which of forty-odd lines matters; Windows Device
Manager expands the branches with a yellow mark and collapses the rest.

The report closes with the line that makes a short page trustworthy rather than
suspicious:

```
  38 devices are working normally.   Get-OS7Device -All
```

### The states

| | |
|---|---|
| `Working` | A driver is bound and nothing better is on offer. |
| `DriverAvailable` | A driver exists that the machine does not have, or has and has not loaded. |
| `NeedsRebuild` | A DKMS driver is not built for the kernel that matters. |
| `NotSupported` | Nothing bound, nothing on offer, nothing in the kernel claims it. |
| `Unknown` | It could not be determined. **Never folded into `Working`.** |

`Unknown` is the fifth and it is not padding. §1.5 is a machine that cannot
answer the question for any device; reporting that machine as healthy is the
failure this repository has paid for most often.

### What the page looks like

```
Hardware      5 devices, kernel 6.14.0-35-generic

  ! Needs a driver rebuild

      Realtek RTL8168                                Network    0000:02:00.0
      r8168 8.053.00 is not installed for 6.14.0-35-generic. It is
      built for 6.14.0-32-generic. This driver will not load until
      it is rebuilt.
      -> Repair-OS7Driver -Name r8168

  ! No driver available

      MediaTek Inc. Wireless_Device                  Bluetooth  3-10
      No driver is bound, and neither the kernel nor Ubuntu's driver
      list has one for it.
      -> Send-OS7HardwareProbe
         https://linux-hardware.org/?id=usb:0e8d-0616

  1 device is working normally.   Get-OS7Device -All
```

---

## 3. The bugs this session's own checks found

Five, and every one of them was found by a check in this repository rather than
by reading the code. Three are entries in `docs/BUILD-NOTES.md` already.

1. **`check-ps-traps.py` found two instances of #65** — a local named after a
   parameter in a different case. `$version` in `Get-HwProbe` **is** the
   `-Version` switch, so assigning a string to it coerced to `$true` and the
   object carried `False` where the version goes. `$before` in
   `Get-OS7DriverRegression` **is** the `-Before` parameter, and the assignment
   replaced the caller's list with a boolean once per loop iteration.

2. **#92, both halves, in `Resolve-KernelModule`.** A PowerShell function
   returning an array unrolls it on the way out: an empty one becomes `$null` —
   collapsing the two answers §1.5 exists to keep apart — and a one-element one
   becomes a **string**, so the caller's `[0]` yields a character. Both were
   live until `Test-HardwareModule` ran. The fix is the comma operator.

3. **#92's other form in the state rule.** `@(…) | Sort-Object -Unique` on a
   one-element list returns a string, and `.Count` on a string under
   `Set-StrictMode -Version Latest` throws — from inside the branch that decides
   a device's state, replacing the state with an exception.

4. **`-Bus ''` fails `ValidateSet`.** `Get-OS7Device` passed its unset `-Bus`
   through to `Get-HardwareDevice`, and an unset `[string]` parameter is `''`
   rather than absent. That is **every ordinary call**. The state-rule half of
   `check-device-logic.py` could never have found it, because that half never
   invokes the cmdlet; the end-to-end half found it on its first run.

5. **A weaker join overruling a stronger one.** When no ubuntu-drivers offer
   matched a device's modalias, the code fell through to matching by sysfs path.
   A device *with* a modalias that matches nothing has been answered — nothing
   is on offer for it — and the fallback belongs only to a device that has no
   modalias at all. Found by a `check-device-logic.py` case that was written to
   test something else and was itself self-contradictory; fixing the fixture and
   the code produced two cases where there had been one.

A sixth, found the same way after the first commit: **nothing tested the write
paths at all.** `check-device-logic.py` read everything and invoked nothing, so
`Install-OS7Driver`, `Repair-OS7Driver` and `Send-OS7HardwareProbe` — the three
cmdlets an operator actually types — had no cover. Seven checks now drive all
three under `-WhatIf`, from the pipeline. The fake that counts write commands
was itself wrong first, reporting that `-WhatIf` had run two: it counted
`modprobe` as a write unless `argv[0]` was `-R`, and `Resolve-KernelModule`
passes `-S <kernel> -R <alias>` whenever a kernel is named, which is every call
`Get-OS7Device` makes for an unbound device. Third time in this feature that a
check found a defect in itself before it found one in the code.

And one design change forced by a check: **`Get-HwProbe` used to run
`hw-probe --version`** to find out whether the tool was present, which meant
`Get-OS7DeviceStatus` — a read-only report an operator might run on a schedule —
executed the upload tool every time. Nothing bad would have happened;
`--version` sends nothing. But the boundary this feature is built around is that
the tool runs when a person runs it, and a boundary with an exception in it is
not one. It looks for the file now.

---

## 4. The update gate

**Feasible, and built.** The question was whether `Update-OS7` could ask about
DKMS in the environment it has just built. It can, and for a reason already in
the update train's design: step 3 assembles the clone with `/dev`, `/proc`,
`/sys` and `/run` mounted, and `Assert-OS7UpdateRootAssembled` refuses to chroot
until the kernel confirms every one of them. A chroot apt can install a kernel
in is a chroot dkms can be asked in. `Get-DkmsModule -Root $root` is the whole
mechanism.

It is **step 6''**, between the migrations and `update-initramfs`:

* after step 5, because the DKMS builds happen there — the kernel package's
  postinst triggers them;
* before step 7, because a module that is not installed is not in
  `/lib/modules`, so an initramfs built first would not carry it and an operator
  who repaired the driver afterwards would be left with an initramfs that
  predates the fix. `check-update-logic.py` asserts that a blocked run reached
  neither `update-initramfs` nor `update-grub`.

**It blocks a regression and warns about anything else.**

| verdict | meaning | effect |
|---|---|---|
| `Regression` | installed for the kernel the machine runs **now**, not installed for the kernel the new environment boots | **refuses** |
| `StillBroken` | was not installed before and is not now | warns |
| `Fixed` | was broken, now builds | reported |
| `Fine` | installed for both | reported |

The distinction is what makes the gate usable. A machine carrying somebody's
abandoned webcam module would otherwise be permanently un-updatable, and the
operator's only route would be the switch that turns the check off — which is
the same as having no check. `-IgnoreDriverRebuild` overrides, and the refusal
names it rather than leaving a dead end.

The refusal also names `/var/lib/dkms/<m>/<v>/build/make.log`, which is the only
place the reason exists: dkms writes the compiler's output there and reports
none of it in its status (§1.1).

A blocked update leaves the environment **built and not activated** — which is
exactly what `-Stage` produces, so the way forward is one that already exists.

---

## 5. hw-probe, and why it is not on the image

`NotSupported` is the one state OS/7 cannot fix. There is no driver; inventing a
suggestion would be worse than saying so. What is useful is that somebody else
may have the same hardware, and linux-hardware.org is where those reports are
collected.

**Decided: hw-probe is not shipped.** It is in Ubuntu universe
(`hw-probe 1.6.5-1build1` in `resolute/universe`, verified), and
`Send-OS7HardwareProbe -InstallTool` fetches it. A managed image aimed at
Intune-controlled fleets should not carry a tool that uploads to a third party
by default, and the arrival of the tool is then itself a deliberate act on a
machine somebody chose.

What makes it an opt-in **mechanically** rather than in a paragraph:

* nothing calls it — not `Get-OS7DeviceStatus`, not `Get-OS7Device`, not any
  health or inventory cmdlet, and `check-device-logic.py` asserts that a status
  run does not invoke the tool even once;
* `ConfirmImpact = 'High'`, so it prompts by default and `-WhatIf` prints the
  destination and sends nothing;
* the tool is absent, and the cmdlet refuses rather than installing it silently;
  `-InstallTool` is a second, separate prompt.

hw-probe's documentation says it hashes or removes serials, MAC addresses,
hostnames and the machine id before uploading. **This session did not verify
that claim and the cmdlet's help does not repeat it as though it had been
checked here.** It is the tool's claim about the tool, and the help says so, and
says that a probe cannot be withdrawn.

---

## 6. Layering

`powershell/Hardware/` is the **sixth** generic Layer-2 module, cut like `Zfs`,
`Net`, `Time`, `Systemd` and `Directory`: it knows sysfs, dkms, modprobe,
ubuntu-drivers and hw-probe, and nothing about OS/7. `check-layering.py` gained
a **sixth** rule, **`P2-hardware`, at a baseline of 0**.

*(It was the fifth of each when this was written. `Directory` landed on the same
day, on another branch, and took fifth — see §9.)*

It did not start at 0. Two sites were found by writing the rule:

* `Repair-OS7Driver` called `Invoke-HardwareCommand -Command 'modprobe'` —
  routing *through* the Hardware module and still deciding, in Layer 3, to run
  modprobe. The invoker pattern in `check-layering.py` was widened to catch that
  shape. The fix is `Add-KernelModule`, which also asks `/proc/modules` back —
  something the inline call did not do, and modprobe exits 0 for a module that
  loads and immediately removes itself.
* `OS7.BackupTarget.ps1` called `udevadm settle`, which predates the rule. Moved
  to `Wait-UdevSettle`; it now carries a timeout rather than udevadm's own 120
  seconds, which is a long time for a cmdlet to block.

`dkms` matters most in that list. The value of this whole feature is that a
module's build state is read **one way, in one place**, because of §1.1 and
§1.2. Two readers of that would eventually disagree, and the one that was wrong
would be the one that said the machine was fine.

---

## 7. What is NOT proven

Read this before quoting anything above as a fact about a computer.

* **No OS/7 machine has run any of this.** No ISO was built this session.
  `Get-OS7Device` has never been run against real hardware, only against sysfs
  trees built from a recorded dump and from a constructed one.
* **The machine this was measured on has no interesting hardware.** Every device
  on it is a virtio device bound to `virtio-pci`. There was no discrete GPU, no
  DKMS-backed device and no unsupported hardware, so the four states could not
  be recorded and the fixture for them says CONSTRUCTED in capitals and lists
  what it does and does not prove.
* **The NVIDIA case has never been seen.** `ubuntu-drivers devices` output for a
  real card is reproduced from the tool's source, not from a run.
* **The gate has never blocked a real update.** `check-update-logic.py` drives
  the real sequence against a fake dkms; `run-s5.py` on a booted machine is
  still what decides, and it needs the Mac.
* **`Test-OS7DeviceNeedsDriver` excuses exactly one PCI class** — 06, Bridge.
  Memory controllers, generic system peripherals and processors also sit
  driverless on real hardware and are **not** excused, because excusing a class
  is how a device manager hides the one device that mattered. Whether that list
  is right can only be decided by looking at real machines. **Open.**
* **The DKMS module name is matched to the bound driver name by string
  equality.** `r8168` registers with dkms as `r8168` and appears in sysfs as
  `r8168`. Where a package's module name differs from the bound module, the
  `NeedsRebuild` state simply does not fire for that device — a miss, not a
  false alarm, and `Get-OS7Driver` still reports the module. **Open.**

## 8. Candidate BUILD-NOTES entries, not written

`docs/BUILD-NOTES.md` had uncommitted work from another session while this one
ran, so nothing was appended to it. That blocker is gone — the note in question
landed upstream under a different number, and by the merge forward on 2026-09-10
the file was at 116 with everything above free. The three findings below are
still not written into it, and are still the kind that file exists for:

* **`dkms status` has no word for a failed build** (§1.1) — the strongest
  instance yet of "a program reported success and the thing it was meant to
  change did not change", because there is not even an exit code to look at
  after the fact.
* **`dkms status -k <kernel>` does not filter by kernel** (§1.2) — a flag that
  changes the shape of the output rather than the rows, and whose obvious
  reading passes a machine where nothing was built.
* **`modprobe -R` gives the same error for "no index" and "no match"** (§1.5).

---

## 9. The merge forward, 2026-09-10

The branch sat unpushed for two weeks while `main` moved **78 commits**. What
came back out of that is worth recording, because most of it is what a feature
branch costs rather than what this feature is.

**Nobody had built a device manager meanwhile.** Checked first, before anything
was merged: no `powershell/Hardware`, no `Get-OS7Device`, no dkms anywhere in
the tree. The work was not duplicated.

**Three numbers had been taken.** `P8` and `P9` — claimed here for the device
manager and for wrapping Ubuntu's detection — were claimed upstream on the same
day for the directory and, two days later, for timers. They are **P10 and P11**
now; the decisions are unchanged and only the number moved. `C13` was still
free. And the fourth commit on this branch was **dropped entirely**: it carried
another session's hook-0070 fix and its BUILD-NOTES entry, both of which landed
upstream independently, with the note under a different number — so `#94` in
this repository is about `TryParseExact`, not about the quiesce hook.

Two branches counting from the last number each could see is not a mistake
either of them made. It is what a numbered list costs when work runs in
parallel, and it is the second time this repository has paid it.

**The delivery mechanism changed underneath the branch.** The PowerShell modules
no longer reach an image through `build.sh` at all — since C7's second half they
are installed from the `os7-module` package, and `stage_ps_module`, the function
this branch called, does not exist any more. What survived the merge was the
module's NAME, and it had to go into **four** lists rather than one: `build.sh`'s
fixture loop, `build-os7-packages.sh`'s package loop, `check-module-parts.py`
and `make-reference.py`. `build.sh`'s own comment had already warned that two of
those lists are held equal by nothing but somebody reading them side by side —
it was written when `Directory` arrived the same way.

**Two traps this module violated did not exist when it was written.**
`check-ps-traps.py` grew from two rules to six while the branch sat, and the
merged code failed two of them at once:

* **#121** — `Invoke-HardwareCommand` read `$LASTEXITCODE` bare. The engine
  rewrites it only when a native command COMPLETES; one that is found and cannot
  be started neither throws nor sets it, so the read is the PREVIOUS command's
  code — zero included. In the one function in this module whose entire job is
  reporting exit codes faithfully. Fixed to the documented
  reset-then-guarded-read.
* **#112/#119** — `Get-HwProbe` read a property off a pipeline that may be
  empty. The `?.` there did guard the null, but the rule is a shape and not a
  case: a scan cannot tell a safe instance of `(… | Select-Object -First 1).X`
  from an unsafe one, and the unsafe form shipped thirteen times and put an
  exception into the manual's own screenshot.

Neither would have been found by re-reading the module. Both were found by
running a check that had been written since.

**What was fixed in passing, and why.** The layer diagram in the manual carried
`Systemd 8` against a module that had grown to 21, and `95` for a product module
at 147. Nothing checks that drawing. Adding a sixth generic layer beside two
wrong numbers would have been worse than adding it beside none, so all three
were corrected together and the box width is now derived from the band rather
than a constant that happened to fit five. `check-module-parts.py`'s headline
regex had `six modules` hardcoded and reported `<no count found>` for a seventh —
a check that breaks when the thing it measures grows is a check that gets
deleted, so it now reads the word and asserts it.

**And the gate held.** `P2-hardware` was written against a tree that no longer
exists and reports **0** against 78 commits of code written after it — the first
time one of these layering rules has been asked about code its author never saw.
`check-update-logic.py` drives step 6″ through the update train as it stands
today, including the credential and `auth.conf` work that landed meanwhile, and
the refusal still lands before `update-initramfs`.

Nothing in §7 became less true. No OS/7 machine has run any of this.
