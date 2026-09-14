# V8 on a machine — the snapshot a restore takes, against real ZFS

**2026-09-14, bench `gui`: an installed, booted OS/7 1.0.0.163 amd64 machine, from
the named snapshot `v8-ready`.** Everything below was typed at that machine.

`installer/testing/check-storage-logic.py` §7 and §8 are the harness and they run
against a fake ZFS. This is what a fake cannot answer: whether `zfs snapshot`
accepts these names, whether the snapshot HOLDS the bytes the restore destroyed,
whether restoring it gives the work back — and **who is allowed to take one**.

The last of those is the finding, and it reverses a property the plan was built
on.

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

So V8, as built, **narrows who can restore**. Before it, an owner could restore
their own file as themselves. After it, they are refused unless they elevate or
give the safety snapshot up. Nothing about that is visible from a fake ZFS, and
nothing about it was visible in the plan.

**Two things were fixed the same hour, and one was left open on purpose.**

**Fixed: the sentence.** What the owner first saw was `cannot create snapshots :
permission denied` — a raw tool error naming no verb and no way forward, which is
BUILD-NOTES #148's and #149's signature. It is now a refusal in this product's
voice, measured on the machine:

```
the safety snapshot '…@os7-before-restore-…' could not be taken, so
'/home/os7admin/v8/notes.txt' has NOT been written and nothing is lost.

  Snapshotting a dataset needs root, even for the owner of the
  files on it. Either restore with privilege:

      sudo pwsh -NoProfile -c 'Restore-OS7File <parameters> -Force'

  or give the way back up deliberately, with -NoSafetySnapshot.

  ZFS said: …
```

The first clause is the one that matters to a person: **nothing was written**.
They came here because a file was in danger, and it is still there.

**Fixed: the behaviour is a refusal, not a silent weakening.** A restore that
could not be made undoable is not performed. Warning and carrying on would have
left exactly the case the feature exists for — a user overwriting today's work
with yesterday's — protected by nothing, quietly.

**Left open: V19**, which needs a decision rather than a fix. Three roads, and
the third is the one this repository would normally take:

1. **Leave it.** The owner elevates, or passes `-NoSafetySnapshot`. Honest, and
   it makes the everyday case of the feature an elevated one.
2. **Route the restore through polkit and a templated unit**, the way
   `os7-update@.service` does (G5) and `Start-OS7Job` widens (AU1). Correct, and
   heavy for "put my file back".
3. **`zfs allow -u <owner> snapshot` on their own USERDATA dataset**, set by
   `New-OS7Storage` at creation with a firstboot migration for existing machines.
   ZFS's own mechanism for precisely this, and it restores the property M-V5
   measured. `snapshot` alone, **not** `destroy` — a user who could destroy
   snapshots on their home could destroy sanoid's, which is the backup policy
   this feature is a reader of. The prune would then stay root's work, so a
   user-driven restore leaves one snapshot behind that the next privileged
   restore, or the next relief pass, would have to clear.

Road 3 changes what every OS/7 machine's storage layout grants, which is not a
thing to decide inside a restore cmdlet.

---

## 3. What this does NOT say

* **The Versions window is unaffected**, because it has no restore verb: V7 gave
  it *Open* and *Copy to…* only, both read-only. M-V22 is about the cmdlet, and
  it will be about the window on the day V9's restore verb reaches it — which is
  the day V19 has to be answered.
* **Nothing here was run by a harness.** The bench is for looking
  (`.claude/skills/os7-lab`). What makes V8 true is `check-storage-logic.py`
  §7–§8, which is 92 checks against real files and a fake ZFS with four planted
  defects proven to fire. M-V22's refusal is case I there.
* **arm64 is unmeasured**, as always.
* **No ISO carries any of this.** The module reached the bench by file copy.
