# OS/7 — how a release is cut

**Written 2026-08-30.** What [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md)
C9 calls "the release descriptor is the product" describes *what* a release is.
[RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §3 describes what the
number means. Neither says who decides it, in what order the steps run, or what
must be green before any of them may. **This file decides only those three
things.** Where it appears to contradict a plan, the plan wins and this file is
wrong.

**This has now been executed end to end, twice** — 1.0.0.175 on 2026-09-03 and
1.0.0.203 on 2026-09-09. The paragraph here said "nothing here has been executed
end to end" until the second run, five days after it stopped being true, which is
itself the argument for the sentence below: a document that describes a process
has to be corrected by the process.

The version has been `1.0.0.<build>` for every build this repository has ever
made and `OS7_VERSION_PATCH` has never moved, both still true. What the second
run added is worth reading before the third: **§4.2 is built** (the credential a
published repository needs), and the run cost **two rebuilds of both media**
because the gate found two defects — in the release tooling itself, not in the
product (BUILD-NOTES #143 and #141). Steps 1–7 are reversible for exactly this
reason. [SESSION-PREVIEW-203.md](SESSION-PREVIEW-203.md) is that run's record.

---

## 1. The two decisions a human makes

Everything else in a release is derived, measured or generated. Exactly two
things are chosen, and they are chosen **together, before anything is built**.

### 1.1 The version — `MAJOR.MINOR.PATCH`

Three fields are edited in [build/config/os7-release.conf](../build/config/os7-release.conf).
The fourth is not: `BUILD` is `git rev-list --count HEAD`, computed by
`build.sh`, and writing it down by hand is what §3.1 forbids.

| Field | Moves when | Consequence nobody should discover later |
|---|---|---|
| `MAJOR` | Ubuntu LTS generation (1.x = 26.04, 2.x = 28.04) | `Update-OS7` **refuses to cross it** (C12). A machine cannot be updated across a Major; it is reinstalled or migrated deliberately. |
| `MINOR` | OS/7 feature release on the same base | **The apt suite changes** — `OS7_SUITE="os7-1.0"` becomes `os7-1.1`. See §7.2; this path has never run. |
| `PATCH` | Maintenance train: Ubuntu security rollup plus fixes | Nothing structural. This is the ordinary monthly move. |

### 1.2 The channel — `development` | `preview` | `stable`

`OS7_CHANNEL` in the same file. It is reported by `Get-OS7Version`, carried in
the manifest, and it is **not** a maturity claim about the Major field — that is
what §3.3 of the release plan means by "this field is NOT a maturity signal".

**There are two words spelled "channel" in this product and they are different
things.** Confusing them is how a development build ends up trusted:

| | What it is | Where it lives |
|---|---|---|
| `OS7_CHANNEL` | **The maturity of this build.** A fact about the artefact. | the pin → the manifest → `Get-OS7Version` |
| the index channel | **Which listing a machine reads.** An intention about an audience. | `index/<channel>.json` in the repository; `Set-OS7UpdateChannel -Channel` on a machine |

They are separate on purpose, and the separation is already enforced: a channel
*named* `stable` that is signed by a development key still demands
`-AllowDevelopment`, "because the channel names an intention and the signing
block names a fact" ([SESSION-UPDATE-DELIVERY.md](SESSION-UPDATE-DELIVERY.md) §2).

**The rule for this process: they agree.** A build whose `OS7_CHANNEL` is
`preview` is published into `index/preview.json` and nowhere else. Publishing a
build into a listing that does not match its own maturity is allowed by the
tooling and must be a deliberate, stated act — never a default.

### 1.3 The commit is part of the decision

`BUILD` comes from `git rev-list --count HEAD`, so **the release is cut from the
commit that bumps the pin, and nothing may be committed between that bump and
the last artefact built from it.** Two consequences that are easy to walk into:

* A commit between the amd64 and the arm64 build gives the two ISOs **different
  version numbers**, and the repository would then offer a release one of the
  media never carried.
* A **dirty tree** makes `build.sh` set `"reproducible": false` in the manifest
  and say so on stdout. That is honest, and it is not a release.

So: bump the pin, commit, and build everything from that commit.

---

## 2. Preconditions — the gate

A release may not be cut while any of these is red. They are listed with the
host that can run them, because that is the thing a single operator forgets.

| Check | Host | What green means |
|---|---|---|
| `pwsh -c 'Import-Module ./powershell/*/…; Test-*Module'` | either | The six module self-tests against recorded real output. |
| `./installer/testing/check-ps-traps.py` | either | The five PowerShell traps this repo has paid for. |
| `check-layering.py` | either | The five layering rules, at baselines that may fall and may not rise. |
| `check-update-logic.py` | either | The update train's decisions **and their order**. |
| `check-os7-repo.py` | either | Install from a signed repository, then refuse it with the key swapped. |
| `check-version-rule.py`, `check-netplan-rule.py` | either | The two specifications that exist twice, byte for byte. |
| `check-be-logic.py`, `check-home-logic.py`, `check-service-logic.py`, `check-scheduledtask-logic.py`, `check-directory-logic.py`, `check-installer-cmdlets.py` | either | The no-VM decision checks. |
| `check-vm-arch.py` | either | The Mac's QEMU command lines are still byte-identical to the pre-port construction. |
| `check-image.py <arch>` | either | **Per architecture, on the artefact** — the shipped `sources.list`, dpkg ownership, the branded identity. |
| `run-s5.py all` | amd64: this box · arm64: the Mac | **The machine gate.** Install, TPM boot, cycle, `Update-OS7` against a served repository, the unattended timer. |
| `run-phase3.py install` and `walk` | amd64: this box · arm64: the Mac | Install, then install again **by keypress**. `boot` cannot run on amd64 — an installed machine there has no `console=` and the phase watches the serial line (#132). |
| `run-secureboot.py all` | amd64: this box · arm64: the Mac | **Secure Boot on a machine**, and the only harness that boots the MEDIUM through its own bootloader. Added to this table 2026-09-09, when it first gated a release. |
| `run-firstrun.py` | amd64: this box · arm64: the Mac | **The documented first run, as the account the installer created** — every other row here runs as root. Added 2026-09-11, after #148 was reported by an operator an hour after a release that passed every other row. |

**arm64's evidence standard is lower than amd64's, and that is a decision, not
an oversight.** As of 1.0.0.203 arm64 gets `check-image.py` — **114 checks**,
green on an ISO built on the x64 host (§7.1) — and **no boot gate at all**,
because no aarch64 host with hardware virtualisation is in the release loop. It
was 93 checks when this paragraph was written on 2026-08-30; the number moved
with the Secure Boot rules, and it is the artefact's whole evidence.
Whatever is true at publication time **must be stated on the download page and
in the release notes**. A version number that claims more than was measured is
the one defect this repository exists to avoid.

---

## 3. The sequence

Steps 1–7 are reversible. **Step 8 is not** — the moment an index is readable,
a machine may take the release.

### 0. Decide, bump, commit

Edit `MAJOR`/`MINOR`/`PATCH` and `OS7_CHANNEL` in the pin. In the same commit,
bump `OS7_ARCHIVE_SNAPSHOT` and any Microsoft component version + hash that
moves — a Microsoft component moving upstream is a release event, not a
background occurrence (§3.4). Commit. Do not commit again until step 7.

### 1–2. Build both media from that commit

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64   # EVERY release
make build-amd64      # x64 Windows, native, ~20 min
make build-arm64      # emulated on the same box, ~50 min (see §7.1)
```

The first line is not optional and not once-per-machine: the registration is
lost on a Docker Desktop restart, and what fails afterwards says
`exec format error` about a shell script (§7.1). Read its JSON back and require
`linux/arm64` and `qemu-aarch64` in it.

### 3. Ask the artefacts what they are

```bash
./installer/testing/check-image.py --arch amd64
./installer/testing/check-image.py --arch arm64
```

This is the only check that sees the medium after live-build's binary stage.
Hook 0075 runs mid-build and cannot see what live-build does to apt afterwards.

### 4. The machine gate

`run-s5.py all` on amd64. Whatever arm64 evidence exists, record it — including
"none".

### 5. Cut the repository, unsigned

Both architectures, into **one** tree — by running `build-os7-repo.sh` once
per architecture **into the same output directory** (since 2026-09-01, §7.3).
The second run merges: every `binary-*` index is regenerated from the shared
pool, the `Release` names the union of architectures, each descriptor lands
under `releases/<version>/<arch>/`, and the index holds one entry per
(version, architecture). There is no separate merge tool to forget.

### 6. Sign, off the build machine

The `Release` → `InRelease`/`Release.gpg`, and `index/<channel>.json.asc`, with
the release key on its token. **C7a's whole point is that a release key is not
reachable unattended by a build script**, so this step is not inside a container
and not inside `make`.

Two keys are in `os7-archive-keyring.gpg` from the first release onward. Rotation
is only cheap if the successor is already trusted — the same reason hook 0010
carries two Microsoft keys.

### 7. Archive what the release actually installs

The `.debs` of both architectures, per UL6, against `snapshot.ubuntu.com` having
no published retention guarantee. This archive **is** the offline bundle (C7
§6.5); there is no second mechanism to build or test.

Tag the commit. The tag and the `BUILD` number must come from the same commit or
the tag names a different build than the artefacts do.

### 8. Publish — payload first, index last

The upload order is the atomicity mechanism. There is no transaction across a
static tree, so ordering is what stands in for one:

1. `pool/`, `dists/`, `releases/` — everything a machine will fetch
2. the ISOs and their hashes
3. **`index/<channel>.json` and its `.asc` last**

Until step 3, the release exists and is invisible: `Get-OS7Release` lists what
the index names and nothing else. A half-uploaded release is therefore not a
release, rather than a release that fails halfway through an update.

### 9. The website

`tools/publish-release.py` in `upinblue/os7-web` measures the ISOs it is given
and writes the download cards, `releases.json`, `SHA256SUMS` and the redirect
routes from the bytes on disk. Nothing about a size or a hash is typed.

Two things it does **not** cover today and a release must not forget:

* **The administrator manual is not published anywhere.** `docs/manual/` (DE and
  EN) is the product described from the outside, and its examples were typed at
  a machine of a specific version. If the site is to carry a documentation
  section, the manual is versioned with the release, not maintained beside it.
* **The site carries hand-typed version strings outside the generated block.**
  Only `download.html` has `BEGIN GENERATED` markers. `index.html` says `1.0.0`
  as a claim about the current version and will rot; `organizations.html` shows
  `IMAGE_VERSION=1.0.0.116` inside a transcript of `/etc/os-release`, which is a
  *measurement of one build* and is legitimately frozen. The release process has
  to know which of those two kinds each number is. Bringing the first kind under
  the generator is the fix; freezing the second is correct as it stands.

### 10. Verify from outside

Not from the tree that built it:

```bash
# a clean container, against the published URL
apt update && apt install os7-server=<version>
```

and, from an installed machine, `Get-OS7Release` — which verifies the signed
index and each descriptor's hash before it lists anything.

and **the public download path, by the name a reader will type** — not the
webspace's own hostname, not the IP, and not a page served out of the checkout.

```bash
curl -sI https://os7.org/download                       # must be 200
curl -sI https://os7.org/download/OS7-<version>-amd64.iso   # must be 200 or a 302 that is
```

**AND A FAILURE OF THAT CHECK IS NOT EVIDENCE UNTIL THE RESOLVER HAS BEEN ASKED
A SECOND WAY.** Added 2026-09-09, having got it wrong: this process reported
1.0.0.203's download links dead, on a timeout to `https://os7.org` and an A
record of `80.158.111.94` with port 443 closed. The record is `167.235.125.41`.
The build host's network was answering for that name with a filter, and asking
`1.1.1.1` with `-Server` does not escape a hijack of port 53 — DNS over HTTPS
does, and it gave the right answer immediately. `github.com` resolved correctly
in the same breath, which is why the wrong answer looked like a fact about the
domain (SESSION-PREVIEW-203.md §7).

```bash
curl -s -H 'accept: application/dns-json'   'https://cloudflare-dns.com/dns-query?name=os7.org&type=A'
```

A release nobody has fetched over the real transport is a release whose
publication has not been tested, only performed.

---

## 4. The Storage Box

**Decided 2026-08-30: a Hetzner Storage Box, reached over WebDAV.** The layout
below is proposed; nothing has been created.

```
os7/
  repo/                                  the apt repository — one tree, both arches
    keyring/os7-archive-keyring.gpg      the trust anchor os7-release ships
    pool/main/o/<pkg>/<pkg>_<v>_<a>.deb  shared by every suite
    dists/os7-1.0/…/binary-amd64/        Architectures: amd64 arm64 in one Release
    dists/os7-1.0/…/binary-arm64/
    dists/os7-1.1/…                      a new suite at every MINOR (§7.2)
    releases/<version>/<arch>/release.json
    index/{stable,preview,development}.json{,.asc}
  iso/<version>/OS7-<version>-<arch>.iso
  archive/<version>/<arch>/*.deb         UL6 — and the offline bundle
  attic/<version>/                       withdrawn releases: moved, never deleted
```

Three properties this layout is chosen for, rather than for tidiness:

* **`pool/` is shared and `dists/` is per suite.** A 1.0 → 1.1 move is then an
  apt operation over a tree that already holds both, not a migration.
* **`releases/<version>/<arch>/`** — the architecture is in the *path*. Today it
  is only in the file's contents, which collides (§7.3).
* **`attic/` exists because withdrawing a release is not deleting it.** Machines
  that already took it must still be able to fetch what they are running, and
  the descriptor is the only record of what that was.

### 4.1 Access — and the hole this choice leaves

Measured against Hetzner's documentation, not remembered: a Storage Box speaks
**FTP/FTPS, SFTP/SCP, rsync/BorgBackup, SMB/CIFS and HTTPS/WebDAV, and every one
of them requires authentication.** There is no public folder, no share link and
no anonymous HTTP. Public links are a feature of *Storage Share*, the Nextcloud
product, not of a Storage Box.

That splits cleanly for the repository and not at all for the ISOs:

| | Reader | Works? |
|---|---|---|
| `repo/` | apt on an OS/7 machine | **Yes, MEASURED — see below.** |
| `iso/` | a browser, from the download page | **No.** A public download link cannot carry a password. |

### 4.1a RP2 — ANSWERED 2026-09-02, and the fact that decided it

`installer/testing/check-storagebox.py`, against the real box, **5 checks, 0
failed**: anonymous `GET /` refused with 401; the read-only credential answers
200; `/dists/os7-1.0/InRelease` answers 200; **apt in a clean `ubuntu:26.04`
fetched and verified the signed index and saw `os7-base 1.0.0.171`**; and the
control — the same run with a deliberately wrong password — was answered 401.
Without that last one the fourth proves nothing, because a repository that
answers anonymously would look identical.

So the apt source a machine gets is:

```
Types: deb
URIs: https://u661569-sub2.your-storagebox.de
Suites: os7-1.0
Components: main
Signed-By: /usr/share/keyrings/os7-archive-keyring.gpg
```

**A SUB-ACCOUNT HAS ITS OWN VIRTUAL HOST, and getting that wrong is
indistinguishable from a wrong password.** The main account's vhost answers a
sub-account's credential with **401** — not 403, not a redirect — so every probe
against `u661569.your-storagebox.de` failed while the sub-account existed and
the credential was correct. `u661569-sub2.your-storagebox.de` answered 200 with
the same credential on the first attempt. Two consequences worth having in
writing: the read host is derived from the sub-account and is **not**
`OS7_SB_HOST`, and a 401 from a Storage Box is not evidence about the password.

**And the sub-account's directory is its ROOT**, so `os7/repo` appears at `/`:
`/dists/os7-1.0/InRelease` is 200 and `/repo/dists/os7-1.0/InRelease` is 404.
The URI therefore carries no path at all, which is the good outcome — it names
the read-only account and cannot reach anything else on the box.

Two traps paid for on the way, both of the shape this repository keeps meeting:

* **`apt-get update` exits 0 when a source could not be fetched at all.** An
  unreachable source is a `W:`, not an `E:`. The first version of this check
  read that as success with the right credential *and* with a wrong one — a
  control that could not fail. The check now reads which of
  `Get:`/`Hit:`/`Err:`/`Ign:` apt printed for the OS/7 source, and distinguishes
  "refused" from "never arrived", because only one of those is evidence.
* **`ubuntu:26.04` ships no `ca-certificates`**, so apt cannot complete a TLS
  handshake with anything and never reaches authentication at all. The check
  installs it from Ubuntu's archive first and removes Ubuntu's source only
  afterwards, so the clean-room property survives.

**OPEN — RP1: where the public ISO download is served from.** Constrained
2026-09-01: **no self-run server.** That rules out the obvious answer (a small
cloud instance with Caddy in front of the box) and leaves three that respect it.

1. **Nothing, yet — the Storage Box covers the whole product while OS/7 is
   `development` or `preview`.** No release has been published, so there is no
   anonymous audience to serve. Named testers get their own read-only
   sub-account; machines get the repo over WebDAV. This is not a workaround, it
   is the honest shape for a product whose own `OS7_CHANNEL` says it is not
   finished, and it defers RP1 to the first `stable` without blocking anything.
2. **Storage Share (Hetzner's managed Nextcloud) for the ISOs, from the first
   `stable` on.** Public share links, no server, and — measured on Hetzner's own
   page — **unlimited external traffic**, which matters because the ISOs are the
   only part of this product that moves real bandwidth. A *folder* share is one
   link for all releases, not one per file, so publishing an ISO into the shared
   folder needs no new link and no manual step per release.
3. **Credentialed downloads on the site.** Rejected: a password on a public
   download page is not a control, it is a decoration.

**Untested, and it would collapse both halves onto one product:** Nextcloud
exposes a public share over WebDAV at `/public.php/webdav`, with the share token
as the username and an empty password. If apt reads that, Storage Share serves
the repository *and* the ISOs, and the "credential" is a public token rather
than a secret — RP3 would disappear with it. This is a guess, not a measurement.
It costs one container and one `apt update` to settle, and it should be settled
before RP1 is answered, because a yes changes the answer.

Until RP1 is answered, the repository half can proceed and the anonymous ISO
half cannot.

### 4.2 The credential — BUILT 2026-09-09, and both halves are as proposed

Both code changes below were owed and neither existed; both exist now, for the
1.0.0.201 preview, which is the first release whose `OS7_REPO_URI` names the
real server.

* **`Set-OS7UpdateChannel -Credential`** writes `/etc/apt/auth.conf.d/os7.conf`
  at mode 0600 — empty file first, then the mode, then the content, because a
  file that is world-readable for the microseconds between create and chmod is
  world-readable (Net's `Set-NetplanDocument` measured that for a pre-shared
  key). It is keyed to the URI's **host**, which is what apt matches on; a
  credential for a `file://` URI is refused rather than written, because a
  secret on disk that can never be used is worse than none. The password
  reaches the file and nothing else: not the returned object, not a stream, not
  a command line.
  **And 0600 is OS/7's decision, not apt's** — measured 2026-09-09 in a clean
  `ubuntu:26.04`: an `auth.conf.d` entry at mode 0644 is read and used with no
  warning, no notice and nothing in any log. So nothing downstream would ever
  report a credential a machine had left readable.
* **The read-back was the weaker half and is now the stronger.** It ran
  `apt-get -qq update` and judged the exit code — and `apt-get update` exits 0
  for a source it could not fetch at all (§4.1a), while `-qq` suppresses the
  `Get:`/`Err:` lines that say which happened. So the check passed for every
  reachable machine and every unreachable one alike. It now reads which line apt
  printed **for this source** and names the outcome: `fetched`, `unauthorized`,
  `tls`, `notfound`, `errored`, `unfetched` — each a different sentence,
  because "refused as it should be" and "never reached it" send an operator to
  different places.
* **The credential ships in the image**, decided 2026-09-09. `os7-release`
  carries it, injected at build time from the operator's
  `~/.os7/storagebox.conf` (`make build-<arch>
  OS7_REPO_CREDENTIAL=$HOME/.os7/storagebox.conf`) and **never from this
  repository, which is public**. It is a conffile for the same reason
  `os7.sources` is one: `Set-OS7UpdateChannel` rewrites it, and a plain file is
  replaced on the next upgrade of the package. A build whose repository needs
  authentication and was handed no credential **refuses** — the medium it would
  produce installs machines that cannot reach the published repository and say
  nothing about why — with `OS7_REPO_NO_CREDENTIAL=1` as the deliberate opt-out.
  **"Needs authentication" is the pin's declaration, `OS7_REPO_AUTH`, and not
  an inference from the URI's scheme** (BUILD-NOTES #143): `http(s)` says
  nothing about a server, C7 §6.4 makes an unauthenticated mirror a supported
  deployment, and the scheme-based version of this refusal stopped `run-s5.py`
  from building the HTTP mirror it tests the update train against. The
  declaration describes the URI beside it, so a caller that overrides
  `OS7_REPO_URI` has replaced the server it was about and the refusal does not
  apply. The mode is then read back **out of the built `.deb`**
  (`dpkg-deb -c` must say `-rw-------`), because the staging tree sits on a bind
  mount and a Windows host does not honour a `chmod` there (BUILD-NOTES #117):
  the file would present as 0777, `pkg_finish`'s exact-0777 sweep would make it
  0644, and a world-readable password would ship in a signed package with every
  check green.
* **What that costs, stated rather than solved.** The credential is extractable
  from any published medium. It is read-only, its account's directory is its
  root, and integrity is GPG's — so what it protects is not the content but the
  bandwidth. **RP3 is still open**: rotation is now a fleet operation, and the
  first release to ship it is the release that makes that true.

Gated by `check-update-logic.py` ("Set-OS7UpdateChannel and the credential apt
reads"), whose fake `apt-get` reproduces the measured trap — it prints a 401
`Err:` line **and exits 0** — so the four refusals are proven to fire, with a
control run in which apt fetches the source and the same call succeeds.

**And the BUILDER's refusal is gated in both directions**, by
`check-os7-repo.py` ("the builder's credential refusal, both ways"), which is
the check that did not exist on the day the refusal was written: it builds
`os7-release` alone, four times, and requires the refusal to fire for the pin's
own URI with no credential, to stay silent for an overridden one, to be
passable with `OS7_REPO_NO_CREDENTIAL=1`, and — when a credential is handed in —
to put it in the `.deb` at `-rw-------` without the password appearing in the
build's own output. A refusal that has never been seen to fire is a refusal
nobody has checked, and #143 is what that cost.

---

## 5. Refusals — what this process must never do

* **Never publish anything signed by a key whose user ID says NOT FOR RELEASE.**
  `build-os7-repo.sh` prints the fingerprint on every run for this reason.
* **Never publish an index before its payload.** §3 step 8.
* **Never cut a release from a dirty tree**, or across two commits.
* **Never let a version number claim evidence that was not gathered.** If arm64
  was built and not booted, that is what the release notes say.
* **Never hand-edit a hash, a size or a version into the website.** Everything a
  human cannot verify by looking is generated from the bytes.

---

## 6. Withdrawing a release

Remove its entry from `index/<channel>.json`, re-sign the index, move the tree to
`attic/<version>/`. Machines stop being offered it immediately; machines already
running it keep working and can still roll back, because a rollback is a local
boot-environment operation and needs nothing from the network.

**`Valid-Until` is the real bound.** `OS7_REPO_VALID_DAYS="30"` means a machine
that never reaches the repository again stops trusting the old index within a
month. That is the freshness property §6.3 asks for, and it is the reason a
withdrawn release cannot be served forever by an attacker who kept a copy.

---

## 7. What must change before the first real publication

Found by reading the code and by building, on 2026-08-30. §7.2 and §7.3 were
**built and gated on 2026-09-01** — each fix's check is named where it is
described, and what a no-VM check cannot say is said too: no machine has yet
taken a real MINOR update, because no 1.1 has ever existed.

### 7.1 arm64 on the release host — measured, and one defect deep

`make build-arm64` runs on the x64 Windows host once
`docker run --privileged --rm tonistiigi/binfmt --install arm64` has registered
the qemu-aarch64 handler. Measured: debootstrap completes (BUILD-NOTES #12/#23's
failure is specific to the *other* direction), the NativeAOT publish for
`linux-arm64` succeeds, all nine OS/7 `.debs` build, hook 0022 installs them and
the `dpkg-divert` of `/usr/lib/os-release` takes. ~50 minutes against ~5 native.

**THE REGISTRATION DOES NOT SURVIVE A DOCKER DESKTOP RESTART, and its failure
does not name itself.** Measured 2026-09-02: a day after a successful arm64 ISO
build, `docker run --privileged --rm tonistiigi/binfmt` listed
`linux/{amd64,amd64/v2,amd64/v3,386}` and emulator `python3.14` alone — no
`linux/arm64`, no `qemu-aarch64`. `make repo-arm64` then died on

```
exec /work/build/lib/build-os7-repo.sh: exec format error
```

which reads like a corrupt script and is in fact a missing interpreter for the
whole architecture. **Re-run the `--install arm64` line at the start of every
release, before the first arm64 target**, and read its JSON back rather than
assuming it took — the same rule as everywhere else here.

The first run stopped at **hook 0070**, on a defect that has been in `main` since
`467f2ee` (2026-08-26) and that four days of amd64 builds could not see: the hook
requires `unattended-upgrades.service` to exist in the image, two paragraphs
after its own comment explains that arm64 is server-only and legitimately leaner.
Split into its two real assertions on 2026-08-30 — the unit must be **named in
the generator's list** on both architectures, and must be **present in the
image** on amd64, where #79 was measured.

**The rerun produced an ISO.** `OS7-1.0.0.165-arm64.iso`, 1 848 668 160 bytes,
built 2026-08-30 on the x64 Windows host in **1 h 15 m** of live-build (against
~5 minutes native on a Mac). Hooks 0070, 0075, 0080 and 0090 all ran, and so did
the binary stage — squashfs, `efi-remaster.sh` and ISO assembly included.
`check-image.py arm64` is **93 checks, 0 failures, exit 0** on it.

This is the first arm64 ISO built anywhere since 2026-08-26 and the first ever
built off a Mac, so **one host can now build both media** — which is what makes
a single-operator release process possible at all.

What this does **not** establish: that the medium boots, installs, or survives
`run-s5.py`. Nothing on this host can start an aarch64 guest with hardware
virtualisation, so arm64's evidence stops at the artefact. That is the bar §2
describes, and it is the bar that has to be printed on the download page.

### 7.2 A MINOR bump changes the suite — FIXED 2026-09-01

`Update-OS7` takes the suite from the **target** release's signed index entry
(`$target.Suite`), so 1.0.x → 1.1.0 writes `Suites: os7-1.1` into the clone and
installs correctly. But at the end it **restored the environment's own OS/7 apt
source verbatim**, and that file is a conffile `Set-OS7UpdateChannel` wrote with
`os7-1.0`, kept across the upgrade by `--force-confold`. A machine that moved to
1.1.0 therefore kept `Suites: os7-1.0` permanently — and nothing downstream
would ever have corrected it.

**The fix is at the restore site, not after activation**: the environment being
written IS the target release, so when the restored file's `Suites:` differs
from the target's, that one line is rewritten — a same-suite update still
restores the file byte for byte, a `-Stage`d 1.1 carries `os7-1.1` for the day
it boots, and the RUNNING 1.0 environment's own copy is never touched.
`check-update-logic.py` gates both halves ("the machine's permanent apt source
across a suite change"). What it cannot say: no machine has taken a real MINOR
update, because no 1.1 has ever existed.

### 7.3 The repository was single-architecture in three places — FIXED 2026-09-01

1. ~~`build-os7-repo.sh` writes `APT::FTPArchive::Release::Architectures=${OS7_ARCH}`
   and one `binary-<arch>/`.~~ Two per-arch runs into one output directory now
   merge: every `binary-*` index in the tree is regenerated from the shared
   pool on every run (eight of the ten packages are arch:all, rebuilt under
   ONE filename by either run — an index the second run did not regenerate
   would record hashes of files that run just replaced), `--arch` keeps each
   index to its own architecture plus arch:all (measured: `--arch amd64`
   includes `Architecture: all`), and the `Release` names the union, read
   back from the directories that exist.
2. ~~`releases/<version>/release.json` has no architecture in the path.~~ It is
   `releases/<version>/<arch>/release.json` now — builder-side only, as
   proposed: the machine reads the path out of the signed index entry.
3. ~~`Get-OS7Release`'s `Applicable` never compares the release's architecture
   to the machine's.~~ It does now — a POSITIVE mismatch (both sides state an
   architecture and they differ) makes the release `ForeignArchitecture` and
   not `Applicable`; `Update-OS7 -Version` prefers the machine's own twin when
   one version is listed for both architectures, and refuses a foreign release
   asked for by name with both architectures in the message.

Gates: `check-os7-repo.py` ("one tree, two architectures" — the second-arch
run happens before the install probe, so the probe installs from the tree the
other architecture's run rewrote last, and the arch:all hash-consistency is
asserted against the pool), and `check-update-logic.py` ("a release for
another architecture" — listed, not applicable, not chosen, refused by name,
and the twin-version preference).

---

## 8. Open questions

| # | Question |
|---|---|
| **RP1** | Where the public ISO download is served from (§4.1), given that a self-run server is ruled out. Blocks the anonymous half of the website, and nothing before the first `stable`. |
| ~~RP2~~ | **ANSWERED 2026-09-02 (§4.1a): yes.** apt reads the box over WebDAV with Basic auth, index verified, and the wrong-credential control is refused — `check-storagebox.py`, 5/5 against the real server. The Nextcloud `/public.php/webdav` idea in §4.1 is now only about RP1 and RP3, not about whether the transport works. |
| **RP3** | The credential's rotation path (§4.2). **Sharper since 2026-09-09, not answered:** the credential now ships in the image, so rotating it needs either a new medium or `Set-OS7UpdateChannel -Credential` typed on every machine — and the second is the reason that parameter exists. What is still unwritten is who rotates it, on what trigger, and how a machine that missed the rotation reports that rather than looking offline. |
| **RP4** | Cadence. U5 proposes monthly `stable` plus out-of-band hotfixes; the number itself is a business decision and is still unmade. |
| **RP5** | Support window per Major, and how long `attic/` keeps a withdrawn release. Both are needed before a customer asks, and neither is written anywhere. |
| **RP6** | Whether the administrator manual is published per version on the site, and where it is generated from (§3 step 9). |
