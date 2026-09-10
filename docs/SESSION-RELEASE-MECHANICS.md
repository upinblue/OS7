# Session: the release process's owed mechanics, built — and #121, found by running a check where it had never run

**2026-09-01, on the x64 Windows host.** Two clusters of work, one method. The
session was asked to fix bugs and finish what was half-built; what was
half-built was named precisely by [RELEASE-PROCESS.md](RELEASE-PROCESS.md) §7.2
and §7.3 (written 2026-08-30, "none of it is speculative; all of it is
unbuilt"), and the first bug of the day was found before any of that — by
running the standing checks on this host and reading the first red line to the
end.

Everything below was measured on this machine. What a no-VM check cannot say
is said in place. `run-s5.py all` — the machine gate — was **not** run in this
session; nothing here changes the paths it proved on 2026-08-28, and the one
thing that would need a machine to say more (a real MINOR update) needs a 1.1
that has never existed.

---

## 1. #121 — a bare `$LASTEXITCODE` read is a crash or an earlier command's exit code

`Test-TimeModule` and `check-be-logic.py` had never run on this host.
`Test-TimeModule` failed on a path-separator literal (below);
`check-be-logic.py` failed with:

```
Invoke-ZfsNative: The variable '$LASTEXITCODE' cannot be retrieved because it has not been set.
```

— a message about a variable, from the one function whose job is to report
what a command did. Both failure shapes were then measured in one pwsh 7.6.5
session rather than reasoned about:

1. A command that does not exist **throws** `CommandNotFoundException`. That
   path was never the problem.
2. A command that is **found but cannot be started** (here: the check's fake
   `zfs`, an extensionless POSIX script, on a Windows PATH) does not throw:
   the pipeline continues with empty output and `$LASTEXITCODE` keeps
   whatever it held. In a fresh session that is *unset* → StrictMode
   terminating error. After any earlier native call it is **that call's
   code** — `0` included, so `Get-ZfsDataset` returned
   `ExitCode = 0, Output = ''`, which every caller reads as "the command
   succeeded and there are no datasets".

Shape 2 is the repository's oldest enemy — a verification step reporting
success for a thing that never happened — sitting inside all six command
runners. The repo half-knew: `Get-OS7PackageDrift` and
`Get-OS7OsReleaseField` have carried a guarded read since 2026-08-26, with a
comment measuring the same engine behaviour against a `.cmd` shim. The
guard never travelled to the runners.

**Fixed in all eight sites** — the six runners (`Invoke-ZfsNative`,
`Invoke-OS7Native`, `Invoke-TimeCommand`, `Invoke-NetCommand`,
`Invoke-SystemdCommand`, `Invoke-DirectoryCommand`), `Move-OS7Home`'s
copy-verification `diff` (the worst possible site for shape 2), and the
gsettings schema-default read — with one idiom, verified in module scope
before it was applied anywhere:

```powershell
$global:LASTEXITCODE = $null          # a stale code cannot be read as this command's
$out = & $exe @argv 2> $errFile
$code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }
```

`$null` is its own outcome: the throwing runners raise
`never completed: <exe> was found but could not be started` (stderr attached);
the non-judging runners return `ExitCode = $null`, which compares unequal to
0, so every existing caller already treats it as a failure. Re-measured
through the real module afterwards: the planted unrunnable `zfs` with a stale
`0` primed now produces the honest throw, not the silent empty success.

**The mechanism is `check-ps-traps.py` class five**, baseline 0, because #112
already proved a note is not a fix. The scan flags any `$LASTEXITCODE` read
outside the guard; writes are the reset half and are allowed. It was checked
against the thing it claims to check — a planted bare read went red, the
idiom did not — and on the clean tree it holds all five classes at 0 across
21 files. [BUILD-NOTES.md](BUILD-NOTES.md) #121 is the note.

## 2. Two checks that could not run on this host now run

* **`Test-TimeModule` 32/33 on Windows**: the sources.d check compared
  `$w.Path` against `'*etc/chrony/sources.d/os7.sources'`, and
  `Path.Combine` joins with `\` here. Compared with separators normalised
  now; 33/33 on this host, and nothing about the Linux path changed.
* **`check-be-logic.py` re-runs itself in a container on Windows** — the same
  container `check-home-logic.py` builds (the pinned pwsh, python3, sh;
  reused deliberately so there is no second PowerShell pin to rot). The fakes
  are POSIX programs and the grub.d script under test is *executed*, so a
  host that cannot start an extensionless file cannot run the check natively
  — running it there anyway is what surfaced #121. On macOS and Linux nothing
  changes. All 23 checks green through the container on this host.

The point of both: [RELEASE-PROCESS.md](RELEASE-PROCESS.md) §2 lists these
gates as runnable on **either** host, and until today that sentence had never
been tested against this one.

## 3. RELEASE-PROCESS §7.2 — the suite now moves with the release

`Update-OS7` wrote the clone's apt source with the *target's* suite and then,
at the end, restored the machine's permanent source **verbatim** — a conffile
`Set-OS7UpdateChannel` wrote with `os7-1.0`, kept by `--force-confold` across
every later upgrade. A machine that took a 1.0 → 1.1 release kept
`Suites: os7-1.0` for ever, and nothing downstream would ever have corrected
it.

The fix is at the restore site, not after activation, and the reasoning is
worth keeping: the environment being written **is** the target release, so it
is the restored *copy in the clone* whose `Suites:` line moves — a `-Stage`d
1.1 carries `os7-1.1` for the day it boots, the running 1.0 environment's own
file is never touched, and a same-suite update restores the file **byte for
byte**.

`check-update-logic.py` gates both halves. The harness grew the two pieces
this needed: the fake `mount` can seed the clone with the machine's permanent
source (a real clone starts with the running system's `/etc`), and a fake
`umount` copies the final file out before the tmpfs standing in for the clone
vanishes — quoting the module's own messages instead would be the
diagnostic-depending-on-the-diagnosed shape BUILD-NOTES warns about twice.

```
ok    a MINOR release (new suite) applies
ok    the environment wakes up on the TARGET's suite
ok    and not on the one the machine followed before
ok    the rest of the file is the machine's own — only the suite moved
ok    a same-suite update restores the file BYTE FOR BYTE
```

## 4. RELEASE-PROCESS §7.3 — one repository, two architectures

Three defects, one property: nothing anywhere compared a release's
architecture to a machine's, because no tree had ever held both.

* **`Get-OS7Release`** now computes `ForeignArchitecture` (a POSITIVE
  mismatch: both sides state an architecture and they differ — a side that
  states none is today's single-arch world, not a refusal) and folds it into
  `Applicable`. **`Update-OS7`** refuses a foreign release asked for by name,
  with both architectures in the message, and when one version is listed for
  both architectures — the two-run tree's normal state — `-Version` prefers
  the machine's own twin over the foreign one the index lists first.
* **`build-os7-repo.sh`** merges: run it once per architecture into the same
  output directory. Every `binary-*` index in the tree is regenerated from
  the shared pool on every run — eight of the ten packages are arch:all,
  rebuilt under ONE filename by either run, so an index the second run did
  not regenerate would record hashes of files that run just replaced. The
  `Release` names the union of architectures, read back from the directories
  that exist. The descriptor moved to `releases/<version>/<arch>/release.json`
  (two architectures at one version were two files overwriting each other);
  machines never compose that path — it travels in the signed index entry —
  and the one fallback in `Get-OS7ReleaseDescriptor` follows the entry's own
  architecture.
* **The index** holds one entry per (version, architecture), and
  `supersedes` names the newest release *of the same architecture* — the
  other architecture's history is another machine's story.

Gated twice, at the two layers:

* `check-update-logic.py` — the reader: a foreign release is LISTED, says
  `ForeignArchitecture`, is never chosen by itself, is refused by name; with
  twins of one version the machine's own wins, chosen and named.
* `check-os7-repo.py` — the builder: after the amd64 tree (dev, stable,
  hotfix) is built, a **second-architecture run merges into the same tree
  before the install probe**, so the probe installs on this host's
  architecture from a tree the other architecture's run rewrote last. The
  Release's `Architectures: amd64 arm64` line, the two descriptors, the
  two index entries, the no-cross-arch `supersedes`, and — the one that
  matters most — the arch:all hash consistency are asserted against the
  pool file that is actually there.

### What the builder's own read-back caught on the way

The first merge run failed inside the harness, and the failure was a
measurement error of this session's own making: an earlier probe had
concluded `apt-ftparchive --arch amd64` includes a package whose control says
`amd64`. It does — **when the filename agrees**. `--arch` keys on the
FILENAME's `_<arch>.deb` segment (`_all.deb` included), and the harness's
hotfix overlay was named `less_…_amd64+os7hf1.deb` — the `+os7hf1` appended
after the architecture segment, where Debian's convention puts it inside the
version. The control field said `amd64`; the file was dropped from the index
without a word; `build-os7-repo.sh`'s every-built-package read-back refused
the build. Measured both ways with the same deb under two names, the overlay
is now named `less_…+os7hf1_amd64.deb`, and the builder's refusal message
names the filename convention so the next person is not sent to the pool
path. The read-back existing at all is why this was one red run instead of a
repository that quietly served every machine of one architecture and no
other.

## 5. What was run, and what was not

Green on this host in this session, after the changes: the six module
self-tests (Zfs 75, Net 68, Time 33, Systemd 76, Directory 51, Backup 63),
`Test-OS7Update` 31, `check-ps-traps.py` (five classes at 0),
`check-layering.py` (five rules), `check-vm-arch.py` 22, `check-be-logic.py`
23 (in the container), `check-home-logic.py`, `check-service-logic.py`,
`check-scheduledtask-logic.py`, `check-network-logic.py`,
`check-directory-logic.py`, `check-installer-cmdlets.py`,
`check-version-rule.py --docker` (both languages),
`check-netplan-rule.py --docker` (byte for byte), `check-ssh-login.py`,
`check-management-logic.py`, `check-update-logic.py` (with the new §7.2/§7.3
sections), and `check-os7-repo.py` (with the two-architecture merge and
probe).

**Not run, said plainly:** `run-s5.py` (nothing in this session's changes is
on the paths it proved, but the suite-rewrite and the merged-tree layout have
not been exercised by a booted machine); everything arm64 (the merge run
labels packages arm64, it does not execute arm64 code); `check-ad.py` and
`check-os7-repo.py --arch arm64`; and no real MINOR release exists, so §7.2's
fix has been seen only through the fake-driven gate.

## 6. What this changes in the plans

* [RELEASE-PROCESS.md](RELEASE-PROCESS.md) §3 step 5 now describes the
  two-run merge instead of naming a missing tool; §7.2 and §7.3 are marked
  fixed with their gates; §2's trap-check row says five.
* [BUILD-NOTES.md](BUILD-NOTES.md) gained #121.
* [HANDOFF.md](HANDOFF.md)'s #118 entry no longer says STILL OPEN — the fix
  and #120's confirmation in `OS7-1.0.0.163-amd64.iso` were already committed
  history (`5e2eb71`), only the handoff had not caught up.
* `CLAUDE.md`'s check table says five traps.
