# =============================================================================
# Net — the network subsystem from PowerShell
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, the same cut as powershell/Zfs.
# It knows netplan, iproute2, networkd, NetworkManager and resolved. It knows
# NOTHING about OS/7: not the install mode, not the renderer that follows from
# it (SETUP-PLAN D14), not boot environments, not Entra. Those live one layer up
# in powershell/OS7, so this module stays usable against any Ubuntu host.
#
# WHAT IS IN HERE SO FAR, and the three questions it keeps apart:
#
#   New-NetplanDocument        what to WRITE. A pure function, and the piece
#                              with a drift risk today: the same rule exists in
#                              C# as `NetworkPlan.ToNetplanYaml`, and P3 is the
#                              two-step plan for collapsing the two into one.
#                              Read P3 before changing a single character of the
#                              output — `check-netplan-rule.py` requires the two
#                              to agree BYTE FOR BYTE, and it owns the cases.
#
#   Get-NetLink / -Route       what the KERNEL has. Asked of `ip`, because
#   Get-NetRadio               `netplan apply` returns 0 for a configuration
#                              that brings nothing up.
#
#   Get-NetplanConfiguration   what is CONFIGURED. Asked of NETPLAN, not of a
#                              file: /etc/netplan is several documents merged
#                              key by key, and the one OS/7 writes is not the
#                              answer (measured — see the cmdlet).
#
# The second and third are never merged into one field. P6, and L28 is that
# failure having already happened.
#
# WRITING is not here yet, and neither is the resolver.
# =============================================================================

Set-StrictMode -Version 3.0

# ---------------------------------------------------------------------------
# The document generator
# ---------------------------------------------------------------------------

function ConvertTo-NetplanScalar {
	<#
	.SYNOPSIS
		Internal. A YAML double-quoted scalar.

	.DESCRIPTION
		Not decoration. An SSID may contain a colon, a `#`, a leading `-` or a
		space, and every one of those changes what the line means unquoted. A
		passphrase may contain a backslash.

		Only `\` and `"` need escaping inside a double-quoted scalar, and the
		ORDER matters: backslashes first, or the backslash this function adds in
		front of a quote gets escaped by its own second pass.

		Control characters cannot reach here from Setup — its TextBox refuses
		them — but they CAN reach here from a cmdlet parameter, which is a
		difference between the two callers rather than a shared guarantee. They
		are left alone: a control character in an SSID is a real, if hostile,
		thing, and silently rewriting somebody's network name would be worse
		than a netplan file that fails to parse loudly.

		This is the PowerShell half of `NetworkPlan.Quote` in
		installer/src/OS7.Setup/Model/NetworkPlan.cs. P3.
	#>
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

	return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function ConvertFrom-NetSecret {
	<#
	.SYNOPSIS
		Internal. A [securestring] as the plaintext netplan has to be given.

	.DESCRIPTION
		P7 says a secret is taken as a [securestring] and never as a [string].
		This is the single point at which that is undone, and it exists once so
		that it can be found once.

		It does not make the secret safe — the netplan document itself carries
		the passphrase in plaintext, because that is netplan's design and
		Ubuntu's own tooling does the same (L25). What P7 buys is that the
		secret is not sitting in a parameter, an object or a transcript on the
		way here.
	#>
	param([securestring]$Secret)

	if ($null -eq $Secret) { return '' }
	return (ConvertFrom-SecureString -SecureString $Secret -AsPlainText)
}

function New-NetplanDocument {
	<#
	.SYNOPSIS
		Renders a netplan document. A pure function — it touches no file, no
		interface and no running system.

	.DESCRIPTION
		THE SPECIFICATION IS NOT IN THIS FILE. It is
		`installer/testing/check-netplan-rule.py`, which owns the case table and
		drives this function AND the C# `NetworkPlan.ToNetplanYaml` against it,
		requiring byte-identical output. docs/POWERSHELL-SURFACE-PLAN.md P3 says
		why there are two implementations and when there will be one.

		Being a pure function is what makes it checkable without a network, a
		target or a VM. A generator whose first test is an install is a
		generator tested once.

		WHAT IT DOES NOT DO: write the file. `New-NetplanDocument` hands back
		text, and the text contains any Wi-Fi passphrase in plaintext. Do not
		put the return value in a log, a transcript or an object that can reach
		ConvertTo-Json. The writing half creates the file 0600 BEFORE the
		content goes in (P7).

	.PARAMETER Renderer
		`networkd` or `NetworkManager`. A PARAMETER, never derived here (D14):
		which renderer a machine takes is a product decision that belongs one
		layer up, and a field for it here would be a second place for it to be
		wrong. Not validated against a set, because netplan's renderers are
		netplan's to name.

	.PARAMETER Version
		The release string for the header comment. Identification only.

	.PARAMETER WrittenBy
		Who is claiming the file, for the header comment. Defaults to
		`OS/7 Setup`, which is what makes the default output byte-identical to
		the C# renderer it is checked against.

	.PARAMETER InterfaceName
		The interface, or the literal `auto` for a match glob (L28). Ignored as
		a name whenever -MacAddress is given: the document then keys on the MAC
		and the block gets the label `os7net`.

	.PARAMETER MacAddress
		WHAT NETPLAN ACTUALLY MATCHES ON, and the most expensive thing Phase 3b
		learned. Measured 2026-08-25: one machine, one NIC, `enp0s5` while
		installing and `enp0s2` once booted, because the setup medium is a PCI
		device and removing it renumbers the slots predictable names come from.
		A netplan file naming the install-time name matches nothing afterwards,
		and netplan accepts that in silence — no address, no route, no error.

	.PARAMETER Wireless
		Renders a `wifis:` block rather than `ethernets:`.

	.PARAMETER Method
		`Dhcp` or `Static`. `None` is accepted and REFUSED, loudly, because a
		caller that forgets writes an empty block that netplan accepts and that
		configures nothing. `None` is a real choice (L23) and it is spelled by
		writing no file at all.

	.PARAMETER Address
		A static address WITH its prefix length — `10.42.0.17/24`.

	.PARAMETER Gateway
		Blank is legal. A segment with no route off it is a real thing, and
		requiring a gateway would be inventing a requirement the network does
		not have.

	.EXAMPLE
		New-NetplanDocument -Renderer networkd -Version 1.0.0.116 `
			-MacAddress 52:54:00:12:34:56 -Method Dhcp

	.EXAMPLE
		New-NetplanDocument -Renderer NetworkManager -Version 1.0.0.116 `
			-InterfaceName enp1s0 -Method Static -Address 10.0.2.99/24 `
			-Gateway 10.0.2.2 -Nameserver 10.0.2.3 -SearchDomain corp.example.com
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param(
		[Parameter(Mandatory)][string]$Renderer,
		[Parameter(Mandatory)][string]$Version,
		[string]$WrittenBy = 'OS/7 Setup',

		[string]$InterfaceName,
		[string]$MacAddress,
		[switch]$Wireless,

		[Parameter(Mandatory)]
		[ValidateSet('Dhcp', 'Static', 'None')]
		[string]$Method,

		[string]$Address,
		[string]$Gateway,
		[string[]]$Nameserver = @(),
		[string[]]$SearchDomain = @(),

		# --- wireless ---
		[string]$Ssid,
		[switch]$Hidden,
		[ValidateSet('Psk', 'Enterprise')]
		[string]$Security = 'Psk',
		[securestring]$Psk,
		[string]$Identity,
		[string]$AnonymousIdentity,
		[securestring]$Password,
		[string]$CaCertificate
	)

	if ($Method -eq 'None') {
		throw [System.InvalidOperationException]::new(
			'Method None writes no netplan file; the caller must not render one.')
	}

	# THE DEVICE ID IS A LABEL, NOT A NAME, whenever there is a `match:` below
	# it — netplan keys the block by this string and decides which hardware it
	# means from the match. `os7net` rather than the interface name makes that
	# unmistakable: an id that looks like an interface name invites the next
	# reader to believe the name selects the device, which is the mistake the
	# -MacAddress help documents.
	$matching = (-not [string]::IsNullOrWhiteSpace($MacAddress)) -or ($InterfaceName -eq 'auto')
	$id = if ($matching) { 'os7net' } else { $InterfaceName }

	$y = [System.Text.StringBuilder]::new()
	# Every line ends in "`n" and never "`r`n". The document is written on Linux
	# and compared byte for byte against a C# renderer that uses '\n'; a
	# PowerShell here-string or Out-File would decide this differently on a
	# different host, so it is spelled out.
	$nl = "`n"

	[void]$y.Append("# Written by $WrittenBy $Version.$nl")
	[void]$y.Append("#$nl")
	[void]$y.Append("# Regenerated by Setup on every install. Edit freely afterwards -$nl")
	[void]$y.Append("# nothing in OS/7 rewrites this file after the machine is installed.$nl")
	[void]$y.Append("network:$nl")
	[void]$y.Append("  version: 2$nl")
	[void]$y.Append("  renderer: $Renderer$nl")
	[void]$y.Append($(if ($Wireless) { "  wifis:$nl" } else { "  ethernets:$nl" }))
	[void]$y.Append("    ${id}:$nl")

	if (-not [string]::IsNullOrWhiteSpace($MacAddress)) {
		# L30. The MAC, because the NAME CHANGES between installing and running.
		[void]$y.Append("      match:$nl")
		[void]$y.Append("        macaddress: `"$($MacAddress.ToLowerInvariant())`"$nl")
	}
	elseif ($InterfaceName -eq 'auto') {
		# L28. A glob, because the plan is replayed on a machine whose interface
		# names — and whose MACs — the writer has never seen.
		$glob = if ($Wireless) { 'wl*' } else { 'en*' }
		[void]$y.Append("      match:$nl")
		[void]$y.Append("        name: `"$glob`"$nl")
	}

	if ($Method -eq 'Dhcp') {
		[void]$y.Append("      dhcp4: true$nl")
		# dhcp6 AND accept-ra: a network that offers DHCPv6 and one that offers
		# only router advertisements are both real, and asking for one of them
		# is how a machine ends up with no v6 on the other.
		[void]$y.Append("      dhcp6: true$nl")
		[void]$y.Append("      accept-ra: true$nl")
	}
	else {
		[void]$y.Append("      dhcp4: false$nl")
		[void]$y.Append("      dhcp6: false$nl")
		[void]$y.Append("      addresses:$nl")
		[void]$y.Append("        - $Address$nl")
		if (-not [string]::IsNullOrWhiteSpace($Gateway)) {
			# `routes:`, NOT `gateway4:`. netplan deprecated gateway4/gateway6
			# and warns on them; the warning goes to a log nobody on a headless
			# machine reads.
			[void]$y.Append("      routes:$nl")
			[void]$y.Append("        - to: default$nl")
			[void]$y.Append("          via: $Gateway$nl")
		}
		if ($Nameserver.Count -gt 0 -or $SearchDomain.Count -gt 0) {
			[void]$y.Append("      nameservers:$nl")
			if ($Nameserver.Count -gt 0) {
				[void]$y.Append("        addresses:$nl")
				foreach ($dns in $Nameserver) { [void]$y.Append("          - $dns$nl") }
			}
			if ($SearchDomain.Count -gt 0) {
				[void]$y.Append("        search:$nl")
				foreach ($d in $SearchDomain) {
					[void]$y.Append("          - $(ConvertTo-NetplanScalar $d)$nl")
				}
			}
		}
	}

	if ($Wireless -and -not [string]::IsNullOrWhiteSpace($Ssid)) {
		[void]$y.Append("      access-points:$nl")
		[void]$y.Append("        $(ConvertTo-NetplanScalar $Ssid):$nl")
		if ($Hidden) { [void]$y.Append("          hidden: true$nl") }
		[void]$y.Append("          auth:$nl")

		if ($Security -eq 'Psk') {
			[void]$y.Append("            key-management: psk$nl")
			[void]$y.Append("            password: $(ConvertTo-NetplanScalar (ConvertFrom-NetSecret $Psk))$nl")
			# A CA certificate is meaningless on a PSK network and the C#
			# renderer returns before it can emit one. Mirrored deliberately:
			# the two must agree on what they DO NOT write as well.
			return $y.ToString()
		}

		[void]$y.Append("            key-management: eap$nl")
		[void]$y.Append("            method: peap$nl")
		[void]$y.Append("            identity: $(ConvertTo-NetplanScalar $Identity)$nl")
		if (-not [string]::IsNullOrWhiteSpace($AnonymousIdentity)) {
			[void]$y.Append("            anonymous-identity: $(ConvertTo-NetplanScalar $AnonymousIdentity)$nl")
		}
		[void]$y.Append("            password: $(ConvertTo-NetplanScalar (ConvertFrom-NetSecret $Password))$nl")
		[void]$y.Append("            phase2-auth: MSCHAPV2$nl")
		if (-not [string]::IsNullOrWhiteSpace($CaCertificate)) {
			# L27: blank is legal and means the RADIUS server is not verified,
			# which screen 9W prints rather than defaulting to silently.
			[void]$y.Append("            ca-certificate: $(ConvertTo-NetplanScalar $CaCertificate)$nl")
		}
	}

	return $y.ToString()
}

# ---------------------------------------------------------------------------
# Reading what the kernel actually has
#
# EVERYTHING HERE ASKS THE KERNEL, NEVER A CONFIGURATION FILE, and that is the
# whole reason these exist beside the netplan half. `netplan apply` returns 0 for
# a configuration that brings nothing up — a wrong passphrase, an absent DHCP
# server and a cable in the wrong port all look identical to it. P5.
# ---------------------------------------------------------------------------

# The seam the self-test replays fixtures through. Copied from the Zfs module,
# including the reason it is a scriptblock rather than a path: it lets the WHOLE
# cmdlet be checked — invocation, exit-code handling and parsing — instead of a
# parser lifted out of the path the product actually takes.
$script:NetCommandOverride = $null

function Invoke-NetCommand {
	<#
	.SYNOPSIS
		Internal. Run a program and return its stdout, stderr and exit code.

	.DESCRIPTION
		It does NOT throw on a non-zero exit, and that is deliberate: `rfkill -J`
		exits 1 when /dev/rfkill is absent AND STILL PRINTS VALID JSON — an empty
		device list (measured 2026-08-27). A runner that threw would hide the
		exit code behind an exception; a runner that ignored it would report "no
		radios are blocked" for a machine that cannot be asked. The caller needs
		both halves to tell those apart, so it gets both.
	#>
	param(
		[Parameter(Mandatory)][string]$Command,
		[string[]]$Arguments = @()
	)

	if ($script:NetCommandOverride) {
		return & $script:NetCommandOverride $Command $Arguments
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

function Get-NetJsonField {
	<#
	.SYNOPSIS
		Internal. A property of a parsed JSON object, or $null when it is absent.

	.DESCRIPTION
		Set-StrictMode turns "property that is not there" into a terminating
		error, and `ip -j` OMITS keys rather than emitting nulls: a link with no
		addresses has no `addr_info`, a non-default route has no `gateway`, and a
		route from the kernel has no `prefsrc` unless it has one. Reaching for
		those directly is a cmdlet that works on the machine it was written on.
	#>
	param($Object, [Parameter(Mandatory)][string]$Name)

	if ($null -eq $Object) { return $null }
	if (-not $Object.PSObject.Properties.Name.Contains($Name)) { return $null }
	return $Object.$Name
}

function Get-NetJsonArray {
	<#
	.SYNOPSIS
		Internal. A JSON field that is a list, as a real array — empty when the
		field is absent.

	.DESCRIPTION
		IT EXISTS BECAUSE `@($null)` HAS COUNT 1, NOT 0. Wrapping a missing
		field in `@(…)` produces a one-element array whose single element is
		`$null`, so `foreach` runs once with nothing in hand and the first
		property access is a terminating error under Set-StrictMode.

		Measured 2026-08-27, twice: a link with no `addr_info` — an interface
		that is up and has no address, which is the ordinary state of an
		unplugged port — and `rfkill` output with no `rfkilldevices` key, where
		the count of 1 would have read as "a radio is blocked".

		BUILD-NOTES #92's family. The lesson there was that one helper should
		own the question rather than every call site guessing; this is that
		helper for the list case, as Get-NetplanScalarValue is for the scalar
		one.

		AND THE CALLER STILL WRAPS IT IN `@(…)`. A function cannot hand back
		an empty array: PowerShell unwraps `return @()` to AutomationNull, and
		`.Count` on that is a terminating error under Set-StrictMode. This
		helper removes the `@($null)`-is-one-element trap and CANNOT remove
		the return-unwrapping one — #92's rule stands: the array is forced at
		the boundary, not inside the function.
	#>
	param($Object, [Parameter(Mandatory)][string]$Name)

	$v = Get-NetJsonField $Object $Name
	if ($null -eq $v) { return @() }
	return @($v | Where-Object { $null -ne $_ })
}

function Get-NetLinkKind {
	<#
	.SYNOPSIS
		Internal. Ethernet, Wireless, Loopback or Other.

	.DESCRIPTION
		WIRELESS IS NOT VISIBLE IN `ip -j`. A Wi-Fi adapter reports
		`link_type: "ether"` exactly like a wired one — measured 2026-08-27 —
		so the answer comes from sysfs, where the driver registers a `phy80211`
		symlink for a device the 802.11 stack owns.

		`wireless` is checked as well because it is the older marker and costs
		one stat(2). Neither has been measured POSITIVELY in this repository:
		the host that recorded the fixtures has no radio, so only the negative
		case is evidence. The self-test builds a sysfs tree of its own for the
		positive one and says so.
	#>
	param(
		[Parameter(Mandatory)][string]$Name,
		[string]$LinkType,
		[string]$SysfsRoot = '/sys/class/net'
	)

	if ($LinkType -eq 'loopback') { return 'Loopback' }
	$dir = Join-Path $SysfsRoot $Name
	if ((Test-Path -LiteralPath (Join-Path $dir 'phy80211')) -or
		(Test-Path -LiteralPath (Join-Path $dir 'wireless'))) {
		return 'Wireless'
	}
	if ($LinkType -eq 'ether') { return 'Ethernet' }
	return 'Other'
}

function Get-NetLink {
	<#
	.SYNOPSIS
		The network links this kernel has, with the addresses actually on them.

	.DESCRIPTION
		ONE `ip -j addr show`, not two. `addr show` emits everything `link show`
		does and the addresses besides, so asking twice would be two answers
		about a moving target with nothing to reconcile them.

		`Carrier` is `LOWER_UP` in the link's flags, and it is the field that
		answers "is there a cable in it" — `OperState` can read `UP` on a link
		the kernel is still bringing up, and `DOWN` is ambiguous between
		administratively down and unplugged.

	.PARAMETER Name
		One link. Absent means all of them. A name that does not exist is an
		error from `ip` and an exception here, not an empty list — an empty list
		is what "this machine has no network adapters" looks like, and the two
		must not be spelled the same way.

	.EXAMPLE
		Get-NetLink | Where-Object Kind -eq Ethernet

	.EXAMPLE
		(Get-NetLink -Name enp1s0).Addresses
	#>
	[CmdletBinding()]
	param(
		[string]$Name,
		# Only the self-test passes this. It exists so the wireless branch can
		# be checked against a directory whose shape was measured, on a host
		# with no radio in it.
		[string]$SysfsRoot = '/sys/class/net'
	)

	$argv = @('-j', 'addr', 'show')
	if ($Name) { $argv += $Name }
	$r = Invoke-NetCommand -Command 'ip' -Arguments $argv

	if ($r.ExitCode -ne 0) {
		# `ip` writes PLAIN TEXT on this path — `Device "x" does not exist.` —
		# not JSON (measured). Parsing before checking the exit code would turn
		# a clear message into a JSON syntax error about the wrong thing.
		throw [System.InvalidOperationException]::new(
			"ip $($argv -join ' ') exited $($r.ExitCode): $($r.StdErr.Trim())")
	}

	foreach ($l in ($r.StdOut | ConvertFrom-Json)) {
		$flags = @(Get-NetJsonArray $l 'flags')
		$addresses = foreach ($a in (Get-NetJsonArray $l 'addr_info')) {
			[pscustomobject]@{
				Family        = if ($a.family -eq 'inet6') { 'IPv6' } else { 'IPv4' }
				Address       = $a.local
				PrefixLength  = [int]$a.prefixlen
				Scope         = Get-NetJsonField $a 'scope'
			}
		}
		[pscustomobject]@{
			Name       = $l.ifname
			Index      = [int]$l.ifindex
			MacAddress = Get-NetJsonField $l 'address'
			Kind       = Get-NetLinkKind -Name $l.ifname `
				-LinkType (Get-NetJsonField $l 'link_type') -SysfsRoot $SysfsRoot
			OperState  = Get-NetJsonField $l 'operstate'
			Up         = $flags -contains 'UP'
			Carrier    = $flags -contains 'LOWER_UP'
			Mtu        = [int](Get-NetJsonField $l 'mtu')
			Addresses  = @($addresses)
		}
	}
}

function Get-NetRoute {
	<#
	.SYNOPSIS
		The routes this kernel has.

	.DESCRIPTION
		v4 and v6 are two separate questions to `ip` and are asked separately.
		A machine with a v4 default route and no v6 one is ordinary, and so is
		the reverse on a v6-only segment; merging them into one call would be
		asking a question neither table answers.

	.PARAMETER Family
		`IPv4`, `IPv6`, or `Any` for both. Default is `Any`.

	.EXAMPLE
		Get-NetRoute | Where-Object IsDefault
	#>
	[CmdletBinding()]
	param(
		[ValidateSet('IPv4', 'IPv6', 'Any')]
		[string]$Family = 'Any'
	)

	$families = switch ($Family) {
		'IPv4' { , @('IPv4') }
		'IPv6' { , @('IPv6') }
		default { , @('IPv4', 'IPv6') }
	}

	foreach ($f in $families) {
		$argv = if ($f -eq 'IPv6') { @('-j', '-6', 'route', 'show') }
		else { @('-j', 'route', 'show') }
		$r = Invoke-NetCommand -Command 'ip' -Arguments $argv
		if ($r.ExitCode -ne 0) {
			throw [System.InvalidOperationException]::new(
				"ip $($argv -join ' ') exited $($r.ExitCode): $($r.StdErr.Trim())")
		}
		foreach ($rt in ($r.StdOut | ConvertFrom-Json)) {
			$dst = Get-NetJsonField $rt 'dst'
			[pscustomobject]@{
				Family          = $f
				Destination     = $dst
				# `ip` spells the default route's destination `default`, not
				# 0.0.0.0/0 or ::/0. A caller looking for the gateway should not
				# have to know that.
				IsDefault       = ($dst -eq 'default')
				Gateway         = Get-NetJsonField $rt 'gateway'
				InterfaceName   = Get-NetJsonField $rt 'dev'
				Protocol        = Get-NetJsonField $rt 'protocol'
				Scope           = Get-NetJsonField $rt 'scope'
				PreferredSource = Get-NetJsonField $rt 'prefsrc'
			}
		}
	}
}

function Get-NetRadio {
	<#
	.SYNOPSIS
		Whether any radio is blocked — and whether that question could be
		answered at all.

	.DESCRIPTION
		RETURNS ONE OBJECT WITH A `Known` FLAG, and that is the whole point of
		the cmdlet. `rfkill -J` exits 1 when /dev/rfkill is absent and STILL
		PRINTS `{"rfkilldevices":[]}` — measured 2026-08-27 on the shipped
		image. A caller that reads the list alone concludes "no radio is
		blocked" from a machine that cannot be asked, and then reports a working
		Wi-Fi adapter as an association failure.

		`Devices` IS PASSED THROUGH RAW, deliberately. This repository has never
		recorded rfkill output with an actual radio in it, so there is no
		measured shape to type it against, and inventing one here is the
		assertion this project does not make. Type it when a capture exists.

	.EXAMPLE
		$r = Get-NetRadio
		if (-not $r.Known) { "cannot tell: $($r.Reason)" }
	#>
	[CmdletBinding()]
	param()

	$r = Invoke-NetCommand -Command 'rfkill' -Arguments @('-J')
	$devices = @()
	$parsed = $false
	try {
		$json = $r.StdOut | ConvertFrom-Json
		$devices = @(Get-NetJsonArray $json 'rfkilldevices')
		$parsed = $true
	}
	catch { }

	[pscustomobject]@{
		Known   = ($r.ExitCode -eq 0 -and $parsed)
		Reason  = if ($r.ExitCode -eq 0 -and $parsed) { $null }
		elseif (-not $parsed) { 'rfkill produced no JSON' }
		else { ($r.StdErr.Trim() -replace '\s+', ' ') }
		Devices = $devices
	}
}

# ---------------------------------------------------------------------------
# Reading what is CONFIGURED — which is a different question, and is never
# merged with the one above (P6).
#
# THE ANSWER COMES FROM netplan, NOT FROM A FILE, and that is not fastidiousness.
# /etc/netplan holds SEVERAL documents and netplan merges them by name order,
# key by key. Measured 2026-08-27: `01-os7-network.yaml` saying `dhcp4: true`
# and `99-later.yaml` saying `dhcp4: false` produce a machine whose configured
# state is `dhcp4: false` with a static address — and a reader that opened
# `01-os7-network.yaml`, the file OS/7 writes, would report DHCP for it.
#
# It also means no YAML parser is written here. `netplan get <dotted.key>`
# answers one key at a time out of the merged document, and the shapes it
# answers in were measured rather than assumed.
# ---------------------------------------------------------------------------

function Get-NetplanValue {
	<#
	.SYNOPSIS
		Internal. One key out of the merged netplan document, as raw lines.
	#>
	param(
		[Parameter(Mandatory)][string]$Key,
		[string]$RootDir
	)

	# --root-dir belongs to `get`, not to `netplan` — in front of the
	# subcommand it is an invalid choice and netplan prints usage. Measured,
	# and it fails loudly, which is the good version of this mistake.
	$argv = @('get')
	if ($RootDir) { $argv += @('--root-dir', $RootDir) }
	$argv += $Key

	$r = Invoke-NetCommand -Command 'netplan' -Arguments $argv
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"netplan $($argv -join ' ') exited $($r.ExitCode): $($r.StdErr.Trim())")
	}
	return @($r.StdOut -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
}

function Get-NetplanScalarValue {
	<#
	.SYNOPSIS
		Internal. One netplan key as a single value.

	.DESCRIPTION
		IT EXISTS BECAUSE `(Get-NetplanValue …)[0]` IS WRONG, and wrong in the
		way that does not announce itself. PowerShell UNROLLS a single-element
		array on return, so a key whose answer is one line comes back as a
		[string] rather than a [string[]] — and `[0]` on a string is its first
		CHARACTER.

		Measured on this module before it was fixed: `network.renderer`
		answered `n` instead of `networkd`, and `dhcp4: false` answered `f`,
		which `[bool]` then read as **$true**. A statically configured machine
		reported DHCP. Same family as BUILD-NOTES #65 — PowerShell coercing
		something plausible out of the wrong type, silently.

		So the array is forced at the call site, every time, and nothing else in
		this module indexes a Get-NetplanValue result directly.
	#>
	param(
		[Parameter(Mandatory)][string]$Key,
		[string]$RootDir
	)

	$lines = @(Get-NetplanValue -Key $Key -RootDir $RootDir)
	if ($lines.Count -eq 0) { return $null }
	return ConvertFrom-NetplanScalar $lines[0]
}

function ConvertFrom-NetplanScalar {
	<#
	.SYNOPSIS
		Internal. One netplan scalar as a PowerShell value.

	.DESCRIPTION
		Measured shapes: a string comes back quoted (`"52:54:00:12:34:56"`), a
		boolean bare (`false`), a number bare (`10.0.2.3` in a list), and an
		ABSENT key comes back as the literal `null` with EXIT 0 — not as an
		error and not as an empty string. That last one is why this exists: a
		caller comparing against '' would treat "not configured" as "configured
		as blank".
	#>
	param([AllowNull()][string]$Value)

	if ($null -eq $Value) { return $null }
	$v = $Value.Trim()
	if ($v -eq '' -or $v -eq 'null') { return $null }
	if ($v -eq 'true') { return $true }
	if ($v -eq 'false') { return $false }
	if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
		return $v.Substring(1, $v.Length - 2).Replace('\"', '"').Replace('\\', '\')
	}
	return $v
}

function ConvertFrom-NetplanList {
	<#
	.SYNOPSIS
		Internal. A netplan list of scalars — the `- item` lines — unquoted.
	#>
	param([string[]]$Lines)

	$out = foreach ($l in @($Lines)) {
		if ($l -match '^\s*-\s+(.*)$') { ConvertFrom-NetplanScalar $Matches[1] }
	}
	return @($out | Where-Object { $null -ne $_ })
}

function Get-NetplanDefaultGateway {
	<#
	.SYNOPSIS
		Internal. The `via:` of the route whose `to:` is default, or $null.

	.DESCRIPTION
		`routes` is a list of maps and comes back as

		    - to: "default"
		      via: "10.0.2.2"

		so this walks items rather than lines: a machine may carry several
		routes and only one of them is the default, and matching `via:`
		anywhere would return whichever happened to be first.
	#>
	param([string[]]$Lines)

	$to = $null
	$via = $null
	foreach ($l in @($Lines)) {
		if ($l -match '^\s*-\s+(.*)$') {
			# A new item starts. Whatever the previous one was, decide it now.
			if ($to -eq 'default' -and $via) { return $via }
			$to = $null; $via = $null
			$rest = $Matches[1]
			if ($rest -match '^to:\s*(.*)$') { $to = ConvertFrom-NetplanScalar $Matches[1] }
			elseif ($rest -match '^via:\s*(.*)$') { $via = ConvertFrom-NetplanScalar $Matches[1] }
			continue
		}
		if ($l -match '^\s+to:\s*(.*)$') { $to = ConvertFrom-NetplanScalar $Matches[1] }
		elseif ($l -match '^\s+via:\s*(.*)$') { $via = ConvertFrom-NetplanScalar $Matches[1] }
	}
	if ($to -eq 'default' -and $via) { return $via }
	return $null
}

function Get-NetplanConfiguration {
	<#
	.SYNOPSIS
		What netplan is configured to do — merged, with the files it was merged
		from named separately.

	.DESCRIPTION
		THE PASSPHRASE IS NEVER RETURNED. `netplan get wifis` prints the
		pre-shared key in cleartext (measured), so this reports that a network
		is configured and how it authenticates, and never what with. P7: a
		secret must not enter an object that can reach ConvertTo-Json, a log or
		a screen, and an object nobody meant to print is exactly how it gets
		into all three.

		`RendererIsDefault` is the field to read before believing `Renderer`.
		With an empty /etc/netplan, `netplan get network.renderer` answers
		`NetworkManager` — measured — which is netplan's own default and not a
		decision anybody made. On a headless OS/7 machine, where NetworkManager
		is not installed at all, believing it would be actively wrong.

	.PARAMETER RootDir
		Read the configuration from under this directory instead of `/`. netplan
		supports it natively (`netplan get --root-dir`), which is what lets the
		self-test check this against a tree it builds rather than against the
		machine it happens to run on.

	.EXAMPLE
		(Get-NetplanConfiguration).Interfaces | Format-Table

	.EXAMPLE
		Get-NetplanConfiguration | Select-Object -ExpandProperty Files
		Which documents netplan merged, in the order it merged them.
	#>
	[CmdletBinding()]
	param([string]$RootDir)

	# THE FILE LIST IS PROVENANCE AND THE MERGE DESTROYS IT. netplan reads
	# /run, /etc and /lib and the merged view cannot say which document set a
	# key — so the documents are named here, in netplan's own precedence order,
	# and an operator surprised by the merged answer has somewhere to look.
	$files = foreach ($dir in @('run/netplan', 'etc/netplan', 'lib/netplan')) {
		$path = if ($RootDir) { Join-Path $RootDir $dir } else { "/$dir" }
		if (Test-Path -LiteralPath $path) {
			Get-ChildItem -LiteralPath $path -Filter '*.yaml' -File -ErrorAction SilentlyContinue |
				Sort-Object Name | ForEach-Object {
					[pscustomobject]@{
						Path = $_.FullName
						# The symbolic string PowerShell reports on Linux
						# (`-rw-------`), passed through rather than converted:
						# it is absent on a host with no Unix modes, and L25
						# means an operator wants to SEE it — a netplan file
						# holding a Wi-Fi passphrase must not be world-readable.
						Mode  = (Get-NetJsonField $_ 'UnixMode')
						Bytes = [int]$_.Length
					}
				}
		}
	}
	$files = @($files)

	# Whether ANY document set a renderer, which the merged value cannot say.
	$rendererSet = $false
	foreach ($f in $files) {
		if (Select-String -LiteralPath $f.Path -Pattern '^\s*renderer\s*:' -Quiet) {
			$rendererSet = $true
		}
	}

	$renderer = Get-NetplanScalarValue -Key 'network.renderer' -RootDir $RootDir

	$interfaces = foreach ($kind in @('ethernets', 'wifis')) {
		$block = @(Get-NetplanValue -Key $kind -RootDir $RootDir)
		# An absent section is the literal `null`, not an empty block.
		if (@($block).Count -eq 0 -or (ConvertFrom-NetplanScalar $block[0]) -eq $null) { continue }
		# The ids are the ZERO-INDENT keys of that block. A narrow read of a
		# shape that was measured, not a YAML parser: anything nested is
		# fetched by its own dotted key below.
		$ids = foreach ($l in $block) { if ($l -match '^(\S+):\s*$') { $Matches[1].Trim('"') } }

		foreach ($id in @($ids)) {
			$base = "$kind.$id"
			$dhcp4 = Get-NetplanScalarValue -Key "$base.dhcp4" -RootDir $RootDir
			$addresses = @(ConvertFrom-NetplanList (Get-NetplanValue -Key "$base.addresses" -RootDir $RootDir))

			$ssids = @()
			if ($kind -eq 'wifis') {
				# ONLY the access-point NAMES. The block this reads also carries
				# the passphrase, so nothing below the SSID key is extracted and
				# nothing but the name reaches the object.
				$ap = @(Get-NetplanValue -Key "$base.access-points" -RootDir $RootDir)
				$ssids = foreach ($l in @($ap)) {
					if ($l -match '^(\S.*?):\s*$') { ConvertFrom-NetplanScalar $Matches[1] }
				}
			}

			[pscustomobject]@{
				Id            = $id
				Kind          = if ($kind -eq 'wifis') { 'Wireless' } else { 'Ethernet' }
				MatchMac      = Get-NetplanScalarValue -Key "$base.match.macaddress" -RootDir $RootDir
				MatchName     = Get-NetplanScalarValue -Key "$base.match.name" -RootDir $RootDir
				# Dhcp4 absent means netplan's default, which is OFF. Reported
				# as the [bool] it behaves as rather than as $null, because
				# "not written down" and "off" are the same machine.
				Dhcp4         = [bool]$dhcp4
				Dhcp6         = [bool](Get-NetplanScalarValue -Key "$base.dhcp6" -RootDir $RootDir)
				Method        = if ($dhcp4) { 'Dhcp' } elseif ($addresses.Count) { 'Static' } else { 'None' }
				Addresses     = @($addresses)
				Gateway       = Get-NetplanDefaultGateway (Get-NetplanValue -Key "$base.routes" -RootDir $RootDir)
				Nameservers   = @(ConvertFrom-NetplanList (Get-NetplanValue -Key "$base.nameservers.addresses" -RootDir $RootDir))
				SearchDomains = @(ConvertFrom-NetplanList (Get-NetplanValue -Key "$base.nameservers.search" -RootDir $RootDir))
				Ssids         = @($ssids)
			}
		}
	}

	[pscustomobject]@{
		Files             = $files
		Renderer          = $renderer
		RendererIsDefault = (-not $rendererSet)
		Interfaces        = @($interfaces)
	}
}

# ---------------------------------------------------------------------------
# Writing, applying, and finding out whether it worked
#
# THREE FUNCTIONS AND NOT ONE, deliberately. `netplan apply` returns 0 for a
# configuration that brings nothing up, so "apply" and "did it work" cannot be
# the same call — the second has to ask a different subsystem than the first
# used. Keeping them apart is also what lets the caller decide what to do about
# a failure, which on a headless machine is the whole question.
# ---------------------------------------------------------------------------

function Set-NetplanDocument {
	<#
	.SYNOPSIS
		Writes a netplan document, and hands back what was there before.

	.DESCRIPTION
		THE FILE IS CREATED AND LOCKED DOWN BEFORE THE CONTENT GOES IN. P7, and
		L25 is the measurement behind it: a netplan document for a wireless
		network carries the pre-shared key in plaintext, and a file that is
		world-readable for the microseconds between create and chmod is
		world-readable. netplan warns about the permissions itself — measured,
		"Permissions for … are too open" — which is a second party agreeing.

		`Previous` is returned rather than kept, because a rollback is the
		CALLER's decision and a function that quietly remembered state would
		make it impossible to tell a restored machine from one that was never
		changed.

	.PARAMETER Path
		The document to write.

	.PARAMETER Content
		The document. Written verbatim, so line endings are the caller's.

	.EXAMPLE
		$prev = Set-NetplanDocument -Path /etc/netplan/01-os7-network.yaml -Content $doc
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][AllowEmptyString()][string]$Content
	)

	$existed = [System.IO.File]::Exists($Path)
	$previous = if ($existed) { [System.IO.File]::ReadAllText($Path) } else { $null }

	if ($PSCmdlet.ShouldProcess($Path, 'write a netplan document')) {
		$dir = [System.IO.Path]::GetDirectoryName($Path)
		if (-not [System.IO.Directory]::Exists($dir)) {
			[void][System.IO.Directory]::CreateDirectory($dir)
		}
		# Empty first, then the mode, THEN the content. The order is the point.
		[System.IO.File]::WriteAllText($Path, '')
		if (-not $IsWindows) {
			[System.IO.File]::SetUnixFileMode($Path,
				[System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)
		}
		[System.IO.File]::WriteAllText($Path, $Content)
	}

	[pscustomobject]@{
		Path     = $Path
		Existed  = $existed
		Previous = $previous
	}
}

function Remove-NetplanDocument {
	<#
	.SYNOPSIS
		Deletes a netplan document. Used to undo a document that did not exist
		before.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][string]$Path)

	if ([System.IO.File]::Exists($Path) -and
		$PSCmdlet.ShouldProcess($Path, 'delete a netplan document')) {
		[System.IO.File]::Delete($Path)
	}
}

function Invoke-NetplanApply {
	<#
	.SYNOPSIS
		Runs `netplan apply`. DOES NOT JUDGE WHETHER IT WORKED.

	.DESCRIPTION
		The exit code is returned and not interpreted, because interpreting it
		is the mistake this whole module is arranged against: `netplan apply`
		returns 0 for a configuration that is syntactically fine and brings
		nothing up. A wrong passphrase, an absent DHCP server and a cable in the
		wrong port all look identical to it.

		Whether it worked is `Wait-NetLinkAddress`, which asks the kernel.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param()

	if (-not $PSCmdlet.ShouldProcess('this machine', 'netplan apply')) {
		return [pscustomobject]@{ StdOut = ''; ExitCode = 0; StdErr = '' }
	}
	return Invoke-NetCommand -Command 'netplan' -Arguments @('apply')
}

function Wait-NetLinkAddress {
	<#
	.SYNOPSIS
		Waits for a link to have an address, and answers by asking the kernel.

	.DESCRIPTION
		THE DIAGNOSTIC DOES NOT DEPEND ON THE SUBSYSTEM IT IS DIAGNOSING. netplan
		was told to configure this; `ip` is asked whether it did. That rule is in
		BUILD-NOTES because it was learned by getting a confident, wrong answer.

		Returns the link once it has an address, or `$null` on timeout. The
		FIRST look happens before any sleep, so `-TimeoutSeconds 0` is a single
		question rather than a wait — which is what makes this testable without
		a test that takes as long as its timeout.

	.PARAMETER Name
		The link to watch.

	.PARAMETER TimeoutSeconds
		How long to keep asking. DHCP on a slow segment can take longer than
		anybody expects, and a default that is too short reports a working
		machine as broken.

	.PARAMETER RequireGateway
		Also require a default route out of this link. Off by default: a segment
		with no route off it is a real thing (see New-NetplanDocument -Gateway).

	.EXAMPLE
		if (-not (Wait-NetLinkAddress -Name enp1s0 -TimeoutSeconds 30)) { … }
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Name,
		[int]$TimeoutSeconds = 30,
		[switch]$RequireGateway
	)

	$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
	while ($true) {
		$link = $null
		try { $link = @(Get-NetLink -Name $Name)[0] } catch { $link = $null }

		if ($link -and @($link.Addresses).Count -gt 0) {
			if (-not $RequireGateway) { return $link }
			$default = @(Get-NetRoute | Where-Object { $_.IsDefault -and $_.InterfaceName -eq $Name })
			if ($default.Count -gt 0) { return $link }
		}

		if ((Get-Date) -ge $deadline) { return $null }
		Start-Sleep -Seconds 1
	}
}

# ---------------------------------------------------------------------------
# Asking the RESOLVER, which is a THIRD question and is merged with neither
#
# What the kernel has, what netplan was told, and what a nameserver answers are
# three different facts about one machine, and P6's rule is that they are never
# collapsed into one field. A machine whose netplan names a resolver it cannot
# reach reports the first two perfectly.
#
# THE TOOL IS NOT GUARANTEED TO BE INSTALLED, and that is why this cmdlet has a
# `Known` flag rather than just returning a list. `dig` comes from
# `bind9-dnsutils`, and it is on the shipped amd64 image BY ACCIDENT — measured
# 2026-08-27 out of the packages manifest lifted from that ISO's squashfs: it
# arrived with live-build's `--mode ubuntu` desktop task, which arm64, being
# server-only, never installs. `os7-base.list.chroot` names it as of the same
# day, which settles it for images built from that list and for nothing else.
# No such image exists yet, and this module also runs on a machine that
# apt-installed `os7-module`, inside a container, and against every ISO already
# written. A generic layer does not get to assume a package, so "there is no
# `dig` here" is an ordinary answer, spelled the way Get-NetRadio spells an
# unanswerable question.
# ---------------------------------------------------------------------------

function Resolve-NetSrvRecord {
	<#
	.SYNOPSIS
		The SRV records for a name — and whether the resolver could be asked at
		all.

	.DESCRIPTION
		[System.Net.Dns] CANNOT QUERY SRV, AND `Resolve-DnsName` DOES NOT EXIST
		ON LINUX POWERSHELL. There is no in-process route to an SRV record on
		this platform, which is the whole reason a network module has to shell
		out for one. `_ldap._tcp.dc._msdcs.<domain>` is how every Active
		Directory client finds a domain controller, and DNS is this module's
		subsystem rather than the caller's (P2).

		RETURNS ONE OBJECT WITH A `Known` FLAG — the Get-NetRadio shape, for the
		Get-NetRadio reason. An empty `Records` list means "this name has no SRV
		records". It must never ALSO mean "dig is not installed" or "the
		nameserver did not answer", because the layer above reads an empty list
		as "this domain has no domain controllers" and would report a healthy
		domain as absent.

		`Known` IS DECIDED BY THE DNS STATUS IN THE ANSWER, NOT BY dig's EXIT
		CODE. Measured 2026-08-27 against the Samba DC in
		installer/testing/Dockerfile.ad-dc: dig exits **0** for NXDOMAIN, and it
		exits 0 for SERVFAIL as well — under `+short` both print nothing at all.
		An exit code therefore cannot tell "there are no records" from "the
		resolver failed", so `+comments` is asked for and the status is read out
		of the answer itself. A diagnostic must not depend on the subsystem it
		is diagnosing, and an exit code is a diagnostic.

		Measured in the same session, and the second reason nothing here trusts
		the plumbing: when no nameserver replies dig writes `;; no servers could
		be reached` to **stdout**, not stderr, and exits 9. A caller that looked
		in StdErr for the reason would find an empty string and report nothing
		wrong.

		`Records` IS SORTED RFC 2782's WAY — lowest priority first, and heavier
		weight first inside a priority — over PARSED integers. See the sort
		below for why that sentence has the word "parsed" in it.

	.PARAMETER Name
		The owner name, e.g. `_ldap._tcp.dc._msdcs.corp.example.com`. Nothing
		here knows what an SRV name means: the `_service._proto` convention
		belongs to whoever is asking, and this module does not enforce it.

	.PARAMETER Server
		Ask this nameserver rather than the ones in /etc/resolv.conf. An AD
		client wants the domain's own DNS, which is not necessarily the one this
		machine was handed by DHCP.

	.PARAMETER Tool
		Only the self-test passes this. It exists so the "the tool is not
		installed" branch can be checked by ACTUALLY NOT HAVING THE TOOL — a
		real Get-Command against a name nothing provides — rather than by a fake
		reporting that something is missing.

	.EXAMPLE
		$srv = Resolve-NetSrvRecord -Name '_ldap._tcp.dc._msdcs.corp.example.com'
		if (-not $srv.Known) { "cannot tell: $($srv.Reason)" }
		else { $srv.Records | ForEach-Object { "$($_.Target):$($_.Port)" } }
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
		[string]$Server,
		# Only the self-test passes this — see .PARAMETER Tool above.
		[string]$Tool = 'dig'
	)

	# THE PRESENCE CHECK IS SKIPPED WHEN THE SEAM IS INSTALLED, because then the
	# override IS the program and there is nothing on disk to look for. Without
	# this, every fixture case in Test-NetModule would take the "dig is absent"
	# branch on any host that has no `dig` — which includes live-build's chroot
	# at the point hook 0060 runs, and every developer's machine — and the
	# parser would go silently unchecked in the one place check-image.py runs
	# this module against the shipped copy. Measured: with /usr/bin/dig moved
	# aside, all 68 checks still pass.
	if (-not $script:NetCommandOverride) {
		if (-not (Get-Command $Tool -CommandType Application -ErrorAction SilentlyContinue)) {
			return [pscustomobject]@{
				Name    = $Name
				Known   = $false
				Status  = $null
				Reason  = "$Tool is not installed; SRV lookup needs bind9-dnsutils"
				Records = @()
			}
		}
	}

	$argv = @('+nocmd', '+noall', '+comments', '+answer')
	# PARENTHESISED. `@('x', '@' + $Server)` is ONE element, not two —
	# BUILD-NOTES #91 — and an argument list is where that costs the most.
	if ($Server) { $argv += ('@' + $Server) }
	$argv += @('SRV', $Name)

	# dig's own retry and timeout defaults are left alone. They are the
	# resolver's policy, not this module's, and inventing a shorter one here
	# would make a slow-but-working nameserver look like an absent one.
	$r = Invoke-NetCommand -Command $Tool -Arguments $argv

	# The status line, verbatim from a run against the Samba DC:
	#
	#   ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 16489
	#
	# This is the only thing in the output that says whether the question was
	# answered, which is why `+comments` is asked for at all.
	$status = $null
	$lines = $r.StdOut -split "`r?`n"
	foreach ($line in $lines) {
		if ($line -match ';;\s+->>HEADER<<-.*status:\s*([A-Z]+)') {
			$status = $Matches[1]
			break
		}
	}

	# An ANSWER SECTION line, and the two forms it comes in — both measured on
	# the same DC in the same session:
	#
	#   _ldap._tcp.dc._msdcs.os7.test. 900 IN<TAB>SRV<TAB>0 100 389 dc1.os7.test.
	#   _ldap._tcp.pdc._msdcs.os7.test.<TAB>900 IN<TAB>SRV<TAB>0 100 389 dc1…
	#
	# dig pads the owner name to a column: a short name gets SPACES and a long
	# one gets a TAB. A parser that split on tabs would work on one of those
	# names and not the other, which is the kind of defect that shows up as
	# "this domain has no domain controllers".
	#
	# `IN\s+SRV` is required rather than assumed. dig chases CNAMEs and puts
	# them in the same section, and a line that is not an SRV record must not be
	# read as one.
	$rows = [System.Collections.Generic.List[object]]::new()
	foreach ($line in $lines) {
		if ($line -match '^\S+\s+(\d+)\s+IN\s+SRV\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s*$') {
			# The target arrives fully qualified, with the root label on it:
			# `dc1.os7.test.`. It is dropped here because everything downstream
			# is a host to connect to, and the alternative is every caller
			# stripping it. Nothing else about the name is touched.
			$target = $Matches[5] -replace '\.$', ''
			$rows.Add([pscustomobject]@{
					Priority = [int]$Matches[2]
					Weight   = [int]$Matches[3]
					Port     = [int]$Matches[4]
					Target   = $target
					Ttl      = [int]$Matches[1]
				})
		}
	}

	# RFC 2782's order, AND IT IS A NUMERIC ONE. Sorting the strings dig printed
	# puts priority 10 ahead of priority 5 and weight 20 ahead of weight 100 —
	# BUILD-NOTES #89 — so the fields are parsed to [int] above and the sort runs
	# over those. The recorded fixture arrives out of order on purpose and
	# carries a 5, a 10 and a 100 for exactly this reason: a sort that has only
	# ever seen one record has not been tested.
	$sorted = @($rows | Sort-Object @{ Expression = 'Priority' },
		@{ Expression = 'Weight'; Descending = $true })

	# NOERROR AND NXDOMAIN ARE BOTH ANSWERS: "here are the records" and "there
	# is no such name". SERVFAIL and REFUSED are not, and neither is output with
	# no status line in it at all — which is what an unreachable nameserver
	# looks like.
	$answered = ($status -eq 'NOERROR' -or $status -eq 'NXDOMAIN')
	$reason = $null
	if (-not $answered) {
		$reason = if ($status) { "the resolver answered $status" }
		else {
			# STDOUT FIRST, because that is where dig writes this (measured).
			$said = (($r.StdOut + ' ' + $r.StdErr) -replace '\s+', ' ').Trim()
			if ($said) { $said } else { "$Tool exited $($r.ExitCode) and said nothing" }
		}
	}

	[pscustomobject]@{
		Name    = $Name
		Known   = $answered
		Status  = $status
		Reason  = $reason
		# #92: forced at the boundary. A one-record answer is a LIST of one
		# here, not a bare object whose [0] indexes into a property name.
		Records = @($sorted)
	}
}

# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------

function Test-NetModule {
	<#
	.SYNOPSIS
		Checks this module's own contract. Needs no network and no root.

	.DESCRIPTION
		IT DOES NOT CHECK THE NETPLAN DOCUMENT AGAINST ITS SPECIFICATION, and
		that omission is the point. The cases live in
		`installer/testing/check-netplan-rule.py` because two implementations
		checked against each other pass on the day they drift together — the
		same argument `check-version-rule.py` makes in its own header. A copy of
		the cases here would be a third place for them to be wrong.

		What is here is what belongs to this module alone: the escaping rule,
		the refusal on Method None, and the guarantee that a secret handed in as
		a [securestring] does not come back out anywhere except the document.

	.EXAMPLE
		Import-Module ./powershell/Net/Net.psd1 -Force; Test-NetModule

	.NOTES
		EVERY LINE GOES THROUGH [Console]::Error, NEVER Write-Host, and it
		THROWS rather than returning $false. Both are copied from
		`Test-ZfsModule` and both are load-bearing:

		Write-Host lives in Microsoft.PowerShell.Utility, which is exactly what
		does not resolve inside a chroot (BUILD-NOTES #38) — and a chroot is
		where `installer/testing/check-image.py` runs this, against the SHIPPED
		module. Reporting through Write-Host would break the check for no
		reason.

		Throwing is what gives the caller a non-zero exit code. A function that
		returns $false leaves pwsh exiting 0, and check-image.py reads EXIT=0 as
		the verdict — so a silent $false would be a self-test that fails and an
		image that passes.
	#>
	[CmdletBinding()]
	param(
		# Where the recorded `ip`/`rfkill` output lives. Defaults to the copy
		# shipped beside the module, which is what lets this run inside the
		# chroot at build time and on a machine with no network at all.
		[string]$FixturePath
	)

	if (-not $FixturePath) {
		$FixturePath = Join-Path $PSScriptRoot 'tests/fixtures'
	}

	$pass = 0
	$fail = @()
	function Check([bool]$ok, [string]$what, [string]$detail = '') {
		$line = "      {0}  {1}" -f $(if ($ok) { 'ok  ' } else { 'FAIL' }), $what
		if ($detail) { $line += "   [$detail]" }
		[Console]::Error.WriteLine($line)
		if ($ok) { $script:__netPass++ } else { $script:__netFail += $what }
	}
	$script:__netPass = 0
	$script:__netFail = @()

	[Console]::Error.WriteLine("`nNet self-test — no network, no root, no netplan")
	[Console]::Error.WriteLine("  the escaping rule")

	Check ((ConvertTo-NetplanScalar 'plain') -eq '"plain"') 'a plain scalar is quoted'
	Check ((ConvertTo-NetplanScalar 'we: "guest" #1') -eq '"we: \"guest\" #1"') `
		'a quote inside a scalar is escaped'
	# The order matters and this is the case that catches it being wrong: escape
	# quotes first and the backslash pass doubles the escape this one added.
	Check ((ConvertTo-NetplanScalar 'back\slash') -eq '"back\\slash"') `
		'a backslash is escaped before anything else'
	Check ((ConvertTo-NetplanScalar 'both\"x') -eq '"both\\\"x"') `
		'a backslash and a quote together survive in the right order'
	Check ((ConvertTo-NetplanScalar '') -eq '""') 'an empty scalar is legal'

	[Console]::Error.WriteLine("  the refusals")

	$threw = $false
	try { New-NetplanDocument -Renderer networkd -Version t -Method None | Out-Null }
	catch [System.InvalidOperationException] { $threw = $true }
	Check $threw 'Method None refuses to render a document'

	[Console]::Error.WriteLine("  line endings")

	$doc = New-NetplanDocument -Renderer networkd -Version t -InterfaceName eth0 -Method Dhcp
	Check (-not $doc.Contains("`r")) 'the document carries no carriage returns'
	Check $doc.EndsWith("`n") 'the document ends with a newline'

	[Console]::Error.WriteLine("  secrets")

	$secret = ConvertTo-SecureString 'PSK-CANARY-VALUE' -AsPlainText -Force
	$wifi = New-NetplanDocument -Renderer networkd -Version t -InterfaceName wlan0 `
		-Wireless -Method Dhcp -Ssid 'net' -Psk $secret
	Check ($wifi.Contains('password: "PSK-CANARY-VALUE"')) `
		'a securestring reaches the document as netplan needs it'
	# P7's actual guarantee: the secret is in the DOCUMENT and nowhere else this
	# module produces. A [securestring] parameter that got copied into an object
	# on the way through would have no symptom until it appeared in a log.
	$plain = New-NetplanDocument -Renderer networkd -Version t -InterfaceName eth0 -Method Dhcp
	Check (-not $plain.Contains('PSK-CANARY-VALUE')) `
		'a secret does not leak into an unrelated document'

	# -----------------------------------------------------------------------
	# The readers, replayed against RECORDED REAL OUTPUT.
	#
	# The seam replaces the command runner rather than the parser, so what is
	# checked is the whole cmdlet — invocation, exit-code handling and parsing —
	# and not a parser lifted out of the path the product takes. Copied from
	# Test-ZfsModule, including the .GetNewClosure(): the scriptblock resolves
	# $full when it RUNS, by which time the scope that defined it is gone, and
	# under Set-StrictMode that is an error rather than a silent $null.
	# -----------------------------------------------------------------------
	[Console]::Error.WriteLine("  the readers, against fixtures in $FixturePath")

	if (-not (Test-Path -LiteralPath $FixturePath)) {
		# A SKIP, not a pass. The fixtures travel with the module precisely so
		# that this cannot silently become a self-test of the escaping rule
		# alone, and an image that shipped without them must say so.
		Check $false 'the recorded fixtures are shipped beside the module' $FixturePath
	}
	else {
		$replay = {
			param($file, $exit)
			$full = Join-Path $FixturePath $file
			$script:NetCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{
					StdOut   = (Get-Content -Raw -LiteralPath $full)
					ExitCode = $exit
					StdErr   = ''
				}
			}.GetNewClosure()
		}

		# A sysfs root with nothing in it, so `Kind` is decided by the recorded
		# link_type alone and not by whatever adapters the host running this
		# happens to have.
		$noSysfs = Join-Path ([System.IO.Path]::GetTempPath()) "os7-net-nosysfs-$PID"

		try {
			& $replay 'ip-addr.json' 0
			$links = @(Get-NetLink -SysfsRoot $noSysfs)
			$lo = $links | Where-Object Name -eq 'lo'
			$eth = $links | Where-Object Name -eq 'eth0'

			Check ($links.Count -eq 2) 'Get-NetLink: nothing in the capture was dropped' "$($links.Count)"
			Check ($lo.Kind -eq 'Loopback') 'Get-NetLink: link_type loopback is Loopback'
			Check ($eth.Kind -eq 'Ethernet') 'Get-NetLink: link_type ether with no phy80211 is Ethernet'
			Check ($eth.MacAddress -eq '0a:6c:7a:97:55:3e') 'Get-NetLink: the MAC comes back'
			Check ($eth.Mtu -eq 1500) 'Get-NetLink: Mtu is an int' "$($eth.Mtu)"
			Check ($eth.Carrier -eq $true) 'Get-NetLink: LOWER_UP becomes Carrier'
			Check ($eth.Addresses.Count -eq 1) 'Get-NetLink: one address on eth0'
			Check ($eth.Addresses[0].Address -eq '172.17.0.2') 'Get-NetLink: the address'
			Check ($eth.Addresses[0].PrefixLength -eq 16) 'Get-NetLink: the prefix length is an int'
			Check ($eth.Addresses[0].Family -eq 'IPv4') 'Get-NetLink: inet becomes IPv4'
			# lo carries both families in one addr_info, which is the case that
			# catches a parser assuming one address per link.
			Check ($lo.Addresses.Count -eq 2) 'Get-NetLink: lo carries v4 and v6'
			Check (($lo.Addresses | Where-Object Family -eq 'IPv6').Address -eq '::1') `
				'Get-NetLink: inet6 becomes IPv6'

			# A LINK WITH NO ADDRESSES AT ALL — an unplugged port, the ordinary
			# state of half the ports on a machine. `ip -j` omits `addr_info`
			# entirely, and `@($null)` has Count 1, so the naive wrapping runs
			# the loop once with nothing in hand. BUILD-NOTES #92's family, and
			# this case is what caught it.
			$script:NetCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{
					StdOut = '[{"ifindex":3,"ifname":"eth1","flags":["BROADCAST","MULTICAST"],' +
					'"mtu":1500,"operstate":"DOWN","link_type":"ether","address":"aa:bb:cc:dd:ee:ff"}]'
					ExitCode = 0; StdErr = ''
				}
			}
			$bare = @(Get-NetLink -SysfsRoot $noSysfs)
			Check ($bare.Count -eq 1) 'Get-NetLink: a link with no addr_info still comes back'
			Check ($bare[0].Addresses.Count -eq 0) `
				'Get-NetLink: and its address list is EMPTY, not one null'
			Check ($bare[0].Carrier -eq $false) 'Get-NetLink: no LOWER_UP is no carrier'
			Check ($bare[0].Up -eq $false) 'Get-NetLink: no UP flag is down'

			& $replay 'ip-route4.json' 0
			$routes = @(Get-NetRoute -Family IPv4)
			$def = $routes | Where-Object IsDefault
			$link = $routes | Where-Object { -not $_.IsDefault }

			Check ($routes.Count -eq 2) 'Get-NetRoute: both routes came back' "$($routes.Count)"
			Check ($def.Gateway -eq '172.17.0.1') 'Get-NetRoute: the default gateway'
			Check ($def.Destination -eq 'default') "Get-NetRoute: ip spells it 'default'"
			# THE FIELD THAT IS NOT THERE. A non-default route has no `gateway`
			# key at all, and Set-StrictMode turns reaching for it into a
			# terminating error — so this is the check that a cmdlet written on
			# a machine with a gateway still works on one without.
			Check ($null -eq $link.Gateway) 'Get-NetRoute: an absent gateway key is $null, not an error'
			Check ($link.PreferredSource -eq '172.17.0.2') 'Get-NetRoute: prefsrc when present'
			Check ($null -eq $def.PreferredSource) 'Get-NetRoute: prefsrc when absent'

			& $replay 'ip-route6-empty.json' 0
			$v6 = @(Get-NetRoute -Family IPv6)
			Check ($v6.Count -eq 0) 'Get-NetRoute: an empty v6 table is empty, not an error'

			# rfkill EXITS 1 AND STILL PRINTS VALID JSON when /dev/rfkill is
			# absent — measured. This is the check that stops an unanswerable
			# question reading as "no radio is blocked".
			& $replay 'rfkill-unavailable.json' 1
			$radio = Get-NetRadio
			Check ($radio.Known -eq $false) 'Get-NetRadio: a non-zero exit is not a clean answer'
			Check ($radio.Devices.Count -eq 0) 'Get-NetRadio: and the empty list is still reported'

			& $replay 'rfkill-unavailable.json' 0
			$radio = Get-NetRadio
			Check ($radio.Known -eq $true) 'Get-NetRadio: exit 0 with no devices IS a clean answer'

			# JSON WITH NO `rfkilldevices` KEY AT ALL. `@($null)` would make
			# that a list of ONE, and the OS/7 layer reads a non-empty list as
			# "a radio is blocked" — so a missing key would ground a working
			# Wi-Fi adapter.
			$script:NetCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{ StdOut = '{"something-else": []}'; ExitCode = 0; StdErr = '' }
			}
			$radio = Get-NetRadio
			Check ($radio.Devices.Count -eq 0) `
				'Get-NetRadio: a missing rfkilldevices key is NO devices, not one null'

			# The wireless branch, against a sysfs tree built here. The hosts
			# that recorded these fixtures have no radio, so the POSITIVE case
			# has never been measured on real hardware — what is checked is that
			# the marker decides the answer, not that a real adapter has it.
			$fakeSysfs = Join-Path ([System.IO.Path]::GetTempPath()) "os7-net-sysfs-$PID"
			try {
				New-Item -ItemType Directory -Force -Path (Join-Path $fakeSysfs 'eth0') | Out-Null
				New-Item -ItemType Directory -Force -Path (Join-Path $fakeSysfs 'wlan0') | Out-Null
				New-Item -ItemType File -Force -Path (Join-Path $fakeSysfs 'wlan0/phy80211') | Out-Null

				& $replay 'ip-addr.json' 0
				$k = Get-NetLinkKind -Name 'wlan0' -LinkType 'ether' -SysfsRoot $fakeSysfs
				Check ($k -eq 'Wireless') 'Get-NetLinkKind: phy80211 makes an ether link Wireless'
				$k = Get-NetLinkKind -Name 'eth0' -LinkType 'ether' -SysfsRoot $fakeSysfs
				Check ($k -eq 'Ethernet') 'Get-NetLinkKind: without it the same link_type is Ethernet'
				$k = Get-NetLinkKind -Name 'wlan0' -LinkType 'loopback' -SysfsRoot $fakeSysfs
				Check ($k -eq 'Loopback') 'Get-NetLinkKind: loopback wins over the marker'
			}
			finally {
				Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $fakeSysfs
			}

			# A failing `ip` must NOT be parsed. It writes plain text, not JSON,
			# so a cmdlet that parses first reports a JSON syntax error about
			# the wrong thing.
			$script:NetCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{
					StdOut = ''; ExitCode = 1; StdErr = 'Device "nosuchdev" does not exist.'
				}
			}
			$threw = $false
			try { Get-NetLink -Name nosuchdev | Out-Null }
			catch [System.InvalidOperationException] { $threw = $true }
			Check $threw 'Get-NetLink: a device that does not exist throws, and is not an empty list'
		}
		catch {
			# Same guard, same reason as the netplan section below — and the
			# line, for the same reason as there.
			Check $false 'the readers ran to the end' `
				"$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
		}
		finally {
			$script:NetCommandOverride = $null
		}
	}

	# -----------------------------------------------------------------------
	# The resolver, replayed against RECORDED REAL `dig` OUTPUT.
	#
	# FIVE CASES AND NOT ONE, because four of them are ways of being wrong that
	# a single happy-path test cannot see:
	#
	#   a MULTI-record answer   a sort that has only ever seen one record has
	#                           not been tested (#89), so the fixture carries
	#                           priorities 0, 5, 10 and 100 and ARRIVES OUT OF
	#                           ORDER
	#   a SINGLE-record answer  #92 — one record must still be a LIST of one
	#   NXDOMAIN                an ANSWER, and `Known` must stay $true for it
	#   SERVFAIL with EXIT 0    not an answer, and the exit code says otherwise
	#   no `dig` on the machine the ordinary case on arm64, and it must not read
	#                           as "this domain has no domain controllers"
	# -----------------------------------------------------------------------
	[Console]::Error.WriteLine("  the resolver, against recorded dig output")

	$digFixture = Join-Path $FixturePath 'dig-srv-ldap.json'
	if (-not (Test-Path -LiteralPath $digFixture)) {
		# A SKIP is not a pass, for the reason above the `ip` fixtures.
		Check $false 'the recorded dig captures are shipped beside the module' $digFixture
	}
	else {
		# THESE TWO FIXTURES ARE AN ENVELOPE, not raw stdout like the ip and
		# rfkill ones, and the reason is written in their README: dig's exit
		# code is part of the evidence — 9 when nothing answered — and a file
		# of raw output cannot carry one. The rfkill capture pays for that by
		# keeping its exit code here in the test instead.
		$replayDig = {
			param($file)
			$cap = Get-Content -Raw -LiteralPath (Join-Path $FixturePath $file) | ConvertFrom-Json
			$script:NetCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{
					StdOut   = $cap.stdout
					ExitCode = [int]$cap.exitcode
					StdErr   = $cap.stderr
				}
			}.GetNewClosure()
			return $cap
		}

		try {
			$ldapCap = & $replayDig 'dig-srv-ldap.json'
			$srv = Resolve-NetSrvRecord -Name '_ldap._tcp.dc._msdcs.os7.test'

			Check ($srv.Known -eq $true) 'Resolve-NetSrvRecord: NOERROR is an answer'
			Check ($srv.Status -eq 'NOERROR') `
				'Resolve-NetSrvRecord: the status comes out of the ANSWER, not out of the exit code'

			# dig's OWN COUNT is the independent witness. It says in the header
			# how many records it put in the section, so a parser that silently
			# dropped one cannot pass here by agreeing with itself.
			$declared = if ($ldapCap.stdout -match 'ANSWER:\s*(\d+)') { [int]$Matches[1] } else { -1 }
			Check ($srv.Records.Count -eq $declared) `
				'Resolve-NetSrvRecord: every record dig declared was parsed' `
				"$($srv.Records.Count) of $declared"

			$order = ($srv.Records | ForEach-Object { $_.Target }) -join ' '
			Check ($order -eq 'dc1.os7.test dc2.os7.test dc3.os7.test branch-dc.os7.test dc5.os7.test') `
				'Resolve-NetSrvRecord: RFC 2782 order - priority up, weight down' $order

			# The two comparisons a STRING sort gets wrong, named rather than
			# left to be inferred from the line above. This is #89, and it is
			# the whole reason the fixture has five records in it.
			Check ($srv.Records[2].Priority -eq 5 -and $srv.Records[3].Priority -eq 10) `
				'Resolve-NetSrvRecord: priority 5 before priority 10, which a string sort reverses'
			Check ($srv.Records[0].Weight -eq 100 -and $srv.Records[1].Weight -eq 20) `
				'Resolve-NetSrvRecord: weight 100 before weight 20, which a string sort also reverses'

			Check ($srv.Records[0].Priority -is [int] -and $srv.Records[0].Weight -is [int]) `
				'Resolve-NetSrvRecord: Priority and Weight are ints, which is what makes the sort real'
			Check ($srv.Records[0].Port -is [int]) 'Resolve-NetSrvRecord: Port is an int too'
			Check ($srv.Records[3].Port -eq 3268) `
				'Resolve-NetSrvRecord: the port is read per record, not assumed to be 389'
			Check ($srv.Records[0].Ttl -eq 900) 'Resolve-NetSrvRecord: the TTL comes back'
			Check (-not $srv.Records[0].Target.EndsWith('.')) `
				'Resolve-NetSrvRecord: the root label is off the target' $srv.Records[0].Target

			# ONE RECORD, and not a trimmed copy of the fixture above. This is
			# the verbatim answer to
			#
			#   dig +nocmd +noall +comments +answer @127.0.0.1 SRV \
			#       _ldap._tcp.pdc._msdcs.os7.test
			#
			# on the same DC in the same session — the PDC record, which a
			# domain has exactly one of. It is inline rather than a fixture
			# because it carries the OTHER spelling of an answer line: this
			# owner name is long enough that dig separates it from the TTL with
			# a TAB, where the shorter name in the fixture gets SPACES. A
			# parser that split on tabs would work on one and not the other.
			$script:NetCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{
					StdOut = ";; Got answer:`n" +
					";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 35516`n" +
					";; flags: qr aa rd ra ad; QUERY: 1, ANSWER: 1, AUTHORITY: 1, ADDITIONAL: 0`n`n" +
					";; ANSWER SECTION:`n" +
					"_ldap._tcp.pdc._msdcs.os7.test.`t900 IN`tSRV`t0 100 389 dc1.os7.test.`n`n"
					ExitCode = 0; StdErr = ''
				}
			}
			$one = Resolve-NetSrvRecord -Name '_ldap._tcp.pdc._msdcs.os7.test'
			# `-is [array]` AND NOT JUST `.Count`. A bare PSCustomObject answers
			# 1 to `.Count` and hands its whole self back from `[0]` on pwsh
			# 7.6.5, so a Count check alone passes against exactly the defect
			# #92 is about. The type is the thing that differs.
			Check (($one.Records -is [array]) -and ($one.Records.Count -eq 1)) `
				'Resolve-NetSrvRecord: one record is a LIST of one, not a bare object' `
				"$($one.Records.GetType().Name), Count $($one.Records.Count)"
			Check ($one.Records[0].Target -eq 'dc1.os7.test') `
				'Resolve-NetSrvRecord: and [0] is the record, not a character of it'
			Check ($one.Records[0].Port -eq 389) `
				'Resolve-NetSrvRecord: a TAB between the owner name and the TTL parses like a space'

			# NXDOMAIN IS AN ANSWER. "There is no such name" and "nobody would
			# tell me" are different facts about a domain, and the layer above
			# turns the first into "no domain controllers" and the second into
			# a diagnostic.
			& $replayDig 'dig-srv-none.json' | Out-Null
			$none = Resolve-NetSrvRecord -Name '_ldap._tcp.dc._msdcs.nosuchdomain.os7.test'
			Check ($none.Known -eq $true) 'Resolve-NetSrvRecord: NXDOMAIN IS an answer'
			Check ($none.Status -eq 'NXDOMAIN') 'Resolve-NetSrvRecord: and the status says which answer'
			Check ($none.Records.Count -eq 0) `
				'Resolve-NetSrvRecord: an empty answer is an EMPTY list, not one null'
			Check ($null -eq $none.Reason) 'Resolve-NetSrvRecord: an answered question carries no Reason'

			# NOTHING ANSWERED AT ALL. Verbatim from the same session:
			#
			#   dig … +time=1 +tries=1 @127.0.0.99 SRV _ldap._tcp.dc._msdcs.os7.test
			#
			# EXIT 9, AND THE MESSAGE ON STDOUT — stderr came back empty, which
			# is why Reason reads stdout first and why the fixture envelope
			# records both streams instead of assuming which one carries what.
			$script:NetCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{
					StdOut = ";; communications error to 127.0.0.99#53: timed out`n" +
					";; no servers could be reached`n"
					ExitCode = 9; StdErr = ''
				}
			}
			$dead = Resolve-NetSrvRecord -Name '_ldap._tcp.dc._msdcs.os7.test'
			Check ($dead.Known -eq $false) `
				'Resolve-NetSrvRecord: no answer at all is not a clean empty list'
			Check ($null -eq $dead.Status) 'Resolve-NetSrvRecord: and there is no status to report'
			Check ($dead.Reason.Contains('no servers could be reached')) `
				'Resolve-NetSrvRecord: the reason is read from STDOUT, where dig writes it' $dead.Reason
			Check ($dead.Records.Count -eq 0) 'Resolve-NetSrvRecord: and the record list is empty'

			# SERVFAIL WITH EXIT 0, and the exit code is the measured half.
			# 2026-08-27, with a twenty-line UDP responder that answers one
			# query with RCODE 2 and one with RCODE 5: a real `dig` against a
			# synthetic server exits **0** for both SERVFAIL and REFUSED, and
			# prints the status in the `+comments` header and nowhere else.
			# The text below is that header, with the responder's own
			# "extra bytes" warning left out because nothing reads it.
			#
			# This is precisely the answer a cmdlet that trusted the exit code
			# would report as "this domain has no domain controllers", and it
			# is the reason the status is read out of the answer at all.
			$script:NetCommandOverride = {
				param($cmd, $a)
				[pscustomobject]@{
					StdOut = ";; Got answer:`n" +
					";; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 11019`n" +
					";; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0`n`n"
					ExitCode = 0; StdErr = ''
				}
			}
			$broken = Resolve-NetSrvRecord -Name '_ldap._tcp.dc._msdcs.os7.test'
			Check ($broken.Known -eq $false) 'Resolve-NetSrvRecord: SERVFAIL with EXIT 0 is not an answer'
			Check ($broken.Reason -eq 'the resolver answered SERVFAIL') `
				'Resolve-NetSrvRecord: and the reason names the status' $broken.Reason

			# THE TOOL NOT BEING THERE, and this case is not faked. The seam is
			# put away so the REAL Get-Command runs, against a name nothing on
			# any machine provides — a fake that reported "missing" would be
			# testing the fake. On arm64, where bind9-dnsutils is in no package
			# list, this is the ordinary path rather than the exotic one.
			$script:NetCommandOverride = $null
			$noTool = Resolve-NetSrvRecord -Name '_ldap._tcp.dc._msdcs.os7.test' `
				-Tool 'os7-no-such-dns-tool'
			Check ($noTool.Known -eq $false) `
				'Resolve-NetSrvRecord: an absent dig is "cannot tell", not "no records"'
			Check ($noTool.Records.Count -eq 0) `
				'Resolve-NetSrvRecord: and the list is empty rather than absent'
			Check ($noTool.Reason.Contains('bind9-dnsutils')) `
				'Resolve-NetSrvRecord: the reason names the package that supplies it' $noTool.Reason
		}
		catch {
			# The same guard and the same reason as the two sections either
			# side of this one: a section that throws must FAIL, not vanish.
			Check $false 'the resolver ran to the end' `
				"$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
		}
		finally {
			$script:NetCommandOverride = $null
		}
	}

	# -----------------------------------------------------------------------
	# The CONFIGURED side, against a tree built here and read by the real
	# netplan through its own --root-dir.
	#
	# Not a fixture, because there is nothing to record: the thing being checked
	# is what NETPLAN does with two documents, and only netplan can answer that.
	# The same shape as check-home-logic.py's fake zfs whose datasets are real
	# mounts — the seam is real, the data is constructed.
	# -----------------------------------------------------------------------
	[Console]::Error.WriteLine("  the configured side, through netplan --root-dir")

	if (-not (Get-Command netplan -CommandType Application -ErrorAction SilentlyContinue)) {
		# A SKIP that is printed, not a pass. This half cannot run on a
		# developer's Windows or macOS box, and a check that quietly counted
		# itself green there would report a clean run for something it never
		# executed. It DOES run in the chroot at build time and on any
		# installed machine.
		[Console]::Error.WriteLine('      SKIP  netplan is not on this host; ' +
			'this half runs in the chroot and on an installed machine')
	}
	else {
		$root = Join-Path ([System.IO.Path]::GetTempPath()) "os7-netplan-root-$PID"
		# A SECTION THAT THROWS MUST FAIL, NOT VANISH. Without this catch an
		# exception anywhere below leaves the section contributing ZERO checks
		# and the verdict reading "all passed" — which is this repository's
		# oldest failure shape and which this file produced on its first run,
		# over Get-ChildItem's UnixMode. A count is not a result unless
		# something guarantees the count was reached.
		try {
			$ErrorActionPreference = 'Stop'
			$dir = Join-Path $root 'etc/netplan'
			New-Item -ItemType Directory -Force -Path $dir | Out-Null

			# THE MERGE, which is the whole reason this cmdlet asks netplan
			# instead of opening the file OS/7 writes. 01 says DHCP; 99 says
			# static. The machine is static, and a reader of 01 alone says DHCP.
			Set-Content -NoNewline -Path (Join-Path $dir '01-os7-network.yaml') -Value @"
network:
  version: 2
  renderer: networkd
  ethernets:
    os7net:
      match:
        macaddress: "52:54:00:12:34:56"
      dhcp4: true
"@
			Set-Content -NoNewline -Path (Join-Path $dir '99-site.yaml') -Value @"
network:
  version: 2
  ethernets:
    os7net:
      dhcp4: false
      addresses:
        - 10.0.2.99/24
      routes:
        - to: default
          via: 10.0.2.2
      nameservers:
        addresses: [10.0.2.3, 10.0.2.4]
        search: ["corp.example.com"]
  wifis:
    wlan0:
      dhcp4: true
      access-points:
        "Branch-Office":
          auth:
            key-management: psk
            password: "hunter2hunter2"
"@
			$cfg = Get-NetplanConfiguration -RootDir $root
			$eth = $cfg.Interfaces | Where-Object Id -eq 'os7net'
			$wifi = $cfg.Interfaces | Where-Object Id -eq 'wlan0'

			Check ($cfg.Files.Count -eq 2) 'Get-NetplanConfiguration: both documents are named' "$($cfg.Files.Count)"
			Check ($cfg.Renderer -eq 'networkd') 'Get-NetplanConfiguration: the renderer'
			Check ($cfg.RendererIsDefault -eq $false) `
				'Get-NetplanConfiguration: a renderer somebody wrote is not flagged as a default'
			Check ($eth.Method -eq 'Static') `
				'Get-NetplanConfiguration: the LATER document wins - dhcp4 true then false is Static'
			Check ($eth.Dhcp4 -eq $false) 'Get-NetplanConfiguration: and Dhcp4 says so'
			Check ($eth.MatchMac -eq '52:54:00:12:34:56') `
				'Get-NetplanConfiguration: the match survives from the EARLIER document'
			Check ($null -eq $eth.MatchName) 'Get-NetplanConfiguration: an absent key is $null, not "null"'
			Check ($eth.Addresses.Count -eq 1 -and $eth.Addresses[0] -eq '10.0.2.99/24') `
				'Get-NetplanConfiguration: the address'
			Check ($eth.Gateway -eq '10.0.2.2') `
				'Get-NetplanConfiguration: the default gateway comes out of the routes list'
			Check ($eth.Nameservers.Count -eq 2) 'Get-NetplanConfiguration: both nameservers'
			Check ($eth.SearchDomains -contains 'corp.example.com') 'Get-NetplanConfiguration: the search domain'
			Check ($wifi.Kind -eq 'Wireless') 'Get-NetplanConfiguration: a wifis block is Wireless'
			Check ($wifi.Ssids -contains 'Branch-Office') 'Get-NetplanConfiguration: the SSID is reported'

			# P7, AND THE ONE CHECK HERE THAT PROTECTS A SECRET RATHER THAN A
			# READING. `netplan get wifis` prints the pre-shared key, so the
			# passphrase passes through this cmdlet on every call. What must
			# never happen is that it comes back out — into a variable, a log,
			# a --print-plan or a screenshot.
			$serialised = $cfg | ConvertTo-Json -Depth 8
			Check (-not $serialised.Contains('hunter2hunter2')) `
				'Get-NetplanConfiguration: the passphrase is NOT in what it returns'

			# The empty case. netplan answers `NetworkManager` for a machine
			# with no configuration at all — its own default, and on a headless
			# OS/7 machine a renderer that is not installed. L23's "no network"
			# and "nobody has configured one" must not read the same.
			$bare = Join-Path ([System.IO.Path]::GetTempPath()) "os7-netplan-bare-$PID"
			try {
				New-Item -ItemType Directory -Force -Path (Join-Path $bare 'etc/netplan') | Out-Null
				$empty = Get-NetplanConfiguration -RootDir $bare
				Check ($empty.Interfaces.Count -eq 0) 'Get-NetplanConfiguration: no documents, no interfaces'
				Check ($empty.RendererIsDefault -eq $true) `
					"Get-NetplanConfiguration: netplan's fallback renderer is flagged as a default"
			}
			finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $bare }
		}
		catch {
			# The LINE, not just the message. "Something threw somewhere in this
			# section" is a diagnostic that sends the next reader back to
			# bisecting by hand, which is the state this catch was added to end.
			Check $false 'the configured side ran to the end' `
				"$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
		}
		finally {
			Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $root
		}
	}

	$pass = $script:__netPass
	$fail = @($script:__netFail)

	[Console]::Error.WriteLine("`nNet self-test: $pass passed, $($fail.Count) failed")
	if ($fail.Count) {
		[Console]::Error.WriteLine('FAILED: ' + ($fail -join '; '))
		throw "Net self-test failed: $($fail.Count) check(s)"
	}
	[Console]::Error.WriteLine('Net self-test: PASS')
}

Export-ModuleMember -Function @(
	# The netplan document generator — a pure function, checked against the C#
	# renderer by installer/testing/check-netplan-rule.py
	'New-NetplanDocument',
	# Reading what the kernel has, which is a different question from what the
	# configuration says and is kept separate from it on purpose (P6)
	'Get-NetLink', 'Get-NetRoute', 'Get-NetRadio',
	# Reading what is CONFIGURED — asked of netplan, because /etc/netplan is
	# several documents merged and one file is not the answer
	'Get-NetplanConfiguration',
	# Writing, applying, and asking the KERNEL whether it worked - three calls
	# and not one, because netplan apply's exit code is not evidence (P5)
	'Set-NetplanDocument', 'Remove-NetplanDocument', 'Invoke-NetplanApply',
	'Wait-NetLinkAddress',
	# Asking the RESOLVER — a third question, merged with neither of the other
	# two, and the only one here whose TOOL is not guaranteed to be installed.
	# It answers Known=$false rather than an empty list, because "no records"
	# and "cannot tell" are different facts about a domain
	'Resolve-NetSrvRecord',
	# The self-test
	'Test-NetModule')
