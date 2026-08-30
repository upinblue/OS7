# =============================================================================
# OS/7 Backup — targets and replication (docs/BACKUP-PLAN.md §5, §6)
#
# Dot-sourced by OS7.psm1.
#
# A snapshot is not a backup. It is on the same disk, in the same pool, and a
# dead controller takes it with everything it was protecting. What makes this a
# backup is the second copy, and that is what this file is: where the copies go,
# how they get there, and — the part that matters — how OS/7 knows they arrived.
#
# THE COPY IS MADE BY `syncoid`, which does incremental `zfs send | zfs receive`
# over ssh, resumes interrupted transfers, and works out the common snapshot to
# send from. It was measured before this was written and it has sharp edges that
# every caller has to handle, because syncoid handles none of them:
#
#   * NO LOCKING OF ANY KIND. Its only overlap guard is a `ps` grep for a
#     running `zfs receive` on the target. Two timers, or a timer and an
#     operator, will both start. OS/7 takes a lock.
#   * NO ssh HARDENING. No BatchMode, no ConnectTimeout, no
#     StrictHostKeyChecking — so an unknown host key becomes an interactive
#     prompt inside a systemd oneshot, which is a hang rather than a failure.
#     OS/7 passes all three through --sshoption.
#   * `zfs receive -F` BY DEFAULT, which ROLLS THE TARGET BACK to the most
#     recent common snapshot and discards anything newer there.
#   * EXIT 0 IS NOT PROOF. Sync-snapshot pruning, target-snapshot deletion and
#     hold release all only `warn`; the exit code is the worst outcome over all
#     datasets, and several post-transfer steps cannot reach it.
#   * It cannot tell "the target dataset does not exist yet" from "the backup
#     pool is not imported" — both make its existence check false, and it then
#     attempts a FULL send. On a 2 TB dataset over a domestic uplink that is not
#     a retry, it is a week.
#
# So OS/7 checks the target is really there BEFORE calling it, and asks the
# target's own ZFS afterwards whether the snapshot arrived.
# =============================================================================

# The GPT partition label a backup container gets. DELIBERATELY NOT `os7-luks`:
# that is the system disk's label, it is what ExistingInstall matches on to
# decide a disk holds an OS/7 installation, and a backup drive that answered to
# it would be offered as an upgrade candidate by Setup.
$script:OS7BackupPartLabel = 'os7-backup-luks'
$script:OS7BackupLuksLabel = 'OS7BACKUP'

# Where a backup pool is mounted when OS/7 imports it. Never `/`, and never a
# path the running system uses: a pool holding received copies of `/home/...`
# and `/var/log` whose datasets inherited a mountpoint would mount over the
# live ones.
$script:OS7BackupAltRoot = '/mnt/os7-backup'

# ---------------------------------------------------------------------------
# Which disk is which — the guard that stops this eating the system
# ---------------------------------------------------------------------------

function Get-OS7BaseDisk {
	<#
	.SYNOPSIS
		Internal. The whole disks underneath a block device, by kernel name.

	.DESCRIPTION
		Walks /sys downwards through device-mapper and partitions until it
		reaches devices that are neither. `/dev/mapper/os7_root` resolves to the
		LUKS container's partition, that partition to its disk — so asking
		"which disks is rpool on" has an answer even though rpool's vdev is a
		mapper node three layers up.

		-SysRoot exists so this is testable. The logic is a tree walk and the
		tree is a directory; pointing it at a fabricated one is how
		Test-OS7Backup checks the guard without a machine that has disks.

	.PARAMETER Device
		A device path, a /dev/disk/by-* symlink, or a bare kernel name.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Device,
		[string]$SysRoot = '/sys/class/block',
		[int]$Depth = 0
	)

	if ($Depth -gt 8) { return @() }      # a cycle in /sys would be a kernel bug; do not hang on it

	$kname = $Device
	if ($kname -like '*/*') {
		try {
			$item = Get-Item -LiteralPath $kname -Force -ErrorAction Stop
			if ($item.LinkTarget) { $kname = Split-Path -Leaf $item.LinkTarget }
			else { $kname = Split-Path -Leaf $kname }
		}
		catch { $kname = Split-Path -Leaf $kname }
	}

	$dir = Join-Path $SysRoot $kname
	if (-not (Test-Path -LiteralPath $dir)) { return @() }

	# device-mapper and md: the things it is built from.
	$slaves = Join-Path $dir 'slaves'
	if (Test-Path -LiteralPath $slaves) {
		$kids = @(Get-ChildItem -LiteralPath $slaves -Force -ErrorAction SilentlyContinue)
		if ($kids) {
			return @($kids | ForEach-Object {
					Get-OS7BaseDisk -Device $_.Name -SysRoot $SysRoot -Depth ($Depth + 1)
				} | Select-Object -Unique)
		}
	}

	# A partition's directory lives inside its disk's, and there are two ways to
	# ask which disk that is. BOTH are used, in this order, because each answers
	# where the other cannot:
	#
	#   1. /sys/class/block/sda1 is a SYMLINK into the device tree, and the
	#      parent of its target is the disk. That is how the real thing is built.
	#   2. Failing that, the disk whose own directory CONTAINS a subdirectory of
	#      this name. This works on the real /sys too — /sys/class/block/sda is a
	#      symlink to a directory that holds sda1 — and it is what makes the walk
	#      checkable against a fabricated tree on a filesystem where an
	#      unprivileged process cannot create symlinks at all.
	if (Test-Path -LiteralPath (Join-Path $dir 'partition')) {
		$parent = $null
		try {
			$resolved = (Get-Item -LiteralPath $dir -Force).Target
			if ($resolved) { $parent = Split-Path -Leaf (Split-Path -Parent $resolved) }
		}
		catch { }
		if ($parent -and $parent -ne 'block' -and
			(Test-Path -LiteralPath (Join-Path $SysRoot $parent))) {
			return @($parent)
		}

		foreach ($cand in @(Get-ChildItem -LiteralPath $SysRoot -Force -ErrorAction SilentlyContinue)) {
			if ($cand.Name -eq $kname) { continue }
			if (Test-Path -LiteralPath (Join-Path $cand.FullName $kname)) { return @($cand.Name) }
		}
	}

	return @($kname)
}

function Get-OS7SystemDisk {
	<#
	.SYNOPSIS
		Internal. Every whole disk an imported pool currently sits on.

	.DESCRIPTION
		Asked of ZFS, through Get-ZpoolStatus's vdev tree, and then resolved
		down to disks. This is the guard `New-Zpool` does not have: Layer 2
		validates a pool NAME and passes the device list through untouched, and
		`New-OS7Storage` already calls it with -Force, which is `zpool create
		-f` — the flag that defeats ZFS's own in-use check. Every device-level
		refusal in this product therefore has to be written here.
	#>
	[CmdletBinding()]
	param([string]$SysRoot = '/sys/class/block')

	Import-OS7ZfsLayer
	$disks = [System.Collections.Generic.HashSet[string]]::new()

	foreach ($v in @(Get-ZpoolStatus -Flat)) {
		if (-not $v.Path) { continue }
		foreach ($d in (Get-OS7BaseDisk -Device $v.Path -SysRoot $SysRoot)) {
			[void]$disks.Add($d)
		}
	}
	return @($disks)
}

function Assert-OS7BackupDiskSafe {
	<#
	.SYNOPSIS
		Internal. Refuse a disk that is not free to be destroyed.

	.DESCRIPTION
		`New-OS7BackupTarget -CreateOn` writes a partition table. Everything
		below is a reason not to, and each was chosen because it is a state the
		machine can actually be in:

		  the disk carries an imported pool     rpool and bpool live here
		  the disk carries an OS/7 partlabel    an OS/7 install, mounted or not
		  the device is a partition             `-CreateOn` takes a whole disk;
		                                        a partition path here almost
		                                        always means the wrong device
		  the device does not exist             a by-id path that has gone away
		                                        while the operator typed

		THE INSTALLER'S OWN GUARD DOES NOT WORK HERE and it is worth saying why,
		because reusing it would look right: the spike compares
		`findmnt -no SOURCE /` with the target device, and on an installed OS/7
		that SOURCE is a DATASET NAME — `rpool/ROOT/os7_…` — which equals no
		device path that was ever typed.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Device,
		[string]$SysRoot = '/sys/class/block'
	)

	if (-not (Test-Path -LiteralPath $Device)) {
		throw [System.IO.FileNotFoundException]::new(
			"'$Device' does not exist. Name a whole disk — /dev/disk/by-id/... is the " +
			'form that stays the same across reboots.')
	}

	$bases = @(Get-OS7BaseDisk -Device $Device -SysRoot $SysRoot)
	$kname = if ($bases.Count -eq 1) { $bases[0] } else { $null }
	if (-not $kname) {
		throw [ArgumentException]::new(
			"'$Device' does not resolve to exactly one whole disk (it resolves to " +
			(($bases -join ', ')) + '). -CreateOn takes one whole disk.')
	}

	# A partition resolves to its parent, so a partition path and its disk both
	# resolve to the same name. Comparing the two is what tells them apart.
	$self = $Device
	try {
		$i = Get-Item -LiteralPath $Device -Force -ErrorAction Stop
		if ($i.LinkTarget) { $self = Split-Path -Leaf $i.LinkTarget } else { $self = Split-Path -Leaf $Device }
	}
	catch { $self = Split-Path -Leaf $Device }
	if ($self -ne $kname) {
		throw [ArgumentException]::new(
			"'$Device' is a partition of $kname, not a whole disk. -CreateOn repartitions " +
			'the whole device, so it takes the disk.')
	}

	$system = @(Get-OS7SystemDisk -SysRoot $SysRoot)
	if ($kname -in $system) {
		throw [System.InvalidOperationException]::new(
			"$kname carries an imported ZFS pool. That is this machine's own storage — " +
			'refusing to repartition it. If this really is a spare disk, export the pool ' +
			'that is on it first.')
	}

	# An OS/7 install that is not imported is still an OS/7 install.
	foreach ($label in @('os7-esp', 'os7-bpool', 'os7-luks')) {
		$p = "/dev/disk/by-partlabel/$label"
		if (-not (Test-Path -LiteralPath $p)) { continue }
		if ((Get-OS7BaseDisk -Device $p -SysRoot $SysRoot) -contains $kname) {
			throw [System.InvalidOperationException]::new(
				"$kname holds an OS/7 installation (it has a '$label' partition). " +
				'Refusing to repartition it, imported or not.')
		}
	}
}

# ---------------------------------------------------------------------------
# Targets — reading and writing the list
# ---------------------------------------------------------------------------

function Get-OS7BackupTargetRaw {
	<#
	.SYNOPSIS
		Internal. The targets array as it is on disk, or an empty array.
	#>
	if (-not (Test-Path -LiteralPath $script:OS7BackupConfig -PathType Leaf)) { return @() }
	$doc = Get-Content -Raw -LiteralPath $script:OS7BackupConfig | ConvertFrom-Json
	if ($doc.PSObject.Properties.Name -notcontains 'targets') { return @() }
	return @($doc.targets)
}

function Get-OS7BackupTarget {
	<#
	.SYNOPSIS
		Where copies go, and what is actually there.

	.DESCRIPTION
		Every field below the configured ones is measured, not remembered:

		  Present            the pool is imported here, or the remote host
		                     answers a `zpool list`
		  Health             from `zpool status`, on the TARGET
		  Errors             read + write + checksum, summed over every vdev
		  NewestReplicated   the creation time of the newest snapshot ON THE
		                     TARGET, which is a statement by the receiving
		                     pool rather than by the sending program
		  InSync             the newest snapshot on the target has the same
		                     ZFS GUID as one on the source

		InSync IS THE ONE THAT MATTERS. A target can hold a fresh-looking
		snapshot that is not the one this machine sent — a second machine
		replicating into the same dataset, or a restore that was never cleaned
		up. A GUID is ZFS's own identity for a snapshot and it survives
		send/receive, so comparing GUIDs answers "is my data over there" rather
		than "is something over there".

	.PARAMETER Name
		One target. Without it, all of them.

	.PARAMETER SkipProbe
		Do not contact anything. The configuration only.

	.EXAMPLE
		Get-OS7BackupTarget | Format-Table Name, Kind, Present, InSync, NewestReplicated
	#>
	[CmdletBinding()]
	[OutputType('OS7.Backup.Target')]
	param(
		[Parameter(Position = 0)][string]$Name,
		[switch]$SkipProbe
	)

	Import-OS7ZfsLayer
	$policy = $null

	foreach ($t in Get-OS7BackupTargetRaw) {
		if ($Name -and [string]$t.name -ne $Name) { continue }

		$obj = [pscustomobject]@{
			PSTypeName       = 'OS7.Backup.Target'
			Name             = [string]$t.name
			Kind             = [string]$t.kind
			Host             = if ($t.PSObject.Properties.Name -contains 'host') { [string]$t.host } else { $null }
			Dataset          = [string]$t.dataset
			Pool             = ([string]$t.dataset).Split('/')[0]
			SshKey           = if ($t.PSObject.Properties.Name -contains 'sshKey') { [string]$t.sshKey } else { $null }
			Enabled          = [bool]$t.enabled
			Present          = $false
			Health           = $null
			Errors           = $null
			FreeBytes        = $null
			NewestReplicated = $null
			InSync           = $false
			Note             = $null
		}

		if (-not $SkipProbe) {
			$remote = @{}
			if ($obj.Kind -eq 'Remote') {
				$remote['ComputerName'] = $obj.Host
				if ($obj.SshKey) { $remote['SshArgument'] = @('-i', $obj.SshKey) }
			}

			try {
				$pool = Get-Zpool -Name $obj.Pool @remote
				if ($pool) {
					$obj.Present = $true
					$obj.Health = [string]$pool.Health
					$obj.FreeBytes = $pool.Free
				}
			}
			catch {
				$obj.Note = "could not reach $($obj.Pool): $($_.Exception.Message.Split("`n")[0])"
			}

			if ($obj.Present) {
				try {
					$errs = 0
					foreach ($v in @(Get-ZpoolStatus -Name $obj.Pool -Flat @remote)) {
						foreach ($f in @('ReadErrors', 'WriteErrors', 'ChecksumErrors')) {
							if ($v.PSObject.Properties.Name -contains $f -and $null -ne $v.$f) {
								$errs += [int]$v.$f
							}
						}
					}
					$obj.Errors = $errs
				}
				catch { }

				try {
					$there = @(Get-ZfsSnapshot -Name $obj.Dataset @remote | Sort-Object Creation)
					$newest = $there | Select-Object -Last 1
					if ($newest) {
						$obj.NewestReplicated = $newest.Creation

						# The GUID comparison. Asked of both sides, never
						# inferred from a name: syncoid stamps its sync
						# snapshots with LOCAL time plus a GMT offset while
						# sanoid's units force TZ=UTC, so two clocks appear in
						# one machine's snapshot names and neither is safe to
						# subtract from the other.
						$theirGuid = Get-OS7ZfsPropertyValue -Name $newest.Name -Property 'guid' -Remote $remote
						if ($theirGuid) {
							if (-not $policy) { $policy = Get-OS7BackupPolicy }
							$mine = @(foreach ($s in $policy.Sources) {
									if ($s.PSObject.Properties.Name -contains 'Datasets' -and $s.Datasets) {
										Get-ZfsSnapshot -Name $s.Datasets
									}
								})
							foreach ($m in $mine) {
								$g = Get-OS7ZfsPropertyValue -Name $m.Name -Property 'guid'
								if ($g -and [string]$g -eq [string]$theirGuid) { $obj.InSync = $true; break }
							}
						}
					}
				}
				catch {
					$obj.Note = "the pool answered and $($obj.Dataset) did not: " +
					$_.Exception.Message.Split("`n")[0]
				}
			}
		}

		$obj
	}
}

function New-OS7BackupTarget {
	<#
	.SYNOPSIS
		Define where backups go — and, with -CreateOn, build it.

	.DESCRIPTION
		Three shapes, and the difference is only where the pool is:

		  -Pool <name>                  a second pool already on this machine
		  -ComputerName user@host       another machine, over ssh
		  -CreateOn <disk>              a whole disk, which this will PARTITION,
		                                ENCRYPT with LUKS2 and make a pool on

		-CreateOn IS DESTRUCTIVE and everything about it is deliberate:

		LUKS2, not ZFS native encryption. Not a preference — DECISIONS locks
		`dm-crypt` because Intune recognises nothing else, and it explicitly
		forbids also turning on ZFS native encryption. The consequence lands
		here: a `zfs send` from a LUKS-backed pool is a PLAINTEXT stream. It is
		protected in flight by ssh and at rest by the target's own encryption,
		and if the target has none then the copy is unencrypted. That is why the
		container is created rather than the bare pool.

		The PBKDF cost is pinned to the same figures the installer uses —
		argon2id, 524288, parallel 2, 2000 ms — so that unlocking this drive
		costs what unlocking the system disk costs and a machine that can boot
		can also open its backup.

		THE POOL IS CREATED WITH cachefile=none, AND THAT IS THE MOST IMPORTANT
		FLAG ON THIS PAGE. Both of OS/7's own pools are created with
		`cachefile=/etc/zfs/zpool.cache` precisely so `zfs-import-cache` imports
		them at boot without scanning. A REMOVABLE pool in that cache is one the
		boot path tries to import on every start with the drive absent. Keeping
		the backup pool out of the cache is also what turns a hostid mismatch —
		the footgun that drops a ZFS-root machine into the initramfs — into a
		message on a running system.

		AND WITH mountpoint=none. A backup pool holds received copies of
		/home/... and /var/log. A dataset that arrives with a mountpoint and
		`canmount=on` mounts over the live one.

	.PARAMETER Name
		What to call this target.

	.PARAMETER Pool
		An existing local pool to send into.

	.PARAMETER ComputerName
		user@host for a remote target.

	.PARAMETER Dataset
		The dataset on the target that receives. Defaults to
		<pool>/os7/<hostname>, so two machines can share one target pool.

	.PARAMETER CreateOn
		A whole disk to partition, encrypt and make a pool on. Destructive.

	.PARAMETER Passphrase
		The LUKS2 passphrase for -CreateOn. Prompted for if not given.

	.PARAMETER SshKey
		Private key for a remote target.

	.EXAMPLE
		New-OS7BackupTarget -Name nas -ComputerName backup@nas.lan -Dataset tank/os7

	.EXAMPLE
		New-OS7BackupTarget -Name usb -CreateOn /dev/disk/by-id/usb-Samsung_T7_0001
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Pool')]
	[OutputType('OS7.Backup.Target')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,

		[Parameter(ParameterSetName = 'Pool', Mandatory)][string]$Pool,
		[Parameter(ParameterSetName = 'Remote', Mandatory)][string]$ComputerName,
		[Parameter(ParameterSetName = 'Create', Mandatory)][string]$CreateOn,

		[Parameter()][string]$Dataset,
		[Parameter(ParameterSetName = 'Create', Mandatory)][string]$ConfirmDisk,
		[Parameter(ParameterSetName = 'Create')][securestring]$Passphrase,
		[Parameter(ParameterSetName = 'Create')][string]$PoolName = 'os7backup',
		[Parameter(ParameterSetName = 'Remote')][string]$SshKey,
		[switch]$Enabled = $true
	)

	Import-OS7ZfsLayer

	if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
		throw [ArgumentException]::new(
			"'$Name' is not a usable target name. Letters, digits, dot, dash and " +
			'underscore; it appears in log lines and in `syncoid --identifier`.')
	}
	if (@(Get-OS7BackupTargetRaw | Where-Object { [string]$_.name -eq $Name })) {
		throw [System.InvalidOperationException]::new(
			"a target called '$Name' already exists. Remove-OS7BackupTarget first.")
	}

	$kind = switch ($PSCmdlet.ParameterSetName) {
		'Remote' { 'Remote' }
		default { 'LocalPool' }
	}
	# $targetPool AND NOT $poolName — BUILD-NOTES #65.
	#
	# `$poolName` IS the `-PoolName` parameter: PowerShell variable names are
	# case-insensitive. This worked, and only by the order things happen in: the
	# switch's branches are evaluated before the assignment lands, so the
	# 'Create' branch read the parameter's own value and the assignment was a
	# no-op — while the 'Remote' branch quietly set the [string] parameter to ''.
	# One reordered branch, or one new branch that read $PoolName after another
	# had written it, and it would have stopped working with an error naming
	# neither. Found 2026-08-27 by installer/testing/check-ps-traps.py,
	# which was written after the same shape cost an afternoon in Update-OS7.
	$targetPool = switch ($PSCmdlet.ParameterSetName) {
		'Pool' { $Pool }
		'Create' { $PoolName }
		default { $null }
	}

	if ($PSCmdlet.ParameterSetName -eq 'Create') {
		Assert-OS7BackupDiskSafe -Device $CreateOn

		# -ConfirmDisk IS NOT -Confirm, AND THAT IS THE POINT. `-Confirm:$false`
		# in a script is the PowerShell equivalent of pressing ENTER by
		# momentum, and this operation erases a disk. Setup solves the same
		# problem by making the destructive key F rather than ENTER
		# (ConfirmScreen), and by re-asking when the selection changes — "a
		# confirmation that survives changing what is being confirmed is not a
		# confirmation". Here the operator has to type the disk's own identity,
		# so no default and no automation setting can supply it.
		$want = $CreateOn.Trim()
		$given = $ConfirmDisk.Trim()
		$serial = $null
		try {
			$serial = (Get-Content -Raw -ErrorAction Stop `
				(Join-Path (Join-Path '/sys/class/block' (Split-Path -Leaf $CreateOn)) 'device/serial')).Trim()
		}
		catch { }
		if ($given -ne $want -and (-not $serial -or $given -ne $serial)) {
			throw [ArgumentException]::new(
				"-ConfirmDisk does not name the disk being erased. Pass -ConfirmDisk " +
				"'$want'" + $(if ($serial) { " (or its serial, '$serial')" } else { '' }) +
				'. This is deliberately something -Confirm:$false cannot answer: the ' +
				'command erases a whole disk.')
		}

		if (-not $PSCmdlet.ShouldProcess($CreateOn,
				"ERASE this disk, put LUKS2 on it and create the pool '$targetPool'")) {
			return
		}
		New-OS7BackupPool -Device $CreateOn -PoolName $targetPool -Passphrase $Passphrase
	}

	if (-not $Dataset) {
		$hostname = [System.Net.Dns]::GetHostName()
		$safe = $hostname -replace '[^0-9A-Za-z._-]', '-'
		$Dataset = if ($kind -eq 'Remote') { "os7/$safe" } else { "$targetPool/os7/$safe" }
	}

	if ($kind -eq 'LocalPool') {
		# A local target on this machine's own pools is not a backup, it is a
		# second copy of the same failure.
		if ($Dataset -like 'rpool/*' -or $Dataset -like 'bpool/*') {
			throw [System.InvalidOperationException]::new(
				"'$Dataset' is on one of this machine's own pools. A copy that shares a " +
				'disk with the original survives none of the things a backup exists for. ' +
				'Use a second pool, an external drive, or a remote host.')
		}
	}

	$entry = [ordered]@{
		name    = $Name
		kind    = $kind
		dataset = $Dataset
		enabled = [bool]$Enabled
	}
	if ($kind -eq 'Remote') {
		$entry['host'] = $ComputerName
		if ($SshKey) { $entry['sshKey'] = $SshKey }
	}

	if (-not $PSCmdlet.ShouldProcess($script:OS7BackupConfig, "add the target '$Name'")) { return }

	$doc = if (Test-Path -LiteralPath $script:OS7BackupConfig) {
		$raw = Get-Content -Raw -LiteralPath $script:OS7BackupConfig | ConvertFrom-Json
		$o = [ordered]@{}
		foreach ($p in $raw.PSObject.Properties) { $o[$p.Name] = $p.Value }
		$o
	}
	else {
		# A target defined before a policy is a reasonable order to do things in,
		# so this writes the default policy rather than refusing.
		Set-OS7BackupPolicy -Confirm:$false | Out-Null
		$raw = Get-Content -Raw -LiteralPath $script:OS7BackupConfig | ConvertFrom-Json
		$o = [ordered]@{}
		foreach ($p in $raw.PSObject.Properties) { $o[$p.Name] = $p.Value }
		$o
	}

	$doc['targets'] = @(@(Get-OS7BackupTargetRaw) + $entry)
	New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:OS7BackupConfig) | Out-Null
	Write-OS7BackupConfig -Document $doc

	Write-OS7BackupLog "target added: $Name ($kind -> $Dataset)"
	Get-OS7BackupTarget -Name $Name
}

function New-OS7BackupPool {
	<#
	.SYNOPSIS
		Internal. Partition, encrypt and create a pool on a whole disk.

	.DESCRIPTION
		The installer's sequence with everything a bootable disk needs taken
		out: no ESP, because nothing boots from this; no boot pool, because
		there is no kernel on it; no bootloader; and no `initramfs` keyword
		anywhere near crypttab, which would put an absent removable device on
		the boot path.

		Ordered exactly as StorageSteps orders it, and for the same reasons:
		labels cleared before the table is written, the table written by GPT
		name so the partition is addressed by something stable, and the device
		waited for rather than assumed to appear.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Device,
		[Parameter(Mandatory)][string]$PoolName,
		[securestring]$Passphrase
	)

	if (-not $Passphrase) {
		$Passphrase = Read-Host -AsSecureString -Prompt `
			"Passphrase for the backup drive $Device"
	}
	$plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
		[System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase))
	if ([string]::IsNullOrWhiteSpace($plain)) {
		throw [ArgumentException]::new('an empty passphrase is not a passphrase')
	}

	$part = "/dev/disk/by-partlabel/$($script:OS7BackupPartLabel)"
	$mapper = "os7_backup_$PoolName"
	$keyfile = "/run/os7-backup.key"

	try {
		# Stale labels, on the disk and on every partition it currently has. A
		# reused disk that still carries one makes `zpool create` refuse or, far
		# worse, lets an import resurrect a pool nobody asked for.
		try { Clear-ZpoolLabel -Device $Device -Force -Confirm:$false | Out-Null } catch { }
		foreach ($p in @(Get-ChildItem -LiteralPath (Join-Path '/sys/class/block' (Split-Path -Leaf $Device)) `
					-Filter ((Split-Path -Leaf $Device) + '*') -Directory -ErrorAction SilentlyContinue)) {
			try { Clear-ZpoolLabel -Device "/dev/$($p.Name)" -Force -Confirm:$false | Out-Null } catch { }
		}

		Invoke-OS7Native -Command 'wipefs' -Arguments @('-a', $Device) | Out-Null
		Invoke-OS7Native -Command 'sgdisk' -Arguments @('--zap-all', $Device) | Out-Null
		Invoke-OS7Native -Command 'sgdisk' -Arguments @(
			'-n1:1M:0', '-t1:8309', "-c1:$($script:OS7BackupPartLabel)", $Device) | Out-Null
		try { Invoke-OS7Native -Command 'partprobe' -Arguments @($Device) | Out-Null } catch { }
		try { Invoke-OS7Native -Command 'udevadm' -Arguments @('settle') | Out-Null } catch { }

		$deadline = (Get-Date).AddSeconds(30)
		while (-not (Test-Path -LiteralPath $part) -and (Get-Date) -lt $deadline) {
			Start-Sleep -Milliseconds 500
		}
		if (-not (Test-Path -LiteralPath $part)) {
			throw [System.IO.IOException]::new(
				"the disk was partitioned and $part did not appear within 30 seconds.")
		}

		# NO TRAILING NEWLINE, and this is the bug that only shows up the second
		# time the drive is plugged in: `luksFormat` consumes the keyfile
		# verbatim while an interactive prompt strips the newline, so a file
		# written with anything that appends one means the passphrase typed here
		# is not the one that opens it later. Set-Content, Out-File and `>` all
		# append one; WriteAllBytes does not. Spike S3 learned this on the
		# system disk and the lesson does not become untrue on a removable one.
		[System.IO.File]::WriteAllBytes($keyfile,
			[System.Text.UTF8Encoding]::new($false).GetBytes($plain))
		try {
			(Get-Item -LiteralPath $keyfile -Force).UnixFileMode =
			[System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
		}
		catch { }

		Invoke-OS7Native -Command 'cryptsetup' -Arguments @(
			'luksFormat', $part, $keyfile,
			'--type', 'luks2', '--batch-mode',
			'--label', $script:OS7BackupLuksLabel,
			'--pbkdf', 'argon2id', '--pbkdf-memory', '524288',
			'--pbkdf-parallel', '2', '--iter-time', '2000') | Out-Null

		# THE ACCEPTANCE TEST IS AN UNLOCK, not luksFormat's exit code. This is
		# the same check installer/testing/run-phase2.py makes after an install,
		# and it is the only thing that proves the passphrase the operator typed
		# is the one in the header.
		Invoke-OS7Native -Command 'cryptsetup' -Arguments @(
			'open', '--test-passphrase', '--key-file', $keyfile, $part) | Out-Null
		Write-OS7Step 'the passphrase was verified against the LUKS2 header'

		Invoke-OS7Native -Command 'cryptsetup' -Arguments @(
			'open', '--key-file', $keyfile, '--allow-discards', '--persistent',
			$part, $mapper) | Out-Null
	}
	finally {
		Remove-Item -Force -ErrorAction SilentlyContinue $keyfile
		$plain = $null
	}

	New-Zpool -Name $PoolName -Device "/dev/mapper/$mapper" -Force -Property ([ordered]@{
			ashift    = 12
			autotrim  = 'on'
			# NOT /etc/zfs/zpool.cache. See the .DESCRIPTION on
			# New-OS7BackupTarget: a removable pool in the cache is one the boot
			# path tries to import with the drive absent.
			cachefile = 'none'
		}) -FilesystemProperty ([ordered]@{
			# The same two as rpool, and for the same reason: a restore has to
			# be able to put back the ACLs and extended attributes it took, and
			# a received dataset inherits these from the pool root.
			acltype       = 'posixacl'
			xattr         = 'sa'
			# zstd rather than rpool's lz4: nothing here has to be readable by
			# GRUB, so the `compatibility=grub2` feature restriction that forces
			# lz4 on bpool does not apply, and a backup pool is the one place
			# where CPU is cheaper than space.
			compression   = 'zstd'
			normalization = 'formD'
			relatime      = 'on'
			canmount      = 'off'
			mountpoint    = 'none'
		}) -AltRoot $script:OS7BackupAltRoot -Confirm:$false | Out-Null

	Write-OS7Step "created the backup pool $PoolName on $Device"
	Write-OS7BackupLog "created backup pool $PoolName on $Device (LUKS2, cachefile=none)"
}

function Remove-OS7BackupTarget {
	<#
	.SYNOPSIS
		Forget a target. Destroys nothing on it.

	.DESCRIPTION
		Removes the entry and cleans up what replication left on THIS machine:
		the `syncoid_*` snapshots that syncoid takes on the source to have a
		common base with. Those are the reason this is a verb rather than an
		edit of a JSON file — syncoid removes the previous one only on its next
		successful run, so a target that is forgotten leaves its sync snapshots
		behind forever, and forever is what "back to bash" means here.

		The data on the target is not touched. A backup that is deleted by the
		command that stops using it is a backup that can be lost by a typo.

	.PARAMETER Name
		The target.

	.PARAMETER KeepSyncSnapshots
		Leave the syncoid_* snapshots on the source alone.

	.EXAMPLE
		Remove-OS7BackupTarget usb
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[switch]$KeepSyncSnapshots
	)

	$targets = @(Get-OS7BackupTargetRaw)
	$match = @($targets | Where-Object { [string]$_.name -eq $Name })
	if (-not $match) {
		throw [System.InvalidOperationException]::new("no target called '$Name'")
	}

	if (-not $PSCmdlet.ShouldProcess($Name, 'stop backing up to this target')) { return }

	if (-not $KeepSyncSnapshots) {
		Import-OS7ZfsLayer
		$policy = Get-OS7BackupPolicy
		foreach ($s in $policy.Sources) {
			if (-not $s.Datasets) { continue }
			foreach ($snap in @(Get-ZfsSnapshot -Name $s.Datasets |
					Where-Object { $_.SnapshotName -like "syncoid_$Name*" -or
						$_.SnapshotName -like 'syncoid_*' })) {
				try {
					Remove-ZfsSnapshot -Name $snap.Name -Confirm:$false
					Write-OS7Step "removed $($snap.Name)"
				}
				catch { Write-OS7Step "note: could not remove $($snap.Name) — $($_.Exception.Message.Split("`n")[0])" }
			}
		}
	}

	$doc = Get-Content -Raw -LiteralPath $script:OS7BackupConfig | ConvertFrom-Json
	$o = [ordered]@{}
	foreach ($p in $doc.PSObject.Properties) { $o[$p.Name] = $p.Value }
	$o['targets'] = @($targets | Where-Object { [string]$_.name -ne $Name })
	Write-OS7BackupConfig -Document $o

	Write-OS7BackupLog "target removed: $Name (data on the target was NOT touched)"
	Write-OS7Step "'$Name' is no longer a target. Nothing on it was deleted."
}

function Test-OS7BackupTarget {
	<#
	.SYNOPSIS
		Is this target reachable, healthy, and holding what it should?

	.DESCRIPTION
		The pre-flight `Start-OS7BackupReplication` runs and an operator can run
		by hand. Every check is a question asked of the target, and each one has
		a failure it exists to catch:

		  reachable       syncoid cannot tell "not created yet" from "pool not
		                  imported" and responds to both by attempting a FULL
		                  send. Finding out first is the difference between a
		                  clear error and a week of uplink.
		  pool health     a DEGRADED backup pool is still a backup, and still
		                  worth knowing about before it is the only copy.
		  error counters  read/write/checksum, summed. Nonzero means the copy
		                  is being read back wrong.
		  free space      a target that cannot take the next increment.
		  encryption      whether the target sits on dm-crypt. LUKS-under-ZFS
		                  means the stream OS/7 sends is PLAINTEXT, so the
		                  target's own encryption is the only thing protecting
		                  the copy at rest.

		The encryption answer is honest about its own limits: on a remote host
		it is what that host reports about itself, and a machine that lies about
		its disks is outside what any check here can see.

	.EXAMPLE
		Test-OS7BackupTarget usb
	#>
	[CmdletBinding()]
	[OutputType('OS7.Backup.TargetTest')]
	param([Parameter(Position = 0)][string]$Name)

	foreach ($t in @(Get-OS7BackupTarget -Name $Name)) {
		$problems = [System.Collections.Generic.List[string]]::new()

		if (-not $t.Present) { $problems.Add("not reachable: $($t.Note)") }
		else {
			if ($t.Health -and $t.Health -ne 'ONLINE') { $problems.Add("pool health is $($t.Health)") }
			if ($t.Errors -and $t.Errors -gt 0) { $problems.Add("$($t.Errors) I/O or checksum error(s)") }
			if ($null -ne $t.FreeBytes -and $t.FreeBytes -lt 1GB) {
				$problems.Add("only $(Format-ZfsSize $t.FreeBytes) free")
			}
			if (-not $t.NewestReplicated) { $problems.Add('nothing has been replicated here yet') }
			elseif (-not $t.InSync) {
				$problems.Add('the newest snapshot on the target is not one of this ' +
					"machine's — the GUIDs do not match")
			}
		}

		[pscustomobject]@{
			PSTypeName = 'OS7.Backup.TargetTest'
			Name       = $t.Name
			Kind       = $t.Kind
			Present    = $t.Present
			Health     = $t.Health
			Errors     = $t.Errors
			FreeBytes  = $t.FreeBytes
			InSync     = $t.InSync
			Ok         = ($problems.Count -eq 0)
			Problems   = @($problems)
		}
	}
}

# ---------------------------------------------------------------------------
# Replication
# ---------------------------------------------------------------------------

function Get-OS7SyncoidArgument {
	<#
	.SYNOPSIS
		Internal. Every syncoid option OS/7 passes, and nothing else.

	.DESCRIPTION
		SEPARATE FROM THE FUNCTION THAT RUNS IT, so it can be tested without a
		target, a network or a pool. On this program the command line is most of
		the risk: two flags are the difference between a safe receive and one
		that mounts a copy of /home over the live one, and one more is the
		difference between a resumable increment and a full send.

		WHAT IS PASSED

		  --recursive         one call per source, whole subtree
		  --skip-parent       for a container. rpool/USERDATA is canmount=off
		                      with nothing in it; sending it makes an empty
		                      dataset on the target
		  --recvoptions=u     `zfs receive -u` — DO NOT MOUNT what arrives.
		                      syncoid never passes -u by default, and what is
		                      arriving are copies of /home/... and /var/log
		  --identifier=<name> the target's name goes into the sync snapshot's
		                      name, so two targets do not fight over one
		  --compress=none     local only: no ssh, nothing to compress across,
		                      and syncoid probes for a compressor regardless
		  --sshoption ...     BatchMode, ConnectTimeout, StrictHostKeyChecking.
		                      syncoid sets NONE of these, so an unknown host key
		                      becomes an interactive prompt inside a systemd
		                      oneshot — a hang, not a failure

		WHAT IS DELIBERATELY NOT PASSED, each with the reason, because the next
		person to read this will wonder about exactly these six:

		  --quiet             it silences every WARN, and the WARNs are where
		                      partial failure lives: sync-snapshot pruning,
		                      target-snapshot deletion and hold release all only
		                      warn and never reach the exit code
		  --no-sync-snap      syncoid's own `syncoid_*` snapshot is the ONE
		                      common base retention cannot remove — sanoid
		                      destroys only names beginning `autosnap`.
		                      Replicating policy snapshots alone would make the
		                      incremental base something the pruner may delete,
		                      and the next run a full send
		  --use-hold          it leaves a ZFS hold released only by the NEXT
		                      successful run, so a forgotten target leaves a
		                      snapshot that cannot be destroyed without
		                      `zfs release` — which is bash
		  --preserve-properties
		                      it does not exclude `mountpoint` or `canmount`,
		                      so it pushes OS/7's local mountpoints onto the
		                      target's datasets
		  --force-delete      it destroys the target dataset recursively when no
		                      common snapshot is found. An operator decides
		                      that; a timer does not
		  --no-stream         it switches `zfs send -I` to `-i`, which sends
		                      only the newest snapshot and drops everything in
		                      between. The intermediates ARE the history this
		                      feature is for
	#>
	[CmdletBinding()]
	[OutputType([string[]])]
	param(
		[Parameter(Mandatory)][ValidateSet('LocalPool', 'Remote')][string]$TargetKind,
		[Parameter(Mandatory)][string]$TargetName,
		[Parameter()][bool]$ChildrenOnly,
		[Parameter()][string]$SshKey
	)

	$a = [System.Collections.Generic.List[string]]::new()
	$a.Add('--recursive')
	if ($ChildrenOnly) { $a.Add('--skip-parent') }
	$a.Add('--recvoptions=u')
	$a.Add("--identifier=$TargetName")

	if ($TargetKind -eq 'LocalPool') { $a.Add('--compress=none') }
	else {
		foreach ($o in @('BatchMode=yes', 'ConnectTimeout=10', 'StrictHostKeyChecking=yes')) {
			$a.Add('--sshoption'); $a.Add($o)
		}
		if ($SshKey) { $a.Add("--sshkey=$SshKey") }
	}
	return @($a)
}

function Start-OS7BackupReplication {
	<#
	.SYNOPSIS
		Send this machine's snapshots to its targets, and check they arrived.

	.DESCRIPTION
		WHAT IS PASSED TO syncoid, AND WHY EACH:

		  --recursive             one call per source, whole subtree
		  --skip-parent           the USERDATA container is canmount=off with
		                          nothing in it; sending it makes an empty
		                          dataset on the target
		  --recvoptions=u         `zfs receive -u`: DO NOT MOUNT what arrives.
		                          syncoid never passes -u by default, and the
		                          things being received are copies of /home/...
		                          and /var/log
		  --sshoption ...         BatchMode, ConnectTimeout,
		                          StrictHostKeyChecking. syncoid sets none of
		                          these, so an unknown host key is an
		                          interactive prompt inside a systemd oneshot
		  --quiet                 progress belongs in the log, not in stdout

		AND WHAT IS DELIBERATELY NOT PASSED:

		  --no-sync-snap    syncoid's own `syncoid_*` snapshot is the ONE common
		                    base that retention cannot remove: sanoid can only
		                    ever destroy a snapshot whose name begins
		                    `autosnap`, so anything else on the source is safe
		                    from it. Replicating only the policy snapshots would
		                    mean the common base is a snapshot the pruner is
		                    entitled to delete, and the next run would be a full
		                    send.
		  --use-hold        it leaves a ZFS hold on the source that is released
		                    only by the NEXT successful run. A forgotten target
		                    would leave a snapshot that cannot be destroyed
		                    without `zfs release` — which is bash.
		  --preserve-properties
		                    it does not exclude `mountpoint` or `canmount`, so
		                    it would push OS/7's locally-set mountpoints onto
		                    the target's datasets. That is the same hazard
		                    --recvoptions=u guards, arriving from the other side.
		  --force-delete    it destroys the target dataset recursively when no
		                    common snapshot is found. That is a decision an
		                    operator makes, not one a timer makes.

		THE RESULT IS VERIFIED FROM THE TARGET. syncoid's exit code is recorded
		and is not believed: it is the worst outcome over all datasets, several
		post-transfer steps only warn, and 0 is reachable with the sync-snapshot
		cleanup unfinished. What decides Ok is whether the target's own ZFS now
		reports a snapshot whose GUID matches one on this machine.

	.PARAMETER Target
		Only these targets. Without it, every enabled one.

	.PARAMETER Force
		Replicate even to a target Test-OS7BackupTarget calls unhealthy.

	.EXAMPLE
		Start-OS7BackupReplication

	.EXAMPLE
		Start-OS7BackupReplication -Target nas
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Backup.Replication')]
	param(
		[Parameter(Position = 0)][string[]]$Target,
		[switch]$Force
	)

	if (-not (Test-Path -LiteralPath $script:OS7SyncoidBin)) {
		throw [System.InvalidOperationException]::new(
			"$($script:OS7SyncoidBin) is not on this machine. It ships in the same " +
			'`sanoid` package as sanoid itself.')
	}

	Import-OS7ZfsLayer
	$policy = Get-OS7BackupPolicy

	# ONE LOCK FOR THE WHOLE MACHINE, because syncoid has none. Two runs of the
	# same dataset race on the target and the loser's receive fails in a way
	# that looks like a network problem.
	$lock = $null
	try {
		$lock = [System.IO.File]::Open($script:OS7BackupLock,
			[System.IO.FileMode]::OpenOrCreate,
			[System.IO.FileAccess]::ReadWrite,
			[System.IO.FileShare]::None)
	}
	catch {
		throw [System.InvalidOperationException]::new(
			'another replication run holds ' + $script:OS7BackupLock + '. syncoid has no ' +
			'locking of its own, so OS/7 refuses rather than letting two sends race.')
	}

	try {
		foreach ($t in @(Get-OS7BackupTarget)) {
			if ($Target -and $t.Name -notin $Target) { continue }
			if (-not $t.Enabled -and -not $Target) {
				Write-OS7Step "skipping $($t.Name): disabled"
				continue
			}

			$check = Test-OS7BackupTarget -Name $t.Name | Select-Object -First 1
			# "Nothing replicated yet" and "not in sync" are the states a first
			# run is SUPPOSED to be in, so they do not block one. Anything about
			# the pool itself does.
			$blocking = @($check.Problems | Where-Object {
					$_ -notlike 'nothing has been replicated*' -and $_ -notlike 'the newest snapshot*'
				})
			if ($blocking -and -not $Force) {
				Write-OS7Step "skipping $($t.Name): $($blocking -join '; ')"
				Write-OS7BackupLog "replication SKIPPED $($t.Name): $($blocking -join '; ')"
				[pscustomobject]@{
					PSTypeName = 'OS7.Backup.Replication'
					Target     = $t.Name
					Ok         = $false
					Skipped    = $true
					ExitCode   = $null
					Datasets   = 0
					Verified   = $false
					Problems   = @($blocking)
				}
				continue
			}

			$dest = if ($t.Kind -eq 'Remote') { "$($t.Host):$($t.Dataset)" } else { $t.Dataset }

			$exit = 0
			$sent = 0
			$problems = [System.Collections.Generic.List[string]]::new()

			foreach ($s in $policy.Sources) {
				if (-not $s.Exists) {
					$problems.Add("$($s.Dataset) does not exist on this machine")
					continue
				}
				$leaf = $s.Dataset.Split('/')[-1]
				$to = "$dest/$leaf"

				$sargs = [System.Collections.Generic.List[string]]::new()
				foreach ($a in (Get-OS7SyncoidArgument -TargetKind $t.Kind -TargetName $t.Name `
							-ChildrenOnly $s.ChildrenOnly -SshKey $t.SshKey)) {
					$sargs.Add($a)
				}
				$sargs.Add($s.Dataset)
				$sargs.Add($to)

				if (-not $PSCmdlet.ShouldProcess("$($s.Dataset) -> $to", 'replicate')) { continue }

				Write-OS7Step "syncoid $($s.Dataset) -> $to"
				try {
					Invoke-OS7Native -Command $script:OS7SyncoidBin -Arguments @($sargs) | Out-Null
					$sent++
				}
				catch {
					# The exit code is recorded because it is evidence about
					# what syncoid believed, and it is not the verdict.
					$exit = 1
					$problems.Add("$($s.Dataset): $($_.Exception.Message.Split("`n")[0])")
				}
			}

			# THE VERDICT, from the target. Re-probed after the run rather than
			# inferred from it.
			$after = Get-OS7BackupTarget -Name $t.Name | Select-Object -First 1
			$verified = [bool]$after.InSync
			if (-not $verified) {
				$problems.Add('the target does not hold a snapshot whose GUID matches ' +
					"one on this machine, so nothing here can say the copy arrived")
			}

			$ok = $verified -and $problems.Count -eq 0
			Write-OS7BackupLog ("replication " + $(if ($ok) { 'OK' } else { 'PROBLEM' }) +
				" $($t.Name): $sent source(s), syncoid exit $exit, verified=$verified" +
				$(if ($problems) { '; ' + ($problems -join '; ') } else { '' }))

			[pscustomobject]@{
				PSTypeName = 'OS7.Backup.Replication'
				Target     = $t.Name
				Ok         = $ok
				Skipped    = $false
				ExitCode   = $exit
				Datasets   = $sent
				Verified   = $verified
				Newest     = $after.NewestReplicated
				Problems   = @($problems)
			}
		}
	}
	finally {
		if ($lock) { $lock.Dispose() }
	}
}

function Mount-OS7BackupTarget {
	<#
	.SYNOPSIS
		Unlock and import a local backup pool that is not currently available.

	.DESCRIPTION
		An external drive is unplugged most of the time, and a backup feature
		whose drive can only be brought up with `cryptsetup open` and
		`zpool import -R` has sent the operator back to bash — which
		docs/RELEASE-AND-UPDATE-PLAN.md §6 says is the whole thing not working.

		IT IMPORTS WITH AN ALTROOT, always. The pool holds received copies of
		/home/... and /var/log; imported at `/` those would mount over the live
		ones. -R is also what makes the import temporary in the way a removable
		drive should be.

	.PARAMETER Name
		The target.

	.PARAMETER Passphrase
		The LUKS2 passphrase. Prompted for if not given.

	.EXAMPLE
		Mount-OS7BackupTarget usb
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Backup.Target')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[securestring]$Passphrase
	)

	Import-OS7ZfsLayer
	$t = Get-OS7BackupTarget -Name $Name -SkipProbe | Select-Object -First 1
	if (-not $t) { throw [System.InvalidOperationException]::new("no target called '$Name'") }
	if ($t.Kind -ne 'LocalPool') {
		throw [System.InvalidOperationException]::new(
			"'$Name' is a remote target. There is nothing on this machine to unlock.")
	}

	if (-not $PSCmdlet.ShouldProcess($t.Pool, 'unlock and import the backup pool')) { return }

	$mapper = "os7_backup_$($t.Pool)"
	if (-not (Test-Path -LiteralPath "/dev/mapper/$mapper")) {
		$part = "/dev/disk/by-partlabel/$($script:OS7BackupPartLabel)"
		if (-not (Test-Path -LiteralPath $part)) {
			throw [System.IO.FileNotFoundException]::new(
				"$part is not present. The drive is not plugged in, or it was not created " +
				'by New-OS7BackupTarget -CreateOn.')
		}
		if (-not $Passphrase) {
			$Passphrase = Read-Host -AsSecureString -Prompt "Passphrase for the backup drive"
		}
		$plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
			[System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase))
		$keyfile = '/run/os7-backup.key'
		try {
			[System.IO.File]::WriteAllBytes($keyfile,
				[System.Text.UTF8Encoding]::new($false).GetBytes($plain))
			Invoke-OS7Native -Command 'cryptsetup' -Arguments @(
				'open', '--key-file', $keyfile, $part, $mapper) | Out-Null
		}
		finally {
			Remove-Item -Force -ErrorAction SilentlyContinue $keyfile
			$plain = $null
		}
	}

	# -Directory IS NOT OPTIONAL when backup pools are named the same on every
	# machine, which they are by default: two drives carrying `os7backup` are
	# two answers to one name, and `zpool import` picks one. Naming the mapper
	# node makes the question unambiguous.
	#
	# -Force is expected here rather than exceptional. A pool records the hostid
	# of whoever last imported it, and a removable pool is meant to be moved.
	# What makes that safe is everything New-OS7BackupTarget did earlier:
	# cachefile=none keeps this off the boot path, so a hostid mismatch is a
	# message on a running system instead of an initramfs prompt.
	Import-Zpool -Name $t.Pool -AltRoot $script:OS7BackupAltRoot `
		-Directory '/dev/mapper' -Force -Confirm:$false | Out-Null
	Write-OS7Step "$($t.Pool) imported under $($script:OS7BackupAltRoot)"
	Get-OS7BackupTarget -Name $Name
}

function Dismount-OS7BackupTarget {
	<#
	.SYNOPSIS
		Export a local backup pool and lock its container, so the drive can go.

	.DESCRIPTION
		EXPORTING IS NOT OPTIONAL POLITENESS. A pool that was not exported
		carries the hostid of whoever last imported it, and the next machine to
		see it gets a refusal it has to override. On the system disk that
		failure mode is an initramfs prompt; here it is merely annoying, and
		only because New-OS7BackupTarget kept this pool off the boot path.

	.EXAMPLE
		Dismount-OS7BackupTarget usb
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory, Position = 0)][string]$Name)

	Import-OS7ZfsLayer
	$t = Get-OS7BackupTarget -Name $Name -SkipProbe | Select-Object -First 1
	if (-not $t) { throw [System.InvalidOperationException]::new("no target called '$Name'") }
	if ($t.Kind -ne 'LocalPool') {
		throw [System.InvalidOperationException]::new("'$Name' is a remote target.")
	}

	if (-not $PSCmdlet.ShouldProcess($t.Pool, 'export the pool and lock the drive')) { return }

	try { Invoke-OS7Native -Command 'sync' -Arguments @() | Out-Null } catch { }

	# Export-Zpool re-reads `zpool list` and throws if the pool is still there,
	# so a failure here is a failure and not a TryExec that scrolled past. That
	# distinction is BUILD-NOTES #42: an export that failed silently let an
	# install report success with rpool still imported.
	Export-Zpool -Name $t.Pool -Confirm:$false
	$mapper = "os7_backup_$($t.Pool)"
	if (Test-Path -LiteralPath "/dev/mapper/$mapper") {
		Invoke-OS7Native -Command 'cryptsetup' -Arguments @('close', $mapper) | Out-Null
	}
	Write-OS7Step "$($t.Pool) exported and locked; the drive can be unplugged"
}
