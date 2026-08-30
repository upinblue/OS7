# 5 Boot environments and rollback

A **boot environment** is a complete, bootable system on the same disk. A
machine can have several and always boots exactly one. It is the mechanism that
turns an update into something that can be undone.

The idea is simple: instead of changing the running system, OS/7 makes a copy,
changes the copy, and switches afterwards. Because ZFS is copy-on-write, the
copy costs almost nothing at first — it grows only by the differences.

## 5.1 What is there

```powershell
Get-OS7BootEnvironment
```

![The machine's boot environments. The default output is one list per environment.](images/30-boot-environments.png)

The fields each say something different, and the differences matter:

| Field | Meaning |
|---|---|
| `Active` | ZFS has this environment mounted **somewhere** |
| `Running` | **the system is running out of this environment** |
| `Menu` | it has an entry in the boot menu |
| `Complete` | both halves — `rpool/ROOT` and `bpool/BOOT` — are present |
| `Release` | which OS/7 version is in it |
| `RootDataset`, `BootDataset` | the two datasets it consists of |
| `Origin` | the snapshot it was cloned from — empty for the installed one |

> **`Active` does not mean "running".** An update mounts the clone in order to
> fill it — at that moment two environments are `Active` and only one is
> `Running`. Everything that means "the running system" reads `Running`.

For an overview of several environments a table is handier:

```powershell
Get-OS7BootEnvironment | Format-Table Name,Active,Running,Menu,Release
```

## 5.2 What decides what boots

Three things, and **none of them is a ZFS property**:

![The three places that together decide which boot environment starts.](images/diagram-boot-environments-en.svg)

1. **OS/7 writes its own boot menu**
   (`/etc/grub.d/09_os7-boot-environments`), with one entry per environment.
   The menu generators Ubuntu ships list exactly one environment per machine; a
   menu generated from one environment can never contain a second.
2. **A file on the EFI partition** decides whose menu GRUB reads at all
   (`set prefix=($root)'/BOOT/<environment>@/grub'`).
3. **`saved_entry`** in that environment's `grubenv` names the entry inside it.

In practice: switching is a **bootloader operation**, not a ZFS one. Activating
a boot environment changes files on the EFI partition and in the boot pool —
not a property on a dataset.

## 5.3 Creating a boot environment

Before a risky change — a configuration edit you may want to take back — create
an environment without activating it:

```powershell
New-OS7BootEnvironment -Name demo
```

![Creating one shows every step: snapshots of both halves first, then the clones, then the result.](images/32-new-be.png)

The output is deliberately talkative. What you see is the complete work: a
snapshot of the root and of the boot pool, then one clone per dataset —
including the `var` children that belong to the boot environment — and finally
the result object. `Active` and `Running` are `False`: the new environment
exists, is mounted nowhere, and does not boot.

It now appears in the list:

```powershell
Get-OS7BootEnvironment
```

![Two boot environments. The new one has no menu entry yet.](images/33-be-after-new.png)

`-From` clones another environment instead of the running one; `-Release` gives
it a version label.

## 5.4 Switching

```powershell
Set-OS7BootEnvironment -Name demo
```

That creates the menu entry, sets the EFI pointer and writes `saved_entry`.
After the next restart the machine runs out of that environment.

> **There is no one-shot "just to try it" boot.** An environment that is booted
> without being activated gets the **activated** environment's `/boot` and
> package database — a half-switched pair that no tool detects. Activation is
> the only supported switch, and it is reversible; that is what `Restore-OS7`
> is for.

## 5.5 Rolling back

The way back after an update that did not work out:

```powershell
Restore-OS7
```

With no parameters this goes back to the previous environment — the one the
running environment came from. `-BootEnvironment` names a specific one:

```powershell
Restore-OS7 -BootEnvironment os7_1.0.0.159_202608300312
```

`Restore-OS7` switches, and nothing more. The user's data, the logs, the
services' state and everything under `rpool/DATA` and `rpool/USERDATA` stay
where they are — they live outside the boot environment and do not roll with
it. What is taken back is the system: `/`, `/usr`, `/etc`, the package database
and the kernel.

After the restart, a check is worth the seconds:

```powershell
Get-OS7BootEnvironment | Format-Table Name, Active, Running, Menu
Get-OS7Version
```

## 5.6 Cleaning up

Boot environments take space over time, because each holds the differences from
its origin. Remove one that is no longer needed:

```powershell
Remove-OS7BootEnvironment -Name demo -Confirm:$false
```

![Removal clears both halves — the root and the boot pool.](images/34-remove-be.png)

The command asks first; in a script you suppress that with `-Confirm:$false`.
Both halves go — an environment with only its boot-pool half left would be a
menu entry that leads nowhere.

The running and the active environment cannot be removed.

`Update-OS7` cleans up on its own: `-Keep` decides how many old environments
survive a successful update.

## 5.7 When a machine will not boot

The boot menu holds one entry per complete boot environment. If the machine
will not start after an update, pick the previous environment's entry in the
menu — the machine comes up, and then you make the switch permanent with
`Restore-OS7`.

That is why OS/7 writes its own menu and why one entry per environment is in
it: the way back has to work when nothing is running on the machine that you
could type a command into.
