# OS/7 releases and updates — versioning and the update train

**Status: plan only. Nothing below is implemented.** This document answers three
questions asked on 2026-08-23 and turns the answers into a phased plan:

1. Can Ubuntu security patches be applied to OS/7 without changing OS/7's code?
2. Can OS/7 be moved from one Ubuntu release to the next, and what does that cost?
3. Can OS/7 carry **one product version number** — "OS/7 1.0.0.0 consists of
   Ubuntu *xy*, PowerShell *xy* and OS/7's own userland *xy*" — and can the
   whole update experience be driven from PowerShell, so an operator never has
   to know the Linux commands underneath?

Short answers: **yes**, **yes but it costs engineering once per Ubuntu LTS**,
and **yes — but only if the package set is pinned, otherwise the number is a
label rather than a state.**

This is the document [../powershell/OS7/OS7.psm1](../powershell/OS7/OS7.psm1)
is missing: its stubs throw `NotImplementedException` and say in their own
help that no on-disk format, transport or ZFS layout is defined. This defines
them. It also closes D8 from
[../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md) as a side effect (§3.5)
and raises one problem that plan did not have to face (§4.4).

---

## 1. Verdict

| Question | Answer |
|---|---|
| Ubuntu security patches within 26.04, no code change | **Yes.** OS/7 is real Ubuntu — `ID=ubuntu`, Ubuntu archive, GA kernel, prebuilt ZFS. What OS/7 adds is a different *delivery* of the same packages, not a different source for them. |
| …with no caveats? | **No — four**, and all four are consequences of OS/7's own design rather than of Ubuntu (§2.2). One of them, a Secure Boot policy update breaking TPM2 unlock fleet-wide, is the single largest operational risk this project has. |
| Ubuntu 26.04 → 28.04 without code change | **No.** Five pins in five files, plus two external dependencies OS/7 does not control (§2.3). This is a product generation, not an update. |
| …is that a design flaw? | **No.** Every derivative pays this. What OS/7 *can* do is make it one manifest instead of a scavenger hunt, and make the upgrade itself safer than upstream's — a release upgrade into a cloned boot environment is rollback-safe, which `do-release-upgrade` is not. |
| One product version number | **Yes, and OS/7 is unusually well placed for it** — the ZFS boot environment already makes "the state of this system" a single nameable, atomic thing. Most apt-based distributions cannot say this. |
| Is that number *true* | **Only if the archive is pinned.** With plain `apt upgrade`, two machines reporting `1.0.0.0` hold different packages, and the number is worthless for exactly what it is wanted for: support and compliance. |
| Is pinning available | **Yes — verified 2026-08-23.** `snapshot.ubuntu.com` serves `resolute`, `resolute-updates` and `resolute-security` addressed by timestamp, **including arm64 under the same path** (§3.2). No private mirror needed. |
| PowerShell-only operation | **Yes for the update train.** Not for everything — `apt` stays present and usable because bash stays the system shell, which is why drift detection is mandatory rather than optional (§5). |

The largest *unknown* here is not the update mechanism. It is whether TPM2
auto-unlock survives the update cycle (§2.2, S6). Everything else is work.

---

## 2. What "update" means, at three different scopes

These get conflated constantly. They are three different products of work.

| Scope | Frequency | Code change | Mechanism |
|---|---|---|---|
| **Patch** — Ubuntu security/updates within 26.04 | monthly train | none | new BE, apt against the next pinned snapshot |
| **Feature** — new OS/7 functionality, new PowerShell major | as needed | OS/7's own code only | same mechanism, minor field bumps |
| **Generation** — Ubuntu 26.04 → 28.04 | once per LTS | substantial | §2.3; a migration project, never automatic |

### 2.1 Patches within 26.04 — the mechanism, not the source, is what changes

Nothing about a `resolute-security` package is OS/7-specific. The kernel, ZFS
module, systemd, GRUB and shim all come from Ubuntu and all install with plain
dpkg. OS/7 does not need to adapt to them.

What OS/7 changes is *where they are applied*: into a clone of the running boot
environment rather than onto the running system. The running system is untouched
until the operator reboots, and the previous BE stays bootable afterwards. That
is the entire value proposition, and it needs no cooperation from Ubuntu.

### 2.2 The four things that break under ordinary patches

Each of these is triggered by a completely routine Ubuntu update. None is
hypothetical — all four follow from decisions already made in this repo.

| # | Trigger | What breaks | Why it is OS/7's problem |
|---|---|---|---|
| 1 | `shim` or `dbx` update | **TPM2 auto-unlock, fleet-wide.** Sealing is against PCR 7, which measures Secure Boot policy. Kernel updates do not disturb it; a Secure Boot policy change does. Every machine falls back to a passphrase prompt at the next boot. | **Measured 2026-08-23 by S6** ([SESSION-S6-UPDATE-CYCLE.md](SESSION-S6-UPDATE-CYCLE.md)), and it degrades better than assumed: the failure is *detectable* (`cryptsetup` names the cause), *survivable* (the passphrase path still works), and *repairable* by one `systemd-cryptenroll` against the new PCR 7. What remains is where the recovery key lives — U8, now a key-management question rather than a boot one. |
| 2 | `base-files` upgrade | Overwrites `/etc/os-release`, taking the OS/7 branding **and the version number** with it (§3.5). | The file is a conffile owned by another package. Branding it is a modification dpkg will contest at every upgrade. Needs an idempotent reassert that runs after every BE update, not a one-time write at install. |
| 3 | Any kernel update | Rebuilds the initramfs. OS/7's TPM2 token handler is a **local initramfs hook** from S4, not an archive package — it carries `libcryptsetup-token-systemd-tpm2.so` and the libtss2 libraries systemd dlopens. | It regenerates correctly *if* the hook is installed properly, and silently produces an unbootable-without-passphrase system if it is not. This is the thing S6 has to prove, because the failure is only visible at the next boot. |
| 4 | `grub` update | Regenerates `grub.cfg` via `10_linux_zfs`, re-emitting the zsys-era *Revert* entries OS/7 has no `zsys` to serve, and re-titling entries from `PRETTY_NAME`. | L4. Cosmetic on its own, but it shares a mechanism with the `GRUB_CMDLINE_LINUX` hazard in the same note: one `root=ZFS=` is emitted per BE, and anything appended lands after it and wins. An update-time regeneration is exactly when that would be introduced by accident. |

Items 2, 3 and 4 are ordinary engineering. Item 1 is a design gap and should be
treated as blocking for any fleet deployment.

### 2.3 Ubuntu 26.04 → 28.04 — a product generation

Every pin that would have to move, and where it lives today:

| Pin | File |
|---|---|
| `OS7_DISTRIBUTION="resolute"` | [../build/config/auto/config](../build/config/auto/config) |
| `archive.ubuntu.com` / `ports.ubuntu.com` split | same file |
| `dotnet-runtime-10.0` + `aspnetcore-runtime-10.0` (was `dotnet-sdk-10.0` until C2, 2026-08-25) | [../build/config/package-lists/os7-base.list.chroot](../build/config/package-lists/os7-base.list.chroot) |
| `--linux-packages "linux-image"` — **not** the package list; live-build installs the kernel itself in `--mode ubuntu` (BUILD-NOTES #62) | [../build/config/auto/config](../build/config/auto/config) |
| `Suites: resolute`, two GPG fingerprints | [../build/config/hooks/0010-microsoft-repos.hook.chroot](../build/config/hooks/0010-microsoft-repos.hook.chroot) |
| `PWSH_VERSION` + two SHA256 | [../build/config/hooks/0020-powershell.hook.chroot](../build/config/hooks/0020-powershell.hook.chroot) |
| `VERSION_ID="26.04"` | wherever os-release is branded (§3.5) |

Plus two dependencies OS/7 does not control:

* **Microsoft must publish a matching suite.** Hook 0010 already documents that
  Azure CLI is only published against `noble` and consumed cross-release. That
  is a standing bet on Microsoft's release cadence, and it is the reason a
  generation bump cannot be scheduled unilaterally.
* **Intune compatibility must be re-verified** against whatever GNOME major
  ships in the new base. Per README, Intune's constraints outrank OS/7's
  preferences, so this gates the release rather than being a follow-up.

**The mitigation is not to avoid this — it is to centralise it.** One
`build/config/os7-release.conf`, sourced by `auto/config`, the package lists and
every hook, turns a generation bump from "find the five pins" into "edit one
file and rebuild". That file then doubles as the input to the release manifest
in §3.4, which is the same data viewed from the other end.

---

## 3. The version number

### 3.1 Why a single number is only honest if the archive is pinned

The requirement is that `OS/7 1.0.0.0` names a **state**, so that a support case,
a compliance report and a test result all refer to the same thing.

If `Update-OS7` runs `apt full-upgrade` against the live archive, the result
depends on *when* it ran. A machine updated on the 3rd and a machine updated on
the 17th both report `1.0.0.0` and hold different kernels. At that point the
number is worse than having no number, because it will be trusted.

So the release must fix the archive, not just the moment.

### 3.2 `snapshot.ubuntu.com` — verified, and better than expected

Checked against the live service on 2026-08-23:

| Check | Result |
|---|---|
| `…/ubuntu/20260801T000000Z/dists/resolute/Release` | `200` |
| `…/dists/resolute-updates/Release` | `200`, header reads `Date: Fri, 31 Jul 2026 18:53:25 UTC` — the timestamp resolves to the archive state *at that instant*, not to a rounded day |
| `…/dists/resolute-security/Release` | `200` |
| `…/dists/resolute/main/binary-arm64/Packages.gz` | `200` |
| `Architectures:` in the resolute Release file | `amd64 amd64v3 arm64 armhf i386 ppc64el riscv64 s390x` |
| Retention depth | `jammy` at `20220601T000000Z` still resolves — at least four years back |

Two consequences worth naming:

* **arm64 lives under the same `/ubuntu/` path.** The `archive`/`ports` split
  that `auto/config` has to handle for the live archive **does not exist in the
  snapshot service**. Building against snapshots therefore *removes* a
  per-architecture special case rather than adding one.
* **No private mirror is required.** Determinism is a URL, not an
  infrastructure project. This is the difference between the version number
  being affordable and being a permanent operating cost.

A release therefore pins `OS7_ARCHIVE_SNAPSHOT=<timestamp>`, and that single
value plus the package selection defines the entire Ubuntu half of the product.

### 3.3 The four fields

Not one field per component — that breaks the moment a component has its own
versioning scheme. The Windows model instead: one **product number**, plus a
**bill of materials** that answers "what is in it".

| Field | Meaning | Moves when |
|---|---|---|
| **Major** | Ubuntu LTS generation. `1.x` = 26.04, `2.x` = 28.04. | §2.3 happens. Never automatically, never without an explicit migration. |
| **Minor** | OS/7 feature release on the same base: new cmdlets, new `os7-setup`, a PowerShell major bump. | OS/7 ships functionality. |
| **Patch** | Maintenance train: Ubuntu security rollup + fixes. The regular cadence. | Monthly (proposed, U5). |
| **Build** | CI build number, and the out-of-band hotfix channel (§7). Monotonic. | Every build. This is the field a support ticket quotes. |

The Ubuntu version is thus encoded in Major and does not need its own field;
"which Ubuntu is this" is answered by the manifest, precisely.

### 3.4 The release manifest — the bill of materials

Shipped in the image at `/usr/lib/os7/release.json`, generated by the build, and
the single source of truth for `Get-OS7Version -Detailed`. Proposed shape:

```json
{
  "version": "1.0.0.0",
  "channel": "stable",
  "built": "2026-08-23T14:30:00Z",
  "architecture": "arm64",
  "base": {
    "distribution": "ubuntu",
    "release": "26.04",
    "codename": "resolute",
    "archive_snapshot": "20260801T000000Z"
  },
  "components": {
    "kernel":       "7.0.0-28-generic",
    "zfs":          "2.4.1-1ubuntu5",
    "powershell":   { "version": "7.6.5", "sha256": "b34ab3b1…6844" },
    "dotnet_sdk":   "10.0.111",
    "os7_setup":    "1.0.0.0",
    "os7_module":   "1.0.0.0",
    "authd":        "…",
    "authd_msentraid": { "snap_revision": "…" }
  },
  "microsoft": {
    "azcmagent":    { "version": "…", "sha256": "…" },
    "intune_portal":{ "version": "…", "sha256": "…" }
  },
  "packages_manifest": "sha256:…"
}
```

`packages_manifest` is the hash of the full `dpkg --get-selections` output
shipped alongside it. That is what makes drift detection (§5) cheap: compare the
running system's selections against the recorded hash, and the answer is one
comparison rather than a package-by-package audit.

The `microsoft` block is separate on purpose: `packages.microsoft.com` has **no
snapshot service**, so those components cannot be pinned by URL. They are pinned
by version *and hash*, verified at build time — the pattern hook 0020 already
uses for the PowerShell tarball. That hook is the model for everything in this
block; it is the one place in the repo that already does release engineering
correctly.

### 3.5 Where the version lives — and why this closes D8

`/etc/os-release` has a field for exactly this case, and it is **not**
`BUILD_ID`. The systemd specification defines `BUILD_ID` as identifying the
image *originally used as the installation base*, explicitly noting that it does
**not** change during incremental updates. That is the opposite of what is
wanted here.

The correct pair is `IMAGE_ID` + `IMAGE_VERSION`, which the same specification
describes as being for environments where OS images are "prepared, built,
shipped and updated as comprehensive, consistent" units, and which it names
alongside `VERSION_ID` as what changes when the system image is replaced.

Resulting file:

```sh
ID=ubuntu                      # untouched — Intune "Allowed distributions"
ID_LIKE=ubuntu                 # untouched
VERSION_ID="26.04"             # untouched — Intune matches on this
NAME="OS/7"                    # branded
PRETTY_NAME="OS/7 1.0.0.0"     # branded
HOME_URL="https://…"           # branded
IMAGE_ID=os7                   # OS/7 product identity
IMAGE_VERSION=1.0.0.0          # OS/7 product version
VARIANT="Server"               # GUI | Server, from Set-OS7Mode
VARIANT_ID=server
```

**This closes D8** (SETUP-PLAN §9) without a trade-off. Intune reads `ID` and
`VERSION_ID` and sees supported Ubuntu 26.04. OS/7 reads `IMAGE_VERSION` and
sees its own product. Nothing has to be sacrificed to the other, and the version
number gains a standard, machine-readable home that every Linux tool already
knows how to parse.

Three further places carry the version, all derived from the manifest:

| Where | Form |
|---|---|
| Boot environment name | `os7_1.0.0.0_202608231430` — the scheme SETUP-PLAN §4.4 already pins, with `<release>` now defined |
| GRUB menu entry title | Fixes the L4 complaint that the menu reads "Ubuntu 26.04 LTS": the generator titles from the manifest, not from `PRETTY_NAME` |
| ISO volume / filename | `OS7-1.0.0.0-arm64.iso` |

---

## 4. Update mechanics

### 4.1 Package-in-BE, not image replacement (recommend U1)

Two viable models:

| | **Package-in-BE** (recommended) | **Image replacement** |
|---|---|---|
| How | Clone the BE, `apt full-upgrade` inside it against the pinned snapshot | Ship a squashfs / `zfs send` stream, unpack into a fresh BE |
| Determinism | Same snapshot + same selections → same dpkg state | Bit-identical, by construction |
| Download size | Changed packages only | Whole image, unless `zfs send -i` deltas |
| `/etc` drift | Handled by dpkg conffile logic, which exists and is understood | Must be designed from scratch (the Silverblue problem) |
| GUI/headless split | Falls out naturally — each machine upgrades what it has | Needs one image per mode per arch |
| Reuse from S3 | Partial | High — S3 already unsquashfs-es into a BE |

**Recommendation: package-in-BE for v1.** Image replacement is more elegant on
paper and buys bit-identity, but it pays for it with the `/etc` merge problem and
a matrix of images. Snapshot pinning already delivers the determinism the version
number needs; bit-identity is not worth that cost yet.

Keep image replacement possible behind the same interface, exactly as D1 keeps
ZFSBootMenu possible behind a bootloader strategy. Do not hard-code apt into
`Update-OS7`'s public surface.

### 4.2 The update sequence

Reuses the S3 install sequence almost wholesale — which is the argument for
writing it once, in the OS7 module, and having both Setup and `Update-OS7` call
it (SETUP-PLAN §6.3 already makes this point about Setup):

```
1.  zfs snapshot rpool/ROOT/<cur>@pre-<newver>   and the bpool BOOT dataset
                  AND the rpool/DATA datasets    (the deliberate-rollback net, 4.4)
2.  zfs clone   → rpool/ROOT/os7_<newver>_<stamp>
                  bpool/BOOT/os7_<newver>_<stamp>
3.  ASSEMBLE the clone: mount it, then mount the rpool/DATA datasets into it
    (/var/log, /var/lib/<service>, agent state — 4.4) so apt sees a whole /var,
    then bind /dev /proc /sys and chroot
4.  point sources.list at snapshot.ubuntu.com/<new stamp>
5.  apt update && apt full-upgrade
6.  reassert /etc/os-release  (§2.2 #2), write /usr/lib/os7/release.json
7.  update-initramfs   → carries the TPM2 token hook forward (§2.2 #3, S6)
8.  update-grub        → new BE appears in the menu
9.  set the new BE as default; leave the old one bootable
10. reboot on the operator's schedule
```

Steps 1–2 are the part that has no equivalent in the S3 script and is the real
new work. Everything from 3 onward is S3 code with a different root.

### 4.3 The paired-dataset hazard

A boot environment is **two datasets in two pools**: `rpool/ROOT/os7_<id>` and
`bpool/BOOT/os7_<id>`. They must be cloned together, activated together and
destroyed together. A half-activated pair boots the old kernel against the new
root, or the reverse, and the symptom appears at boot rather than at update time.

This is a direct consequence of D1 (GRUB forces `bpool`) and it does not exist
under ZFSBootMenu. It is not a reason to reopen D1, but it is a reason for the BE
primitives to treat the pair as one object and never expose the halves.

### 4.4 `/var` — DECIDED (U6): split, not placed

SETUP-PLAN §4.4 originally placed `var` and `var/log` **as children of the boot
environment**. For install that is correct and unremarkable. For updates it had a
consequence nobody had written down:

> **A rollback rolls `/var` back with it.**

`rpool/USERDATA` is correctly outside `ROOT`, so user files survive — that plan is
explicit that getting this wrong "cannot be fixed after the fact". But service
state lives in `/var/lib`. Rolling back a bad update on a server would silently
revert a database, a container store, or anything else under `/var/lib/<service>`
to its state at update time. On the headless product — which is the Azure Arc
target, i.e. servers — that is data loss disguised as a safety feature.

**Decided 2026-08-23.** The rule, which is *not* "system versus user data":

> **A path belongs inside the boot environment if, and only if, rolling it back
> makes the system more correct.** State that something outside this machine also
> believes must stay outside, because the other side does not roll back.

| Path | Placement | Why |
|---|---|---|
| `/var/lib/dpkg`, `/var/lib/apt`, `/var/cache` | **in** | The package database describes exactly the `/usr` that rolls with it. Shared, a rollback leaves dpkg claiming `libfoo 2.0` while `/usr` holds `1.0`. Non-negotiable. |
| `/var/log`, `/var/spool`, `/var/tmp` | **out** | Forensics and in-flight work. The log explaining why an update failed must not vanish with the update. |
| `/var/lib/<workload>`, `/srv` | **out** | The workload's data is not the release's property. |
| `/var/lib/snapd` | **out** | `authd-msentraid` is a snap and snapd runs its own revision rollback; a BE rolling over the top is two systems fighting over one directory. |
| **Management-agent state** — `authd`, `microsoft-identity-broker`, `intune-portal`, `azcmagent` | **out** | Entra, Intune and Arc hold the other end of a device identity: enrolment records, self-rotating certificates, compliance state. **The tenant has no rollback.** A machine returning from a rollback with a stale identity or an expired certificate is a tenant problem — worse than a device problem, because it is invisible from the device. |
| `/var/lib/NetworkManager` | **out** | Practical: a rolled-back headless server with no network configuration is a site visit. |

The full table, the `canmount=off` container detail and the boot-path footgun
(`ZFS_INITRD_ADDITIONAL_DATASETS`, now L21) are in the layout itself —
[../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md) §4.4, which this decision
rewrote.

**Two things this forces on the update sequence:**

* Out-of-BE datasets hang under `rpool/DATA`, **not** under `rpool/ROOT/<be>` with
  a do-not-clone property. zsys used a property (`com.ubuntu.zsys:bootfs=no`) and
  zsys is gone; OS/7 writes its own clone logic, and a dataset that is not a child
  of the BE cannot be cloned into the next one by mistake. The hierarchy makes the
  bug unrepresentable rather than merely discouraged.
* **A cloned BE has to be assembled before it is usable** — §4.2 step 3. Mounting
  the clone alone yields a `/var` with holes in it, and `apt` would run against it.

**The honest cost:** a rollback restores the *system*, not the *world*. An update
that migrates an on-disk data format leaves the old release facing new data, and
no layout fixes that — it is what "keep the data" means. The `@pre-<version>`
snapshot in step 1 therefore covers the `rpool/DATA` datasets too, so an operator
*can* roll one back deliberately and individually. Automatically, never.

---

## 5. Drift — the three holes that make the number lie

The version number is a claim about the whole system. Three things can change the
system without going through `Update-OS7`.

| # | Hole | Why it is real | Mitigation |
|---|---|---|---|
| 1 | **`apt` is still there** | Bash is the system shell by locked decision — cron, systemd, dpkg hooks and Intune's own bash-based compliance scripts all need it. Every admin eventually types `apt upgrade`. It cannot be removed and should not be. | Two layers: **apt pinning** so OS/7-managed packages are held, and **detection** — `Get-OS7Version` compares `dpkg --get-selections` against `packages_manifest` and reports `1.0.0.0 (modified)`. A number that lies silently is worse than no number. |
| 2 | **`authd-msentraid` is a snap** | README records this: it is not in the archive, it is a Canonical-verified snap. Snaps refresh themselves on snapd's schedule. The Entra identity component would therefore move independently of the release train — the exact thing hook 0020 rejected the PowerShell snap to avoid. | `snap refresh --hold` on the OS/7-managed snaps; revision recorded in the manifest; bumped deliberately per release. |
| 3 | **`packages.microsoft.com` has no snapshots** | Edge, `intune-portal`, `microsoft-identity-broker`, `azcmagent` and Azure CLI cannot be pinned by URL the way the Ubuntu archive can. | Pin by version + SHA256 in the manifest and verify at build time — the hook 0020 pattern. Accept that a Microsoft component moving upstream is a release event, not a background occurrence. |

---

## 6. The command surface

The goal is that an operator never needs the Linux commands. That holds only if
the surface is complete — a single missing verb sends them back to bash and the
guarantee is gone.

| Cmdlet | Purpose |
|---|---|
| `Get-OS7Version [-Detailed]` | The number; with `-Detailed`, the manifest. **Reports drift** (§5). |
| `Get-OS7Release -Available` | What the channel offers, without applying it. |
| `Update-OS7 [-WhatIf] [-Stage] [-Reboot]` | Build the new BE. `-Stage` prepares without activating; `-WhatIf` is already promised by the stub's help. |
| `Get-OS7BootEnvironment` | List BEs with version, creation date, active/next flags. |
| `Restore-OS7 [-BootEnvironment]` | Roll back. Defaults to the previous BE so the panic path is one word. |
| `Remove-OS7BootEnvironment` | Prune old BEs — otherwise the pool fills, which is how BE systems fail in practice. |
| `Set-OS7UpdateChannel -Channel Stable\|Preview` | Channel selection. |
| `Set-OS7Mode -Mode GUI\|Headless` | Unchanged in scope. |

**This resolves the ambiguity the stub documents about itself.** `Set-OS7Mode`'s
help says it cannot tell whether "mode" means GUI/headless or the release
channel. It means GUI/headless; the channel gets its own verb.

Two properties that are easy to forget and expensive to add later:

* **Unattended operation.** On a managed fleet nobody types `Update-OS7`. It has
  to run from a systemd timer, from Intune, and from Azure Arc — non-interactive,
  exit-code-correct, and logging somewhere both platforms can read.
* **Every cmdlet must work over serial and SSH**, because the arm64 product is
  server-only and may never have a local console.

---

## 7. Security cadence — the cost of pinning, and the way out

Pinning the archive means a CVE fixed in `resolute-security` on the 4th does not
reach machines until the next OS/7 release. For a monthly train, mean exposure is
around two weeks. For an audience that runs Intune compliance and answers to CVE
SLAs, that is a **regression versus plain Ubuntu**, and it will be raised in a
procurement review rather than discovered gently.

This is what the fourth version field is for:

| Channel | Cadence | Content |
|---|---|---|
| `stable` | monthly | Full snapshot roll: `x.y.Z.0` |
| hotfix | out of band | Single-package overlay on the current snapshot, bumping only Build: `x.y.z.N` |

A hotfix is a narrow, pinned exception to the frozen archive — one package, one
hash, still recorded in the manifest, so the state stays describable. Without
this path, pinning is not defensible; with it, OS/7 can claim something plain
Ubuntu cannot, namely that a security patch was applied to a *known* state and is
one command from being rolled back.

**Ubuntu Pro / ESM / Livepatch** interact with all of this and are unexamined.
Pro adds suites that must be snapshot-pinned too; Livepatch changes a running
kernel underneath a version number that claims to describe it. Neither is a
blocker for v1, both need a position before an enterprise deal. Flagged as UL7.

---

## 8. Limitations — the honest list

| # | Limitation | Mitigation |
|---|---|---|
| UL1 | **A Secure Boot policy update breaks TPM2 unlock fleet-wide** (L17, §2.2 #1) | **Characterised 2026-08-23 by S6.** The break is real — PCR 7 moves and the seal stops opening — but it is loud, non-fatal and one command from repaired. The mechanism for recovery is demonstrated; what is *not* built is the escrowed recovery key it needs to run unattended (U8). Until that exists, a policy change means every machine asks a human for a passphrase once. |
| UL2 | A rollback reverts `/var`, including service state, on the server product | **RESOLVED 2026-08-23 by U6 (§4.4).** `/var` is split: package state in, everything a rollback should not un-say out to `rpool/DATA`. **Residual, and unfixable by any layout:** a rollback restores the system, not the world — an update that migrates an on-disk data format leaves the old release facing new data. The `@pre-<version>` snapshot covers `rpool/DATA` so that case is recoverable by hand, never automatically. |
| UL3 | Pinning delays security patches relative to plain Ubuntu (§7) | Out-of-band hotfix channel on the Build field. Non-optional. |
| UL4 | Microsoft components cannot be snapshot-pinned (§5 #3) | Version + SHA256 in the manifest, hook 0020 pattern. Accept that MS moves are release events. |
| UL5 | `apt` remains usable and can silently invalidate the version number (§5 #1) | apt pinning + drift detection in `Get-OS7Version`. |
| UL6 | Canonical publishes no retention guarantee for `snapshot.ubuntu.com`; verified back to 2022 but not contractual | Archive the `.debs` a release actually installs — a few GB per release, not a mirror of the archive. Cheap insurance for the reproducibility claim. |
| UL7 | Ubuntu Pro / ESM / Livepatch unexamined against this model (§7) | Position needed before an enterprise deal; not a v1 blocker. |
| UL8 | A BE pair spans two pools and can half-activate (§4.3) | BE primitives treat the pair as one object; never expose the halves. |
| UL9 | Boot environments accumulate and fill the pool | `Remove-OS7BootEnvironment` plus a retention policy shipped by default, not left to the operator. |
| UL10 | `/etc/os-release` is a conffile of `base-files`; branding it is contested at every upgrade (§2.2 #2) | Idempotent reassert as a step in the update sequence, not a one-time write at install. |
| UL11 | A generation bump depends on Microsoft publishing a matching suite (§2.3) | Cannot be mitigated, only scheduled around. Azure CLI on `noble` is the standing precedent. |

---

## 9. Decisions

| # | Decision | Outcome |
|---|---|---|
| U1 | Update mechanism: package-in-BE or image replacement | **Recommend package-in-BE for v1** (§4.1). Keep image replacement behind the same interface, as D1 does for ZFSBootMenu. |
| U2 | Version scheme | **DECIDED 2026-08-23 — `Major.Minor.Patch.Build`**, Major = Ubuntu LTS generation (§3.3), plus a release manifest as the bill of materials (§3.4). Locked in [../README.md](../README.md). |
| U3 | Where the version lives | **DECIDED 2026-08-23 — `IMAGE_ID` + `IMAGE_VERSION`** in `/etc/os-release`, `ID`/`ID_LIKE`/`VERSION_ID` untouched (§3.5). Follows from U2 having a value to carry, and it is what **closes D8** in [../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md). |
| U4 | Archive pinning | **DECIDED 2026-08-23 — `snapshot.ubuntu.com`**, one timestamp per release (§3.2). Verified available for resolute on both architectures. This is what makes U2's number describe a state rather than label one; without it the two decisions do not hold together. |
| U5 | Release cadence | **Proposed: monthly `stable`**, plus an out-of-band hotfix channel on the Build field (§7). Needs a business decision, not a technical one. |
| U6 | Is `/var` inside the boot environment | **DECIDED 2026-08-23 — split (§4.4).** Package state in; logs, spool, workload data, snapd and management-agent state out to `rpool/DATA`. Deciding rule: a path belongs in the BE only if rolling it back makes the system *more correct* — anything a system outside this machine also believes stays out, because the tenant does not roll back. Rewrote SETUP-PLAN §4.4 and closed its D10. |
| U7 | Does `apt` get pinned against OS/7-managed packages | **Recommend yes**, plus drift detection regardless (§5 #1). |
| U8 | Recovery path for UL1 | **OPEN, but reduced 2026-08-23 by S6.** Recovery works: detect the fallback (the error string is specific, and the token state is queryable), then re-enrol against the new PCR 7 — no reinstall, no initramfs work. **The remaining problem is key escrow**: unattended re-enrolment needs the existing passphrase, so something must hold it. Entra, an OS/7-managed store, or Intune's own escrow. A Microsoft-stack design question, no longer a boot question. |

---

## 10. Plan

### Phase 0 — Spikes. Before any `Update-OS7` code.

Continuing the S-series from SETUP-PLAN Phase 0. Each reuses the S3/S4 QEMU
harness in [../installer/spikes/](../installer/spikes/), which already installs
and boots an arm64 system — the expensive part is built.

| Spike | Question | Method | Done when |
|---|---|---|---|
| **S5** | Does the clone-update-activate-rollback cycle work at all | On a machine Setup installed: snapshot + clone both BE datasets, assemble the clone and change it, `update-initramfs`, activate, reboot; then `Restore-OS7` back | **PASS 2026-08-25 (arm64)** — nine checks, three boots: the machine booted the clone with `/boot` and `/var/lib/dpkg` from the clone and the change present, and came back to the original with the change un-said, both environments still complete. — `installer/testing/run-s5.py`, findings in [SESSION-BOOT-ENVIRONMENTS.md](SESSION-BOOT-ENVIRONMENTS.md). **The method changed in one place and it matters:** the spike as written applies `apt full-upgrade` against a *pinned* snapshot, which is a no-op against the snapshot the machine was built from — so the change applied to the clone is one package it does not have, which makes the two package databases genuinely differ and a rollback something that can be seen to un-say. A new *kernel* in the clone is still untested |
| **S6** | **Does TPM2 auto-unlock survive an update** | Six boots on a copy of the S4 target (disk + variable store + swtpm state): rebuild the initramfs and boot; swap the variable store to change Secure Boot policy and boot; re-enrol and boot again | **PASS 2026-08-23 (arm64).** Survives an initramfs rebuild with PCR 7 byte-identical; a policy change moves PCR 7 and breaks the seal *loudly and recoverably*; one `systemd-cryptenroll` restores it. `installer/spikes/run-s6.py` + `s6-update-cycle.sh`; findings in [SESSION-S6-UPDATE-CYCLE.md](SESSION-S6-UPDATE-CYCLE.md) |
| **S7** | Is the version number true | Build the same release twice from the same snapshot; diff the package manifest | **PASS 2026-08-24 (arm64).** Two builds from `20260824T000000Z` hold identical package sets — 549 packages, manifest `sha256:ffd05e12c9cb3d08…` both times. `installer/spikes/run-s7.py`; findings in [SESSION-RELEASE-IDENTITY.md](SESSION-RELEASE-IDENTITY.md). **The method had to change:** §3.4's `dpkg --get-selections` carries no versions, so two builds holding different kernels compare EQUAL and this spike would have passed without testing anything (BUILD-NOTES #37). The manifest records `package<TAB>version<TAB>arch` |

**S5's method changed in one place, and the change is the finding.** The spike as
written applies `apt full-upgrade` against a pinned snapshot, which against the
snapshot the machine was built from is a no-op — so what the clone gets instead is
one package it does not have, which makes the two package databases genuinely
differ and a rollback something that can be seen to un-say. A new *kernel* in the
clone is still untested, and that is the case where §4.3's paired-dataset hazard
is sharpest.

**Gate: S5 and S7 pass, and S6's failure mode is characterised, before Phase 1.**
**S6 is done** (2026-08-23) and **S7 passed on 2026-08-24**, so the gate on the
version number itself is open: the archive pin holds, and `1.0.0.32` names a
package set rather than a moment. ~~**S5 — does the clone-update-activate-rollback
cycle boot at all — remains**~~ — **S5 PASSED 2026-08-25**, so the gate on
`Update-OS7` is open too; what stands in its way now is the release itself
([CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) C7), not the
mechanism.

Phase 1 was therefore run ahead of S5, deliberately: nothing it does clones a
boot environment, and SETUP-PLAN Phase 3 needed the version number that did not
exist.

### Phase 1 — Release engineering (no runtime code)
**DONE 2026-08-24**, and pulled forward ahead of SETUP-PLAN Phase 3 rather than
run after it: Phase 3 writes `/etc/os-release` (D8), titles the GRUB menu (L4)
and names the boot environment (§4.4), and all three need a version number that
until now did not exist anywhere in the repository.

`build/config/os7-release.conf` is the single pin file; hook 0075 emits
`/usr/lib/os7/release.json` and `packages.manifest` and brands os-release per
§3.5; the version names the ISO and the boot environment. Findings in
[SESSION-RELEASE-IDENTITY.md](SESSION-RELEASE-IDENTITY.md):

* **It takes fourteen mirror flags, not five.** `*_VOLATILE` is Debian's name for
  `-updates`, defaults to the live archive, and is the one covering the suite
  that MOVES. A build with the obvious five is pinned everywhere except where it
  matters. Read `config/bootstrap` back after `lb config`; do not reason about
  which flags live-build derives. BUILD-NOTES #36.
* **Pinning removed a per-architecture special case.** The snapshot service has
  no `archive`/`ports` split — arm64 is under the same `/ubuntu/<stamp>/` path —
  so `auto/config` lost the branch it used to carry, as §3.2 predicted.
* **§3.4's `dpkg --get-selections` cannot detect drift** and §5 depends on it
  doing so: selections carry no versions, so two systems on different kernels
  hash identically. The manifest records `package<TAB>version<TAB>arch`.
  BUILD-NOTES #37.
* **The BUILD field is `git rev-list --count HEAD`**, there being no CI here by
  design. A dirty tree cannot be caught by that, so it is recorded as
  `reproducible: false` and said on the Welcome screen rather than only warned
  about once in a log.
* **`/etc/os-release` is a symlink to `/usr/lib/os-release`**, which is a
  `base-files` conffile — so the branding must be re-asserted after any `apt`
  run (§4.2 step 6), and read back by SOURCING the file, never by scraping it.
  BUILD-NOTES #37.

### Phase 2 — BE primitives in the OS7 module

The paired clone/activate/list/destroy operations (§4.3), written once so
`os7-setup` and `Update-OS7` share them — SETUP-PLAN §6.3 already routes Setup's
ZFS work through PowerShell for exactly this reason.

**DONE 2026-08-25**, and the phase name turned out to be half right:
`Get-`/`New-`/`Set-`/`Remove-OS7BootEnvironment` and `Restore-OS7` are in
`powershell/OS7/OS7.psm1`, but **only the clone half is a ZFS operation**.
Activation is a bootloader operation — OS/7 writes its own GRUB entries, because
`10_linux_zfs` lists exactly one boot environment per machine without `zsys`
([BUILD-NOTES.md](BUILD-NOTES.md) #67); a file on the ESP names whose menu is
read; and `saved_entry` names the entry. Nothing in ZFS decides what boots.
Findings: [SESSION-BOOT-ENVIRONMENTS.md](SESSION-BOOT-ENVIRONMENTS.md).

### Phase 3 — `Update-OS7` / `Restore-OS7`

The §4.2 sequence, `-WhatIf` first. Drift detection in `Get-OS7Version`.

### Phase 4 — Channels, hotfixes, unattended operation

Channel selection, the hotfix overlay path (§7), systemd timer, Intune and Arc
invocation, BE retention policy.

### Phase 5 — Generation upgrade

`26.04 → 28.04` as a supported, rollback-safe operation. Not needed for v1;
designed for from the start so the pin file and manifest do not have to be
rebuilt to accommodate it.

---

## 11. What this changes in the repo

**The documentation rows were applied on 2026-08-23. The code rows were applied
on 2026-08-24** — §10 Phase 1 (release engineering) was pulled forward, ahead of
SETUP-PLAN's Phase 3, because Phase 3 configures the installed system and all
three of the things it has to write there need a version that did not exist:
`/etc/os-release` (D8), the GRUB menu title (L4) and the boot-environment name
(§4.4). See [SESSION-RELEASE-IDENTITY.md](SESSION-RELEASE-IDENTITY.md).

| Where | Change | State |
|---|---|---|
| `../README.md`, "Locked decisions" → Updates | Gains the version scheme (**U2, locked**), the `IMAGE_ID`/`IMAGE_VERSION` identity (**U3, locked**), archive pinning (**U4, locked**) and the cadence model (U5, still a proposal). The one-line "curated release train over ZFS boot environments" is now specified. | **applied** |
| `../README.md`, "Status" table | New row for the update train; the `powershell/OS7/` row points here for the format its stubs say they lack. | **applied** |
| `../README.md`, "Open questions" | U6 (`/var` in the BE) and U8 (TPM2 recovery) added as questions 5 and 6. | **applied** |
| `../installer/SETUP-PLAN.md` §4.4 | **Layout rewritten** — `/var` split per U6/D10, out-of-BE paths moved to `rpool/DATA`, `canmount=off` containers, and the `ZFS_INITRD_ADDITIONAL_DATASETS` footgun recorded as L21. The `<id>` example updated to the four-field version. | **applied** |
| `../installer/SETUP-PLAN.md` §9 | D8 **closed** (`IMAGE_ID`/`IMAGE_VERSION`, `ID`/`VERSION_ID` untouched, §3.5); **D10 opened** for the `/var` question — that plan's counterpart to U6. | **applied** |
| `../installer/SETUP-PLAN.md` §8, L4 | The GRUB generator titles entries from the manifest, fixing the "reads Ubuntu 26.04 LTS" complaint. | **applied** |
| `../installer/SETUP-PLAN.md` §6.3 | The shared BE primitives gain the paired-dataset constraint from §4.3. | **applied** |
| `../powershell/OS7/OS7.psd1` | `ModuleVersion` becomes the OS/7 product version. `FunctionsToExport` grows §6. | **`ModuleVersion` done 2026-08-24** — stamped into the STAGED copy by `build.sh`, never into the source, so the module is not separately versioned and cannot drift from the release. `FunctionsToExport` still pending. |
| `../powershell/OS7/OS7.psm1` | The stubs get their missing on-disk format, transport and ZFS layout. `Set-OS7Mode`'s self-documented ambiguity resolves (§6). | pending. `New-OS7BootEnvironmentName` now finds `/usr/lib/os7/release.json` and no longer falls back to `0.0.0.0` — measured, not assumed. |
| `../build/config/auto/config` | Sources `os7-release.conf` instead of carrying `OS7_DISTRIBUTION` itself. Mirror URLs point at the pinned snapshot — **and the archive/ports split disappears** (§3.2). | **done 2026-08-24.** The split did disappear. It takes **fourteen** mirror flags, not five: the two `*_VOLATILE` ones cover `-updates` and default to the live archive — BUILD-NOTES #36. |
| `../build/config/hooks/0010`, `0020` | Pins move to `os7-release.conf`; both hooks feed the manifest. | **done 2026-08-24.** Key fingerprints and the PowerShell version + hashes are read from the pin file; hook 0075 measures what they produced. |
| New `build/config/hooks/0075-release-identity.hook.chroot` | Writes the branded os-release per §3.5, **and** `release.json` + `packages.manifest`. One hook, because the branded `IMAGE_VERSION` and the manifest's `version` are the same number and two writers are two chances to disagree. | **done 2026-08-24.** Numbered 0075 so it runs BEFORE 0080, which lets `os7-setup --self-test` check the manifest at build time — a missing version fails the ISO build rather than appearing on a booted screen. |
| `../Makefile`, `../.github/workflows/build-iso.yml` | Version and snapshot timestamp become build inputs; ISO artefacts carry the version. | **done 2026-08-24.** `out/OS7-<version>-<arch>.iso` plus its `.release.json` and `.packages.manifest`, with `out/os7-<arch>.iso` kept as a symlink because six harnesses open it by that name. The workflow's `out/*.iso` glob needed no change. |

---

## 12. What was verified, and how

Checked live on **2026-08-23**, not remembered. Everything not in this table is a
decision (§9), a recommendation, or a reading of this repo's own files, and is
marked as such above.

| Claim | Source |
|---|---|
| `snapshot.ubuntu.com` serves `resolute`, `resolute-updates` and `resolute-security` addressed by timestamp | `GET …/ubuntu/20260801T000000Z/dists/{resolute,resolute-updates,resolute-security}/Release` → `200` |
| The timestamp resolves to an instant, not a rounded day | `resolute-updates` Release under the `20260801T000000Z` stamp carries `Date: Fri, 31 Jul 2026 18:53:25 UTC` |
| **arm64 is covered under the same `/ubuntu/` path** — no `ports` split | `Architectures:` lists `arm64`; `…/dists/resolute/main/binary-arm64/Packages.gz` → `200` |
| Snapshots reach back at least four years | `…/ubuntu/20220601T000000Z/dists/jammy/Release` → `200` |
| **`BUILD_ID` is the wrong field**: it identifies the original installation base and does not change during incremental updates | [os-release(5)](https://www.freedesktop.org/software/systemd/man/latest/os-release.html) |
| **`IMAGE_ID` + `IMAGE_VERSION` are the right fields**: for systems built, shipped and updated as consistent images, and named alongside `VERSION_ID` as what changes when the image is replaced | same page |
| `VARIANT` / `VARIANT_ID` are standard fields for edition (`server`, etc.) | same page |
| The Ubuntu root-on-ZFS layout gives `/var/lib`, `/var/log`, `/var/spool`, `/var/lib/docker`, `/var/www`, `/srv` and `/usr/local` **separate datasets**, with `/var` and `/usr` as `canmount=off` containers — the granularity U6's split needs, and the precedent for it | [OpenZFS: Ubuntu 22.04 Root on ZFS](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html) |
| A boot-required directory split into its own dataset must be added to `ZFS_INITRD_ADDITIONAL_DATASETS` in `/etc/default/zfs`; `canmount=off` datasets are exempt — the basis for L21 | same page |
| **PCR 7 is unchanged by an initramfs rebuild**, byte-identical across the rebuild *and* across sessions — the same value S4 measured before it enrolled anything | S6, `installer/spikes/run-s6.py initramfs`; [SESSION-S6-UPDATE-CYCLE.md](SESSION-S6-UPDATE-CYCLE.md) |
| **A Secure Boot policy change moves PCR 7 and the sealed key stops opening**, with `cryptsetup` naming the cause rather than failing silently, and the passphrase path intact | S6, `run-s6.py policy` |
| **Re-enrolment against the new PCR 7 restores auto-unlock using only the existing passphrase** — new keyslot, untouched initramfs | S6, `run-s6.py recover` |

Not verified, and deliberately left as spikes: whether the clone-update cycle
boots (S5), whether TPM2 unlock survives it (S6), and whether two builds from one
snapshot are identical (S7). Canonical publishes no retention guarantee for the
snapshot service — UL6 assumes none.
