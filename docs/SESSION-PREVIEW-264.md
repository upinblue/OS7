# Session: the fourth preview — five lines of work on one main, two media thrown away, and the first release the release key signs

**2026-10-29/30, on the x64 Windows host.** Cutting **1.0.0.264**, channel
`preview`, from `9a0059b`. [RELEASE-PROCESS.md](RELEASE-PROCESS.md) is the
sequence; this file is what one run of it measured. Where a harness could not
run, that is said in place.

The short version: three sessions had finished that day and two had never been
committed; all five reached `main`. The gate found a fifth logo the merge could
not see, a check that died on the host's code page, both published previews
signed by the development key, a harness rule that could never pass on the run
it existed for, a boot that stalls when a serial terminal answers, and an arm64
build the boot splash had broken. **1.0.0.262** passed its whole amd64 gate and
was discarded for the last of those, because a release is both media from one
commit.

---

## 1. Five lines of work, one main

| line | where it was | how it reached main |
|---|---|---|
| quality of life ([SESSION-QOL-SURVEY](SESSION-QOL-SURVEY.md)) | `2a037f7` on main, unpushed | already there |
| containers, steps 1–3 | `e447e0b`, `98d2c43`, `02b15a0` on main, unpushed | already there |
| the brand and the boot splash ([SESSION-BRAND-FREEZE](SESSION-BRAND-FREEZE.md)) | three commits on `worktree-brand-freeze` | merged, `48e0273` |
| the rollback clone direction ([SESSION-ROLLBACK-CLONE-PIN](SESSION-ROLLBACK-CLONE-PIN.md)) | **uncommitted** in a worktree since 2026-09-22 | committed `64dcdd8`, merged `64c1ee8` |
| the manual's two applications ([SESSION-MANUAL-APPS-AND-SHOTS](SESSION-MANUAL-APPS-AND-SHOTS.md)) | **uncommitted** in a worktree since 2026-09-22 | committed `d2daeec`, merged `daf5d68` |

### 1.1 Seven BUILD-NOTES numbers were taken twice

`main` had reached #179. The brand branch had written #172–#174 and each old
worktree #168–#169. Every line a branch ADDED that cites one of its own numbers
was renumbered, matched by exact text against that branch's own diff, so
`main`'s entries of the same number were not touched:

| was | is | |
|---|---|---|
| brand #172, #173, #174 | #180, #181, #182 | the probe newline, the frozen command line, the redrawn prompt |
| rollback #168, #169 | #183, #184 | the clone direction, the precondition in a comment |
| manual #168, #169 | #185, #186 | the AltGr table, the greeter's session class |

The brand branch's three commit messages keep the old numbers;
SESSION-BRAND-FREEZE §6b says so.

### 1.2 A fifth logo, which no merge conflict could show

The brand work removed every `<text>` mark from the image. The quality-of-life
work, the same afternoon in the other checkout, added one: the two
`ubuntu-logo-text*.svg` that gnome-control-center hard-codes for
Settings > About, as `<text>OS/7</text>` in DejaVu Sans on the old tile. The two
never touched the same lines, git merged them silently, and `check-brand.py` was
green on both sides because it holds the consumers it LISTS. Both files are now
`brand.CONSUMERS` of kind `tile`, byte-identical to the app icon; hook 0090 and
`check-image.py` compare with `cmp`. **Not looked at on a screen**: the old file's
natural size was 96 px, the tile's is 64.

### 1.3 What the merge told the handoff

The manual's run had named three product defects as open. The first — Ubuntu's
`update-manager` beside Software Update — was found again independently and
fixed by the quality-of-life work (Q1). The third — a shell panel `#131313` where
the theme says `#d4d0c8` — got a likely cause, marked as not measured: #168, the
first desktop login on 1.0.0.245 being Ubuntu's session, whose panel is black.

## 2. The no-VM gate

38 checks, run before the pin moved. 37 green; `check-container-logic.py` died
before asserting anything — **#146 on the writer's side**: with stdout
redirected, pwsh on Windows writes in the console's code page, so the arrow in
`8080 → 80/tcp` arrived as `\x1a` and `json.loads` refused it. Fixed in the
harness (UTF-8 out of pwsh, UTF-8 out of Python), red without, 86 ok with, and
`--prove` turns all seven planted defects red (`98dff14`).

## 3. #187 — the published repository is development-signed

The published tree was fetched over the read-only sub-account (24 pool files,
234 268 104 bytes, each at its recorded size and sha256 — the same numbers
SESSION-PREVIEW-245 §9 took) and verified with the release key alone. Nothing
verified: `Release`, `InRelease` and `index/preview.json.asc` are signed by
`17C46067…`, the development key, and all four published descriptors say
`development: true`. And step 6 as written would not have fixed it — each
descriptor names the key the CUT was made with, and `Get-OS7Release` decides
`Development` from that. `scripts/sign-release.sh` is step 6 in full (BUILD-NOTES
#187), proven with throwaway keys on a copy of the published tree. Both published
releases' trust anchors already carry the release key, read out of their
`os7-release` .debs, so their machines accept a release-signed repository.

The release key's secret half IS on this host — in the WSL home, where
`setup-release-credentials.sh` puts it (#97). SESSION-PREVIEW-245 §5 looked in
the Windows profile.

## 4. The pin

`OS7_ARCHIVE_SNAPSHOT` `20260921T000000Z → 20261029T000000Z`. Asked of apt for
all 1 529 names in the newest manifest, in a clean `ubuntu:26.04` per snapshot:
1 512 have an archive candidate, **164 moved**, and this time the boot chain is
among them — `linux-image-generic 7.0.0-31.31 → 7.0.0-42.42`, systemd and
systemd-cryptsetup `259.5 → 259.9`, sudo, openssh, sssd, gnome-shell, mutter.
Shim, GRUB, ZFS, cryptsetup and openssl did not move, so PCR 7 stays put; the
kernel moving is why the TPM and Secure Boot evidence below was taken again.
MAJOR.MINOR.PATCH stays 1.0.0 for SESSION-PREVIEW-245 §1's reason; pwsh stays
7.6.5.

## 5. The gate on 1.0.0.262, and why that medium was thrown away

On `OS7-1.0.0.262-amd64.iso` (`88cc01f`, clean, `reproducible: true`):

| | |
|---|---|
| `check-image.py amd64` | 192 ok, 0 failed |
| `run-s5.py all` | install, boot, cycle, update PASS — 107 ok; **timer FAIL** (#189) |
| `run-firstrun.py --bench s5` | **FAIL**, no login prompt in 15 min (#188) |
| `run-phase3.py install`, `walk` | PASS, PASS — 2 ok, 27 ok |
| `run-secureboot.py all` | 32 ok, GREEN |

### 5.1 #189 — #184's rule could never pass on the run it was for

`run-s5.py timer` 3/4 asked for `staging ` in `tail -2` of update.log. When the
check really stages, `Update-OS7` writes between `staging <v>` and the verdict,
so the word is never in the last two; the screen showed `check: staged:
1.0.0.263 into os7_1.0.0.263_…`. The rule now reads the check's last line, proven
on both recorded tails; the rerun on the same machine: **timer PASS, 7 ok** —
including #183's first success on a machine: the environment left behind by an
update and a rollback was removed.

### 5.2 #188 — a serial terminal that answers stalls a `splash` boot

`run-firstrun.py` never reached a login: one boot ID, the same block 1 809 times,
ending in `Failed to start up manager`. `os7lab.py` answered terminal queries
from the first byte; `vmconsole` answers after a `login:`. Three boots of one
disk:

| boot | `splash` | terminal | result |
|---|---|---|---|
| A | yes | silent until a prompt | login; `run-firstrun` 13 ok, 0 failed |
| B | yes | answers from byte one | no login in 300 s; on the machine afterwards `plymouth-start.service: start-post operation timed out` at 94 s, `multi-user.target reached after 4min 24.940s` — when Enter was pressed |
| C | **no** | answers from byte one | login after 55 s (30 of them GRUB's menu) |

Harness fixed (`os7lab.py login` answers only after a prompt). **Product not
fixed**: BRAND-PLAN BRL9, release notes "Known limits", workaround `splash` out
of `GRUB_CMDLINE_LINUX_DEFAULT`. On the same bench, with the fixed login:
`Test-DockerModule` **58 passed, 0 failed** — the verdict `check-image.py` cannot
get in a chroot.

### 5.3 #190 — the boot splash broke the arm64 build

72 minutes in, hook 0022, `update-initramfs`: `cp: cannot stat
'/etc/fonts/fonts.conf'`. Ubuntu's plymouth hook copies fonts.conf and runs
`fc-cache` for every graphical theme and does not depend on fontconfig; the arm64
server image had neither. `os7-console: Depends: fontconfig`, checked in an arm64
`ubuntu:26.04` before the next build. The fix is a commit, so 1.0.0.262 — both
media — was discarded (§1.3 of the process).

## 6. 1.0.0.264

Both media from `9a0059b`, a clean tree, `reproducible: true` in both
descriptors. arm64 under emulation in 97 minutes, amd64 natively in 26, the
amd64 build started only once the arm64 one was past the shared signing key.

| medium | bytes | sha256 |
|---|---|---|
| `OS7-1.0.0.264-amd64.iso` | 3 412 471 808 | `44d2d4785322eaa8df3f3e05f3c32d6415a47faaae706b83c8c2ccbe0cd9d801` |
| `OS7-1.0.0.264-arm64.iso` | 1 846 882 304 | `2b2c98fcf89193b731b2a8c10b1f9495a3a84b4fd8ed67b59f99dbe091e49125` |

| | |
|---|---|
| `check-image.py amd64` | 192 ok, 0 failed |
| `run-s5.py all` | install, boot, cycle, update, timer — all PASS, 108 ok; the update `1.0.0.264 → 1.0.0.265` against a served repository |
| `run-firstrun.py --bench s5` | 13 ok, 0 failed — with the fixed `os7lab.py login`, on a `splash` boot |
| `run-phase3.py install`, `walk` | PASS, PASS — 2 ok; 26 ok and one note (the copy bar was sampled once, too few to say it advanced) |
| `run-secureboot.py all` | 32 ok, GREEN — on the new kernel |
| `check-image.py arm64` | 146 ok, 0 failed |

Everything the gate on 1.0.0.262 found red is green here, on a medium that
differs from 262 in its version number and #190's dependency — the commit
between them (`30957e5`) touched harnesses and documents only.

## 7. The repository and the publication

### 7.1 The cut

`make repo-amd64` and `make repo-arm64` into `out/os7-repo`, seeded with the
published tree fetched over the read-only account, so the suite accumulates:
the preview index holds 1.0.0.175, 1.0.0.203 and 1.0.0.264 per architecture,
264 superseding 203; 39 pool files, each at its recorded size and sha256;
`Packages` 33 entries for amd64, 31 for arm64; `Valid-Until` 2026-11-29.

### 7.2 Step 6, signed by the release key

`scripts/sign-release.sh out/os7-repo 1.0.0.264 preview`, the operator at the
terminal. It rewrote both 264 descriptors to `development: false`, carried
their hashes into the index, signed `Release`, `InRelease` and
`index/preview.json.asc` with `E39B3127…B3F5FAF9`, and asked all three back
against the release key's public half alone — one signature each, every
descriptor's hash matching, 175 and 203 still `development: true` because they
are.

It took three starts. The first two ended `signing failed: Timeout` about a
minute after pinentry-curses drew its dialog in the desktop app's terminal
panel, nobody having typed; in a plain pty the same dialog waits until its
input closes (150 s measured) and a SIGWINCH does not end it, so what closed it
in the panel is not known. `sign-release.sh` now asks through
`--pinentry-mode loopback` — one prompt on the terminal, cached by gpg-agent
for the signatures after it, measured with a throwaway key (one prompt, three
processes, three good signatures) and re-proven by the throwaway-key test's
four cases before it touched the release key (BUILD-NOTES #187).

### 7.3 Step 8a, the repository

Over SFTP as the publish sub-account, which the operator typed the password
for. The script found the published root at `repo/` and uploaded in §3 step 8's
order — pool, releases, keyring, dists without their signatures, then
`Release`, `Release.gpg`, `InRelease`, then the index and its signature last.
**Asked back from outside**, over the read-only account: the new
`preview.json.asc` was there 21 s after the upload ended; all 39 pool files
fetched at their recorded size and sha256 (366 539 504 bytes); `Release.gpg`,
`InRelease` and `index/preview.json.asc` verified by `gpgv` against the release
key alone, one signature each; the seven files that make the release
byte-identical to the signed local tree; and every descriptor's hash equal to
the index's, 264 `development: false`.

### 7.4 Step 8b, the images — and the network in between

`publish-264.sh` failed at the images, and four more attempts failed before one
worked, each for a different reason. **All of them are this host's network or
my tooling, not the webspace**:

| attempt | what happened |
|---|---|
| `ftps://` by name | the local resolver answers `80.158.111.94` for `www762.your-server.de`; DNS over HTTPS (Cloudflare and Google agreeing) answers `167.235.125.41` — SESSION-PREVIEW-203 §7's filter, on the webspace's own name this time. `Connection refused` |
| `ftps://` to the DoH address | `ftps://` is **implicit** TLS on port 990, which this webspace does not answer: `SYN_SENT` to `:990` |
| `ftp://` + forced TLS | lftp's own `/etc/lftp.conf` says `dns:order "inet6 inet"`; `--add-host` pins only IPv4, so the AAAA came from the filtering resolver and lftp refused the certificate that answered |
| the same, IPv4 only | the control channel on `:21` presents the real certificate (`your-server.de`, DigiCert / Thawte TLS RSA CA G1, sha1 `6F1FD300…`) and the login succeeds; **every data channel** presents `CN=your-server.de` issued by **`Deutsche Telekom OnNet CA`** (sha1 `D270905E…`) — TLS inspection in the path, after which the server resets the connection. The server refuses `PROT C`, so a clear data channel is not available either |
| **SFTP** | works. The ED25519 host key read from the DoH address, `SHA256:FptHFzbs…`, is the one os7-web's deploy pins in `SSH_HOST_KEY` since 2026-08-30, and it was checked STRICTLY. Both images in 2 minutes |

os7-web's `deploy-web.yml` had already written the FTPS half of this down in
August — the control connection fine, "the separate data channel was reset",
and the reason it names is a server that may require the data channel to resume
the control channel's TLS session — from GitHub's runners, not this network. So
FTPS data channels to this webspace fail from two places, and SFTP is the route
from both.
`publish-release.py --print-upload` still prints an `ftps://` line.

**And one of the failed attempts deleted 1.0.0.203's images.** The operator had
said yes to exactly that exchange, but it happened in an attempt that should
have stopped first: its listing failed on the data channel's certificate, lftp
exited 0 anyway because `bye` was the last command, and the `|| die` behind it
never fired — so `rm` and the first 64 KiB of the amd64 `put` ran. From then
until the site deployed, the live download page linked to files that no longer
existed. *An exit code is a diagnostic*, and lftp's reports the last command of
the script, not the one that failed.

**Read back off the server**, over SFTP with the same pinned key, and hashed:

| | sha256 on the webspace | |
|---|---|---|
| `OS7-1.0.0.264-amd64.iso` | `44d2d4785322eaa8df3f3e05f3c32d6415a47faaae706b83c8c2ccbe0cd9d801` | ok |
| `OS7-1.0.0.264-arm64.iso` | `2b2c98fcf89193b731b2a8c10b1f9495a3a84b4fd8ed67b59f99dbe091e49125` | ok |
| `SHA256SUMS` | `4bccadf5…`, the file `publish-release.py` wrote | ok |

**The public path by name was NOT fetched.** From this host `os7.org` answers
every URL with `403` and a refresh to
`onnet.telekom.de/portal/telekom-de/blocking` — the network's filter, through
the DoH address as well as the hijacked one — IPv6 does not connect, and
WebFetch fails the same way. What stands in for it: the bytes on the server,
read back; the rewrites from `/download/<file>` to `/iso/<file>`, held by
`check-htaccess.py` against a real Apache here and again in the deploy run; and
the deploy itself. RELEASE-PROCESS §3's check by name is owed from another
network.

**And from another network it works.** The operator opened
`https://os7.org/download` away from this host's network on 2026-10-30 and
reported the page working. That is a person looking, not a `curl -sI` with its
status recorded, and an image fetched by name and checked against `SHA256SUMS`
was not reported — the read-back hashes above remain the evidence for the bytes.

### 7.5 The site, the tag, the release

`tools/publish-release.py` wrote the download page, `releases.json`, the
`.htaccess` rewrites and the manual links; `check-sitemap.py` 17 ok,
`check-deploy-mirror.py` 17 ok, `check-htaccess.py` 54 ok against a real Apache;
pushed as os7-web `e343467`, deployed by its workflow.
`v1.0.0.264-preview` is an annotated tag on `9a0059b`, where
`git rev-list --count` is 264.

The GitHub pre-release
[OS/7 1.0.0.264 — third preview](https://github.com/upinblue/OS7/releases/tag/v1.0.0.264-preview)
carries the release notes, both media's `release.json` and `SHA256SUMS` — the
last one only after a fix: `scripts/make-release-dir.py` wrote it with CRLF on
this host, which `sha256sum -c` reads as a file name ending in `\r`. It now
writes `\n`, and its `SHA256SUMS` is byte-identical to the one on the webspace.

**The order deviated from §3 step 8**, which puts the ISOs before the index:
`publish-264.sh` uploaded the repository with its index first and the images
after. Nothing a machine reads names an ISO, so no machine saw a difference;
the download page did, for the hour between the 203 images going and the deploy.

## 8. What this run does NOT say

* **arm64 has no boot gate**, as always; its evidence is `check-image.py`.
* **The download by name was not fetched from this host** — `os7.org` is
  blocked from this network (§7.4). The operator confirmed the download page
  from another one; an image fetched by name and hashed there was not reported.
* **No machine has updated from 1.0.0.175 or 1.0.0.203 to this release** against
  the published repository; the measured update starts at 1.0.0.264. That both
  trust anchors carry the release key was read out of their packages, not
  exercised.
* **#188 is not fixed in the product.** Which answer triggers it — DSR or
  XTGETTCAP — is not separated.
* **The About page with the tile and the login screen with the generated mark
  were not looked at on a screen** in this run.
* **The manual's pictures are 1.0.0.245's** — Setup from `run-phase3.py walk` on
  that medium, the desktop from a 1.0.0.245 bench. The brand and the
  quality-of-life work change the login screen, the desktop and the boot, so the
  desktop pictures are stale; the road to retake them (`shoot-desktop.py`,
  `place-manual-shots.py`) exists and was not driven here.
* **UL6 and #144 stand** as SESSION-PREVIEW-245 §12 describes them.
