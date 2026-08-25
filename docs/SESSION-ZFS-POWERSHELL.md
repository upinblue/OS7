# Session — ZFS from PowerShell: the layer, and what measuring it changed

**2026-08-25.** Designing and building the ZFS operator surface OS/7 did not
have. What was measured, what the measurements changed, and what is still owed.

Plan and decisions: [ZFS-POWERSHELL-PLAN.md](ZFS-POWERSHELL-PLAN.md).

---

## 1. The result

| | |
|---|---|
| `powershell/Zfs/` | new module, the whole v1 surface: **23 cmdlets**, read and write, plus `Format-ZfsSize` and `Test-ZfsModule` |
| `Test-ZfsModule` | **56 checks offline**, against 18 captures of real ZFS output; **+`-Live`/`-LiveWrite`** against real pools in a VM |
| `installer/testing/run-zfs.py` | new harness: builds a ZFS world in a VM and brings its output home |
| `installer/testing/check-layering.py` | new: holds Z1 — OS7 must not reach ZFS directly — and it is now at **0** |
| `powershell/OS7/` | `New-OS7Storage` moved onto the ZFS layer (Z-4). `check-layering.py`: **0** direct `zfs`/`zpool` invocations, down from 3 |
| `docs/BUILD-NOTES.md` | **#60** `Write-Verbose` writes to stdout and breaks a JSON contract; **#61** a payload ISO lowercases its names |

The write path exists and is exercised against real ZFS. Replication, device
management, delegation and zvol tooling are v2.

---

## 2. Why this exists at all

[RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §6 states OS/7's own
criterion:

> The goal is that an operator never needs the Linux commands. That holds only
> if the surface is complete — a single missing verb sends them back to bash and
> the guarantee is gone.

The cmdlet table under that sentence has **no ZFS verbs at all**. OS/7 puts ZFS
under every machine it installs and gives the operator no way to snapshot a
dataset, scrub a pool, read pool health, set a quota or replace a failed disk.
The gap is the product's own stated criterion, unmet.

The second reason is drift. `New-OS7Storage` holds the `zpool create` flags as
inline string arrays; `Update-OS7` needs snapshot, clone, import, export and
destroy (§4.2 of the release plan) and would write them inline a second time.
That is exactly the duplication SETUP-PLAN §6.3 refused when it moved storage
out of C# — so this is that argument carried to its conclusion, not a new one.

---

## 3. Prior art — measured, because it decides the packaging

The question was whether this module is worth publishing separately. Asked
rather than assumed:

| Source | Query | Result |
|---|---|---|
| PowerShell Gallery | `zfs` | **0 packages** |
| PowerShell Gallery | `zpool` | **0 packages** |
| GitHub repo search | `zfs powershell` | **0 repositories** |
| GitHub repo search | `zfs` + `language:PowerShell` | 3 repos, **0 stars each** — a test suite, a WSL2 kernel build, a script dump |
| GitHub code search | `Get-ZfsDataset` | 0 |
| GitHub code search | `Get-ZfsItem` | 3 hits, all the same SANS SEC505 teaching script |

**Nobody has built this.** Which is not evidence of a bad idea: until PowerShell
was somebody's primary shell on a ZFS root, no single person held both halves.
Decision Z11 — build it here, extract it to its own repository at a defined bar
— is in the plan with its reasoning.

---

## 4. The measurements, and what each one changed

### M-Z1 — which subcommands speak JSON. The first probe was worthless and said "yes" ten times.

The cheap way to ask is `check-image.py`'s: loop-mount the squashfs, chroot in,
run `zfs list -j` and see whether the option is rejected. It reported **`-j`
accepted** for all ten commands tried.

The control killed it. A bogus option and a bogus *subcommand*:

```
zfs list -Q       ->  The ZFS modules cannot be auto-loaded.
zfs frobnicate    ->  The ZFS modules cannot be auto-loaded.
```

Identical. **The chroot has no ZFS kernel module, so every invocation fails in
libzfs before it parses anything**, and the probe could not distinguish an
option that exists from one that does not. Ten confident answers, zero
information.

Answered instead from the man pages *shipped in the image* — ZFS 2.4.1's own
statement about itself — and later confirmed against real output (M-Z4):

| Command | `-j` | Extras |
|---|---|---|
| `zfs list`, `zfs get`, `zpool list`, `zpool get`, `zpool status` | **yes** | `--json-int` on all five; `--json-flat-vdevs` on `zpool status` |
| `zpool iostat`, `zpool history`, `zpool events`, `zfs mount`, `zfs holds`, the whole write path | **no** | |

**What it changed:** v1 parses no text at all, because the five that speak JSON
*are* the read surface. And Z10's test strategy grew a second tier — a test of a
ZFS parser that runs where ZFS does not is a test of argument strings.

### M-Z2 — `Write-Verbose` goes to stdout, and it would have broken every install

`OS7.psm1` writes progress with a hand-rolled `[Console]::Error.WriteLine()`.
That looks like something to modernise. Measured in the shipped image, with the
two descriptors redirected separately:

```
Write-Verbose "V"  ->  STDOUT   "VERBOSE: V"
Write-Warning "W"  ->  STDOUT   "WARNING: W"
Write-Error   "E"  ->  stderr
```

and therefore, with the installer's contract of one JSON object on stdout:

```
f -Verbose | ConvertTo-Json -Compress
   stdout:  VERBOSE: progress
            {"a":1}
   parsed:  JSONDecodeError
```

**What it changed:** the plan's own §5 was rewritten. The `[Console]` call is
load-bearing, not a crutch; progress in the new module goes to stderr
explicitly (Z5); and the failure only appears when somebody adds `-Verbose` to
debug a storage problem, which is the worst possible moment. BUILD-NOTES #60.

### M-Z3 — module import cost

Bare `pwsh -Command exit`: 87 / 95 / 101 ms. With `Import-Module OS7`: 136 /
139 / 143 ms. The module costs ~45 ms and Setup starts `pwsh` twice. Room for a
second module and a format file; re-measure when both are in an image.

### M-Z4 — the shapes, from a VM where ZFS is actually loaded

`run-zfs.py capture` boots the live ISO, builds two pools on 256 MB files, five
datasets, a zvol, three snapshots and a clone, and carries 18 captures home over
the serial line. All five `-j` commands returned parseable JSON.

Three things only real output could say:

* **`zpool status --json` nests for real** — `pools.tank.vdevs.tank.vdevs.mirror-0.vdevs.<leaf>`,
  each level carrying state and read/write/checksum counters. Captured healthy
  and again with a device offlined: `DEGRADED` propagates upward and the pool
  gains `status` and `action` keys a healthy pool does not have.
* **Snapshots carry `dataset` and `snapshot_name` as fields**, so nothing splits
  a name on `@`.
* **`-j` does not make errors JSON.** `zfs list -j nosuchpool/x` exits 1 with
  plain text and no output. A reader expecting an empty result set is wrong.

### M-Z5 — the 20-digit number in the first field

`pool_guid` is `13714606391384389334` — above `Int64.MaxValue`. §12 had listed
"very large values" as unmeasured; it turned out to be unavoidable rather than
theoretical. `ConvertFrom-Json` returns `System.Numerics.BigInteger` and it
**round-trips exactly**. `ConvertTo-ZfsBytes` handles it explicitly and the
self-test asserts it. Measured on PowerShell 7.6.2 (host); 7.6.5 is in the
image and this should be re-checked there.

### M-Z6 — the build integration, proved on the artefact

`OS7-1.0.0.78-arm64.iso` built with both modules staged. Hook 0060 accepted
them, and `check-image.py` — which loop-mounts the squashfs, overlays it and
chroots in — reported:

```
ok    the Zfs module parses the ZFS output it ships with — Zfs self-test: 40 passed, 0 failed
```

The module is in the image, the recorded captures are in it too, and PowerShell
can call bundled cmdlets in *that* chroot. It says nothing about live-build's,
where #38 measured the opposite; the hook still does only what a hook may.

40 rather than 43 because that ISO carries the module as it stood before three
rendering fixes landed — which is the point of asking the image instead of the
source.

---

---
---

## 5. What was wrong on the way, and how each one surfaced

### The capture script accepted a failed `zpool create` and carried on

`zpool create spare7 …` was refused — **ZFS reserves pool names beginning with
`spare`, and equally `mirror`, `raidz`, `draid`, `log`, `cache`, `special`,
`dedup`**. The script ignored the return code, captured one pool where the tests
expected two, and the failure surfaced two steps later as a failing assertion
about a parser that was correct.

This is the repo's standing shape — *a program reported success and the thing it
was meant to change did not change* — reproduced by the very script written to
serve it. `zfs-fixtures.sh` now asks ZFS whether every pool, dataset and
snapshot it was told to build exists, and refuses to capture otherwise. And
`New-Zpool` (phase Z-3) has to validate the name up front rather than let
`zpool` refuse it later.

### The plan said the self-test would run in a build hook. BUILD-NOTES #38 had already said it cannot.

Z10's first draft had `Test-ZfsModule` running in hook 0080 "so a broken parser
fails the BUILD rather than a boot", by analogy with `os7-setup --self-test`.
The analogy does not hold: `os7-setup` is a NativeAOT binary depending on
nothing, while `Test-ZfsModule` calls `Get-Content` and `ConvertFrom-Json`,
which autoload **by name** out of `$PSHOME/Modules` — the lookup live-build's
chroot mangles. #38's rule predates this plan by a day:

> A build-time hook may `Import-Module` by path and inspect what it exports. It
> must not CALL anything that needs a bundled cmdlet.

So the verification is split three ways, and hook 0060 does only what a hook
may: presence, manifest parse, exports, and that at least five recorded captures
shipped. `check-image.py` runs the self-test against the finished ISO and treats
"PowerShell produced no verdict" as a NOTE and "the verdict was FAIL" as fatal —
the shape hook 0075 uses and #38 credits with saving a good build.
`run-zfs.py test` on a booted VM is the authority.

---

### Three more, all found by actually looking at the output

Written, self-test green, and then rendered for the first time. Each of these
was invisible to 40 passing assertions:

* **`Format-ZfsSize` produced `1,1 MiB`.** `'{0:N1}'` formats in the *host's*
  culture, and the host is German. A decimal comma inside an English table is
  ugly; inside an exported helper that reports and Intune compliance scripts are
  meant to share (§10 of the plan), it is a bug that depends on the machine.
  Now `InvariantCulture`, explicitly.
* **`Get-ZpoolStatus -Flat` was unreadable.** It emitted the pool object and then
  the vdev nodes into one pipeline; `Format-Table` picks the view of the first
  object and renders every later type as a *list*, so a four-node tree came out
  as four paragraphs. `-Flat` now emits **only** vdev nodes, each carrying
  `Pool`. Two types in one pipeline is a formatting decision, not a convenience.
* **Every leaf showed a blank size.** Interior vdevs report `total_space`;
  leaves report `rep_dev_size` and `phys_space` instead — so the one column
  somebody replacing a failed disk needs was empty on exactly the rows that
  matter. And the depth-first walk used a stack, which reversed siblings, so the
  second half of a mirror printed above the first.

The general point: a self-test asserting values proves the parser. It says
nothing about whether a human can read the result, and this module exists to be
read.

### The live test corrected my test twice, about the same thing

`Test-ZfsModule -LiveWrite` creates a scratch dataset, exercises the write path
and destroys it again. Two of its assertions were wrong, and both times ZFS
explained itself precisely — because `Invoke-ZfsNative` carries the failing
command line *and its output* into the exception, which is the whole reason
SETUP-PLAN §3.1 asks for both.

**First:** clone, promote, then roll back to the original snapshot.

```
cannot open 'tank/os7-zfs-selftest@t1': dataset does not exist
```

`zfs promote` **moves** the shared snapshots to the promoted clone. The origin
does not have them any more. That reversal is what `Convert-ZfsClone`'s own help
describes, and it was still a surprise in practice.

**Second**, after reordering: destroy the snapshot where it now lives.

```
cannot destroy 'tank/os7-zfs-selftest-clone@t1': snapshot has dependent clones
use '-R' to destroy the following datasets:
tank/os7-zfs-selftest
```

The reversal is total: after the promote, **the original is the dependent
clone**. It even changes the order the cleanup has to run in — destroying the
promoted dataset first fails and leaves both behind.

Both are now assertions rather than comments: the test checks that the snapshot
moved, and that the promoted snapshot is protected by its new dependent. A
promote that quietly failed to reverse the dependency would make both pass
today and fail here.

The general shape is worth keeping: *a live test earns its keep by disagreeing
with the person who wrote it.* Recorded fixtures cannot do this — they replay
what somebody already believed.

---

## 6. What the module is, in one screen

```
Layer 3   OS7      Update-OS7, Restore-OS7, New-OS7Storage …   knows OS/7
                   ── Z1: calls nothing but Layer 2 ──
Layer 2   Zfs      Get-Zpool, Get-ZfsDataset, …                knows no OS/7
Layer 1   zfs/zpool                                            one seam only
```

What makes it more than a wrapper, and all of it cheap:

* **`Used` is a `[uint64]` of bytes**, so `Where-Object { $_.Used -gt 1TB }` and
  `Measure-Object -Sum Used` work. `zfs list -o used` gives the string `1.4T`.
  `Zfs.format.ps1xml` renders it back as `1.4 TiB`, so nothing is lost by
  looking at it.
* **`Get-ZpoolStatus` returns a vdev object tree** with `Children`, or `-Flat`
  with a `Level`. `Get-ZpoolStatus -Flat | Where-Object State -ne 'ONLINE'` is
  the whole of a health check.
* **`Get-ZfsProperty` keeps the source** — LOCAL, INHERITED, DEFAULT, NONE.
  "compression is lz4" and "compression is lz4 *because it is inherited*" are
  different facts and only the second says where to change it.
* **Z3, for phase Z-3:** every mutating cmdlet will re-read what it changed and
  emit the observed state. A cmdlet that echoes its own parameters back is a
  diagnostic that depends on the subsystem it is diagnosing.

---

## 7. Z-4 — the proven path moved, and the diff that made it safe

`New-OS7Storage` is the only code path proven to install a machine that boots,
and Z1 says it must stop calling `zpool` and `zfs` itself. It now goes through
`New-Zpool`, `New-ZfsDataset` and `Mount-ZfsDataset` like everything else, and
`check-layering.py` reports **0 direct invocations**, down from 3.

**What made that safe to do before spending an hour in a VM:** the old command
lines were known, so the new ones were captured through the seam and compared.

```
=== DIFF: expected (old code) vs actual (Layer 2) ===
IDENTICAL — every command line matches the old implementation
```

All 25 mutations, byte for byte — same flags, same order, same devices. Plus the
contract `os7-setup` depends on, checked separately: **exactly one line on
stdout, and it parses as JSON**, with progress on stderr as `OS7-STEP` and
`ZFS-STEP` lines.

Three things that shaped the rewrite, each of them a trap avoided rather than
survived:

* **The dry run is a separate branch, not `-WhatIf` passed downwards.**
  PowerShell writes "What if:" to the host, and the host's output is stdout —
  BUILD-NOTES #60 again, wearing a different hat. Handing `-WhatIf` to the Zfs
  cmdlets would have put English prose in front of the JSON.
* **Every Zfs call ends in `| Out-Null`.** Z3 makes the mutating cmdlets return
  what they created; here, anything returned would land on stdout.
* **The ZFS layer is imported lazily, never at module level.** A live-build hook
  may import a module by path and list its exports, but module-level code runs
  during import and `Test-Path` is a bundled cmdlet (BUILD-NOTES #38). Resolving
  the Zfs module at the top of `OS7.psm1` would have failed hook 0060 and broken
  the build.

The command-line diff is not a substitute for `run-phase3.py all`; it is what
made running it worth the time. **The gate then passed:**

```
### Phase 3 result
    install   PASS
    boot      PASS
    walk      PASS
```

Installed unattended on `OS7-1.0.0.78-arm64`, started again **with no ISO
attached** — GRUB, kernel, initramfs, the LUKS prompt, both pools imported, a
login served from `rpool/ROOT/os7_…` — and then a second machine installed **by
keypress alone** to the Complete screen.

One more step before calling it proved. The harness does not surface `pwsh`'s
stderr, so the absence of `ZFS-STEP` lines in its log says nothing about which
code ran; believing it either way would have been the mistake this whole
document is about. So the artefact was asked:

```
=== direct zfs/zpool invocations in the SHIPPED OS7 module ===
  (none)
=== does the shipped OS7 module call the Zfs layer? ===
  New-Zpool -Name bpool …   New-ZfsDataset …   Mount-ZfsDataset …
```

There is no other path inside that image. The pools on that disk were created
through Layer 2.

---

## 8. What is owed

* **`Test-ZfsModule -Live` has never run.** The offline test proves the parsers
  against recorded output; it structurally cannot prove that the `-o` column
  lists the cmdlets send are columns ZFS accepts. `run-zfs.py test`, phase Z-2b.
* **The whole write path.** 15 cmdlets, phase Z-3.
* **amd64**, as with every result in this repository.
* **The Intune custom-compliance angle** (plan §10) is unread against
  Microsoft's live documentation.

## 9. The "vanished" ISOs — an instrument lying, and the instrument was me

For twenty minutes this session believed every built ISO had been deleted. Two
independent reads agreed:

```
$ ls -la out/
total 0                       <- empty
$ docker run -v "$PWD/out:/iso:ro" …
mount: failed to setup loop device for /iso/OS7-1.0.0.46-arm64.iso
ls: cannot access '/iso/OS7-…': No such file or directory
```

`out/` was never touched. **The shell's working directory had drifted.** An
earlier command ended in `cd powershell/Zfs/tests/fixtures`; the working
directory persists between tool calls, so the *next* command's
`cd powershell/Zfs/tests/fixtures` failed — and everything after it ran one
directory deep inside the fixtures.

`ls -la out/` then listed `powershell/Zfs/tests/fixtures/out`. Which existed,
and was empty, **because Docker had just created it**: a bind mount whose host
path does not exist is not an error — `docker run -v "$PWD/out:/iso:ro"` makes
the directory and mounts it empty. The container dutifully reported no ISO
inside, and the two "independent" instruments were reading the same fiction.

The proof was left on disk: two empty skeletons under the fixtures directory,
`out/` and `powershell/Zfs/tests/fixtures/`, matching the two `-v` flags of the
probe that "failed", flag for flag.

**Three things worth carrying:**

* `cd` persists across tool calls, so a *relative* path is a statement about
  history rather than about the repository. Every harness in
  `installer/testing/` already computes `REPO` from `__file__` and uses absolute
  paths throughout; this is why.
* **A Docker bind mount creates a missing host path instead of refusing.** That
  turns a wrong path into an empty directory rather than an error, which is the
  worst possible failure mode: it looks like data loss.
* Two instruments agreeing is not corroboration when the second one is derived
  from the first. Both were reading `$PWD`.

An earlier version of this section recorded the event as unexplained and said
so, rather than inventing a cause. That was the right call at the time and it is
what made the real cause findable later — the empty skeletons were still there
to be found.
