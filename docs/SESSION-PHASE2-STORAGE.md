# Phase 2 — the storage executor

[../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md) §10 Phase 2:

> Disk enumeration and the plan model; screens 4–6; the executor for
> partition + pool + dataset creation, driven by S3's proven sequence;
> `--unattend` and `--dry-run`. Failure rolls back **only** what Setup created.

**Date:** 2026-08-24 · **Done.** `os7-setup` now writes to a disk: it
partitions, makes the ESP, creates the LUKS2 container, and lays down both pools
and the §4.4 dataset hierarchy. There is still no operating system on the
result — copying the system, the accounts and the bootloader are Phase 3, and
screen 12 says so.

```bash
./installer/testing/run-phase2.py all      # four boots, ~40 minutes
```

```
### Phase 2 result
    dryrun    PASS   every command printed, the disk still blank afterwards
    unattend  PASS   the §4.4 layout, and the passphrase opens the container
    rollback  PASS   a failed step leaves no table, no mapping and no pool
    walk      PASS   screens 4-6 by hand, then the same disk verification
```

- The executor: [`installer/src/OS7.Setup/Steps/`](../installer/src/OS7.Setup/Steps/)
- The ZFS layer: [`powershell/OS7/OS7.psm1`](../powershell/OS7/OS7.psm1) — `New-OS7Storage`
- Screens 4–6: [`installer/src/OS7.Setup/Screens/`](../installer/src/OS7.Setup/Screens/)
- The harness: [`installer/testing/run-phase2.py`](../installer/testing/run-phase2.py)

## What is checked, and how

The deliverable is not a screen, so the harness does not stop at one. Each phase
runs and then **reads the disk back** — `sgdisk -p`, `blkid`,
`cryptsetup luksDump`, `zpool list`, `zfs list` — and compares the answers with
§4.4. Not "the installer said it worked": the installer says that into its own
log, which is precisely the class of evidence this project has now been bitten
by five times.

| Phase | What it proves |
|---|---|
| `dryrun` | `--dry-run` prints every command and **runs none** — verified by looking at the disk afterwards, because a dry run that partitions is the worst bug this option could have |
| `unattend` | `--unattend plan.json` produces the §4.4 layout, and **the passphrase actually opens the container** |
| `rollback` | a step that fails leaves no partition table, no LUKS mapping and no pool behind |
| `walk` | screens 4–6 driven by keypresses: the setup medium is refused, ENTER does not confirm a destructive step, and the passphrase is typed and confirmed |

The one check that matters most is easy to miss in that list: **the passphrase is
tested against the container that was just created.** Everything else about LUKS
can be right while the passphrase typed at install time is not the one that
unlocks at boot — spike S3 found that a keyfile written with a trailing newline
does exactly that, and a header that merely *exists* would have passed.

## Where the ZFS layer lives, and why it is not in C#

`New-OS7Storage` is in the **OS7 PowerShell module**, and Setup invokes it
out-of-process. §6.3 asks for that and the reason is not tidiness:

> `Update-OS7` and `Restore-OS7` need boot-environment creation, activation and
> rollback. **Setup needs the identical logic** to create the first one. Writing
> it twice guarantees drift.

And the drift would be in a dataset hierarchy that **cannot be corrected after
the fact** — `USERDATA` sitting outside `ROOT` is not retrofittable (§4.4). So
the hierarchy exists once, in the place `Update-OS7` will read it from.

Everything else is C# driving processes, exactly as §6.2's table says:
partitioning is `sgdisk`, the ESP is `mkfs.vfat`, the container is `cryptsetup`.

The module's convention, which the installer depends on: **stdout carries
exactly one JSON object and nothing else; stderr carries progress.** A stray
`Write-Output` makes the result unparseable, so `Invoke-OS7Native` writes every
step to stderr and the function writes one object at the end.

## The sequence is S3's, and the one place it is not

§10 says the executor "should be a front-end over exactly this sequence, not a
re-derivation", so the order is
[`s3-zfs-luks.sh`](../installer/spikes/s3-zfs-luks.sh)'s and every ordering
constraint carries S3's reason:

1. **`zgenhostid` first, before the pools exist.** A pool records the hostid of
   whoever last imported it; a mismatch at boot drops the machine into the
   initramfs. Generating it on the live system, creating the pools under it and
   copying that exact file into the target is the only order that is safe (L13).
2. `zpool labelclear` on the disk *and* every partition, before `wipefs` —
   stale ZFS labels make `zpool create` refuse or resurrect a phantom pool (L12).
3. Partitions addressed **by GPT name**, never by `${disk}${n}`: `/dev/vdb1` vs
   `/dev/nvme0n1p1` vs `/dev/mmcblk0p1` is L12's naming trap.
4. `partprobe` then `udevadm settle` then *wait for the by-partlabel links* —
   `sgdisk` returns before udev has made them.
5. The keyfile holds the passphrase **with no trailing newline**, and the PBKDF
   cost is pinned rather than measured, because the default sizes memory from
   the live system's RAM and the initramfs has to reproduce it at boot.
6. `cryptsetup open --allow-discards --persistent`, so TRIM reaches the SSD from
   the initramfs unlock too — without it ZFS `autotrim` is silently a no-op.

**The one divergence, and §11 names it:** S3 predates D10 and puts `/var` and
`/var/log` inside the boot environment. §4.4 now splits them, so the hierarchy
comes from the module rather than from the spike. The spike is not "fixed" — it
is evidence of what booted, not a template.

## What Phase 2 found

### 1. A screen must validate what it collected, not the whole plan

Adding the storage half to `InstallPlan.Validate()` made screen 3 — regional
settings — fail with:

```
Setup cannot continue with the settings as they are.
  no disk selected
  encryption is on but no passphrase was given
```

…three screens before the disk screen exists. §6.6 has the screens filling the
plan in one at a time, so **the plan is incomplete for most of the flow by
design**, and a whole-plan check anywhere inside the flow is asking a question
that has no right answer yet.

Split: `ValidateRegional` for screen 3, and the full `Validate` in exactly two
places — `--unattend`, and the Confirm screen the moment before anything is
written. The second one matters more than it looks: after `F` there is no screen
left to catch an incomplete plan on.

### 2. `--dry-run` must run nothing, including the parts that only *read*

The first version still started PowerShell under `--dry-run`, to ask the module
for a boot-environment name. That is defensible — it is a read — and it is
wrong twice over: it makes `--dry-run` fail on a machine without `pwsh` where
the real run would have worked, and it means the option's promise is "runs
almost nothing", which is not a promise anybody can rely on before touching a
disk.

The dry run now formats a local placeholder name and says it is doing so. And
the harness does not take the promise on trust: it runs `--dry-run` against a
blank disk and then asks the disk whether it is still blank.

### 3. The harness walked into BUILD-NOTES #16, in a new place

Two `zpool list` checks reported the pools missing on a disk whose datasets the
*next* check listed successfully. The cause is the trap the repo already
records: the marker was in the typed command.

```python
ask(c, "zpool list …; echo V4", "V4")   # matches the shell ECHOING "echo V4"
```

`expect` returned while the command was still being typed, so the caller read an
empty buffer. It is intermittent by nature — a fast command's output arrives
before the next poll and the check passes — which is what makes it worth writing
down again: **it does not fail, it flickers.**

The fix is to build the marker in the shell rather than type it:
`printf 'OK%s\n' 4` types `OK%s` and prints `OK4`.

### 4. The disk selection could not be moved, and it looked like a dead keyboard

`DiskScreen.Layout()` rebuilt its list to fit the frame — and `Layout()` runs
before **every** repaint, which happens on every keypress. So pressing DOWN
moved the highlight and the next frame put it straight back on the plan's disk.

The screen was perfect and completely unusable, and the symptom pointed at the
input layer rather than at the screen: a list that does not respond to the arrow
keys reads as keys not arriving, which is where the looking starts. It was found
by driving the flow, not by reading it — nothing about the code says "this runs
on every frame" at the call site.

`Layout()` now returns early unless the size actually changed, and carries the
current selection across a genuine resize.

### 5. The refusal said "read-only" when it meant "setup medium"

Both were true of the ISO — attached read-only, and mounted at `/cdrom` — and
the read-only check came first, so that is what the screen said.

It matters on the case that is not a VM: **a real USB stick is writable.** The
read-only check would not fire, and the medium check is then the only thing
standing between Setup and eating the installer it is running from (L12). The
order is now medium first, and the reason is written next to it.

### 6. QMP `send-key` at 50 keys a second is not a keyboard

The passphrase is typed twice and compared. Injected at 20 ms a key, the two
entries differed and Setup said so — correct behaviour, and a harness artefact:
that is ten times faster than anybody types. At 80 ms it is reliable.

The real cause turned out to be smaller and sharper than "too fast": QEMU holds
each key for **100 ms** unless told otherwise, so anything sent closer than that
overlaps, and a USB HID keyboard cannot report two independent presses at once.
Thirteen characters at 20 ms apart produced **one** character on screen — and at
80 ms, also one. Setting `hold-time` to 20 ms and leaving 120 ms between calls
fixed it. BUILD-NOTES #34.

Worth recording because the conclusion is the opposite of the usual one: **the
product does not need fixing to accept that rate.** A console that keeps up with
50 keys a second is not a requirement OS/7 has.

### 7. And one the harness got wrong about the product being helpful

Refusing to continue without a passphrase also **moves the selection onto the
offending row** — right for a person, and an assumption the harness did not
share: it navigated there itself, landed one row further on `Encryption`, and
turned encryption off. Twelve checks then failed about a passphrase screen that
was never going to appear.

Nothing to fix in the product. Recorded because "the harness assumed the UI
would not help" is a failure mode that will recur, and because it is the second
time in this phase that a red result was the harness rather than the installer.

## What Phase 2 does not do

* **arm64 only**, and no amd64 ISO has ever been built.
* **The result does not boot.** No system is copied, no account is created, no
  bootloader is installed — Phase 3.
* **`--unattend` cannot carry the passphrase**, deliberately: a plan file goes
  into a repository, a log and a screenshot. `--passphrase-file` is a separate
  artefact. What an unattended fleet install actually does about that is U8's
  problem, not this phase's.
* **Single disk only.** Mirrors need one LUKS container per member (§4.5) and
  the plan refuses `layout` values it has not implemented rather than guessing.
* **Encryption can be turned off**, and the screen says what that costs — Intune
  recognises only dm-crypt (D3), so an unencrypted machine fails the
  device-encryption rule. Allowed because Azure Arc has no equivalent rule and
  arm64 is server-only.
* **No TPM2 enrolment.** Spikes S4 and S6 proved it works and what it costs; the
  installer does not do it yet, and it needs the initramfs work from
  `s4-tpm-enroll.sh` (BUILD-NOTES #19, #20) which belongs with Phase 3's
  initramfs step.
* **Nothing is mounted for Phase 3 yet.** The pools are created with `-R /target`
  and the boot environment is mounted, which is where Phase 3 starts.
