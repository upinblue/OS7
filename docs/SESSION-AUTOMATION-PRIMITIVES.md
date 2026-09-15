# Phase 1 of the automation host, and the four things a machine corrected

**2026-09-14.** `docs/AUTOMATION-PLAN.md` phase 1 — AU2, AU3, AU4, AU5, AU6,
AU7, AU8, AU11 — built, and run on an installed amd64 machine. Every decision in
that document was *Proposed* and nothing in it had been near a computer; this
session measured first, built second, and the measurements corrected the plan
three times before a line of it was implemented. A machine then corrected the
implementation three more times.

Host: x64 Windows + Docker Desktop. Machine: `os7lab.py` bench `manual`, an
installed 1.0.0.175 amd64 disk, booted with `--no-gui`, under **non-enforcing
firmware** — the kernel says `secureboot: Secure boot disabled`, which is the
control M-AU1 asked for and got for free.

---

## 1. What was measured before anything was written

### M-AU1 — `systemd-creds` on the shipped image

**Four findings, and three of them change the plan.**

**(a) `--with-key=host+tpm2` binds to NO PCRs by default.** The plan's AU2 said
the opposite — *"The second is stronger and inherits #69/#100: a shim or `dbx`
update moves PCR 7 and the blob stops opening"* — and AUL2 was sized from it:
*"a shim or `dbx` update can make every stored secret unopenable"*.

The image's own man page says otherwise:

> `--tpm2-pcrs=` … If an empty string is specified, binds the encryption key to
> no PCRs at all (this is also the default if this option is not used).

and the machine agrees. `tpm2_pcrextend` is on the image, so PCR 7 was moved for
real rather than argued about:

```
PCR 7 before   127C18EBA2300E30767FAFE71F4E5975776F665D22C7CA9017C7C24846B96FA1
PCR 7 after    709725BA583F65DA4CEF491C8CC46FDD5AFA50756863CEE61BFA4AA118EC576D

default blob   M-AU1-secret-value-0001                        rc=0
--tpm2-pcrs=7  TPM policy does not match current system state: Operation not permitted
```

That second line is BUILD-NOTES #69's own sentence, and it appears only when the
binding is asked for by name. **AUL2 shrinks from "every secret" to "every
secret whose creator passed `-Pcrs`."**

**(b) Both `host` modes depend on a file INSIDE the boot environment.** This is
the finding that decides the sealing target, and nothing in the plan had looked
for it. `systemd-creds`' host key is `/var/lib/systemd/credential.secret`, and
on an OS/7 machine:

```
# df --output=source,target /var/lib/systemd/
rpool/ROOT/os7_1.0.0.175_202609030759   /
# zfs list | grep var/lib
rpool/ROOT/os7_1.0.0.175_202609030759/var/lib   /var/lib   off
```

`/var/lib` is inside the boot environment. Moved aside — which is what a
rollback to an ancestor environment does — the two host modes die and the third
does not:

```
k-host   Failed to determine local credential key: No such file or directory
k-both   Failed to determine local credential key: No such file or directory
k-tpm2   M-AU1-secret-value-0001
```

A *different* key in place gives the same two failures (systemd validates the
file and treats a hand-made one as absent).

So: **AU6 puts secrets outside the boot environment, and `host+tpm2` would have
put their KEY back inside it.** `New-OS7Secret` defaults to `-SealTo tpm2`,
which is not systemd's own default, and the help says why. A machine with no
TPM is told so and has to choose `host` deliberately.

**(c) `LoadCredentialEncrypted=` delivers exactly as AU2 describes.** Measured
rather than assumed, and every word holds:

```
CREDDIR=/run/credentials/mau1-probe.service
-r-------- 1 root root  20 probe
tmpfs ro,nosuid,nodev,noexec,relatime,nosymfollow,size=1024k,mode=700,inode64,noswap
… unit stops …
GONE
```

**(d) `systemd-creds has-tpm2` is deprecated in systemd 259** and prints
*"The 'systemd-creds has-tpm2' command has been replaced by 'systemd-analyze
has-tpm2'. Redirecting invocation."* **on stdout** before answering.
`Test-SystemdTpm2` asks `systemd-analyze`, so the answer is an answer and not a
sentence about a command name.

*(A trap met in passing and worth one line: `%a` and `%U` in an `ExecStart=`
are systemd SPECIFIERS. A probe running `stat -c "mode=%a owner=%U:%G"` printed
`mode=x86-64 owner=0:0` — systemd substituted the architecture and the user
before `stat` ever saw them. `Register-OS7ScheduledTask` already escapes `%`
for this reason.)*

### M-AU4 — does a transient timer survive a reboot?

No, as expected — and the interesting half is that **nothing anywhere says it
went**. Full transcript and consequences in **BUILD-NOTES #154**.

---

## 2. What was built

| | |
|---|---|
| `powershell/Systemd/` | `Test-SystemdTpm2`, `New-SystemdCredential`, `Unprotect-SystemdCredential`, `New-SystemdUnitDropIn`, `Remove-SystemdUnitDropIn`, and `-NoBlock` on `Start-SystemdUnit`. 21 → 26 functions |
| `powershell/Directory/` | `New-DirectoryTicket` gains `-Keytab` and `-CachePath`; `Get-`/`Remove-DirectoryTicket` gain `-CachePath`. AU7 is otherwise unbuildable without `powershell/OS7` naming `kinit`, which P2-directory forbids |
| `powershell/OS7/OS7.Automation.ps1` | the product layer: 16 cmdlets, listed in [POWERSHELL-REFERENCE.md](POWERSHELL-REFERENCE.md). 147 → 164 functions |
| `build/packages/os7-automation/` | `os7-automation.slice`, `os7-job@.service`, `os7-job-run.ps1`, `49-os7-job.rules` |
| `installer/testing/check-automation-logic.py` | 48 checks; 9 planted defects, all of which fire |
| `installer/testing/check-layering.py` | **P2-automation**, baseline 0 — seven rules |

**`Start-OS7Job` widens the proven pattern rather than adding a second one**,
which was the one non-negotiable in the brief. `os7-job@<id>.service` is
`os7-update@<version>.service`'s shape pointed at a different kind of work:
a packaged template unit, started through `Start-SystemdUnit`, governed by
polkit, with progress in the unit's journal. What phase 1 adds is the credential
(`LoadCredentialEncrypted=`), the input channel (`StandardInput=file:`) and the
fence — not a new way to start work. `systemd-run` was rejected explicitly, and
P2-automation now keeps it out of `powershell/OS7` by check.

**The fence is in the package, not in the cmdlet.** Everything that is the same
for every job on every machine — the slice, `ProtectSystem=strict`,
`ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, `PrivateDevices`, the input
channel — is in a unit file that is signed by the repository, readable by an
auditor, greppable by a check and rolled back with the release. `Start-OS7Job`
writes only the per-run drop-in under `/run`.

---

## 3. What the machine corrected, after every check on the host was green

This is the part worth reading. Three defects, none of which any instrument in
`installer/testing/` could have found, in an implementation whose checks were
passing.

**(1) `New-OS7ServiceDataset` did not create the directories its own error
message promised.** The dataset was created, mounted and verified against ZFS.
The next cmdlet said:

```
no secret store at /var/lib/os7-automation/secrets.
New-OS7ServiceDataset -Name os7-automation creates it.
```

It did not. BUILD-NOTES #148's family — a message naming a verb that does not do
what the message says — and invisible to the logic check for a precise reason:
**the check made the directories itself before it started**, because it drives
the cmdlets against a scratch tree. A fixture that prepares the world hides
every defect about preparing the world.

**(2) `Get-OS7Job` threw instead of returning.** `The property 'result' cannot be
found on this object.` The job journal is written by **two** parties with
**different fields** — `Start-OS7Job` writes the intent, the runner inside the
unit writes the result and knows `exitCode`, `credentials` and `ticket` that the
starter does not. Reading `.result` off the runner's record is #112/#119 exactly:
under `Set-StrictMode -Version Latest` a missing property is terminating, so the
cmdlet returned *nothing* rather than a job with a blank column.

**(3) `RuntimeMaxSec=` is ignored for `Type=oneshot`, so no job had a timeout.**
The unit carried the directive, the check asserted the directive, systemd loaded
the unit — and said so in its own journal while doing nothing about it. Full
entry, and the three rules it is an instance of, in **BUILD-NOTES #155**. The
third is the uncomfortable one: `os7-update@.service` has had this right since
the day it was written, and the file whose header says it WIDENS that proven
pattern reached for a different directive.

---

## 4. What ran on the machine

After the three fixes, on bench `manual`:

```
AU6   rpool/DATA/lib/os7-automation → /var/lib/os7-automation
      canmount=on  Mounted=True  InBootEnvironment=False  BackupPolicy=added
      and /var/lib/os7/x REFUSED, naming the boot environment and why

AU2   svc-probe sealed to tpm2, 564 bytes, blob 600 root:root, Openable=True
      Get-OS7Secret as JSON: every field, and not one that could hold a value

AU8   probe-resource held by "pid 5632 (pwsh)" since 19:03:01, Stale=False
      second caller: "'probe-resource' is held by pid 5632 (pwsh) for 0 minutes"

AU3   the job printed:  the job ran as uid 0, input scope=all
      — one JSON document, on stdin, put there by StandardInput=file:

AU2   the record says   credentials: ["svc-probe"]
      — the job saw the secret in $CREDENTIALS_DIRECTORY

AU5   19:03:01  Intent   … startedBy: os7admin, secrets: ["svc-probe"]
      19:03:02  Result   … exitCode: 0, ranBy: os7-job-run
      19:03:03  Note     … unitGone: true, startedOk: true
      journal mode 640 root:adm
      — the intent is on disk a second and a half before the result

AU4   asked of systemd, of the unit that actually ran:
      Slice            os7-automation.slice
      ProtectSystem    strict
      ProtectHome      yes
      PrivateTmp       yes
      NoNewPrivileges  yes
      MemoryMax        268435456
      TasksMax         32
      TimeoutStartUSec 8s          (after #155; RuntimeMaxUSec infinity)

M-AU1c /run/credentials/os7-job@probe-22edae9c.service: GONE
```

and the timeout, proven by a job that sleeps for 300 seconds with
`-TimeoutSec 8`:

```
os7-job@tmo-2dcae3f3.service: start operation timed out. Terminating.
os7-job@tmo-2dcae3f3.service: Failed with result 'timeout'.
DurationSec : 8.268
```

---

## 5. What was NOT run, and is still owed

Said plainly, because a session that cannot run something should say so rather
than leave the next reader to assume it was run.

* ~~**No ISO carries any of this.**~~ **`OS7-1.0.0.222-amd64.iso` does**, built
  here on the fifth attempt, and `check-image.py amd64` says so of the artefact
  rather than of the build log:

  ```
  ok    os7-automation is installed at 1.0.0.222
  ok    dpkg -S: /usr/lib/systemd/system/os7-job@.service belongs to os7-automation
  ok    dpkg -S: /usr/lib/systemd/system/os7-automation.slice belongs to os7-automation
  ```

  Asked of **dpkg**, which is the point: a file placed by a hook and a file owned
  by a package look identical on a running machine, and only the second rolls
  back with the release. `os7-automation` is a `Depends` of both `os7-server` and
  `os7-desktop`, the way `os7-backup` is.

  **That medium is NOT shippable and the check says which four things are wrong
  with it:** it was built with `OS7_REPO_NO_CREDENTIAL=1`, so it carries no
  repository credential and the four failures are all that one fact. The build
  REFUSES to produce such a medium without the override, which is how the
  override came to be typed.

  **Four failed builds to get there**, and three of them were worth the time —
  BUILD-NOTES #156, #157 and #158. The module changes had reached the bench by
  `os7lab.py push` over a 1.0.0.175 install; that is no longer the only evidence.
* **`New-OS7JobTicket` has never obtained a ticket.** AU7's private cache is
  asserted in the drop-in (`KRB5CCNAME=FILE:%t/os7-job/<id>/krb5cc`, checked) and
  the Directory layer's `-Keytab`/`-CachePath` path has not been exercised
  against the Windows Server 2025 test DC. **M-AU7 stands.**
* **`Send-OS7Notification` has never delivered anything.** The check proves one
  result per sink and that a failure is named; no mail has been sent and no
  webhook received. What IS measured about the no-MTA correction is exactly one
  thing and it is worth stating narrowly: `System.Net.Mail.SmtpClient` and
  `MailMessage` **resolve in the pinned pwsh 7.6.5 on Linux** (asked of the
  container the logic check runs in). A type that resolves is not a mail that
  arrives — a relay that refuses the envelope sender, a TLS requirement, an
  authenticated submission port are all unexercised.
* **`-DynamicUser` has never been used.** AUL4 is confirmed only by refusal:
  `-DynamicUser` with `-Keytab` is rejected as two answers to one question.
  **M-AU5 stands.**
* **`-Unconfined` has never run a job.** The drop-in it writes is checked; a job
  under it has not run. **M-AU3 stands** — nobody has yet run a representative
  operator script under `ProtectSystem=strict` and recorded what breaks, which
  is what would size AUL5 with a number.
* **A secret across a rollback has not been shown.** M-AU8 is now *cheaper* than
  the plan thought, because the sealing target no longer depends on a file in
  the boot environment — but "cheaper" is not "done".
* **arm64 is unmeasured.** AUL7, as usual.
* **polkit was never exercised.** Every run here was root. The rule is
  `os7-update`'s, narrowed to `os7-job@`, with `AUTH_ADMIN` rather than
  `AUTH_ADMIN_KEEP` — and no unprivileged caller has started a job.

---

## 6. What this changes in the plan

Corrections written into [AUTOMATION-PLAN.md](AUTOMATION-PLAN.md), each with the
measurement behind it:

1. **AU2's sealing target is decided: `tpm2`, no PCRs.** Open question 1 is
   closed, by M-AU1(b) rather than by preference.
2. **AUL2 is much smaller than written.** No PCRs by default means a shim or
   `dbx` update does not silently disarm a machine's automation. The escrow
   question (DECISIONS open question 7) is still open; it is no longer on the
   critical path for a secret store.
3. **AU11 needs no MTA.** §1 recorded *"no MTA is in any package list, so a
   machine that wants to send a mail today cannot"*, and §8 put AU11 last
   because installing one costs a build. SMTP submission to the organisation's
   relay is a TCP conversation and `System.Net.Mail` ships inside pwsh. Not
   installing an MTA is now the decision rather than the obstacle: an MTA would
   add a spool, a queue, a second retry policy and a listening socket to a
   machine whose bad news is better delivered synchronously or not at all.
4. **Open question 3 is answered: root, inside the fence, and recorded.**
   `-Identity` and `-DynamicUser` opt out. The reasoning is uncomfortable and is
   stated where somebody can disagree with it: a job that must write its own
   state, hold a keytab and append to the machine journal cannot be a dynamic
   user (AUL4), and a job run as the CALLER would make the fence depend on who
   typed the command.
5. **Open question 4 is answered: yes, the journal's schema is a contract**, and
   every record carries `schema: 1` from the first line written — which cannot
   be added retroactively.
6. **AU11's sinks live on the AU6 dataset, not beside the module.** The plan said
   *"beside the module, the shape `Get-OS7Endpoint` already uses"*;
   `os7-endpoints.json` ships in the package and is identical on every machine,
   while a sink is this machine's configuration. Beside the module it would be
   inside the boot environment — and the first thing a machine wants to say
   after a bad update is that the update was bad.

---

## 7. The instruments, and what each one cannot see

| | |
|---|---|
| `check-automation-logic.py` | 48 checks. **It runs itself in a container on a non-Linux host** — `SetUnixFileMode` throws on Windows and `/proc/<pid>` is how AU8 decides staleness, so two rules are simply not expressible there. `--self-test` plants nine defects and requires every one to fire |
| `check-layering.py` | seven rules. **P2-automation**, baseline 0, keeps `systemd-creds`, `systemd-run` and `systemd-analyze` out of `powershell/OS7`. Proven to fire against a planted `Invoke-OS7Native -Command 'systemd-creds'` |
| `check-privilege.py` | **both baselines held** — OS7 42/42, the generic layers 41/41 — and half of #149 is now decided: the four new mutating verbs in `powershell/Systemd` carry `Assert-SystemdElevated`, the same `/proc/self/status` read in the module's own file, so nothing calls upward and P2 still points one way. The scan accepts any `Assert-*Elevated`. The forty-one that predate it are NOT retrofitted, deliberately: adding a guard to a cmdlet whose behaviour nothing has re-tested is a change made to satisfy a check |
| `check-module-parts.py` | green. It caught the reference file drifting by 21 functions on the first run after the module grew, which is what it is for |
| `check-ps-traps.py` | six rules, all held at 0 |
| `check-image.py` | **it had stopped running on this host entirely** and the first attempt to use it found that rather than anything about the image (#158). Now green on `OS7-1.0.0.222-amd64.iso` apart from the four credential checks the `OS7_REPO_NO_CREDENTIAL=1` build deliberately fails |

**And three checks gained a rule that each cost a build**, which is the honest
measure of this session's second half: `check-module-parts.py` now holds the
packages as well as the module files — every `os7-*` a metapackage depends on
must be named in hook 0022 (#156) — and holds every shell file against the
literal `\n` that is not a line continuation (#157). Both are proven to fire
against the exact defect that cost the build.

**What none of them could see** is §3: a directory that was never created, a
property read that throws under strict mode, and a directive systemd ignores.
All three needed a machine, and all three were found in the first twenty minutes
on one.
