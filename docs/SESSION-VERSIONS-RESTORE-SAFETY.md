# V8 and V19 on a machine — what a restore keeps, against real ZFS

**2026-09-14 and 2026-09-15, bench `gui`: an installed, booted OS/7 1.0.0.163
amd64 machine, from the named snapshot `v8-ready`.** Everything below was typed at
that machine.

`installer/testing/check-storage-logic.py` §7 and §8 are the harness and they run
against a fake ZFS. This is what a fake cannot answer: whether `zfs snapshot`
accepts these names, whether the snapshot HOLDS the bytes the restore destroyed,
whether restoring it gives the work back — and **who is allowed to take one**.

The last of those is the finding. It reversed a property the plan was built on,
and answering it changed the feature: **V19, decided by the owner 2026-09-15** —
a restore keeps what it is about to overwrite by the strongest means available
where it stands, and the weaker means is the one Time Machine itself uses.

---

## 1. What was measured

| # | Question | Answer |
|---|---|---|
| M-V13 | Does the safety snapshot exist, and does it hold what was overwritten? | **Yes to both.** `rpool/USERDATA/os7admin_af456a8e@os7-before-restore-20260914-232359`, listed by ZFS, created 23:23:59 — and `…/.zfs/snapshot/<it>/v8/notes.txt` reads `TODAYS WORK`, the bytes the restore replaced |
| M-V14 | Does the way back actually work? | **Yes.** `Restore-OS7File -Snapshot os7-before-restore-… -Force` put `TODAYS WORK` back. The restore was undone by the thing the restore made |
| M-V15 | Is one taken when nothing is overwritten? | **No.** `-Destination` to a path that did not exist: `SafetySnapshot` `$null`, snapshot count unchanged, file delivered |
| M-V16 | Whose dataset? | **The destination's.** The version came out of `rpool/USERDATA/os7admin_af456a8e`; restoring it to `/srv/v8/notes.txt` snapshotted `rpool/DATA/srv`, and that snapshot holds `srv had its own` |
| M-V17 | Does the prune keep five, and does it leave sanoid alone? | **Yes.** Seven separate invocations → 7 snapshots, 5 remain, and they are the newest five. Sanoid's count was **32 before and 32 after** |
| M-V18 | Does the one-second collision really happen? | **YES, THREE TIMES IN ONE MEASUREMENT.** The seven invocations took about four seconds and produced `…-232401`, `…-232401-2`, `…-232402`, `…-232402-2`, `…-232403`, `…-232403-2`, `…-232404`. Without the uniqueness suffix three of those seven restores would have failed (BUILD-NOTES #159) |
| M-V19 | Two files, one invocation? | **One snapshot**, named by both results, both files restored |
| M-V20 | A destination ZFS does not own? | `/dev/shm` is `tmpfs`: `SafetySnapshot` `$null`, the warning printed, **and the restore still happened**. Not a refusal |
| M-V21 | What does the operator see before answering? | `… to /home/os7admin/v8/notes.txt (snapshotting /home/os7admin/v8/notes.txt first, so this can be undone)` when one will be taken, and no such clause when none will. `-WhatIf` wrote nothing and took nothing |
| **M-V22** | **Can the OWNER of the file do this, as themselves?** | **NO — and this is the finding.** See §2 |

---

## 2. M-V22 — the owner can read every version and cannot take a snapshot

Typed as `os7admin`, uid 1000, restoring a file in their own home:

```
  versions this account can see = 3
  restored = NO
  refusal = zfs snapshot rpool/USERDATA/os7admin_af456a8e@os7-before-restore-…
            exited 1
            cannot create snapshots : permission denied
```

**Reading needed no privilege and writing the safety net does.** That is M-V5
exactly — *"`su - os7admin` listed the snapshots and read the file. Browsing and
restoring into one's own home need no privilege and therefore no polkit"* — meeting
a fact about ZFS: `zfs snapshot` is root's, delegation aside, even on a dataset
whose files belong to the caller.

So V8, **as built on 2026-09-14, narrowed who could restore.** Before it, an owner
restored their own file as themselves; for one day after it, they were refused
unless they elevated or gave the safety net up. Nothing about that is visible from
a fake ZFS, and nothing about it was visible in the plan.

**The first fix was the sentence**, and it still stands where it applies. What the
owner saw was `cannot create snapshots : permission denied` — a raw tool error
naming no verb and no way forward, which is BUILD-NOTES #148's and #149's
signature. Every refusal on this path now leads with the clause that matters to a
person — *the file you came here about has NOT been written and nothing is lost* —
then both roads in #148's exact form, then the tool's own words, because they say
why.

**The second fix was the decision, the next day, and it removed the refusal from
this case entirely.** V19, and the answer came from asking what Time Machine
actually does.

Time Machine takes **no snapshot before a restore at all**. `backupd` is a root
daemon and the APFS snapshots are the system's — a user cannot make one — and
when something is already at the restore destination the choice offered is *Keep
Original / Keep Both / Replace*, where "Keep Both" **puts the existing file aside
under another name**. Windows' Previous Versions has the same shape: VSS
snapshots are an administrator's, and the tab offers *Copy* beside *Restore*.
(Recalled rather than measured — there is no macOS machine here, and this
document says so rather than dressing it up as a reading.)

So OS/7 keeps what is about to be overwritten **by the strongest means available
where it stands**: a ZFS snapshot of the destination's dataset where that can be
had, and otherwise the destination itself, renamed to
`<path>.os7-before-restore-<stamp>`. A rename needs only write permission on the
containing directory, which the owner of a file in their own home has, and it is
the same inode, so it costs no space. §2a is that, measured.

The refusal above now fires only where **both** roads are shut — and, separately
and deliberately, where ZFS reported success and produced no snapshot, which is a
fault rather than a "no" and must not quietly take the weaker road.

**The two roads NOT taken**, both of which were on the table and neither of which
is ruled out for ever:

1. **Route the restore through polkit and a templated unit**, the way
   `os7-update@.service` does (G5) and `Start-OS7Job` widens (AU1). Correct and
   consistent with the product — and it puts a root-run `rsync` where a user-run
   one would do, for "put my file back".
2. **`zfs allow -u <owner> snapshot` on their own USERDATA dataset**, set by
   `New-OS7Storage` at creation with a firstboot migration. ZFS's own mechanism
   for precisely this, and it would give M-V5 back whole. `snapshot` alone and
   **never `destroy`** — an account able to destroy snapshots of its home could
   destroy sanoid's, and that is the backup policy this feature reads. It would
   permanently change what every machine's storage layout grants its accounts, to
   buy a case the rename already answers; and it has no counterpart in either
   reference product, since macOS grants no user the right to snapshot.

---

## 2a. V19 measured, as the owner, uid 1000

Same bench, same account, with the decision built:

| # | Question | Answer |
|---|---|---|
| M-V23 | Is the owner still refused? | **No.** `SafetySnapshot` empty, `SafetyCopy = /home/os7admin/v8/notes.txt.os7-before-restore-20260915-073919`, live file restored — as uid 1000, no `sudo`, no prompt |
| M-V24 | Does the copy hold the work the restore replaced? | **Yes**: `TODAYS WORK, unsnapshotted`, which was in no snapshot anywhere. Moving it back by hand put the work back |
| M-V25 | Two restores of one file? | Two distinct copies, `…073919` and `…073920`, each holding its own moment (`first work` / `second work`) |
| M-V26 | What does the prompt say now? | `… (keeping /home/os7admin/v8/notes.txt first, so this can be undone)` — the word changed with the mechanism |
| M-V27 | Does root still get the better road? | **Yes.** As root the same restore produced `SafetySnapshot = rpool/USERDATA/os7admin_af456a8e@os7-before-restore-20260915-073944`, holding `root work`, and **no** copy was made |

**One cosmetic wart, recorded rather than fixed.** `New-ZfsSnapshot` writes its
`ZFS-STEP snapshot …` progress line *before* invoking `zfs`, so an unprivileged
restore prints a step that did not happen, immediately above the
`OS7-STEP put … aside` line that did. It is stderr progress, not a claim in any
output object, and fixing it means changing Layer 2's step-then-do order for
every verb in the Zfs module. Named here so the next reader does not report it as
a defect.

---

## 2b. The automatic half, and the packages, on a machine — 2026-09-15

The owner's requirement: **the storage must be freed automatically when the system
needs it.** `Invoke-OS7StorageRelief` had existed for a day with 137 checks behind
it and nothing anywhere called it.

| # | Question | Answer |
|---|---|---|
| M-V28 | Does the packaged timer install and run? | **Yes.** `dpkg -i os7-backup`, then `systemctl start os7-storage-relief.service` → `Result=success`, and `/run/os7/storage-pressure` reads `{"Level":"Normal","Capacity":12,"Reason":"The pool is 12% full. Nothing to do."}` |
| M-V29 | Does the login banner stay silent on a healthy machine? | **Yes** — it prints nothing at Normal, which is the whole design: a banner that says "storage: ok" at every login trains people to skip the banner |
| M-V30 | Does dpkg own the files? | **Yes**, after a real install: `os7-backup` owns the units, the script and the banner; `os7-app-versions` owns the binary and the Nautilus extension |
| M-V31 | **Is the timer enabled by the package alone?** | **NO, AND THAT IS THE FINDING.** See below |
| M-V32 | Does apt pull the Nautilus binding? | **Yes**: installing `os7-app-versions` brought `python3-nautilus 4.1.0-1build1` and `gir1.2-nautilus-4.1` from the archive — the version O-V6 measured |
| M-V33 | Does the application run on the machine? | **Yes**: `/usr/lib/os7/apps/versions/os7-versions --self-test` → 58 ok, 0 failed, from the installed package |

### M-V31 — a timer that runs and reports that it will not

The package ships `/usr/lib/systemd/system/timers.target.wants/os7-storage-relief.timer`,
which is how `os7-backup` pre-enables its own units and is the pattern that
argues against `systemctl enable` in a postinst. With that symlink and nothing
else:

```
systemctl is-enabled os7-storage-relief.timer        →  disabled
systemctl list-dependencies timers.target            →  ● ├─os7-storage-relief.timer
```

**Both are true.** `timers.target` wants the unit, so it is pulled in at boot and
the automatic relief runs; `is-enabled` reports only on `/etc`-level enablement
and answers "disabled". An administrator who checks the obvious verb would
conclude the feature is off.

The sibling timer reads `enabled` because **hook 0090 also runs `systemctl
enable` at image build** and then verifies the `/etc` symlink exists — belt and
braces, and the braces were missing here. The hook now enables and verifies this
one too, and `check-storage-logic.py` §10 holds both halves.

Found by asking `dpkg -S` who owned the files, which also caught a contaminated
bench: the first install was a no-op because the version already matched, so the
files under test were the ones this session had placed by hand an hour earlier.
BUILD-NOTES #93's shape, in a new place.

---

## 2c. What the packages are

| package | carries |
|---|---|
| `os7-backup` | `os7-storage-relief.service`/`.timer`, `/usr/libexec/os7-storage-relief`, `/etc/update-motd.d/40-os7-storage`, and `VERSIONS-PLAN.md` for the units' `Documentation=` |
| `os7-app-versions` | the window, the `NoDisplay` desktop entry, and the GNOME Files context-menu extension over `python3-nautilus` |
| `os7-powershell` | `$PSHOME/powershell.config.json` — `LogLevel: Error`, worth 2 MB of journal per pwsh invocation (BUILD-NOTES #160) |

Both new packages build from a clean tree: `os7-app-versions_1.0.0.163_amd64.deb`
(7.3 MB, 5 required paths present, its `--self-test` run inside the build) and
`os7-backup_1.0.0.163_all.deb` (10 required paths present, the banner at 0755 and
the PowerShell script at 0644 with no shebang).

---

## 2d. From an ISO, through the context menu, to a restore — 2026-09-15

**`OS7-1.0.0.231-amd64.iso`, installed onto bench `v19` (`--mode Gui`), logged in
at the OS/7 login screen, right-clicked in GNOME Files.** The medium carries
`os7-app-versions`, the Nautilus extension, the storage-relief timer and
PowerShell's log config, all dpkg-owned (`check-image.py`).

**THREE DEFECTS, AND NO CHECK IN THIS REPOSITORY COULD HAVE FOUND ANY OF THEM.**

| # | What happened | What it was |
|---|---|---|
| M-V34 | The context menu had no *Versions* entry | `gi.require_version("Nautilus", "4.0")` — the namespace on GNOME 50 is **4.1**, and nautilus-python has ALREADY required it before importing extensions, so the call cannot succeed and is not needed. Nautilus logged the traceback to the session journal and drew the menu without the entry, which looks exactly like a machine where nothing was installed |
| M-V35 | The window opened and said *the version list could not be read: The JSON value could not be converted to System.DateTimeOffset* | `Select-OS7DistinctVersion` ended with **`,@($kept)`** — the list as ONE object. `… \| Select-Object Path, Created, Length` then gives one row with every property null and `Length = 4`, the ARRAY's length |
| M-V36 | After a successful restore the window listed four snapshots and **no "Now"** | `rsync -a` preserves mtime, so the restored file is byte-identical to the version it came from AND carries its time. `-DistinctOnly` saw a run and kept its oldest member — the snapshot. `-IncludeCurrent` promises the live file is in the list and `-DistinctOnly` silently took it out |

M-V35 is the one worth dwelling on. **`check-storage-logic.py` §6 was green
throughout**, because it asked `… | ForEach-Object { $_.SnapshotName }` and
PowerShell's MEMBER ENUMERATION answers that correctly on an array: the names
came back right and the shape was wrong. The check now counts what the pipeline
delivers (`Measure-Object`) and reads the first object off it, neither of which
member enumeration can rescue; putting the comma back reddens three assertions.

M-V36 is not a collapsing bug — *"it has looked like this since 09:00"* is true.
It is that **the current version is not a moment in history; it is the thing the
history is about**, so it gets a row of its own whatever it resembles. The rule
is now in `Select-OS7DistinctVersion` and held by a case built from exactly this
sequence.

### What was then proven, in order

| # | Question | Answer |
|---|---|---|
| M-V37 | Does the entry appear? | **Yes** — *Versions*, in its own section above *Properties*, on a right-clicked file |
| M-V38 | Does it launch the application with the path? | **Yes**: `/usr/lib/os7/apps/versions/os7-versions /home/os7admin/Dokumente/Angebot.txt` |
| M-V39 | Does the window draw the history? | **Yes** — five versions, the cascade receding, *Now* in front with the active caption, sanoid's own `_monthly` bucket named on the row it took at 13:45 |
| M-V40 | Is *Restore…* disabled on the live file? | **Yes**, and enabled on an older one — the rule the self-test asserts, visible on a machine |
| M-V41 | Does the confirmation say it first? | *"Replace Angebot.txt with the version from 2026-09-15 13:40:29? What is there now is kept first, so this can be undone."* |
| M-V42 | **Does the restore happen, as an unprivileged owner, through the window?** | **Yes.** The live file reads `Angebot v1 - Entwurf.` |
| M-V43 | **And is V19's way back there?** | **Yes**: `Angebot.txt.os7-before-restore-20260915-134815`, 37 bytes, holding `KAPUTT - versehentlich ueberschrieben` — the work the restore replaced, renamed aside because `os7admin` may not snapshot. Time Machine's mechanism, on a machine, through a GUI, with no privilege and no polkit dialog |
| M-V44 | Is the backup policy live on a fresh install? | **Yes** — sanoid took `autosnap_2026-09-15_11:45:04_{monthly,weekly,daily}` on its own timer, the machine's first snapshots, in UTC as its units declare |

---

## 3. What this does NOT say

* **The Versions window is unaffected**, because it has no restore verb: V7 gave
  it *Open* and *Copy to…* only, both read-only. M-V22 is about the cmdlet — and
  because V19 is answered, the day V9's restore verb reaches the window it will
  work for an ordinary user without a polkit dialog, which is what M-V5 promised
  and V8 had briefly taken away.
* **Nothing here was run by a harness.** The bench is for looking
  (`.claude/skills/os7-lab`). What makes V8 true is `check-storage-logic.py`
  §7–§8, in a file of 102 checks against real files with a fake ZFS around them.
  Eight planted defects are proven to fire, one per rule. M-V22 is case I there,
  and its strongest assertion is the one that would have passed before V19 and
  must not now: **an owner who cannot snapshot is not refused their own file.**
* **arm64 is unmeasured**, as always.
* ~~**THE CONTEXT MENU HAS NEVER BEEN CLICKED**~~ — it has, §2d, and clicking it
  found three defects in an hour that every check in this repository had passed.
* ~~**No ISO carries any of this.**~~ — `OS7-1.0.0.231-amd64.iso` does, and a
  machine was installed from it.
* **THE THREE FIXES IN §2d HAVE NOT THEMSELVES BEEN THROUGH A FRESH INSTALL.**
  They were copied onto the running machine and verified there; the medium that
  installed it still carries the broken extension. The next ISO is what closes
  that, and until it is built this is a machine that was repaired rather than one
  that arrived working.
* **The medium cannot reach the OS/7 repository.** Built with
  `OS7_REPO_NO_CREDENTIAL=1`, which is four of `check-image.py`'s failures and one
  fact. Deliberate: this build existed to be installed and clicked.
