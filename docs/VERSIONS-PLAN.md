# Versions — previous versions of a file, from the file manager

**This file is authoritative for OS/7's "Versionen" / "Versions" feature: where the versions come
from, what the window is, what a restore means, what it costs in disk space, and how it survives a
change of file manager.**

**The read half is built and has run on a machine; nothing yet changes a file.** Every `Vn` below is
*Proposed 2026-09-14* — the foundation is not: §2 measured, on a running OS/7 machine, that every
technical prerequisite already exists and that the snapshots this feature would read **are already
being taken**. Decisions are V1–V18, limitations VL1–VL8. A measurement still owed is `O-V1…`.

**V15 and V16 are DECIDED and BUILT** — the storage-pressure rule (70 warn / 80 tighten / 90
refuse, gated on whether thinning could even work) and the boot environment that is never pruned.
§5 has them, `powershell/OS7/OS7.Storage.ps1` implements them, and
`installer/testing/check-storage-logic.py` holds all of it at 37 checks with no ZFS.

`src/OS7.App.Versions/` draws the window, reads real snapshots, and offers *Open* and *Copy to…*
only; **§7a is what building it measured**, including the two things about the cascade that were
wrong until a machine showed them. The cmdlets V9 requires do not exist yet, which is G7 the wrong
way round and the next piece of work.

It exists because of a question — *"can we put a Versions entry in the file manager's context menu
that brings up a Time-Machine-like UI, and is ZFS up to it?"* — and the short answer is that ZFS is
up to it, most of it is already running, and the hard part is not the snapshots but **the disk
filling up**, which collides with a decision this repository has already half-made (BL5).

Related authority: [BACKUP-PLAN.md](BACKUP-PLAN.md) B5 (the retention policy this reads), BL5 (the
collision); [GUI-APPS-PLAN.md](GUI-APPS-PLAN.md) G1–G12 (the toolkit, the layer cut, the design
system); [ZFS-POWERSHELL-PLAN.md](ZFS-POWERSHELL-PLAN.md) Z1 and
[POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md) P2/P12 (OS7 reaches ZFS only through the
Zfs module); [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) UL9 (boot environments have
no retention policy either); [BUILD-NOTES.md](BUILD-NOTES.md) #74 (why `/home/<user>` is its own
dataset, which is what makes this per-user).

---

## 1. Verdict

**Yes, and most of it exists.** An OS/7 machine already takes hourly, daily, weekly and monthly
snapshots of every user's home, already exposes every one of them as an ordinary readable directory,
and already lets the unprivileged owner read their own files out of them with no authentication at
all. The feature is a **reader** with a window on it, not a new mechanism.

The three things that are genuinely new are a window, a context-menu entry, and an answer to *what
happens when the pool fills up* — and only the third is hard.

**The one thing this must not become is a second snapshot policy.** `sanoid` takes the snapshots and
prunes them (B5); a versions feature that took its own would put two autonomous thinners on one pool,
which is this repository's most-paid-for shape — two tools, each reporting success, disagreeing about
what exists.

---

## 2. What was measured

**2026-09-14, on the `gui` bench: an installed, booted OS/7 1.0.0.163 amd64 machine.** Every row
below is from that machine, not from documentation.

| # | Question | Answer |
|---|---|---|
| M-V1 | Is the user's home its own dataset? | **Yes** — `rpool/USERDATA/os7admin_af456a8e` at `/home/os7admin`. #74's fix, on a machine. So versions are per-user by construction |
| M-V2 | Are snapshots already being taken? | **Yes, 32 of them**, by `sanoid.timer` every 15 minutes — `autosnap_…_daily`, `_weekly`, `_monthly` |
| M-V3 | What is the retention? | B5, live in `/etc/sanoid/sanoid.conf`: `hourly=24 daily=14 weekly=4 monthly=3` on `rpool/USERDATA`. **That is Time Machine's own model** — fine granularity near now, coarse going back |
| M-V4 | Can a previous version be read as a path? | **Yes.** `/home/os7admin/.zfs/snapshot/<snap>/<relative path>` returned the old contents — **including for a file deleted from the live filesystem** |
| M-V5 | Does it need root? | **No.** `su - os7admin` listed the snapshots and read the file. Browsing and restoring into one's own home need no privilege and therefore no polkit |
| M-V6 | Does `.zfs` clutter the file manager? | **No.** `snapdir=hidden`, and a plain `ls -a` does not list it. The feature is invisible until asked for |
| M-V7 | What does a snapshot cost in time? | **55 ms** each (10 in 550 ms) |
| M-V8 | What does listing them cost? | **16 ms** for 44 snapshots — a UI can list on every open |
| M-V9 | First access to a cold snapshot directory? | **17 ms**, and browsing five of them leaves **no** extra mounts in `/proc/self/mountinfo` |
| M-V10 | Can a path be resolved to its dataset without running `zfs`? | **Yes** — `/proc/self/mountinfo` lists `/home/os7admin … zfs`. Longest-prefix match is pure C# |
| M-V11 | Does the snapshot directory carry the snapshot's time? | **NO, AND IT LIES.** See below |
| M-V12 | What is `usedbysnapshots`? | A real per-dataset property: `1.54M` on this one. Pool at `12%` capacity |

### M-V11 — `stat` on a snapshot directory reports a time that is not the snapshot's

Four snapshots taken minutes and days apart all report the same `mtime` and `ctime`:

```
autosnap_2026-09-09_09:56:06_daily     mtime = 2026-09-09 11:37:15
autosnap_2026-09-09_09:56:06_weekly    mtime = 2026-09-09 11:37:15
autosnap_2026-09-10_00:00:03_daily     mtime = 2026-09-09 11:37:15   ← a day later
```

while ZFS itself says `Wed Sep 9 11:56`, `Wed Sep 9 11:56`, `Thu Sep 10 2:00`. The directory's
timestamp is the dataset root's mtime *inside* that snapshot — a real value, about something else.

**This decides the architecture.** A window that read times from `stat` would be confidently,
silently wrong about every entry on its timeline, which is the one thing a timeline cannot be. The
times must come from ZFS. Parsing them out of sanoid's snapshot *names* is the other tempting option
and is refused: it works only for snapshots sanoid made, and an administrator's own
`zfs snapshot rpool/USERDATA/x@before-the-migration` is exactly the one somebody will look for.

---

## 3. Decisions

### V1 — Versions are a READER. This feature takes no snapshots of its own. Proposed 2026-09-14.

`sanoid` takes them and prunes them, under B5's policy, on `rpool/USERDATA`. The Versions feature
lists what exists and reads out of it. It does not schedule, and it does not prune.

The one exception is V8 (a snapshot immediately before a restore), which is a single snapshot taken
at an operator's explicit request, not a policy.

### V2 — The times come from ZFS; the contents come from the filesystem. Proposed 2026-09-14.

Forced by M-V11. `zfs list -t snapshot -o name,creation`, through the **Zfs module** (Z1/P2 — OS7
code never calls `zfs` itself), gives the timeline. `/mountpoint/.zfs/snapshot/<name>/<rel>` gives
the bytes, and that is ordinary `System.IO` in C#.

The split is not a compromise. Asking ZFS for 44 snapshots costs 16 ms (M-V8) and happens once per
window; reading file contents through a cmdlet would put a `pwsh` launch in front of every preview.

### V3 — The whole feature is one C# application, and the file manager only launches it. Proposed 2026-09-14.

```
os7-versions <absolute path>
```

That is the entire contract between OS/7 and whatever file manager is installed. The application
resolves the dataset, lists the snapshots, draws the window, and performs the restore.

**This is what survives a change of file manager**, which was a stated requirement. The adapter for
each manager is a few lines that run one command:

| manager | adapter | kind |
|---|---|---|
| **Nautilus** (today) | a `nautilus-python` extension, ~30 lines | code, but trivial |
| Nemo, Caja | the same API under another name | code, trivial |
| Thunar | a "custom action" | **pure XML config** |
| Dolphin / KDE | a `.desktop` ServiceMenu | **pure config** |
| anything at all | a `.desktop` with `MimeType=all/all`, appearing under *Open With* | **pure config** |

No adapter contains any logic, and none of them can be wrong about anything except the path they
pass. If a future OS/7 ships a different file manager, the work is one file, not a port.

### V4 — The menu entry is localised even though the window is not. Proposed 2026-09-14.

`Name=Versions`, `Name[de]=Versionen` in the desktop entry, which the desktop-entry specification
localises for free. GL8 keeps the *window* English in v1; the context-menu item is different in kind,
because it sits inside the file manager's own menu between entries that are all in the operator's
language, and a lone English word there reads as a bug.

### V5 — It works on a file and on a folder, and the folder case is the point. Proposed 2026-09-14.

Right-clicking a **file** shows that file's versions. Right-clicking a **folder** (or the background
of one) browses the folder *as it was*, which is the case that finds a file somebody deleted three
weeks ago — measured possible in M-V4 and the thing an operator cannot do today by any means.

### V6 — A path with no version history says so. Proposed 2026-09-14.

`/etc`, `/var/log`, a USB stick, an NFS mount: no ZFS dataset, or one nobody snapshots. The window
says which of those it is. It must never show an empty list, because an empty list means "nothing
changed" and this means "nothing is being kept".

### V7 — Three verbs, and only one of them changes anything. Proposed 2026-09-14.

| verb | what it does | privilege |
|---|---|---|
| **Open** | opens the old version read-only, in whatever handles that type | none (M-V5) |
| **Copy to…** | writes a copy where the operator chooses; the original is untouched | none |
| **Restore** | replaces the live file | none for one's own home; see V9 |

*Open* and *Copy to…* are first because most of what people want from a versions feature is to
**look**, and a design whose only verb is the destructive one makes looking dangerous.

### V8 — A restore takes a snapshot first, so the restore itself is undoable. Proposed 2026-09-14.

55 ms (M-V7). Without it, restoring yesterday's file over today's work destroys the work with no way
back, and the feature whose entire purpose is "you can go back" would have a one-way door in it.

The snapshot is named for what it is (`os7-before-restore-<timestamp>`) and is **exempt from sanoid's
pruning by name**, for a bounded period — otherwise the safety net is thinned away by the policy
that did not create it.

### V9 — Restoring is done by the PowerShell surface, not by the window. Proposed 2026-09-14.

G3. Reading is observation and the window may do it directly (V2); restoring changes the machine,
takes a snapshot first (V8), and has to decide what to do when the live file has changed since the
window was opened. Those are decisions, and decisions live in cmdlets:

- ~~`Get-OS7FileVersion -Path <p>`~~ — **IT ALREADY EXISTED.** `powershell/OS7/OS7.BackupRestore.ps1`
  has had it since the backup work, with `-DistinctOnly`, `-Newest` and `-IncludeCurrent`, and
  [BACKUP-PLAN.md](BACKUP-PLAN.md) §344 and its cmdlet table document it. **This plan proposed
  building it because nobody grepped**, and a session then built a second one before noticing —
  removed again the same hour. It works on a machine, unprivileged (§7b).
- ~~`Restore-OS7FileVersion`~~ — **`Restore-OS7File` already exists too**, beside it. What it does
  NOT do is V8's snapshot-before-restore; that is the part still owed, and it is a change to an
  existing cmdlet rather than a new one.
- `Get-OS7VersionStore [-Dataset <d>]` — what the history costs and how much headroom is left. This
  one was genuinely new and is built.

**The lesson is about this file rather than the code.** A plan that lists cmdlets to build has to be
written against `Get-Command`, not against memory — the same rule
[POWERSHELL-REFERENCE.md](POWERSHELL-REFERENCE.md) exists for, and the same one
`check-module-parts.py` enforces on the counts. Two of the three were already there.

G7 also requires this: a headless or arm64 machine has no window, and USERDATA snapshots exist there
just the same. An administrator must be able to recover a file over ssh.

### V10 — The layer check needs a per-application scope, and this is what shows it. Proposed 2026-09-14.

`check-gui-logic.py` forbids any application assembly from touching the filesystem — written for
Software Update, where it is right. For Versions the filesystem *is* the subject. The rule becomes
per-project: an application declares what it may reach, and Versions declares "the user's own tree
and `.zfs/snapshot` under it, read-only". The default stays "nothing".

Recorded as a decision rather than a note because the alternative — quietly exempting a directory —
is how a rule stops meaning anything.

---

### V17 — The boundary stays, and a run of it collapses to the NEWEST. Decided 2026-09-14.

Owner's decision. A version list shows not only the snapshots that hold the path but a row for the
point at which it was **not there** — *"This file did not exist at this point."* Without it the list
answers "give me the file back" and not "when did this appear", and the second is the question a
Time-Machine window is opened with.

`Get-OS7FileVersion -IncludeAbsent` reports it. Without the switch the cmdlet behaves as it always
has, which keeps every existing caller unchanged.

**Which member of an absent run is kept is the whole of the design.** `-DistinctOnly` keeps the
OLDEST of a present run — "it has looked like this since" — and the **NEWEST** of an absent one:
"this is the last moment it is known not to have been there". Measured on a machine: 30 absent
snapshots collapsed to one, and that one names 20:00 on the day the file appeared at 20:39. Keeping
the oldest instead would have been equally true and nearly useless — it names the beginning of
recorded history, and brackets the change to five days instead of thirty-nine minutes.

A boundary row offers no verb: there is nothing to open and nothing to copy, and the window disables
both rather than failing when they are used. `Restore-OS7File` refuses one too, in its own words.

### V18 — The window asks the cmdlet. Decided 2026-09-14, and built.

`os7-versions` resolved datasets, listed snapshots and collapsed version runs in C# of its own until
2026-09-14. That made "which versions are worth showing" a decision implemented twice, in two
languages, and the two did not even agree. It calls
`Get-OS7FileVersion -DistinctOnly -IncludeCurrent -IncludeAbsent` now and arranges what comes back.

**Four files left the application**: `MountTable.cs`, `VersionStore.cs`, `ZfsCli.cs` and
`SnapshotRef.cs`. Its capability grant in `check-gui-logic.py` shrank from four files to two, and
what it may still open is the *contents* of a version — bytes, not decisions. Its self-test lost the
mount-parsing and collapsing cases because those moved to `check-storage-logic.py` §5 and §6, where
an administrator over ssh is covered by them too.

**Every refusal is now the cmdlet's own sentence**, reaching the window unaltered — which is what
makes V6 real rather than a rule the window re-implements.

## 4. The window: Time Machine in Windows 2000's vocabulary

Apple's Time Machine is a receding stack of the same window at different times, over a starfield,
with a timeline down the right edge. Three of those four translate; one must not.

### V11 — Cascade, not perspective. Proposed 2026-09-14.

Windows 2000 had no compositing and no 3-D, but it had a well-known way of showing *the same kind of
thing, several times over*: **MDI cascade** — child windows stepping down and right, each showing its
own title bar. Every Windows administrator has used `Window → Cascade`.

So the stack is a cascade of bevelled panels stepping up-and-left, the front one live and full, the
ones behind showing only their caption. It reads as depth without pretending to be 3-D, and it is
drawable with `BevelBorder` and an offset — no new primitive.

### V12 — The active/inactive caption IS the "now versus then" signal. Proposed 2026-09-14.

This is the part the palette already knows how to say. `os7-ui` carries both caption gradients:

```
os7_title  #0a246a → os7_title2  #a6caf0     active
os7_ititle #808080 → os7_ititle2 #b5b5b5     inactive
```

The selected point in time gets the **active** caption; every layer behind it gets the **inactive**
one. Windows 2000 used exactly that pair to mean "this is the one you are working in", and that is
precisely what the front of the stack means here. Nothing needs inventing.

Each caption reads `Dokumente — 14.09.2026 15:04`.

### V13 — The timeline is a trackbar, and the arrows are scrollbar steppers. Proposed 2026-09-14.

Time Machine's right-edge timeline becomes a **vertical sunken groove with tick marks and a
draggable thumb** — the Windows 2000 trackbar, which is a period control and already the shape of
`os7-ui`'s ScrollBar. Ticks are denser where snapshots are denser, which under B5 means the last day
is fine-grained and the last quarter is coarse — the timeline draws the retention policy without
explaining it.

Back and forward are the **stepper buttons** from the scrollbar: raised bevelled squares with
triangle glyphs, already built.

**No starfield.** The background behind the cascade is the OS/7 desktop, dimmed. A nebula would be
the one element that turns a design into a costume, and this desktop is black on purpose.

### V14 — Restore is the default button, and it is not the only way out. Proposed 2026-09-14.

Bottom right, `Abbrechen` / `Restore`, with the default button's black ring — the same pair as every
other OS/7 window and the same pair Apple used. *Copy to…* sits beside them rather than in a menu,
because V7 puts looking before replacing.

---

## 5. Space, thresholds, and the decision this collides with

**This is the hard part, and it is not a snapshot problem.**

A snapshot pins the blocks a file occupied when it was taken. A user who deletes a 10 GiB video gets
none of that space back until every snapshot referencing it has expired — under B5, up to three
months later. The feature therefore makes a machine's free space depend on its history, and it makes
users *value* that history, which makes deleting it a support conversation rather than a cron job.

**What can be measured today** (M-V12): `usedbysnapshots` per dataset, `avail` per dataset, and the
pool's `cap`. All three are properties, cheap to read, and `Get-OS7VersionStore` is where they are
reported honestly — how much the history costs, how much room is left, and how far back it reaches.

**What is NOT decided, and this plan does not pretend to decide it:**
[BACKUP-PLAN.md](BACKUP-PLAN.md) **BL5** already says it — *"backup retention and boot-environment
retention are one decision and only half is made"* — and UL9 says boot environments have no retention
policy at all while holding the prior claim on `rpool`. B5 adds the consequence in its own words: a
retention policy that fills `rpool` does not merely lose backups, **it can stop the machine
updating**.

So there are already two consumers of one pool with no shared budget, and Versions would be a third
— except that it consumes nothing new, because V1 makes it a reader of B5's existing snapshots.
**That is the strongest argument for V1**, and it is why this plan proposes no second thinner:

- A pressure-triggered thinner here would be a *fourth* opinion about what may be deleted.
- Two autonomous thinners on one pool is the shape where both report success and the pool fills
  anyway.

**What this feature should do instead** is make the cost visible and make BL5 urgent:

1. `Get-OS7VersionStore` reports the cost per user and for the pool.
2. The window says, in one line, how far back history reaches and what it occupies.
3. When the pool crosses a threshold, the machine **says so** — through the existing device/health
   surface — rather than silently thinning something.

### V15 — Three levels, and the destructive one has to prove it would help. Decided 2026-09-14.

Owner's decision. Pool capacity, as `zpool list` reports it:

| | | |
|---|---|---|
| **70 %** | **Warn** | Say so. Delete nothing. |
| **80 %** | **Tighten** | Tighten the retention policy and let **sanoid** prune under it. |
| **90 %** | **Refuse** | Retention to the floor, no new version snapshots, say so loudly. |

**70 is a notice level and not a deletion level.** The ~80 % figure quoted everywhere for ZFS is
about performance degradation, not failure; deleting a user's file history while 30 % of the disk is
free would astonish anybody. What 70 buys is *time*.

**It deletes no snapshot itself.** At 80 % it rewrites the policy sanoid prunes *by* and sanoid does
the deleting — one thinner (§1). A pressure rule deleting "oldest first" would delete exactly the
monthlies sanoid is trying to keep, leaving an effective retention nobody configured.

**And it is gated on whether it could work.** `Get-OS7StoragePressure`'s `WouldHelp` is `$false` when
every snapshot and every prunable boot environment together cannot reach the target — which means
the live data is what is full, and deleting the history would cost it and change nothing. At that
point nothing is deleted and the reason is reported. `-Force` overrides it for an operator who has
read why. At **Refuse** the gate does not apply: every byte counts there.

**The floor is `hourly=24 daily=7`**, at any pressure. A feature that silently becomes useless under
load is worse than one that says it is under load.

### V16 — The boot environment before the last update is never pruned. Decided 2026-09-14.

Owner's decision, and it closes the half of **BL5** that was open. More environments may exist and
those are subject to V15; the running one and **the newest one older than it** — the one an operator
would boot to undo the last update — are not candidates at any pressure.

**Derived from creation order, not from a marker.** Nothing writes "this is the one before the last
update" anywhere, and a marker would be a second source of truth that an interrupted update could
leave pointing at the wrong environment. When the running environment cannot be identified at all —
a live medium, a container — **every** environment is protected, because refusing to prune what you
cannot reason about is the only safe direction.

A machine that freed space by deleting its own way back cannot recover from the update it made room
for.

### What is built

`powershell/OS7/OS7.Storage.ps1`: `Get-OS7StorageThreshold`, `Get-OS7StoragePressure`,
`Invoke-OS7StorageRelief`, `Get-OS7ProtectedBootEnvironment`, `Get-OS7VersionStore` — and
`Get-ZfsPool` in the generic layer, which did not exist and which Z1 required rather than letting
OS/7 call `zpool` itself. `installer/testing/check-storage-logic.py` holds every decision above
against a fake pool: 37 checks, no ZFS, seconds.

---

## 6. What it deliberately does not do

- **It is not a backup.** Same pool, same disk. A snapshot survives a mistake and not a disk. The
  off-machine half is `syncoid` replication, [BACKUP-PLAN.md](BACKUP-PLAN.md), and the window must
  not let anybody confuse the two.
- **It does not version `/etc` or the system.** That is what boot environments are, and `Restore-OS7`
  is their verb. V6 says so to the operator's face.
- **It does not delete snapshots.** Ever. Not even "clean up old versions". That is sanoid's, and
  giving a window a destructive verb over a shared resource is how one user frees space another was
  relying on.
- **It does not index or scan.** No background crawler, no database of what changed when. The
  filesystem answers in 16 ms; a cache would be a second source of truth for no gain.

---

## 7. Limitations and open questions

**Limitations**

- **VL1 — only ZFS datasets that are snapshotted.** In practice `rpool/USERDATA` and
  `rpool/DATA/srv` (B5). A file anywhere else has no history, and V6 makes the window say it.
- **VL2 — granularity is the policy's.** B5's finest bucket is hourly, so work done and undone
  within an hour is not recoverable. Time Machine has the same property and the same reason.
- **VL3 — a snapshot is not a backup** (above).
- **VL4 — space is consumed by history the user cannot see the size of per-file.** ZFS accounts
  `usedbysnapshots` per dataset, not per file; "which of my files is costing me 8 GiB" is not a
  question ZFS answers cheaply.
- **VL5 — amd64 GUI only for the window** (GL1). The cmdlets (V9) work everywhere, which is why
  they exist.
- **VL6 — a renamed or moved file loses its thread.** The path is the identity, so
  `notes.txt` → `notes-old.txt` looks like a deletion and a creation. Time Machine behaves the same
  way; naming it here stops it being reported as a defect.
- **VL7 — domain users' homes are not on USERDATA datasets.** They live under
  `/var/lib/os7/domain-homes` ([DECISIONS.md](DECISIONS.md) open question 10), which is `rpool/DATA`
  and not in B5's policy. **A domain user would have no versions at all**, and that is the same open
  question arriving in a third place.
- **VL8 — nothing here is built.**

**Open questions**

1. ~~**O-V1 — does the cascade actually read as depth at 96 dpi?**~~ — **ANSWERED 2026-09-14, on a
   machine: yes.** Five layers stepping up-and-left, grey inactive captions behind a blue active
   one, reads immediately as a stack of times. V12 carries it without a legend. Two things had to be
   fixed after seeing it, and neither was the idea: three snapshots taken inside one minute drew
   three identical captions (the list now gains seconds when it needs them, for every row at once),
   and stepping to the oldest version made the front panel grow as the stack behind it ran out — so
   `CascadePanel` now reserves the room and the front layer stays put.
2. **O-V2 — what does a preview cost?** *Narrowed:* a text preview of a small file is free at 64 KiB
   and is what makes the window worth opening — the old version is readable in place rather than by
   opening each one. Unmeasured is the case that will hurt: a folder of 400 photos at four points in
   time.
3. ~~**O-V3 — the thresholds.**~~ — **DECIDED 2026-09-14 (V15): 70 warn, 80 tighten, 90 refuse.**
   What is STILL not measured is what ZFS on this layout actually does at those capacities: the
   numbers are a policy arrived at by argument, and the performance behaviour behind them is
   received wisdom rather than anything measured here. Worth a bench run of its own before a
   `stable` release — it could change the numbers, and cannot change the shape of the rule.
4. **O-V4 — how many snapshots before the UI stalls?** 44 listed in 16 ms. B5's policy tops out
   around 45 per dataset, so this is comfortable today — but a machine with ten users has ten
   datasets, and `zfs list -t snapshot` without `-r <dataset>` is a different cost.
5. ~~**O-V5 — does the Zfs module already expose `creation`?**~~ — **ANSWERED 2026-09-14 by reading
   it.** `Get-ZfsSnapshot`, `New-ZfsSnapshot` and `Remove-ZfsSnapshot` all exist, and
   `Get-ZfsDataset` returns **`Creation` as a real `[datetime]`**, converted from ZFS's Unix epoch
   under `--json-int` — the module's own comment records that as measured. So the timeline sorts by
   `DateTime` and not by text, which is the trap it would otherwise have walked into, and V8's
   pre-restore snapshot has a cmdlet waiting for it. **V2's ZFS half needs no new Zfs code at all.**
6. **O-V6 — Nautilus's extension surface on GNOME 50.** `nautilus-python` is an archive package and
   its API has changed across GNOME generations; whether it is in the pinned snapshot, and at what
   version, has not been checked. If it is absent, the `.desktop`/*Open With* fallback is the v1
   route and the context menu waits.
7. **O-V7 — should the boot environment's own history appear here too?** An operator asking "what
   did this config file look like last week" is asking the same question about `/etc`, which is
   inside the BE and has snapshots of a different kind. Answering it would make the feature whole
   and is a larger design.

---

## 7a. What building steps 1–3 measured, 2026-09-14

**`src/OS7.App.Versions/` is built and read-only, and it has run on a machine
against real snapshots.** `--self-test` is 62 checks with no ZFS and no display;
`check-gui-logic.py` holds the layer rules for both applications.

| | |
|---|---|
| The cascade | Reads as depth (O-V1). The palette carries "now versus then" on its own |
| The read path | `/proc/self/mountinfo` → dataset, `Get-ZfsSnapshot` → times, `.zfs/snapshot/…` → contents. Unprivileged throughout |
| Collapsing | Four demo snapshots of three contents drew three rows on a machine, with the unchanged one absorbed — V's `Distinct` working against real ZFS rather than fixtures |
| The deleted case | Selecting a point before the file existed says *"This file did not exist at this point."* — which is the whole reason for the feature (V5) |
| Text preview | Added after seeing the first window: five versions and no way to read any of them is the work an operator came to avoid |

**V10 is implemented rather than merely proposed.** `check-gui-logic.py` now
declares capabilities per project — Versions may open files in four named
files, `OS7.Shell` may start a process in one, everything else may do neither,
and a project nobody declared fails the check. The grant is required to stay
narrow, because a project that declared everything would pass and mean nothing.

**And one thing was found that belongs to the design system rather than here:**
a global `TextBlock` foreground was overriding every disabled state in the
product, so a correctly-disabled button looked pressable — in **both**
applications, through a whole machine run ([BUILD-NOTES #153](BUILD-NOTES.md)).
No check here could have seen it; two screenshots side by side could.

**Also learned, about checks rather than code:** a self-test that asserted
`"2026-09-14 20:39:10"` was asserting the test host's timezone, and went red in
a UTC container while being green on a +02:00 machine. Captions are rendered in
local time, so the assertions are about shape now, not value.

---

## 7b. The cmdlet already existed, and asking it found a defect — 2026-09-14

`Get-OS7FileVersion` and `Restore-OS7File` have been in
`powershell/OS7/OS7.BackupRestore.ps1` since the backup work. This plan's V9
proposed building them, a session started to, and the duplicate was removed
within the hour — the psd1's own export list caught it, because the name was
suddenly in it twice and `check-module-parts.py` went red on a count that no
longer matched.

**It works on a machine**, which had not been shown before: against the demo
file's four snapshots it returned 24, 50 and 77 bytes plus the live 38,
`-DistinctOnly` collapsed the unchanged one, and it did all of that as the
unprivileged owner. That also settles **BACKUP-PLAN BL9**, which said the
assumption the restore path rests on — that `snapdir=hidden` still permits
explicit traversal of `.zfs/snapshot` — was unmeasured. It is measured now
(M-V4, M-V5, M-V6).

**And one defect, which is the kind this repository collects.**
`Get-OS7FileVersion /proc/cpuinfo` returned **zero versions in silence**. The
refusal it should have given is written, correct and well-phrased —

> '/proc/cpuinfo' is not inside a mounted ZFS filesystem, so it has no
> snapshots. Only ZFS datasets have versions…

— and it was **unreachable**. `Get-OS7PathDataset` resolves ownership by
comparing the path against ZFS *mountpoints*, which cannot see that `/proc`,
`/dev`, `/run`, `/sys` and `/tmp` interrupt the root dataset: on a machine whose
`/` is a boot environment, every one of those paths is "under" it. The guard
never fired, and the caller got an empty list — which by V6's own argument is
the wrong answer, because empty means "nothing changed" and this means "not a
place that has versions".

Fixed by asking the kernel: `Get-OS7PathMount` reads `/proc/self/mountinfo` and
`Get-OS7PathDataset` now refuses when something that is not ZFS is mounted
between the dataset and the path. Eight cases in
`installer/testing/check-storage-logic.py` §5 hold it, including the two that
were silently wrong and the `/home/os7admin2` prefix trap.

**It matters for this feature specifically**: the file manager hands over
whatever path was right-clicked, and a window that says "no versions" for
`/proc` teaches an operator that the feature is unreliable rather than that the
path is.


## 8. Order of work

1. ~~**A mock-up of the window**~~ and ~~**3. `os7-versions <path>`, read-only**~~ — **DONE
   2026-09-14**, together: the real read path drew the real window, so the mock-up was the product
   and nothing was thrown away. §7a is what it measured.
2. **`Get-OS7FileVersion`** and its check, with no window: it is what V9 needs and what a headless
   or arm64 machine gets, and it is now the largest gap — the window exists and the cmdlet does
   not, which is G7 the wrong way round.
4. **The Nautilus adapter**, plus the `.desktop` fallback, once O-V6 is answered.
5. **`Restore-OS7FileVersion`** with V8's pre-snapshot, and Restore in the window.
6. **`Get-OS7VersionStore`**, and the honest space reporting — which is where BL5 has to be faced.

Steps 1–4 change nothing on a machine. The first destructive verb appears at step 5, by which point
the window has been looked at by somebody.
