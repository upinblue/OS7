# Session — vendor package sources, the generic half (VENDOR-APPS-PLAN Phase 1)

**2026-11-09, x64 Windows host.** Built after the owner approved
[VENDOR-APPS-PLAN.md](VENDOR-APPS-PLAN.md) the same evening; measured on bench `ts` (amd64), from
snapshot `tslab-ready` (a fresh 1.0.0.277) through two updates built from the working tree,
1.0.0.279 and 1.0.0.280. Nothing is committed, no ISO was built. The Phase 0 measurements are
[SESSION-TAILSCALE.md](SESSION-TAILSCALE.md).

## What was built

| Piece | Where | Held by |
|---|---|---|
| The eighth generic layer: sources (one-line and deb822), preferences, keyring fingerprints, `apt-cache policy`, a fail-loud source-restricted index update, packages — every program in the C locale | `powershell/Apt/` (12 functions, `Assert-AptElevated` on the six that write) | `Test-AptModule`, 42 checks against output recorded on a 1.0.0.277 |
| P2-apt — `powershell/OS7` reaches apt, dpkg and gpg only through it. Baseline **11**, counted by the rule's own pattern, which also matches a program passed to `chroot` as an array element and the `& env … apt-get` form | `installer/testing/check-layering.py` (nine rules) | itself |
| `Register-`, `Get-`, `Unregister-`, `Update-OS7PackageSource`, `Save-OS7PackageBaseline` | `powershell/OS7/OS7.PackageSource.ps1` | `check-package-source-logic.py` |
| The drift repair (VA8): the hash from `image.json`, `@($Installed \| Where-Object)`, the baseline as reference, three classes | `OS7.psm1` | the same, S11/S12; `check-version-rule.py` |
| `Update-OS7`: a preflight refusal for sources apt would refuse together; registered keyrings read back in the clone; unregistered sources named; what vendor sources moved recorded (`VendorPackages`, `update.log`); the baseline written in the clone; the drift refusal on Unexplained-against-Baseline only, and said when the drift could not be checked | `OS7.Update.ps1` | `check-update-logic.py` (green), the bench |
| `os7-vendor-update.timer`/`.service` (daily, in place) and `os7-package-baseline.service` (first boot without a baseline) | `build/packages/os7-release/` | the bench |
| Tailscale's source in the pin: URI, suite, components, key URI, fingerprint, packages — no version | `build/config/os7-release.conf` | the bench (`-FromRelease`) |

## The check

`./installer/testing/check-package-source-logic.py` — real apt, dpkg and gpg in `ubuntu:26.04`
with the pinned PowerShell, against a signed repository it builds (three packages) and serves on
127.0.0.1, with two test keys. **13 scenarios, 38 assertions, plus `Test-AptModule` on Linux, green; eight planted defects, each
in a copy of `powershell/`, each turning its scenario red**: the fingerprint not compared, no
`Package: *` at −1, apt asked without `--error-on` and judged by its exit code, the timer without
`--only-upgrade`, every source called Release, `@($Installed)` again, no Signed-By clash check, no
rollback of a failed registration. It also fails when a scenario records nothing.

**It found a defect in itself before it found one in the code.** S12 passed alone and was
missing from every full run: S11 created a local called `only` — the name of the function's own
parameter — so `want("S12")` asked whether `"S12"` was a substring of a path. BUILD-NOTES #65's
shape in Python, and the reason the check now counts its scenarios.

## On a machine

**277 → 279** (by 277's own `Update-OS7`, which knows nothing of this), then on 279:

| Reading | Value |
|---|---|
| `os7-package-baseline.service` at the first boot of 279 | `Result=success`, 1527 packages, header *"… by Save-OS7PackageBaseline: first boot"* |
| `Get-OS7Version -CheckDrift` right after | `Clean`, Reference `Baseline` |
| `os7-vendor-update.timer` | listed, next run that night |
| `Get-OS7PackageSource -All` before anything was registered | the four `microsoft-*.sources` **Image**, `os7.sources` and `ubuntu.sources` **Release** |
| `Register-OS7PackageSource -Name tailscale -FromRelease` | `Verified True`, `KeyringIntact True`; `/etc/os7/keyrings/tailscale.gpg` 2288 bytes; the preference's two stanzas |
| `Get-AptPolicy` | `tailscale` candidate 1.104.5 at **500** from pkgs.tailscale.com; `tailscale-archive-keyring` and `tailscale-nginx-auth` **no candidate** |
| tailscale 1.104.4 installed, baseline saved, `systemctl start os7-vendor-update.service` | `os7-vendor-update: tailscale: moved tailscale 1.104.4 -> 1.104.5`, `Result=success`; the line in `vendor-update.log`; drift `Clean` afterwards (the baseline was rewritten) |

**The documented install's file beside the registered source stops apt entirely** (new,
M-TS15): with Tailscale's `tailscale.list` (Signed-By `/usr/share/keyrings/…`) next to the
registered source (Signed-By `/etc/os7/keyrings/…`), `apt-get update` printed
`E: Conflicting values set for option Signed-By regarding source https://pkgs.tailscale.com/stable/ubuntu/ resolute …`
and `E: The list of sources could not be read.` — exit **100**, for every source on the machine.
Nothing could update. So `Register-` refuses beside such a file, naming it; `Get-OS7PackageSource
-All` says what the file does; `Update-OS7` refuses before it changes anything.

**279 → 280** by 279's `Update-OS7` (the two files changed after 279 was built copied in by hand,
so this machine is not what any medium installed — BUILD-NOTES #93):

| Step | Result |
|---|---|
| `sl` installed by hand after the baseline, `Update-OS7` | **refused**: *"this machine's packages changed outside OS/7 since it last changed them (§5): sl …"* |
| `tailscale.list` put back, `Update-OS7 -Force` | **refused**, naming both files and both keyrings, *"Nothing has been changed"*; no snapshot named for 280, no new environment |
| `sl` accepted with `Save-OS7PackageBaseline`, a harmless unregistered source (`backports.sources`, the snapshot's backports pocket) present, tailscale at 1.104.4 | applied and activated. Warning: *"backports.sources is not a registered source and takes part in this update unconfined"*. **`VendorPackages`: tailscale 1.104.4 → 1.104.5, Registered, pkgs.tailscale.com** — and both as lines in `update.log` |
| first boot of 280 | baseline header *"Update-OS7 1.0.0.279 -> 1.0.0.280"* (written in the clone); `os7-package-baseline.service` `ConditionResult=no`; drift `Clean` against `Baseline` |

Snapshot `p1-280` keeps that machine.

## Found in passing, and not this work's

**A refusal after the clone leaves the environment and the `rpool/DATA` snapshot, and the
environment then cannot be removed until a reboot.** The first version of the Signed-By check
ran inside the clone; it refused there, and the update left `os7_1.0.0.280_…` and
`rpool/DATA@os7_1.0.0.280_…` behind — deliberately, per `Update-OS7`'s own comment (*"the only
evidence of what went wrong"*). Two consequences nobody had written down: a retry **in the same
minute** collides with the snapshot's name (`dataset already exists`), because environment names
have minute resolution; and `Remove-OS7BootEnvironment` failed with *"dataset is busy"* while
nothing was mounted — `chronyd`, `polkitd` and `NetworkManager` held the clone's mounts in their
own mount namespaces. After a reboot it was removed. The check now runs before anything is
created; the general behaviour is the update train's and is left as found.

## Not done here

* Phase 2 — the Tailscale role and `powershell/Tailscale/` — and VA16 (the container check).
* No ISO carries any of it; the units have run only on machines that took 279/280 by update.
* `check-update-logic.py` drives the train's order and refusals and stays green; it does not
  assert the new vendor steps, which the bench did.
* arm64.
