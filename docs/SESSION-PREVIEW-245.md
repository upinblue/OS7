# Session: the third preview — and every defect it found was in an instrument

**2026-09-21, on the x64 Windows host.** Cutting the third preview of `1.0.0`.
[RELEASE-PROCESS.md](RELEASE-PROCESS.md) is the sequence; this file is what one
run of it measured. Everything below was measured on this machine, and where a
harness could not run, that is said in place rather than left for the next
reader to assume.

The release: **1.0.0.245, channel `preview`**, from `93fd496`, clean tree,
`reproducible: true`. The version fields do not move; `BUILD` moved three times
and each of the two extra moves is a defect in this file.

**Four defects were found in this run and NOT ONE of them was in the product.**
Two were in measuring instruments, one was in the release process's own notion
of a clean tree, and one was a subsystem fixing its own bug underneath a reader
that had trusted the bug. That is the third consecutive release whose cost was
paid by the instruments (#141 and #143 did it to 1.0.0.203), and it is the
argument for running the §2 gate *before* cutting media rather than after —
which the handoff already said and which this run finally did.

---

## 1. The two decisions, and why MINOR did not move

`OS7_CHANNEL` stays `preview`. `MAJOR.MINOR.PATCH` stays `1.0.0`, and that one
took an argument rather than inertia.

What has landed since 1.0.0.203 is unmistakably feature work: two GUI
applications (Software Update, Versions), the automation host's phase 1, the
previous-versions reader, the storage-pressure rule, the privilege guards
(#148/#149) and `run-firstrun.py`. §1.1 says MINOR moves for "an OS/7 feature
release on the same base", which reads like 1.1.0.

It is not, for a reason the same table states two columns further along: **a
MINOR bump changes the apt suite**, `os7-1.0` becomes `os7-1.1`, and §7.2 says
in as many words that this path has never run on a machine because no 1.1 has
ever existed. A release whose purpose is to be stable is the wrong place to
debut an untested update path across every machine already on 1.0.0.203. The
deeper reason is that MINOR is for a feature release on a RELEASED base, and
1.0.0 has been previewed twice and released never — the whole 1.0.0 line *is*
the preview train.

### 1.1 The snapshot, asked of every package the medium holds

`OS7_ARCHIVE_SNAPSHOT` moves `20260909T000000Z → 20260921T000000Z`.

The previous two bumps recorded what they brought in by naming a handful of
packages and asking apt about those. That method can only confirm what the
author already suspected, so this one asked about **all 1 515 names in
`OS7-1.0.0.233-amd64.packages.manifest`**, in a clean container pointed at each
snapshot in turn.

**50 of 1 515 moved.** None is the kernel (`linux-image-generic 7.0.0-31.31`),
ZFS (`2.4.1-1ubuntu5.1`), `shim-signed`, `grub-efi-amd64-signed`, `systemd`,
`cryptsetup`, `openssl`, `sudo`, `sanoid` or `fonts-cascadia-code` — each
measured explicitly and each unchanged, so the boot chain this release's Secure
Boot and TPM evidence is taken against is 1.0.0.203's boot chain.

Four of the fifty are things this repository has its own checks about, and
writing them into the pin is what made the netplan failure in §5 legible in
thirty seconds instead of an afternoon:

| | | |
|---|---|---|
| `polkitd`, `pkexec`, `libpolkit-*` | `127-2ubuntu1` → `127-2ubuntu1.1` | The Software Update window asks polkit by name before systemd runs `Update-OS7`; `os7-automation` ships a rule of its own |
| `netplan.io`, `libnetplan1`, `netplan-generator`, `python3-netplan` | `1.2-1ubuntu5` → `1.2-1ubuntu5.1` | The target of the two-language renderer `check-netplan-rule.py` holds byte for byte |
| `libmutter-18-0`, `mutter-common` | `50.1-0ubuntu2.2` → `50.1-0ubuntu2.4` | What draws the themed title bar the GUI applications appear in |
| `perl`, `perl-base`, `libperl5.40` | `5.40.1-7ubuntu0.2` → `5.40.1-7ubuntu0.3` | sanoid and syncoid are Perl |

The rest is pipewire and its spa modules, libheif and libaom, libinput,
malcontent, sqlite3, python3-cryptography, thermald, libbluetooth3 and
wireless-regdb — a desktop's ordinary twelve days.

### 1.2 pwsh 7.6.6 exists and is deliberately not taken

Measured against GitHub rather than remembered: `v7.6.6`, published
**2026-09-08T20:28:01Z** — one day before 1.0.0.203 shipped 7.6.5, so that
release was already one patch behind and nothing said so.

Held at 7.6.5 for this preview on purpose. The whole product *is* PowerShell, so
the runtime is the single largest variable a release can be given; and
`check-compat-windows.py` drives its 214 checks against parameter sets
**recorded from a real Windows pwsh 7.6.5** — "the pinned version, so a
difference is a platform one". Moving the pin without re-recording those
fixtures would leave that check comparing against a version the product no
longer ships, which is the premise of the check rather than a detail of it. So
the bump is two hashes AND a re-recording, and it belongs to its own session.

Written into the pin rather than left silent, because §3.4 says a Microsoft
component moving upstream is a release event.

---

## 2. #166 — a fixture's package list was written by hand, and a Depends added
## three weeks later walked past it

`check-os7-repo.py` — a §2 gate row — failed four assertions:

```
os7-server:amd64=1.0.0.243 Depends os7-automation (= 1.0.0.243)
but none of the choices are installable: [no choices]
```

The package was in the tree. The dev-channel half of the same run had built
`os7-automation_1.0.0.242_all.deb` and installed `os7-server` from it
successfully, twenty lines earlier.

The stable/hotfix repositories are built from a SUBSET (`OS7_REPO_PACKAGES`),
because the full set costs the NativeAOT compile that is the expensive half of
that harness — and the subset was eight names typed into the source on
2026-08-28. On 2026-09-14 `os7-automation` became a `Depends` of `os7-server`.
The list did not move. **The check had been red for a week**, because it is a
four-minute check rather than one of the seconds-long ones, and nobody had run
it.

**The assertion half had the same defect and it is the more interesting one.**
The report's list of packages required to be installed was also typed out, and
also lacked `os7-automation` — so the one package whose absence broke the hotfix
phase was also the one package that, in the phase where it WORKED, nothing
claimed had arrived. Two hand-written lists, one omission, and the check could
neither prove the good case nor explain the bad one.

Both are derived now, and **from `check-module-parts.py`'s parser rather than a
second one**: that file already reads every metapackage's `Depends` out of
`control.in`, because #156 made it hold hook 0022's list against them, and a
`Depends:` line wraps onto continuation lines — exactly the detail a second
parser gets subtly wrong. The import shape is the one
`check-automation-kerberos.py` already uses for `check-ad.py`.

`os7-desktop` left the fixture in the same change: nothing installs it there,
its members are the compiles the subset exists to avoid, and keeping it made it
an uninstallable metapackage in a repository — which proves nothing and is what
made the failure read as a repository defect rather than a harness one.

**And one transient.** On the first re-run, `base-files reinstalls cleanly over
the divert` failed and passed on the runs either side of it. That step FETCHES,
and the check recorded only the exit code — so it could not tell a broken
divert from a 503. The log is recorded now and appears in the message; the next
red will say which it was.

---

## 3. #145, closed, and its read-back

`OS7_CHANNEL` was the fourth value `build-os7-packages.sh` silently takes from
the pin while only three were captured, so one `docker run -e
OS7_CHANNEL=development` produced a package declaring `preview` inside an index
called `development`. Found on 2026-09-09, left as a one-line fix nobody made,
named in the handoff as owed.

It is on the list now. The second half the handoff asked for was "print the two
channels together"; what was built instead is a **read-back**:
`build-os7-repo.sh` opens the `os7-release` .deb it has just built, reads the
channel out of its `release.json`, and refuses if that differs from the index it
is about to write. Proved by the check's own run, which overrides the channel:

```
channel: index and os7-release both say 'development'
```

---

## 4. #165 — `git status` called a tree dirty in which nothing differed

Six files reported modified whose bytes were identical to HEAD, proved three
ways on the same tree:

```
git hash-object <file>  ==  git ls-files -s <file>  ==  git rev-parse HEAD:<file>
git diff                ->  nothing, exit 0
git update-index --really-refresh  ->  "<file>: needs update", and it stays
```

`scripts/os7-source-facts.sh` asked `git status --porcelain` for
`OS7_GIT_DIRTY`, `build.sh` turns that into `"reproducible": false`, and §1.3
says a dirty tree is not a release. **A release would have been refused — or cut
while disclaiming its own provenance — over a tree in which nothing differed.**
The field claims something about CONTENT and was answered by a stat comparison.

Fixed by asking the question the manifest makes a claim about: `git diff --quiet
HEAD` for tracked bytes, and `git ls-files --others --exclude-standard` beside
it, because an untracked file under `build/config/hooks` is copied into the
image by live-build and changes the product while `git diff` says nothing.

Proved in a scratch clone, five directions: a clean tree `false`; a file whose
mtime moved and whose bytes did not `false`; a tracked file one byte longer
`true`; an uncommitted hook under `build/config/hooks` `true`; removing it
`false`.

**What is NOT established is the mechanism.** A bare `touch` does not reproduce
it in a fresh clone, where git resolves it by content on its own. What could not
be manufactured is the index state in which git keeps its opinion. The fix does
not depend on knowing why — it stops asking the question that had the wrong
answer.

---

## 5. The trust anchor, and a key that says NOT FOR RELEASE

Establishing which `make` invocation produces a release medium was done by
**opening the published one**, not by reasoning from the command believed to
have built it. `OS7-1.0.0.203-amd64.iso`, the squashfs read out of the ISO with
`bsdtar` and `unsquashfs`:

```
=== the anchor, 512 bytes ===
17C460671FF8A8DC2FD8AFA64A0EDD17EF8591AC
    OS/7 DEVELOPMENT signing key — NOT FOR RELEASE <os7-dev@localhost>
E39B31279A2540F17CC9B961B62CBF99B3F5FAF9
    OS/7 release signing key <release@os7.org>
```

So every machine installed from the second published preview trusts a
passphrase-less key that lives in `out/os7-gnupg` on one build host. Three
documents state the rule that bears on this — CURATION C7a, RELEASE-PROCESS §5,
HANDOFF — and all three say the same thing: nothing **signed** by that key may
be published. **None of them says the key is SHIPPED.** Those are different
claims, and only the second decides what a machine will accept.

`check-image.py` could not see it. The only assertion about the anchor was

```python
check(int(img.get("os7.keyring") or 0) > 100, "the trust anchor ships")
```

and a medium whose anchor holds nothing but a development key passes that. One
does: `OS7-1.0.0.233-amd64.iso`, the bench medium the Versions feature was
proven from, declares itself `preview` and carries 269 bytes, one key, the
development one.

**The rule is read off the UIDs and not off a fingerprint.** A key id would have
to be written down somewhere and release plan §3.1 says the pin is the only
place a value may live. So: a medium calling itself anything other than
`development` must trust at least one key whose UID does not say NOT FOR
RELEASE. Everything else in the anchor is printed, on every run, by fingerprint
and UID — so the question of whether to keep shipping the development key is
decided against a reading rather than against a memory. This run does not answer
it; it makes it visible.

Proven in both directions on artefacts rather than fixtures:

| medium | channel | anchor | |
|---|---|---|---|
| `OS7-1.0.0.233-amd64.iso` | preview | 269 bytes, 1 key, development only | **FAIL** |
| `OS7-1.0.0.203-amd64.iso` | preview | 512 bytes, 2 keys, release key present | **ok** |

**And the release key's secret half is not on this host.**
`~/.os7/gnupg-release` holds an empty `pubring.kbx` and nothing else; only the
public half is present, as `os7-release-key.pub`. That is §6 working as designed
— the key is not reachable unattended by a build script — and it means an ISO
can be built here and the repository cannot be signed here.

---

## 6. #167 — netplan stopped exiting 0 for a failure

`check-image.py amd64` on `OS7-1.0.0.244-amd64.iso` — the first medium this
product built against the new snapshot — had **exactly one** failure:

```
FAIL  the Net module's netplan renderer behaves as designed
      Net self-test: 82 passed, 1 failed
FAILED: the configured side ran to the end
      netplan get --root-dir /tmp/os7-netplan-bare-16 network.renderer
      exited 1: Command failed: Unexpected YAML structure found
```

The measurement, one container per snapshot and with the two streams kept apart:

```
netplan get --root-dir <a root with no netplan document> network.renderer

                 rc   stdout   stderr
1.2-1ubuntu5      0   empty    Command failed: Unexpected YAML structure found
1.2-1ubuntu5.1    1   empty    the same 48 bytes
(a real document: rc=0, stdout `networkd`, on both)
```

**netplan 1.2-1ubuntu5 printed a failure and exited 0** — the shape this
repository has a standing rule about — and 1ubuntu5.1 corrected it.
`Get-NetplanValue` throws on any non-zero exit, so `Get-NetplanConfiguration`
stopped answering at all for a root with no netplan document. That is a
legitimate state and not an error: L23's "no network" and "nobody has configured
one" are different answers, and `RendererIsDefault` exists to keep them apart. A
machine with a real document is unaffected, which is why only the self-test's
empty case saw it.

### 6.1 Three things went wrong in the fixing

**One — I claimed a defect that does not exist.** The first version of the fix's
comment said that on 1ubuntu5 the error MESSAGE came back as the value, so every
1.0.0.203 machine had been reporting a `Renderer` of "Command failed: …" with
nothing noticing. That was inferred from a measurement taken with `2>&1`, which
collapses the streams. The message is on **stderr** and stdout is empty on both
versions, so `Get-NetplanScalarValue`'s `$lines.Count -eq 0` path already
answered `$null` — correctly, and entirely because of which stream netplan
chose. Read off the shipped product rather than argued about: `git archive
v1.0.0.203-preview` into a container with 1ubuntu5 answers `Renderer = []`,
`RendererIsDefault = True`, `Interfaces = 0`.

**Two — a harness reported success for a downgrade that never happened.** The
first attempt to check the fix against both versions ran `apt-get install
--allow-downgrades netplan.io=<old>` and then PRINTED the version it found. apt
declined; both runs were 1ubuntu5.1; the run came back green for a fix that
covered one of the two cases. The harness now requires `dpkg-query` to report
the version asked for and dies otherwise — and the two versions are measured in
two containers, because apt would not perform that downgrade in a tree that
already held the newer `libnetplan1`.

**Three — the principled placement was the wrong one, and a harness said so.**
The guard first went in front of `Invoke-NetCommand`: one rule, no dependence on
an exit code. It is unnecessary there, because the rc=0 path was already right;
and it reads the FILESYSTEM before netplan is asked, which bypasses this
module's own test double. `check-network-logic.py` fakes `Invoke-NetCommand` and
answers `netplan get` out of a case table with no files anywhere, so the
front-placed version short-circuited every case to `null` and took **seven** of
its decisions down with it. **A rule that cannot be exercised by the harness
that checks the layer is not a better rule.**

### 6.2 The fix

In the failure branch: ask the FILESYSTEM whether any document exists under that
root, and if none does, return netplan's own absent-key answer. Never match
netplan's wording — that is a third version of this bug waiting for the next
release to reword it. `Get-NetplanDocumentPath` is one definition of "the
documents netplan would merge", shared with `Get-NetplanConfiguration`, because
two lists of three directories is #66 in miniature.

The self-test's empty case gains the assertion that was missing — the renderer
must be `$null`, unknown rather than invented — and its comment and
`Get-NetplanConfiguration`'s docstring both claimed netplan answers
`NetworkManager` for an empty `/etc/netplan`. That was measured once, long ago,
and is true of neither version this product has shipped.

Verified at **86 checks, 0 failed against each netplan version**, installed
fresh in its own container, with dpkg required to agree about which one.

---

## 7. The media

Both from `93fd496`, `OS7_GIT_DIRTY=false`, `reproducible: true`.

| | | |
|---|---|---|
| `OS7-1.0.0.245-amd64.iso` | 3 335 172 096 bytes | native, ~26 min |
| `OS7-1.0.0.245-arm64.iso` | 1 833 480 192 bytes | emulated, ~1 h 35 m |

`1.0.0.244` was built and discarded — §1.3 working as written rather than a cost
it failed to anticipate.

The arm64 build is chained behind amd64 rather than run beside it, and the
chaining script asks two things rather than assuming them: the amd64 **medium**
must exist (not merely `make` exiting 0), and `docker run --platform linux/arm64
ubuntu:26.04 uname -m` must answer `aarch64` immediately before the build, which
is §7.1's registration that does not survive a Docker Desktop restart and whose
failure does not name itself.

### 7.1 check-image.py

**amd64: 158 ok, 0 failed, exit 0.**

```
ok  the Net module's netplan renderer behaves as designed — Net self-test: 86 passed, 0 failed
ok  anchor key B62CBF99B3F5FAF9 — OS/7 release signing key <release@os7.org>
ok  a `preview` medium trusts at least one non-development key

The image is OS/7 1.0.0.245 (preview), amd64, built 2026-09-21T13:18:52Z
from archive snapshot 20260921T000000Z, and every source in it says so.
```

**arm64: 126 ok, 0 failed, exit 0** — and this is arm64's whole evidence, as
§2 says it is. 126 against amd64's 158 because arm64 is server-only: the desktop
rows do not apply to it.

```
ok  the Net module's netplan renderer behaves as designed — Net self-test: 86 passed, 0 failed
ok  anchor key B62CBF99B3F5FAF9 — OS/7 release signing key <release@os7.org>
ok  a `preview` medium trusts at least one non-development key

The image is OS/7 1.0.0.245 (preview), arm64, built 2026-09-21T13:48:02Z
from archive snapshot 20260921T000000Z, and every source in it says so.
```

So #167's fix is proven on the arm64 artefact too, out of its own squashfs,
rather than assumed to travel with the source.

---

## 8. The machine gate

All of it on amd64, on this host. arm64's evidence stops at §7.1 and there is no
aarch64 host with hardware virtualisation in the release loop.

### 8.1 `run-s5.py all` — 108 ok, five phases, all PASS

```
install  PASS   unattended, with a TPM attached
boot     PASS   the disk ALONE, and nothing typed at the passphrase prompt
cycle    PASS   clone -> change -> activate -> reboot -> roll back
update   PASS   Update-OS7 against a served repository, 1.0.0.245 -> 1.0.0.246,
                firstboot migrations, and back by recorded ancestry
timer    PASS   the unattended check's exit-code contract
```

This is the gate the update train has to pass, and it passed first try on a
fully packaged medium — install, TPM unlock with nothing typed, the clone cycle,
a real N -> N+1 update against a signed repository the harness serves, and the
timer. The `update` phase is also what exercises the four firstboot migrations
`os7-release` now ships, **including `71-domain-homes-in-backup-policy`, which
had never run from a medium** before this release: VERSIONS-PLAN VL7 landed on
2026-09-15 and its session document says in as many words that no ISO carried
any of it.

### 8.2 `run-firstrun.py --bench s5` — 13 ok, 0 failed

The documented first run, typed by the account the installer created, on the
bench §8.1 left behind. Every other row in the gate runs as root; this one does
not, which is why #148 reached an operator an hour after 1.0.0.203 had passed
141 artefact checks per architecture.

```
ok  Get-OS7Version                                       must work
ok  Get-OS7Version | Format-List *                       must work
ok  Get-OS7BootEnvironment                               must work
ok  Test-OS7Network                                      must work
ok  Get-OS7ManagementStatus                              must work
ok  Get-Module -ListAvailable OS7,Zfs,Net,Time,Systemd   must work
ok  Get-Command -Module OS7 -Noun OS7BootEnvironment     must work
ok  Update-OS7                                           must refuse, actionably
ok  Restore-OS7                                          must refuse, actionably
```

`Test-OS7Network` passing here is worth noting beside §6: it is the OS/7 layer
over the Net module on a machine that has a netplan document, which is the case
netplan's change did not touch — and the first-run harness quotes it from
`docs/manual/en/` and refuses to start if the manual no longer says it.

### 8.3 `run-phase3.py install` — PASS, and `walk` — PASS, 25 ok

```
OS7-SETUP-DONE install
ok  Setup reported a finished install
ok  the installer exported both pools
install   PASS
```

**`walk` crashed the first time and it was #146, which this repository had
already numbered and already told me how to avoid.** The run reached its last
assertion — the install had succeeded, the screenshots show the bootloader being
written — and then died printing the `→` in

```
ok  the copy bar advanced while copying (… % → … %, N samples)
```

with `UnicodeEncodeError: 'charmap' codec can't encode character '→'`,
because stdout was redirected to a file and Python then takes the locale
encoding, which is cp1252 on this host. #146's entry says the fix is
`PYTHONUTF8=1` **in the invocation**, that it belongs there rather than in the
harnesses because the arrow is correct output and the codepage is what is wrong
about it, and — in as many words — that *every* `installer/testing/*.py` run
with redirected output on this host needs it. My invocation did not have it.

Worth writing down rather than quietly re-running, because #146's own entry
says what this looks like: "a `Traceback` in the last line of a two-phase VM
harness reads as 'the walk failed', and the walk had not failed — it had passed
and could not say so."

Re-run with `PYTHONUTF8=1`: **PASS, 25 ok**, screens 1–7 to Complete by
keypress, and the Complete screen naming the version on the medium
(`1.0.0.245`), the disk, the encryption, the computer name, the account and the
desktop mode that was chosen.

### 8.4 `run-secureboot.py all` — 32 ok, 0 failed, GREEN

On `OS7-1.0.0.245-amd64.iso`, and it is the only harness here that boots the
MEDIUM through its own bootloader — `-cdrom`, no `-kernel`, the firmware finding
shim by itself (#134).

```
medium    booted through its own signed bootloader, then asked
install   unattended, from a medium the firmware verified
disk      the installed machine, Secure Boot on, no medium — TPM unsealed
policy    Secure Boot OFF again: the passphrase MUST come back, and did
```

The `policy` phase is the control that makes the other three mean something:
under non-enforcing firmware the same disk asks for the passphrase and still
takes it, and the phase requires the firmware to admit what it is — *"This
system doesn't support Secure Boot"*.

---

## 9. The repository

The published index was **read** rather than inferred, because two sources
disagreed about it and neither was the server: HANDOFF said the Storage Box
carries 1.0.0.175 and 1.0.0.203 with a supersedes chain, and
`out/os7-repo.local-only-203/index/preview.json` holds one entry with
`supersedes: null`.

```
=== index/preview.json  HTTP 200 ===
   channel: preview   entries: 4
   - 1.0.0.203    arm64  supersedes 1.0.0.175
   - 1.0.0.203    amd64  supersedes 1.0.0.175
   - 1.0.0.175    arm64  supersedes None
   - 1.0.0.175    amd64  supersedes None

=== index/stable.json  HTTP 404 ===
```

HANDOFF was right; the local tree is what its name says it is. So §5 must
accumulate into a tree that already holds those four, and the tree has to be
fetched before it is cut into — `build-os7-repo.sh` regenerates every `binary-*`
index FROM THE POOL, so a pool missing an older release's `.debs` would produce
indices that no longer list it.

**The published pool, taken from the published `Packages` indices rather than a
WebDAV PROPFIND** (the read-only sub-account answers GET only): **24 files,
234 268 104 bytes / 223.4 MiB**, dominated by four `os7-powershell` .debs at
~57 MB each. `os7-automation`, `os7-app-softwareupdate` and `os7-app-versions`
are not in it — this release is the first to carry them into the repository.

### 9.1 The cut

`make repo-amd64` then `make repo-arm64`, both into the fetched tree, which is
§5's merge: every `binary-*` index is regenerated from the shared pool, the
`Release` names the union, each descriptor lands under
`releases/<version>/<arch>/`, and the index holds one entry per (version,
architecture). The builder's own lines:

```
amd64:  channel: index and os7-release both say 'preview'
        Packages: 33 in the index, 13 built this run
        descriptor: releases/1.0.0.245/amd64/release.json  sha256 834c07e77f57966d…
arm64:  os7-app-softwareupdate: SKIPPED on arm64 — arm64 is server-only
        Packages: 31 in the index, 10 built this run
        descriptor: releases/1.0.0.245/arm64/release.json  sha256 8dc0c5774bd9b9bf…
```

The `channel:` line is #145's read-back doing its job on a real release cut
rather than on a harness: the index being written and the `os7-release` package
just built are required to declare the same maturity.

**`make repo-arm64` failed once and it was not the cut.** `make` reported
`/scripts/os7-source-facts.sh: No such file or directory` and then
`mkdir: Permission denied` on `/out/os7-repo` — `$(CURDIR)` had come out EMPTY,
so `OUT := $(CURDIR)/out` was `/out`. The amd64 half had completed normally
seconds earlier and the same `cd` worked immediately afterwards, so this was the
`/mnt/c` mount dropping out from under one `make` invocation rather than
anything about the repository. Re-run alone, it produced its half first try.
Worth a line because the message names a missing script and a permission
problem, and the cause is neither.

### 9.2 The cut, asked what it is

Read off the tree rather than off the builder's log, inside `os7-build` with the
tree mounted read-only — **0 problems**:

* the index is the `preview` channel with **six entries**, 1.0.0.175 / .203 /
  .245 × two architectures, and 1.0.0.245 records `supersedes: 1.0.0.203`;
* all six descriptors exist at the path their index entry names, each with the
  `manifest_sha256` that entry records;
* `binary-amd64/Packages` lists 33 and `binary-arm64/Packages` 31, and **every
  one of the 39 distinct files they name is in the pool at the recorded size
  and sha256** — which is the property that matters, because the indices are
  regenerated from the pool and a published release dropping out of them is how
  a machine on 1.0.0.175 stops finding its own version;
* `os7-base`, `os7-powershell`, `os7-setup` and `os7-module` are still listed at
  **both** 1.0.0.175 and 1.0.0.203, asserted by name;
* the anchor holds two keys, one of which is not a development key.

### 9.3 What step 6 has to replace, exactly

All three signatures in the tree are the DEVELOPMENT key's, because the release
key's secret half is not on this host — §6 as designed. Verified rather than
assumed, and each names its signer:

```
dists/os7-1.0/Release.gpg    OS/7 DEVELOPMENT signing key — NOT FOR RELEASE
dists/os7-1.0/InRelease      OS/7 DEVELOPMENT signing key — NOT FOR RELEASE
index/preview.json.asc       OS/7 DEVELOPMENT signing key — NOT FOR RELEASE
```

`dists/os7-1.0/Release` and `index/preview.json` are the two files to sign; the
three above are the outputs to replace. Nothing signed by that key may be
published (RELEASE-PROCESS §5), so this tree is not publishable as it stands and
is not published.

---

## 10. What this run does NOT say

* **Nothing is published.** Steps 6 to 10 are not done: the release key's secret
  half is not on this host, which is §6 as designed, so signing and publishing
  are the operator's.
* **arm64 has no boot gate**, as always. Its evidence is `check-image.py` on the
  artefact and nothing else, and that has to be stated on the download page and
  in the release notes (§2).
* **#144 is not fixed.** The amd64 medium's four Microsoft packages — Edge, the
  Intune portal, the identity broker and `code` — still come from
  `packages.microsoft.com` unpinned, so two media from this one pin need not
  hold the same package set. Carried deliberately: pinning them turns every
  upstream Edge release into a release event, which is RP4 and unmade.
* **UL6 is not satisfied.** No `archive/<version>/<arch>/*.deb` exists for any
  release and no tool builds one, so the reproducibility claim still rests on
  `snapshot.ubuntu.com` having no published retention guarantee.
* **`Test-HardwareModule` and `check-device-logic.py` cannot run on this host at
  all**, and nothing said so until 2026-09-15: a PCI address is `0000:00:00.0`
  and Windows permits no colon in a path, so the sysfs tree they build cannot be
  created. That is a fact about the host, not the code. The Hardware module's
  readers ARE exercised — inside the image, by `check-image.py`, which got
  `Hardware self-test: 52 passed, 0 failed` on this medium.
* **The Software Update window has still never performed an update**, because
  every release it can reach is development-signed.
* **The development key in the trust anchor is visible now and not decided.**
  §5 makes it a reading on every medium; whether a release medium should ship it
  at all is open.
