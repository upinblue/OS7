# Session — the Management module's missing names, and the one that lies

**2026-09-09, x64 Windows host.** Started from a user report: cmdlets documented
in Microsoft's `Microsoft.PowerShell.Management` reference — `Stop-Computer` was
the example given — appear in autocomplete and then fail with "cmdlet not
found", and that has to work.

Two things came out of asking, and they are not the same thing. One is the
missing names, which is what the report was about. The other is a name that is
present and does the opposite of what it says, which nobody was looking for.

---

## 1. What was measured, and how

Everything below was asked of **the shipped ISO's own pwsh 7.6.5**, by mounting
`OS7-1.0.0.193-amd64.iso`, overlaying its squashfs and chrooting into it —
BUILD-NOTES #93's rule, because a container image derived from an ISO is not the
ISO. The same questions were then put to an **installed machine** (the `gui`
bench, `os7lab.py`), and the answers agreed.

The Windows side of every comparison came from **a real Windows pwsh 7.6.5 on
this host** — the version the pin carries — so a difference is a platform
difference and not a version one.

### 1.1 Fifteen of sixty-two documented cmdlets are absent

Of the 62 cmdlets the 7.6 `Microsoft.PowerShell.Management` reference documents:

| | |
|---|---|
| present | 47 |
| absent | 15 |

The 15: `Get-Service`, `Set-Service`, `New-Service`, `Remove-Service`,
`Start-Service`, `Stop-Service`, `Restart-Service`, `Suspend-Service`,
`Resume-Service`, `Set-TimeZone`, `Get-ComputerInfo`, `Rename-Computer`,
`Get-HotFix`, `Clear-RecycleBin`, `Restore-Computer`.

Invoking one gives exactly what the report described:

```
The term 'Get-Service' is not recognized as a name of a cmdlet, function,
script file, or executable program.
```

### 1.2 …but the autocomplete half of the report was NOT reproduced

Asked of `[System.Management.Automation.CommandCompletion]::CompleteInput`,
which is the code path Tab uses, **none of the 15 is offered** — on the live
medium or on the installed machine. The Unix module manifest's `CmdletsToExport`
does not list them, so nothing has them to offer.

What DOES complete and is documented is `Stop-Computer` and `Restart-Computer`,
because the Unix manifest lists both and the Unix build implements both. So the
"completes, then not found" combination was not reproduced for any name, and
the report's example is a name that completes and *runs*. Which turned out to
matter more, not less.

**Not measured:** which name the reporter actually typed, and in which session.
Both halves of the report are individually explained — a documented Management
cmdlet that is missing (§1.1), and one that completes (§1.3) — but the exact
combination was not seen here. If it recurs, the thing to capture is the
command line and the full error text.

### 1.3 `Restart-Computer` powers the machine off, and reports success

Both `Restart-Computer` and `Stop-Computer` run

```
/usr/sbin/shutdown          (with NO arguments at all)
```

recorded by putting a recorder in place of every binary they might reach for
(`/sbin/shutdown`, `/usr/sbin/shutdown`, `systemctl`, `reboot`, `poweroff`,
`halt`) inside a throwaway overlay of the ISO's own root. Both produced one
line each, with an empty argument vector.

`/usr/sbin/shutdown` is a symlink to `systemctl`, whose compatibility interface
takes the action as a flag (`-H`, `-P`, `-r`) and **defaults to poweroff**
without one. So on the `gui` bench, as root:

```
Restart-Computer            ->  exit 0
[  OK  ] Reached target poweroff.target - System Power Off.
[  479.165454] reboot: Power down
```

The machine was off. Upstream since 2021:
[PowerShell/PowerShell#14684](https://github.com/PowerShell/PowerShell/issues/14684).

As a **non-root** user it fails loudly and correctly — polkit's "Access denied
as the requested operation requires interactive authentication", exit 1 — so
there is no silent-failure problem, only a silent-wrong-action one.

And neither cmdlet carries **any** parameter on Linux beyond the common ones:
no `-Force`, no `-Wait`, no `-Delay`. A copied `Restart-Computer -Force` fails
on the parameter before it can do the wrong thing.

### 1.4 Three smaller measurements that decided code

* **`systemctl freeze` works, and a frozen unit still reports
  `ActiveState=active`.** Measured on the bench: freeze exits 0,
  `FreezerState=frozen`, `ActiveState=active`. So a paused service is invisible
  to every state field systemd offers except the freezer's own.
* **`[TimeZoneInfo]::TryConvertWindowsIdToIanaId` works on an OS/7 machine.**
  `W. Europe Standard Time` → `Europe/Berlin`, and back. So a Windows time-zone
  id out of a copied script can be honoured rather than rejected.
* **`Get-SystemdSession` has `Name`, `Uid` and `Class` — it has no `User`.**
  Guessed wrong in the first draft of `Get-ComputerInfo`; the machine said so.
  `Class` is what separates a signed-in person from the greeter and from each
  user's `manager` unit, all three of which logind calls sessions.

---

## 2. What was built

### 2.1 In the generic layer, `powershell/Systemd/` (+8 functions, 13 → 21)

`Invoke-SystemdShutdown` (mandatory `-Action`, never the flagless form),
`Get-SystemdUnitFreezerState`, `Suspend-`/`Resume-SystemdUnit`,
`New-`/`Remove-SystemdService`, `Get-`/`Set-SystemdHostName`. Plus a fourth
word on `Set-SystemdUnitStartup`: **`Unmasked`**, because `systemctl disable`
does not unmask and a caller walking a unit back from Masked otherwise leaves
it reporting `disabled` and refusing to start.

`Set-SystemdHostName` changes the static name, the transient name **and the
`127.0.0.1`/`127.0.1.1` line in `/etc/hosts`** together — sudo resolves its own
host name on every invocation, and a machine renamed without that line answers
`sudo: unable to resolve host` to everything afterwards.

### 2.2 In the product layer, `powershell/OS7/OS7.Compat.Windows.ps1` (+14)

Twelve of the fifteen absent names, plus `Restart-Computer` and
`Stop-Computer`. Three are not supplied — `Clear-RecycleBin`,
`Restore-Computer`, `Get-HotFix` — because this machine has no recycle bin, no
system restore and no Windows Update.

Functions, not aliases, and **loaded by default**. Every parameter the real
Windows cmdlet has is declared; each is honoured or **refused by name with a
reason and a pointer**. Nothing here touches systemd directly:
`check-layering.py` P2-systemd is unchanged at its baseline of 2.

The module count went **126 → 140**, and the total **229 → 243**.

### 2.3 The one decision this layer makes rather than translating

`Set-Service -StartupType Disabled` **masks** the unit. On Windows a disabled
service cannot be started at all; systemd's `disable` only removes it from boot.
Mapping the word to `disable` would quietly grant what a hardening script asked
to forbid. It warns when it does this, and `-StartupType Manual` unmasks.

This differs from `Set-OS7Service` deliberately: that cmdlet has four words and
its `Blocked` is the mask, because an OS/7 administrator can say which one they
mean and a copied script cannot. The difference is written down in both places.

The three words round-trip, measured on the bench:

```
Disabled  -> StartType=Disabled   UnitFileState=masked
Manual    -> StartType=Manual     UnitFileState=disabled
Automatic -> StartType=Automatic  UnitFileState=enabled
```

---

## 3. What was verified on a machine

On the `gui` bench, amd64, KVM in a container, all on 2026-09-09:

| | |
|---|---|
| `Restart-Computer` (OS/7's) | **the machine restarted** — `reboot: Restarting system`, VM still up on a fresh kernel |
| `Restart-Computer` (PowerShell's) | the machine **powered off** — `poweroff.target`, `reboot: Power down` |
| `Get-Service ssh` | 38 ms; `Status=Running`, `StartType=Manual`, `Unit=ssh.service`, `Healthy=True` |
| `Get-Service` (all) | **227 services in 2 815 ms** |
| Windows-shaped filters | Running 71, Stopped 156, Automatic 65, Manual 134, Disabled 0 |
| `Suspend-Service chrony` | `Status=Paused` while `ActiveState=active`, `freezer=frozen`; `Resume-` back to Running |
| `Set-Service -StartupType` | the three-word round trip above |
| `Set-TimeZone -Id 'W. Europe Standard Time'` | `Etc/UTC` → `Europe/Berlin`, symlink confirmed |
| `Get-ComputerInfo` | real values under Windows' names — QEMU/Q35, 4 logical processors, 7 778 336 768 bytes, `OS/7 1.0.0 (development)`, uptime, `Uefi` |
| a missing name | `Cannot find any service with service name 'nosuchservice'.` — non-terminating, the other name still returned |
| the shadow notice | **silent** on Linux (no such cmdlet), **fires** on Windows (there is one) |

**The 2 815 ms is the honest cost of a full listing**: `Get-Service` asks for
detail on every service, one `systemctl show` each, because `StartType` is
`$null` without it and a `$null` start type turns
`Get-Service | Where StartType -eq 'Automatic'` into a filter that silently
matches nothing. A single `systemctl list-unit-files` call would answer the same
question for the whole machine and is the obvious next improvement; it needs a
new verb in the generic layer, which this session did not add.

### Not verified

* **arm64.** Nothing here has run on arm64; the module code is
  architecture-independent and the measurement is not.
* **`New-Service` / `Remove-Service` on a machine.** Their decisions are
  checked against a fake systemd and their unit-writing discipline is
  `New-SystemdTimer`'s, which has run; the pair itself has not written a unit
  on a booted machine in this session.
* **`Rename-Computer` actually renaming a machine.** The refusal path (joined)
  is checked; the rename path is not — it changes the host name of the bench
  every other measurement here depends on, and it belongs in a harness with a
  snapshot around it.
* **`Restart-Computer -Delay`** (the scheduling path through `shutdown -r +m`).
  Checked against the fake, not on a machine.

---

## 4. What it changed in the plans

* **[POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md) P1a** — new, and it
  supersedes P1's last paragraph. The prefix stays canonical; the Windows names
  are no longer opt-in and no longer aliases. P1's own objection (a free name is
  not free for ever) is kept and answered with a warning that fires on first use
  if PowerShell ever ships one of these for real — asserted in both directions.
* **§1.1's table** — the `Restart-Computer, Stop-Computer` row said "present"
  and now says what "present" turned out to mean.
* **[BUILD-NOTES.md](BUILD-NOTES.md) #142** — the trap, and the rule: a cmdlet
  that exists is not a cmdlet that works, and when a program shells out, the
  argument vector IS the behaviour.
* **[POWERSHELL-REFERENCE.md](POWERSHELL-REFERENCE.md)** — the counts, a new
  section for the fourteen names, and two statements this session falsified: P4
  listed `Restart-Computer` among things "measured present and working", and the
  `Set-TimeZone` entry under "deliberately not here" described a module that is
  now built.
* **[docs/manual/](manual/README.md)**, both languages — §1.4's "there is no
  `Get-Service`" is now wrong and says so; appendix C's services note, its
  "what stayed the same" list and a new table of the fourteen; §9.6's example of
  something that already works was `Restart-Computer`, and it is now the
  paragraph explaining why it is not.

## 5. New and changed checks

| | |
|---|---|
| `check-compat-windows.py` | **new.** 214 checks, seconds, needs only pwsh. The contract in both directions, the refusal table proven to throw, the mapping tables proven total, and the four decisions that matter. `OS7_MODULE_ROOT` plants a defect on a copy: `Action = 'PowerOff'` in `Restart-Computer` goes RED. |
| `check-module-parts.py` | its four part-name regexes were `OS7\.[A-Za-z]+\.ps1`, which **cannot match `OS7.Compat.Windows.ps1`** — the new file was invisible in all four lists at once, which is the exact drift that check exists to catch. Widened, and its function-name patterns too, which were keyed to `-OS7` and could not see `Get-Service`. Parts 18 → 19. |
| `check-layering.py` | unchanged and green: five rules held, P2-systemd still 2. |
| `check-ps-traps.py` | unchanged and green: all six held over 25 files. |
| `Test-SystemdModule` | 95 checks, green. |

## 6. A note about how this session ran

A **second session was working in the same tree at the same time** and committed
this session's `powershell/Systemd/` work in
`f64bed0` — whose message says so, and which added the
`check_manifests_deliver` rule after observing that `Systemd.psd1` promised 21
functions while `Export-ModuleMember` was still at 13. That was this session's
own mistake, fixed here at 12:01 before the other one committed. Two agents in
one working tree is worth knowing about when reading the history: the commit
that carries a change is not necessarily the session that made it.
