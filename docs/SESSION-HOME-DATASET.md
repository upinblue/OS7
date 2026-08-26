# Session — the home directory gets a dataset (BUILD-NOTES #74)

**2026-08-26.** Closing, in code, the finding the backup work raised the day
before: `/home/<user>` is not on a USERDATA dataset unless the account happens
to be called `os7`.

**Done from Windows, with no Apple Silicon host available.** That decides the
shape of everything below: the VM harnesses in `installer/testing/` are
`qemu-system-aarch64 -machine virt,accel=hvf` and could not be run, so this
session's rule was that **nothing may be claimed that was not measured here**,
and everything else is written down as owed. §5 is the owed list, and it is the
part of this document that matters most.

---

## 1. What was wrong

`New-OS7Storage` creates `rpool/USERDATA/<UserName>_<suffix>` mounted at
`/home/<UserName>`, and `-UserName` defaulted to `os7`. `os7-setup` built its
invocation with four arguments and not five. The account is created six steps
later by `useradd -m` under whatever the operator typed. So on the one machine
this repository has installed and booted, account `os7admin`:

```
/home/os7        a mounted dataset, empty
/home/os7admin   an ordinary directory inside rpool/ROOT/<be>
```

`Restore-OS7` rolls a boot environment back. With the home inside it, that
un-says the user's files — which is exactly what
[installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md) §4.4 puts USERDATA outside
ROOT to prevent, and which §4.4 also says cannot be corrected after the fact.
It cannot be corrected *by the layout*; it can be corrected by moving the data,
which is §4 below.

It survived every automated check in the repository because
`grep -rIn "/home" installer/testing/*.py` returned nothing.

---

## 2. What was measured

Three things, all in a container running Ubuntu 26.04 — the same release OS/7 is
built on — because that is what Windows could reach.

### 2.1 `useradd -m` against a home that already exists → BUILD-NOTES #78

The identical command three times, differing only in what was at the path
first. `passwd 1:4.17.4-2ubuntu3`:

| `/home/<user>` beforehand | exit | after | contents |
|---|---|---|---|
| absent | 0 | `fresh:fresh 750` | `.bash_logout .bashrc .profile` |
| an ordinary directory | 0 | `root:root 755` | *(empty)* |
| a mount point | 0 | `root:root 1777` | *(empty)* |

with `useradd: warning: the home directory … already exists. / Not copying any
file from skel directory into it.` on stderr in the second and third cases.

**This is the finding that changed the fix.** Once `New-OS7Storage` is told the
account name, the home directory ALWAYS exists before `useradd` runs, so this
path is the only one an OS/7 install ever takes. The one-parameter fix on its
own produces a correctly-placed home that is `root:root`, empty, and unwritable
by its owner — a worse machine than the bug, reached by fixing the bug.

Also measured, and used rather than assumed: `HOME_MODE` in this image's
`/etc/login.defs` is **0750**, not the 0755 that gets assumed from `useradd`'s
documented `0777 & ~UMASK` fallback.

### 2.2 `stat -c %d` answers correctly inside a chroot

`AccountStep` runs inside `unshare --mount` + `chroot /target`, where `/proc` is
a bind of the live system's and the pools are imported at an altroot — so
`findmnt` and `zfs list` are both answering about paths that namespace names
differently. Measured: the device number of a mounted directory differs from its
parent's, read from inside such a chroot, with no mount table involved. That is
the check `AccountStep` makes, and the second witness `run-phase3.py` and
`Get-OS7Home` make.

### 2.3 The bash `os7-setup` generates, run against a real `useradd`

The AccountStep script was extracted out of `os7-setup --dry-run`'s log — which
is where the generated shell is already written down — and run for real in three
situations:

```
A  /home/os7admin is its own filesystem   exit 0  os7admin:os7admin 750, skel copied
B  an ordinary directory inside /         exit 1  "…has no dataset of its own… #74"
C  a dataset that already has files in it  exit 0  skel NOT copied, ownership fixed
```

**C failed the first time**, on a `.bashrc` assertion that fires where not
copying skel is the correct behaviour (`R=Repair` installs beside an existing
USERDATA). That is the whole argument for running generated shell rather than
reading it — the same lesson as #16 and #64.

---

## 3. What changed, for new installs

| | |
|---|---|
| `StorageSteps.cs` | builds `-UserName '<account>'` into the `New-OS7Storage` command. The name is there because the executor's contract is a complete plan — `ExecuteScreen.Start` and `--unattend` are its only doors and both call `InstallPlan.Validate` |
| `OS7.psm1` | `-UserName` no longer defaults to `os7`. **Empty means no home dataset is created**, and the result object gained `userName` and `userDataset` so the install log records which home was made. `--storage-only` gets no home dataset instead of a wrongly-named one |
| `SystemSteps.cs` | `AccountStep` copies `/etc/skel` when the home is empty, chowns, chmods to the `HOME_MODE` it reads out of `login.defs`, and then asks `stat` what it actually did. It **fails the install** if the home is on the same filesystem as `/` |
| `run-phase3.py` | checks 9 and 10, on a machine that has booted with no ISO attached: `findmnt` must name a `rpool/USERDATA` dataset, `stat -c %d` must disagree with `/`, the home must belong to the account and hold `.bashrc`, and there must be no phantom `/home/os7` |
| `run-s5.py` | a file written into the home **from the clone** must still be there after the rollback that removes the clone's package. One rollback, two opposite outcomes — the whole of §4.4 in one assertion |

---

## 4. What changed, for machines already installed

`powershell/OS7/OS7.Home.ps1` — `Get-OS7Home` and `Move-OS7Home`.

**The design problem is `overlay=on`.** OpenZFS has defaulted to it since 0.8,
so `zfs create -o mountpoint=/home/<user>` mounts straight over the live
directory and hides every file in it — no error, no warning, and a home that now
looks empty to the person whose home it is. The dataset is therefore created on a
staging path under `/run`, filled, verified, and only then moved into place.

The order, and every step is undone by the one that fails after it:

1. refuse unless the account exists, its home is not already a dataset, ZFS and
   `stat(2)` agree about that, nobody is logged in, and the pool has room;
2. **snapshot the boot environment**, which is what currently holds the files;
3. create `<pool>/USERDATA/<user>_<suffix>` mounted on the staging path;
4. `cp -a`, then verify against the original — owner, mode, a metadata manifest,
   file sizes, symlink targets, and every byte unless `-SkipContentVerify`;
5. rename the original aside — **never delete** it, unless `-RemoveOriginal`;
6. set the dataset's mountpoint to the home, which remounts it there;
7. verify again at the final location, from ZFS and from `stat(2)` both.

`Get-OS7Home` is the diagnostic, and it answers from two independent places on
purpose: ZFS is asked which dataset is mounted where, `stat(2)` is asked whether
the path is a different filesystem from `/`, and `Agrees` reports whether the two
witnesses said the same thing. A dataset ZFS believes is mounted and is not is a
machine whose home LOOKS covered.

### `installer/testing/check-home-logic.py` — 45 checks, about four seconds

The same bargain `check-be-logic.py` struck for the boot environments: run the
real cmdlets against a fake `zfs` and check the DECISIONS, because the VM cycle
that would find these bugs costs twenty-five minutes and has not been run at all.

**The fake's one load-bearing behaviour is that a dataset IS A SEPARATE
FILESYSTEM**: `zfs create -o mountpoint=X` mounts a tmpfs, `zfs set
mountpoint=Y` does `mount --move`. So `st_dev` really changes, the independent
witness really answers, and the migrated files really travel with the mount. A
fake that modelled this with a directory rename would leave the one property the
cmdlet exists to establish unchecked.

It needs Linux, root and mount(2) — and GNU `find -printf`, `stat -c` and
`diff --no-dereference`, which are what the module verifies a copy with — so it
re-runs itself inside `docker run --privileged` in a private mount namespace.
The PowerShell in that container is the version and hash
`build/config/os7-release.conf` pins, so the check does not become a second
place a version number lives.

What it caught while being written, both in the module and both real:

* `& $scriptblock` returns pipeline output, and a pipeline **unrolls**: a list of
  one comes back as a scalar. `$manifest.Links.Count` is therefore an error under
  `Set-StrictMode` on a home with exactly one symlink in it — an entirely
  ordinary home. Same family as #76.
* `$home = $account.Home` **throws**. `$HOME` is a PowerShell automatic variable
  whose options are `ReadOnly, AllScope`, so the name does not shadow it. Caught
  before it ran, by checking, and it is #65's family exactly.

---

## 5. What is NOT measured, and what it would take

This is the honest list, and none of it is optional.

| | |
|---|---|
| **`./installer/testing/run-phase3.py all`** | **The gate.** install, boot with no ISO attached, and a second install by keypress. It has NOT been run. The storage step and the account step of the only code path proven to produce a machine that boots have both been changed |
| **`Move-OS7Home` against real ZFS** | Never. BACKUP-PLAN B-6. Everything known about it comes from a fake whose datasets are tmpfs mounts. The design answers the risk rather than the testing: nothing is deleted, the original is renamed aside, and the boot environment is snapshotted first — so being wrong costs space, not a home |
| **`./installer/testing/run-s5.py all`** | Not run. The rollback assertion added here has never executed |
| **A machine that has the bug, migrated** | Nothing constructs the #74 shape on real ZFS and then repairs it. That is the harness this session did not write, and it is the natural next piece: build the broken shape in a VM, run `Move-OS7Home`, reboot, log in |
| **amd64** | As everywhere else in this repository: nothing here has been near it |
| **An Entra account through `authd`** | `Get-OS7Account` uses `getent` rather than `/etc/passwd` precisely so that those accounts are visible, and no such account has ever existed on an OS/7 machine (DECISIONS open question 4) |

What ran here, green: `Test-ZfsModule` (75), `Test-OS7Backup` (63),
`check-layering.py` (0 direct invocations, baseline held), `check-home-logic.py`
(45), `dotnet build` of `os7-setup` (0 warnings), and the generated AccountStep
bash against a real `useradd` in three situations.

**Which is to say: the decisions are checked and the machine is not.** That
distinction is the whole of this repository's method, and the reason #74 was
flagged rather than fixed in the first place.
