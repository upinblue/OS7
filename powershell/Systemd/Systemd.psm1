# =============================================================================
# Systemd — units and the journal, as objects
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like Zfs, Net and Time. It
# knows systemctl and journalctl and nothing about OS/7.
#
# THIS IS THE MODULE THAT MAKES THE CASE FOR THE WHOLE PRODUCT. `journalctl |
# grep` is a text pipeline; `Get-SystemdJournal -Priority Error | Group-Object
# Unit` is a question about objects, and that difference is the reason
# PowerShell is the shell here at all. It only holds if the objects are really
# typed — which is most of the work below, because journalctl's JSON is not.
#
# FIVE THINGS MEASURED 2026-08-27, inside a container running real systemd, and
# each one decides a piece of this file:
#
#   1. `systemctl list-units --output=json` is NATIVE JSON. There is no reason
#      to parse the human table, which is columnar, localised and truncated.
#
#   2. EVERY VALUE IN journalctl's JSON IS A STRING. `PRIORITY` is `"6"`,
#      `_PID` is `"1"`, `__REALTIME_TIMESTAMP` is `"1787839897839138"` — and
#      that last one is MICROSECONDS since the epoch, not seconds and not
#      milliseconds. A parser that passes them through leaves
#      `Where-Object Priority -le 3` comparing text, which succeeds and is
#      wrong.
#
#   3. `MESSAGE` IS AN ARRAY OF BYTES when it is not valid UTF-8 — measured by
#      logging `OS7BIN-\xff\xfe-END`, which came back as
#      `[79,83,55,66,73,78,45,255,254,45,69,78,68]`. A parser assuming a string
#      puts `System.Object[]` in the message column of the one line somebody is
#      trying to read.
#
#   4. `_SYSTEMD_UNIT` and `UNIT` are NOT the same field. The underscore prefix
#      means journald added it and the sender could not forge it; the bare name
#      came from the sender. Filtering on the wrong one is how a log filter
#      lies.
# =============================================================================

Set-StrictMode -Version 3.0

$script:SystemdCommandOverride = $null

# Where New-SystemdTimer writes and Remove-SystemdTimer is willing to delete.
# A VARIABLE rather than a literal so the self-test and the logic checks can
# point it at a scratch directory — the same seam check-management-logic.py
# uses on the OS7 module ($script:OS7AuthdBrokerDir and friends).
$script:SystemdUnitDirectory = '/etc/systemd/system'

# journald's priorities, which are syslog's. Kept here rather than inline
# because they are read in two directions — a name to filter by, and a number
# to report — and two hand-written copies of a table drift.
$script:SystemdPriorities = @(
	'Emergency', 'Alert', 'Critical', 'Error', 'Warning', 'Notice', 'Information', 'Debug')

function Invoke-SystemdCommand {
	<#
	.SYNOPSIS
		Internal. Run a program and return stdout, stderr and the exit code,
		without judging the exit code.
	#>
	param(
		[Parameter(Mandatory)][string]$Command,
		[string[]]$Arguments = @()
	)

	if ($script:SystemdCommandOverride) {
		return & $script:SystemdCommandOverride $Command $Arguments
	}

	$errFile = [System.IO.Path]::GetTempFileName()
	try {
		# Reset, then read guarded: $LASTEXITCODE is rewritten only when the
		# command COMPLETES through the pipeline (BUILD-NOTES #121). ExitCode
		# comes back $null — not a stale earlier code — when it never did,
		# and $null compares unequal to 0, so callers treat it as a failure.
		$global:LASTEXITCODE = $null
		$out = & $Command @Arguments 2> $errFile
		return [pscustomobject]@{
			StdOut   = ($out -join "`n")
			ExitCode = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }
			StdErr   = ((Get-Content -Raw -ErrorAction SilentlyContinue $errFile) ?? '')
		}
	}
	finally {
		Remove-Item -Force -ErrorAction SilentlyContinue $errFile
	}
}

function ConvertFrom-SystemdShow {
	<#
	.SYNOPSIS
		Internal. `systemctl show`'s KEY=VALUE output as a hashtable.

	.DESCRIPTION
		Split on the FIRST `=` only. A `Description=` or an `ExecStart=` can
		contain any number of them, and splitting on all of them silently
		truncates exactly the fields a person reads.
	#>
	param([string]$Text)

	$h = @{}
	foreach ($line in ($Text -split "`n")) {
		$line = $line.TrimEnd("`r")
		if (-not $line) { continue }
		$i = $line.IndexOf('=')
		if ($i -lt 1) { continue }
		$h[$line.Substring(0, $i)] = $line.Substring($i + 1)
	}
	return $h
}

function ConvertTo-SystemdInt {
	<#
	.SYNOPSIS
		Internal. A journal or systemctl string as an integer, or $null.

	.DESCRIPTION
		Invariant, for the reason `ConvertTo-TimeDouble` in the Time module
		gives: this product is aimed at machines whose culture is not English,
		and a parse that follows the host's culture is a parse that reads
		differently on a German desktop.
	#>
	param([AllowNull()]$Value)

	if ($null -eq $Value -or $Value -eq '') { return $null }
	$n = [long]0
	if ([long]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Integer,
			[System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
		return $n
	}
	return $null
}

function ConvertFrom-SystemdMessage {
	<#
	.SYNOPSIS
		Internal. A journal MESSAGE, whether it arrived as text or as bytes.

	.DESCRIPTION
		MEASURED: a message that is not valid UTF-8 comes back as an ARRAY OF
		BYTE VALUES rather than a string — `OS7BIN-\xff\xfe-END` became
		`[79,83,55,66,73,78,45,255,254,45,69,78,68]`. Anything that assumed a
		string would print `System.Object[]` in the column somebody is reading.

		The bytes are decoded with replacement rather than dropped, so the
		readable part of a mangled line survives, and `IsBinary` is set so that
		nobody has to guess why a message has a replacement character in it.
	#>
	param($Value)

	if ($null -eq $Value) { return [pscustomobject]@{ Text = ''; IsBinary = $false } }
	if ($Value -is [string]) { return [pscustomobject]@{ Text = $Value; IsBinary = $false } }
	# An array of numbers. [byte[]] cast rather than a loop so that a value
	# outside 0..255 throws here rather than becoming something plausible.
	try {
		$bytes = [byte[]]@($Value)
		return [pscustomobject]@{
			Text     = [System.Text.Encoding]::UTF8.GetString($bytes)
			IsBinary = $true
		}
	}
	catch {
		return [pscustomobject]@{ Text = ($Value -join ' '); IsBinary = $true }
	}
}

function Get-SystemdUnit {
	<#
	.SYNOPSIS
		The units this machine has, and what state they are in.

	.DESCRIPTION
		`ActiveState` ALONE IS NOT A HEALTH ANSWER, which is why this returns
		four fields about state rather than one. `systemctl is-active` says
		`active` for a unit that is in a restart loop; `SubState` says
		`auto-restart`, `Result` says why it last stopped — a real machine
		answered `unit-start-limit-hit` — and `RestartCount` says how often. An
		operator needs all four to tell a healthy service from one that is
		failing every ten seconds.

		THE DETAIL FIELDS ARE `$null` UNTIL `-Detailed` IS ASKED FOR, never
		`$false` and never zero. The same rule `Get-OS7Version`'s `Drift`
		follows: a property that was not looked up must not read like one that
		was and came back clean. `list-units` is one cheap call for the whole
		machine; `systemctl show` is one call per unit.

	.PARAMETER Name
		A unit, or a glob. Implies -Detailed, because asking about one unit is
		asking for its detail.

	.PARAMETER Type
		`service`, `timer`, `socket`, `path`, `mount`, `target`.

	.PARAMETER State
		`running`, `failed`, `active`, `inactive` — systemd's own words, passed
		through rather than translated.

	.EXAMPLE
		Get-SystemdUnit -State failed

	.EXAMPLE
		Get-SystemdUnit -Name chrony.service | Format-List
	#>
	[CmdletBinding()]
	param(
		[string]$Name,
		[string]$Type,
		[string]$State,
		[switch]$Detailed
	)

	if ($Name) { $Detailed = $true }

	$argv = @('--no-pager', 'list-units', '--all', '--output=json')
	if ($Type) { $argv += "--type=$Type" }
	if ($State) { $argv += "--state=$State" }
	if ($Name) { $argv += $Name }

	$r = Invoke-SystemdCommand -Command 'systemctl' -Arguments $argv
	# systemctl exits non-zero when a listed unit is failed, which is not an
	# error in the question "which units are failed". Only an empty answer with
	# a non-zero code is treated as a failure to ask.
	if ($r.ExitCode -ne 0 -and -not $r.StdOut.Trim()) {
		throw [System.InvalidOperationException]::new(
			"systemctl $($argv -join ' ') exited $($r.ExitCode): $($r.StdErr.Trim())" +
			' (is systemd running here?)')
	}

	$units = @()
	if ($r.StdOut.Trim()) { $units = @($r.StdOut | ConvertFrom-Json) }

	foreach ($u in $units) {
		$detail = @{}
		if ($Detailed) {
			$show = Invoke-SystemdCommand -Command 'systemctl' -Arguments @(
				'show', $u.unit,
				'-p', 'Id', '-p', 'Description', '-p', 'LoadState', '-p', 'ActiveState',
				'-p', 'SubState', '-p', 'UnitFileState', '-p', 'Result', '-p', 'NRestarts',
				'-p', 'ExecMainPID', '-p', 'ActiveEnterTimestamp', '-p', 'FragmentPath',
				# Type, because `inactive/dead` means opposite things for a
				# oneshot that has run and for a long-running service that has
				# stopped. Without it, `zfs-mount.service` - which is oneshot,
				# succeeded, and is SUPPOSED to be dead - reads as unhealthy.
				'-p', 'Type',
				# ASK FOR THE MACHINE FORMAT. The default is LOCALISED: the same
				# unit reported `Thu 2026-08-27 14:11:07 UTC` under TZ=UTC and
				# `Thu 2026-08-27 16:11:07 CEST` under TZ=Europe/Berlin - a
				# different time and a different abbreviation, measured. A parser
				# written against the default works on the machine it was written
				# on and reports the wrong hour on every German desktop, which is
				# this product's market. `--timestamp=unix` gives `@1787839867`.
				'--timestamp=unix')
			if ($show.ExitCode -eq 0) { $detail = ConvertFrom-SystemdShow $show.StdOut }
		}

		$since = $null
		if ($detail.ContainsKey('ActiveEnterTimestamp')) {
			# `@1787839867` — seconds since the epoch, with the `@` systemd
			# puts in front of a unix timestamp. An empty value means the unit
			# has never been active, which is $null and not 1970.
			$raw = $detail['ActiveEnterTimestamp']
			if ($raw -match '^@(\d+)$') {
				$since = [System.DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).UtcDateTime
			}
		}

		[pscustomobject]@{
			Name         = $u.unit
			Description  = $u.description
			LoadState    = $u.load
			ActiveState  = $u.active
			SubState     = $u.sub
			# --- only with -Detailed; $null means "not asked", not "clean" ---
			StartupType  = if ($detail.ContainsKey('UnitFileState')) { $detail['UnitFileState'] } else { $null }
			Result       = if ($detail.ContainsKey('Result')) { $detail['Result'] } else { $null }
			RestartCount = if ($detail.ContainsKey('NRestarts')) { ConvertTo-SystemdInt $detail['NRestarts'] } else { $null }
			MainPid      = if ($detail.ContainsKey('ExecMainPID')) { ConvertTo-SystemdInt $detail['ExecMainPID'] } else { $null }
			ActiveSince  = $since
			UnitFile     = if ($detail.ContainsKey('FragmentPath')) { $detail['FragmentPath'] } else { $null }
			ServiceType  = if ($detail.ContainsKey('Type')) { $detail['Type'] } else { $null }
			Detailed     = [bool]$Detailed
		}
	}
}

function Set-SystemdUnitState {
	<#
	.SYNOPSIS
		Internal. start / stop / restart, and then ASK what happened.

	.DESCRIPTION
		`systemctl start` returns 0 when the job was ACCEPTED. For a
		`Type=notify` or `Type=forking` service that then dies, the job
		succeeded and the unit is failed — so the exit code and the answer are
		two different things, and this returns the second.
	#>
	param(
		[Parameter(Mandatory)][string]$Verb,
		[Parameter(Mandatory)][string]$Name
	)

	$r = Invoke-SystemdCommand -Command 'systemctl' -Arguments @($Verb, $Name)
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"systemctl $Verb $Name exited $($r.ExitCode): $($r.StdErr.Trim())")
	}
	return @(Get-SystemdUnit -Name $Name)
}

function Start-SystemdUnit {
	<#
	.SYNOPSIS
		Starts a unit and reports what it became.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][string]$Name)
	if (-not $PSCmdlet.ShouldProcess($Name, 'start')) { return @(Get-SystemdUnit -Name $Name) }
	Set-SystemdUnitState -Verb 'start' -Name $Name
}

function Stop-SystemdUnit {
	<#
	.SYNOPSIS
		Stops a unit and reports what it became.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param([Parameter(Mandatory)][string]$Name)
	if (-not $PSCmdlet.ShouldProcess($Name, 'stop')) { return @(Get-SystemdUnit -Name $Name) }
	Set-SystemdUnitState -Verb 'stop' -Name $Name
}

function Restart-SystemdUnit {
	<#
	.SYNOPSIS
		Restarts a unit and reports what it became.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param([Parameter(Mandatory)][string]$Name)
	if (-not $PSCmdlet.ShouldProcess($Name, 'restart')) { return @(Get-SystemdUnit -Name $Name) }
	Set-SystemdUnitState -Verb 'restart' -Name $Name
}

function Update-SystemdUnit {
	<#
	.SYNOPSIS
		Tells a running unit to re-read its own configuration — `systemctl
		reload`.

	.DESCRIPTION
		NOT `daemon-reload`, which is a different operation entirely: that one
		makes systemd re-read UNIT FILES, this one makes the SERVICE re-read its
		own. Confusing them is how a configuration change is applied to systemd
		and not to the program it configures.

		Reload rather than restart, wherever a service supports it, because a
		restart drops every connection the service is holding — which for sshd
		includes the session running the command.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][string]$Name)
	if (-not $PSCmdlet.ShouldProcess($Name, 'reload its configuration')) {
		return @(Get-SystemdUnit -Name $Name)
	}
	Set-SystemdUnitState -Verb 'reload' -Name $Name
}

function Set-SystemdUnitStartup {
	<#
	.SYNOPSIS
		Whether a unit starts at boot, and reports what it became.

	.DESCRIPTION
		`enable` and `disable` change what happens at the NEXT boot and do not
		touch the running unit — a distinction `systemctl` makes and nobody
		remembers. The returned object shows both `StartupType` and
		`ActiveState`, so the difference is visible rather than assumed.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][ValidateSet('Enabled', 'Disabled', 'Masked')][string]$Startup
	)

	$verb = switch ($Startup) { 'Enabled' { 'enable' } 'Disabled' { 'disable' } 'Masked' { 'mask' } }
	if (-not $PSCmdlet.ShouldProcess($Name, "$verb at boot")) { return @(Get-SystemdUnit -Name $Name) }
	Set-SystemdUnitState -Verb $verb -Name $Name
}

# ---------------------------------------------------------------------------
# Timers
#
# FOUR THINGS MEASURED 2026-08-29, inside a container running real systemd 259
# (259.5-0ubuntu3.4), and each one decides a piece of what follows:
#
#   1. `systemctl list-timers --all --output=json` is native JSON whose numbers
#      ARE numbers — unlike journalctl's. `next` and `last` are MICROSECONDS
#      since the epoch; `last` is `0` (not null) for a timer that has never
#      fired, `next` is null for one that is not scheduled. `left` and
#      `passed` are NOT the durations their names promise (`left` came back
#      equal to `next`, byte for byte), so nothing here reads them.
#
#   2. A timer that is ENABLED BUT NOT STARTED never fires until the next
#      boot, and nothing says so: `UnitFileState=enabled`, `ActiveState=
#      inactive`, `next` null. `systemctl enable` arms the NEXT boot only —
#      arming it NOW is a separate `start`. This is the trap the OS7 layer's
#      `Healthy` exists to name.
#
#   3. A timer that is neither enabled nor active is invisible to BOTH
#      `list-timers --all` AND `list-units --all` — systemd does not load
#      units nothing references. `list-unit-files --type=timer` still lists
#      it, and `systemctl show` loads it on demand. So the timer list below
#      is a UNION of two commands, and a point query falls through to `show`.
#
#   4. With `--timestamp=unix`, timestamps come back as `@<seconds>` (empty
#      when unset) but DURATIONS still come back human-readable — the same
#      unit answered `RandomizedDelayUSec=10min`. Durations are therefore
#      reported verbatim, not parsed: a suffix table maintained here would be
#      a second implementation of systemd's.
# ---------------------------------------------------------------------------

function ConvertFrom-SystemdUsec {
	<#
	.SYNOPSIS
		Internal. Microseconds since the epoch as a UTC [datetime], where 0 and
		null both mean "never".
	#>
	param([AllowNull()]$Value)

	$n = ConvertTo-SystemdInt $Value
	if ($null -eq $n) { return $null }
	return [System.DateTimeOffset]::FromUnixTimeMilliseconds([long]($n / 1000)).UtcDateTime
}

function ConvertFrom-SystemdAtSeconds {
	<#
	.SYNOPSIS
		Internal. `systemctl show --timestamp=unix` renders a set timestamp as
		`@<seconds>` and an unset one as the empty string.
	#>
	param([AllowNull()]$Value)

	if ($null -eq $Value -or "$Value" -notmatch '^@(\d+)$') { return $null }
	return [System.DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).UtcDateTime
}

function Get-SystemdUnitLoadState {
	<#
	.SYNOPSIS
		Internal. `loaded`, `not-found`, `masked`, … — asked of systemd itself.

	.DESCRIPTION
		`Get-SystemdUnit` cannot answer this: it reads `list-units`, and a unit
		that is neither enabled nor active is not IN `list-units` (measured —
		point 3 above). `systemctl show` loads the unit on demand and answers
		for anything, including a name that does not exist.
	#>
	param([Parameter(Mandatory)][string]$Name)

	$r = Invoke-SystemdCommand -Command 'systemctl' -Arguments @(
		'show', $Name, '-p', 'LoadState', '--timestamp=unix')
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"systemctl show $Name exited $($r.ExitCode): $($r.StdErr.Trim())")
	}
	return (ConvertFrom-SystemdShow $r.StdOut)['LoadState']
}

function Get-SystemdTimer {
	<#
	.SYNOPSIS
		The timers this machine has: what they will run, when they will next
		run, and when they last did.

	.DESCRIPTION
		A UNION OF TWO COMMANDS, because neither alone answers "what runs on a
		schedule here". `list-timers --all` knows next/last elapse but omits
		any timer that is neither enabled nor active; `list-unit-files
		--type=timer` knows every installed timer but nothing about elapses. A
		timer only systemd's on-demand loader can see (present, disabled,
		never started) is found by the point query's fall-through to
		`systemctl show`.

		`NextElapse` is `$null` for a timer that WILL NOT FIRE — which
		includes the enabled-but-never-started state `systemctl enable` alone
		leaves behind. `LastTrigger` is `$null` for one that never has; a
		manual `systemctl start` of the SERVICE does not move it, because the
		schedule did not fire (measured).

		THE DETAIL FIELDS ARE `$null` UNTIL `-Detailed` IS ASKED FOR — the
		same rule as `Get-SystemdUnit`. `RandomizedDelay` stays the string
		systemd renders (`10min`), verbatim: durations come back
		human-readable even under `--timestamp=unix`, and a suffix parser here
		would be a second implementation of systemd's.

	.PARAMETER Name
		A timer, or a glob. `.timer` is appended to a bare name. Implies
		-Detailed, because asking about one timer is asking for its detail.

	.PARAMETER Detailed
		Look up state, schedule, Persistent and the delay for every timer
		listed. One `systemctl show` per timer, so it is a choice rather than
		a default.

	.EXAMPLE
		Get-SystemdTimer | Sort-Object NextElapse

	.EXAMPLE
		Get-SystemdTimer -Name sanoid.timer | Format-List
	#>
	[CmdletBinding()]
	param(
		[string]$Name,
		[switch]$Detailed
	)

	if ($Name -and $Name -notmatch '[*?\[]' -and -not $Name.EndsWith('.timer')) {
		$Name = "$Name.timer"
	}
	if ($Name) { $Detailed = $true }

	$argvFiles = @('--no-pager', 'list-unit-files', '--type=timer', '--output=json')
	$argvArmed = @('--no-pager', 'list-timers', '--all', '--output=json')
	if ($Name) { $argvFiles += $Name; $argvArmed += $Name }

	$rf = Invoke-SystemdCommand -Command 'systemctl' -Arguments $argvFiles
	if ($rf.ExitCode -ne 0 -and -not $rf.StdOut.Trim()) {
		throw [System.InvalidOperationException]::new(
			"systemctl $($argvFiles -join ' ') exited $($rf.ExitCode): $($rf.StdErr.Trim())" +
			' (is systemd running here?)')
	}
	$ra = Invoke-SystemdCommand -Command 'systemctl' -Arguments $argvArmed
	if ($ra.ExitCode -ne 0 -and -not $ra.StdOut.Trim()) {
		throw [System.InvalidOperationException]::new(
			"systemctl $($argvArmed -join ' ') exited $($ra.ExitCode): $($ra.StdErr.Trim())")
	}

	$files = @(); if ($rf.StdOut.Trim()) { $files = @($rf.StdOut | ConvertFrom-Json) }
	$armed = @(); if ($ra.StdOut.Trim()) { $armed = @($ra.StdOut | ConvertFrom-Json) }

	# The union, keyed by unit name: every installed timer, plus anything
	# list-timers knows that has no unit file (a transient timer). ORDINAL
	# keys, because `[ordered]@{}` compares case-insensitively and systemd
	# unit names are case-sensitive — `Backup.timer` and `backup.timer` are
	# two units, and folding them staples one's elapses onto the other's file
	# state: an object describing a machine that cannot exist.
	$rows = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
	foreach ($f in $files) {
		$rows[$f.unit_file] = @{ FileState = $f.state; Armed = $null }
	}
	foreach ($t in $armed) {
		if ($rows.Contains($t.unit)) { $rows[$t.unit].Armed = $t }
		else { $rows[$t.unit] = @{ FileState = $null; Armed = $t } }
	}

	# The fall-through measured as point 3 of the header: a point query for a
	# timer that is in NEITHER list is answered by systemd's on-demand loader.
	if ($Name -and $rows.Count -eq 0 -and $Name -notmatch '[*?\[]') {
		if ((Get-SystemdUnitLoadState -Name $Name) -eq 'loaded') {
			$rows[$Name] = @{ FileState = $null; Armed = $null }
		}
	}

	foreach ($unit in @($rows.Keys)) {
		$row = $rows[$unit]

		$detail = @{}
		if ($Detailed) {
			$show = Invoke-SystemdCommand -Command 'systemctl' -Arguments @(
				'show', $unit,
				'-p', 'Id', '-p', 'Description', '-p', 'LoadState', '-p', 'ActiveState',
				'-p', 'SubState', '-p', 'UnitFileState', '-p', 'FragmentPath', '-p', 'Unit',
				'-p', 'TimersCalendar', '-p', 'TimersMonotonic',
				'-p', 'NextElapseUSecRealtime', '-p', 'NextElapseUSecMonotonic',
				'-p', 'LastTriggerUSec', '-p', 'Persistent', '-p', 'RandomizedDelayUSec',
				'-p', 'Result',
				'--timestamp=unix')
			if ($show.ExitCode -eq 0) { $detail = ConvertFrom-SystemdShow $show.StdOut }
		}

		# The schedule, as systemd states it. TimersCalendar reads
		# `{ OnCalendar=*-*-* *:00/15:00 ; next_elapse=@1788033600 }` and a
		# monotonic timer's TimersMonotonic `{ OnStartupUSec=15min ;
		# next_elapse=0 }` — one brace group per trigger. The spec is kept
		# verbatim; the elapse half is already NextElapse.
		$schedule = @()
		if ($detail.ContainsKey('TimersCalendar')) {
			foreach ($m in [regex]::Matches($detail['TimersCalendar'], 'OnCalendar=([^;]+?)\s*;')) {
				$schedule += $m.Groups[1].Value.Trim()
			}
		}
		if ($detail.ContainsKey('TimersMonotonic')) {
			foreach ($m in [regex]::Matches($detail['TimersMonotonic'], '(On\w+USec)=([^;]+?)\s*;')) {
				$schedule += "$($m.Groups[1].Value)=$($m.Groups[2].Value.Trim())"
			}
		}

		# list-timers' microseconds are the first choice for the elapses; the
		# show fall-backs carry seconds and cover the timers list-timers
		# cannot see.
		$next = $null; $last = $null
		if ($row.Armed) {
			$next = ConvertFrom-SystemdUsec $row.Armed.next
			$last = ConvertFrom-SystemdUsec $row.Armed.last
		}
		if ($null -eq $next -and $detail.ContainsKey('NextElapseUSecRealtime')) {
			$next = ConvertFrom-SystemdAtSeconds $detail['NextElapseUSecRealtime']
		}
		if ($null -eq $last -and $detail.ContainsKey('LastTriggerUSec')) {
			$last = ConvertFrom-SystemdAtSeconds $detail['LastTriggerUSec']
		}

		[pscustomobject]@{
			Name            = $unit
			NextElapse      = $next
			LastTrigger     = $last
			Activates       = if ($row.Armed) { $row.Armed.activates }
			elseif ($detail.ContainsKey('Unit')) { $detail['Unit'] } else { $null }
			# From list-unit-files even without -Detailed — the summary is one
			# call for the whole machine, and `enabled` vs `disabled` is half
			# of the question "why is this not running".
			StartupType     = if ($null -ne $row.FileState) { $row.FileState }
			elseif ($detail.ContainsKey('UnitFileState')) { $detail['UnitFileState'] } else { $null }
			# --- only with -Detailed; $null means "not asked", not "clean" ---
			Description     = if ($detail.ContainsKey('Description')) { $detail['Description'] } else { $null }
			ActiveState     = if ($detail.ContainsKey('ActiveState')) { $detail['ActiveState'] } else { $null }
			SubState        = if ($detail.ContainsKey('SubState')) { $detail['SubState'] } else { $null }
			Schedule        = if ($Detailed) { $schedule } else { $null }
			Persistent      = if ($detail.ContainsKey('Persistent')) { $detail['Persistent'] -eq 'yes' } else { $null }
			RandomizedDelay = if ($detail.ContainsKey('RandomizedDelayUSec')) { $detail['RandomizedDelayUSec'] } else { $null }
			Result          = if ($detail.ContainsKey('Result')) { $detail['Result'] } else { $null }
			UnitFile        = if ($detail.ContainsKey('FragmentPath')) { $detail['FragmentPath'] } else { $null }
			Detailed        = [bool]$Detailed
		}
	}
}

function Test-SystemdUnitText {
	<#
	.SYNOPSIS
		Internal. Refuses text that cannot go into a unit-file line.

	.DESCRIPTION
		A newline inside a Description or an ExecStart is not a value, it is
		the NEXT DIRECTIVE — `-Description "x`n[Service]`nExecStart=/evil"`
		would write a unit that does something other than what was asked.
		Refused loudly rather than escaped, because systemd's unit syntax has
		no escape that puts a literal newline into a value.
	#>
	param(
		[Parameter(Mandatory)][string]$What,
		[AllowEmptyString()][string]$Value
	)

	if ($Value -match '[\r\n]') {
		throw [System.ArgumentException]::new(
			"$What contains a line break, which a unit file would read as the next " +
			'directive rather than as part of the value.')
	}
}

function New-SystemdTimer {
	<#
	.SYNOPSIS
		Writes a timer and the service it activates, and asks systemd whether
		it loaded them.

	.DESCRIPTION
		TWO FILES, ONE OPERATION. A `.timer` names a `.service` and systemd
		will not schedule one without the other, so this writes the pair into
		one directory (`/etc/systemd/system`) and treats them as one thing —
		the same rule the boot-environment cmdlets apply to the rpool/bpool
		pair.

		EVERY `-OnCalendar` SPEC IS VALIDATED WITH `systemd-analyze calendar`
		BEFORE ANYTHING IS WRITTEN — the visudo pattern from
		Set-OS7DomainLogonPolicy: a spec systemd cannot parse becomes a timer
		that never fires and reports nothing, and `systemd-analyze` is the
		parser that will read it, not a second implementation here (measured:
		exit 1 and a named error for garbage, exit 0 for anything the timer
		will accept).

		This function WRITES AND VERIFIES; it does not enable or start.
		Enabling is `Set-SystemdUnitStartup`, arming it now is
		`Start-SystemdUnit` on the timer, and running it once is
		`Start-SystemdUnit` on the service — deliberately separate, because
		`enable` alone leaves a timer that never fires until the next boot
		(measured), and a function that hid that distinction would hide the
		trap with it.

		NO SECRETS IN -Command. The unit file is world-readable and the
		command line shows in `systemctl show` — the same reason P7 keeps
		passwords off argv everywhere else.

	.PARAMETER Name
		The unit pair's name, without suffix (`os7-task-nightly` writes
		`os7-task-nightly.timer` and `os7-task-nightly.service`).

	.PARAMETER Command
		The service's `ExecStart=` line, verbatim — systemd's own vocabulary,
		so the first word must be an absolute path, and `%` and `$` mean what
		they mean THERE: `%m` is the machine id, `$VAR` is environment
		substitution, and a literal percent or dollar is spelled `%%` and `$$`.
		This layer passes the line through because a caller may want the
		specifiers; a layer that promises "what you type is what runs" has to
		escape them itself (Register-OS7ScheduledTask does).

	.PARAMETER OnCalendar
		One or more calendar specs, each validated by `systemd-analyze
		calendar` before anything is written.

	.PARAMETER User
		Run the service as this account instead of root.

	.PARAMETER Persistent
		Catch up after downtime: a machine that was off at the elapse runs the
		job when it returns.

	.PARAMETER RandomizedDelay
		Spread a fleet's elapses over this window.

	.PARAMETER Force
		Replace an existing unit pair of the same name. Without it, a pair
		that already exists — hand-authored, or another operator's — is
		refused rather than silently overwritten.

	.EXAMPLE
		New-SystemdTimer -Name os7-task-report -OnCalendar 'Mon..Fri 03:00' `
			-Command '/usr/bin/pwsh -NoProfile -Command Get-Date'
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$Command,
		[Parameter(Mandatory)][string[]]$OnCalendar,
		[string]$Description,
		[string]$User,
		[switch]$Persistent,
		[timespan]$RandomizedDelay,
		[switch]$Force
	)

	$base = $Name -replace '\.timer$', ''
	# The leading '-' refusal is not taste: '-x' is a VALID systemd unit name,
	# but every systemctl invocation in this module would then parse it as an
	# option and fail with "invalid option" (measured on systemd 259) — a unit
	# this module could write and never again address.
	if ($base -notmatch '^[A-Za-z0-9:_.\\-]+$' -or $base.StartsWith('-') -or
		$base -match '\.(service|socket|mount|target)$') {
		throw [System.ArgumentException]::new(
			"'$Name' cannot name a timer unit here. Letters, digits, ':', '_', '.', '\' and " +
			"'-' only, not starting with '-', and no unit-type suffix other than .timer.")
	}
	if (-not $Description) { $Description = $base }

	Test-SystemdUnitText -What '-Description' -Value $Description
	Test-SystemdUnitText -What '-Command' -Value $Command
	if ($User) { Test-SystemdUnitText -What '-User' -Value $User }
	# The first word must be an absolute path — quoted or bare, both of which
	# systemd's own ExecStart parsing accepts.
	if ($Command.TrimStart() -notmatch '^"?/') {
		throw [System.ArgumentException]::new(
			'systemd runs ExecStart without a shell, so the first word of -Command must be ' +
			"an absolute path. Got: $Command")
	}

	# The parser that will read the spec is the one that judges it — BEFORE a
	# file exists that carries the mistake. The '--' is load-bearing: without
	# it an option-shaped spec ('--version') is parsed as an OPTION, exits 0,
	# and the validation waves through a line systemd will later drop with
	# nothing but a journal warning (measured on systemd 259).
	foreach ($spec in $OnCalendar) {
		Test-SystemdUnitText -What '-OnCalendar' -Value $spec
		$v = Invoke-SystemdCommand -Command 'systemd-analyze' -Arguments @('calendar', '--', $spec)
		if ($v.ExitCode -ne 0) {
			throw [System.ArgumentException]::new(
				"systemd cannot parse the calendar spec '$spec': $($v.StdErr.Trim())")
		}
	}

	$servicePath = Join-Path $script:SystemdUnitDirectory "$base.service"
	$timerPath = Join-Path $script:SystemdUnitDirectory "$base.timer"

	# A New- verb does not silently replace what exists (cf. New-Item). An
	# existing pair may be hand-authored or another operator's task; -Force is
	# the explicit way over it.
	if (-not $Force) {
		foreach ($existing in @($timerPath, $servicePath)) {
			if ([System.IO.File]::Exists($existing)) {
				throw [System.InvalidOperationException]::new(
					"$existing already exists. -Force replaces it deliberately.")
			}
		}
	}

	if (-not $PSCmdlet.ShouldProcess("$timerPath + $servicePath", 'write timer unit pair')) {
		return @(Get-SystemdTimer -Name "$base.timer")
	}

	$serviceText = @(
		'[Unit]'
		"Description=$Description"
		''
		'[Service]'
		'Type=oneshot'
		"ExecStart=$Command"
	)
	if ($User) { $serviceText += "User=$User" }

	$timerText = @(
		'[Unit]'
		"Description=$Description"
		''
		'[Timer]'
	)
	foreach ($spec in $OnCalendar) { $timerText += "OnCalendar=$spec" }
	if ($PSBoundParameters.ContainsKey('RandomizedDelay') -and $RandomizedDelay -gt [timespan]::Zero) {
		# Invariant DECIMAL seconds, not [long]: a cast rounds (banker's) and
		# turns a sub-second delay into `RandomizedDelaySec=0` — the requested
		# jitter silently dropped. systemd parses fractional seconds.
		$timerText += ('RandomizedDelaySec=' + $RandomizedDelay.TotalSeconds.ToString(
				'0.###', [System.Globalization.CultureInfo]::InvariantCulture))
	}
	if ($Persistent) { $timerText += 'Persistent=true' }
	$timerText += @('', '[Install]', 'WantedBy=timers.target')

	[System.IO.File]::WriteAllText($servicePath, (($serviceText -join "`n") + "`n"))
	[System.IO.File]::WriteAllText($timerPath, (($timerText -join "`n") + "`n"))

	$r = Invoke-SystemdCommand -Command 'systemctl' -Arguments @('daemon-reload')
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"systemctl daemon-reload exited $($r.ExitCode): $($r.StdErr.Trim())")
	}

	# Ask systemd back, per unit — the files existing proves nothing about
	# whether systemd will schedule them.
	foreach ($unit in @("$base.timer", "$base.service")) {
		$state = Get-SystemdUnitLoadState -Name $unit
		if ($state -ne 'loaded') {
			throw [System.InvalidOperationException]::new(
				"systemd did not load $unit (LoadState=$state). The written files are left " +
				"in $script:SystemdUnitDirectory for inspection.")
		}
	}

	return @(Get-SystemdTimer -Name "$base.timer")
}

function Remove-SystemdTimer {
	<#
	.SYNOPSIS
		Removes a timer unit pair this module could have written, and asks
		systemd whether it is gone.

	.DESCRIPTION
		ONLY FROM `/etc/systemd/system`. A timer whose unit file lives
		anywhere else — `/usr/lib/systemd/system`, a package's — is refused by
		name: deleting a package's unit file is dpkg's job, and the polite way
		to silence one is `Set-SystemdUnitStartup -Startup Disabled` (or
		Masked), which this deliberately is not.

		AND ONLY THE PAIR. A mask — `systemctl mask` puts a symlink to
		/dev/null at exactly the path this would delete — is refused, because
		deleting it would not remove a timer, it would silently UNMASK a
		package's. A lone `.timer` with no `.service` beside it (a `systemctl
		edit --full` override, or a hand-authored unit) is refused too: the
		pair is what `New-SystemdTimer` writes, and the pair is what this
		removes.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param([Parameter(Mandatory)][string]$Name)

	$base = $Name -replace '\.timer$', ''
	$timerPath = Join-Path $script:SystemdUnitDirectory "$base.timer"
	$servicePath = Join-Path $script:SystemdUnitDirectory "$base.service"

	if (-not [System.IO.File]::Exists($timerPath)) {
		$state = Get-SystemdUnitLoadState -Name "$base.timer"
		if ($state -eq 'loaded') {
			throw [System.InvalidOperationException]::new(
				"$base.timer exists but its unit file is not in $script:SystemdUnitDirectory, " +
				'so it is not one this module wrote. Deleting a package''s unit file is the ' +
				'package manager''s job; to stop it, disable or mask it instead.')
		}
		throw [System.InvalidOperationException]::new(
			"There is no $base.timer in $script:SystemdUnitDirectory and systemd reports " +
			"LoadState=$state.")
	}

	# TWO REFUSALS BEFORE ANYTHING RUNS, both for files this module did not
	# write. `systemctl mask` puts a SYMLINK to /dev/null at exactly this
	# path — [System.IO.File]::Exists follows it and answers true (measured) —
	# and deleting it would not remove a timer, it would UNMASK a package's:
	# an administrator's suppression silently reverted. And a `systemctl edit
	# --full` override of a package timer is a regular file here with NO
	# .service beside it; the pair is what New-SystemdTimer writes, so a lone
	# .timer is not ours to delete either.
	if ($null -ne [System.IO.FileInfo]::new($timerPath).LinkTarget) {
		throw [System.InvalidOperationException]::new(
			"$timerPath is a symlink" +
			" — that is a mask (or somebody's redirection), not a timer this module wrote. " +
			'Deleting it would un-say the mask; systemctl unmask is the verb that means that.')
	}
	if (-not [System.IO.File]::Exists($servicePath)) {
		throw [System.InvalidOperationException]::new(
			"$timerPath exists but $servicePath does not. This module removes the PAIR it " +
			'writes; a lone timer file here is an override or a hand-authored unit, and ' +
			'deleting it is not this cmdlet''s to do.')
	}

	if (-not $PSCmdlet.ShouldProcess("$base.timer", 'stop, disable and remove')) {
		return @(Get-SystemdTimer -Name "$base.timer")
	}

	# Stop and disable are best-effort — a timer that was never started makes
	# `stop` a no-op and one that was never enabled makes `disable` one. The
	# assertion that matters is systemd's own answer at the end.
	Invoke-SystemdCommand -Command 'systemctl' -Arguments @('stop', "$base.timer") | Out-Null
	Invoke-SystemdCommand -Command 'systemctl' -Arguments @('disable', "$base.timer") | Out-Null

	[System.IO.File]::Delete($timerPath)
	if ([System.IO.File]::Exists($servicePath)) { [System.IO.File]::Delete($servicePath) }

	$r = Invoke-SystemdCommand -Command 'systemctl' -Arguments @('daemon-reload')
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"systemctl daemon-reload exited $($r.ExitCode): $($r.StdErr.Trim())")
	}

	$state = Get-SystemdUnitLoadState -Name "$base.timer"
	if ($state -ne 'not-found') {
		throw [System.InvalidOperationException]::new(
			"$base.timer was removed from $script:SystemdUnitDirectory but systemd still " +
			"reports LoadState=$state — another unit file elsewhere is shadowing it.")
	}
}

function Get-SystemdJournal {
	<#
	.SYNOPSIS
		The journal, as objects with real types.

	.DESCRIPTION
		THIS IS THE ONE THAT JUSTIFIES THE SHELL. `journalctl | grep` is a text
		pipeline over a log that is already structured; this hands back records
		whose timestamp is a `[datetime]`, whose priority is a number AND a
		name, and whose unit is a field — so `Group-Object Unit`,
		`Where-Object Priority -le 3` and `Sort-Object Timestamp` all work.

		THE TYPING IS THE WORK, because journalctl's JSON has none: every value
		is a string, and `__REALTIME_TIMESTAMP` is MICROSECONDS since the epoch.
		Passing those through would leave `-le 3` comparing text — which does
		not error, and is wrong.

		`Unit` COMES FROM `_SYSTEMD_UNIT`, the field journald adds, and never
		from `UNIT`, which the sender supplies and can therefore be anything.
		A log filter that trusted the wrong one would be a log filter that lies
		about which service said what.

	.PARAMETER Unit
		Only this unit's entries.

	.PARAMETER Priority
		`Emergency`…`Debug`, or a number. journalctl's own semantics: the level
		AND everything more severe.

	.PARAMETER Since
	.PARAMETER Until
		Passed to journalctl in a form it parses. A `[datetime]` is rendered
		invariantly here so the host's culture cannot change which entries come
		back.

	.PARAMETER Tail
		The last N entries. Default 100 — a journal is large, and a cmdlet whose
		default is "everything" is a cmdlet that hangs a terminal.

	.PARAMETER Boot
		`0` for this boot, `-1` for the previous one.

	.EXAMPLE
		Get-SystemdJournal -Priority Error -Tail 50 | Group-Object Unit

	.EXAMPLE
		Get-SystemdJournal -Unit os7-backup-replicate.service -Since (Get-Date).AddHours(-6)
	#>
	[CmdletBinding()]
	param(
		[string]$Unit,
		[string]$Identifier,
		[ValidateSet('Emergency', 'Alert', 'Critical', 'Error', 'Warning', 'Notice',
			'Information', 'Debug')]
		[string]$Priority,
		[datetime]$Since,
		[datetime]$Until,
		[int]$Tail = 100,
		[int]$Boot
	)

	$argv = @('--no-pager', '-o', 'json')
	if ($Unit) { $argv += @('-u', $Unit) }
	if ($Identifier) { $argv += @('-t', $Identifier) }
	if ($Priority) { $argv += @('-p', "$([array]::IndexOf($script:SystemdPriorities, $Priority))") }
	if ($PSBoundParameters.ContainsKey('Since')) {
		$argv += @('--since', $Since.ToString('yyyy-MM-dd HH:mm:ss',
				[System.Globalization.CultureInfo]::InvariantCulture))
	}
	if ($PSBoundParameters.ContainsKey('Until')) {
		$argv += @('--until', $Until.ToString('yyyy-MM-dd HH:mm:ss',
				[System.Globalization.CultureInfo]::InvariantCulture))
	}
	if ($PSBoundParameters.ContainsKey('Boot')) { $argv += @('-b', "$Boot") }
	if ($Tail -gt 0) { $argv += @('-n', "$Tail") }

	$r = Invoke-SystemdCommand -Command 'journalctl' -Arguments $argv
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"journalctl $($argv -join ' ') exited $($r.ExitCode): $($r.StdErr.Trim())")
	}

	foreach ($line in ($r.StdOut -split "`n")) {
		$line = $line.Trim()
		if (-not $line) { continue }
		$e = $line | ConvertFrom-Json

		$fields = $e.PSObject.Properties.Name
		function Field([string]$n) { if ($fields -contains $n) { $e.$n } else { $null } }

		$us = ConvertTo-SystemdInt (Field '__REALTIME_TIMESTAMP')
		$pri = ConvertTo-SystemdInt (Field 'PRIORITY')
		$msg = ConvertFrom-SystemdMessage (Field 'MESSAGE')

		[pscustomobject]@{
			# MICROSECONDS, measured. Seconds would put every entry in 1970 and
			# milliseconds would put them in the year 58000 — both plausible
			# enough to survive a glance.
			Timestamp     = if ($null -ne $us) {
				[System.DateTimeOffset]::FromUnixTimeMilliseconds([long]($us / 1000)).UtcDateTime
			}
			else { $null }
			Priority      = if ($null -ne $pri -and $pri -ge 0 -and $pri -lt 8) {
				$script:SystemdPriorities[$pri]
			}
			else { $null }
			PriorityValue = $pri
			# The TRUSTED unit field. `UNIT` is the sender's and is kept beside
			# it rather than merged, so a discrepancy is visible.
			Unit          = Field '_SYSTEMD_UNIT'
			ClaimedUnit   = Field 'UNIT'
			Identifier    = Field 'SYSLOG_IDENTIFIER'
			ProcessId     = ConvertTo-SystemdInt (Field '_PID')
			Message       = $msg.Text
			MessageIsBinary = $msg.IsBinary
			Hostname      = Field '_HOSTNAME'
			Transport     = Field '_TRANSPORT'
			Cursor        = Field '__CURSOR'
		}
	}
}

# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------

function Test-SystemdModule {
	<#
	.SYNOPSIS
		Checks this module against RECORDED REAL systemctl and journalctl
		output. Needs no systemd, no root and no journal.

	.NOTES
		Reports through [Console]::Error and THROWS on failure — Write-Host does
		not resolve inside a chroot (BUILD-NOTES #38), and a $false return
		leaves pwsh exiting 0, so a failing self-test would be a passing image.
	#>
	[CmdletBinding()]
	param([string]$FixturePath)

	if (-not $FixturePath) { $FixturePath = Join-Path $PSScriptRoot 'tests/fixtures' }

	$script:__sdPass = 0
	$script:__sdFail = @()
	function Check([bool]$ok, [string]$what, [string]$detail = '') {
		$line = "      {0}  {1}" -f $(if ($ok) { 'ok  ' } else { 'FAIL' }), $what
		if ($detail) { $line += "   [$detail]" }
		[Console]::Error.WriteLine($line)
		if ($ok) { $script:__sdPass++ } else { $script:__sdFail += $what }
	}

	[Console]::Error.WriteLine("`nSystemd self-test — no systemd, no root, no journal")
	[Console]::Error.WriteLine("  against recorded output in $FixturePath")

	if (-not (Test-Path -LiteralPath $FixturePath)) {
		Check $false 'the recorded fixtures are shipped beside the module' $FixturePath
	}
	else {
		try {
			$ErrorActionPreference = 'Stop'
			$fx = { param($f) Get-Content -Raw -LiteralPath (Join-Path $FixturePath $f) }

			# REAL `systemctl list-units <name>` RETURNS ONLY THAT UNIT, and the
			# fake has to as well. Without this it answered every question with
			# the whole list, so `Get-SystemdUnit -Name tpm-udev.service` got the
			# FIRST unit's state stapled to tpm-udev's `systemctl show` — an
			# object describing a machine that cannot exist, which passed every
			# check that looked at one field at a time.
			$listFor = {
				param($name)
				$all = (& $fx 'systemctl-list-units.json') | ConvertFrom-Json
				$kept = if ($name) { @($all | Where-Object unit -eq $name) } else { @($all) }
				ConvertTo-Json $kept -Depth 6 -Compress -AsArray
			}.GetNewClosure()

			# --- units, summary -------------------------------------------
			$script:SystemdCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{ StdOut = (& $fx 'systemctl-list-units.json'); ExitCode = 0; StdErr = '' }
			}.GetNewClosure()
			$units = @(Get-SystemdUnit)
			Check ($units.Count -gt 10) 'units: the recorded list came back' "$($units.Count)"
			$chrony = $units | Where-Object Name -eq 'chrony.service'
			Check ($null -ne $chrony) 'units: a named unit is in it'
			Check ($chrony.ActiveState -eq 'active') 'units: ActiveState'
			Check ($chrony.SubState -eq 'running') 'units: SubState'
			# THE RULE THIS MODULE IS BUILT ON. Without -Detailed these were
			# never looked up, and $null says so. Zero restarts and "not asked"
			# must not read the same.
			Check ($null -eq $chrony.RestartCount) `
				'units: RestartCount is $null without -Detailed, not 0'
			Check ($null -eq $chrony.Result) 'units: and so is Result'
			Check ($chrony.Detailed -eq $false) 'units: and the object says it was not detailed'

			# --- units, detailed ------------------------------------------
			$script:SystemdCommandOverride = {
				param($cmd, $a)
				$out = if ($a -contains 'show') { & $fx 'systemctl-show-active.txt' }
				else { & $listFor 'chrony.service' }
				[pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
			}.GetNewClosure()
			$d = @(Get-SystemdUnit -Name 'chrony.service')[0]
			Check ($d.StartupType -eq 'enabled') 'detailed: UnitFileState becomes StartupType'
			Check ($d.Result -eq 'success') 'detailed: Result'
			Check ($d.RestartCount -eq 0) 'detailed: RestartCount is 0 once it HAS been asked'
			Check ($d.MainPid -is [long] -or $d.MainPid -is [int]) 'detailed: MainPid is a number'
			Check ($d.ActiveSince -is [datetime]) 'detailed: ActiveEnterTimestamp becomes a [datetime]'
			Check ($d.ActiveSince.Year -eq 2026) 'detailed: and it parses' "$($d.ActiveSince)"
			Check ($d.UnitFile -like '*chrony.service') 'detailed: the unit file path'

			# --- a unit that really failed, on a real machine --------------
			$script:SystemdCommandOverride = {
				param($cmd, $a)
				$out = if ($a -contains 'show') { & $fx 'systemctl-show-failed.txt' }
				else { & $listFor 'tpm-udev.service' }
				[pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
			}.GetNewClosure()
			$f = @(Get-SystemdUnit -Name 'tpm-udev.service')[0]
			# `start-limit-hit` for a .service; a .path unit on the SAME machine
			# said `unit-start-limit-hit`. Two spellings of one condition,
			# measured, and the reason this asserts the fixture's value rather
			# than a remembered one.
			Check ($f.Result -eq 'start-limit-hit') `
				'failed: Result carries WHY, not just that it failed' $f.Result
			Check ($f.ActiveState -eq 'failed' -and $f.Result -ne 'success') `
				'failed: and ActiveState and Result agree it is bad'

			# --- the journal ----------------------------------------------
			$script:SystemdCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{ StdOut = (& $fx 'journal.json'); ExitCode = 0; StdErr = '' }
			}.GetNewClosure()
			$j = @(Get-SystemdJournal)
			Check ($j.Count -ge 3) 'journal: the recorded entries came back' "$($j.Count)"
			$e = $j[0]
			# THE TYPING, WHICH IS THE WHOLE POINT. journalctl gives strings.
			Check ($e.Timestamp -is [datetime]) 'journal: Timestamp is a [datetime], not a string'
			Check ($e.Timestamp.Year -eq 2026) `
				'journal: MICROSECONDS decoded - seconds would say 1970' "$($e.Timestamp)"
			Check ($e.PriorityValue -is [long] -or $e.PriorityValue -is [int]) `
				'journal: PriorityValue is a number, so -le 3 compares numbers'
			Check ($e.Priority -in $script:SystemdPriorities) `
				'journal: and Priority is the name beside it' "$($e.Priority)"
			Check ($e.ProcessId -is [long] -or $e.ProcessId -is [int]) 'journal: ProcessId is a number'
			Check ($e.Message -is [string]) 'journal: Message is a string'
			Check (-not $e.MessageIsBinary) 'journal: and is not flagged binary'
			Check ($null -ne $e.Cursor) 'journal: the cursor survives'

			# --- a MESSAGE THAT IS NOT TEXT --------------------------------
			# Measured by logging invalid UTF-8 into a real journal. Without
			# this case the message column reads `System.Object[]`.
			$script:SystemdCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{ StdOut = (& $fx 'journal-binary-message.json'); ExitCode = 0; StdErr = '' }
			}.GetNewClosure()
			$b = @(Get-SystemdJournal)[0]
			Check ($b.Message -is [string]) 'binary: a byte-array MESSAGE still becomes a string'
			Check ($b.MessageIsBinary -eq $true) 'binary: and is flagged, so nobody has to guess'
			Check ($b.Message -like 'OS7BIN*') 'binary: the readable part survives' $b.Message

			# --- the arguments journalctl is actually given -----------------
			$seen = $null
			$script:SystemdCommandOverride = {
				param($cmd, $a)
				$script:__sdSeen = ($a -join ' ')
				[pscustomobject]@{ StdOut = ''; ExitCode = 0; StdErr = '' }
			}
			Get-SystemdJournal -Priority Error -Unit 'x.service' -Tail 5 | Out-Null
			$seen = $script:__sdSeen
			# journalctl's -p takes a NUMBER and means "this and worse". Error
			# is 3; passing the word would be rejected, and passing the wrong
			# number would quietly return the wrong severities.
			Check ($seen -match '-p 3') 'journal: -Priority Error becomes -p 3' $seen
			Check ($seen -match '-u x\.service') 'journal: -Unit becomes -u'
			Check ($seen -match '-n 5') 'journal: -Tail becomes -n'

			# A culture-independent --since. On a de-DE host, a [datetime]
			# rendered with the current culture is `27.08.2026`, which
			# journalctl does not parse.
			Get-SystemdJournal -Since ([datetime]::new(2026, 8, 27, 14, 5, 0)) | Out-Null
			Check ($script:__sdSeen -match '--since 2026-08-27 14:05:00') `
				'journal: -Since is rendered invariantly' $script:__sdSeen

			# --- timers: the union of two lists ------------------------------
			# list-timers knows elapses and misses disabled timers;
			# list-unit-files knows every installed timer and no elapses.
			# Recorded 2026-08-29 from a container running systemd 259, minutes
			# after sanoid.timer had fired — so `last` is real in the fixture.
			$timerLists = {
				param($cmd, $a)
				$out = if ($a -contains 'list-unit-files') { & $fx 'systemctl-list-unit-files.json' }
				else { & $fx 'systemctl-list-timers.json' }
				[pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
			}.GetNewClosure()
			$script:SystemdCommandOverride = $timerLists
			$timers = @(Get-SystemdTimer)
			Check ($timers.Count -ge 20) 'timers: the union came back' "$($timers.Count)"
			$sanoid = $timers | Where-Object Name -eq 'sanoid.timer'
			Check ($null -ne $sanoid) 'timers: a named timer is in it'
			Check ($sanoid.NextElapse -is [datetime]) 'timers: NextElapse is a [datetime]'
			Check ($sanoid.NextElapse.Year -eq 2026) `
				'timers: MICROSECONDS decoded - seconds would say 1970' "$($sanoid.NextElapse)"
			Check ($sanoid.LastTrigger -is [datetime]) `
				'timers: LastTrigger is a [datetime] once it HAS fired'
			Check ($sanoid.Activates -eq 'sanoid.service') 'timers: Activates names the service'
			Check ($sanoid.StartupType -eq 'enabled') `
				'timers: StartupType comes from list-unit-files without -Detailed'
			Check ($null -eq $sanoid.Persistent) `
				'timers: Persistent is $null without -Detailed, not $false'
			# fstrim.timer is enabled and NOT scheduled in the fixture (its
			# condition fails in a container) — `next` is null and must come
			# back $null, never 1970.
			$fstrim = $timers | Where-Object Name -eq 'fstrim.timer'
			Check ($null -ne $fstrim -and $null -eq $fstrim.NextElapse) `
				'timers: a null next elapse is $null'
			# chrony-dnssrv@.timer is disabled: list-timers cannot see it at
			# all, list-unit-files can — the reason this is a union.
			$disabled = $timers | Where-Object Name -eq 'chrony-dnssrv@.timer'
			Check ($null -ne $disabled -and $disabled.StartupType -eq 'disabled') `
				'timers: a disabled timer is listed at all' "$($disabled.StartupType)"
			Check ($null -eq $disabled.NextElapse -and $null -eq $disabled.LastTrigger) `
				'timers: and has never fired and never will'

			# --- one timer, detailed -----------------------------------------
			$timerListsFor = {
				param($name)
				$all = (& $fx 'systemctl-list-timers.json') | ConvertFrom-Json
				$kept = if ($name) { @($all | Where-Object unit -eq $name) } else { @($all) }
				ConvertTo-Json $kept -Depth 6 -Compress -AsArray
			}.GetNewClosure()
			$script:SystemdCommandOverride = {
				param($cmd, $a)
				$out = if ($a -contains 'TimersCalendar') { & $fx 'systemctl-show-timer.txt' }
				elseif ($a -contains 'list-unit-files') {
					'[{"unit_file":"sanoid.timer","state":"enabled","preset":"enabled"}]'
				}
				else { & $timerListsFor 'sanoid.timer' }
				[pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
			}.GetNewClosure()
			$st = @(Get-SystemdTimer -Name 'sanoid.timer')[0]
			Check ($st.Schedule -contains '*-*-* *:00/15:00') `
				'timer detail: the calendar spec, verbatim' "$($st.Schedule)"
			Check ($st.Persistent -eq $true) 'timer detail: Persistent=yes becomes $true'
			Check ($st.ActiveState -eq 'active' -and $st.SubState -eq 'waiting') `
				'timer detail: a scheduled timer is active/waiting'
			Check ($st.UnitFile -like '*sanoid.timer') 'timer detail: the unit file path'
			Check ($st.RandomizedDelay -eq '0') `
				'timer detail: durations stay verbatim - systemd renders them human-readable'

			# --- THE TRAP: enabled and never started -------------------------
			# `systemctl enable` alone arms the NEXT boot; until then the timer
			# is enabled, inactive, and will never fire. Recorded from exactly
			# that state. list-timers showed the unit with next=null while
			# enabled; here the lists answer empty so the point query's
			# fall-through to `systemctl show` is what is exercised — the road
			# a disabled timer is found by.
			$script:SystemdCommandOverride = {
				param($cmd, $a)
				$out = if ($a -contains 'TimersCalendar') { & $fx 'systemctl-show-timer-enabled-inactive.txt' }
				elseif ($a -contains 'LoadState') { & $fx 'systemctl-show-loadstate-loaded.txt' }
				else { '[]' }
				[pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
			}.GetNewClosure()
			$trap2 = @(Get-SystemdTimer -Name 'os7-task-probe.timer')[0]
			Check ($null -ne $trap2) 'trap: a timer in NEITHER list is still found by name'
			Check ($trap2.StartupType -eq 'enabled' -and $trap2.ActiveState -eq 'inactive') `
				'trap: enabled AND inactive - the state enable-without-start leaves'
			Check ($null -eq $trap2.NextElapse) 'trap: and it will never fire' 'NextElapse $null'
			Check ($trap2.RandomizedDelay -eq '10min') `
				'trap: RandomizedDelayUSec=10min survives verbatim'

			# --- writing a pair ----------------------------------------------
			$unitDirBefore = $script:SystemdUnitDirectory
			$lab = Join-Path ([System.IO.Path]::GetTempPath()) "os7-sd-test-$PID"
			$null = [System.IO.Directory]::CreateDirectory($lab)
			try {
				$script:SystemdUnitDirectory = $lab
				$script:__sdCalls = @()
				# NO .GetNewClosure() on a block that writes $script: state —
				# BUILD-NOTES #96: the fresh closure scope is where $script:
				# stops resolving to the module's session state, and every
				# recorded call becomes $null. $fx is still reachable through
				# the call stack.
				$script:SystemdCommandOverride = {
					param($cmd, $a)
					$script:__sdCalls += "$cmd $($a -join ' ')"
					$out = if ($cmd -eq 'systemd-analyze') { 'Normalized form: *-*-* 03:00:00' }
					elseif ($a -contains 'TimersCalendar') { & $fx 'systemctl-show-timer-enabled-inactive.txt' }
					elseif ($a -contains 'LoadState') { & $fx 'systemctl-show-loadstate-loaded.txt' }
					elseif ($a -contains 'list-unit-files' -or $a -contains 'list-timers') { '[]' }
					else { '' }
					[pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
				}

				# The same pair the fixtures were recorded from, name and all.
				$made = @(New-SystemdTimer -Name os7-task-probe -Description 'OS/7 task: probe' `
						-OnCalendar '*-*-* 03:00:00' -Command '/usr/bin/true' `
						-Persistent -RandomizedDelay ([timespan]::FromMinutes(10)))[0]
				$svcText = [System.IO.File]::ReadAllText((Join-Path $lab 'os7-task-probe.service'))
				$tmText = [System.IO.File]::ReadAllText((Join-Path $lab 'os7-task-probe.timer'))
				Check ($svcText -match '(?m)^ExecStart=/usr/bin/true$') 'write: ExecStart, verbatim'
				Check ($svcText -match '(?m)^Type=oneshot$') 'write: the service is a oneshot'
				Check ($tmText -match '(?m)^OnCalendar=\*-\*-\* 03:00:00$') 'write: the calendar spec'
				Check ($tmText -match '(?m)^RandomizedDelaySec=600$') `
					'write: -RandomizedDelay becomes whole seconds'
				Check ($tmText -match '(?m)^Persistent=true$') 'write: -Persistent'
				Check ($tmText -match '(?m)^WantedBy=timers\.target$') 'write: enablement has a target'
				# The '--' is what stops an option-shaped spec ('--version')
				# from being parsed as an OPTION and waved through (measured
				# on systemd 259 — exit 0 without it, exit 1 with it).
				Check ([bool](@($script:__sdCalls) -match '^systemd-analyze calendar -- ')) `
					'write: the spec went past systemd-analyze first, behind --'
				Check ([bool](@($script:__sdCalls) -match 'daemon-reload')) `
					'write: systemd was told to re-read'
				Check ($null -ne $made -and $made.Name -eq 'os7-task-probe.timer') `
					'write: and the answer is the timer, asked back'

				# A New- verb does not silently replace what exists.
				$dup = $null
				try {
					New-SystemdTimer -Name os7-task-probe -OnCalendar '*-*-* 03:00:00' `
						-Command '/usr/bin/true'
				}
				catch { $dup = $_.Exception.Message }
				Check ($dup -like '*already exists*') `
					'write: an existing pair is refused without -Force'
				New-SystemdTimer -Name os7-task-probe -OnCalendar '*-*-* 04:00:00' `
					-Command '/usr/bin/true' -Force | Out-Null
				Check (([System.IO.File]::ReadAllText((Join-Path $lab 'os7-task-probe.timer'))) `
						-match '(?m)^OnCalendar=\*-\*-\* 04:00:00$') `
					'write: and -Force replaces it deliberately'

				# A sub-second delay must not silently become
				# RandomizedDelaySec=0 - systemd parses decimal seconds.
				New-SystemdTimer -Name os7-task-jitter -OnCalendar 'daily' -Command '/usr/bin/true' `
					-RandomizedDelay ([timespan]::FromMilliseconds(500)) | Out-Null
				Check (([System.IO.File]::ReadAllText((Join-Path $lab 'os7-task-jitter.timer'))) `
						-match '(?m)^RandomizedDelaySec=0\.5$') `
					'write: a sub-second -RandomizedDelay survives as decimal seconds'

				# A unit name systemd would parse as an OPTION can be written
				# and never again addressed - refused up front (measured:
				# `systemctl show -x.timer` exits 1, "invalid option").
				$dash = $null
				try { New-SystemdTimer -Name '-x' -OnCalendar 'daily' -Command '/usr/bin/true' }
				catch { $dash = $_.Exception.Message }
				Check ($dash -like '*cannot name a timer unit*') `
					'refuse: a leading dash cannot name a unit here'

				# THE ASK-BACK IS NOT DECORATION: when systemd does not load
				# what was written, the write must throw, not exit 0 - this is
				# the branch a fake that always answers 'loaded' leaves dead.
				$script:SystemdCommandOverride = {
					param($cmd, $a)
					$out = if ($cmd -eq 'systemd-analyze') { 'Normalized form: *-*-* 03:00:00' }
					elseif ($a -contains 'LoadState') { & $fx 'systemctl-show-loadstate-notfound.txt' }
					else { '' }
					[pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
				}
				$unloaded = $null
				try { New-SystemdTimer -Name os7-task-ghost -OnCalendar 'daily' -Command '/usr/bin/true' }
				catch { $unloaded = $_.Exception.Message }
				Check ($unloaded -like '*did not load*') `
					'verify: a written pair systemd will not load throws, not returns'

				# A spec systemd cannot parse must refuse BEFORE anything is
				# written — a broken timer on disk fires never and says nothing.
				$script:SystemdCommandOverride = {
					param($cmd, $a)
					if ($cmd -eq 'systemd-analyze') {
						return [pscustomobject]@{ StdOut = ''; ExitCode = 1
							StdErr = "Failed to parse calendar specification 'garbage': Invalid argument" }
					}
					[pscustomobject]@{ StdOut = ''; ExitCode = 0; StdErr = '' }
				}
				$bad = $null
				try { New-SystemdTimer -Name os7-task-bad -OnCalendar 'garbage' -Command '/usr/bin/true' }
				catch { $bad = $_.Exception.Message }
				Check ($bad -like '*cannot parse the calendar spec*') `
					'refuse: an unparseable spec is refused with systemd''s own words'
				Check (-not [System.IO.File]::Exists((Join-Path $lab 'os7-task-bad.timer'))) `
					'refuse: and nothing was written'

				# A line break in a value IS the next directive. Refused, not
				# escaped - unit syntax has no escape for it.
				$inj = $null
				try {
					New-SystemdTimer -Name os7-task-inj -OnCalendar 'daily' `
						-Command "/usr/bin/true`n[Service]"
				}
				catch { $inj = $_.Exception.Message }
				Check ($inj -like '*line break*') 'refuse: a newline cannot enter a unit file'

				# --- removing the pair ---------------------------------------
				$script:__sdCalls = @()
				# Again no .GetNewClosure() — #96.
				$script:SystemdCommandOverride = {
					param($cmd, $a)
					$script:__sdCalls += "$cmd $($a -join ' ')"
					$out = if ($a -contains 'LoadState') { & $fx 'systemctl-show-loadstate-notfound.txt' }
					else { '' }
					[pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
				}
				Remove-SystemdTimer -Name os7-task-probe -Confirm:$false
				Check (-not [System.IO.File]::Exists((Join-Path $lab 'os7-task-probe.timer'))) `
					'remove: the timer file is gone'
				Check (-not [System.IO.File]::Exists((Join-Path $lab 'os7-task-probe.service'))) `
					'remove: and the service beside it'
				Check ([bool](@($script:__sdCalls) -match 'daemon-reload')) 'remove: systemd was told'

				# A timer whose unit file is a PACKAGE's is refused by name —
				# recorded from sanoid.timer, whose FragmentPath is /usr/lib.
				$script:SystemdCommandOverride = {
					param($cmd, $a)
					$out = if ($a -contains 'LoadState') { & $fx 'systemctl-show-loadstate-loaded.txt' }
					else { '' }
					[pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
				}.GetNewClosure()
				$vendor = $null
				try { Remove-SystemdTimer -Name sanoid -Confirm:$false }
				catch { $vendor = $_.Exception.Message }
				Check ($vendor -like '*not in*' -or $vendor -like '*package*') `
					'remove: a package''s timer is refused' $vendor

				# A LONE .timer here is an override or a hand-authored unit -
				# the pair is what New- writes, and the pair is what Remove-
				# removes. (The MASK case - a symlink at this path - is
				# refused by the same function and proven against real
				# systemd in the container run: a symlink needs privileges
				# this self-test does not have on every host.)
				[System.IO.File]::WriteAllText((Join-Path $lab 'os7-task-lone.timer'), "[Timer]`n")
				$lone = $null
				try { Remove-SystemdTimer -Name os7-task-lone -Confirm:$false }
				catch { $lone = $_.Exception.Message }
				Check ($lone -like '*removes the PAIR*') `
					'remove: a lone timer file is not ours to delete' $lone
				Check ([System.IO.File]::Exists((Join-Path $lab 'os7-task-lone.timer'))) `
					'remove: and it was left untouched'
				[System.IO.File]::Delete((Join-Path $lab 'os7-task-lone.timer'))

				# THE ASK-BACK, again: deletion that leaves the unit loaded
				# (another file elsewhere shadows it) must throw, not exit 0.
				[System.IO.File]::WriteAllText((Join-Path $lab 'os7-task-shadow.timer'), "[Timer]`n")
				[System.IO.File]::WriteAllText((Join-Path $lab 'os7-task-shadow.service'), "[Service]`n")
				$script:SystemdCommandOverride = {
					param($cmd, $a)
					$out = if ($a -contains 'LoadState') { & $fx 'systemctl-show-loadstate-loaded.txt' }
					else { '' }
					[pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
				}.GetNewClosure()
				$shadow = $null
				try { Remove-SystemdTimer -Name os7-task-shadow -Confirm:$false }
				catch { $shadow = $_.Exception.Message }
				Check ($shadow -like '*shadowing*') `
					'remove: still loaded after deletion throws, not returns'
			}
			finally {
				$script:SystemdUnitDirectory = $unitDirBefore
				if ([System.IO.Directory]::Exists($lab)) {
					[System.IO.Directory]::Delete($lab, $true)
				}
			}
		}
		catch {
			Check $false 'the recorded section ran to the end' `
				"$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
		}
		finally { $script:SystemdCommandOverride = $null }
	}

	$pass = $script:__sdPass
	$fail = @($script:__sdFail)
	[Console]::Error.WriteLine("`nSystemd self-test: $pass passed, $($fail.Count) failed")
	if ($fail.Count) {
		[Console]::Error.WriteLine('FAILED: ' + ($fail -join '; '))
		throw "Systemd self-test failed: $($fail.Count) check(s)"
	}
	[Console]::Error.WriteLine('Systemd self-test: PASS')
}

Export-ModuleMember -Function @(
	'Get-SystemdUnit', 'Start-SystemdUnit', 'Stop-SystemdUnit', 'Restart-SystemdUnit',
	'Set-SystemdUnitStartup', 'Update-SystemdUnit',
	'Get-SystemdTimer', 'New-SystemdTimer', 'Remove-SystemdTimer',
	'Get-SystemdJournal',
	'Test-SystemdModule')
