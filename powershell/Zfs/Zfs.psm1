# =============================================================================
# Zfs — ZFS from PowerShell
#
# Layer 2 of docs/ZFS-POWERSHELL-PLAN.md. Knows nothing about OS/7: no boot
# environments, no release manifest, no LUKS (Z8). The rules this file keeps:
#
#   Z2  ONE SEAM to the binaries. Every native call goes through
#       Invoke-ZfsNative. It is the only function that knows `zfs` and `zpool`
#       are processes, and it is the single thing Test-ZfsModule replaces in
#       order to run where ZFS is not.
#
#   Z3  THE OBSERVED STATE, NEVER THE INTENDED ONE. A mutating cmdlet re-reads
#       what it changed and emits what ZFS now reports. (Phase Z-3; the read
#       surface here is what it will re-read WITH.)
#
#   Z5  PROGRESS GOES TO STDERR EXPLICITLY, never Write-Verbose. MEASURED: in
#       PowerShell 7.6.5 on this image Write-Verbose and Write-Warning go to
#       STDOUT, so one verbose line ahead of `| ConvertTo-Json` makes the
#       installer's result channel unparseable (plan §5, M-Z2). Not a style
#       choice, and not to be "cleaned up".
#
#   Z6  TYPES. Sizes are [uint64] bytes, dates are [datetime]. The format file
#       renders them readably; the objects stay comparable and summable.
#
# WHAT ZFS GIVES US — measured, twice. The man pages shipped in the image say
# -j/--json exists on exactly `zfs list`, `zfs get`, `zpool list`, `zpool get`
# and `zpool status`; a capture run against real pools confirmed all five emit
# parseable JSON (installer/testing/run-zfs.py, fixtures in tests/fixtures).
# That is the whole v1 read surface, so v1 parses no text at all.
#
# THE SHAPE, from those fixtures and not from documentation:
#
#   { "output_version": {...},
#     "pools"|"datasets": {
#        "<name>": { name, type, state|pool, ...,
#                    "properties": { "<prop>": { "value": …,
#                                                "source": {type, data} } } } } }
#
#   zpool status nests instead: pools.<n>.vdevs.<n>.vdevs.<n>… each level
#   carrying state and read/write/checksum error counters.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# The seam (Z2)
# ---------------------------------------------------------------------------

# Set by Test-ZfsModule to feed recorded output in instead of running anything.
# Script scope rather than a parameter on every function: the alternative is
# threading a mock through every call site, which is how mocks leak into
# production signatures.
$script:ZfsCommandOverride = $null

# The ssh options every remote read is made with (Z14). Not negotiable and not
# a parameter:
#
#   BatchMode=yes      never prompt. A verification that BLOCKS on a password
#                      prompt is worse than one that fails, because nothing
#                      times out and nothing says why - the same shape
#                      BUILD-NOTES #16 records for a serial console.
#   ConnectTimeout     a target that is off must fail in seconds, not in the
#                      TCP default.
#   StrictHostKeyChecking=yes
#                      the host key must already be known. A backup target
#                      whose identity is accepted on first sight is a target
#                      anything on the path can impersonate, and this reads the
#                      answer to "is my data really over there".
$script:ZfsSshOptions = @(
	'-o', 'BatchMode=yes',
	'-o', 'ConnectTimeout=10',
	'-o', 'StrictHostKeyChecking=yes')

function ConvertTo-ZfsShellWord {
	<#
	.SYNOPSIS
		Quote one argument for the REMOTE shell (Z14).

	.DESCRIPTION
		`ssh host zfs list x` does not pass an argv: sshd hands the joined
		string to a login shell, which re-splits and re-globs it. Locally
		`& zfs @args` has no shell in it at all, so the two paths do not
		escape the same and the remote one has to be made explicit.

		ZFS names may contain `:` and `@`, which are shell-safe, but a
		mountpoint or a property value is not guaranteed to be - and a name that
		round-trips locally and word-splits remotely is a bug that only appears
		against one particular target.

		Words matching the safe set are passed through so that a command line in
		a log or in the self-test stays readable; anything else is single-quoted
		with the standard `'\''` escape.
	#>
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Word)

	if ($Word -match "^[A-Za-z0-9_@%+=:,./-]+$") { return $Word }
	return "'" + $Word.Replace("'", "'\''") + "'"
}

function Write-ZfsStep {
	<#
	.SYNOPSIS
		One line of progress, on stderr. Z5 — this is load-bearing, see the
		header.
	#>
	param([Parameter(Mandatory)][string]$Message)
	[Console]::Error.WriteLine("ZFS-STEP $Message")
}

function Invoke-ZfsNative {
	<#
	.SYNOPSIS
		Run zfs/zpool. The only place in this module that starts a process.

	.DESCRIPTION
		$ErrorActionPreference = 'Stop' does nothing for a native command
		exiting non-zero, so a failed call would otherwise sail on and fail
		later about something else. This checks $LASTEXITCODE and carries the
		command line AND its stderr into the exception, because
		installer/SETUP-PLAN.md §3.1 requires an error screen to name both — an
		exception reading "zpool exited 1" is not something anybody can act on.

		MEASURED failure shapes (tests/fixtures/err.*):
		  zfs  list  nosuchpool/x  -> exit 1, "cannot open 'nosuchpool/x':
		                              dataset does not exist"
		  zpool status nosuchpool  -> exit 1, "cannot open 'nosuchpool':
		                              no such pool"
		  zfs  list -j nosuchpool/x-> exit 1, and NO JSON at all. So -j does not
		                              turn errors into JSON, and a reader must
		                              not expect an empty result set.

	.PARAMETER AllowFail
		Return the exit code instead of throwing — for the reads where "no such
		dataset" is an answer rather than a failure.

	.PARAMETER ComputerName
		Run the command on ANOTHER host, over ssh (Z14). The seam stays one
		function: `ssh <host> zfs …` is still the only place this module starts
		a process, and Test-ZfsModule still replaces exactly this.

		READ ONLY BY CONVENTION IS NOT ENOUGH, so it is enforced: the mutating
		cmdlets do not take -ComputerName at all. What this exists for is
		answering "is the snapshot actually on the target" from the target's own
		ZFS rather than from the replication tool's exit code — the repeated bug
		shape in docs/BUILD-NOTES.md is a program reporting success while the
		thing it was meant to change did not change, and a backup is the worst
		possible place to make that mistake.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][ValidateSet('zfs', 'zpool')][string]$Command,
		[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
		[switch]$AllowFail,
		[string]$ComputerName,
		[string[]]$SshArgument
	)

	# LOCAL: argv straight to the process, no shell anywhere.
	# REMOTE: sshd joins what it is given and hands it to a login shell, so the
	# remote words are quoted here and the local ones are not. Two paths, and
	# they escape differently on purpose.
	$exe = $Command
	$argv = @($Arguments)
	if ($ComputerName) {
		$remote = @($Command) + @($Arguments) |
			ForEach-Object { ConvertTo-ZfsShellWord -Word $_ }
		$exe = 'ssh'
		$argv = @($script:ZfsSshOptions) + @($SshArgument) + @($ComputerName) + $remote
	}

	$line = "$exe $($argv -join ' ')"

	if ($null -ne $script:ZfsCommandOverride) {
		$r = & $script:ZfsCommandOverride $exe $argv
		if (-not $AllowFail -and $r.ExitCode -ne 0) {
			throw [System.Management.Automation.RuntimeException]::new(
				"$line`nexited $($r.ExitCode)`n$($r.StdErr)")
		}
		return [pscustomobject]@{
			Output = $r.StdOut; ExitCode = $r.ExitCode; StdErr = $r.StdErr
		}
	}

	$errFile = [System.IO.Path]::GetTempFileName()
	try {
		$out = & $exe @argv 2> $errFile
		$code = $LASTEXITCODE
		$err = (Get-Content -Raw -ErrorAction SilentlyContinue $errFile)
		if (-not $AllowFail -and $code -ne 0) {
			throw [System.Management.Automation.RuntimeException]::new(
				"$line`nexited $code`n$err")
		}
		return [pscustomobject]@{
			Output = ($out -join "`n"); ExitCode = $code; StdErr = $err
		}
	}
	finally {
		Remove-Item -Force -ErrorAction SilentlyContinue $errFile
	}
}

function Invoke-ZfsJson {
	<#
	.SYNOPSIS
		Run one of the five commands that speak JSON and hand back the object.

	.DESCRIPTION
		-AsHashtable is deliberate. ZFS keys its JSON BY NAME — pools by pool
		name, datasets by dataset name — and a dataset is called
		`tank/data@snap`. As PSCustomObject properties those names contain `/`
		and `@`: legal, but hostile to every access pattern in PowerShell. As
		hashtable keys they are just keys.

		-Depth 64 because zpool status nests a vdev tree; the explicit value
		documents that nesting is expected rather than accidental.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][ValidateSet('zfs', 'zpool')][string]$Command,
		[Parameter(Mandatory)][string[]]$Arguments,
		[switch]$AllowFail,
		[string]$ComputerName,
		[string[]]$SshArgument
	)

	$r = Invoke-ZfsNative -Command $Command -Arguments $Arguments -AllowFail:$AllowFail `
		-ComputerName $ComputerName -SshArgument $SshArgument
	if ($r.ExitCode -ne 0) { return $null }
	if ([string]::IsNullOrWhiteSpace($r.Output)) { return $null }

	try {
		return $r.Output | ConvertFrom-Json -AsHashtable -Depth 64
	}
	catch {
		# The failure that matters here is a ZFS whose -j is not what §4
		# measured. Say that, instead of letting a parser error stand in for it.
		$head = $r.Output.Substring(0, [Math]::Min(200, $r.Output.Length))
		throw [System.Management.Automation.RuntimeException]::new(
			"$Command $($Arguments -join ' ') did not return parseable JSON. " +
			"This module needs OpenZFS with --json on list/get/status " +
			"(docs/ZFS-POWERSHELL-PLAN.md §4).`nfirst 200 characters: $head")
	}
}

# ---------------------------------------------------------------------------
# Reading the JSON (shapes above, all from captured output)
# ---------------------------------------------------------------------------

function Get-ZfsRawProperty {
	param($Properties, [string]$Name)

	if ($null -eq $Properties) { return $null }
	if ($Properties -isnot [System.Collections.IDictionary]) { return $null }
	if (-not $Properties.Contains($Name)) { return $null }

	$p = $Properties[$Name]
	if ($p -is [System.Collections.IDictionary] -and $p.Contains('value')) {
		return $p['value']
	}
	return $p
}

function ConvertTo-ZfsBytes {
	<#
	.SYNOPSIS
		A ZFS size as [uint64] bytes, whatever form it arrived in.

	.DESCRIPTION
		With --json-int this is nearly a cast. Nearly, because:

		  * `-`, `none` and `off` are real ZFS values meaning "not applicable".
		    They become $null, not 0 — a quota of "none" is not a quota of zero.
		  * MEASURED: a value beyond Int64 arrives from ConvertFrom-Json as
		    [System.Numerics.BigInteger] and round-trips EXACTLY (M-Z4). Pool
		    GUIDs are routinely above 2^63 — the first fixture captured has
		    13714606391384389334 — so this path is not theoretical.
		  * WITHOUT --json-int the same field is the string "1.4T". That returns
		    $null rather than a guessed multiplier: a wrong size is worse than a
		    missing one, and every caller in this module passes --json-int.
	#>
	param($Value)

	if ($null -eq $Value) { return $null }
	if ($Value -is [uint64]) { return $Value }
	if ($Value -is [bigint]) {
		if ($Value -lt 0 -or $Value -gt [uint64]::MaxValue) { return $null }
		return [uint64]$Value
	}
	if ($Value -is [long] -or $Value -is [int]) {
		if ($Value -lt 0) { return $null }
		return [uint64]$Value
	}
	$s = [string]$Value
	if ($s -in @('', '-', 'none', 'off')) { return $null }
	$n = [uint64]0
	if ([uint64]::TryParse($s, [ref]$n)) { return $n }
	return $null
}

function ConvertTo-ZfsDateTime {
	<#
	.SYNOPSIS
		A ZFS `creation` as [datetime]. MEASURED: with --json-int it is a Unix
		timestamp (1787676263 in tests/fixtures/zfs.get.json).
	#>
	param($Value)

	if ($null -eq $Value) { return $null }
	$n = [long]0
	if ([long]::TryParse([string]$Value, [ref]$n) -and $n -gt 0) {
		return [DateTimeOffset]::FromUnixTimeSeconds($n).LocalDateTime
	}
	# Without --json-int it is a formatted local string. A date that will not
	# parse is reported absent rather than as today.
	$d = [datetime]::MinValue
	if ([datetime]::TryParse([string]$Value, [ref]$d)) { return $d }
	return $null
}

function ConvertTo-ZfsBool {
	param($Value)
	if ($null -eq $Value) { return $null }
	if ($Value -is [bool]) { return $Value }
	switch -Exact ([string]$Value) {
		'on'    { return $true }
		'yes'   { return $true }
		'true'  { return $true }
		'off'   { return $false }
		'no'    { return $false }
		'false' { return $false }
		default { return $null }
	}
}

function Format-ZfsSize {
	<#
	.SYNOPSIS
		A byte count as a human-readable binary size. The display half of Z6.

	.DESCRIPTION
		Exported because Zfs.format.ps1xml calls it from every size column, and
		because a script printing its own report wants the same rendering the
		module uses rather than a second, slightly different one.

		Binary units, because K/M/G mean 1024 to ZFS. One decimal below ten
		units and none above, which keeps a column narrow without rounding a
		small number into a lie.

	.EXAMPLE
		Format-ZfsSize 251658240
		240 MiB
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param([Parameter(Position = 0, ValueFromPipeline)]$Size)

	process {
		if ($null -eq $Size) { return '-' }
		$u = @('B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB')
		$v = [double]$Size
		$i = 0
		while ($v -ge 1024 -and $i -lt ($u.Count - 1)) { $v /= 1024; $i++ }
		# INVARIANT CULTURE, not the host's. Measured on a German-locale host,
		# '{0:N1}' produced "1,1 MiB" — a decimal comma inside an
		# otherwise-English table, and worse, inside anything that parses this
		# back. Format-ZfsSize is exported precisely so that reports and Intune
		# compliance scripts render sizes the same way the module does, and a
		# separator that depends on the machine's locale defeats that.
		$inv = [System.Globalization.CultureInfo]::InvariantCulture
		if ($i -eq 0) { return "$([uint64]$Size) B" }
		if ($v -lt 10) { return ([string]::Format($inv, '{0:N1} {1}', $v, $u[$i])) }
		return ([string]::Format($inv, '{0:N0} {1}', $v, $u[$i]))
	}
}

function ConvertTo-ZfsNumber {
	param($Value)
	if ($null -eq $Value) { return $null }
	$s = [string]$Value
	if ($s -in @('', '-', 'none')) { return $null }
	$d = [double]0
	# dedupratio arrives as the string "1.00"; capacity and fragmentation as
	# integers. One accessor, because the caller should not have to know which.
	if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float,
			[System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
		return $d
	}
	return $null
}

# ---------------------------------------------------------------------------
# Pools
# ---------------------------------------------------------------------------

function New-ZfsPoolObject {
	param([string]$Name, $Node)

	$p = if ($Node.Contains('properties')) { $Node['properties'] } else { $null }
	[pscustomobject]@{
		PSTypeName    = 'OS7.Zfs.Pool'
		Name          = $Name
		Health        = [string](Get-ZfsRawProperty $p 'health')
		State         = [string]$Node['state']
		Size          = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'size')
		Allocated     = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'allocated')
		Free          = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'free')
		CapacityPct   = ConvertTo-ZfsNumber (Get-ZfsRawProperty $p 'capacity')
		Fragmentation = ConvertTo-ZfsNumber (Get-ZfsRawProperty $p 'fragmentation')
		DedupRatio    = ConvertTo-ZfsNumber (Get-ZfsRawProperty $p 'dedupratio')
		ExpandSize    = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'expandsize')
		AltRoot        = $(
			$a = [string](Get-ZfsRawProperty $p 'altroot')
			if ($a -eq '-' -or $a -eq '') { $null } else { $a })
		Guid          = [string]$Node['pool_guid']
		SpaVersion    = $Node['spa_version']
		Txg           = $Node['txg']
	}
}

function Get-Zpool {
	<#
	.SYNOPSIS
		The ZFS storage pools on this system.

	.DESCRIPTION
		`zpool list` with typed fields. Size, Allocated and Free are [uint64]
		BYTES, so they can be compared and summed — `zpool list` prints "232G",
		which cannot. The format file renders them back into human units, so
		nothing is lost by looking at it.

		Guid is a STRING. A pool GUID is a full unsigned 64-bit value, routinely
		above what [long] holds, and it is an identifier rather than a number —
		nobody does arithmetic on it, and a string never loses a digit.

	.PARAMETER Name
		Limit to these pools. Without it, every imported pool.

	.PARAMETER ComputerName
		Ask another host over ssh instead of this one (Z14).

	.EXAMPLE
		Get-Zpool

	.EXAMPLE
		Get-Zpool | Where-Object { $_.CapacityPct -gt 80 }
		Pools worth worrying about. The comparison is why the type matters.

	.EXAMPLE
		Get-Zpool -ComputerName backup@nas.example.net
		The pools on a replication target, as objects.
	#>
	[CmdletBinding()]
	[OutputType('OS7.Zfs.Pool')]
	param(
		[Parameter(Position = 0, ValueFromPipelineByPropertyName)]
		[string[]]$Name,
		[string]$ComputerName,
		[string[]]$SshArgument
	)

	process {
		# $zargs, not $args. $args is an automatic variable; assigning to it
		# inside an advanced function works today and is a trap waiting for the
		# person who adds a nested scriptblock or splats it.
		$zargs = @('list', '-j', '--json-int')
		if ($Name) { $zargs += $Name }

		$j = Invoke-ZfsJson -Command zpool -Arguments $zargs `
			-ComputerName $ComputerName -SshArgument $SshArgument
		if ($null -eq $j -or -not $j.Contains('pools')) { return }

		foreach ($key in $j['pools'].Keys) {
			New-ZfsPoolObject -Name $key -Node $j['pools'][$key]
		}
	}
}

function New-ZfsVdevObject {
	<#
	.SYNOPSIS
		One node of the vdev tree, with its children already built.

	.DESCRIPTION
		Recursive, because zpool status IS recursive: pool -> root -> mirror-0
		-> the leaves. MEASURED from tests/fixtures/zpool.status.json; the
		degraded capture shows the state propagating up the levels, which is the
		thing a health check actually wants to read.
	#>
	param([string]$Name, $Node, [int]$Level, [string]$Pool)

	$children = @()
	if ($Node.Contains('vdevs')) {
		foreach ($k in $Node['vdevs'].Keys) {
			$children += New-ZfsVdevObject -Name $k -Node $Node['vdevs'][$k] -Level ($Level + 1) -Pool $Pool
		}
	}

	[pscustomobject]@{
		PSTypeName     = 'OS7.Zfs.VdevNode'
		Pool           = $Pool
		Name           = $Name
		Type           = [string]$Node['vdev_type']
		State          = [string]$Node['state']
		Path           = if ($Node.Contains('path')) { [string]$Node['path'] } else { $null }
		Class          = if ($Node.Contains('class')) { [string]$Node['class'] } else { $null }
		ReadErrors     = $Node['read_errors']
		WriteErrors    = $Node['write_errors']
		ChecksumErrors = $Node['checksum_errors']
		# A LEAF DOES NOT CARRY total_space. Measured: interior vdevs report
		# total_space/alloc_space, leaves report rep_dev_size/phys_space
		# instead, so a single accessor would leave every disk in the tree
		# showing a blank size - which is exactly the column somebody replacing
		# a failed disk needs.
		TotalSpace     = ConvertTo-ZfsBytes $(
			if ($Node.Contains('total_space')) { $Node['total_space'] }
			elseif ($Node.Contains('rep_dev_size')) { $Node['rep_dev_size'] })
		AllocSpace     = ConvertTo-ZfsBytes $(if ($Node.Contains('alloc_space')) { $Node['alloc_space'] })
		PhysicalSize   = ConvertTo-ZfsBytes $(if ($Node.Contains('phys_space')) { $Node['phys_space'] })
		Guid           = [string]$Node['guid']
		Level          = $Level
		Children       = $children
	}
}

function Get-ZpoolStatus {
	<#
	.SYNOPSIS
		Pool health with the vdev tree as objects, not as indented text.

	.DESCRIPTION
		This is the cmdlet that justifies the module. `zpool status` prints a
		tree that every monitoring script in existence re-parses badly;
		`zpool status -j` returns it as structure, and this turns that into
		objects with a Children property, so a failing disk is found by walking
		rather than by regex.

		-Flat returns every node in one sequence with a Level, which is what a
		report or a compliance check wants.

	.PARAMETER Name
		Limit to these pools.

	.PARAMETER Flat
		Emit every vdev as its own object instead of nesting them.

	.EXAMPLE
		Get-ZpoolStatus -Flat | Where-Object State -ne 'ONLINE'
		Everything that is not healthy, at any depth, in one line.
	#>
	[CmdletBinding()]
	[OutputType('OS7.Zfs.PoolStatus')]
	param(
		[Parameter(Position = 0, ValueFromPipelineByPropertyName)]
		[string[]]$Name,
		[switch]$Flat
	)

	process {
		$zargs = @('status', '-j', '--json-int')
		if ($Name) { $zargs += $Name }

		$j = Invoke-ZfsJson -Command zpool -Arguments $zargs
		if ($null -eq $j -or -not $j.Contains('pools')) { return }

		foreach ($key in $j['pools'].Keys) {
			$pool = $j['pools'][$key]

			$roots = @()
			if ($pool.Contains('vdevs')) {
				foreach ($k in $pool['vdevs'].Keys) {
					$roots += New-ZfsVdevObject -Name $k -Node $pool['vdevs'][$k] -Level 0 -Pool $key
				}
			}

			$status = [pscustomobject]@{
				PSTypeName = 'OS7.Zfs.PoolStatus'
				Name       = $key
				State      = [string]$pool['state']
				# `status` and `action` appear only when something is wrong —
				# confirmed by capturing the same pool healthy and DEGRADED.
				Status     = if ($pool.Contains('status')) { [string]$pool['status'] } else { $null }
				Action     = if ($pool.Contains('action')) { [string]$pool['action'] } else { $null }
				ErrorCount = if ($pool.Contains('error_count')) { $pool['error_count'] } else { $null }
				Guid       = [string]$pool['pool_guid']
				Vdevs      = $roots
			}

			if (-not $Flat) { $status; continue }

			# -Flat emits ONLY the vdev nodes, not the pool object as well.
			# MEASURED the other way first: with both in one stream,
			# `Get-ZpoolStatus -Flat | Format-Table` picks the view of the FIRST
			# object and renders every later type as a list, so the output was
			# unreadable. Two types in one pipeline is a formatting decision, not
			# a convenience. Each node carries Pool, so the sequence stands alone.
			# Children are pushed in REVERSE so they pop in the order ZFS listed
			# them. A stack reverses siblings, which put the second half of a
			# mirror above the first - harmless until somebody reads a vdev
			# report and matches it against `zpool status` by position.
			$stack = [System.Collections.Generic.Stack[object]]::new()
			for ($i = $roots.Count - 1; $i -ge 0; $i--) { $stack.Push($roots[$i]) }
			while ($stack.Count) {
				$n = $stack.Pop()
				$n
				for ($i = $n.Children.Count - 1; $i -ge 0; $i--) { $stack.Push($n.Children[$i]) }
			}
		}
	}
}

# ---------------------------------------------------------------------------
# Datasets
# ---------------------------------------------------------------------------

function New-ZfsDatasetObject {
	param([string]$Name, $Node)

	$p = if ($Node.Contains('properties')) { $Node['properties'] } else { $null }

	[pscustomobject]@{
		PSTypeName   = 'OS7.Zfs.Dataset'
		Name         = $Name
		Type         = [string]$Node['type']
		Pool         = [string]$Node['pool']
		# MEASURED: snapshots carry `dataset` and `snapshot_name` of their own,
		# so nothing here has to split a string on '@'.
		Dataset      = if ($Node.Contains('dataset')) { [string]$Node['dataset'] } else { $null }
		SnapshotName = if ($Node.Contains('snapshot_name')) { [string]$Node['snapshot_name'] } else { $null }
		Used         = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'used')
		Available    = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'available')
		Referenced   = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'referenced')
		Mountpoint   = $(
			$m = [string](Get-ZfsRawProperty $p 'mountpoint')
			if ($m -in @('', '-', 'none')) { $null } else { $m })
		Creation     = ConvertTo-ZfsDateTime (Get-ZfsRawProperty $p 'creation')
		Compression  = [string](Get-ZfsRawProperty $p 'compression')
		Quota        = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'quota')
		Origin       = $(
			$o = [string](Get-ZfsRawProperty $p 'origin')
			if ($o -in @('', '-')) { $null } else { $o })
		Mounted      = ConvertTo-ZfsBool (Get-ZfsRawProperty $p 'mounted')
		CreateTxg    = $Node['createtxg']
		Properties   = $p
	}
}

# The columns Get-ZfsDataset asks for. ZFS's own default is
# name,used,available,referenced,mountpoint; these four are added because they
# are what makes the object useful and they cost one column each.
$script:ZfsDatasetColumns = @(
	'name', 'used', 'available', 'referenced', 'mountpoint',
	'creation', 'compression', 'quota', 'origin', 'mounted'
)

function Get-ZfsDataset {
	<#
	.SYNOPSIS
		Filesystems, volumes and snapshots, as objects.

	.DESCRIPTION
		`zfs list` with sizes as [uint64] bytes and `creation` as [datetime].
		That is the difference that matters: `zfs list -o used` gives you the
		string "1.4T", which cannot be compared, summed or sorted numerically.

	.PARAMETER Name
		Datasets to list. Without it, everything.

	.PARAMETER Type
		Filesystem, Volume, Snapshot, Bookmark, or All. Default: filesystems and
		volumes, which is what `zfs list` itself defaults to.

	.PARAMETER Recurse
		Include children.

	.PARAMETER Depth
		Limit recursion. Implies -Recurse.

	.PARAMETER Property
		Extra properties to fetch, on top of the standard columns.

	.EXAMPLE
		Get-ZfsDataset rpool -Recurse | Sort-Object Used -Descending |
			Select-Object -First 10
		The ten biggest datasets. Sorting works because Used is a number.

	.EXAMPLE
		Get-ZfsDataset -Type Snapshot | Where-Object Creation -lt (Get-Date).AddDays(-30)
	#>
	[CmdletBinding()]
	[OutputType('OS7.Zfs.Dataset')]
	param(
		[Parameter(Position = 0, ValueFromPipelineByPropertyName)]
		[string[]]$Name,

		[ValidateSet('Filesystem', 'Volume', 'Snapshot', 'Bookmark', 'All')]
		[string[]]$Type,

		[switch]$Recurse,
		[int]$Depth = -1,
		[string[]]$Property
	)

	process {
		$cols = $script:ZfsDatasetColumns
		if ($Property) { $cols = @($cols + $Property | Select-Object -Unique) }

		$zargs = @('list', '-j', '--json-int', '-o', ($cols -join ','))

		if ($Type) {
			$t = if ($Type -contains 'All') { 'all' }
			else { ($Type | ForEach-Object { $_.ToLowerInvariant() }) -join ',' }
			$zargs += @('-t', $t)
		}
		if ($Depth -ge 0) { $zargs += @('-d', "$Depth") }
		elseif ($Recurse) { $zargs += '-r' }
		if ($Name) { $zargs += $Name }

		$j = Invoke-ZfsJson -Command zfs -Arguments $zargs
		if ($null -eq $j -or -not $j.Contains('datasets')) { return }

		foreach ($key in $j['datasets'].Keys) {
			New-ZfsDatasetObject -Name $key -Node $j['datasets'][$key]
		}
	}
}

function Get-ZfsSnapshot {
	<#
	.SYNOPSIS
		Snapshots, as objects.

	.DESCRIPTION
		`Get-ZfsDataset -Type Snapshot` with the recursion default flipped:
		asking for the snapshots "of rpool/data" almost always means the ones
		below it as well, which is the opposite of what listing a filesystem
		means. Named separately because `Get-ZfsSnapshot` is what an
		administrator will type.

	.EXAMPLE
		Get-ZfsSnapshot rpool/USERDATA |
			Sort-Object Creation -Descending | Select-Object -First 5
	#>
	[CmdletBinding()]
	[OutputType('OS7.Zfs.Dataset')]
	param(
		[Parameter(Position = 0, ValueFromPipelineByPropertyName)]
		[Alias('Dataset')]
		[string[]]$Name,
		[switch]$NoRecurse
	)

	process {
		Get-ZfsDataset -Name $Name -Type Snapshot -Recurse:(-not $NoRecurse)
	}
}

function Get-ZfsProperty {
	<#
	.SYNOPSIS
		Properties of a dataset, one object per property, with their source.

	.DESCRIPTION
		The source is the half `zfs get` users actually need and the half a
		naive wrapper drops: LOCAL, INHERITED, DEFAULT, NONE or TEMPORARY.
		"compression is lz4" and "compression is lz4 because it is inherited
		from the pool" are different facts, and only the second one tells you
		where to change it.

		MEASURED: `zfs get all` returns 83 properties on a plain filesystem, and
		the four source types seen were DEFAULT, INHERITED, LOCAL and NONE.

	.PARAMETER Name
		The dataset.

	.PARAMETER Property
		Which properties. Default: all.

	.EXAMPLE
		Get-ZfsProperty rpool/ROOT -Property compression,quota

	.EXAMPLE
		Get-ZfsProperty rpool/data | Where-Object Source -eq 'LOCAL'
		Everything set ON this dataset rather than inherited — the answer to
		"what did somebody change here".
	#>
	[CmdletBinding()]
	[OutputType('OS7.Zfs.Property')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string[]]$Name,

		[Parameter(Position = 1)]
		[string[]]$Property = @('all')
	)

	process {
		$zargs = @('get', '-j', '--json-int', '-o', 'all',
			($Property -join ','))
		$zargs += $Name

		$j = Invoke-ZfsJson -Command zfs -Arguments $zargs
		if ($null -eq $j -or -not $j.Contains('datasets')) { return }

		foreach ($ds in $j['datasets'].Keys) {
			$node = $j['datasets'][$ds]
			if (-not $node.Contains('properties')) { continue }
			$props = $node['properties']
			foreach ($pk in $props.Keys) {
				$entry = $props[$pk]
				$src = $null
				$srcData = $null
				if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('source')) {
					$src = [string]$entry['source']['type']
					$d = [string]$entry['source']['data']
					$srcData = if ($d -eq '-') { $null } else { $d }
				}
				[pscustomobject]@{
					PSTypeName = 'OS7.Zfs.Property'
					Dataset    = $ds
					Name       = $pk
					Value      = Get-ZfsRawProperty $props $pk
					Source     = $src
					SourceFrom = $srcData
				}
			}
		}
	}
}

function Get-ZfsSpace {
	<#
	.SYNOPSIS
		Where a dataset's space has actually gone.

	.DESCRIPTION
		`zfs list -o space` as numbers. The breakdown is the only way to answer
		"the pool is full and the filesystem looks small" — the space is usually
		in UsedBySnapshots, which the plain listing never shows.

	.EXAMPLE
		Get-ZfsSpace rpool -Recurse | Sort-Object UsedBySnapshots -Descending
	#>
	[CmdletBinding()]
	[OutputType('OS7.Zfs.Space')]
	param(
		[Parameter(Position = 0, ValueFromPipelineByPropertyName)]
		[string[]]$Name,
		[switch]$Recurse
	)

	process {
		$cols = @('name', 'available', 'used', 'usedbysnapshots',
			'usedbydataset', 'usedbyrefreservation', 'usedbychildren')
		$zargs = @('list', '-j', '--json-int', '-o', ($cols -join ','))
		if ($Recurse) { $zargs += '-r' }
		if ($Name) { $zargs += $Name }

		$j = Invoke-ZfsJson -Command zfs -Arguments $zargs
		if ($null -eq $j -or -not $j.Contains('datasets')) { return }

		foreach ($key in $j['datasets'].Keys) {
			$p = $j['datasets'][$key]['properties']
			[pscustomobject]@{
				PSTypeName           = 'OS7.Zfs.Space'
				Name                 = $key
				Available            = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'available')
				Used                 = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'used')
				UsedBySnapshots      = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'usedbysnapshots')
				UsedByDataset        = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'usedbydataset')
				UsedByRefReservation = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'usedbyrefreservation')
				UsedByChildren       = ConvertTo-ZfsBytes (Get-ZfsRawProperty $p 'usedbychildren')
			}
		}
	}
}

# ---------------------------------------------------------------------------
# THE WRITE PATH (plan phase Z-3)
#
# Two rules apply to everything below, and they are the reason this section is
# longer than a wrapper would be:
#
#   Z3  RE-READ AND RETURN WHAT ZFS NOW SAYS, never the parameters that were
#       passed in. `zfs set` and friends produce no output at all, so a cmdlet
#       that echoed its own arguments back would be a diagnostic depending on
#       the subsystem it is diagnosing - the exact shape of every expensive bug
#       in docs/BUILD-NOTES.md. It costs one extra process per mutation.
#
#   Z7  SupportsShouldProcess with ConfirmImpact='High' on anything that
#       destroys. These prompt by default and take -Confirm:$false for the
#       unattended operation RELEASE-AND-UPDATE-PLAN §6 requires of Intune and
#       Arc. `zfs destroy` takes snapshots and children with it and `zfs
#       rollback` discards everything after the snapshot; the audience is
#       Windows administrators for whom neither is obvious.
#
# WHAT IS NOT HERE: the OS/7 guard that refuses to touch the running boot
# environment. That is Layer 3 knowledge and belongs in the OS7 module (Z8) -
# putting it here would cripple this module for anyone pointing it at their own
# storage.
# ---------------------------------------------------------------------------

# `zpool create` refuses a name beginning with any of these, with "name is
# reserved". Found by a capture script that ignored the return code and carried
# on with one pool where it wanted two.
$script:ZpoolReservedPrefixes = @(
	'mirror', 'raidz', 'draid', 'spare', 'log', 'cache', 'special', 'dedup')

function Assert-ZfsName {
	param([Parameter(Mandatory)][string]$Name, [switch]$Pool)

	if ([string]::IsNullOrWhiteSpace($Name)) {
		throw [ArgumentException]::new('a ZFS name cannot be empty')
	}
	if (-not $Pool) { return }

	if ($Name.Contains('/')) {
		throw [ArgumentException]::new(
			"'$Name' is a dataset name, not a pool name — a pool name has no '/'")
	}
	foreach ($p in $script:ZpoolReservedPrefixes) {
		if ($Name -like "$p*") {
			throw [ArgumentException]::new(
				"'$Name' starts with the reserved word '$p'. ZFS refuses pool " +
				"names beginning with " + ($script:ZpoolReservedPrefixes -join ', ') +
				" — it would fail with 'name is reserved'.")
		}
	}
}

function ConvertTo-ZfsPropertyArguments {
	<#
	.SYNOPSIS
		A property table as -o/-O arguments.

	.DESCRIPTION
		IDictionary, not [hashtable], so that [ordered]@{} works. `zpool
		create` does not care what order its -o flags arrive in, but a caller
		reproducing a documented command line does, and every logged command
		line is easier to compare against a written specification when it comes
		out in the order it was written. OS7's storage layer passes an ordered
		table for exactly that reason.
	#>
	param([System.Collections.IDictionary]$Property, [string]$Flag = '-o')

	$out = @()
	if (-not $Property) { return $out }
	foreach ($k in $Property.Keys) {
		$out += @($Flag, "$k=$($Property[$k])")
	}
	return $out
}

function Assert-ZfsGone {
	<#
	.SYNOPSIS
		Z3 for a destroy: ask ZFS whether the thing is actually gone.

	.DESCRIPTION
		`zfs destroy` exiting 0 is a diagnostic. This is the fact.
	#>
	param([Parameter(Mandatory)][string]$Name)

	$r = Invoke-ZfsNative -Command zfs -Arguments @('list', '-H', '-o', 'name', $Name) -AllowFail
	if ($r.ExitCode -eq 0) {
		throw [System.Management.Automation.RuntimeException]::new(
			"zfs destroy '$Name' reported success and '$Name' is still there.")
	}
}

function New-ZfsDataset {
	<#
	.SYNOPSIS
		Create a filesystem or a volume.

	.PARAMETER Name
		The dataset, e.g. rpool/data/projects.

	.PARAMETER Property
		Properties to set at creation, as a hashtable. Set at creation rather
		than afterwards wherever possible: some (notably `casesensitivity` and
		`normalization`) cannot be changed later at all.

	.PARAMETER Size
		Create a VOLUME (zvol) of this size instead of a filesystem.

	.PARAMETER Parents
		Create missing parent datasets, like `mkdir -p`.

	.EXAMPLE
		New-ZfsDataset rpool/data -Property @{ compression = 'zstd'; quota = '10G' }
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Zfs.Dataset')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[System.Collections.IDictionary]$Property,
		[string]$Size,
		[switch]$Parents,
		[switch]$Sparse
	)

	process {
		Assert-ZfsName -Name $Name

		$zargs = @('create')
		if ($Parents) { $zargs += '-p' }
		$zargs += ConvertTo-ZfsPropertyArguments $Property
		if ($Size) {
			if ($Sparse) { $zargs += '-s' }
			$zargs += @('-V', $Size)
		}
		$zargs += $Name

		if (-not $PSCmdlet.ShouldProcess($Name, 'create ZFS dataset')) { return }
		Write-ZfsStep "create $Name"
		Invoke-ZfsNative -Command zfs -Arguments $zargs | Out-Null

		# Z3: what exists now, not what was asked for.
		Get-ZfsDataset -Name $Name -Type All
	}
}

function Remove-ZfsDataset {
	<#
	.SYNOPSIS
		Destroy a dataset. Irreversible.

	.DESCRIPTION
		Prompts by default (Z7). `-Recurse` takes every child AND every snapshot
		with it, which is the part that surprises people: a dataset with
		snapshots refuses to go without it, and then goes completely with it.

	.PARAMETER Recurse
		Destroy children and snapshots too. `zfs destroy -r`.

	.EXAMPLE
		Get-ZfsSnapshot rpool/data | Where-Object Creation -lt (Get-Date).AddDays(-90) |
			Remove-ZfsDataset -Confirm:$false
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[switch]$Recurse
	)

	process {
		Assert-ZfsName -Name $Name

		$what = if ($Recurse) { 'destroy, WITH every child and snapshot' } else { 'destroy' }
		if (-not $PSCmdlet.ShouldProcess($Name, $what)) { return }

		$zargs = @('destroy')
		if ($Recurse) { $zargs += '-r' }
		$zargs += $Name

		Write-ZfsStep "destroy $Name"
		Invoke-ZfsNative -Command zfs -Arguments $zargs | Out-Null
		Assert-ZfsGone -Name $Name
	}
}

function Rename-ZfsDataset {
	<#
	.SYNOPSIS
		Rename or move a dataset.

	.EXAMPLE
		Rename-ZfsDataset rpool/old rpool/new
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Zfs.Dataset')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[Parameter(Mandatory, Position = 1)]
		[string]$NewName,
		[switch]$Parents,
		[switch]$Force
	)

	process {
		Assert-ZfsName -Name $Name
		Assert-ZfsName -Name $NewName

		$zargs = @('rename')
		if ($Parents) { $zargs += '-p' }
		if ($Force) { $zargs += '-f' }
		$zargs += @($Name, $NewName)

		if (-not $PSCmdlet.ShouldProcess($Name, "rename to $NewName")) { return }
		Write-ZfsStep "rename $Name -> $NewName"
		Invoke-ZfsNative -Command zfs -Arguments $zargs | Out-Null

		Get-ZfsDataset -Name $NewName -Type All
	}
}

function Set-ZfsProperty {
	<#
	.SYNOPSIS
		Set one or more properties on a dataset, and report what ZFS then holds.

	.DESCRIPTION
		Z3 in its clearest form. `zfs set` prints nothing, so this re-reads the
		properties it changed and returns them WITH THEIR SOURCE. That catches
		the case where a value was accepted, normalised into something else, and
		would otherwise have been reported back verbatim as though it had been
		stored as typed.

	.EXAMPLE
		Set-ZfsProperty rpool/data -Property @{ compression = 'zstd'; quota = '10G' }

	.EXAMPLE
		Set-ZfsProperty rpool/data compression zstd
	#>
	[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Hashtable')]
	[OutputType('OS7.Zfs.Property')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,

		[Parameter(Mandatory, ParameterSetName = 'Hashtable')]
		[System.Collections.IDictionary]$Property,

		[Parameter(Mandatory, Position = 1, ParameterSetName = 'Single')]
		[string]$PropertyName,
		[Parameter(Mandatory, Position = 2, ParameterSetName = 'Single')]
		[string]$Value
	)

	process {
		Assert-ZfsName -Name $Name

		$table = if ($PSCmdlet.ParameterSetName -eq 'Single') {
			@{ $PropertyName = $Value }
		}
		else { $Property }

		if ($table.Count -eq 0) { return }

		$pairs = foreach ($k in $table.Keys) { "$k=$($table[$k])" }
		if (-not $PSCmdlet.ShouldProcess($Name, "set $($pairs -join ', ')")) { return }

		Write-ZfsStep "set $($pairs -join ' ') on $Name"
		Invoke-ZfsNative -Command zfs -Arguments (@('set') + $pairs + $Name) | Out-Null

		# Z3: read back exactly the properties that were touched.
		Get-ZfsProperty -Name $Name -Property @($table.Keys)
	}
}

function Clear-ZfsProperty {
	<#
	.SYNOPSIS
		Return a property to its inherited or default value. `zfs inherit`.

	.EXAMPLE
		Clear-ZfsProperty rpool/data compression
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Zfs.Property')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[Parameter(Mandatory, Position = 1)]
		[string[]]$Property,
		[switch]$Recurse
	)

	process {
		Assert-ZfsName -Name $Name
		if (-not $PSCmdlet.ShouldProcess($Name, "inherit $($Property -join ', ')")) { return }

		foreach ($p in $Property) {
			$zargs = @('inherit')
			if ($Recurse) { $zargs += '-r' }
			$zargs += @($p, $Name)
			Write-ZfsStep "inherit $p on $Name"
			Invoke-ZfsNative -Command zfs -Arguments $zargs | Out-Null
		}

		Get-ZfsProperty -Name $Name -Property $Property
	}
}

function Mount-ZfsDataset {
	<#
	.SYNOPSIS
		Mount a dataset, and confirm from ZFS that it is mounted.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Zfs.Dataset')]
	param(
		[Parameter(Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[switch]$All,
		[switch]$Overlay
	)

	process {
		if (-not $All -and -not $Name) {
			throw [ArgumentException]::new('give -Name or -All')
		}
		$target = if ($All) { 'every dataset' } else { $Name }
		if (-not $PSCmdlet.ShouldProcess($target, 'mount')) { return }

		$zargs = @('mount')
		if ($Overlay) { $zargs += '-O' }
		if ($All) { $zargs += '-a' } else { $zargs += $Name }

		Write-ZfsStep "mount $target"
		Invoke-ZfsNative -Command zfs -Arguments $zargs | Out-Null

		# Z3: `mounted` as ZFS reports it. An exit code of 0 from `zfs mount`
		# says the command ran, not that anything is mounted at the path.
		if ($All) { Get-ZfsDataset -Type Filesystem } else { Get-ZfsDataset -Name $Name }
	}
}

function Dismount-ZfsDataset {
	<#
	.SYNOPSIS
		Unmount a dataset. `zfs unmount`.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Zfs.Dataset')]
	param(
		[Parameter(Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[switch]$All,
		[switch]$Force
	)

	process {
		if (-not $All -and -not $Name) {
			throw [ArgumentException]::new('give -Name or -All')
		}
		$target = if ($All) { 'every dataset' } else { $Name }
		if (-not $PSCmdlet.ShouldProcess($target, 'unmount')) { return }

		$zargs = @('unmount')
		if ($Force) { $zargs += '-f' }
		if ($All) { $zargs += '-a' } else { $zargs += $Name }

		Write-ZfsStep "unmount $target"
		Invoke-ZfsNative -Command zfs -Arguments $zargs | Out-Null

		if (-not $All) { Get-ZfsDataset -Name $Name }
	}
}

function New-ZfsSnapshot {
	<#
	.SYNOPSIS
		Snapshot a dataset.

	.DESCRIPTION
		Takes its dataset from the pipeline by property name, which is what
		makes the one-liner work:

		    Get-ZfsDataset rpool/DATA -Recurse |
		        New-ZfsSnapshot -SnapshotName daily-$(Get-Date -f yyyyMMdd)

	.PARAMETER SnapshotName
		The part after the '@'.

	.PARAMETER Recurse
		Snapshot all descendants at the same instant. `zfs snapshot -r`, and it
		is atomic across them - taking them one at a time is not the same thing.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Zfs.Dataset')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[Alias('Dataset')]
		[string]$Name,

		[Parameter(Mandatory, Position = 1)]
		[string]$SnapshotName,

		[switch]$Recurse,
		[System.Collections.IDictionary]$Property
	)

	process {
		Assert-ZfsName -Name $Name
		if ($SnapshotName.Contains('@')) {
			throw [ArgumentException]::new(
				"-SnapshotName is the part AFTER the '@'; got '$SnapshotName'")
		}
		$full = "$Name@$SnapshotName"

		if (-not $PSCmdlet.ShouldProcess($full, 'snapshot')) { return }

		$zargs = @('snapshot')
		if ($Recurse) { $zargs += '-r' }
		$zargs += ConvertTo-ZfsPropertyArguments $Property
		$zargs += $full

		Write-ZfsStep "snapshot $full"
		Invoke-ZfsNative -Command zfs -Arguments $zargs | Out-Null

		Get-ZfsDataset -Name $full -Type Snapshot
	}
}

function Remove-ZfsSnapshot {
	<#
	.SYNOPSIS
		Destroy a snapshot. Irreversible.

	.EXAMPLE
		Get-ZfsSnapshot rpool/data |
			Sort-Object Creation | Select-Object -SkipLast 10 |
			Remove-ZfsSnapshot -Confirm:$false
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[switch]$Recurse
	)

	process {
		if (-not $Name.Contains('@')) {
			throw [ArgumentException]::new(
				"'$Name' is not a snapshot. Use Remove-ZfsDataset for a filesystem " +
				'or a volume — the two are separate cmdlets so that a mistyped ' +
				'name cannot destroy a whole filesystem instead of a snapshot.')
		}
		if (-not $PSCmdlet.ShouldProcess($Name, 'destroy snapshot')) { return }

		$zargs = @('destroy')
		if ($Recurse) { $zargs += '-r' }
		$zargs += $Name

		Write-ZfsStep "destroy snapshot $Name"
		Invoke-ZfsNative -Command zfs -Arguments $zargs | Out-Null
		Assert-ZfsGone -Name $Name
	}
}

function Restore-ZfsSnapshot {
	<#
	.SYNOPSIS
		Roll a dataset back to a snapshot. DESTRUCTIVE.

	.DESCRIPTION
		`zfs rollback`. Everything written since the snapshot is discarded, and
		there is no undo. ConfirmImpact is High and the prompt says so.

		ZFS refuses if newer snapshots exist. -Force (`-r`) destroys those
		newer snapshots to make the rollback possible; -DestroyClones (`-R`)
		additionally destroys clones of them. Both are separate switches and
		neither is implied, because the flag letters are one keystroke apart and
		one of them takes other people's datasets with it.

	.EXAMPLE
		Restore-ZfsSnapshot rpool/data@before-upgrade
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.Zfs.Dataset')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[switch]$Force,
		[switch]$DestroyClones
	)

	process {
		if (-not $Name.Contains('@')) {
			throw [ArgumentException]::new("'$Name' is not a snapshot name")
		}
		$dataset = $Name.Split('@')[0]

		$what = 'roll back, DISCARDING everything written since this snapshot'
		if ($Force) { $what += ' and destroying newer snapshots' }
		if ($DestroyClones) { $what += ' and their clones' }
		if (-not $PSCmdlet.ShouldProcess($dataset, $what)) { return }

		$zargs = @('rollback')
		if ($DestroyClones) { $zargs += '-R' }
		elseif ($Force) { $zargs += '-r' }
		$zargs += $Name

		Write-ZfsStep "rollback $dataset to $Name"
		Invoke-ZfsNative -Command zfs -Arguments $zargs | Out-Null

		Get-ZfsDataset -Name $dataset -Type All
	}
}

function New-ZfsClone {
	<#
	.SYNOPSIS
		Create a writable clone of a snapshot.

	.DESCRIPTION
		The clone DEPENDS on its snapshot: the snapshot cannot be destroyed
		while the clone exists. `Convert-ZfsClone` (zfs promote) is what breaks
		that dependency.

	.EXAMPLE
		New-ZfsClone rpool/data@yesterday rpool/data-restored
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Zfs.Dataset')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Snapshot,
		[Parameter(Mandatory, Position = 1)]
		[string]$Name,
		[System.Collections.IDictionary]$Property,
		[switch]$Parents
	)

	process {
		if (-not $Snapshot.Contains('@')) {
			throw [ArgumentException]::new("'$Snapshot' is not a snapshot name")
		}
		Assert-ZfsName -Name $Name
		if (-not $PSCmdlet.ShouldProcess($Name, "clone from $Snapshot")) { return }

		$zargs = @('clone')
		if ($Parents) { $zargs += '-p' }
		$zargs += ConvertTo-ZfsPropertyArguments $Property
		$zargs += @($Snapshot, $Name)

		Write-ZfsStep "clone $Snapshot -> $Name"
		Invoke-ZfsNative -Command zfs -Arguments $zargs | Out-Null

		Get-ZfsDataset -Name $Name -Type All
	}
}

function Convert-ZfsClone {
	<#
	.SYNOPSIS
		Promote a clone so it no longer depends on its origin. `zfs promote`.

	.DESCRIPTION
		After this the clone owns the shared history and the ORIGINAL becomes
		the dependent one. That reversal is the whole point and it is easy to
		get backwards, so the returned object carries Origin as ZFS now reports
		it - which is the observed answer to "which way round is it".
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Zfs.Dataset')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name
	)

	process {
		Assert-ZfsName -Name $Name
		if (-not $PSCmdlet.ShouldProcess($Name, 'promote clone')) { return }

		Write-ZfsStep "promote $Name"
		Invoke-ZfsNative -Command zfs -Arguments @('promote', $Name) | Out-Null

		Get-ZfsDataset -Name $Name -Type All
	}
}

# ---------------------------------------------------------------------------
# Pools
# ---------------------------------------------------------------------------

function New-Zpool {
	<#
	.SYNOPSIS
		Create a storage pool.

	.DESCRIPTION
		-Layout picks the vdev type. `Stripe` is the default and means NO
		redundancy: one device failing loses the pool. It is named rather than
		implied so that nobody gets it by omission.

		The name is validated before `zpool` sees it — ZFS refuses names
		beginning with mirror, raidz, draid, spare, log, cache, special or
		dedup, and its message ("name is reserved") arrives after the fact.

	.EXAMPLE
		New-Zpool tank -Device /dev/disk/by-id/a,/dev/disk/by-id/b -Layout Mirror
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.Zfs.Pool')]
	param(
		[Parameter(Mandatory, Position = 0)]
		[string]$Name,

		[Parameter(Mandatory, Position = 1)]
		[string[]]$Device,

		[ValidateSet('Stripe', 'Mirror', 'RaidZ', 'RaidZ2', 'RaidZ3')]
		[string]$Layout = 'Stripe',

		[System.Collections.IDictionary]$Property,
		[System.Collections.IDictionary]$FilesystemProperty,
		[string]$AltRoot,
		[switch]$Force
	)

	Assert-ZfsName -Name $Name -Pool

	$vdev = switch ($Layout) {
		'Mirror' { 'mirror' }
		'RaidZ'  { 'raidz1' }
		'RaidZ2' { 'raidz2' }
		'RaidZ3' { 'raidz3' }
		default  { $null }
	}

	$zargs = @('create')
	if ($Force) { $zargs += '-f' }
	$zargs += ConvertTo-ZfsPropertyArguments $Property '-o'
	$zargs += ConvertTo-ZfsPropertyArguments $FilesystemProperty '-O'
	if ($AltRoot) { $zargs += @('-R', $AltRoot) }
	$zargs += $Name
	if ($vdev) { $zargs += $vdev }
	$zargs += $Device

	$desc = "create $Layout pool on $($Device -join ', ')"
	if (-not $PSCmdlet.ShouldProcess($Name, $desc)) { return }

	Write-ZfsStep "create pool $Name ($Layout)"
	Invoke-ZfsNative -Command zpool -Arguments $zargs | Out-Null

	Get-Zpool -Name $Name
}

function Remove-Zpool {
	<#
	.SYNOPSIS
		Destroy a pool and everything in it. Irreversible.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[switch]$Force
	)

	process {
		Assert-ZfsName -Name $Name -Pool
		if (-not $PSCmdlet.ShouldProcess($Name, 'DESTROY the pool and every dataset in it')) { return }

		$zargs = @('destroy')
		if ($Force) { $zargs += '-f' }
		$zargs += $Name

		Write-ZfsStep "destroy pool $Name"
		Invoke-ZfsNative -Command zpool -Arguments $zargs | Out-Null

		# Z3: gone means zpool no longer lists it.
		$r = Invoke-ZfsNative -Command zpool -Arguments @('list', '-H', '-o', 'name', $Name) -AllowFail
		if ($r.ExitCode -eq 0) {
			throw [System.Management.Automation.RuntimeException]::new(
				"zpool destroy '$Name' reported success and the pool is still imported.")
		}
	}
}

function Import-Zpool {
	<#
	.SYNOPSIS
		Import a pool.

	.PARAMETER Directory
		Search these directories for devices instead of /dev. This is what makes
		file-backed pools importable, and it is how the test harness works.

	.PARAMETER AltRoot
		Mount everything under this prefix. Always use it when importing a pool
		that is not this machine's own root — otherwise its datasets mount over
		the running system's directories.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Zfs.Pool')]
	param(
		[Parameter(Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[switch]$All,
		[string[]]$Directory,
		[string]$AltRoot,
		[switch]$Force
	)

	process {
		if (-not $All -and -not $Name) {
			throw [ArgumentException]::new('give -Name or -All')
		}
		$target = if ($All) { 'every importable pool' } else { $Name }
		if (-not $PSCmdlet.ShouldProcess($target, 'import')) { return }

		$zargs = @('import')
		if ($Force) { $zargs += '-f' }
		foreach ($d in $Directory) { $zargs += @('-d', $d) }
		if ($AltRoot) { $zargs += @('-R', $AltRoot) }
		if ($All) { $zargs += '-a' } else { $zargs += $Name }

		Write-ZfsStep "import $target"
		Invoke-ZfsNative -Command zpool -Arguments $zargs | Out-Null

		if ($All) { Get-Zpool } else { Get-Zpool -Name $Name }
	}
}

function Export-Zpool {
	<#
	.SYNOPSIS
		Export a pool, so it can be imported elsewhere.

	.DESCRIPTION
		Also the correct way to leave a pool alone: an exported pool records
		that it was released, and a pool that was NOT exported carries the
		hostid of whoever last imported it — which is what drops a machine into
		the initramfs at boot (BUILD-NOTES L13, spike S3).
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[switch]$Force
	)

	process {
		Assert-ZfsName -Name $Name -Pool
		if (-not $PSCmdlet.ShouldProcess($Name, 'export')) { return }

		$zargs = @('export')
		if ($Force) { $zargs += '-f' }
		$zargs += $Name

		Write-ZfsStep "export $Name"
		Invoke-ZfsNative -Command zpool -Arguments $zargs | Out-Null

		$r = Invoke-ZfsNative -Command zpool -Arguments @('list', '-H', '-o', 'name', $Name) -AllowFail
		if ($r.ExitCode -eq 0) {
			throw [System.Management.Automation.RuntimeException]::new(
				"zpool export '$Name' reported success and the pool is still imported.")
		}
	}
}

function Start-ZpoolScrub {
	<#
	.SYNOPSIS
		Start, pause or stop a scrub, and report what the pool then says.

	.DESCRIPTION
		A scrub reads every block and verifies its checksum. It is the only
		thing that finds silent corruption before something needs the data, and
		it is what an "is this pool healthy" policy should actually be asking
		about — a pool that has never been scrubbed is ONLINE and unverified.

		Returns the pool status, so the scan state is visible immediately rather
		than requiring a second command.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Zfs.PoolStatus')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name,
		[switch]$Stop,
		[switch]$Pause
	)

	process {
		Assert-ZfsName -Name $Name -Pool
		$verb = if ($Stop) { 'stop the scrub on' } elseif ($Pause) { 'pause the scrub on' } else { 'scrub' }
		if (-not $PSCmdlet.ShouldProcess($Name, $verb)) { return }

		$zargs = @('scrub')
		if ($Stop) { $zargs += '-s' }
		elseif ($Pause) { $zargs += '-p' }
		$zargs += $Name

		Write-ZfsStep "$verb $Name"
		Invoke-ZfsNative -Command zpool -Arguments $zargs | Out-Null

		Get-ZpoolStatus -Name $Name
	}
}

# ---------------------------------------------------------------------------
# The self-test (Z10)
#
# The shape os7-setup --self-test already uses, and for the same reason: build
# hook 0080 can run it inside the chroot, so a parser that stopped matching what
# ZFS emits fails the BUILD instead of a boot.
#
# TWO MODES, and the difference is the whole test strategy:
#   default  parse RECORDED REAL OUTPUT. Runs anywhere, including where ZFS is
#            not loaded - which is every chroot (M-Z1). Tests the parser.
#   -Live    call real ZFS. Tests the arguments, which recorded output cannot:
#            a fixture cannot notice that `-o` was spelled wrong.
# ---------------------------------------------------------------------------

function Test-ZfsModule {
	<#
	.SYNOPSIS
		Check the module against recorded real ZFS output, or against real ZFS.

	.PARAMETER Live
		Also exercise the cmdlets against the ZFS on this machine. Requires
		pools; read-only throughout.

	.PARAMETER FixturePath
		Where the recorded output lives. Defaults to tests/fixtures beside the
		module.
	#>
	[CmdletBinding()]
	param(
		[switch]$Live,

		# WRITING is opt-in and names its own playing field, because
		# Test-ZfsModule must be safe to run on a machine somebody cares about.
		# -Live only reads. -LiveWrite creates ONE dataset,
		# <Pool>/os7-zfs-selftest, works inside it and destroys it again; it
		# refuses to start if that dataset already exists, so it can never
		# adopt and then delete something that was already there.
		[switch]$LiveWrite,
		[string]$Pool,

		[string]$FixturePath
	)

	$pass = 0
	$fail = [System.Collections.Generic.List[string]]::new()

	function ok($name, $cond, $detail = '') {
		if ($cond) {
			$script:null = $null
			[Console]::Error.WriteLine("  PASS  $name")
			return $true
		}
		[Console]::Error.WriteLine("  FAIL  $name $detail")
		return $false
	}

	if (-not $FixturePath) {
		$FixturePath = Join-Path $PSScriptRoot 'tests/fixtures'
	}

	[Console]::Error.WriteLine("Zfs self-test — fixtures: $FixturePath")

	# -- the converters, which are where a wrong answer is silent ------------
	$cases = @(
		@{ n = 'bytes: plain integer'; got = (ConvertTo-ZfsBytes 251658240); want = [uint64]251658240 }
		@{ n = 'bytes: "-" is absent, not zero'; got = (ConvertTo-ZfsBytes '-'); want = $null }
		@{ n = 'bytes: "none" is absent'; got = (ConvertTo-ZfsBytes 'none'); want = $null }
		@{ n = 'bytes: "1.4T" refuses to guess'; got = (ConvertTo-ZfsBytes '1.4T'); want = $null }
		@{ n = 'bytes: BigInteger beyond Int64'; got = (ConvertTo-ZfsBytes ([bigint]'13714606391384389334')); want = [uint64]13714606391384389334 }
		@{ n = 'bool: on'; got = (ConvertTo-ZfsBool 'on'); want = $true }
		@{ n = 'bool: off'; got = (ConvertTo-ZfsBool 'off'); want = $false }
		@{ n = 'bool: nonsense is null'; got = (ConvertTo-ZfsBool 'sometimes'); want = $null }
		@{ n = 'number: dedupratio "1.00"'; got = (ConvertTo-ZfsNumber '1.00'); want = 1.0 }
	)
	foreach ($c in $cases) {
		if (ok $c.n ($c.got -eq $c.want) "(got '$($c.got)' want '$($c.want)')") { $pass++ }
		else { $fail.Add($c.n) }
	}

	$dt = ConvertTo-ZfsDateTime 1787676263
	if (ok 'datetime: unix seconds' ($dt -is [datetime] -and $dt.Year -eq 2026)) { $pass++ }
	else { $fail.Add('datetime') }

	# -- the parsers, against recorded REAL output --------------------------
	if (-not (Test-Path $FixturePath)) {
		[Console]::Error.WriteLine("  SKIP  no fixtures at $FixturePath")
	}
	else {
		# .GetNewClosure() is not optional here. Without it the inner scriptblock
		# resolves $full when it RUNS, by which time the scope that defined it
		# is gone — and under Set-StrictMode that is an error rather than a
		# silent $null. The seam is invoked long after it is installed, so
		# everything it needs has to be captured, not referenced.
		$replay = {
			param($file)
			$full = Join-Path $FixturePath $file
			$script:ZfsCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{
					StdOut   = (Get-Content -Raw $full)
					ExitCode = 0
					StdErr   = ''
				}
			}.GetNewClosure()
		}

		try {
			& $replay 'zpool.list.json'
			$pools = @(Get-Zpool)
			$tank = $pools | Where-Object Name -eq 'tank'
			foreach ($t in @(
					# NOT a hard-coded count, on purpose. The capture asked for
					# two pools and got one: ZFS REFUSES A POOL NAME STARTING
					# WITH A RESERVED WORD — `spare`, and equally `mirror`,
					# `raidz`, `draid`, `log`, `cache`, `special`, `dedup` —
					# with "name is reserved", so `spare7` was never created.
					# What this checks is that nothing ZFS reported was dropped
					# or left untyped. New-Zpool (Z-3) must validate this up
					# front rather than let zpool refuse it later.
					@{ n = 'Get-Zpool: nothing in the capture was dropped'; c = ($pools.Count -ge 1) }
					@{ n = 'Get-Zpool: every pool came back named'; c = (@($pools | Where-Object { [string]::IsNullOrEmpty($_.Name) }).Count -eq 0) }
					@{ n = 'Get-Zpool: Size is uint64 bytes'; c = ($tank.Size -eq [uint64]251658240) }
					@{ n = 'Get-Zpool: Health'; c = ($tank.Health -eq 'ONLINE') }
					@{ n = 'Get-Zpool: GUID keeps all 20 digits'; c = ($tank.Guid -eq '13714606391384389334') }
					@{ n = 'Get-Zpool: altroot "-" becomes null'; c = ($null -eq $tank.AltRoot) }
				)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }

			& $replay 'zpool.status.json'
			$st = @(Get-ZpoolStatus)[0]
			$root = $st.Vdevs[0]
			$mirror = $root.Children[0]
			foreach ($t in @(
					@{ n = 'Get-ZpoolStatus: state'; c = ($st.State -eq 'ONLINE') }
					@{ n = 'Get-ZpoolStatus: healthy pool has no Status'; c = ($null -eq $st.Status) }
					@{ n = 'Get-ZpoolStatus: root vdev'; c = ($root.Type -eq 'root') }
					@{ n = 'Get-ZpoolStatus: mirror below root'; c = ($mirror.Type -eq 'mirror') }
					@{ n = 'Get-ZpoolStatus: two leaves below the mirror'; c = ($mirror.Children.Count -eq 2) }
					@{ n = 'Get-ZpoolStatus: leaf carries its path'; c = ($mirror.Children[0].Path -like '*.img') }
					@{ n = 'Get-ZpoolStatus: leaf depth is 2'; c = ($mirror.Children[0].Level -eq 2) }
				)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }

			& $replay 'zpool.status.degraded.json'
			$dg = @(Get-ZpoolStatus)[0]
			$flat = @(Get-ZpoolStatus -Flat)
			$offline = @($flat | Where-Object State -eq 'OFFLINE')
			foreach ($t in @(
					@{ n = 'degraded: pool state'; c = ($dg.State -eq 'DEGRADED') }
					@{ n = 'degraded: a Status appears'; c = ($null -ne $dg.Status) }
					@{ n = 'degraded: an Action appears'; c = ($null -ne $dg.Action) }
					@{ n = 'degraded: -Flat finds the OFFLINE leaf'; c = ($offline.Count -eq 1) }
					@{ n = 'degraded: -Flat emits only vdevs, no pool object'; c = (@($flat | Where-Object { $_.PSObject.TypeNames[0] -ne 'OS7.Zfs.VdevNode' }).Count -eq 0) }
					@{ n = 'degraded: every flat node names its pool'; c = (@($flat | Where-Object Pool -ne 'tank').Count -eq 0) }
					@{ n = 'degraded: a leaf reports its size'; c = ($null -ne ($flat | Where-Object Type -eq 'file' | Select-Object -First 1).TotalSpace) }
				)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }

			& $replay 'zfs.list.json'
			$ds = @(Get-ZfsDataset)
			$data = $ds | Where-Object Name -eq 'tank/data'
			$snap = $ds | Where-Object Name -eq 'tank/data@first'
			$vol = $ds | Where-Object Name -eq 'tank/vol'
			foreach ($t in @(
					@{ n = 'Get-ZfsDataset: eight datasets'; c = ($ds.Count -eq 8) }
					@{ n = 'Get-ZfsDataset: Used is a number'; c = ($data.Used -is [uint64]) }
					@{ n = 'Get-ZfsDataset: mountpoint'; c = ($data.Mountpoint -eq '/tank/data') }
					@{ n = 'Get-ZfsDataset: snapshot type'; c = ($snap.Type -eq 'SNAPSHOT') }
					@{ n = 'Get-ZfsDataset: snapshot names itself'; c = ($snap.SnapshotName -eq 'first' -and $snap.Dataset -eq 'tank/data') }
					@{ n = 'Get-ZfsDataset: volume has no mountpoint'; c = ($null -eq $vol.Mountpoint) }
					@{ n = 'Get-ZfsDataset: a name with / and @ survives'; c = ($null -ne $snap) }
				)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }

			& $replay 'zfs.get.one.json'
			$props = @(Get-ZfsProperty tank/data/projects)
			$comp = $props | Where-Object Name -eq 'compression'
			$used = $props | Where-Object Name -eq 'used'
			foreach ($t in @(
					@{ n = 'Get-ZfsProperty: three properties'; c = ($props.Count -eq 3) }
					@{ n = 'Get-ZfsProperty: value'; c = ($comp.Value -eq 'zstd') }
					@{ n = 'Get-ZfsProperty: LOCAL source is kept'; c = ($comp.Source -eq 'LOCAL') }
					@{ n = 'Get-ZfsProperty: NONE source is kept'; c = ($used.Source -eq 'NONE') }
					@{ n = 'Get-ZfsProperty: names its dataset'; c = ($comp.Dataset -eq 'tank/data/projects') }
				)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }

			# -- THE WRITE PATH, offline ------------------------------------
			#
			# What a recorded fixture CAN check about a mutation: the command
			# line it builds, and the guard that runs before it. What it cannot
			# check is the effect - that is -Live below.
			$calls = [System.Collections.Generic.List[string]]::new()
			$script:ZfsCommandOverride = {
				param($cmd, $a)
				$calls.Add("$cmd $($a -join ' ')")
				# The existence check that Assert-ZfsGone makes after a destroy
				# has to be answered as "not there", or every destroy in this
				# block trips its own Z3 verification. That the verification
				# DOES trip when the answer is "still there" is tested
				# separately, below.
				if ($a -contains 'list' -and $a -contains '-H') {
					return [pscustomobject]@{ StdOut = ''; ExitCode = 1; StdErr = 'dataset does not exist' }
				}
				[pscustomobject]@{ StdOut = ''; ExitCode = 0; StdErr = '' }
			}.GetNewClosure()

			$calls.Clear()
			New-ZfsDataset tank/x -Property @{ compression = 'zstd' } -Parents -Confirm:$false | Out-Null
			$mk = $calls[0]

			$calls.Clear()
			Set-ZfsProperty tank/x quota 10G -Confirm:$false | Out-Null
			$setline = $calls[0]

			$calls.Clear()
			New-ZfsSnapshot tank/x -SnapshotName daily -Recurse -Confirm:$false | Out-Null
			$snapline = $calls[0]

			$calls.Clear()
			Remove-ZfsDataset tank/x -Recurse -Confirm:$false | Out-Null
			$rmline = $calls[0]

			$calls.Clear()
			Start-ZpoolScrub tank -Confirm:$false | Out-Null
			$scrubline = $calls[0]

			$calls.Clear()
			New-Zpool tank2 -Device /dev/a, /dev/b -Layout Mirror -Confirm:$false | Out-Null
			$poolline = $calls[0]

			foreach ($t in @(
					@{ n = 'New-ZfsDataset builds create -p -o'; c = ($mk -eq 'zfs create -p -o compression=zstd tank/x') }
					@{ n = 'Set-ZfsProperty builds set k=v'; c = ($setline -eq 'zfs set quota=10G tank/x') }
					@{ n = 'New-ZfsSnapshot joins dataset and name with @'; c = ($snapline -eq 'zfs snapshot -r tank/x@daily') }
					@{ n = 'Remove-ZfsDataset passes -r only when asked'; c = ($rmline -eq 'zfs destroy -r tank/x') }
					@{ n = 'Start-ZpoolScrub builds scrub'; c = ($scrubline -eq 'zpool scrub tank') }
					@{ n = 'New-Zpool puts the vdev word before the devices'; c = ($poolline -eq 'zpool create tank2 mirror /dev/a /dev/b') }
				)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }

			# -WhatIf must run NOTHING. A cmdlet that builds its command line
			# before consulting ShouldProcess and then runs it anyway is the
			# classic way this goes wrong, and it is silent until it destroys
			# something.
			$calls.Clear()
			Remove-ZfsDataset tank/x -WhatIf | Out-Null
			Remove-ZfsSnapshot tank/x@daily -WhatIf | Out-Null
			Restore-ZfsSnapshot tank/x@daily -WhatIf | Out-Null
			Remove-Zpool tank -WhatIf | Out-Null
			if (ok '-WhatIf issues no commands at all' ($calls.Count -eq 0) "(issued $($calls.Count))") { $pass++ }
			else { $fail.Add('-WhatIf issued commands') }

			# The guards, which run before anything is spawned.
			$guards = @(
				@{ n = 'a reserved pool prefix is refused before zpool sees it'
				   s = { New-Zpool spare7 -Device /dev/a -Confirm:$false } }
				@{ n = 'a pool name with a slash is refused'
				   s = { New-Zpool 'tank/x' -Device /dev/a -Confirm:$false } }
				@{ n = 'Remove-ZfsSnapshot refuses a non-snapshot name'
				   s = { Remove-ZfsSnapshot tank/x -Confirm:$false } }
				@{ n = 'New-ZfsSnapshot refuses an @ in -SnapshotName'
				   s = { New-ZfsSnapshot tank/x -SnapshotName 'a@b' -Confirm:$false } }
				@{ n = 'Restore-ZfsSnapshot refuses a non-snapshot name'
				   s = { Restore-ZfsSnapshot tank/x -Confirm:$false } }
			)
			foreach ($g in $guards) {
				$calls.Clear()
				$threw = $false
				try { & $g.s | Out-Null } catch { $threw = $true }
				if (ok $g.n ($threw -and $calls.Count -eq 0)) { $pass++ } else { $fail.Add($g.n) }
			}

			# Z3: a destroy that changed nothing must be reported as a failure.
			$script:ZfsCommandOverride = {
				param($cmd, $a)
				# `destroy` succeeds; the `list` that checks it also succeeds,
				# i.e. the dataset is still there. Exactly the shape
				# docs/BUILD-NOTES.md keeps recording.
				[pscustomobject]@{ StdOut = 'tank/x'; ExitCode = 0; StdErr = '' }
			}
			$caught = $false
			try { Remove-ZfsDataset tank/x -Confirm:$false } catch { $caught = $true }
			if (ok 'a destroy that did not destroy is reported as a failure' $caught) { $pass++ }
			else { $fail.Add('destroy verification') }

			# The error shape, which is the one a wrapper usually gets wrong:
			# -j does NOT produce JSON for a failure, it exits 1 with text.
			$script:ZfsCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{
					StdOut   = ''
					ExitCode = 1
					StdErr   = "cannot open 'nosuchpool': no such pool"
				}
			}
			$threw = $false
			try { Get-Zpool -Name nosuchpool | Out-Null } catch { $threw = $true }
			if (ok 'a missing pool throws, naming the command' $threw) { $pass++ }
			else { $fail.Add('missing pool must throw') }
		}
		finally {
			$script:ZfsCommandOverride = $null
		}
	}

	# -- against real ZFS ---------------------------------------------------
	if ($Live) {
		[Console]::Error.WriteLine('  --- live ---')
		try {
			$pools = @(Get-Zpool)
			if (ok "live: Get-Zpool returned $($pools.Count) pool(s)" ($pools.Count -ge 1)) { $pass++ }
			else { $fail.Add('live Get-Zpool') }

			$st = @(Get-ZpoolStatus)
			if (ok 'live: Get-ZpoolStatus has a vdev tree' ($st.Count -ge 1 -and $st[0].Vdevs.Count -ge 1)) { $pass++ }
			else { $fail.Add('live Get-ZpoolStatus') }

			$ds = @(Get-ZfsDataset -Type All -Recurse)
			if (ok "live: Get-ZfsDataset returned $($ds.Count) dataset(s)" ($ds.Count -ge 1)) { $pass++ }
			else { $fail.Add('live Get-ZfsDataset') }

			# The check a fixture structurally cannot make: that the COLUMNS
			# this module asks for are columns ZFS actually has. A typo in -o
			# is invisible to recorded output and fatal in production.
			$withProps = $ds | Where-Object { $null -ne $_.Creation } | Select-Object -First 1
			if (ok 'live: the -o column list is accepted and Creation arrives' ($null -ne $withProps)) { $pass++ }
			else { $fail.Add('live -o columns') }

			$sp = @(Get-ZfsSpace -Recurse)
			if (ok 'live: Get-ZfsSpace breaks space down' ($sp.Count -ge 1 -and $null -ne $sp[0].Used)) { $pass++ }
			else { $fail.Add('live Get-ZfsSpace') }

			$pr = @(Get-ZfsProperty $ds[0].Name)
			if (ok "live: Get-ZfsProperty returned $($pr.Count) properties" ($pr.Count -gt 10)) { $pass++ }
			else { $fail.Add('live Get-ZfsProperty') }
		}
		catch {
			[Console]::Error.WriteLine("  FAIL  live: $($_.Exception.Message)")
			$fail.Add('live threw')
		}
	}

	# -- the write path, against real ZFS -----------------------------------
	if ($LiveWrite) {
		if (-not $Pool) {
			throw [ArgumentException]::new(
				'-LiveWrite needs -Pool: the test must be told where it may write.')
		}
		$scratch = "$Pool/os7-zfs-selftest"
		[Console]::Error.WriteLine("  --- live write, in $scratch ---")

		$exists = Invoke-ZfsNative -Command zfs -Arguments @('list', '-H', '-o', 'name', $scratch) -AllowFail
		if ($exists.ExitCode -eq 0) {
			throw [System.Management.Automation.RuntimeException]::new(
				"$scratch already exists. Refusing to use it — this test destroys " +
				'what it works in, and it will not destroy something it did not create.')
		}

		try {
			$ds = New-ZfsDataset $scratch -Property @{ compression = 'lz4' } -Confirm:$false
			if (ok 'live write: New-ZfsDataset returns the created dataset' (
					$ds.Name -eq $scratch -and $ds.Type -eq 'FILESYSTEM')) { $pass++ }
			else { $fail.Add('live New-ZfsDataset') }

			# Z3 IN ANGER. The value asked for is 'zstd'; what is asserted is
			# what ZFS reports afterwards, from a separate read.
			$prop = Set-ZfsProperty $scratch compression zstd -Confirm:$false
			$comp = $prop | Where-Object Name -eq 'compression'
			if (ok 'live write: Set-ZfsProperty reports the OBSERVED value' (
					$comp.Value -eq 'zstd' -and $comp.Source -eq 'LOCAL')) { $pass++ }
			else { $fail.Add('live Set-ZfsProperty') }

			$snap = New-ZfsSnapshot $scratch -SnapshotName t1 -Confirm:$false
			if (ok 'live write: New-ZfsSnapshot returns the snapshot' (
					$snap.Name -eq "$scratch@t1" -and $snap.Type -eq 'SNAPSHOT')) { $pass++ }
			else { $fail.Add('live New-ZfsSnapshot') }

			# ROLLBACK BEFORE PROMOTE, and the order is not cosmetic.
			#
			# The first version of this test cloned, promoted, and then rolled
			# back to the original snapshot — and ZFS answered `cannot open
			# 'tank/os7-zfs-selftest@t1': dataset does not exist`. `zfs promote`
			# MOVES the shared snapshots to the promoted clone; the origin no
			# longer has them. That is the reversal Convert-ZfsClone's help
			# describes, and it was still a surprise in practice, so it is
			# asserted below rather than only written down.
			$back = Restore-ZfsSnapshot "$scratch@t1" -Confirm:$false
			if (ok 'live write: Restore-ZfsSnapshot returns the dataset' (
					$back.Name -eq $scratch)) { $pass++ }
			else { $fail.Add('live Restore-ZfsSnapshot') }

			$clone = New-ZfsClone "$scratch@t1" "$Pool/os7-zfs-selftest-clone" -Confirm:$false
			if (ok 'live write: New-ZfsClone records its origin' (
					$clone.Origin -eq "$scratch@t1")) { $pass++ }
			else { $fail.Add('live New-ZfsClone') }

			$promoted = Convert-ZfsClone "$Pool/os7-zfs-selftest-clone" -Confirm:$false
			if (ok 'live write: a promoted clone has no origin any more' (
					$null -eq $promoted.Origin)) { $pass++ }
			else { $fail.Add('live Convert-ZfsClone') }

			# The half that bit: the snapshot is now the CLONE's, and the
			# original cannot see it any more.
			$onOrigin = Invoke-ZfsNative -Command zfs -Arguments @('list', '-H', '-o', 'name', "$scratch@t1") -AllowFail
			$onClone = Invoke-ZfsNative -Command zfs -Arguments @('list', '-H', '-o', 'name', "$Pool/os7-zfs-selftest-clone@t1") -AllowFail
			if (ok 'live write: promote MOVED the snapshot to the clone' (
					$onOrigin.ExitCode -ne 0 -and $onClone.ExitCode -eq 0)) { $pass++ }
			else { $fail.Add('live promote moves snapshots') }

			$inh = Clear-ZfsProperty $scratch compression -Confirm:$false
			$ic = $inh | Where-Object Name -eq 'compression'
			if (ok 'live write: Clear-ZfsProperty stops the source being LOCAL' (
					$ic.Source -ne 'LOCAL')) { $pass++ }
			else { $fail.Add('live Clear-ZfsProperty') }

			# The destroy, and its verification. Assert-ZfsGone throws if the
			# dataset survives a successful-looking destroy.
			# THE OTHER HALF OF THE REVERSAL, and the second thing this test got
			# wrong before ZFS corrected it. After the promote the ORIGINAL is
			# the dependent clone, so @t1 cannot be destroyed at all:
			#
			#   cannot destroy 'tank/os7-zfs-selftest-clone@t1':
			#   snapshot has dependent clones
			#   use '-R' to destroy the following datasets:
			#   tank/os7-zfs-selftest
			#
			# Asserted, because a promote that did not actually reverse the
			# dependency would let this succeed.
			$blocked = $false
			try { Remove-ZfsSnapshot "$Pool/os7-zfs-selftest-clone@t1" -Confirm:$false }
			catch { $blocked = "$($_.Exception.Message)" -match 'dependent clones' }
			if (ok 'live write: the promoted snapshot is protected by its new dependent' $blocked) { $pass++ }
			else { $fail.Add('live promote dependency') }

			# A snapshot nothing depends on, so the removal path itself can be
			# tested. Assert-ZfsGone throws if a destroy that looked successful
			# left it behind.
			New-ZfsSnapshot "$Pool/os7-zfs-selftest-clone" -SnapshotName t2 -Confirm:$false | Out-Null
			Remove-ZfsSnapshot "$Pool/os7-zfs-selftest-clone@t2" -Confirm:$false
			if (ok 'live write: Remove-ZfsSnapshot verified the snapshot is gone' $true) { $pass++ }

			$status = Start-ZpoolScrub $Pool -Confirm:$false
			if (ok 'live write: Start-ZpoolScrub returns pool status' (
					$status.Name -eq $Pool)) { $pass++ }
			else { $fail.Add('live Start-ZpoolScrub') }
		}
		catch {
			[Console]::Error.WriteLine("  FAIL  live write: $($_.Exception.Message)")
			$fail.Add('live write threw')
		}
		finally {
			# Leave nothing behind, whatever happened. -Confirm:$false because
			# this is cleanup, not an operator decision.
			# ORDER MATTERS after a promote: the original is now the dependent,
			# so it has to go first. Destroying the promoted one first fails
			# with "filesystem has dependent clones" and leaves both behind.
			foreach ($d in @($scratch, "$Pool/os7-zfs-selftest-clone")) {
				try { Remove-ZfsDataset $d -Recurse -Confirm:$false -ErrorAction SilentlyContinue } catch { }
			}
		}
	}

	[Console]::Error.WriteLine("`nZfs self-test: $pass passed, $($fail.Count) failed")
	if ($fail.Count) {
		[Console]::Error.WriteLine('FAILED: ' + ($fail -join '; '))
		throw "Zfs self-test failed: $($fail.Count) check(s)"
	}
	[Console]::Error.WriteLine('Zfs self-test: PASS')
}

Export-ModuleMember -Function @(
	# Read
	'Get-Zpool', 'Get-ZpoolStatus', 'Get-ZfsDataset', 'Get-ZfsSnapshot',
	'Get-ZfsProperty', 'Get-ZfsSpace',
	# Datasets
	'New-ZfsDataset', 'Remove-ZfsDataset', 'Rename-ZfsDataset',
	'Set-ZfsProperty', 'Clear-ZfsProperty',
	'Mount-ZfsDataset', 'Dismount-ZfsDataset',
	# Snapshots and clones
	'New-ZfsSnapshot', 'Remove-ZfsSnapshot', 'Restore-ZfsSnapshot',
	'New-ZfsClone', 'Convert-ZfsClone',
	# Pools
	'New-Zpool', 'Remove-Zpool', 'Import-Zpool', 'Export-Zpool',
	'Start-ZpoolScrub',
	# Helpers
	'Format-ZfsSize', 'Test-ZfsModule')
