# Backup — Time Machine on the primitive OS/7 already has

**Written 2026-08-25, finished 2026-08-26.** How OS/7 backs up user and
application data, what it builds on, what it deliberately does not build, and
what has and has not been proven. The measurements in §13 were all made on
2026-08-25 and are dated as they happened.

Authority: this document decides the **backup feature** — its policy model, its
cmdlet surface, its safety rules and its verification. It does not decide the
dataset hierarchy ([../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md) §4.4),
the update train ([RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md)), the
ZFS layer ([ZFS-POWERSHELL-PLAN.md](ZFS-POWERSHELL-PLAN.md) Z1–Z14) or what a
release contains ([CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md)).
Where it touches those, it says so and defers.

---

## 1. Verdict

OS/7 already treats a ZFS snapshot as a first-class thing. An update happens in a
clone; a bad one is undone by booting yesterday's environment; the whole dataset
hierarchy exists so that a rollback of the *system* cannot take the *user's files*
with it ([SETUP-PLAN §4.4](../installer/SETUP-PLAN.md), D10).

And then nothing ever snapshots the user's files. `os7-setup` takes no snapshot at
any point, no timer takes one afterwards, and a freshly installed OS/7 machine has
**zero** snapshots outside the boot environment. The primitive is there, wired to
one half of the machine.

**Decision: apply it to the other half, and send the result off the machine.**

* **snapshots and retention** are `sanoid`'s,
* **replication** is `syncoid`'s,
* **which datasets, which targets, and whether it actually worked** are OS/7's.

Both tools are GPL-3.0+, in the pinned Ubuntu archive, and mature. They are
**shelled out to as programs**, never vendored: running a GPLv3 binary is not a
licensing question for OS/7's MIT tooling, and re-implementing a decade-old
retention thinner would be worse than either.

**The third column is the whole job, and it is bigger than it looks.** Both tools
were read before this was written, and *both report success in situations where
nothing happened* (§13). That is the exact bug shape
[BUILD-NOTES](BUILD-NOTES.md) keeps recording — *a program reported success and
the thing it was meant to change did not change* — arriving in the one feature
where being wrong is discovered by the person who needed the data.

So nothing in OS/7's layer believes an exit code. Every verb that claims
something happened re-reads it from ZFS: locally through the `Zfs` module, and on
a remote target through the same module over ssh (Z14).

---

## 2. What is built, and where it lives

| Piece | Where |
|---|---|
| Policy, schedule, status, coverage | [`powershell/OS7/OS7.Backup.ps1`](../powershell/OS7/OS7.Backup.ps1) |
| Targets, replication, target creation | [`powershell/OS7/OS7.BackupTarget.ps1`](../powershell/OS7/OS7.BackupTarget.ps1) |
| Browsing and restoring files | [`powershell/OS7/OS7.BackupRestore.ps1`](../powershell/OS7/OS7.BackupRestore.ps1) |
| The self-test | [`powershell/OS7/OS7.BackupSelfTest.ps1`](../powershell/OS7/OS7.BackupSelfTest.ps1) |
| The units and their scripts | `build/config/includes.chroot/usr/{lib/systemd/system,libexec}/os7-backup-*` |
| Build-time verification | [`build/config/hooks/0090-os7-backup.hook.chroot`](../build/config/hooks/0090-os7-backup.hook.chroot) |
| The VM harness | [`installer/testing/run-backup.py`](../installer/testing/run-backup.py) |

### B1 — it lives in the OS7 module, not in a module of its own

Four dot-sourced files under `powershell/OS7/`, exported through the existing
manifest.

The `Zfs` module exists because there was a generic layer worth having:
`Get-ZfsDataset` runs on TrueNAS. **There is no equivalent here** — the generic
layer is sanoid and syncoid, and they are already generic and already somebody
else's. What is left after subtracting them is entirely OS/7 knowledge: which
datasets the update train owns, which a rollback must not touch, where `/home`
really is on this product, and how to prove a copy arrived. Z8 puts OS/7
knowledge in Layer 3, and this is Layer 3.

**Z1 still holds at zero.** `check-layering.py` reports no direct `zfs`/`zpool`
invocation anywhere in `powershell/OS7` — including the remote reads, which is
what §4's Z14 addition to the generic module was for.

---

## 3. What sanoid and syncoid actually do

Measured from the package OS/7 pins — `sanoid 2.3.0-1`, `Architecture: all`,
SHA256 `24bc2809…d603d` — by reading the perl in it. Line numbers are that file's.

```
/usr/sbin/sanoid    take and thin snapshots on a policy. 62 KB of perl.
/usr/sbin/syncoid   incremental zfs send | zfs receive, local or over ssh. 84 KB.
/usr/sbin/findoid   list versions of one file. OS/7 does not use it — B10.
```

The package also ships `sanoid.timer` (`OnCalendar=*:0/15`, `Persistent=true`),
`sanoid.service` and `sanoid-prune.service`, all three gated on
`ConditionFileNotEmpty=/etc/sanoid/sanoid.conf` — **and no such file**. Its only
`/etc` content is a `cron.d` entry that disables itself under systemd.

**It has no replication unit at all.** syncoid has no config file, no schedule
and no unit, so everything about *when* a copy leaves this machine is OS/7's.

---

## 4. The one addition to the generic ZFS layer

### Z14 — the read cmdlets take `-ComputerName`, and `Clear-ZpoolLabel` exists

Two additions to `powershell/Zfs`, both generic, both additive, and both needed
before this feature can be honest. Recorded here and cross-referenced from
[ZFS-POWERSHELL-PLAN.md](ZFS-POWERSHELL-PLAN.md), whose v1 surface they extend.

**`-ComputerName` on `Get-Zpool`, `Get-ZpoolStatus`, `Get-ZfsDataset` and
`Get-ZfsSnapshot`**, plumbed through the one seam (`Invoke-ZfsNative`, Z2) as
`ssh <host> zfs …`. Read-only: the mutating cmdlets do not take it.

Without it there is no way to answer *"is my data actually on the target"*
except by believing syncoid, and syncoid's exit code is 0 with its
post-transfer work unfinished. With it, the answer comes from the receiving
pool's own ZFS. The alternative — an `ssh` call from `powershell/OS7` — would
have needed `check-layering.py` weakened to let it past, which is the wrong
direction for a guard.

Three properties it carries, none of them optional:

* `BatchMode=yes` — a verification that **blocks** on a password prompt is worse
  than one that fails, because nothing times out and nothing says why.
* `ConnectTimeout=10` — a target that is switched off must fail in seconds.
* `StrictHostKeyChecking=yes` — a target whose identity is accepted on sight is
  one that anything on the path can impersonate, and this reads the answer to
  *"is my data really over there"*.

Remote arguments are shell-quoted, local ones are not: `ssh` joins its arguments
and hands them to a **login shell**, while `& zfs @args` has no shell in it at
all. Two paths, escaped differently on purpose.

**`Clear-ZpoolLabel`** wraps `zpool labelclear`, which B9 needs and Layer 3 may
not call directly. It verifies the way everything else in that module does, and
the mechanism is unusual enough to name: `labelclear` **exits non-zero when there
is nothing to clear**, so a *second* call that succeeds means the label survived
the first. That is the only question `zpool list` cannot answer — it cannot see a
device that is not in a pool.

---

## 5. The policy model

### B2 — `/etc/os7/backup.json` is the truth; `sanoid.conf` is generated from it

The same shape `Set-OS7BootEnvironment` already uses for the GRUB menu: OS/7 owns
a file, and renders the other program's file out of it with a header saying so.

Two reasons it is not just sanoid.conf:

* sanoid.conf cannot hold what OS/7 needs. **Only the 52 keys in
  `[template_default]` of the shipped defaults may appear**, and an unrecognised
  one is a **fatal die** (sanoid:975) — not a warning. There is nowhere to put a
  target, an ssh key, or the fact that backups are switched off.
* A generated file can be regenerated, diffed, and **validated before it is
  installed**.

### B3 — the rendered config is parsed by sanoid before it is installed

`Set-OS7BackupPolicy` writes the candidate to a scratch directory and runs

```
sanoid --configdir <tmp> --cache-dir <tmp> --run-dir <tmp> --readonly --take-snapshots
```

and installs nothing unless that exits 0. `--readonly` guards every mutating call
in the program (sanoid:380, :398, :643, :665, :722), and the scratch directories
keep the real cache and locks out of it.

**All three directory options are given deliberately.** `if (keys %args < 4)` at
sanoid:34 turns `--cron` on when few enough arguments are present, and `%args` is
*pre-seeded* with `configdir`, `cache-dir` and `run-dir` — so an invocation that
passed only those three would silently become a full cron run.

This is the difference between a bad policy failing at the prompt, in front of
the person who typed it, and failing at 00:15 in a way that looks exactly like
success.

### B4 — local snapshots are on by default; replication is opt-in

`os7-backup-firstboot.service` runs `Enable-OS7Backup` once, on the first boot of
a machine that has `rpool/USERDATA`. Replication does nothing until a target is
defined.

**Not baked into the image**, and hook 0090 fails the build if it ever is: the
policy names datasets that exist only on an installed machine, so a
`sanoid.conf` on the ISO would un-skip sanoid's services on the **live medium**,
where sanoid would try to snapshot datasets that are not there, print
`CRITICAL ERROR` to stderr, and exit 0 — every fifteen minutes, for as long as
anybody left the ISO running.

**Not in `os7-setup` either**, and that is a judgement rather than a rule. One
line in `SystemSteps` would do it, and the installer is the one code path in this
repository proven to produce a machine that boots; changing it means re-running
`run-phase3.py all`. The first-boot unit reaches the same place without touching
that. If a later session is running the installer harness anyway, moving it there
is a fair trade.

### B5 — OS/7's retention, not sanoid's

| | frequently | hourly | daily | weekly | monthly | yearly |
|---|---|---|---|---|---|---|
| sanoid ships | 0 | 48 | 90 | 0 | 6 | 0 |
| **OS/7** | **0** | **24** | **14** | **4** | **3** | **0** |

144 snapshots per dataset against 45. The floor OS/7 installs on is a **16 GB**
disk (README; `Disks.cs` `MinimumBytes`), **no dataset it creates carries a
quota**, and `rpool` holds `/` — so a retention policy that fills rpool does not
fail the backup, it makes the running system unwritable. Boot environments have
the prior claim on that space and have no retention policy of their own yet
(RELEASE-AND-UPDATE-PLAN UL9); **backup retention and BE retention are one
decision**, and only half of it is made here.

24 / 14 / 4 / 3 covers what an operator actually asks for: today by the hour, a
fortnight by the day, a month by the week, a quarter by the month.

**A count of 0 is not "leave alone".** It means *keep none*, and sanoid prunes
the existing snapshots of that type at the next run. Worth knowing before
somebody sets `hourly = 0` to pause hourly snapshots.

---

## 6. Safety — the part that could destroy a machine

### B6 — `Assert-OS7DatasetSafe`, which Z8 named and nothing had written

Z8 says the OS/7 guard lives in Layer 3 and calls it `Assert-OS7DatasetSafe`. It
did not exist. This feature is the first OS/7 code to hand a dataset name to
something that takes and **destroys** snapshots on a schedule, so it is written
here.

Refused: `rpool/ROOT`, `bpool/BOOT` and everything below them; `bpool`; and **any
pool root**. The last one is not tidiness — `recursive = yes` makes sanoid create
**one configuration section per descendant**, each inheriting `autoprune`, so a
single `[rpool]` section puts `rpool/ROOT/*` inside the pruner's scope.

The generic layer cannot do any of this: `New-Zpool` validates a pool *name* and
passes the device list through untouched, and `New-OS7Storage` already calls it
with `-Force`, which is `zpool create -f`.

### B7 — and the guard is the second line of defence, not the first

**sanoid can only ever destroy a snapshot whose name begins `autosnap`**
(sanoid:914 — the sole write into `%snaps`, which is the only thing the pruner
reads) **and ends in `ly`** (the cache regex at sanoid:909). OS/7's
boot-environment snapshots are named `os7_<release>_<yyyyMMddHHmm>` and fail
both tests.

So there are two independent reasons a boot environment is safe, and the
self-test asserts **both** — including from the other side: it checks that
`New-OS7BootEnvironmentName` still produces a name failing both filters, so a
future rename of boot environments cannot quietly remove one of them.

The route that defeats both is `recursive = zfs`, which runs `zfs snapshot -r`
and snapshots the whole subtree at the ZFS level *including datasets sanoid has
no section for*. **OS/7 never emits it**, and the self-test asserts that too.

### B8 — the replication run takes a lock, because syncoid has none

syncoid has **no locking of any kind**; its only overlap guard is a `ps` grep for
a running `zfs receive` on the target. Two timers, or a timer and an operator,
both start. `Start-OS7BackupReplication` holds `/run/os7-backup.lock` for the
whole run and refuses rather than racing.

### B9 — creating a target is destructive, and `-ConfirmDisk` is not `-Confirm`

`New-OS7BackupTarget -CreateOn <disk>` partitions a whole disk, puts LUKS2 on it
and creates a pool. Guards, all before `ShouldProcess`:

* the disk carries no imported pool — asked of ZFS through `Get-ZpoolStatus`'s
  vdev tree, resolved down through device-mapper and partitions to whole disks;
* the disk carries no `os7-esp` / `os7-bpool` / `os7-luks` partition, imported or
  not;
* it is a whole disk, not a partition;
* **`-ConfirmDisk` must name the disk's own by-id path or serial.** `-Confirm:$false`
  in a script is the equivalent of pressing ENTER by momentum, and this command
  erases a disk. Setup solves the same problem by making the destructive key **F**
  rather than ENTER; this is that idea in a cmdlet.

*The installer's own guard is not reused, and it is worth saying why:* the spike
compares `findmnt -no SOURCE /` with the target device, and on an installed OS/7
that SOURCE is a **dataset name** — `rpool/ROOT/os7_…` — which equals no device
path anybody could type.

Three properties of the pool it creates:

* **`cachefile=none`.** Both of OS/7's own pools are created with
  `cachefile=/etc/zfs/zpool.cache` precisely so `zfs-import-cache` imports them at
  boot. A **removable** pool in that cache is one the boot path tries to import on
  every start with the drive absent — and it is what turns a hostid mismatch from
  *a message on a running system* into *an initramfs prompt*.
* **`mountpoint=none`, `canmount=off`, and an altroot.** It holds received copies
  of `/home/...` and `/var/log`. A dataset that arrives with a mountpoint mounts
  over the live one.
* **zstd, not lz4.** `compatibility=grub2` is what forces lz4 on `bpool`, and
  nothing boots from a backup drive.

The LUKS2 cost is pinned to the installer's figures — argon2id, 524288, parallel
2, 2000 ms. **Not by cargo cult:** the installer's stated reason is that the
initramfs must reproduce it at boot, and a backup drive is never unlocked from an
initramfs. The reason here is different and its own — matching the system disk's
cost means *a machine that can boot can open its own backup*. (The unit of
`--pbkdf-memory` is not stated anywhere in this repository; README's "512 MiB" is
consistent with KiB and is not a measurement made here.)

The passphrase is written to a `/run` keyfile with **no trailing newline** —
`luksFormat` consumes it verbatim while a prompt strips the newline, so
`Set-Content`, `Out-File` and `>` all produce a header the operator's passphrase
does not open. And the acceptance test is `cryptsetup open --test-passphrase`,
not `luksFormat`'s exit code.

---

## 7. Restore

### B10 — `.zfs/snapshot`, reimplemented in PowerShell; `findoid` is not used

The mechanism is kept and the tool is not. `findoid` ships in the same package
and does roughly this job, and reading it decided the question:

* It **dedupes by (size, mtime)** and drops whole snapshots from the output;
  which one survives is `readdir` order, not chronological order.
* It matches the owning dataset with `$path =~ /^$mountpoint/` — an
  **unanchored, unescaped** regex. `/home/os7admin` matches the mountpoint
  `/home/os7`, which on OS/7 is not hypothetical: `New-OS7Storage` mounts one
  dataset per account under `/home`.
* Its relative-path splice never fires for a dataset mounted at `/`, which is
  where OS/7 mounts its boot environment; the path it builds has a doubled slash
  and cannot be stat-ed.
* It sorts and displays **the file's mtime, not the snapshot's creation time**,
  so a timeline built on it puts any file whose mtime was preserved by a copy at
  the wrong point.
* For a **deleted file** — its headline use case — it prints `/` as a version,
  and exits 0.
* It checks no return value anywhere and always exits 0.
* Its output is three tab-separated fields with no quoting, a lossy human size,
  and a `localtime()` string with no timezone.

`Get-OS7FileVersion` resolves the owning dataset by **longest path-component
match** over `Get-ZfsDataset`'s structured `Mountpoint`, enumerates snapshots
from ZFS so every version has a real `[datetime]`, and reports every snapshot
that holds the path. `-DistinctOnly` collapses identical runs and keeps the
**oldest** of each — the snapshot in which that content first appeared.

**Three different nothings get three different sentences**, because an empty
result is the least useful thing a restore command can say: *permission denied*,
*`.zfs/snapshot` unreachable* (with the `snapdir` property named), and *the
dataset genuinely has no such file*.

`Restore-OS7File` copies with `rsync -aAX --numeric-ids`. `-A` and `-X` because
both pools are created `acltype=posixacl` and `xattr=sa`, so a plain `cp` copies
the bytes and drops the permissions that made the file private — and because the
image carries **both** GNU coreutils and the uutils Rust ones, so which binary
answers to `cp` is not a question this repository has answered. `--numeric-ids`
because an Entra-backed account's uid comes from `authd` and may resolve
differently now than when the snapshot was taken.

It **will not write over the live path** without `-Force`; the reason somebody is
here is that a file was lost, and a restore that overwrites the wrong version by
default has lost a second one. And the copy is verified afterwards by stat-ing
the result: `rsync` exiting 0 for a path that resolved into a **child dataset's
empty mountpoint inside a parent's snapshot** is exactly the silent-nothing case,
and it is reported here rather than discovered by the person who needed the file.

### B11 — a GUI browser is later, and is never the only route

arm64 is server-only and may never have a local console; RELEASE-AND-UPDATE-PLAN
§6 requires every cmdlet to work over serial and ssh. So the cmdlets are the
surface, and a Time-Machine-style browser on the amd64 desktop is a second front
end over them.

---

## 8. Status, and what it refuses to trust

### B12 — `Get-OS7BackupStatus` asks ZFS, never sanoid

Not sanoid's exit code, which is **0 after taking snapshots even when
`zfs snapshot` failed** — the failure is a perl `warn` carrying the words
"CRITICAL ERROR" and never reaches the exit status.

Not `sanoid --monitor-snapshots` either, and this one is the sharpest: it does
not ask ZFS at all. It answers from `/var/cache/sanoid/snapshots.txt`, and when
only monitor flags are given **the cache TTL is deliberately raised from 1200
seconds to 18000 — five hours** (sanoid:69-85). A monitor that can be five hours
stale is not a diagnostic, it is a memory.

Not syncoid's exit code, which is the worst outcome over all datasets and which
several post-transfer steps cannot reach.

And not OS/7's own log, which is written for diagnosis and read by nothing.

What it does instead:

| Question | Answered by |
|---|---|
| how fresh are the local snapshots | `Get-ZfsSnapshot` on the configured datasets, newest `Creation` |
| how fresh is the copy on the target | `Get-ZfsSnapshot` **on the target**, over ssh — written by `zfs receive` |
| is it *my* copy | the ZFS **GUID** of the newest target snapshot, compared with this machine's |
| is the target healthy | `Get-ZpoolStatus` on the target: state, and read+write+checksum errors summed |
| what is not covered at all | `Get-OS7BackupCoverage` — §11 |

The GUID comparison is the one that turns "something is over there" into "my data
is over there". Names cannot do it: syncoid stamps its sync snapshots with
**local time plus a GMT offset** while sanoid's units force `TZ=UTC`, so a single
machine's snapshot names carry two clocks and one of them moves twice a year.

### B13 — the replication unit fails for the right reason and not the other one

A target that is **unplugged or unreachable** is a *skip*: exit 0, recorded in
the log, visible in the status. A target that is **present and did not receive
the data** is a *failure*: exit 1.

An external drive is absent most of the time. A unit that goes `failed` every
hour for a drive in somebody's bag teaches a fleet to ignore it, and the next
thing it ignores is the real one. "The drive has been unplugged for a month" is a
question about a fleet, answered where fleets are managed — `HoursSinceReplication`
in the status object, and an Intune or Arc rule over it.

### B14 — TZ stays UTC

Both shipped sanoid units set `Environment=TZ=UTC`, and OS/7's units match rather
than fighting it. Retention arithmetic is elapsed seconds and does not care, but
the **bucket anchors** do: `daily_hour=23 daily_min=59` is 23:59 in whatever TZ
the unit runs with, so an admin in Europe/Berlin gets a "daily" at 01:59 local.

Kept anyway, and the reason is a failure mode rather than a preference: under a
DST fall-back sanoid collides with its own name and rewrites the type to
`dst_hourly` — a snapshot whose type is derived by a greedy regex. Under `TZ=UTC`
that path cannot run at all. The cmdlets render `[datetime]`s in local time, which
is where a human should meet the difference.

---

## 9. Test strategy

### B15 — two tiers, exactly as Z10 does it

There is no Pester in the image and adding one would mean a new pinned component
for test code only.

| Tier | What | Where | State |
|---|---|---|---|
| 1 | `Test-OS7Backup` — the guard, the renderer, path resolution, the syncoid command line | in the module; anywhere pwsh runs | **63 checks, green** |
| 1b | the same, against the **shipped** module in a chroot | `check-image.py` | written, needs an ISO |
| 2 | `Test-OS7Backup -Live` and a full cycle against real ZFS and real sanoid | `run-backup.py`, a booted VM | **written, never run** |

Tier 1 checks every rule this feature encodes about somebody else's program. It
cannot check that the program then behaves as measured — that is tier 2, and
**tier 2 is the gate**. The distinction is the same one Z10 draws and it is not a
formality: a test of a parser that runs where ZFS does not is a test of argument
strings.

What tier 2 adds that tier 1 structurally cannot: that sanoid takes a snapshot,
that syncoid's stream arrives, and that a file comes back with its contents.
Those three are what a backup *is*.

---

## 10. The command surface

RELEASE-AND-UPDATE-PLAN §6: *"an operator never needs the Linux commands. That
holds only if the surface is complete — a single missing verb sends them back to
bash and the guarantee is gone."*

| Cmdlet | Purpose |
|---|---|
| `Get-OS7BackupPolicy` | what is configured, and what ZFS holds for it |
| `Set-OS7BackupPolicy` | change the datasets or the retention; validated by sanoid before it lands |
| `Enable-OS7Backup` / `Disable-OS7Backup` | start and stop the schedule. Disable destroys nothing |
| `Start-OS7Backup [-Replicate]` | run now; reports the change ZFS reports |
| `Get-OS7BackupStatus` | the verified answer — §8 |
| `Get-OS7BackupCoverage` | what the policy does **not** reach — §11 |
| `Get-OS7BackupTarget` | targets, with health and freshness measured from them |
| `New-OS7BackupTarget` | define one — a pool, a host, or a whole disk to build |
| `Test-OS7BackupTarget` | reachable, healthy, in sync, has room |
| `Remove-OS7BackupTarget` | forget one, cleaning up the sync snapshots it left here |
| `Start-OS7BackupReplication` | send now, and verify from the target |
| `Mount-OS7BackupTarget` / `Dismount-OS7BackupTarget` | unlock/import and export/lock a removable target |
| `Get-OS7FileVersion` | every version of a file or folder a snapshot still holds |
| `Restore-OS7File` | copy one back, ACLs and xattrs included |
| `Test-OS7Backup` | the self-test |

`Remove-OS7BackupTarget` cleans up on purpose: syncoid removes its previous sync
snapshot only on its **next successful run**, so a target that is merely deleted
from a config file leaves snapshots on the source forever — and "forever" is what
back-to-bash means here.

---

## 11. The finding that limits what this is worth today

### B-Q1 — OPEN: `/home/<user>` is not on a USERDATA dataset

**Measured 2026-08-25**, and it is not a backup bug:

* `New-OS7Storage` creates `rpool/USERDATA/<UserName>_<suffix>` mounted at
  `/home/<UserName>`, and **`-UserName` defaults to `os7`**.
* `os7-setup` never passes `-UserName` — the command it builds carries `-Root`,
  `-RootDevice`, `-BootDevice` and `-BootEnvironment` and nothing else.
* The account is created afterwards by `useradd -m` with whatever name the
  operator typed. On the one machine this repository has installed and booted,
  that is **`os7admin`**.

So on that machine `/home/os7` is a mounted dataset with nothing in it, and
`/home/os7admin` is an ordinary directory **inside the boot environment's root
dataset**. Two consequences:

1. A `Restore-OS7` rollback un-says the user's files — exactly what SETUP-PLAN
   §4.4 puts USERDATA outside ROOT to prevent.
2. **No snapshot policy can cover that home** without snapshotting the boot
   environment, which B6 refuses for good reasons.

This feature does not fix it and does not paper over it. `Get-OS7BackupCoverage`
reports every `/home/*` the policy cannot reach, with the reason, and the
first-boot unit prints it on the boot where it becomes true.

**The fix is one parameter in `StorageSteps`**, plus a migration for machines
already installed. It is not made here because the installer is the only code
path proven to produce a machine that boots, and changing it means running
`run-phase3.py all` — which needs the Apple Silicon host this was not written on.
It is the first item in [HANDOFF.md](HANDOFF.md).

---

## 12. Limitations — the honest list

| # | Limitation |
|---|---|
| BL1 | **Never run on a machine.** Tier 1 is green; `run-backup.py` has never executed. Every claim here about sanoid and syncoid is from reading their source, and every claim about OS/7's layer is from a self-test that mocks them. |
| BL2 | **arm64 only, and not even that.** Nothing in this repository has been installed on amd64, so the desktop product's backup is doubly unproven. sanoid is `Architecture: all`, so the *engine* is identical; the attestation path is not (Intune on amd64, Arc on arm64). |
| BL3 | **The replicated stream is plaintext.** DECISIONS locks LUKS2-under-ZFS and forbids ZFS native encryption, so `zfs send -w` is unavailable. ssh protects it in flight; at rest it is the target's own encryption or none. `Test-OS7BackupTarget` reports what the target says about itself, which is all any check here can see. |
| BL4 | **No scrub of the target is scheduled.** Nothing in sanoid, syncoid or findoid verifies a copy is readable; only a scrub does. `Get-ZpoolStatus` surfaces the counters and `Start-ZpoolScrub` exists, but nothing runs one on a timer. |
| BL5 | **Backup retention and boot-environment retention are one decision and only half is made.** BEs have the prior claim on rpool and no retention policy of their own (UL9). |
| BL6 | **`Start-OS7Backup -Replicate -WhatIf` cannot preview the send.** syncoid has no dry run. The snapshot half delegates to `sanoid --readonly`; the replication half would have to be simulated by OS/7, and is not. |
| BL7 | **Unlock-on-reconnect is manual.** `Mount-OS7BackupTarget` asks for the passphrase. TPM2 would work — spike S4's `--token-only` form is not initramfs-specific — but it inherits open question U8 exactly: after a shim or dbx update the drive stops unlocking itself, and there is no escrowed recovery key. A keyfile on the root filesystem would be the first persistent key material in OS/7 and means "anyone who has the running system has the backups". |
| BL8 | **Intune custom compliance is not built.** `Get-OS7BackupStatus | ConvertTo-Json` is the shape one would emit, and the assertions are obvious — replication within N hours, zero pool errors, a scrub younger than 35 days. The contract must be verified against Microsoft's live documentation first; DECISIONS makes that a rule for anything touching Intune, and this document deliberately does not restate it from memory. |
| BL9 | **`snapdir` is left at ZFS's default.** OS/7 sets it nowhere. Whether `hidden` still permits explicit traversal of `.zfs/snapshot` is not measured here — it is the assumption the restore path rests on, and `Get-OS7FileVersion` is written to say so plainly if it turns out to be wrong rather than reporting "no versions". |
| BL10 | **A second machine importing the same backup pool is undecided.** Backup pools are named `os7backup` by default, so two drives answer to one name; `Mount-OS7BackupTarget` passes `-Directory /dev/mapper` to disambiguate, which is sufficient for one drive at a time and not for two. |

---

## 13. What was measured, and how

All on 2026-08-25, against the package OS/7's own pin resolves to, fetched from
`snapshot.ubuntu.com/ubuntu/20260824T000000Z/`.

**M-B1 — sanoid is in the pin, and so is everything it needs.** `sanoid 2.3.0-1`,
`Architecture: all`, `universe`, 56 770 bytes, SHA256 `24bc2809…d603d` — the deb
was downloaded and its hash computed, not read out of an index. Its five
dependencies resolve from the same snapshot: `pv 1.10.3-1` and
`lzop 1.04-2build4` (main), `mbuffer 20251025+ds1-1` (universe),
`libconfig-inifiles-perl 3.000003-4build1` and `libcapture-tiny-perl 0.50-1`
(main, both `all`). ≈357 KB downloaded, ≈1.1 MB installed. `perl` is already in
the image — checked against `out/OS7-1.0.0.95-amd64.packages.manifest`, which
also shows `rsync`, `openssh-client`, `cryptsetup`, `gdisk` and `acl` present and
`attr` absent.

**M-B2 — what the package actually contains.** Extracted with a hand-written `ar`
+ zstd reader, because the deb is `zstd`-compressed and no `dpkg-deb` was to
hand. Three programs in `/usr/sbin`, three systemd units, one `cron.d` conffile,
the defaults file — **and no `/etc/sanoid/sanoid.conf` and no `/etc/sanoid`.**
The postinst enables *and starts* `sanoid.timer` unconditionally, without looking
at whether a config exists.

**M-B3 — sanoid cannot reach a boot environment.** `getsnaps()` populates
`%snaps` only for names matching `/^autosnap/` (sanoid:914) and only for lines
matching `@(.*ly)` (sanoid:909); `prune_snapshots` reads nothing else, and is
scoped to configured sections. This is the measurement B7 rests on, and it is why
the guard is the *second* line of defence rather than the only one.

**M-B4 — the five-hour monitor cache.** sanoid:69-85: when `--monitor-*` is given
without `--cron`, `--force-update`, `--take-snapshots`, `--prune-snapshots` or
`--cache-ttl`, `$cacheTTL` becomes 18000. This is the single fact that decided
§8: a status verb built on `--monitor-snapshots` would be a diagnostic that
depends on a cache rather than on the subsystem.

**M-B5 — `/home` is not where the layout says.** §11, from
`powershell/OS7/OS7.psm1` (`-UserName` defaults to `os7`),
`installer/src/OS7.Setup/Steps/StorageSteps.cs` (the command string it builds),
and `installer/testing/run-phase3.py` (the account is `os7admin`).

**M-B6 — the two self-tests are green here.** `Test-ZfsModule` 75 checks,
`Test-OS7Backup` 63 checks, both run under the same PowerShell 7.6.5 the image
ships, on the machine this was written on. `check-layering.py` reports **0**
direct `zfs`/`zpool` invocations in `powershell/OS7`, so Z1 holds across the new
code including the remote reads.

**What was NOT measured, and must be before any of this is believed:** every
claim about sanoid's and syncoid's *runtime* behaviour is from reading perl. No
snapshot has been taken, no stream has been sent, and no file has been restored
by this code. `run-backup.py` is the thing that would change that.

---

## 14. Plan

| Phase | What | Gate | State |
|---|---|---|---|
| **B-0** | Measure the package and both programs | §13 | **done** |
| **B-1** | Z14: `-ComputerName` reads and `Clear-ZpoolLabel` in the Zfs module | `Test-ZfsModule` green | **done — 75 checks** |
| **B-2** | Policy, sanoid.conf renderer, guard, status, coverage | `Test-OS7Backup` green | **done — 63 checks** |
| **B-3** | Targets, replication, target creation, restore | tier 1 green | **done** |
| **B-4** | Image: the package, the units, hooks 0060/0075/0090, `check-image.py` | a built ISO | **written, no ISO built** |
| **B-5** | **`./installer/testing/run-backup.py all` on a booted VM** | tier 2 green | **NOT DONE — the gate** |
| **B-6** | B-Q1: the installer passes `-UserName`, and a migration for installed machines | `run-phase3.py all` | not started |
| **B-7** | A scrub schedule for targets; Intune compliance definitions | | not started |
| **B-8** | The GUI restore browser, amd64 | | not started |

**B-5 is the one with teeth**, and until it passes this feature is code rather
than a backup. That is the same sentence Z-4 got in the ZFS plan, and it is here
for the same reason: a passing build has never been the check in this repository.
