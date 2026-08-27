# Session — `Update-OS7`, and the defects that writing and reviewing it found

**2026-08-27**, on the x64 Windows host. The stub is gone. The update train is
code, it is checked, and it has never run on a machine — which is said here
before anything else, because `run-s5.py` is the gate and this session could not
reach it.

The day before, C7 built the thing to point at: nine OS/7 packages in a signed
suite with a release descriptor and a signed index
([SESSION-OS7-REPOSITORY.md](SESSION-OS7-REPOSITORY.md)). This is the other half.

---

## 1. What was built

`powershell/OS7/OS7.Update.ps1`, dot-sourced by `OS7.psm1` beside the backup and
home files. Four public cmdlets:

| | |
|---|---|
| `Update-OS7` | the sequence: §4.2 as corrected by C10 |
| `Get-OS7Release -Available` | what the channel offers, **verified before it is listed** |
| `Set-OS7UpdateChannel` | point the machine at a repository, and switch on the apt source `os7-release` ships disabled |
| `Test-OS7Update` | 30 tier-1 checks, no VM, about a second |

The sequence, in the order it runs. Step 0 is this file's own; the rest are
numbered as §4.2 numbers them so a reader can hold the plan beside the code.

```
0.  preflight — read the machine, fetch and VERIFY the index and the target
    descriptor, and refuse: wrong Major (C12), stale index, bad signature, a
    development key without -AllowDevelopment, a drifted machine
1.  snapshot rpool/ROOT/<cur>, bpool/BOOT/<cur> AND rpool/DATA
2.  clone the pair
3.  ASSEMBLE the clone, and PROVE it is assembled before chrooting
4.  point apt at BOTH repositories — the pinned snapshot and the OS/7 suite
5.  apt install os7-<mode>=<version>, then full-upgrade, then autoremove
6.  deleted by C10 — but verified, because no ISO installs os7-release yet
6'. run every intervening release's migrations, in order
7.  update-initramfs, and check the TPM2 handler survived it
8.  update-grub inside the clone
9.  activate the pair, then prune to -Keep environments
10. reboot — only with -Reboot
```

### Three decisions the plans did not make

The plans decide a great deal and leave gaps; the operator settled three of them
on 2026-08-27.

**A multi-release jump runs every intervening release's migrations, in order.**
C11 makes `1.0.0 → 1.0.7` one operation and says "the only sequencing is the
migrations … keyed by the *from* version". Either a release declares what
changed in **it**, or every release declares a migration for every older version
it might be reached from. The first: a release that has to remember its
ancestors is a release somebody eventually forgets to update.

**Two boot environments survive an update.** UL9 requires a retention policy
"shipped by default, not left to the operator", and no number existed anywhere.
Two — the new one and the one it replaced — so `Restore-OS7` always has a target
and the pool does not grow without bound. `-Keep` overrides it; the running
environment and the one the menu names are never candidates.

**`Set-OS7UpdateChannel` lands in the same change.** Without it the apt source
stays `Enabled: no` at a `file://` path nothing creates, and `Update-OS7` cannot
reach the OS/7 suite on any real machine. §6's own argument applies: "a single
missing verb sends them back to bash and the guarantee is gone."

### The migration contract, which no document had written down

```
/usr/lib/os7/migrations/<version>/<chroot|firstboot>/NN-name
```

`<version>` is the release that **introduced** the migration. `<context>` is
forced by BUILD-NOTES #69 rather than chosen: C10 names TPM2 re-enrolment after
a PCR 7 move as migration content, and sealing to PCR 7 **from a chroot seals
against the chroot's PCR 7**. So `chroot` migrations run inside the assembled
environment before `update-initramfs`; `firstboot` ones are recorded for the
target's first boot and `Update-OS7` says out loud that it has left work behind.

What has run is recorded under `/var/lib/os7/migrations/` **inside the boot
environment**, and that placement is the other half of C10's own requirement. A
rollback takes the record with it — which is exactly why migrations must be
idempotent: after a rollback the machine genuinely has not run them, and a
record that survived would make it claim otherwise. The full contract is in
`build/packages/os7-release/tree/usr/lib/os7/migrations/README`, which
`os7-release` ships and `build-os7-repo.sh` reads to fill the descriptor's
`migrations` array — so declared and shipped cannot diverge.

---

## 2. The four defects WRITING it found

Two were already in the module. Two were in the new code and were found by the
check, not by reading. §2a is what REVIEWING it found afterwards, which was more.

### #89 — the kernel picker chose the OLDER kernel, and only an update could reveal it

`Get-OS7BootEnvironmentKernel` used `Sort-Object Name -Descending`. Measured:

```
'vmlinuz-7.0.0-9-generic','vmlinuz-7.0.0-31-generic' | Sort-Object -Descending
  -> vmlinuz-7.0.0-9-generic
```

Every boot environment this repository has produced held **exactly one** kernel,
and with one candidate a sort cannot be wrong. **An update is the operation that
leaves two.** The first release ever applied would have produced an environment
whose menu entry named the kernel it was replacing — the older kernel against
the newer root, §4.3's half-activated pair by a different road, with
`update-grub` reporting nothing because OS/7 writes its own entries (#67).

### #90 — a freshness check that could not read the date, and warned

`Get-OS7ReleaseIndex` refuses an expired index — §6.3's defence against a
withdrawn release being served forever. It parsed `valid_until` with
`[datetime]::TryParse` and, when that failed, **warned and carried on**. Three
spellings of the same instant are in circulation here and .NET accepts two of
them; `date -u +'… UTC'` is the third. So an index in that spelling was accepted
**while expired**.

Two fixes, and the second is the one that matters: `" UTC"` is normalised, and
the `else` branch now **throws**. A check that cannot run must never read as a
check that passed — the rule that keeps `Get-OS7Version`'s `Drift` empty rather
than `$false`, and the same shape as #72 and #85.

### #91 — `@('a', $b, $c + $d)` is four elements and reads as three

```powershell
Invoke-OS7Native -Command 'mount' -Arguments @('--bind', $mp, $Root + $mp)
```

produces `mount --bind /srv /run/os7-update /srv`. The array literal binds first
and the `+` **appends**: `('--bind', $mp, $Root) + $mp`. Five instances in one
file. Three failed loudly because `mount` rejected them; two would not have —
`sh -c` handed a concatenation built that way runs the first fragment and takes
the rest as `$0 $1 $2`.

### #65, again, twice — and the second one was mine

`$source` **is** the `-Source` parameter: PowerShell variable names are
case-insensitive, and a `[string]` parameter coerces whatever it is given. I
wrote it four lines below a comment citing #65. The error —
*"The property 'Name' cannot be found on this object"* — names no variable, no
parameter and no file.

The scan written to find it then found a second, latent one in
`New-OS7BackupTarget`: `$poolName` is `-PoolName`, and it worked only because a
`switch` evaluates its branches before the assignment lands.

### The mechanism both got

`installer/testing/check-ps-traps.py`, baselines 0, needs `pwsh` and nothing
else. It asks PowerShell's own parser rather than a regex, because a regex
cannot tell an assignment from a comparison and a check that cries wolf is a
check people delete. The #91 rule keys on an AST signature that is unambiguous —
a `BinaryExpressionAst` with operator `Plus` whose left side is an
`ArrayLiteralAst` — so it cannot fire on a deliberate append, which has a
variable on the left. **It found the fifth #91 thirty seconds after it was
written, in code its author had just reviewed.**

---

## 2a. And ten more that reviewing it found

The implementation was then put to five independent reviewers — sequence,
failure paths, the trust path, PowerShell traps, and the check itself — each
told to report only defects it could point at with a file and a line. They
returned 28 findings. The ones that survived reading the code again, and what
each would have done:

| | what it would have done |
|---|---|
| **The dismount failure said "refusing to go further" and then went further** | The message *was* the refusal. Execution fell through to the activation, which is the one place the "two environments report Active" state does the wrong thing quietly. It throws now. |
| **The retention prune could never remove anything** | Every boot environment is a `zfs clone` of a snapshot *inside* the previous one, so `zfs destroy` refuses the older one for as long as the newer exists. The catch swallowed it and the cmdlet reported success. UL9 was unmitigated while looking mitigated. `Convert-ZfsClone` — `zfs promote` — now runs on **both halves** first, which is what beadm and zsys do and why they can prune at all. |
| **An index entry with no `manifest_sha256`, and a descriptor with no `signing` block** | Both failed OPEN. The first accepted a descriptor nothing signed, with a log line; the second made "this release says nothing about how it was signed" read as "signed for production", so `-AllowDevelopment` was not required. Both refuse now. Unknown provenance is not provenance. |
| **`Set-OS7UpdateChannel` never recorded the channel** | It returned an object saying `Channel = preview` and changed nothing any updater reads — the apt source has no field for it and the suite is per-Major. `/etc/os7/update.conf` now holds it, in `/etc` so a rollback returns the machine to the channel it was on. |
| **`-Keep 2` left three** | Two names are exempt from the candidate list after an activation — the running environment and the one the menu names — and the arithmetic subtracted one. Every value of `-Keep` left `-Keep + 1`. |
| **`full-upgrade` undid the pinned version** | `apt install pkg=1.0.1.0` marks, it does not hold, and the suite accumulates releases — so `-Version` could only ever name the newest one. A `preferences.d` pin on `os7-*` now spans the three apt operations and is removed with them. |
| **The apt source "for the duration of this update" was never taken back out** | A `-Source` handed in for one run — a stick, a mirror, a harness — became the machine's permanent channel, shipped inside the environment about to be booted. So was the version pin. Both are removed now; the *Ubuntu* source stays, because it names the snapshot of the release just applied and that is the result rather than a leftover. |
| **The log was declared and never written** | §6 requires "logging somewhere both platforms can read" and the constant was there with nothing writing to it. It is written now, on `/var/log` — outside the boot environment, which is the whole reason §4.4 puts it there: "the log explaining why an update failed must not vanish with the update." |
| **Nothing named what a failed run left behind** | The cmdlet's own help promised it. A `catch` now names the environment and the one command that clears it, and the check asserts that it does. |
| **The assembly assertion checked a list the caller composed** | Four hard-coded paths, rather than what the assembler actually mounted — so a layout that gained a dataset would be asserted against the old one. `Mount-OS7UpdateRoot` returns what it mounted and that is what is checked. |

**And one that reaches further than this file.** `Get-OS7BootEnvironmentKernel`
took `if ($BootEnvironment.Active)` to mean "this is the running system" and read
the **running machine's** `/boot`. `Active` is ZFS's `mounted` — mounted
*anywhere* — and `Update-OS7` mounts a clone for the whole of an update. The
menu entry for the new environment would have named the running machine's kernel.

That is fixed at the source rather than at the call site: `Get-OS7RootDataset`
asks the kernel which dataset serves `/`, boot environments carry a `Running`
property beside `Active`, and every consumer that meant "the system that is
running" now says so. `Running` is `$null` on a machine that is not ZFS-rooted —
a live medium is casper on overlayfs — and `Test-OS7IsRunning` falls back to
`Active` there, because that is the only signal `os7-setup` has.

**Two of the 28 were about the check rather than the code**, and both were right:
the "nothing left mounted" assertion ran only after a successful `-Stage`, which
is the one path that cannot leak, and the initramfs case only ever exercised the
*skip* branch. Both are now driven from the failing side as well.

---

## 3. What is checked, and what is not

```bash
./installer/testing/check-ps-traps.py        # seconds, needs only pwsh
./installer/testing/check-update-logic.py    # ~3 min, builds its own container
pwsh -c 'Import-Module ./powershell/OS7/OS7.psd1 -Force; Test-OS7Update'   # 25
```

`check-update-logic.py` runs the real module against a `zfs`, an `apt-get`, a
`chroot` and their neighbours that are fakes, and checks **the order** as well
as the outcome — because reversing `install` and `autoremove` removes the
product and both orders "work".

**Three things in it are real, and each because faking it would test nothing:**

* **The mounts.** The fake `mount` performs a real `mount -t tmpfs`, so
  `/proc/self/mountinfo` genuinely reflects what was assembled and
  `Assert-OS7UpdateRootAssembled` reads the kernel rather than a file the test
  wrote. That check exists to catch a partly assembled environment; a fake mount
  table would let the bug it guards against walk through it.
* **The signatures.** `gpg` and `gpgv` are the real ones. The run generates a
  key, signs an index, and then signs another with a **different** key and
  requires the refusal.
* **The order**, above.

**Green on 2026-08-27**, 26 checks, 0 failures:

```
ok  apt install came before full-upgrade
ok  and autoremove came LAST
ok  the rpool/DATA rollback net was snapshotted, BEFORE the clone
ok  nothing is still mounted under /run/os7-update
ok  a release signed by a development key, without -AllowDevelopment  → refused
ok  an index signed by a key it does not trust                        → refused
ok  a target in another OS/7 generation (C12)                         → refused
ok  apt exiting 0 having installed a different version                → refused
ok  an initrd that DROPPED the TPM2 handler                           → refused
ok  and an initrd that carries it                                     → accepted
ok  nothing left mounted after a run that THREW, and the environment
    it left behind is named with the command that clears it
```

### Not covered, and none of it accidentally

* **It has never run on a machine.** `run-s5.py` is the gate — install, clone,
  change, boot the clone, roll back — and it is `qemu-system-aarch64` and needs
  the Mac. Everything here is a claim about code.
* **The chroot is not a chroot.** The fake runs the command in place with a
  variable naming what would have been the root, so the check cannot see whether
  a maintainer script would have acted on the running system instead of on the
  environment being built. That is the single largest thing only a real machine
  can answer, and it is why §4.2 says chroot and not `apt -o Dir::RootDir=`.
* **Activation is checked elsewhere.** The scenarios run `-Stage`, which stops
  before step 9, because `Set-OS7BootEnvironment` already has
  `check-be-logic.py` and `run-s5.py`. What is new here is steps 0 to 8.
* **No migration has ever been written**, so the ordering is checked against
  fabricated files and the execution against a fake `sh`. The first real one
  will be the first test of the contract.
* **`os7-release` is not on any machine yet**, so the branch that re-derives
  `/etc/os-release` after an upgrade has been reasoned about and not run.

---

## 4. Next

1. **`run-s5.py` on the Mac**, extended to call `Update-OS7` instead of doing
   steps 3–8 by hand. That is the gate, and it is the sentence "a machine
   updated by this cmdlet boots" turning from a claim about code into a
   measurement.
2. **Switch the ISO to install the OS/7 packages.** Until then step 6 has a
   branch that exists only for machines the product no longer intends to
   produce, and there are two files called `release.json`
   ([SESSION-OS7-REPOSITORY.md](SESSION-OS7-REPOSITORY.md) §5).
3. **The first-boot migration runner.** `Update-OS7` records what it could not
   run; nothing runs it. UL1 — TPM2 re-enrolment after a PCR 7 move — is the
   case that needs it, and it is the one C10 named.
4. **`Set-OS7Mode`**, the last stub. GUI ↔ headless is now expressible as a
   metapackage swap, which is a sequence of its own with its own risk.
