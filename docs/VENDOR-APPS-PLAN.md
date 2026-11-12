# Vendor applications — registered package sources, state outside the boot environment, and Tailscale

**This file is authoritative for software OS/7 machines take from a vendor's own apt repository
rather than from the archive the release pins: how such a source is admitted, what it may
supply, how what it supplies is kept current, where its state lives, and how the first of them,
Tailscale, is installed and run.**

**Approved by the owner 2026-11-09 as the basis for the work; Phase 1 (§7, the generic half) is
built the same day and has run on a machine** — `powershell/Apt/`, P2-apt, `OS7.PackageSource.ps1`,
the drift repair, the `Update-OS7` steps and the two `os7-release` units, held by
`check-package-source-logic.py` (13 scenarios against real apt, 8 planted defects red), and run on
a bench through two updates ([SESSION-VENDOR-SOURCES.md](SESSION-VENDOR-SOURCES.md)). **Phase 2
(the Tailscale role) is built since 2026-11-10 and has NOT run end to end on a machine**:
`powershell/Tailscale/` against output recorded on a bench, P2-tailscale, `OS7.Tailscale.ps1`,
VA16, held by `check-tailscale-logic.py` (73 checks, 12 planted defects red) — and one measurement
on the way, M-TS17, corrected VA11 before any of it ran
([SESSION-TAILSCALE-ROLE.md](SESSION-TAILSCALE-ROLE.md)). §7 step 8 is owed. The decisions below
keep the word *Proposed* until a machine has run them. The measurements behind it are
[SESSION-TAILSCALE.md](SESSION-TAILSCALE.md) (prefix `M-TS` below, by section). Decisions are
VA1–VA17, limitations VAL1–…, open questions O-VA…, and a measurement still owed is `O-M…`, so the
prefix tells "measured" from "owed".

It exists because of a request from the owner: *how would Tailscale work on OS/7, and can it be
integrated elegantly without making it a special case?* The owner then decided the shape
(2026-11-09):

1. **Generic first.** A mechanism for registered vendor sources and for service state outside the
   boot environment; Tailscale is its first consumer. Edge
   ([CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) C15, *"mechanism not chosen"*)
   is meant to be the second. Designed for, not built.
2. **Tailscale follows its own stable channel**, like Edge in C15: drift by design, reported as
   such, kept current by `Update-OS7` **and** by a timer between releases. No Tailscale version in
   the pin.
3. **Tailscale SSH is off by default.** OS/7 never enables it and reports when someone has; the
   recommended path is OpenSSH over the tailnet address.
4. **Login is interactive (a login URL) or by an auth key from OS/7's secret store**, never a key
   on a command line, in a file in the repository, in chat or in a commit.

Related authority: [AUTOMATION-PLAN.md](AUTOMATION-PLAN.md) AU1 (primitives, not policy), AU2 (the
secret store), AU6 (`New-OS7ServiceDataset`), AU10 (`Start-OS7Job`);
[RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §4.4 (D10, what belongs inside a boot
environment) and §5 (drift); [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) C15;
[CONTAINERS-PLAN.md](CONTAINERS-PLAN.md) CT2/CT3 (the role pattern) and CT7 (the bridge ranges);
[POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md) P2, P5, P7;
[REMOTE-DESKTOP-PLAN.md](REMOTE-DESKTOP-PLAN.md) (ufw scopes) and the account lockout.

---

## 1. Verdict

- **A vendor source is registered, not written.** One cmdlet admits it with the vendor's key
  pinned by fingerprint, an apt preference that lets that origin supply only the packages named,
  and a record under `/etc/os7` (VA2–VA5). Anything else in `sources.list.d` is reported as
  unregistered.
- **What a vendor source supplies is drift by design, and is said to be.** `-CheckDrift` learns to
  tell an intended vendor package from an accident — after its three present defects are repaired
  (VA8).
- **It moves twice**: inside `Update-OS7`, recorded per package, and in place between releases by a
  timer. The vendor's own updater is switched off, because two updaters is one too many (VA6, VA7).
- **A vendor application's state is a dataset made before its package** (AU6's verb), because the
  documented install puts it in the boot environment and a rollback then takes the machine off the
  network it is administered through (VA9, M-TS §5).
- **Tailscale is a role on top**: a generic `powershell/Tailscale/` layer over the CLI's JSON, and
  `Install-`/`Get-`/`Connect-`/`Disconnect-`/`Uninstall-OS7Tailscale` that ask the daemon
  back (VA10–VA15). Login from the secret store goes through `Start-OS7Job` — which already works
  (M-TS §6).
- **Two facts every Tailscale machine has to be told**: the host firewall does not filter tailnet
  traffic (M-TS §7), and Tailscale SSH bypasses the PAM account stack for commands (M-TS §8).

---

## 2. What was measured, and what was not

All on 2026-11-09, on the x64 Windows host, against a fresh 1.0.0.277 and a **local Headscale**
— the owner asked that nothing be tested in a real tailnet. [SESSION-TAILSCALE.md](SESSION-TAILSCALE.md)
§2 says what Headscale can stand for: everything the client does on the machine, nothing the
control plane decides.

| # | Finding | Session |
|---|---|---|
| **M-TS1** | The repository holds `tailscale`, `tailscale-nginx-auth` and **`tailscale-archive-keyring`**, which `tailscale` Recommends and which ships the key apt checks the vendor with | §1 |
| **M-TS2** | `Pin: origin pkgs.tailscale.com` at −1 plus `Package: tailscale` at 500 leaves exactly one installable package, in either stanza order | §1a |
| **M-TS3** | **A mismatched key is a warning**: `apt-get update` exits 0 and the old index stays on offer | §1a |
| **M-TS4** | The documented install: state (2326-byte `tailscaled.state` with the machine key) **inside the boot environment**; daemon enabled and running; `AutoUpdate.Apply` unset | §3 |
| **M-TS5** | `Update-OS7`'s clone **moved tailscale 1.104.4 → 1.104.5**, recorded nowhere but apt's history; the chroot `postinst` left the running daemon alone; the state was **copied** into the new environment | §4 |
| **M-TS6** | **R1**: state in the environment, re-login in the new one, `Restore-OS7` → `NeedsLogin`, off the tailnet. **R2**: state on `rpool/DATA/lib/tailscale` made first → `Running` with the new key | §5 |
| **M-TS7** | Auth key from the secret store via `Start-OS7Job -Secret` → logged in; the value in 0 places a reader could reach; **the job succeeds whether or not the login did** | §6 |
| **M-TS8** | `ts-input` precedes ufw and accepts all of `tailscale0`; with ufw at `deny incoming` a tailnet peer still connected | §7 |
| **M-TS9** | Tailscale SSH owns port 22 of the tailnet address; **non-interactive sessions run without PAM when PAM refuses** (expired account, `/etc/nologin`); `root` per tailnet policy; no `loginuid`. Interactive sessions use `login(1)`, land in PowerShell and respect the account stack | §8 |
| **M-TS10** | MagicDNS: resolved per link, routing domains only, `Default Route: no` | §7 |
| **M-TS11** | `Install-OS7ContainerHost`'s range check misses `100.64.0.0/10` except by coincidence, and Tailscale drops traffic from that range on any other interface | §10 |
| **M-TS12** | `apt remove` masks the unit; **`apt purge` empties the state dataset**, then fails on the mount point | §10 |
| **M-TS13** | **`-CheckDrift` checks nothing** (wrong file; `@($null)`), and a correct check would refuse every fresh install (five Setup removals) | §11 |
| **M-TS14** | The tailnet's default decided `AutoUpdate.Apply` (false in R1, **true** in R2); the updater runs `apt-get install --yes --allow-downgrades` in the running system | §12 |
| **M-TS15** | **The vendor's documented source file beside a registered source makes apt refuse EVERY source**: `Conflicting values set for option Signed-By`, `The list of sources could not be read`, exit 100 — measured on 1.0.0.279 | [SESSION-VENDOR-SOURCES.md](SESSION-VENDOR-SOURCES.md) |
| **M-TS16** | O-M1's answer: with a keyring that does not hold the signing key, `apt-get update --error-on=any` **exits 100**; without the switch the SAME `E:` lines arrive at exit 0. `-o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts=<dir> -o APT::List-Cleanup=0` updates that one source and leaves every other list in place (17 before, 17 after) | `powershell/Apt/tests/fixtures` (`update-restricted-*`), [SESSION-VENDOR-SOURCES.md](SESSION-VENDOR-SOURCES.md) |
| **M-TS17** | O-M2's answer, and **NOT what Headscale documents**: a local `set --auto-update=false` made before the first login came out of `tailscale up` AND out of `tailscale login` as `Apply: true` — the control server's default — twice. `up` has no `--auto-update` flag. `set` AFTER the login held across 45 s, a daemon restart and an `up` on the running node; `down` + `up` and `logout` reset it to unset | [SESSION-TAILSCALE-ROLE.md](SESSION-TAILSCALE-ROLE.md) §2 |

**Not measured, and owed before anything is called Decided:**

- ~~**O-M1**~~ — answered by M-TS16.
- ~~**O-M2**~~ — answered by M-TS17, against the plan: VA11 step 5 is corrected below.
- **O-M3** — an SSH session over the tailnet while `tailscaled` restarts (what VA7's in-place
  update does).
- **O-M4** — an older `tailscaled` on a newer state file (a rollback across a vendor update).
- **O-M5** — two registrations on one origin (`packages.microsoft.com` serves Edge and the
  Intune packages from one host) composing as M-TS2 predicts.
- **O-M6** — a domain account refused by AD's logon rules, over Tailscale SSH. M-TS9's mechanism is
  `pam_unix` in the account stack where `pam_sss` sits; no DC was attached.
- **O-M7** — Tailscale's own control plane: version announcements, key expiry defaults, SSH check
  mode. Not measurable without a tailnet, which the owner ruled out; the plan does not depend on
  them.
- **arm64**, entirely. The vendor publishes arm64, so nothing here is amd64-only in design.

---

## 3. The decisions — the generic half

### VA1 — A vendor application is a role: not on the medium, not in the pin's versions, installed on purpose. Proposed 2026-11-09.

The medium carries what the release describes. A vendor application is on some machines and not
others, and its version is the vendor's (owner's decision 2). So it is never in a package list or
a metapackage, and its version is never in [os7-release.conf](../build/config/os7-release.conf).

**What the pin does carry is the trust**: a vendor source's URI, suite and key fingerprint are
"archive URLs" in CLAUDE.md's sense, so they live in the pin like `OS7_MSKEY_*_FPR`
(`OS7_VENDOR_TAILSCALE_URI`, `…_SUITE`, `…_FPR`, `…_PACKAGES`). The release says *where from and
signed by whom*; the vendor says *which version*. A key rotation is then a release event (VAL4).

### VA2 — `Register-OS7PackageSource` admits a source in three files and a record. Proposed 2026-11-09.

```
/etc/os7/keyrings/<name>.gpg                      the vendor key, dearmored, OS/7's path
/etc/apt/sources.list.d/os7-vendor-<name>.sources deb822, Signed-By: that keyring
/etc/apt/preferences.d/os7-vendor-<name>.pref     the origin at -1, the named packages at 500
/etc/os7/package-sources/<name>.json              the record: uri, suite, components,
                                                  fingerprint, packages, update policy,
                                                  registered by/at, schema
```

**The key is OS/7's copy at OS/7's path**, not `/usr/share/keyrings/<vendor>-archive-keyring.gpg`,
because that path belongs to the vendor's keyring package (M-TS1) — trust handed to the party it
is meant to check.

**The record is inside the boot environment, deliberately.** D10's rule: a path belongs inside if
rolling it back makes the system more correct. The record describes which packages may come from
where, and those packages, dpkg's database and the apt configuration all roll back together; a
record outside would describe a package set the rolled-back environment does not have. This is the
opposite answer to VA9's, for the opposite reason.

`Get-OS7PackageSource` lists registered sources with what each supplies (installed, candidate),
when its index was last **verified** (VA4), its update policy, and — with `-All` — every other
source on the machine, classified (VA5). `Unregister-OS7PackageSource` removes the three files and
the record, and refuses while a package it supplies is installed unless told otherwise.

### VA3 — The key is pinned by fingerprint, and the vendor cannot hand itself trust. Proposed 2026-11-09.

`Register-` takes the key (a URL or a file) **and** the expected fingerprint, compares them before
writing anything, and refuses on a mismatch, naming both. The preference's `Package: *` at −1 is
what keeps `<vendor>-archive-keyring` and everything else on that origin out (M-TS2), so the
vendor's key package is never installed by this mechanism — and the documented install's copy, if
present, is reported (VA5).

The origin pin is `Pin: origin <host>`, never `Pin: release o=…`: the host is what apt derived
from the URI OS/7 wrote, the `o=` field is what the vendor's `Release` file says about itself.

### VA4 — A source whose index cannot be verified is a finding, not a warning in a scroll-back. Proposed 2026-11-09.

M-TS3: apt keeps installing from the last verified index and exits 0. So every apt run this
mechanism makes is source-restricted and asked to fail (`--error-on=any`, O-M1), and the outcome
is written into the record (`verified`, `lastError`). `Get-OS7PackageSource` shows *"index not
verified since <date>: <apt's sentence>"*, and `Update-OS7` repeats it. **A vendor key that stops
verifying never stops an OS/7 update**: the OS update proceeds and the vendor package stays where
it was, said out loud.

### VA5 — Every source on a machine has a class. Proposed 2026-11-09.

| Class | What | Today |
|---|---|---|
| `Release` | the pinned archive and the OS/7 repository — written by `Update-OS7` and `os7-release` | `sources.list`/`ubuntu.sources`, `os7.sources` |
| `Image` | vendor sources the medium ships, unconfined | the four `microsoft-*.sources` on every amd64 machine, one of them rewritten by Edge's own `postinst` (M-TS §3) |
| `Registered` | VA2's | none yet |
| `Unregistered` | anything else | e.g. `tailscale.list` from the documented install |

`Update-OS7` warns once per `Unregistered` source, by file, and says what registering it would
mean. **One unregistered source is a refusal and not a warning**: a file that names a registered
repository with another keyring (M-TS15) — apt then reads no source at all. `Register-` refuses
beside it, `Get-OS7PackageSource -All` says what it does, and `Update-OS7` refuses in its
preflight, before anything is created. It does not disable it: removing an administrator's source in the middle of an update is a
decision the administrator has not made. `Image` sources are listed honestly as what they are —
participants in every update with nothing confining them (M-TS5's Microsoft half) — until C15 makes
them `Registered` (VA17).

### VA6 — `Update-OS7` handles registered sources deliberately and records what they moved. Proposed 2026-11-09.

In the clone, before `apt-get update`: each registered source's keyring is read back and its
fingerprint compared with the record; a mismatch excludes that source from this run (VA4) rather
than failing the update. After `full-upgrade`: every package a `Registered` or `Image` source
supplies that changed version is recorded — **a new `VendorPackages` field on the result** and a
line in `update.log` — which is exactly what M-TS5 found missing. Unregistered sources: VA5's
warning.

The chroot `postinst` restarting nothing on the running system (M-TS5) is relied on and stated, not
re-implemented.

### VA7 — Between releases a timer brings registered sources forward, in place. Proposed 2026-11-09.

`os7-vendor-update.timer`, daily with a randomised delay, runs `Update-OS7PackageSource -All` for
sources whose policy is `Follow`: a source-restricted, fail-loud `apt-get update` (VA4), then
`apt-get install --only-upgrade` of that source's installed packages — never a `full-upgrade`, so
the pinned archive does not move between releases. What moved goes to `/var/log/os7/vendor-update.log`
(outside the boot environment) and the journal.

**In place, not into a new boot environment.** The package is outside the release; an environment
per vendor bump would multiply environments for a version nobody pinned. The cost is the one C15
already accepted for Edge: a `Restore-OS7` takes the vendor package back to the version the older
environment had, and the next run brings it forward (VAL1, O-M4).

**One updater.** A vendor's own updater is switched off by the role and reported if switched on:
Tailscale's would run apt in the running system with `--allow-downgrades` (M-TS14), and the
tailnet's administrator — not the machine's — decides whether it runs.

### VA8 — Drift is measured against what OS/7 last made the machine, and classified. Proposed 2026-11-09.

M-TS13 found three things, and the first two are plain defects:

1. `Get-OS7Version` reads `packages_manifest` from `release.json`; since C7 split declared from
   measured facts it is in `image.json`.
2. `Get-OS7PackageDrift` without `-Installed` never asks dpkg (`@($null).Count` is 1) and throws;
   `Update-OS7` swallows the exception, so its drift refusal has never fired.

The third is a design gap: the manifest describes the **image**, Setup removes five packages from
every install, so a correct comparison with the manifest calls every fresh machine drifted.

So the comparison changes its reference. **`/var/lib/os7/packages.baseline`** — inside the boot
environment, like C10's migration record, because it describes this environment's package set — is
written by OS/7 whenever OS/7 changes the package set: on the first boot (a small unit, since Setup
is owned elsewhere), by `Update-OS7` in the clone after its apt step, and by a role's install
after its own. Drift is then *what changed since OS/7 last changed it*, in three classes:

| Class | Meaning | `Update-OS7` |
|---|---|---|
| `Intended` | supplied by a `Registered` source, or recorded by a role's install as pulled in for it | proceeds, lists them |
| `Image` | moved by an `Image` source (Edge, today) | proceeds, lists them |
| `Unexplained` | everything else — somebody ran apt | refuses without `-Force`, as §5 always meant to |

The image comparison stays, as `-CheckImage`, for the question it actually answers.

### VA9 — A vendor application's state is a dataset made before its package. Proposed 2026-11-09.

AU6's verb, CT3's order: `New-OS7ServiceDataset -Name <app> -NoLayout` **before** `apt-get install`,
so the package's `StateDirectory=` (or postinst) finds a mount. M-TS6 is the argument: in the boot
environment, a rollback restores an identity the other side has already replaced, and every
environment carries a copy of the private key.

**Backup is per application, and for an identity it is off.** A node key restored onto a second
machine is two machines with one identity. `-Backup $false`, and the role says so. (The update's
recursive `rpool/DATA` snapshot still takes one per update, on the same pool — VAL7.)

**A documented install found on the machine is adopted, not refused.** Unlike containers (CT's
O-CT7), the data is one directory and moving it is mechanical: stop the daemon, create the dataset
at a temporary mount point, copy, swap the mount, start, ask back. The identity survives;
`-Adopt` does it, and without it the role refuses and says why.

---

## 4. The decisions — Tailscale

### VA10 — `powershell/Tailscale/` is the generic layer, over the CLI's JSON. Proposed 2026-11-09.

P2's shape. It knows Tailscale and nothing about OS/7: `Get-TailscaleStatus` (`status --json`),
`Get-TailscalePreference` (`debug prefs`), `Connect-Tailscale` (`up`, with `--json` for the login
URL), `Disconnect-Tailscale` (`down`, `logout`), `Set-TailscalePreference` (`set`). **One function
runs the CLI, `Invoke-TailscaleCommand`, not exported** — the seam fixtures are replayed through
(`Test-TailscaleModule`, recordings of 1.104.5 in four states: logged out, needs login with a URL,
running, running with SSH on), and the thing **P2-tailscale** in `check-layering.py` keeps
`powershell/OS7` away from, at 0.

**The CLI, not the LocalAPI socket**: the CLI's JSON is what Tailscale documents for scripts; the
LocalAPI is internal and changes. `debug prefs` is the one debug command used, because the
preferences (`AutoUpdate`, `RunSSH`, `CorpDNS`) are not in `status`; its fixtures are what a
version that renames a field turns red.

### VA11 — `Install-OS7Tailscale`: state, source, package, preferences, then ask back. Proposed 2026-11-09.

1. refuse a documented install's layout unless `-Adopt` (VA9);
2. `rpool/DATA/lib/tailscale` at `/var/lib/tailscale`, no layout, **no backup**;
3. `Register-OS7PackageSource tailscale` from the pin (VA1), policy `Follow`;
4. `apt-get install --no-install-recommends tailscale`;
5. `--auto-update=false` and `--ssh=false` — **as a statement, not a guarantee.** This step said
   "before any login, so the tailnet's defaults cannot decide them" until M-TS17 measured the
   opposite: a login replaces the preferences `up` has no flag for, and the tailnet's default
   then fills the gap. What makes them hold is `Connect-OS7Tailscale` setting them again AFTER the
   daemon reports `Running` (VA12), and `Get-OS7Tailscale` reporting anything but an explicit off
   (VA13);
6. ask back: the dataset mounted and the state on it, the daemon active, the two preferences, the
   source verified, the package's origin the registered one, the baseline written (VA8).

The order is decided before anything is changed — `Get-OS7TailscaleInstallPlan`, a function of
its own so `check-tailscale-logic.py` can assert it: the dataset before the package, the source
before the package, and on `-Adopt` the daemon stopped before its state is copied and the old copy
deleted only after the SAME node answers from the dataset.

Not on the medium, not in any metapackage (VA1). Both architectures.

### VA12 — `Connect-OS7Tailscale`: an auth key from the secret store, or a URL. Proposed 2026-11-09.

`-AuthKeySecret <name>` runs `tailscale up --auth-key=file:$CREDENTIALS_DIRECTORY/<name>` through
`Start-OS7Job -Secret` (AU10 — no second job runner), which M-TS7 measured. The job's command is a
CONSTANT that calls `Connect-Tailscale` and **throws** on its verdict, because the runner counts
only a throw as failure (M-TS7); its parameters arrive as the job's input document (AU3), so
nothing an operator typed is spliced into code. **Then asks the daemon**: `BackendState Running`
and an address are the result, and anything else is a refusal carrying the daemon's own sentence —
or, when the job failed, Tailscale's sentence from the runner's record, because `Start-OS7Job`
reports a failed oneshot as "could not be started" in systemctl's words. **Then sets
`--auto-update=false` and `--ssh=false`**, after the login and never before it (M-TS17).

Without a secret it prints the login URL from `up --json` and waits up to `-TimeoutSec` for a
person to use it — `up --json --timeout` exits 1 after printing the URL and the daemon keeps the
login pending, so that exit is not a failure. `-NoWait` returns at once; the preferences are then
set by the next `Connect-OS7Tailscale` on the connected machine, and `Get-OS7Tailscale` says so
until then. `-LoginServer` exists for a self-hosted control server; `-Hostname`, `-AdvertiseTag`,
`-AcceptDns` pass through. There is no `-Ssh`.

How a key reaches the secret store unattended — Intune or Arc running `New-OS7Secret` with a value
the management plane holds — is the management plane's (O-VA3).

### VA13 — `Get-OS7Tailscale` says what needs attention first. Proposed 2026-11-09.

Installed, version and candidate, the daemon, `BackendState`, tailnet, hostname, addresses, key
expiry, the state's layout (`OS7` / `InBootEnvironment`), the source's verification, and the
three facts M-TS measured as sentences when they apply:

- **TailscaleSsh on** — *"Tailscale SSH answers on port 22 of this machine's tailnet address.
  A command sent over it runs even when PAM's account checks refuse the account — an expired
  account, `/etc/nologin` — and `root` logs in if the tailnet's policy allows it. OpenSSH over the
  tailnet address applies those checks, and on a domain-joined machine they include AD's logon
  rules."* (The last clause is the mechanism; O-M6 is the measurement.)
- **AutoUpdate on** — the vendor's updater runs apt beside OS/7's (VA7). **And AutoUpdate NOT
  DECIDED** on a logged-in node, which is the state a `logout` or a `down` + `up` leaves (M-TS17):
  the tailnet's default decides at the next login. The preference is three-valued and reported as
  such — `$null` is never collapsed to off.
- **always, once connected** — *"This machine's firewall does not filter traffic from the tailnet;
  the tailnet's access policy does."* (M-TS8). It is a property of the product, not a defect, and an
  administrator who scoped Remote Desktop with `-AllowFrom` needs to know it does not apply here.
  So it is in `Notes`, apart from `Attention`: an attention list that is never empty on a healthy
  machine is one nobody reads.

### VA14 — Tailscale SSH is off, and OS/7 has no verb that turns it on. Proposed 2026-11-09.

Owner's decision 3, and M-TS9 is why it is the right default rather than a preference: OpenSSH
over the tailnet address keeps OS/7's account lockout, AD's logon rules through `pam_sss`, the
PowerShell landing and `loginuid`; Tailscale SSH keeps them for an interactive login and drops them
for a command. `Install-` and `Connect-` set `--ssh=false`; `Set-OS7Tailscale -TailscaleSsh:$false`
exists to switch it off; nothing switches it on — **not even the generic layer**:
`Set-TailscalePreference -Ssh` and `-AutoUpdate` accept `$false` only, because a generic verb that
could switch them on would be an OS/7 verb that does. It is the one piece of OS/7 policy in
`powershell/Tailscale/`, and its header says so. An administrator who wants it uses `tailscale set
--ssh` and is reported (VA13).

### VA15 — Disconnect, uninstall, and the one thing never to run. Proposed 2026-11-09.

`Disconnect-OS7Tailscale` is `down` (still enrolled); `-Logout` removes the node from the tailnet.
`Uninstall-OS7Tailscale` logs out unless `-KeepIdentity`, runs **`apt-get remove`** (M-TS12: the
unit ends up masked, which it undoes for a later install), unregisters the source, and with
`-RemoveState` destroys the dataset and its snapshots. **It never runs `apt purge`**: the vendor's
`postrm` empties the dataset — the identity with it — and then fails (M-TS12).

### VA16 — The container host knows about a tailnet. Proposed 2026-11-09.

`Test-OS7ContainerRangeCollision` gains a third thing a range must not overlap: **`100.64.0.0/10`
whenever a `tailscale0` link exists** (and `fd7a:115c:a1e0::/48` once the check reads IPv6),
because Tailscale drops traffic from that range on every other interface (M-TS11) and its peer
routes live in table 52, which the main-table check cannot see. `Install-OS7ContainerHost`'s help
example moves out of `100.64.0.0/10`. CONTAINERS-PLAN O-CT6 loses its CGNAT candidate.

### VA17 — Edge is the second consumer, and this is what it needs. Proposed 2026-11-09; not built.

C15 decided that Edge follows Microsoft's channel and that VS Code, the Intune portal and the
identity broker are pinned. In this plan's terms: one `Registered` source owned by the **release**
(shipped by `os7-release`, not registered by an operator), `Follow` for `microsoft-edge-stable`, and
`Pin: version` records for the three pinned packages on the same origin (O-M5). Two things are
Edge's own and must be measured first: its `postinst` rewrites its source file (M-TS §3), which a
registered source must survive or prevent; and C15's open question — whether Edge's updater or this
timer is the mechanism — is answered by VA7's *one updater*.

---

## 5. Limitations

- **VAL1** — A rollback takes a vendor package back to the older environment's version until the
  next timer run (C15's cost, accepted for Edge).
- **VAL2** — A vendor version that needs a library newer than the pinned archive cannot be
  installed; the timer reports it and the package stays.
- **VAL3** — Vendor maintainer scripts run as root, in the clone during `Update-OS7` and on the
  running system during the timer.
- **VAL4** — A vendor key rotation stops the source verifying (VA4) until a release carries the new
  fingerprint, or an administrator re-registers with it.
- **VAL5** — On a tailnet node the tailnet's access policy, not ufw, decides who reaches the machine
  (M-TS8).
- **VAL6** — The timer's in-place update restarts `tailscaled` (its `postinst` does), so a session
  over the tailnet may stall for the restart (O-M3).
- **VAL7** — `Update-OS7`'s recursive `rpool/DATA` snapshot keeps one copy of the node key per
  update on the same pool; no policy replicates it.
- **VAL8** — The Tailscale half is measured against Headscale; Tailscale's own control plane is
  unmeasured (O-M7).
- **VAL9** — arm64 is unmeasured.

## 6. The layers

```
Install-/Get-/Connect-/Disconnect-/Uninstall-OS7Tailscale     OS7.Tailscale.ps1    (the role)
        │                         │
        │                         └── Start-OS7Job -Secret            (AU10, AU2)
        ▼
Register-/Get-/Unregister-/Update-OS7PackageSource            OS7.PackageSource.ps1 (generic)
New-OS7ServiceDataset (AU6)   Get-OS7Version -CheckDrift (VA8)
        │  P2-apt, P2-tailscale (check-layering.py)
        ▼
powershell/Apt/        sources (deb822), keyrings and fingerprints, preferences, apt-cache
                       policy, source-restricted fail-loud update, install/remove, dpkg-query
powershell/Tailscale/  the CLI's JSON, one invoker, recorded fixtures
```

**`powershell/Apt/` is new**, and the reason is the seam rather than tidiness: the logic check needs
a fake apt it can plant defects behind, the way `check-container-logic.py` fakes the engine at the
Docker module's seam. **P2-apt** starts at the number of direct apt/dpkg invocations
`powershell/OS7` has on the day the rule is written — `OS7.Update.ps1` and `OS7.Device.ps1` hold
them, counted by the rule's own pattern rather than by a grep that also matches comments — and may
fall, not rise: P2-directory's way of starting above zero.

## 7. Order of work — one step at a time, each approved

**Phase 1 — the generic half**

1. `powershell/Apt/` and P2-apt; O-M1 answered in a container first.
2. VA8: the two drift defects, the baseline and its first-boot unit, the classes. A check proven to
   fire on each defect.
3. `OS7.PackageSource.ps1` (VA2–VA5) and the pin's vendor fields.
4. `Update-OS7` (VA6) and the timer (VA7), in `os7-release`.
5. `check-package-source-logic.py`: the decisions against the Apt seam — fingerprint refusal, the
   preference's shape, classification, `VendorPackages`, the timer never running `full-upgrade` —
   with planted defects required to go red. `check-module-parts.py`, `check-privilege.py`,
   `check-ps-traps.py`, `check-update-logic.py` and the reference counts kept green.

**Phase 2 — Tailscale**

6. `powershell/Tailscale/`, fixtures recorded on the bench, P2-tailscale. **Done 2026-11-10.**
7. `OS7.Tailscale.ps1` (VA10–VA15), VA16 in `OS7.Container.ps1`, `check-tailscale-logic.py`.
   **Done 2026-11-10**; VA16 is code and untested.
8. **Owed.** **On a bench, end to end**: install, login with a key from the secret store, `Update-OS7` with
   the source registered (and the timer), a rollback that keeps the identity, `-Adopt` of a
   documented install, uninstall. Against the local Headscale, driven by a harness
   (`run-tailscale.py`) whose lab — Headscale's configuration, the client's Dockerfile — lives under
   `installer/testing/`, with the CA and every key generated per run.

**Phase 3** — a chapter in the administrator manual (DE and EN), HANDOFF's table, CLAUDE.md's
authority table, `POWERSHELL-REFERENCE.md`.

No ISO is built and no release published as part of this; it lands in a later release.

## 8. Open questions

- **O-VA1 — The verb names.** `Register-OS7PackageSource` mirrors Windows' `Register-PackageSource`
  (PackageManagement); `Update-OS7PackageSource` for "bring what this source supplies up to date"
  is the least clear of them.
- **O-VA2 — The timer's window.** Daily with a randomised delay, like `os7-update-check`, or a
  maintenance window an administrator sets — which VA7's restart (VAL6) argues for.
- **O-VA3 — Unattended enrolment.** Which management-plane mechanism (an Intune script, an Arc
  extension) puts the key into the secret store, and whether the key should be single-use there.
- **O-VA4 — `nodivert`.** Tailscale can leave inbound filtering to the host firewall
  (`--netfilter-mode=nodivert`). OS/7 has no host firewall policy of its own (ufw is inactive), so
  VA13 reports instead; revisit when one exists.
- **O-VA5 — `Get-OS7NetworkAdapter`'s kind.** `tailscale0` reads `Other` (M-TS §3); a `Tunnel` kind
  would be truer for every WireGuard-shaped link.

## 9. What this changes elsewhere — once approved

- [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) C15: *"mechanism not chosen"* →
  this plan's VA17; [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §5: drift's reference
  and classes (VA8).
- [CONTAINERS-PLAN.md](CONTAINERS-PLAN.md) O-CT6 and CT7 (VA16).
- [REMOTE-DESKTOP-PLAN.md](REMOTE-DESKTOP-PLAN.md): `-AllowFrom` does not scope a tailnet peer
  (M-TS8).
- [POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md): P2-apt and P2-tailscale beside the eight
  rules.
- [BUILD-NOTES.md](BUILD-NOTES.md): the drift check that never ran (M-TS13); `sudo -S` swallowing
  standard input (SESSION §2).
- CLAUDE.md's authority table, HANDOFF, the manual.
