# =============================================================================
# OS/7 — the clock, as an operator asks about it
#
# Layer 3 of docs/POWERSHELL-SURFACE-PLAN.md P2. THIS FILE CONTAINS NO CALL TO
# `chronyc`, `timedatectl`, `hwclock` OR `localectl` — those go through
# powershell/Time, and installer/testing/check-layering.py holds that line.
#
# WHY TIME IS TIER 1 AND NOT A CONVENIENCE. Kerberos refuses a ticket whose
# timestamp is more than five minutes from the KDC's clock, and Entra ID sign-in
# on this product goes through Kerberos-shaped machinery. A machine with a
# drifting clock does not report a clock problem: it reports that the user's
# password is wrong. That is the whole reason `Get-OS7TimeSynchronization` has a
# threshold in it rather than just reporting an offset and leaving the operator
# to know what a bad one looks like.
#
# WHAT IS OS/7's KNOWLEDGE HERE, and therefore why this file is not a
# pass-through:
#
#   * five minutes, and where the number comes from
#   * that "chronyd is not running" and "the clock is wrong" are different
#     answers to an operator and must not collapse into one boolean
#   * that OS/7 owns exactly one file in /etc/chrony/sources.d and must not
#     touch the ones Ubuntu ships
#
# Dot-sourced by OS7.psm1.
# =============================================================================

# THE KERBEROS SKEW. MIT Kerberos and Active Directory both default to five
# minutes (`clockskew = 300`), and Entra's Kerberos surface inherits it. It is a
# constant here rather than a literal in three places, and it is the reason the
# health answer is a threshold rather than a raw number.
$script:OS7MaxClockSkewSeconds = 300

# The one file OS/7 owns under /etc/chrony/sources.d. Named so that Ubuntu's
# `ubuntu-ntp-pools.sources` is never the file being rewritten: a machine that
# lost the distribution's pools because OS/7 wanted to add one server is a
# machine with fewer time sources than it started with.
$script:OS7ChronySourceName = 'os7'

function Import-OS7TimeLayer {
	<#
	.SYNOPSIS
		Internal. Make the Time module available, lazily.

	.DESCRIPTION
		LAZILY, AND NEVER AT IMPORT TIME — BUILD-NOTES #38, and #82 is that rule
		being broken in this module and costing a day of builds. Same shape as
		Import-OS7ZfsLayer and Import-OS7NetLayer.
	#>
	if (Get-Module -Name Time) { return }

	$candidates = @(
		(Join-Path (Split-Path -Parent $PSScriptRoot) 'Time/Time.psd1'),
		'/usr/local/share/powershell/Modules/Time/Time.psd1'
	)
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			Import-Module $c -Force -ErrorAction Stop
			Write-OS7Step "time layer: $c"
			return
		}
	}
	Import-Module Time -Force -ErrorAction Stop
	Write-OS7Step 'time layer: Time (by name)'
}

function Set-OS7TimeZone {
	<#
	.SYNOPSIS
		Sets this machine's time zone.

	.DESCRIPTION
		THE PAIR POWERSHELL LEAVES BROKEN. `Get-TimeZone` works on Linux and
		`Set-TimeZone` does not — measured on the shipped image, PowerShell
		7.6.5. P1 decided not to define Microsoft's name ourselves, because a
		free name is not free for ever and a shadowed cmdlet with a different
		parameter set is worse than a missing one. So this is the OS/7 name, and
		`Get-TimeZone` remains the way to read it.

		It writes the symlink and READS IT BACK, and it refuses a zone that is
		not in /usr/share/zoneinfo before writing anything — a symlink accepts
		any target, and the failure it leaves is a machine on UTC whose
		configuration says Berlin.

	.PARAMETER Id
		An IANA zone — `Europe/Berlin`. `(Get-ChildItem /usr/share/zoneinfo)`
		lists them, and so does the installer's screen 3.

	.EXAMPLE
		Set-OS7TimeZone -Id 'Europe/Berlin'
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][string]$Id)

	Import-OS7TimeLayer
	Set-SystemTimeZone -Id $Id
}

function Get-OS7Time {
	<#
	.SYNOPSIS
		The clock: local, UTC, the zone, and whether the hardware clock is kept
		in local time.

	.DESCRIPTION
		`RtcInLocalTime` is the field worth reading on a machine that dual-boots
		Windows. Windows keeps the hardware clock in LOCAL time by default and
		Linux keeps it in UTC, so a machine that boots both moves by the UTC
		offset every time it changes operating system — and a clock that is an
		hour out fails Kerberos, which presents as a password that will not work.

		`RtcIsDefault` says whether anybody decided: an absent /etc/adjtime
		means UTC, and "nobody configured this" is not the same fact as
		"somebody chose UTC".

	.EXAMPLE
		Get-OS7Time
	#>
	[CmdletBinding()]
	param()

	Import-OS7TimeLayer
	Get-SystemClock
}

function Get-OS7TimeSynchronization {
	<#
	.SYNOPSIS
		Whether this machine's clock is being disciplined, by whom, and whether
		it is close enough for Entra sign-in to work.

	.DESCRIPTION
		THREE OUTCOMES AND NOT TWO, because they are three different problems:

		  Synchronised = $null   chronyd could not be asked at all
		  Synchronised = $false  it was asked, and it is not disciplining
		  Synchronised = $true   it is

		A cmdlet that returned `$false` for "no daemon" would send an operator
		to look at NTP servers on a machine whose time service is simply not
		running. `$null` is the same rule `Get-OS7Version`'s `Drift` follows: a
		check that could not run must never read as one that failed cleanly.

		`WithinKerberosSkew` is the OS/7 policy on top of chrony's numbers. Five
		minutes is Kerberos's default `clockskew`, which Active Directory and
		Entra both inherit, and it is the threshold at which a clock problem
		starts presenting as an authentication problem.

	.EXAMPLE
		Get-OS7TimeSynchronization

	.EXAMPLE
		(Get-OS7TimeSynchronization).Sources | Where-Object State -eq Selected
	#>
	[CmdletBinding()]
	param()

	Import-OS7TimeLayer

	$tracking = $null
	$reason = $null
	try { $tracking = Get-ChronyTracking }
	catch { $reason = $_.Exception.Message }

	$sources = @()
	if ($tracking) {
		try { $sources = @(Get-ChronySource) } catch { }
	}

	# The offset that matters is how far THIS clock is from real time, which is
	# chrony's `System time` field. `LastOffset` is the last correction it
	# applied and is a much smaller number on a healthy machine — reporting that
	# one would make every machine look perfect.
	$offset = if ($tracking) { [math]::Abs($tracking.SystemTimeOffsetSeconds) } else { $null }

	[pscustomobject]@{
		Synchronised       = if ($tracking) { $tracking.Synchronised } else { $null }
		Reason             = $reason
		Source             = if ($tracking) { $tracking.Source } else { $null }
		Stratum            = if ($tracking) { $tracking.Stratum } else { $null }
		OffsetSeconds      = $offset
		LeapStatus         = if ($tracking) { $tracking.LeapStatus } else { $null }
		# $null when it could not be asked, for the same reason as above.
		WithinKerberosSkew = if ($null -eq $offset) { $null }
		else { $offset -lt $script:OS7MaxClockSkewSeconds }
		MaxSkewSeconds     = $script:OS7MaxClockSkewSeconds
		Servers            = @(Get-ChronySourceFile | ForEach-Object { $_.Servers } |
			ForEach-Object { $_.Address })
		Sources            = $sources
	}
}

function Set-OS7TimeSynchronization {
	<#
	.SYNOPSIS
		Points this machine at NTP servers.

	.DESCRIPTION
		WRITES ONE FILE THAT OS/7 OWNS, and never chrony.conf. Measured
		2026-08-27: NTP sources belong in `/etc/chrony/sources.d/*.sources`,
		`chronyc reload sources` applies them without restarting chronyd, and
		chrony's own README in that directory says both. Editing chrony.conf is
		the naive move and is wrong twice — a package upgrade owns that file,
		and a change in it does nothing until chronyd restarts.

		IT DOES NOT REPLACE UBUNTU'S POOLS. This writes `os7.sources` and leaves
		`ubuntu-ntp-pools.sources` alone, so a machine given a corporate NTP
		server keeps the distribution's as well. Use `-Exclusive` to disable the
		shipped pools, which is what a network with no outbound NTP needs.

	.PARAMETER NtpServer
		The servers. Written as `server <address> iburst`.

	.PARAMETER Pool
		Pools, written as `pool <address> iburst`.

	.PARAMETER Exclusive
		Also disable Ubuntu's shipped pools, by renaming their file aside. Not
		deleted: a machine that loses its only time source because somebody
		mistyped a hostname should be one `Move-Item` from working again.

	.EXAMPLE
		Set-OS7TimeSynchronization -NtpServer time.windows.com

	.EXAMPLE
		Set-OS7TimeSynchronization -NtpServer ntp1.corp.example, ntp2.corp.example -Exclusive
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[string[]]$NtpServer = @(),
		[string[]]$Pool = @(),
		[switch]$Exclusive
	)

	Import-OS7TimeLayer

	$result = Set-ChronySource -Name $script:OS7ChronySourceName -Server $NtpServer -Pool $Pool

	$disabled = @()
	if ($Exclusive) {
		foreach ($f in @(Get-ChronySourceFile)) {
			if ([System.IO.Path]::GetFileNameWithoutExtension($f.Path) -eq $script:OS7ChronySourceName) {
				continue
			}
			$aside = "$($f.Path).disabled-by-os7"
			if ($PSCmdlet.ShouldProcess($f.Path, 'move aside so only OS/7 sources are used')) {
				Move-Item -LiteralPath $f.Path -Destination $aside -Force
				$disabled += $aside
			}
		}
		# Reload again: the first reload happened before these were moved.
		if ($disabled.Count -and $PSCmdlet.ShouldProcess('chronyd', 'reload sources')) {
			Set-ChronySource -Name $script:OS7ChronySourceName -Server $NtpServer -Pool $Pool | Out-Null
		}
	}

	[pscustomobject]@{
		Path     = $result.Path
		Servers  = $result.Servers
		Pools    = $result.Pools
		Reloaded = $result.Reloaded
		Detail   = $result.Detail
		Disabled = $disabled
	}
}

function Sync-OS7Time {
	<#
	.SYNOPSIS
		Asks chrony to correct the clock now, and reports what it did.

	.DESCRIPTION
		The `w32tm /resync` of this product. `chronyc makestep` tells chronyd to
		step the clock rather than slew it, which is what an operator wants when
		the machine is minutes out and sign-in is failing — slewing a five-minute
		error takes hours.

		IT REPORTS THE OFFSET BEFORE AND AFTER, from `Get-ChronyTracking`, and
		does not believe `chronyc`'s exit code: `makestep` returns 0 when it has
		asked, not when the clock has moved.

	.PARAMETER SettleSeconds
		How long to let chrony work before asking again.

	.EXAMPLE
		Sync-OS7Time
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([int]$SettleSeconds = 3)

	Import-OS7TimeLayer

	$before = Get-OS7TimeSynchronization
	if ($null -eq $before.Synchronised) {
		throw [System.InvalidOperationException]::new(
			"chronyd could not be asked, so there is nothing to resynchronise: $($before.Reason)")
	}

	if (-not $PSCmdlet.ShouldProcess('this machine', 'step the clock to NTP time')) {
		return $before
	}

	Sync-ChronyClock | Out-Null
	Start-Sleep -Seconds $SettleSeconds

	$after = Get-OS7TimeSynchronization
	[pscustomobject]@{
		Synchronised        = $after.Synchronised
		OffsetSecondsBefore = $before.OffsetSeconds
		OffsetSecondsAfter  = $after.OffsetSeconds
		WithinKerberosSkew  = $after.WithinKerberosSkew
		Source              = $after.Source
		# The answer comes from asking chrony again, not from makestep's exit
		# code — it returns 0 for "I have been asked", not for "the clock moved".
		Detail              = "offset $($before.OffsetSeconds)s -> $($after.OffsetSeconds)s"
	}
}
