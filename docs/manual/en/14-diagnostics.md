# 14 Diagnostics

This chapter is an order, not a list of commands. The commands are in the
chapters before it; here is the sequence to ask them in, and why the sequence
is what it is.

## 14.1 The rule underneath

**Ask the thing itself, not its exit code.**

The expensive faults all have the same shape: a program reported success, and
the thing it was meant to change did not change. An exit code is a diagnostic.
So is a log line.

In practice: when a command says it wrote the network configuration, ask the
kernel which address is on the adapter. When a service reports `active`, ask
for `Healthy`. The cmdlets in this manual do that by themselves — the rule is
for everything you do beside them.

**And: a diagnostic must not depend on the subsystem it is diagnosing.** The
state of the network cannot be asked over the network; the state of systemd not
through a service systemd starts.

## 14.2 First look at a machine

```powershell
Get-OS7Version                                  # which OS/7, which boot environment
Get-OS7BootEnvironment | Format-Table Name, Active, Running, Menu, Release
Get-Zpool | Format-Table Name, Health, Free
Get-OS7Service -Detailed | Where-Object { $_.Healthy -eq $false }
Test-OS7Network
Get-OS7ManagementStatus
```

Six commands, about a minute. If nothing here stands out, the problem is not in
the machine's foundations.

## 14.3 A sign-in fails

The most common wrong turn: the password is assumed to be wrong, because that
is what the error says.

```powershell
# 1. The clock. Kerberos refuses beyond five minutes of skew,
#    and the message then reads "wrong password".
Get-OS7TimeSynchronization
Get-OS7Time

# 2. With Entra: is the broker missing? That also looks like a wrong password.
Get-OS7EntraStatus

# 3. With a domain: which link of the chain is missing?
Test-OS7Directory -Domain contoso.local
Test-OS7Domain   -Domain contoso.local

# 4. Only now, the log.
Get-OS7Log -Priority Error -Since (Get-Date).AddMinutes(-15)
```

The order is chosen so that the causes which disguise themselves as something
else are checked first.

## 14.4 No network

```powershell
Get-OS7NetworkAdapter                 # is there an adapter, does it have link?
Get-OS7NetworkConfiguration           # configured and effective — do they agree?
Test-OS7Network                       # where does the chain break?
```

The second is the telling one. A common case is a netplan file describing an
adapter this machine does not have — netplan accepts that in silence and
configures nothing.

After a failed change:

```powershell
Set-OS7NetworkAdapter -Name enp0s31f6 -Dhcp
```

And if an earlier attempt ended in `RollbackFailed`, the machine needs hands at
the console — that is the case where the rollback itself failed.

## 14.5 The machine will not boot

1. In the boot menu, pick the entry for the **previous boot environment**.
   There is one for every complete environment.
2. Once the machine is up, make the switch permanent:
   ```powershell
   Restore-OS7
   ```
3. Then look at what was wrong in the new environment:
   ```powershell
   Get-OS7Log -Boot -1 -Priority Error
   ```

If the machine drops to an initramfs prompt, the disk was not unlocked or the
pool was not imported. That is the corner where the passphrase is needed — the
TPM unlock does not take when the boot chain has changed, after a firmware
update for instance.

## 14.6 An update went wrong

```powershell
Get-OS7BootEnvironment | Format-Table Name, Active, Running, Menu, Complete, Release
```

Read `Running`, not `Active` — during an update two environments are `Active`
and only one is running.

`Complete = False` means an environment is missing one of its halves. Such an
environment should not be booted; remove it and start the update again.

Back:

```powershell
Restore-OS7
```

## 14.7 The pool is full

```powershell
Get-ZfsSpace rpool | Format-List
Get-ZfsDataset | Sort-Object Used -Descending | Select-Object -First 10 Name, Used
Get-ZfsSnapshot | Sort-Object Used -Descending | Select-Object -First 10 Name, Used
Get-OS7BootEnvironment | Format-Table Name, Used, Running
```

Three usual causes, in that frequency:

1. **Old boot environments.** Each holds the differences from its origin.
   `Remove-OS7BootEnvironment` clears them, and `Update-OS7 -Keep` stops them
   accumulating.
2. **Backup policy snapshots.** Retention is set with
   `Set-OS7BackupPolicy -Retention`.
3. **Hand-made snapshots** nobody removed.

## 14.8 What to attach to a report

When you pass a fault on, attach this — it answers most of the follow-up
questions in advance:

```powershell
Get-OS7Version -Detailed
Get-OS7BootEnvironment | Format-Table *
Get-OS7Service -Detailed | Where-Object { $_.Healthy -eq $false } | Format-Table *
Get-OS7Log -Priority Error -Boot 0 | Select-Object -Last 50
Get-OS7InstallLog | Select-Object -Last 40
```

The installation log is particularly useful, because it holds each installation
step's self-proof — and because it survives a rollback.
