# 8 Time

On OS/7 the clock is not a side issue but a prerequisite. Kerberos refuses a
ticket whose timestamp is more than **five minutes** from the domain
controller's clock — and a drifting clock does not report a clock problem. It
reports that the password is wrong.

That is why this short chapter comes before the chapters on management and the
directory, and why the five-minute limit is built into
`Get-OS7TimeSynchronization`.

Time synchronisation is **chrony**, not `systemd-timesyncd`.

## 8.1 What time is it

```powershell
Get-OS7Time | Format-List
```

![The clock: local time, UTC, the zone, and whether the hardware clock is kept in local time.](images/70-time.png)

The last field is the one that matters on a machine that also boots Windows:
Windows usually keeps the hardware clock in local time, Linux in UTC. When the
two assumptions disagree, the clock jumps at every switch.

## 8.2 Is the clock being set at all

```powershell
Get-OS7TimeSynchronization | Format-List
```

![Whether the clock is being disciplined, by whom, how far off it is — and whether that is close enough for a sign-in to work.](images/71-time-sync.png)

The command distinguishes **three** outcomes, and the distinction is the reason
it exists:

| Result | Meaning |
|---|---|
| `$null` | chronyd could not be asked — the service is not running |
| `$false` | chronyd was asked and is **not** disciplining the clock |
| `$true` | the clock is being disciplined |

"Could not be asked" and "answers no" are different states with different
causes. A command that merged both into "not synchronised" would make a crashed
service and a missing network connection indistinguishable.

The offset itself comes with it, and the statement whether it is inside the
Kerberos tolerance.

## 8.3 Setting the time zone

```powershell
Set-OS7TimeZone -Id Europe/London
```

The command writes the symlink that actually decides the zone and reads it
back. Valid identifiers are the IANA ones (`Europe/London`, `America/New_York`,
`UTC`).

## 8.4 Setting time servers

```powershell
Set-OS7TimeSynchronization -NtpServer dc01.contoso.local, dc02.contoso.local
```

In an Active Directory environment the domain controllers are the right time
sources — they are the clock Kerberos measures against.

A pool instead of individual servers:

```powershell
Set-OS7TimeSynchronization -Pool uk.pool.ntp.org
```

`-Exclusive` replaces the existing sources instead of adding to them.

The servers go into a file of their own under chrony's `sources.d` directory,
not into `chrony.conf`. chrony is then asked to reload — the service is **not**
restarted, because a restart discards the synchronisation already achieved.

## 8.5 Correcting the clock now

Normally chrony pulls a wrong clock in slowly (*slewing*), so that no time
jumps occur. After a long shutdown that is too slow:

```powershell
Sync-OS7Time
```

That tells chrony to step the clock **now**, waits for it to settle
(`-SettleSeconds`) and reports what actually happened.

## 8.6 The order to ask in, on a sign-in problem

When a sign-in against the domain fails with "wrong password" and the password
is right, this is the order:

```powershell
Get-OS7TimeSynchronization      # is the clock being set at all?
Get-OS7Time                     # and is it right?
Test-OS7Directory -Domain contoso.local   # measures the skew against the DC
```

`Test-OS7Directory` measures the offset against the domain controller's own
clock — and that is the number that counts, not the offset against some time
server.
