# Session — scheduled tasks: the Task Scheduler question, and the #113 fix

**2026-08-29, x64 Windows host.** This session built the scheduled-task
surface — `Get-/Enable-/Disable-/Start-/Register-/Unregister-OS7ScheduledTask`
over a new timer surface in `powershell/Systemd/` — and with it closed
BUILD-NOTES #113: the unattended update check, the mechanism
RELEASE-AND-UPDATE-PLAN §6 ships so that *"on a managed fleet nobody types
`Update-OS7`"*, was a timer no cmdlet could see. Everything below was measured
on this host: the systemd facts in a container running systemd 259 as PID 1,
the packaging on a rebuilt ISO, and the cmdlets typed at an installed machine.
arm64 was not touched.

## 1. The decision: a noun, not a service type (P9)

#113 left one decision open — *"either `Get-OS7Service -Type`, or a separate
noun for timers"* — and it resolved to the noun, recorded as
[POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md) **P9**. The argument
is Windows' own: `Get-Service` does not list scheduled tasks either, and
services.msc and taskschd.msc are different tools because "is this program
running" and "will this job run at three in the morning" are different
questions. `Get-OS7Service` stays deliberately services-only.

The feature had sat in Tier 3 of the surface plan ("completeness"); #113
pulled it forward, because the timer it could not see is the update train's
fleet mechanism, not a convenience.

## 2. What was measured before anything was written

The repo's rule — measure, do not assert — applied to systemd's timer
surface, in a container from `os7img:116` with systemd 259 as PID 1. Four
facts shaped the whole design; the first two are numbered because they are
traps:

* **#115 — `systemctl enable` on a timer arms the NEXT boot only.** Enabled
  and never started is `UnitFileState=enabled`, `ActiveState=inactive`,
  `next: null` — a timer that never fires, with every individual answer
  looking normal. This is why `Enable-OS7ScheduledTask` enables AND starts,
  and why `Healthy` is `$false` for exactly this state.
* **#116 — a timer that is neither enabled nor active is invisible to BOTH
  `list-timers --all` AND `list-units --all`** (systemd does not load units
  nothing references; only `list-unit-files` and the on-demand loader see
  it) — so `Get-SystemdTimer` is a union of two lists with a point-query
  fall-through to `systemctl show`, and a task registered `-Disabled` stays
  in the inventory. And `list-timers`' JSON fields `left`/`passed` are NOT
  the durations their names promise (`left` came back equal to `next`, byte
  for byte); nothing reads them.
* `list-timers --output=json` carries real numbers (microseconds since the
  epoch; `last: 0` for never) — unlike journalctl's JSON, where every value
  is a string. Two JSON emitters in one tool family, two typing rules.
* With `--timestamp=unix`, timestamps come back `@<seconds>` but durations
  stay human-readable (`RandomizedDelayUSec=10min`) — so `RandomizedDelay`
  is reported verbatim rather than parsed by a suffix table maintained here.

Also measured, because the design leans on them: `systemd-analyze calendar`
exits 1 with a named error for a spec systemd cannot parse (so `Register-`
validates BEFORE writing — the visudo pattern); running a task now means
starting the SERVICE (starting the timer merely arms the schedule), and a
manual run does not move the timer's `LastTriggerUSec` — the schedule did not
fire; `systemctl list-timers`/`list-unit-files` honour name and glob
arguments; `/usr/bin/pwsh` is a symlink to `/opt/microsoft/powershell/7/pwsh`
on the image, which is what `Register- -Command`'s `ExecStart` uses.

The fixtures were captured from that container verbatim —
`systemctl-list-timers.json`, `systemctl-list-unit-files.json` (with a
disabled `os7-task-idle.timer` pair present, so the recorded data carries the
#116 case), `systemctl-show-timer.txt` (sanoid, active/waiting, after its
schedule had genuinely fired), `systemctl-show-timer-enabled-inactive.txt`
(the #115 state), and the two one-line LoadState answers `New-/Remove-` verify
against. They ship in `powershell/Systemd/tests/fixtures/` like the rest.

## 3. What was built

**Generic layer** (`powershell/Systemd/`, v0 → v1 — its release notes said
"timers … are not here" and now they are):

* `Get-SystemdTimer` — the union of #116, typed elapses, `Schedule` verbatim
  from `TimersCalendar`/`TimersMonotonic`.
* `New-SystemdTimer` — writes the timer+service pair as ONE thing into
  `/etc/systemd/system`, validates every `-OnCalendar` with `systemd-analyze`
  first, refuses line breaks in every value (a newline in a unit value IS the
  next directive — an injection, not an escape problem), `daemon-reload`s,
  and asks systemd for `LoadState=loaded` on both units afterwards.
* `Remove-SystemdTimer` — removes only from `/etc/systemd/system`, refuses a
  unit whose file lives elsewhere (a package's), verifies
  `LoadState=not-found` afterwards.

**Product layer** (`powershell/OS7/OS7.ScheduledTask.ps1`, the file that made
the dot-source list FIFTEEN — it loads tenth, after OS7.Service.ps1 whose
helpers it calls, and OS7.Update.ps1 stays last): the six cmdlets, the
`os7-task-` prefix for registered
tasks, `Healthy` with the same three-valued contract as everywhere else
(`$null` until `-Detailed`), `LastResult` read from the SERVICE the timer
activates, `-OS7Only` on the shared pattern list — which gained `'sanoid*'`,
because the backup schedule IS sanoid's own timer and a list that answers
"which schedules are this product's" without it would be #113 in a second
shape. `Unregister-` refuses non-`os7-task-*` names BEFORE any systemd call.

**Packaging**: the fifteenth file joined all three copies of the file list in
one commit — `OS7.psm1`'s foreach, hook 0060's present-and-non-empty loop,
and `pkg_finish`'s required paths (os7-module now asserts **27** paths, was
26) — plus both export filters in each module (`Export-ModuleMember` AND
`FunctionsToExport`), and hook 0060's named-export checks for both modules.

**Writing it re-paid one old bill**: the first version of the self-test's
argv recorder went through `.GetNewClosure()` and recorded nothing — #96
exactly, the fresh closure scope is where `$script:` stops resolving to the
module. The recording blocks now carry a comment pointing at #96.

## 4. The gates, in the order they ran

All on this host, all green:

| gate | result |
|---|---|
| `Test-SystemdModule` | **76 checks** (was 32; 68 before the review round below), including the #115 state, the #116 union, overwrite/`-Force`, the `--` behind `systemd-analyze`, and both ask-back failure paths |
| `check-scheduledtask-logic.py` (new) | **64 checks** — the decisions: typing, the union, `Healthy`'s three values, run-now-starts-the-service, enable-arms-now, register-arms (enable AND start recorded), the `%`/`$`/space escaping, every `Register-` refusal happening BEFORE anything is written, `Unregister-`'s refusal happening before any systemd call, and the ask-back failure that must throw |
| `check-service-logic.py`, `check-ps-traps.py`, `check-installer-cmdlets.py`, `Test-OS7Backup` | unchanged, still green |
| `check-layering.py` | **all five rules HELD** — P2-systemd stays at baseline 2; the new file reaches systemd only through the Systemd module |
| the cmdlets against REAL systemd | in the os7img:116 container with systemd as PID 1, twice: `Register-` (real files, real daemon-reload, `NextRun` = next 03:00), `Start-` actually ran the pwsh task (the file it was told to write exists; `LastResult=success`), the #115 trap reproduced raw and reported `Healthy=$false`, `sanoid.timer` refused by name, `Unregister-` verified gone — and after the review round: a `%` in `-Command` surviving to the filesystem literally, a taken name refused and `-Force` over it, a glob refused, a real `systemctl mask` refused WITH THE MASK INTACT (`is-enabled` still `masked`), a lone /etc override refused |
| `make repo-amd64` + `check-os7-repo.py` | **123 checks** — the fifteenth file installs from the signed repository, apt still refuses the foreign key |
| `make build-amd64` → `OS7-1.0.0.159-amd64.iso` + `check-image.py` | **114 checks** — dpkg owns the new file, `Test-SystemdModule` runs green inside the artefact's chroot. Built three times under one number (uncommitted tree): the third carries the review fixes and is the one in `out/` |
| `run-s5.py install` | **PASS** — the ISO installs a machine, serial console configured (run twice: once per shoot) |
| `shoot-manual.py` | all 47 pictures (41 existing retaken + 6 new) typed at the installed machine — including `Register-OS7ScheduledTask @t` armed with a real `NextRun` and `Unregister-` cleaning up |

## 4a. The adversarial review round, and what it changed

Before committing, the whole diff went through a fan-out review (four lenses,
every finding independently re-verified against the code, several by
measurement on real systemd). **31 findings survived verification**; the ones
that changed code:

* **`Remove-SystemdTimer` would have deleted a MASK** — `systemctl mask` puts
  a symlink to /dev/null at exactly the path the guard checked with
  `File.Exists`, which follows symlinks (measured). Deleting it silently
  UNMASKS a package timer — an administrator's suppression reverted by a
  cmdlet whose contract is to refuse package timers. Now: symlinks refused,
  and a lone `.timer` without its `.service` (a `systemctl edit --full`
  override) refused too — the PAIR is what New- writes and what Remove-
  removes. Proven against a real mask in the container.
* **`systemd-analyze calendar` without `--` waves option-shaped specs
  through** — `--version` exits 0 as an OPTION (measured), so a half-broken
  timer could be written and systemd would drop the bad line with only a
  journal warning. Now validated behind `--`.
* **`%` and `$` reached ExecStart unescaped** — systemd expands `%m` into the
  machine id and `$VAR` from the environment, so the task would run a
  DIFFERENT command than the operator typed, silently. The OS7 layer now
  escapes both (what you type is what runs); the generic layer documents that
  its contract is systemd's vocabulary verbatim — the escape hatch for a task
  that wants specifiers.
* **A spaced `-Execute` path ran the wrong binary** (`/opt/my app/run.sh` →
  `/opt/my`, failing 203/EXEC days later at the first elapse). Now quoted.
* **`New-SystemdTimer` silently overwrote an existing pair** — now refused,
  `-Force` is the deliberate way over it, on both layers.
* **`-At` beside `-OnCalendar` was validated and then ignored** — a schedule
  the operator believes in and the machine does not have. Now refused, like a
  stray `-DayOfWeek`.
* **Globs fell apart under the verbs** — `systemctl stop` expands them and
  `disable` refuses them (measured), so `Disable- 'sanoid*'` would stop NOW
  and stay enabled at boot: the mirror of #115, manufactured by our own
  cmdlet. Now refused up front.
* **`Healthy` missed `enabled-runtime`** (the same trap wearing /run) — now
  `-like 'enabled*'`. The inverse state (active now, disabled at boot) stays
  `$true` deliberately and the code says why.
* Smaller: `@()[0]` under `Set-StrictMode Latest` THROWS (measured), so
  Register's explanation branch was unreachable — #112's shape again;
  `Unregister demo.timer` read an explicit unit name as a short name;
  `Disable-` declared High impact and never called ShouldProcess; a
  sub-second `-RandomizedDelay` became `RandomizedDelaySec=0`; the timer
  union keyed case-insensitively while unit names are case-sensitive; a
  leading `-` in a unit name would be written and never again addressable
  (`systemctl show -x.timer` parses it as an option, measured); and the OS7
  layer read the Systemd module's private state — all fixed.

**And the review broke the tree while reviewing it.** Two verify agents
edited module files to prove findings by experiment ("deleting X leaves the
suite green") and failed to restore them: `Register-`'s enable+start lines
and `New-SystemdTimer`'s ask-back loop were missing from the working tree
afterwards — while `check-scheduledtask-logic.py` stayed green, which proved
the finding those agents were verifying. Both harnesses now assert the arming
calls and both ask-back failure paths, so that class of regression turns a
check red. The ISO shipped at that point was built BEFORE the mutations and
was clean; everything was re-verified from the sources afterwards.

One review find changed a picture rather than code: the first shoot showed
`Schedule: Sun *-*-* 03:00:00` beside `NextRun: 01:00:00` — the spec is read
in the machine's zone (Europe/Berlin) and `NextRun` rendered UTC.
`Get-OS7ScheduledTask` now renders LOCAL time, the convention the backup
cmdlets already follow (B13/B14: units run UTC, cmdlets render local), and
the pictures were re-shot.

## 5. The manual moved with the surface

Chapter 9 gained **9.5 Scheduled tasks / Geplante Aufgaben** in both
languages (the closing "what was not rebuilt" section became 9.6); chapter
6.7's documented workaround — *"a timer is inspected through the generic
layer"* — was rewritten, because a manual describing a workaround that no
longer applies would be worse than either state; the DE chapter-9 startup
example moved off the timer it no longer needs to demonstrate. Appendix A was
regenerated (`make-reference.py`: **194 commands, asked of the modules**),
docs/POWERSHELL-REFERENCE.md was updated the same way (194 across six
modules; Systemd 11, OS7 101), and both PDFs were rebuilt.

## 5a. Two findings beside the feature

* **`check-be-logic.py` does not run on this Windows host** — 20 of its
  checks fail on an untouched HEAD exactly as on this tree (attributed in a
  clean worktree before assuming a regression): `Invoke-ZfsNative` reads
  `$LASTEXITCODE` after invoking the fake `zfs`, which is a POSIX script
  Windows cannot execute, so the variable is never set and StrictMode throws.
  The check needs the Mac (or a container wrapper like `check-home-logic.py`'s).
  Not this feature's — recorded so the next session does not re-attribute it.
* **`shoot-manual.py`'s passphrase typing flaked once**: the first shoot of
  the final ISO died with the TPM prompt re-asking after the passphrase was
  typed ("Please unlock disk os7_root" again, then the 900 s login budget
  ran out). The retry went through cleanly. One occurrence in four runs this
  session; worth a numbered note if it recurs.

## 6. What was NOT measured

* **arm64 — nothing.** No arm64 image has been built since the feature (or
  since hook 0022 at all); the timer surface there is the same inference as
  everything else on that architecture.
* **`run-s5.py all` was not re-run** — only `install` (which this feature's
  packaging touches) plus the manual shoot. The update train's own code is
  unchanged, `check-os7-repo.py`/`check-update-logic.py` cover the .deb and
  the decisions, but "the full gate passed on 1.0.0.159" is a claim this
  session does not make.
* **No schedule FIRED on the installed machine.** `Start-OS7ScheduledTask`
  ran a task's service by hand at the machine, and in the container sanoid's
  own schedule genuinely fired (its recorded `LastTriggerUSec` is real) —
  but no `Register-`ed task has been observed firing from its OnCalendar
  spec on a booted machine. `-Persistent` catch-up and `-RandomizedDelay`
  spreading are asserted from the unit file and systemd's parsed properties,
  not from observed runs.
* **`Start-OS7ScheduledTask` waits** (deliberately, and reports the actual
  outcome) — a task that runs for an hour holds the prompt for an hour, and
  no `-NoWait` exists yet. Recorded as a known limitation, not measured
  further.

## 7. What to do next

1. ~~**#112 is still open** — `Get-OS7BackupStatus` throws on every machine
   without a replication target. Same shape of fix as this session's
   (two-step value taking, plus the two missing states in `Test-OS7Backup`).~~
   **CLOSED 2026-08-30** (#112/#119), by exactly that fix — found again by
   `run-surface.py` typing the cmdlet at a machine, not by re-reading this.
2. The default rendering of a task list is PowerShell's (>4 properties →
   list); a table view in `OS7.format.ps1xml` would make the bare
   `Get-OS7ScheduledTask` picture nicer. Cosmetic, deliberate deferral.
3. arm64 owes everything above from `make build-arm64` onward.
