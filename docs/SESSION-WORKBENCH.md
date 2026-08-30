# Session — a machine you can sit at: the workbench, and the three defects it found in its first hour

**2026-08-30, on the x64 Windows host.** No Mac took part, so everything below
is amd64 and the arm64 half of it is written but unrun.

The testing here was all one shape. Every `run-*.py` and `check-*.py` is a
batch: a Python process opens QEMU's stdio, walks a fixed script, and the
machine dies with the process. That is the right shape for a gate — `run-s5.py
all` must be one sitting or it proves nothing — and it is the wrong shape for
the other half of testing, which is *sitting at a machine and asking it
things*. Under the batch shape, "what does `Get-OS7BackupStatus` actually print
on a real install" costs a boot, and with no disk lying around it costs the
25-minute install that makes one.

So the question this session was given was how to test OS/7 properly on this
box: start a VM, install, then **operate** it — see what every function
actually prints on a booted system, and exercise updates and rollback on a real
machine.

---

## 1. What was built

| | |
|---|---|
| `installer/testing/os7lab.py` | the workbench: a VM that outlives the process that started it |
| `installer/testing/run-surface.py` | every cmdlet typed at that machine, with what came back |
| `.claude/skills/os7-lab/SKILL.md` | how to use it, so a later session does not rediscover the traps |

**Nothing existing was edited.** `check-vm-arch.py` holds the other harnesses'
arm64 command lines byte-identical to the pre-port construction and no Mac is
available to re-measure them, so the bench builds its own command line beside
theirs out of the same `vmarch.py` facts. `run-s5.py`, `run-phase3.py` and
`shoot-manual.py` are untouched.

### The three channels, and why there are three

Each presupposes more of the machine than the last, so **which channel answered
is part of the answer**.

* **The serial line** presupposes a kernel. The only channel before the first
  login — the initramfs passphrase prompt, `os7-setup`, a machine with no
  network — and the only one that can watch a boot fail.
* **SSH** presupposes network, sshd, PAM and an account. In exchange: a real
  exit code, stderr apart from stdout, and no quoting limit at all, because
  the script goes over as `-EncodedCommand`. `run-s5.py`'s `ps()` must *refuse*
  a single quote; this does not.
* **QMP** presupposes only QEMU. Screendump and input — so the GUI, which on
  amd64 is the product and which HANDOFF §6 records as never having been seen.

### The one mechanism worth reading

Detaching costs a harness QEMU's stdio, and `-serial tcp:…,server,nowait`
alone throws away everything printed before something connects — which is the
whole boot. So the chardev carries **both**: `logfile=` records every byte from
power-on whether anyone is listening or not, and the socket is how bytes get
in. **Reads come from the file, writes go to the socket**, and a disconnect
loses nothing. `os7lab.py console <bench> --read` works on a machine that is
no longer running.

### Snapshots, which are why the bench is cheap

**0.6 s to take, 0.7 s to restore** — measured, amd64, a 5 GB qcow2. Against
25 minutes for the install that produced the disk.

A snapshot is **three things**: the disk (`qemu-img snapshot -c`), the firmware
variables and the TPM state, taken together with the VM stopped. Restore puts
all three back. Proof that it is a real rollback and not a hopeful one: host
keys and `~/.ssh` created *after* a snapshot were gone after restoring it.

---

## 2. What was measured

* **The bench works end to end on this host.** `up` → detached container,
  deterministic ports; `console --read` showed the boot minutes after it
  happened; `login` walked initramfs → login → PowerShell → bash and installed
  a key; `exec 'Get-OS7Version | Format-List'` returned the full object and
  `exit 0` in under a second; `shot` produced a 1280×800 PNG of tty1 with the
  branded `/etc/issue`.
* **`run-surface.py` ran 77 read-only functions in one pass.** The machine
  reported **194 functions in 6 modules** — the same number
  `POWERSHELL-REFERENCE.md` records, so all six modules reached the image.
  Outcomes: **46 ok, 12 empty, 12 needs-args, 6 refused, 1 error**. Full text
  per function in `.vm/<bench>/surface/`, summary in `docs/SURFACE-MATRIX.md`.
* **HID input reaches the guest**, verified from a screendump rather than from
  a return code.

---

## 3. Three defects in the product

Each has its own BUILD-NOTES entry; this is what they are and how they were
reached.

**#117 — the build host's filesystem decided the shipped permissions.**
`ls -la /etc/ssh` on the booted machine showed `drwxrwxrwx`, and the trail led
back past the installer to the ISO: **27 world-writable paths** in the shipped
squashfs of 1.0.0.159, among them `/usr/lib/systemd/system` and
`/usr/lib/systemd/system-generators` — a local user can drop in a unit or a
generator and systemd runs it as root. Cause, measured inside the build
container: Docker Desktop presents the Windows bind mount as `0777`, `cp -a`
preserves that, and live-build copies the tree verbatim. A native mount carries
real modes, so **the Mac never produced this image**; amd64 ISOs have only been
built on Windows since 2026-08-28. Fixed by declaring the modes in `build.sh`
and `build-os7-packages.sh` instead of inheriting them, and held by two new
checks in `check-image.py` — both of which were **red against 1.0.0.159 before
the fix existed**.

**It took two builds, and the second one is the interesting half.** The first
fix covered `config/includes.chroot` and took the count from 27 to **2**. The
two survivors — `/usr/lib/os7/migrations/README` and the installer binary
`/usr/lib/os7-setup/os7-setup` — came from the package staging, and they showed
that the cause is more general than "`cp -a` copies the mount's modes": the
staging directory ITSELF sits on the mount, so a file `dotnet publish` creates
there is 0777 as well, with nothing having copied it from the host. That is
also why `[[ -x "${dst}/os7-setup" ]]` proves nothing on this host and the
binary now gets an explicit `chmod 0755`. `pkg_finish` normalises files that
are EXACTLY 0777 — the mount's invention — and leaves anything a deliberate
chmod set. **The third ISO measures 0**, and the whole `check-image.py` run is
green.

**#118 — no installed machine can accept an SSH connection.**
`/etc/ssh/ssh_host_*` does not exist, so socket-activated `ssh.service` dies on
every attempt with `no hostkeys available -- exiting`. `sshd-keygen.service`
exists and is enabled; its status is `inactive (dead)` with
`ConditionFirstBoot=yes was not met` — **#33 in its quietest form**, an enabled
unit whose condition fails is not a failure, it is silence. `os7-setup` does
its half right (it writes an empty machine-id, and the ISO carries one too), so
why the installation's first boot did not count as a first boot is open. What
was green while this was true: `check-ssh-login.py`, which runs a real sshd
against a **container** built from the ISO. #93 said a container from an ISO is
not the ISO; this extends it — it is not the installation either.

**#119 — `(collection | Select-Object -Last 1).Property` under
`Set-StrictMode`.** An empty collection makes that `$null.Property`, which
throws, and the empty case is a fresh install: no replication targets, no
snapshots, no history. `Get-OS7BackupStatus -SkipTargets` came back `error` —
the single `error` in 77.

**And it was already diagnosed.** #112, written the day before, names the same
two lines, explains StrictMode correctly, and ends "the fix is to take the
value in two steps". Nothing had been changed. So this is not a subtle
recurrence: a defect stayed shipped with its own diagnosis sitting in the
repository beside it, and what found it again was a tool that asked a machine
instead of a person re-reading the note. It was also **already visible in a
shipped document** — `docs/manual/transcripts/92-backup-status.txt`, the
manual's own picture of this cmdlet, is not output, it is the exception. The
manual shipped a screenshot of the defect and nothing read it back.

Fixed 2026-08-30: the four optional-collection sites take the selection in two
steps, and the nine `Get-ZfsProperty … .Value` sites became one private helper
so the idiom itself is gone rather than its instances. Verified on a booted
machine — `os7lab.py push` of the fixed module, then the cmdlet returning a
status object and `exit 0`. `Test-OS7Backup` was 63 green before and after and
could not have shown it.

---

## 4. One defect in the harness, and it is instructive

**A qcode is a key position, not a character.** `os7lab type manual
"os7lab-hid-test"` put `os7labßhidßtest` on the screen. The keystrokes were
perfect; the machine has `keyboard: de` from this repository's install plans,
and `minus` is where `ß` lives on a German keyboard. `os7lab.py` now carries a
layout table, **verified against the machine** (`test-de_layout:5/8(x)` typed
and read back off a screendump) rather than copied out of a keymap file.

`run-phase3.py`'s five-entry `QCODE` table has the same exposure and is correct
only while the guest is still on US layout — which it is during Setup, and is
not afterwards.

### And three in this session's own code, all of one kind

Recorded because they are the same mistake in three costumes: **a diagnostic
that reports something it did not measure.**

* Terminal-query replies were sent from `expect()`'s poll loop instead of a
  thread. A reply that is late is not a reply, it is a keystroke somewhere
  else — six cursor reports went into a password field and the run reached no
  prompt, with nothing saying why.
* The machine's state was derived from the log. The log holds *every* boot the
  bench ever had, so it found a `login:` from an hour ago and typed a user name
  into a bash that had been sitting there since. `probe_state()` now presses
  Enter and reads who answers.
* `login` printed "the disk unlocked with nothing typed" whenever it found a
  login prompt — on a machine that may have been up for an hour and whose
  passphrase an earlier session typed. It now says that only when *this boot*
  printed no passphrase prompt, and otherwise says the claim is not measurable
  from here.
* **The host's code page decided what the guest was allowed to say, and the
  result was published.** `subprocess.run(text=True)` decodes with the host
  locale — cp1252 on Windows — so the first journal entry carrying an em dash
  killed subprocess's reader thread and `p.stdout` came back `None`. An earlier
  `or ""` guard turned that into an empty string, so the caller saw returncode
  0 and no output, and `run-surface.py` wrote `Get-SystemdJournal | empty` into
  `docs/SURFACE-MATRIX.md` — about a cmdlet whose `.Count` on that same machine
  is **100**. The guard made a crash into silent truncation, which is the worse
  of the two. Fixed with `encoding="utf-8", errors="replace"`; the matrix went
  from 47 `ok` to 48.

That last one is the session's own contribution to the pattern this repository
keeps paying for: **a program reported success and the thing it was meant to
carry did not arrive.** It was found by asking the machine the same question a
second way — `.Count` instead of `Format-List` — which is the only method that
has ever caught this shape.

---

## 4a. What the bench answered once it could install a machine itself

`os7lab.py install` ran end to end on its first attempt — 18 Setup steps, both
pools exported, a serial console given to the amd64 machine, a clean shutdown
and an `installed` snapshot. Three things followed from having a machine whose
first boot had just happened.

**#118 got a much better measurement, and a fix.** On that first boot:

```
systemd[1]: Initializing machine ID from random generator.
first-boot-complete.target … skipped, unmet condition ConditionFirstBoot=yes
sshd-keygen.service        … skipped, unmet condition ConditionFirstBoot=yes
```

systemd initialises the uninitialised machine ID — the first-boot path — and
does not raise the first-boot flag, in the same boot. So it is not that
os7-setup takes the first boot away; the two decisions simply disagree, and
**nothing** gated on `ConditionFirstBoot` runs on this product, `first-boot-
complete.target` included. Fixed by not depending on it:
`os7-sshd-keygen.service` uses `ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key`,
the condition OS/7's own first-boot units already use.

**B-Q1 / #74 is half closed after four days as "FIXED IN CODE … STILL OPEN".**
`Get-OS7Home` on the new machine: `Dataset: rpool/USERDATA/os7admin_8caded3b`,
`OwnDataset: True`, `Agrees: True` — ZFS and `stat(2)` asked separately and
agreeing. The installer half is measured; `Move-OS7Home` is still unverified.
BACKUP-PLAN.md said this needed `run-phase3.py all` and the Apple Silicon host.
It needed a booted machine and a question.

**And one finding with no explanation yet, which is why it has no number.**
The freshly installed machine did NOT unlock itself:

```
Begin: Running /scripts/local-top ...
OS/7 TPM: the TPM would not unlock os7_root - the passphrase still works
```

The initramfs handler is present and says so cleanly, which is #64 behaving.
But **the bench is not a control**: it attaches a virtio GPU, an xHCI
controller, a USB keyboard and a tablet that `run-s5.py` does not, and PCRs 0–7
measure the platform. Whether this is the product or the fixture is one
`--no-gui` install away, and until that runs it would be wrong to call it
either. `run-s5.py boot` remains where the TPM claim is measured.

## 4b. The desktop, seen for the first time

`os7lab.py install gui --mode Gui` built a desktop machine, and a session was
logged into through the HID keyboard and the tablet. docs/HANDOFF.md §6 had
recorded the GNOME Shell half of OS/7 Classic as **never seen**, "because that
needs a session and no amd64 ISO has been built with it". The ISO was not the
missing piece — a way to log in and look was.

`.vm/gui/shots/` now holds:

* **the greeter** — OS/7 blue (`#0057ad`, the Setup field colour), the OS/7
  mark with "up in blue", no Ubuntu orange and no Ubuntu logo. #110 and #111
  are about exactly this screen and were until now asserted only statically,
  out of a squashfs.
* **the desktop** — the panel with Apps and Places, the window-list taskbar
  along the bottom, the black desktop, the Home icon.
* **the Apps menu, opened BY MOUSE** — Microsoft Edge, Files, Terminal and
  Microsoft Intune, in the classic grey.

**And the reason it took two attempts is worth keeping.** The first screendump
came back 640x480 and said "Guest has not initialized the display (yet)" while
`gnome-shell` was demonstrably running and logging about `/dev/dri/card0` AND
`card1`. Two cards: q35 keeps its default VGA adapter unless told otherwise, so
`-device virtio-gpu-pci` had added a SECOND one — mutter drew on one and QMP
photographed the other. `-vga none` is the fix, and the shape of the mistake is
this repository's usual one: **the fixture was wrong and the report about the
product looked convincing.** A session that renders nothing and a session
photographed through the wrong adapter are indistinguishable from the outside.

## 5. What was NOT measured

* **arm64: nothing.** The bench is symmetric by way of `vmarch.py` — host
  process, unix QMP, sibling swtpm — and not one line of that path has run.
* ~~**The desktop.**~~ **SEEN**, see §4b.
* ~~**Mouse input beyond acceptance.**~~ **Proved**, see §4b.
* **Stage 2 of the survey** — the 117 functions that change something. Written,
  unrun.
* **Why #118's first boot was not a first boot.** The machine now carries a
  populated machine-id and the window is gone. Reproducing it needs an install
  plus a snapshot before boot one, which is exactly what the bench is for.

---

## 6. What this changes

The repository's rule is that a diagnostic must not depend on the subsystem it
diagnoses, and that the expensive defects here have one shape: *a program
reported success and the thing it was meant to change did not change.* Three of
the four findings above are that shape again, and none of them was reachable by
the checks that existed — not because those checks are weak, but because they
all ask a **build host** or a **container** about an image. #117 was invisible
because no check asked about a mode. #118 was invisible because the SSH check
runs against a container, where the first boot never happened. #119 was
invisible because the backup self-test never runs the cmdlet on a machine with
nothing in it.

What the bench adds is not more assertions. It is the ability to ask an
installed machine a question that nobody thought to write down in advance —
cheaply enough that asking is the first move rather than the last.

**It does not make findings true.** Looking changes the machine: forty typed
commands later it is not the one that came off the installer, which is #93 in a
new place. Anything that is to count as evidence must still be reproducible by
a harness from a named snapshot. The bench makes findings cheap to *find*.
