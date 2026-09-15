# Domain users had no versions, and the window told them their history reached back to this morning

**2026-09-15, bench `v20`** — an amd64 machine installed from
`OS7-1.0.0.233-amd64.iso`, the medium §2e of
[SESSION-VERSIONS-RESTORE-SAFETY.md](SESSION-VERSIONS-RESTORE-SAFETY.md) was
installed from. Everything below was typed at it.

**The short version.** VERSIONS-PLAN **VL7** said domain users' homes are on
`rpool/DATA` and outside the snapshot policy, so they have no versions. That was
right and it was the smaller half. Measured here: the feature does not merely
go quiet on those paths — **the window states a history that does not exist**.
It asks with `-IncludeCurrent`, the live file is always there, so the count is
never zero and the `NoHistory` sentence written for exactly this case was
**unreachable for any file that exists**. A reader was told *"1 versions, back
to 2026-09-15"* about a file nothing on the machine keeps.

Three defects, and the second and third were found by **clicking**, after the
first was fixed and every check in this repository was green — which is §2d's
lesson arriving a second time, in the same feature, within a day. Two of them
are now BUILD-NOTES **#163** (a switch that guarantees a non-empty answer makes
the empty branch unreachable) and **#164** (the workbench, §6), and each is held
by a check proven to fire.

| | what it was |
|---|---|
| **VL7** | `rpool/DATA/lib/os7-domain-homes` was in no backup policy. One line of defaults and one migration |
| **V6, unreachable** | a dataset with no snapshots returned an empty list in silence, and the window turned that into a claim about the past |
| **the refusal arrived as a stack trace** | PowerShell 7's default `ConciseView` renders a thrown exception as a source excerpt with the message in `\| `-prefixed fragments beneath it, and the window drew all of it — **and drew it twice**, because the message was bound both under the heading and in the empty pane |

---

## 1. What was measured

| # | Question | Answer |
|---|---|---|
| M-V52 | Is the domain-home dataset in the snapshot policy? | **No.** `/etc/sanoid/sanoid.conf` and `/etc/os7/backup.json` name `rpool/USERDATA` and `rpool/DATA/srv`. `rpool/DATA/lib/os7-domain-homes` exists, is mounted at `/var/lib/os7/domain-homes`, and is in neither |
| M-V53 | What does `Get-OS7FileVersion` say about a file in it? | **Nothing at all**: `COUNT=0`, `ERRORS=0`. The same for `/var/log/syslog`, `/var/tmp/...` — every ZFS dataset with no policy |
| M-V54 | **What does the WINDOW say?** | **"1 versions, back to 2026-09-15"**, over a single `Now` card. Not "no history" — a claim that the history reaches back to today. See §2 |
| M-V55 | Does anything else about the feature fail on that dataset? | **No.** Two hand-made snapshots and the whole window works through it — cascade, timeline, preview, captions. **Only the policy was missing** |
| M-V56 | Can one user read another's files out of a snapshot of the SHARED dataset? | **Only if the live file allowed it.** A home at 0700 answers `Permission denied` through `.zfs/snapshot`; one that was 0755 when the snapshot was taken is readable. Snapshots keep the permissions the files had — measured in both directions, with a second unprivileged account as the control |
| M-V57 | Can the message name which of the two reasons applies? | **Not honestly.** `/etc/os7/backup.json` is **0600 root:root**, so the unprivileged owner who reads the refusal cannot read the file that would say. `/etc/sanoid/sanoid.conf` is 0644 — and it is the GENERATED half, which this module's own comment forbids reading as truth |
| M-V58 | Does the migration take a machine that already has a policy? | **Yes**, and it is idempotent: first run added the dataset and re-read the policy to prove it, second run said "already in the policy" and exited 0. The two existing sources kept their place, the retention carried across, `childrenOnly` came out `false` |
| M-V59 | Does sanoid then snapshot it? | **Yes** — `autosnap_2026-09-15_15:20:01_{monthly,weekly,daily,hourly}`, on its own timer, its own names |
| M-V60 | And does the feature work for a domain-home path? | **Yes.** The cmdlet returns five rows; the window draws two (the four identical snapshots collapse) with `Now` in front |
| M-V61 | **What does the new refusal look like in the window?** | **A stack trace.** See §3 |
| M-V62 | Is that PowerShell's view setting? | **Yes.** `ConciseView` (the default) wraps the sentence into `\| ` fragments under `OperationStopped: …/OS7.BackupRestore.ps1:478` and a row of tildes. `NormalView` puts the message **first and whole** and appends its own account of the source |
| M-V63 | And after the fix? | **The sentence, once, and nothing else** — no source excerpt, no `OS7-STEP` progress line, and not repeated under the heading |

---

## 2. M-V54 — the window did not go quiet, it made a claim

The pane that says which kind of nothing this is (V6) is reached from
`App.axaml.cs` when the cmdlet returns **zero** entries. The window asks

```
Get-OS7FileVersion -Path $p -DistinctOnly -IncludeCurrent -IncludeAbsent
```

and `-IncludeCurrent` puts the live file in the list. A file somebody
right-clicked exists, so the count is **one**, never zero, and the window went
to its ordinary listing path:

```
notes.txt
1 versions, back to 2026-09-15
```

with one `Now` card. Every word of that is defensible in isolation and the whole
of it is false about the thing the operator came to ask. `/var/lib/os7/domain-homes`
is where **every domain user's home** is, so on a domain-joined machine this is
what the feature does for everybody who would use it.

**This is §7b's shape in a second place**, and that is worth saying plainly: a
refusal that is written, correct, well-phrased, and unreachable. The first time
it was `Get-OS7PathDataset` resolving `/proc/cpuinfo` to the boot environment;
this time it is `-IncludeCurrent` guaranteeing the list is never empty. Neither
was visible from the code, and both were visible in one screenshot.

### What was built

`Get-OS7FileVersion` now refuses **before the loop** when the owning dataset has
no snapshots at all, regardless of `-IncludeCurrent` — because *what is there
now* is not an answer to *what is kept*. The message names the dataset, says out
loud what the empty list would have meant, and carries **both** reasons with the
verb that separates them:

> `rpool/DATA/tmp` has NO snapshots at all, so nothing on this machine holds an
> earlier version of '/var/tmp/probe/bericht.txt'. This is NOT 'the file has
> never changed' — no history is being kept for this dataset. Get-OS7BackupPolicy
> says which datasets this machine snapshots; if `rpool/DATA/tmp` is not among
> them, Set-OS7BackupPolicy is what adds it, and if it IS among them this machine
> has simply not taken its first snapshot yet — sanoid takes one within fifteen
> minutes of a fresh install.

**It consults neither of those cmdlets**, and M-V57 is why: the file that would
decide between the two reasons is 0600, and the reader of this message is
exactly the account that cannot open it. A diagnostic that asked would be right
only for the reader who needs it least. `check-storage-logic.py` §11 holds that
as a source rule, and asks about a **call** rather than about the names
appearing — the names are in the sentence on purpose.

---

## 3. M-V61 — the sentence arrived wrapped in PowerShell's account of its own source

With the fix on the machine, the window drew this:

```
Previous versions could not be listed.
OS7-STEP ZFS layer: /usr/local/share/powershell/Modules/Zfs/Zfs.psd1
OperationStopped: /usr/local/share/powershell/Modules/OS7/OS7.BackupRestore.ps1:478
Line |
 478 |          throw [System.InvalidOperationException]::new(
     |          ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     | rpool/DATA/tmp has NO snapshots at all, so nothing on this machine holds
     | an earlier version of '/var/tmp/probe/bericht.txt'. This is NOT 'the
     …
```

**and then the same block again**, in the pane below it.

Two independent defects, neither of them new and both invisible until a refusal
was long enough to notice:

**PowerShell 7 defaults to `ConciseView`**, which renders a thrown exception as
a source excerpt with the message broken into `| `-prefixed fragments. That is a
good format at a terminal for somebody debugging a script and the wrong one for
every other reader. `PowerShellRunner.PlainTextPrefix` now asks for
`NormalView` — the third setting of exactly this kind in that one string, beside
`$PSStyle.OutputRendering = 'PlainText'` — and `ShellResult.Message` drops what
NormalView appends (`At <file>:<line> char:<col>` and everything after it) plus
the `OS7-STEP`/`ZFS-STEP` progress lines, which are not errors and which
[§2a](SESSION-VERSIONS-RESTORE-SAFETY.md) already recorded can name a step that
did not happen.

**It is never "the first line".** A refusal may be several lines on purpose —
V19's carries `zfs`'s own words under OS/7's — so the rule removes two
recognisable shapes and keeps everything else. Held by four cases in
`os7-versions --self-test`, over stderr **recorded from this machine**.

**And the window bound the message twice**: `SubHeader`, under the heading, and
the empty pane both showed it. `SubHeader` is now the path (what a heading's
second line is for) and a new `Explanation` carries the sentence, in one place.
Survivable with M-V35's one-line message, absurd with a nine-line one, which is
how it shipped.

---

## 4. VL7, and why the simplest answer is the right one here

**One dataset for all domain users, not one per account.** The owner's
instruction was "the simplest — there will not be that many real domain users
anyway", and the measurement agrees:

* A per-account layout means a dataset created at **first login**, before
  `pam_mkhomedir` makes the directory — BUILD-NOTES #78 says `useradd -m` and
  friends do nothing when the directory is already there — and `zfs create` is
  root's. That is a PAM-time mechanism running as root, for a machine with a
  handful of domain accounts.
* The shared dataset needed **one line** in `$script:OS7BackupDefaultSources`
  and one migration, and M-V55 had already shown the feature works through it
  unchanged.
* M-V56 says the sharing costs nothing in confidentiality that the live files do
  not already cost: the snapshot carries the permissions the files had.

**What it does cost** is recorded as **VL10**: retention and `usedbysnapshots`
are shared across every domain user, so `Get-OS7VersionStore` answers for all of
them at once and one busy account's history is charged to the group. That
sharpens VL4 rather than creating a new problem.

**`childrenOnly` is `false` here and `true` for `rpool/USERDATA`**, and the
difference decides whether anything is snapshotted at all: USERDATA's accounts
ARE datasets, and a domain user's home is a **directory**. Children-only on the
domain-home dataset would render a section that snapshots nothing, quietly, for
ever. That decision was inline in `Set-OS7BackupPolicy` where no check could
reach it; it is `New-OS7BackupSourceShape` now, and `Test-OS7Backup` asks it.

### The migration

`build/packages/os7-release/migrations.d/firstboot/71-domain-homes-in-backup-policy`,
because `Set-OS7BackupPolicy` with no `-Dataset` keeps what is **configured** and
falls back to the defaults only when nothing is. That is correct — an update must
not silently rewrite an administrator's dataset list — and it means a machine
installed before today would keep its two-entry policy for ever.

It **adds**, never replaces; passes no retention, so the one in force carries
across; refuses to add a section for a dataset that is not there (a section
naming a missing dataset makes sanoid print CRITICAL ERROR and **exit 0**), and
names migration 70, which creates it; and **re-reads the policy afterwards**,
because `Set-OS7BackupPolicy` exiting 0 is not the same fact as the dataset
being in the policy.

**And the package's required-path list is now derived from the glob that copies
them.** It named `50-tpm2-reseal` alone while three migrations were in the tree,
so a migration that failed to reach the package would have shipped a release
silently missing it — `check-module-parts.py`'s shape, in a directory it does not
cover.

---

## 5. What the checks are, and that they fire

`installer/testing/check-storage-logic.py` grew **§11** (15 checks) and **§12**
(13), and `OS7_STORAGE_MODULE`/`OS7_RESTORE_MODULE` so a defect can be planted on
a copy — the mechanism `check-secureboot-logic.py` and `check-ps-traps.py`
already use, which this file did not have.

| planted | what went red |
|---|---|
| the whole no-snapshots guard removed | **9 assertions**, and `windowCount` came back as **1** — the exact "1 versions" of the screenshot. The two control cases (a dataset WITH snapshots, a file too new to be in one) stayed green |
| a real `Get-OS7BackupPolicy -ConfigOnly` call inside `Get-OS7FileVersion` | **1 assertion**, naming the line it found |

`Test-OS7Backup` is **69** (was 63): the three defaults, the two shapes, and the
guard allowing the new dataset. `os7-versions --self-test` is **70** (was 58):
the stderr section and the drawn-once rules.

---

## 6. The workbench, which cost an hour of this session

**`os7lab.py exec --shell --sudo` elevated only the FIRST command of a chain.**
`sudo -S -p '' <script>` is handed whole to the guest's bash, which parses
`a; b; c` into three commands with `sudo` a word of the first. So

```
id -u; zfs destroy rpool/DATA/lib/os7-domain-homes@probe-2
```

printed `0` and then `cannot destroy snapshots: permission denied`, which reads
as a fact about ZFS and automounted snapshots and is a fact about quoting. It
was believed for two commands.

Fixed: an elevated `--shell` script now goes through base64 into
`sudo -S -p '' bash -c "$(echo … | base64 -d)"` — base64 because it contains
nothing a shell reacts to, the same argument as `-EncodedCommand` on the pwsh
side. Verified on this bench: `id -u` → 0, `zfs snapshot` → 0, `zfs destroy` → 0,
`id -un` → root, all on one line; and a script carrying `"`, `'`, `$`, `;`, `|`
and `&&` survives intact. The one other `run_remote` caller passes
`elevated=False` and is untouched.

**Every pwsh measurement in this document is unaffected** — without `--shell` the
script goes to `sudo pwsh -EncodedCommand` as one process.

---

## 7. What this does NOT say

* **No ISO carries any of it.** The bench has the module file and the
  application copied on by hand (BUILD-NOTES #93), which is why every rule here
  is also held by a check that needs no machine. The next medium is what would
  prove the packaged path, and §2e is the shape that run should take.
* **No domain was involved.** `rpool/DATA/lib/os7-domain-homes` is the dataset
  domain homes live on and it was populated by hand here. That a real domain
  user's home lands there is measured in
  [SESSION-AD-JOIN.md](SESSION-AD-JOIN.md) and is not re-measured.
* **The header still says "could not be listed" for a dataset that keeps
  nothing**, because the cmdlet refuses and the window reads a refusal as
  `Failed`. Nothing failed. Fixing it properly means giving the cmdlet a
  structured error channel — a JSON answer rather than a throw — which touches
  both applications and every refusal, and fixing it improperly means the window
  parsing the message text, which is the coupling V18 removed. Left open and
  written down rather than done badly.
* **arm64 is unmeasured**, as always. The cmdlets are what should be checked
  there; the window is amd64-only by design (VL5).
* **`Get-OS7VersionStore` still answers per dataset**, so VL10 is a limitation
  and not a feature with a report behind it.
