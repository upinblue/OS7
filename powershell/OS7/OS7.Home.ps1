# =============================================================================
# OS/7 — where a user's home directory actually lives
#
# THIS FILE EXISTS BECAUSE OF ONE MISSING ARGUMENT (docs/BUILD-NOTES.md #74).
#
# `New-OS7Storage` creates `rpool/USERDATA/<user>_<suffix>` mounted at
# `/home/<user>`, and until 2026-08-26 `os7-setup` never told it which user, so
# the module's own default — `os7` — named the dataset. The account was created
# six steps later by `useradd -m` under whatever the operator typed. Every
# machine this repository has installed therefore came out with:
#
#     /home/os7        a mounted dataset with nothing in it
#     /home/os7admin   an ordinary directory INSIDE rpool/ROOT/<be>
#
# which is exactly what installer/SETUP-PLAN.md §4.4 puts USERDATA outside ROOT
# to prevent: `Restore-OS7` un-says the user's files along with the release, and
# no snapshot policy can cover that home without snapshotting the boot
# environment (docs/BACKUP-PLAN.md B6 refuses that, correctly).
#
# The installer half of the fix is one argument in `StorageSteps.cs`. THIS half
# is the machines that are already installed, and it is not a one-liner:
#
# THE THING THAT MAKES IT DANGEROUS is that a dataset cannot simply be created
# at `/home/<user>` and the files moved "into" it. OpenZFS has defaulted to
# `overlay=on` since 0.8, so `zfs create -o mountpoint=/home/<user>` MOUNTS OVER
# the live directory and hides every file in it — no error, no warning, and a
# home that now looks empty to the person whose home it is. So the dataset is
# built somewhere else, filled, verified, and only then moved into place.
#
# WHAT THIS CODE ASSUMES ABOUT ITS OWN CORRECTNESS: nothing. It has never run
# against real ZFS (docs/BACKUP-PLAN.md B-6 is the gate), so it is written so
# that the worst outcome of being wrong is wasted space rather than a lost home:
#
#   * a snapshot of the dataset holding the home is taken BEFORE anything,
#   * the copy is verified against the original before the original is touched,
#   * the original is RENAMED ASIDE, never deleted, unless -RemoveOriginal,
#   * and every step after the rename undoes itself if the next one fails.
#
# `installer/testing/check-home-logic.py` runs all of it against a fake `zfs`
# and a real filesystem in seconds; it checks the DECISIONS, and a machine is
# still the only thing that can check the machine.
#
# ONE NAMING RULE, PAID FOR IN ADVANCE (BUILD-NOTES #65's family): the variable
# holding a home directory is `$homePath` and never `$home`. `$HOME` is a
# PowerShell automatic variable and its options are `ReadOnly, AllScope`, so
# `$home = $account.Home` does not shadow it — it throws.
# =============================================================================

# The staging area. Under /run because it is a tmpfs that exists on every booted
# machine and is cleared at boot, so a migration interrupted by a power cut
# leaves no mountpoint behind in a directory anybody looks at. Only the empty
# mountpoint lives on the tmpfs — the data is on the dataset mounted over it.
$script:OS7HomeStagingRoot = '/run/os7-home-migrate'

# A variable rather than a literal, for the same reason $script:OS7BootDir is
# one: installer/testing/check-home-logic.py points the whole of this at a
# temporary tree, and the alternative is that a destructive cmdlet is only ever
# exercised by a twenty-five-minute VM run.
$script:OS7HomeRoot = '/home'

# What "the boot environment" means to stat(2): the filesystem a home must NOT
# be on. A seam for the same reason as the one above, and named rather than
# written inline twice so that the two device comparisons in this file cannot
# drift apart.
$script:OS7RootPath = '/'

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

function Get-OS7PathDeviceId {
	<#
	.SYNOPSIS
		Internal. st_dev for a path, as a string, or $null.

	.DESCRIPTION
		THE INDEPENDENT WITNESS, and the reason it is not `zfs list`.

		"Is /home/<user> its own filesystem" is the question this whole file is
		about, and asking ZFS alone is asking one of the two parties whose
		disagreement would BE the bug. st_dev comes from stat(2): a separately
		mounted filesystem has a different device number from its parent,
		whatever any tool believes. It also works inside os7-setup's chroot,
		where /proc is a bind of the live system's and every mount table names
		the outer paths — which is why AccountStep asks it the same way.

		PowerShell cannot read st_dev without P/Invoke, so this shells out.
	#>
	param([Parameter(Mandatory)][string]$Path)

	try { return (Invoke-OS7Native -Command stat -Arguments @('-c', '%d', $Path)).Trim() }
	catch { return $null }
}

function Get-OS7PathOwnerMode {
	<#
	.SYNOPSIS
		Internal. "user:group mode" for a path, or $null.
	#>
	param([Parameter(Mandatory)][string]$Path)

	try {
		return (Invoke-OS7Native -Command stat -Arguments @('-c', '%U:%G %a', $Path)).Trim()
	}
	catch { return $null }
}

function Get-OS7Account {
	<#
	.SYNOPSIS
		Internal. One account from getent, or $null.

	.DESCRIPTION
		getent and not /etc/passwd: OS/7's whole point is Entra ID logins
		through authd, and those accounts are not in the file. An account this
		cannot see is one this must refuse to migrate, not one it may treat as
		absent.
	#>
	param([Parameter(Mandatory)][string]$UserName)

	$line = $null
	try { $line = (Invoke-OS7Native -Command getent -Arguments @('passwd', $UserName)).Trim() }
	catch { return $null }
	if (-not $line) { return $null }

	# name:passwd:uid:gid:gecos:home:shell
	$f = $line.Split(':')
	if ($f.Count -lt 7) { return $null }
	[pscustomobject]@{
		Name  = $f[0]
		Uid   = [int]$f[2]
		Gid   = [int]$f[3]
		Home  = $f[5]
		Shell = $f[6]
	}
}

function Get-OS7HomeUsage {
	<#
	.SYNOPSIS
		Internal. Apparent bytes under a path, or $null if du could not say.
	#>
	param([Parameter(Mandatory)][string]$Path)

	try {
		# --apparent-size, because the copy lands on a compressed dataset and
		# what has to fit is the logical size, not the source's allocation. It
		# over-estimates, which is the right direction for a refusal.
		$out = Invoke-OS7Native -Command du -Arguments @('-s', '-B1', '--apparent-size', $Path)
		return [uint64](($out -split '\s+')[0])
	}
	catch { return $null }
}

function Test-OS7HomeIdle {
	<#
	.SYNOPSIS
		Internal. Is anybody using this account right now?

	.DESCRIPTION
		EVERY PROBE REPORTS WHETHER IT COULD ANSWER, and a probe that is not
		installed says so rather than saying "idle". That rule is written down
		in installer/testing/run-phase3.py — a check that cannot see something
		must say NOT CHECKED, never FINE — and it matters more here than there,
		because the cost of getting it wrong is copying a home while its owner
		is writing to it.

	.OUTPUTS
		Objects with Probe, Available, Busy and Detail.
	#>
	param(
		[Parameter(Mandatory)][string]$UserName,
		[Parameter(Mandatory)][int]$Uid,
		[Parameter(Mandatory)][string]$Path
	)

	$probe = {
		param($probeName, $command, $commandArgs, $test)
		$out = $null
		try { $out = Invoke-OS7Native -Command $command -Arguments $commandArgs }
		catch {
			# A non-zero exit is two different things, told apart by whether the
			# command exists at all. `ps -u <uid>` exits 1 when the account has
			# no processes, which IS the answer; a missing binary is not.
			$msg = [string]$_.Exception.Message
			if ($msg -match 'not recognized|No such file|not found|CommandNotFound') {
				return [pscustomobject]@{
					Probe = $probeName; Available = $false; Busy = $false
					Detail = "$command is not installed on this machine"
				}
			}
			$out = ''
		}
		$busy = & $test $out
		[pscustomobject]@{
			Probe     = $probeName
			Available = $true
			Busy      = [bool]$busy
			Detail    = $(
				if ($busy) { (@($out -split "`n" | Where-Object { $_.Trim() } |
							Select-Object -First 3)) -join '; ' }
				else { 'nothing' })
		}
	}

	& $probe 'loginctl' 'loginctl' @('--no-legend', 'list-sessions') {
		param($o) @($o -split "`n" | Where-Object { $_ -match "(^|\s)$UserName(\s|$)" }).Count -gt 0
	}

	& $probe 'processes' 'ps' @('-u', "$Uid", '-o', 'pid=,comm=') {
		param($o) @($o -split "`n" | Where-Object { $_.Trim() }).Count -gt 0
	}

	# OPTIONAL, AND SAID TO BE. `fuser` is in psmisc, which OS/7 does not
	# require; where it is present it is the only probe that sees a process with
	# a file open under the home but no session and no ownership — a backup
	# agent, an indexer, an ssh subsystem running as root.
	& $probe 'open files' 'fuser' @('-m', $Path) {
		param($o) @($o -split "`n" | Where-Object { $_.Trim() }).Count -gt 0
	}
}

function Get-OS7TreeManifest {
	<#
	.SYNOPSIS
		Internal. What is in a directory tree, in three sorted lists.

	.DESCRIPTION
		WHAT VERIFIES A COPY, and it verifies it without asking `cp` anything.
		`cp -a` exits 0 having skipped a file it could not read, and this file's
		whole premise is that an exit code is not evidence.

		Three lists rather than one because a DIRECTORY's own size differs
		between filesystems — the same tree on ext4 and on ZFS reports different
		numbers for the directories and identical ones for the files — so size
		is compared for regular files only. Symlink targets are compared on
		their own because `%s` for a symlink is the length of its target, which
		would compare equal for two different targets of the same length.

		-mindepth 1: the top directory itself is not in the list, because the
		source is a directory inside the boot environment and the destination is
		a dataset root. Its owner and mode are checked separately, and set
		explicitly with `--reference` rather than copied.
	#>
	param([Parameter(Mandatory)][string]$Path)

	$meta = Invoke-OS7Native -Command find -Arguments @(
		$Path, '-mindepth', '1', '-printf', '%y %m %U %G %P\n')
	$size = Invoke-OS7Native -Command find -Arguments @(
		$Path, '-mindepth', '1', '-type', 'f', '-printf', '%s %P\n')
	$link = Invoke-OS7Native -Command find -Arguments @(
		$Path, '-mindepth', '1', '-type', 'l', '-printf', '%P -> %l\n')

	$sorted = {
		param($text)
		if (-not $text) { return @() }
		@($text -split "`n" | Where-Object { $_.Trim() } | Sort-Object)
	}
	[pscustomobject]@{
		Metadata = & $sorted $meta
		Sizes    = & $sorted $size
		Links    = & $sorted $link
	}
}

function Compare-OS7Tree {
	<#
	.SYNOPSIS
		Internal. Throw unless two directories hold the same tree.

	.DESCRIPTION
		Metadata, sizes and symlink targets always; the top directory's own
		owner and mode too. CONTENT unless the caller skips it — `diff -r` reads
		every byte twice, which on a large home is the difference between a
		minute and an hour, and it is the only check that can see a file that
		arrived the right size and the wrong shape.
	#>
	param(
		[Parameter(Mandatory)][string]$Source,
		[Parameter(Mandatory)][string]$Destination,
		[switch]$SkipContent
	)

	$sourceStat = Get-OS7PathOwnerMode -Path $Source
	$destStat = Get-OS7PathOwnerMode -Path $Destination
	if ($sourceStat -ne $destStat) {
		throw [System.InvalidOperationException]::new(
			"$Destination is '$destStat' where $Source is '$sourceStat'.")
	}

	$a = Get-OS7TreeManifest -Path $Source
	$b = Get-OS7TreeManifest -Path $Destination

	# @( ) ROUND EVERY ONE OF THESE, INCLUDING THE COUNTS BELOW. A scriptblock
	# invoked with & returns its pipeline output, and a pipeline UNROLLS: a list
	# of one comes back as a scalar and a list of none comes back as $null. So
	# `$a.Links.Count` is an error under Set-StrictMode on a home with exactly
	# one symlink in it — which is a completely ordinary home, and which is how
	# check-home-logic.py found this. Same family as BUILD-NOTES #76.
	$counted = @{}
	foreach ($part in 'Metadata', 'Sizes', 'Links') {
		$x = @($a.$part)
		$y = @($b.$part)
		$counted[$part] = $x.Count
		# Compare-Object refuses an empty -ReferenceObject, and an empty home is
		# a legitimate thing to migrate.
		if ($x.Count -eq 0 -and $y.Count -eq 0) { continue }
		if ($x.Count -eq 0 -or $y.Count -eq 0) {
			throw [System.InvalidOperationException]::new(
				"${part}: $Source has $($x.Count) entries and $Destination has $($y.Count).")
		}
		$diff = @(Compare-Object -ReferenceObject $x -DifferenceObject $y)
		if ($diff.Count -gt 0) {
			$first = ((@($diff | Select-Object -First 5) |
					ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join "`n  ")
			throw [System.InvalidOperationException]::new(
				"the copy of $Source into $Destination does not match: " +
				"$($diff.Count) difference(s) in $part, the first of them:`n  $first")
		}
	}
	Write-OS7Step ("verified $($counted['Metadata']) entries, " +
		"$($counted['Sizes']) file sizes and $($counted['Links']) symlink targets")

	if ($SkipContent) {
		Write-OS7Step 'NOT CHECKED: file contents (-SkipContentVerify was given)'
		return
	}

	# NOT THROUGH Invoke-OS7Native, and this is the one place in the module that
	# says so. `diff -q` writes WHICH files differ to stdout and nothing to
	# stderr; Invoke-OS7Native carries only stderr into its exception, so going
	# through it would raise "diff exited 1" with the answer thrown away.
	#
	# --no-dereference, or two symlinks with different targets compare equal by
	# being read through, and a dangling one is an error rather than a
	# difference.
	Write-OS7Step "diff -r -q --no-dereference $Source $Destination"
	# Reset, then read guarded (BUILD-NOTES #121): a diff that never ran must
	# FAIL this verification — an unguarded read would hand it an earlier
	# command's 0 and pass a copy nothing compared.
	$global:LASTEXITCODE = $null
	$out = & diff -r -q --no-dereference $Source $Destination 2>&1
	$code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }
	if ($null -eq $code -or $code -ne 0) {
		$lines = (@($out | Select-Object -First 10) -join "`n  ")
		$how = if ($null -eq $code) { 'never completed' } else { "exited $code" }
		throw [System.InvalidOperationException]::new(
			"the contents of $Source and $Destination differ (diff " +
			"$how):`n  $lines")
	}
	Write-OS7Step 'verified every byte of every file'
}

# ---------------------------------------------------------------------------
# The read half
# ---------------------------------------------------------------------------

function Get-OS7Home {
	<#
	.SYNOPSIS
		Every home directory on this machine, and whether it has a dataset.

	.DESCRIPTION
		THE DIAGNOSTIC FOR BUILD-NOTES #74, and it answers the question twice
		from two independent places:

		  * ZFS is asked which dataset is mounted where          -> OwnDataset
		  * stat(2) is asked whether the path is on a different
		    filesystem from `/`                                  -> OwnFilesystem

		They should agree, and `Agrees` says whether they did. Where they do
		not, that fact is worth more than either answer on its own: a dataset
		ZFS believes is mounted and is not is a machine whose home is a
		directory in the boot environment that LOOKS covered.

		A directory here with no account behind it is almost certainly #74's
		other half — the empty `/home/os7` that `New-OS7Storage`'s old default
		created on every machine. It is reported, never removed: an empty
		dataset costs nothing, and destroying storage is an operator's decision.

	.PARAMETER UserName
		One account, found through getent. Without it, every directory under
		/home.

	.EXAMPLE
		Get-OS7Home | Format-Table Path, Account, Dataset, OwnDataset

	.EXAMPLE
		Get-OS7Home | Where-Object { -not $_.OwnDataset }
		The homes a rollback would take with the system.
	#>
	[CmdletBinding()]
	[OutputType('OS7.Home')]
	param([Parameter(Position = 0)][string]$UserName)

	Import-OS7ZfsLayer

	$mounted = @(Get-ZfsDataset -Type Filesystem -Recurse |
		Where-Object { $_.Mounted -and $_.Mountpoint })
	$rootDev = Get-OS7PathDeviceId -Path $script:OS7RootPath

	$paths = @()
	if ($UserName) {
		$named = Get-OS7Account -UserName $UserName
		if (-not $named) {
			throw [System.ArgumentException]::new(
				"getent knows no account called '$UserName'.", 'UserName')
		}
		$paths = @($named.Home)
	}
	elseif (Test-Path -LiteralPath $script:OS7HomeRoot) {
		$paths = @(Get-ChildItem -LiteralPath $script:OS7HomeRoot -Directory -Force |
			ForEach-Object { $_.FullName })
	}

	foreach ($path in $paths) {
		$account = Get-OS7Account -UserName $(
			if ($UserName) { $UserName } else { Split-Path -Leaf $path })
		# A home belongs to an account only if the ACCOUNT says so. A directory
		# called /home/bob that bob's passwd entry does not point at is not
		# bob's home, and migrating it would move something nothing reads.
		if ($account -and $account.Home -ne $path) { $account = $null }

		$owner = Get-OS7PathDataset -Path $path -Dataset $mounted
		$dataset = if ($owner) { $owner.Dataset } else { $null }
		$ownDataset = [bool]($owner -and $owner.Mountpoint -eq $path)

		$dev = Get-OS7PathDeviceId -Path $path
		$ownFs = [bool]($dev -and $rootDev -and $dev -ne $rootDev)

		[pscustomobject]@{
			PSTypeName    = 'OS7.Home'
			Path          = $path
			Account       = if ($account) { $account.Name } else { $null }
			Uid           = if ($account) { $account.Uid } else { $null }
			Dataset       = $dataset
			OwnDataset    = $ownDataset
			OwnFilesystem = $ownFs
			Agrees        = ($ownDataset -eq $ownFs)
			DeviceId      = $dev
			Note          = $(
				if ($ownDataset -ne $ownFs) {
					"ZFS AND stat(2) DISAGREE: zfs says own-dataset=$ownDataset, " +
					"st_dev says own-filesystem=$ownFs. Trust neither until that " +
					'is explained.'
				}
				elseif (-not $account) {
					'no account has this as its home' + $(
						if ($ownDataset) {
							" — an empty dataset at $path is what New-OS7Storage's " +
							"old -UserName default left on every machine (BUILD-NOTES #74)"
						}
						else { '' })
				}
				elseif (-not $ownDataset) {
					"inside $dataset — Restore-OS7 would roll this home back with the " +
					'system, and no snapshot policy can cover it. Move-OS7Home fixes it.'
				}
				else { 'on its own dataset, outside the boot environment' })
		}
	}
}

# ---------------------------------------------------------------------------
# The migration
# ---------------------------------------------------------------------------

function Move-OS7Home {
	<#
	.SYNOPSIS
		Move an existing home directory onto a USERDATA dataset of its own.

	.DESCRIPTION
		THE MIGRATION FOR MACHINES ALREADY INSTALLED (BUILD-NOTES #74). New
		installs need none of it: `os7-setup` passes `-UserName` to
		`New-OS7Storage` and the dataset exists before the account does.

		THE ORDER IS THE DESIGN. Each step is undone by the one that fails after
		it, and nothing is destroyed at all unless -RemoveOriginal:

		  1. refuse unless the account exists, its home is not already on a
		     dataset, ZFS and stat(2) agree about that, nobody is logged in as
		     it, and the pool has room for a second copy;
		  2. snapshot the dataset the home is currently INSIDE — the boot
		     environment — so the original survives even -RemoveOriginal;
		  3. create <pool>/USERDATA/<user>_<suffix> mounted on a STAGING path
		     under /run, never on /home/<user>: OpenZFS mounts over a non-empty
		     directory by default and would hide the files about to be copied;
		  4. copy with `cp -a`, then verify the copy against the original by
		     asking the filesystem — owner, mode, metadata, sizes, symlink
		     targets, and every byte unless -SkipContentVerify;
		  5. rename the original aside to <home>.os7-premigration-<stamp>;
		  6. set the dataset's mountpoint to the home, which remounts it there;
		  7. verify again at the final location, from ZFS and stat(2) both;
		  8. leave the renamed original in place, and print how to remove it.

		WHAT IT DOES NOT DO. It does not touch /etc/passwd — the home PATH does
		not change, only what is mounted at it. It does not migrate /root, which
		has been a dataset since the first install. It does not remove the empty
		`/home/os7` that #74 left behind; `Get-OS7Home` reports it.

		NEVER RUN AGAINST REAL ZFS. docs/BACKUP-PLAN.md B-6 is the gate, and
		until it passes this is code rather than a migration.

	.PARAMETER UserName
		The account whose home moves. Its passwd entry decides which directory
		that is — this never constructs /home/<name>.

	.PARAMETER RemoveOriginal
		Destroy the renamed original once the new dataset is verified in place.
		OFF by default: the copy is verified, but a machine that has just been
		through this should keep what it came from until somebody has logged in.
		The snapshot from step 2 holds it either way.

	.PARAMETER SkipContentVerify
		Compare owner, mode, metadata, sizes and symlink targets but not file
		contents. For a home too large to read twice. What was not checked is
		printed rather than passed over.

	.EXAMPLE
		Move-OS7Home -UserName os7admin -WhatIf
		Every step, in order, with nothing done.

	.EXAMPLE
		Get-OS7Home | Where-Object { $_.Account -and -not $_.OwnDataset }
		Move-OS7Home -UserName os7admin
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.Home.Migration')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$UserName,
		[switch]$RemoveOriginal,
		[switch]$SkipContentVerify
	)

	Import-OS7ZfsLayer

	$result = {
		param($migrated, $reason, $dataset, $homePath, $snapshot, $original, $dryRun)
		[pscustomobject]@{
			PSTypeName = 'OS7.Home.Migration'
			UserName   = $UserName
			Home       = $homePath
			Dataset    = $dataset
			Migrated   = [bool]$migrated
			Reason     = $reason
			Snapshot   = $snapshot
			Original   = $original
			DryRun     = [bool]$dryRun
		}
	}

	# -- 1. refuse, for reasons that name themselves ------------------------
	$account = Get-OS7Account -UserName $UserName
	if (-not $account) {
		throw [System.ArgumentException]::new(
			"getent knows no account called '$UserName', so it has no home to move.",
			'UserName')
	}
	$homePath = $account.Home
	if (-not $homePath -or $homePath -in @('/', '/root', '/nonexistent', '/dev/null')) {
		throw [System.InvalidOperationException]::new(
			"$UserName's home is '$homePath', which is not a home directory this moves.")
	}
	if (-not (Test-Path -LiteralPath $homePath -PathType Container)) {
		throw [System.InvalidOperationException]::new(
			"$UserName's home is $homePath and there is no such directory.")
	}

	$state = Get-OS7Home -UserName $UserName
	if (-not $state.Agrees) {
		throw [System.InvalidOperationException]::new(
			"ZFS and stat(2) disagree about $homePath. $($state.Note) " +
			'Nothing will be moved until that is explained.')
	}
	if ($state.OwnDataset) {
		Write-OS7Step "$homePath is already $($state.Dataset) — nothing to do"
		return & $result $false 'already on its own dataset' $state.Dataset $homePath `
			$null $null $false
	}

	$inside = $state.Dataset
	if (-not $inside) {
		throw [System.InvalidOperationException]::new(
			"$homePath is not on ZFS at all, so there is no pool to make a dataset in.")
	}
	$pool = $inside.Split('/')[0]

	# NOBODY LOGGED IN. Every probe runs, and the ones that could not answer are
	# named too — an operator reading "idle" needs to know which of three checks
	# said so.
	$probes = @(Test-OS7HomeIdle -UserName $UserName -Uid $account.Uid -Path $homePath)
	$busy = @($probes | Where-Object { $_.Available -and $_.Busy })
	if ($busy.Count -gt 0) {
		$what = (@($busy | ForEach-Object { "$($_.Probe): $($_.Detail)" }) -join '; ')
		throw [System.InvalidOperationException]::new(
			"$UserName is still using $homePath ($what). Log the account out — " +
			"loginctl terminate-user $UserName — and run this again.")
	}
	foreach ($p in $probes) {
		if ($p.Available) { Write-OS7Step "idle check, $($p.Probe): $($p.Detail)" }
		else { Write-OS7Step "NOT CHECKED: $($p.Probe) — $($p.Detail)" }
	}

	# ROOM. The apparent size against what the pool says is free. Compression
	# means this over-estimates, which is the safe direction: it can refuse a
	# migration that would have fitted, and it cannot allow one that will not.
	$needed = Get-OS7HomeUsage -Path $homePath
	$space = Get-ZfsSpace -Name $pool
	$available = if ($space) { $space.Available } else { $null }
	if ($null -eq $needed) {
		Write-OS7Step "NOT CHECKED: how large $homePath is — du could not say"
	}
	elseif ($null -eq $available) {
		Write-OS7Step "NOT CHECKED: how much room $pool has — zfs did not say"
	}
	elseif ($needed -gt $available) {
		throw [System.InvalidOperationException]::new(
			"$homePath holds $(Format-ZfsSize $needed) and $pool has " +
			"$(Format-ZfsSize $available) free. The copy has to exist beside the " +
			'original before the original is touched, so this will not fit.')
	}
	else {
		Write-OS7Step ("$homePath is $(Format-ZfsSize $needed); " +
			"$pool has $(Format-ZfsSize $available) free")
	}

	$stamp = (Get-Date).ToString('yyyyMMddHHmmss')
	$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
	$dataset = "$pool/USERDATA/${UserName}_$suffix"
	$staging = "$script:OS7HomeStagingRoot/$UserName.$suffix"
	$aside = "$homePath.os7-premigration-$stamp"
	$snapName = "os7-premigration-$UserName-$stamp"

	$dry = -not $PSCmdlet.ShouldProcess(
		$homePath, "move onto $dataset (snapshotting $inside first)")
	if ($dry) {
		# A SEPARATE BRANCH, not -WhatIf handed downwards — BUILD-NOTES #60.
		# PowerShell writes "What if:" to the HOST, and the host's output is
		# stdout; every other progress line in this module is stderr, and a dry
		# run that mixes the two is unreadable in a log.
		foreach ($line in @(
				"would snapshot $inside@$snapName",
				"would create $dataset, mounted at $staging",
				"would copy $homePath into $staging and verify it",
				"would rename $homePath to $aside",
				"would set $dataset's mountpoint to $homePath",
				"would verify $homePath is $dataset, from ZFS and from stat(2)",
				$(if ($RemoveOriginal) { "would then remove $aside" }
					else { "would LEAVE $aside in place" }))) {
			Write-OS7Step $line
		}
		return & $result $false 'dry run' $dataset $homePath "$inside@$snapName" $aside $true
	}

	# -- 2. the safety net, before anything changes -------------------------
	#
	# The home is INSIDE the boot environment, so this snapshots the boot
	# environment. Assert-OS7DatasetSafe refuses to put a snapshot POLICY on
	# rpool/ROOT and is right to; one deliberate snapshot is the opposite of a
	# policy, and it is the only thing that can bring these files back if
	# everything below turns out to be wrong.
	New-ZfsSnapshot -Name $inside -SnapshotName $snapName -Confirm:$false | Out-Null
	Write-OS7Step "snapshot $inside@$snapName taken"

	# -- 3. the dataset, mounted OUT OF THE WAY -----------------------------
	$container = "$pool/USERDATA"
	$haveContainer = $false
	try { $haveContainer = [bool](Get-ZfsDataset -Name $container) } catch { $haveContainer = $false }
	if (-not $haveContainer) {
		New-ZfsDataset -Name $container -Property ([ordered]@{
				canmount = 'off'; mountpoint = 'none' }) -Confirm:$false | Out-Null
		Write-OS7Step "created $container"
	}

	# The staging root, 0700 and owned by root: it holds a copy of somebody's
	# home for as long as the copy takes.
	New-Item -ItemType Directory -Force -Path $script:OS7HomeStagingRoot | Out-Null
	Invoke-OS7Native -Command chmod -Arguments @('0700', $script:OS7HomeStagingRoot) | Out-Null

	$created = $false
	try {
		New-ZfsDataset -Name $dataset -Property ([ordered]@{
				mountpoint = $staging }) -Confirm:$false | Out-Null
		$created = $true
		Write-OS7Step "created $dataset at $staging"

		if (-not (Test-Path -LiteralPath $staging -PathType Container)) {
			throw [System.InvalidOperationException]::new(
				"$dataset was created but nothing is mounted at $staging.")
		}
		$stageDev = Get-OS7PathDeviceId -Path $staging
		$rootDev = Get-OS7PathDeviceId -Path $script:OS7RootPath
		if (-not $stageDev -or $stageDev -eq $rootDev) {
			throw [System.InvalidOperationException]::new(
				"$staging is on the same filesystem as / (device $stageDev), so " +
				"$dataset is not mounted there and the copy would land in the " +
				'boot environment.')
		}
		if (@(Get-ChildItem -LiteralPath $staging -Force).Count -ne 0) {
			throw [System.InvalidOperationException]::new(
				"$staging is not empty before the copy has started.")
		}

		# The dataset's own root inode, which becomes the home's directory entry
		# once the mountpoint moves. --reference, so the home keeps exactly the
		# owner and mode it has now rather than one this file decided; `cp -a`
		# copies the CONTENTS and never the destination itself.
		Invoke-OS7Native -Command chown -Arguments @("--reference=$homePath", $staging) | Out-Null
		Invoke-OS7Native -Command chmod -Arguments @("--reference=$homePath", $staging) | Out-Null

		# -- 4. copy, then prove it ----------------------------------------
		Write-OS7Step "copying $homePath into $staging"
		Invoke-OS7Native -Command cp -Arguments @('-a', "$homePath/.", "$staging/") | Out-Null
		Compare-OS7Tree -Source $homePath -Destination $staging -SkipContent:$SkipContentVerify
	}
	catch {
		# NOTHING OF THE ORIGINAL HAS BEEN TOUCHED, so the whole of the cleanup
		# is to throw the copy away. The home is exactly as it was.
		if ($created) {
			Write-OS7Step "the copy failed; destroying $dataset and leaving $homePath alone"
			try { Remove-ZfsDataset -Name $dataset -Recurse -Confirm:$false }
			catch { Write-OS7Step "note: could not destroy $dataset — remove it by hand" }
		}
		throw
	}

	# -- 5, 6. the swap. From here a failure has to be undone ---------------
	$moved = $false
	try {
		Invoke-OS7Native -Command mv -Arguments @('--', $homePath, $aside) | Out-Null
		$moved = $true
		Write-OS7Step "renamed $homePath to $aside"

		# ZFS unmounts from the staging path and mounts at the home, creating
		# the mountpoint directory if it has to.
		Set-ZfsProperty -Name $dataset -PropertyName mountpoint -Value $homePath `
			-Confirm:$false | Out-Null
		Write-OS7Step "$dataset now mounts at $homePath"

		# -- 7. and prove THAT, from both sides ------------------------------
		$after = Get-OS7Home -UserName $UserName
		if (-not $after.OwnDataset -or $after.Dataset -ne $dataset) {
			throw [System.InvalidOperationException]::new(
				"after the move, ZFS says $homePath belongs to " +
				"'$($after.Dataset)' rather than to $dataset.")
		}
		if (-not $after.OwnFilesystem) {
			throw [System.InvalidOperationException]::new(
				"after the move, $homePath is still on the same filesystem as / " +
				"(device $($after.DeviceId)). ZFS says the dataset is mounted there " +
				'and stat(2) says it is not.')
		}
		# THE CONTENTS, AT THE FINAL LOCATION. Not because the copy was not
		# verified — it was — but because everything since then was a mount
		# operation, and a mount is exactly the thing that can make a verified
		# directory show something else.
		Compare-OS7Tree -Source $aside -Destination $homePath -SkipContent:$SkipContentVerify
	}
	catch {
		Write-OS7Step 'the swap failed; putting the original home back'
		try {
			Set-ZfsProperty -Name $dataset -PropertyName mountpoint -Value $staging `
				-Confirm:$false | Out-Null
		}
		catch { Write-OS7Step "note: $dataset could not be moved off $homePath" }
		if ($moved -and -not (Test-Path -LiteralPath $homePath)) {
			try { Invoke-OS7Native -Command mv -Arguments @('--', $aside, $homePath) | Out-Null }
			catch { Write-OS7Step "!!! $homePath could NOT be restored; it is at $aside" }
		}
		Write-OS7Step "the copy is still on $dataset and the snapshot is $inside@$snapName"
		throw
	}

	# -- 8. the original -----------------------------------------------------
	if ($RemoveOriginal) {
		Remove-Item -LiteralPath $aside -Recurse -Force
		Write-OS7Step "removed $aside — the snapshot $inside@$snapName still holds it"
		$aside = $null
	}
	else {
		Write-OS7Step "LEFT IN PLACE: $aside. Remove it once somebody has logged in:"
		Write-OS7Step "    rm -rf '$aside'"
	}

	Write-OS7Step "$homePath is now $dataset, outside the boot environment"
	& $result $true "moved out of $inside" $dataset $homePath "$inside@$snapName" $aside $false
}
