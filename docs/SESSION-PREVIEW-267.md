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
* **No machine has updated from 1.0.0.264 to this release** against the
  published repository. The measured update starts at 1.0.0.267, against a
  served copy.
* **The Containers window was not driven on a machine installed from this
  medium.** It ran on an installed 1.0.0.264 with this release's packages and
  on a GUI machine installed from a test medium built from this source
  (SESSION-CONTAINERS-WINDOW.md); this medium's gate is headless.
* **`cmd:fail-exit` was not exercised**: nothing failed (§5).
* **The manual's pictures are still 1.0.0.245's**, and it has no Containers
  chapter.
* **UL6 stands**: no per-release archive of the `.deb` files; step 7 was the tag.
