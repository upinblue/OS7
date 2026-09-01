# OS/7 — how a release is cut

**Written 2026-08-30.** What [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md)
C9 calls "the release descriptor is the product" describes *what* a release is.
[RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §3 describes what the
number means. Neither says who decides it, in what order the steps run, or what
must be green before any of them may. **This file decides only those three
things.** Where it appears to contradict a plan, the plan wins and this file is
wrong.

Nothing here has been executed end to end. **No OS/7 release has ever been
published**, the version has been `1.0.0.<build>` for every build this
repository has ever made, and `OS7_VERSION_PATCH` has never moved. This document
is the sequence that first publication is meant to follow, written before it
happens rather than reconstructed after.

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
| `run-phase3.py all` | the Mac | Install, boot with no medium, install again by keypress. Still the #74 gate, still unrun since the fix. |

**arm64's evidence standard is lower than amd64's, and that is a decision, not
an oversight.** As of 2026-08-30 arm64 gets `check-image.py` — 93 checks, green
on an ISO built on the x64 host (§7.1) — and no boot gate, because no aarch64
host with hardware virtualisation is in the release loop.
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
make build-amd64      # x64 Windows, native, ~20 min
make build-arm64      # emulated on the same box, ~50 min (see §7.1)
```

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

Both architectures, into **one** tree. See §7.3: today `build-os7-repo.sh`
produces a single-architecture tree and this step needs a merge that does not
exist yet.

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
| `repo/` | apt on an OS/7 machine | **Yes** — apt does Basic auth out of `/etc/apt/auth.conf.d/`. A read-only sub-account restricted to `os7/repo` is exactly the shape; Hetzner's own note that a read-only box "allows HTTP GET requests only" describes apt's access pattern precisely. |
| `iso/` | a browser, from the download page | **No.** A public download link cannot carry a password. |

**OPEN — RP1: where the public ISO download is served from.** Three candidates,
none chosen:

1. A small Hetzner Cloud server (CAX, ARM64, ~6 €/month, 20 TB traffic) running
   Caddy in front of the Storage Box. It solves the ISOs *and* removes the apt
   credential entirely, and a CAX builds arm64 natively — which is the other
   thing this repository owes.
2. Storage Share public links for the ISOs alone. No server, but the links are
   per-file and manual, which is the kind of step that gets forgotten.
3. Credentialed downloads on the site. Rejected here: a password on a public
   download page is not a control, it is a decoration.

Until RP1 is answered, the repository half can proceed and the ISO half cannot.

### 4.2 The credential, if the repository stays on WebDAV

Two code changes this implies, neither of which exists:

* **`Set-OS7UpdateChannel` cannot write a credential.** It writes the `.sources`
  file and reads it back through apt. WebDAV needs it to also write
  `/etc/apt/auth.conf.d/os7.conf` at mode 0600, with the same read-it-back
  discipline — a file that was written is not a file apt accepted.
* **The credential ships in the image** if `os7-release` carries it, which makes
  rotation a fleet operation. It is not a secrecy problem — integrity is GPG's,
  the content is public, and a leaked read credential compromises nothing — but
  it is a shared secret with an owner, and it needs a stated rotation path
  before the first machine carries it.

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

Found by reading the code and by building, on 2026-08-30. None of it is
speculative; all of it is unbuilt.

### 7.1 arm64 on the release host — measured, and one defect deep

`make build-arm64` runs on the x64 Windows host once
`docker run --privileged --rm tonistiigi/binfmt --install arm64` has registered
the qemu-aarch64 handler. Measured: debootstrap completes (BUILD-NOTES #12/#23's
failure is specific to the *other* direction), the NativeAOT publish for
`linux-arm64` succeeds, all nine OS/7 `.debs` build, hook 0022 installs them and
the `dpkg-divert` of `/usr/lib/os-release` takes. ~50 minutes against ~5 native.

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

### 7.2 A MINOR bump changes the suite, and that path has never run

`Update-OS7` takes the suite from the **target** release's signed index entry
(`$target.Suite`), so 1.0.x → 1.1.0 writes `Suites: os7-1.1` into the clone and
installs correctly. But at the end it **restores the environment's own OS/7 apt
source**, and that file is a conffile `Set-OS7UpdateChannel` wrote with
`os7-1.0`, kept across the upgrade by `--force-confold`. A machine that moved to
1.1.0 therefore keeps `Suites: os7-1.0` permanently.

Read from the code, never executed — no 1.1 has ever existed. The fix is to
rewrite the permanent source with the target's suite after a successful
activation.

### 7.3 The repository is single-architecture in three places

1. `build-os7-repo.sh` writes `APT::FTPArchive::Release::Architectures=${OS7_ARCH}`
   and one `binary-<arch>/`. Two architectures need one `Release` naming both.
2. `releases/<version>/release.json` has **no architecture in the path** while
   carrying `"architecture"` in its contents. Two architectures at one version
   overwrite each other. Proposed: `releases/<version>/<arch>/release.json` —
   builder-side only, because the index entry carries the manifest path and the
   machine reads it from there.
3. `Get-OS7Release`'s `Applicable` is `$newer -and $major -eq $myMajor -and
   $onBase`. **It never compares the release's architecture to the machine's.**
   Harmless while every repository is single-architecture; wrong the moment one
   URL serves both.

---

## 8. Open questions

| # | Question |
|---|---|
| **RP1** | Where the public ISO download is served from (§4.1). Blocks the website half of every release. |
| **RP2** | Whether apt actually reads a Hetzner WebDAV endpoint with Basic auth. Never tried. A ~20-minute test against a real box, and it must be done before anything depends on it. |
| **RP3** | The credential's rotation path, if the repository stays on WebDAV (§4.2). |
| **RP4** | Cadence. U5 proposes monthly `stable` plus out-of-band hotfixes; the number itself is a business decision and is still unmade. |
| **RP5** | Support window per Major, and how long `attic/` keeps a withdrawn release. Both are needed before a customer asks, and neither is written anywhere. |
| **RP6** | Whether the administrator manual is published per version on the site, and where it is generated from (§3 step 9). |
