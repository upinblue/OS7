# =============================================================================
# Time — the clock, the zone and the discipline, from PowerShell
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like powershell/Zfs and
# powershell/Net. It knows chrony, /etc/localtime and /etc/adjtime, and nothing
# about OS/7.
#
# P2's OWN EXAMPLE WAS WRONG ABOUT THIS ONE, and the correction is measured
# rather than argued. P2 offered "the time zone is a symlink" as the case where
# a subsystem is too thin to warrant a module. The zone is a symlink; what is
# behind it is not. This image runs `chrony 4.8`, NOT systemd-timesyncd, with
# its own vocabulary — tracking, sources, sourcestats, stratum, leap status,
# reach — its own machine-readable format, and its own configuration mechanism
# that is not the file everybody assumes.
#
# THREE THINGS MEASURED 2026-08-27 THAT DECIDE THE SHAPE OF THIS FILE:
#
#   1. `chronyc -c` emits CSV. There is no reason to parse the human table, and
#      the field COUNTS are fixed — 14 for tracking, 10 for sources — so a
#      chrony that changed them would be caught rather than mis-parsed.
#
#   2. NTP servers do NOT go in chrony.conf. `/etc/chrony/sources.d/*.sources`
#      is where they belong, `chronyc reload sources` applies them without a
#      restart, and chrony's own README in that directory says so. Editing
#      chrony.conf is the naive move and it is wrong twice over: a package
#      upgrade overwrites it, and the change does not take effect until chronyd
#      restarts.
#
#   3. `/etc/timezone` DOES NOT EXIST on this image and `/etc/adjtime` does not
#      either. The symlink at /etc/localtime is the only truth about the zone,
#      and an absent /etc/adjtime means the RTC is UTC — which is a default, so
#      it is reported as one.
# =============================================================================

Set-StrictMode -Version 3.0

# The seam the self-test replays fixtures through — the same one, for the same
# reason, as powershell/Zfs and powershell/Net: it lets the WHOLE cmdlet be
# checked rather than a parser lifted out of the path the product takes.
$script:TimeCommandOverride = $null

function Invoke-TimeCommand {
	<#
	.SYNOPSIS
		Internal. Run a program and return its stdout, stderr and exit code,
		without judging the exit code.
	#>
	param(
		[Parameter(Mandatory)][string]$Command,
		[string[]]$Arguments = @()
	)

	if ($script:TimeCommandOverride) {
		return & $script:TimeCommandOverride $Command $Arguments
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

function ConvertTo-TimeDouble {
	<#
	.SYNOPSIS
		Internal. A chrony CSV number, parsed INVARIANTLY.

	.DESCRIPTION
		`[double]::Parse` without a culture reads `0.034` as thirty-four on a
		machine whose decimal separator is a comma — which is every German,
		French or Spanish desktop this product is aimed at. chrony always emits
		a point. This is the whole reason the conversion is a function rather
		than a cast.
	#>
	param([AllowNull()][string]$Value)

	if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
	$n = 0.0
	if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float,
			[System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
		return $n
	}
	return $null
}

function Get-ChronyTracking {
	<#
	.SYNOPSIS
		What chrony is doing with this clock — whether it is disciplined, by
		whom, and how far off it is.

	.DESCRIPTION
		THIS IS THE ANSWER, NOT `timedatectl`. `timedatectl` reports "System
		clock synchronized" out of a kernel flag; it does not say against WHOM,
		by how much, or with what dispersion. `chronyc tracking` is the question
		asked of the thing that is actually doing the work.

		`Synchronised` is `Leap status` being anything other than
		`Not synchronised` — chrony's own word for it, measured in both states.

	.EXAMPLE
		(Get-ChronyTracking).Synchronised

	.EXAMPLE
		Get-ChronyTracking | Format-List Source, Stratum, LastOffsetSeconds
	#>
	[CmdletBinding()]
	param()

	$r = Invoke-TimeCommand -Command 'chronyc' -Arguments @('-c', 'tracking')
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"chronyc -c tracking exited $($r.ExitCode): $($r.StdErr.Trim())" +
			' (is chronyd running?)')
	}

	$f = ($r.StdOut.Trim() -split ',')
	# FOURTEEN, and checked rather than assumed. A chrony that added a column
	# would otherwise shift every field silently, and the value that moves into
	# `LeapStatus` decides whether this machine reports itself synchronised.
	if ($f.Count -ne 14) {
		throw [System.InvalidOperationException]::new(
			"chronyc -c tracking gave $($f.Count) fields, expected 14. " +
			'This chrony emits a different format than the one this module was measured against.')
	}

	$refUnix = ConvertTo-TimeDouble $f[3]
	[pscustomobject]@{
		ReferenceId          = $f[0]
		Source               = if ($f[1]) { $f[1] } else { $null }
		Stratum              = [int]$f[2]
		ReferenceTime        = if ($refUnix) {
			[System.DateTimeOffset]::FromUnixTimeMilliseconds([long]($refUnix * 1000)).UtcDateTime
		}
		else { $null }
		SystemTimeOffsetSeconds = ConvertTo-TimeDouble $f[4]
		LastOffsetSeconds    = ConvertTo-TimeDouble $f[5]
		RmsOffsetSeconds     = ConvertTo-TimeDouble $f[6]
		FrequencyPpm         = ConvertTo-TimeDouble $f[7]
		ResidualFrequencyPpm = ConvertTo-TimeDouble $f[8]
		SkewPpm              = ConvertTo-TimeDouble $f[9]
		RootDelaySeconds     = ConvertTo-TimeDouble $f[10]
		RootDispersionSeconds = ConvertTo-TimeDouble $f[11]
		UpdateIntervalSeconds = ConvertTo-TimeDouble $f[12]
		LeapStatus           = $f[13]
		Synchronised         = ($f[13] -ne 'Not synchronised')
	}
}

function Get-ChronySource {
	<#
	.SYNOPSIS
		The time sources chrony knows about, and what it thinks of each.

	.DESCRIPTION
		`State` is chrony's one-character verdict and it is expanded here
		because nobody remembers it: `*` the one being used, `+` combined with
		it, `-` measured and excluded, `?` unreachable, `x` a falseticker —
		a server whose time disagrees with the majority — and `~` too variable
		to use.

		`LastReceived` of 4294967295 means NEVER, which is chrony's sentinel and
		not a very long time. Reported as `$null`.

	.EXAMPLE
		Get-ChronySource | Where-Object State -eq 'Selected'
	#>
	[CmdletBinding()]
	param()

	$r = Invoke-TimeCommand -Command 'chronyc' -Arguments @('-c', 'sources')
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"chronyc -c sources exited $($r.ExitCode): $($r.StdErr.Trim())")
	}

	foreach ($line in ($r.StdOut -split "`n")) {
		$line = $line.Trim()
		if (-not $line) { continue }
		$f = $line -split ','
		if ($f.Count -ne 10) {
			throw [System.InvalidOperationException]::new(
				"chronyc -c sources gave $($f.Count) fields, expected 10.")
		}
		$lastRx = [uint32]$f[6]
		[pscustomobject]@{
			Mode = switch ($f[0]) { '^' { 'Server' } '=' { 'Peer' } '#' { 'Local' } default { $f[0] } }
			State = switch ($f[1]) {
				'*' { 'Selected' } '+' { 'Combined' } '-' { 'Excluded' }
				'?' { 'Unreachable' } 'x' { 'Falseticker' } '~' { 'TooVariable' }
				default { $f[1] }
			}
			Name             = $f[2]
			Stratum          = [int]$f[3]
			PollInterval     = [int]$f[4]
			Reachability     = [int]$f[5]
			# chrony's sentinel for "never heard from", not a duration.
			LastReceived     = if ($lastRx -eq [uint32]::MaxValue) { $null } else { [int]$lastRx }
			OffsetSeconds    = ConvertTo-TimeDouble $f[7]
			MeasuredOffsetSeconds = ConvertTo-TimeDouble $f[8]
			EstimatedErrorSeconds = ConvertTo-TimeDouble $f[9]
		}
	}
}

function Get-ChronySourceFile {
	<#
	.SYNOPSIS
		Where chrony reads NTP sources from, and what is in each file.

	.DESCRIPTION
		`/etc/chrony/sources.d/*.sources`, which is NOT chrony.conf. Reported as
		files rather than as a merged list for the same reason netplan's
		documents are: a `pool` line in one file and a `server` line in another
		are one configuration and two places to look.
	#>
	[CmdletBinding()]
	param([string]$Root)

	$dir = if ($Root) { [System.IO.Path]::Combine($Root, 'etc/chrony/sources.d') }
	else { '/etc/chrony/sources.d' }
	if (-not [System.IO.Directory]::Exists($dir)) { return }

	foreach ($path in ([System.IO.Directory]::GetFiles($dir, '*.sources') | Sort-Object)) {
		$lines = @([System.IO.File]::ReadAllLines($path) |
			ForEach-Object { $_.Trim() } |
			Where-Object { $_ -and -not $_.StartsWith('#') })
		[pscustomobject]@{
			Path    = $path
			Servers = @($lines | ForEach-Object {
					$parts = $_ -split '\s+'
					if ($parts.Count -ge 2 -and $parts[0] -in @('server', 'pool', 'peer')) {
						[pscustomobject]@{ Directive = $parts[0]; Address = $parts[1] }
					}
				})
			Lines   = $lines
		}
	}
}

function Set-ChronySource {
	<#
	.SYNOPSIS
		Writes one `.sources` file and asks chrony to reload — without
		restarting it.

	.DESCRIPTION
		`/etc/chrony/sources.d/<Name>.sources`, NEVER chrony.conf. Measured, and
		chrony's own README in that directory says the same: a package upgrade
		owns chrony.conf, and a change there does not take effect until chronyd
		restarts, whereas `chronyc reload sources` applies this immediately.

		EVERY LINE MUST END IN A NEWLINE — that is chrony's requirement, stated
		in the same README, and a file whose last line has no terminator is a
		file whose last server is ignored. `WriteAllLines` gives every line one
		including the last.

	.PARAMETER Name
		The file's basename. `os7` gives `/etc/chrony/sources.d/os7.sources`.

	.PARAMETER Server
		The NTP servers. Written as `server <address> iburst`.

	.PARAMETER Pool
		Pools, written as `pool <address> iburst`.

	.PARAMETER Root
		Write under this directory instead of `/`. For the self-test.

	.EXAMPLE
		Set-ChronySource -Name os7 -Server time.windows.com, time.example.com
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string]$Name,
		[string[]]$Server = @(),
		[string[]]$Pool = @(),
		[string]$Root
	)

	if ($Server.Count -eq 0 -and $Pool.Count -eq 0) {
		throw [System.ArgumentException]::new(
			'Set-ChronySource needs at least one -Server or -Pool. A file with no ' +
			'sources in it is not "no change", it is a machine with no time source.')
	}
	if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
		throw [System.ArgumentException]::new(
			"'$Name' is not a usable file name for /etc/chrony/sources.d.")
	}

	$dir = if ($Root) { [System.IO.Path]::Combine($Root, 'etc/chrony/sources.d') }
	else { '/etc/chrony/sources.d' }
	$path = [System.IO.Path]::Combine($dir, "$Name.sources")

	$lines = @("# Written by OS/7. Edit with Set-OS7TimeSynchronization, or by hand -")
	$lines += '# nothing rewrites this file except a later Set-ChronySource -Name ' + $Name + '.'
	foreach ($s in $Server) { $lines += "server $s iburst" }
	foreach ($p in $Pool) { $lines += "pool $p iburst" }

	if ($PSCmdlet.ShouldProcess($path, 'write chrony sources')) {
		if (-not [System.IO.Directory]::Exists($dir)) {
			[void][System.IO.Directory]::CreateDirectory($dir)
		}
		# WriteAllLines terminates every line, including the last. chrony
		# requires that; a file without it loses its final source silently.
		[System.IO.File]::WriteAllLines($path, [string[]]$lines)
	}

	# Reload rather than restart, and only against a real chronyd.
	$reloaded = $false
	$detail = 'not reloaded'
	if (-not $Root -and $PSCmdlet.ShouldProcess('chronyd', 'reload sources')) {
		$r = Invoke-TimeCommand -Command 'chronyc' -Arguments @('reload', 'sources')
		$reloaded = ($r.ExitCode -eq 0)
		$detail = if ($reloaded) { 'chronyc reload sources' }
		else { "chronyc reload sources exited $($r.ExitCode): $($r.StdErr.Trim())" }
	}

	[pscustomobject]@{
		Path     = $path
		Servers  = @($Server)
		Pools    = @($Pool)
		Reloaded = $reloaded
		Detail   = $detail
	}
}

function Sync-ChronyClock {
	<#
	.SYNOPSIS
		Tells chronyd to STEP the clock now rather than slew it.

	.DESCRIPTION
		`chronyc makestep` returns 0 when it has been ASKED, not when the clock
		has moved — so this returns the exit code and lets the caller ask
		`Get-ChronyTracking` again. Same rule as `Invoke-NetplanApply`: the call
		that changes something and the call that says whether it worked must ask
		different things.

		Stepping and not slewing is the point. Slewing a five-minute error takes
		hours, and five minutes is where Kerberos stops issuing tickets.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param()

	if (-not $PSCmdlet.ShouldProcess('this machine', 'chronyc makestep')) {
		return [pscustomobject]@{ StdOut = ''; ExitCode = 0; StdErr = '' }
	}
	return Invoke-TimeCommand -Command 'chronyc' -Arguments @('makestep')
}

# ---------------------------------------------------------------------------
# The zone and the hardware clock — files, not daemons
# ---------------------------------------------------------------------------

function Get-SystemTimeZone {
	<#
	.SYNOPSIS
		The zone this machine is in, read from the only thing that decides it.

	.DESCRIPTION
		`/etc/localtime` IS THE ANSWER, and `/etc/timezone` is not — measured
		2026-08-27: this image has the symlink and does NOT have
		`/etc/timezone` at all. Everything that reads local time follows the
		symlink; a file that may not exist cannot be the source of truth.

	.EXAMPLE
		Get-SystemTimeZone
	#>
	[CmdletBinding()]
	param([string]$Root)

	$link = if ($Root) { [System.IO.Path]::Combine($Root, 'etc/localtime') } else { '/etc/localtime' }
	$zoneRoot = if ($Root) { [System.IO.Path]::Combine($Root, 'usr/share/zoneinfo') }
	else { '/usr/share/zoneinfo' }

	if (-not (Test-Path -LiteralPath $link)) {
		return [pscustomobject]@{ Id = $null; Path = $link; IsLink = $false
			Detail = 'there is no /etc/localtime; this machine has no zone set'
		}
	}
	$item = Get-Item -LiteralPath $link -Force
	$target = $item.LinkTarget
	$id = if ($target) {
		# The zone id is the path under zoneinfo — `Europe/Berlin`, not
		# `/usr/share/zoneinfo/Europe/Berlin`.
		$t = $target -replace '\\', '/'
		$marker = 'zoneinfo/'
		$i = $t.IndexOf($marker)
		if ($i -ge 0) { $t.Substring($i + $marker.Length) } else { $null }
	}
	else { $null }

	[pscustomobject]@{
		Id     = $id
		Path   = $link
		IsLink = [bool]$target
		Target = $target
		# A COPY IS NOT A LINK, and it is the state `cp /usr/share/zoneinfo/X
		# /etc/localtime` leaves behind. The zone still works and nothing can
		# say which zone it is, which is worth reporting rather than guessing.
		Detail = if (-not $target) { "/etc/localtime is a file, not a link, so the zone cannot be named" }
		elseif (-not $id) { "/etc/localtime points outside $zoneRoot" }
		else { $null }
	}
}

function Set-SystemTimeZone {
	<#
	.SYNOPSIS
		Sets the zone by writing the symlink, and reads it back.

	.DESCRIPTION
		The zone is checked against `/usr/share/zoneinfo` BEFORE anything is
		written. `timedatectl set-timezone` would refuse an unknown zone; a
		symlink accepts anything and leaves a machine whose local time is UTC
		and whose configuration says otherwise.

		A symlink, which is what `timedatectl` would make and what every tool
		reading local time expects — the same choice, for the same reason, that
		`SystemSteps.cs` makes in the installer.

		IT READS THE LINK BACK. Z3's rule for the ZFS layer, applied here: a
		cmdlet that changed something says what the thing is now, not what it
		was told to make it.

	.EXAMPLE
		Set-SystemTimeZone -Id 'Europe/Berlin'
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string]$Id,
		[string]$Root
	)

	$zoneRoot = if ($Root) { [System.IO.Path]::Combine($Root, 'usr/share/zoneinfo') }
	else { '/usr/share/zoneinfo' }
	$target = [System.IO.Path]::Combine($zoneRoot, $Id)
	if (-not [System.IO.File]::Exists($target)) {
		throw [System.ArgumentException]::new(
			"'$Id' is not a zone in $zoneRoot. Get-ChildItem $zoneRoot lists them.")
	}

	$link = if ($Root) { [System.IO.Path]::Combine($Root, 'etc/localtime') } else { '/etc/localtime' }
	if ($PSCmdlet.ShouldProcess($link, "point at $Id")) {
		$dir = [System.IO.Path]::GetDirectoryName($link)
		if (-not [System.IO.Directory]::Exists($dir)) {
			[void][System.IO.Directory]::CreateDirectory($dir)
		}
		if (Test-Path -LiteralPath $link) { Remove-Item -Force -LiteralPath $link }
		New-Item -ItemType SymbolicLink -Path $link -Target $target -Force | Out-Null
	}

	Get-SystemTimeZone -Root $Root
}

function Get-SystemClock {
	<#
	.SYNOPSIS
		The clock: local, UTC, and whether the hardware clock is kept in local
		time.

	.DESCRIPTION
		THE RTC QUESTION IS THE ONE THAT MATTERS ON A DUAL-BOOT MACHINE.
		Windows keeps the hardware clock in LOCAL time by default and Linux
		keeps it in UTC, so a machine that boots both drifts by the UTC offset
		every time it changes operating system.

		The answer is the third line of `/etc/adjtime` — `UTC` or `LOCAL`. That
		file DOES NOT EXIST on this image (measured), and its absence means UTC.
		Because that is a default rather than a decision, `IsDefault` says so:
		a machine nobody has configured and a machine somebody set to UTC are
		the same clock and not the same fact.
	#>
	[CmdletBinding()]
	param([string]$Root)

	$adj = if ($Root) { [System.IO.Path]::Combine($Root, 'etc/adjtime') } else { '/etc/adjtime' }
	$local = $false
	$isDefault = $true
	if ([System.IO.File]::Exists($adj)) {
		$lines = @([System.IO.File]::ReadAllLines($adj))
		if ($lines.Count -ge 3) {
			$local = ($lines[2].Trim() -eq 'LOCAL')
			$isDefault = $false
		}
	}

	$now = Get-Date
	[pscustomobject]@{
		LocalTime         = $now
		UtcTime           = $now.ToUniversalTime()
		TimeZone          = (Get-SystemTimeZone -Root $Root).Id
		RtcInLocalTime    = $local
		RtcIsDefault      = $isDefault
		RtcSource         = $adj
	}
}

# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------

function Test-TimeModule {
	<#
	.SYNOPSIS
		Checks this module against RECORDED REAL chrony output and a zone tree
		it builds. No daemon, no root, no network.

	.NOTES
		Reports through [Console]::Error and THROWS on failure, for the reasons
		Test-ZfsModule does: Write-Host does not resolve inside a chroot
		(BUILD-NOTES #38), and a function that returns $false leaves pwsh
		exiting 0 — so a self-test that failed would be an image that passed.
	#>
	[CmdletBinding()]
	param([string]$FixturePath)

	if (-not $FixturePath) {
		$FixturePath = Join-Path $PSScriptRoot 'tests/fixtures'
	}

	$script:__timePass = 0
	$script:__timeFail = @()
	function Check([bool]$ok, [string]$what, [string]$detail = '') {
		$line = "      {0}  {1}" -f $(if ($ok) { 'ok  ' } else { 'FAIL' }), $what
		if ($detail) { $line += "   [$detail]" }
		[Console]::Error.WriteLine($line)
		if ($ok) { $script:__timePass++ } else { $script:__timeFail += $what }
	}

	[Console]::Error.WriteLine("`nTime self-test — no chronyd, no root, no network")
	[Console]::Error.WriteLine("  chrony, against recorded output in $FixturePath")

	if (-not (Test-Path -LiteralPath $FixturePath)) {
		Check $false 'the recorded fixtures are shipped beside the module' $FixturePath
	}
	else {
		$replay = {
			param($file, $exit)
			$full = Join-Path $FixturePath $file
			$script:TimeCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{
					StdOut = (Get-Content -Raw -LiteralPath $full); ExitCode = $exit; StdErr = ''
				}
			}.GetNewClosure()
		}
		try {
			$ErrorActionPreference = 'Stop'

			& $replay 'chrony-tracking-synchronised.csv' 0
			$t = Get-ChronyTracking
			Check ($t.Synchronised -eq $true) 'tracking: Leap status Normal is synchronised'
			Check ($t.Source -eq '185.125.190.121') 'tracking: the source it is following'
			Check ($t.Stratum -eq 3) 'tracking: stratum is an int' "$($t.Stratum)"
			Check ($t.ReferenceTime -is [datetime]) 'tracking: the reference time is a [datetime]'
			Check ($t.ReferenceTime.Year -eq 2026) 'tracking: and it decodes the unix epoch' "$($t.ReferenceTime)"
			# INVARIANT PARSING. On a de-DE host [double]::Parse would read
			# 0.034182489 as 34182489 — and this repository is aimed at German
			# and French desktops.
			Check ([math]::Abs($t.RootDelaySeconds - 0.034182489) -lt 1e-9) `
				'tracking: a decimal is parsed invariantly, not by host culture' "$($t.RootDelaySeconds)"
			Check ($t.LastOffsetSeconds -lt 0) 'tracking: a negative offset keeps its sign' "$($t.LastOffsetSeconds)"

			& $replay 'chrony-tracking-unsynchronised.csv' 0
			$u = Get-ChronyTracking
			# THE FIELD THIS MODULE EXISTS FOR. timedatectl answers this from a
			# kernel flag; chrony answers it from what it is actually doing.
			Check ($u.Synchronised -eq $false) 'tracking: "Not synchronised" is NOT synchronised'
			Check ($u.Stratum -eq 0) 'tracking: an unsynchronised clock is stratum 0'
			Check ($null -eq $u.Source) 'tracking: with no source named'

			& $replay 'chrony-sources.csv' 0
			$s = @(Get-ChronySource)
			Check ($s.Count -ge 4) 'sources: every recorded source came back' "$($s.Count)"
			Check ($s[0].Mode -eq 'Server') 'sources: ^ is expanded to Server'
			Check ($s[0].State -eq 'Unreachable') 'sources: ? is expanded to Unreachable'
			# 4294967295 IS A SENTINEL, not a duration. A cmdlet reporting it as
			# a number would say this source was last heard from 136 years ago.
			Check ($null -eq $s[0].LastReceived) 'sources: "never heard from" is null, not 4294967295'

			# A CHRONY THAT CHANGED ITS FORMAT MUST FAIL LOUDLY. A shifted field
			# moves a number into LeapStatus and the machine reports itself
			# synchronised on the strength of a string comparison.
			$script:TimeCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{ StdOut = 'a,b,c'; ExitCode = 0; StdErr = '' }
			}
			$threw = $false
			try { Get-ChronyTracking | Out-Null }
			catch [System.InvalidOperationException] { $threw = $true }
			Check $threw 'tracking: a different number of fields is refused, not mis-parsed'

			# chronyd not running is an error and not an empty answer.
			$script:TimeCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{ StdOut = ''; ExitCode = 1; StdErr = '506 Cannot talk to daemon' }
			}
			$threw = $false
			try { Get-ChronyTracking | Out-Null }
			catch [System.InvalidOperationException] { $threw = $true }
			Check $threw 'tracking: no chronyd is an error, not "not synchronised"'
		}
		catch {
			Check $false 'the chrony section ran to the end' `
				"$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
		}
		finally { $script:TimeCommandOverride = $null }
	}

	# --- the zone and the RTC, against a tree built here --------------------
	[Console]::Error.WriteLine('  the zone and the RTC, against a constructed tree')
	$root = Join-Path ([System.IO.Path]::GetTempPath()) "os7-time-$PID"
	try {
		$ErrorActionPreference = 'Stop'
		$zoneDir = Join-Path $root 'usr/share/zoneinfo/Europe'
		New-Item -ItemType Directory -Force -Path $zoneDir | Out-Null
		New-Item -ItemType Directory -Force -Path (Join-Path $root 'etc') | Out-Null
		Set-Content -NoNewline -Path (Join-Path $zoneDir 'Berlin') -Value 'TZif'
		Set-Content -NoNewline -Path (Join-Path $zoneDir 'Paris') -Value 'TZif'

		$z = Set-SystemTimeZone -Id 'Europe/Berlin' -Root $root
		Check ($z.Id -eq 'Europe/Berlin') 'zone: set, and READ BACK from the link' "$($z.Id)"
		Check ($z.IsLink -eq $true) 'zone: it is a symlink, which is what reads local time'
		$z = Set-SystemTimeZone -Id 'Europe/Paris' -Root $root
		Check ($z.Id -eq 'Europe/Paris') 'zone: setting it again replaces the link'

		# An unknown zone must be refused BEFORE the link is written. A symlink
		# accepts any target, so without this check the machine ends up on UTC
		# with a configuration that says otherwise.
		$threw = $false
		try { Set-SystemTimeZone -Id 'Mars/Olympus' -Root $root | Out-Null }
		catch [System.ArgumentException] { $threw = $true }
		Check $threw 'zone: an unknown zone is refused'
		Check ((Get-SystemTimeZone -Root $root).Id -eq 'Europe/Paris') `
			'zone: and the refusal left the previous zone alone'

		# A COPY IS NOT A LINK — the state `cp` leaves, in which the zone works
		# and nothing can name it.
		Remove-Item -Force (Join-Path $root 'etc/localtime')
		Set-Content -NoNewline -Path (Join-Path $root 'etc/localtime') -Value 'TZif'
		$z = Get-SystemTimeZone -Root $root
		Check ($null -eq $z.Id -and $z.IsLink -eq $false) `
			'zone: a copied file is reported as unnameable, not guessed at'

		# The RTC. Absent /etc/adjtime means UTC, and that is a DEFAULT.
		$c = Get-SystemClock -Root $root
		Check ($c.RtcInLocalTime -eq $false) 'rtc: no /etc/adjtime means UTC'
		Check ($c.RtcIsDefault -eq $true) 'rtc: and it is reported as a default, not a decision'
		Set-Content -Path (Join-Path $root 'etc/adjtime') -Value "0.0 0 0.0`n0`nLOCAL"
		$c = Get-SystemClock -Root $root
		Check ($c.RtcInLocalTime -eq $true) 'rtc: LOCAL in /etc/adjtime is the Windows dual-boot case'
		Check ($c.RtcIsDefault -eq $false) 'rtc: and that is a decision, not a default'

		# --- the sources file -----------------------------------------------
		$w = Set-ChronySource -Name os7 -Server 'time.windows.com', 'time.example.com' -Root $root
		$text = [System.IO.File]::ReadAllText($w.Path)
		Check ($w.Path -like '*etc/chrony/sources.d/os7.sources') `
			'sources.d: written to sources.d, NOT to chrony.conf' $w.Path
		Check ($text -match 'server time\.windows\.com iburst') 'sources.d: the server line'
		# chrony REQUIRES a trailing newline on every line, its own README says
		# so, and a file without one loses its last source in silence.
		Check ($text.EndsWith("`n") -or $text.EndsWith("`r`n")) `
			'sources.d: the last line is terminated, as chrony requires'
		Check ($w.Reloaded -eq $false) 'sources.d: -Root does not touch a running chronyd'

		$read = @(Get-ChronySourceFile -Root $root)
		Check ($read.Count -eq 1) 'sources.d: the file is read back'
		Check (@($read[0].Servers).Count -eq 2) 'sources.d: with both servers' "$(@($read[0].Servers).Count)"

		$threw = $false
		try { Set-ChronySource -Name os7 -Root $root | Out-Null }
		catch [System.ArgumentException] { $threw = $true }
		Check $threw 'sources.d: a file with no sources in it is refused'
	}
	catch {
		Check $false 'the zone section ran to the end' `
			"$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
	}
	finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $root }

	$pass = $script:__timePass
	$fail = @($script:__timeFail)
	[Console]::Error.WriteLine("`nTime self-test: $pass passed, $($fail.Count) failed")
	if ($fail.Count) {
		[Console]::Error.WriteLine('FAILED: ' + ($fail -join '; '))
		throw "Time self-test failed: $($fail.Count) check(s)"
	}
	[Console]::Error.WriteLine('Time self-test: PASS')
}

Export-ModuleMember -Function @(
	# chrony — asked because `timedatectl` answers "synchronised" from a kernel
	# flag and cannot say against whom, by how much, or with what dispersion
	'Get-ChronyTracking', 'Get-ChronySource',
	'Get-ChronySourceFile', 'Set-ChronySource', 'Sync-ChronyClock',
	# the zone and the hardware clock, which are files rather than daemons
	'Get-SystemTimeZone', 'Set-SystemTimeZone', 'Get-SystemClock',
	'Test-TimeModule')
