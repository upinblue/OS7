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
* **No ISO carries any of this.** The module reached the bench by file copy.
