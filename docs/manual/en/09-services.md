# 9 Services, scheduled tasks, logs and remoting

## 9.1 Services

What is a *service* on a Linux machine is a *unit* to **systemd**.
`Get-OS7Service` presents them as objects — and answers one question
`systemctl` does not.

```powershell
Get-OS7Service -OS7Only -Detailed
```

![The services that make an OS/7 machine, with the health verdict.](images/50-services.png)

### `Healthy` is not `active`

In **both** directions. That is why the field exists:

**`Healthy = $false` although `systemctl` says `active`.** A service in a
restart loop has the sub-state `auto-restart`, and `systemctl is-active`
reports that as `active`. It is not well.

**`Healthy = $true` although the service is not running.** A `oneshot` unit —
`zfs-mount.service`, for instance — is `inactive/dead` after a successful run,
and that is its correct end state. A check that reads "not running" as "sick"
reports a fault on a perfectly well machine. The first version of this field
did exactly that.

`Healthy` is therefore `$false` when one of these holds:

* the unit is `failed`;
* it is in a restart loop;
* it stopped for a reason that was not success;
* it is enabled at boot, is a service that **stays up**, and is not up.

> **`-Detailed` is required if you want to evaluate `Healthy`.** Without the
> switch the details were never fetched and `Healthy` is `$null` — not
> `$false`. A `Where-Object { -not $_.Healthy }` without `-Detailed` therefore
> matches **every** service.
>
> The correct form is:
> ```powershell
> Get-OS7Service -Detailed | Where-Object { $_.Healthy -eq $false }
> ```

A single service:

```powershell
Get-OS7Service -Name ssh.service -Detailed | Format-List
```

![One service in detail.](images/51-one-service.png)

### Controlling services

```powershell
Start-OS7Service   -Name chrony.service
Stop-OS7Service    -Name chrony.service
Restart-OS7Service -Name chrony.service
```

Each of these reports **what the unit became** — not what was asked of it. A
`Start-` that returns an object whose `ActiveState` is not `active` is a failed
start, and it looks like one.

Whether a service comes up at boot:

```powershell
Set-OS7Service -Name ssh.service -StartupType Automatic
```

The choices are `Automatic`, `Manual`, `Disabled` and `Blocked`. `Blocked` is
stronger than `Disabled`: it also prevents another service from pulling the
unit in as a dependency.

## 9.2 Logs

```powershell
Get-OS7Log -Tail 6 | Format-Table Timestamp,Unit,Message
```

Because these are objects, you filter with PowerShell rather than with `grep`:

```powershell
Get-OS7Log -Priority Error -Since (Get-Date).AddHours(-2)
Get-OS7Log -Unit ssh.service -Tail 50
Get-OS7Log -OS7Only -Boot 0
Get-OS7Log -Since '2026-08-28 14:00' -Until '2026-08-28 15:00' |
    Group-Object Unit | Sort-Object Count -Descending
```

`-Boot 0` is the running boot, `-Boot -1` the one before — useful after an
unexpected restart.

Filtering is on the `Unit` field systemd sets itself, not on what the sender
claims. Otherwise a program could steer whether it appears in a filtered log.

## 9.3 The installation log

The installation itself has no journal — the system that would have recorded it
did not exist yet. Setup therefore writes a file of its own onto the machine,
holding each step's self-proof:

```powershell
Get-OS7InstallLog | Select -Skip 4 -First 8 Message
```

![The record of the installation, as it sits on the machine.](images/53-install-log.png)

The file lives at `/var/log/os7-setup/install.log` with mode `0600` and sits
**inside** the boot environment — so it survives a rollback, because it belongs
to exactly this installation.

Secrets are not in it. Where one was involved the line reads `[not kept]` — it
witnesses that something was passed without saying what.

## 9.4 PowerShell remoting

```powershell
Get-OS7Remoting | Format-List
```

![Whether this machine can be reached with PowerShell — in both senses of the question.](images/80-remoting.png)

"Reachable with PowerShell" can mean two things, and the command answers both
separately:

* **An interactive SSH login lands in PowerShell.** That is true on every OS/7
  machine and needs nothing.
* **`Enter-PSSession -HostName` works.** That needs a subsystem in the SSH
  service which is not configured out of the box.

Turning the second on:

```powershell
Enable-OS7Remoting
```

Then, from another machine:

```powershell
Enter-PSSession -HostName os7-srv-01 -UserName os7admin
Invoke-Command -HostName os7-srv-01 -UserName os7admin -ScriptBlock {
    Get-OS7BootEnvironment
}
```

And off again:

```powershell
Disable-OS7Remoting
```

> **There is no WinRM.** `New-PSSession -ComputerName` exists as a parameter
> and answers *"no supported WSMan client library was found"*. The way onto an
> OS/7 machine is SSH-based remoting, that is `-HostName`. It is PowerShell's
> own mechanism and works from Windows too.

## 9.5 Scheduled tasks

What the Task Scheduler is on Windows, **systemd timers** are here — and they
are deliberately not services. `Get-OS7Service` answers "is this program
running"; `Get-OS7ScheduledTask` answers "what will run, and when":

```powershell
Get-OS7ScheduledTask | Format-Table Name,NextRun,LastRun
```

![Everything that runs on a schedule, with the next and the last run.](images/54-scheduled-tasks.png)

The list includes tasks that are currently disabled — a task you have switched
off has not ceased to exist, and an inventory that loses it would be an
inventory you cannot trust.

Three of these schedules are the product's own: `sanoid.timer` takes the
backup snapshots (chapter 12), `os7-backup-replicate.timer` copies them to the
backup target, and `os7-update-check.timer` is the unattended update check
(chapter 6.7). They are managed like any other task — but they belong to the
product, which matters for `Unregister-` below.

One task in full:

```powershell
Get-OS7ScheduledTask sanoid.timer | Format-List
```

![One scheduled task in detail — schedule, next run, last run, and the outcome.](images/55-task-detail.png)

`LastRun` is when the **schedule** last fired; `LastResult` is how that run
ended. Starting a task by hand moves `LastResult` and not `LastRun` — the
schedule did not fire, and the two answers are kept apart on purpose.

### `Healthy`, and the trap it exists to name

A timer can be **enabled and still never run**: systemd's `enable` arms the
*next boot* and nothing else. A timer in that state is enabled, inactive, and
will not fire until the machine restarts — and no tool on the machine calls
that a problem. `Get-OS7ScheduledTask` does: `Healthy` is `$false` and
`NextRun` is empty.

`Enable-OS7ScheduledTask` therefore does both — it enables the task *and* arms
it now:

```powershell
Enable-OS7ScheduledTask  os7-update-check.timer
Disable-OS7ScheduledTask os7-update-check.timer
```

`Healthy` is also `$false` for a task whose last run failed. As everywhere
else, it is `$null` when the details were not fetched — a check that did not
run must never read as one that passed.

### Running a task now

```powershell
Start-OS7ScheduledTask os7-update-check.timer
```

This starts the task's **service**, waits for it, and reports what happened —
the same run the schedule would have produced, just now.

### Creating your own task

A weekly pool scrub, Sunday at three in the morning — the parameters no longer
fit on one line, so they are splatted, which is the idiom for any parameter
set that has outgrown a line:

```powershell
$t = @{ Name='scrub'; Weekly=$true; DayOfWeek='Sunday' }
```

![The task's parameters, collected in a hashtable.](images/56-register-a.png)

```powershell
$t += @{ At='03:00'; Command='Start-ZpoolScrub rpool' }
```

![The schedule and the command join them.](images/57-register-b.png)

```powershell
Register-OS7ScheduledTask @t
```

![The registered task, armed — NextRun has a value.](images/58-register.png)

The task is named `os7-task-scrub` — every task you register carries the
`os7-task-` prefix, which is what makes it recognisably yours in every
listing. `-Command` runs PowerShell; for anything else there is
`-Execute`/`-Arguments` with an absolute path. `-Daily -At` and
`-Weekly -DayOfWeek -At` cover the common schedules; `-OnCalendar` takes a raw
systemd calendar expression for everything they cannot say (`'Mon..Fri
06:30'`, `'*-*-01 06:00:00'`). The schedule is validated **before** anything
is written — a spec systemd cannot parse is refused with systemd's own error,
not written to disk as a timer that never fires.

Two switches are worth knowing: `-Persistent` catches up after downtime (a
machine that was off at three runs the job when it returns), and
`-RandomizedDelay` spreads a fleet's runs over a window, so a thousand
machines do not start the same job in the same second.

> **No secrets in `-Command`.** The command line lands in a world-readable
> unit file and shows in systemd's own tooling. A task that needs a credential
> reads it at run time from a root-owned file with mode `0600`.

### Removing a task

```powershell
Unregister-OS7ScheduledTask scrub -Confirm:$false
```

![The task is stopped, disarmed and removed.](images/59-unregister.png)

`Unregister-` removes **only** tasks that were created with `Register-` — it
refuses `sanoid.timer` and the other product schedules by name. Those belong
to packages, and deleting a package's unit file leaves the package manager
believing in a file that is gone. A product schedule you want silenced is
disabled, not removed:

```powershell
Disable-OS7ScheduledTask sanoid.timer
```

## 9.6 What was not rebuilt

OS/7 rebuilds nothing PowerShell on Linux already does. There is no
`Get-OS7Process`, no `Get-OS7FileHash`, no `Restart-OS7Computer` and no
`Test-OS7Connection` — `Get-Process`, `Get-FileHash`, `Restart-Computer` and
`Test-Connection` work here normally.

The test for admission is not "would this be convenient" but "would an
administrator otherwise have to type a Linux command".
