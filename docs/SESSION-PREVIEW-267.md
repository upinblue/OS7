# Session: the fifth preview — the Containers window ships, and the publication runs in §3's order

**2026-10-30 to 2026-10-31, x64 Windows host.** OS/7 1.0.0.267 is published: both
media from `b8a904b`, signed by the release key, on the download server and in
the repository, the tag `v1.0.0.267-preview` and the GitHub pre-release
[OS/7 1.0.0.267 — fourth preview](https://github.com/upinblue/OS7/releases/tag/v1.0.0.267-preview).
It is the first release that carries the Containers window
([SESSION-CONTAINERS-WINDOW.md](SESSION-CONTAINERS-WINDOW.md)). Nothing in the
product changed during the release; this document is the release itself.

(The GitHub title says *fourth preview* because it counts published ones — 175,
203, 264, 267. 1.0.0.245 was gated and never published; SESSION-PREVIEW-264's
title counts it, which is why that one says *fourth* too.)

## 1. The decisions

| | |
|---|---|
| version | `1.0.0.267`, `BUILD` = `git rev-list --count b8a904b` |
| channel | `preview` |
| commit | `b8a904b` — the Containers commit; the pin is unchanged since 1.0.0.264 |
| archive snapshot | `20261029T000000Z`, unchanged |
| supersedes | `1.0.0.264` |

No pin commit was needed: version and channel come from the count and the pin,
and neither the snapshot nor a Microsoft component moved.

## 2. The media, and two builds that did not count

Both media from `b8a904b`, clean tree, `reproducible: true` in both descriptors.

| medium | bytes | sha256 |
|---|---|---|
| `OS7-1.0.0.267-amd64.iso` | 3 412 471 808 | `1e7a9e7cfd7a0a6f3bec831d5fd04d1f66028515d0374b1c4b39c8d2c04c838f` |
| `OS7-1.0.0.267-arm64.iso` | 1 846 882 304 | `46a0b2a5c191904c073d194428805fa187c4a8d9df1d1d05a33a100a18c798c2` |

Both sizes equal 1.0.0.264's to the byte, because the ISOs are padded. The hashes
differ.

arm64 under emulation in 96 minutes, amd64 natively in 27, started the moment
arm64 had passed its package stage, five minutes in. Two earlier arm64 starts did not
produce a medium:

* **The first died of my own concurrency**: `NETSDK1047, project.assets.json
  has no target for linux-arm64`. The no-VM gate was running beside it, and
  three of its checks (`check-installer-cmdlets.py`, `check-version-rule.py`,
  `check-netplan-rule.py`) restore `installer/src/OS7.Setup` for their C# half,
  into the same `obj/` the build was publishing from. One RID's restore
  replaced the other's assets file mid-build.
* **The second was started without `OS7_RELEASE_PUBKEY`** and stopped while it
  ran. A medium built that way has a trust anchor with the development key
  alone, and a machine installed from it can never take a release-signed
  update. The Makefile says so at length; the bare `make build-arm64` in
  RELEASE-PROCESS §3 step 1 did not, and that is what was copied.

Both are now in RELEASE-PROCESS §3 steps 1–2. The build that counted ran from a
script that refuses a HEAD other than `b8a904b`, a dirty tree or a missing
public key, checks that emulated arm64 answers `aarch64` (#140), and passes both
host paths.

## 3. The gate

The no-VM gate ran on `b8a904b` the evening of the build: 36 green, 2 red. The
two reds are the known Windows limit: `Test-HardwareModule` and
`check-device-logic.py` build a sysfs tree with `0000:00:00.0` in a path, which
Windows does not allow (CLAUDE.md, `check-device-logic.py`). `check-version-rule`
and `check-netplan-rule` compared 3 of 4 and 1 of 2 implementations, and said
so: the C# half was not passed `--docker`.

| on the medium | |
|---|---|
| `check-image.py amd64` | 198 ok, 0 failed — 1.0.0.264 had 192; the six are `os7-app-containers` and what it owns |
| `run-s5.py all` | install, boot, cycle, update, timer — all PASS, 108 ok. The update `1.0.0.267 → 1.0.0.268` against a served repository, its firstboot migrations, and back |
| `run-firstrun.py --bench s5` | 13 ok |
| `run-phase3.py install`, `walk` | PASS, PASS — walk to a Complete screen naming 1.0.0.267 |
| `run-secureboot.py all` | 32 ok, GREEN — `rpool/ROOT/os7_1.0.0.267_…`, TPM unsealed under enforcing firmware, refused under a changed policy |
| `check-image.py arm64` | 146 ok, 0 failed |

The whole amd64 gate took 46 minutes after the build, while arm64 was still in
live-build.

## 4. The repository

`make repo-amd64` and `make repo-arm64` into `out/os7-repo`, each from a script
that refuses a HEAD other than `b8a904b` and a dirty tree, with the same two
host paths. The first amd64 attempt went through PowerShell and exited 1 on
the quoting of `test -z "$(git status --porcelain)"`. The cut accumulated over
the published tree fetched beforehand: the preview index holds 175, 203, 264
and 267 for each architecture, 267 superseding 264. `Packages` 47 entries for
amd64 (14 built in this run), 42 for arm64. The arm64 cut ran while the amd64
gate was running, and the amd64 cut while arm64 was in live-build.

## 5. Step 6 and step 8, typed by the operator

One script, `publish-267.sh`, in the desktop app's terminal panel, asked four
things: the release key's passphrase, the publish sub-account's password, and
`yes` twice. It ran in §3 step 8's order this time. 1.0.0.264 had uploaded its
index before its images:

1. **Step 6**: `scripts/sign-release.sh out/os7-repo 1.0.0.267 preview`. Both
   267 descriptors rewritten to `development: false`, the index re-hashed, and
   `Release.gpg`, `InRelease` and `index/preview.json.asc` signed by
   `E39B3127…B3F5FAF9`. Each asked back against the release key's public half
   alone, one signature each. All eight descriptors' hashes match the index;
   264 and 267 are `development: false`, 175 and 203 `true`, because they are.
   One passphrase prompt (`--pinentry-mode loopback`, #187), no timeout.
2. **8a, the payload**: over SFTP as the publish sub-account, root found at
   `repo/` by asking for `InRelease` under the three candidates: pool (only the
   missing files), releases, keyring, dists without their signatures, then
   `Release`, `Release.gpg`, `InRelease`.
3. **8b, the images**: to the webspace over SFTP, the address from DNS over
   HTTPS (`167.235.125.41`, the same as recorded), the ED25519 host key
   compared with os7-web's `SSH_HOST_KEY` before anything was sent. 1.0.0.264's
   two images removed (the 10 GB package holds one release), 267's two and
   `SHA256SUMS` uploaded in 2 minutes, then **read back off the server and
   hashed**: `1e7a9e7c…c838f`, `46a0b2a5…798c2`, and `SHA256SUMS` `0dbbdb85…`,
   each equal to the file on disk. Reading back 5 GB took longer than the
   upload, about 8 minutes. The script would have stopped before the index on
   any mismatch.
4. **8c, the index, last**.

Every lftp session ran with `set cmd:fail-exit yes`. That is the answer to
SESSION-PREVIEW-264 §7.4, where a listing that failed let an `rm` run because
lftp reports its last command's status. Nothing failed this time, so the setting
was not exercised. What it changes is that a failure would have stopped the
session at the failed command.

## 6. Asked back from outside

Over the read-only account, not the tree that was uploaded:

* the published `preview.json.asc` was the local one **1 s** after the script
  ended;
* all **55 pool files** fetched at their recorded size and sha256, 506 180 934
  bytes;
* `Release.gpg`, `InRelease` and `index/preview.json.asc` verified by `gpgv`
  against the release key alone, one signature each;
* `Release`, `InRelease`, `Release.gpg`, the index, its signature and both 267
  descriptors **byte-identical** to the signed local tree;
* every descriptor's hash equal to the index's, 267 `development: false`,
  `supersedes 1.0.0.264`;
* `Valid-Until: Sun, 29 Nov 2026 23:13:08 +0000`;
* at version 1.0.0.267 in `Packages`: 14 packages for amd64, among them
  `os7-app-containers`, and 11 for arm64, without it.

## 7. The site, the tag, the release

`tools/publish-release.py` had written the download cards, `releases.json`, the
`.htaccess` rewrites, `SHA256SUMS` and the manual links (`manual/1.0.0.267/`, the
same two PDFs as 264's: the manual did not change). `check-sitemap.py` 17 ok,
`check-deploy-mirror.py` 17 ok, `check-htaccess.py` 54 ok against a real Apache,
then pushed as os7-web `d26bb01` once both images had read back equal, and
deployed by its workflow (`success`). Between the `rm` of 264's images and that
deploy, about ten minutes, the live page linked to files that were gone. In a
one-release package that is unavoidable unless the site goes first, and then it
links to files that are not there yet.

`v1.0.0.267-preview` is an annotated tag on `b8a904b`, where
`git rev-list --count` is 267. The GitHub pre-release carries the release notes,
both `release.json` and `SHA256SUMS`, assembled by `scripts/make-release-dir.py`
with `--no-screenshots`. Its `SHA256SUMS` is byte-identical to the one on the
webspace.

**The public path by name was NOT fetched.** From this host `os7.org` resolves
to the filter, and by name the connection times out. Through the DoH address
(`167.235.125.41`) TLS presents a certificate from an authority this machine
does not trust, the network's inspection again (SESSION-PREVIEW-264 §7.4).
RELEASE-PROCESS §3 step 10's check by name is owed from another network.

## 8. What this run does NOT say

* **arm64 has no boot gate**, as always; its evidence is `check-image.py`.
* **The download by name was not fetched** (§7).
* **An installed machine cannot update from the published repository with
  the shipped cmdlets** (§9, #193). The update from 1.0.0.264 to this release
  ran only with one internal function replaced in memory.
* **The Containers window was not driven on a machine installed from this
  medium.** It ran on an installed 1.0.0.264 with this release's packages and
  on a GUI machine installed from a test medium built from this source
  (SESSION-CONTAINERS-WINDOW.md); this medium's gate is headless.
* **`cmd:fail-exit` was not exercised**: nothing failed (§5).
* **The manual's pictures are still 1.0.0.245's**, and it has no Containers
  chapter.
* **UL6 stands**: no per-release archive of the `.deb` files; step 7 was the tag.

## 9. The update from 1.0.0.264, against the published repository

**2026-10-31, the day after the release.** The question was whether a machine on
this release can take the next one. Every update measured until now went against a
repository a harness served over plain HTTP, signed by the development key, with
`-AllowDevelopment`. Not one machine had ever updated from the published Storage
Box, across four releases. So: bench `u264`, installed headless from the published
`OS7-1.0.0.264-amd64.iso`, updated to 1.0.0.267 the way the manual says. The updater
code is identical in 264 and 267 (`git diff 9a0059b b8a904b` on `OS7.Update.ps1` and
`os7-release` is empty), so this measures the code 267 itself will update with.

| step | result |
|---|---|
| the shipped state | `os7.sources` points at the published URI, `Enabled: no`; `/etc/apt/auth.conf.d/os7.conf` present, `0600`; no `update.conf` |
| `Set-OS7UpdateChannel -Channel preview` | **works**, no `-Uri`, no `-Credential`. Its read-back is a real `apt-get update` against the Storage Box |
| `Get-OS7Release` | **fails**: *"no release index for channel 'preview'"* — #193. Anonymous 401, with the apt credential 200 |
| the same, `Copy-OS7RepoFile` replaced in memory with one that passes `--netrc-file` | the index verified by `gpgv` against the 264 medium's keyring: *"Korrekte Signatur von OS/7 release signing key"*. 1.0.0.267 amd64 `Applicable`, `Development: False` |
| `Update-OS7`, no `-AllowDevelopment`, same session | **`From 1.0.0.264, To 1.0.0.267, Applied, Activated`**: clone, `apt install os7-desktop=1.0.0.267`, `full-upgrade`, `autoremove`, 7 firstboot migrations recorded, initramfs, menu |
| the package set after it | identical to a fresh 1.0.0.267 amd64 install: 1 526 packages, none extra, no version apart. `os7-app-containers` came in automatically. The update removed nothing |
| reboot | 1.0.0.267 running, its boot environment active, 25 container cmdlets |
| `Get-OS7Version` | **`Architecture: arm64`** on an amd64 machine — #194. `os7-release` is `all`, and the pool's copy carries the arm64 descriptor, in all four published releases. `Get-OS7Release` now judges the amd64 entries foreign |
| firstboot migrations | **hung** at `50-tpm2-reseal`, waiting on a passphrase prompt with no timeout — #195. Answered once by hand: re-sealed, the new seal opens, 60 to 80 ran |
| `Restore-OS7`, reboot | 1.0.0.264 running again, `release.json` amd64; the disk unlocked from the TPM with nothing typed |

**What this run proves works**: the published repository from the outside with the
medium's own credential, the release key accepted by the trust anchor of the previous
release's medium, the choice of the applicable release, the whole update into a new
boot environment, the package set it lands on, the migrations once they can run, and
the rollback.

**What it proves does not**: #193 is the one that matters. No machine anywhere can
use `Update-OS7`, the Software Update window or the unattended timer against the
published repository, and a fixed release cannot be delivered by the broken updater.
#194 turns the next update's architecture decision around on every amd64 machine that
updated. #195 holds a fleet's migrations behind an invisible prompt on the day PCR 7
moves.

**Bench notes**, not product findings: the first boot stalled under `splash` because
`os7lab.py login` answers Plymouth's terminal queries (#188). Waiting on the serial
line WITHOUT answering until *"Please unlock disk"* appeared, then logging in, worked
every time. And the update printed twelve `could not unmount
/run/os7-update/run/os7-update/…` lines, the `--rbind /run` seeing its own mount
point. The gate's log does not carry the update's output, so whether it prints them
too was not compared. Each migration was recorded twice (14 entries for 7); the second
pass skips them as already run.

The bench is kept: `u264`, snapshots `installed` (fresh 264) and
`rolled-back-from-267` (264 running, the 267 environment beside it).

## 10. The three fixes, and what each was checked against

All three are in the tree for 1.0.0.268; none is in a published release.

| | fix | check | on a machine (`u264`) |
|---|---|---|---|
| #193 | `Copy-OS7RepoFile` passes apt's file to curl as `--netrc-file`, reads the status code, and throws on 401/403 with a sentence per case: none, refused (by account), unreadable (root, `sudo pwsh -c`) | `check-update-logic.py`: a server that refuses anonymous requests, the credential in the shipped shape; listing, `Update-OS7`, the three refusals, an unprivileged caller, and a planted copy without the netrc that goes red | the fixed file in the 264 module: `Get-OS7Release` as root lists the published releases; as `os7admin` the root sentence; **`Update-OS7` 264 → 267 applied and activated with nothing patched in memory** |
| #194 | `os7-release` per architecture; `build-os7-repo.sh` keeps an identical arch:all file and refuses a different one; `Get-OS7Release` asks `dpkg` for the machine's architecture | `check-os7-repo.py` 143 ok: both `os7-release` files in the pool, each index its own, the installed descriptor names the probe's architecture after the other cut ran last, a planted arch:all difference refused; `check-update-logic.py`: a lying manifest does not make amd64 foreign, planted copy red; and the FULL cut of both architectures into a scratch tree, amd64 then arm64: all eight arch:all packages identical and kept, each index serving its own `os7-release` whose descriptor names its own architecture | 1.0.0.267 with the arm64 descriptor and the fixed module: amd64 own, arm64 foreign. apt takes `all` → `amd64` of one name as an upgrade (clean container) |
| #195 | the enrolment under `timeout` (120 s), stdin closed; after the bound the operator sentence and exit 0 | `check-reseal-migration.py`: seven cases against fakes, the blocking one ends; a copy without the bound hangs | the real `systemd-cryptenroll`: unanswered with a 15 s bound, exit 0 after 15 s, nothing left behind; answered within 90 s, re-sealed and the seal opens |

**What is still open, and is a decision rather than a fix:** no machine in the
field can take these fixes through its own `Update-OS7`, because that is the
code with #193 in it. Every machine installed from 175, 203, 264 or 267 needs one
step from outside the update train. (The Software Update window was the other
open point; §11.)

## 11. The Software Update window, against the published repository

The window calls `Get-OS7Release -Available` as the desktop user, and the
credential is `0600 root`. The owner chose that root writes the verified list
somewhere readable. As built:

* every `Get-OS7Release` run **as root** against the machine's own source writes
  what it listed, or the sentence it failed with, to `/run/os7/releases.json`
  (0644, directory 0755, only root can create it). The daily timer, a `sudo`
  listing and `Update-OS7` all leave it behind;
* an **unprivileged** call starts `os7-release-list.service`, a oneshot that runs
  `Get-OS7Release` as root and nothing else, waits for it, and reads the file.
  It refuses a list stamped before it asked, one naming another source, channel or
  release, and one in a file or directory anyone else could write;
* `49-os7-release-list.rules` lets an **active local session** start that one
  unit without a password. Anything else gets systemd's default policy;
* `/run`, not `/var`: a copy in `/var` would be cloned into the next boot
  environment and name the release just installed as applicable. And the timer
  alone would not do: `/run` is empty after every boot, and the timer runs once
  a day.

The window's code did not change.

**On `u267gui`** — GUI, installed from the published 1.0.0.267 medium, with the
fixed module and the three files copied in, the preview channel switched on:

| | |
|---|---|
| `os7admin` over ssh | refused by polkit: *"Access denied as the requested operation requires interactive authentication"*, and the root sentence with the `sudo pwsh -c` form |
| signed in at the greeter, Software Update from the start menu | **the eight published releases, no prompt**, "Your software is up to date", the arm64 rows explained as another architecture |
| the journal | `os7-release-list.service` started as the window opened, every fetch with `--netrc-file`, finished in 2.7 s |
| the file | `-rw-r--r-- root`, written at the second the window asked |

The first picture showed 1.0.0.175 as released **2026-03-09**. It was published on
3 September. `Get-OS7Release` rendered the index's date with `[string]`
("09/03/2026 07:53:54"), and a German machine read it back day-first. The
window's self-test had named that limit and called the fix in `Get-OS7Release`
owed. `Format-OS7Timestamp` now sends ISO 8601 in UTC, and the second picture
showed 2026-09-03.

`check-update-logic.py` holds all of it with no systemd. A fake `systemctl`
files a request, and a thread running as root plays systemd: it runs the real
`Get-OS7Release`, refuses the way polkit refuses ssh, or "runs" without writing.
The cases: the list arrives and matches root's own JSON field for field, the
refusal, a silent unit not answered from the old file, root's failure in root's
words, a loose directory refused, and the date. Two plants go red, the freshness
check removed and the old date line. Its first run caught a defect no machine had
reached yet: `Start-SystemdUnit` is unknown inside the module until
`Import-OS7SystemdLayer` has run.
