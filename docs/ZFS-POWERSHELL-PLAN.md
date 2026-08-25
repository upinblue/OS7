# ZFS from PowerShell — the operator surface OS/7 does not have

**Written 2026-08-25.** How ZFS becomes fully manageable from PowerShell on
OS/7, what that module is, where it lives, and when it leaves this repository.

Authority: this document decides the **ZFS layer**. It does not decide the
update train ([RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md)), the
dataset hierarchy ([../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md) §4.4)
or what a release contains
([CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md)). Where it
touches those, it says so and defers.

---

## 1. Verdict

OS/7 puts ZFS under every installed machine and gives the operator **no way to
touch it from PowerShell**. Not a snapshot, not a scrub, not pool health, not a
quota, not a failed disk. The release plan already states the criterion this
fails:

> The goal is that an operator never needs the Linux commands. That holds only
> if the surface is complete — a single missing verb sends them back to bash and
> the guarantee is gone.
> — [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §6

The cmdlet table under that sentence contains **zero ZFS verbs**. The gap is not
a nice-to-have; it is the product's own stated criterion, unmet.

**Decision: a two-layer PowerShell surface.** A generic `Zfs` module that knows
nothing about OS/7, and the existing `OS7` module on top of it. The hard rule is
that `OS7` never calls `zfs` or `zpool` directly again — the same anti-drift
argument SETUP-PLAN §6.3 used to move `New-OS7Storage` out of C#, carried to its
conclusion.

Five measurements changed this document while it was being written (§12). The
one that changed it most: **`Write-Verbose` in PowerShell 7.6.5 writes to
`stdout`, not `stderr`**, and it makes the installer's JSON unparseable. The
hand-rolled stderr writer in `OS7.psm1` is not a crutch to be cleaned up. It is
load-bearing, and the obvious cleanup would have broken every install.

---

## 2. Prior art — measured, because the answer decides the packaging

Asked on 2026-08-25:

| Source | Query | Result |
|---|---|---|
| PowerShell Gallery | `zfs` | **0 packages** |
| PowerShell Gallery | `zpool` | **0 packages** |
| GitHub repo search | `zfs powershell` | **0 repositories** |
| GitHub repo search | `zfs` + `language:PowerShell` | 3 repositories, **0 stars each** — a test suite, a WSL2 kernel build, a personal script dump. None is a management module. |
| GitHub code search | `Get-ZfsDataset` | 0 |
| GitHub code search | `Get-ZfsItem` | 3 hits, all the **same file** — teaching material from the SANS SEC505 course, copied into three repos |

**Nobody has built this.** Not partially, not badly, not once. That is not
evidence of a bad idea; it is evidence that until PowerShell-as-the-primary-shell
on a ZFS root existed, there was no person holding both halves. OS/7 *is* that
person. The consequence for packaging is in §9.

---

## 3. The architecture

```
Layer 3   OS7            Update-OS7, Restore-OS7, New-OS7Storage,
                         Get-OS7BootEnvironment, Get-OS7Version …
                         Knows boot environments, release.json, LUKS, Intune.

                         ── Z1: calls NOTHING but Layer 2 ──

Layer 2   Zfs            Get-Zpool, Get-ZfsDataset, New-ZfsSnapshot,
                         Set-ZfsProperty, Start-ZpoolScrub …
                         Knows nothing about OS/7. Runs on TrueNAS, Proxmox,
                         plain Ubuntu, FreeBSD.

Layer 1   zfs / zpool    The binaries. Reached only through one seam,
                         Invoke-ZfsNative.
```

### Z1 — Layer 3 never shells out to ZFS

Today the `zpool create` flags live as inline string arrays in `New-OS7Storage`
([../powershell/OS7/OS7.psm1](../powershell/OS7/OS7.psm1)). `Update-OS7` needs
`zfs snapshot`, `zfs clone`, `zpool import`/`export`, `zfs set canmount`,
`zpool set bootfs` and `zfs destroy -r` (RELEASE-AND-UPDATE-PLAN §4.2). Written
inline a second time, that is exactly the duplication SETUP-PLAN §6.3 refused
when it moved storage out of C#.

**Enforced by a mechanism, not by discipline.**
[`installer/testing/check-layering.py`](../installer/testing/check-layering.py)
counts direct `zfs`/`zpool` invocations in `powershell/OS7/` and fails if the
number grows. A rule that is only written down erodes; BUILD-NOTES #13, #43 and
#45 are three records of that.

It was written to hold a **baseline rather than zero**, because
`New-OS7Storage` had three such sites and is the only code path proven to
install a machine that boots — a hard zero before phase Z-4 would either fail
every run or be switched off, and a switched-off check is worse than none. The
baseline was **3**, measured by running the script rather than counted by eye,
which got 24 by counting dataset creations instead of invocation sites.

**Z-4 has since landed and the baseline is 0**, so the check now says what Z1
says. What made the move safe to attempt: the old command lines were known, so
the new ones were captured through the seam and diffed — all 25 mutations come
out byte-identical, same flags, same order, same devices — and the JSON contract
`os7-setup` depends on was checked separately (exactly one line on stdout, and
it parses).

### Z2 — one seam to the binaries

Every native call in Layer 2 goes through `Invoke-ZfsNative`, which is the
present `Invoke-OS7Native` generalised: it captures stderr, checks
`$LASTEXITCODE` (PowerShell's `$ErrorActionPreference` does nothing for a native
non-zero exit), and carries the failing command line *and its output* into the
exception, because SETUP-PLAN §3.1 requires an error screen to name both.

One seam is also what makes the module testable without ZFS: `Test-ZfsModule`
replaces exactly this function with one that replays recorded output (Z10).

### Z3 — the observed state, never the intended state

Every mutating cmdlet **re-reads the object it changed and emits what it found**,
not what it asked for. `Set-ZfsProperty -Name compression -Value zstd` returns
the dataset with `compression` as ZFS now reports it.

This is BUILD-NOTES' recurring bug shape written into the module's convention:

> *a program reported success and the thing it was meant to change did not
> change.*

A cmdlet that echoes its own parameters back is a diagnostic that depends on the
subsystem it is diagnosing. Costs one extra `zfs get` per mutation; buys the
class of bug that has been most expensive in this repo.

---

## 4. JSON or text — measured, and better than expected

OpenZFS **2.4.1-1ubuntu5** is what OS/7 ships (`out/OS7-1.0.0.65-arm64.release.json`,
`components.zfs`). Read out of the shipped man pages in the image itself — not
from upstream release notes, which describe a version this product does not
necessarily have:

| Command | `-j` / `--json` | Extras |
|---|---|---|
| `zfs list` | **yes** | `--json-int` |
| `zfs get` | **yes** | `--json-int` |
| `zpool list` | **yes** | `--json-int`, `--json-pool-key-guid` |
| `zpool get` | **yes** | `--json-int`, `--json-pool-key-guid` |
| `zpool status` | **yes** | `--json-int`, `--json-pool-key-guid`, `--json-flat-vdevs` |
| everything else | **no** | `iostat`, `history`, `events`, `mount`, `holds`, `userspace`, and the entire write path |

Three consequences, and they shape the whole module:

1. **The read surface is JSON.** `list`, `get` and `status` on both tools *are*
   the read surface. v1 parses no text at all.
2. **`--json-int` removes the worst part of wrapping ZFS.** `zfs list -o used`
   returns the string `1.4T`, which cannot be compared or summed. With
   `--json-int` the number arrives as an integer, so `Used` is a `[uint64]` of
   bytes and `Where-Object { $_.Used -gt 1TB }` works. No `-p` parsing, no unit
   table, no rounding argument.
3. **`zpool status --json` returns a nested vdev object graph.** The single
   hardest thing to parse in ZFS, and the one every monitoring script gets
   wrong, arrives as structure. `--json-flat-vdevs` exists for consumers that
   want it flat; OS/7 wants the tree. This is the cmdlet that justifies the
   module on its own.

### ZL1 — the write path returns nothing, so Z3 costs a round trip

`zfs snapshot`, `zfs set`, `zpool scrub` and friends have no JSON output and no
output at all. Z3's re-read is therefore a second process per mutation. Accepted:
correctness over a process spawn measured at ~90 ms (§12, M-Z3).

### ZL2 — `zpool iostat` and `zpool events` are text, and they are v2

Performance counters and the event stream are the two things a monitoring
integration wants most and the two `-j` does not reach. They are text-parsed in
v2 or not at all. Naming this now so v1 is not mistaken for complete.

---

## 5. Objects, not JSON — and the boundary that measurement moved

Two consumers want opposite things:

* **`os7-setup`** wants exactly one JSON object on stdout and progress on stderr
  ([../installer/src/OS7.Setup/Steps/StorageSteps.cs](../installer/src/OS7.Setup/Steps/StorageSteps.cs)).
* **A human** wants objects in the pipeline: `Where-Object`, `Sort-Object`,
  `Format-Table`, `-WhatIf`, tab completion.

### Z4 — the object layer is the truth; JSON is a transport at the boundary

Cmdlets return typed objects. The installer gets a thin entry script that adds
`| ConvertTo-Json -Compress`. **No `-AsJson` switch on individual cmdlets** — a
switch that changes the output type is a PowerShell anti-pattern and doubles
every cmdlet's test surface.

### Z5 — progress goes to stderr explicitly, never through `Write-Verbose`

**Measured (M-Z2), and it inverts the obvious design.** In PowerShell 7.6.5 on
this image:

```
Write-Verbose "V"  ->  stdout      "VERBOSE: V"
Write-Warning "W"  ->  stdout      "WARNING: W"
Write-Output  "O"  ->  stdout      "O"
Write-Error   "E"  ->  stderr
```

and therefore:

```
f -Verbose | ConvertTo-Json -Compress
    stdout:  VERBOSE: progress
             {"a":1}
    parsed:  JSONDecodeError — stdout is not valid JSON
```

`Write-Verbose` **pollutes the installer's result channel and breaks it.** The
`[Console]::Error.WriteLine()` in `OS7.psm1` looks like something to modernise;
it is the reason the contract holds. Rules that follow:

* Machine progress: `Write-ZfsStep`, writing to `[Console]::Error`. Always.
* `Write-Verbose` is for humans and never appears on a path that feeds
  `ConvertTo-Json`.
* The IPC entry script suppresses the other streams anyway
  (`3>$null 4>$null 6>$null`) — belt as well as braces, because the rule above
  is a convention and the redirect is a mechanism.

It is in BUILD-NOTES as **#60** — a trap with a silent failure mode and a
plausible wrong fix.

Getting that number cost a lesson of its own. This session read its own tree,
saw "numbers above 56 are free", left #57 clear because the cascadia branch had
spoken for it, and took 58 and 59. By the time it came to push, `origin/main`
had 57, **58 and 59** all taken, and both entries had to be renumbered on top of
a rebase. BUILD-NOTES' own claiming section says it in one line — *check against
`origin/main`, not against your own tree* — and it says it because this has now
happened twice.

### Z6 — types and formats

* Sizes: `[uint64]` bytes, displayed through `Zfs.format.ps1xml` as `1.4 TiB`.
  Visible as human units, comparable as numbers.
* `creation` etc.: `[datetime]`. GUIDs: `[guid]`. Health: an enum.
* `PSTypeName` on every object (`OS7.Zfs.Dataset`, `OS7.Zfs.Pool`,
  `OS7.Zfs.VdevNode`, `OS7.Zfs.Snapshot`) so formats and parameter binding work.
* Datasets accept pipeline input by property name, which is what makes
  `Get-ZfsDataset rpool/DATA -Recurse | New-ZfsSnapshot -Name daily` one line
  instead of a shell loop.

---

## 6. Safety

ZFS destroys data quickly and irreversibly, and the audience is Windows admins
who do not necessarily know that `zfs destroy tank/data` takes its snapshots
with it.

### Z7 — `ConfirmImpact = 'High'` on everything destructive

`Remove-ZfsDataset`, `Remove-ZfsSnapshot`, `Restore-ZfsSnapshot` (rollback is
destructive — it discards everything after the snapshot), `Remove-Zpool`. They
prompt by default and take `-Confirm:$false` for automation, which §6 of the
release plan requires for Intune and Arc.

### Z8 — the OS/7 guard lives in Layer 3, not Layer 2

Refusing to operate on `rpool/ROOT/<active BE>`, `bpool/BOOT/*` or
`rpool/USERDATA/*` without `-Force` is **OS/7 knowledge**. Putting it in the
generic module would cripple it for someone running it against a TrueNAS box and
would leak the boot-environment concept across the boundary Z1 draws.

So Layer 2 stays sharp, and `OS7` wraps the dangerous verbs with
`Assert-OS7DatasetSafe`. This is the clearest single argument for the split
being real rather than cosmetic.

---

## 7. The v1 surface — 24 cmdlets, built

Chosen to serve exactly two customers: the update train, and an operator's day.

| Group | Cmdlets |
|---|---|
| Read | `Get-Zpool`, `Get-ZpoolStatus`, `Get-ZfsDataset`, `Get-ZfsSnapshot`, `Get-ZfsProperty`, `Get-ZfsSpace` |
| Datasets | `New-ZfsDataset`, `Remove-ZfsDataset`, `Rename-ZfsDataset`, `Set-ZfsProperty`, `Clear-ZfsProperty`, `Mount-ZfsDataset`, `Dismount-ZfsDataset` |
| Snapshots and clones | `New-ZfsSnapshot`, `Remove-ZfsSnapshot`, `Restore-ZfsSnapshot`, `New-ZfsClone`, `Convert-ZfsClone` |
| Pools | `New-Zpool`, `Remove-Zpool`, `Import-Zpool`, `Export-Zpool`, `Start-ZpoolScrub`, `Clear-ZpoolLabel` |

Plus `Format-ZfsSize` (Z6) and `Test-ZfsModule` (Z10), which are not operator
verbs.

**24 since 2026-08-26**, when `Clear-ZpoolLabel` was added for Z14. **23 and not
the 21 this section first listed.** `Clear-ZfsProperty` and
`Remove-Zpool` were moved forward from v2 for one reason: each is the inverse of
something v1 already has. `Set-ZfsProperty` with no way to un-set leaves the
operator in bash to type `zfs inherit`, and that is the exact failure §6 of the
release plan describes — one missing verb and the guarantee is gone. Both are a
few lines.

**v2:** `Send-`/`Receive-ZfsSnapshot` (replication), device management
(`replace`/`attach`/`detach`/`offline`/`online`), zvol tooling, delegation
(`allow`/`unallow`), holds and bookmarks, `Get-ZfsEvent`, `Get-ZpoolIostat`,
native encryption (`Unlock-`/`Lock-ZfsDataset` — present in the generic module,
unused by OS/7 by locked decision).

### Safety, as built

* Destructive verbs — `Remove-ZfsDataset`, `Remove-ZfsSnapshot`,
  `Restore-ZfsSnapshot`, `Remove-Zpool`, `New-Zpool` — are
  `ConfirmImpact='High'`, so they prompt unless given `-Confirm:$false`.
* **`Remove-ZfsSnapshot` refuses a name without an `@`**, and
  `Remove-ZfsDataset` is a separate cmdlet. One mistyped name should not be able
  to destroy a filesystem when a snapshot was meant.
* `Restore-ZfsSnapshot` needs `-Force` to discard newer snapshots and a
  *separate* `-DestroyClones` to take their clones. `zfs rollback`'s `-r` and
  `-R` are one keystroke apart and one of them reaches other people's datasets.
* **Pool names are validated before `zpool` sees them** — a name beginning with
  `mirror`, `raidz`, `draid`, `spare`, `log`, `cache`, `special` or `dedup` is
  rejected with an explanation, rather than by ZFS afterwards with "name is
  reserved". §5 of the session document is how that was learned.
* Every destroy **asks ZFS whether the thing is gone** (Z3) and throws if a
  successful-looking destroy changed nothing.

### Z9 — two nouns, `Zfs` and `Zpool`, mirroring the two binaries

`Get-Command *Zpool*` then answers "what can I do to a pool", which is the mental
model an admin already has. A single `Zfs` prefix would merge two objects that
ZFS itself keeps apart.

Approved verbs throughout, so the module imports without a warning:
`zfs rollback` → `Restore-ZfsSnapshot`, `zfs promote` → `Convert-ZfsClone`,
`zpool scrub` → `Start-ZpoolScrub`, `zfs inherit` → `Clear-ZfsProperty` (v2).

### ZL3 — "fully manageable" is true after v2, not after v1

v1 leaves replication, device replacement and delegation on the CLI. The §6
criterion is met at the end of v2, and the documentation must say so rather than
claim completeness early.

---

## 8. Test strategy

There is no Pester in this repository and no test of the OS7 module beyond an
install implicitly exercising it. For ~45 cmdlets that is not enough.

### Z10 — two tiers, and the fixtures are real output

1. **`Test-ZfsModule`, a self-test in the module**, against the one seam (Z2),
   with **captured real ZFS output as fixtures** — never hand-written JSON,
   which tests the fixture author's belief rather than ZFS. Runs in the build
   container in seconds; CI can run it.
2. **`installer/testing/run-zfs.py`** — boots the live ISO, creates file-backed
   vdevs (`truncate` + `zpool create tank /path/img`) and runs the surface
   against **real ZFS with a real kernel module**. No physical disk, and the
   same shape as `run-phase1/3`.

**No Pester — measured, not preferred.** PowerShell 7.6.5 ships ten modules in
this image and Pester is not among them, and nothing else on the image provides
it. Adding it would mean a new pinned component in
[os7-release.conf](../build/config/os7-release.conf), fetched and hash-checked
like the PowerShell tarball, for test code only.

The alternative costs less and fits what this repository already does: it wrote
`vmconsole`, `vmscreen` and `check-image.py` rather than adopting frameworks,
and `os7-setup --self-test` is exactly this pattern. A test that only a
developer can run is a test that stops being run.

### ZL4 — the self-test cannot run in a build hook, and the plan first said it could

This document's first draft had `Test-ZfsModule` running in build hook 0080
"inside the chroot, so a broken parser fails the BUILD rather than a boot",
by analogy with `os7-setup --self-test`. **The analogy does not hold, and
BUILD-NOTES #38 had already measured why.**

`os7-setup` is a NativeAOT binary that depends on nothing. `Test-ZfsModule` is
PowerShell, and it calls `Get-Content`, `ConvertFrom-Json` and `Where-Object` —
all of which are *autoloaded by name* from `$PSHOME/Modules`, which is precisely
the lookup that is broken under live-build's `chroot(2)`. #38's rule, written
before this plan existed:

> A build-time hook may `Import-Module` by path and inspect what it exports. It
> must not CALL anything that needs a bundled cmdlet.

So the self-test runs in two places instead, and hook 0060 does what a hook may:

| Where | What it proves | Authority |
|---|---|---|
| **hook 0060** (build) | both modules are present, their manifests parse, and every documented function exports. Plus: at least five recorded ZFS captures shipped beside the Zfs module | fails the build |
| **`check-image.py`** (finished ISO) | the shipped module parses the shipped captures, run by chrooting into an overlay with `/dev` bound | fails the image — but only if a verdict was produced; "PowerShell said nothing" is a NOTE, the shape hook 0075 uses and #38 credits |
| **`run-zfs.py test`** (booted VM) | `Test-ZfsModule -Live`: the cmdlets against real ZFS, which is the only thing that can catch a wrong `-o` column | the real gate |

Tier 2 is not optional, and M-Z1 is why: the chroot could not answer a question
about ZFS because the kernel module is not loaded there (§12). A test that runs
where ZFS does not is a test of argument strings.

---

## 9. Where the module lives — and when it leaves

### Z11 — built here, extracted at a defined bar

`powershell/Zfs/` next to `powershell/OS7/`, boundary enforced by the Z1 test.
Extraction to a separate repository (`upinblue/PSZfs`) and publication to the
PowerShell Gallery happens when, and not before:

> `New-OS7Storage`, `Update-OS7` and `Restore-OS7` use nothing but Layer 2, and
> the Pester suite is green against a booted OS/7 VM.

At that point the extraction is mechanical, and the first published version is
one that has demonstrably installed and updated machines — a better first
release than a wrapper somebody wrote.

**Why not a separate repository today:** the cost is not the repository, it is
the second release train. OS/7 pins everything to one
[os7-release.conf](../build/config/os7-release.conf). An external module must be
consumed **pinned**.

### Z12 — when extracted, consumed as a pinned tarball with a SHA256 — not a submodule

The shape hook 0020 already uses for PowerShell and the font: fetch a released
artefact at build time, verify its hash, fail the build on a mismatch. A git
submodule is git indirection inside the build container, and **BUILD-NOTES #43
is the record of what git indirection does there** — a `.git` file pointing
outside the bind mount made every ISO report version `1.0.0.0`. Do not buy that
problem a second time.

The module then gets a `components.zfs_module` entry in `release.json`, and the
manifest keeps describing what the release actually consists of.

### Z13 — inside OS/7 it ships as `os7-zfs-module`, separate from `os7-module`

CURATION-AND-DELIVERY-PLAN C7 turns every OS/7 component into a `.deb`. The ZFS
layer is its own package because it has its own version and its own upstream
once Z11 fires; `os7-module` depends on it.

### Z14 — the READ cmdlets take `-ComputerName`; and `Clear-ZpoolLabel`

**Added 2026-08-26 for the backup feature** ([BACKUP-PLAN.md](BACKUP-PLAN.md) §4),
and both are Layer 2 rather than Layer 3 because both are generic: they would be
the same on a TrueNAS box, and neither knows anything about OS/7.

**`-ComputerName` on `Get-Zpool`, `Get-ZpoolStatus`, `Get-ZfsDataset` and
`Get-ZfsSnapshot`.** Plumbed through the one seam (Z2) as `ssh <host> zfs …`, so
`Invoke-ZfsNative` is still the only function in this module that starts a
process and `Test-ZfsModule` still replaces exactly one thing.

It exists because of a question Layer 3 could not otherwise answer honestly:
*did the replication actually land*. The tools that do the replicating report
success with their post-transfer work unfinished, so the only trustworthy answer
comes from the receiving pool's own ZFS. The alternative — an `ssh` invocation
from `powershell/OS7` — would have required weakening `check-layering.py` to let
it past, which is the wrong direction for a guard. With this, Z1 stays at **0**.

**READ ONLY, and enforced rather than documented:** the mutating cmdlets do not
take the parameter at all. A module that can destroy a dataset on another
machine is a different product.

Three ssh options are not negotiable and are not parameters — `BatchMode=yes`
(a verification that BLOCKS on a prompt is worse than one that fails),
`ConnectTimeout=10`, and `StrictHostKeyChecking=yes` (a target whose identity is
accepted on sight is one anything on the path can impersonate, and this reads the
answer to "is my data really over there"). Remote arguments are shell-quoted and
local ones are not: `ssh` joins its arguments and hands them to a **login shell**
while `& zfs @args` has no shell in it at all, so the two paths escape
differently on purpose.

**`Clear-ZpoolLabel`** — `zpool labelclear`, needed before a pool can be created
on a device that held one. Without it, Layer 3 would have to run `zpool` itself,
which Z1 forbids. Its verification is the interesting part: `labelclear` **exits
non-zero when there is nothing to clear**, so a *second* call that succeeds means
the label survived the first. That is the only way to satisfy Z3 here, because
`zpool list` cannot see a device that is not in a pool.

**What this does NOT do.** It is not replication: `Send-`/`Receive-ZfsSnapshot`
are still v2 and still unbuilt, and OS/7 replicates with `syncoid` rather than
with this module. Nor is it holds or bookmarks. ZL3 is unchanged — "fully
manageable" is true after v2, not after v1 plus these two.

### Why a public module is worth anything at all

Honestly: the audience is initially our own. PowerShell people are not asking
for ZFS and ZFS people are not asking for PowerShell. But it is a **measurably
empty niche** (§2), MIT-licensed at no extra cost once the module exists, and a
checkable artefact of the claim "PowerShell-first Linux" — which is the pitch.
It is worth more as evidence than as a contribution, and that is a reason for it,
not against it.

---

## 10. What this buys the product beyond the shell

**Intune custom compliance on Linux is a script that emits JSON.** With this
layer, an OS/7 compliance rule is:

```powershell
pwsh -c "Test-Zpool | ConvertTo-Json"
```

so OS/7 can ship **ready-made compliance definitions**: pool healthy, scrub
younger than N days, no degraded vdev, no checksum errors. No other Linux
distribution can offer that, and it sits exactly on the Intune requirement that
already outranks everything else (README, "Intune compatibility is a hard
requirement"). Verify the custom-compliance script contract against Microsoft's
live docs before building it — that rule applies here too.

---

## 11. Plan

| Phase | What | Gate | State |
|---|---|---|---|
| **Z-0** | Measurements M-Z1…M-Z5 | §12 | **done** |
| **Z-2a** | `run-zfs.py capture` + `zfs-fixtures.sh`: build a ZFS world in a VM and bring its output home | all five `-j` captures parse | **done** — 18 fixtures |
| **Z-1** | `Invoke-ZfsNative`, `Invoke-ZfsJson`, the six `Get-*` cmdlets, `Format-ZfsSize`, `Zfs.format.ps1xml`, `Test-ZfsModule` | `Test-ZfsModule` green against the captures | **done** — 43 checks |
| **Z-1b** | Staged by `build.sh`, verified by hook 0060, self-tested by `check-image.py`; `check-layering.py` holds Z1 at its baseline | a built ISO | **done** — `OS7-1.0.0.78-arm64`, M-Z6 |
| **Z-2b** | `run-zfs.py test`: `Test-ZfsModule -Live` on a booted VM | tier 2 green | **done** — 49 checks, incl. the `-o` columns |
| **Z-3** | The 17 mutating cmdlets, each honouring Z3 and Z7 | tier 2 green | **done** — 56 offline, plus `-LiveWrite` |
| **Z-4** | `New-OS7Storage` moved onto Layer 2; `check-layering.py` at 0 | **`./installer/testing/run-phase3.py all`** | **done, and through the gate** — install PASS, boot PASS, walk PASS (M-Z7) |
| **Z-5** | v2 surface; then the Z11 bar and extraction | | |

**Z-4 is the one with teeth.** It touches the only code path proven to install a
machine that boots. It goes last, after Layer 2 is tested, and it does not land
until `run-phase3.py all` is green — a passing build is not the check, because a
passing build has never been the check in this repository.

---

## 12. What was measured, and how

All three on 2026-08-25, against `out/OS7-1.0.0.46-arm64.iso`, by loop-mounting
the squashfs and chrooting into the shipped image — the `check-image.py` method.

**M-Z1 — which ZFS subcommands support `-j`.** *First attempt failed and said so
loudly.* Probing `zfs list -j` in a chroot returned "The ZFS modules cannot be
auto-loaded" for all ten commands tried, which the probe scored as ten times
"`-j` accepted". The control — a bogus option `-Q` and a bogus subcommand
`frobnicate` — produced **the identical message**, proving the probe could
distinguish nothing. Answered instead from the man pages shipped *in the image*,
which are ZFS 2.4.1's own statement about itself: `-j`/`--json` on `zfs list`,
`zfs get`, `zpool list`, `zpool get`, `zpool status`, with `--json-int` on all
five and `--json-flat-vdevs` on `zpool status`. Nowhere else. §4.

**M-Z2 — where PowerShell's streams go.** `Write-Verbose` and `Write-Warning`
land on **stdout**; only `Write-Error` reaches stderr. A verbose line ahead of
`ConvertTo-Json` makes stdout fail `json.load` outright. §5, Z5.

**M-Z3 — module import cost.** Bare `pwsh -Command exit`: 87 / 95 / 101 ms.
With `Import-Module OS7`: 136 / 139 / 143 ms. The module costs ~45 ms; Setup
starts `pwsh` twice, so ~90 ms total. There is room for a second module and a
format file, and this is the number to re-measure when both exist.

**M-Z4 — the shapes, from real ZFS.** `run-zfs.py capture` booted the live ISO,
built two pools on 256 MB files (a mirror and a single device), five datasets, a
zvol, three snapshots and a clone, and brought 18 captures home over the serial
line. All five `-j` commands returned parseable JSON, so §4 is now confirmed
against output and not only against a man page. The shapes are in
`powershell/Zfs/tests/fixtures/` and are what the parsers were written against.

Three things that only real output could have said:

* **`zpool status --json` really does nest** — `pools.tank.vdevs.tank.vdevs.mirror-0.vdevs.<leaf>`,
  every level carrying `state` and read/write/checksum counters. Captured
  healthy and then again with a device `offline`: `DEGRADED` propagates up the
  levels, and the pool gains `status` and `action` keys that a healthy pool does
  not have.
* **Snapshots carry `dataset` and `snapshot_name` as their own fields**, so
  nothing has to split a name on `@`.
* **`-j` does not turn errors into JSON.** `zfs list -j nosuchpool/x` exits 1
  with plain text on stderr and no output at all. A reader that expects an empty
  result set on a bad name is wrong.

**M-Z6 — the three-way split works, and the middle tier does run.** ISO
`OS7-1.0.0.78-arm64` built with both modules staged; hook 0060 passed, and
`check-image.py` reported:

```
ok    the Zfs module parses the ZFS output it ships with — Zfs self-test: 40 passed, 0 failed
```

So the module reaches the image, the fixtures reach it with it, and **PowerShell
can call bundled cmdlets in `check-image.py`'s overlay chroot** — which is the
half of ZL4 that could only be settled by trying. It says nothing about
live-build's chroot, where BUILD-NOTES #38 measured the opposite and where the
hook still does only what a hook may.

(40 rather than 43: that ISO carries the module as it was before three
rendering fixes landed. The count is a property of the shipped module, which is
the point of asking the image rather than the source.)

**M-Z5 — numbers beyond `Int64`, which §12 first listed as unmeasured.** The
very first captured field settles it: `pool_guid` is `13714606391384389334`,
above `Int64.MaxValue`. `ConvertFrom-Json` returns it as
`System.Numerics.BigInteger` and it **round-trips exactly** — `ToString()`
equals the 20 digits in the file, and `[uint64]` accepts it. Measured on
PowerShell 7.6.2 (the host); the image has 7.6.5, and this should be re-checked
there when an ISO exists. `ConvertTo-ZfsBytes` handles `BigInteger` explicitly
and the self-test asserts it.

**M-Z7 — Z-4 through its gate: a machine installed by the new path BOOTS.**
`./installer/testing/run-phase3.py all` on `OS7-1.0.0.78-arm64`:

```
### Phase 3 result
    install   PASS
    boot      PASS
    walk      PASS
```

— installed unattended, then started **with no ISO attached** (GRUB, kernel,
initramfs, LUKS, pool import, login, `/` from `rpool/ROOT/os7_…`), then a second
machine installed **by keypress alone** through to the Complete screen.

The harness does not surface `pwsh`'s stderr, so the absence of `ZFS-STEP` lines
in its log proves nothing about which code path ran. Asked of the artefact
instead:

```
=== direct zfs/zpool invocations in the SHIPPED OS7 module ===
  (none)
=== does the shipped OS7 module call the Zfs layer? ===
  New-Zpool -Name bpool …   New-ZfsDataset …   Mount-ZfsDataset …
```

There is no other path in the image. The pools on that disk were created through
Layer 2.

### What was NOT measured

* **`Test-ZfsModule -Live` has never run.** The offline self-test proves the
  parsers against recorded output; it structurally cannot prove that the `-o`
  column lists the cmdlets send are columns ZFS accepts. That is phase Z-2b and
  nothing about argument construction should be trusted until it passes.
* **M-Z5 on 7.6.5.** Measured on 7.6.2. A JSON number-handling change between
  two patch releases is unlikely and is not evidence.
* **amd64.** As with every other result in this repository.
* **The write path on anything but a file-backed pool in a VM.** `-LiveWrite`
  exercises create, set, snapshot, rollback, clone, promote and destroy — on
  256 MB files, on one machine, on arm64. No real disk, no pool under load, no
  pool with a real fault.
* **amd64, and a real disk.** Phase 3 is arm64 in QEMU, as every result in this
  repository is.
* **The Intune custom-compliance contract** (§10) has not been read against
  Microsoft's live documentation.
