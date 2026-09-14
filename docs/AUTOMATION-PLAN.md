# OS/7 as an automation host

**Status: every decision here is *Proposed*. Nothing in this document has been run on a
machine.** Written 2026-09-14 from reading the module surface and from one customer
requirement list; the inventory in §5 is read out of the source, the rest is design.

This plan decides what **the operating system** owes an automation workload, and — just as
deliberately — what it does not. A product that provisions identities, holds approvals and
governs entitlements is described in a separate concept document that is **deliberately not in
this repository** — this one is public, that one is commercial. This file is the machine
underneath it, and is useful without it: nothing below depends on that product being built.

---

## 1. What was measured, and what was not

**Measured** (by reading this repository's own source, 2026-09-14):

- `Register-OS7ScheduledTask` accepts `Name, Command, Execute, Arguments, Daily, Weekly,
  DayOfWeek, At, OnCalendar, User, Description, Persistent, RandomizedDelay, Disabled, Force`
  — and therefore **no resource limit, no timeout and no isolation parameter of any kind**
  ([powershell/OS7/OS7.ScheduledTask.ps1](../powershell/OS7/OS7.ScheduledTask.ps1)).
- There is **no `*-OS7Secret`**, **no lock verb** and **no notification verb** anywhere in
  `powershell/`. `New-OS7Storage`, `Enable-/Disable-/Get-OS7Remoting`,
  `New-OS7KerberosTicket`, `Write-OS7UpdateLog` and `Write-OS7BackupLog` do exist.
- **No MTA is in any package list**, so a machine that wants to send a mail today cannot.
- **`systemd-creds` and `LoadCredentialEncrypted` appear nowhere in this repository** — not
  in a plan, not in a hook, not in a unit.

**Measured by somebody else, on a machine, while this plan was being written** (`f9ca2b5`,
2026-09-14, GUI-APPS-PLAN O-G6): an unprivileged process can have root work done for it by a
**templated systemd unit started through `Start-SystemdUnit`, with polkit prompting and the
unit's journal carrying progress** — no D-Bus library, no local service, no change to the
cmdlet doing the work. AU10 was written from the other direction and reaches the same
mechanism; that is the strongest single fact in this document and the only one that has been
near a computer.

**Not measured, and named as such wherever it is relied on below:**

- Whether `systemd-creds` on the shipped image can seal against the same TPM that already
  holds the LUKS key, and what a PCR 7 change does to a sealed credential (AU2, M-AU1).
- Whether a transient systemd timer survives a reboot. The expectation is **no** — transient
  units live under `/run` — and AU12 is written on that expectation (M-AU4).
- Every performance claim. There are none in this document on purpose.

**The customer requirement list that motivated this plan is not its authority.** It is one
document from one organisation (82 rows, an IGA questionnaire). Where a decision below was
prompted by a row, the row is cited as motivation and nothing more.

---

## 2. AU1 — The operating system provides primitives; a product above provides policy. Proposed 2026-09-14.

An earlier draft of this work put runs, plans and a connector contract into
`powershell/Automation/`. That was right only while nothing sat above it. With a product
above, it is **the engine twice, in two languages, with nobody at the seam** — BUILD-NOTES
#66 exactly, which this repository has already paid for at full price with the installer's
TPM step and is currently paying off a second time with the two-language netplan renderer
(P3).

So:

| The OS owns | A product above owns |
|---|---|
| running a process with an identity, limits, a timeout and isolation | what should be run, and why |
| holding a secret and handing it to a process | which target system the secret belongs to |
| recording what the machine did | recording what anybody intended |
| durable storage that a rollback does not un-say | what is stored in it |
| delivering content to machines, signed | what the content means |
| a schedule for the machine's own jobs | a schedule for business work |

**The test, and it is decidable by grep:** if a cmdlet in this surface contains the word
*approval*, *target system*, *role*, *entitlement* or *connector*, the boundary has moved.

`Register-OS7ScheduledTask` stays what it is — "what runs on **this machine** on a schedule".
It is not the seed of a workflow engine. That is P9's argument (a timer is a noun, not a
service type) applied one level up.

---

## 3. Decisions

### AU2 — A secret is sealed by systemd, delivered to the process, and never returned to the caller. Proposed 2026-09-14.

Today P7 says how a cmdlet *handles* a secret, and `Register-OS7ScheduledTask` says a task
"reads it from a root-owned 0600 file at run time" — **while no such store exists**. That
sentence has been describing a mechanism nobody built.

The mechanism is already on the machine: `systemd-creds encrypt` writes an encrypted blob,
`LoadCredentialEncrypted=` in a unit decrypts it into `$CREDENTIALS_DIRECTORY` — a tmpfs,
mode 0400, owned by the unit's user, **unmounted when the unit stops**. It is never on a
command line, never in the environment (which `/proc` shows to other users), and never in
the caller's memory.

Therefore:

- **`New-OS7Secret`** takes a `[securestring]`/`[pscredential]` and writes a sealed blob.
- **`Get-OS7Secret`** returns **metadata only** — name, created, sealed-to, last delivered.
  It cannot return a value, because a value that can be returned can reach `ConvertTo-Json`,
  and P7 forbids that.
- **`Unprotect-OS7Secret`** is the deliberate exception, returns `[securestring]`, and exists
  for the cases the unit mechanism cannot reach. Its use is a smell, not a pattern.
- **Delivery to a job is by unit directive, not by cmdlet.** `Start-OS7Job -Secret <name>`
  arranges `LoadCredentialEncrypted=`; the job reads `$env:CREDENTIALS_DIRECTORY`.

**Secrets live outside the boot environment**, and the reason is D10's own deciding rule: a
rolled-back credential is one the other side has already rotated away from, so a rollback
would make the system *less* correct. **This is the third time this question has appeared** —
`/etc/krb5.keytab` (DECISIONS open question 9) and `/etc/shadow` (SETUP-PLAN L26) are the
same question in two other places, and open question 9 says explicitly that deciding one
without the others is deciding half of one question twice. AU2 does not resolve those; it
joins them.

**Sealing target is undecided.** `--with-key=host` ties the blob to this machine's key;
`host+tpm2` adds the TPM. The second is stronger and inherits #69/#100: a shim or `dbx`
update moves PCR 7 and the blob stops opening, with the same escrow gap DECISIONS open
question 7 already records. M-AU1 decides it.

### AU3 — A job's input arrives on stdin as one JSON document. Proposed 2026-09-14.

Not the environment: `/proc/<pid>/environ` is readable by the same user and by root, and a
job's input routinely carries an identity, a department and a manager's address. Not the
command line: it is world-readable in `ps` and in systemd's own tooling, which
`Register-OS7ScheduledTask` already says in capitals. Not a file, unless it is too large,
because a file has a lifetime and someone has to end it.

One document, on stdin, closed. The job parses it or fails. Motivated by R41 ("all relevant
parameters passed automatically to the script"), and the mechanism is the answer to *how*,
which that row does not ask and needs.

### AU4 — Every job runs in a slice, with limits, a timeout and isolation, and the defaults are restrictive. Proposed 2026-09-14.

`os7-automation.slice` with `MemoryMax`, `CPUQuota` and `TasksMax`; each job with
`RuntimeMaxSec` (the kill for a job that will not end), `PrivateTmp=yes`,
`ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges=yes`, and `DynamicUser=yes`
wherever the job does not need a named identity.

The motivating case is a product above running **customer-authored scripts** (R42). A script
that allocates until the machine dies takes the audit trail's writer with it. systemd has
done this for a decade; nothing here is new except that it is switched on and stated.

**Restrictive by default and widened explicitly** — `Start-OS7Job -Unconfined` exists, names
what it gives up in its help, and appears in the job record so an auditor can see which jobs
ran without a fence.

### AU5 — The job journal is the machine's record, is append-only, is written before the action, and is outside the boot environment. Proposed 2026-09-14.

Two records, **not one**: a product above records *intent* (who asked, who approved, which
object), and the machine records *what it did* (at 14:02 a process ran as `svc-prov` for
1.3 s and exited 0). The second is what makes the first checkable, and the rule it serves is
BUILD-NOTES' oldest: **a diagnostic must not depend on the subsystem it is diagnosing.** An
IGA product's own audit trail attesting to its own writes is exactly that dependency.

Mechanics: JSON Lines, one file per day, `0640 root:adm`, on the dataset from AU6, **written
and flushed before the action starts** and completed after it. A run killed mid-step
therefore leaves an intent with no result — which is precisely the state a product above
must be able to detect in order to re-plan rather than re-run.

**It is not `journald`, and that is not a contradiction of the application work.** The
Software Update window reads *progress* out of a unit's journal (GUI-APPS-PLAN O-G6, measured
on a machine), and that is right — journald is the correct place for "what is this run doing
right now". It is the wrong place for "what did this machine change, eight months ago, in a
way an auditor will read": journald rotates, is not append-only in the sense an auditor
means, and lives inside the boot environment's `/var/log` policy. **Progress and evidence are
two questions, and only one of them has a retention requirement.**

### AU6 — Durable service state is a dataset outside the boot environment, provisioned by a cmdlet that reads it back. Proposed 2026-09-14.

D10 gives the rule and `New-OS7Storage` gives the install-time layout; what is missing is the
verb a service uses at any other time.

`New-OS7ServiceDataset -Name os7-automation` creates `rpool/DATA/lib/os7-automation` at
`/var/lib/os7-automation`, sets the properties explicitly (#63 — a clone carries neither
`canmount` nor `mountpoint`), enters it into the backup policy, and **asks ZFS back** rather
than reporting four commands that exited 0.

**`/var/lib/os7` is the wrong place and this must be said, because it is the obvious one.**
It is inside the boot environment — deliberately, because C10's migration record has to keep
rolling back with the release. A secret or an audit record under it would roll back with it.

### AU7 — A job that needs a domain identity gets its own ticket cache from a keytab. Proposed 2026-09-14.

`KRB5CCNAME` into the job's runtime directory, obtained at job start from the named keytab,
renewed before expiry, destroyed with the unit. Never the machine's default cache, because
two jobs sharing one cache is two jobs sharing one identity and a race over its lifetime.

`New-OS7KerberosTicket` exists; what it does not have is the keytab-and-private-cache shape.

### AU8 — Mutual exclusion is a named lock that says who holds it and since when. Proposed 2026-09-14.

`Update-OS7` already has `/run/os7-update.lock`; there is no general form.
`Lock-OS7Resource` / `Unlock-OS7Resource` / `Get-OS7Lock`, under `/run/os7/locks/`, each
carrying holder and acquisition time — because the question an operator actually has is not
"is it locked" but "who has it and should I be worried".

Locks are in `/run` and therefore do not survive a reboot. That is correct and must be
written down: a lock held by a process that no longer exists is a deadlock, and a reboot is
the cheapest possible release.

### AU9 — Automation content is a package. Proposed 2026-09-14.

A runbook, a script, a connector configuration: `os7-runbook-<name>` or
`os7-connector-<name>`, built by `build/lib/build-os7-packages.sh`, signed by
`build-os7-repo.sh`, installed by apt, delivered by the update train, **rolled back by the
boot environment**.

This is the cheapest strong claim in the whole plan, because all of it exists. It means a
fleet's automation content has a version, a signature, a rollout and a rollback, and none of
those had to be invented.

### AU10 — The contract to a product above is a machine contract, not a service API. Proposed 2026-09-14.

The temptation is a daemon with a Unix socket and JSON. That is a second implementation of
things the machine already has, and P11 says what Ubuntu maintains is wrapped and never
rebuilt.

**Cmdlets are the setup interface. systemd and the filesystem are the runtime interface.**

**This is not a guess any more.** GUI-APPS-PLAN asked the same question from the other side —
how does an unprivileged application reach a privileged cmdlet — and answered it on 2026-09-14
**by building it and running it on a machine** (`f9ca2b5`, O-G6): a templated unit
`os7-update@<version>.service`, started through `Start-SystemdUnit`, governed by polkit, with
progress read out of the unit's journal. *"No D-Bus library, no local HTTP service, and no
change to `Update-OS7`."* Two independent problems — a window that needs root, a product that
needs a job runner — arrived at one mechanism.

So **`Start-OS7Job` must be that mechanism widened, not a second one.** A privileged helper
for the applications and a job runner for a product above are the same thing asked for twice,
and building them separately is #66 in its purest form: two routes from the same notes, one
of which has been on a machine. What AU2/AU3/AU4 add to the proven pattern is the credential,
the input channel and the fence — not a new way to start work.

| The product needs to | It does this by |
|---|---|
| create its storage, seal a secret, register a schedule | calling a cmdlet as a child process — rare and coarse |
| start a job under the contract | a transient unit in `os7-automation.slice`, or `Start-OS7Job` |
| receive a secret | reading `$CREDENTIALS_DIRECTORY` inside the job |
| persist state | writing under `/var/lib/os7-automation/state/<service>/` |
| leave machine-level evidence | appending to the journal from AU5 |
| act as a service account | the ticket cache from AU7 |
| ship itself and its connectors | AU9 |

The paths and unit names in §4 are the contract. They are checked (AU14) or they are
folklore.

### AU11 — Notification is a machine-level sink, configured once. Proposed 2026-09-14.

A job that failed at 03:00 is today known to nobody: `Healthy` is pull, not push, and no MTA
is installed. `Send-OS7Notification` with sinks in a data file beside the module — the shape
`Get-OS7Endpoint` already uses, because sovereign clouds and customer relays are data, not
code. Sinks: SMTP, webhook, command.

A product above will send its own business mail (an approver's task, R65) through its own
templates. AU11 is for the machine's own bad news — backup failed, update failed, a lock has
been held for six hours.

### AU12 — Scheduling stays the machine's; business schedules belong to the product. Proposed 2026-09-14.

`Register-OS7ScheduledTask` is not the place for "move this employee to another department on
1 October". A product above holds due work in its own store and wakes on **one** heartbeat.

The trap that forces this, and it must be recorded whether or not anyone builds the product:
**a transient systemd timer does not survive a reboot** (expected — transient units live
under `/run`; M-AU4 measures it). An implementation that registers a date change as
`systemd-run --on-calendar '2026-10-01 06:00'` loses it at the next reboot **with nothing
reporting a problem** — the exact failure shape #113 already cost this repository once.

### AU13 — Triggers beyond the calendar are systemd's own, exposed as nouns. Proposed 2026-09-14. *Phase 2.*

`path` units (inotify) and socket activation exist; OS/7 has no noun for them. No new trigger
runtime is to be written. A webhook receiver is the one genuinely missing piece and is
deliberately deferred, because a product above brings its own.

### AU14 — The rules above are checks, or they are decoration. Proposed 2026-09-14.

In the shape `check-layering.py` established — a named baseline that may fall and may not
rise, each violation named on every run, and each rule proven to **fire** against a planted
defect via an environment override:

- **`check-automation-logic.py`** — AU2 (no cmdlet returns a secret value; `Get-OS7Secret`'s
  output type cannot carry one), AU3 (the job input is on stdin and nowhere else), AU4 (the
  default unit carries every named directive), AU5 (intent is written before the action —
  proven by killing a job mid-step and requiring an intent with no result), AU6 (the dataset
  is outside the BE), AU8 (a lock names its holder).
- **`check-layering.py` gains `P2-automation`** — nothing in the automation surface calls
  `systemctl`, `systemd-run` or `systemd-creds` directly; it goes through `powershell/Systemd`.
  Baseline to be set at whatever the first implementation measures, and it may fall and may
  not rise.
- **`check-privilege.py`** already covers the new changing verbs by reading bodies rather than
  verbs (#148). Its 42-UNGUARDED baseline may not rise because of this work.
- **`check-module-parts.py`** already holds the dot-source list, hook 0060, the `.deb` paths
  and the manifest against each other. New files land in all four or the check goes red.

P2-time is the standing reminder of what an unchecked rule is worth: it was written in
capitals in a file header while the code underneath called `chronyc makestep`.

---

## 4. The machine contract

Everything a product above may rely on. Nothing else is contract.

```
rpool/DATA/lib/os7-automation          outside the boot environment (AU6, D10)
  → /var/lib/os7-automation/
      secrets/<name>.cred              systemd-creds blob, 0600 root:root
      journal/<YYYY-MM-DD>.jsonl       append-only, 0640 root:adm (AU5)
      state/<service>/                 a product's durable state, its own shape

/run/os7/locks/<name>                  holder + acquisition time (AU8)

os7-automation.slice                   every job runs inside it (AU4)
os7-job-<id>.service                   transient; input on stdin (AU3),
                                       secrets via LoadCredentialEncrypted= (AU2),
                                       KRB5CCNAME per job (AU7)
```

Cmdlets, product layer, `powershell/OS7/OS7.Automation.ps1` (setup interface only):

```
New-OS7Secret  Get-OS7Secret  Remove-OS7Secret  Unprotect-OS7Secret
New-OS7ServiceDataset
Start-OS7Job   Get-OS7JobRecord   Write-OS7JobRecord
Lock-OS7Resource  Unlock-OS7Resource  Get-OS7Lock
Send-OS7Notification  Get-OS7NotificationSink  Set-OS7NotificationSink
```

Generic layer (`powershell/Systemd/`) grows whatever transient-unit and credential plumbing
the above needs, and keeps knowing nothing about OS/7 — P2, held by `check-layering.py`.

---

## 5. What exists today

Read out of the source on 2026-09-14. This is the honest starting line.

| Need | State | Where |
|---|---|---|
| Calendar schedule, validated before it is written | **done** | `Register-OS7ScheduledTask`, via `systemd-analyze calendar` |
| The enable-without-start trap named | **done** | `Healthy`, `Get-OS7ScheduledTask` |
| Catch-up after downtime, fleet jitter | **done** | `-Persistent`, `-RandomizedDelay` |
| No secrets on the command line; `%`/`$` escaped | **done** | `Register-OS7ScheduledTask` |
| Package timers refused for deletion by name | **done** | `Unregister-OS7ScheduledTask` |
| Rollback-safe machine; state split by rule | **done** | boot environments, D10 |
| Signed delivery of content to a fleet | **done** | `build-os7-repo.sh`, the update train |
| PowerShell as the native language, Windows names supplied | **done** | 243 functions, P1a |
| A changing verb refuses without root, in a sentence | **done** | `Assert-OS7Elevated`, #148 |
| Clock discipline with three outcomes | **done** | `powershell/Time/` |
| Interactive SSH lands in PowerShell; `ssh host cmd` stays bash | **done** | `check-ssh-login.py` |
| **Privileged work started by an unprivileged caller, with progress** | **done, and measured on a machine** | templated unit + `Start-SystemdUnit` + polkit + journal, `f9ca2b5` / O-G6 — the pattern `Start-OS7Job` must widen rather than replace (AU10) |
| **Secret store** | **missing** | AU2 |
| **Job journal** | **missing** | AU5 |
| **Resource limits / isolation for jobs** | **missing** (systemd has it; nothing exposes it) | AU4 |
| **Service dataset provisioning at runtime** | **missing** (rule exists, verb does not) | AU6 |
| **Service-account ticket cache** | partial (`New-OS7KerberosTicket`) | AU7 |
| **Named locks** | partial (`Update-OS7`'s only) | AU8 |
| **Notification, and any MTA at all** | **missing** | AU11 |
| Triggers beyond the calendar | missing | AU13, phase 2 |
| Fleet execution | missing | §8, phase 2 |
| Machine desired-state | missing | §8, phase 3 |

---

## 6. Limitations — the honest list

- **AUL1 — None of this has run.** Every decision is Proposed and the plan is written from
  source reading. The first implementation will correct it; that is what §7 is for.
- **AUL2 — AU2 inherits the TPM's whole problem.** Sealing to `host+tpm2` means a shim or
  `dbx` update can make every stored secret unopenable, and DECISIONS open question 7 records
  that OS/7 has no escrow. A machine that cannot open its secrets is a machine whose
  automation stops silently unless AU11 exists first.
- **AUL3 — The journal is append-only by convention, not by the filesystem.** Root can
  rewrite it. `zfs diff` against a snapshot is an independent check and is *not* tamper
  *proofing*; claiming more than that would be the kind of confident wrong answer
  BUILD-NOTES exists to record.
- **AUL4 — `DynamicUser=yes` and a durable state directory fight.** A dynamic user's
  `StateDirectory` is owned by an id that changes; jobs that must persist need a named
  identity. The default therefore cannot be dynamic for every job, and AU4 will need a
  second sentence once somebody implements it.
- **AUL5 — `ProtectSystem=strict` will break customer scripts** that write where they always
  did. The escape (`-Unconfined`) exists and is recorded per job; the support burden is real
  and belongs to whoever ships the product above.
- **AUL6 — No fleet story.** Everything here is one machine. `Enable-OS7Remoting` and SSH
  exist; orchestration does not.
- **AUL7 — arm64 is unmeasured, as usual.** Nothing here should be architecture-specific, and
  that sentence has been wrong before in this repository.
- **AUL8 — An automation host holds credentials for systems more valuable than itself.** A
  machine that may create AD users is, in effect, a tier-0 asset. This plan gives it a
  sealed store and an isolation model; it does not give it a threat model, and OS/7's
  existing rule points the other way — `Enter-OS7AdminSession` uses a credential and
  **forgets** it, because "a session that could re-authenticate is a password at rest".
  Unattended automation cannot forget. **AU2 knowingly breaks a stated OS/7 rule**, and the
  compensating controls (own machine, per-connector service accounts with least privilege,
  no interactive logon) are named here and built nowhere.

---

## 7. Measurements owed before any of this is called Decided

Each kills or confirms a decision. Four need nothing but a VM.

- **M-AU1 — `systemd-creds` on the shipped image.** Does `encrypt --with-key=host+tpm2`
  work against the same TPM that holds the LUKS key? Does `LoadCredentialEncrypted=` deliver
  it? What is the file mode, and is the directory really gone when the unit stops? Then the
  one that matters: **boot the machine under non-enforcing firmware — the control
  `run-secureboot.py policy` already builds — and try to open the blob.** Decides AU2's
  sealing target and sizes AUL2.
- **M-AU2 — the write-ahead property.** Kill a job mid-step and require an intent record with
  no result. Proven by killing, not by reading the code (#16's lesson).
- **M-AU3 — restrictive defaults against a real script.** Run a representative
  PowerShell job under AU4's directives and record what breaks. Sizes AUL5 with a number
  instead of a worry.
- **M-AU4 — does a transient timer survive a reboot?** Expected no. Whatever the answer, it
  becomes a BUILD-NOTES entry, because the failure it produces is silent (AU12).
- **M-AU5 — `DynamicUser` against a state directory.** Confirms or refutes AUL4.
- **M-AU6 — two jobs, one lock.** The contended path, including the holder dying.
- **M-AU7 — a keytab-derived ticket in a private cache, across expiry.** AU7 is otherwise
  a sentence about Kerberos, and this repository has learned what those are worth.
- **M-AU8 — a secret's survival across a boot-environment rollback.** The point of AU6 and
  the third appearance of open question 9; it must be shown, not argued.
- **M-AU9 — the same on arm64.** AUL7.

---

## 8. Order of work

**Phase 1 — the primitives a product above cannot be built without.** AU2, AU5, AU6, AU4,
AU8, AU7, AU11, plus AU14's `check-automation-logic.py` alongside rather than after. This is
the whole of what a product above requires from the machine — and every one of them is worth
having on a machine where no such product is ever installed.

**Phase 2 — the OS's own value, needed by no product.** AU13 (path and socket triggers),
fleet execution — where the differentiator is honesty: a machine that was not reached reports
`$null` and never `$true`, which is the one thing every orchestration tool gets wrong.
AU9's runbook packaging belongs here too, since its parts exist.

**Phase 3 — machine desired-state.** A declared document over the `Get-`/`Set-` pairs that
already exist, harvested out of P6's configured-vs-effective. Large, and needed by nothing
above.

---

## 9. Open questions

1. **AU2's sealing target**, and with it whether OS/7 needs escrow before it needs a secret
   store. M-AU1.
2. **Does AU2 resolve, or merely join, DECISIONS open questions 7 and 9?** The keytab,
   `/etc/shadow` and the secret store are one question about credentials and rollback asked
   in three places. Deciding any one alone is the mistake open question 9 already names.
3. **Which identity does a job run as by default** — `DynamicUser`, a per-product service
   account, or the caller? AUL4 makes this not merely a preference.
4. **Is the journal's schema a contract?** If a product above reads it, it is, and it needs a
   version field from the first line written.
5. **Does an automation host get its own machine role in the installer** — a mode beside
   `Server` and `Gui`, with no desktop, restrictive defaults and AUL8's controls applied by
   construction? That is the honest form of "appliance", and it is an installer decision
   (SETUP-PLAN), not this file's.
