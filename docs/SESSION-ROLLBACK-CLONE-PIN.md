# A rollback inverts the clone direction, and nothing promoted on the way back

**2026-09-22, x64 Windows host, no machine.** Two findings from the 1.0.0.245
release gate ([SESSION-PREVIEW-245.md](SESSION-PREVIEW-245.md)), both
**pre-existing** and neither a regression: `Convert-ZfsClone` has been in
`powershell/Zfs/` since 1.0.0.203 and nothing in the product layer called it
except `Update-OS7`.

**The short version.** A boot environment is a `zfs clone`, so one of any pair is
un-destroyable and the other is not. `Update-OS7` has always known this and
promotes the environment it activates (UL9). `Restore-OS7` did not, so after a
rollback the direction stayed inverted and the environment an operator most wants
gone — the one they just rolled back FROM — was the one thing on the machine
that could not be removed. The second finding is the instrument: the `timer`
phase of `run-s5.py` depended on that removal working, said so in a comment, and
asserted nothing. It reported PASS on a run in which three of its four
assertions were satisfied by the leftover.

**Read §4 before adding a check here.** Writing the planted-defect half of
`check-be-logic.py` found two real defects in this session's own work, and one of
them was a check that was green against the defect it had just been written for.

---

## 1. What was measured, and by whom

| # | Question | Answer | Where |
|---|---|---|---|
| M-BE1 | Does `Remove-OS7BootEnvironment` fail on a machine that has rolled back? | **Yes**, with a raw `ParentContainsErrorRecordException` naming `-R` and the running machine's `/boot` | a machine (bench `.vm/manual`), 2026-09-21, by the session that reported this |
| M-BE2 | What is the origin direction after a rollback? | **Inverted on both halves**: `…245_…` is the clone of `…246_…@…` in bpool and rpool alike | same |
| M-BE3 | Is the topology uniform? | **No, it is mixed.** Top-level 245 ← 246; the children under `rpool/ROOT/os7_…246_…/var*` are 246 ← 245 | same |
| M-BE4 | Does promoting the two top-level halves let the removal run? | **Yes.** Two `Convert-ZfsClone`, then `Remove-OS7BootEnvironment` exits 0 | same |
| M-BE5 | Did the `timer` phase's removal actually fail on the 245 gate? | **Yes**, and the count it collected was never printed at all — the throw ended the statement first | `.vm/s5/timer-1.serial.log`, read this session |
| M-BE6 | What did the phase then measure? | **The leftover.** The check logged `already waits`, which is the branch that stages nothing | same log, §3 |
| M-BE7 | Do the fixes hold against a fake ZFS that models the refusal? | **Yes**, 34 checks | `check-be-logic.py`, this session |
| M-BE8 | Can each new rule be seen to FAIL? | **Yes**, three planted defects, each caught | `check-be-logic.py --self-test` |
| M-BE9 | Do the fixes hold **on a machine**? | **NOT MEASURED.** See §6 | — |

M-BE1 to M-BE4 were taken on a machine by the session that filed the findings.
Everything this session added is checked against a fake ZFS and against a
recorded serial log. **No VM was started for this work.**

---

## 2. The finding, and why the direction is the whole of it

```
cannot destroy 'bpool/BOOT/os7_1.0.0.246_202609211744': filesystem has dependent
clones use '-R' to destroy the following datasets:
bpool/BOOT/os7_1.0.0.245_202609211528
```

The dataset ZFS offers to take with `-R` is the running machine's `/boot`.

`zfs destroy` refuses for a clone that lives **outside** the subtree being
destroyed. A clone **inside** it is not a problem at all — a clone can always be
destroyed; it is the ORIGIN that is pinned. That distinction is not academic
here, because M-BE3 measured a mixed topology: `zfs promote` is per-dataset and
**not recursive**, so UL9 promotes the two top-level halves and every child keeps
the origin it was cloned with. An implementation that promoted "everything that
is a clone" would have promoted datasets inside the doomed subtree, which is
work with no effect, and one that promoted "the other environment" would have
been right by accident on this machine and wrong on the next.

So the question the code asks is: **is anything outside this subtree a clone of
something inside it.** `Get-OS7CloneDependent` in
[powershell/OS7/OS7.psm1](../powershell/OS7/OS7.psm1) asks exactly that, of the
whole pool rather than of `ROOT/` and `BOOT/` — a clone of a boot environment's
snapshot is not obliged to live beside boot environments.

### 2.1 The decision, and the evidence that settled it

Two shapes were on the table: promote automatically, or refuse with a sentence
naming `Convert-ZfsClone`. What settled it is that **the product had already
decided**. `Update-OS7` step UL9 promotes both halves of the environment it
activates, with the comment "WITHOUT THAT NOTHING CAN EVER BE REMOVED … That is
what beadm and zsys do and it is why they can prune at all"; and `Restore-OS7`
reads `org.os7:previous` before the ZFS origin **precisely because promote
rotates origins under it** (#107). The defence against the side effect was
already built and already relied on. Promoting here is the update train's own
step, not a new idea.

Against that, the refusal-only shape leaves `Invoke-OS7StorageRelief` unable to
free the largest thing on exactly the machine most likely to be full — see §5.

Both were built in the end. The promotion is the behaviour; the sentence is what
happens when the promotion did not help, which §4.2 shows is reachable.

### 2.2 What changed

| Where | What |
|---|---|
| `Restore-OS7` | promotes both halves of the environment it rolls back to, after the activation has succeeded, **only where the half is actually a clone** (`zfs promote` on a dataset with no origin is an error, and a note that appears when nothing is wrong is a note people learn to read past). Said and not thrown, like UL9's own: the machine already boots what the operator asked for, and failing a rollback over a tidying step takes a working answer away from somebody whose machine has just stopped working |
| `Remove-OS7BootEnvironment` | asks for its dependents BEFORE the confirmation and names them in it; promotes them a pass at a time, re-asking each time because promote moves origins; and refuses in a sentence naming `Convert-ZfsClone`, the blocking dataset, and why `-R` is not the answer, if they are still there after eight passes |
| `Get-OS7CloneDependent` (new, internal) | the one question above, per half, through `Get-ZfsDataset` |

`check-layering.py` holds at **seven rules**, Z1 included: everything goes
through the Zfs layer. `check-privilege.py` holds at **42 / 41**.

---

## 3. The instrument, which is the more useful half

`run-s5.py`'s `timer` phase named its precondition in a comment and asserted
nothing:

```python
# The environment the update phase staged and the rollback left behind is
# removed first, so the timer's own staging is what is measured rather than
# found.
text = ps(c, "… | Remove-OS7BootEnvironment -Confirm:$false; @(Get-OS7BootEnvironment).Count")
```

`text` was never read. On the 245 gate the removal failed for the reason above,
and the count was never printed at all — the throw ended the statement before it
ran (M-BE5).

**The half that made it invisible** is that `os7-update-check` has two branches
which both exit 2. One runs `Update-OS7 -Stage`; the other finds an environment
for that version already there, logs `already waits`, and does nothing. The
assertion read only the code. From the log:

```
2026-09-21T15:50:07Z check: staged: 1.0.0.246 already waits in
os7_1.0.0.246_202609211744; activation and a reboot are pending
```

So on the run that reported PASS: 3/4 measured a staging that did not happen;
the follow-up read `1.0.0.246` off the environment the removal had failed to
destroy; and 4/4 ("a second run finds it already staged") was true before the
first run. **Two of the phase's four assertions were satisfied by the leftover
and a third was true beforehand.**

Both halves are fixed. The count is asserted through a `Write-Output
"S5BE$(…)"` marker — so that "no count came back" reads as itself rather than as
a parse miss, which is the case that actually occurred — and the phase stops
rather than measuring on. And 3/4 now requires the log to say `staging` and not
`already waits`.

BUILD-NOTES **#183** and **#184**.

---

## 4. What the planted-defect run found in this session's own work

`check-be-logic.py --self-test` copies `powershell/` inside the container, cuts
one rule out of `OS7.psm1`, and requires the named checks to go red. It found two
things that a green run would never have shown.

### 4.1 A check green against the defect it was written for — because the wrong actor satisfied it

The assertion "Remove-OS7BootEnvironment promoted BOTH halves" looked for
`zfs promote rpool/ROOT/os7_a` in the command log. It was there — issued by
`Restore-OS7`, two acts later in the same drive script, on a module whose
`Remove-OS7BootEnvironment` had the rule cut out of it.

The fix is that the drive script writes `--- <act>` markers into the same log the
fakes append to, and every assertion is scoped to the act that issued the
command. **"Who did this" is now a fact rather than an assumption.**

### 4.2 The fake modelled promote as a pointer swap, and that is not what promote does

With the rule cut out, the planted run **destroyed** an environment a machine
refuses to destroy. The fake's `zfs promote` rewrote the origin string and left
the snapshot where it was; real promote **transfers the shared history**, which
is the half that makes the original destroyable. So the refusal the whole section
is about was not reproducible, and the check passed.

The fake now moves the snapshot too, per-dataset and not recursively — which is
what produces the mixed topology of M-BE3 by construction rather than by being
told about it.

### 4.3 And one rule was unreachable

The sentence `Remove-OS7BootEnvironment` refuses with cannot be reached by any
correct ZFS: promoting always works. So the fake takes `BE_PROMOTE_NOOP`, which
makes `zfs promote` exit 0 and change nothing — this repository's recurring
failure shape, modelled on purpose — and the check then requires the refusal to
name `Convert-ZfsClone`, name the blocking dataset, and say why `-R` is not the
answer, each asserted separately. It tried sixteen times before refusing, which
is the eight passes.

---

## 5. The interaction that was asked about, and what is still owed

`Invoke-OS7StorageRelief` calls `Remove-OS7BootEnvironment` per environment,
inside a try/catch that **warns rather than swallows** — so on a rolled-back
machine it was honest about the failure. What was not honest is what an operator
reads *before* that: `Get-OS7StoragePressure` counts every prunable
environment's `Used` into `Reclaimable`, including one that cannot be removed, so
`WouldHelp` was true and the `Reason` string said "would free up to X and bring
it back under Y%" of space it could not reach.

That promise is now keepable for this cause. It is **not measured** — no relief
run was made, with or without pressure — and V15's effectiveness gate is
unchanged: it still counts an environment as reclaimable without asking whether
the removal would succeed. Bounded rather than eliminated.

---

## 6. What this session does NOT say

* **Nothing here ran on a machine.** M-BE1 to M-BE4 were taken on one by the
  session that filed the findings; M-BE5 and M-BE6 are read off a serial log that
  a machine wrote. Everything added this session is checked against a fake ZFS.
* **`run-s5.py all` has not been run since the change**, on either host. The
  `timer` phase is the one the change is about and it is the one that needs it:
  `cycle` and `update` exercise `Restore-OS7`'s new promote, and `timer` exercises
  both the removal and the new precondition. That is the gate this work owes.
* **`Restore-OS7`'s promote has never run on a machine.** It is two `zfs promote`
  calls on the pair the activation has just pointed the bootloader at, and the
  activation is the part that decides whether the machine starts — but a promote
  that misbehaved on a real pool would do so after a rollback, which is the worst
  place to find out.
* **arm64 is unmeasured**, as it is for everything in the update train.
* **Nothing was rebuilt.** No ISO carries this.
