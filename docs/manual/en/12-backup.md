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

Which datasets are backed up. **This replaces the list, it does not add to
it** — name every dataset you want kept, including the ones that were already
there:

```powershell
Set-OS7BackupPolicy -Dataset rpool/USERDATA, rpool/DATA/srv, rpool/DATA/lib/os7-domain-homes
```

That is the default list. `rpool/USERDATA` holds local accounts' home
directories, one dataset each; `rpool/DATA/lib/os7-domain-homes` holds the home
directories of accounts that sign in from the domain. Leaving the third one out
stops the machine keeping anything at all for domain users — no snapshots, no
backup, and no previous versions of their files.

`Get-OS7BackupPolicy` shows the list in force before you change it.

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

**What was there is kept, so a restore can itself be undone.** Before anything
is overwritten the machine keeps the current state by the strongest means it
has where the file stands, and the confirmation says which before you answer:

* as **root**, a ZFS snapshot of the destination's dataset, named
  `os7-before-restore-<date>-<time>`. The result's `SafetySnapshot` names it,
  and `Restore-OS7File -Snapshot <that name> -Force` puts things back.
* as the **file's owner**, the existing file **renamed** to
  `<file>.os7-before-restore-<date>-<time>`, beside it in the same directory.
  The result's `SafetyCopy` names it. Renaming costs no disk space, and it is
  visible: you decide when it is finished with, and nothing deletes it for you.

`-NoSafetyPoint` turns both off. If the destination is not on ZFS at all — a USB
stick, a network share — the restore still happens and you are told that it
could not be made undoable.

> A user who owns the file needs no administrator for this: snapshots are
> readable to them, and `Get-OS7FileVersion` runs without elevation.

**"has NO snapshots at all" is not "the file never changed".** If the command
answers

```
rpool/DATA/tmp has NO snapshots at all, so nothing on this machine holds an
earlier version of '/var/tmp/report.txt'...
```

then that dataset is keeping no history — either it is not in the backup policy
(`Get-OS7BackupPolicy` shows which datasets are, and `Set-OS7BackupPolicy` is
how one is added, §12.2) or the machine was installed minutes ago and has not
taken its first snapshot yet. Only `rpool/USERDATA`, `rpool/DATA/srv` and
`rpool/DATA/lib/os7-domain-homes` are snapshotted by default; `/var/log`,
`/var/tmp` and removable media are not.

## 12.8 Versions, the window

On a desktop machine the same history is available from the file manager. Right
click a file in **Files** and choose **Versions**:

![The context menu in Files. The entry is offered for any local file.](images/app-versions-menu.png)

It comes from the `os7-app-versions` package and exists on amd64 installations
with a desktop only. There is no Start-menu entry, deliberately: the application
is a question about *one file* and takes a path, so a menu entry could only open
a window that says "name a file". The other way in is *Open With*, which keeps
the road open on a file manager OS/7 has not met yet.

![The versions of a file, newest at the front.](images/app-versions.png)

The heading is the file's name and the line under it says what the history
covers — *"6 versions, back to 2026-09-22"* — because the question when deciding
whether to keep looking is the range and not the count. Each card carries its
time, its size and which retention bucket keeps it: *kept as: hourly*, *daily*,
*weekly*, *monthly*, and *live* for the file as it stands now. Those are
sanoid's own buckets, read off the snapshot's name rather than worked out here.
A text file is previewed in the card; anything else says so and points at
**Open**.

Three buttons act on the selected version, and the difference between them is
the point:

| Button | What it does |
|---|---|
| **Open** | opens that version read-only. Changes nothing |
| **Copy to…** | writes that version somewhere else under a name you choose. Changes nothing |
| **Restore…** | replaces the live file with that version. Asks first |

*Restore…* names the file and the version's timestamp in the question before it
is answered, and says that what is there now is kept first:

![The restore asks, and names what it is about to replace.](images/app-versions-restore.png)

**The window decides nothing that 12.7 has not already decided.** It calls
`Get-OS7FileVersion` for what to show and `Restore-OS7File` to put a version
back; the restore is that cmdlet's, not a second implementation of it. (*Copy
to…* writes the file itself, which is why it is in a different row of the table
above: copying a version to a name you choose touches nothing the machine keeps
and needs no rule.) So the safety rule above is the one that applies here too:
run by the file's owner, the file being replaced is **renamed** to
`<file>.os7-before-restore-<date>-<time>` and stays in the same directory. It
is visible, it costs no disk space, and
nothing removes it on its own:

```powershell
# in an elevated session — the default list of datasets comes from
# /etc/os7/backup.json, which only root reads
Get-OS7RestoreAside | Format-Table Path, Length, PutAside, Held

# or name the dataset, and no elevation is needed
Get-OS7RestoreAside -Dataset rpool/USERDATA/jsmith_0f855748
```

`Held` is asked of ZFS per file rather than assumed from its age: it says
whether a snapshot still holds that content, which is the only thing that makes
deleting the file beside it safe. A file put aside minutes ago is `False` — the
next snapshot is what changes that.

**For a file whose dataset keeps nothing, the heading reads *Previous versions
could not be listed.*** Nothing has failed. The sentence in the middle of the
window is the cmdlet's own — the one quoted above, naming the dataset and what
to do — and it is the sentence that matters. `/var/log`, `/var/tmp` and anything
outside the backup policy are in that state.
