# OS/7 — the product identity: what the machine calls itself, and to whom

**Status: plan. Three measurements, ten decisions, nothing implemented.**

**Date: 2026-08-26.** The question asked:

> OS/7 should identify itself as OS/7 everywhere a person can see it, without
> breaking compatibility with anything that expects Ubuntu — Intune above all.
> In the background it may call itself Ubuntu wherever it has to. And the
> version a person sees should be three fields, `1.x.x`; the build number only
> when they ask for it.

Short answer: **yes**, and the way to get there turned out not to be "brand more
fields in `/etc/os-release`". Two Microsoft components read that file, **they
read different fields**, and one of them already refuses to run on the image
this repo ships today. The identity has to stop depending on that file.

This document is the authority for the product identity and for the friendly
version. [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §3 stays the
authority for the *number* — what its fields mean and why the archive is pinned.
This is where the number is *shown*.

---

## 1. Verdict

| Question | Answer |
|---|---|
| Can OS/7 show its own name everywhere a person looks | **Yes**, and only one of those places is inside `/etc/os-release` |
| Can `ID=ubuntu` stay for Intune | **Yes**, unchanged — and it was never the field at risk |
| Is branding `NAME` safe | **No, measured.** Microsoft's own Arc onboarding script reads `NAME`, matches `*buntu*`, and exits 133 on anything else. Hook 0075 brands `NAME` today |
| Is branding `PRETTY_NAME` safe | **Unproven, and it is the one branded field that stays provisional.** `intune-agent` reads it. Whether it reaches a compliance decision cannot be measured without a tenant |
| A friendly `1.x.x` | **Yes.** It is a *display rule*, not a second version number |
| `uname -a` for the build number | **Wrong instrument.** It reports the kernel, and cannot be branded without building one |

---

## 2. Three layers, and which one a reader is in

Everything below follows from separating three audiences that have been treated
as one:

| Layer | Who reads it | Rule |
|---|---|---|
| **Product** | a person: console, boot menu, shell, installer, desktop | says **OS/7**, always, with the friendly version |
| **Compatibility** | somebody else's software: `azcmagent`, `intune-agent`, `apt`, `lsb_release`, `uname` | says **Ubuntu 26.04**, untouched, and that is a feature |
| **Machine-readable OS/7** | OS/7's own code: `Update-OS7`, drift, boot environments, support | `/usr/lib/os7/release.json` and `IMAGE_ID`/`IMAGE_VERSION`, four fields, exact |

`/etc/os-release` is the only file that contains all three layers at once, which
is exactly why it keeps being the place things go wrong.

---

## 3. What was measured, 2026-08-26

Three measurements. Two of them are readings of Microsoft's own code, taken
because [../CLAUDE.md](../CLAUDE.md) requires that anything touching OS identity
is checked against Microsoft's live material first — and because the alternative
was to keep asserting that `ID` is the field that matters.

### 3.1 The Arc onboarding script reads `NAME`, not `ID`

[BUILD-NOTES.md](BUILD-NOTES.md) #80.
`https://aka.ms/azcmagent`, downloaded 2026-08-26. 1014 lines,
`sha256 4a8ecb57997d12ed9f2c5fb9c0370e60c92e8a980e6092b47d562b073643682b`.

```sh
370  elif [ -f /etc/os-release ]; then
372      distro=$(grep ^NAME /etc/os-release | awk -F"=" '{ print $2 }' | tr -d '"')
373      distro_version=$(grep VERSION_ID /etc/os-release | awk -F"=" '{ print $2 }' | tr -d '"')
...
597      *buntu*)
...
748      *)
749          exit_failure 133 "$0: unsupported Linux distribution: ${distro}:..."
```

With the `NAME="OS/7"` that hook 0075 writes today, `distro` is `OS/7`, no case
arm matches, and the script exits 133. **`ID=ubuntu` is never read.** The whole
D8 argument — brand `NAME`, protect `ID` — was aimed at the wrong field for this
consumer.

Two things that keep this from being larger than it is, both worth stating
because either one alone would mislead:

* **OS/7 does not use this script.** Hook 0040 caches the `azcmagent` `.deb`
  from the pinned Microsoft repository and Phase 3 installs it. What breaks is
  the path Microsoft's documentation tells an administrator to take.
* **The script rejects 26.04 anyway today.** Its Ubuntu arm stops at
  `-eq 24`, so `distro_major_version=26` falls through to the same
  `exit_failure 133`. One of those two failures is Microsoft's to fix and one is
  ours. **Do not read a future green Arc install as evidence that `NAME` was
  fine** — fixing their half would expose ours.

### 3.2 `intune-agent` reads `PRETTY_NAME` — and `ID`, and `VERSION_ID`

`intune-portal_1.2607.4-resolute_amd64.deb` from
`packages.microsoft.com/ubuntu/26.04/prod`, which is the exact version the
amd64 image already ships (`out/OS7-1.0.0.95-amd64.release.json`).
`sha256 5978332c7eee9af07be686f34c6616f84677784d73c5d20934534a71a358d38b`,
verified against the repository's own `Packages` index before unpacking.

Strings in `/opt/microsoft/intune/bin/intune-agent` (11 MB) and
`intune-portal` (11.6 MB) — `intune-daemon` and `pam_intune.so` contain none of
this:

```
/proc/version
/etc/os-release
.*VERSION="(.*)".*
.*VERSION_ID="(.*)".*
.*ID=(.*)[
/etc/machine-id
```

```
Failed to open os-release file: %s
tryReadPrettyName
PRETTY_NAME=
PRETTY_NAME not found in os-release file: %s
```

```
/proc/sys/kernel/osrelease
wsl2
/usr/lib/os-release
Linux distribution version not found in /etc/os-release or /usr/lib/os-release files.
GetDistributionVersion
```

and, in the Rust half, the serialised field names sent to the service —
`Manufacturer`, **`OSDistribution`**, **`OSVersion`** — beside a path table
reading `/proc/mounts` `/etc/os-release` `/usr/lib/os-release`
`/proc/sys/kernel/hostname` `/sys/class/dmi/id/product_name`
`/sys/class/dmi/id/sys_vendor`, and the adjacent literal pair `ID` `VERSION_ID`.

Three conclusions, and one non-conclusion:

* **There is no hardcoded distribution allowlist in the agent.** The only
  `ubuntu` literals in the whole binary are `/run/mnt/ubuntu-seed` and
  `/run/mnt/ubuntu-boot`, and they sit inside the *encryption* check next to
  `/boot` — an Ubuntu Core path exemption, nothing to do with identity.
  The agent reports `OSDistribution`/`OSVersion` upward and **the service
  decides**. So "Allowed distributions" cannot be satisfied or broken locally;
  it is decided by what the agent sends.
* **`PRETTY_NAME` is read.** `tryReadPrettyName` is in the C++ OneAuth layer,
  where the neighbouring strings are HTTP and token handling — which reads like
  telemetry or a user-agent rather than compliance.
* **`ID` and `VERSION_ID` are read**, which is consistent with
  `OSDistribution`/`OSVersion` and with Microsoft's documented wording
  ("distribution type", "minimum and maximum OS version").
* **What this does not prove:** which of those fields actually becomes
  `OSDistribution`. Strings in a binary say what it *can* read, not what it
  sends. The only instrument that answers it is an enrolment — see §10, IL2.

### 3.3 Microsoft's documentation does not name a field

[Linux device compliance settings](https://learn.microsoft.com/en-us/intune/device-security/compliance/ref-linux-settings)
(fetched 2026-08-26) describes *Allowed distributions* only as "a maximum and
minimum OS version for a Linux distribution type", and
[the Linux deployment guide](https://learn.microsoft.com/en-us/intune/fundamentals/platform-guide-linux)
lists Ubuntu 24.04/26.04 LTS and RHEL 9/10. Neither names an `/etc/os-release`
field.

That absence is itself a design input: **when the contract is not documented,
the safe move is to change as few identity fields as possible**, not to change
every field the current documentation happens not to mention. §4 follows that.

---

## 4. `/etc/os-release`, field by field

Replaces the table in [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md)
§3.5. One row changes value (`NAME`); several rows change *status* from
"untouched by omission" to "untouched by decision".

| Field | Value | Why |
|---|---|---|
| `ID` | `ubuntu` | **untouched.** Compliance layer. Read by `intune-agent` |
| `ID_LIKE` | `debian` | **untouched.** Note it is `debian`, not `ubuntu`: the release plan's §3.5 example said `ubuntu` for two days and the file on disk was right all along (BUILD-NOTES #37). Do not "fix" the file to match an example |
| `VERSION_ID` | `"26.04"` | **untouched.** Read by both agents *and* by the Arc script |
| `VERSION` | `26.04 LTS (Resolute Raccoon)` | **untouched.** Read by `intune-agent`'s `.*VERSION="(.*)".*`. Never previously named as protected |
| `VERSION_CODENAME` | `resolute` | **untouched.** Same reasoning, zero cost |
| `UBUNTU_CODENAME` | `resolute` | **untouched.** Not in the original list; added when a container run showed it sitting in the file unprotected |
| `NAME` | `Ubuntu` | **NO LONGER WRITTEN AT ALL**, where it used to be branded `OS/7`. §3.1, I2. The hook does not set it to `Ubuntu` either — it is Ubuntu's field and OS/7 leaves it alone — and the read-back asserts the **glob** `*buntu*` rather than the literal, because the glob is what Arc's script actually matches and a literal check would be checking the wrong thing |
| `PRETTY_NAME` | `OS/7 1.0.0` | branded, **provisional**. §3.2, I3 |
| `IMAGE_ID` | `os7` | the product identity, machine-readable |
| `IMAGE_VERSION` | `1.0.0.95` | **four fields.** This identifies; it does not describe. I6 |
| `VARIANT` / `VARIANT_ID` | `Server`/`server`, `GUI`/`gui` | unchanged; the installer rewrites it for the target |
| `HOME_URL` | OS/7 | branded |
| `SUPPORT_URL`, `BUG_REPORT_URL`, `DOCUMENTATION_URL` | OS/7 | **new.** Free, and they are where a person goes when the product misbehaves. Leaving Ubuntu's is worse than leaving them unset — it sends OS/7 bugs to Canonical |
| `PRIVACY_POLICY_URL` | removed, or OS/7's | Ubuntu's is not OS/7's policy |
| `LOGO` | `os7` | for the amd64 desktop, once an icon exists |
| `ANSI_COLOR` | the brand blue | cosmetic; used by `hostnamectl` and by fetch tools |

And **`/etc/lsb-release` is untouched, entirely.** `DISTRIB_ID=Ubuntu`,
`DISTRIB_DESCRIPTION="Ubuntu 26.04 LTS"`. It is the third fallback in the Arc
script (`lsb_release -i`), it is what Ubuntu's own MOTD header reads, and every
consumer of it is in the compatibility layer. OS/7's MOTD stops *reading* it
(§6.1) rather than OS/7 rewriting it.

---

## 5. The friendly version

### 5.1 The rule

There is **one** version number — `MAJOR.MINOR.PATCH.BUILD`, defined by
[RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §3.3 and pinned in
[../build/config/os7-release.conf](../build/config/os7-release.conf). "Friendly"
is not a second number and is never stored anywhere. It is a **display rule**,
and the rule is one question:

> **Does this number identify a thing, or describe one?**

*Identify* — two builds must be told apart, a filename or a dataset name must be
unique, a support case must be answerable — **four fields**.
*Describe* — a person is being told what they are looking at — **three**, plus
the channel in brackets while it is not `stable`.

### 5.2 Where each form goes

There is **one** rendering of each form and everything that shows a version uses
it. `PRETTY_NAME`, `/etc/issue` and the MOTD header all carry the identical
string — `OS/7 1.0.0 (development)` — because they are the same sentence in
three places, and three formatters would be three chances to disagree.

| Surface | Form | |
|---|---|---|
| `PRETTY_NAME`, `/etc/issue`, MOTD header, `/usr/lib/os7/product` | `OS/7 1.0.0 (development)` | describes |
| `/etc/issue.net` | `OS/7` | describes — and **no version at all**: it is shown before authentication |
| `hostnamectl`, GNOME *About* | via `PRETTY_NAME` | describes |
| PowerShell login banner | `OS/7 1.0.0 (development)` | describes |
| Setup title row, every screen | `Version 1.0.0 (development)` | describes |
| GRUB, the running system's entry | `OS/7 1.0.0` | describes |
| `Get-OS7Version`, default view | `OS/7 1.0.0 (development)` | describes |
| | | |
| `IMAGE_VERSION` | `1.0.0.95` | identifies |
| `/usr/lib/os7/release.json` | `1.0.0.95` | identifies |
| Boot-environment dataset name | `os7_1.0.0.95_202608251935` | identifies — must be unique |
| **GRUB boot-environment menu** | `OS/7 1.0.0.95 — os7_1.0.0.95_…` | identifies — **two environments would otherwise read identically**, and this menu exists to choose between them |
| **Setup screen 4**, existing install | `vdb already carries OS/7 1.0.0.95` | identifies — the number decides whether to erase it |
| Setup Welcome screen | version, channel, archive snapshot, clean-tree warning | the screen somebody photographs for a ticket |
| `os7-setup --version` | full | explicit query |
| `Get-OS7Version -Detailed` | full, plus the bill of materials | explicit query |
| ISO filename and volume label | `OS7-1.0.0.95-arm64` | identifies — must be unique |

### 5.3 The honest cost

`1.0.0` is **not unique across builds**, by design. Today `MINOR` and `PATCH`
never move, so every development build displays the same three fields. That is
the Windows model exactly — "Windows 11 24H2" identifies nothing either, and
`26100.2033` does — and it is survivable for two reasons: the channel tag
`(development)` is printed beside it until a release is `stable`, and the fourth
field is one command away in every context where somebody could care.

Once the product ships, `PATCH` moves with the monthly maintenance train (§3.3),
so `1.0.0` / `1.0.1` / `1.0.2` do distinguish releases. The degenerate case is
development, and it is loudly labelled as such.

---

## 6. The surfaces, one at a time

Ordered by how many people see them.

### 6.1 MOTD — the first thing an administrator ever sees

Today, over SSH: `Welcome to Ubuntu 26.04 LTS (GNU/Linux 7.0.0-30-generic …)`,
composed by `base-files`' `/etc/update-motd.d/00-header` out of
`/etc/lsb-release`, followed by Ubuntu documentation links and — depending on
what the package lists pulled in — `50-motd-news`, which **makes a network
request to `motd.ubuntu.com` at login**, and Ubuntu Pro / ESM announcements.

For a Microsoft-administered corporate fleet the news fetch is a privacy and
latency problem before it is a branding one.

The plan:

* ship `/etc/update-motd.d/00-os7-header`, which reads
  `/usr/lib/os7/release.json` — **not** `/etc/lsb-release`, and not
  `PRETTY_NAME` (I1) — and prints the product, the friendly version, the
  channel, the boot environment and the kernel;
* **disable** Ubuntu's drop-ins rather than delete them: `chmod -x`, which is
  what `run-parts` honours, plus `ENABLED=0` in `/etc/default/motd-news` where
  that file exists. Deleting a file a package owns means `dpkg` restores it on
  the next `apt` run, and nothing reports that;
* read back which drop-ins are executable, in `check-image.py`.

**Measure before writing.** Which of those drop-ins the pinned image actually
contains has not been checked; the arm64 server list may already exclude the Pro
tooling. The mechanism above is correct either way, but the file list is a claim
and belongs in `check-image.py`, not in this document.

### 6.2 `/etc/issue` and `/etc/issue.net` — the login prompt

`Ubuntu 26.04 LTS \n \l` today. Becomes `OS/7 1.0.0 (development) \n \l`,
written from the manifest by the same function that writes `os-release` and
re-asserted with it (IL6).

`issue.net` is the pre-authentication SSH banner and is a *deliberately*
different decision: it is shown to whoever connects, including whoever should
not, so it names the product and nothing else — no version, no channel, no
kernel.

### 6.3 `/etc/legal` — a licence question wearing a branding costume

Ubuntu's text states that the included programs are free software and that the
system comes with no warranty. Most of that software is still Ubuntu's, under
Ubuntu's licences. Rewriting it is not a find-and-replace: it has to keep saying
the true thing about the same software while naming OS/7 as the distributor, and
it should carry the same kind of licence pointer the console font already needs
(SETUP-PLAN L29).

**Flagged as a licence review, not a branding task**, and left alone until it
gets one.

### 6.4 The boot — including the one screen every user sees every day

* **GRUB, the running system.** `GRUB_DISTRIBUTOR="OS/7"` is already written by
  `SystemSteps`. One thing to read back rather than assume: `grub-mkconfig`
  derives a CSS class from `GRUB_DISTRIBUTOR` by lowercasing its first word, so
  the `/` in `OS/7` ends up inside a class name. OS/7's own generator already
  passes `--class os_7` explicitly; the stock generator's output has never been
  looked at with this in mind.
* **The boot-environment menu** keeps four fields (§5.2). It is the one
  human-facing surface where the build number *is* the information.
* **The LUKS passphrase prompt is the real prize.** Every OS/7 machine asks for
  it at every boot, which makes it the most-seen screen the product has. On a
  text console its wording comes from the crypttab target name — so *naming the
  device* brands the prompt, at zero cost. Under Plymouth it is themed.
* **Plymouth** is worth doing for the amd64 GUI product and close to pointless
  for arm64 server: `GRUB_CMDLINE_LINUX_DEFAULT=""` carries no `splash`, so no
  theme is displayed at all. Sequence the theme behind the crypttab naming,
  which is a tenth of the work and helps both products.

### 6.5 PowerShell — the shell this product exists for

`pwsh` is started with `-NoLogo` by `/etc/profile.d/95-os7-powershell.sh`, so a
session begins with no identification of any kind. Add:

* a two-line banner — product, friendly version, channel, and **the boot
  environment**, because on a rollback-capable machine "which one am I in" is a
  question the login should not require a cmdlet to answer;
* a prompt function that matches the product rather than PowerShell's default;
* `Get-OS7Version` (§7).

Two traps, both of which have to be designed around rather than discovered:

* **A profile that writes to stdout corrupts every `pwsh -c` pipeline that
  forgets `-NoProfile`.** The banner must be guarded on an interactive host, and
  `OS7_NO_BANNER` must turn it off — for the same reason `OS7_NO_PWSH` exists.
* **`$PSHOME/profile.ps1` lives inside the PowerShell tree**, which hook 0020
  unpacks from the pinned tarball — so it is destroyed by a PowerShell upgrade.
  Survivable only because PowerShell comes from the pin and moving it is a
  release event that re-runs the hook. It still has to be written down, because
  the failure is silent and reads as "the banner stopped working".

### 6.6 The installer

Already branded on every screen. What changes is only the formatter:
`Release.Short` becomes three fields, a new `Release.Full` keeps four, and the
call sites in §5.2 pick one. `run-phase1.py` needs no new expected string — it
composes one from the shipped manifest by applying the same rule, so it fails if
the two implementations ever disagree, which is the point.

### 6.7 The desktop (amd64)

Out of scope for this round. `LOGO=os7` plus an icon is most of it; GDM branding
is not. It is also unmeasurable today — no amd64 machine has ever been installed.

---

## 7. `Get-OS7Version`

The cmdlet [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §6 promises
and nothing implements. It reads `/usr/lib/os7/release.json` — the same file
`New-OS7BootEnvironmentName` and `os7-setup` read, so the three cannot disagree.

```
PS /> Get-OS7Version

OS/7 1.0.0 (development)
Ubuntu 26.04 base, Server, arm64

PS /> Get-OS7Version | Format-List

ProductName  : OS/7
Version      : 1.0.0
Build        : 95
FullVersion  : 1.0.0.95
Channel      : development
Edition      : Server
Architecture : arm64
BaseRelease  : 26.04
Built        : 25.08.2026 19:35:22
Reproducible : False
Drift        :
```

Shape decisions, each for a reason:

* **`Version` and `FullVersion` are `[version]`, not strings**, so
  `(Get-OS7Version).Version -ge [version]'1.1.0'` works. That is what an
  administrator will try first, and it should not need a string parse.
* **`[version]` calls its own third field `Build`.** So `FullVersion.Build` is
  OS/7's *PATCH* and `FullVersion.Revision` is OS/7's *BUILD*. The object exposes
  `Build` as a plain `[int]` holding OS/7's meaning; the collision is real, it
  cannot be removed, and it is written down here so the next reader does not
  find it inside a comparison that silently succeeds. (IL3)
* **`Drift` starts empty, never `$false`.** Drift detection means hashing
  `dpkg-query` output over ~550 packages against `packages_manifest`, which is
  seconds rather than milliseconds — so it happens only under `-CheckDrift`.
  Reporting "no drift" for a check that did not run is precisely the failure
  [BUILD-NOTES.md](BUILD-NOTES.md) records over and over. Empty means *not
  asked*; it never means *clean*.
* **No manifest gives `unknown`, not a plausible number** — the same choice
  `Model/Release.cs` already makes with `Release.Unknown`.
* **`-Path` reads another root's manifest**, so one cmdlet answers both "what is
  this machine" and "what is on that disk".
* **A format file** (`OS7.format.ps1xml`) provides the default view. The `Zfs`
  module already ships one; `OS7` ships none yet, and this is the cmdlet that
  needs one first.

---

## 8. `uname`, and why it is not on the list

`uname` reports the **kernel**, not the product:

```
Linux os7-lab 7.0.0-30-generic #30-Ubuntu SMP … aarch64 aarch64 aarch64 GNU/Linux
      ^hostname ^uname -r       ^uname -v                             ^uname -o
```

`uname -r` and `uname -v` are compiled into the kernel image;
`/proc/sys/kernel/osrelease` and `/proc/sys/kernel/version` are mode `0444`; and
the UTS namespace permits changing only the hostname and the domain name.
Putting "OS/7" there means building the kernel — which discards the archive pin,
the Secure Boot signature against the Microsoft UEFI CA, the prebuilt ZFS
modules and every supportability claim toward Intune and Arc, in exchange for a
string.

So `uname` stays in the compatibility layer, and it stays truthful: this *is* an
Ubuntu kernel. The Linux-native home for a product version is `/etc/os-release`,
which is what D8 already decided. The command that answers "which OS/7 is this,
exactly" is `Get-OS7Version`.

---

## 9. Decisions

| | | |
|---|---|---|
| **I1** | **The brand never depends on a single `/etc/os-release` field.** Every user-facing surface takes its text from `/usr/lib/os7/release.json` | Measured (§3): two Microsoft components read *different* fields of that file and one already breaks. If a field has to be given back, only that field's own consumer loses the brand — the MOTD, the boot menu, the shell, the installer and the prompt are unaffected. This is the decision the other nine hang off |
| **I2** | **`NAME="Ubuntu"`** — changed back from `OS/7` | §3.1. The Arc onboarding script reads `NAME` and exits 133 on anything without `buntu` in it. CLAUDE.md makes Microsoft's constraints outrank OS/7's preferences where the two collide, and here they collide |
| **I3** | **`PRETTY_NAME="OS/7 <friendly>"`, provisional** | §3.2. `intune-agent` reads it. The evidence reads as telemetry rather than compliance, but strings in a binary say what a program *can* read, not what it sends. Phase E checks it against a tenant; if it fails, this reverts and I1 means nothing else moves |
| **I4** | `ID`, `ID_LIKE`, `VERSION_ID`, **`VERSION`**, **`VERSION_CODENAME`** and **`/etc/lsb-release`** are untouched | D8 protected the first three. The last three are added because §3.3 found the contract undocumented, and the cost of leaving a field alone is zero |
| **I5** | The friendly version is a **display rule**, not a stored value | One number exists. Storing a second is how two numbers start disagreeing, which is what release plan §3.1 is entirely about |
| **I6** | Four fields wherever the number **identifies**; three wherever it **describes** | §5.1. The boundary is a question with an answer, not a matter of taste |
| **I7** | `Get-OS7Version` never reports "no drift" when it did not look | `Drift` is empty until `-CheckDrift`. A check that cannot distinguish absence of evidence from evidence of absence will eventually report the first as the second |
| **I8** | `uname` is **not** branded, and that is a decision rather than an omission | §8 |
| **I9** | MOTD: OS/7 writes its own header; Ubuntu's are **disabled, not deleted**, by a **keep-list** — `00-os7-header` and `98-reboot-required` run, everything else has its executable bit removed | `dpkg` restores deleted files it owns, silently, on the next `apt` run; `chmod -x` is what `run-parts` honours. A keep-list rather than a deny-list because what is in that directory has never been measured (IL10) and Ubuntu can add to it: nothing appears at login that OS/7 did not put there, except the reboot notice, which is real product-neutral information. Run against a real 26.04 root the rule caught `60-unminimize`, which no deny-list would have named |
| **I10** | `/etc/legal` is a **licence** review, not a branding task | §6.3 |

---

## 10. Limitations — the honest list

| | |
|---|---|
| **IL1** | **`PRETTY_NAME` is read by `intune-agent`**, so branding it is an unverified risk rather than a safe default. It is taken deliberately, because I1 makes it cheap to undo |
| **IL2** | **Nothing here has met a tenant.** L16 and D8 have been "resolved" since 2026-08-23 and no OS/7 device has ever enrolled in Intune or connected to Arc. Every identity claim toward Microsoft is a reading of their code, not an observation of their service |
| **IL3** | `[version]`'s third field is named `Build`; OS/7's BUILD is `.Revision`. Two vocabularies, one type |
| **IL4** | A PowerShell profile that prints corrupts `pwsh -c` output for anyone who omits `-NoProfile` |
| **IL5** | `$PSHOME/profile.ps1` is inside the PowerShell tree and does not survive a PowerShell upgrade |
| **IL6** | Every branded file in `/etc` is a `base-files` conffile. `apt` can revert all of them, and the re-assert has three call sites — build hook 0075, the installer's `ReleaseIdentityStep`, and update step §4.2/6. **One function, three callers**, or they will drift apart |
| **IL7** | A Plymouth theme is invisible on arm64: no `splash` on the kernel command line. The crypttab naming helps both products and is a tenth of the work |
| **IL8** | `1.0.0` does not identify a build, by design. In development every build shows it. §5.3 |
| **IL9** | The Arc script rejects 26.04 outright today for a second, unrelated reason. Do not read a future green Arc install as evidence that I2 was unnecessary |
| **IL10** | Which MOTD drop-ins the pinned image actually contains is **unmeasured**. §6.1 describes a mechanism, not an inventory |

---

## 11. Plan

**Phase A — the display rule. No build, no VM. DONE 2026-08-26.**
`Release.Short`/`Release.Full`/`Release.DisplayFull` in `Model/Release.cs`;
`Get-OS7Version` and `OS7.format.ps1xml` in `powershell/OS7`; and
`installer/testing/check-version-rule.py`, which owns the case table and drives
both implementations over it.

```bash
./installer/testing/check-version-rule.py --docker os7-build:amd64   # 82 checks
```

Three things it found, all of which are the reason the check was written before
anything else:

* **BUILD-NOTES #65, again.** `Get-OS7PackageDrift` computed its hash into
  `$installed` and had a `-Installed` parameter. PowerShell variable names are
  case-insensitive, so the string was coerced into a one-element `[string[]]` —
  and everything downstream still *worked*, because `@('sha256:x') -eq
  'sha256:x'` returns the matching element and is truthy. The Clean case passed;
  only the value handed to the caller was wrong. Caught on the check's first run.
* **`$LASTEXITCODE` can be unset after a native command has visibly run.**
  Measured on Windows against a `.cmd` shim: the command executed, its output
  went to the console instead of the pipeline, and the variable was never set —
  so reading it under `Set-StrictMode -Version Latest` was a terminating error
  *inside the function whose job is to report that it could not tell*. Both
  reads are now guarded through `Test-Path Variable:LASTEXITCODE`.
* **A fake binary was the wrong seam.** The drift check originally put a fake
  `dpkg-query` on `PATH`. What can be silently wrong is not the invocation — one
  line, exercised by any real machine — but the byte-order sort and the trailing
  newline that decide the hash. Those are now reached by handing the package
  list in, which also removed every per-platform shim from the harness.

**Phase B — the image. DONE 2026-08-26, but NOT YET IN AN ISO.**
Hook 0075 stops branding `NAME`, brands `PRETTY_NAME` with the friendly form,
adds the URL fields, `LOGO` and `ANSI_COLOR`, drops `PRIVACY_POLICY_URL`, and
writes `/usr/lib/os7/product`, `/etc/issue` and `/etc/issue.net`. It disables
Ubuntu's MOTD drop-ins and installs `00-os7-header` from `includes.chroot`.
`check-image.py` reads all of it back off the artefact.

Two things are worth calling out about *how* it does it:

* **The display rule is not implemented in the hook.** `build.sh` applies the
  shell implementation (`build/lib/version-rule.sh`) and hands the rendered
  strings in through `build.conf`. That keeps the count at four — C#,
  PowerShell, Python, shell — and every one of the four is reachable by
  `check-version-rule.py`, which now drives all of them over one case table:
  **133 checks, green.** A fifth copy inside a chroot hook would have been the
  one nothing could reach.
* **The MOTD is a keep-list, and the hook enumerates rather than assumes.** What
  Ubuntu actually ships in `/etc/update-motd.d` has never been measured (IL10),
  so nothing names a file it expects to find: the hook disables everything that
  is not OS/7's header or `98-reboot-required`, and prints what it disabled.
  Run against a real Ubuntu 26.04 root it found `60-unminimize`, which was not
  on anybody's list — which is the argument for a keep-list in one line.

**Verified without an ISO** by running the hook's identity sections against a
real Ubuntu 26.04 filesystem in a container: `PRETTY_NAME` branded, `NAME`,
`ID`, `VERSION`, `VERSION_ID`, `VERSION_CODENAME` and `UBUNTU_CODENAME`
untouched, `PRIVACY_POLICY_URL` gone, the banners written, and `run-parts`
producing the two-line login header. **What that does not prove:** that
live-build runs the hook in the real chroot, that the image ships
`00-os7-header` at all, or that anything is on a screen. `make build-arm64`
followed by `check-image.py` and `run-phase1.py all` is the next step, and needs
the Mac.

**Phase C — the installed machine, and the update.** `ReleaseIdentityStep`
rewrites `VARIANT` alone today; it becomes the single re-assert function of IL6,
and update step §4.2/6 calls the same one.

**Phase D — the boot.** crypttab naming, the `GRUB_DISTRIBUTOR` class read-back,
then Plymouth for amd64.

**Phase E — the tenant (SETUP-PLAN Phase 6).** The two measurements that cannot
be made on this hardware: what the Intune console reports as the device's OS
name and version, and whether an *Allowed distributions* policy for Ubuntu 26.04
passes. Both are one enrolment. Until then IL1 and IL2 stand.

---

## 12. Where this is checked

| Check | What it proves | Cost |
|---|---|---|
| `check-version-rule.py` | **all four implementations** — C#, PowerShell, Python and shell — produce the same strings for the same cases; the object's types are the types an operator can compare; and drift reports `Unknown` rather than `Clean` when it could not look. **133 checks, green.** It names which implementations a given run actually compared, so a run that could not reach one says so instead of claiming agreement | seconds; the C# arm needs a Linux binary, so `--docker os7-build:<arch>` off a Mac or Windows box |
| `os7-setup --self-test` | the C# half on its own, including the two forms and the channel rule — and it runs in the chroot during every ISO build (hook 0080), so that half is never *unchecked*, only sometimes un*compared* | the build stops |
| hook 0075's read-back | the image's `os-release` carries the branded fields *and* the untouched ones — **now including `NAME=Ubuntu`, which today's hook would fail** | the build stops |
| `check-image.py` | the finished artefact: `NAME`, the `PRETTY_NAME` prefix, `IMAGE_VERSION` having four fields whose first three equal `PRETTY_NAME`'s, `/etc/issue`, and which MOTD drop-ins are executable | seconds, no VM |
| `run-phase1.py` | the friendly version is **on a framebuffer**, read back through the console font, composed from the shipped manifest rather than carried by the harness | a VM |
| `run-phase2.py existing` | the four-field version still makes the round trip to a disk and back | a VM |
| **Phase E, once** | what Microsoft's service actually thinks this machine is | a tenant |

The rule every one of these follows is the repo's existing one: **no harness
carries an expected version as a string.** Each re-derives it from the manifest,
so a harness cannot pass because somebody forgot to edit it.
