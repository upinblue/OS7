# Session — the Tailscale role (VENDOR-APPS-PLAN Phase 2, steps 6, 7 and 8)

**2026-11-10, x64 Windows host.** Built on top of Phase 1
([SESSION-VENDOR-SOURCES.md](SESSION-VENDOR-SOURCES.md)) after the owner's "Phase 2". Recorded on
bench `ts` (amd64, from snapshot `p1-280`: 1.0.0.280 with the registered Tailscale source and
tailscale 1.104.5 installed by Phase 1) against the local Headscale lab of
[SESSION-TAILSCALE.md](SESSION-TAILSCALE.md) §2 — no real tailnet was touched. No ISO was built.

**2026-11-12: VENDOR-APPS-PLAN §7 step 8, the role on a machine end to end.** `run-tailscale.py` drove it through
eleven phases, the machine found three defects every check had passed (§9), and after their fixes
one run of 105 checks was green against release 1.0.0.283 (§7). §1–§6 are the build of 2026-11-10;
§7–§12 are the machine.

## 1. What was built

| Piece | Where | Held by |
|---|---|---|
| The ninth generic layer: `Get-TailscaleVersion`, `-Status`, `-Preference`, `Connect-`, `Disconnect-`, `Set-TailscalePreference`, `Test-TailscaleModule`. The CLI's JSON, one invoker (`Invoke-TailscaleCommand`, not exported), the key only as `--auth-key=file:<path>`, SSH and the client's updater switchable OFF only | `powershell/Tailscale/` | `Test-TailscaleModule`, 40 checks against 16 recorded outputs |
| P2-tailscale — `powershell/OS7` reaches the client only through it. Baseline **0**. It matches the program by PATH (`/usr/bin/tailscale`), the `& env` form and the LocalAPI socket, because the way round the layer that Phase 0 actually used was a `Start-OS7Job -Command '& /usr/bin/tailscale up …'` string, which `direct()` cannot see. The package name is deliberately not matched. Proven to fire on four planted forms | `installer/testing/check-layering.py` (ten rules) | itself |
| `Get-`, `Install-` (with `-Adopt`), `Connect-`, `Disconnect-`, `Set-`, `Uninstall-OS7Tailscale`; the judgements as two pure functions (`Get-OS7TailscaleAttention`, `Get-OS7TailscaleInstallPlan`) and the login job's command as a constant | `powershell/OS7/OS7.Tailscale.ps1` | `check-tailscale-logic.py` |
| VA16: the container host's range check refuses `100.64.0.0/10` whenever a `tailscale0` link exists | `OS7.Container.ps1` | `run-tailscale.py` va16, on a machine (§7) |
| The Apt and Tailscale self-tests run out of a built image, and their fixtures counted by hook 0060 (Apt's had been asked by nothing since Phase 1) | `check-image.py`, hook 0060 | the next ISO |

**`check-tailscale-logic.py`**: 73 checks — sixteen attention situations (the healthy one first,
because an attention list that is never empty is one nobody reads), eight install plans plus the
order invariants, the login job's command run against the replayed CLI, eight `Connect-` cases,
both layers refusing to switch SSH or the updater on, and four uninstall cases — with the role's
side effects (Start-OS7Job, apt, systemd, ZFS) stubbed in the module's scope and both root guards
stubbed, so it runs as any account on either host. `--prove` plants twelve defects in a copy and
requires each red; all twelve are.

## 2. M-TS17 — a login replaces what `up` has no flag for (O-M2)

VA11 said to set `--auto-update=false` **before any login**, so the tailnet's default could not
decide it, and quoted Headscale's documentation that a local choice holds. Measured on the bench
against the lab, whose `auto_update.enabled` is true, the login made through `Start-OS7Job` with
a key from the secret store:

| Step | `AutoUpdate.Apply` |
|---|---|
| logged out, `tailscale set --auto-update=false --ssh=false` | `false` |
| `tailscale up --auth-key=file:… --login-server=…` (no auto-update flag: `up` has none) | **`true`** |
| `tailscale set --auto-update=false` while running | `false` |
| 20 s later; after `systemctl restart tailscaled` | `false`, `false` |
| `tailscale down`, then `up` with the same flags | **unset** |
| `tailscale logout` | unset |
| logged out, `set` false, then `tailscale login` instead of `up` | **`true`** again |
| `set` false, then `up` on the RUNNING node, 45 s, a daemon restart | `false` throughout |

`tailscale up --auto-update=false` is not a thing: the login failed on the flag. So the local
choice does not survive a login by either verb, and a `set` made after the login does. The role
follows that: `Connect-OS7Tailscale` sets both preferences AFTER the daemon reports `Running`, and
`Get-OS7Tailscale` reports `Apply` true AND unset — three-valued, never collapsed to off. Raw data:
`m-om2.out` and `m-om2b.out` in the session's working directory, outside the repository.

## 3. The fixtures, and how the first recording lied

`powershell/Tailscale/tests/fixtures/` is tailscale 1.104.5 in the states a machine was seen in:
fresh, a login waiting for a person, running by key, `down`, logged out, and the daemon stopped;
`debug prefs` in five of them; `up` with a bad key, with `--json` and no key, and on a running
node without its flags. The registration request id in every `AuthURL` and the QR code that
encodes it are replaced by placeholders; `debug prefs` already zeroes the node keys, and nothing
from that block is passed on by the module in case a later client does not. Only lab addresses
and lab host names remain.

**The first recording logged nothing in and looked as if it had.** The login job's command was
built in a DOUBLE-quoted string in the recording script, so the OUTER pwsh expanded
`$env:CREDENTIALS_DIRECTORY` — empty there — and the job ran `tailscale up
--auth-key=file:/tailscale-authkey`. Its journal said `open /tailscale-authkey: no such file or
directory`; the job record said success; every "running" fixture was `NeedsLogin`. Two lessons the
code now carries: the role's job command is a single-quoted constant whose parameters arrive as
the input document, and `check-tailscale-logic.py` J0 requires `$env:CREDENTIALS_DIRECTORY` to be
in the command unexpanded.

## 4. The job runner counts only a throw

Measured on the same run: a native `tailscale up` that exits 1 inside `Start-OS7Job` is a job
that SUCCEEDED (`/usr/libexec/os7-job-run.ps1` sets `exitCode = 1` only in its `catch`). So the
login job calls `Connect-Tailscale` and throws on its verdict. And the other direction: a job
whose command throws is a oneshot that failed, which `Start-OS7Job` reports as *"could not be
started"* in systemctl's words — so `Connect-OS7Tailscale` reads the RUNNER's record for the
error, which carries Tailscale's sentence (`invalid pre auth key`). Both are checked (J1, C3).

## 5. Found on the way

* **BUILD-NOTES #202** — a self-test whose checks sit in `try { } finally { }` printed PASS and
  exited 0 after a strict-mode exception had stopped it three checks in. Fixed in the Tailscale
  and Apt self-tests; `Test-HardwareModule` and `Test-OS7Update` have the same shape.
* **The exported function is not the re-defined one.** `check-tailscale-logic.py` dot-sources a
  planted copy into the OS7 module's scope, as `check-container-logic.py` does; five of its
  first twelve plants came back MISS, because a call from the harness's scope resolves to the
  function the module EXPORTED at import. Every cmdlet is now called inside the module's scope.
* **`Import-Module <Name>` does not take a module already loaded by path**; it searches
  `PSModulePath` and fails. On a machine the module is there; the check puts the repository's
  `powershell/` on the path.
* **An empty pipeline assigned to a variable is AutomationNull, and AutomationNull on the left of
  `-like` is an empty ARRAY, not `$false`** — which a `[bool]` parameter then refuses.
* **`[IO.Path]::Combine` writes `\` on Windows.** The login job builds the credential path with
  `/` because it is a Linux path wherever the check runs.
* **check-layering.py could not report a planted copy on another drive** (`relpath` across `C:`
  and `D:`); fixed. And **P2-apt said 11 for a day after it was 10**: Phase 1's drift repair took
  the `dpkg-query` out of `OS7.psm1`, and IMPROVED passes. Lowered to 10.

## 6. The checks, all green on 2026-11-10

`check-tailscale-logic.py --prove` (73 + 12 RED), `Test-TailscaleModule` (40), `Test-AptModule`
(42), `check-layering.py` (ten rules, P2-apt 10, P2-tailscale 0), `check-module-parts.py` (45),
`check-ps-traps.py` (six held), `check-privilege.py` (OS7 42, generic 41 — at their baselines),
`check-image.py --self-test`. The reference counts moved to **378 functions in ten modules, OS7
206**.

## 7. Step 8: the role on a machine — `run-tailscale.py`

**2026-11-12.** The harness VENDOR-APPS-PLAN §7 step 8 asked for:
`installer/testing/run-tailscale.py`, its lab under `installer/testing/tailscale-lab/`
(Headscale's configuration, the policy, the peer's Dockerfile), and the CA, Headscale's own keys
and every auth key made per run — a key read into the harness's memory and handed on over
standard input, never printed, never an argument, never a file. It drives an `os7lab.py` bench
from snapshot `p1-280` through eleven phases and checks what the role says against three witnesses
that do not go through the role: the client's own JSON (`tailscale status --json`, `tailscale
debug prefs`), the kernel's mount table (`findmnt -T /var/lib/tailscale`), and Headscale's node
list.

**The run that counts: 105 checks, 0 FAIL, 19 minutes**, against release **1.0.0.283** served
from the bench's repository — built from `f8e9270` with this session's fixes in the working tree,
which the release records as `dirty`, and with nothing laid over the installed module. Log:
`run9-evidence.log` in the session's working directory, outside the repository.

| Phase | What the machine did |
|---|---|
| documented | 1.0.0.280 logged in the vendor's way (`tailscale up --auth-key=file:/dev/stdin`): node 2, its state on `rpool/ROOT/os7_1.0.0.280_…` |
| update | `Update-OS7` 280 → 283; `VendorPackages`: `tailscale 1.104.5 -> 1.104.6 [Registered]` beside three Microsoft packages `[Image]`. After the reboot the same node key, its state copied into the new environment; `Get-OS7Tailscale` says `InBootEnvironment` and names `-Adopt` |
| adopt | `Install-OS7Tailscale` refused and changed nothing. `-Adopt`: `Adopted`, 7 files copied; `findmnt` → `rpool/DATA/lib/tailscale zfs`; `tailscaled.state` `600 root`; the environment's copy gone (an empty mount point under the dataset, read through a bind mount of `/`); the same node key and id; one node in Headscale; the peer answers; not in the backup policy; attention empty; both preferences `False` in the client's own prefs; drift `Clean`. Run again: `AlreadyInstalled` |
| rollback | logout, then a login from the secret store in 283: a new node key (B), the same node id. `Restore-OS7` → 280, reboot: the dataset mounted there too, B answers, the peer answers (§8) |
| timer | 1.104.5 by hand; `os7-vendor-update.timer` active with its next elapse scheduled; the service exits 0 in 22 s, back at 1.104.6, the same node running, its state still on the dataset |
| ssh | `tailscale set --ssh=true` and `--auto-update=true` typed by hand: both reported as attention; both `Set-OS7Tailscale … $true` refused with the client unchanged; `… $false` switches each off, and the client agrees |
| uninstall | `-KeepIdentity`: removed (not purged), source unregistered, unit not masked, dataset and state kept, Headscale still lists the node. `Install-OS7Tailscale`: `Installed`, and the SAME node back with no login. `-RemoveState`: dataset and mount point gone, the client logged out (`client.Logout()` in its journal), layout `None` |
| keylogin | a fresh install says `NeedsLogin` and names the command; a missing secret is refused by name; a key Headscale never issued fails with the login job's own sentence — *"…the login job tailscale-login-14f6a2cd failed: tailscale up did not log in: backend error: handling register with auth key: failed to parse auth-key: key too short, expected at least 77 chars after prefix, got 32"*; a real key: Running, `100.64.0.2`, `tag:os7-bench`, the updater `False` and SSH off in the client's own prefs (M-TS17 on a machine). The key is in no journal line and in no file under `/var/lib/os7-automation`, `/var/log` or `/run` |
| urllogin | logout; `Connect-OS7Tailscale` printed the login URL and waited; approved in Headscale (`headscale auth register`) 15 s later: Running, the updater `False` after this login too, a node of `lab@`, untagged |
| va16 | with `tailscale0` up: *"100.70.0.1/24 overlaps this machine's tailnet (Tailscale drops traffic from it on every other interface), 100.64.0.0/10."* — refused before anything was written; ranges outside it pass the check |

## 8. A rollback across a vendor update (O-M4)

Recorded directly by the phase run on its own a second time (8 checks, 0 FAIL; the evidence run in §7 predates the two lines that print the versions). In 1.0.0.283, Tailscale 1.104.6 wrote identity B's state onto the dataset; 1.0.0.280 carries
1.104.5 (VAL1). After `Restore-OS7`:

* **The dataset is mounted in 280 as well**, although it was made in 283 and nothing in 280 knew
  of it: OS/7 has no `zfs-list.cache`, so `zfs-mount.service` mounts by property, and `overlay` is
  `on`, so the non-empty directory underneath does not stop it.
* **1.104.5 read 1.104.6's state and answered as B**: Running, the peer reachable. O-M4 is answered
  for a patch-level step, and no further.
* **Underneath the mount, 280's own `/var/lib/tailscale` still holds identity A's
  `tailscaled.state` — 2330 bytes, the private key of the node as it was before the adoption.**
  `-Adopt` deletes the copy in the environment it runs in and cannot reach older ones (VAL10). On
  this control server the copy is dead weight rather than a second identity, because the re-login
  replaced A's key on the same machine key (§10).

## 9. Three defects a machine found while every check was green

1. **`-Confirm:$false` does not cross a module boundary (BUILD-NOTES #203).** `Install-OS7Tailscale
   -Adopt -Confirm:$false` died at its first step: `Stop-SystemdUnit` is `ConfirmImpact = 'High'`
   in the Systemd module, which resolves `$ConfirmPreference` through its own session state, so it
   prompted — and under `-NonInteractive` a prompt is an exception. Every other caller in
   `powershell/OS7` already passed `-Confirm:$false`. Fixed at all five systemd calls in the role;
   `check-ps-traps.py` has a seventh rule for it, at 0, proven to fire on the defect planted back.
2. **The identity was read before the daemon had one.** After `-Adopt` started the daemon from the
   dataset, it read the node id at once; `status` said `Starting` with no id, the identity check
   said *"before 2, after "*, and the adoption refused itself and kept the old state aside at
   `/var/lib/tailscale.os7-replaced-<time>` — the right outcome for a check that cannot tell, and
   the wrong one for an adoption that had worked. `start-daemon` now waits up to 60 s for a node
   that was enrolled to leave `NoState`/`Starting`; one that cannot reach its control server stays
   there, and the check then fails for the reason it should.
3. **An empty mount point read as an identity.** `zfs destroy` leaves the mount point behind
   (measured), and `Get-OS7TailscaleLayout` keyed on the directory: after `Uninstall-OS7Tailscale
   -RemoveState`, `Get-OS7Tailscale` said `InBootEnvironment`, and the next `Install-OS7Tailscale`
   would have refused to install over an identity that did not exist. The layout now keys on
   `tailscaled.state` — what a daemon that has run once leaves — and `-RemoveState` removes the
   empty directory. `check-tailscale-logic.py` P10 holds it, with a thirteenth plant (74 checks).

None of the three was reachable from the logic check as it stood: the first is a property of a
stubbed callee's declaration, the second is time, the third is what ZFS leaves on a disk.

After the fixes, green on 2026-11-12: `check-tailscale-logic.py --prove` (74 + 13 RED),
`check-ps-traps.py` (seven held; #203 proven to fire on a copy), `check-layering.py` (ten rules),
`check-privilege.py` (at its baselines), `check-module-parts.py` (45).

## 10. What else the machine said

* **`is-enabled` says `disabled` for a running timer.** `os7-release` enables
  `os7-vendor-update.timer` and `os7-update-check.timer` by a symlink in
  `/usr/lib/systemd/system/timers.target.wants/`; `systemctl is-enabled` reads `/etc` and answers
  `disabled` for both while `systemctl list-timers` shows their next elapse. An administrator who
  asks the obvious question gets the wrong answer. Not changed here — it is the update check's
  shape since it shipped — and noted.
* **Headscale reuses the node id by machine key.** A logout and a new login with a key gave node 2
  again with a new node key; the old key is refused from then on.
* **Headscale does not expire a TAGGED node on logout.** After the client's own `client.Logout()`
  the tagged node stayed `Expired: no`; the same verb on `lab@`'s untagged node was expired at once
  (the control in `urllogin`). That is the control server's policy, which this lab does not stand
  for ([SESSION-TAILSCALE.md](SESSION-TAILSCALE.md) §2, O-M7). What OS/7 owns — that the client
  logs out before the package goes — is checked on the client.
* **The login URL reaches the operator after ten seconds.** `Connect-OS7Tailscale` takes it from
  `tailscale up --json --timeout=10s`, which holds it until it gives up. A person cannot approve
  before seeing it, so nothing is lost but the ten seconds.
* **`Update-OS7` moved Tailscale 1.104.5 → 1.104.6 in the clone** — the vendor published .6 that
  afternoon — and said so in `VendorPackages`, class `Registered`, beside three Microsoft packages
  of class `Image`.

## 11. How the harness misled on the way

Five red results were the harness's own, each a measurement mistake this repository has made
before in another form:

* **A running Go daemon keeps the roots it read first.** The lab's CA is new on every run; put into
  the system store while `tailscaled` ran, `curl` trusted it in the same second `tailscaled` logged
  `x509: certificate signed by unknown authority`, and the documented login timed out. The bench
  preparation restarts the daemon after `update-ca-certificates` (BUILD-NOTES #204).
* **A machine snapshot is half of a pair.** The identity lives in the machine and in Headscale's
  database, and the database moved on: restored from `tsrun-updated` after a later phase had logged
  that node out, the machine came up `NeedsLogin`. Every snapshot is now taken and restored with a
  copy of the database.
* **A booted node is `Starting` for a few seconds** — defect 2's race, in the harness: the timer
  phase's "before" was read there. It waits after every boot.
* **`is-enabled` was the wrong question** for these timers (§10); it asks whether the timer is
  active and has a next elapse.
* **A harness approves faster than a person can.** Reading the URL off the daemon and approving at
  once finished the login inside `up`'s ten seconds, so `Connect-OS7Tailscale` never printed the
  URL or entered its wait — the path a person takes went unmeasured, green. It now waits 15 s.

`--overlay` lays a repository file over the installed module after each boot, for iterating on a
defect without a release per attempt. It says so on every boot, and the run in §7 used none.

## 12. Not done here

* **arm64.** The harness refuses a host whose QEMU does not run inside Docker Desktop — the relay
  is announced at that host's address — and no arm64 boot was measured.
* **Tailscale's own control plane**, by the owner's rule: a tagged node's logout, version
  announcements, key expiry defaults (O-M7).
* O-M3 (an SSH session over the tailnet across the timer's restart), O-M5 (two registrations on one
  origin), O-M6 (Active Directory's logon rules over Tailscale SSH).
* The administrator manual's chapter (Phase 3), and an image: no ISO carries the role; it reaches a
  machine in a release's `os7-module` package, as here.
* `Test-HardwareModule` and `Test-OS7Update` still have #202's shape.
