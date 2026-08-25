# =============================================================================
# OS/7 Backup — policy, schedule and status (docs/BACKUP-PLAN.md)
#
# Dot-sourced by OS7.psm1.
#
# WHAT THIS IS. OS/7 already treats a ZFS snapshot as a first-class thing: an
# update happens in a clone and a bad one is undone by booting yesterday's
# environment. This applies the same primitive to the OTHER half of the machine
# — the user's and the workload's data — and then sends it somewhere else,
# which is the part that makes it a backup rather than an on-disk undo history.
#
# WHAT IT IS NOT. It is not a snapshot scheduler, a retention thinner or a
# replication engine. Those are `sanoid` and `syncoid` (GPL-3.0+,
# https://github.com/jimsalterjrs/sanoid), which are in the pinned Ubuntu
# archive and are shelled out to as ordinary programs. OS/7 is MIT; running a
# GPLv3 binary as a process is not a licensing question, vendoring its code
# would be, and re-implementing thinning logic that has been in production for
# a decade would be worse than both.
#
#   sanoid   takes and thins snapshots on a policy         /usr/sbin/sanoid
#   syncoid  incremental zfs send/receive to another pool  /usr/sbin/syncoid
#   OS/7     decides WHAT, WHERE, and WHETHER IT WORKED    this file
#
# THE THIRD COLUMN IS THE WHOLE JOB, and it is bigger than it looks. Both tools
# were measured before this was written (docs/BACKUP-PLAN.md §13) and BOTH
# report success in situations where nothing happened:
#
#   * `sanoid` exits 0 after taking snapshots even when `zfs snapshot` FAILED —
#     the failure is a perl `warn` and never reaches the exit status
#     (sanoid:692-705, and the exit at :144).
#   * `sanoid --monitor-snapshots` does not ask ZFS at all. It answers from
#     /var/cache/sanoid/snapshots.txt, and for a monitor-only invocation the
#     cache TTL is deliberately raised to FIVE HOURS (sanoid:69-85).
#   * `syncoid` exits 0 with its post-replication work unfinished: sync-snapshot
#     pruning, target-snapshot deletion and hold release all only `warn`.
#
# So nothing here believes an exit code. Every OS/7 verb that claims something
# happened re-reads it from ZFS — locally through the Zfs module, and on a
# remote target through the same module over ssh (ZFS-POWERSHELL-PLAN Z14).
# That is docs/BUILD-NOTES.md's oldest rule applied to the one feature where
# being wrong is discovered by the person who needed the data.
# =============================================================================

# ---------------------------------------------------------------------------
# Where things live
# ---------------------------------------------------------------------------

# OS/7's own policy. THE source of truth; sanoid.conf is generated from it and
# is never hand-edited. Same shape as the boot menu: Set-OS7BootEnvironment
# writes /etc/os7/grub-boot-environments.cfg and GRUB reads it.
$script:OS7BackupConfig = '/etc/os7/backup.json'

# The generated file. sanoid's units point at exactly this path and nowhere
# else (ConditionFileNotEmpty=/etc/sanoid/sanoid.conf).
$script:OS7SanoidConfDir = '/etc/sanoid'
$script:OS7SanoidConf = '/etc/sanoid/sanoid.conf'

# The shipped defaults, which are ALSO the list of legal keys — see
# Assert-OS7SanoidKeys.
$script:OS7SanoidDefaults = '/usr/share/sanoid/sanoid.defaults.conf'

$script:OS7SanoidBin = '/usr/sbin/sanoid'
$script:OS7SyncoidBin = '/usr/sbin/syncoid'

# The log lives OUTSIDE the boot environment, on purpose. /var/log is
# rpool/DATA/log (SETUP-PLAN §4.4, D10): rolling the system back must not also
# roll back the record of what the backups did, because the record is how
# somebody finds out what the rollback cost them.
$script:OS7BackupLog = '/var/log/os7/backup.log'

# /run is a tmpfs, so the lock cannot outlive a boot. syncoid has NO locking of
# any kind — its only overlap guard is a `ps` grep for a running `zfs receive`
# on the target — so this is the only thing standing between two timers and two
# concurrent sends of the same dataset.
$script:OS7BackupLock = '/run/os7-backup.lock'

# The dataset trees a snapshot policy may touch, and the ones it may not.
#
# rpool/ROOT and bpool/BOOT ARE THE UPDATE TRAIN. `New-OS7BootEnvironment`
# snapshots `rpool/ROOT/<be>` and `bpool/BOOT/<be>` recursively and clones every
# dataset from those snapshots, so a snapshot under there is not inert: it is
# cloned into the next boot environment and carried forward for as long as the
# environment lives. `Remove-OS7BootEnvironment` destroys both halves with
# `zfs destroy -r`, which takes every snapshot with them.
$script:OS7BackupForbidden = @('rpool/ROOT', 'bpool/BOOT', 'bpool')

# What the default policy covers. Both are OUTSIDE the boot environment by the
# D10 rule — a path belongs in the BE only if rolling it back makes the system
# more correct — which is the same test as "is this the user's data".
$script:OS7BackupDefaultSources = @('rpool/USERDATA', 'rpool/DATA/srv')

# ---------------------------------------------------------------------------
# Safety (ZFS-POWERSHELL-PLAN Z8)
# ---------------------------------------------------------------------------

function Assert-OS7DatasetSafe {
	<#
	.SYNOPSIS
		Refuse a dataset that belongs to the update train.

	.DESCRIPTION
		Z8 says the OS/7 guard lives in Layer 3, and names this function. It
		did not exist until the backup feature needed it, which is the right
		time to write it: this is the first OS/7 code that hands a dataset name
		to something that will take and DESTROY snapshots on a schedule.

		THE GENERIC LAYER CANNOT DO THIS. `New-Zpool` validates a pool NAME and
		nothing about the devices; `Remove-Zpool` refuses no pool by name. That
		is correct for a module meant to run against a TrueNAS box, and it means
		every OS/7-specific refusal has to be here.

		WHAT IS REFUSED, and why each:

		  rpool/ROOT, bpool/BOOT and everything under them
		      The boot environments. A policy that snapshots here has its
		      snapshots cloned into the next environment by
		      New-OS7BootEnvironment and destroyed by Remove-OS7BootEnvironment.
		  bpool
		      Created with `compatibility=grub2` so GRUB can read it. It holds
		      kernels, not data, and it is the smallest pool on the machine.
		  a pool root (rpool, bpool)
		      `recursive = yes` in sanoid.conf makes every child dataset its own
		      configuration section, inheriting autoprune — so one `[rpool]`
		      section puts rpool/ROOT inside the pruner's scope. Refusing the
		      pool root refuses that whole class of mistake rather than the one
		      example of it.

	.PARAMETER Name
		The dataset.

	.PARAMETER Action
		What it was going to be used for, so the message says what was refused.

	.PARAMETER Force
		Proceed anyway. There is no supported reason to; it exists so that the
		refusal is a decision rather than a wall, and it is never passed by any
		OS/7 code path.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter()][string]$Action = 'back up',
		[switch]$Force
	)

	$why = $null
	if ($Name -notmatch '/') {
		$why = "'$Name' is a whole pool. A snapshot policy on a pool root reaches " +
		'every dataset in it, including the boot environments — sanoid turns ' +
		'`recursive = yes` into one configuration section per child, and each ' +
		'inherits autoprune. Name the datasets instead.'
	}
	else {
		foreach ($f in $script:OS7BackupForbidden) {
			if ($Name -eq $f -or $Name.StartsWith("$f/")) {
				$why = "'$Name' is part of the update train ($f). Boot environments are " +
				'snapshotted, cloned and destroyed by Update-OS7 and ' +
				'Remove-OS7BootEnvironment; a second thing taking and pruning ' +
				'snapshots there would be cloned into every future environment. ' +
				'Roll the system back with Restore-OS7, not with a backup policy.'
				break
			}
		}
	}

	if (-not $why) { return }
	if ($Force) {
		Write-OS7Step "WARNING: -Force overrode the guard on $Name ($Action)"
		return
	}
	throw [System.InvalidOperationException]::new("Refusing to $Action $Name. $why")
}

# ---------------------------------------------------------------------------
# The policy object
# ---------------------------------------------------------------------------

function New-OS7BackupRetention {
	<#
	.SYNOPSIS
		Internal. OS/7's default retention, as an ordered table.

	.DESCRIPTION
		NOT sanoid's defaults, and the difference is deliberate. Shipped:
		hourly=48, daily=90, monthly=6, with weekly and yearly off — 144
		snapshots per dataset. OS/7's disk floor is 16 GB (README, and
		Disks.cs's MinimumBytes), no dataset it creates carries a quota, and
		rpool holds `/` — so a retention policy that fills rpool does not fail
		the backup, it makes the running system unwritable.

		24 / 14 / 4 / 3 is 45 snapshots and covers the same ground an operator
		actually asks for: today by the hour, a fortnight by the day, a month by
		the week, a quarter by the month.

		`frequently` and `yearly` are 0, and 0 does not mean "leave alone" — it
		means "destroy every existing snapshot of that type now" (sanoid:462 and
		the prune loop). That is correct here and it is worth knowing before
		somebody sets `hourly = 0` to pause hourly snapshots and loses the ones
		they had.
	#>
	[ordered]@{
		frequently = 0
		hourly     = 24
		daily      = 14
		weekly     = 4
		monthly    = 3
		yearly     = 0
	}
}

function ConvertTo-OS7BackupSource {
	<#
	.SYNOPSIS
		Internal. Normalise one source entry and check it.
	#>
	param([Parameter(Mandatory)]$Source, [switch]$Force)

	$dataset = [string]$Source.dataset
	if (-not $dataset) { throw [ArgumentException]::new('a backup source needs a dataset') }
	Assert-OS7DatasetSafe -Name $dataset -Action 'snapshot' -Force:$Force

	$retention = [ordered]@{}
	$defaults = New-OS7BackupRetention
	foreach ($k in $defaults.Keys) {
		$v = if ($Source.PSObject.Properties.Name -contains 'retention' -and
			$Source.retention -and
			$Source.retention.PSObject.Properties.Name -contains $k) {
			[int]$Source.retention.$k
		}
		else { [int]$defaults[$k] }
		if ($v -lt 0) { throw [ArgumentException]::new("retention '$k' cannot be negative") }
		$retention[$k] = $v
	}

	$has = { param($n) $Source.PSObject.Properties.Name -contains $n }

	[pscustomobject]@{
		PSTypeName   = 'OS7.Backup.Source'
		Dataset      = $dataset
		Recursive    = if (& $has 'recursive') { [bool]$Source.recursive } else { $true }
		ChildrenOnly = if (& $has 'childrenOnly') { [bool]$Source.childrenOnly } else { $false }
		Retention    = $retention
	}
}

function Get-OS7BackupPolicy {
	<#
	.SYNOPSIS
		What this machine is configured to snapshot, and what it actually has.

	.DESCRIPTION
		Reads /etc/os7/backup.json and, unless -ConfigOnly, answers the question
		the operator is really asking — is it working — by looking at ZFS rather
		than at the configuration file:

		  Exists     the dataset is really there. A section naming a dataset
		             that does not exist is NOT detected by sanoid at
		             configuration time: it treats "no snapshots" as infinitely
		             stale, tries to snapshot it, `zfs snapshot` fails, sanoid
		             prints CRITICAL ERROR to stderr — and exits 0.
		  Snapshots  how many autosnap_* snapshots that dataset holds now.
		  Newest     the creation time of the newest one, from ZFS.

		WITH NO CONFIGURATION FILE this returns the DEFAULT policy with
		Configured = $false, rather than nothing. The difference matters on a
		machine where somebody has not run Enable-OS7Backup yet: "no backups"
		and "no such feature" look identical otherwise.

	.PARAMETER ConfigOnly
		Do not go near ZFS. For a machine where the pools are not imported.

	.EXAMPLE
		Get-OS7BackupPolicy

	.EXAMPLE
		(Get-OS7BackupPolicy).Sources | Format-Table Dataset, Snapshots, Newest
	#>
	[CmdletBinding()]
	[OutputType('OS7.Backup.Policy')]
	param([switch]$ConfigOnly)

	$configured = Test-Path -LiteralPath $script:OS7BackupConfig -PathType Leaf
	$doc = if ($configured) {
		Get-Content -Raw -LiteralPath $script:OS7BackupConfig | ConvertFrom-Json
	}
	else {
		[pscustomobject]@{
			version = 1
			enabled = $false
			sources = @($script:OS7BackupDefaultSources | ForEach-Object {
					[pscustomobject]@{ dataset = $_ }
				})
			targets = @()
		}
	}

	# Read through property checks rather than straight off the object. Under
	# Set-StrictMode a missing property is an ERROR, not $null, and this file is
	# on disk where a human can edit it — so a hand-trimmed backup.json would
	# otherwise take out every backup cmdlet at once with a message about a
	# property rather than about the file.
	# The @( … ) goes AROUND the if, not just inside its branches. An `if` whose
	# branch evaluates to an empty array assigns $null, because the pipeline
	# unrolls it on the way out — so `$x = if (…) { @() }` is $null and `.Count`
	# on it throws under Set-StrictMode, naming the property and not the cause.
	$has = { param($n) $doc.PSObject.Properties.Name -contains $n }
	$rawSources = @(if (& $has 'sources') { $doc.sources })
	$enabled = if (& $has 'enabled') { [bool]$doc.enabled } else { $false }
	$rawTargets = @(if (& $has 'targets') { $doc.targets })

	$sources = @(foreach ($s in $rawSources) { ConvertTo-OS7BackupSource -Source $s })

	if (-not $ConfigOnly) {
		Import-OS7ZfsLayer
		$live = @{}
		foreach ($d in @(Get-ZfsDataset -Type Filesystem -Recurse)) { $live[[string]$d.Name] = $d }

		foreach ($s in $sources) {
			$names = @($live.Keys | Where-Object {
					$_ -eq $s.Dataset -or ($s.Recursive -and $_.StartsWith("$($s.Dataset)/"))
				})
			if ($s.ChildrenOnly) { $names = @($names | Where-Object { $_ -ne $s.Dataset }) }

			# Only sanoid's own snapshots count. sanoid can see and destroy
			# nothing whose name does not begin `autosnap` (sanoid:914), so
			# counting anything else would credit the policy with snapshots it
			# neither took nor maintains.
			$snaps = @(if ($names) {
					Get-ZfsSnapshot -Name $names | Where-Object { $_.SnapshotName -like 'autosnap_*' }
				})
			$newest = ($snaps | Sort-Object Creation | Select-Object -Last 1).Creation

			$s | Add-Member -NotePropertyName Exists -NotePropertyValue ([bool]$live.ContainsKey($s.Dataset))
			$s | Add-Member -NotePropertyName Datasets -NotePropertyValue @($names | Sort-Object)
			$s | Add-Member -NotePropertyName Snapshots -NotePropertyValue $snaps.Count
			$s | Add-Member -NotePropertyName Newest -NotePropertyValue $newest
		}
	}

	[pscustomobject]@{
		PSTypeName  = 'OS7.Backup.Policy'
		Configured  = $configured
		Enabled     = $enabled
		ConfigPath  = $script:OS7BackupConfig
		SanoidConf  = $script:OS7SanoidConf
		Sources     = $sources
		TargetCount = $rawTargets.Count
	}
}

# ---------------------------------------------------------------------------
# Rendering sanoid.conf — and having sanoid check it
# ---------------------------------------------------------------------------

function Get-OS7SanoidKey {
	<#
	.SYNOPSIS
		Internal. The settings sanoid will accept, read from its own defaults.

	.DESCRIPTION
		READ, NOT HARD-CODED. sanoid uses [template_default] in
		/usr/share/sanoid/sanoid.defaults.conf as its list of allowable settings
		— the file says so in its own header — and an unrecognised key anywhere
		is a FATAL die, not a warning (sanoid:975). Hard-coding the list here
		would make an OS/7 upgrade of sanoid a silent trap in both directions:
		a key that went away would still be emitted, and a key that arrived
		would be refused by OS/7 for no reason.

		Returns an empty set when the file is not there, which is what happens
		on a machine where sanoid is not installed; the caller decides whether
		that is an error.
	#>
	param([string]$Path = $script:OS7SanoidDefaults)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }

	$keys = [System.Collections.Generic.List[string]]::new()
	$inTemplate = $false
	foreach ($line in (Get-Content -LiteralPath $Path)) {
		$t = $line.Trim()
		if ($t -match '^\[(.+)\]$') { $inTemplate = ($Matches[1] -eq 'template_default'); continue }
		if (-not $inTemplate) { continue }
		if ($t -match '^([A-Za-z0-9_]+)\s*=') { $keys.Add($Matches[1]) }
	}
	return @($keys)
}

function Assert-OS7SanoidKeys {
	<#
	.SYNOPSIS
		Internal. Refuse a key sanoid would die on.
	#>
	param([Parameter(Mandatory)][string[]]$Key)

	$allowed = Get-OS7SanoidKey
	if (-not $allowed) { return }     # sanoid not installed; nothing to check against

	$bad = @($Key | Where-Object { $_ -notin $allowed })
	if ($bad) {
		throw [System.InvalidOperationException]::new(
			"sanoid would refuse " + ($bad -join ', ') + " and it refuses FATALLY — an " +
			'unrecognised setting is a die, not a warning, so the timer would stop ' +
			'silently. Allowed settings are the ones in [template_default] of ' +
			"$script:OS7SanoidDefaults.")
	}
}

function ConvertTo-OS7SanoidConf {
	<#
	.SYNOPSIS
		Internal. Render the OS/7 policy as a sanoid.conf.

	.DESCRIPTION
		THERE IS NO [version] STANZA HERE, and that is not an oversight.
		`version = 2` belongs in /usr/share/sanoid/sanoid.defaults.conf, which
		is the packaged file; `version` is not one of the settings a user
		section may carry, so writing `[version]` into /etc/sanoid/sanoid.conf
		is itself the FATAL error above.

		EVERY RETENTION KEY IS EMITTED, all six, even the zeroes. Anything left
		out inherits from the shipped [template_default] — hourly=48, daily=90,
		monthly=6 — so an omission is not "unset", it is "sanoid's policy
		instead of OS/7's", silently.
	#>
	param([Parameter(Mandatory)][object[]]$Source, [string]$Stamp)

	$out = [System.Collections.Generic.List[string]]::new()
	$out.Add('# Generated by OS/7 (Set-OS7BackupPolicy). Do not edit.')
	$out.Add('#')
	$out.Add('# The source of truth is /etc/os7/backup.json. This file is rendered from')
	$out.Add('# it and overwritten without warning; edits here are lost and, worse, are')
	$out.Add('# invisible to Get-OS7BackupPolicy, which reports the JSON.')
	$out.Add('#')
	$out.Add('# NO [version] STANZA: `version` is not a legal setting in this file and an')
	$out.Add('# unrecognised setting makes sanoid die rather than warn. version=2 lives in')
	$out.Add('# /usr/share/sanoid/sanoid.defaults.conf, which belongs to the package.')
	if ($Stamp) { $out.Add("# rendered $Stamp") }

	foreach ($s in $Source) {
		$out.Add('')
		$out.Add("[$($s.Dataset)]")
		$out.Add("`tuse_template = ")
		# recursive = yes, never `recursive = zfs`. `zfs` runs `zfs snapshot -r`,
		# which snapshots the WHOLE subtree atomically at the ZFS level —
		# including datasets created after this file was written and datasets
		# sanoid has no section for. `yes` makes each child its own section,
		# which is what keeps the guard above meaningful.
		$out.Add("`trecursive = " + $(if ($s.Recursive) { 'yes' } else { 'no' }))
		if ($s.ChildrenOnly) { $out.Add("`tprocess_children_only = yes") }
		$out.Add("`tautosnap = yes")
		$out.Add("`tautoprune = yes")
		foreach ($k in $s.Retention.Keys) { $out.Add("`t$k = $($s.Retention[$k])") }
	}
	$out.Add('')

	# `use_template = ` with an empty value is what the shipped defaults
	# themselves carry; every other key here is one of the six retention
	# settings plus recursive/process_children_only/autosnap/autoprune. Checked
	# rather than believed, because the failure is a dead timer.
	# PARENTHESISED, and it is not decoration. `-Key @(a,b) + @(c)` binds the
	# array to -Key and then offers `+` as a POSITIONAL argument, which fails
	# with "A positional parameter cannot be found that accepts argument '+'"
	# and names neither the parameter nor the operator. Same family as
	# docs/BUILD-NOTES.md #68 — PowerShell's operator precedence inside an
	# argument list is not the one the line looks like it has.
	Assert-OS7SanoidKeys -Key (@('use_template', 'recursive', 'process_children_only',
			'autosnap', 'autoprune') + @((New-OS7BackupRetention).Keys))

	return ($out -join "`n") + "`n"
}

function Test-OS7SanoidConf {
	<#
	.SYNOPSIS
		Internal. Have SANOID parse a candidate config, before it is installed.

	.DESCRIPTION
		THE POINT OF THIS FUNCTION IS THAT OS/7 DOES NOT GET TO DECIDE WHETHER
		THE FILE IS VALID. sanoid does, and it is the only thing that can:
		an unrecognised key is a fatal die (sanoid:975), a missing
		sanoid.defaults.conf is a fatal die (:932), and a defaults file older
		than v2 is a fatal die (:953). None of those is visible to a renderer.

		It is run with `--readonly`, which guards every mutating call in the
		program (:380, :398, :643, :665, :722), and with --configdir,
		--cache-dir and --run-dir all pointed at a scratch directory, so a
		validation run cannot take a snapshot, destroy one, or disturb the real
		cache.

		THREE OPTIONS ARE GIVEN ON PURPOSE. `if (keys %args < 4)` at sanoid:34
		turns --cron on when few enough arguments are present, and %args is
		pre-seeded with configdir, cache-dir and run-dir — so an invocation that
		passed only those three would silently become a full cron run.

		Returns $true / $false and writes sanoid's own message to stderr. A
		machine without sanoid returns $true with a step line saying so: the
		policy file is still worth writing, and Enable-OS7Backup is where the
		missing package is an error.
	#>
	param([Parameter(Mandatory)][string]$Content)

	if (-not (Test-Path -LiteralPath $script:OS7SanoidBin)) {
		Write-OS7Step "sanoid is not installed; the rendered config was not parsed"
		return $true
	}

	$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("os7-sanoid-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
	New-Item -ItemType Directory -Force -Path $scratch | Out-Null
	try {
		[System.IO.File]::WriteAllText((Join-Path $scratch 'sanoid.conf'), $Content)
		$r = Invoke-OS7Native -Command $script:OS7SanoidBin -Arguments @(
			'--configdir', $scratch, '--cache-dir', $scratch, '--run-dir', $scratch,
			'--readonly', '--take-snapshots', '--quiet')
		Write-OS7Step 'sanoid parsed the rendered configuration'
		return $true
	}
	catch {
		Write-OS7Step "sanoid REFUSED the rendered configuration: $($_.Exception.Message)"
		return $false
	}
	finally {
		Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $scratch
	}
}

# ---------------------------------------------------------------------------
# Writing the policy
# ---------------------------------------------------------------------------

function Set-OS7BackupPolicy {
	<#
	.SYNOPSIS
		Decide what this machine snapshots, and how long it keeps it.

	.DESCRIPTION
		Writes /etc/os7/backup.json, renders /etc/sanoid/sanoid.conf from it,
		and — before installing either — has sanoid parse the rendered file.
		A policy that sanoid would die on is refused here, at the prompt, rather
		than at 00:15 by a timer whose failure looks exactly like success.

		WRITING THE CONFIG IS WHAT STARTS THE SCHEDULE. sanoid.service and
		sanoid-prune.service carry `ConditionFileNotEmpty=/etc/sanoid/sanoid.conf`
		and the package ships no such file, so on a machine where nothing has
		configured backups the timer fires every fifteen minutes and both
		services condition-skip. `systemctl is-enabled sanoid.timer` says
		"enabled" the whole time. That is the BUILD-NOTES #33 split — a
		condition is evaluated when the job runs — and it is the reason
		Get-OS7BackupStatus asks ZFS for snapshots instead of asking systemd
		whether a timer is enabled.

	.PARAMETER Dataset
		The datasets to snapshot. Replaces the current list. Without it the
		existing sources are kept and only the retention changes.

	.PARAMETER Retention
		A table of frequently/hourly/daily/weekly/monthly/yearly counts. Applied
		to every source. Anything not named keeps OS/7's default.

		A COUNT OF 0 DESTROYS THE EXISTING SNAPSHOTS OF THAT TYPE at the next
		prune — it means "do not keep any", not "stop making new ones".

	.PARAMETER Enabled
		Whether the schedule should run at all. Disable-OS7Backup is the same
		thing said the other way round.

	.PARAMETER Force
		Override the update-train guard. There is no supported reason to.

	.EXAMPLE
		Set-OS7BackupPolicy -Dataset rpool/USERDATA, rpool/DATA/srv

	.EXAMPLE
		Set-OS7BackupPolicy -Retention @{ hourly = 48; daily = 30 }
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	[OutputType('OS7.Backup.Policy')]
	param(
		[Parameter(Position = 0)][string[]]$Dataset,
		[Parameter()][System.Collections.IDictionary]$Retention,
		[Parameter()][nullable[bool]]$Enabled,
		[switch]$Force
	)

	$current = Get-OS7BackupPolicy -ConfigOnly

	$wanted = if ($Dataset) { @($Dataset) }
	elseif ($current.Sources) { @($current.Sources.Dataset) }
	else { @($script:OS7BackupDefaultSources) }

	# $keep, NOT $retention. PowerShell variable names are CASE-INSENSITIVE, so a
	# local `$retention` IS the `-Retention` parameter — assigning the defaults
	# to it overwrites what the caller passed, the `if ($Retention)` below is
	# then always true, and `foreach ($k in $Retention.Keys) { $retention[$k]=… }`
	# enumerates the very dictionary it is writing to. The error that comes out
	# says "Collection was modified; enumeration operation may not execute" and
	# names no variable. Exactly docs/BUILD-NOTES.md #65, in a second place, and
	# found here the same way: by running the thing.
	$keep = New-OS7BackupRetention
	if ($Retention) {
		$unknown = @($Retention.Keys | Where-Object { $_ -notin $keep.Keys })
		if ($unknown) {
			throw [ArgumentException]::new(
				'retention takes ' + (($keep.Keys) -join ', ') + '; got ' +
				($unknown -join ', '))
		}
		# Over a COPY of the keys, because assigning into $keep while enumerating
		# $Retention is only safe while they are different objects — and the
		# whole point of the paragraph above is how easily they stop being.
		foreach ($k in @($Retention.Keys)) { $keep[$k] = [int]$Retention[$k] }
	}
	elseif ($current.Sources) {
		# Keep what is there when only the dataset list is changing.
		$keep = $current.Sources[0].Retention
	}

	$sources = foreach ($d in $wanted) {
		Assert-OS7DatasetSafe -Name $d -Action 'snapshot' -Force:$Force
		[pscustomobject]@{
			PSTypeName   = 'OS7.Backup.Source'
			Dataset      = $d
			# USERDATA is a container with canmount=off and mountpoint=none: the
			# accounts live below it. Snapshotting the container itself keeps a
			# snapshot of nothing on a schedule, so the default for a container
			# is children-only. Named by shape rather than by name, so a second
			# container gets the same treatment.
			Recursive    = $true
			ChildrenOnly = ($d -eq 'rpool/USERDATA' -or $d -eq 'rpool/DATA')
			Retention    = $keep
		}
	}
	$sources = @($sources)

	$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
	$conf = ConvertTo-OS7SanoidConf -Source $sources -Stamp $stamp

	$enabledNow = if ($null -ne $Enabled) { [bool]$Enabled } else { [bool]$current.Enabled }

	if (-not $PSCmdlet.ShouldProcess($script:OS7BackupConfig,
			"set the backup policy to $($wanted -join ', ')")) {
		return
	}

	if (-not (Test-OS7SanoidConf -Content $conf)) {
		throw [System.InvalidOperationException]::new(
			'sanoid refused the configuration this policy renders to (its message is ' +
			'above). Nothing was written, so the schedule still holds the previous ' +
			'policy.')
	}

	# The OS/7 file first: it is the source of truth, and a machine that has one
	# without the other should have the one that can regenerate the other.
	$doc = [ordered]@{
		version = 1
		enabled = $enabledNow
		written = $stamp
		sources = @(foreach ($s in $sources) {
				[ordered]@{
					dataset      = $s.Dataset
					recursive    = $s.Recursive
					childrenOnly = $s.ChildrenOnly
					retention    = $s.Retention
				}
			})
		# Read back off disk rather than carried through $current: the targets are
		# not part of the policy this cmdlet edits, and rewriting them from a
		# projection would be a way to lose one.
		targets = @(Get-OS7BackupTargetRaw)
	}

	New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:OS7BackupConfig) | Out-Null
	Write-OS7BackupConfig -Document $doc

	New-Item -ItemType Directory -Force -Path $script:OS7SanoidConfDir | Out-Null
	[System.IO.File]::WriteAllText($script:OS7SanoidConf, $conf)
	Write-OS7Step "wrote $($script:OS7SanoidConf) ($($sources.Count) source(s))"

	# Z3: read back what is on disk, not what was intended.
	Get-OS7BackupPolicy
}

function Write-OS7BackupConfig {
	<#
	.SYNOPSIS
		Internal. Write /etc/os7/backup.json, and read it back.
	#>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)

	$json = $Document | ConvertTo-Json -Depth 8
	[System.IO.File]::WriteAllText($script:OS7BackupConfig, $json + "`n")

	# It carries target host names and ssh key paths. 0600 is not paranoia: a
	# world-readable file naming a machine that holds a copy of everything on
	# this one is a map somebody else can read.
	try {
		$f = Get-Item -LiteralPath $script:OS7BackupConfig -Force
		$f.UnixFileMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
	}
	catch { Write-OS7Step "note: could not set the mode on $($script:OS7BackupConfig)" }

	# Parse it again. A ConvertTo-Json that produced something ConvertFrom-Json
	# cannot read would otherwise be found by the next command to run.
	try { Get-Content -Raw -LiteralPath $script:OS7BackupConfig | ConvertFrom-Json | Out-Null }
	catch {
		throw [System.InvalidOperationException]::new(
			"$($script:OS7BackupConfig) was written and does not parse: $($_.Exception.Message)")
	}
	Write-OS7Step "wrote $($script:OS7BackupConfig)"
}

function Enable-OS7Backup {
	<#
	.SYNOPSIS
		Turn scheduled snapshots on, writing a default policy if there is none.

	.DESCRIPTION
		The one command a new machine needs. With no policy it writes OS/7's
		default — rpool/USERDATA and rpool/DATA/srv, 24 hourly / 14 daily /
		4 weekly / 3 monthly — and starts the schedule.

		THE SCHEDULE IS SANOID'S OWN TIMER and OS/7 ships no competing one.
		`sanoid.timer` is OnCalendar=*:0/15 with Persistent=true, which is what
		makes hourly snapshots possible at all and what makes a laptop that was
		closed for two days catch up when it opens. The package enables it at
		install time; all that is missing on an unconfigured machine is the
		config file, and writing it is what un-skips the services.

		IT REPORTS WHAT IT COULD NOT DO. On a machine without the sanoid package
		this throws, because "enabled" would otherwise be a claim about a file.

	.EXAMPLE
		Enable-OS7Backup
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Backup.Policy')]
	param()

	if (-not (Test-Path -LiteralPath $script:OS7SanoidBin)) {
		throw [System.InvalidOperationException]::new(
			"$($script:OS7SanoidBin) is not on this machine, so nothing would take a " +
			'snapshot. It is in the pinned Ubuntu archive as the `sanoid` package and ' +
			'OS/7 installs it; an image without it is an image built before backups ' +
			'existed.')
	}

	if (-not $PSCmdlet.ShouldProcess('this machine', 'enable scheduled ZFS snapshots')) { return }

	$policy = Set-OS7BackupPolicy -Enabled $true -Confirm:$false

	foreach ($unit in @('sanoid.timer')) {
		try {
			Invoke-OS7Native -Command 'systemctl' -Arguments @('enable', '--now', $unit) | Out-Null
		}
		catch { Write-OS7Step "note: could not enable $unit — $($_.Exception.Message)" }
	}

	Write-OS7Step 'backups enabled; the first snapshot is taken within 15 minutes'
	$policy
}

function Disable-OS7Backup {
	<#
	.SYNOPSIS
		Stop taking scheduled snapshots. Destroys nothing.

	.DESCRIPTION
		Sets enabled=false and REMOVES /etc/sanoid/sanoid.conf, which is what
		actually stops the work: with the file gone both services fail their
		condition and do nothing, whatever the timer does.

		The OS/7 policy stays on disk, so Enable-OS7Backup brings back the same
		one rather than the default. Existing snapshots are left exactly where
		they are — this is a schedule being switched off, not data being thrown
		away, and the two must never be the same command.

	.EXAMPLE
		Disable-OS7Backup
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	[OutputType('OS7.Backup.Policy')]
	param()

	if (-not $PSCmdlet.ShouldProcess('this machine', 'stop taking scheduled snapshots')) { return }

	if (Test-Path -LiteralPath $script:OS7BackupConfig) {
		$doc = Get-Content -Raw -LiteralPath $script:OS7BackupConfig | ConvertFrom-Json
		$ordered = [ordered]@{}
		foreach ($p in $doc.PSObject.Properties) { $ordered[$p.Name] = $p.Value }
		$ordered['enabled'] = $false
		Write-OS7BackupConfig -Document $ordered
	}

	if (Test-Path -LiteralPath $script:OS7SanoidConf) {
		Remove-Item -Force -LiteralPath $script:OS7SanoidConf
		Write-OS7Step "removed $($script:OS7SanoidConf); sanoid's services now skip"
	}

	Write-OS7Step 'scheduled snapshots stopped. Existing snapshots were NOT touched.'
	Get-OS7BackupPolicy
}

# ---------------------------------------------------------------------------
# Running one now
# ---------------------------------------------------------------------------

function Start-OS7Backup {
	<#
	.SYNOPSIS
		Snapshot now, replicate now, or both — without waiting for the timer.

	.DESCRIPTION
		THE RESULT IS MEASURED, NOT REPORTED. sanoid exits 0 after taking
		snapshots even when `zfs snapshot` failed: the failure is a perl `warn`
		carrying the words "CRITICAL ERROR" and it never reaches the exit
		status. So this counts the autosnap_* snapshots on every configured
		dataset before and after, and the number it returns is the difference
		ZFS reports.

		A run that takes no snapshot is NOT a failure. sanoid takes one only
		when the period for that type has elapsed, so two runs a minute apart
		legitimately produce one snapshot. What would be a failure is a machine
		that has none at all, and Get-OS7BackupStatus is where that is asked.

	.PARAMETER Snapshot
		Take and thin snapshots. The default when neither switch is given.

	.PARAMETER Replicate
		Also send to every enabled target. See Start-OS7BackupReplication.

	.PARAMETER Target
		Only these targets, with -Replicate.

	.EXAMPLE
		Start-OS7Backup

	.EXAMPLE
		Start-OS7Backup -Replicate
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Backup.Run')]
	param(
		[switch]$Snapshot,
		[switch]$Replicate,
		[string[]]$Target
	)

	$doSnapshot = $Snapshot -or -not $Replicate
	Import-OS7ZfsLayer

	$policy = Get-OS7BackupPolicy
	if (-not $policy.Configured) {
		throw [System.InvalidOperationException]::new(
			'this machine has no backup policy. Run Enable-OS7Backup.')
	}

	$countSnaps = {
		$n = 0
		foreach ($s in $policy.Sources) {
			if (-not $s.Datasets) { continue }
			$n += @(Get-ZfsSnapshot -Name $s.Datasets |
				Where-Object { $_.SnapshotName -like 'autosnap_*' }).Count
		}
		$n
	}

	$before = if ($doSnapshot) { & $countSnaps } else { 0 }
	$taken = 0

	if ($doSnapshot -and $PSCmdlet.ShouldProcess('the configured datasets', 'snapshot and thin now')) {
		Write-OS7Step 'sanoid --take-snapshots --prune-snapshots'
		# --force-update because the snapshot list is cached for 20 minutes and
		# an operator who just typed this wants a decision made on what ZFS
		# holds now, not on what it held at the last timer tick.
		Invoke-OS7Native -Command $script:OS7SanoidBin -Arguments @(
			'--take-snapshots', '--prune-snapshots', '--force-update', '--quiet') | Out-Null

		$after = & $countSnaps
		$taken = $after - $before
		Write-OS7Step "ZFS reports $taken more autosnap snapshot(s) than before the run"
	}

	$replication = @()
	if ($Replicate) {
		$replication = @(Start-OS7BackupReplication -Target $Target)
	}

	[pscustomobject]@{
		PSTypeName      = 'OS7.Backup.Run'
		Snapshotted     = $doSnapshot
		SnapshotsBefore = $before
		SnapshotsTaken  = $taken
		Replication     = $replication
	}
}

# ---------------------------------------------------------------------------
# Status — the verb that has to be trustworthy
# ---------------------------------------------------------------------------

function Get-OS7BackupStatus {
	<#
	.SYNOPSIS
		Whether this machine's data is actually backed up, asked of ZFS.

	.DESCRIPTION
		The answer no other command in this feature is allowed to give, because
		it is the one an operator acts on.

		NOTHING HERE TRUSTS SANOID OR SYNCOID. Not their exit codes, which are 0
		in failure cases both tools document as warnings; not
		`sanoid --monitor-snapshots`, which answers from a cache file that is
		allowed to be five hours old when only monitor flags are given; and not
		the OS/7 log. Local freshness comes from `Get-ZfsSnapshot` on the
		configured datasets. Remote freshness comes from `Get-ZfsSnapshot` on
		the TARGET, over ssh — the snapshot on the far side was written by
		`zfs receive`, so its existence is the receiving pool's statement rather
		than the sending program's.

		COVERAGE IS REPORTED SEPARATELY FROM FRESHNESS, and on OS/7 today that
		is not a formality. See Get-OS7BackupCoverage: on every machine this
		repository has installed, the account's home directory is NOT on a
		USERDATA dataset, so a policy that covers rpool/USERDATA covers an empty
		container. A status verb that only reported "snapshots are 12 minutes
		old" would be telling the truth and answering the wrong question.

	.PARAMETER SkipTargets
		Do not contact the replication targets. Local answers only, and fast.

	.EXAMPLE
		Get-OS7BackupStatus

	.EXAMPLE
		Get-OS7BackupStatus | ConvertTo-Json -Depth 6
		The shape an Intune custom-compliance script would emit. Verify the
		contract against Microsoft's live documentation before building one —
		docs/DECISIONS.md makes that a rule for anything touching Intune.
	#>
	[CmdletBinding()]
	[OutputType('OS7.Backup.Status')]
	param([switch]$SkipTargets)

	Import-OS7ZfsLayer
	$now = Get-Date

	$policy = Get-OS7BackupPolicy
	$coverage = @(Get-OS7BackupCoverage -Policy $policy)

	$sources = foreach ($s in $policy.Sources) {
		$age = if ($s.Newest) { [int]($now - $s.Newest).TotalMinutes } else { $null }
		[pscustomobject]@{
			PSTypeName     = 'OS7.Backup.SourceStatus'
			Dataset        = $s.Dataset
			Exists         = $s.Exists
			Datasets       = $s.Datasets.Count
			Snapshots      = $s.Snapshots
			Newest         = $s.Newest
			AgeMinutes     = $age
			Oldest         = $null
		}
	}
	$sources = @($sources)

	$targets = if ($SkipTargets) { @() } else { @(Get-OS7BackupTarget) }

	$newestLocal = ($policy.Sources | Where-Object Newest | Sort-Object Newest |
		Select-Object -Last 1).Newest
	$newestRemote = ($targets | Where-Object { $_.NewestReplicated } |
		Sort-Object NewestReplicated | Select-Object -Last 1).NewestReplicated

	[pscustomobject]@{
		PSTypeName                 = 'OS7.Backup.Status'
		Configured                 = $policy.Configured
		Enabled                    = $policy.Enabled
		# The one thing that is a statement about a file rather than about ZFS,
		# and it is named so that it cannot be mistaken for the others.
		ScheduleFileInstalled       = (Test-Path -LiteralPath $script:OS7SanoidConf -PathType Leaf)
		Sources                    = $sources
		Targets                    = $targets
		Uncovered                  = @($coverage | Where-Object { -not $_.Covered })
		NewestLocalSnapshot        = $newestLocal
		MinutesSinceLocalSnapshot  = if ($newestLocal) { [int]($now - $newestLocal).TotalMinutes } else { $null }
		NewestReplication          = $newestRemote
		HoursSinceReplication      = if ($newestRemote) { [int]($now - $newestRemote).TotalHours } else { $null }
		CheckedAt                  = $now
	}
}

function Get-OS7BackupCoverage {
	<#
	.SYNOPSIS
		Which home directories the policy actually reaches — and which it cannot.

	.DESCRIPTION
		MEASURED 2026-08-25, and it is the finding that most changes what this
		feature is worth on a machine installed today:

		`New-OS7Storage` creates `rpool/USERDATA/<UserName>_<suffix>` mounted at
		`/home/<UserName>`, and `-UserName` DEFAULTS TO 'os7'. `os7-setup` never
		passes it (StorageSteps.cs, the New-OS7Storage command it builds), and
		the account is created afterwards by `useradd -m` with whatever name the
		operator typed. On the machine this repository has actually installed
		and booted, that name is `os7admin` — so `/home/os7admin` is an ordinary
		directory inside the boot environment's root dataset, and
		`/home/os7` is a mounted dataset with nothing in it.

		Two consequences, and neither is a backup problem:

		  * A `Restore-OS7` rollback un-says the user's files, which is exactly
		    what SETUP-PLAN §4.4 puts USERDATA outside ROOT to prevent.
		  * No snapshot policy can cover that home without snapshotting the boot
		    environment, which Assert-OS7DatasetSafe refuses for good reasons.

		This function does not fix it. It makes it visible, on every machine,
		every time somebody asks about backups — because the alternative is a
		green status page over an uncovered home directory.

	.PARAMETER Policy
		A policy from Get-OS7BackupPolicy. Read if not given.

	.EXAMPLE
		Get-OS7BackupCoverage | Where-Object { -not $_.Covered }
	#>
	[CmdletBinding()]
	[OutputType('OS7.Backup.Coverage')]
	param([Parameter()]$Policy)

	Import-OS7ZfsLayer
	if (-not $Policy) { $Policy = Get-OS7BackupPolicy }

	$covered = [System.Collections.Generic.HashSet[string]]::new()
	foreach ($s in $Policy.Sources) {
		if ($s.PSObject.Properties.Name -contains 'Datasets') {
			foreach ($d in $s.Datasets) { [void]$covered.Add([string]$d) }
		}
	}

	$mounted = @(Get-ZfsDataset -Type Filesystem -Recurse |
		Where-Object { $_.Mounted -and $_.Mountpoint })

	$homes = @()
	if (Test-Path -LiteralPath '/home') {
		$homes = @(Get-ChildItem -LiteralPath '/home' -Directory -Force -ErrorAction SilentlyContinue)
	}

	foreach ($h in $homes) {
		$path = '/home/' + $h.Name
		$owner = Get-OS7PathDataset -Path $path -Dataset $mounted
		$ds = if ($owner) { $owner.Dataset } else { $null }

		# Its own dataset means the mountpoint IS this path. Anything else means
		# the directory lives inside some larger dataset — on OS/7 that larger
		# dataset is the boot environment.
		$ownDataset = ($owner -and $owner.Mountpoint -eq $path)

		[pscustomobject]@{
			PSTypeName = 'OS7.Backup.Coverage'
			Path       = $path
			Dataset    = $ds
			OwnDataset = [bool]$ownDataset
			Covered    = ($ds -and $covered.Contains($ds))
			Reason     = $(
				if (-not $ds) { 'not on ZFS' }
				elseif (-not $ownDataset) {
					"inside $ds — this directory has no dataset of its own, so it can " +
					'only be snapshotted by snapshotting the boot environment. ' +
					'New-OS7Storage was not told the account name (its -UserName ' +
					"defaults to 'os7'), so the dataset it made is /home/os7."
				}
				elseif ($covered.Contains($ds)) { 'covered' }
				else { "on $ds, which no backup source covers" })
		}
	}
}

# ---------------------------------------------------------------------------
# The log
# ---------------------------------------------------------------------------

function Write-OS7BackupLog {
	<#
	.SYNOPSIS
		Internal. Append one line to /var/log/os7/backup.log.

	.DESCRIPTION
		DIAGNOSIS ONLY. Nothing in this feature reads it back to decide
		anything: a log is a record of what a program believed, and this whole
		file exists because those two came apart. Get-OS7BackupStatus asks ZFS.

		It lives on rpool/DATA/log, outside the boot environment, so a rollback
		does not take the record of what happened with it.
	#>
	param([Parameter(Mandatory)][string]$Message)

	try {
		New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:OS7BackupLog) | Out-Null
		$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
		Add-Content -LiteralPath $script:OS7BackupLog -Value "$stamp $Message"
	}
	catch {
		# A log that cannot be written must not stop a backup. Say so on stderr
		# and carry on.
		Write-OS7Step "note: could not write $($script:OS7BackupLog)"
	}
}
