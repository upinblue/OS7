# Session: the second preview — and two gate failures that were both in the measuring instruments

**2026-09-09, on the x64 Windows host.** Cutting the second preview of `1.0.0`.
[RELEASE-PROCESS.md](RELEASE-PROCESS.md) is the sequence; this file is what one
run of it measured. Everything below was measured on this machine, and where a
harness could not run, that is said in place rather than left for the next
reader to assume.

The release: **1.0.0.203, channel `preview`**. The version fields do not move —
`1.0.0` has been published once (1.0.0.175, 2026-09-03) and this is the second
preview of the same product, so only `BUILD` moves.

**It moved three times, and both reasons are in this file.** 200 was the clean
tree this session started on; the archive-snapshot bump made it 201 (§1.3: the
release is cut from the commit that bumps the pin); #143 made it 202 and #141
made it 203. Each of those two was a defect in a measuring instrument, each was
found by running the gate on the medium about to be published, and each cost a
rebuild of both media rather than a footnote in the release notes. That is the
process working, and it is the reason the number is not 201.

---

## 1. The two decisions, and the one that had a consequence nobody had priced

`OS7_CHANNEL` stays `preview` and `MAJOR.MINOR.PATCH` stays `1.0.0`. What moved
is `OS7_ARCHIVE_SNAPSHOT`, `20260824T000000Z → 20260909T000000Z`, and
`OS7_REPO_URI`, from the pre-publication `file:///usr/lib/os7/repo` to the real
server.

**What the snapshot bump brings in was asked of apt, not assumed.** A clean
`ubuntu:26.04` pointed at the new snapshot, `apt-cache madison`:

| package | 175's pin | 201's pin |
|---|---|---|
| `linux-image-generic` | 7.0.0-30 | **7.0.0-31.31** (updates + security) |
| `zfsutils-linux` | — | 2.4.1-1ubuntu5.1 |
| `sanoid` | 2.3.0-1 | unchanged |
| `fonts-cascadia-code` | 2407.24-3 | unchanged |
| `wine-common` | 10.0~repack-12ubuntu1 | unchanged |

So none of the three components the pin holds by **hash** moved, and their
hashes stand as measured on 2026-08-25. The kernel did move, which is the reason
this release's Secure Boot and TPM evidence has to be taken against its own
medium rather than inherited from 1.0.0.192/194.

The snapshot itself was measured against the live service before it was written
down: `resolute-updates` dated **Tue, 08 Sep 2026 23:19:56 UTC**,
`resolute-security` 21:04:13 UTC, `resolute` still the frozen 23 Apr suite. The
timestamp resolves to an instant, not a rounded day.

---

## 2. §4.2 — the credential, built because a published URI without one is a
## machine that cannot update and does not say why

[RELEASE-PROCESS.md](RELEASE-PROCESS.md) §4.2 named two owed code changes and
said neither existed. Both had to exist for this release, because this is the
first one whose `OS7_REPO_URI` is a real server: the repository is served over
WebDAV from a Storage Box, every transport that box speaks requires
authentication, and a deb822 source has no field for a credential.

### What was built

* **`Set-OS7UpdateChannel -Credential`** writes `/etc/apt/auth.conf.d/os7.conf`
  — empty file, then the mode, then the content, the order Net's
  `Set-NetplanDocument` uses for a pre-shared key. Keyed to the URI's **host**,
  which is what apt matches on. A credential for a `file://` URI is refused
  rather than written. The password reaches the file and nothing else: not the
  returned object, not a stream, not a command line.
* **The credential ships in the medium**, in `os7-release`, injected at build
  time from the operator's `~/.os7/storagebox.conf` through a host path the
  Makefile mounts read-only — the shape `OS7_RELEASE_PUBKEY` already uses, and
  for the same reason: this repository is public. A build whose URI needs
  authentication and was handed no credential **refuses**;
  `OS7_REPO_NO_CREDENTIAL=1` is the opt-out.

### Two measurements that changed what got written

**apt does not care about the mode.** Measured in a clean `ubuntu:26.04`: an
`auth.conf.d` entry at **0644** is read and USED, with no warning, no notice and
nothing in any log — `MaybeAddAuth: … from /etc/apt/auth.conf.d/os7.conf` under
`-o Debug::Acquire::netrc=1`, and silence without it. The comment that was about
to be written said apt would refuse such a file. It would not, and that matters:
nothing downstream would ever report a credential a machine had left readable,
so **0600 is OS/7's own decision and has to be checked by OS/7** — which it now
is, from the filesystem in the cmdlet and from `dpkg-deb -c` in the build.

**A flags enum compared by its text is a bug.** `Write-OS7AptCredential`'s first
version compared `UnixFileMode` against the string `'UserRead, UserWrite'`. In
pwsh 7.6.5 on Linux a 0600 file stringifies as **`'UserWrite, UserRead'`**, so
it refused a file whose mode was exactly right. Found by the check, in the first
run, on my own new code; compared by value now.

### The half that was weaker than the thing it was checking

`Set-OS7UpdateChannel` confirmed its own work with `apt-get -qq update` and the
exit code. **`apt-get update` exits 0 for a source it could not fetch at all** —
§4.1a measured that against this very server, where the first version of
`check-storagebox.py` read that nothing as success with the right credential
*and* with a deliberately wrong one — and `-qq` suppresses the `Get:`/`Err:`
lines that carry the answer. So this verb's own verification passed for every
reachable machine and every unreachable one alike.

It now reads which line apt printed **for this source** and names the outcome:
`fetched`, `unauthorized`, `tls`, `notfound`, `errored`, `unfetched`. Each is a
different sentence, because "refused as it should be" and "never reached it"
send an operator to different places.

### Gated in three places, each proven to fire

* **`check-update-logic.py`** grew "Set-OS7UpdateChannel and the credential apt
  reads" — **15 checks**. Its fake `apt-get` now reproduces the measured trap:
  it prints a 401 `Err:` line **and exits 0**. All four refusals fire; a control
  run in which apt fetches the source shows the same call succeeding, so they
  are not a verb that refuses everything.
* **`check-image.py`** asks the shipped squashfs, conditionally on the medium:
  the credential must be present, keyed to the host apt matches on, mode 600,
  owned by `os7-release`. What makes it conditional was wrong in the first
  version and is §4 of this file — it read the URI's scheme, and it now reads
  the shipped `release.conf`'s own `OS7_REPO_AUTH`, required only while the
  shipped source still points where that file says. A tree building for
  somewhere else is not failed for a credential it was right not to have.
* **`check-storagebox.py`** compares the pin's host against the host it probes.
  The host is now written down twice, and if the two disagree every check below
  it passes against a server no machine will ever contact — while the machine's
  own symptom is a 401, which §4.1a already established says nothing about the
  password.

### What it costs, stated rather than solved

The credential is extractable from any published medium. It is read-only, its
account's directory is its root so it reaches nothing else on the box, and
integrity is GPG's — so what it protects is bandwidth, not content. **RP3 is
still open and is now sharper:** rotation became a fleet operation on the day
the first medium carried one.

---

## 3. The no-VM half of the gate, on this tree

All of §2's no-VM row, run against `45d00f8` before either medium was built.
Green, with the counts each reported:

| | |
|---|---|
| module self-tests | Zfs **75**, Net **68**, Time **33**, Systemd **95**, Directory **54**, OS7 Backup **63**, OS7 Update **31** |
| the traps and the layers | `check-ps-traps.py` — six classes at 0 · `check-layering.py` — five rules, P2-directory at its baseline of 1 · `check-module-parts.py` 23 |
| decision checks | `compat-windows`, `be`, `home`, `service`, `scheduledtask`, `directory`, `secureboot`, `network`, `remotedesktop`, `management`, `installer-cmdlets`, `vm-arch` |
| the two specifications that exist twice | `check-version-rule.py --docker`, `check-netplan-rule.py --docker` — byte for byte |
| against real things | `check-os7-repo.py` (a clean Ubuntu container becomes an OS/7 machine in one apt operation, and refuses the tree with the key swapped) · `check-ssh-login.py` (a real sshd) · `check-ad.py` (a real Samba AD DC, every write read back with `ldbsearch` inside it, and stage 1 re-run with stage 2's tooling moved out of PATH) · `check-image.py --self-test` |
| the Storage Box | `check-storagebox.py --probe` — 4 ok: the pin names the host the check probes, an anonymous `GET /` is 401, the read-only credential answers 200, and `/dists/os7-1.0/InRelease` is 200 |

**One finding worth carrying, found by running them from a script rather than by
hand.** Five of the seven self-tests **return nothing**: `Test-ZfsModule`,
`Test-NetModule`, `Test-TimeModule`, `Test-SystemdModule` and
`Test-DirectoryModule` print their verdict and return `$null`, while
`Test-OS7Backup` and `Test-OS7Update` return a boolean. So
`if (-not (Test-ZfsModule)) { exit 1 }` — the idiom that is correct for the OS7
pair, and the one `check-update-logic.py` uses — reports a **failure for a module
whose own last line says PASS**. CLAUDE.md's documented invocation just calls
them and reads the printed line, so nothing in the repository was wrong; a
caller that trusts the exit code would be. Not fixed here: it is a change to
five modules' contracts on the day of a release, and this file is the record
that it is known.

---

## 4. The gate found a defect, and it was in the gating code — #143

**`run-s5.py all` on the 1.0.0.201 amd64 medium: `install`, `boot` and `cycle`
passed, `update` failed.**

| phase | verdict |
|---|---|
| `install` — unattended, with a TPM | 7 checks ok: `/` is a boot environment on ZFS, `boot=zfs` on the command line, a tpm2 token in the LUKS header, no .NET SDK, no kernel headers, `zfs.ko` survived the package swap |
| `boot` — the disk alone, nothing typed | **the TPM unlocked the disk** |
| `cycle` — clone, change, activate, reboot, roll back | 9/9: the clone is inert (#63), assembled at `/mnt/be`, carries a package the running system does not, the ESP stub and `grubenv` name it, **the machine booted the clone**, `Restore-OS7` chose the right ancestor (#107) and **the rollback took** |
| `update` — `Update-OS7` against a served repository | **FAILED** — and not on the product |

What failed was the credential refusal added that morning:

```
!!! os7-release: OS7_REPO_URI is http://10.0.2.2:8907, which needs a
!!! credential (RELEASE-PROCESS §4.1a: that server answers an
!!! anonymous request with 401), and this build was handed none.
```

**`10.0.2.2:8907` is the harness's own HTTP mirror.** The refusal keyed on the
URI being `http(s)` and read that as "this server requires authentication". One
server was measured requiring it; that was generalised to a scheme. C7 §6.4
makes an unauthenticated static mirror a supported deployment, so the guess was
wrong about a case the repository ships a harness for. [BUILD-NOTES](BUILD-NOTES.md)
**#143**.

The fix puts the fact where the URI is chosen — the pin declares
`OS7_REPO_AUTH="yes"` — and keys the refusal on that **and** on the URI in force
being the pin's own, because a caller that overrode `OS7_REPO_URI` replaced the
server the declaration was about. `check-image.py`'s artefact-side check had the
same defect and now reads the declaration out of the shipped `release.conf`,
requiring it only while the shipped source still points where that file says.

**Why nothing caught it earlier is the part worth keeping.** Three checks were
written for §4.2 that morning — the cmdlet, the artefact, the two-places-one-host
consistency. None covered the builder's refusal, the one piece of new logic whose
whole job is to fail. `check-os7-repo.py` does exercise the builder, but it hands
an overridden URI in, so it walked the not-firing branch and never visited the
other one. It now visits both, four builds of `os7-release` alone:

```
ok    the pin declares its server needs a credential — the premise of all this
ok    no credential for the pin's own URI is REFUSED
ok    an OVERRIDDEN URI builds without one — a scheme is not a server
ok    and ships no credential, since none was given for that server
ok    OS7_REPO_NO_CREDENTIAL=1 is the deliberate way past it
ok    and it ships no credential either
ok    a credential handed in ships at 0600, asked of the .deb   -rw-------
ok    and the build never printed the password
```

**And that check failed the first time it ran, for a reason of its own**:
`os7-release` refuses to be built without a trust anchor (§6.3), and that
refusal comes *before* the credential logic — so all four cases failed on the
anchor rather than on what they were asking about. The anchor is handed in from
the repository the same run already built. A check that cannot reach the code it
is about reports on nothing, and it reports it as a failure, which is the more
dangerous of the two ways to be wrong.

**The consequence for the release: the version moved.** A fix is a commit and
`BUILD` is the commit count, so the media are rebuilt and the release is
**1.0.0.202**. The alternative — publish 201 and land the fix afterwards — was
rejected deliberately: the tag would then name a tree whose own `run-s5.py all`
cannot run, and a release nobody can reproduce from its tag is the thing this
process exists to prevent.

---

## 5. The gate failed a second time, in the harness — #141 again

**`run-s5.py all` on the 1.0.0.202 medium: `install` PASS, `boot` PASS,
`cycle` PASS, `update` and `timer` FAILED.** Same pattern as §4: the product was
right and the instrument was stale.

```
ok    2/8 Set-OS7UpdateChannel took http://10.0.2.2:8907, and apt verified it
FAIL  3/8 Update-OS7 did not apply the release:
      no release index for channel 'development' at http://10.0.2.2:8907.
```

Check 2 is worth reading first, because it is the one §4.2 was built for: the
**new, strict read-back** — the one that parses which line apt printed for this
source instead of trusting `apt-get -qq update`'s exit code — passed on a real
machine, against real apt, against a real repository, on a server with **no**
credential. Both halves of the new logic therefore hold on a machine: the
credential path in the image, and the no-credential path #143 had wrongly
forbidden.

Check 3 failed because `run-s5.py` built its test repository with no
`OS7_CHANNEL` and so inherited the pin's — `preview` since 2026-09-02 — while
pointing the machine at `-Channel development` on a hard-coded line three
hundred lines away. The index went to `index/preview.json`, the machine asked
for `index/development.json`, and the `timer` phase then failed the same way,
reporting exit 1 where it asserts 2. **Four red checks, one stale word.** The
phase had not run since 2026-08-28, four days before the pin changed.

That is [BUILD-NOTES](BUILD-NOTES.md) **#141** in a second place, and #141 was
written the same morning about `check-os7-repo.py`. The fix is a named
`UPDATE_CHANNEL` at the top of the file, read by the repository build and by
both places that point the machine. Two harnesses here build the real
repository and both now name the channel; `check-update-logic.py` authors its
own index and controls it already — so the class is closed, not the instance.

**And the version moved again**: 1.0.0.202 → **1.0.0.203**, both media rebuilt
from one commit. Two rebuilds for two defects in one afternoon, both of them in
the parts of this repository that exist to catch defects, and both found by the
only thing that could find them — running the gate on the medium that was about
to be published.

---

## 6. What 1.0.0.203 was measured against

Both media from `42156cf6bda2`, clean tree, `reproducible: true`.

| | |
|---|---|
| `OS7-1.0.0.203-amd64.iso` | 3 344 904 192 B |
| `OS7-1.0.0.203-arm64.iso` | 1 848 668 160 B |

### amd64 — on this host, with KVM

* **`check-image.py amd64` — 141 ok, 0 failed** (1.0.0.175's number was 121).
  Includes the whole Secure Boot chain read out of the shipped medium:
  `BOOTX64.EFI` is Microsoft-signed shim, **byte-identical to the shim the image
  itself ships** (`4c89145e958cf592` on both sides), Canonical's `grubx64.efi`
  beside it, the same loader in the ISO9660 tree and in the El Torito FAT image,
  and a Canonical-signed kernel. Plus the four new credential checks: shipped,
  keyed to the host apt matches on, **mode 600**, owned by `os7-release`.
* **`run-s5.py all` — all five phases PASS, 28 checks, 0 failed.** Installed
  unattended with a TPM; **booted from the disk alone with nothing typed**;
  cloned, changed, activated, rebooted into the clone and rolled back; then took
  a served release **1.0.0.203 → 1.0.0.204**, ran its firstboot migration,
  reported the new version from `Get-OS7Version`, kept the previous environment
  under `-Keep 2` and **rolled the update back**; and the unattended timer
  honoured its exit-code contract — 0 with no channel, 2 staged, 2 again without
  minting a second environment.
* **`run-secureboot.py all` — 35 ok, GREEN**, all four phases: the medium booted
  **through its own signed bootloader** under Microsoft-keyed OVMF (`-cdrom`, no
  `-kernel`), a machine was installed from that verified medium, the disk came up
  with **no medium attached and Secure Boot on and unlocked itself from the
  TPM**, and the control phase — the same disk under non-enforcing firmware —
  required the passphrase back.
* **`run-phase3.py install` — PASS.** All eighteen Setup steps, both pools
  exported.
* **`run-phase3.py walk`** — see §7; its first run died on an encoding fault in
  its own success message (#146), not on the install.

### arm64 — the artefact, and only the artefact

* **`check-image.py arm64` — 114 ok, 0 failed.** The signed chain is on this
  medium too: `shimaa64.efi.signed.latest` (987 440 B) and `gcdaa64`
  (2 533 256 B), lifted out of the squashfs the build had just written.
* **Never booted.** No aarch64 host with hardware virtualisation is in this
  release loop, so `run-secureboot.py all`, `run-s5.py all` and `run-phase3.py`
  have not run on arm64 for this build or any other. That is the bar
  RELEASE-PROCESS §2 describes and it is what the download page has to say.

### The no-VM half

Green on `45d00f8` (§3) and unchanged by the two fixes since, except
`check-os7-repo.py`, which grew the eight-check refusal section and is green
with it.
