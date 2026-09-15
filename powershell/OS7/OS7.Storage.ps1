# =============================================================================
# OS/7 — storage pressure: what happens when the pool starts filling up.
#
# docs/VERSIONS-PLAN.md §5 and BACKUP-PLAN.md BL5. The Versions feature makes a
# machine's free space depend on its history and makes users VALUE that history,
# which turns deleting it from a cron job into a support conversation. This is
# the answer to "and then what".
#
# THREE LEVELS, AND THE DESTRUCTIVE ONE HAS TO PROVE IT WOULD HELP.
#
#   70 %  say so, delete nothing
#   80 %  tighten the RETENTION POLICY and let sanoid prune under it
#   90 %  tighten to the floor, refuse new version snapshots, say so loudly
#
# ONE THINNER, NOT TWO. sanoid takes the snapshots and prunes them under B5's
# policy. This never deletes a snapshot behind sanoid's back: it changes the
# policy sanoid prunes BY, writes it, and lets sanoid do the deleting. Two
# autonomous thinners on one pool is this repository's most-paid-for shape —
# both report success and the pool fills anyway — and a pressure rule deleting
# "oldest first" would delete exactly the monthlies sanoid is trying to keep,
# leaving an effective retention nobody configured.
#
# WOULD IT EVEN HELP? A snapshot holds only the blocks it ALONE still needs. A
# pool that is 80 % full of LIVE data does not get better by deleting history:
# measured on a bench, `usedbysnapshots` was 1.54 MiB against a 4.21 MiB
# dataset. So the relief is gated on whether it can actually reach the target,
# and when it cannot the honest answer is "the live data is what is full" —
# reported, with nothing deleted. Destructive AND ineffective is the worst
# outcome available, and it is the one an ungated rule produces.
#
# THE BOOT ENVIRONMENT BEFORE THE LAST UPDATE IS NEVER PRUNED. Owner's
# decision, 2026-09-14, and it closes the half of BL5 that was open: more
# environments may exist and those are subject to these rules, but the one an
# operator would roll back to is not a candidate at any pressure. A machine that
# freed space by deleting its own way back is a machine that cannot recover from
# the update it made room for.
# =============================================================================

# ---------------------------------------------------------------------------
# The numbers, in one place
# ---------------------------------------------------------------------------

# Pool capacity, whole percent, as `zpool list` reports it.
#
# 70 IS A WARNING AND NOT A DELETION LEVEL. The ~80 % figure quoted everywhere
# for ZFS is about performance degradation, not failure; deleting a user's file
# history while 30 % of the disk is free would astonish anybody. What 70 buys is
# TIME: a machine that grows slowly has weeks of notice.
$script:OS7StorageThresholds = [ordered]@{
	Warn    = 70
	Tighten = 80
	Refuse  = 90
}

# What 80 % tightens TO. An absolute target rather than a step, so running it
# twice changes nothing — a ratchet that tightened a little on every timer tick
# would reach zero without anybody deciding to.
$script:OS7StorageTightRetention = [ordered]@{
	frequently = 0
	hourly     = 24
	daily      = 7
	weekly     = 2
	monthly    = 1
	yearly     = 0
}

# The floor. Nothing here goes below it at any pressure, because a feature that
# silently becomes useless under load is worse than one that says it is under
# load. A day by the hour and a week by the day is still a usable history.
$script:OS7StorageRetentionFloor = [ordered]@{
	frequently = 0
	hourly     = 24
	daily      = 7
	weekly     = 0
	monthly    = 0
	yearly     = 0
}

# The running environment, and the one before the last update. Never fewer.
$script:OS7BootEnvironmentFloor = 2

# How old a file put aside by a restore (V19) must be before storage relief may
# remove it, and it may ONLY ever remove one a snapshot still holds. The owner
# chose 30 days on 2026-09-15; the `Held` test is what makes the reasoning
# behind that number true rather than assumed. See Get-OS7RestoreAside.
$script:OS7RestoreAsideMaxAgeDays = 30

function Get-OS7StorageThreshold {
	<#
	.SYNOPSIS
		The pool-capacity levels at which OS/7 warns, tightens and refuses.

	.EXAMPLE
		Get-OS7StorageThreshold
	#>
	[CmdletBinding()]
	[OutputType('OS7.Storage.Threshold')]
	param()

	[pscustomobject]@{
		PSTypeName            = 'OS7.Storage.Threshold'
		Warn                  = [int]$script:OS7StorageThresholds['Warn']
		Tighten               = [int]$script:OS7StorageThresholds['Tighten']
		Refuse                = [int]$script:OS7StorageThresholds['Refuse']
		TightRetention        = $script:OS7StorageTightRetention
		RetentionFloor        = $script:OS7StorageRetentionFloor
		BootEnvironmentFloor  = [int]$script:OS7BootEnvironmentFloor
	}
}

function Get-OS7ProtectedBootEnvironment {
	<#
	.SYNOPSIS
		The boot environments no pressure may remove.

	.DESCRIPTION
		The running one, and the newest one older than it — the environment an
		operator would boot to undo the last update. Owner's decision,
		2026-09-14.

		DERIVED FROM CREATION ORDER, not from a marker. Nothing writes "this is
		the one before the last update" anywhere, and a marker would be a second
		source of truth that an interrupted update could leave pointing at the
		wrong environment. Sorting by Created and taking the running one plus
		its predecessor asks ZFS the same question every time.

		When the running environment cannot be identified — a live medium, a
		container, anything not ZFS-rooted — EVERY environment is protected.
		Refusing to prune what you cannot reason about is the only safe
		direction, and Get-OS7BootEnvironment already reports Running as $null
		rather than guessing (BUILD-NOTES: Active is "mounted anywhere").

	.EXAMPLE
		Get-OS7ProtectedBootEnvironment
	#>
	[CmdletBinding()]
	[OutputType([string[]])]
	param()

	$all = @(Get-OS7BootEnvironment | Sort-Object Created -Descending)
	if ($all.Count -eq 0) { return @() }

	$running = @($all | Where-Object { $_.Running -eq $true })

	if ($running.Count -eq 0) {
		# Nothing said it is running. Protect everything rather than choose.
		return @($all.Name)
	}

	$names = [System.Collections.Generic.List[string]]::new()
	$names.Add($running[0].Name)

	# The newest environment older than the running one: the way back.
	$older = @($all | Where-Object { $_.Created -lt $running[0].Created })
	if ($older.Count -gt 0) { $names.Add($older[0].Name) }

	# RETURNED AS [string[]], NOT AS THE LIST, and that is not tidiness.
	# `,@($list)` emitted the List as ONE object, so the caller's
	# `$protected -notcontains $_.Name` compared a List against a string, was
	# never true, and every environment came back prunable — INCLUDING THE
	# RUNNING ONE. Measured on a machine, where the protected list and the
	# prunable list both named os7_1.0.0.163_202608301351.
	[string[]]$names.ToArray()
}

function Get-OS7StoragePressure {
	<#
	.SYNOPSIS
		How full the pool is, what level that is, and whether thinning would help.

	.DESCRIPTION
		The measurement and the decision, with nothing changed. This is what
		`Invoke-OS7StorageRelief` acts on and what an operator reads when a
		machine says it is filling up.

		`WouldHelp` is the property that matters. It is $false when every
		snapshot and every prunable boot environment could be destroyed and the
		pool would STILL be above the target — which means the live data is what
		is full, and deleting history is destruction with no benefit.

	.PARAMETER Pool
		Which pool. Defaults to the one the root filesystem is on.

	.EXAMPLE
		Get-OS7StoragePressure | Format-List

	.EXAMPLE
		if ((Get-OS7StoragePressure).Level -ne 'Normal') { Invoke-OS7StorageRelief -WhatIf }
	#>
	[CmdletBinding()]
	[OutputType('OS7.Storage.Pressure')]
	param(
		[Parameter(Position = 0)][string]$Pool = 'rpool'
	)

	$thresholds = Get-OS7StorageThreshold
	$pools = @(Get-ZfsPool -Name $Pool)

	if ($pools.Count -eq 0) {
		throw [System.InvalidOperationException]::new(
			"there is no pool called '$Pool' on this machine.")
	}

	$p = $pools[0]

	$level =
		if ($p.Capacity -ge $thresholds.Refuse) { 'Refuse' }
		elseif ($p.Capacity -ge $thresholds.Tighten) { 'Tighten' }
		elseif ($p.Capacity -ge $thresholds.Warn) { 'Warn' }
		else { 'Normal' }

	# What it is trying to get back under: one step down from where it is.
	$target = switch ($level) {
		'Refuse' { [int]$thresholds.Tighten }
		'Tighten' { [int]$thresholds.Warn }
		default { [int]$thresholds.Warn }
	}

	# What would have to go to reach it. Negative when nothing does.
	$bytesToRelieve = [int64]($p.Allocated - ($p.Size * $target / 100))

	# WHAT IS ACTUALLY RECLAIMABLE, and it is not "everything the snapshots
	# reference". `usedbysnapshots` is the space held ONLY by snapshots — the
	# blocks the live filesystem no longer points at — which is exactly what
	# deleting them would return.
	$space = @(Get-ZfsSpace -Name $Pool -Recurse)
	$snapshotBytes = [int64](
		($space | Measure-Object -Property UsedBySnapshots -Sum).Sum)

	# Boot environments beyond the floor. The protected ones are not counted,
	# because they are not candidates at any pressure.
	$protected = @(Get-OS7ProtectedBootEnvironment)
	$environments = @(Get-OS7BootEnvironment | Sort-Object Created -Descending)
	$prunableEnvironments = @($environments |
		Where-Object { $protected -notcontains $_.Name })

	# Get-OS7BootEnvironment's own `Used` already sums the ROOT and BOOT
	# datasets — an environment is a pair, and half of it lives on bpool.
	# Asking Get-ZfsSpace about one dataset would count the smaller half twice
	# over several environments and miss the other entirely.
	$environmentBytes = [int64]0
	foreach ($be in $prunableEnvironments) {
		$environmentBytes += [int64]$be.Used
	}

	$reclaimable = $snapshotBytes + $environmentBytes
	$wouldHelp = ($bytesToRelieve -le 0) -or ($reclaimable -ge $bytesToRelieve)

	$reason = switch ($level) {
		'Normal' {
			"The pool is $($p.Capacity)% full. Nothing to do."
		}
		'Warn' {
			"The pool is $($p.Capacity)% full, at or above the $($thresholds.Warn)% " +
			'notice level. Nothing is deleted at this level; the machine is telling ' +
			'you while there is still time to decide.'
		}
		'Tighten' {
			if ($wouldHelp) {
				"The pool is $($p.Capacity)% full. Tightening the retention policy " +
				"would free up to $(Format-ZfsSize $reclaimable) and bring it back " +
				"under $target%."
			}
			else {
				"The pool is $($p.Capacity)% full, and thinning CANNOT fix it: every " +
				"snapshot and prunable boot environment together holds " +
				"$(Format-ZfsSize $reclaimable), and $(Format-ZfsSize $bytesToRelieve) " +
				'would have to go. The live data is what is full. Nothing will be ' +
				'deleted, because deleting the history would cost it and change nothing.'
			}
		}
		'Refuse' {
			"The pool is $($p.Capacity)% full, at or above the $($thresholds.Refuse)% " +
			'limit. Retention drops to the floor and no new version snapshots are ' +
			'taken until there is room.' +
			$(if (-not $wouldHelp) {
				' That will NOT be enough — the live data is what is full.'
			} else { '' })
		}
	}

	[pscustomobject]@{
		PSTypeName           = 'OS7.Storage.Pressure'
		Pool                 = $p.Name
		Capacity             = $p.Capacity
		Size                 = $p.Size
		Allocated            = $p.Allocated
		Free                 = $p.Free
		Level                = $level
		Target               = $target
		# [int64]0, NOT 0. `[math]::Max(0, $int64)` binds the Int32 overload and
		# throws on anything that does not fit — measured on a machine, where a
		# pool with 22 GB spare produced a -22956657050 and a conversion error
		# instead of a number. The literal decides the overload, not the
		# variable.
		BytesToRelieve       = [int64][math]::Max([int64]0, $bytesToRelieve)
		SnapshotBytes        = $snapshotBytes
		BootEnvironmentBytes = $environmentBytes
		Reclaimable          = $reclaimable
		WouldHelp            = $wouldHelp
		ProtectedEnvironments = [string[]]$protected
		# PROJECTED, NOT MEMBER-ENUMERATED. `@($empty.Name)` raises "the
		# property 'Name' cannot be found on this object" — measured on a
		# machine the moment the protection rule started working and left
		# nothing prunable, which is the ORDINARY case on a machine with one
		# boot environment.
		PrunableEnvironments = [string[]]@($prunableEnvironments | ForEach-Object { $_.Name })
		Thresholds           = $thresholds
		Reason               = $reason
	}
}

function Get-OS7TightenedRetention {
	<#
	.SYNOPSIS
		Internal. The retention to apply at a level, never looser than now.

	.DESCRIPTION
		Element-wise MINIMUM of what is configured and what the level asks for.
		An operator who has already set `daily = 3` keeps 3 when the tight
		profile says 7 — pressure relief must never RAISE retention, which would
		be this function quietly undoing somebody's decision while claiming to
		free space.
	#>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Current,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Target
	)

	$result = [ordered]@{}
	foreach ($k in $Target.Keys) {
		$now = if ($Current.Contains($k)) { [int]$Current[$k] } else { [int]$Target[$k] }
		$result[$k] = [math]::Min($now, [int]$Target[$k])
	}
	$result
}

function Invoke-OS7StorageRelief {
	<#
	.SYNOPSIS
		Act on storage pressure: tighten retention, prune spare boot environments.

	.DESCRIPTION
		docs/VERSIONS-PLAN.md §5. What it does depends on the level, and below
		the tighten threshold it does nothing at all.

		  Normal, Warn   nothing. The machine has already said so.
		  Tighten        IF thinning would reach the target: tighten the
		                 retention policy and let sanoid prune under it, and
		                 remove boot environments beyond the floor. If it would
		                 NOT reach the target, nothing is deleted and the reason
		                 is reported.
		  Refuse         retention to the floor and spare environments removed
		                 whether or not it suffices, because at that point every
		                 byte counts and the alternative is a machine that stops
		                 working.

		IT DELETES NO SNAPSHOT ITSELF. It writes the policy and sanoid prunes.
		The only thing it removes directly is a boot environment, which sanoid
		knows nothing about.

	.PARAMETER Pool
		Which pool to judge. Defaults to rpool.

	.PARAMETER Force
		Act at Tighten even when thinning cannot reach the target. For an
		operator who wants the space back anyway and has read why it will not be
		enough.

	.EXAMPLE
		Invoke-OS7StorageRelief -WhatIf

	.EXAMPLE
		Invoke-OS7StorageRelief
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.Storage.Relief')]
	param(
		[Parameter(Position = 0)][string]$Pool = 'rpool',
		[switch]$Force
	)

	Assert-OS7Elevated -Cmdlet 'Invoke-OS7StorageRelief' -Because (
		'rewrites the snapshot retention policy and can remove boot environments')

	$pressure = Get-OS7StoragePressure -Pool $Pool
	$removed = [System.Collections.Generic.List[string]]::new()
	$removedAside = [System.Collections.Generic.List[string]]::new()
	$keptAside = [System.Collections.Generic.List[string]]::new()
	[int64]$freedBytes = 0
	$applied = $null
	$action = 'None'

	if ($pressure.Level -in @('Normal', 'Warn')) {
		$action = 'None'
	}
	elseif ($pressure.Level -eq 'Tighten' -and -not $pressure.WouldHelp -and -not $Force) {
		# The gate. Deleting the history would cost it and change nothing.
		$action = 'Reported'
	}
	else {
		$target = if ($pressure.Level -eq 'Refuse') {
			$script:OS7StorageRetentionFloor
		}
		else {
			$script:OS7StorageTightRetention
		}

		$policy = Get-OS7BackupPolicy -ConfigOnly
		$current = if ($policy.Sources -and $policy.Sources.Count -gt 0) {
			$policy.Sources[0].Retention
		}
		else {
			New-OS7BackupRetention
		}

		$applied = Get-OS7TightenedRetention -Current $current -Target $target

		# A MACHINE WITH NO POLICY MUST NOT GAIN ONE HERE, and this guard is the
		# difference between "tighten the retention" and "enable backup".
		# Get-OS7BackupPolicy -ConfigOnly answers with DEFAULTS when there is no
		# /etc/os7/backup.json — measured, two sources on a host that has never had
		# the file — so Set-OS7BackupPolicy would WRITE one. That is not a
		# tightening: it is this cmdlet turning a feature on, unattended, from a
		# timer, on every machine that reaches 80 %. And the file it would create is
		# exactly what os7-backup-replicate.service's ConditionPathExists waits for,
		# so the side effect would not even stay inside backup policy.
		#
		# There is also nothing to tighten. No policy means no OS/7-managed
		# snapshots, which means the history this rule exists to thin is not there.
		if (-not [System.IO.File]::Exists($script:OS7BackupConfig)) {
			$applied = $null
			Write-Verbose ("no $script:OS7BackupConfig, so there is no retention to " +
				'tighten and none will be created')
		}
		elseif ($PSCmdlet.ShouldProcess($Pool,
				"tighten retention to $(($applied.GetEnumerator() |
					ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')")) {
			Set-OS7BackupPolicy -Retention $applied -Confirm:$false | Out-Null
		}

		# Boot environments beyond the floor, oldest first. The protected two
		# are not in this list at all.
		$spare = @($pressure.PrunableEnvironments)
		$keepCount = [math]::Max(0,
			$script:OS7BootEnvironmentFloor - $pressure.ProtectedEnvironments.Count)

		if ($spare.Count -gt $keepCount) {
			$toRemove = @($spare | Select-Object -Skip $keepCount)
			foreach ($name in $toRemove) {
				if ($PSCmdlet.ShouldProcess($name, 'remove boot environment')) {
					try {
						Remove-OS7BootEnvironment -Name $name -Confirm:$false | Out-Null
						$removed.Add($name)
					}
					catch {
						# Said, not swallowed: a prune that cannot run is a pool
						# that keeps filling, and the operator has to know which.
						Write-Warning "could not remove boot environment ${name}: $($_.Exception.Message)"
					}
				}
			}
		}

		# THE FILES A RESTORE PUT ASIDE (V19/VL9), by the owner's decision of
		# 2026-09-15: removable from the Tighten level, older than 30 days —
		# AND ONLY WHERE A SNAPSHOT STILL HOLDS THEM.
		#
		# The age rule came with a reason ("by then sanoid has taken it into a
		# snapshot"), and that reason is not safe to assume HERE of all places:
		# the level that authorises this removal is the same one that has just
		# tightened the retention from daily=14 to daily=7 and monthly=3 to
		# monthly=1. A file put aside 40 days ago can fall out of history in the
		# same pass that decides it is old enough to delete.
		#
		# So Get-OS7RestoreAside asks ZFS per file, and a file nothing holds is
		# the ONLY copy of somebody's work — which is exactly why the restore
		# put it aside, and why it stays whatever the pressure.
		foreach ($aside in @(Get-OS7RestoreAside -OlderThanDays $script:OS7RestoreAsideMaxAgeDays)) {
			if (-not $aside.Held) {
				$keptAside.Add($aside.Path)
				continue
			}
			if (-not $PSCmdlet.ShouldProcess($aside.Path,
					"remove a file put aside $($aside.AgeDays) days ago by a restore")) {
				continue
			}
			try {
				Remove-Item -LiteralPath $aside.Path -Force -ErrorAction Stop
				$removedAside.Add($aside.Path)
				$freedBytes += [int64]$aside.Length
			}
			catch {
				Write-Warning "could not remove $($aside.Path): $($_.Exception.Message)"
			}
		}

		$action = if ($pressure.Level -eq 'Refuse') { 'Emergency' } else { 'Tightened' }
	}

	[pscustomobject]@{
		PSTypeName       = 'OS7.Storage.Relief'
		Pool             = $pressure.Pool
		Level            = $pressure.Level
		Action           = $action
		WouldHelp        = $pressure.WouldHelp
		AppliedRetention = $applied
		RemovedEnvironments = @($removed)
		# V19's files: what was removed, what was KEPT because ZFS holds no
		# copy of it, and what the removals actually returned. The kept list is
		# reported rather than silent — "I left these alone and here is why" is
		# the half an operator needs in order to deal with them by hand.
		RemovedAsideFiles = @($removedAside)
		KeptAsideFiles    = @($keptAside)
		FreedBytes        = [int64]$freedBytes
		Reason            = $pressure.Reason
	}
}

function Get-OS7RestoreAside {
	<#
	.SYNOPSIS
		The files a restore put aside, what they cost, and whether ZFS still has them.

	.DESCRIPTION
		docs/VERSIONS-PLAN.md V19 and VL9. When `Restore-OS7File` cannot take a
		ZFS snapshot — which on this product means, nearly always, that the
		caller is the OWNER of the file and not root (M-V22) — it renames the
		file it is about to overwrite to `<path>.os7-before-restore-<stamp>`
		instead of destroying it. That is Time Machine's "Keep Both", and nothing
		cleans them up on its own.

		THIS IS WHAT MAKES THEM VISIBLE. An operator asking "what are all these
		files and may I delete them" gets an answer per file rather than a
		convention to remember, and `Invoke-OS7StorageRelief` asks the same
		question before it removes any.

		`Held` IS ASKED, NOT ASSUMED, and that is the whole point of the column.
		The owner's decision (2026-09-15) was to remove these under pressure once
		they are older than 30 days, on the reasoning that sanoid will have taken
		them into a snapshot by then. That reasoning is TRUE ONLY IF THE
		RETENTION STILL REACHES BACK THAT FAR — and the pressure level that
		authorises the removal is the same one that TIGHTENS the retention, from
		daily=14 to daily=7 and monthly=3 to monthly=1. So age is not evidence
		here; `Get-OS7FileVersion` is asked whether a snapshot actually holds the
		file, per file, and only `Held` is ever removable.

		Read-only, and unprivileged: these live in the operator's own directories
		and asking about them needs nothing.

	.PARAMETER Dataset
		Which datasets' mountpoints to walk. Defaults to the ones the backup
		policy covers, which is where restores happen.

	.PARAMETER OlderThanDays
		Report only files put aside longer ago than this. The age comes from the
		STAMP IN THE NAME — when the file was put aside — and not from its
		mtime, which is the age of the contents and is usually much older.

	.OUTPUTS
		OS7.Storage.RestoreAside: Path, Dataset, Length, PutAside, AgeDays, Held.

	.EXAMPLE
		Get-OS7RestoreAside | Format-Table Path, Length, PutAside, Held

	.EXAMPLE
		Get-OS7RestoreAside -OlderThanDays 30 | Where-Object Held
	#>
	[CmdletBinding()]
	[OutputType('OS7.Storage.RestoreAside')]
	param(
		[Parameter(Position = 0)][string[]]$Dataset,
		[int]$OlderThanDays = 0
	)

	$roots = if ($Dataset) { @($Dataset) }
	else {
		$policy = Get-OS7BackupPolicy -ConfigOnly
		if ($policy.Sources) { @($policy.Sources.Dataset) } else { @('rpool/USERDATA') }
	}

	$now = Get-Date
	$pattern = "*.$script:OS7RestoreSafetyPrefix*"

	foreach ($root in $roots) {
		$datasets = @(Get-ZfsDataset -Name $root -Type Filesystem -Recurse -ErrorAction SilentlyContinue)

		foreach ($d in $datasets) {
			$mount = [string]$d.Mountpoint
			if (-not $mount -or $mount -eq 'legacy' -or -not (Test-Path -LiteralPath $mount)) {
				continue
			}

			$found = @()
			try {
				$found = @(Get-ChildItem -LiteralPath $mount -Filter $pattern -Recurse -File -Force -ErrorAction SilentlyContinue)
			}
			catch { continue }

			foreach ($f in $found) {
				# `.zfs` is snapdir=hidden and Get-ChildItem does not descend
				# into it — but a snapshot reached by an explicit path would be
				# read-only and undeletable, and reporting one as removable
				# would be a lie. Cheap to exclude, so excluded.
				if ($f.FullName -like '*/.zfs/*') { continue }

				# The stamp is what this owns; the mtime belongs to the contents
				# and is older, often by years.
				$putAside = $null
				$stamp = $f.Name -replace ".*$([regex]::Escape($script:OS7RestoreSafetyPrefix))", ''
				$stamp = ($stamp -split '-')[0..1] -join '-'
				$parsed = [datetime]::MinValue
				if ([datetime]::TryParseExact($stamp, 'yyyyMMdd-HHmmss', $null,
						[System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
					$putAside = $parsed
				}

				$ageDays = if ($putAside) { [int]($now - $putAside).TotalDays } else { $null }
				if ($OlderThanDays -gt 0 -and ($null -eq $ageDays -or $ageDays -lt $OlderThanDays)) {
					continue
				}

				# ASKED OF ZFS. A file whose content is in no snapshot is the
				# ONLY copy of somebody's work — that is precisely why the
				# restore put it aside — and nothing may remove it.
				$held = $false
				try {
					$held = @(Get-OS7FileVersion -Path $f.FullName -ErrorAction Stop).Count -gt 0
				}
				catch { $held = $false }

				[pscustomobject]@{
					PSTypeName = 'OS7.Storage.RestoreAside'
					Path       = $f.FullName
					Dataset    = $d.Name
					Length     = [int64]$f.Length
					PutAside   = $putAside
					AgeDays    = $ageDays
					Held       = $held
				}
			}
		}
	}
}

function Get-OS7VersionStore {
	<#
	.SYNOPSIS
		What a machine's file history costs, and how far back it reaches.

	.DESCRIPTION
		docs/VERSIONS-PLAN.md V9. The reporting half of the Versions feature:
		per dataset, how many snapshots there are, how far back they go, and how
		much space is held ONLY by them — which is what deleting them would
		return, and is usually far less than people expect.

		Read-only, and unprivileged: a user can ask what their own history
		costs.

	.PARAMETER Dataset
		One dataset, or all of the ones the backup policy covers.

	.EXAMPLE
		Get-OS7VersionStore | Format-Table Dataset, Snapshots, Oldest, Held

	.EXAMPLE
		(Get-OS7VersionStore -Dataset rpool/USERDATA/os7admin_af456a8e).Held
	#>
	[CmdletBinding()]
	[OutputType('OS7.Storage.VersionStore')]
	param(
		[Parameter(Position = 0)][string[]]$Dataset
	)

	$wanted = if ($Dataset) { @($Dataset) }
	else {
		$policy = Get-OS7BackupPolicy -ConfigOnly
		if ($policy.Sources) { @($policy.Sources.Dataset) } else { @('rpool/USERDATA') }
	}

	foreach ($root in $wanted) {
		$space = @(Get-ZfsSpace -Name $root -Recurse -ErrorAction SilentlyContinue)

		foreach ($s in $space) {
			$snapshots = @(Get-ZfsSnapshot -Name $s.Name -NoRecurse -ErrorAction SilentlyContinue)

			# SORTED ONCE, INTO A VARIABLE, and the property read off the array
			# rather than off the pipeline. `(… | Select-Object -First 1).X` on
			# an empty pipeline is BUILD-NOTES #112/#119 — it yields $null and
			# the read goes unnoticed — and check-ps-traps.py holds that at
			# zero. The guard below makes it safe today; writing it this way
			# keeps it safe when somebody edits the guard.
			$ordered = @($snapshots | Sort-Object Creation)
			$hasAny = $ordered.Count -gt 0

			# A dataset with no snapshots is REPORTED, not skipped: "this home
			# has no history" is the answer somebody is looking for when the
			# Versions window comes up empty (V6).
			[pscustomobject]@{
				PSTypeName = 'OS7.Storage.VersionStore'
				Dataset    = $s.Name
				Snapshots  = $ordered.Count
				Oldest     = $(if ($hasAny) { $ordered[0].Creation } else { $null })
				Newest     = $(if ($hasAny) { $ordered[-1].Creation } else { $null })
				Held       = $s.UsedBySnapshots
				Live       = $s.UsedByDataset
				Available  = $s.Available
			}
		}
	}
}
