# Session — the Tailscale role (VENDOR-APPS-PLAN Phase 2, steps 6 and 7)

**2026-11-10, x64 Windows host.** Built on top of Phase 1
([SESSION-VENDOR-SOURCES.md](SESSION-VENDOR-SOURCES.md)) after the owner's "Phase 2". Recorded on
bench `ts` (amd64, from snapshot `p1-280`: 1.0.0.280 with the registered Tailscale source and
tailscale 1.104.5 installed by Phase 1) against the local Headscale lab of
[SESSION-TAILSCALE.md](SESSION-TAILSCALE.md) §2 — no real tailnet was touched. **The role has NOT
run end to end on a machine**: §7 says what is owed. No ISO was built.

## 1. What was built

| Piece | Where | Held by |
|---|---|---|
| The ninth generic layer: `Get-TailscaleVersion`, `-Status`, `-Preference`, `Connect-`, `Disconnect-`, `Set-TailscalePreference`, `Test-TailscaleModule`. The CLI's JSON, one invoker (`Invoke-TailscaleCommand`, not exported), the key only as `--auth-key=file:<path>`, SSH and the client's updater switchable OFF only | `powershell/Tailscale/` | `Test-TailscaleModule`, 40 checks against 16 recorded outputs |
| P2-tailscale — `powershell/OS7` reaches the client only through it. Baseline **0**. It matches the program by PATH (`/usr/bin/tailscale`), the `& env` form and the LocalAPI socket, because the way round the layer that Phase 0 actually used was a `Start-OS7Job -Command '& /usr/bin/tailscale up …'` string, which `direct()` cannot see. The package name is deliberately not matched. Proven to fire on four planted forms | `installer/testing/check-layering.py` (ten rules) | itself |
| `Get-`, `Install-` (with `-Adopt`), `Connect-`, `Disconnect-`, `Set-`, `Uninstall-OS7Tailscale`; the judgements as two pure functions (`Get-OS7TailscaleAttention`, `Get-OS7TailscaleInstallPlan`) and the login job's command as a constant | `powershell/OS7/OS7.Tailscale.ps1` | `check-tailscale-logic.py` |
| VA16: the container host's range check refuses `100.64.0.0/10` whenever a `tailscale0` link exists | `OS7.Container.ps1` | nothing yet — code only |
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

## 7. Not done here — owed by §7 step 8

* **The role on a machine, end to end**: `-Adopt` of the Phase 1 machine's state (which is in the
  boot environment) with the SAME node answering afterwards, `Update-OS7` 280 → 281 with the
  source registered, a rollback that keeps the identity (and what `/var/lib/tailscale` is in the
  older environment, where a directory sits under the dataset's mount point), the timer, Tailscale
  SSH reported and switched off, `Uninstall -KeepIdentity` and a reinstall that is the same node,
  `Uninstall -RemoveState`, a fresh install logged in from the secret store with `Apply` false
  afterwards, a login by URL approved in Headscale, and VA16's refusal.
* **`run-tailscale.py`** — the harness for that, with the lab (Headscale's configuration, the
  client's Dockerfile) under `installer/testing/` and the CA and every key generated per run.
  The lab used here lives outside the repository.
* A release **1.0.0.281** was built from this tree into the bench's repository (`os7lab.py
  release ts`, 14 packages, index signed and verified). No machine has taken it.
* The administrator manual's chapter (Phase 3), and arm64.
