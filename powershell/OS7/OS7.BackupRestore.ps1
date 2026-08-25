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
		[switch]$IncludeCurrent
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
			if (-not $item) { continue }

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
			# Runs, not a global set: a file that changes and changes back is
			# two distinct versions of the same content and both are real. The
			# OLDEST of each run is kept because that is the snapshot in which
			# the content first appeared.
			$kept = [System.Collections.Generic.List[object]]::new()
			$prev = $null
			foreach ($v in $versions) {
				$same = $prev -and $prev.Length -eq $v.Length -and $prev.Modified -eq $v.Modified
				if (-not $same) { $kept.Add($v) }
				$prev = $v
			}
			$versions = @($kept)
		}

		if ($Newest -gt 0) {
			$versions = @($versions | Select-Object -Last $Newest)
		}
		$versions
	}
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
		[switch]$Force
	)

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
			$oldest = ($versions | Sort-Object Created | Select-Object -First 1).Created
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

		if ((Test-Path -LiteralPath $target) -and -not $Force) {
			throw [System.IO.IOException]::new(
				"'$target' exists. Use -Force to overwrite it.")
		}

		$what = "restore from $($pick.SnapshotName) ($($pick.Created)) to $target"
		if (-not $PSCmdlet.ShouldProcess($pick.Path, $what)) { return }

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
		}
	}
}
