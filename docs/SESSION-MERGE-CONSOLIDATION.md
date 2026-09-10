# Session: five branches onto one main, and what merging measured

**2026-08-28, on the x64 Windows + Docker Desktop host.** The repository had
drifted into five local branches and two extra worktrees. This session put
everything on `main`. The merge found two defects and one number claimed twice
that neither branch could have seen alone; building an ISO from the result found
a third that neither the merge nor either branch had caused, and that had been
quietly stopping `main` from building for a day.

Nothing here is a new feature. What is new is a tree in which the two lines of
work are true at the same time, a set of measurements taken on that tree rather
than on either half of it, and one rule that stopped being a note and became a
scan.

---

## 1. What was there

```
                      claude/magical-hermann-b93e23  (2 commits)
                     /
  ... 3befe71 ... 34dc6c8   update-train   (9 commits, worktree OS7-update)
     /
8700095
     \
      6aeea12 ... fd8e970   main           (2 commits: Active Directory,
                                            and the website moving out)

claude/amd64-gui-mode          already fully merged into main
claude/amd64-on-windows        already fully merged into main
claude/beautiful-bose-f5e566   already fully merged into main (and on origin)
```

Both worktrees were clean, there were no stashes, and nothing was uncommitted
anywhere. The three `claude/*` branches at the bottom were ancestors of `main`
and carried nothing.

`git merge-base main update-train` is `8700095`. The two lines ran for about a
day without seeing each other: `main` took Active Directory and moved the
website into `upinblue/os7-web`; `update-train` packaged the ISO, ported the VM
harness to x86_64/KVM, and took the update train through a real end-to-end gate
on this box.

## 2. What was done

`claude/magical-hermann-b93e23` went into `update-train` first (`767d1d6`) — it
branches off `3befe71`, which is inside that line, and it merged with **no
conflicts**. So the consolidation is two merge commits, not three, and the
history of both lines is intact.

Merge commits rather than a rebase, on purpose: these commit messages reference
each other **by hash** (`34dc6c8` names `a545e6e` as the commit ISO 1.0.0.137
was built from), and a rebase would have made every one of those references
point at nothing.

Then `update-train` into `main` (`fdb00f9`), with four conflicts.

## 3. The four conflicts, and the one shape three of them share

### `build/build.sh` — a function deleted on one side, extended on the other

`update-train` had removed `stage_ps_module` entirely: the module **code** now
reaches an image only as the `os7-module` .deb through hook 0022, and what
`build.sh` still stages is the `tests/` fixture trees alone, through
`stage_ps_fixtures` over a loop. `main`'s **entire** `build.sh` diff was adding
`Directory` to the function `update-train` deleted.

Resolved toward `update-train`'s structure with `Directory` added to its loop,
which read `Zfs Net Time Systemd OS7`. The measured fact `main`'s comment
carried was kept at the loop, because it is the reason Directory's fixtures are
provenance rather than input: `Test-DirectoryModule` does not read them.
`SearchResultEntry` has no public constructor, so no fake can produce what
`SendRequest` returns, and an image shipped without those files would still
self-test green.

### `build/lib/build-os7-packages.sh` — the same list, in the package

`main`'s `Zfs Net Time Systemd Directory OS7` against `update-train`'s
`Zfs Net Time Systemd OS7`, plus `pkg_finish`'s required paths. Resolved as
HANDOFF's own merge checklist asked: the loop toward `main`, the **union** for
`pkg_finish`. A third hunk was two descriptions of why the .deb drops `tests/`
while the ISO keeps them; each carried a fact the other did not, so the
resolution carries both.

### The shape

**Two independently written module lists, one entry apart, in two files, with no
conflict between them.** The `build.sh` list was not part of any conflict at
all — it merged clean and wrong. That is BUILD-NOTES #82's family exactly, and
the only thing that reveals it is reading the two lists side by side, which is
what the merge forced. Both now say six, and the comments say why.

### `docs/BUILD-NOTES.md` — and #108 claimed twice

Both lines appended at the same place. Spliced in numeric order: 94-96 (the AD
line), #97-#107 (the update train), 108 (the AD line), #109.

**#108 was claimed by two branches that had both already committed it** — the AD
line for the installer/cmdlet parameter disagreement, the update train's line
for the missing journal. The file carries a reservation convention, and it
works: a session once took #80 by reading the table rather than colliding. It
cannot work between sessions that never share a branch, which is what happened
here.

`main` had it first and is published, so the journal note is **#109**, and its
eight references moved with it: `build-os7-packages.sh`, the journal-flush
drop-in, `check-image.py`'s comment **and its check message**, both session
documents, and HANDOFF. The AD note's five references were left alone. The check
message matters more than the comments: it is the sentence a person reads when
the check fails, and a wrong note number sends them to the wrong page.

### `docs/HANDOFF.md` — where the newer sentence is the worse one

Both appended rows to section 1. Union, with one exception: the `run-backup.py`
row exists on **both** sides, and `update-train`'s corrects `main`'s. `main`
still said the harness is `qemu-system-aarch64` and needs the Apple Silicon
host. Since the vmarch port that is no longer true; it is unrun on **either**
host, which is a different and worse sentence, so it is the one that stayed.

## 4. Two defects the merge found

### `pkg_finish` named three of the fourteen dot-sourced files

The comment above that list says "not a sample" and explains that a list naming
only what the loop already copies is decoration. For the six **modules** that
was made true on 2026-08-27. For OS7's own parts it was never true at all: the
list named `OS7.Backup.ps1`, `OS7.Home.ps1` and `OS7.Update.ps1` out of fourteen.

The merge is what made it legible. The AD line added `OS7.Directory.ps1`,
`OS7.DirectoryObject.ps1` and `OS7.Domain.ps1`; neither branch touched the list,
because on each of them the other's files did not exist. All fourteen are named
now, and the set was diffed against the `.psm1`'s own `foreach` rather than
against `ls`.

This is not the same failure as the missing modules. A missing dot-sourced file
**does** stop the machine — `OS7.psm1` throws a `FileNotFoundException` naming
the part. But it throws at import, on an operator's machine, and the point of
the list is that the .deb is refused at **build** time. `dpkg-deb -c` reads the
built package back; nothing else does.

### An error message pointing at a function this merge deleted

That same `throw` told the reader the module is "staged by copying the whole
directory (build.sh stage_ps_module)". `stage_ps_module` no longer exists. An
error message that names a function that is not there sends the diagnosis to the
wrong file at exactly the moment it is being read. It now names the package, and
says what it used to name.

## 5. What was measured on the merged tree

Not asserted. Every line below was run on `fdb00f9` / `f6d45a4` on this host.

| check | result |
|---|---|
| `check-installer-cmdlets.py` | **all pass**, 157 cmdlets across OS7, Directory and Zfs — the checklist's first-thing |
| `os7-setup --self-test` (AOT, container) | builds and passes; the 10 failures are image-files-absent, as it says itself |
| `check-version-rule.py --docker` | **all four** implementations agree |
| `check-netplan-rule.py --docker` | C# and PowerShell agree **byte for byte** |
| `Test-ZfsModule` | 75 PASS |
| `Test-OS7Backup` | 63 PASS |
| `Test-OS7Update` | 31 PASS |
| `Test-DirectoryModule` | 51 PASS |
| `check-layering.py` | 5 rules held, every baseline unchanged |
| `check-ps-traps.py` | #65 and #91 both at 0 |
| `check-be-logic.py` | green in Linux (see section 8) |
| `check-home-logic.py` | green |
| `check-update-logic.py` | green |
| `check-directory-logic.py` | green |
| `check-network-logic.py` | green |
| `check-service-logic.py` | green |
| `check-vm-arch.py` | 41 ok |
| `make repo-amd64` | ten .debs, suite signed and verified. **os7-module: 26 required paths present** |
| `check-os7-repo.py` | **123/123, exit 0** — installs into a plain `ubuntu:26.04`, applies a hotfix, and REFUSES a foreign signing key |
| `make build-amd64` | **OS7-1.0.0.148-amd64.iso**, hook 0060 green for all six modules — but only on the second attempt, see section 6 |
| `check-image.py amd64` | **107 ok, 0 FAIL, exit 0** over the shipped squashfs |

`26 required paths` is the number that matters for section 4: 2 manifests + 14
dot-sourced files + 5 generic modules at 2 each. Read back out of the built
package by `dpkg-deb -c`, not out of the source tree.

### The one thing a clean auto-merge does not prove

`powershell/OS7/OS7.psm1` auto-merged — `main` added the AD export block,
`update-train` restructured 302 lines of it. A clean auto-merge is not evidence,
so the export surface was compared as **sets** against both parents:

```
pre-merge main          95 exported functions
pre-merge update-train  58
merged                  95   = exactly the union
                             nothing lost from either side, nothing invented
```

`update-train`'s 58 is a strict subset: the AD product files are `main`'s. The
six modules together export **185** functions (26/11/9/8/36/95), which is what
`POWERSHELL-REFERENCE.md` says — asked of the modules rather than read off the
page.

## 6. The ISO build, which failed — and the exit code that said it had not

The first `make build-amd64` from the consolidated tree died at hook 0060:

```
OS/7 hook 0060:   OS7: FAILED: The term 'Sort-Object' is not recognized as a
name of a cmdlet, function, script file, or executable program.
make: *** [Makefile:145: build-amd64] Error 1
```

**BUILD-NOTES #82, for the third time.** `OS7.DirectoryObject.ps1` built the
attribute set a group membership is read with as the union of three lists, in a
statement at module scope — so it runs at IMPORT — and did it with
`| Sort-Object -Unique`. `Sort-Object` is `Microsoft.PowerShell.Utility`,
autoloaded by name, and the build chroot has only `Microsoft.PowerShell.Core`.

**It was not the merge's doing, which is the worse finding.** The line is
byte-identical on `pre-consolidation-main`: `main` had been unable to build an
ISO since the Active Directory commit, and nothing said so because no ISO was
built in between. That is #82's own opening paragraph, happening again to
readers who had the note.

### And the exit code lied about it

The build ran as `make … > log 2>&1; echo "BUILD_EXIT=$?" >> log; tail -3 log`.
The shell's status was `tail`'s, so the task reported **exit code 0** over a
build that had exited 2 — and this session came within one command of reporting
a green build. It is the first rule in CLAUDE.md, met from the harness side
rather than the product side: *an exit code is a diagnostic.* The rebuild ends
in `exit $rc`.

### The reproduction, and why it became a check

The chroot condition is one variable:

```powershell
$PSModuleAutoLoadingPreference = 'None'
Import-Module ./powershell/OS7/OS7.psd1 -Force -ErrorAction Stop
```

On the broken tree that returns the build's error **word for word**, in under a
second, with no container and no ISO. On the fixed tree all six modules import.

The fix builds the union with a `HashSet[string]` and
`List[string].Sort(comparer)` — .NET types, always present, never looked up by
name, the same move #82 already made for `[System.IO.Path]`. The value was
captured before and after and diffed: 29 attributes, identical, same order.

`check-ps-traps.py` now holds this as its **third trap**, baseline 0. It asks the
parser for every `CommandAst` outside every `FunctionDefinitionAst`, then asks
`Get-Command` which module the name belongs to. Neither the safe modules nor the
names the tree defines are lists in the file — a hand-written list of either
would agree with the code instead of checking it. It was run against
`pre-consolidation-main` **before** being trusted, and goes red on exactly the
one line, naming file, line, cmdlet and module.

The second build then produced `OS7-1.0.0.148-amd64.iso` with hook 0060 green
for all six modules, and `check-image.py amd64` reads **107 ok, 0 FAIL** out of
the shipped squashfs.

Three ISO builds have now been lost to this one rule. The scan costs a second.

## 7. What was NOT measured

* **`run-phase3.py all`** — still unrun, still the #74 gate. It went through the
  vmarch port with the rest (it reaches QEMU through `vmscreen`), so it is no
  longer Mac-only; it has simply never been executed on either host since the
  fix.
* **`run-s5.py all` on arm64/HVF** — ported, byte-identical, never executed.
* **`make build-arm64`** — no arm64 ISO has been built with hook 0022.
* **`run-backup.py all`** — B-5's gate, never run on any host.
* **A domain join** — no OS/7 machine has ever joined one. Unchanged by this
  session.
* **`check-ad.py`, `check-management-logic.py`, `check-ssh-login.py`** — not run
  in this session.

## 8. One host finding, recorded because it cost time

**`check-be-logic.py` reports 20 FAILs on Windows where it should report NOT
CHECKED.** Its fake `zfs` is a shebang script; Windows cannot exec one, so
`$LASTEXITCODE` is never set and every dependent check fails with
`Invoke-ZfsNative: The variable '$LASTEXITCODE' cannot be retrieved`. In a Linux
container with pwsh on PATH it is green, exit 0.

It was shown not to be a merge regression the only way that settles it: **both
parents fail it identically on this host.**

`check-netplan-rule.py` and `check-version-rule.py` say NOT CHECKED in exactly
this situation and name the container flag that would fix it. `check-be-logic.py`
says FAIL. A check that reports a host limitation as a product defect is the
shape this repository exists to avoid, and it is the second most expensive kind
of wrong answer after a green that should have been red.

`check-home-logic.py` shows the fix: it runs **itself** in a container.

## 9. Claims corrected, and why they were wrong

The merge falsified sentences on both sides. None of these was edited for
tidiness; each was measured first.

| said | actually |
|---|---|
| CLAUDE.md: "The update train is code and has **NEVER RUN ON A MACHINE**"; "`run-s5.py` is the gate and **needs the Mac**" | the gate passes on this Windows box: four runs, four numbered defects |
| CLAUDE.md: "Everything proven so far is **arm64 only**; no amd64 ISO has ever been built" | amd64 ISOs are built routinely here; `out/` holds several, and four carried the update train through its gate |
| CLAUDE.md: "**Four** files DOT-SOURCED by OS7.psm1 ... hook 0060 checks all **five**" | fourteen — and the same file said FOURTEEN sixty lines below it |
| CLAUDE.md: the OS7 module is "staged by build.sh" | it reaches an image as the `os7-module` .deb; build.sh stages fixtures only |
| CLAUDE.md: `run-phase3.py all` "needs the Mac" | ported; unrun on either host |
| hook 0060: "OS7.Update.ps1 — the **sixth** dot-sourced file" | the fourteenth and last |
| HANDOFF.md: `powershell/Directory/` has "**25** functions, `Test-DirectoryModule` **40/40**" | 36 and 51 — and both were already stale on `main` before the merge |

Every one of these is a count or a status written in prose with nothing checking
it, which is the argument CLAUDE.md already makes for `POWERSHELL-REFERENCE.md`
being generated rather than maintained. The two that *were* checked by
something — the module list in the loop, and the required-path list — turned out
to be checked against each other rather than against the product.

## 10. What is on `main` now

Both lines, one history, two merge commits. The three fully-merged `claude/*`
branches, `update-train` and `claude/magical-hermann-b93e23` were left in place
at the user's request; they are ancestors of `main` now and carry nothing that is
not on it. `pre-consolidation-main`, `pre-consolidation-update-train` and
`pre-consolidation-hermann` tag the three pre-merge heads.
