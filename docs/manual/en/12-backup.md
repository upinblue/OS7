# 12 Backup and restore

OS/7's backup has two halves, and the split explains the whole chapter:

* **Snapshots on this machine** protect against mistakes — deleted by accident,
  overwritten wrongly, a migration that went badly. They cost almost nothing
  and are available immediately.
* **Replication to a target** protects against losing the machine. It needs a
  second medium and time.

Snapshots are on by default; replication is a deliberate decision.

![The backup architecture: sanoid snapshots, syncoid replicates, and OS/7 verifies — by asking ZFS, never the tools.](images/diagram-backup-en.svg)

> **Why OS/7 verifies.** Both tools report success in cases where nothing
> happened: sanoid exits 0 even when taking a snapshot failed, and its own
> monitoring answers from a cache that is deliberately allowed to be five hours
> old. So `Get-OS7BackupStatus` asks **ZFS** — on the source, and over SSH on
> the target — and neither of the two tools.

## 12.1 Looking at the policy

```powershell
Get-OS7BackupPolicy | Format-List
```

![What this machine snapshots and how long it keeps it.](images/90-backup-policy.png)

The detail per dataset:

```powershell
(Get-OS7BackupPolicy).Sources | Format-Table Dataset, Snapshots, Newest
```

The policy lives in `/etc/os7/backup.json`. That file is the authority; the
configuration for sanoid is generated from it — and parsed by sanoid itself
before it is installed.

## 12.2 Changing the policy

Which datasets are backed up:

```powershell
Set-OS7BackupPolicy -Dataset rpool/USERDATA, rpool/DATA/srv
```

How long the snapshots are kept:

```powershell
Set-OS7BackupPolicy -Retention @{ hourly = 48; daily = 30; weekly = 8; monthly = 12 }
```

On and off:

```powershell
Enable-OS7Backup
Disable-OS7Backup
```

Disabling **destroys nothing**. Existing snapshots stay; no new ones are taken
and no old ones are pruned.

> **`rpool/ROOT` and `bpool/BOOT` do not belong in the policy.** Those datasets
> belong to the boot-environment mechanism. The attempt is refused — a second
> thing taking and pruning snapshots there would get in the rollback's way.

## 12.3 What the policy actually reaches

A policy that names a home directory which is not on a dataset of its own does
not back that home up — it backs nothing up under that name, and does not say
so by itself:

```powershell
Get-OS7BackupCoverage | Format-List
```

![Which home directories the policy actually reaches — and for those it does not, why.](images/91-backup-coverage.png)

Only what is not covered:

```powershell
Get-OS7BackupCoverage | Where-Object { -not $_.Covered }
```

This is the companion to `Get-OS7Home` in chapter 4.4: there the question was
whether a home is on a dataset of its own; here it is whether the backup
reaches it. A home without its own dataset cannot be caught by any snapshot
policy.

## 12.4 Setting up a target

**An external disk**, prepared by OS/7:

```powershell
$pw = Read-Host -AsSecureString -Prompt 'Passphrase for the backup disk'
New-OS7BackupTarget -Name usb `
    -CreateOn /dev/disk/by-id/usb-Samsung_T7_0001 `
    -ConfirmDisk /dev/disk/by-id/usb-Samsung_T7_0001 `
    -Passphrase $pw
```

> **`-ConfirmDisk` is not a prompt, it is a second naming.** This command
> **erases the named disk**. Someone who has to type it twice does not type the
> wrong one — a yes/no prompt only confirms that the command was submitted.

**A pool on another machine**, over SSH:

```powershell
New-OS7BackupTarget -Name nas -ComputerName backup@nas.lan -Dataset tank/os7
```

**An existing local pool:**

```powershell
New-OS7BackupTarget -Name second -Pool tank -Dataset tank/os7
```

Looking at targets and testing them:

```powershell
Get-OS7BackupTarget | Format-Table Name, Kind, Present, InSync, NewestReplicated
Test-OS7BackupTarget usb
```

Mounting and unmounting a removable disk:

```powershell
Mount-OS7BackupTarget usb -Passphrase $pw
# … replication …
Dismount-OS7BackupTarget usb
```

`Dismount-` exports the pool and closes the LUKS container so the disk can be
pulled safely.

## 12.5 Backing up

Snapshots run on a schedule. By hand:

```powershell
Start-OS7Backup                          # snapshots only
Start-OS7Backup -Replicate               # snapshots, then replicate
Start-OS7BackupReplication -Target nas   # replicate only, this target only
```

The replication run takes a lock, because syncoid has none of its own — two
concurrent runs against the same source would be a problem.

## 12.6 Is it really backed up

```powershell
Get-OS7BackupStatus | Format-List
```

The command asks ZFS on the source and, through the ZFS layer over SSH, on the
target — and compares the snapshots' **GUIDs**. Not their names: two snapshots
with the same name are not the same object, and a name comparison would treat a
broken replication chain as sound.

`-SkipTargets` limits the answer to the local side; that is fast and needs no
reachable target.

For monitoring:

```powershell
Get-OS7BackupStatus | ConvertTo-Json -Depth 6
```

## 12.7 Getting a file back

The most common case of all: a single file from yesterday.

```powershell
Get-OS7FileVersion /home/jsmith/quote.docx
```

The command walks the snapshots and lists every version still held, with its
time and size. `-DistinctOnly` hides consecutive identical versions, `-Newest`
limits the count, `-IncludeCurrent` brings the live file into the comparison.

Restoring:

```powershell
# yesterday's 18:00 version, back to where it came from
Restore-OS7File /home/jsmith/quote.docx -AsOf '2026-08-28 18:00'

# a specific version, somewhere else — safer, because nothing is overwritten
Restore-OS7File /home/jsmith/quote.docx `
    -Snapshot autosnap_2026-08-28_18:00:01_hourly `
    -Destination /home/jsmith/quote-old.docx
```

Without `-Destination` the existing file is replaced, and for that the command
requires `-Force`.

> A user who owns the file needs no administrator for this: snapshots are
> readable to them, and `Get-OS7FileVersion` runs without elevation.
