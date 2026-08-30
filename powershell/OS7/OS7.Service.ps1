# =============================================================================
# OS/7 — services and the log, as an operator asks about them
#
# Layer 3 of docs/POWERSHELL-SURFACE-PLAN.md P2. THIS FILE CONTAINS NO CALL TO
# `systemctl` OR `journalctl` — both go through powershell/Systemd, and
# installer/testing/check-layering.py holds that line as `P2-systemd`.
#
# WHAT IS OS/7's KNOWLEDGE HERE, and why this is not a pass-through:
#
#   * WHICH services are this product's. An operator asking "is my machine
#     healthy" does not mean the 56 units Ubuntu ships; they mean the handful
#     that make an OS/7 machine an OS/7 machine — backup, identity, the update
#     train, the management agents. `-OS7Only` is that list, and it is written
#     down once here rather than typed differently every time.
#   * That `Get-Service` DOES NOT EXIST on PowerShell for Linux (measured, §1.1
#     of the plan), so this is not a rename of something that works — it is the
#     verb an admin reaches for and does not find.
#   * That the install log is a FILE and not a journal, and an operator looking
#     for "what happened during setup" should not have to know that.
#
# Dot-sourced by OS7.psm1.
# =============================================================================

# The services that make this an OS/7 machine rather than an Ubuntu one.
# Globs, matched against the unit name.
#
# WRITTEN DOWN ONCE. `Get-OS7SystemStatus` will want the same list, so will a
# support bundle, and three hand-typed copies of it drift — the argument Z6 and
# BACKUP-PLAN both make about numbers appearing in more than one place.
$script:OS7ServicePatterns = @(
	# OS/7's own
	'os7-*',
	# Identity: Entra sign-in goes through authd and its broker
	'authd*', 'snap.authd-msentraid.*',
	# The management path this product exists for
	'intune*', 'microsoft-identity-broker*', 'azcmagent*', 'himds*', 'gcad*', 'extd*',
	# The things an OS/7 machine is unreachable or untrusted without
	'ssh*', 'chrony*', 'systemd-resolved*', 'zfs-*',
	# The backup engine. The snapshot schedule IS sanoid's own timer
	# (BACKUP-PLAN: OS/7 ships no competing one), so a list that answers
	# "which schedules are this product's" without sanoid.timer would be
	# BUILD-NOTES #113 in a second shape. Replication rides os7-backup-*,
	# which os7-* already matches. Added 2026-08-29 with Get-OS7ScheduledTask.
	'sanoid*'
)

function Import-OS7SystemdLayer {
	<#
	.SYNOPSIS
		Internal. Make the Systemd module available, lazily.

	.DESCRIPTION
		LAZILY, AND NEVER AT IMPORT TIME — BUILD-NOTES #38, and #82 is that rule
		being broken in this module and costing a day of builds.
	#>
	if (Get-Module -Name Systemd) { return }

	$candidates = @(
		(Join-Path (Split-Path -Parent $PSScriptRoot) 'Systemd/Systemd.psd1'),
		'/usr/local/share/powershell/Modules/Systemd/Systemd.psd1'
	)
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			Import-Module $c -Force -ErrorAction Stop
			Write-OS7Step "systemd layer: $c"
			return
		}
	}
	Import-Module Systemd -Force -ErrorAction Stop
	Write-OS7Step 'systemd layer: Systemd (by name)'
}

function Test-OS7ServiceName {
	<#
	.SYNOPSIS
		Internal. Is this one of the services that make an OS/7 machine?
	#>
	param([Parameter(Mandatory)][string]$Name)

	foreach ($p in $script:OS7ServicePatterns) {
		if ($Name -like $p) { return $true }
	}
	return $false
}

function Get-OS7Service {
	<#
	.SYNOPSIS
		The services on this machine, and whether they are actually well.

	.DESCRIPTION
		`Healthy` IS NOT `is-active`, IN BOTH DIRECTIONS.

		It is `$false` when something is actually wrong: the unit failed, it is
		in a restart loop (`SubState = auto-restart`, which `is-active` reports
		as `active`), it stopped for a reason that was not success, or it is
		enabled at boot and is a service that STAYS up and is not up.

		It is `$true` for a unit that is simply not running and is not supposed
		to be. THE FIRST VERSION OF THIS FIELD GOT THAT WRONG and it took real
		output to see it: `zfs-mount.service` is a `oneshot`, it succeeded, it
		is `inactive/dead` because that is what a finished oneshot looks like —
		and it was reported as unhealthy on a perfectly well machine. `Type` is
		what makes the question answerable, and a field that cries wolf is a
		field that gets ignored.

		It is `$null` — never `$true` — when the detail was not looked up,
		because a check that did not run must not read as one that passed.

		`-OS7Only` is the list an operator means when they ask whether the
		machine is well: OS/7's own units, the identity path, the management
		agents, and the services without which the machine is unreachable or
		untrusted. Not the 56 units Ubuntu ships.

	.PARAMETER Name
		One service, or a glob. Implies the detail lookup.

	.PARAMETER State
		systemd's own words — `running`, `failed`, `active`, `inactive`.

	.PARAMETER OS7Only
		Only the services this product is made of.

	.PARAMETER Detailed
		Look up Result, RestartCount and StartupType for every unit listed. One
		`systemctl show` per unit, so it is a choice rather than a default.

	.EXAMPLE
		Get-OS7Service -OS7Only -Detailed | Format-Table Name, ActiveState, Healthy

	.EXAMPLE
		Get-OS7Service -State failed
	#>
	[CmdletBinding()]
	param(
		[string]$Name,
		[string]$State,
		[switch]$OS7Only,
		[switch]$Detailed
	)

	Import-OS7SystemdLayer

	$splat = @{ Type = 'service' }
	if ($Name) { $splat.Name = $Name }
	if ($State) { $splat.State = $State }
	if ($Detailed) { $splat.Detailed = $true }

	foreach ($u in @(Get-SystemdUnit @splat)) {
		if ($OS7Only -and -not (Test-OS7ServiceName $u.Name)) { continue }

		[pscustomobject]@{
			Name         = $u.Name
			Description  = $u.Description
			ActiveState  = $u.ActiveState
			SubState     = $u.SubState
			StartupType  = $u.StartupType
			Result       = $u.Result
			RestartCount = $u.RestartCount
			MainPid      = $u.MainPid
			ActiveSince  = $u.ActiveSince
			IsOS7        = (Test-OS7ServiceName $u.Name)
			ServiceType  = $u.ServiceType
			# $null until the detail was fetched — see the description.
			Healthy      = if (-not $u.Detailed) { $null }
			# Something is actually wrong: it failed, it is in a restart loop, or
			# it stopped for a reason that was not success.
			elseif ($u.ActiveState -eq 'failed' -or $u.SubState -eq 'auto-restart' -or
				($u.Result -and $u.Result -ne 'success')) { $false }
			# It is supposed to come up at boot, it is a service that STAYS up,
			# and it is not up. `Type` is what makes this answerable: a oneshot
			# that has run is `inactive/dead` and is SUPPOSED to be — measured on
			# zfs-mount.service, which the first version of this field reported
			# as unhealthy on a perfectly well machine.
			elseif ($u.StartupType -eq 'enabled' -and $u.ActiveState -ne 'active' -and
				$u.ServiceType -notin @('oneshot', 'idle')) { $false }
			else { $true }
		}
	}
}

function Start-OS7Service {
	<#
	.SYNOPSIS
		Starts a service and reports what it became.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][string]$Name)
	Import-OS7SystemdLayer
	Start-SystemdUnit -Name $Name -WhatIf:$WhatIfPreference | Out-Null
	Get-OS7Service -Name $Name -Detailed
}

function Stop-OS7Service {
	<#
	.SYNOPSIS
		Stops a service and reports what it became.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param([Parameter(Mandatory)][string]$Name)
	Import-OS7SystemdLayer
	Stop-SystemdUnit -Name $Name -WhatIf:$WhatIfPreference -Confirm:$false | Out-Null
	Get-OS7Service -Name $Name -Detailed
}

function Restart-OS7Service {
	<#
	.SYNOPSIS
		Restarts a service and reports what it became.

	.DESCRIPTION
		The answer comes from asking systemd again afterwards, not from
		`systemctl`'s exit code: a restart JOB succeeds for a service that then
		dies, which leaves a successful command and a failed unit.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param([Parameter(Mandatory)][string]$Name)
	Import-OS7SystemdLayer
	Restart-SystemdUnit -Name $Name -WhatIf:$WhatIfPreference -Confirm:$false | Out-Null
	Get-OS7Service -Name $Name -Detailed
}

function Set-OS7Service {
	<#
	.SYNOPSIS
		Whether a service starts at boot.

	.DESCRIPTION
		`Automatic`, `Manual` and `Disabled` are the words a Windows admin
		knows, mapped to systemd's `enable`, `disable` and `mask`. `Manual` is
		`disable`: systemd has no third state between "starts at boot" and "does
		not", and `mask` is stronger than Windows' Disabled — it makes the unit
		unstartable even by hand, which is why it has its own name here rather
		than being hidden behind `Disabled`.

	.EXAMPLE
		Set-OS7Service -Name os7-backup-replicate.timer -StartupType Automatic
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)]
		[ValidateSet('Automatic', 'Manual', 'Disabled', 'Blocked')]
		[string]$StartupType
	)

	Import-OS7SystemdLayer
	$startup = switch ($StartupType) {
		'Automatic' { 'Enabled' }
		'Manual' { 'Disabled' }
		'Disabled' { 'Disabled' }
		'Blocked' { 'Masked' }
	}
	Set-SystemdUnitStartup -Name $Name -Startup $startup -WhatIf:$WhatIfPreference | Out-Null
	Get-OS7Service -Name $Name -Detailed
}

function Get-OS7Log {
	<#
	.SYNOPSIS
		The system log, as objects.

	.DESCRIPTION
		THE REASON POWERSHELL IS THE SHELL HERE. `journalctl | grep` is a text
		pipeline over a log that is already structured; this hands back records
		with a `[datetime]` timestamp, a priority that is both a number and a
		name, and a unit field — so `Group-Object Unit`, `Where-Object Priority
		-le 3` and `Sort-Object Timestamp` all mean what they say.

		`-OS7Only` narrows it to the services this product is made of, which is
		what somebody investigating an OS/7 machine means by "the log".

	.PARAMETER Unit
		One unit's entries.

	.PARAMETER Priority
		This severity and everything worse — journalctl's own semantics.

	.PARAMETER Since
	.PARAMETER Until
		A `[datetime]`, rendered invariantly for journalctl.

	.PARAMETER Tail
		The last N entries. 200 by default: a journal is large, and a default of
		"everything" is a cmdlet that hangs a terminal.

	.PARAMETER Boot
		`0` for this boot, `-1` for the previous one — which is the one that
		matters after a machine has come back from a crash.

	.EXAMPLE
		Get-OS7Log -Priority Error -Tail 200 | Group-Object Unit

	.EXAMPLE
		Get-OS7Log -OS7Only -Since (Get-Date).AddHours(-1)
	#>
	[CmdletBinding()]
	param(
		[string]$Unit,
		[ValidateSet('Emergency', 'Alert', 'Critical', 'Error', 'Warning', 'Notice',
			'Information', 'Debug')]
		[string]$Priority,
		[datetime]$Since,
		[datetime]$Until,
		[int]$Tail = 200,
		[int]$Boot,
		[switch]$OS7Only
	)

	Import-OS7SystemdLayer

	$splat = @{ Tail = $Tail }
	if ($Unit) { $splat.Unit = $Unit }
	if ($Priority) { $splat.Priority = $Priority }
	if ($PSBoundParameters.ContainsKey('Since')) { $splat.Since = $Since }
	if ($PSBoundParameters.ContainsKey('Until')) { $splat.Until = $Until }
	if ($PSBoundParameters.ContainsKey('Boot')) { $splat.Boot = $Boot }

	foreach ($e in @(Get-SystemdJournal @splat)) {
		# The filter is on the TRUSTED unit field. `ClaimedUnit` comes from the
		# sender and could name anything, which would let a log filter be
		# steered by the thing it is filtering.
		if ($OS7Only -and -not ($e.Unit -and (Test-OS7ServiceName $e.Unit))) { continue }
		$e
	}
}

function Get-OS7InstallLog {
	<#
	.SYNOPSIS
		What os7-setup did when this machine was installed.

	.DESCRIPTION
		A FILE AND NOT THE JOURNAL. `/var/log/os7-setup/install.log` is written
		by the installer with every step's self-proof in it (SETUP-PLAN L31) and
		is mode 0600 — it is the record of an install that happened before this
		system had a journal at all, and it survives a rollback because it is on
		the boot environment.

		Parsed into objects rather than handed back as text, so the same
		`Where-Object` an operator uses on `Get-OS7Log` works here too.

	.PARAMETER Path
		The log. Defaults to the installer's own location.

	.EXAMPLE
		Get-OS7InstallLog | Where-Object Message -match 'zpool'
	#>
	[CmdletBinding()]
	param([string]$Path = '/var/log/os7-setup/install.log')

	if (-not [System.IO.File]::Exists($Path)) {
		throw [System.IO.FileNotFoundException]::new(
			"There is no install log at $Path. It is written by os7-setup (SETUP-PLAN L31), " +
			'so a machine that was not installed by Setup — a live session, or one built ' +
			'another way — will not have one.')
	}

	$n = 0
	foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
		$n++
		if (-not $line.Trim()) { continue }
		# The installer writes `<ISO-8601> <LEVEL> <message>`, and a line that
		# does not match is passed through whole rather than dropped: a log
		# reader that silently discards what it cannot parse is a log reader
		# that hides the crash.
		if ($line -match '^(?<t>\S+)\s+(?<l>[A-Z]+)\s+(?<m>.*)$') {
			$stamp = [datetime]::MinValue
			$parsed = [datetime]::TryParse($Matches.t,
				[System.Globalization.CultureInfo]::InvariantCulture,
				[System.Globalization.DateTimeStyles]::AssumeUniversal -bor
				[System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$stamp)
			[pscustomobject]@{
				Line      = $n
				Timestamp = if ($parsed) { $stamp } else { $null }
				Level     = $Matches.l
				Message   = $Matches.m
				Raw       = $line
			}
		}
		else {
			[pscustomobject]@{
				Line = $n; Timestamp = $null; Level = $null; Message = $line; Raw = $line
			}
		}
	}
}
