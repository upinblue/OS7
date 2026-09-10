# Appendix C  For Windows administrators

What you do on Windows, and how it is done on OS/7. The table is a map, not an
equivalence — where the concepts differ, it says so.

## The system and its version

| Windows | OS/7 |
|---|---|
| `winver`, `Get-ComputerInfo` | `Get-OS7Version`, `Get-OS7Version -Detailed` |
| `systeminfo` | `Get-OS7Version -Detailed`, `Get-OS7ManagementStatus` |
| Control Panel → System | `Get-OS7Version`, `Get-OS7Home`, `Get-Zpool` |

## Services

| Windows | OS/7 |
|---|---|
| `Get-Service` | `Get-OS7Service` |
| `Get-Service \| Where Status -eq Running` | `Get-OS7Service -Detailed \| Where { $_.Healthy -eq $false }` |
| `Start-Service`, `Stop-Service`, `Restart-Service` | `Start-OS7Service`, `Stop-OS7Service`, `Restart-OS7Service` |
| `Set-Service -StartupType` | `Set-OS7Service -StartupType` |
| `services.msc` | `Get-OS7Service -OS7Only -Detailed` |

> **The left-hand column works here too.** `Get-Service`, `Start-Service`,
> `Stop-Service`, `Restart-Service` and `Set-Service` exist on OS/7 with
> Windows' parameters and Windows' columns (`Status`, `Name`, `StartType`,
> `DisplayName`) — PowerShell itself does not ship them on Linux. The
> right-hand column stays the surface this manual teaches: its parameters are
> systemd's, and `Healthy` answers a question `Status` cannot — a unit in a
> restart loop reports `Running`.
>
> Two differences matter if you use the Windows names.
> `Set-Service -StartupType Disabled` **masks** the unit, because "cannot be
> started" is exactly what that means to systemd; `-StartupType Manual` undoes
> it. And `Suspend-Service` freezes the processes rather than asking the service
> to pause — systemd does not ask.

## Scheduled tasks

| Windows | OS/7 |
|---|---|
| `Get-ScheduledTask`, `taskschd.msc` | `Get-OS7ScheduledTask` |
| `Get-ScheduledTaskInfo` | `Get-OS7ScheduledTask <name>` — `NextRun`, `LastRun`, `LastResult` |
| `Enable-ScheduledTask`, `Disable-ScheduledTask` | `Enable-OS7ScheduledTask`, `Disable-OS7ScheduledTask` |
| `Start-ScheduledTask` | `Start-OS7ScheduledTask` |
| `Register-ScheduledTask` | `Register-OS7ScheduledTask` |
| `Unregister-ScheduledTask` | `Unregister-OS7ScheduledTask` |
| `schtasks /create` | `Register-OS7ScheduledTask -Daily -At 03:00 -Command '…'` |

## Event log

| Windows | OS/7 |
|---|---|
| `Get-WinEvent`, `eventvwr` | `Get-OS7Log` |
| `Get-WinEvent -MaxEvents 50` | `Get-OS7Log -Tail 50` |
| filter by source | `Get-OS7Log -Unit ssh.service` |
| filter by level | `Get-OS7Log -Priority Error` |
| events since the last boot | `Get-OS7Log -Boot 0`, before that `-Boot -1` |

## Network

| Windows | OS/7 |
|---|---|
| `Get-NetAdapter` | `Get-OS7NetworkAdapter` |
| `Get-NetIPConfiguration` | `Get-OS7NetworkConfiguration` |
| `New-NetIPAddress`, `Set-DnsClientServerAddress` | `Set-OS7NetworkAdapter -Address … -Nameserver …` |
| turn on DHCP | `Set-OS7NetworkAdapter -Dhcp` |
| `Test-NetConnection` | `Test-OS7Network`, or PowerShell's own `Test-Connection` |
| `ipconfig /all` | `Get-OS7NetworkAdapter \| Format-List` |

## Time

| Windows | OS/7 |
|---|---|
| `w32tm /query /status` | `Get-OS7TimeSynchronization` |
| `w32tm /resync` | `Sync-OS7Time` |
| `Set-TimeZone` | `Set-OS7TimeZone -Id Europe/London` |
| `Get-Date` | `Get-Date` (unchanged); `Get-OS7Time` for the full answer |

## Disks

| Windows | OS/7 |
|---|---|
| Disk Management, `Get-Disk`, `Get-Volume` | `Get-Zpool`, `Get-ZfsDataset` |
| `Get-Volume \| Select SizeRemaining` | `Get-ZfsSpace` |
| growing a partition | does not arise — datasets share the pool's free space |
| `chkdsk` | `Start-ZpoolScrub` (verifies all data against its checksums) |
| Volume Shadow Copies | ZFS snapshots: `New-ZfsSnapshot`, `Get-ZfsSnapshot` |
| Previous Versions of a file | `Get-OS7FileVersion`, `Restore-OS7File` |

## Updates and recovery

| Windows | OS/7 |
|---|---|
| Windows Update | `Get-OS7Release`, `Update-OS7` |
| WSUS ring / servicing ring | `Set-OS7UpdateChannel -Channel stable\|preview\|development` |
| uninstall an update | `Restore-OS7` — goes back to the previous boot environment |
| System Restore point | `New-OS7BootEnvironment` |
| managing restore points | `Get-`/`Remove-OS7BootEnvironment` |
| Safe Mode | pick an older boot environment in the boot menu |

> The difference from Windows is fundamental: an update on OS/7 does **not**
> change the running system. It fills a copy and switches afterwards. There is
> therefore no such state as "half updated".

## Directory

| Windows (RSAT / ActiveDirectory module) | OS/7 |
|---|---|
| `Get-ADUser` | `Get-OS7ADUser` |
| `New-ADUser` | `New-OS7ADUser` |
| `Set-ADUser` | `Set-OS7ADUser` |
| `Get-ADGroup`, `Get-ADGroupMember` | `Get-OS7ADGroup`, `Get-OS7ADGroupMember` |
| `Add-ADGroupMember` | `Add-OS7ADGroupMember` |
| `Set-ADAccountPassword` | `Reset-OS7ADAccountPassword` |
| `Unlock-ADAccount`, `Enable-`/`Disable-ADAccount` | `Unlock-OS7ADAccount`, `Enable-`/`Disable-OS7ADAccount` |
| `Get-ADComputer`, `Get-ADOrganizationalUnit` | `Get-OS7ADComputer`, `Get-OS7ADOrganizationalUnit` |
| `Get-ADObject -LDAPFilter` | `Search-OS7AD -Filter` |
| `Add-Computer -DomainName` | `Join-OS7Domain` |
| `Test-ComputerSecureChannel` | `Test-OS7Domain` |
| `Reset-ComputerMachinePassword` | `Repair-OS7Domain` |
| `klist`, `klist purge` | `Get-OS7KerberosTicket`, `Remove-OS7KerberosTicket` |

Unlike on Windows, directory administration needs **no domain membership**:
`Enter-OS7AdminSession` opens a session from any OS/7 machine.

## Remoting

| Windows | OS/7 |
|---|---|
| `Enter-PSSession -ComputerName` (WinRM) | `Enter-PSSession -HostName` (SSH) |
| `Invoke-Command -ComputerName` | `Invoke-Command -HostName` |
| `Enable-PSRemoting` | `Enable-OS7Remoting` |
| RDP | SSH; on the desktop, the usual Linux tools as well |

> There is no WinRM here. `-ComputerName` exists as a parameter and answers "no
> supported WSMan client library was found". SSH-based remoting is PowerShell's
> own mechanism and works from Windows too.

## What stayed the same

These cmdlets work unchanged on OS/7 and were therefore deliberately **not**
rebuilt:

`Get-Process` · `Stop-Process` · `Get-FileHash` · `Get-Date` ·
`Test-Connection` · `Get-Credential` · `Get-ChildItem` · `Copy-Item` ·
`Select-String` · `ConvertTo-Json` · `Invoke-RestMethod` · `Get-Content` ·
`Start-Job`

`Restart-Computer` and `Stop-Computer` were on that list until 2026-09-09 and
are now on the next one: **OS/7 supplies them itself.** PowerShell's own version
on Linux runs `/usr/sbin/shutdown` with **no arguments at all**, and on Ubuntu
that path is a symlink to `systemctl`, whose default action without a flag is
**power off**. So `Restart-Computer` powered the machine off and reported
success. The OS/7 version says `systemctl reboot`, and it takes the `-Force` a
copied script carries — PowerShell's own has no parameters at all on Linux.

## Windows names that exist here

Fourteen cmdlets from `Microsoft.PowerShell.Management` that PowerShell does not
ship on Linux (measured: 15 of the 62 documented ones are absent) are supplied
by OS/7 itself, with Windows' parameters:

| Name | Note |
|---|---|
| `Get-Service` | `Status` is `Running`/`Stopped`/`Paused`, `StartType` is `Automatic`/`Manual`/`Disabled`. systemd's own words sit beside them: `SystemdActiveState`, `SystemdSubState`, `SystemdFreezerState` — and `Healthy`. |
| `Start-`/`Stop-`/`Restart-Service` | Each reads the unit back afterwards. `systemctl start` reports success as soon as the *job* is accepted. |
| `Suspend-`/`Resume-Service` | systemd's freezer. It freezes every process in the unit without asking. A frozen unit still reports `ActiveState=active`, which is why `Paused` comes from the freezer. |
| `Set-Service` | `-StartupType` and `-Status`. `Disabled` masks. |
| `New-`/`Remove-Service` | Writes or removes a `.service` unit in `/etc/systemd/system` and asks systemd whether it loaded. It removes nothing a package brought. |
| `Set-TimeZone` | The half that was missing beside `Get-TimeZone`. Takes IANA names **and Windows ids**: `-Id 'W. Europe Standard Time'` becomes `Europe/Berlin`. |
| `Get-ComputerInfo` | What this machine is, under Windows' property names. |
| `Rename-Computer` | Changes the static name, the kernel name and the `127.0.1.1` line in `/etc/hosts` together. **Refused on a domain-joined machine** — the keytab carries the old name. |
| `Restart-`/`Stop-Computer` | See above. |

> Anything a cmdlet here cannot do, it refuses **by name** and says where to go:
> `Get-Service -DependentServices` explains that systemd keeps dependencies as a
> graph and that `systemctl list-dependencies --reverse` answers the question. A
> parameter ignored in silence would be worse than an error.

And so does the whole language: pipelines, `Where-Object`, `ForEach-Object`,
the format cmdlets, `Export-Csv`, error handling, scripts and modules.

## What is not here

| Windows | Why not |
|---|---|
| Group Policy / the GPO editor | there is no GPO engine for Linux |
| `repadmin`, `dcdiag`, `netdom` | RPC/DCOM; no cross-platform client |
| DNS and DHCP server management | the same cause |
| `[ADSI]` | `System.DirectoryServices` loads on Linux and then throws "not supported on this platform". A Windows script built on it does not port by copying |
| WinRM | see above |
