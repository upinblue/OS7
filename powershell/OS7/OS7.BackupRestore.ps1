# =============================================================================
# OS/7 Backup — file-level restore (docs/BACKUP-PLAN.md §7, decisions B10–B12)
#
# Dot-sourced by OS7.psm1. Not a module of its own: the backup surface is OS/7
# knowledge (which datasets, which snapshots, what a rollback must not touch),
# and docs/ZFS-POWERSHELL-PLAN.md Z8 puts OS/7 knowledge in Layer 3.
#
# THE WHOLE OF THIS FILE IS ZFS DOING THE WORK. `.zfs/snapshot/<snap>/<rel>` is
# a real, read-only view of the dataset at that instant, so "browse a point in
# time" is a directory walk and "restore" is a copy. Nothing is unpacked,
# nothing is indexed, and there is no catalogue to get out of step with the
# data — which is the single biggest reason to build a backup feature on ZFS
# rather than on top of it.
#
# WHY NOT `findoid`, which ships in the same package and does roughly this:
#
#   * It DEDUPES BY (size, mtime) — `sanoid:findoid` getversions(). Two
#     genuinely different versions with the same length and the same mtime are
#     reported as one, and an operator restoring "the version from Tuesday" is
#     handed Monday's without being told.
#   * It matches the owning dataset with `$path =~ /^$mountpoint/` — an
#     UNANCHORED, UNESCAPED regex. `/home/os7x` matches the mountpoint
#     `/home/os7`, and a mountpoint containing `.` or `+` matches things it
#     should not.
#   * Its output is three tab-separated columns of localised text. Parsing a
#     date back out of `localtime()` to compare it is worse than asking ZFS.
#
# So the mechanism is kept and the tool is not. Nothing here shells out to
# findoid, and nothing here parses its output.
# =============================================================================

# The snapshot directory ZFS exposes inside every mounted filesystem. Present
# whatever `snapdir` says: `snapdir=visible` only decides whether it appears in
# a DIRECTORY LISTING; the path is always traversable by name. That is what
# makes this work without OS/7 changing a property on the user's datasets.
$script:OS7SnapshotDir = '.zfs/snapshot'

# The snapshot a restore takes before it overwrites anything, and how many of
# them one dataset keeps.
#
# BOTH NUMBERS ARE OS/7's OWN, AND THAT IS THE MEASUREMENT RATHER THAN THE
# PLAN. docs/VERSIONS-PLAN.md V8 asked for a snapshot "exempt from sanoid's
# pruning by name, for a bounded period", on the assumption that the retention
# policy would otherwise thin the safety net away. Measured on the bench
# 2026-09-14: four hand-made `demo-*` snapshots were still there after sanoid
# ran a policy pass over the same dataset — SANOID PRUNES ONLY WHAT SANOID
# TOOK. So the exemption costs nothing and is not a feature; the real risk is
# the inverse, that nothing thins these at all and a machine that restores
# often accumulates them for its lifetime. OS/7 prunes its own, here, at the
# moment it makes one — no timer, no policy, nothing else to keep in step.
$script:OS7RestoreSafetyPrefix = 'os7-before-restore-'
$script:OS7RestoreSafetyKeep = 5

function Get-OS7PathMount {
	<#
	.SYNOPSIS
		Internal. The filesystem actually mounted at a path, from the kernel.

	.DESCRIPTION
		Get-OS7PathDataset knows which ZFS dataset's MOUNTPOINT is the longest
		prefix of a path. That is not the same question as which filesystem the
		path is on, and on this product the difference is every pseudo-filesystem
		there is: `/` is a ZFS boot environment, so `/proc/cpuinfo`, `/dev/null`,
		`/run/utmp` and `/sys/...` are all "under" it by path and on procfs,
		devtmpfs, tmpfs and sysfs in fact.

		MEASURED, 2026-09-14: `Get-OS7FileVersion /proc/cpuinfo` returned zero
		versions in silence. The refusal it should have given — "is not inside a
		mounted ZFS filesystem, so it has no snapshots" — is written, correct,
		and was UNREACHABLE for exactly the paths a file manager hands over from
		outside a home directory. A guard that cannot fire is not a guard.

		THE FORMAT IS PARSED, NOT SPLIT. Between the mount point (field 5) and
		the ` - ` separator the kernel writes a VARIABLE number of optional
		fields, so counting from either end is wrong; everything before the lone
		` - ` is one part and everything after is the other. Octal escapes are
		decoded because a home directory with a space in it is ordinary and an
		undecoded one resolves to the wrong mount.

		IT NEVER THROWS. A machine with no /proc — or one where it cannot be
		read — gets $null and the caller carries on as it did before this
		existed. A diagnostic that becomes a new failure mode is worse than the
		gap it closes.

	.OUTPUTS
		An object with MountPoint and FsType, or $null.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Path,
		[string]$MountInfo = '/proc/self/mountinfo'
	)

	if (-not [System.IO.File]::Exists($MountInfo)) { return $null }

	$lines = $null
	try { $lines = [System.IO.File]::ReadAllLines($MountInfo) } catch { return $null }
	if ($null -eq $lines) { return $null }

	$wanted = $Path -replace '/+$', ''
	if ([string]::IsNullOrEmpty($wanted)) { $wanted = '/' }

	$bestPoint = $null
	$bestType = $null

	foreach ($line in $lines) {
		$sep = $line.IndexOf(' - ')
		if ($sep -lt 0) { continue }

		$left = $line.Substring(0, $sep) -split ' +'
		$right = $line.Substring($sep + 3) -split ' +'
		if ($left.Count -lt 5 -or $right.Count -lt 1) { continue }

		$point = $left[4] -replace '\\040', ' ' -replace '\\011', "`t" `
			-replace '\\012', "`n" -replace '\\134', '\'
		$type = $right[0]

		# A string prefix is not enough: /home/os7admin2 starts with
		# /home/os7admin and is a different account's home.
		$owns = if ($point -eq '/') { $wanted.StartsWith('/') }
		elseif ($wanted -eq $point) { $true }
		else { $wanted.StartsWith($point.TrimEnd('/') + '/') }

		if (-not $owns) { continue }

		if ($null -eq $bestPoint -or $point.Length -gt $bestPoint.Length) {
			$bestPoint = $point
			$bestType = $type
		}
	}

	if ($null -eq $bestPoint) { return $null }

	[pscustomobject]@{
		MountPoint = $bestPoint
		FsType     = $bestType
	}
}

function Get-OS7PathDataset {
	<#
	.SYNOPSIS
		Internal. The mounted dataset that owns a path, and the path within it.

	.DESCRIPTION
		Longest-mountpoint-wins, and matched BY PATH COMPONENT rather than by
		string prefix. The difference is not theoretical on an OS/7 machine:
		`New-OS7Storage` mounts one dataset per account under /home, so
		`/home/os7admin` and `/home/os7` are two datasets whose names are a
		string prefix of one another. A prefix match would resolve a file in the
		first to the second, look in the wrong snapshots, and report "no
		versions" for a file that has fifty.

		Only MOUNTED filesystems are candidates. An unmounted dataset has no
		path to own, and `.zfs/snapshot` is reached through the mountpoint.

	.OUTPUTS
		An object with Dataset, Mountpoint and RelativePath, or $null.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter()][object[]]$Dataset
	)

	if (-not $Dataset) {
		$Dataset = @(Get-ZfsDataset -Type Filesystem -Recurse)
	}

	# Trailing slashes off, but never the root's own slash.
	$p = $Path -replace '/+$', ''
	if ([string]::IsNullOrEmpty($p)) { $p = '/' }

	# UNMOUNTED DATASETS ARE CONSIDERED, and then reported rather than used.
	# `R=Repair` installs a new boot environment beside an old one, and
	# New-OS7Storage gives each install its own USERDATA datasets — so two
	# datasets can carry the SAME mountpoint with only one of them mounted.
	# Skipping the unmounted one silently resolves to the wrong dataset when the
	# mounted one is a shorter match, and it is the reason findoid cannot see a
	# repair install at all. Longest mountpoint wins; a tie prefers the mounted
	# one; and the caller is told when the winner is not mounted.
	$best = $null
	foreach ($d in $Dataset) {
		if (-not $d.Mountpoint) { continue }
		$mp = [string]$d.Mountpoint
		if ($mp -eq 'legacy') { continue }

		# `/` owns every ABSOLUTE path and nothing else. Without the
		# StartsWith('/') a relative path — or the string `legacy/x` that a
		# legacy mountpoint would produce — resolves to the root dataset and the
		# caller is told a confident wrong answer.
		$owns = if ($mp -eq '/') { $p.StartsWith('/') }
		elseif ($p -eq $mp) { $true }
		else { $p.StartsWith($mp + '/') }

		if (-not $owns) { continue }
		if ($null -eq $best) { $best = $d; continue }

		$bmp = [string]$best.Mountpoint
		if ($mp.Length -gt $bmp.Length) { $best = $d }
		elseif ($mp.Length -eq $bmp.Length -and $d.Mounted -and -not $best.Mounted) { $best = $d }
	}
	if (-not $best) { return $null }

	$mp = [string]$best.Mountpoint

	# AND IS ANYTHING ELSE MOUNTED IN BETWEEN? Everything above compares the
	# path against ZFS MOUNTPOINTS, which cannot see that /proc, /dev, /run,
	# /sys and /tmp interrupt the root dataset's ownership. Measured: this
	# returned the running boot environment for /proc/cpuinfo, and the caller's
	# correct refusal was therefore unreachable for every path outside a ZFS
	# filesystem on a machine whose / IS one.
	#
	# A LONGER mount than the dataset's means something is mounted underneath
	# it. If that something is zfs it is a child dataset, which the loop above
	# has already considered as a longer candidate; anything else owns the path
	# and this dataset does not.
	$actual = Get-OS7PathMount -Path $p
	if ($null -ne $actual -and
		$actual.MountPoint.TrimEnd('/').Length -gt $mp.TrimEnd('/').Length -and
		$actual.FsType -ne 'zfs') {
		return $null
	}

	# SPLICED BY LENGTH, not by a regex over the mountpoint. `/` is the case
	# that catches a regex out — findoid's `s/^$dataset\///` never fires for a
	# dataset mounted at `/`, which is exactly where OS/7 mounts its boot
	# environment, and the path it then builds has a doubled slash in it and
	# cannot be stat-ed.
	$rel = if ($p -eq $mp) { '' } else { $p.Substring($mp.TrimEnd('/').Length).TrimStart('/') }

	[pscustomobject]@{
		Dataset      = [string]$best.Name
		Mountpoint   = $mp
		RelativePath = $rel
		Mounted      = [bool]$best.Mounted
	}
}

function Select-OS7DistinctVersion {
	<#
	.SYNOPSIS
		Internal. Collapse runs of identical versions, keeping the one nearest
		the change.

	.DESCRIPTION
		Runs, not a global set: a file that changes and changes back is two
		distinct versions of the same content and both are real.

		WHICH MEMBER OF A RUN IS KEPT DEPENDS ON WHAT THE RUN MEANS, and both
		answers are "the snapshot nearest the change".

		  PRESENT run  -> the OLDEST, the snapshot in which this content first
		                  appeared. "It has looked like this since."
		  ABSENT run   -> the NEWEST, the last moment the path is known not to
		                  have been there. "It appeared after."

		Keeping the oldest of an absent run instead would be true and nearly
		useless: on a machine with three months of snapshots it reports "did not
		exist" at the very beginning of history, and the bracket around when the
		file appeared is three months wide instead of an hour. Measured on a
		machine: 30 absent snapshots collapsed to one, and the one names 20:00
		on the day the file was created at 20:39.

	.PARAMETER Version
		The versions, OLDEST FIRST, as Get-OS7FileVersion builds them.
	#>
	[CmdletBinding()]
	param([Parameter()][object[]]$Version)

	if (-not $Version -or $Version.Count -eq 0) { return @() }

	$runs = [System.Collections.Generic.List[object]]::new()
	$current = [System.Collections.Generic.List[object]]::new()
	$prev = $null

	foreach ($v in $Version) {
		$same = $prev -and $prev.Exists -eq $v.Exists -and
			$prev.Length -eq $v.Length -and $prev.Modified -eq $v.Modified
		if (-not $same -and $current.Count -gt 0) {
			$runs.Add(@($current))
			$current = [System.Collections.Generic.List[object]]::new()
		}
		$current.Add($v)
		$prev = $v
	}
	if ($current.Count -gt 0) { $runs.Add(@($current)) }

	$kept = [System.Collections.Generic.List[object]]::new()
	foreach ($run in $runs) {
		# The input is oldest-first, so [0] is the oldest of the run and [-1]
		# the newest.
		if ($run[0].Exists -eq $false) { $kept.Add($run[-1]) }
		else { $kept.Add($run[0]) }
	}

	,@($kept)
}

function Get-OS7FileVersion {
	<#
	.SYNOPSIS
		Every version of a file or folder that a snapshot still holds.

	.DESCRIPTION
		The browse half of the restore story. Each version is the same path seen
		through one snapshot, so the answer is exact rather than reconstructed:
		if a version is listed, the bytes are on this machine right now and
		`Restore-OS7File` will copy them.

		THE OWNING DATASET IS RESOLVED FIRST, and this is the part that decides
		whether the answer is right at all. A path under /home belongs to that
		account's own dataset; /var/log belongs to rpool/DATA/log; / belongs to
		the running boot environment. Snapshots of a PARENT do not contain a
		child dataset's files — a child is a separate filesystem and its
		mountpoint inside the parent's snapshot is an empty directory — so
		looking in the wrong dataset does not error, it silently finds nothing.

		SNAPSHOTS COME FROM ZFS, not from a listing of `.zfs/snapshot`. That is
		what gives every version a real [datetime] creation time to sort and
		filter by, and it is one fewer thing to be wrong about ordering.

		Versions are reported for every snapshot that HAS the path, including
		identical ones — `-DistinctOnly` collapses those. The default is the
		honest one: two snapshots holding identical bytes is a fact about the
		snapshots, and hiding it is what makes findoid's answer smaller than the
		truth.

	.PARAMETER Path
		The file or folder, as it is on the live filesystem — the same path you
		would type to open it. It does not have to still exist.

	.PARAMETER Newest
		Only the N most recent versions.

	.PARAMETER DistinctOnly
		Collapse runs of versions with identical length and modification time,
		keeping the OLDEST of each run — the snapshot in which that version
		first appeared, which is the one an operator means by "when did it
		change".

	.PARAMETER IncludeCurrent
		Also report what is on the live filesystem now, as a version with
		SnapshotName $null.

	.EXAMPLE
		Get-OS7FileVersion /home/os7/notes.txt

	.EXAMPLE
		Get-OS7FileVersion /home/os7/Documents -DistinctOnly |
			Sort-Object Created -Descending | Select-Object -First 5
	#>
	[CmdletBinding()]
	[OutputType('OS7.Backup.FileVersion')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[Alias('FullName')]
		[string]$Path,

		[Parameter()][int]$Newest = 0,
		[switch]$DistinctOnly,
		[switch]$IncludeCurrent,
		[switch]$IncludeAbsent
	)

	process {
		Import-OS7ZfsLayer

		# Resolved against the filesystem where possible, so that a symlink or a
		# relative path is answered about the file it actually names. A path
		# that no longer exists cannot be resolved and is used as given — which
		# is the interesting case, because a deleted file is what a restore is
		# usually for.
		$full = $Path
		try {
			$resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
			if ($resolved) { $full = $resolved }
		}
		catch {
			if (-not [System.IO.Path]::IsPathRooted($full)) {
				$full = Join-Path (Get-Location).ProviderPath $full
			}
		}
		$full = $full -replace '\\', '/'

		$owner = Get-OS7PathDataset -Path $full
		if (-not $owner) {
			throw [System.InvalidOperationException]::new(
				"'$full' is not inside a mounted ZFS filesystem, so it has no snapshots. " +
				'Only ZFS datasets have versions; the EFI system partition and anything ' +
				'on removable media do not.')
		}
		if (-not $owner.RelativePath) {
			throw [ArgumentException]::new(
				"'$full' IS the mountpoint of $($owner.Dataset). Name a file or a folder " +
				'inside it — a whole dataset is rolled back with Restore-ZfsSnapshot, not ' +
				'restored file by file.')
		}
		if (-not $owner.Mounted) {
			throw [System.InvalidOperationException]::new(
				"$($owner.Dataset) claims '$($owner.Mountpoint)' and is NOT MOUNTED, so its " +
				'snapshots cannot be reached — .zfs/snapshot is served through the ' +
				'mountpoint. This is what a repair install looks like: two datasets with ' +
				"one mountpoint. Mount-ZfsDataset $($owner.Dataset) first, or name a path " +
				'under the dataset that is mounted.')
		}

		$snaps = @(Get-ZfsSnapshot -Name $owner.Dataset -NoRecurse | Sort-Object Creation)

		$out = [System.Collections.Generic.List[object]]::new()
		$denied = 0
		foreach ($s in $snaps) {
			$snapPath = ($owner.Mountpoint.TrimEnd('/') + '/' + $script:OS7SnapshotDir +
				'/' + $s.SnapshotName + '/' + $owner.RelativePath)

			$item = $null
			try { $item = Get-Item -LiteralPath $snapPath -Force -ErrorAction Stop }
			catch [System.UnauthorizedAccessException] { $denied++ }
			catch { }
			if (-not $item) {
				# THE BOUNDARY. Without -IncludeAbsent these snapshots are
				# skipped, which is right for "give me the file back" and wrong
				# for "when did it appear" — the question a Time-Machine window
				# is opened to answer. A row saying the path was NOT there is
				# what turns a list of versions into a history.
				if ($IncludeAbsent) {
					$out.Add([pscustomobject]@{
							PSTypeName   = 'OS7.Backup.FileVersion'
							Path         = $full
							SnapshotName = $s.SnapshotName
							Snapshot     = $s.Name
							Created      = $s.Creation
							Modified     = $null
							Length       = $null
							IsFolder     = $false
							IsCurrent    = $false
							Exists       = $false
							Dataset      = $owner.Dataset
							SnapshotPath = $snapPath
						})
				}
				continue
			}

			$isDir = $item.PSIsContainer
			$out.Add([pscustomobject]@{
					PSTypeName   = 'OS7.Backup.FileVersion'
					Path         = $full
					SnapshotName = $s.SnapshotName
					Snapshot     = $s.Name
					Created      = $s.Creation
					Modified     = $item.LastWriteTime
					Length       = if ($isDir) { $null } else { [uint64]$item.Length }
					IsFolder     = $isDir
					IsCurrent    = $false
					Exists       = $true
					Dataset      = $owner.Dataset
					SnapshotPath = $snapPath
				})
		}

		if ($IncludeCurrent) {
			$live = $null
			try { $live = Get-Item -LiteralPath $full -Force -ErrorAction Stop } catch { }
			if ($live) {
				$out.Add([pscustomobject]@{
						PSTypeName   = 'OS7.Backup.FileVersion'
						Path         = $full
						SnapshotName = $null
						Snapshot     = $null
						Created      = $live.LastWriteTime
						Modified     = $live.LastWriteTime
						Length       = if ($live.PSIsContainer) { $null } else { [uint64]$live.Length }
						IsFolder     = $live.PSIsContainer
						IsCurrent    = $true
						Exists       = $true
						Dataset      = $owner.Dataset
						SnapshotPath = $full
					})
			}
		}

		# THREE DIFFERENT NOTHINGS, and they need three different sentences. A
		# cmdlet that returns an empty set for all of them sends the operator to
		# look for a file that is right there behind a permission or a property.
		if ($out.Count -eq 0 -and $snaps.Count -gt 0) {
			if ($denied -gt 0) {
				throw [System.UnauthorizedAccessException]::new(
					"$denied of $($snaps.Count) snapshots refused to be read. The versions " +
					'may exist; this account cannot see them. Snapshots keep the ' +
					'permissions the files had when they were taken.')
			}
			$probe = ($owner.Mountpoint.TrimEnd('/') + '/' + $script:OS7SnapshotDir)
			if (-not (Test-Path -LiteralPath $probe)) {
				throw [System.InvalidOperationException]::new(
					"$($owner.Dataset) has $($snaps.Count) snapshot(s) and $probe cannot be " +
					'reached. ZFS serves that directory through the mountpoint; if it is ' +
					'absent, this kernel or this dataset is not exposing it. ' +
					"`Set-ZfsProperty $($owner.Dataset) snapdir visible` is the property " +
					'that governs whether it is listed — OS/7 sets it nowhere, so it is at ' +
					"ZFS's default.")
			}
		}

		$versions = @($out | Sort-Object Created)

		if ($DistinctOnly) {
			$versions = @(Select-OS7DistinctVersion -Version $versions)
		}

		if ($Newest -gt 0) {
			$versions = @($versions | Select-Object -Last $Newest)
		}
		$versions
	}
}

function New-OS7RestoreSafetySnapshot {
	<#
	.SYNOPSIS
		Internal. Snapshot what a restore is about to write over.

	.DESCRIPTION
		docs/VERSIONS-PLAN.md V8. A restore that overwrites the live file
		destroys whatever was there, and a feature whose entire purpose is "you
		can go back" must not contain a one-way door: restoring yesterday's
		version over today's work loses the work, and the next snapshot is up to
		an hour away. This is the way back from the way back.

		IT SNAPSHOTS THE DESTINATION'S DATASET, NOT THE SOURCE'S, and those are
		not the same question. The version being restored came out of some
		dataset's snapshot; what is at RISK is whatever the copy lands on, and
		`-Destination` can name a path on an entirely different dataset — or on
		no ZFS filesystem at all.

		IT IS TAKEN ONLY WHEN SOMETHING EXISTS TO LOSE. A restore to a path
		that is not there destroys nothing, and a snapshot of the dataset for
		that costs a name, a prune and an entry in every later listing.

		WHAT IT COSTS: 55 ms (docs/VERSIONS-PLAN.md M-V7) and no space at the
		moment it is taken — a snapshot shares every block with the live
		filesystem and only begins to hold space as the two diverge. So this is
		affordable even when the pool is under pressure, which is deliberate:
		Get-OS7StoragePressure's Refuse level is about a machine that is running
		out of room, and a restore performed with no way back is not the thing
		to do about that.

		AND IT PRUNES ITS OWN. Nothing else will: `Invoke-OS7StorageRelief`
		deletes no snapshot itself — it writes the retention policy and lets
		sanoid prune under it — and sanoid prunes only the snapshots it took.
		The newest $script:OS7RestoreSafetyKeep per dataset are kept and the
		rest are destroyed here, so the count is bounded by the mechanism that
		creates them rather than by a timer that could stop running.

	.PARAMETER Path
		The path about to be written. Its dataset is what gets snapshotted.

	.PARAMETER Taken
		What this invocation has already snapshotted: dataset name → snapshot
		name. ONE SAFETY SNAPSHOT PER DATASET PER INVOCATION, and both halves of
		that are needed.

		Restoring twenty files in one pipeline would otherwise take twenty
		snapshots of one dataset — nineteen of them redundant, because the FIRST
		one already holds the state before any of the writes, which is precisely
		what "the way back from this restore" means. They would also flood the
		version list the feature exists to make readable.

		AND IT IS WHAT MAKES THE NAME SAFE. The stamp has one-second resolution,
		so two files restored in the same second asked ZFS for a snapshot that
		already existed; `zfs snapshot` fails on that, and the second file's
		restore would have died of the mechanism protecting it. Found by
		check-storage-logic.py §7 case G, which reached the same second by
		accident and reported the wrong failure until this existed.

	.PARAMETER Keep
		How many of these one dataset keeps. Negative disables pruning.

	.OUTPUTS
		An object with `Snapshot` and `Copy`, exactly one of which is set.
		`Snapshot` is a ZFS snapshot of the destination's dataset; `Copy` is the
		destination itself, renamed out of the way. See V19 above for why there
		are two.
	#>
	[CmdletBinding()]
	[OutputType('OS7.Backup.SafetyPoint')]
	param(
		[Parameter(Mandatory)][string]$Path,
		[System.Collections.IDictionary]$Taken,
		[int]$Keep = $script:OS7RestoreSafetyKeep
	)

	$owner = Get-OS7PathDataset -Path $Path

	# ZFS FIRST WHEREVER IT IS AVAILABLE, and the fallback is not a consolation
	# prize — it is what Time Machine and Windows' Previous Versions both do.
	# But a snapshot is better wherever it can be had: it is atomic, it covers a
	# whole folder, it costs nothing, it is invisible, and OS/7 prunes it.
	if ($owner -and -not ($Taken -and $Taken[$owner.Dataset] -eq $false)) {
		if ($Taken -and $Taken.Contains($owner.Dataset)) {
			return New-OS7SafetyPoint -Snapshot ([string]$Taken[$owner.Dataset])
		}

		$point = New-OS7RestoreSafetySnapshotInternal -Owner $owner -Keep $Keep
		if ($point) {
			if ($Taken) { $Taken[$owner.Dataset] = $point.Snapshot }
			return $point
		}

		# It could not be had. Remember that, so a hundred files in one pipeline
		# do not ask ZFS a hundred times and warn a hundred times.
		if ($Taken) { $Taken[$owner.Dataset] = $false }
	}

	Move-OS7RestoreTargetAside -Path $Path
}

function New-OS7SafetyPoint {
	<#
	.SYNOPSIS
		Internal. The one shape both halves of V19 answer in.
	#>
	param([string]$Snapshot, [string]$Copy)

	[pscustomobject]@{
		PSTypeName = 'OS7.Backup.SafetyPoint'
		Snapshot   = if ($Snapshot) { $Snapshot } else { $null }
		Copy       = if ($Copy) { $Copy } else { $null }
	}
}

function New-OS7RestoreSafetySnapshotInternal {
	<#
	.SYNOPSIS
		Internal. The ZFS half: snapshot the dataset, verify it, prune ours.

	.DESCRIPTION
		Returns a safety point, or **$null** when ZFS would not make one — which
		on this product means, nearly always, that the caller is the OWNER of the
		file rather than root (M-V22). That is not an error and the caller has a
		second road; anything else wrong with the pool will surface there instead,
		in the warning this writes.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][object]$Owner,
		[int]$Keep = $script:OS7RestoreSafetyKeep
	)

	$existing = @(Get-ZfsSnapshot -Name $Owner.Dataset -NoRecurse)

	# The name a person can read, and then whatever it takes to make it unique.
	# A second invocation in the same second is a script's `foreach`, which the
	# per-invocation memo above cannot see.
	$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
	$snapshotName = "$script:OS7RestoreSafetyPrefix$stamp"
	$suffix = 1
	while ($existing | Where-Object { $_.SnapshotName -eq $snapshotName }) {
		$suffix++
		$snapshotName = "$script:OS7RestoreSafetyPrefix$stamp-$suffix"
	}
	$full = "$($Owner.Dataset)@$snapshotName"

	# -Confirm:$false ON PURPOSE. The operator has already confirmed the
	# restore, and this snapshot is part of that restore rather than a second
	# decision to make — being asked twice teaches people to answer without
	# reading. `Restore-OS7File -WhatIf` never reaches here at all, because its
	# own ShouldProcess returns first.
	try {
		New-ZfsSnapshot -Name $Owner.Dataset -SnapshotName $snapshotName -Confirm:$false |
			Out-Null
	}
	catch {
		# NOT AN ERROR, AND A MACHINE IS WHAT TAUGHT THAT (M-V22). The common
		# case here is not a broken pool: it is the OWNER of the file, restoring
		# their own work, as themselves. Reading a version needs no privilege at
		# all (M-V5) and `zfs snapshot` needs root, so this is the one part of
		# the feature an ordinary user cannot reach — and refusing them their own
		# file over it would be the wrong answer to a question Time Machine
		# answers by moving the file aside. The caller does that next.
		Write-Verbose "no ZFS safety snapshot on $($Owner.Dataset): $($_.Exception.Message)"
		return $null
	}

	# THE SNAPSHOT IS ASKED FOR RATHER THAN ASSUMED (docs/BUILD-NOTES.md's
	# recurring rule). `zfs snapshot` exiting 0 is a diagnostic; this is the
	# thing itself. If it is not there, the caller must not go on to overwrite
	# a file believing it is protected — and unlike the permission case this IS
	# a fault, because ZFS reported success. It gets its own sentence rather
	# than a quiet fall back to the weaker road.
	$made = @(Get-ZfsSnapshot -Name $Owner.Dataset -NoRecurse |
		Where-Object { $_.SnapshotName -eq $snapshotName })
	if ($made.Count -eq 0) {
		throw [System.InvalidOperationException]::new(
			"the safety snapshot '$full' was requested, ZFS reported success, and " +
			'it does not exist. Nothing has been written. Use -NoSafetyPoint to ' +
			'restore anyway, knowing there will be no way back from it.')
	}

	# Prune ours, and only ours. Matched on the prefix rather than on a
	# property, because a property would have to be read back from a snapshot
	# somebody may have renamed, and the name is what this owns.
	if ($Keep -ge 0) {
		$ours = @(Get-ZfsSnapshot -Name $Owner.Dataset -NoRecurse |
			Where-Object { $_.SnapshotName -and
				$_.SnapshotName.StartsWith($script:OS7RestoreSafetyPrefix, 'Ordinal') } |
			Sort-Object Creation)

		# SkipLast, not Select -First: the newest $Keep stay, whatever their
		# count, and a machine that has never restored has none to skip.
		foreach ($old in ($ours | Select-Object -SkipLast $Keep)) {
			try {
				Remove-ZfsSnapshot -Name $old.Name -Confirm:$false
			}
			catch {
				# A prune that failed has cost disk space. A restore that failed
				# because of it would have cost the operator their file, and the
				# snapshot this call just took is already in place.
				Write-Warning "could not remove the old safety snapshot '$($old.Name)': $_"
			}
		}
	}

	New-OS7SafetyPoint -Snapshot $full
}

function Move-OS7RestoreTargetAside {
	<#
	.SYNOPSIS
		Internal. The way back that needs no privilege: rename, do not destroy.

	.DESCRIPTION
		docs/VERSIONS-PLAN.md V19, decided by the owner 2026-09-15, and it is
		**the mechanism Time Machine itself uses**. Time Machine takes no
		snapshot before a restore at all: when something is already at the
		destination it offers *Keep Original / Keep Both / Replace*, and "Keep
		Both" puts the existing file aside under another name. Windows' Previous
		Versions is the same shape — VSS snapshots are an administrator's, and
		the tab offers *Copy* beside *Restore*.

		IT NEEDS ONLY WHAT THE CALLER ALREADY HAS. A rename needs write on the
		containing directory, which the owner of a file in their own home has;
		`zfs snapshot` needs root, which they do not (M-V22). So this is the road
		for the everyday case of the feature, and the ZFS snapshot is the road
		for everything privileged — same promise, two strengths.

		AND IT COSTS NO SPACE. A rename is the same inode: nothing is copied, no
		second copy of the bytes exists, and §5's storage rule is untouched. That
		is the whole reason it is a rename rather than a copy.

		NOTHING PRUNES THESE. They are visible, they are in the operator's own
		directory, and they belong to whoever owns that directory — an invisible
		cleaner deleting files out of somebody's home is the opposite of what
		this product does elsewhere. Time Machine does not clean up its "Keep
		Both" copies either. VL9 is that cost written down.
	#>
	[CmdletBinding()]
	[OutputType('OS7.Backup.SafetyPoint')]
	param([Parameter(Mandatory)][string]$Path)

	$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
	$aside = "$Path.$script:OS7RestoreSafetyPrefix$stamp"

	# #159's lesson in a second place: a name made from the clock is unique only
	# if the thing is made more slowly than the clock ticks, and a `process{}`
	# block runs once per pipeline item.
	$suffix = 1
	while (Test-Path -LiteralPath $aside) {
		$suffix++
		$aside = "$Path.$script:OS7RestoreSafetyPrefix$stamp-$suffix"
	}

	try {
		Move-Item -LiteralPath $Path -Destination $aside -ErrorAction Stop
	}
	catch {
		# BOTH ROADS ARE NOW SHUT, so this is the refusal — and the first clause
		# is the one a person needs: the file they came here about is still
		# there. #148's form, because the likeliest cause after this is a
		# directory the caller may read and not write.
		throw [System.InvalidOperationException]::new(
			"'$Path' could not be put aside before being written over, so it has " +
			"NOT been written and nothing is lost.`n" +
			"`n" +
			"  A ZFS snapshot of it was not possible either. Either restore with`n" +
			"  privilege:`n" +
			"`n" +
			"      sudo pwsh -NoProfile -c 'Restore-OS7File <parameters> -Force'`n" +
			"`n" +
			"  or give the way back up deliberately, with -NoSafetyPoint.`n" +
			"`n" +
			"  The move failed with: $($_.Exception.Message)",
			$_.Exception)
	}

	# ASKED FOR RATHER THAN ASSUMED, the same rule the snapshot half obeys.
	if (-not (Test-Path -LiteralPath $aside)) {
		throw [System.IO.IOException]::new(
			"'$Path' was moved to '$aside', the move reported success, and " +
			'nothing is there. Nothing further has been written.')
	}

	Write-OS7Step "put $Path aside as $(Split-Path -Leaf $aside)"
	New-OS7SafetyPoint -Copy $aside
}

function Restore-OS7File {
	<#
	.SYNOPSIS
		Copy a file or folder back out of a snapshot.

	.DESCRIPTION
		The restore half. It copies OUT of `.zfs/snapshot`, which is read-only,
		so the source cannot be damaged by anything this does.

		IT WILL NOT WRITE OVER THE LIVE PATH UNLESS TOLD TO. `-Destination`
		is how it is normally used, and restoring in place needs `-Force` and
		says so in the confirmation prompt. That asymmetry is deliberate: the
		reason somebody is here is that a file was lost, and a restore that
		overwrites the wrong version of it by default has lost a second one.

		ACLs AND EXTENDED ATTRIBUTES ARE PRESERVED, and it takes saying so.
		`New-OS7Storage` creates both pools with `acltype=posixacl` and
		`xattr=sa`, so a plain `cp` copies the bytes and drops the permissions
		that made the file private. rsync with `-aAX` carries both, and rsync is
		already in the image because Setup installs with it.

		THE COPY IS VERIFIED (docs/BUILD-NOTES.md's recurring rule). rsync
		exiting 0 is a diagnostic, not evidence, so the restored path is stat-ed
		afterwards and its length and modification time are compared with the
		snapshot's. A restore that silently produced nothing — which is exactly
		what happens when a path resolves into a CHILD dataset's empty
		mountpoint inside a parent's snapshot — is reported as a failure here
		rather than discovered by the person who needed the file.

	.PARAMETER Path
		The file or folder to restore, named as it is on the live filesystem.

	.PARAMETER Snapshot
		Which snapshot to take it from. Without it, -AsOf or the newest version.

	.PARAMETER AsOf
		Take the newest version that is not newer than this time.

	.PARAMETER Destination
		Where to put it. A folder means "into this folder, under its own name";
		anything else is the exact target path.

	.PARAMETER Force
		Overwrite. Required to restore over the live path.

	.PARAMETER NoSafetyPoint
		Do not make the restore undoable: write over the destination directly.

		Normally what is about to be overwritten is kept first — as a ZFS
		snapshot of the destination's dataset where that is possible, and
		otherwise by renaming the destination out of the way (V8, V19). This
		switch is the named way to give that up, for a destination whose dataset
		must not gain snapshots, or an operator who wants the file and nothing
		beside it. It changes nothing when there was nothing at the destination
		to lose.

	.EXAMPLE
		Restore-OS7File /home/os7/notes.txt -Destination /home/os7/notes.restored.txt

	.EXAMPLE
		Restore-OS7File /home/os7/Documents -AsOf (Get-Date).AddDays(-1) `
			-Destination /home/os7/Documents-yesterday
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	[OutputType('OS7.Backup.Restore')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[Alias('FullName')]
		[string]$Path,

		[Parameter()][string]$Snapshot,
		[Parameter()][datetime]$AsOf,
		[Parameter()][string]$Destination,
		[switch]$Force,
		[switch]$NoSafetyPoint
	)

	begin {
		# What this invocation has already snapshotted, so that restoring a
		# hundred files through the pipeline takes one snapshot per dataset and
		# not a hundred. See New-OS7RestoreSafetySnapshot -Taken.
		$safetyTaken = @{}
	}

	process {
		$versions = @(Get-OS7FileVersion -Path $Path)
		if (-not $versions) {
			throw [System.InvalidOperationException]::new(
				"no snapshot holds '$Path'. Either it was never there when a snapshot " +
				'was taken, or its dataset is not one this machine snapshots — ' +
				'Get-OS7BackupPolicy says which are.')
		}

		$pick = if ($Snapshot) {
			$versions | Where-Object { $_.SnapshotName -eq $Snapshot } | Select-Object -First 1
		}
		elseif ($PSBoundParameters.ContainsKey('AsOf')) {
			$versions | Where-Object { $_.Created -le $AsOf } |
				Sort-Object Created | Select-Object -Last 1
		}
		else {
			$versions | Sort-Object Created | Select-Object -Last 1
		}

		if (-not $pick) {
			# BUILD-NOTES #119, and here the empty case is the LIKELY one: this
			# branch is reached because nothing matched, and "nothing matched"
			# very often means $versions is empty. Reading `.Created` off the
			# $null that `@() | Select-Object -First 1` produces replaced a
			# clear "no version of X at or before Y" with a StrictMode property
			# error about the error path itself.
			$oldestVersion = $versions | Sort-Object Created | Select-Object -First 1
			$oldest = if ($oldestVersion) { $oldestVersion.Created } else { $null }
			throw [System.InvalidOperationException]::new(
				$(if ($Snapshot) { "no version of '$Path' in snapshot '$Snapshot'." }
					else { "no version of '$Path' at or before $AsOf; the oldest is $oldest." }))
		}

		# The destination, decided before anything is asked or copied.
		$target = $Destination
		if (-not $target) {
			if (-not $Force) {
				throw [ArgumentException]::new(
					"give -Destination, or -Force to restore over '$($pick.Path)' itself. " +
					'Restoring in place is not the default because the reason for a ' +
					'restore is usually that the live copy is the wrong one.')
			}
			$target = $pick.Path
		}
		elseif ((Test-Path -LiteralPath $target -PathType Container) -and
			-not $pick.IsFolder) {
			$target = Join-Path $target (Split-Path -Leaf $pick.Path)
		}
		$target = $target -replace '\\', '/'

		$targetExists = Test-Path -LiteralPath $target
		if ($targetExists -and -not $Force) {
			throw [System.IO.IOException]::new(
				"'$target' exists. Use -Force to overwrite it.")
		}

		# V8, AND THE WHOLE OF THE DECISION IS THIS LINE. A restore is only
		# destructive where it lands on something: a -Destination that is not
		# there yet takes nothing away, and a safety snapshot for it would cost
		# a name, a prune and a row in every later version listing for nothing.
		$takeSafety = $targetExists -and -not $NoSafetyPoint

		$what = "restore from $($pick.SnapshotName) ($($pick.Created)) to $target"
		if ($takeSafety) {
			# SAID BEFORE IT HAPPENS, not reported after. The operator is being
			# asked to approve overwriting a file, and whether that is reversible
			# is the most important thing about the answer.
			$what += " (keeping $target first, so this can be undone)"
		}
		if (-not $PSCmdlet.ShouldProcess($pick.Path, $what)) { return }

		$safety = if ($takeSafety) {
			New-OS7RestoreSafetySnapshot -Path $target -Taken $safetyTaken
		}
		else { $null }

		$parent = Split-Path -Parent $target
		if ($parent -and -not (Test-Path -LiteralPath $parent)) {
			New-Item -ItemType Directory -Force -Path $parent | Out-Null
		}

		# -a  archive: recurse, keep times, ownership, symlinks
		# -A  POSIX ACLs      ) both because New-OS7Storage sets acltype=posixacl
		# -X  extended attrs  ) and xattr=sa on every pool it creates
		# --numeric-ids  never remap a uid through a name lookup that may resolve
		#                differently now than when the snapshot was taken —
		#                Entra-backed accounts get their uid from authd
		# The trailing slash on a FOLDER source means "the contents of", which
		# with a named destination is what "restore this folder as that one"
		# means. On a file it would be wrong, so it is added only for folders.
		$src = if ($pick.IsFolder) { $pick.SnapshotPath.TrimEnd('/') + '/' } else { $pick.SnapshotPath }
		$dst = if ($pick.IsFolder) { $target.TrimEnd('/') + '/' } else { $target }

		Write-OS7Step "restore $($pick.Path) from $($pick.SnapshotName)"
		Invoke-OS7Native -Command 'rsync' -Arguments @(
			'-a', '-A', '-X', '--numeric-ids', '--', $src, $dst) | Out-Null

		# THE VERIFICATION. rsync's exit code says rsync finished; it does not
		# say this path now holds those bytes.
		$now = $null
		try { $now = Get-Item -LiteralPath $target -Force -ErrorAction Stop } catch { }
		if (-not $now) {
			throw [System.IO.IOException]::new(
				"rsync reported success and '$target' does not exist. " +
				'If the path was inside a CHILD dataset, the parent snapshot holds ' +
				"only an empty mountpoint for it — restore from the child's own snapshots.")
		}
		if (-not $pick.IsFolder -and [uint64]$now.Length -ne [uint64]$pick.Length) {
			throw [System.IO.IOException]::new(
				"restored '$target' is $($now.Length) bytes; the snapshot holds " +
				"$($pick.Length). The copy did not complete.")
		}

		[pscustomobject]@{
			PSTypeName   = 'OS7.Backup.Restore'
			Path         = $pick.Path
			RestoredTo   = $target
			SnapshotName = $pick.SnapshotName
			Snapshot     = $pick.Snapshot
			Created      = $pick.Created
			Length       = if ($pick.IsFolder) { $null } else { [uint64]$now.Length }
			IsFolder     = $pick.IsFolder
			# THE WAY BACK FROM THIS RESTORE, in whichever of the two forms
			# was available here (V19). Exactly one is ever set, and both are
			# null when nothing was overwritten or the operator gave it up.
			#   SafetySnapshot  Restore-OS7File <path> -Snapshot os7-before-… -Force
			#   SafetyCopy      the old file, sitting beside the new one
			SafetySnapshot = if ($safety) { $safety.Snapshot } else { $null }
			SafetyCopy     = if ($safety) { $safety.Copy } else { $null }
		}
	}
}
