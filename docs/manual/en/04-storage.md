# 4 Storage and the filesystem

OS/7's filesystem is **ZFS**. Coming from Windows, think of it as disk
management, the filesystem, shadow copies and software RAID combined — except
that one layer manages all of it and all of it can be checked for consistency
at any time.

Two terms are enough to start:

* A **pool** is the disks taken together. OS/7 creates two: `bpool` for what
  GRUB has to read, and `rpool` for everything else.
* A **dataset** is a filesystem inside a pool. Datasets share the pool's free
  space but have their own properties, their own snapshots and their own mount
  point. Where Windows would create a partition, ZFS creates a dataset — with
  no fixed size and no reformatting.

## 4.1 Looking at the pools

```powershell
Get-Zpool | Format-Table Name,Health,Size,Free
```

![The two pools of an OS/7 machine.](images/20-get-zpool.png)

`Health` is the question that counts. `ONLINE` is good; anything else is a
reason to look further:

```powershell
Get-ZpoolStatus rpool | Format-List Name,State,Scan
```

![A pool's state, with its last scan.](images/21-zpool-status.png)

`Get-ZpoolStatus` returns the vdev tree as **objects**, not as indented text.
You can walk it instead of reading it:

```powershell
(Get-ZpoolStatus rpool).Vdevs | Where-Object { $_.State -ne 'ONLINE' }
```

A full verification of the pool is started with:

```powershell
Start-ZpoolScrub rpool
```

It runs in the background and barely affects service; progress appears in
`Get-ZpoolStatus`'s `Scan` field.

## 4.2 The datasets

```powershell
Get-ZfsDataset | Format-Table Name,Mountpoint
```

![The dataset layout of an installed machine. The structure is the one from chapter 3.](images/22-datasets.png)

This output is the layout chapter 3 drew:

| What you see | What it is |
|---|---|
| `rpool/ROOT/os7_<version>_<time>` | the boot environment — the system itself |
| `rpool/ROOT/…/var/lib/dpkg`, `…/var/lib/apt`, `…/var/cache` | the package database, **inside** the boot environment |
| `rpool/DATA/log`, `…/spool`, `…/tmp`, `…/srv`, `…/lib/<service>` | state **outside** the boot environment |
| `rpool/USERDATA/<user>_<uuid>` | a home directory, outside the boot environment |
| `bpool/BOOT/os7_<version>_<time>` | this environment's kernel and initramfs |

Sizes come back as **`uint64` bytes**, timestamps as `[datetime]`. You can
calculate and sort without parsing:

```powershell
Get-ZfsDataset | Sort-Object Used -Descending | Select-Object -First 5 Name,
    @{ n = 'Used'; e = { Format-ZfsSize $_.Used } }
```

## 4.3 Where the space went

ZFS answers "why is the pool full" differently from an ordinary filesystem,
because snapshots hold space that no visible file needs any more:

```powershell
Get-ZfsSpace rpool | Format-List
```

![The breakdown of used space.](images/23-space.png)

The fields separate what the data itself occupies, what **snapshots** are
holding, and what is reserved for child datasets. A pool that is full with
nothing visibly in it is holding its space in snapshots — and those come either
from the backup policy (chapter 12) or from old boot environments (chapter 5).

## 4.4 Home directories

Every home directory should sit on a dataset of its own under
`rpool/USERDATA`. This is not tidiness: a home **inside** the boot environment
is taken back by a rollback along with the user's files, and no snapshot policy
can follow it.

```powershell
Get-OS7Home | Format-List
```

![For each home directory: does it have a dataset of its own, does it actually live there, and do those two answers agree.](images/24-home.png)

The fields are chosen so that the fault shows, not only the intent:

| Field | Question |
|---|---|
| `Dataset` | which dataset this home is meant to be on |
| `OwnDataset` | whether that dataset exists |
| `OwnFilesystem` | whether the home really is on a filesystem of its own |
| `Agrees` | whether those two say the same thing |
| `DeviceId` | the filesystem id that answer was derived from |

`Agrees = False` is exactly the case the field exists to find: the dataset is
there, and the home is somewhere else.

Moving a home onto its own dataset after the fact:

```powershell
Move-OS7Home -UserName smith
```

The move creates the dataset, copies the content, verifies it and remounts.
The original stays put at first; only `-RemoveOriginal` removes it, and only
after the verification passed.

## 4.5 Snapshots by hand

The backup policy in chapter 12 takes snapshots on a schedule. Before a larger
change one by hand is worth having:

```powershell
New-ZfsSnapshot -Name rpool/USERDATA/smith_1a2b3c4d -SnapshotName before-migration
Get-ZfsSnapshot | Where-Object Name -like '*@before-migration'
```

A snapshot costs nothing at first and grows only by what changes afterwards. A
single file is fetched back out of a snapshot with `Restore-OS7File` (chapter
12.7), without touching the dataset.

> **Careful.** `Restore-ZfsSnapshot` rolls an **entire dataset** back to the
> snapshot and discards everything newer, irreversibly. For "I only need this
> one file from yesterday", `Restore-OS7File` is the right tool.

## 4.6 What not to do

**No swap on ZFS.** Under memory pressure the combination deadlocks. OS/7 puts
swap on zram, compressed in memory.

**No snapshot policy on `rpool/ROOT` or `bpool/BOOT`.** Those datasets belong to
the boot-environment mechanism; a second thing taking and pruning snapshots
there gets in its way. `Assert-OS7DatasetSafe` refuses it even if somebody
tries.

**Do not create datasets by hand where a cmdlet exists.** `New-OS7Storage` and
`New-OS7BootEnvironment` set properties a clone does not inherit — `canmount`
and `mountpoint` in particular. A hand-made clone comes out `canmount=on
mountpoint=none`: mountable over the running root, and invisible to every boot
menu.
