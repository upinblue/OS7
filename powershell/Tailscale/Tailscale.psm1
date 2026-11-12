# =============================================================================
# Tailscale — the tailnet client, as objects
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like Apt, Docker and
# Hardware. It knows the `tailscale` CLI and nothing about OS/7: where the
# daemon's state lives, which source the package comes from, and what an
# administrator needs to be told are decided one layer up, in OS7.Tailscale.ps1
# (docs/VENDOR-APPS-PLAN.md VA10-VA15). P2-tailscale in installer/testing/
# check-layering.py keeps powershell/OS7 from running the CLI itself.
#
# THE CLI'S JSON, NOT THE LOCALAPI SOCKET (VA10). `status --json` and
# `version --json` are what Tailscale documents for scripts; the LocalAPI is
# internal and changes. `debug prefs` is the one debug command used, because
# the preferences (AutoUpdate, RunSSH, CorpDNS) are not in `status` at all. Its
# fixtures are what a client that renames a field turns red.
#
# FIVE THINGS MEASURED on an installed OS/7 1.0.0.280 against a local
# Headscale, tailscale 1.104.5 (docs/SESSION-TAILSCALE.md, SESSION-VENDOR-
# SOURCES.md), each of which decides a piece of this file:
#
#   1. A STOPPED DAEMON IS NOT A BACKEND STATE. `status --json` exits 1 with
#      "failed to connect to local tailscaled" and prints nothing on stdout;
#      `debug prefs` exits 1 with another sentence. Tailscale's own states —
#      NeedsLogin, Stopped, Running — all need a daemon that answered, so
#      Get-TailscaleStatus says Reachable=$false and carries the CLI's sentence
#      rather than inventing a state.
#
#   2. AutoUpdate.Apply IS THREE-VALUED. null on a fresh client ("not decided
#      here"), false or true once decided — and null is when the TAILNET's
#      default decides at the next login. Get-TailscalePreference keeps $null
#      as $null, because collapsing it to $false would report a machine as
#      having switched the updater off when nobody has.
#
#   3. A LOGIN REPLACES WHAT `up` HAS NO FLAG FOR (O-M2). `up` has no
#      --auto-update. A local `set --auto-update=false` made before the first
#      login came out of `up` AND out of `login` as Apply=true — the
#      Headscale's default — twice; `down` + `up` reset it to null; `logout`
#      resets it to null. `set` AFTER the login held across 45 seconds, a
#      daemon restart and an `up` while running. So a preference that matters
#      is set after the login and read back, and that is the caller's job: this
#      layer reports, OS7.Tailscale.ps1 decides when.
#
#   4. `up --json` PRINTS THE LOGIN URL AND THEN WAITS. With --timeout it exits
#      1 ("timeout waiting for Tailscale service to enter a Running state")
#      AFTER printing {"AuthURL": …, "BackendState": "NeedsLogin"} — and the
#      daemon keeps the login pending, with the same URL in `status --json`. So
#      an interactive login is an exit code of 1 that is not a failure, and the
#      result says LoginPending rather than Succeeded.
#
#   5. `debug prefs` PRINTS THE PERSIST BLOCK — PrivateNodeKey,
#      OldPrivateNodeKey, NetworkLockKey. Version 1.104.5 zeroes them; nothing
#      promises that a later one will. Get-TailscalePreference passes on none of
#      the block, so no future client can make this layer a key reader.
#
# THE AUTH KEY IS NEVER A VALUE HERE. Connect-Tailscale takes the PATH of a file
# that holds it (`--auth-key=file:<path>`, measured), and refuses an argument
# that looks like a key rather than a path — a key on a command line is readable
# by every account on the machine through /proc/<pid>/cmdline.
#
# TWO PREFERENCES THIS LAYER SWITCHES OFF AND NOT ON: Tailscale SSH and the
# client's own updater. That is the one piece of OS/7 policy in this file, and
# it is here rather than one layer up because a generic verb that could switch
# them on would be an OS/7 verb that does (owner's decision 3, VA7 "one
# updater", VA14). `tailscale set --ssh` is how an administrator who wants
# Tailscale SSH gets it, and the product layer reports that it is on.
#
# ONE FUNCTION RUNS THE CLI: Invoke-TailscaleCommand, not exported. It is the
# seam Test-TailscaleModule replays recorded output through, and the reason the
# layering rule can be a grep.
# =============================================================================

Set-StrictMode -Version 3.0

# The self-test's seam: a scriptblock taking (arguments) and returning what
# Invoke-TailscaleCommand returns. $null in production, not exported.
$script:TailscaleCommandOverride = $null

# The prefix of a Tailscale auth key, and of Headscale's. A -AuthKeyFile value
# that starts like this is a key typed where a path belongs.
$script:TailscaleKeyShape = '^\s*(tskey|hskey)-'

function Write-TailscaleStep {
	<#
	.SYNOPSIS
		Internal. One line of progress, on stderr, in the shape every layer here
		uses (ZFS-STEP, APT-STEP, OS7-STEP).
	#>
	param([Parameter(Mandatory)][string]$Message)
	[Console]::Error.WriteLine("TAILSCALE-STEP $Message")
}

function Invoke-TailscaleCommand {
	<#
	.SYNOPSIS
		Internal. Run `tailscale <arguments>` and return stdout, stderr and the
		exit code, without judging the exit code.

	.DESCRIPTION
		In the C locale, through `env`, the way Invoke-AptCommand runs apt: the
		CLI does not translate today, and a layer that parses English should not
		depend on that staying true.

		Nothing secret is ever an argument here — Connect-Tailscale passes a
		file path for the key — so the arguments are safe to log, and the
		self-test does.
	#>
	param([Parameter(Mandatory)][string[]]$Arguments)

	if ($script:TailscaleCommandOverride) {
		return & $script:TailscaleCommandOverride $Arguments
	}

	$errFile = [System.IO.Path]::GetTempFileName()
	try {
		# RESET, THEN GUARDED READ — BUILD-NOTES #121.
		$global:LASTEXITCODE = $null
		$out = & env 'LC_ALL=C.UTF-8' tailscale @Arguments 2> $errFile
		$code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }
		if ($null -eq $code) { $code = 127 }
		return [pscustomobject]@{
			StdOut   = (@($out) -join "`n")
			StdErr   = ((Get-Content -Raw -ErrorAction SilentlyContinue $errFile) ?? '')
			ExitCode = $code
		}
	}
	catch {
		return [pscustomobject]@{ StdOut = ''; StdErr = [string]$_; ExitCode = 127 }
	}
	finally {
		Remove-Item -Force -ErrorAction SilentlyContinue $errFile
	}
}

function Test-TailscaleMissing {
	<#
	.SYNOPSIS
		Internal. Whether a result says the CLI is not on this machine — `env`
		reports a program it cannot find as exit 127, the shell's own word.
	#>
	param([Parameter(Mandatory)]$Result)
	return ($Result.ExitCode -eq 127)
}

function Get-TailscaleSentence {
	<#
	.SYNOPSIS
		Internal. What the CLI said, as one trimmed string: stderr first, stdout
		if stderr was empty.
	#>
	param([Parameter(Mandatory)]$Result)
	$text = ([string]$Result.StdErr).Trim()
	if (-not $text) { $text = ([string]$Result.StdOut).Trim() }
	return $text
}

function Assert-TailscaleElevated {
	<#
	.SYNOPSIS
		Internal. This layer's own root guard, in the words the product's uses
		(BUILD-NOTES #148/#149; Assert-AptElevated's shape).

	.DESCRIPTION
		The daemon refuses a preference write from an account that is neither
		root nor its configured operator, with "Access denied: prefs write
		access denied". OS/7 configures no operator, so the refusal here is the
		same answer said in a sentence that names the verb. A host with no /proc
		(the self-test on Windows) is not a refusal.
	#>
	param(
		[Parameter(Mandatory)][string]$Cmdlet,
		[Parameter(Mandatory)][string]$Because
	)
	$status = '/proc/self/status'
	if (-not [System.IO.File]::Exists($status)) { return }
	$uid = $null
	foreach ($line in [System.IO.File]::ReadAllLines($status)) {
		if (-not $line.StartsWith('Uid:')) { continue }
		$f = $line.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)
		if ($f.Count -ge 3) { $uid = $f[2] }
		break
	}
	if ($null -eq $uid -or $uid -eq '0') { return }
	throw [System.InvalidOperationException]::new(
		"$Cmdlet must run as root: it $Because. This process is uid $uid. Elevate the shell: " +
		"sudo pwsh -NoProfile -c '$Cmdlet <parameters>'")
}

function ConvertFrom-TailscaleJson {
	<#
	.SYNOPSIS
		Internal. The CLI's JSON as a hashtable — indexed, so a field a client
		version dropped reads as $null under strict mode instead of throwing.
	#>
	param(
		[AllowEmptyString()][string]$Text,
		[Parameter(Mandatory)][string]$Command
	)
	if ([string]::IsNullOrWhiteSpace($Text)) {
		throw [System.InvalidOperationException]::new("``tailscale $Command`` printed nothing.")
	}
	try { return ($Text | ConvertFrom-Json -AsHashtable -Depth 64) }
	catch {
		$head = $Text.Substring(0, [Math]::Min(200, $Text.Length))
		throw [System.InvalidOperationException]::new(
			"``tailscale $Command`` did not print JSON: $head")
	}
}

function ConvertTo-TailscaleList {
	<#
	.SYNOPSIS
		Internal. A JSON array that may be null, as an array of non-empty
		strings. @($null) is one element, not none (#112/#119).
	#>
	param($Value)
	return @(@($Value) | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { [string]$_ })
}

function ConvertTo-TailscaleTime {
	<#
	.SYNOPSIS
		Internal. A JSON time that pwsh may or may not have parsed already.
	#>
	param($Value)
	if ($null -eq $Value -or [string]$Value -eq '') { return $null }
	if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
	if ($Value -is [System.DateTimeOffset]) { return $Value.UtcDateTime }
	$t = [datetime]::MinValue
	if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture,
			[System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) {
		return $t.ToUniversalTime()
	}
	return $null
}

# =============================================================================
# Reading
# =============================================================================

function Get-TailscaleVersion {
	<#
	.SYNOPSIS
		The installed client's version, or $null when there is no `tailscale` on
		this machine.

	.DESCRIPTION
		`tailscale version --json` answers without the daemon (measured with
		tailscaled stopped), so this is the question "is the client installed"
		as well as "which one".
	#>
	[CmdletBinding()]
	[OutputType('Tailscale.Version')]
	param()

	$r = Invoke-TailscaleCommand -Arguments @('version', '--json')
	if (Test-TailscaleMissing $r) { return $null }
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"``tailscale version --json`` exited $($r.ExitCode): $(Get-TailscaleSentence $r)")
	}
	$j = ConvertFrom-TailscaleJson -Text $r.StdOut -Command 'version --json'
	return [pscustomobject]@{
		PSTypeName = 'Tailscale.Version'
		Version    = [string]$j['short']
		Long       = [string]$j['long']
		Commit     = [string]$j['gitCommit']
		Capability = $j['cap']
	}
}

function Get-TailscaleStatus {
	<#
	.SYNOPSIS
		What the client is connected to: its backend state, tailnet, name and
		addresses, its health messages and its peers — or that the daemon could
		not be asked, and the CLI's sentence for why.

	.DESCRIPTION
		`tailscale status --json`. BackendState is Tailscale's own word —
		NeedsLogin, NeedsMachineAuth, Starting, Stopped, Running — and is
		reported as it is. A daemon that did not answer has no backend state, so
		Reachable is $false, BackendState is $null and Error carries what the
		CLI said (measured: "failed to connect to local tailscaled; it doesn't
		appear to be running"). A machine without the CLI says so the same way.

		AuthUrl is the pending login's URL while a login waits for a person, and
		$null otherwise (the CLI prints "" — reported as nothing, not as an
		empty URL).

		KeyExpiry is $null for a node whose key does not expire — a TAGGED node,
		which is what an auth key with tags makes (measured).
	#>
	[CmdletBinding()]
	[OutputType('Tailscale.Status')]
	param()

	$r = Invoke-TailscaleCommand -Arguments @('status', '--json')
	$unreachable = {
		param($why)
		[pscustomobject]@{
			PSTypeName     = 'Tailscale.Status'
			Reachable      = $false
			Error          = $why
			BackendState   = $null
			Running        = $false
			AuthUrl        = $null
			Version        = $null
			Tailnet        = $null
			MagicDnsSuffix = $null
			HostName       = $null
			DnsName        = $null
			Addresses      = @()
			NodeId         = $null
			Online         = $false
			KeyExpiry      = $null
			Tags           = @()
			Health         = @()
			HaveNodeKey    = $false
			Peers          = @()
		}
	}
	if (Test-TailscaleMissing $r) { return (& $unreachable 'tailscale is not installed on this machine.') }
	if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.StdOut)) {
		$why = Get-TailscaleSentence $r
		if (-not $why) { $why = "``tailscale status --json`` exited $($r.ExitCode) and said nothing." }
		return (& $unreachable $why)
	}

	$j = ConvertFrom-TailscaleJson -Text $r.StdOut -Command 'status --json'
	$self = $j['Self']
	if ($null -eq $self) { $self = @{} }
	$tailnet = $j['CurrentTailnet']
	$dnsName = ([string]$self['DNSName']).TrimEnd('.')

	$peers = foreach ($p in @(if ($j['Peer']) { $j['Peer'].Values })) {
		if ($null -eq $p) { continue }
		[pscustomobject]@{
			PSTypeName = 'Tailscale.Peer'
			HostName   = [string]$p['HostName']
			DnsName    = ([string]$p['DNSName']).TrimEnd('.')
			Addresses  = @(ConvertTo-TailscaleList $p['TailscaleIPs'])
			Online     = ($p['Online'] -eq $true)
			OS         = [string]$p['OS']
			Tags       = @(ConvertTo-TailscaleList $p['Tags'])
		}
	}

	$backend = [string]$j['BackendState']
	$authUrl = [string]$j['AuthURL']
	$suffix = [string]$j['MagicDNSSuffix']
	$nodeId = [string]$self['ID']
	return [pscustomobject]@{
		PSTypeName     = 'Tailscale.Status'
		Reachable      = $true
		Error          = $null
		BackendState   = $backend
		Running        = ($backend -eq 'Running')
		AuthUrl        = $(if ($authUrl) { $authUrl } else { $null })
		Version        = [string]$j['Version']
		Tailnet        = $(if ($tailnet) { [string]$tailnet['Name'] } else { $null })
		MagicDnsSuffix = $(if ($suffix) { $suffix } else { $null })
		HostName       = [string]$self['HostName']
		DnsName        = $(if ($dnsName) { $dnsName } else { $null })
		Addresses      = @(ConvertTo-TailscaleList $self['TailscaleIPs'])
		NodeId         = $(if ($nodeId) { $nodeId } else { $null })
		Online         = ($self['Online'] -eq $true)
		KeyExpiry      = ConvertTo-TailscaleTime $self['KeyExpiry']
		Tags           = @(ConvertTo-TailscaleList $self['Tags'])
		Health         = @(ConvertTo-TailscaleList $j['Health'])
		HaveNodeKey    = ($j['HaveNodeKey'] -eq $true)
		Peers          = @($peers)
	}
}

function Get-TailscalePreference {
	<#
	.SYNOPSIS
		How the client is set: control server, hostname, whether it wants to
		run, Tailscale SSH, DNS, tags — and its own updater, three-valued.

	.DESCRIPTION
		`tailscale debug prefs`, because `status` does not carry preferences.

		AutoUpdateApply is $null when nothing on this machine decided it — the
		state in which the TAILNET's default decides at the next login, and the
		state `logout` and `down` + `up` put it back into (measured, O-M2). It
		is $false or $true once something decided. Never collapsed.

		THE PERSIST BLOCK IS NOT PASSED ON. `debug prefs` prints PrivateNodeKey
		and its relatives inside "Config"; 1.104.5 zeroes them and no promise
		says a later client will. Nothing from that block leaves this function.

		Throws when the daemon cannot be asked, with the CLI's sentence: a
		preference read from nothing is not a preference.
	#>
	[CmdletBinding()]
	[OutputType('Tailscale.Preference')]
	param()

	$r = Invoke-TailscaleCommand -Arguments @('debug', 'prefs')
	if (Test-TailscaleMissing $r) {
		throw [System.InvalidOperationException]::new('tailscale is not installed on this machine.')
	}
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"The Tailscale daemon could not be asked for its preferences: $(Get-TailscaleSentence $r)")
	}
	$j = ConvertFrom-TailscaleJson -Text $r.StdOut -Command 'debug prefs'
	$au = $j['AutoUpdate']
	if ($null -eq $au) { $au = @{} }
	$apply = $au['Apply']
	$hostname = [string]$j['Hostname']
	$exitNode = [string]$j['ExitNodeID']
	return [pscustomobject]@{
		PSTypeName      = 'Tailscale.Preference'
		ControlUrl      = [string]$j['ControlURL']
		WantRunning     = ($j['WantRunning'] -eq $true)
		LoggedOut       = ($j['LoggedOut'] -eq $true)
		Hostname        = $(if ($hostname) { $hostname } else { $null })
		RunSsh          = ($j['RunSSH'] -eq $true)
		AcceptDns       = ($j['CorpDNS'] -eq $true)
		AcceptRoutes    = ($j['RouteAll'] -eq $true)
		AdvertiseTags   = @(ConvertTo-TailscaleList $j['AdvertiseTags'])
		AdvertiseRoutes = @(ConvertTo-TailscaleList $j['AdvertiseRoutes'])
		ExitNodeId      = $(if ($exitNode) { $exitNode } else { $null })
		ShieldsUp       = ($j['ShieldsUp'] -eq $true)
		NetfilterMode   = $j['NetfilterMode']
		AutoUpdateCheck = $(if ($null -eq $au['Check']) { $null } else { [bool]$au['Check'] })
		AutoUpdateApply = $(if ($null -eq $apply) { $null } else { [bool]$apply })
	}
}

# =============================================================================
# Changing
# =============================================================================

function Connect-Tailscale {
	<#
	.SYNOPSIS
		`tailscale up`: log in with an auth key read from a FILE, or start an
		interactive login and return its URL.

	.DESCRIPTION
		WITH -AuthKeyFile the key is passed as `--auth-key=file:<path>`, so it is
		never an argument (/proc/<pid>/cmdline is readable by every account) and
		this function never holds it. A value that looks like a key rather than
		a path is refused before anything runs.

		WITHOUT IT, `up --json` prints the login URL and waits up to -TimeoutSec
		for a person to use it. A timeout is exit 1 and is NOT a failure: the
		daemon keeps the login pending with the same URL (measured), so the
		result says LoginPending and carries AuthUrl.

		Never throws for what the CLI answered — an invalid key, a refused
		change — because the caller decides what each one means; the result
		carries Succeeded, ExitCode and the CLI's sentence. Throws only for a
		parameter refused before anything ran.

		`up` replaces every preference it has no flag for when it logs a node in
		(O-M2: AutoUpdate.Apply came out of a login as the tailnet's default
		after a local `set` had made it false). Set what matters AFTER this, with
		Set-TailscalePreference, and read it back.

	.PARAMETER AuthKeyFile
		The absolute path of a file whose first line is the key — under systemd,
		`$CREDENTIALS_DIRECTORY/<name>`.

	.PARAMETER LoginServer
		A control server other than Tailscale's, e.g. a self-hosted Headscale.

	.PARAMETER Reset
		Passes --reset: every preference not named here goes back to its
		default. Without it `up` on a running node refuses to change settings
		unless every non-default one is named, and says which (measured).

	.EXAMPLE
		Connect-Tailscale -AuthKeyFile "$env:CREDENTIALS_DIRECTORY/tailscale-authkey" -Hostname web01
	#>
	[CmdletBinding()]
	[OutputType('Tailscale.ConnectResult')]
	param(
		[string]$AuthKeyFile,
		[string]$LoginServer,
		[string]$Hostname,
		[string[]]$AdvertiseTag = @(),
		[Nullable[bool]]$AcceptDns,
		[switch]$Reset,
		[ValidateRange(1, 3600)][int]$TimeoutSec = 60
	)

	Assert-TailscaleElevated -Cmdlet 'Connect-Tailscale' -Because 'changes the Tailscale daemon''s login and preferences'

	$argv = [System.Collections.Generic.List[string]]::new()
	$argv.Add('up')
	if ($AuthKeyFile) {
		if ($AuthKeyFile -match $script:TailscaleKeyShape) {
			throw [System.ArgumentException]::new(
				'-AuthKeyFile takes the PATH of a file that holds the key, and this is the key itself. ' +
				'A key on a command line is readable by every account on the machine through /proc; ' +
				'put it in a file, or in the OS/7 secret store with New-OS7Secret.')
		}
		if (-not $AuthKeyFile.StartsWith('/')) {
			throw [System.ArgumentException]::new("-AuthKeyFile '$AuthKeyFile' is not an absolute path.")
		}
		$argv.Add("--auth-key=file:$AuthKeyFile")
	}
	else {
		# Interactive: the URL arrives as JSON before the wait starts.
		$argv.Add('--json')
	}
	if ($LoginServer) {
		if ($LoginServer -notmatch '^https?://\S+$') {
			throw [System.ArgumentException]::new("-LoginServer '$LoginServer' is not an http(s) URL.")
		}
		$argv.Add("--login-server=$LoginServer")
	}
	if ($Hostname) {
		if ($Hostname -notmatch '^[A-Za-z0-9][A-Za-z0-9\-]{0,62}$') {
			throw [System.ArgumentException]::new("-Hostname '$Hostname' is not a single DNS label.")
		}
		$argv.Add("--hostname=$Hostname")
	}
	$tags = @($AdvertiseTag | Where-Object { $_ })
	if ($tags.Count) {
		foreach ($t in $tags) {
			if ($t -notmatch '^tag:[A-Za-z0-9\-]+$') {
				throw [System.ArgumentException]::new("-AdvertiseTag '$t' is not a tag (tag:<name>).")
			}
		}
		$argv.Add("--advertise-tags=$($tags -join ',')")
	}
	if ($null -ne $AcceptDns) { $argv.Add("--accept-dns=$(([string]$AcceptDns).ToLowerInvariant())") }
	if ($Reset) { $argv.Add('--reset') }
	$argv.Add("--timeout=$($TimeoutSec)s")

	Write-TailscaleStep ("tailscale " + ($argv -join ' '))
	$r = Invoke-TailscaleCommand -Arguments $argv.ToArray()

	$authUrl = $null
	$backend = $null
	if (-not $AuthKeyFile -and -not [string]::IsNullOrWhiteSpace($r.StdOut)) {
		# The JSON object is the first thing on stdout; a client that prints a
		# second line after it is not a reason to lose the URL.
		$first = ($r.StdOut -split "`n(?=\{)")[0]
		try {
			$j = $first | ConvertFrom-Json -AsHashtable -Depth 8
			if ($j -is [System.Collections.IDictionary]) {
				if ($j['AuthURL']) { $authUrl = [string]$j['AuthURL'] }
				if ($j['BackendState']) { $backend = [string]$j['BackendState'] }
			}
		}
		catch { Write-Verbose "tailscale up --json printed something that is not JSON: $first" }
	}
	$sentence = Get-TailscaleSentence $r
	return [pscustomobject]@{
		PSTypeName   = 'Tailscale.ConnectResult'
		Succeeded    = ($r.ExitCode -eq 0)
		LoginPending = ($r.ExitCode -ne 0 -and [bool]$authUrl)
		AuthUrl      = $authUrl
		BackendState = $backend
		ExitCode     = $r.ExitCode
		Error        = $(if ($r.ExitCode -ne 0 -and $sentence) { $sentence } else { $null })
		Arguments    = $argv.ToArray()
	}
}

function Disconnect-Tailscale {
	<#
	.SYNOPSIS
		`tailscale down` — still enrolled, not connected — or with -Logout,
		`tailscale logout`: the node leaves the tailnet and its key is expired.

	.DESCRIPTION
		Both reset AutoUpdate.Apply to "not decided" (measured, O-M2): a caller
		that cares sets it again after the next login.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([switch]$Logout)

	Assert-TailscaleElevated -Cmdlet 'Disconnect-Tailscale' -Because 'disconnects this machine from its tailnet'
	$verb = if ($Logout) { 'logout' } else { 'down' }
	if (-not $PSCmdlet.ShouldProcess('the Tailscale daemon', "tailscale $verb")) { return }
	Write-TailscaleStep "tailscale $verb"
	$r = Invoke-TailscaleCommand -Arguments @($verb)
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"``tailscale $verb`` exited $($r.ExitCode): $(Get-TailscaleSentence $r)")
	}
}

function Set-TailscalePreference {
	<#
	.SYNOPSIS
		`tailscale set`, then the daemon asked back: what it reports is the
		result, not the exit code.

	.DESCRIPTION
		-Ssh and -AutoUpdate accept $false ONLY. Tailscale SSH bypasses PAM's
		account checks for a command (docs/SESSION-TAILSCALE.md §8), and the
		client's updater runs apt in the running system with --allow-downgrades
		(§12) — OS/7 switches both off and has no verb that switches either on
		(VENDOR-APPS-PLAN VA7, VA14). `tailscale set --ssh` is how an
		administrator who wants it gets it.

		A value the daemon does not report back after `set` exited 0 is a
		refusal, naming both.

	.EXAMPLE
		Set-TailscalePreference -AutoUpdate $false -Ssh $false
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('Tailscale.Preference')]
	param(
		[string]$Hostname,
		[Nullable[bool]]$AcceptDns,
		[Nullable[bool]]$Ssh,
		[Nullable[bool]]$AutoUpdate
	)

	Assert-TailscaleElevated -Cmdlet 'Set-TailscalePreference' -Because 'changes the Tailscale daemon''s preferences'
	if ($Ssh -eq $true) {
		throw [System.ArgumentException]::new(
			'Set-TailscalePreference does not switch Tailscale SSH on. A command sent over it runs even when ' +
			'PAM''s account checks refuse the account; OpenSSH over the tailnet address keeps them ' +
			'(docs/VENDOR-APPS-PLAN.md VA14). An administrator who wants it anyway runs `tailscale set --ssh`.')
	}
	if ($AutoUpdate -eq $true) {
		throw [System.ArgumentException]::new(
			'Set-TailscalePreference does not switch Tailscale''s own updater on: it runs apt in the running ' +
			'system with --allow-downgrades, beside the update OS/7 already runs for this package ' +
			'(docs/VENDOR-APPS-PLAN.md VA7, "one updater").')
	}

	$argv = [System.Collections.Generic.List[string]]::new()
	$argv.Add('set')
	if ($Hostname) {
		if ($Hostname -notmatch '^[A-Za-z0-9][A-Za-z0-9\-]{0,62}$') {
			throw [System.ArgumentException]::new("-Hostname '$Hostname' is not a single DNS label.")
		}
		$argv.Add("--hostname=$Hostname")
	}
	if ($null -ne $AcceptDns) { $argv.Add("--accept-dns=$(([string]$AcceptDns).ToLowerInvariant())") }
	if ($null -ne $Ssh) { $argv.Add('--ssh=false') }
	if ($null -ne $AutoUpdate) { $argv.Add('--auto-update=false') }
	if ($argv.Count -eq 1) {
		throw [System.ArgumentException]::new('Set-TailscalePreference was given nothing to set.')
	}
	if (-not $PSCmdlet.ShouldProcess('the Tailscale daemon', "tailscale $(($argv | Select-Object -Skip 1) -join ' ')")) { return }

	Write-TailscaleStep ("tailscale " + ($argv -join ' '))
	$r = Invoke-TailscaleCommand -Arguments $argv.ToArray()
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"``tailscale $($argv -join ' ')`` exited $($r.ExitCode): $(Get-TailscaleSentence $r)")
	}

	# ASK BACK. `set` exiting 0 is the CLI's claim.
	$p = Get-TailscalePreference
	$wrong = [System.Collections.Generic.List[string]]::new()
	if ($Hostname -and $p.Hostname -ne $Hostname) { $wrong.Add("Hostname is '$($p.Hostname)', not '$Hostname'") }
	if ($null -ne $AcceptDns -and $p.AcceptDns -ne $AcceptDns) { $wrong.Add("CorpDNS is $($p.AcceptDns)") }
	if ($null -ne $Ssh -and $p.RunSsh) { $wrong.Add('RunSSH is still true') }
	if ($null -ne $AutoUpdate -and $p.AutoUpdateApply -ne $false) {
		$wrong.Add("AutoUpdate.Apply is $(if ($null -eq $p.AutoUpdateApply) { 'not decided' } else { $p.AutoUpdateApply })")
	}
	if ($wrong.Count) {
		throw [System.InvalidOperationException]::new(
			"``tailscale $($argv -join ' ')`` exited 0 and the daemon does not report it: " + ($wrong -join '; ') + '.')
	}
	return $p
}

# =============================================================================
# Self-test
# =============================================================================

function Test-TailscaleModule {
	<#
	.SYNOPSIS
		Checks this module against RECORDED real `tailscale` output from an OS/7
		machine (1.104.5, a local Headscale). No tailscale, no root, any host.

	.NOTES
		Reports through [Console]::Error and THROWS on failure, for the reason
		every self-test here does: a function that returns $false leaves pwsh
		exiting 0.
	#>
	[CmdletBinding()]
	param([string]$FixturePath)

	if (-not $FixturePath) { $FixturePath = Join-Path $PSScriptRoot 'tests/fixtures' }
	if (-not (Test-Path -LiteralPath $FixturePath)) {
		throw [System.IO.FileNotFoundException]::new(
			"the recorded fixtures are not beside the module: $FixturePath")
	}
	$script:__tsPass = 0
	$script:__tsFail = @()
	function Check([bool]$ok, [string]$what, [string]$detail = '') {
		$line = "      {0}  {1}" -f $(if ($ok) { 'ok  ' } else { 'FAIL' }), $what
		if ($detail) { $line += "   [$detail]" }
		[Console]::Error.WriteLine($line)
		if ($ok) { $script:__tsPass++ } else { $script:__tsFail += $what }
	}
	function Fixture([string]$name) {
		$read = {
			param($ext)
			$p = Join-Path $FixturePath "$name.$ext"
			if ([System.IO.File]::Exists($p)) { [System.IO.File]::ReadAllText($p) } else { '' }
		}
		[pscustomobject]@{
			StdOut   = (& $read 'out')
			StdErr   = (& $read 'err')
			ExitCode = [int]((& $read 'rc').Trim())
		}
	}
	$seen = [System.Collections.Generic.List[string]]::new()
	# Replay: the first argument of each call picks the fixture. Read HERE and
	# captured by the closure, because the override runs from
	# Invoke-TailscaleCommand's scope, where this test's functions are not seen.
	function Replay([hashtable]$map) {
		$fx = @{}
		foreach ($k in $map.Keys) {
			$fx[$k] = if ($map[$k] -is [string]) { Fixture $map[$k] } else { $map[$k] }
		}
		$log = $seen
		$script:TailscaleCommandOverride = {
			param($a)
			$log.Add(($a -join ' '))
			$fx[$a[0]]
		}.GetNewClosure()
	}
	$ok0 = [pscustomobject]@{ StdOut = ''; StdErr = ''; ExitCode = 0 }
	$missing = [pscustomobject]@{ StdOut = ''; StdErr = 'env: ''tailscale'': No such file or directory'; ExitCode = 127 }

	[Console]::Error.WriteLine("`nTailscale self-test — no tailscale, no root")
	[Console]::Error.WriteLine("  against recorded output in $FixturePath")
	try {
		# -- version -------------------------------------------------------------
		[Console]::Error.WriteLine("`n  version")
		Replay @{ version = 'version-json' }
		$v = Get-TailscaleVersion
		Check ($null -ne $v -and $v.Version -eq '1.104.5' -and $v.Capability -eq 148) 'tailscale version --json: 1.104.5, capability 148'
		Replay @{ version = $missing; status = $missing; debug = $missing }
		Check ($null -eq (Get-TailscaleVersion)) 'no CLI on the machine: $null, not a throw'

		# -- status --------------------------------------------------------------
		[Console]::Error.WriteLine("`n  status, in the five states a machine was seen in")
		Replay @{ status = 'status-fresh' }
		$s = Get-TailscaleStatus
		Check ($s.Reachable -and $s.BackendState -eq 'NeedsLogin' -and -not $s.Running) 'fresh install: NeedsLogin'
		Check ($null -eq $s.AuthUrl -and $s.Addresses.Count -eq 0 -and $null -eq $s.NodeId) 'and no URL, no address, no node — "" is reported as nothing'
		Replay @{ status = 'status-needslogin' }
		$s = Get-TailscaleStatus
		Check ($s.BackendState -eq 'NeedsLogin' -and $s.AuthUrl -like 'https://headscale.os7.test:8443/register/*') 'a login waiting for a person: NeedsLogin AND the URL'
		Replay @{ status = 'status-running' }
		$s = Get-TailscaleStatus
		Check ($s.Running -and $s.BackendState -eq 'Running') 'logged in by key: Running'
		Check (($s.Addresses -join ' ') -eq '100.64.0.5 fd7a:115c:a1e0::5') 'both addresses, IPv4 first' "$($s.Addresses -join ' ')"
		Check ($s.DnsName -eq 'os7-fixture.tailnet.os7.test' -and $s.HostName -eq 'os7-fixture') 'the MagicDNS name, without the trailing dot'
		Check ($s.Tailnet -eq 'headscale.os7.test' -and $s.MagicDnsSuffix -eq 'tailnet.os7.test') 'the tailnet and its DNS suffix'
		Check ((@($s.Tags) -join ',') -eq 'tag:os7-bench' -and $null -eq $s.KeyExpiry) 'a TAGGED node: its tag, and a key that does not expire'
		Check ($s.Peers.Count -eq 4 -and @($s.Peers | Where-Object HostName -eq 'lab-client').Count -eq 1) 'four peers, by name' "$($s.Peers.Count)"
		Check ($s.Health.Count -eq 0 -and $s.HaveNodeKey -and $s.NodeId -eq '5') 'no health message, a node key, node id 5'
		Replay @{ status = 'status-stopped' }
		$s = Get-TailscaleStatus
		Check ($s.BackendState -eq 'Stopped' -and -not $s.Running -and $s.Addresses.Count -eq 2) '`down`: Stopped, and the addresses are still the node''s'
		Check ($s.Health -contains 'Tailscale is stopped.') 'and its health message'
		Replay @{ status = 'status-loggedout' }
		$s = Get-TailscaleStatus
		Check ($s.BackendState -eq 'NeedsLogin' -and $s.Addresses.Count -eq 0 -and $null -eq $s.Tailnet) '`logout`: NeedsLogin, no address, no tailnet'
		Replay @{ status = 'status-nodaemon' }
		$s = Get-TailscaleStatus
		Check (-not $s.Reachable -and $null -eq $s.BackendState -and $s.Error -match "doesn't appear to be running") `
			'a STOPPED DAEMON is not a backend state: Reachable false, the CLI''s sentence'
		Replay @{ status = $missing }
		$s = Get-TailscaleStatus
		Check (-not $s.Reachable -and $s.Error -match 'not installed') 'no CLI: Reachable false, "not installed"'

		# -- preferences ---------------------------------------------------------
		[Console]::Error.WriteLine("`n  preferences (debug prefs), AutoUpdate.Apply three-valued")
		Replay @{ debug = 'prefs-fresh' }
		$p = Get-TailscalePreference
		Check ($null -eq $p.AutoUpdateApply -and $p.LoggedOut -and -not $p.RunSsh) 'fresh: Apply NOT DECIDED ($null), logged out, no SSH'
		Replay @{ debug = 'prefs-local-choices' }
		$p = Get-TailscalePreference
		Check ($p.AutoUpdateApply -eq $false -and $null -ne $p.AutoUpdateApply) 'a local `set --auto-update=false`: $false, which is not $null'
		Replay @{ debug = 'prefs-running' }
		$p = Get-TailscalePreference
		Check ($p.AutoUpdateApply -eq $true) 'after the login: $true — the tailnet''s default replaced the local choice (O-M2)'
		Check ($p.ControlUrl -eq 'https://headscale.os7.test:8443' -and $p.Hostname -eq 'os7-fixture' -and $p.WantRunning -and -not $p.LoggedOut) `
			'the control server, the hostname, WantRunning'
		Check ($p.AcceptDns -and $p.NetfilterMode -eq 2 -and -not $p.RunSsh) 'CorpDNS on, netfilter on (2), SSH off'
		$names = @($p.PSObject.Properties.Name)
		Check (-not @($names | Where-Object { $_ -match 'Key|Config|Persist' }).Count) 'NOTHING from the Persist block is passed on' ($names -join ',')
		Replay @{ debug = 'prefs-ssh' }
		Check ((Get-TailscalePreference).RunSsh) '`set --ssh`: RunSSH true'
		Replay @{ debug = 'prefs-nodaemon' }
		$threw = $false
		try { Get-TailscalePreference | Out-Null } catch { $threw = $_.Exception.Message -match 'could not be asked' -and $_.Exception.Message -match 'not running' }
		Check $threw 'a stopped daemon THROWS, with the CLI''s sentence'

		# -- connect -------------------------------------------------------------
		[Console]::Error.WriteLine("`n  connect")
		$seen.Clear()
		Replay @{ up = 'up-badkey' }
		$c = Connect-Tailscale -AuthKeyFile '/run/credentials/os7-job@x.service/tailscale-authkey' -LoginServer 'https://headscale.os7.test:8443' -Hostname os7-fixture 2>$null
		$cmd = $seen | Select-Object -Last 1
		Check ($cmd -match '(^| )--auth-key=file:/run/credentials/os7-job@x\.service/tailscale-authkey( |$)') 'the key is passed as file:<path>' $cmd
		Check ($cmd -notmatch '--json' -and $cmd -match '--login-server=https://headscale\.os7\.test:8443' -and $cmd -match '--timeout=60s') `
			'no --json with a key; the login server; a timeout'
		Check (-not $c.Succeeded -and -not $c.LoginPending -and $c.Error -match 'invalid pre auth key') 'a bad key: not Succeeded, the control server''s sentence'
		$seen.Clear()
		$refused = $false
		try { Connect-Tailscale -AuthKeyFile 'tskey-auth-kNOTAREALKEY-0000' 2>$null | Out-Null } catch { $refused = $_.Exception.Message -match 'the key itself' }
		Check ($refused -and $seen.Count -eq 0) 'a KEY where the path belongs is refused, and nothing ran'
		$refused = $false
		try { Connect-Tailscale -AuthKeyFile 'relative/key' 2>$null | Out-Null } catch { $refused = $true }
		Check $refused 'a relative path is refused'
		Replay @{ up = 'up-json-needslogin' }
		$c = Connect-Tailscale -LoginServer 'https://headscale.os7.test:8443' -TimeoutSec 10 2>$null
		$cmd = $seen | Select-Object -Last 1
		Check ($cmd -match '--json' -and $cmd -match '--timeout=10s') 'interactive: --json, the timeout given'
		Check ($c.LoginPending -and -not $c.Succeeded -and $c.AuthUrl -like 'https://headscale.os7.test:8443/register/*') `
			'exit 1 after the URL: LoginPending, with the URL — not a failure'
		Replay @{ up = 'up-without-flags' }
		$c = Connect-Tailscale -LoginServer 'https://headscale.os7.test:8443' 2>$null
		Check (-not $c.Succeeded -and -not $c.LoginPending -and $c.Error -match 'requires mentioning all') '`up` on a running node without every flag: the CLI''s refusal, carried'

		# -- set -----------------------------------------------------------------
		[Console]::Error.WriteLine("`n  set, read back")
		$seen.Clear()
		$refused = $false
		try { Set-TailscalePreference -Ssh $true -Confirm:$false 2>$null | Out-Null } catch { $refused = $_.Exception.Message -match 'does not switch Tailscale SSH on' }
		Check ($refused -and $seen.Count -eq 0) '-Ssh $true is refused, and nothing ran'
		$refused = $false
		try { Set-TailscalePreference -AutoUpdate $true -Confirm:$false 2>$null | Out-Null } catch { $refused = $_.Exception.Message -match 'one updater' }
		Check ($refused -and $seen.Count -eq 0) '-AutoUpdate $true is refused, and nothing ran'
		Replay @{ set = $ok0; debug = 'prefs-local-choices' }
		$p = Set-TailscalePreference -AutoUpdate $false -Ssh $false -Confirm:$false 2>$null
		Check (@($seen | Where-Object { $_ -eq 'set --ssh=false --auto-update=false' }).Count -eq 1) '`tailscale set --ssh=false --auto-update=false`' ($seen -join ' | ')
		Check ($null -ne $p -and $p.AutoUpdateApply -eq $false -and ($seen | Select-Object -Last 1) -eq 'debug prefs') 'and the daemon asked back'
		Replay @{ set = $ok0; debug = 'prefs-ssh' }
		$threw = $false
		try { Set-TailscalePreference -Ssh $false -Confirm:$false 2>$null | Out-Null } catch { $threw = $_.Exception.Message -match 'RunSSH is still true' }
		Check $threw 'exit 0 and RunSSH still true: a refusal naming it'
		Replay @{ set = $ok0; debug = 'prefs-fresh' }
		$threw = $false
		try { Set-TailscalePreference -AutoUpdate $false -Confirm:$false 2>$null | Out-Null } catch { $threw = $_.Exception.Message -match 'not decided' }
		Check $threw 'exit 0 and Apply still NOT DECIDED: a refusal — $null is not $false'

		# -- the environment the CLI runs in -------------------------------------
		$script:TailscaleCommandOverride = $null
		Check ((Get-Command Invoke-TailscaleCommand).ScriptBlock.ToString() -match "'LC_ALL=C\.UTF-8'") 'the CLI is asked in the C locale'
	}
	catch {
		# A STATEMENT-TERMINATING ERROR INSIDE try/finally ABANDONS THE REST OF
		# THE CHECKS AND EXECUTION CONTINUES AFTER THE try — so without this
		# catch the verdict below counts only the checks that ran and says PASS,
		# and pwsh exits 0 (measured 2026-11-10: Test-TailscaleModule's first run
		# printed a PropertyNotFoundException after three checks and then PASS).
		Check $false "the self-test stopped before its end: $($_.Exception.Message)"
	}
	finally {
		$script:TailscaleCommandOverride = $null
	}

	$pass = $script:__tsPass
	$fail = $script:__tsFail
	# THE VERDICT LINE IS THE ONE THE IMAGE CHECK GREPS FOR, worded exactly like
	# every other module's.
	[Console]::Error.WriteLine("`nTailscale self-test: $pass passed, $($fail.Count) failed")
	if ($fail.Count -gt 0) {
		foreach ($f in $fail) { [Console]::Error.WriteLine("    FAILED: $f") }
		[Console]::Error.WriteLine('Tailscale self-test: FAIL')
		throw [System.InvalidOperationException]::new(
			"Test-TailscaleModule: $($fail.Count) of $($pass + $fail.Count) checks failed.")
	}
	[Console]::Error.WriteLine('Tailscale self-test: PASS')
}

Export-ModuleMember -Function Get-TailscaleVersion, Get-TailscaleStatus, Get-TailscalePreference,
	Connect-Tailscale, Disconnect-Tailscale, Set-TailscalePreference, Test-TailscaleModule
