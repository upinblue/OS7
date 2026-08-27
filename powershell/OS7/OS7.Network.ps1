# =============================================================================
# OS/7 — the network, as an operator asks about it
#
# Layer 3 of docs/POWERSHELL-SURFACE-PLAN.md P2. THIS FILE CONTAINS NO CALL TO
# `ip`, `netplan`, `nmcli`, `networkctl` OR `resolvectl` — every one of those
# goes through powershell/Net, and installer/testing/check-layering.py holds
# that line at a baseline of 0 the same way it holds Z1 for ZFS.
#
# What is OS/7's knowledge and therefore lives here rather than one layer down:
#
#   * which renderer this machine takes (SETUP-PLAN D14), and the fact that a
#     renderer netplan merely defaulted to is not a decision anybody made
#   * that loopback is not an "adapter" to somebody asking what adapters a
#     machine has, while still being a link
#   * that a machine whose configuration and reality disagree is the case worth
#     reporting, which is why P6 forbids merging them into one field
#
# Dot-sourced by OS7.psm1. See the comment at the foot of that file for why the
# order of that list is a fact about line order rather than taste.
# =============================================================================

function Import-OS7NetLayer {
	<#
	.SYNOPSIS
		Internal. Make the Net module available, lazily.

	.DESCRIPTION
		LAZILY, AND NEVER AT IMPORT TIME — the same rule, for the same reason,
		as Import-OS7ZfsLayer above it. A live-build hook may import this module
		by path and list what it exports, but anything that CALLS a bundled
		cmdlet during import fails inside live-build's chroot (BUILD-NOTES #38,
		and #82 is that rule being broken here and costing a day of builds).
	#>
	if (Get-Module -Name Net) { return }

	$candidates = @(
		# Beside this module in the repository, which is how a developer and the
		# VM harness see it...
		(Join-Path (Split-Path -Parent $PSScriptRoot) 'Net/Net.psd1'),
		# ...and where build.sh stages it on an installed system.
		'/usr/local/share/powershell/Modules/Net/Net.psd1'
	)
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			Import-Module $c -Force -ErrorAction Stop
			Write-OS7Step "network layer: $c"
			return
		}
	}
	# By name as the last resort. It works on a booted system and not in a
	# chroot (BUILD-NOTES #14), which is the right way round for this caller.
	Import-Module Net -Force -ErrorAction Stop
	Write-OS7Step 'network layer: Net (by name)'
}

function Get-OS7NetworkAdapter {
	<#
	.SYNOPSIS
		The network adapters this machine has, and what is actually on them.

	.DESCRIPTION
		ASKS THE KERNEL. Not netplan, not NetworkManager, not a configuration
		file — `netplan apply` returns 0 for a configuration that brings nothing
		up, and every one of a wrong passphrase, an absent DHCP server and a
		cable in the wrong port looks identical to it (P5). What this reports is
		what `ip` says, which is the only thing that cannot be wrong about a
		running machine.

		LOOPBACK IS EXCLUDED BY DEFAULT, and that is a product decision rather
		than a technical one: `lo` is a link and is not an adapter to anybody
		asking what adapters a machine has. `-IncludeLoopback` brings it back,
		because a support case about a service bound to 127.0.0.1 is a real one.

		`Gateway` is the default route pointing out of that adapter, joined here
		rather than in the Net layer: a route table is a route table, and "the
		gateway of this adapter" is a convenience for a person.

	.PARAMETER Name
		One adapter. A name that does not exist is an error, not an empty list.

	.PARAMETER IncludeLoopback
		Report `lo` as well.

	.EXAMPLE
		Get-OS7NetworkAdapter

	.EXAMPLE
		Get-OS7NetworkAdapter | Where-Object { -not $_.Carrier }
		The ports with nothing plugged into them.
	#>
	[CmdletBinding()]
	param(
		[string]$Name,
		[switch]$IncludeLoopback
	)

	Import-OS7NetLayer

	$links = if ($Name) { @(Get-NetLink -Name $Name) } else { @(Get-NetLink) }
	$routes = @(Get-NetRoute)
	# ONE rfkill call for the whole answer, not one per adapter. It is the same
	# question every time and it can fail; asking it repeatedly would multiply a
	# single "cannot tell" into a per-adapter one.
	$radio = Get-NetRadio

	foreach ($l in $links) {
		if ($l.Kind -eq 'Loopback' -and -not $IncludeLoopback -and -not $Name) { continue }

		# @(...) AND THEN A COUNT CHECK, never `@(...)[0]` — BUILD-NOTES #92,
		# which this line broke on its first run: loopback has no default route,
		# so the array is empty and the index is out of bounds. An adapter with
		# no gateway is the ordinary case, not an error.
		$default = @($routes | Where-Object { $_.IsDefault -and $_.InterfaceName -eq $l.Name })
		$gateway = if ($default.Count) { $default[0].Gateway } else { $null }
		$v4 = @($l.Addresses | Where-Object Family -eq 'IPv4')
		$v6 = @($l.Addresses | Where-Object Family -eq 'IPv6')

		[pscustomobject]@{
			Name          = $l.Name
			Kind          = $l.Kind
			MacAddress    = $l.MacAddress
			OperState     = $l.OperState
			Up            = $l.Up
			Carrier       = $l.Carrier
			Mtu           = $l.Mtu
			IPv4Address   = @($v4 | ForEach-Object { "$($_.Address)/$($_.PrefixLength)" })
			IPv6Address   = @($v6 | ForEach-Object { "$($_.Address)/$($_.PrefixLength)" })
			Gateway       = $gateway
			# $null, NOT $false, when rfkill could not be asked — the same rule
			# Get-OS7Version's Drift follows: a check that did not run must never
			# read as a clean result. Only meaningful for a wireless adapter.
			RadioBlocked  = if ($l.Kind -ne 'Wireless') { $null }
			elseif (-not $radio.Known) { $null }
			else { @($radio.Devices).Count -gt 0 }
		}
	}
}

function Get-OS7NetworkConfiguration {
	<#
	.SYNOPSIS
		What this machine is CONFIGURED to do about the network, and what it is
		ACTUALLY doing — as two separate answers.

	.DESCRIPTION
		P6, AND THE TWO HALVES ARE NEVER MERGED. `Configured` comes from netplan
		— which merges every document in /etc/netplan key by key, so it is asked
		rather than read out of the file OS/7 writes — and `Effective` comes from
		the kernel. A single field would have to pick one, and the interesting
		machine is exactly the one where they disagree.

		`Agrees` is the summary of that comparison and it is deliberately
		conservative: it is `$true` only when every configured interface that
		asks for an address has one. It says nothing about WHICH address, because
		a DHCP lease is not predictable from a configuration and pretending
		otherwise would make the field lie on the commonest setup there is.

		THE RENDERER NEEDS `RendererIsDefault` READ BESIDE IT. With no
		configuration at all, netplan answers `NetworkManager` — its own
		default, measured — and on a headless OS/7 machine NetworkManager is not
		installed. `Renderer` alone would name a renderer that cannot run.

	.EXAMPLE
		Get-OS7NetworkConfiguration | Select-Object Agrees, Renderer

	.EXAMPLE
		(Get-OS7NetworkConfiguration).Disagreements
		The configured interfaces that have not got what they asked for.
	#>
	[CmdletBinding()]
	param()

	Import-OS7NetLayer

	$configured = Get-NetplanConfiguration
	$adapters = @(Get-OS7NetworkAdapter -IncludeLoopback)

	# MATCHING A CONFIGURED BLOCK TO A REAL ADAPTER IS THE WHOLE PROBLEM, and it
	# is why L28 exists. The netplan id is a LABEL when there is a match: block
	# `os7net` means "whichever port has this MAC", and no adapter is called
	# that. So the MAC is tried first, then the glob, and the id is used as a
	# name only when the document gave netplan nothing else to go on.
	$disagreements = foreach ($c in @($configured.Interfaces)) {
		$match = if ($c.MatchMac) {
			$adapters | Where-Object { $_.MacAddress -eq $c.MatchMac.ToLowerInvariant() }
		}
		elseif ($c.MatchName) {
			$adapters | Where-Object { $_.Name -like $c.MatchName }
		}
		else {
			$adapters | Where-Object Name -eq $c.Id
		}
		$match = @($match)

		$why = if ($match.Count -eq 0) {
			# The failure L28 is about: a document that matches no hardware.
			# netplan accepts it in silence, so this is the only place it is
			# ever said out loud.
			'matches no adapter on this machine'
		}
		elseif ($c.Method -eq 'None') { $null }
		elseif (@($match[0].IPv4Address).Count -eq 0 -and @($match[0].IPv6Address).Count -eq 0) {
			'is configured for an address and has none'
		}
		else { $null }

		if ($why) {
			[pscustomobject]@{
				Id      = $c.Id
				Adapter = if ($match.Count) { $match[0].Name } else { $null }
				Method  = $c.Method
				Problem = $why
			}
		}
	}
	$disagreements = @($disagreements)

	[pscustomobject]@{
		Renderer          = $configured.Renderer
		RendererIsDefault = $configured.RendererIsDefault
		Files             = @($configured.Files)
		Configured        = @($configured.Interfaces)
		Effective         = @($adapters | Where-Object Kind -ne 'Loopback')
		Disagreements     = $disagreements
		Agrees            = ($disagreements.Count -eq 0)
	}
}

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

# The document OS/7 owns. The installer writes this same path
# (installer/testing/check-image.py asserts it is written 0600), so a machine
# reconfigured from PowerShell keeps ONE OS/7 document rather than growing a
# second one that netplan would merge with the first in name order.
$script:OS7NetplanPath = '/etc/netplan/01-os7-network.yaml'

function Get-OS7NetplanRenderer {
	<#
	.SYNOPSIS
		Internal. Which renderer this machine takes (SETUP-PLAN D14).

	.DESCRIPTION
		TWO QUESTIONS IN ORDER, and the order is the decision.

		If a netplan document on this machine names a renderer, that is an
		answer somebody gave and it is kept. Overriding it would be OS/7
		deciding again about a machine an operator has already decided about.

		Only when nothing names one is it derived — from whether NetworkManager
		is installed, which is the one place "what is installed right now" is
		the correct question, because it is a question about THIS machine rather
		than about the plan. `NetworkProbe.LiveRenderer` in the installer makes
		the same call for the same reason, about the live medium.

		The alternative — deriving it from the install mode — is not available
		here: an installed machine does not record which mode it was installed
		in, and inferring one from the presence of a desktop would be the same
		question by a longer route.
	#>
	param([string]$Configured, [bool]$IsDefault)

	if ($Configured -and -not $IsDefault) { return $Configured }
	# Not an invocation of nmcli, and deliberately so: P2 forbids this file from
	# CALLING the network tools, not from knowing whether one is installed.
	if ((Test-Path -LiteralPath '/usr/sbin/NetworkManager') -or
		(Test-Path -LiteralPath '/usr/bin/nmcli')) {
		return 'NetworkManager'
	}
	return 'networkd'
}

function Set-OS7NetworkAdapter {
	<#
	.SYNOPSIS
		Configures an adapter, applies it, checks that it worked — and puts the
		old configuration back when it did not.

	.DESCRIPTION
		THE ROLLBACK IS THE POINT. `netplan apply` returns 0 for a configuration
		that brings nothing up, so a mistyped address on a headless machine is
		a machine nobody can reach and therefore nobody can fix. The sequence
		is: render, keep the old document, write the new one 0600-first, apply,
		then ASK `ip` — and if no address appears, put the old document back,
		apply again, and check THAT.

		A ROLLBACK THAT ITSELF FAILS IS SAID OUT LOUD. `RolledBack` is `$true`
		only when the old configuration was restored AND came back up.
		`RollbackFailed` is the case where the machine is now on neither
		configuration, which is the worst outcome and the one that must never
		be reported as a tidy failure.

		`-Force` skips the verification and therefore the rollback. It is not a
		formality: configuring a static address for a segment the machine will
		be moved to is an ordinary thing to do, and the verification would
		"fail" every time.

		THE ADAPTER IS MATCHED BY MAC. L28: the interface name is not stable —
		measured, `enp0s5` while installing and `enp0s2` once booted, one
		machine, one NIC — so -Name is resolved to a MAC here and the document
		matches on that.

	.PARAMETER Name
		The adapter, as `Get-OS7NetworkAdapter` lists it. Resolved to its MAC
		before anything is written.

	.PARAMETER Dhcp
		Take an address from the network.

	.PARAMETER Address
		A static address with its prefix length — `10.42.0.17/24`.

	.PARAMETER Gateway
		Optional. A segment with no route off it is a real thing.

	.PARAMETER Nameserver
		DNS servers for this link.

	.PARAMETER SearchDomain
		DNS search domains for this link.

	.PARAMETER TimeoutSeconds
		How long to wait for an address before deciding it did not work.

	.PARAMETER Force
		Apply without verifying, and therefore without the rollback.

	.EXAMPLE
		Set-OS7NetworkAdapter -Name enp1s0 -Dhcp

	.EXAMPLE
		Set-OS7NetworkAdapter -Name enp1s0 -Address 10.42.0.17/24 `
			-Gateway 10.42.0.1 -Nameserver 10.42.0.2

	.EXAMPLE
		Set-OS7NetworkAdapter -Name enp1s0 -Address 10.9.0.5/24 -Force
		A machine being prepared for a segment it is not plugged into yet.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Dhcp')]
	param(
		[Parameter(Mandatory)][string]$Name,

		[Parameter(Mandatory, ParameterSetName = 'Dhcp')]
		[switch]$Dhcp,

		[Parameter(Mandatory, ParameterSetName = 'Static')]
		[string]$Address,
		[Parameter(ParameterSetName = 'Static')]
		[string]$Gateway,

		[string[]]$Nameserver = @(),
		[string[]]$SearchDomain = @(),
		[int]$TimeoutSeconds = 30,
		[switch]$Force
	)

	Import-OS7NetLayer

	# Resolve the name to hardware BEFORE anything is written. A name that does
	# not exist must fail here, with nothing changed, rather than after a
	# document naming it is already on the disk.
	$adapter = @(Get-OS7NetworkAdapter -Name $Name)
	if ($adapter.Count -eq 0) {
		throw [System.InvalidOperationException]::new(
			"No adapter called '$Name'. Get-OS7NetworkAdapter lists what this machine has.")
	}
	$adapter = $adapter[0]
	if (-not $adapter.MacAddress) {
		throw [System.InvalidOperationException]::new(
			"'$Name' has no MAC address, so a netplan document could not match it after a reboot (L28).")
	}

	$existing = Get-NetplanConfiguration
	$renderer = Get-OS7NetplanRenderer -Configured $existing.Renderer `
		-IsDefault $existing.RendererIsDefault

	$doc = New-NetplanDocument -Renderer $renderer -Version (Get-OS7Version).Full `
		-WrittenBy 'OS/7' `
		-MacAddress $adapter.MacAddress `
		-Wireless:($adapter.Kind -eq 'Wireless') `
		-Method $(if ($PSCmdlet.ParameterSetName -eq 'Static') { 'Static' } else { 'Dhcp' }) `
		-Address $Address -Gateway $Gateway `
		-Nameserver $Nameserver -SearchDomain $SearchDomain

	if (-not $PSCmdlet.ShouldProcess($Name, "write $($script:OS7NetplanPath) and apply it")) {
		return [pscustomobject]@{
			Adapter = $Name; Applied = $false; Verified = $false
			RolledBack = $false; RollbackFailed = $false
			Renderer = $renderer; Detail = 'not applied (-WhatIf)'
			Document = $doc
		}
	}

	$saved = Set-NetplanDocument -Path $script:OS7NetplanPath -Content $doc
	$apply = Invoke-NetplanApply
	Write-OS7Step "netplan apply exited $($apply.ExitCode)"

	if ($Force) {
		# Not verified, and the object says so rather than leaving the field
		# looking like a pass. Same rule as Get-OS7Version's Drift.
		return [pscustomobject]@{
			Adapter = $Name; Applied = $true; Verified = $null
			RolledBack = $false; RollbackFailed = $false
			Renderer = $renderer
			Detail = '-Force: applied without checking, and therefore without a rollback'
			Document = $doc
		}
	}

	$link = Wait-NetLinkAddress -Name $Name -TimeoutSeconds $TimeoutSeconds
	if ($link) {
		$addrs = @($link.Addresses | ForEach-Object { "$($_.Address)/$($_.PrefixLength)" })
		return [pscustomobject]@{
			Adapter = $Name; Applied = $true; Verified = $true
			RolledBack = $false; RollbackFailed = $false
			Renderer = $renderer
			Detail = "$Name has $($addrs -join ', ')"
			Document = $doc
		}
	}

	# It did not work. Put back exactly what was there — including "nothing",
	# which is a state a document cannot express and a deletion can.
	Write-OS7Step "no address on $Name after ${TimeoutSeconds}s; rolling back"
	if ($saved.Existed) {
		Set-NetplanDocument -Path $script:OS7NetplanPath -Content $saved.Previous | Out-Null
	}
	else {
		Remove-NetplanDocument -Path $script:OS7NetplanPath
	}
	$back = Invoke-NetplanApply
	Write-OS7Step "rollback apply exited $($back.ExitCode)"
	$restored = Wait-NetLinkAddress -Name $Name -TimeoutSeconds $TimeoutSeconds

	[pscustomobject]@{
		Adapter        = $Name
		Applied        = $true
		Verified       = $false
		RolledBack     = [bool]$restored
		# THE OUTCOME THAT MUST NOT BE QUIET: the new configuration did not work
		# and the old one did not come back, so this machine is on neither.
		RollbackFailed = (-not $restored)
		Renderer       = $renderer
		Detail         = if ($restored) {
			"$Name got no address; the previous configuration was restored and is up"
		}
		else {
			"$Name got no address AND the previous configuration did not come back. " +
			'This machine may be unreachable. Check it on the console.'
		}
		Document       = $doc
	}
}

# ---------------------------------------------------------------------------
# Asking whether this machine can reach what it needs
# ---------------------------------------------------------------------------

function Get-OS7Endpoint {
	<#
	.SYNOPSIS
		The named services OS/7 knows how to test for, out of the data file
		beside this module.

	.DESCRIPTION
		DATA, NOT LITERALS. Microsoft's endpoints depend on the cloud a tenant
		is in — Azure Government and 21Vianet use different hostnames — so a
		hostname compiled into a cmdlet is wrong for those customers and wrong
		in the way that reports THEIR network as broken.

		The file also carries `verified: null`, which this cmdlet passes
		through: nothing in it has been checked against Microsoft's live
		documentation, and CLAUDE.md's rule is that identity-adjacent facts get
		checked there first. Saying so is the difference between a gap and a
		claim.

	.PARAMETER Cloud
		`public` (the default in the file), `usgov` or `china`.

	.EXAMPLE
		Get-OS7Endpoint | Format-Table Name, Host, Port
	#>
	[CmdletBinding()]
	param([string]$Cloud, [string]$Name)

	$path = [System.IO.Path]::Combine($PSScriptRoot, 'os7-endpoints.json')
	if (-not [System.IO.File]::Exists($path)) {
		throw [System.IO.FileNotFoundException]::new(
			"os7-endpoints.json is missing from $PSScriptRoot. The OS7 module is staged by " +
			'copying the whole directory (build.sh stage_ps_module); a partial copy is what ' +
			'this looks like.')
	}
	$data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json

	if (-not $Cloud) { $Cloud = $data.defaultCloud }
	if (-not $data.clouds.PSObject.Properties.Name.Contains($Cloud)) {
		throw [System.ArgumentException]::new(
			"No cloud '$Cloud' in os7-endpoints.json. It has: " +
			($data.clouds.PSObject.Properties.Name -join ', '))
	}

	$set = $data.clouds.$Cloud
	foreach ($service in $set.PSObject.Properties.Name) {
		if ($Name -and $service -ne $Name) { continue }
		foreach ($e in @($set.$service)) {
			[pscustomobject]@{
				Name     = $service
				Cloud    = $Cloud
				Host     = $e.host
				Port     = [int]$e.port
				Why      = $e.why
				# Passed through, never defaulted to $true. A check that has not
				# been made must not read as one that passed.
				Verified = $data.verified
			}
		}
	}
}

function Test-OS7Network {
	<#
	.SYNOPSIS
		Whether this machine can actually reach the network, its resolver and
		the services OS/7 exists to reach.

	.DESCRIPTION
		FOUR SEPARATE ANSWERS, because they fail separately and an operator
		needs to know which: a link with no carrier, an address but no gateway,
		a gateway but no DNS, and DNS but no route to the service are four
		different site visits.

		TCP, NOT ICMP. The service test opens a connection to the port the
		service is actually on. An enterprise network that blocks ping and
		permits HTTPS is ordinary, and testing with ICMP would report the
		commonest configuration there is as broken. It is also the honest test:
		"can this machine reach Entra" is a question about port 443, not about
		echo replies.

		Nothing here writes anything, so it is safe on a machine somebody is
		relying on.

	.PARAMETER Endpoint
		Named services from `Get-OS7Endpoint` — `Entra`, `Intune`, `Arc`,
		`Graph` — or a bare `host:port`. Omit for all of the named ones.

	.PARAMETER Cloud
		Which cloud's endpoints to use. Defaults to the file's own default.

	.PARAMETER TimeoutSeconds
		Per connection.

	.EXAMPLE
		Test-OS7Network

	.EXAMPLE
		Test-OS7Network -Endpoint Entra -Cloud usgov
	#>
	[CmdletBinding()]
	param(
		[string[]]$Endpoint,
		[string]$Cloud,
		[int]$TimeoutSeconds = 5
	)

	Import-OS7NetLayer

	$adapters = @(Get-OS7NetworkAdapter)
	$routes = @(Get-NetRoute | Where-Object IsDefault)

	# --- the resolver ------------------------------------------------------
	# .NET, not `resolvectl`: the question is what THIS PROCESS resolves, which
	# is what every other program on the machine will get too, and it needs no
	# daemon to be running to be answered.
	$dnsProbe = if ($Endpoint -and $Endpoint[0] -match '^[^:]+:\d+$') { $Endpoint[0].Split(':')[0] }
	else { @(Get-OS7Endpoint -Cloud $Cloud)[0].Host }
	$dnsOk = $false
	$dnsDetail = ''
	try {
		$sw = [System.Diagnostics.Stopwatch]::StartNew()
		$addrs = [System.Net.Dns]::GetHostAddresses($dnsProbe)
		$sw.Stop()
		$dnsOk = ($addrs.Count -gt 0)
		$dnsDetail = "$dnsProbe -> $(($addrs | ForEach-Object { $_.IPAddressToString }) -join ', ') in $($sw.ElapsedMilliseconds) ms"
	}
	catch {
		$dnsDetail = "$dnsProbe did not resolve: $($_.Exception.Message)"
	}

	# --- the services ------------------------------------------------------
	$targets = if (-not $Endpoint) { @(Get-OS7Endpoint -Cloud $Cloud) }
	else {
		foreach ($e in $Endpoint) {
			if ($e -match '^(?<h>[^:]+):(?<p>\d+)$') {
				[pscustomobject]@{
					Name = $Matches.h; Cloud = $null; Host = $Matches.h
					Port = [int]$Matches.p; Why = 'given on the command line'; Verified = $null
				}
			}
			else { Get-OS7Endpoint -Cloud $Cloud -Name $e }
		}
	}
	$targets = @($targets)

	$results = foreach ($t in $targets) {
		$ok = $false
		$detail = ''
		$sw = [System.Diagnostics.Stopwatch]::StartNew()
		try {
			$client = [System.Net.Sockets.TcpClient]::new()
			$task = $client.ConnectAsync($t.Host, $t.Port)
			if ($task.Wait([timespan]::FromSeconds($TimeoutSeconds))) {
				$ok = $client.Connected
				$detail = if ($ok) { "connected in $($sw.ElapsedMilliseconds) ms" }
				else { 'the connection was refused' }
			}
			else {
				$detail = "no answer in ${TimeoutSeconds}s"
			}
		}
		catch {
			# The inner exception is the useful one — "Name or service not
			# known" against "Connection refused" are different site visits.
			$detail = ($_.Exception.InnerException ?? $_.Exception).Message
		}
		finally {
			$sw.Stop()
			if ($client) { $client.Dispose() }
		}
		[pscustomobject]@{
			Name = $t.Name; Host = $t.Host; Port = $t.Port
			Reachable = $ok; Detail = $detail; Verified = $t.Verified
		}
	}
	$results = @($results)

	$carrying = @($adapters | Where-Object { $_.Carrier -and @($_.IPv4Address).Count -gt 0 })

	[pscustomobject]@{
		Adapters      = $adapters
		# Four separate answers. Merging them would hide which of four site
		# visits this is.
		HasLink       = ($carrying.Count -gt 0)
		HasGateway    = ($routes.Count -gt 0)
		DnsWorks      = $dnsOk
		DnsDetail     = $dnsDetail
		Endpoints     = $results
		# $null, not $true, when the endpoint list itself has never been checked
		# against Microsoft's documentation — the file says so and this passes it
		# through rather than swallowing it.
		EndpointsVerified = @($targets | ForEach-Object { $_.Verified } | Select-Object -First 1)
		Ok            = (($carrying.Count -gt 0) -and $dnsOk -and
			(@($results | Where-Object { -not $_.Reachable }).Count -eq 0))
	}
}
