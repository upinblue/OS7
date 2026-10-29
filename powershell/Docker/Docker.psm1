# =============================================================================
# Docker — the container engine, from PowerShell, over its own API
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like powershell/Zfs and
# powershell/Hardware. It knows the Docker Engine API and nothing about OS/7:
# which container "needs attention", which store is backed up and who may hold
# the socket are product decisions and live one layer up
# (docs/CONTAINERS-PLAN.md CT3, CT5, CT6).
#
# IT SPEAKS HTTP TO THE SOCKET AND NEVER RUNS `docker`. Measured 2026-10-29
# (CONTAINERS-PLAN M-CT4): `docker start` on a running container and `docker
# stop` on a stopped one both exit 0, while the API answers 304 for each. The
# repository's most expensive bug shape is a program reporting success for a
# change that did not happen; wrapping the CLI would choose it on purpose. The
# pinned pwsh has `Invoke-WebRequest -UnixSocket` (M-CT3), so this needs no
# client binary and no Add-Type.
#
# ONE FUNCTION TALKS TO THE ENGINE: Invoke-DockerApi. It is the seam the
# self-test replays recorded responses through, the place a recording is made
# (OS7_DOCKER_RECORD), and the thing P2-docker in check-layering.py keeps
# powershell/OS7 away from. It is deliberately NOT exported: P2-hardware found
# Layer 3 routing THROUGH an exported invoker and still deciding, itself, what
# to run.
#
# THE API VERSION IS NEGOTIATED, NEVER WRITTEN INTO A PATH BY HAND. The
# engine's minimum moved from 1.40 to 1.44 between two 29.x builds (M-CT5), so
# a hard-coded version is a refusal waiting for an engine update. The module
# carries the range it has RECORDED RESPONSES for, asks /version once per
# socket, and uses the lower of the engine's version and the newest it has
# tested. Test-DockerModule holds that range equal to the fixtures shipped
# beside it, so a new engine's recording and the constant move together or
# the test goes red. That is CONTAINERS-PLAN §3's whole answer to "easy to
# keep up to date", in one place.
#
# STRICT MODE AND AN API THAT GROWS. Under Set-StrictMode 3 reading a property
# the engine did not send throws, and engines add and drop fields between
# versions. Every read of an engine field goes through Get-DockerField, which
# answers $null for an absent one — the #112/#119 shape, avoided by
# construction rather than by care.
# =============================================================================

Set-StrictMode -Version 3.0

# The range this module has recorded responses for. Test-DockerModule fails if
# these disagree with the fixtures in tests/fixtures/.
$script:DockerApiOldest = [version]'1.52'
$script:DockerApiNewest = [version]'1.55'

# Docker's own default, spelled the way Docker's documentation spells it. On
# Ubuntu /var/run is a symlink to /run, so this is /run/docker.sock.
$script:DockerDefaultSocket = '/var/run/docker.sock'

# The self-test's seam: a scriptblock taking (method, target, json) and
# returning what Send-DockerRequest returns.
$script:DockerTransportOverride = $null

# Negotiated API version per socket path. One /version per session, not one
# per request.
$script:DockerNegotiated = @{}

# Container, volume and network names as the engine accepts them. Checked
# here so that a name reaches a URL only after it has been shown to be one.
$script:DockerNamePattern = '^[A-Za-z0-9][A-Za-z0-9_.-]*$'

# =============================================================================
# The transport
# =============================================================================

function Get-DockerSocketPath {
	<#
	.SYNOPSIS
		Internal. The engine's socket: DOCKER_HOST when it names a unix
		socket, Docker's default otherwise.

	.DESCRIPTION
		DOCKER_HOST is honoured because it is Docker's own convention and an
		operator who set it meant it. Anything but `unix://` is REFUSED by name
		rather than ignored: a tcp:// engine is a remote engine with its own
		TLS and its own trust, and silently talking to the local socket instead
		would answer a different machine's question.
	#>
	param()

	$hostVar = [System.Environment]::GetEnvironmentVariable('DOCKER_HOST')
	if ([string]::IsNullOrWhiteSpace($hostVar)) { return $script:DockerDefaultSocket }
	if ($hostVar.StartsWith('unix://')) { return $hostVar.Substring(7) }
	throw [System.NotSupportedException]::new(
		"DOCKER_HOST is '$hostVar'. This module speaks to a local engine over its unix socket " +
		'only; a tcp:// or ssh:// engine is another machine with its own trust, and is not ' +
		'reached by pretending it is this one. Unset DOCKER_HOST or point it at unix:///path.')
}

function ConvertTo-DockerQueryString {
	<#
	.SYNOPSIS
		Internal. A hashtable as a query string, every value escaped.
	#>
	param([System.Collections.IDictionary]$Table)

	if (-not $Table -or $Table.Count -eq 0) { return '' }
	$parts = foreach ($k in ($Table.Keys | Sort-Object)) {
		'{0}={1}' -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Table[$k])
	}
	return '?' + ($parts -join '&')
}

function ConvertTo-DockerTransportError {
	<#
	.SYNOPSIS
		Internal. Why the socket did not answer, as a sentence an operator can
		act on.

	.DESCRIPTION
		THREE DIFFERENT FAILURES look the same from Invoke-WebRequest — an
		HttpRequestException with a socket error inside — and they send an
		operator three different places:

		  no socket at all      the engine is not installed or not started
		  permission denied     the socket is root:docker 0660 ON PURPOSE:
		                        holding it is root-equivalent, and it shows
		                        every container's environment (M-CT6)
		  anything else         the engine is there and did not answer

		Separate from Send-DockerRequest so the self-test can hand it
		constructed exceptions; a socket permission cannot be faked any other
		way without root.
	#>
	param(
		[Parameter(Mandatory)][System.Exception]$Exception,
		[Parameter(Mandatory)][string]$Socket,
		[bool]$SocketExists = $true
	)

	if (-not $SocketExists) {
		return [System.IO.FileNotFoundException]::new(
			"There is no Docker engine socket at $Socket. The engine is not installed, or " +
			'docker.socket is not enabled.')
	}

	$e = $Exception
	while ($e) {
		if ($e -is [System.Net.Sockets.SocketException] -and
			$e.SocketErrorCode -eq [System.Net.Sockets.SocketError]::AccessDenied) {
			return [System.UnauthorizedAccessException]::new(
				"$Socket refused '$([System.Environment]::UserName)'. The socket is root:docker " +
				'0660 on purpose: holding it is equivalent to root and shows every ' +
				"container's environment, passwords included. Run this as root.")
		}
		$e = $e.InnerException
	}
	return [System.InvalidOperationException]::new(
		"The Docker engine at $Socket did not answer: $($Exception.Message)", $Exception)
}

function Send-DockerRequest {
	<#
	.SYNOPSIS
		Internal. One HTTP request over the unix socket. Returns the status,
		the content type and the body, and never judges the status.
	#>
	param(
		[Parameter(Mandatory)][string]$Socket,
		[Parameter(Mandatory)][string]$Method,
		[Parameter(Mandatory)][string]$Target,
		[AllowNull()][string]$Json
	)

	$ProgressPreference = 'SilentlyContinue'
	$req = @{
		UnixSocket         = $Socket
		Uri                = "http://localhost$Target"
		Method             = $Method
		SkipHttpErrorCheck = $true
		ErrorAction        = 'Stop'
	}
	if ($null -ne $Json -and $Json -ne '') {
		$req.Body = $Json
		$req.ContentType = 'application/json'
	}

	try {
		$resp = Invoke-WebRequest @req
	}
	catch {
		throw (ConvertTo-DockerTransportError -Exception $_.Exception -Socket $Socket `
				-SocketExists (Test-Path -LiteralPath $Socket))
	}

	$ct = ''
	if ($resp.Headers.ContainsKey('Content-Type')) { $ct = (@($resp.Headers['Content-Type']) -join ';') }

	# Invoke-WebRequest decides by content type whether Content is a string or
	# a byte[]. JSON arrives as a string; a log stream and an empty 204 arrive
	# as bytes. Both are kept, because a multiplexed log stream decoded as text
	# loses the frame headers that say which line was stderr.
	$text = $null; $bytes = $null
	if ($resp.Content -is [string]) { $text = $resp.Content }
	elseif ($null -ne $resp.Content) { $bytes = [byte[]]$resp.Content }

	return [pscustomobject]@{
		StatusCode  = [int]$resp.StatusCode
		ContentType = $ct
		Text        = $text
		Bytes       = $bytes
	}
}

function Save-DockerExchange {
	<#
	.SYNOPSIS
		Internal. Appends one request and its response to the recording named
		by OS7_DOCKER_RECORD — one JSON object per line.

	.DESCRIPTION
		The path is recorded WITHOUT its /vX.Y prefix, because the replay must
		work whichever version the module negotiates against that fixture. The
		version that was used is recorded beside it.
	#>
	param(
		[Parameter(Mandatory)][string]$File,
		[Parameter(Mandatory)][string]$Method,
		[Parameter(Mandatory)][string]$Target,
		[AllowNull()][string]$Json,
		[Parameter(Mandatory)]$Response
	)

	$api = $null
	$bare = $Target
	if ($Target -match '^/v(\d+\.\d+)(/.*)$') { $api = $Matches[1]; $bare = $Matches[2] }
	$line = [ordered]@{
		method      = $Method
		path        = $bare
		api         = $api
		request     = $Json
		status      = $Response.StatusCode
		contentType = $Response.ContentType
		text        = $Response.Text
		base64      = if ($null -ne $Response.Bytes -and $Response.Bytes.Length -gt 0) {
			[Convert]::ToBase64String($Response.Bytes) } else { $null }
	}
	Add-Content -LiteralPath $File -Encoding utf8NoBOM -Value ($line | ConvertTo-Json -Compress -Depth 5)
}

function Invoke-DockerApi {
	<#
	.SYNOPSIS
		Internal. One request to the engine, at the negotiated API version.
		Returns what the engine said and does not judge it.

	.DESCRIPTION
		THE ONLY FUNCTION IN THIS MODULE THAT REACHES THE ENGINE. Every cmdlet
		goes through it, so the self-test exercises the cmdlets whole and a
		recording captures exactly the requests the cmdlets make.

	.PARAMETER Path
		The endpoint without a version prefix: '/containers/json'.

	.PARAMETER Unversioned
		Send the path as it is. Only /version is asked this way, because it is
		how the version is found.

	.PARAMETER ApiVersion
		Override the negotiated version for this one request.
	#>
	param(
		[Parameter(Mandatory)][ValidateSet('GET', 'POST', 'DELETE')][string]$Method,
		[Parameter(Mandatory)][string]$Path,
		[System.Collections.IDictionary]$Query,
		$Body,
		[switch]$Unversioned,
		[version]$ApiVersion
	)

	$socket = Get-DockerSocketPath
	$prefix = ''
	if (-not $Unversioned) {
		$v = if ($ApiVersion) { $ApiVersion } else { Get-DockerNegotiatedVersion -Socket $socket }
		$prefix = "/v$($v.Major).$($v.Minor)"
	}
	$target = $prefix + $Path + (ConvertTo-DockerQueryString -Table $Query)
	$json = if ($null -ne $Body) { $Body | ConvertTo-Json -Compress -Depth 20 } else { $null }

	$r = if ($script:DockerTransportOverride) {
		& $script:DockerTransportOverride $Method $target $json
	}
	else {
		Send-DockerRequest -Socket $socket -Method $Method -Target $target -Json $json
	}

	$rec = [System.Environment]::GetEnvironmentVariable('OS7_DOCKER_RECORD')
	if (-not [string]::IsNullOrWhiteSpace($rec)) {
		Save-DockerExchange -File $rec -Method $Method -Target $target -Json $json -Response $r
	}
	return $r
}

# =============================================================================
# Reading what came back
# =============================================================================

function Get-DockerField {
	<#
	.SYNOPSIS
		Internal. A dotted path into an engine object; $null where the engine
		did not send the field.
	#>
	param($Object, [Parameter(Mandatory)][string]$Field)

	$o = $Object
	foreach ($part in $Field.Split('.')) {
		if ($null -eq $o) { return $null }
		if ($o -is [System.Collections.IDictionary]) { $o = $o[$part]; continue }
		$prop = $o.PSObject.Properties[$part]
		if (-not $prop) { return $null }
		$o = $prop.Value
	}
	return $o
}

function Read-DockerJson {
	<#
	.SYNOPSIS
		Internal. The body as objects, or $null for an empty one.
	#>
	param([Parameter(Mandatory)]$Response)

	$t = $Response.Text
	if ([string]::IsNullOrWhiteSpace($t) -and $null -ne $Response.Bytes -and $Response.Bytes.Length -gt 0) {
		$t = [System.Text.Encoding]::UTF8.GetString($Response.Bytes)
	}
	if ([string]::IsNullOrWhiteSpace($t)) { return $null }
	return ($t | ConvertFrom-Json -Depth 64 -NoEnumerate)
}

function Assert-DockerStatus {
	<#
	.SYNOPSIS
		Internal. Throws, in the engine's own words, unless the status is one
		the caller expected.

	.DESCRIPTION
		404 is ItemNotFoundException so a caller can ask "does it exist" with a
		catch of one type. Everything else carries the engine's message, which
		is usually the most precise sentence available ("cannot remove
		container: container is running: stop the container before removing or
		force remove").
	#>
	param(
		[Parameter(Mandatory)]$Response,
		[Parameter(Mandatory)][int[]]$Expected,
		[Parameter(Mandatory)][string]$What
	)

	if ($Expected -contains $Response.StatusCode) { return }

	$msg = $null
	try { $msg = Get-DockerField (Read-DockerJson -Response $Response) 'message' } catch { $msg = $null }
	if (-not $msg) { $msg = "$($Response.Text)".Trim() }
	$sentence = "Could not $What — the engine answered $($Response.StatusCode)" +
		$(if ($msg) { ": $msg" } else { '.' })

	switch ($Response.StatusCode) {
		404 { throw [System.Management.Automation.ItemNotFoundException]::new($sentence) }
		400 { throw [System.ArgumentException]::new($sentence) }
		default { throw [System.InvalidOperationException]::new($sentence) }
	}
}

function ConvertTo-DockerApiVersion {
	<#
	.SYNOPSIS
		Internal. '1.52' as a [version], or $null.
	#>
	param([AllowNull()][string]$Text)

	$v = $null
	if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
	if ([version]::TryParse($Text, [ref]$v)) { return $v }
	return $null
}

function Resolve-DockerApiVersion {
	<#
	.SYNOPSIS
		Internal. The API version to speak to an engine, or a refusal that
		names both ranges.

	.DESCRIPTION
		The lower of the engine's version and the newest this module has
		recorded responses for — and a refusal on either side of the range,
		because a request at a version the module has never seen answered is a
		parse of a shape nobody checked.
	#>
	param(
		[AllowNull()][string]$EngineApi,
		[AllowNull()][string]$EngineMinimum
	)

	$engine = ConvertTo-DockerApiVersion -Text $EngineApi
	if ($null -eq $engine) {
		throw [System.InvalidOperationException]::new(
			"The engine did not say which API version it speaks (ApiVersion '$EngineApi').")
	}
	$floor = ConvertTo-DockerApiVersion -Text $EngineMinimum
	if ($null -eq $floor) { $floor = $engine }

	if ($engine -lt $script:DockerApiOldest) {
		throw [System.NotSupportedException]::new(
			"The engine speaks API $engine. This module has recorded responses for API " +
			"$($script:DockerApiOldest) to $($script:DockerApiNewest) and nothing older, so it " +
			'will not guess at the shape of an older answer.')
	}
	$chosen = if ($engine -lt $script:DockerApiNewest) { $engine } else { $script:DockerApiNewest }
	if ($floor -gt $chosen) {
		throw [System.NotSupportedException]::new(
			"The engine accepts API $floor and newer; the newest this module has recorded " +
			"responses for is $($script:DockerApiNewest). Record this engine " +
			'(installer/testing/capture-docker-fixtures.py) and widen the range in Docker.psm1.')
	}
	return $chosen
}

function Get-DockerNegotiatedVersion {
	<#
	.SYNOPSIS
		Internal. Asks /version once per socket and remembers the answer.
	#>
	param([Parameter(Mandatory)][string]$Socket)

	if ($script:DockerNegotiated.ContainsKey($Socket)) { return $script:DockerNegotiated[$Socket] }
	$r = Invoke-DockerApi -Method GET -Path '/version' -Unversioned
	Assert-DockerStatus -Response $r -Expected 200 -What 'ask the engine its version'
	$v = Read-DockerJson -Response $r
	$chosen = Resolve-DockerApiVersion -EngineApi (Get-DockerField $v 'ApiVersion') `
		-EngineMinimum (Get-DockerField $v 'MinAPIVersion')
	$script:DockerNegotiated[$Socket] = $chosen
	return $chosen
}

function ConvertTo-DockerFilter {
	<#
	.SYNOPSIS
		Internal. A filter hashtable as the engine's JSON map of ARRAYS.

	.DESCRIPTION
		The engine takes {"name":["web"]}. @{ name = 'web' } is what a person
		types, and serialised as it stands it is {"name":"web"}, which the
		engine refuses with a 400. Every value is made an array here, once.
	#>
	param([System.Collections.IDictionary]$Table)

	if (-not $Table -or $Table.Count -eq 0) { return $null }
	$f = [ordered]@{}
	foreach ($k in ($Table.Keys | Sort-Object)) { $f[[string]$k] = @($Table[$k] | ForEach-Object { [string]$_ }) }
	return ($f | ConvertTo-Json -Compress -Depth 5)
}

function Get-DockerResource {
	<#
	.SYNOPSIS
		Internal. GET a list endpoint and return its items, tagged.
	#>
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][string]$What,
		[Parameter(Mandatory)][string]$TypeName,
		[System.Collections.IDictionary]$Query,
		[string]$Member
	)

	$r = Invoke-DockerApi -Method GET -Path $Path -Query $Query
	Assert-DockerStatus -Response $r -Expected 200 -What $What
	$body = Read-DockerJson -Response $r
	$items = if ($Member) { Get-DockerField $body $Member } else { $body }
	foreach ($i in @($items)) {
		if ($null -eq $i) { continue }
		$i.PSObject.TypeNames.Insert(0, $TypeName)
		$i
	}
}

# =============================================================================
# The engine
# =============================================================================

function Get-DockerEngine {
	<#
	.SYNOPSIS
		Which engine answers on the socket, which API version was negotiated
		with it, and which storage it actually chose.

	.DESCRIPTION
		`Driver` and `DriverType` are read from /info rather than assumed. On
		Docker 29 with the containerd image store the driver is `overlayfs` of
		type io.containerd.snapshotter.v1, and its images live under
		containerd's root, not Docker's — which decides where a product has to
		put a dataset (CONTAINERS-PLAN M-CT8). `BackingFilesystem` is only sent
		by the legacy graph drivers.

	.EXAMPLE
		Get-DockerEngine | Format-List Version, ApiVersion, NegotiatedApiVersion, Driver
	#>
	[CmdletBinding()]
	param()

	$socket = Get-DockerSocketPath
	$vr = Invoke-DockerApi -Method GET -Path '/version' -Unversioned
	Assert-DockerStatus -Response $vr -Expected 200 -What 'ask the engine its version'
	$v = Read-DockerJson -Response $vr
	$negotiated = Get-DockerNegotiatedVersion -Socket $socket

	$ir = Invoke-DockerApi -Method GET -Path '/info'
	Assert-DockerStatus -Response $ir -Expected 200 -What 'ask the engine about itself'
	$i = Read-DockerJson -Response $ir

	# DriverStatus is a list of [key, value] pairs, not an object.
	$pairs = @{}
	foreach ($pair in @(Get-DockerField $i 'DriverStatus')) {
		$kv = @($pair)
		if ($kv.Count -ge 2) { $pairs[[string]$kv[0]] = [string]$kv[1] }
	}

	[pscustomobject]@{
		PSTypeName           = 'Docker.Engine'
		Socket               = $socket
		Version              = Get-DockerField $v 'Version'
		ApiVersion           = Get-DockerField $v 'ApiVersion'
		MinApiVersion        = Get-DockerField $v 'MinAPIVersion'
		NegotiatedApiVersion = "$($negotiated.Major).$($negotiated.Minor)"
		Os                   = Get-DockerField $v 'Os'
		Arch                 = Get-DockerField $v 'Arch'
		KernelVersion        = Get-DockerField $v 'KernelVersion'
		Driver               = Get-DockerField $i 'Driver'
		DriverType           = $pairs['driver-type']
		BackingFilesystem    = $pairs['Backing Filesystem']
		DockerRootDir        = Get-DockerField $i 'DockerRootDir'
		CgroupVersion        = Get-DockerField $i 'CgroupVersion'
		Containers           = Get-DockerField $i 'Containers'
		ContainersRunning    = Get-DockerField $i 'ContainersRunning'
		Images               = Get-DockerField $i 'Images'
	}
}

# =============================================================================
# Containers
# =============================================================================

function Add-DockerContainerName {
	<#
	.SYNOPSIS
		Internal. `Name` without the engine's leading slash, on both shapes.

	.DESCRIPTION
		A list item carries `Names` (an array, "/web"); an inspected container
		carries `Name` ("/web"). The slash is an artefact of the engine's
		storage, and a pipeline that binds -Name by property name needs one
		spelling on both.
	#>
	param([Parameter(Mandatory)]$Container)

	$n = Get-DockerField $Container 'Name'
	if (-not $n) { $n = @(Get-DockerField $Container 'Names') | Select-Object -First 1 }
	$Container | Add-Member -NotePropertyName Name -NotePropertyValue ("$n".TrimStart('/')) -Force
	return $Container
}

function Get-DockerContainer {
	<#
	.SYNOPSIS
		Containers, as the engine describes them: a list, or one inspected in
		full.

	.DESCRIPTION
		Without -Name, the engine's list (running ones only, unless -All). With
		-Name, each container inspected — the full object, including its
		environment, which is why reading it needs the socket and the socket
		is root's (CONTAINERS-PLAN M-CT6).

		A name that does not exist throws ItemNotFoundException.

	.PARAMETER Filter
		The engine's own filters, as a hashtable: @{ name = 'web' },
		@{ label = 'com.docker.compose.project=shop' }, @{ status = 'exited' }.
		Each value may be one string or several.

	.EXAMPLE
		Get-DockerContainer -All | Select-Object Name, State, Status

	.EXAMPLE
		(Get-DockerContainer -Name web).State
	#>
	[CmdletBinding(DefaultParameterSetName = 'List')]
	param(
		[Parameter(ParameterSetName = 'Inspect', Mandatory, Position = 0,
			ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string[]]$Name,
		[Parameter(ParameterSetName = 'List')][switch]$All,
		[Parameter(ParameterSetName = 'List')][System.Collections.IDictionary]$Filter
	)

	process {
		if ($PSCmdlet.ParameterSetName -eq 'Inspect') {
			foreach ($n in $Name) {
				$r = Invoke-DockerApi -Method GET -Path "/containers/$([uri]::EscapeDataString($n))/json"
				Assert-DockerStatus -Response $r -Expected 200 -What "inspect container '$n'"
				$c = Add-DockerContainerName -Container (Read-DockerJson -Response $r)
				$c.PSObject.TypeNames.Insert(0, 'Docker.Container')
				$c
			}
			return
		}

		$q = @{ all = $(if ($All) { '1' } else { '0' }) }
		$f = ConvertTo-DockerFilter -Table $Filter
		if ($f) { $q.filters = $f }
		foreach ($c in @(Get-DockerResource -Path '/containers/json' -Query $q `
					-What 'list containers' -TypeName 'Docker.ContainerSummary')) {
			Add-DockerContainerName -Container $c
		}
	}
}

function Get-DockerContainerState {
	<#
	.SYNOPSIS
		Internal. The container's State asked again, or $null when it is gone.
	#>
	param([Parameter(Mandatory)][string]$Container)

	$r = Invoke-DockerApi -Method GET -Path "/containers/$([uri]::EscapeDataString($Container))/json"
	if ($r.StatusCode -eq 404) { return $null }
	Assert-DockerStatus -Response $r -Expected 200 -What "read container '$Container' back"
	return Get-DockerField (Read-DockerJson -Response $r) 'State'
}

function New-DockerActionResult {
	<#
	.SYNOPSIS
		Internal. What a lifecycle verb did, with the state READ BACK.
	#>
	param(
		[Parameter(Mandatory)][string]$Container,
		[Parameter(Mandatory)][string]$Action,
		[Parameter(Mandatory)][string]$Outcome,
		[Parameter(Mandatory)][int]$StatusCode,
		$State
	)

	[pscustomobject]@{
		PSTypeName = 'Docker.ContainerAction'
		Name       = $Container
		Action     = $Action
		Outcome    = $Outcome
		StatusCode = $StatusCode
		Status     = Get-DockerField $State 'Status'
		Running    = Get-DockerField $State 'Running'
		ExitCode   = Get-DockerField $State 'ExitCode'
	}
}

function Start-DockerContainer {
	<#
	.SYNOPSIS
		Starts a container, and says whether it was ALREADY running.

	.DESCRIPTION
		Outcome is read off the engine's status AND the container asked back
		immediately afterwards:

		  Started          204, and the container is running
		  AlreadyRunning   304 — the engine did nothing. `docker start` exits
		                   0 here (M-CT4); this does not hide it
		  Exited           204, and the container is NOT running when asked
		                   back: its process ended at once. ExitCode says how

		Read back once, immediately. A container that dies a second later is
		not caught here, and that is a question for the product layer's view
		of restart loops, not for a verb.

	.EXAMPLE
		Start-DockerContainer web | Format-List Outcome, Running
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string[]]$Name
	)

	process {
		foreach ($n in $Name) {
			if (-not $PSCmdlet.ShouldProcess($n, 'start container')) { continue }
			$r = Invoke-DockerApi -Method POST -Path "/containers/$([uri]::EscapeDataString($n))/start"
			Assert-DockerStatus -Response $r -Expected 204, 304 -What "start container '$n'"
			$s = Get-DockerContainerState -Container $n
			$outcome = if ($r.StatusCode -eq 304) { 'AlreadyRunning' }
			elseif (Get-DockerField $s 'Running') { 'Started' }
			else { 'Exited' }
			New-DockerActionResult -Container $n -Action 'Start' -Outcome $outcome `
				-StatusCode $r.StatusCode -State $s
		}
	}
}

function Stop-DockerContainer {
	<#
	.SYNOPSIS
		Stops a container, and says whether it was ALREADY stopped.

	.DESCRIPTION
		  Stopped          204, and the container is not running when asked back
		  AlreadyStopped   304 — the engine did nothing (M-CT4)
		  StillRunning     204, and the container IS running when asked back.
		                   Not expected — the engine waits for the stop — and
		                   reported rather than assumed away

	.PARAMETER TimeoutSeconds
		How long the engine waits after SIGTERM before it kills. Docker's own
		default (10) when not given.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string[]]$Name,
		[ValidateRange(0, 3600)][int]$TimeoutSeconds = -1
	)

	process {
		foreach ($n in $Name) {
			if (-not $PSCmdlet.ShouldProcess($n, 'stop container')) { continue }
			$q = @{}
			if ($TimeoutSeconds -ge 0) { $q.t = "$TimeoutSeconds" }
			$r = Invoke-DockerApi -Method POST -Path "/containers/$([uri]::EscapeDataString($n))/stop" -Query $q
			Assert-DockerStatus -Response $r -Expected 204, 304 -What "stop container '$n'"
			$s = Get-DockerContainerState -Container $n
			$outcome = if ($r.StatusCode -eq 304) { 'AlreadyStopped' }
			elseif (Get-DockerField $s 'Running') { 'StillRunning' }
			else { 'Stopped' }
			New-DockerActionResult -Container $n -Action 'Stop' -Outcome $outcome `
				-StatusCode $r.StatusCode -State $s
		}
	}
}

function Restart-DockerContainer {
	<#
	.SYNOPSIS
		Restarts a container, and says whether it is running afterwards.

	.DESCRIPTION
		  Restarted   204, and the container is running when asked back
		  Exited      204, and it is not: it came up and its process ended
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string[]]$Name,
		[ValidateRange(0, 3600)][int]$TimeoutSeconds = -1
	)

	process {
		foreach ($n in $Name) {
			if (-not $PSCmdlet.ShouldProcess($n, 'restart container')) { continue }
			$q = @{}
			if ($TimeoutSeconds -ge 0) { $q.t = "$TimeoutSeconds" }
			$r = Invoke-DockerApi -Method POST -Path "/containers/$([uri]::EscapeDataString($n))/restart" -Query $q
			Assert-DockerStatus -Response $r -Expected 204 -What "restart container '$n'"
			$s = Get-DockerContainerState -Container $n
			$outcome = if (Get-DockerField $s 'Running') { 'Restarted' } else { 'Exited' }
			New-DockerActionResult -Container $n -Action 'Restart' -Outcome $outcome `
				-StatusCode $r.StatusCode -State $s
		}
	}
}

function Remove-DockerContainer {
	<#
	.SYNOPSIS
		Removes a container, and asks the engine afterwards whether it is gone.

	.DESCRIPTION
		A running container is refused by the engine unless -Force, and the
		refusal comes back in the engine's words. -RemoveVolumes also removes
		the container's ANONYMOUS volumes; named volumes are never removed
		here.

		The container is asked for again afterwards and must answer 404. A
		remove the engine accepted and did not perform throws.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string[]]$Name,
		[switch]$Force,
		[switch]$RemoveVolumes
	)

	process {
		foreach ($n in $Name) {
			if (-not $PSCmdlet.ShouldProcess($n, 'remove container')) { continue }
			$q = @{
				force = $(if ($Force) { '1' } else { '0' })
				v     = $(if ($RemoveVolumes) { '1' } else { '0' })
			}
			$r = Invoke-DockerApi -Method DELETE -Path "/containers/$([uri]::EscapeDataString($n))" -Query $q
			Assert-DockerStatus -Response $r -Expected 204 -What "remove container '$n'"
			$s = Get-DockerContainerState -Container $n
			if ($null -ne $s) {
				throw [System.InvalidOperationException]::new(
					"The engine answered 204 to removing '$n' and still lists it " +
					"(status $(Get-DockerField $s 'Status')).")
			}
			New-DockerActionResult -Container $n -Action 'Remove' -Outcome 'Removed' `
				-StatusCode $r.StatusCode -State $null
		}
	}
}

function ConvertFrom-DockerLogStream {
	<#
	.SYNOPSIS
		Internal. Splits the engine's multiplexed log stream into lines, each
		with the stream it came from.

	.DESCRIPTION
		A container started without a TTY sends its logs as frames: one byte
		for the stream (1 stdout, 2 stderr), three zero bytes, a big-endian
		32-bit length, then that many bytes. Decoding the whole body as text
		would print the headers as garbage AND lose which lines were stderr.
		A TTY container sends a raw stream with no frames, all of it stdout.
	#>
	param(
		[AllowNull()][byte[]]$Bytes,
		[bool]$Multiplexed = $true
	)

	if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return }
	$utf8 = [System.Text.Encoding]::UTF8

	if (-not $Multiplexed) {
		foreach ($l in ($utf8.GetString($Bytes) -split "`r?`n")) {
			if ($l -ne '') { [pscustomobject]@{ PSTypeName = 'Docker.LogLine'; Stream = 'stdout'; Text = $l } }
		}
		return
	}

	$i = 0
	while ($i + 8 -le $Bytes.Length) {
		$stream = switch ($Bytes[$i]) { 0 { 'stdin' } 1 { 'stdout' } 2 { 'stderr' } default { "stream$($Bytes[$i])" } }
		$len = ([int]$Bytes[$i + 4] -shl 24) -bor ([int]$Bytes[$i + 5] -shl 16) -bor
			([int]$Bytes[$i + 6] -shl 8) -bor [int]$Bytes[$i + 7]
		if ($len -lt 0 -or $i + 8 + $len -gt $Bytes.Length) {
			throw [System.IO.InvalidDataException]::new(
				"The engine's log stream has a frame of $len bytes at offset $i in a body of " +
				"$($Bytes.Length). It is not the multiplexed format this module reads.")
		}
		$payload = $utf8.GetString($Bytes, $i + 8, $len)
		foreach ($l in ($payload -split "`r?`n")) {
			if ($l -ne '') { [pscustomobject]@{ PSTypeName = 'Docker.LogLine'; Stream = $stream; Text = $l } }
		}
		$i += 8 + $len
	}
}

function Get-DockerContainerLog {
	<#
	.SYNOPSIS
		The last lines a container wrote, each marked stdout or stderr.

	.DESCRIPTION
		The engine reads its log driver — the journal, when the product sets
		`log-driver journald` (CONTAINERS-PLAN CT7) — and this reads the
		engine. It does not follow; a window that wants more asks again.

	.EXAMPLE
		Get-DockerContainerLog web -Tail 20 | Where-Object Stream -eq 'stderr'
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string]$Name,
		[ValidateRange(1, 100000)][int]$Tail = 100,
		[switch]$Timestamps
	)

	$q = @{
		stdout     = '1'
		stderr     = '1'
		tail       = "$Tail"
		timestamps = $(if ($Timestamps) { '1' } else { '0' })
	}
	$r = Invoke-DockerApi -Method GET -Path "/containers/$([uri]::EscapeDataString($Name))/logs" -Query $q
	Assert-DockerStatus -Response $r -Expected 200 -What "read the log of container '$Name'"

	$bytes = $r.Bytes
	if ($null -eq $bytes -and $null -ne $r.Text) { $bytes = [System.Text.Encoding]::UTF8.GetBytes($r.Text) }
	# The content type says which format, and is checked rather than guessed
	# from the first byte.
	$mux = $r.ContentType -notmatch 'raw-stream'
	ConvertFrom-DockerLogStream -Bytes $bytes -Multiplexed $mux
}

# =============================================================================
# Images, volumes, networks, disk usage — read only
# =============================================================================

function Get-DockerImage {
	<#
	.SYNOPSIS
		The images the engine holds.

	.EXAMPLE
		Get-DockerImage -Filter @{ reference = 'nginx' } | Select-Object RepoTags, Size
	#>
	[CmdletBinding()]
	param([System.Collections.IDictionary]$Filter)

	$q = @{}
	$f = ConvertTo-DockerFilter -Table $Filter
	if ($f) { $q.filters = $f }
	Get-DockerResource -Path '/images/json' -Query $q -What 'list images' -TypeName 'Docker.Image'
}

function Get-DockerVolume {
	<#
	.SYNOPSIS
		The volumes the engine holds, and where each one is on disk.

	.DESCRIPTION
		`Mountpoint` is where the data actually lives, which on OS/7 decides
		which dataset holds it and whether it is backed up (CONTAINERS-PLAN
		CT3). This module reports the path; deciding what it means is not its
		job.
	#>
	[CmdletBinding()]
	param([System.Collections.IDictionary]$Filter)

	$q = @{}
	$f = ConvertTo-DockerFilter -Table $Filter
	if ($f) { $q.filters = $f }
	Get-DockerResource -Path '/volumes' -Query $q -What 'list volumes' -TypeName 'Docker.Volume' -Member 'Volumes'
}

function Get-DockerNetwork {
	<#
	.SYNOPSIS
		The networks the engine has made, with their address ranges.

	.DESCRIPTION
		The ranges matter more than they look: the engine's default bridge
		took 172.17.0.0/16 and cut a machine off from an SSH peer inside that
		range (CONTAINERS-PLAN M-CT10).
	#>
	[CmdletBinding()]
	param([System.Collections.IDictionary]$Filter)

	$q = @{}
	$f = ConvertTo-DockerFilter -Table $Filter
	if ($f) { $q.filters = $f }
	Get-DockerResource -Path '/networks' -Query $q -What 'list networks' -TypeName 'Docker.Network'
}

function Get-DockerDiskUsage {
	<#
	.SYNOPSIS
		What the engine says its images, containers, volumes and build cache
		occupy.
	#>
	[CmdletBinding()]
	param()

	$r = Invoke-DockerApi -Method GET -Path '/system/df'
	Assert-DockerStatus -Response $r -Expected 200 -What 'ask the engine its disk usage'
	$d = Read-DockerJson -Response $r
	$sum = {
		param($items, $field)
		$t = [long]0
		foreach ($x in @($items)) {
			$val = Get-DockerField $x $field
			if ($null -ne $val -and [long]$val -gt 0) { $t += [long]$val }
		}
		$t
	}
	$volumes = @(Get-DockerField $d 'Volumes')
	[pscustomobject]@{
		PSTypeName     = 'Docker.DiskUsage'
		LayersSize     = Get-DockerField $d 'LayersSize'
		Images         = @(Get-DockerField $d 'Images').Count
		Containers     = @(Get-DockerField $d 'Containers').Count
		Volumes        = $volumes.Count
		VolumesSize    = & $sum $volumes 'UsageData.Size'
		BuildCacheSize = & $sum @(Get-DockerField $d 'BuildCache') 'Size'
		Raw            = $d
	}
}

# =============================================================================
# The recording, and the scenario it records
# =============================================================================

function Invoke-DockerFixtureScenario {
	<#
	.SYNOPSIS
		Internal. The ONE sequence of requests that is recorded against a real
		engine and replayed by Test-DockerModule.

	.DESCRIPTION
		ONE SEQUENCE, TWO USES. The capture runs it against a live engine with
		OS7_DOCKER_RECORD set; the self-test runs it against the recording and
		checks what came back. A second copy of these steps in the test would
		drift from the first, which is BUILD-NOTES #66 waiting to happen.

		It creates one container and one volume, both named os7-fixture-*, and
		removes both. Creating goes through Invoke-DockerApi directly because
		this module has no create verb (CONTAINERS-PLAN CT12) — the scenario is
		a harness, not a surface.

		Every list is FILTERED to the probe. The recordings are committed to a
		public repository, and an unfiltered list on a development host names
		every container and image on it.
	#>
	param(
		[string]$Image = 'alpine:3.20',
		[int]$PauseSeconds = 0,
		[switch]$NoDiskUsage
	)

	$probe = 'os7-fixture-probe'
	$vol = 'os7-fixture-vol'
	$out = [ordered]@{}

	$out.Engine = Get-DockerEngine

	$c = Invoke-DockerApi -Method POST -Path '/containers/create' -Query @{ name = $probe } -Body ([ordered]@{
			Image  = $Image
			Cmd    = @('sh', '-c', 'echo out-line; echo err-line >&2; sleep 300')
			Labels = @{ 'org.os7.fixture' = '1' }
		})
	Assert-DockerStatus -Response $c -Expected 201 -What 'create the probe container'
	$v = Invoke-DockerApi -Method POST -Path '/volumes/create' -Body ([ordered]@{
			Name   = $vol
			Labels = @{ 'org.os7.fixture' = '1' }
		})
	Assert-DockerStatus -Response $v -Expected 201 -What 'create the probe volume'

	$out.ListedCreated = @(Get-DockerContainer -All -Filter @{ name = $probe })
	$out.ListedRunningOnly = @(Get-DockerContainer -Filter @{ name = $probe })
	$out.Start = Start-DockerContainer -Name $probe -Confirm:$false
	$out.StartAgain = Start-DockerContainer -Name $probe -Confirm:$false
	if ($PauseSeconds -gt 0) { Start-Sleep -Seconds $PauseSeconds }
	$out.Log = @(Get-DockerContainerLog -Name $probe -Tail 10)
	$out.Inspected = Get-DockerContainer -Name $probe
	$out.Restart = Restart-DockerContainer -Name $probe -TimeoutSeconds 1 -Confirm:$false
	$out.Stop = Stop-DockerContainer -Name $probe -TimeoutSeconds 1 -Confirm:$false
	$out.StopAgain = Stop-DockerContainer -Name $probe -TimeoutSeconds 1 -Confirm:$false
	$out.Images = @(Get-DockerImage -Filter @{ reference = $Image })
	$out.Volumes = @(Get-DockerVolume -Filter @{ name = $vol })
	$out.Networks = @(Get-DockerNetwork -Filter @{ name = 'bridge' })
	if (-not $NoDiskUsage) { $out.DiskUsage = Get-DockerDiskUsage }
	$out.Remove = Remove-DockerContainer -Name $probe -Confirm:$false
	$out.GoneError = $null
	try { $null = Get-DockerContainer -Name $probe } catch { $out.GoneError = $_.Exception }
	$out.RemoveAgainError = $null
	try { $null = Remove-DockerContainer -Name $probe -Confirm:$false } catch { $out.RemoveAgainError = $_.Exception }

	$d = Invoke-DockerApi -Method DELETE -Path "/volumes/$vol"
	Assert-DockerStatus -Response $d -Expected 204 -What 'remove the probe volume'
	return $out
}

function Save-DockerFixture {
	<#
	.SYNOPSIS
		Internal. Records Invoke-DockerFixtureScenario against the live engine
		into one JSON-lines file. Called by
		installer/testing/capture-docker-fixtures.py, as root where the socket
		is root's.

	.DESCRIPTION
		The first line says where and when it was recorded and against which
		engine; every line after it is one request and its response, in order.
		A probe left behind by an aborted run is removed first, and that
		clean-up is NOT recorded.
	#>
	param(
		[Parameter(Mandatory)][string]$File,
		[Parameter(Mandatory)][string]$Where,
		[string]$Image = 'alpine:3.20',
		[switch]$NoDiskUsage
	)

	$old = [System.Environment]::GetEnvironmentVariable('OS7_DOCKER_RECORD')
	[System.Environment]::SetEnvironmentVariable('OS7_DOCKER_RECORD', $null)
	$script:DockerNegotiated = @{}
	try {
		$null = Invoke-DockerApi -Method DELETE -Path '/containers/os7-fixture-probe' -Query @{ force = '1' }
		$null = Invoke-DockerApi -Method DELETE -Path '/volumes/os7-fixture-vol'
		$vr = Invoke-DockerApi -Method GET -Path '/version' -Unversioned
		Assert-DockerStatus -Response $vr -Expected 200 -What 'ask the engine its version'
		$ver = Read-DockerJson -Response $vr

		if (Test-Path -LiteralPath $File) { Remove-Item -LiteralPath $File -Force }
		$meta = [ordered]@{
			_meta       = 'docker-fixture'
			recorded    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
			where       = $Where
			engine      = Get-DockerField $ver 'Version'
			api         = Get-DockerField $ver 'ApiVersion'
			minApi      = Get-DockerField $ver 'MinAPIVersion'
			pwsh        = $PSVersionTable.PSVersion.ToString()
			image       = $Image
			noDiskUsage = [bool]$NoDiskUsage
		}
		Set-Content -LiteralPath $File -Encoding utf8NoBOM -Value ($meta | ConvertTo-Json -Compress)

		$script:DockerNegotiated = @{}
		[System.Environment]::SetEnvironmentVariable('OS7_DOCKER_RECORD', $File)
		$null = Invoke-DockerFixtureScenario -Image $Image -PauseSeconds 1 -NoDiskUsage:$NoDiskUsage
	}
	finally {
		[System.Environment]::SetEnvironmentVariable('OS7_DOCKER_RECORD', $old)
	}
	return Get-Item -LiteralPath $File
}

# =============================================================================
# The self-test
# =============================================================================

function Test-DockerModule {
	<#
	.SYNOPSIS
		Checks this module against RECORDED engine responses, one set per
		engine version. No engine, no root, no network.

	.DESCRIPTION
		Each fixture in tests/fixtures/ is one run of the scenario against a
		real engine. The self-test replays it through the module's own seam —
		the cmdlets run whole, only the socket is replaced — and checks what
		they made of it. Then the decisions that no recording can contain: the
		version negotiation at both edges of the range, a filter typed the way
		a person types it, and the three ways a socket can fail.

		THE RANGE IS HELD TO THE FIXTURES. The oldest and newest API versions
		the module will speak must be exactly the oldest and newest that were
		recorded. Recording a new engine without widening the range, or
		widening it without recording, fails here.

	.PARAMETER Live
		Also ask the real engine on the socket, read only: version, info, the
		container list. Needs the socket, which is root's.

	.NOTES
		Reports through [Console]::Error and THROWS on failure, for the reasons
		Test-ZfsModule does: Write-Host does not resolve inside a chroot
		(BUILD-NOTES #38), and a function that returns $false leaves pwsh
		exiting 0 — so a self-test that failed would be an image that passed.
	#>
	[CmdletBinding()]
	param(
		[string]$FixturePath,
		[switch]$Live
	)

	if (-not $FixturePath) { $FixturePath = Join-Path $PSScriptRoot 'tests/fixtures' }

	$script:__dockerPass = 0
	$script:__dockerFail = @()
	function Check([bool]$ok, [string]$what, [string]$detail = '') {
		$line = '      {0}  {1}' -f $(if ($ok) { 'ok  ' } else { 'FAIL' }), $what
		if ($detail) { $line += "   [$detail]" }
		[Console]::Error.WriteLine($line)
		if ($ok) { $script:__dockerPass++ } else { $script:__dockerFail += $what }
	}

	$savedOverride = $script:DockerTransportOverride
	$savedNegotiated = $script:DockerNegotiated
	$savedRecord = [System.Environment]::GetEnvironmentVariable('OS7_DOCKER_RECORD')
	[System.Environment]::SetEnvironmentVariable('OS7_DOCKER_RECORD', $null)

	[Console]::Error.WriteLine("`nDocker self-test — no engine, no root, no network")
	try {
		$ErrorActionPreference = 'Stop'

		# ---------------------------------------------------------------
		# 1. Every recorded engine, replayed through the module's own seam
		# ---------------------------------------------------------------
		$files = @()
		if (Test-Path -LiteralPath $FixturePath) {
			$files = @(Get-ChildItem -LiteralPath $FixturePath -Filter 'engine-*.jsonl' | Sort-Object Name)
		}
		Check ($files.Count -ge 2) 'recordings from at least two engine versions are shipped' `
			"$($files.Count) in $FixturePath"

		$recordedApis = @()
		foreach ($file in $files) {
			$lines = @(Get-Content -LiteralPath $file.FullName | Where-Object { $_.Trim() })
			$meta = $lines[0] | ConvertFrom-Json
			$exchanges = @($lines | Select-Object -Skip 1 | ForEach-Object { $_ | ConvertFrom-Json })
			$api = ConvertTo-DockerApiVersion -Text (Get-DockerField $meta 'api')
			$recordedApis += $api
			[Console]::Error.WriteLine("  engine $(Get-DockerField $meta 'engine') (API $api), recorded $(Get-DockerField $meta 'recorded') on $(Get-DockerField $meta 'where')")

			$seen = @{}
			$sent = [System.Collections.Generic.List[string]]::new()
			$script:DockerNegotiated = @{}
			$script:DockerTransportOverride = {
				param($m, $target, $json)
				$sent.Add("$m $target")
				$bare = $target -replace '^/v\d+\.\d+', ''
				$key = "$m $bare"
				$hits = @($exchanges | Where-Object { "$($_.method) $($_.path)" -eq $key })
				if ($hits.Count -eq 0) {
					throw [System.InvalidOperationException]::new("no recorded response for $key")
				}
				$k = if ($seen.ContainsKey($key)) { $seen[$key] } else { 0 }
				$seen[$key] = $k + 1
				$x = $hits[[Math]::Min($k, $hits.Count - 1)]
				[pscustomobject]@{
					StatusCode  = [int]$x.status
					ContentType = [string]$x.contentType
					Text        = $x.text
					Bytes       = if ($x.base64) { [Convert]::FromBase64String($x.base64) } else { $null }
				}
			}.GetNewClosure()

			$s = Invoke-DockerFixtureScenario -Image ([string](Get-DockerField $meta 'image')) `
				-NoDiskUsage:([bool](Get-DockerField $meta 'noDiskUsage'))

			# The version actually put into the paths, not the one the module
			# thinks it chose.
			$want = Resolve-DockerApiVersion -EngineApi (Get-DockerField $meta 'api') `
				-EngineMinimum (Get-DockerField $meta 'minApi')
			$versioned = @($sent | Where-Object { $_ -match ' /v\d+\.\d+/' })
			$prefixes = @($versioned | ForEach-Object { ([regex]::Match($_, ' /v(\d+\.\d+)/')).Groups[1].Value } |
					Sort-Object -Unique)
			Check ($prefixes.Count -eq 1 -and $prefixes[0] -eq "$($want.Major).$($want.Minor)") `
				'every versioned request carried the negotiated version' "$($prefixes -join ',')"
			Check ($s.Engine.NegotiatedApiVersion -eq "$($want.Major).$($want.Minor)") `
				'Get-DockerEngine reports the version it negotiated' "$($s.Engine.NegotiatedApiVersion)"
			Check (-not [string]::IsNullOrWhiteSpace($s.Engine.Driver)) `
				'the engine says which storage driver it chose' "$($s.Engine.Driver) / $($s.Engine.DriverType)"

			Check ($s.ListedCreated.Count -eq 1 -and $s.ListedCreated[0].Name -eq 'os7-fixture-probe') `
				'a created container is listed with -All, by name without the slash' "$(@($s.ListedCreated).Count)"
			Check ($s.ListedRunningOnly.Count -eq 0) 'and NOT listed without -All, because it is not running'

			# THE DISTINCTION THIS MODULE EXISTS FOR (M-CT4).
			Check ($s.Start.Outcome -eq 'Started' -and $s.Start.Running -eq $true) `
				'start: 204, and asked back it is running' "$($s.Start.StatusCode) $($s.Start.Outcome)"
			Check ($s.StartAgain.Outcome -eq 'AlreadyRunning' -and $s.StartAgain.StatusCode -eq 304) `
				'start again: the engine said 304, and the verb says AlreadyRunning' "$($s.StartAgain.StatusCode) $($s.StartAgain.Outcome)"
			Check ($s.Stop.Outcome -eq 'Stopped' -and $s.Stop.Running -eq $false) `
				'stop: 204, and asked back it is not running' "$($s.Stop.StatusCode) $($s.Stop.Outcome)"
			Check ($s.StopAgain.Outcome -eq 'AlreadyStopped' -and $s.StopAgain.StatusCode -eq 304) `
				'stop again: 304 is AlreadyStopped' "$($s.StopAgain.StatusCode) $($s.StopAgain.Outcome)"
			Check ($s.Restart.Outcome -eq 'Restarted') 'restart: asked back, it is running' "$($s.Restart.Outcome)"

			$out = @($s.Log | Where-Object Stream -EQ 'stdout' | ForEach-Object Text)
			$err = @($s.Log | Where-Object Stream -EQ 'stderr' | ForEach-Object Text)
			Check ($out -contains 'out-line') 'logs: a stdout line, demultiplexed' "$($out -join '|')"
			Check ($err -contains 'err-line') 'logs: a stderr line, and it is marked stderr' "$($err -join '|')"

			Check ($s.Inspected.Name -eq 'os7-fixture-probe') 'inspect: Name without the leading slash'
			Check ($null -ne (Get-DockerField $s.Inspected 'State.Status')) 'inspect: the State is there'

			Check ($s.Images.Count -ge 1) 'images: the probe image is listed through a filter typed as a string' "$($s.Images.Count)"
			Check ($s.Volumes.Count -eq 1 -and $s.Volumes[0].Name -eq 'os7-fixture-vol') `
				'volumes: the probe volume, from inside the engine''s Volumes member' "$($s.Volumes.Count)"
			Check (-not [string]::IsNullOrWhiteSpace((Get-DockerField $s.Volumes[0] 'Mountpoint'))) `
				'volumes: and where it lives on disk'
			$bridge = @($s.Networks | Where-Object { (Get-DockerField $_ 'Name') -eq 'bridge' })
			$subnet = if ($bridge.Count) { @(Get-DockerField $bridge[0] 'IPAM.Config') | Select-Object -First 1 } else { $null }
			Check ($null -ne (Get-DockerField $subnet 'Subnet')) 'networks: the default bridge, and its address range' `
				"$(Get-DockerField $subnet 'Subnet')"
			if (-not [bool](Get-DockerField $meta 'noDiskUsage')) {
				Check ($null -ne $s.DiskUsage -and $s.DiskUsage.LayersSize -gt 0) 'disk usage: the layers have a size' `
					"$(if ($s.DiskUsage) { $s.DiskUsage.LayersSize })"
			}

			Check ($s.Remove.Outcome -eq 'Removed') 'remove: 204, and asked back it is gone'
			Check ($s.GoneError -is [System.Management.Automation.ItemNotFoundException]) `
				'inspecting a removed container is ItemNotFound' "$(if ($s.GoneError) { $s.GoneError.GetType().Name })"
			Check ($s.RemoveAgainError -is [System.Management.Automation.ItemNotFoundException] -and
				"$($s.RemoveAgainError.Message)" -match 'No such container') `
				'removing it again is ItemNotFound, in the engine''s own words' "$(if ($s.RemoveAgainError) { $s.RemoveAgainError.Message })"
		}

		# ---------------------------------------------------------------
		# 2. The range is the recordings, and nothing else
		# ---------------------------------------------------------------
		[Console]::Error.WriteLine('  the API range, held to the recordings')
		if ($recordedApis.Count) {
			$lo = ($recordedApis | Sort-Object | Select-Object -First 1)
			$hi = ($recordedApis | Sort-Object | Select-Object -Last 1)
			Check ($lo -eq $script:DockerApiOldest) 'the oldest API spoken is the oldest recorded' "$lo vs $($script:DockerApiOldest)"
			Check ($hi -eq $script:DockerApiNewest) 'the newest API spoken is the newest recorded' "$hi vs $($script:DockerApiNewest)"
		}

		# ---------------------------------------------------------------
		# 3. Negotiation at the edges — no recording can contain these
		# ---------------------------------------------------------------
		# RELATIVE TO THE RANGE, never literal versions. Widening the range with
		# a new recording is the routine way this module is kept up to date,
		# and a negotiation check written against '1.52' would fail on exactly
		# that routine — measured, by planting a widened range on a copy.
		[Console]::Error.WriteLine('  negotiation, at both edges of the range')
		$lo = $script:DockerApiOldest; $hi = $script:DockerApiNewest
		$below = "$($lo.Major).$($lo.Minor - 1)"
		Check ((Resolve-DockerApiVersion -EngineApi "$lo" -EngineMinimum '1.24') -eq $lo) `
			'an engine inside the range is spoken to at its own version'
		Check ((Resolve-DockerApiVersion -EngineApi "$($hi.Major).$($hi.Minor + 5)" -EngineMinimum '1.24') -eq $hi) `
			'a NEWER engine is spoken to at the newest recorded version, not its own'
		$threw = $null
		try { $null = Resolve-DockerApiVersion -EngineApi $below -EngineMinimum '1.24' } catch { $threw = $_.Exception }
		Check ($threw -is [System.NotSupportedException] -and $threw.Message.Contains($below) -and
			$threw.Message.Contains("$lo")) 'an OLDER engine is refused, naming both versions'
		$threw = $null
		try {
			$null = Resolve-DockerApiVersion -EngineApi "$($hi.Major).$($hi.Minor + 15)" `
				-EngineMinimum "$($hi.Major).$($hi.Minor + 5)"
		}
		catch { $threw = $_.Exception }
		Check ($threw -is [System.NotSupportedException] -and $threw.Message -match 'capture-docker-fixtures') `
			'an engine whose MINIMUM passed the newest recorded is refused, and says how to fix it'

		# ---------------------------------------------------------------
		# 4. The things a person types, and the ways a socket fails
		# ---------------------------------------------------------------
		[Console]::Error.WriteLine('  filters, and the socket')
		Check ((ConvertTo-DockerFilter -Table @{ name = 'web' }) -eq '{"name":["web"]}') `
			'a filter typed as a string is sent as the array the engine requires'
		Check ((ConvertTo-DockerQueryString -Table @{ filters = '{"a":["b c"]}' }) -eq '?filters=%7B%22a%22%3A%5B%22b%20c%22%5D%7D') `
			'a query value is escaped'

		$denied = [System.Net.Http.HttpRequestException]::new('x',
			[System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::AccessDenied))
		$e = ConvertTo-DockerTransportError -Exception $denied -Socket '/var/run/docker.sock'
		Check ($e -is [System.UnauthorizedAccessException] -and $e.Message -match 'root') `
			'permission denied on the socket says it is root''s, and why'
		$e = ConvertTo-DockerTransportError -Exception $denied -Socket '/nowhere.sock' -SocketExists $false
		Check ($e -is [System.IO.FileNotFoundException] -and $e.Message -match 'docker.socket') `
			'no socket at all says the engine is not there'
		$e = ConvertTo-DockerTransportError -Exception ([System.Net.Http.HttpRequestException]::new('reset')) -Socket '/s'
		Check ($e -is [System.InvalidOperationException] -and $e.Message -match 'did not answer') `
			'anything else says the engine did not answer'

		$savedHost = [System.Environment]::GetEnvironmentVariable('DOCKER_HOST')
		try {
			[System.Environment]::SetEnvironmentVariable('DOCKER_HOST', 'tcp://10.0.0.1:2376')
			$threw = $null
			try { $null = Get-DockerSocketPath } catch { $threw = $_.Exception }
			Check ($threw -is [System.NotSupportedException]) 'DOCKER_HOST=tcp:// is refused, not ignored'
			[System.Environment]::SetEnvironmentVariable('DOCKER_HOST', 'unix:///srv/d.sock')
			Check ((Get-DockerSocketPath) -eq '/srv/d.sock') 'DOCKER_HOST=unix:// is honoured'
		}
		finally {
			[System.Environment]::SetEnvironmentVariable('DOCKER_HOST', $savedHost)
		}

		# A 400 from the engine — what an unsupported API version gets (M-CT5)
		# — comes back as a refusal carrying the engine's sentence.
		$four = [pscustomobject]@{ StatusCode = 400; ContentType = 'application/json'; Bytes = $null
			Text = '{"message":"client version 1.24 is too old. Minimum supported API version is 1.44"}' }
		$threw = $null
		try { Assert-DockerStatus -Response $four -Expected 200 -What 'ask' } catch { $threw = $_.Exception }
		Check ($threw -is [System.ArgumentException] -and $threw.Message -match 'too old') `
			'a 400 is a refusal in the engine''s own words'

		# ---------------------------------------------------------------
		# 5. The real engine, read only
		# ---------------------------------------------------------------
		if ($Live) {
			[Console]::Error.WriteLine("  live, against $(Get-DockerSocketPath)")
			$script:DockerTransportOverride = $null
			$script:DockerNegotiated = @{}
			$g = Get-DockerEngine
			Check (-not [string]::IsNullOrWhiteSpace($g.Version)) 'live: the engine answers /version' "$($g.Version)"
			$nv = ConvertTo-DockerApiVersion -Text $g.NegotiatedApiVersion
			Check ($null -ne $nv -and $nv -ge $script:DockerApiOldest -and $nv -le $script:DockerApiNewest) `
				'live: the negotiated version is inside the recorded range' "$($g.NegotiatedApiVersion)"
			$all = @(Get-DockerContainer -All)
			Check ($null -eq ($all | Where-Object { [string]::IsNullOrEmpty($_.Name) } | Select-Object -First 1)) `
				'live: every listed container has a Name' "$($all.Count) listed"
		}
	}
	catch {
		Check $false 'the self-test ran to the end' $_.Exception.Message
	}
	finally {
		$script:DockerTransportOverride = $savedOverride
		$script:DockerNegotiated = $savedNegotiated
		[System.Environment]::SetEnvironmentVariable('OS7_DOCKER_RECORD', $savedRecord)
	}

	$failed = @($script:__dockerFail)
	[Console]::Error.WriteLine("`n  $($script:__dockerPass) passed, $($failed.Count) failed")
	if ($failed.Count) {
		throw "Docker self-test: $($failed.Count) check(s) failed: $($failed -join '; ')"
	}
}

Export-ModuleMember -Function @(
	'Get-DockerEngine',
	'Get-DockerContainer', 'Start-DockerContainer', 'Stop-DockerContainer',
	'Restart-DockerContainer', 'Remove-DockerContainer', 'Get-DockerContainerLog',
	'Get-DockerImage', 'Get-DockerVolume', 'Get-DockerNetwork', 'Get-DockerDiskUsage',
	'Test-DockerModule'
)
