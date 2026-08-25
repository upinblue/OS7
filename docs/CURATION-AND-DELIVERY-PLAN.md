# OS/7 — what the product contains, and how a version of it is delivered

**Status: definition, with two of its decisions now built.** C2 (.NET) and §4.2
(the kernel) were implemented on 2026-08-25 and are measured on a shipped
image and a booted machine — §4.1, §4.2, and
[SESSION-BOOT-ENVIRONMENTS.md](SESSION-BOOT-ENVIRONMENTS.md) §6. Everything
else below is still definition only: there is no OS/7 package repository, no
signing key and no release index. §16 lists what it *would* change, with the
rows that have been done marked.

This answers three questions asked on 2026-08-25:

1. Can OS/7 ship fewer packages, the way Azure Linux does, on an Ubuntu base?
2. Can the update train be OS/7's own — the operator installs `OS/7 1.0.1.<build>`
   from PowerShell, and that version carries a known Ubuntu security state, a
   known PowerShell, and OS/7's own userland — cleanly, architecturally?
3. Is an upgrade always possible, including directly from Setup?

Short answers: **yes, but not in the way Azure Linux does it**; **yes, and the
build half is already decided and proven — the delivery half is missing**; and
**yes, but only once OS/7's own components are packages, which today they are
not.**

[RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) remains authoritative
for the version scheme, the update mechanics and `/var`. This document extends
it in one direction it does not cover — *what is in the release, and where the
release comes from* — and corrects one step of its §4.2 (§9 below).

---

## 1. Verdict

| Question | Answer |
|---|---|
| Fewer packages on an Ubuntu base | **Yes — by selection, never by re-cutting packages.** Azure Linux builds every package from source and owns its archive; OS/7 chooses from Ubuntu's. That is a different kind of control, and pretending otherwise would commit OS/7 to becoming a distribution. |
| How much is actually there | **Measured: 2.86 GiB installed, 549 packages** (arm64, server-only, `OS7-1.0.0.46`). Four decisions take it to **1.19 GiB**. §2, §4. **Two of the four are now built** (2026-08-25): −1 089.3 MiB and −36 packages, measured against the shipped manifests of two builds. |
| Does that shrink the package *count* too | **Less than the bytes, but more than predicted.** The same four decisions were expected to remove 58 % of the bytes and 6 % of the packages; the two that were built removed 36 packages rather than the 12 they were costed at, because live-build installs *Recommends* and the kernel meta-package's chain is long (§4.2). Size, count and the kernel's 8544-module surface are three different problems with three different levers, and for a security-curated product it is the last two that govern attack surface and CVE volume. §2.3, §4.5. |
| Is the version scheme sound | **Yes, and it is already decided** (U2/U3/U4) **and proven** — spike S7 built twice from one pin and got identical package sets. The requested `1.0.1.<build>` is field-for-field the scheme already locked. |
| So what is missing | **The delivery half, entirely.** No OS/7 package repository, no signing, no release index, and — the sharpest one — **no OS/7-specific file on a running system belongs to any package**, so no update can reach them. §5, §6. |
| Would `apt full-upgrade` deliver a curated release | **No.** It converges *versions*, not *membership*. A machine installed at 1.0.0 keeps what 1.0.5 dropped, and two differently-shaped systems then report one number. §5. |
| Upgrade from Setup | **Yes, and the attachment point already exists** — screen 1's `R=Repair` (SETUP-PLAN §3), install into a new boot environment beside the current one. It must call the same code as `Update-OS7`, not a second implementation. §10. |

The largest *unknown* here is not technical. It is that decision C8 (§7) puts
OS/7 in the business of building and security-tracking packages Canonical
currently builds. That is a standing operating cost, not a one-off.

---

## 2. What was measured

### 2.1 Method

The shipped manifest of a real build, joined against the archive the build was
pinned to — not against a live archive, and not estimated.

* Input: `out/OS7-1.0.0.46-arm64.packages.manifest` (549 lines, name / version /
  arch), produced by hook 0075 from the image itself.
* Joined against `Packages.gz` for `main`, `restricted`, `universe` and
  `multiverse`, for `resolute`, `resolute-updates` and `resolute-security`, at
  `snapshot.ubuntu.com/ubuntu/20260824T000000Z/` — the exact `OS7_ARCHIVE_SNAPSHOT`
  in [../build/config/os7-release.conf](../build/config/os7-release.conf).
* Fields taken: `Installed-Size`, `Priority`, `Section`, `Source`, and which
  component file the stanza came from.

**548 of 549 resolved. The one that did not is `azure-cli`** — which is the
join confirming itself: `azure-cli` comes from `packages.microsoft.com`, which
is outside the pin by construction (RELEASE-AND-UPDATE-PLAN §5 #3). A join that
resolved everything would have meant the snapshot was not the real source.

Sizes are `Installed-Size` from the archive, i.e. what dpkg records, not
squashfs-compressed bytes on the ISO. The ISO is 2.1 GB; the installed system
these packages describe is 2.86 GiB.

### 2.2 The image as it stands

| | arm64 (`1.0.0.46`) | amd64 (`1.0.0.45`) |
|---|---|---|
| packages | **549** | **1528** |
| installed size | **2.86 GiB** | not measured |
| product | server only | GUI or headless, GNOME + Edge + `intune-portal` |

By priority — the first column is what a Debian-derived system considers
non-negotiable, and it is a small part of the whole:

| Priority | packages | size |
|---|---|---|
| `required` | 77 | 112.5 MiB |
| `important` | 146 | 199.5 MiB |
| `standard` | 122 | 86.6 MiB |
| `optional` | 192 | **2520.7 MiB** |
| `extra` | 11 | 8.5 MiB |

By component: **544 from `main`, 4 from `universe`**, none from `restricted` or
`multiverse`. The four are §7.

The five largest groups:

| Group | packages | size | why it is there |
|---|---|---|---|
| .NET | 10 | **625.5 MiB** | `dotnet-sdk-10.0` in the base package list |
| firmware | 20 | **704.9 MiB** | `linux-image-generic` **Depends** `linux-firmware`, which Depends on all 19 sub-packages |
| kernel headers | 3 | **268.1 MiB** | `linux-generic` **Depends** `linux-headers-generic` |
| llvm / clang | 3 | **216.0 MiB** | `dotnet-sdk-10.0` **Recommends** `dotnet-sdk-aot-10.0` |
| kernel modules + image | 2 | 291.6 MiB | the kernel. Stays. |

**`dotnet-sdk-aot-10.0` is only a *Recommends*, and it shipped.** That is the
measurement proving `APT::Install-Recommends` is on in this build — no flag had
to be read to know it. `ubuntu-standard` says the same thing a second time: all
27 of its `Depends` **and all 22 of its `Recommends`** are in the image.

### 2.3 Size, count and module surface are three different problems

Applying every size decision in §4:

| | today | after |
|---|---|---|
| installed size | 2.86 GiB | **1.19 GiB** (−58 %) |
| packages | 549 | **517** (−6 %) |

Four decisions remove two thirds of the bytes and almost none of the packages,
because the count lives somewhere else entirely: **201 packages in section
`libs`**, 51 Python, 9 Perl, and the 49 packages `ubuntu-standard` drags in
directly.

This matters for the reason the product exists. Bytes are a download and a disk;
**count is attack surface and CVE feed volume**, and a curated OS is sold on the
second. `telnet`, `ftp`, `wget`, `command-not-found` and `plymouth` are each
under a megabyte and each is a line in a vulnerability report.

So the goals need saying separately, because they are not achieved by the same
work — and the third one is not reached by package curation at all:

* **Size** — four decisions, §4.1–§4.3, mostly mechanical.
* **Count** — the `ubuntu-standard` / Recommends layer, §4.4, which is many small
  judgements rather than one big one, and where the risk of removing something a
  running system quietly needs is real.
* **Neither** — the kernel module surface, §4.5. 8544 modules inside one package,
  which no package decision reaches at all.

---

## 3. Curation has three degrees, not one (C1)

The question "do we curate this package" has three answers, and OS/7 should use
all three rather than picking one:

| Degree | Who builds it | What OS/7 controls | Cost |
|---|---|---|---|
| **Pin** | Canonical | *which snapshot* reaches machines | none beyond the pin — this is today |
| **Re-host** | Canonical | *which exact build* reaches machines, and *when* | a signed repo, a copy step, no source work |
| **Rebuild** | **OS/7** | version, patches, CVE response | a build pipeline and a permanent security-tracking duty |

**Re-host is the degree this project is missing, and it is the one that does most
of the work.** It gives full timing control over any package without taking on
the maintenance of it: the `.deb` is byte-identical to Canonical's, it is simply
served from OS/7's repository and moves when OS/7 says so. Rebuild is reserved
for packages where OS/7 genuinely needs to fix something Canonical will not.

**C1 — DECIDED: all three degrees exist, and every curated package is labelled in
the release manifest with the degree that applies to it.** Without the label a
support case cannot tell whether a CVE is OS/7's problem or Canonical's.

---

## 4. What comes out

### 4.1 .NET — SDK out, runtime stays (C2)

**DECIDED 2026-08-25. BUILT AND MEASURED THE SAME DAY** — see
[SESSION-BOOT-ENVIRONMENTS.md](SESSION-BOOT-ENVIRONMENTS.md) §6. Predicted, and
then what the two shipped manifests actually differed by:

| | packages | size | |
|---|---|---|---|
| .NET as shipped before | 10 | 625.5 MiB | |
| llvm/clang pulled by the AOT recommendation | 3 | 216.0 MiB | **not present on arm64** — see below |
| kept: `dotnet-runtime-10.0`, `aspnetcore-runtime-10.0`, host, hostfxr | 4 | 106.1 MiB | as predicted |
| **predicted removal** | **9** | **735.8 MiB** | |
| **measured removal, arm64** | **6** | **519.1 MiB** | `dotnet-sdk-10.0`, `dotnet-sdk-aot-10.0`, both targeting packs, apphost-pack, templates |

**The prediction was 216 MiB too generous HERE, and the 216 MiB was real — it
just belonged to something else.** Two builds, an hour apart, settle it:

* build 1 removed the .NET SDK **including `dotnet-sdk-aot-10.0`**, and
  `libllvm21`, `libclang-cpp21` and `libclang1-21` were **still in the image**.
* build 2 additionally stopped live-build installing `linux-generic` (§4.2), and
  all three left.

So llvm and clang were held by the **kernel** meta-package's Recommends chain —
`linux-generic` Recommends `linux-tools-<abi>-generic` and
`ubuntu-kernel-accessories`, which reach `bpftrace`, which links LLVM — and not
by the .NET AOT recommendation this document attributed them to. **The size was
right and the cause was wrong**, which is only visible because the two removals
were made in separate builds and both manifests were kept. Their 216.0 MiB is
counted under §4.2 below, where it was earned.

Nothing in the image needs the SDK. `os7-setup` is NativeAOT and runs with .NET
deleted (S2, measured); PowerShell 7.6.5 is the self-contained upstream tarball
(hook 0020). The SDK was serving a product intention, not a dependency — and it
brought 216 MiB of llvm and clang with it through a *Recommends* nobody chose.

The runtime stays because the Foundation Framework is a .NET library and set of
services (C3 below), so the product has a first-party consumer for it.

### 4.2 Kernel headers — `linux-generic` → `linux-image-generic` (C3)

`linux-generic` **Depends** `linux-image-generic` *and* `linux-headers-generic`.
Headers exist for DKMS, and OS/7 uses the GA-kernel-matched **prebuilt** ZFS
module by locked decision — it has no DKMS builds to serve.

Measured on the dependency graph of the pinned snapshot:
`linux-image-generic` Depends `linux-image-<abi>-generic`,
`linux-modules-<abi>-generic`, **`linux-main-modules-zfs-<abi>-generic`** and
`linux-firmware`. So the prebuilt ZFS module survives the swap; only the headers
leave.

**−268.1 MiB, −3 packages** predicted. **−570.2 MiB, −30 packages** measured,
and the difference is entirely *Recommends*, which live-build installs:
`linux-generic` Recommends `linux-tools-<abi>-generic` and
`ubuntu-kernel-accessories`, and behind those came `linux-perf`, `bpftool`,
`bpftrace`, `bpfcc-tools`, **`libllvm21` + `libclang-cpp21` + `libclang1-21`
(216.0 MiB — see §4.1)**, `libc6-dev` and the rest of the C development headers,
`hwdata`, `ieee-data`, `python3-netaddr`. The headers themselves were exactly the
predicted 268.1 MiB across four packages rather than three, the fourth being
`linux-headers-7.0.0-30` (`Architecture: all`, 90.3 MiB), which the count of the
`-generic` chain missed.

**Both changes together: 554 → 518 packages, −1 089.3 MiB installed, and the ISO
goes 2 149 740 544 → 1 835 249 664 bytes (−300 MiB compressed).**

**AND THE FIRST ATTEMPT REMOVED NOTHING, with a green build.** Editing this
package list does not change which kernel is installed: in `--mode ubuntu`
live-build derives `LB_LINUX_PACKAGES="linux"` and installs `linux-generic`
beside whatever the lists name. The shipped manifest still carried both
metapackages and all three header packages. The fix is `--linux-packages
"linux-image"` in `build/config/auto/config`, and the reason it was caught at all
is that two manifests were diffed instead of the build being believed —
[BUILD-NOTES.md](BUILD-NOTES.md) #62.

CL9 asked for `check-image.py` plus a boot before this is believed. Both were
done: `check-image.py` now asserts the membership on the artefact
(no `dotnet-sdk*`, no `linux-headers*`, no `linux-generic`,
`linux-main-modules-zfs-*` present), and `run-s5.py boot` asks a machine running
from ZFS with the swapped kernel.

### 4.3 Firmware — the one to be careful with (C4)

20 packages, **704.9 MiB**, the largest single group in the image. And
`linux-image-generic` depends on `linux-firmware` *hard*, which in turn depends
on all 19 sub-packages, so there is no Recommends to switch off: removing any of
them requires an `os7-firmware` package that `Provides: linux-firmware`.

**This is not a size decision and must not be taken as one.** Argument, not
measurement, and it came from the session working on Setup's network screen
(Phase 3b, branch `worktree-setup-network-accounts`):

> Firmware is the only component that cannot be installed after the fact when it
> is missing. No wireless firmware → no wireless → no network → no `apt install`.
> On a wired machine a missing firmware package is an annoyance; on a
> wireless-only machine it is a site visit.

That splits the group cleanly, and the split is the decision:

| Class | Treatment |
|---|---|
| **Network** — `intel-wireless`, `broadcom-wireless`, `marvell-wireless`, `qualcomm-wireless`, `realtek`, `mellanox-spectrum`, `netronome`, `qlogic`, `marvell-prestera`, `misc` | **stays.** Recoverable only by a person standing at the machine. |
| **Graphics and audio** — `nvidia-graphics`, `amd-graphics`, `intel-graphics`, `qualcomm-graphics`, `qualcomm-misc`, `mediatek`, `intel-misc`, `amd-misc`, `firmware-sof-signed` | **candidate for removal**, because a machine without it still boots, still has network, and can be repaired remotely. |

That second class is 396.2 MiB of the 704.9 MiB. On the **arm64 server** product
it is close to free; on the **amd64 GUI** product it is not, and the two
architectures should not get the same answer.

**C4 — DECIDED in shape, OPEN in extent:** firmware is curated per class, never
as one number; network firmware ships unconditionally on both architectures; the
graphics/audio class is decided per architecture with a measurement behind it.
The peer session measured that all 19 sub-packages are present on **both**
images today, which is the same count reached here independently.

### 4.4 `ubuntu-standard` and Recommends — the package *count* (C5)

`ubuntu-standard` contributes **49 packages / 47.0 MiB directly** (27 Depends,
22 Recommends, all present), plus their own dependency tails — which is where
Perl (9 packages, 58.9 MiB) and much of the `libs` section come from.

It is also where the things a hardened image should not have live: `telnet`,
`ftp`, `wget`, `command-not-found`, `plymouth`, `ntfs-3g`, `friendly-recovery`,
`update-manager-core`.

**C5 — PROPOSED, not decided:** replace `ubuntu-standard` with an explicit list
inside `os7-base` (C6), and turn Recommends off for the image build. Neither
half is safe alone — several of those Recommends *are* wanted (`apparmor`,
`openssh-client`, `iptables`, `uuid-runtime`), so a blanket
`--apt-recommends false` without the explicit list would remove things the
product needs. This is the lever that moves the count, and it is the one that
needs a boot behind every removal rather than a table.

**One thing that is not removable, and was checked:** `zfsutils-linux` **Depends
`python3`**. Python is in the image because of ZFS, not by accident. 51 packages,
50.9 MiB, and they stay.

### 4.5 Kernel modules are a third axis, and packages do not reach it

**Measured 2026-08-25 by the Phase 3b session, by reading the squashfs of
`OS7-1.0.0.46-arm64` — not from the package manifest:**

| | |
|---|---|
| kernel modules in the image | **8544** |
| wireless driver modules | **197**, across 20 vendor directories (`ath`, `intel`, `broadcom`, `marvell`, `mediatek`, `ralink`, `realtek`, `ti`, …) |
| `cfg80211.ko.zst`, `mac80211.ko.zst` | present |
| `mac80211_hwsim.ko.zst` | present |

That measurement was taken to check a plausible inference, and it **refuted**
it. The manifest lists `linux-modules-7.0.0-30-generic` and **no
`linux-modules-extra`**, and on older Ubuntu layouts the wireless drivers live in
`-extra`. The obvious reading — this image has wireless firmware and no wireless
drivers — is wrong for this release: the drivers are in `linux-modules`.

**The rule worth keeping is the general one: the package list is not the module
list.** It is the same error class as the `mac80211_hwsim` limit in §15, running
the other way. There, a test proves less than it appears to; here, a package list
is credited with more than it says. Both are answered the same way — ask the
thing itself, which is why this number came out of the squashfs and not out of a
`Depends` field.

**What it means for curation:** 8544 modules are an attack surface that **no
package decision in §4 touches**. `linux-modules` is one package; CL1 applies
exactly here — OS/7 takes it whole or not at all. If the module surface is to be
reduced, the lever is module blacklisting and a trimmed initramfs, which is a
different mechanism with a different failure mode: a wrongly blacklisted module
does not fail at build time, it fails at boot on the one machine that needed it.
Open question 7 (§14).

### 4.6 The floor — what cannot come out

* **`ubuntu-minimal`'s closure**: dpkg, apt, systemd, netplan, sudo, tzdata,
  locales. Below this there is no Ubuntu left to be compatible with.
* **GNOME and Microsoft Edge on amd64 GUI.** Intune requires both for
  enrolment, and Intune's constraints outrank OS/7's preferences (README).
  The amd64 GUI product's 1528 packages have a much higher floor than arm64's.
* **`casper`** on the ISO, and the D3 storage group on the installed system.
* **Ubuntu's package granularity.** Where Canonical ships one large package,
  OS/7 takes it whole or not at all. This is the actual, permanent difference
  from Azure Linux, and no amount of selection closes it.

---

## 5. Membership has to be executable, not descriptive (C6)

RELEASE-AND-UPDATE-PLAN §4.2 step 5 is `apt update && apt full-upgrade`. That
converges every installed package to the version the pinned snapshot holds. It
does **not** converge *which packages are installed*.

The consequence is precise and it defeats §4 entirely:

> A machine installed from 1.0.0 with the .NET SDK still has the .NET SDK under
> 1.0.5, after every update succeeded. The slimming reaches new installations
> only, the fleet splits into two shapes, and both report the same version
> number.

That is the exact failure the version number exists to prevent (§3.1 of the
release plan), arriving through the update path instead of through `apt upgrade`.

**C6 — DECIDED: the release's package set is expressed as OS/7 metapackages, and
those metapackages are the contract.**

```
os7-base      versioned Depends on everything common to the product
os7-server    Depends: os7-base + the headless set
os7-desktop   Depends: os7-base + GNOME + Edge + intune-portal   (amd64 only)
```

Everything else is marked `apt-mark auto`. An update then reads:

```
apt install os7-server=1.0.5.<build>     # pulls in what joined the set
apt autoremove                            # removes what left it
```

Membership becomes something dpkg enforces rather than something a build-time
list described. It is Ubuntu's own pattern (`ubuntu-minimal` / `ubuntu-standard`
/ `ubuntu-desktop-minimal`), which means it is well-trodden by apt and by every
admin who will ever look at it.

**Two things fall out of this for free:**

* **`Set-OS7Mode -Mode GUI|Headless` becomes a metapackage swap** — `apt install
  os7-desktop` / `apt install os7-server`, with `autoremove` doing the removal
  half. Today "headless is a package-removal step" is a sentence in a package
  list with no mechanism under it.
* **Drift detection gets sharper.** `Get-OS7Version` can compare the installed
  set against the metapackage's `Depends` closure, which is a statement about
  *this release*, rather than against a recorded hash, which only says
  "something changed".

---

## 6. The OS/7 repository (C7)

### 6.1 The gap this closes

Checked in the hooks, not assumed:

| Component | Where it lands | Owned by a package? |
|---|---|---|
| PowerShell 7.6.5 | `tar -xzf` → `/opt/microsoft/powershell/7` (hook 0020) | **no** |
| OS7 PowerShell module | `/usr/local/share/powershell/Modules/OS7` (hook 0060) | **no** |
| `os7-setup` + its unit | `/usr/lib/os7-setup/`, `/usr/lib/systemd/system/` (hook 0080) | **no** |
| release manifest | `/usr/lib/os7/release.json` (hook 0075) | **no** |
| console fonts, `/etc/vtrgb` | `includes.chroot` | **no** |
| os-release branding | rewritten in place (hook 0075) | **no — it is `base-files`' conffile** |

**Every OS/7-specific file on a running OS/7 system is unowned by dpkg.** Three
consequences, all of them load-bearing:

1. `Update-OS7` **cannot update any of them.** An apt-based update train reaches
   the Ubuntu half of the product and nothing else. "The user installs OS/7
   1.0.1 from PowerShell" would be true only of Ubuntu's packages.
2. The drift detection in release-plan §5 compares `dpkg --get-selections`, so it
   is **blind to exactly the files that make this OS/7** — replace `os7-setup` or
   the OS7 module and the check still reports clean.
3. The os-release branding has to be re-asserted after every update (UL10),
   because it is a conffile of a package that legitimately owns it.

**C7 — DECIDED: OS/7's own components become `.deb` packages in an OS/7-signed
repository.**

```
os7-release      /usr/lib/os7/release.json, release.conf, the os-release identity
os7-console      the two PSFs, /etc/vtrgb, console-setup defaults
os7-setup        the NativeAOT binary and its systemd unit
os7-powershell   the pinned upstream tarball, repacked - pinned by SHA256 exactly as hook 0020 does today
os7-module       the OS7 PowerShell module
os7-foundation   the Foundation Framework (C3): .NET library + services
os7-base / os7-server / os7-desktop    the metapackages of C6
os7-firmware     if C4 removes a firmware class: Provides: linux-firmware
```

The build hooks do not disappear; they become **package builds**, and the ISO
installs the packages instead of copying files. Every hook that currently writes
into the chroot is a `.deb` waiting to be extracted, and the hooks' existing
verification steps (`--self-test`, the SHA256 checks, hook 0075's write-back
checks) become the package builds' tests.

### 6.2 `os-release` stops being a fight

Once `os7-release` is a real package it can `dpkg-divert` `/usr/lib/os-release`
away from `base-files`. dpkg then knows who owns the identity, the file survives
`base-files` upgrades by mechanism rather than by re-assertion, and
**UL10 closes** — a limitation the current plan mitigates with a step in the
update sequence that has to be remembered forever.

*Unverified:* that diverting `/usr/lib/os-release` is accepted cleanly on Ubuntu
26.04 and that systemd, Intune's `Allowed distributions` rule and
`lsb_release` all still read what they are supposed to. This is cheap to test in
a chroot and must be tested before it is believed.

### 6.3 Signing and trust — the hole nobody has named yet

Ubuntu's packages are signed by Canonical; Microsoft's by Microsoft; **OS/7's by
nobody**, because there are none. The moment C7 exists, OS/7 is a software
supplier and needs the apparatus:

* a signing key that is **not** on the build machine unattended,
* the public key shipped in the image (`/usr/share/keyrings/os7-archive-keyring.gpg`),
  owned by `os7-release`, so the trust anchor updates with the system,
* a documented rotation path — a second key trusted before the first is retired,
  the same shape as the two Microsoft keys hook 0010 already carries for exactly
  this reason,
* **the release descriptor itself signed** (§8), not only the individual packages.
  A signed package set with an unsigned index of *which* set is current lets an
  attacker serve an older, still-validly-signed release. Freshness is a separate
  property from authenticity, and apt's `Valid-Until` is the mechanism.

**C7a — OPEN:** where the key lives and who holds it. Not a technical question,
and not one to answer by accident on the day the first repo is published.

### 6.4 The release index

`Get-OS7Release -Available` currently has nothing to ask. Proposed: one signed
static file per channel, cacheable and mirrorable, with no service behind it:

```json
{
  "channel": "stable",
  "releases": [
    { "version": "1.0.1.412",
      "released": "2026-09-28T00:00:00Z",
      "archive_snapshot": "20260928T000000Z",
      "os7_suite": "os7-1.0",
      "metapackage": { "os7-server": "1.0.1.412", "os7-desktop": "1.0.1.412" },
      "manifest": "https://…/1.0.1.412/release.json",
      "manifest_sha256": "…",
      "migrations": ["1.0.0->1.0.1"],
      "supersedes": "1.0.0.398" }
  ]
}
```

A static tree is deliberate: it can be served from anything, mirrored into an
air-gapped site by copying a directory, and it keeps the "no cloud, no paid
services" constraint from becoming a product dependency.

### 6.5 Offline falls out

UL6 already says a release archives the `.debs` it actually installs, as
insurance against `snapshot.ubuntu.com` retention. Combined with C7, that archive
**is** the offline bundle: an air-gapped customer gets the same release by
copying a directory, with no separate mechanism to build or test.

---

## 7. The four `universe` packages (C8)

Measured, and each one is load-bearing:

| Package | Component | Source package | In `-updates` / `-security`? |
|---|---|---|---|
| `authd` — Entra ID login | universe | `authd` | **yes** — `0.6.1` → `0.6.1ubuntu0.1` in `resolute-security` |
| `tpm2-tools` — TPM2 unlock | universe | `tpm2-tools` | no — release pocket only |
| `zfs-initramfs` — boots the ZFS root | universe | **`zfs-linux`** | no — release pocket only |
| `systemd-zram-generator` — swap (D4) | universe | `rust-zram-generator` | no — release pocket only |

Universe has no Canonical security SLA without Ubuntu Pro. The `authd` row shows
universe is not *unmaintained* — a security update did ship — it is
**unguaranteed**, which is a different and harder thing to put in a customer
contract.

**C8 — DECIDED: these four are carried in the OS/7 repository.** The decision as
taken was "build them ourselves"; the measurement changes what that should mean
per package, because for two of them building costs far more than it buys:

| Package | Degree (C1) | Why |
|---|---|---|
| `zfs-initramfs` | **re-host, do not rebuild** | It comes from **`zfs-linux` 2.4.1-1ubuntu5 — the same source package as `zfsutils-linux`, which is in `main`**. Rebuilding the binary means forking that source, which also produces `zfsutils-linux` and `libzfs7linux`, and those must stay ABI-matched to `linux-main-modules-zfs-*` — a *different* source package (`linux-main-signed`) that moves with **every kernel update**. Rebuilding here means owning a ZFS userland fork in lockstep with Canonical's kernel. Re-hosting gives the timing control without the fork. |
| `authd` | **re-host, and solve the snap** | Canonical develops it and ships security updates for it. Rebuilding buys little — and **it does not close the gap**: the Entra half is `authd-msentraid`, a Canonical-verified **snap** that is not in the archive at all and cannot be rebuilt as a `.deb`. A repo that mirrors `authd` and leaves the broker on snapd's own refresh schedule has curated the half that was already fine. |
| `tpm2-tools` | **rebuild is affordable** | Plain C, one source package, no cross-component coupling. No update since release, and it is on the path that unlocks the disk — a package where OS/7 wanting its own CVE response is defensible. |
| `systemd-zram-generator` | **rebuild is affordable** | Small Rust package, self-contained. |

**C8a — OPEN, and it is the real problem in this row: `authd-msentraid` is a
snap.** DECISIONS open question 4 already records that seeding it into a live-build
image is unsolved, so **no OS/7 build can log in with Entra ID today** — the
headline feature. C7 does not fix this by itself: a snap is not a `.deb`, and
snapd refreshes on its own schedule regardless of the release train (§5 #2 of
the release plan). Three possible positions, none free: hold the snap at a
recorded revision and accept it as a second, snap-shaped supply chain; repackage
the broker as a `.deb` in the OS/7 repo, against Canonical's chosen delivery; or
carry a first-party Entra broker. **This decides whether OS/7's identity story
has one supply chain or two**, and it should be answered before C7 is built,
because it changes what the repository has to be able to hold.

---

## 8. What a release *is* (C9)

The version scheme is unchanged from U2. What C6 and C7 add is that a release
becomes a **closed, signed description** rather than a build output:

| Part | What it fixes |
|---|---|
| `archive_snapshot` | the whole Ubuntu half (U4, already in place) |
| `os7_suite` + metapackage version | OS/7's own half, and **membership** (C6) |
| component pins with SHA256 | PowerShell, Foundation, anything not from an archive |
| `authd_msentraid` snap revision | the snap-shaped supply chain, until C8a resolves it |
| curation degree per package (C1) | who answers a CVE about this package |
| `migrations` | what must run that dpkg cannot express (§9) |
| signature over all of the above | that this is OS/7's release and not a replay |

**C9 — DECIDED: the release descriptor is the product, and the ISO is one way of
materialising it.** An ISO and an updated machine at the same version are the
same system by construction, because both are the same descriptor applied.

---

## 9. What changes in the update sequence (C10)

Against RELEASE-AND-UPDATE-PLAN §4.2, which stays correct in shape. Steps 1–4
and 7–10 are unchanged. Three corrections:

| Step | Was | Becomes |
|---|---|---|
| 5 | `apt update && apt full-upgrade` | point at **both** repos (pinned snapshot + OS/7 suite), then `apt install os7-<mode>=<version>` → `apt full-upgrade` → **`apt autoremove`**. Versions *and* membership. |
| 6 | "reassert `/etc/os-release`, write `release.json`" | **deleted.** `os7-release` owns both (§6.2). A step that must be remembered forever is a defect. |
| 6′ | — | **new: run the release's migrations**, ordered and idempotent, keyed by the version being upgraded *from*. Dataset layout changes, initramfs hook installs, TPM2 re-enrolment after a PCR 7 move (UL1) — none of which dpkg can express, and all of which currently have no home. |

**C10 — DECIDED.** Migrations are declared in the release descriptor, ship in
`os7-release`, and must be idempotent because a rollback followed by a re-update
runs them twice. Re-running a migration is normal operation, not an error path.

---

## 10. Upgrade from Setup, and version skew (C11)

Three separate things get conflated here; they need separate answers.

**a) Setup upgrading an installed machine.** Screen 1's `R=Repair` — import the
existing `rpool`, install into a **new boot environment beside** the current one,
leave `rpool/USERDATA` alone (SETUP-PLAN §3, Phase 6). Setup already reads the
target's manifest through `Release.Load(path)` against
`/target/usr/lib/os7/release.json`, precisely so it can say what it would
replace (SETUP-PLAN §6.7). The mechanism is `Update-OS7`'s, called from a
different front end — **never a second implementation**, which is what SETUP-PLAN
§6.3 and RELEASE-AND-UPDATE-PLAN §4.2 both already argue for.

**b) Setup's medium is older than the current release.** Setup installs **what is
on the medium**, always, and then offers `Update-OS7` on the Complete screen. An
installer that pulls a newer release from the network mid-install has two
versions in flight and a network dependency in the one phase that must work
without one.

**c) How far can a machine jump?** **Any version → any later version within one
Major.** A release is a full snapshot roll plus a metapackage, not a delta, so
`1.0.0 → 1.0.7` is one operation and not seven. The only sequencing is the
migrations (§9), which are keyed by the *from* version and applied in order.

**C11 — DECIDED.** Across a Major (`1.x → 2.x`) this does **not** hold: that is a
generation migration with its own path (§11), and `Update-OS7` must refuse it
rather than attempt it.

---

## 11. Generation `1.x` → `2.x` (C12)

RELEASE-AND-UPDATE-PLAN §2.3 costs this at five pins in five files plus two
external dependencies. C6 and C7 change the shape of that work, in both
directions, and both should be written down before the day arrives:

* **Cheaper:** the pins are already centralised in `os7-release.conf`, and the
  package *set* is now a metapackage whose `Depends` can be diffed between
  generations. "What did the product contain in 1.x that 2.x has no equivalent
  for" becomes a mechanical question with a mechanical answer.
* **More expensive:** every OS/7 package must be rebuilt against the new base,
  and every rebuilt-from-source package (C8) must be re-based onto the new
  Ubuntu source. The four universe packages become four rebuild-and-verify jobs
  per generation, forever.
* **Unchanged:** Microsoft must publish a matching suite, and Intune must be
  re-verified. Neither is OS/7's to schedule.

**C12 — DECIDED: a generation upgrade is a separate, explicit operation, and
`Update-OS7` refuses to cross a Major boundary.** The mechanism can still be a
new boot environment — which makes an OS/7 generation upgrade rollback-safe,
something `do-release-upgrade` is not, and worth saying out loud because it is
the one place where this architecture is straightforwardly better than upstream's.

---

## 12. Limitations — the honest list

| # | Limitation | Mitigation |
|---|---|---|
| CL1 | **OS/7 cannot re-cut Ubuntu's packages.** Where Canonical ships one large binary package, OS/7 takes it whole. This is the permanent difference from Azure Linux and no selection strategy closes it. | Accept and state it. Rebuild (C1) is available where a specific package justifies it, and it is not a general answer. |
| CL2 | **The four size decisions barely move the package count** (§2.3). | The count lever is `ubuntu-standard` and Recommends (C5), which is many small judgements with a boot behind each. |
| CL3 | **Removing firmware can strand a machine with no network** and no way to repair itself remotely (§4.3). | Network firmware never leaves. Graphics/audio decided per architecture, with a measurement. |
| CL4 | **C8 makes OS/7 a package builder.** Rebuilt packages need CVE tracking against upstream forever, and a rebuilt package is one Canonical's security team no longer covers. | Rebuild only where it buys something: `tpm2-tools`, `systemd-zram-generator`. Re-host `authd` and `zfs-initramfs` (§7). |
| CL5 | **`authd-msentraid` is a snap and stays outside every mechanism here** (C8a). Entra login — the headline feature — has no working delivery in any OS/7 build today. | Unresolved. It decides whether the identity story has one supply chain or two, and it blocks the claim that a release describes the whole system. |
| CL6 | **A signing key is a permanent operational responsibility**, and its compromise is worse than any bug this project can ship. | C7a. Key custody answered before the first published repo, not after. |
| CL7 | **A signed package set with an unsigned index permits a replay** of an older, validly-signed release. | Sign the release index; use apt's `Valid-Until`; treat freshness as separate from authenticity (§6.3). |
| CL8 | **Migrations run twice** whenever a rollback is followed by a re-update. | Idempotence is a requirement, not a quality goal (§9). |
| CL10 | **Package curation does not reach the kernel module surface** — 8544 modules ship inside one package (§4.5). | A different mechanism entirely: blacklisting and initramfs trimming, whose failures appear at boot on one machine rather than at build time. Out of scope here; open question 7. |
| ~~CL9~~ | ~~**`linux-image-generic` instead of `linux-generic` is unproven**~~ — **CLOSED 2026-08-25, and it was worse than unproven: the first attempt changed nothing at all** because live-build installs the kernel beside the package lists (BUILD-NOTES #62). Now built, asserted on the artefact by `check-image.py`, and booted by `run-s5.py`. |

---

## 13. Decisions

| # | Decision | Outcome |
|---|---|---|
| C1 | Degrees of curation | **DECIDED — pin / re-host / rebuild**, chosen per package, and the degree is recorded in the manifest (§3). |
| C2 | .NET in the image | **DONE 2026-08-25 — SDK out, runtime stays.** Predicted −735.8 MiB / −9 packages; **built and measured at −519.1 MiB / −6 packages** on arm64, the difference being llvm/clang that were never in this image (§4.1). |
| C3 | Foundation Framework | **DECIDED 2026-08-25 — a .NET library and services**, shipped as `os7-foundation`, framework-dependent against the pinned runtime C2 keeps. Its own version line in the manifest. |
| C4 | Firmware | **DECIDED in shape, OPEN in extent** (§4.3). Network firmware always ships; graphics/audio (396.2 MiB) decided per architecture. |
| C5 | `ubuntu-standard` and Recommends | **PROPOSED, not decided** (§4.4). The lever that moves the package count, and the one that needs a boot behind every removal. |
| C6 | Membership | **DECIDED — OS/7 metapackages are the package contract**, `apt-mark auto` plus `autoremove` do the convergence (§5). |
| C7 | OS/7's own components | **DECIDED 2026-08-25 — `.deb`s in an OS/7-signed repository** (§6). This is what makes "install version 1.0.1 from PowerShell" true of the whole system rather than of Ubuntu's half. |
| C7a | Key custody | **OPEN** (§6.3). |
| C8 | The four universe packages | **DECIDED — carried in the OS/7 repo**, by degree: rebuild `tpm2-tools` and `systemd-zram-generator`; re-host `authd` and `zfs-initramfs`, because rebuilding the latter means forking `zfs-linux` in lockstep with Canonical's kernel (§7). |
| C8a | `authd-msentraid` (snap) | **OPEN, and blocking the completeness of C9** (§7). |
| C9 | What a release is | **DECIDED — a signed descriptor**; the ISO is one materialisation of it (§8). |
| C10 | Update sequence | **DECIDED** — §4.2 step 5 gains `autoremove`, step 6 is deleted, and an idempotent migration step is added (§9). |
| C11 | Upgrade paths | **DECIDED** — Setup's `R=Repair` calls `Update-OS7`'s code; Setup installs what is on the medium; any→latest within a Major (§10). |
| C12 | Generation upgrade | **DECIDED — explicit and separate**; `Update-OS7` refuses to cross a Major (§11). |

---

## 14. Open questions

1. **C7a — where does the signing key live**, and who holds it.
2. **C8a — the `authd-msentraid` snap.** One supply chain or two.
3. **C4's extent** — which graphics/audio firmware leaves which architecture.
4. **U5 (still open from the release plan) — cadence.** Proposed unchanged:
   monthly `stable` plus an out-of-band hotfix on the Build field. C7 makes the
   hotfix path cheap, because a hotfix is a repository with one package in it.
5. **Support window per Major, and boot-environment retention.** Neither is
   defined anywhere. Both are needed before a customer asks.
6. **Ubuntu Pro / ESM / Livepatch** (UL7). C8 reduces the exposure to four
   packages but does not remove the question — Livepatch in particular changes a
   running kernel underneath a version number that claims to describe it.
7. **Is the kernel module surface in scope at all?** 8544 modules (§4.5), one
   package, no apt lever. Reducing it is defensible for a hardened product and
   its failure mode is a machine that does not boot. Not a v1 question, but it
   should be answered deliberately rather than by never asking.

---

## 15. What was *not* measured

Stated so nobody reads a number here as covering more than it does.

* **amd64 was not measured at all** beyond its package count (1528, from
  [SESSION-AMD64-FIRST-ISO.md](SESSION-AMD64-FIRST-ISO.md)). Every size figure in
  this document is arm64, server-only. The GUI product's floor is higher and its
  ratios will differ.
* **No build was run and nothing was booted.** Every removal in §4 is a
  dependency-graph result. C3's swap in particular is measured on `Depends`
  fields and nowhere else (CL9).
* **Compressed size was not measured.** `Installed-Size` is what dpkg records,
  not what the squashfs holds. The ISO/download effect of §4 is unknown.
* **The dependency *closure* of `ubuntu-standard` was not computed** — only its
  49 direct Depends and Recommends. The tail is where the package count lives,
  and it is larger than 49 by an unmeasured amount.
* **Nothing about firmware coverage was measured**, on either architecture. The
  peer session's wireless test uses `mac80211_hwsim`, a kernel module that
  simulates the hardware layer away and loads no firmware — so it proves Setup's
  scan and association path works and proves **nothing** about whether a real
  wireless chip comes up in this image. That session flagged this itself, against
  its own interest. The 197 wireless drivers measured in §4.5 do not change that:
  they are a statement about what the image contains, not about a chip that ever
  came up. Both are measurements; neither is a field test.

Reproducing §2: the join script is in this session's scratchpad
(`measure-pkgs.py`). It is not in the repo; if these numbers are going to be
checked again after a package-list change, it belongs in `installer/testing/`
next to `check-image.py`, which is the tool it complements — `check-image.py`
asks a built ISO what it *is*, this asks what it *costs*.

---

## 16. What this would change in the repo — no edits made

| File | Change |
|---|---|
| [../README.md](../README.md) | "Microsoft technology scope": .NET **SDK**/Runtime → **Runtime** (C2). Locked decisions: the update train gains the OS/7 repository and the metapackage contract (C6, C7). Open questions: add C7a, C8a. |
| [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) | §4.2 steps 5, 6 and 6′ (C10). §5 gains a fourth drift hole: OS/7's own unowned files, until C7. §8: UL10 closes via §6.2; add the signing and index limitations (CL6, CL7). §9: reference C1–C12. |
| [../build/config/os7-release.conf](../build/config/os7-release.conf) | Gains the OS/7 suite name and the repository base URL — the same "nothing else in the repo may carry a version number or an archive URL" rule, extended to OS/7's own archive. |
| [../build/config/package-lists/os7-base.list.chroot](../build/config/package-lists/os7-base.list.chroot) | **DONE 2026-08-25.** `dotnet-sdk-10.0` → `dotnet-runtime-10.0` + `aspnetcore-runtime-10.0` (C2); `linux-generic` → `linux-image-generic` (§4.2) — though the kernel half needed `--linux-packages` in `auto/config` as well, because this file never decided it (BUILD-NOTES #62). Eventually the whole file becomes `os7-base`'s `Depends` (C6). |
| [../build/config/auto/config](../build/config/auto/config) | **DONE 2026-08-25.** `--linux-packages "linux-image"`, without which §4.2 is inert. |
| [../installer/testing/check-image.py](../installer/testing/check-image.py) | **DONE 2026-08-25.** Asserts the C2 and §4.2 membership on the shipped manifest, so neither can quietly come back. |
| `build/config/auto/config` | `--apt-recommends false` once C5's explicit list exists, and not before. |
| `build/config/hooks/0020, 0060, 0075, 0080` | Become package builds rather than chroot writers (C7). Their existing verification steps become the packages' tests. |
| [../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md) | Phase 6 (`R=Repair`) gains C11's three answers. **Owned by another session — not to be edited without asking.** |
| `powershell/OS7/OS7.psm1` | `Get-OS7Release -Available` reads the signed index (§6.4); `Update-OS7` gains the metapackage and migration steps (C10). |
| `installer/testing/` | A home for the §2 join script, next to `check-image.py`. |
