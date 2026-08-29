# 9 Services, logs and remoting

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

## 9.5 What was not rebuilt

OS/7 rebuilds nothing PowerShell on Linux already does. There is no
`Get-OS7Process`, no `Get-OS7FileHash`, no `Restart-OS7Computer` and no
`Test-OS7Connection` — `Get-Process`, `Get-FileHash`, `Restart-Computer` and
`Test-Connection` work here normally.

The test for admission is not "would this be convenient" but "would an
administrator otherwise have to type a Linux command".
