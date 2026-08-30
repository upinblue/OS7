# =============================================================================
# OS/7 — scheduled tasks, as an operator asks about them
#
# Layer 3 of docs/POWERSHELL-SURFACE-PLAN.md P2. THIS FILE CONTAINS NO CALL TO
# `systemctl`, `journalctl` OR `systemd-analyze` — everything goes through
# powershell/Systemd, and installer/testing/check-layering.py holds that line
# as `P2-systemd`.
#
# WHAT IS OS/7's KNOWLEDGE HERE, and why this is not a pass-through:
#
#   * That `Get-ScheduledTask` DOES NOT EXIST on PowerShell for Linux, so this
#     is the verb a Windows admin reaches for and does not find — and until
#     this file, the answer to "what runs on a schedule here" was a systemd
#     command. BUILD-NOTES #113 is the defect this noun closes: the unattended
#     update check — the mechanism RELEASE-AND-UPDATE-PLAN §6 ships so that
#     "on a managed fleet nobody types Update-OS7" — was invisible to the
#     whole cmdlet surface. It is a TIMER, and Get-OS7Service deliberately
#     answers for services, the same split Windows itself makes between
#     services.msc and taskschd.msc.
#
#   * THE TRAP `Healthy` EXISTS TO NAME: `systemctl enable` on a timer arms
#     the NEXT boot and nothing else. Enabled and never started means enabled,
#     inactive, and NEVER FIRING — with nothing on the machine reporting a
#     problem (measured, BUILD-NOTES #113's session). `Enable-OS7ScheduledTask`
#     therefore enables AND starts, and `Healthy` is `$false` for the state
#     `enable` alone leaves behind.
#
#   * That RUNNING A TASK NOW means starting the SERVICE, not the timer —
#     starting the timer merely arms the schedule. And a manual run does not
#     move `LastRun`, because the schedule did not fire (measured); it moves
#     `LastResult`.
#
#   * WHICH tasks are an operator's to remove. `Register-OS7ScheduledTask`
#     writes units named `os7-task-<name>`, and `Unregister-OS7ScheduledTask`
#     refuses anything else BY NAME: sanoid.timer and os7-update-check.timer
#     are the product's, shipped by packages, and are disabled rather than
#     deleted.
#
# Dot-sourced by OS7.psm1.
# =============================================================================

# Registered tasks are named so that they are recognisable in every listing,
# match the `os7-*` pattern in $script:OS7ServicePatterns (so -OS7Only sees
# them), and are provably NOT a package's units — which is what makes
# Unregister's refusal rule decidable by name.
$script:OS7TaskPrefix = 'os7-task-'

function Resolve-OS7TaskName {
	<#
	.SYNOPSIS
		Internal. A task name as the timer unit's base name, prefixed.
	#>
	param([Parameter(Mandatory)][string]$Name)

	$base = $Name -replace '\.timer$', ''
	if (-not $base.StartsWith($script:OS7TaskPrefix)) {
		$base = "$($script:OS7TaskPrefix)$base"
	}
	return $base
}

function Get-OS7ScheduledTask {
	<#
	.SYNOPSIS
		What runs on a schedule on this machine, and whether it actually will.

	.DESCRIPTION
		`Healthy` IS NOT `is-active`, and for a timer the trap has a specific
		shape: `systemctl enable` arms the NEXT boot only, so a timer can be
		enabled, inactive, and NEVER FIRING, with nothing on the machine
		reporting a problem (measured). `Healthy` is `$false` for exactly that
		state, and for a task whose last run did not succeed. It is `$true`
		for a disabled task that is not running — that is what disabled means.
		It is `$null` — never `$true` — when the detail was not looked up,
		because a check that did not run must not read as one that passed.

		`NextRun` is `$null` for a task that will not run again as things
		stand. `LastRun` is when the SCHEDULE last fired; a manual
		`Start-OS7ScheduledTask` does not move it (measured) — the run it
		causes shows in `LastResult`.

		Disabled tasks are listed too. systemd's own `list-timers` cannot see
		a timer that is neither enabled nor active (measured), which is why
		this goes through the Systemd layer's union of two lists — a task you
		registered `-Disabled` does not vanish from the inventory.

	.PARAMETER Name
		One task, or a glob. `Get-OS7ScheduledTask demo` finds
		`os7-task-demo`; package timers are asked for by their full name
		(`sanoid.timer`, `os7-update-check.timer`). Implies the detail lookup.

	.PARAMETER OS7Only
		Only the schedules this product is made of: the unattended update
		check, the backup snapshots and replication, and anything registered
		through Register-OS7ScheduledTask.

	.PARAMETER Detailed
		Look up state, schedule, catch-up policy and the last run's outcome
		for every task listed. Several systemd questions per task, so it is a
		choice rather than a default.

	.EXAMPLE
		Get-OS7ScheduledTask -OS7Only -Detailed | Format-Table Name, NextRun, LastRun, Healthy

	.EXAMPLE
		Get-OS7ScheduledTask os7-update-check.timer
	#>
	[CmdletBinding()]
	param(
		[string]$Name,
		[switch]$OS7Only,
		[switch]$Detailed
	)

	Import-OS7SystemdLayer

	$splat = @{}
	if ($Name) {
		# A bare name that is not a glob and not already a unit name is first
		# tried as a registered task's short name — `demo` means
		# `os7-task-demo` — and asked for verbatim when that finds nothing.
		if ($Name -notmatch '[*?\[]' -and -not $Name.EndsWith('.timer') -and
			-not $Name.StartsWith($script:OS7TaskPrefix) -and
			@(Get-SystemdTimer -Name (Resolve-OS7TaskName $Name)).Count -gt 0) {
			$Name = Resolve-OS7TaskName $Name
		}
		$splat.Name = $Name
	}
	if ($Detailed) { $splat.Detailed = $true }

	foreach ($t in @(Get-SystemdTimer @splat)) {
		if ($OS7Only -and -not (Test-OS7ServiceName $t.Name)) { continue }

		# The last run's outcome lives on the SERVICE the timer activates, not
		# on the timer. A service that has never run is not in `list-units` at
		# all (measured), and that reads as "no outcome yet" — $null.
		$lastResult = $null
		if ($t.Detailed -and $t.Activates) {
			$svc = @(Get-SystemdUnit -Name $t.Activates)
			if ($svc.Count -gt 0) { $lastResult = $svc[0].Result }
		}

		[pscustomobject]@{
			Name        = $t.Name
			Description = $t.Description
			# LOCAL time, deliberately — the same clock the calendar spec is
			# written against (systemd interprets `Sun 03:00` in the machine's
			# zone), and the backup convention B13/B14: units run UTC, cmdlets
			# render local. The first machine picture showed `Schedule: Sun
			# 03:00:00` beside `NextRun: 01:00:00` UTC, which reads as a bug
			# in whichever half the operator trusts less.
			NextRun     = if ($null -ne $t.NextElapse) { $t.NextElapse.ToLocalTime() } else { $null }
			LastRun     = if ($null -ne $t.LastTrigger) { $t.LastTrigger.ToLocalTime() } else { $null }
			LastResult  = $lastResult
			Activates   = $t.Activates
			StartupType = $t.StartupType
			ActiveState = $t.ActiveState
			SubState    = $t.SubState
			Schedule    = $t.Schedule
			Persistent  = $t.Persistent
			IsOS7       = (Test-OS7ServiceName $t.Name)
			# $null until the detail was fetched — see the description.
			Healthy     = if (-not $t.Detailed) { $null }
			# THE TRAP: enabled at boot, not active now — armed for the next
			# boot and firing never until then. `enable` alone leaves a timer
			# in exactly this state (#115). `-like`, not `-eq`: systemd also
			# spells `enabled-runtime`, which is the same trap wearing /run.
			elseif ($t.StartupType -like 'enabled*' -and $t.ActiveState -ne 'active') { $false }
			# The last run failed, and the schedule will keep repeating it.
			elseif ($lastResult -and $lastResult -ne 'success') { $false }
			# The inverse state — active now, disabled at boot — reads $true
			# DELIBERATELY: it is what "started without enabling" means, both
			# facts are in their own columns, and the update-check timer on a
			# freshly installed machine sits in exactly this state.
			else { $true }
		}
	}
}

function Enable-OS7ScheduledTask {
	<#
	.SYNOPSIS
		Makes a task run on its schedule — from now on, and after reboots.

	.DESCRIPTION
		ENABLE AND START, DELIBERATELY BOTH. systemd's `enable` arms the next
		boot and nothing else: a timer that is enabled and never started is
		enabled, inactive, and never fires, and nothing on the machine says so
		(measured — the state Get-OS7ScheduledTask reports as unhealthy). The
		answer comes from asking systemd again afterwards, not from the
		commands' exit codes.

	.EXAMPLE
		Enable-OS7ScheduledTask os7-update-check.timer
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][string]$Name)

	Import-OS7SystemdLayer
	$unit = (Resolve-OS7TaskUnit $Name)
	Set-SystemdUnitStartup -Name $unit -Startup Enabled -WhatIf:$WhatIfPreference | Out-Null
	Start-SystemdUnit -Name $unit -WhatIf:$WhatIfPreference | Out-Null
	Get-OS7ScheduledTask -Name $unit -Detailed
}

function Disable-OS7ScheduledTask {
	<#
	.SYNOPSIS
		Stops a task's schedule — now, and at the next boot.

	.DESCRIPTION
		The mirror of Enable-OS7ScheduledTask: stop AND disable, because
		`disable` alone leaves the timer armed until the next reboot. The unit
		files stay — a disabled task remains in Get-OS7ScheduledTask's
		inventory, which is the difference between disabling and
		Unregister-OS7ScheduledTask.

	.EXAMPLE
		Disable-OS7ScheduledTask os7-task-nightly-report
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][string]$Name)

	Import-OS7SystemdLayer
	$unit = (Resolve-OS7TaskUnit $Name)
	# ONE gate for the WHOLE operation. Gating the halves separately would
	# let -Confirm interrupt between stop and disable, leaving the
	# stopped-but-enabled mirror of the #115 half-state.
	if (-not $PSCmdlet.ShouldProcess($unit, 'stop now and disable at boot')) {
		return Get-OS7ScheduledTask -Name $unit -Detailed
	}
	Stop-SystemdUnit -Name $unit -Confirm:$false | Out-Null
	Set-SystemdUnitStartup -Name $unit -Startup Disabled -Confirm:$false | Out-Null
	Get-OS7ScheduledTask -Name $unit -Detailed
}

function Start-OS7ScheduledTask {
	<#
	.SYNOPSIS
		Runs a task now, waits for it, and reports what happened.

	.DESCRIPTION
		THE SERVICE IS STARTED, NOT THE TIMER — starting a timer merely arms
		the schedule (measured). This waits for the run to finish, because the
		alternative is reporting that a job was accepted, which is an exit
		code and not an answer.

		A manual run does not move `LastRun` — the schedule did not fire. It
		moves `LastResult`, which is the run's actual outcome.

	.EXAMPLE
		Start-OS7ScheduledTask os7-update-check.timer
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][string]$Name)

	Import-OS7SystemdLayer
	$unit = (Resolve-OS7TaskUnit $Name)
	$task = @(Get-OS7ScheduledTask -Name $unit -Detailed)
	if ($task.Count -eq 0) {
		throw [System.InvalidOperationException]::new(
			"There is no scheduled task $unit on this machine.")
	}
	$service = $task[0].Activates
	if (-not $service) { $service = ($unit -replace '\.timer$', '.service') }

	Start-SystemdUnit -Name $service -WhatIf:$WhatIfPreference | Out-Null
	Get-OS7ScheduledTask -Name $unit -Detailed
}

function Resolve-OS7TaskUnit {
	<#
	.SYNOPSIS
		Internal. A task name as the timer unit it means, or a loud refusal.

	.DESCRIPTION
		`demo` resolves to `os7-task-demo.timer` when that exists; a full unit
		name (`sanoid.timer`) passes through. What must not happen is a verb
		acting on a unit the name only nearly meant.
	#>
	param([Parameter(Mandatory)][string]$Name)

	# ONE task. A glob would fall apart under the verbs: `systemctl stop`
	# expands globs and `systemctl enable`/`disable` refuse them (measured),
	# so `Disable- 'sanoid*'` would stop the timer NOW and fail to disable it
	# — the mirror of the #115 half-state, manufactured by our own cmdlet.
	if ($Name -match '[*?\[]') {
		throw [System.ArgumentException]::new(
			"'$Name' is a pattern. The task verbs act on ONE task — list with " +
			'Get-OS7ScheduledTask (which takes globs) and pipe the names one by one.')
	}

	$candidates = @(
		if ($Name.EndsWith('.timer')) { $Name } else { "$Name.timer" }
	)
	if (-not $Name.StartsWith($script:OS7TaskPrefix) -and $Name -notmatch '\.timer$') {
		$candidates = @("$(Resolve-OS7TaskName $Name).timer") + $candidates
	}
	foreach ($c in $candidates) {
		if (@(Get-SystemdTimer -Name $c).Count -gt 0) { return $c }
	}
	throw [System.InvalidOperationException]::new(
		"There is no scheduled task named $Name on this machine (asked systemd for: " +
		"$($candidates -join ', ')).")
}

function Register-OS7ScheduledTask {
	<#
	.SYNOPSIS
		Creates a scheduled task and reports it armed.

	.DESCRIPTION
		The task is a systemd timer+service pair named `os7-task-<name>`,
		written to /etc/systemd/system — the prefix is what makes it
		recognisably an operator's task and provably not a package's, which is
		the line Unregister-OS7ScheduledTask holds.

		THE SCHEDULE IS VALIDATED BEFORE ANYTHING IS WRITTEN, by the parser
		that will read it (`systemd-analyze calendar`, through the Systemd
		layer) — a spec systemd cannot parse would otherwise become a timer
		that never fires and reports nothing.

		Unless `-Disabled`, the task is enabled AND started, and the answer is
		systemd's own afterwards: registered means `NextRun` has a value, not
		that four commands exited 0. `-Disabled` registers the definition only
		— Enable-OS7ScheduledTask arms it later.

		NO SECRETS IN THE COMMAND (P7): the unit file is world-readable and
		the command line shows in systemd's own tooling. A task that needs a
		credential reads it from a root-owned 0600 file at run time.

		WHAT YOU TYPE IS WHAT RUNS: `%` and `$` are escaped on the way into
		the unit file, because systemd would otherwise expand them there —
		`%m` into the machine id, `$VAR` from the (empty) environment — and
		run a different command than the operator typed, with nothing
		reporting it. A task that WANTS systemd's specifiers is authored with
		New-SystemdTimer, whose contract is systemd's vocabulary verbatim.

		THE SCHEDULE THAT ALREADY EXISTS IS NOT DUPLICATED HERE: backup
		snapshots are sanoid's own timer (BACKUP-PLAN) and update staging is
		os7-update-check.timer — this cmdlet is for the fleet's own jobs, not
		a second copy of the product's.

	.PARAMETER Name
		The task's name. `nightly-report` becomes `os7-task-nightly-report`.

	.PARAMETER Command
		A PowerShell command line. It runs as
		`pwsh -NoProfile -NonInteractive -Command <command>` — Import-Module
		what it needs; profiles do not run.

	.PARAMETER Execute
		An absolute path to a program, for a task that is not PowerShell.

	.PARAMETER Arguments
		Arguments for -Execute, verbatim.

	.PARAMETER Daily
		Run every day at -At.

	.PARAMETER Weekly
		Run every week on -DayOfWeek at -At.

	.PARAMETER DayOfWeek
		Monday…Sunday, for -Weekly.

	.PARAMETER At
		The time of day, `HH:mm` or `HH:mm:ss`.

	.PARAMETER OnCalendar
		A raw systemd calendar spec (or several), for every schedule the
		convenience parameters cannot say — `Mon..Fri 03:00`,
		`*-*-01 06:00:00`. The escape hatch, on the A6 argument: a curated
		surface that cannot be escaped would have to be complete.

	.PARAMETER User
		Run as this account instead of root.

	.PARAMETER Persistent
		Catch up after downtime: a machine that was off at the scheduled time
		runs the job when it returns.

	.PARAMETER RandomizedDelay
		Spread a fleet's runs over this window — a thousand machines must not
		start the same job the same second.

	.PARAMETER Disabled
		Write the task but do not arm it.

	.PARAMETER Force
		Replace an existing task of the same name. Without it, a name that is
		already taken is refused rather than silently overwritten.

	.EXAMPLE
		Register-OS7ScheduledTask -Name pool-scrub -Weekly -DayOfWeek Sunday -At 03:00 `
			-Command 'Import-Module Zfs; Start-ZpoolScrub -Pool rpool'

	.EXAMPLE
		Register-OS7ScheduledTask -Name compliance -OnCalendar 'Mon..Fri 06:30' `
			-Command 'Import-Module OS7; Get-OS7BackupStatus | ConvertTo-Json > /var/lib/os7/compliance.json'
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string]$Name,
		[string]$Command,
		[string]$Execute,
		[string]$Arguments,
		[switch]$Daily,
		[switch]$Weekly,
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
		[string]$DayOfWeek,
		[string]$At,
		[string[]]$OnCalendar,
		[string]$User,
		[string]$Description,
		[switch]$Persistent,
		[timespan]$RandomizedDelay,
		[switch]$Disabled,
		[switch]$Force
	)

	Import-OS7SystemdLayer

	# --- exactly one action ------------------------------------------------
	if (-not ($Command -xor $Execute)) {
		throw [System.ArgumentException]::new(
			'A task does exactly one thing: pass -Command (PowerShell) or -Execute (a program), ' +
			'not both and not neither.')
	}
	if ($Execute -and -not $Execute.StartsWith('/')) {
		throw [System.ArgumentException]::new(
			"systemd runs the task without a shell, so -Execute must be an absolute path. Got: $Execute")
	}

	# --- exactly one trigger -----------------------------------------------
	$triggers = @(@($Daily, $Weekly, [bool]$OnCalendar) | Where-Object { $_ })
	if ($triggers.Count -ne 1) {
		throw [System.ArgumentException]::new(
			'A task has exactly one trigger: -Daily, -Weekly or -OnCalendar.')
	}
	if (($Daily -or $Weekly) -and -not $At) {
		throw [System.ArgumentException]::new('-Daily and -Weekly need -At (HH:mm).')
	}
	if ($Weekly -and -not $DayOfWeek) {
		throw [System.ArgumentException]::new('-Weekly needs -DayOfWeek.')
	}
	# A parameter that is accepted and then not used is a schedule the
	# operator believes in and the machine does not have: -OnCalendar 'daily'
	# with -At 03:00 would run at MIDNIGHT and register green.
	if ($OnCalendar -and $At) {
		throw [System.ArgumentException]::new(
			'-At belongs to -Daily and -Weekly; an -OnCalendar spec carries its own time of day.')
	}
	if ($DayOfWeek -and -not $Weekly) {
		throw [System.ArgumentException]::new('-DayOfWeek belongs to -Weekly.')
	}
	if ($At) {
		if ($At -notmatch '^([01]?\d|2[0-3]):([0-5]\d)(:[0-5]\d)?$') {
			throw [System.ArgumentException]::new(
				"-At is a time of day, HH:mm or HH:mm:ss. Got: $At")
		}
		if ($At -notmatch ':\d\d:\d\d$') { $At = "${At}:00" }
	}

	$specs = if ($OnCalendar) { $OnCalendar }
	elseif ($Daily) { @("*-*-* $At") }
	else {
		# systemd spells weekdays with three letters.
		$abbr = @{ Monday = 'Mon'; Tuesday = 'Tue'; Wednesday = 'Wed'; Thursday = 'Thu'
			Friday = 'Fri'; Saturday = 'Sat'; Sunday = 'Sun' }[$DayOfWeek]
		@("$abbr *-*-* $At")
	}

	# --- the command line --------------------------------------------------
	# THIS LAYER PROMISES "WHAT YOU TYPE IS WHAT RUNS", so everything systemd
	# would interpret in an ExecStart line is escaped: backslash and quote for
	# its quoting, `%` for its specifiers (`%m` is the machine id — silently
	# substituted into the command, measured), `$` for its environment
	# substitution (a PowerShell command line is full of them). A task that
	# WANTS specifiers is authored with New-SystemdTimer, whose contract is
	# systemd's vocabulary verbatim — the A6 escape hatch.
	$exec = if ($Execute) {
		# A path with a space would be word-split into a different binary
		# (`/opt/my app/run.sh` runs /opt/my), loading cleanly and failing
		# 203/EXEC at the first elapse, days later. Quote it systemd's way.
		$exe = $Execute.Replace('%', '%%').Replace('$', '$$')
		if ($exe -match '[\s"\\'']') {
			$exe = '"' + $exe.Replace('\', '\\').Replace('"', '\"') + '"'
		}
		if ($Arguments) { "$exe $($Arguments.Replace('%', '%%').Replace('$', '$$'))" } else { $exe }
	}
	else {
		# systemd's own quoting: backslash-escapes inside double quotes. The
		# absolute pwsh path because ExecStart runs without a shell or PATH.
		$escaped = $Command.Replace('\', '\\').Replace('"', '\"').Replace('%', '%%').Replace('$', '$$')
		"/usr/bin/pwsh -NoProfile -NonInteractive -Command `"$escaped`""
	}

	$base = Resolve-OS7TaskName $Name
	if ($base -notmatch '^[A-Za-z0-9._-]+$') {
		throw [System.ArgumentException]::new(
			"'$Name' cannot name a task: letters, digits, '.', '_' and '-' only.")
	}
	if (-not $Description) { $Description = "OS/7 task: $($base.Substring($script:OS7TaskPrefix.Length))" }

	if (-not $PSCmdlet.ShouldProcess($base, 'register scheduled task')) {
		return
	}

	$new = @{
		Name        = $base
		Command     = $exec
		OnCalendar  = $specs
		# Description= takes % specifiers too; this layer's contract is
		# literal text.
		Description = $Description.Replace('%', '%%')
	}
	if ($User) { $new.User = $User }
	if ($Persistent) { $new.Persistent = $true }
	if ($Force) { $new.Force = $true }
	if ($PSBoundParameters.ContainsKey('RandomizedDelay')) { $new.RandomizedDelay = $RandomizedDelay }
	New-SystemdTimer @new | Out-Null
	Write-OS7Step "task written: $base.timer + $base.service"

	if ($Disabled) {
		return Get-OS7ScheduledTask -Name "$base.timer" -Detailed
	}

	# Enable AND start — enable alone arms the next boot and nothing else
	# (measured, #115; the trap Healthy names).
	Set-SystemdUnitStartup -Name "$base.timer" -Startup Enabled | Out-Null
	Start-SystemdUnit -Name "$base.timer" | Out-Null

	# Registered means systemd says it will run — not that the commands above
	# exited 0. NOT `@(...)[0]`: under Set-StrictMode Latest, indexing an EMPTY
	# array THROWS (measured), so the explanation branch would be unreachable —
	# #112's shape, a strict-mode error where the explanation belonged.
	$task = @(Get-OS7ScheduledTask -Name "$base.timer" -Detailed)
	if ($task.Count -eq 0) {
		throw [System.InvalidOperationException]::new(
			"$base.timer was written and enabled but cannot be read back at all. " +
			'The unit files are left in place for inspection.')
	}
	$task = $task[0]
	if ($task.ActiveState -ne 'active' -or $null -eq $task.NextRun) {
		throw [System.InvalidOperationException]::new(
			"$base.timer was written and enabled but systemd does not schedule it " +
			"(ActiveState=$($task.ActiveState), NextRun=$($task.NextRun ?? 'none')). " +
			'The unit files are left in place for inspection.')
	}
	return $task
}

function Unregister-OS7ScheduledTask {
	<#
	.SYNOPSIS
		Removes a task Register-OS7ScheduledTask created — and only such a
		task.

	.DESCRIPTION
		THE REFUSAL IS THE FEATURE. Only `os7-task-*` units are removable
		here: sanoid.timer, os7-backup-replicate.timer and
		os7-update-check.timer are the product's, shipped and owned by
		packages, and deleting a package's unit file leaves dpkg believing in
		a file that is gone. Those are silenced with
		Disable-OS7ScheduledTask, which keeps them in the inventory.

	.EXAMPLE
		Unregister-OS7ScheduledTask os7-task-nightly-report
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param([Parameter(Mandatory)][string]$Name)

	Import-OS7SystemdLayer

	$base = $Name -replace '\.timer$', ''
	if (-not $base.StartsWith($script:OS7TaskPrefix)) {
		# An EXPLICIT unit name (`sanoid.timer`) without the prefix is the
		# refusal — the one verb that deletes must never read a unit name as
		# a different unit. A bare SHORT name (`demo`) means what Register
		# made of it, unconditionally: `os7-task-demo`. If that task does not
		# exist, Remove-SystemdTimer's own error names exactly the unit that
		# was looked for.
		if ($Name.EndsWith('.timer')) {
			throw [System.InvalidOperationException]::new(
				"$Name is not an operator-registered task (they are named $($script:OS7TaskPrefix)*). " +
				'A package''s schedule is disabled with Disable-OS7ScheduledTask, not unregistered — ' +
				'removing its unit file would leave the package manager believing in a file that is gone.')
		}
		$base = "$($script:OS7TaskPrefix)$base"
	}

	if (-not $PSCmdlet.ShouldProcess("$base.timer", 'stop, disable and remove')) { return }

	Remove-SystemdTimer -Name $base -Confirm:$false
	Write-OS7Step "task removed: $base.timer + $base.service"
}
