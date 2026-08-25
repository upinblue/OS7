# The gate on screen 6 — Setup could not reach screen 7

**Date:** 2026-08-25. Against `main` at 1d764e0, "Phase 3: os7-setup installs a
machine, and the machine boots", and the arm64 ISO built from it —
`OS7-1.0.0.0-arm64.iso`, archive `20260824T000000Z`.

**THE INTERACTIVE INSTALLER COULD NOT GET PAST SCREEN 6.** Walk Welcome →
Licence → Regional → Disk → Layout → Confirm, press `F`, and what appears is:

```
Setup cannot continue.
Setup cannot continue with the settings as they are.
  no user account was named
  the account has no password
```

Screen 7 was unreachable interactively for the whole of that commit. The error
screen was the only thing past the confirmation.

---

## The bug

Both halves came in with 1d764e0.

* [`Screens/ConfirmScreen.cs`](../installer/src/OS7.Setup/Screens/ConfirmScreen.cs)
  called `_plan.Validate(out problems)` when `F` was pressed, and only on success
  transitioned to `new AccountScreen(_plan)`.
* [`Model/InstallPlan.cs`](../installer/src/OS7.Setup/Model/InstallPlan.cs)'s
  `Validate()` unconditionally runs `Account.Validate(problems)`.

So the plan was checked for an account **one screen before the account is
typed** — and the check that ran is the one whose own doc comment says *"A SCREEN
MUST NOT CALL THIS."*

### The comment on the line was the bug

The call carried a justification, and every word of it had been true:

> The last gate before anything is written, and the first place the WHOLE plan is
> complete enough to check … after here there is no screen left to catch it on.

[SESSION-PHASE2-STORAGE.md](SESSION-PHASE2-STORAGE.md) says the same thing, and
SETUP-PLAN §10 repeated it: *"The full check runs in exactly two places:
`--unattend`, and the Confirm screen the moment before anything is written."*

Then Phase 3 inserted screens 7 and 8 between the confirmation and the executor.
The sentence became false; the code it justified stayed. **A comment that states
a structural fact is a claim with a lifetime, and nothing in this repository
checks one.** The general shape is worth naming: *when a screen is inserted into
a flow, the screen before it inherits a promise it can no longer keep.*

### Why nothing caught it

Three automated paths crossed this code and all three passed, each for a
different reason:

| path | why it passed |
|---|---|
| `--unattend` | the plan file it is handed **already contains an account**, so the whole-plan check is correct there |
| `--storage-only` | skips the account check **by design** — a plan complete for preparing a disk should not be refused for lacking a login |
| `run-phase2.py walk` | the only path that drives the screens by hand. It pressed `F` and waited for a progress bar, **because at Phase 2 the executor was what came next.** Nobody told it about screens 7 and 8. |

The third one's failure output is the lesson. It reported

```
FAIL  the executor is running
```

which reads as a storage-executor problem and is not about the executor at all.
**A harness that asserts "the next thing appeared" without naming which thing
reports the wrong subsystem when the flow changes underneath it.**

---

## The fix — the gate moved down, not up

`ConfirmScreen` now calls **`ValidateThroughStorage`** — the regional half and
the storage half, which is exactly what screens 3 to 5 collected. A screen may
only refuse for something it could have got right.

The whole-plan check moved to **`ExecuteScreen.Start`**, and `ExecuteScreen`'s
constructor is now **private** so that factory is the only way to build one.
Constructing that object starts a thread that partitions a disk, so *"did anybody
check the plan first?"* must not be a question about the caller. Both routes into
it — screen 8's ENTER, and `ModeScreen.Next`'s arm64 branch that skips screen 8 —
go through the same door.

That is the same rule as BUILD-NOTES #33 and #42 in a third costume: **put the
check on the thing, not on whoever happens to call it today.**

SETUP-PLAN §3 now says so beside the screen table: *screen 6 is the gate, not the
last check.* `F` is a decision, not an action — the writing starts at 10.

---

## The regression guard fails the BUILD, not a VM run

Four checks in `--self-test`, which hook 0080 runs inside the chroot during
`make build-arm64`:

```
SELFTEST ok   screen 6's check passes a plan that has no account yet
SELFTEST ok   and the whole-plan check still refuses the same plan — no user account was named; the account has no password
SELFTEST ok   F on screen 6 reaches screen 7 with no account in the plan — AccountScreen
SELFTEST ok   the executor's own gate refuses a plan with no account — ErrorScreen
SELFTEST-DONE failures=0 image-files-absent=0
```

The third is the load-bearing one: **it asks the transition, not the predicate
behind it.** The bug was a screen calling the wrong check, so asking the check is
asking the wrong question.

What the self-test must not do is walk past screen 7. A complete plan through
`ExecuteScreen.Start` returns an executor, and an executor is a thread
partitioning a disk — as root, inside a build chroot. Only the refusal is safe to
ask for, and the refusal is the half that guards a person.

---

## Where the interactive walk lives now

**`run-phase2.py walk` stops at the gate.** It drives screens 4, 5 and 6, presses
`F`, checks that the **account screen** is what appears, checks that ESC comes
back, and then asks `lsblk` whether any of that touched the disk. It runs no
executor, so it needs no `--storage-only` to be told not to — which is how it
keeps that file's contract.

**`run-phase3.py walk` is new, and installs by keypress alone.** Screens 1 to 7,
a typed passphrase, a typed computer name, account name and password, to the
Complete screen. It is here and not in run-phase2 because **there is no
interactive equivalent of `--storage-only`**: from screen 7 onwards the
interactive path installs an entire operating system.

It types the same values `install` puts in its plan file, so `boot` verifies
whichever of the two ran last.

Two Phase-2-era assumptions were retired with it: the walk no longer waits for
"the executor is running" straight after `F`, and it no longer expects **"NO
OPERATING SYSTEM HAS BEEN COPIED"** on the Complete screen. That sentence was
Phase 2's screen 12 being honest about a disk that could not boot; Phase 3 copies
a system, so a Complete screen still carrying it would be the screen lying in the
other direction. The walk now fails if it is still there.

---

## What was measured

All on the arm64 ISO built from this branch, in QEMU on Apple Silicon.

### `./installer/testing/run-phase2.py walk` — PASS

```
ok    screen 4 is Select a disk
ok    the setup medium is refused
ok    screen 5 is Storage layout
ok    it refuses to continue without one
ok    the passphrase prompt
ok    screen 6 is the confirmation
ok    ENTER does not confirm a destructive step
ok    F on screen 6 leads to screen 7
ok    screen 7 asks for a computer name
ok    and for an account to administer it
ok    ESC from screen 7 returns to the confirmation
ok    the target is still blank - F decides, it does not write
```

The last line is asked of the **device**, not of the screen: `F` is documented as
a decision rather than an action, which is a claim about a disk and therefore has
to be checked on the disk.

### `./installer/testing/run-phase3.py walk` — PASS

Every value on the Complete screen was typed by keypress:

```
OS/7 version: 1.0.0.0 (development)
Language:     en_US.UTF-8
Keyboard:     us
Time zone:    UTC
Disk:         /dev/disk/by-id/virtio-os7target
Encryption:   LUKS2 (passphrase set)
Swap:         zram
Computer:     os7-phase3
Account:      os7admin   (headless)
```

Screen 8 does not appear, and that is asserted rather than assumed: arm64 is
server-only, so `ModeScreen.Next` skips it and goes straight to the executor.

### `./installer/testing/run-phase3.py boot` — PASS, on the disk that walk built

No ISO attached:

```
ok    1/8 GRUB, the kernel and the initramfs all ran
ok    2/8 the pool imported and / was mounted
ok    3/8 a login prompt
ok    4/8 os7admin logged in with the password Setup set
ok    5/8 / is rpool/ROOT/os7_1.0.0.0_…
ok    6/8 IMAGE_VERSION is 1.0.0.0
ok    7/8 ID and VERSION_ID are untouched (Intune, L16)
ok    8/8 the computer is called os7-phase3
ok         boot=zfs is on the kernel command line
```

`rpool/ROOT/os7_1.0.0.0_202608250646`, hostname `os7-phase3`, login `os7admin`
with the password typed into screen 7. **A machine installed entirely by
keypress boots.** That is the sentence Phase 3's deliverable makes, said for the
first time about the interactive path rather than about `--unattend`.

Run twice, on two disks the walk built — `…_202608250637` before the reader fix
below and `…_202608250646` after it. Both booted; the reader bug was never about
the installer.

---

## The second finding: the harness could not read a hyphen

The first walk failed three assertions on a screen that was completely correct:

```
FAIL  the computer name that was typed (os7-phase3): 'os7-phase3' is not on the screen in #ffffff
ok    the account that was typed (os7admin)
```

`os7admin` has no hyphen; `os7-phase3` does. `vmscreen.read_text` OCRs a cell by
comparing it against every glyph in the PSF — and **eight bitmaps in
`os7-fixedsys-16x32.psf` belong to more than one codepoint.** U+002D, U+00AD,
U+2010 and U+2212 are four separate glyph indices drawing identical pixels, and
the lookup was built with `setdefault`, so the winner was whichever came first in
the unicode table. That is glyph order — an artefact of how the subset is
assembled — and for the dash it is U+00AD SOFT HYPHEN.

**The lowest codepoint now wins**, which is the ASCII one wherever there is one.
Confirmed by decoding the PNGs the failing run had already photographed and
re-running the same needles against the same pixels: all three matched.

`read_text` has been in use since spike S1 and had been right every time, because
every needle anyone had written happened to avoid the eight ambiguous glyphs. The
first assertion about a typed computer name found it in one run.

Full detail: BUILD-NOTES #46.

---

## What this changes in the plan

Nothing about the design; two things about what is believed.

* **SETUP-PLAN §10 Phase 2's "exactly two places" bullet was wrong** from the
  moment Phase 3 landed, and is corrected in place with a dated note. The second
  place is `ExecuteScreen.Start`.
* **Phase 3's deliverable was true and untested by the path a person uses.**
  "A machine installed by Setup boots into OS/7" was proven on 2026-08-24 through
  `--unattend`, which is the one path that could not see this bug. It is now
  proven through the keyboard as well.

## What is still not covered

* **Screen 8 has never been walked**, because no amd64 ISO has ever been built.
  `ModeScreen`'s ENTER now goes through `ExecuteScreen.Start`; only the arm64
  branch that skips the screen has been exercised.
* **The Regional screen's values are accepted as defaults** in both walks. The
  regional lists have their own coverage in `run-phase1.py`; nothing types a
  language or a timezone and then reads it back off an installed system.
* **`fetch_font` is now duplicated three times** across `run-phase1.py`,
  `run-phase2.py` and `run-phase3.py`. Left alone in a bug-fix change; it belongs
  on `vmscreen.Lab`.

### What was run, and what was not

Run against the ISO built from this branch: `check-image.py` (all green,
including `--self-test` inside the image), `run-phase1.py all` (live, boot, walk,
contrast — 4/4), `run-phase2.py walk`, `run-phase3.py walk` and
`run-phase3.py boot`, the last two twice.

**`run-phase2.py`'s `unattend`, `rollback` and `existing` were not re-run.**
Nothing in this change touches them — only `phase_walk` and the file's docstring
moved — and the `vmscreen.read_text` fix is exercised by `run-phase1.py all` and
by both walks, which between them read every screen in the flow. `existing` is
the one that would be worth an hour if `read_text` is touched again: it is the
only phase that reads a version off a screen.
