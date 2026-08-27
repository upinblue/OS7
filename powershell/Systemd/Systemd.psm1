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
		$out = & $Command @Arguments 2> $errFile
		return [pscustomobject]@{
			StdOut   = ($out -join "`n")
			ExitCode = $LASTEXITCODE
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
	'Get-SystemdJournal',
	'Test-SystemdModule')
