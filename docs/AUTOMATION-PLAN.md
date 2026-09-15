# OS/7 as an automation host

**Status: PHASE 1 IS BUILT AND HAS RUN ON A MACHINE (2026-09-14).** AU2, AU3, AU4, AU5,
AU6, AU7, AU8 and AU11 are implemented in `powershell/OS7/OS7.Automation.ps1`,
`powershell/Systemd/` and `build/packages/os7-automation/`, and were exercised on an
installed amd64 machine the day this was written —
[SESSION-AUTOMATION-PRIMITIVES.md](SESSION-AUTOMATION-PRIMITIVES.md) has the transcripts and,
more usefully, the list of what was NOT run. AU9, AU12 and AU13 are still *Proposed*.

**Four decisions below were WRONG and are corrected in place**, each marked
**CORRECTED 2026-09-14** with the measurement that did it. That is what this document was
for; a plan whose first implementation changes nothing was not measuring anything.

Written 2026-09-14 from reading the module surface; the inventory in §5 is read out of the
source, the rest was design and is now partly evidence.

This plan decides what **the operating system** owes an automation workload, and — just as
deliberately — what it does not. A product that provisions identities, holds approvals and
governs entitlements is [IAM-PLAN.md](IAM-PLAN.md). This file is the machine underneath it,
and is useful without it: nothing below depends on that application being built.

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

- ~~Whether `systemd-creds` on the shipped image can seal against the same TPM that already
  holds the LUKS key, and what a PCR 7 change does to a sealed credential (AU2, M-AU1).~~
  **MEASURED 2026-09-14.** It can; `LoadCredentialEncrypted=` delivers exactly as described;
  and a PCR 7 change does **nothing**, because `--tpm2-pcrs=` defaults to empty. See AU2.
- ~~Whether a transient systemd timer survives a reboot.~~ **MEASURED 2026-09-14: it does
  not, and nothing anywhere says it went** — BUILD-NOTES #154.
- **A CORRECTION TO THE THIRD BULLET ABOVE: an MTA is not needed.** "No MTA is in any package
  list, so a machine that wants to send a mail today cannot" is true about MTAs and false
  about mail. SMTP submission to an organisation's relay is a TCP conversation and
  `System.Net.Mail` ships inside pwsh. AU11 is built without one, and not installing one is
  now a decision rather than an obstacle.
- Every performance claim. There are none in this document on purpose.

**What a MACHINE corrected, after every check on the build host was green** — the three
defects in §3 of the session document, recorded here because they are the argument for the
session document existing: a directory the cmdlet's own error message promised and did not
create; a property read that throws under `Set-StrictMode -Version Latest` because the
journal has two writers with different fields; and `RuntimeMaxSec=`, which systemd IGNORES
for `Type=oneshot` (BUILD-NOTES #155) so that every job ran with no timeout while the unit
file looked complete.

**What motivated this plan does not govern it.** The work that prompted it is an identity
and access management application on top of OS/7 ([IAM-PLAN.md](IAM-PLAN.md)); every decision
below is justified on this machine's own terms, and every one of them is worth having on a
machine where no such application is ever installed.

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

### AU2 — A secret is sealed by systemd, delivered to the process, and never returned to the caller. BUILT, and sealed against a real TPM on a machine, 2026-09-14.

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

**Sealing target: `tpm2` alone, no PCRs. DECIDED 2026-09-14, and the plan had it wrong.**

This paragraph used to read *"`--with-key=host` ties the blob to this machine's key;
`host+tpm2` adds the TPM. The second is stronger and inherits #69/#100: a shim or `dbx`
update moves PCR 7 and the blob stops opening."* Both halves are wrong, and one measurement
each says so.

**`host+tpm2` does not inherit #69/#100.** `--tpm2-pcrs=` defaults to EMPTY — the man page on
the image says so, and PCR 7 was extended for real with `tpm2_pcrextend` to check: the
default blob still opened, and only a blob sealed with `--tpm2-pcrs=7` died with *"TPM policy
does not match current system state"*. So the fragility has to be asked for by name, and
`New-OS7Secret -Pcrs` is where it is asked for.

**`host+tpm2` is WEAKER here, not stronger, and for a reason AU6 makes visible.** systemd's
host key is `/var/lib/systemd/credential.secret`; `/var/lib` on an OS/7 machine is
`rpool/ROOT/<be>/var/lib`, which is INSIDE the boot environment. A secret stored on AU6's
dataset survives a rollback and its KEY does not: moved aside, `host` and `host+tpm2` both
fail with *"Failed to determine local credential key"* while `tpm2` opens in the same second.
Adding the host key would put back exactly what this section moved out.

A machine with no usable TPM is TOLD so and has to choose `-SealTo host` deliberately, with
the trade named in the refusal. **This closes open question 1.**

### AU3 — A job's input arrives on stdin as one JSON document. BUILT and RUN 2026-09-14.

Not the environment: `/proc/<pid>/environ` is readable by the same user and by root, and a
job's input routinely carries an identity, a department and a manager's address. Not the
command line: it is world-readable in `ps` and in systemd's own tooling, which
`Register-OS7ScheduledTask` already says in capitals. Not a file, unless it is too large,
because a file has a lifetime and someone has to end it.

One document, on stdin, closed. The job parses it or fails. The requirement it serves is
that a caller hands a job every parameter it needs with no manual step — and the interesting
half of that is not *whether* but *through which channel*, which is what this decides.

### AU4 — Every job runs in a slice, with limits, a timeout and isolation, and the defaults are restrictive. BUILT and RUN 2026-09-14, with the timeout corrected by the machine (#155).

`os7-automation.slice` with `MemoryMax`, `CPUQuota` and `TasksMax`; each job with
`TimeoutStartSec` (the kill for a job that will not end), `PrivateTmp=yes`,
`ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges=yes`, `PrivateDevices=yes`, and
`DynamicUser=yes` wherever the job does not need a named identity.

**`TimeoutStartSec`, and this sentence said `RuntimeMaxSec` until a machine printed the
correction into its own journal.** `RuntimeMaxSec=` has NO EFFECT with `Type=oneshot` —
systemd says so, loads the unit anyway, and `systemctl show -p RuntimeMaxSec` answers with an
empty string, so every job ran unbounded while the unit file looked complete. A oneshot unit
is `activating` for its whole life and never reaches `active`. BUILD-NOTES #155.

**THE FENCE LIVES IN A PACKAGED TEMPLATE UNIT, not in the cmdlet.** Everything that is the
same for every job on every machine is in `os7-job@.service`, shipped by
`build/packages/os7-automation` — signed by the repository that delivered it, readable by an
auditor, greppable by a check, and rolled back with the release. `Start-OS7Job` writes only
the per-run parts as a drop-in under `/run`. `systemd-run` was rejected for the opposite
property: it assembles the whole fence out of arguments at run time, so the fence is whatever
the caller passed and exists in no file at all.

The motivating case is a product above running **scripts written by the operator**. A script
that allocates until the machine dies takes the audit trail's writer with it. systemd has
done this for a decade; nothing here is new except that it is switched on and stated.

**Restrictive by default and widened explicitly** — `Start-OS7Job -Unconfined` exists, names
what it gives up in its help, and appears in the job record so an auditor can see which jobs
ran without a fence.

### AU5 — The job journal is the machine's record, is append-only, is written before the action, and is outside the boot environment. BUILT and RUN 2026-09-14.

Two records, **not one**: a product above records *intent* (who asked, who approved, which
object), and the machine records *what it did* (at 14:02 a process ran as `svc-prov` for
1.3 s and exited 0). The second is what makes the first checkable, and the rule it serves is
BUILD-NOTES' oldest: **a diagnostic must not depend on the subsystem it is diagnosing.** An
IGA product's own audit trail attesting to its own writes is exactly that dependency.

Mechanics: JSON Lines, one file per day, `0640 root:adm`, on the dataset from AU6, **written
and fsynced before the action starts** and completed after it. `Flush()` pushes bytes into
the page cache; `Flush($true)` is fsync, and without it "written before the action" is a
statement about a buffer.

**Every record carries `schema`, from the first line ever written** — that answers open
question 4 in the only direction it can be answered, because a version field added later
cannot describe the records written before it.

**THE JOURNAL HAS TWO WRITERS AND THEIR RECORDS DO NOT HAVE THE SAME FIELDS**, which is not a
detail: `Start-OS7Job` writes the Intent, and — only when the unit could not be started at
all — a Result, because the runner will never write one and an intent with no result is
reserved for a machine that died. The RUNNER inside the unit writes the ordinary Result and
knows `exitCode`, `credentials` and `ticket` that the starter does not. A reader must read
fields defensively; `Get-OS7Job` did not, and threw instead of returning (#112/#119, found on
a machine). A run killed mid-step
therefore leaves an intent with no result — which is precisely the state a product above
must be able to detect in order to re-plan rather than re-run.

**It is not `journald`, and that is not a contradiction of the application work.** The
Software Update window reads *progress* out of a unit's journal (GUI-APPS-PLAN O-G6, measured
on a machine), and that is right — journald is the correct place for "what is this run doing
right now". It is the wrong place for "what did this machine change, eight months ago, in a
way an auditor will read": journald rotates, is not append-only in the sense an auditor
means, and lives inside the boot environment's `/var/log` policy. **Progress and evidence are
two questions, and only one of them has a retention requirement.**

### AU6 — Durable service state is a dataset outside the boot environment, provisioned by a cmdlet that reads it back. BUILT and RUN against a real pool 2026-09-14.

D10 gives the rule and `New-OS7Storage` gives the install-time layout; what is missing is the
verb a service uses at any other time.

`New-OS7ServiceDataset -Name os7-automation` creates `rpool/DATA/lib/os7-automation` at
`/var/lib/os7-automation`, sets the properties explicitly (#63 — a clone carries neither
`canmount` nor `mountpoint`), **creates the directories §4 names**, enters it into the backup
policy, and **asks ZFS back** rather than reporting four commands that exited 0.

That third clause was added after the fact and is worth the sentence: the first
implementation created the dataset, mounted it, verified it against ZFS — and the next cmdlet
said *"no secret store at /var/lib/os7-automation/secrets. New-OS7ServiceDataset -Name
os7-automation creates it."* It did not. BUILD-NOTES #148's family, and invisible to the
logic check for a precise reason: **the check made the directories itself before it started.**
A fixture that prepares the world hides every defect about preparing the world.

**It REFUSES a dataset under `ROOT`, and refuses `/var/lib/os7`** — a refusal rather than a
default, because "outside the boot environment" is the one property of this dataset that
cannot be added afterwards.

**`/var/lib/os7` is the wrong place and this must be said, because it is the obvious one.**
It is inside the boot environment — deliberately, because C10's migration record has to keep
rolling back with the release. A secret or an audit record under it would roll back with it.

### AU7 — A job that needs a domain identity gets its own ticket cache from a keytab. BUILT 2026-09-14; NO TICKET HAS EVER BEEN OBTAINED (M-AU7).

`KRB5CCNAME` into the job's runtime directory, obtained at job start from the named keytab,
renewed before expiry, destroyed with the unit. Never the machine's default cache, because
two jobs sharing one cache is two jobs sharing one identity and a race over its lifetime.

`New-OS7KerberosTicket` exists; what it does not have is the keytab-and-private-cache shape.

### AU8 — Mutual exclusion is a named lock that says who holds it and since when. BUILT and RUN 2026-09-14.

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

### AU10 — The contract to a product above is a machine contract, not a service API. BUILT 2026-09-14 as the widening it asks for.

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

### AU11 — Notification is a machine-level sink, configured once. BUILT 2026-09-14; NOTHING HAS EVER BEEN DELIVERED.

A job that failed at 03:00 is today known to nobody: `Healthy` is pull, not push.
`Send-OS7Notification` with sinks in a data file. Sinks: SMTP, webhook, command.

**NO MTA, AND THAT IS NOW THE DECISION RATHER THAN THE OBSTACLE. CORRECTED 2026-09-14.** §1
recorded that no MTA is in any package list "so a machine that wants to send a mail today
cannot", and §8 put AU11 last because installing one costs a build. SMTP submission to the
organisation's relay is a TCP conversation and `System.Net.Mail` ships inside pwsh. An MTA
would add a spool, a queue, a second retry policy and a listening socket to a machine whose
bad news is better delivered synchronously or not at all.

**The sinks live on the AU6 dataset, not beside the module. CORRECTED 2026-09-14.** This
paragraph said "beside the module — the shape `Get-OS7Endpoint` already uses".
`os7-endpoints.json` ships in the package and is identical on every machine; a sink is THIS
machine's configuration. Beside the module it would be inside the boot environment and would
roll back with the release — and the first thing a machine wants to say after a bad update is
that the update was bad.

**One result per sink, never one answer.** "Sent" over three sinks of which one worked is how
an alerting system quietly stops alerting. A failing sink is named, with what it said, and is
**not** a terminating error: this is usually called from a catch block, and throwing here
would replace the problem being reported with a problem reporting it.

A product above will send its own business mail — an approver's task, a request accepted —
through its own templates. AU11 is for the machine's own bad news — backup failed, update failed, a lock has
been held for six hours.

### AU12 — Scheduling stays the machine's; business schedules belong to the product. Proposed 2026-09-14; its trap MEASURED (BUILD-NOTES #154).

`Register-OS7ScheduledTask` is not the place for "move this employee to another department on
1 October". A product above holds due work in its own store and wakes on **one** heartbeat.

The trap that forces this, and it must be recorded whether or not anyone builds the product:
**a transient systemd timer does not survive a reboot** — MEASURED 2026-09-14, and the
expected half is the boring one. `LoadState=not-found`, nothing under
`/run/systemd/transient`, and **not one line in either boot's journal saying it went**
(BUILD-NOTES #154). An implementation that registers a date change as
`systemd-run --on-calendar '2026-10-01 06:00'` loses it at the next reboot **with nothing
reporting a problem** — the exact failure shape #113 already cost this repository once.

### AU13 — Triggers beyond the calendar are systemd's own, exposed as nouns. Proposed 2026-09-14. *Phase 2.*

`path` units (inotify) and socket activation exist; OS/7 has no noun for them. No new trigger
runtime is to be written. A webhook receiver is the one genuinely missing piece and is
deliberately deferred, because a product above brings its own.

### AU14 — The rules above are checks, or they are decoration. BUILT 2026-09-14.

In the shape `check-layering.py` established — a named baseline that may fall and may not
rise, each violation named on every run, and each rule proven to **fire** against a planted
defect via an environment override:

- **`check-automation-logic.py`** — **BUILT: 48 checks, and `--self-test` plants NINE
  defects and requires every one to fire.** AU1 (the boundary, by grep, baseline 0), AU2, AU3,
  AU4, AU5, AU6, AU8, AU11. **It runs itself in a container on a non-Linux host** and that is
  not convenience: `SetUnixFileMode` throws on Windows and `/proc/<pid>` is how AU8 decides
  staleness, so two rules are not expressible there at all.

  AU5's write-ahead is proven **without a VM**, and the substitution is worth naming: the plan
  said "by killing a job mid-step", and making the ACTION fail while requiring the INTENT to
  be on disk already gives the same evidence — if the intent were written second, that job
  would leave no trace at all, which is the state a product above could not tell from "never
  asked for".

  **And one rule is NEGATIVE, which the plan did not anticipate.** A check that asserts a
  directive is PRESENT cannot see a directive being IGNORED, which is how every job ran
  without a timeout for an afternoon (#155). So `RuntimeMaxSec=` and `Type=oneshot` are
  required never to appear together. The general form: *for any directive whose effect
  depends on another directive, the rule has to name the combination.*
- **`check-layering.py` gained `P2-automation`, baseline 0** — `systemd-creds`, `systemd-run`,
  `systemd-analyze` and their neighbours, none of which `powershell/OS7` may name. It is a
  seventh rule rather than more tokens on `P2-systemd` because that one stands at 2 and can
  therefore never assert that a subsystem is at zero — only that it has not got worse. Proven
  to fire against a planted `Invoke-OS7Native -Command 'systemd-creds'`.
- **`check-privilege.py`** — **both baselines held: OS7 42/42 and the generic layers 41/41.**
  And half of #149 is now decided, which the plan did not ask for and the work required: the
  four new mutating verbs in `powershell/Systemd` carry **`Assert-SystemdElevated`**, the same
  `/proc/self/status` read in the module's OWN file, so nothing calls upward and P2 still
  points one way. The scan accepts any `Assert-*Elevated`. The forty-one that predate it are
  deliberately NOT retrofitted: adding a guard to a cmdlet whose behaviour nothing has
  re-tested is a change made to satisfy a check rather than to fix a defect.
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
| **Secret store** | **done, sealed against a real TPM on a machine** | `New-/Get-/Remove-/Unprotect-OS7Secret`, AU2 |
| **Job journal** | **done, and the intent lands 1.5 s before the result** | `Write-/Get-OS7JobRecord`, AU5 |
| **Resource limits / isolation for jobs** | **done** — and `systemctl show` was asked what the machine actually applied, which is how #155 was found | `os7-job@.service`, AU4 |
| **Service dataset provisioning at runtime** | **done, against a real pool** | `New-OS7ServiceDataset`, AU6 |
| **Service-account ticket cache** | **built, never exercised** — the cache path is in the drop-in and checked; no ticket has been obtained (M-AU7) | `New-OS7JobTicket`, AU7 |
| **Named locks** | **done** | `Lock-/Unlock-/Get-OS7Lock`, AU8 |
| **Notification** | **built, nothing ever delivered.** No MTA, and none needed | `Send-OS7Notification`, AU11 |
| Triggers beyond the calendar | missing | AU13, phase 2 |
| Fleet execution | missing | §8, phase 2 |
| Machine desired-state | missing | §8, phase 3 |

---

## 6. Limitations — the honest list

- ~~**AUL1 — None of this has run.**~~ **Phase 1 has run** (2026-09-14). It corrected four
  decisions and a machine corrected three implementation defects in the first twenty minutes,
  which is what this limitation predicted.
  **The new AUL1 is narrower and is the one to read: NO ISO CARRIES ANY OF THIS.** The
  `os7-automation` package builds and has never been built into an image; the module reached
  a machine by `os7lab.py push` over a 1.0.0.175 install. Until a build carries it, every
  claim here is about a machine that was assembled by hand.
- **AUL2 — MUCH SMALLER THAN THIS SAID. CORRECTED 2026-09-14.** It read: *"Sealing to
  `host+tpm2` means a shim or `dbx` update can make every stored secret unopenable."* It
  cannot, because `--tpm2-pcrs=` defaults to EMPTY and the default is what `New-OS7Secret`
  uses — measured by extending PCR 7 for real. What survives is narrow and worth keeping:
  **a secret sealed with `-Pcrs` explicitly does inherit #69/#100**, a machine whose TPM is
  cleared or replaced loses every secret, and OS/7 still has no escrow (DECISIONS open
  question 7). The escrow question is no longer on the critical path for a secret store.
- **AUL3 — The journal is append-only by convention, not by the filesystem.** Root can
  rewrite it. `zfs diff` against a snapshot is an independent check and is *not* tamper
  *proofing*; claiming more than that would be the kind of confident wrong answer
  BUILD-NOTES exists to record.
- **AUL4 — `DynamicUser=yes` and a durable state directory fight**, and here is the second
  sentence it asked for. **The default is root, inside the fence, and the job record says
  so** — because a job that must write its own state, hold a keytab and append to the machine
  journal cannot be a dynamic user, and a job run as the CALLER would make the fence depend on
  who typed the command. `-Identity` and `-DynamicUser` opt out; `-DynamicUser` with
  `-Keytab` is REFUSED as two answers to one question. That is uncomfortable and is stated
  here so somebody can disagree with it; it answers open question 3. **M-AU5 still stands** —
  nothing has run under `DynamicUser` at all.
- **AUL5 — `ProtectSystem=strict` will break operator-authored scripts** that write where they always
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

- ~~**M-AU1 — `systemd-creds` on the shipped image.**~~ **DONE 2026-09-14**, on an installed
  1.0.0.175 amd64 machine under non-enforcing firmware (the bench's own kernel says
  `secureboot: Secure boot disabled`, so the control came free). It works; delivery is a
  tmpfs at 0400 that is gone when the unit stops; and PCR 7 was extended with
  `tpm2_pcrextend` rather than argued about. It decided the sealing target the other way
  round from the plan — see AU2 and
  [SESSION-AUTOMATION-PRIMITIVES.md](SESSION-AUTOMATION-PRIMITIVES.md) §1.
- ~~**M-AU2 — the write-ahead property.**~~ **DONE, and not by killing.** The intent is
  required to be on disk when the ACTION fails, which gives the same evidence with no VM:
  `check-automation-logic.py` makes `systemctl start` fail and requires the Intent record to
  already exist. On a machine the order is visible in the timestamps — Intent 19:03:01,
  Result 19:03:02.
- **M-AU3 — restrictive defaults against a real script.** Run a representative
  PowerShell job under AU4's directives and record what breaks. Sizes AUL5 with a number
  instead of a worry.
- ~~**M-AU4 — does a transient timer survive a reboot?**~~ **DONE 2026-09-14: no, and
  silently.** BUILD-NOTES #154.
- **M-AU5 — `DynamicUser` against a state directory.** Confirms or refutes AUL4.
- **M-AU6 — two jobs, one lock.** The contended path, including the holder dying.
- **M-AU7 — a keytab-derived ticket in a private cache, across expiry.** AU7 is otherwise
  a sentence about Kerberos, and this repository has learned what those are worth.
- **M-AU8 — a secret's survival across a boot-environment rollback.** The point of AU6 and
  the third appearance of open question 9; it must be shown, not argued.
- **M-AU9 — the same on arm64.** AUL7.

---

## 8. Order of work

**Phase 1 — the primitives a product above cannot be built without. DONE 2026-09-14**, in
the order AU6 → AU5 → AU4 → AU2 → AU8 → AU7 → AU11, with `check-automation-logic.py`
alongside rather than after. AU6 went first because everything else puts something somewhere.

**What phase 1 still owes, as of 2026-09-15 — and it is down to four things:**

  * **M-AU7, a ticket from a keytab.** The one measurement with nothing standing in for it.
    The test DC answers on 88, 389, 636 and 464 from the bench and every Kerberos tool is on
    the image; what is missing is a keytab, which needs a domain join.
  * **`-Unconfined` has never run a job.** The drop-in it writes is checked.
  * **A `Restore-OS7` rollback over a secret**, as opposed to the dataset topology M-AU8
    showed.
  * **arm64** (M-AU9), and polkit's `AUTH_ADMIN` dialog, which needs a seat.

Everything else phase 1 owed on 2026-09-14 has been measured, and two of those measurements
found defects rather than confirming a design — which is what §7 is for.

**Phase 2 — the OS's own value, needed by no product.** AU13 (path and socket triggers),
fleet execution — where the differentiator is honesty: a machine that was not reached reports
`$null` and never `$true`, which is the one thing every orchestration tool gets wrong.
AU9's runbook packaging belongs here too, since its parts exist.

**Phase 3 — machine desired-state.** A declared document over the `Get-`/`Set-` pairs that
already exist, harvested out of P6's configured-vs-effective. Large, and needed by nothing
above.

---

## 9. Open questions

1. ~~**AU2's sealing target**~~ — **CLOSED 2026-09-14: `tpm2`, no PCRs.** Not by preference:
   the `host` half is a file inside the boot environment, so `host+tpm2` would have put the
   KEY back where AU6 exists to keep the SECRET out of. Escrow is still owed and is no longer
   on the critical path, because the default binding survives a firmware policy change.
2. **Does AU2 resolve, or merely join, DECISIONS open questions 7 and 9?** The keytab,
   `/etc/shadow` and the secret store are one question about credentials and rollback asked
   in three places. Deciding any one alone is the mistake open question 9 already names.
3. ~~**Which identity does a job run as by default**~~ — **ANSWERED 2026-09-14: root, inside
   the fence, and the job record says so.** `-Identity` and `-DynamicUser` opt out. See AUL4
   for the reasoning and for why it is stated where somebody can disagree with it.
4. ~~**Is the journal's schema a contract?**~~ **ANSWERED: yes**, and every record carries
   `schema: 1` from the first line ever written, which is the only moment that decision can be
   made. What the implementation added to it: **the journal has two writers with different
   fields**, so a reader has to read defensively even within one schema version — `Get-OS7Job`
   did not, and threw (#112/#119, found on a machine).
5. **Does an automation host get its own machine role in the installer** — a mode beside
   `Server` and `Gui`, with no desktop, restrictive defaults and AUL8's controls applied by
   construction? That is the honest form of "appliance", and it is an installer decision
   (SETUP-PLAN), not this file's.
