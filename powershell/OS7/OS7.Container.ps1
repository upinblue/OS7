# =============================================================================
# OS/7 — containers, as an operator asks about them
#
# Layer 3 of docs/POWERSHELL-SURFACE-PLAN.md P2 for docs/CONTAINERS-PLAN.md.
# THIS FILE CONTAINS NO CALL TO `docker` AND NO REQUEST TO THE ENGINE'S SOCKET —
# those go through powershell/Docker, and check-layering.py's P2-docker holds
# that line.
#
# WHAT IS OS/7's KNOWLEDGE HERE, and therefore why this file is not a
# pass-through:
#
#   * CT6 — which containers NEED ATTENTION, in a word and a sentence and a
#     command each, and which do not. The second half is the harder half: a
#     health field that calls a deliberately stopped container "failed" is a
#     field people learn to ignore, and then it is wrong about the broken one
#     too. check-service-logic.py paid for that lesson on systemd units; the
#     cases in check-container-logic.py that must read as FINE are written as
#     carefully as the ones that must not.
#   * CT8 — who can reach a published port, as words: all networks, this
#     machine only, one address, or the machine's own network stack.
#   * P6 — the restart policy and the published ports a container was
#     CONFIGURED with, beside what it is DOING. Never merged into one field.
#   * CT5 — reading containers is root's, and the refusal says so in #148's
#     words rather than in the Docker layer's.
#
# The DECISIONS are checked with no engine by
# installer/testing/check-container-logic.py (19 situations, seven planted
# defects). The cmdlets have NOT run on a machine yet: no OS/7 image carries an
# engine until CONTAINERS-PLAN step 5, and on one without it every read says
# there is no Docker engine socket.
#
# Dot-sourced by OS7.psm1.
# =============================================================================

# The exit codes a SIGNAL leaves behind: 128 + SIGINT, SIGKILL, SIGTERM. `docker
# stop` sends SIGTERM and, after its timeout, SIGKILL, so a container somebody
# stopped deliberately exits 143 or 137 — and reading those as failures would
# put every stopped service in the attention view. The engine's API does not say
# whether a person stopped it (that flag is internal to the daemon), so the
# exit code is the honest answer and it is reported as one.
$script:OS7ContainerSignalExits = @(130, 137, 143)

# The engine statuses this file knows. Anything else is reported, with the
# engine's word, as needing attention: an engine that grew a state is worth a
# look, and a state this file does not know is not one it may call fine.
$script:OS7ContainerKnownStatus = @('created', 'running', 'paused', 'restarting', 'removing', 'exited', 'dead')

function Import-OS7DockerLayer {
	<#
	.SYNOPSIS
		Internal. Make the Docker module available, lazily.

	.DESCRIPTION
		LAZILY, AND NEVER AT IMPORT TIME — BUILD-NOTES #38, and #82 is that rule
		being broken in this module and costing a day of builds. Same shape as
		Import-OS7SystemdLayer.
	#>
	if (Get-Module -Name Docker) { return }

	$candidates = @(
		(Join-Path (Split-Path -Parent $PSScriptRoot) 'Docker/Docker.psd1'),
		'/usr/local/share/powershell/Modules/Docker/Docker.psd1'
	)
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			Import-Module $c -Force -ErrorAction Stop
			Write-OS7Step "docker layer: $c"
			return
		}
	}
	Import-Module Docker -Force -ErrorAction Stop
	Write-OS7Step 'docker layer: Docker (by name)'
}

function Get-OS7ContainerField {
	<#
	.SYNOPSIS
		Internal. A dotted path into an engine object; $null where it is absent.

	.DESCRIPTION
		The Docker layer's own reader, asked for by name rather than copied:
		engines add and drop fields between versions, and under strict mode a
		missing one throws (#112/#119's shape).
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

function Invoke-OS7ContainerRead {
	<#
	.SYNOPSIS
		Internal. Runs a read against the engine and turns the socket's
		refusal into #148's sentence.

	.DESCRIPTION
		The Docker layer already says that the socket is root's and why. What
		it cannot say is how to elevate an OS/7 verb — `sudo <verb>` does not
		work, because every verb here is a function and sudo resolves
		executables. That half is OS/7's, so it is added here, in the same
		words Assert-OS7Elevated uses for a verb that changes the machine.

		Reading is refused AFTER the attempt, not before it, on purpose: an
		administrator who put their own account in the `docker` group has
		chosen root equivalence (CONTAINERS-PLAN O-CT3), and refusing them by
		uid would be OS/7 overruling a decision that was theirs to make.
	#>
	param(
		[Parameter(Mandatory)][string]$Cmdlet,
		[Parameter(Mandatory)][scriptblock]$Read
	)

	Import-OS7DockerLayer
	try {
		& $Read
	}
	catch [System.UnauthorizedAccessException] {
		throw [System.InvalidOperationException]::new(
			"$Cmdlet must run as root: it reads the container engine, whose socket is root's " +
			"because holding it shows every container's environment, passwords included.`n" +
			"`n" +
			"  sudo $Cmdlet  DOES NOT WORK: every OS/7 cmdlet is a PowerShell`n" +
			"  function and sudo resolves executables. Elevate the shell instead:`n" +
			"`n" +
			"      sudo pwsh -NoProfile -c '$Cmdlet <parameters>'`n" +
			"`n" +
			"  or work in an elevated session: sudo pwsh`n" +
			"`n" +
			"  An administrator can instead make this account a container operator,`n" +
			"  which is ROOT-EQUIVALENT and is chosen as such:`n" +
			"`n" +
			"      sudo pwsh -NoProfile -c 'Add-OS7ContainerOperator <account>'", $_.Exception)
	}
}

function Assert-OS7ContainerElevated {
	<#
	.SYNOPSIS
		Internal. Refuse, in #148's words, unless this process is root OR holds
		the engine's socket.

	.DESCRIPTION
		THE ONE PLACE THE CONTAINER VERBS DIFFER FROM EVERY OTHER CHANGING VERB.
		Assert-OS7Elevated asks for uid 0, and for a container that is the wrong
		question: the engine decides who may change a container, and it decides
		by who can open its socket. An account an administrator made a container
		operator (Add-OS7ContainerOperator, CONTAINERS-PLAN O-CT3, chosen by the
		owner on 2026-10-30) can — and refusing it by uid would be OS/7
		overruling a decision that was the administrator's to make, which is the
		argument Invoke-OS7ContainerRead already gives for reading.

		THE SOCKET IS ASKED, NOT THE GROUP FILE. Membership in `docker` takes
		effect at the next login, so /etc/group can say yes to a process that
		the kernel will refuse. Test-DockerSocketAccess opens the socket.
	#>
	param(
		[Parameter(Mandatory)][string]$Cmdlet,
		[Parameter(Mandatory)][string]$Because
	)

	$refusal = $null
	try { Assert-OS7Elevated -Cmdlet $Cmdlet -Because $Because; return }
	catch [System.InvalidOperationException] { $refusal = $_.Exception }

	Import-OS7DockerLayer
	if (Test-DockerSocketAccess) { return }

	throw [System.InvalidOperationException]::new(
		$refusal.Message + "`n" +
		"`n" +
		"  An administrator can instead make this account a container operator,`n" +
		"  which is ROOT-EQUIVALENT and is chosen as such:`n" +
		"`n" +
		"      sudo pwsh -NoProfile -c 'Add-OS7ContainerOperator <account>'")
}

function Get-OS7ContainerCondition {
	<#
	.SYNOPSIS
		Internal. CT6: one container's state, in a word, a sentence and a
		command, and whether it needs attention.

	.DESCRIPTION
		ONE DECISION, AND THE ORDER IS PART OF IT.

		  RestartLoop   the engine says `restarting`. RestartCount is reported
		                and NOT used to decide: "rising" needs two readings
		                over time, which is polling (G10), and a count of three
		                over a year is not a loop
		  Unhealthy     running, and its own health check says unhealthy.
		                Docker's `running` is true and is not the answer
		  OutOfMemory   not running, and OOMKilled. BEFORE the signal rule,
		                because the kernel's OOM kill leaves exit code 137 —
		                the same as `docker stop` timing out
		  StartFailed   not running, and the engine recorded an error starting
		                it: a port already taken, a mount that is not there.
		                THIS is the reliable form of "it should be running and
		                is not", which CT6 first proposed as "stopped while the
		                restart policy says always" — a rule that would have
		                fired on every container anybody stopped on purpose,
		                because an `always` container that CRASHED is
		                restarted by the engine itself
		  Failed        exited with a code that is not 0 and not a signal's
		  Dead          the engine's own word for a container it could not
		                clean up
		  Unknown       a status this file does not know

		Not attention: Running, Starting (health check not decided yet),
		Paused (a deliberate act), Created (never started), Stopped (exit 0,
		or a signal — what a stop leaves), Removing.
	#>
	param([Parameter(Mandatory)]$Container)

	$name = [string](Get-OS7ContainerField $Container 'Name')
	$name = $name.TrimStart('/')
	$st = Get-OS7ContainerField $Container 'State'
	$status = [string](Get-OS7ContainerField $st 'Status')
	$health = [string](Get-OS7ContainerField $st 'Health.Status')
	$exit = Get-OS7ContainerField $st 'ExitCode'
	$oom = [bool](Get-OS7ContainerField $st 'OOMKilled')
	$err = [string](Get-OS7ContainerField $st 'Error')
	$restarts = Get-OS7ContainerField $Container 'RestartCount'
	$log = "Get-OS7ContainerLog -Name $name -Tail 50"

	$verdict = {
		param($word, $attention, $sentence, $command)
		[pscustomobject]@{ State = $word; NeedsAttention = $attention; Reason = $sentence; Command = $command }
	}

	if ($script:OS7ContainerKnownStatus -notcontains $status) {
		return & $verdict 'Unknown' $true ("The engine reports '$status', a status this version of " +
			'OS/7 does not know.') "Get-OS7Container -Name $name | Format-List *"
	}
	if ($status -eq 'restarting') {
		return & $verdict 'RestartLoop' $true ("It keeps stopping and being restarted by its restart " +
			"policy: $restarts restarts so far, last exit code $exit." +
			$(if ($oom) { ' The last exit was the kernel killing it for memory.' } else { '' })) $log
	}
	if ($status -eq 'running' -and $health -eq 'unhealthy') {
		$streak = Get-OS7ContainerField $st 'Health.FailingStreak'
		return & $verdict 'Unhealthy' $true ("It is running, and its own health check has failed " +
			"$streak time(s) in a row.") "Get-OS7Container -Name $name | Select-Object -ExpandProperty Health"
	}
	if ($status -eq 'running' -and $health -eq 'starting') {
		return & $verdict 'Starting' $false 'It is running, and its health check has not decided yet.' $null
	}
	if ($status -eq 'running') { return & $verdict 'Running' $false $null $null }
	if ($status -eq 'paused') {
		# No Command: OS/7 has no pause or resume verb (CT10), and a Command
		# is something to TYPE — check-container-logic.py parses every one.
		return & $verdict 'Paused' $false ('It was paused: its processes are frozen, not stopped. ' +
			'OS/7 has no resume verb; the engine''s own tools resume it.') $null
	}
	if ($status -eq 'created') {
		return & $verdict 'Created' $false 'It was created and has never been started.' $null
	}
	if ($status -eq 'removing') { return & $verdict 'Removing' $false 'The engine is removing it.' $null }
	if ($status -eq 'dead') {
		return & $verdict 'Dead' $true ('The engine could not finish stopping or removing it. That is ' +
			'usually a mount or a storage driver refusing.') "Remove-OS7Container -Name $name -Force"
	}

	# exited
	if ($oom) {
		return & $verdict 'OutOfMemory' $true ("The kernel killed it for using more memory than it was " +
			"allowed (exit code $exit).") $log
	}
	if (-not [string]::IsNullOrWhiteSpace($err)) {
		return & $verdict 'StartFailed' $true "The engine could not start it: $err" "Start-OS7Container -Name $name"
	}
	if ($null -eq $exit -or [int]$exit -eq 0) {
		return & $verdict 'Stopped' $false 'It ended normally (exit code 0).' $null
	}
	if ($script:OS7ContainerSignalExits -contains [int]$exit) {
		$sig = switch ([int]$exit) { 130 { 'SIGINT' } 137 { 'SIGKILL' } 143 { 'SIGTERM' } }
		return & $verdict 'Stopped' $false ("It was ended by $sig (exit code $exit), which is what " +
			'stopping it does. If nobody stopped it, something else on this machine did.') $null
	}
	return & $verdict 'Failed' $true "Its process ended with exit code $exit." $log
}

function ConvertTo-OS7ContainerPort {
	<#
	.SYNOPSIS
		Internal. CT8: one engine port mapping as who can reach it, in words.

	.DESCRIPTION
		The bind address decides it, and two spellings mean every address:
		`0.0.0.0` and `::`, and an empty one, which the engine reports for a
		binding given without an address. Loopback is this machine only.
		Anything else is that one address.

		WHAT THIS DOES NOT CLAIM. Whether the host's firewall also stands
		between the network and the port is CONTAINERS-PLAN O-M2 and
		unmeasured: Docker writes its own rules ahead of the host's filter, and
		until that is measured on this product the words say what the port is
		BOUND to, not what a firewall would let through.
	#>
	param(
		[Parameter(Mandatory)][string]$ContainerPort,
		[AllowEmptyString()][string]$HostIp,
		[AllowEmptyString()][string]$HostPort
	)

	$reach = 'Address'
	if ([string]::IsNullOrEmpty($HostIp) -or $HostIp -eq '0.0.0.0' -or $HostIp -eq '::') { $reach = 'AllNetworks' }
	elseif ($HostIp -eq '127.0.0.1' -or $HostIp -eq '::1' -or $HostIp.StartsWith('127.')) { $reach = 'ThisMachine' }

	$who = switch ($reach) {
		'AllNetworks' { 'all networks' }
		'ThisMachine' { 'this machine only' }
		default { "only on $HostIp" }
	}
	[pscustomobject]@{
		PSTypeName    = 'OS7.ContainerPort'
		ContainerPort = $ContainerPort
		HostIp        = $HostIp
		HostPort      = $HostPort
		Reach         = $reach
		Text          = "$HostPort → $ContainerPort · $who"
	}
}

function Get-OS7ContainerPortSet {
	<#
	.SYNOPSIS
		Internal. A port map — the engine's {"80/tcp": [{HostIp, HostPort}]} —
		as CT8 words, one entry per binding, IPv4 and IPv6 of the same port
		folded into one.

	.DESCRIPTION
		The engine lists a port published on every address TWICE, once for
		0.0.0.0 and once for ::. Showing both would tell an operator that two
		things are open when one is; they are folded when they agree on the
		host port and both mean every address.
	#>
	param($Map)

	if ($null -eq $Map) { return }
	$out = [System.Collections.Generic.List[object]]::new()
	foreach ($p in @($Map.PSObject.Properties)) {
		foreach ($b in @($p.Value)) {
			if ($null -eq $b) { continue }
			$port = ConvertTo-OS7ContainerPort -ContainerPort $p.Name `
				-HostIp ([string](Get-OS7ContainerField $b 'HostIp')) `
				-HostPort ([string](Get-OS7ContainerField $b 'HostPort'))
			$dup = $false
			foreach ($seen in $out) {
				if ($seen.ContainerPort -eq $port.ContainerPort -and $seen.HostPort -eq $port.HostPort -and
					$seen.Reach -eq 'AllNetworks' -and $port.Reach -eq 'AllNetworks') { $dup = $true }
			}
			if (-not $dup) { $out.Add($port) }
		}
	}
	return $out.ToArray()
}

function Get-OS7ContainerLabel {
	<#
	.SYNOPSIS
		Internal. One label's value, or $null.

	.DESCRIPTION
		A label's KEY has dots in it, so it is read as one name and never
		through the dotted-path reader — which split `com.docker.compose.project`
		into four steps and found nothing, while the window's Applications node
		would have stayed empty in silence. check-container-logic.py found it.
	#>
	param($Labels, [Parameter(Mandatory)][string]$Key)

	if ($null -eq $Labels) { return $null }
	if ($Labels -is [System.Collections.IDictionary]) { return $Labels[$Key] }
	$lp = $Labels.PSObject.Properties[$Key]
	if ($lp) { return $lp.Value }
	return $null
}

function ConvertFrom-OS7ComposeDependency {
	<#
	.SYNOPSIS
		Internal. Compose's depends_on label as the service names it names.

	.DESCRIPTION
		Compose v2 writes `db:service_started:false,cache:service_healthy:true`
		— service, condition, whether to restart with it — on every container
		of a service that depends on others. Only the service name decides an
		order; the condition is compose's to wait for, and starting through the
		engine cannot wait for health the way `compose up` does, which is why
		Start-OS7ContainerApplication starts in order and reports each result
		rather than promising readiness.
	#>
	param([AllowNull()][string]$Text)

	if ([string]::IsNullOrWhiteSpace($Text)) { return }
	foreach ($part in $Text.Split(',')) {
		$svc = $part.Split(':')[0].Trim()
		if ($svc) { $svc }
	}
}

function ConvertTo-OS7Container {
	<#
	.SYNOPSIS
		Internal. One inspected engine container as the object OS/7 shows.
	#>
	param([Parameter(Mandatory)]$Inspect)

	$cond = Get-OS7ContainerCondition -Container $Inspect
	$st = Get-OS7ContainerField $Inspect 'State'
	$mode = [string](Get-OS7ContainerField $Inspect 'HostConfig.NetworkMode')

	# P6: what it was CONFIGURED to publish, and what is published NOW. A
	# stopped container has the first and not the second.
	$configured = @(Get-OS7ContainerPortSet -Map (Get-OS7ContainerField $Inspect 'HostConfig.PortBindings'))
	$effective = @(Get-OS7ContainerPortSet -Map (Get-OS7ContainerField $Inspect 'NetworkSettings.Ports'))

	# CT8's fourth answer. A container on the host's network publishes
	# nothing, and every port its process opens is a port of this machine —
	# the list above is empty and the truth is the opposite of empty.
	$reachSummary = if ($mode -eq 'host') {
		"shares this machine's network: every port it opens is reachable as this machine's own"
	}
	elseif ($effective.Count) { ($effective | ForEach-Object Text) -join '; ' }
	else { $null }

	$policy = [string](Get-OS7ContainerField $Inspect 'HostConfig.RestartPolicy.Name')
	if ([string]::IsNullOrEmpty($policy)) { $policy = 'no' }
	$retries = Get-OS7ContainerField $Inspect 'HostConfig.RestartPolicy.MaximumRetryCount'
	if ($policy -eq 'on-failure' -and $retries) { $policy = "on-failure:$retries" }

	$labels = Get-OS7ContainerField $Inspect 'Config.Labels'
	$app = Get-OS7ContainerLabel -Labels $labels -Key 'com.docker.compose.project'
	$service = Get-OS7ContainerLabel -Labels $labels -Key 'com.docker.compose.service'
	$dependsOn = @(ConvertFrom-OS7ComposeDependency -Text (Get-OS7ContainerLabel -Labels $labels -Key 'com.docker.compose.depends_on'))

	# The volumes and networks it uses, by name. NOT its environment: that is
	# where passwords are put, and an object the window renders property by
	# property (CT11) would draw them (M-CT6).
	$volumes = @(@(Get-OS7ContainerField $Inspect 'Mounts') | Where-Object {
			$_ -and (Get-OS7ContainerField $_ 'Type') -eq 'volume' } |
			ForEach-Object { [string](Get-OS7ContainerField $_ 'Name') } | Where-Object { $_ })
	$nets = Get-OS7ContainerField $Inspect 'NetworkSettings.Networks'
	$networks = @(if ($nets) { $nets.PSObject.Properties | ForEach-Object Name })

	[pscustomobject]@{
		PSTypeName          = 'OS7.Container'
		Name                = ([string](Get-OS7ContainerField $Inspect 'Name')).TrimStart('/')
		State               = $cond.State
		NeedsAttention      = $cond.NeedsAttention
		Reason              = $cond.Reason
		Command             = $cond.Command
		Image               = Get-OS7ContainerField $Inspect 'Config.Image'
		EngineStatus        = Get-OS7ContainerField $st 'Status'
		Health              = Get-OS7ContainerField $st 'Health.Status'
		ExitCode            = Get-OS7ContainerField $st 'ExitCode'
		RestartPolicy       = $policy
		RestartCount        = Get-OS7ContainerField $Inspect 'RestartCount'
		NetworkMode         = $mode
		Ports               = $effective
		PortsConfigured     = $configured
		Reachable           = $reachSummary
		Application         = $app
		Service             = $service
		DependsOn           = $dependsOn
		Volumes             = $volumes
		Networks            = $networks
		Labels              = $labels
		StartedAt           = Get-OS7ContainerField $st 'StartedAt'
		FinishedAt          = Get-OS7ContainerField $st 'FinishedAt'
		Created             = Get-OS7ContainerField $Inspect 'Created'
		Id                  = Get-OS7ContainerField $Inspect 'Id'
	}
}

function Get-OS7Container {
	<#
	.SYNOPSIS
		The containers that need attention — or, with -All, every container —
		each with a state, a sentence and a command.

	.DESCRIPTION
		THE DEFAULT VIEW IS WHAT IS WRONG, not what is there (CONTAINERS-PLAN
		CT6, POWERSHELL-SURFACE-PLAN P10's shape). An empty answer means
		nothing needs attention, and says so on the information stream.

		Each object carries what the container was CONFIGURED to do beside what
		it is DOING (P6): RestartPolicy beside State, PortsConfigured beside
		Ports. `Reachable` says who can reach its published ports in words
		(CT8) — and for a container on the host's own network, that the answer
		is every port it opens.

		Reading needs root: the engine's socket is root's because holding it
		shows every container's environment (CT5).

	.EXAMPLE
		Get-OS7Container

	.EXAMPLE
		Get-OS7Container -All | Format-Table Name, State, Reachable

	.EXAMPLE
		Get-OS7Container -Name web | Format-List *
	#>
	[CmdletBinding(DefaultParameterSetName = 'Attention')]
	[OutputType('OS7.Container')]
	param(
		[Parameter(ParameterSetName = 'Name', Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string[]]$Name,
		[Parameter(ParameterSetName = 'All')][switch]$All
	)

	process {
		$set = $PSCmdlet.ParameterSetName
		$wanted = $Name
		$rows = Invoke-OS7ContainerRead -Cmdlet 'Get-OS7Container' -Read {
			if ($set -eq 'Name') {
				foreach ($n in $wanted) { Get-DockerContainer -Name $n }
			}
			else {
				foreach ($c in @(Get-DockerContainer -All)) { Get-DockerContainer -Name $c.Name }
			}
		}

		$shown = 0
		foreach ($r in @($rows)) {
			$o = ConvertTo-OS7Container -Inspect $r
			if ($set -eq 'Attention' -and -not $o.NeedsAttention) { continue }
			$shown++
			$o
		}
		if ($set -eq 'Attention' -and $shown -eq 0) {
			Write-Information 'No container needs attention. Get-OS7Container -All lists every one.' `
				-InformationAction Continue
		}
	}
}

function Get-OS7ContainerLog {
	<#
	.SYNOPSIS
		The last lines a container wrote, each marked stdout or stderr.

	.EXAMPLE
		Get-OS7ContainerLog -Name web -Tail 50
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string]$Name,
		[ValidateRange(1, 100000)][int]$Tail = 100
	)

	$n = $Name; $t = $Tail
	Invoke-OS7ContainerRead -Cmdlet 'Get-OS7ContainerLog' -Read { Get-DockerContainerLog -Name $n -Tail $t }
}

function Invoke-OS7ContainerAction {
	<#
	.SYNOPSIS
		Internal. One lifecycle verb: refuse as a user (#148), act through the
		Docker layer, and report the container's OS/7 state afterwards.

	.DESCRIPTION
		The Docker layer already reads the container back and says
		AlreadyRunning / AlreadyStopped when the engine did nothing (M-CT4).
		What this adds is the operator's word for the container AFTERWARDS —
		Running, Failed, StartFailed — so a start that the engine accepted and
		that died at once reads as what it is.
	#>
	param(
		[Parameter(Mandatory)][string]$Cmdlet,
		[Parameter(Mandatory)][string]$Because,
		[Parameter(Mandatory)][string]$Container,
		[Parameter(Mandatory)][scriptblock]$Act
	)

	Assert-OS7ContainerElevated -Cmdlet $Cmdlet -Because $Because
	Import-OS7DockerLayer
	$did = & $Act
	$after = $null
	try { $after = ConvertTo-OS7Container -Inspect (Get-DockerContainer -Name $Container) }
	catch [System.Management.Automation.ItemNotFoundException] { $after = $null }

	[pscustomobject]@{
		PSTypeName = 'OS7.ContainerAction'
		Name       = $Container
		Action     = $did.Action
		Outcome    = $did.Outcome
		State      = if ($after) { $after.State } else { 'Removed' }
		Reason     = if ($after) { $after.Reason } else { $null }
	}
}

function Start-OS7Container {
	<#
	.SYNOPSIS
		Starts a container, and says what it is doing afterwards.

	.DESCRIPTION
		Outcome is the engine's (Started, AlreadyRunning, Exited); State is
		OS/7's reading of the container right afterwards (CT6).
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.ContainerAction')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string]$Name
	)

	if (-not $PSCmdlet.ShouldProcess($Name, 'start container')) { return }
	$n = $Name
	Invoke-OS7ContainerAction -Cmdlet 'Start-OS7Container' -Container $n `
		-Because 'starts a container through the engine, whose socket is root''s' `
		-Act { Start-DockerContainer -Name $n -Confirm:$false }
}

function Stop-OS7Container {
	<#
	.SYNOPSIS
		Stops a container, and says what it is doing afterwards.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.ContainerAction')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string]$Name,
		[ValidateRange(0, 3600)][int]$TimeoutSeconds = 10
	)

	if (-not $PSCmdlet.ShouldProcess($Name, 'stop container')) { return }
	$n = $Name; $t = $TimeoutSeconds
	Invoke-OS7ContainerAction -Cmdlet 'Stop-OS7Container' -Container $n `
		-Because 'stops a container through the engine, whose socket is root''s' `
		-Act { Stop-DockerContainer -Name $n -TimeoutSeconds $t -Confirm:$false }
}

function Restart-OS7Container {
	<#
	.SYNOPSIS
		Restarts a container, and says what it is doing afterwards.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.ContainerAction')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string]$Name,
		[ValidateRange(0, 3600)][int]$TimeoutSeconds = 10
	)

	if (-not $PSCmdlet.ShouldProcess($Name, 'restart container')) { return }
	$n = $Name; $t = $TimeoutSeconds
	Invoke-OS7ContainerAction -Cmdlet 'Restart-OS7Container' -Container $n `
		-Because 'restarts a container through the engine, whose socket is root''s' `
		-Act { Restart-DockerContainer -Name $n -TimeoutSeconds $t -Confirm:$false }
}

function Remove-OS7Container {
	<#
	.SYNOPSIS
		Removes a container. Its NAMED volumes stay, and the result says which.

	.DESCRIPTION
		What a remove destroys is the container's own writable layer — anything
		it wrote outside a volume. On OS/7 that layer lives in the image store,
		which is deliberately NOT backed up (CONTAINERS-PLAN CT3), so it is
		gone for good. Named volumes are not touched; `KeptVolumes` lists them
		so the operator can see their data is still there. Anonymous volumes
		go with the container only under -RemoveVolumes.

		A running container is refused by the engine unless -Force.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.ContainerAction')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string]$Name,
		[switch]$Force,
		[switch]$RemoveVolumes
	)

	if (-not $PSCmdlet.ShouldProcess($Name, 'remove container and its writable layer')) { return }
	$n = $Name; $f = [bool]$Force; $rv = [bool]$RemoveVolumes

	Assert-OS7ContainerElevated -Cmdlet 'Remove-OS7Container' -Because 'removes a container through the engine, whose socket is root''s'
	Import-OS7DockerLayer
	$before = Get-DockerContainer -Name $n
	$kept = @(@(Get-OS7ContainerField $before 'Mounts') |
			Where-Object { (Get-OS7ContainerField $_ 'Type') -eq 'volume' -and
				-not [string]::IsNullOrEmpty([string](Get-OS7ContainerField $_ 'Name')) -and
				-not ($rv -and ([string](Get-OS7ContainerField $_ 'Name')) -match '^[0-9a-f]{64}$') } |
			ForEach-Object { [string](Get-OS7ContainerField $_ 'Name') })

	$result = Invoke-OS7ContainerAction -Cmdlet 'Remove-OS7Container' -Container $n `
		-Because 'removes a container through the engine, whose socket is root''s' `
		-Act { Remove-DockerContainer -Name $n -Force:$f -RemoveVolumes:$rv -Confirm:$false }
	$result | Add-Member -NotePropertyName KeptVolumes -NotePropertyValue $kept
	return $result
}

# =============================================================================
# Images, volumes, networks — what the engine holds besides containers
#
# Added 2026-10-30 for the window's v1, as the owner scoped it: images with
# "used by" and whether the registry has moved the tag on, volumes with whether
# they are backed up, networks, and a clean-up that shows what it would remove
# before it removes it.
# =============================================================================

function ConvertFrom-OS7UnixTime {
	<#
	.SYNOPSIS
		Internal. The engine's seconds-since-1970 as a UTC DateTime, or $null.
	#>
	param($Seconds)
	if ($null -eq $Seconds -or "$Seconds" -eq '' -or [long]$Seconds -le 0) { return $null }
	return [DateTimeOffset]::FromUnixTimeSeconds([long]$Seconds).UtcDateTime
}

function Get-OS7ContainerUsage {
	<#
	.SYNOPSIS
		Internal. One reading of the engine for the views below: every
		container (summary), the disk usage, and which container uses which
		image, volume and network.

	.DESCRIPTION
		ONE READING, NOT ONE PER ROW. "Used by" is a join across the container
		list, and asking the engine once per image would be N requests for an
		answer the engine gives in one. /system/df is the engine's own sizes;
		where it fails (it can be slow on a large store) the sizes are $null
		and the rest still answers.
	#>
	param()

	$containers = @(Get-DockerContainer -All)
	$df = $null
	try { $df = Get-DockerDiskUsage } catch { $df = $null }

	$byImage = @{}; $byVolume = @{}; $byNetwork = @{}
	foreach ($c in $containers) {
		$n = [string]$c.Name
		$img = [string](Get-OS7ContainerField $c 'ImageID')
		if ($img) { if (-not $byImage.ContainsKey($img)) { $byImage[$img] = [System.Collections.Generic.List[string]]::new() }; $byImage[$img].Add($n) }
		foreach ($m in @(Get-OS7ContainerField $c 'Mounts')) {
			if ($null -eq $m -or (Get-OS7ContainerField $m 'Type') -ne 'volume') { continue }
			$v = [string](Get-OS7ContainerField $m 'Name')
			if (-not $v) { continue }
			if (-not $byVolume.ContainsKey($v)) { $byVolume[$v] = [System.Collections.Generic.List[string]]::new() }
			$byVolume[$v].Add($n)
		}
		$nets = Get-OS7ContainerField $c 'NetworkSettings.Networks'
		if ($nets) {
			foreach ($p in $nets.PSObject.Properties) {
				if (-not $byNetwork.ContainsKey($p.Name)) { $byNetwork[$p.Name] = [System.Collections.Generic.List[string]]::new() }
				$byNetwork[$p.Name].Add($n)
			}
		}
	}

	$imageSize = @{}; $volumeSize = @{}; $containerSize = @{}
	if ($df) {
		foreach ($i in @(Get-OS7ContainerField $df.Raw 'Images')) {
			if ($null -eq $i) { continue }
			$size = Get-OS7ContainerField $i 'Size'
			$shared = Get-OS7ContainerField $i 'SharedSize'
			# What removing it would free is what it does NOT share with
			# another image. The engine reports -1 for "not computed".
			$unique = if ($null -ne $size -and $null -ne $shared -and [long]$shared -ge 0) { [long]$size - [long]$shared } else { $size }
			$imageSize[[string](Get-OS7ContainerField $i 'Id')] = $unique
		}
		foreach ($v in @(Get-OS7ContainerField $df.Raw 'Volumes')) {
			if ($null -eq $v) { continue }
			$s = Get-OS7ContainerField $v 'UsageData.Size'
			$volumeSize[[string](Get-OS7ContainerField $v 'Name')] = if ($null -ne $s -and [long]$s -ge 0) { [long]$s } else { $null }
		}
		foreach ($c in @(Get-OS7ContainerField $df.Raw 'Containers')) {
			if ($null -eq $c) { continue }
			$containerSize[[string](Get-OS7ContainerField $c 'Id')] = Get-OS7ContainerField $c 'SizeRw'
		}
	}

	[pscustomobject]@{
		Containers    = $containers
		DiskUsage     = $df
		ImageUsers    = $byImage
		VolumeUsers   = $byVolume
		NetworkUsers  = $byNetwork
		ImageSize     = $imageSize
		VolumeSize    = $volumeSize
		ContainerSize = $containerSize
	}
}

function Get-OS7ContainerImageUpdate {
	<#
	.SYNOPSIS
		Internal. Has the registry moved this image's tag on? $true, $false,
		or $null with the reason it could not be told.

	.DESCRIPTION
		THE COMPARISON, AND ITS PREMISE MEASURED. The registry's digest for a
		tag is compared with the digests the local image was pulled by
		(RepoDigests). Test-DockerModule checks, on every recorded engine,
		that a JUST-PULLED tag's registry digest IS among them — without that,
		this would call every image outdated. Measured on 29.7.2 and 29.1.3.

		Three outcomes, never two (Get-OS7TimeSynchronization's rule): an
		image that was never pulled from a registry, or whose registry did not
		answer, is $null with a sentence, because "no update" would be a
		claim nobody checked.
	#>
	param([Parameter(Mandatory)]$Image)

	$tags = @(@(Get-OS7ContainerField $Image 'RepoTags') | Where-Object { $_ -and $_ -ne '<none>:<none>' })
	$digests = @(@(Get-OS7ContainerField $Image 'RepoDigests') | Where-Object { $_ })
	if ($tags.Count -eq 0) {
		return [pscustomobject]@{ Available = $null; Remote = $null; Reason = 'It has no tag, so there is nothing to compare at a registry.' }
	}
	if ($digests.Count -eq 0) {
		return [pscustomobject]@{ Available = $null; Remote = $null; Reason = 'It was not pulled from a registry (built or loaded on this machine), so no registry knows it.' }
	}
	$tag = $tags[0]
	try { $d = Get-DockerDistribution -Reference $tag }
	catch {
		return [pscustomobject]@{ Available = $null; Remote = $null; Reason = "The registry could not be asked: $($_.Exception.Message)" }
	}
	$local = @($digests | ForEach-Object { "$_".Split('@')[-1] })
	if ($local -contains [string]$d.Digest) {
		return [pscustomobject]@{ Available = $false; Remote = $d.Digest; Reason = "$tag at the registry is this image." }
	}
	return [pscustomobject]@{ Available = $true; Remote = $d.Digest; Reason = ("$tag at the registry is a newer image ($($d.Digest.Substring(0, [Math]::Min(19, $d.Digest.Length)))…). " +
			'Containers keep the image they were created from until they are created again.') }
}

function Get-OS7ContainerImage {
	<#
	.SYNOPSIS
		The images on this machine: their size, which containers use them, and
		— with -CheckUpdate — whether the registry has a newer image under the
		same tag.

	.DESCRIPTION
		`Size` is what removing the image would free: the engine's size less
		what it shares with other images. `UpdateAvailable` is $null unless
		-CheckUpdate asked, and $null afterwards too when the registry could
		not answer — `UpdateCheck` says which.

		-CheckUpdate reaches the network, once per image. It pulls nothing.

	.EXAMPLE
		Get-OS7ContainerImage | Format-Table Name, Size, InUse, UsedBy

	.EXAMPLE
		Get-OS7ContainerImage -CheckUpdate | Where-Object UpdateAvailable
	#>
	[CmdletBinding()]
	[OutputType('OS7.ContainerImage')]
	param(
		[Parameter(Position = 0)][string[]]$Name,
		[switch]$CheckUpdate
	)

	$check = [bool]$CheckUpdate
	Invoke-OS7ContainerRead -Cmdlet 'Get-OS7ContainerImage' -Read {
		$u = Get-OS7ContainerUsage
		foreach ($i in @(Get-DockerImage)) {
			$id = [string](Get-OS7ContainerField $i 'Id')
			$tags = @(@(Get-OS7ContainerField $i 'RepoTags') | Where-Object { $_ -and $_ -ne '<none>:<none>' })
			$label = if ($tags.Count) { $tags[0] } else { "<none> ($($id.Replace('sha256:', '').Substring(0, 12)))" }
			if ($Name -and -not ($Name | Where-Object { $tags -contains $_ -or $label -eq $_ -or $id -eq $_ })) { continue }
			$users = @(if ($u.ImageUsers.ContainsKey($id)) { $u.ImageUsers[$id] })
			$upd = if ($check) { Get-OS7ContainerImageUpdate -Image $i } else {
				[pscustomobject]@{ Available = $null; Remote = $null; Reason = 'Not asked. -CheckUpdate asks the registry.' } }
			[pscustomobject]@{
				PSTypeName      = 'OS7.ContainerImage'
				Name            = $label
				Tags            = $tags
				Dangling        = ($tags.Count -eq 0)
				InUse           = ($users.Count -gt 0)
				UsedBy          = $users
				Size            = if ($u.ImageSize.ContainsKey($id)) { $u.ImageSize[$id] } else { Get-OS7ContainerField $i 'Size' }
				Created         = ConvertFrom-OS7UnixTime (Get-OS7ContainerField $i 'Created')
				UpdateChecked   = $check
				UpdateAvailable = $upd.Available
				UpdateCheck     = $upd.Reason
				RemoteDigest    = $upd.Remote
				RepoDigests     = @(@(Get-OS7ContainerField $i 'RepoDigests') | Where-Object { $_ })
				Id              = $id
			}
		}
	}
}

function Remove-OS7ContainerImage {
	<#
	.SYNOPSIS
		Removes an image. One a container uses is refused, in the engine's words.

	.DESCRIPTION
		Without -Force the engine refuses an image any container uses — running
		or stopped — because the container could not be started again. An image
		can always be pulled again, so this is the cheap end of a clean-up.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/:@+-]*$')]
		[string]$Name,
		[switch]$Force
	)

	if (-not $PSCmdlet.ShouldProcess($Name, 'remove image')) { return }
	Assert-OS7ContainerElevated -Cmdlet 'Remove-OS7ContainerImage' -Because 'removes an image through the engine, whose socket is root''s'
	$n = $Name; $f = [bool]$Force
	$r = Remove-DockerImage -Name $n -Force:$f -Confirm:$false
	[pscustomobject]@{ PSTypeName = 'OS7.ContainerRemoval'; Kind = 'Image'; Name = $n; Outcome = $r.Outcome; Reason = $null }
}

function Get-OS7ContainerStoreDataset {
	<#
	.SYNOPSIS
		Internal. Which dataset holds a path of the engine's, whether that is
		inside the boot environment, and whether the backup policy reaches it.
	#>
	param([Parameter(Mandatory)][string]$Path, $Datasets, $Covered)

	$owner = $null
	try { $owner = Get-OS7PathDataset -Path $Path -Dataset $Datasets } catch { $owner = $null }
	$ds = if ($owner) { [string]$owner.Dataset } else { $null }
	[pscustomobject]@{
		Path              = $Path
		Dataset           = $ds
		InBootEnvironment = [bool]($ds -and $ds -match '(^|/)ROOT(/|$)')
		BackedUp          = if ($null -eq $Covered) { $null } else { [bool]($ds -and $Covered -contains $ds) }
	}
}

function Get-OS7ContainerBackupContext {
	<#
	.SYNOPSIS
		Internal. The ZFS datasets and the backup policy, read once.
	#>
	param()

	$datasets = @()
	try { Import-OS7ZfsLayer; $datasets = @(Get-ZfsDataset -Type Filesystem -Recurse) } catch { $datasets = @() }

	# A POLICY THAT COULD NOT BE READ IS NOT AN EMPTY ONE. As a user,
	# /etc/os7/backup.json is root's, Get-OS7BackupPolicy falls back to the
	# default policy, and the default does not name the engine's dataset — so
	# the Containers window, opened by a user, said "Data backed up: No" about a
	# dataset that IS backed up (seen on a machine, 2026-10-30). $null is the
	# answer when the question could not be asked (Get-OS7TimeSynchronization's
	# three outcomes).
	$covered = $null
	$readable = $true
	if ([System.IO.File]::Exists($script:OS7BackupConfig)) {
		try { [System.IO.File]::OpenRead($script:OS7BackupConfig).Dispose() } catch { $readable = $false }
	}
	if ($readable) {
		try {
			$policy = Get-OS7BackupPolicy
			$covered = @(@($policy.Sources) | ForEach-Object { @(Get-OS7ContainerField $_ 'Datasets') } | Where-Object { $_ })
		}
		catch { $covered = $null }
	}
	[pscustomobject]@{ Datasets = $datasets; Covered = $covered }
}

function Get-OS7ContainerVolume {
	<#
	.SYNOPSIS
		The volumes on this machine: their size, which containers use them, and
		whether the backup reaches them.

	.DESCRIPTION
		A volume is where a container's data belongs (CONTAINERS-PLAN CT3), so
		the questions an operator asks of one are about that data: is it
		backed up, when was the last snapshot taken, and what is using it.
		`BackedUp` is computed from the dataset that holds the volume's path
		and the backup policy — not assumed from where OS/7 meant to put it,
		because a machine where the engine was installed by hand keeps its
		volumes somewhere else (O-CT7).

		-IncludeVersions, with one -Name, adds the volume folder's versions
		(Get-OS7FileVersion). Its data is root's, so this answers as root; the
		Versions window, which runs as the user, cannot read it.

	.EXAMPLE
		Get-OS7ContainerVolume | Format-Table Name, Size, InUse, BackedUp, LatestSnapshot
	#>
	[CmdletBinding()]
	[OutputType('OS7.ContainerVolume')]
	param(
		[Parameter(Position = 0)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')][string[]]$Name,
		[switch]$IncludeVersions
	)

	if ($IncludeVersions -and @($Name).Count -ne 1) {
		throw [System.ArgumentException]::new('-IncludeVersions answers for ONE volume: name it with -Name.')
	}
	$wanted = $Name; $withVersions = [bool]$IncludeVersions
	Invoke-OS7ContainerRead -Cmdlet 'Get-OS7ContainerVolume' -Read {
		$u = Get-OS7ContainerUsage
		$ctx = Get-OS7ContainerBackupContext
		$stores = @{}
		foreach ($v in @(Get-DockerVolume)) {
			$vn = [string](Get-OS7ContainerField $v 'Name')
			if ($wanted -and $wanted -notcontains $vn) { continue }
			$mp = [string](Get-OS7ContainerField $v 'Mountpoint')
			$store = Get-OS7ContainerStoreDataset -Path $mp -Datasets $ctx.Datasets -Covered $ctx.Covered
			$snap = $null
			if ($store.Dataset) {
				if (-not $stores.ContainsKey($store.Dataset)) {
					$vs = $null
					try { $vs = @(Get-OS7VersionStore -Dataset $store.Dataset) | Select-Object -First 1 } catch { $vs = $null }
					$stores[$store.Dataset] = $vs
				}
				$snap = $stores[$store.Dataset]
			}
			$users = @(if ($u.VolumeUsers.ContainsKey($vn)) { $u.VolumeUsers[$vn] })
			$labels = Get-OS7ContainerField $v 'Labels'
			$o = [pscustomobject]@{
				PSTypeName        = 'OS7.ContainerVolume'
				Name              = $vn
				Anonymous         = [bool]($vn -match '^[0-9a-f]{64}$')
				InUse             = ($users.Count -gt 0)
				UsedBy            = $users
				Size              = if ($u.VolumeSize.ContainsKey($vn)) { $u.VolumeSize[$vn] } else { $null }
				Application       = Get-OS7ContainerLabel -Labels $labels -Key 'com.docker.compose.project'
				Dataset           = $store.Dataset
				InBootEnvironment = $store.InBootEnvironment
				BackedUp          = $store.BackedUp
				Snapshots         = if ($snap) { $snap.Snapshots } else { 0 }
				LatestSnapshot    = if ($snap) { $snap.Newest } else { $null }
				Reason            = $(
					if (-not $store.Dataset) { 'It is not on a ZFS dataset, so no snapshot holds it.' }
					elseif ($store.InBootEnvironment) { "It is inside the boot environment ($($store.Dataset)), so a rollback would revert it and no backup policy may follow it. Install-OS7ContainerHost puts the engine's data outside." }
					elseif ($null -eq $store.BackedUp) { "Whether $($store.Dataset) is backed up could not be read as this account: the backup policy is root's." }
					elseif (-not $store.BackedUp) { "$($store.Dataset) is not in this machine's backup policy." }
					else { $null })
				Mountpoint        = $mp
				Driver            = Get-OS7ContainerField $v 'Driver'
				Created           = Get-OS7ContainerField $v 'CreatedAt'
			}
			if ($withVersions) {
				$o | Add-Member -NotePropertyName Versions -NotePropertyValue @(
					Get-OS7FileVersion -Path $mp -DistinctOnly -IncludeCurrent |
						Select-Object Created, Modified, Length, IsCurrent, Exists, SnapshotName)
			}
			$o
		}
	}
}

function Remove-OS7ContainerVolume {
	<#
	.SYNOPSIS
		Removes a volume and the data in it. One a container uses is refused.

	.DESCRIPTION
		This is the one removal on this surface that deletes a workload's DATA.
		The engine refuses it while any container — running or stopped — has
		the volume mounted. What is left afterwards is what the snapshots of
		the engine's dataset still hold, and the result names the newest one
		until the retention policy thins it away.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string]$Name
	)

	if (-not $PSCmdlet.ShouldProcess($Name, 'remove volume AND ITS DATA')) { return }
	Assert-OS7ContainerElevated -Cmdlet 'Remove-OS7ContainerVolume' -Because 'removes a volume through the engine, whose socket is root''s'
	$n = $Name
	$before = @(Get-OS7ContainerVolume -Name $n) | Select-Object -First 1
	$r = Remove-DockerVolume -Name $n -Confirm:$false
	$why = if ($before -and $before.LatestSnapshot) {
		"Its data is still in the snapshots of $($before.Dataset), newest $($before.LatestSnapshot), until retention thins them."
	}
	elseif ($before -and -not $before.BackedUp) { 'No snapshot held it: its data is gone.' }
	else { $null }
	[pscustomobject]@{ PSTypeName = 'OS7.ContainerRemoval'; Kind = 'Volume'; Name = $n; Outcome = $r.Outcome; Reason = $why }
}

function Get-OS7ContainerNetwork {
	<#
	.SYNOPSIS
		The networks the engine has made: their address range, and which
		containers are attached.

	.DESCRIPTION
		`Builtin` marks the engine's own three — bridge, host, none — which it
		will not remove. The address range matters more than it looks: the
		engine's default once cut a machine off from the SSH session it was
		being administered over (CONTAINERS-PLAN M-CT10).
	#>
	[CmdletBinding()]
	[OutputType('OS7.ContainerNetwork')]
	param([Parameter(Position = 0)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')][string[]]$Name)

	$wanted = $Name
	Invoke-OS7ContainerRead -Cmdlet 'Get-OS7ContainerNetwork' -Read {
		$u = Get-OS7ContainerUsage
		foreach ($n in @(Get-DockerNetwork)) {
			$nn = [string](Get-OS7ContainerField $n 'Name')
			if ($wanted -and $wanted -notcontains $nn) { continue }
			$cfg = @(@(Get-OS7ContainerField $n 'IPAM.Config') | Where-Object { $_ })
			$users = @(if ($u.NetworkUsers.ContainsKey($nn)) { $u.NetworkUsers[$nn] })
			[pscustomobject]@{
				PSTypeName  = 'OS7.ContainerNetwork'
				Name        = $nn
				Driver      = Get-OS7ContainerField $n 'Driver'
				Builtin     = ($nn -in 'bridge', 'host', 'none')
				Subnet      = @($cfg | ForEach-Object { Get-OS7ContainerField $_ 'Subnet' } | Where-Object { $_ })
				Gateway     = @($cfg | ForEach-Object { Get-OS7ContainerField $_ 'Gateway' } | Where-Object { $_ })
				Internal    = [bool](Get-OS7ContainerField $n 'Internal')
				InUse       = ($users.Count -gt 0)
				UsedBy      = $users
				Application = Get-OS7ContainerLabel -Labels (Get-OS7ContainerField $n 'Labels') -Key 'com.docker.compose.project'
				Id          = Get-OS7ContainerField $n 'Id'
			}
		}
	}
}

function Remove-OS7ContainerNetwork {
	<#
	.SYNOPSIS
		Removes a network the engine made. Its own three, and one a container is
		attached to, are refused in the engine's words.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
		[string]$Name
	)

	if (-not $PSCmdlet.ShouldProcess($Name, 'remove network')) { return }
	Assert-OS7ContainerElevated -Cmdlet 'Remove-OS7ContainerNetwork' -Because 'removes a network through the engine, whose socket is root''s'
	$r = Remove-DockerNetwork -Name $Name -Confirm:$false
	[pscustomobject]@{ PSTypeName = 'OS7.ContainerRemoval'; Kind = 'Network'; Name = $Name; Outcome = $r.Outcome; Reason = $null }
}

# =============================================================================
# Applications — Compose projects, operated as one
# =============================================================================

function Get-OS7ContainerApplication {
	<#
	.SYNOPSIS
		The applications on this machine — Compose projects, read off their
		containers' labels — and whether each one is whole.

	.DESCRIPTION
		Compose has no API (CT4); what it leaves on the engine is a label on
		every container it made. So an application is the set of containers
		that carry the same project label, and it can be started and stopped
		through the engine as one without the compose CLI.

		  Running          every container is running and none needs attention
		  Partial          some are running and some are not
		  Stopped          none is running
		  NeedsAttention   at least one container needs attention (CT6) — its
		                   word is in that container's own row

	.EXAMPLE
		Get-OS7ContainerApplication | Format-Table Name, State, Running, Total
	#>
	[CmdletBinding()]
	[OutputType('OS7.ContainerApplication')]
	param([Parameter(Position = 0)][string[]]$Name)

	$all = @(Get-OS7Container -All)
	$groups = $all | Where-Object { $_.Application } | Group-Object Application | Sort-Object Name
	foreach ($g in $groups) {
		if ($Name -and $Name -notcontains $g.Name) { continue }
		$members = @($g.Group)
		$running = @($members | Where-Object { $_.State -in 'Running', 'Starting', 'Unhealthy' }).Count
		$attention = @($members | Where-Object NeedsAttention)
		$state = if ($attention.Count) { 'NeedsAttention' }
		elseif ($running -eq $members.Count) { 'Running' }
		elseif ($running -eq 0) { 'Stopped' }
		else { 'Partial' }
		$first = $members[0]
		[pscustomobject]@{
			PSTypeName       = 'OS7.ContainerApplication'
			Name             = $g.Name
			State            = $state
			NeedsAttention   = ($attention.Count -gt 0)
			Reason           = $(if ($attention.Count) { "$(($attention | ForEach-Object { "$($_.Name): $($_.State)" }) -join '; ')" } else { $null })
			Running          = $running
			Total            = $members.Count
			Services         = @($members | ForEach-Object Service | Where-Object { $_ } | Sort-Object -Unique)
			Containers       = @($members | ForEach-Object Name)
			WorkingDirectory = Get-OS7ContainerLabel -Labels $first.Labels -Key 'com.docker.compose.project.working_dir'
			ConfigFiles      = Get-OS7ContainerLabel -Labels $first.Labels -Key 'com.docker.compose.project.config_files'
		}
	}
}

function Get-OS7ContainerStartOrder {
	<#
	.SYNOPSIS
		Internal. An application's containers in the order their depends_on
		labels require: what a service depends on starts first.

	.DESCRIPTION
		A cycle, or a dependency on a service that has no container here, does
		not stop the start: the containers it touches are started last, in
		name order, and the order is reported. Compose refuses a cycle at `up`,
		so a cycle on a running machine means labels somebody edited.
	#>
	param([Parameter(Mandatory)][object[]]$Containers)

	$byService = @{}
	foreach ($c in $Containers) {
		$svc = if ($c.Service) { [string]$c.Service } else { [string]$c.Name }
		if (-not $byService.ContainsKey($svc)) { $byService[$svc] = [System.Collections.Generic.List[object]]::new() }
		$byService[$svc].Add($c)
	}
	$done = [System.Collections.Generic.HashSet[string]]::new()
	$order = [System.Collections.Generic.List[object]]::new()
	$progress = $true
	while ($done.Count -lt $byService.Count -and $progress) {
		$progress = $false
		foreach ($svc in ($byService.Keys | Sort-Object)) {
			if ($done.Contains($svc)) { continue }
			$deps = @($byService[$svc] | ForEach-Object { @($_.DependsOn) } | Where-Object { $_ -and $byService.ContainsKey($_) } | Sort-Object -Unique)
			if (@($deps | Where-Object { -not $done.Contains($_) }).Count -eq 0) {
				foreach ($c in ($byService[$svc] | Sort-Object Name)) { $order.Add($c) }
				$null = $done.Add($svc)
				$progress = $true
			}
		}
	}
	foreach ($svc in ($byService.Keys | Sort-Object)) {
		if (-not $done.Contains($svc)) { foreach ($c in ($byService[$svc] | Sort-Object Name)) { $order.Add($c) } }
	}
	return $order.ToArray()
}

function Invoke-OS7ContainerApplicationAction {
	<#
	.SYNOPSIS
		Internal. Starts or stops every container of one application, in order,
		and reports each.
	#>
	param(
		[Parameter(Mandatory)][string]$Cmdlet,
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][ValidateSet('Start', 'Stop')][string]$Action
	)

	Assert-OS7ContainerElevated -Cmdlet $Cmdlet -Because "$($Action.ToLower())s an application's containers through the engine, whose socket is root's"
	$members = @(Get-OS7Container -All | Where-Object Application -EQ $Name)
	if ($members.Count -eq 0) {
		throw [System.Management.Automation.ItemNotFoundException]::new(
			"No container on this machine carries the application label '$Name'. Get-OS7ContainerApplication lists the applications.")
	}
	$order = @(Get-OS7ContainerStartOrder -Containers $members)
	# Stopping goes the other way round: what others depend on stops last.
	if ($Action -eq 'Stop') { [array]::Reverse($order) }
	$step = 0
	foreach ($c in $order) {
		$step++
		$cn = [string]$c.Name
		$r = if ($Action -eq 'Start') {
			Invoke-OS7ContainerAction -Cmdlet $Cmdlet -Container $cn -Because 'starts a container' -Act { Start-DockerContainer -Name $cn -Confirm:$false }
		}
		else {
			Invoke-OS7ContainerAction -Cmdlet $Cmdlet -Container $cn -Because 'stops a container' -Act { Stop-DockerContainer -Name $cn -Confirm:$false }
		}
		$r | Add-Member -NotePropertyName Application -NotePropertyValue $Name
		$r | Add-Member -NotePropertyName Step -NotePropertyValue $step
		$r
	}
}

function Start-OS7ContainerApplication {
	<#
	.SYNOPSIS
		Starts every container of an application, dependencies first, and says
		what each is doing afterwards.

	.DESCRIPTION
		Through the engine, not through compose: what a service depends on is
		started before it (its depends_on label), but this does not WAIT for a
		dependency to be healthy the way `docker compose up` can. Each result
		carries that container's state right afterwards, so one that came up
		and died reads as what it is.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name)

	if (-not $PSCmdlet.ShouldProcess($Name, 'start application')) { return }
	Invoke-OS7ContainerApplicationAction -Cmdlet 'Start-OS7ContainerApplication' -Name $Name -Action Start
}

function Stop-OS7ContainerApplication {
	<#
	.SYNOPSIS
		Stops every container of an application, dependants first.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][string]$Name)

	if (-not $PSCmdlet.ShouldProcess($Name, 'stop application')) { return }
	Invoke-OS7ContainerApplicationAction -Cmdlet 'Stop-OS7ContainerApplication' -Name $Name -Action Stop
}

# =============================================================================
# Clean-up — what is unused, shown before anything is removed
# =============================================================================

function Get-OS7ContainerUnused {
	<#
	.SYNOPSIS
		What a clean-up would remove, each item with its size and why it
		counts as unused. Removes nothing.

	.DESCRIPTION
		THE PREVIEW IS THE LIST THAT GETS ACTED ON. Remove-OS7ContainerUnused
		takes these objects and removes exactly them, by Id, checking each is
		still unused first. The engine's prune endpoints were not used,
		because they decide again at the moment of removal by rules of their
		own, and a preview computed by a second copy of those rules is #66's
		shape: nearly right, and different on the day it matters.

		`Recommended` is OS/7's judgement of what is SAFE to clean up, and the
		window pre-selects by it:

		  Image, dangling        yes — no name, nothing uses it
		  Image, tagged unused   yes — it can be pulled again
		  Network, unused        yes — the engine made it and nothing is on it
		  Volume, anonymous      yes — Docker's own prune default; it holds
		                         data, which the engine's snapshots keep for a
		                         while, and the Reason says so
		  Container, not running NO — removing it deletes its writable layer
		                         and its configuration
		  Volume, named unused   NO, and only listed with -IncludeNamedVolumes
		                         — a named volume is somebody's data on purpose

	.EXAMPLE
		Get-OS7ContainerUnused | Format-Table Kind, Name, Size, Recommended

	.EXAMPLE
		Get-OS7ContainerUnused | Where-Object Recommended | Remove-OS7ContainerUnused
	#>
	[CmdletBinding()]
	[OutputType('OS7.ContainerUnused')]
	param([switch]$IncludeNamedVolumes)

	$named = [bool]$IncludeNamedVolumes
	Invoke-OS7ContainerRead -Cmdlet 'Get-OS7ContainerUnused' -Read {
		$u = Get-OS7ContainerUsage
		$item = {
			param($kind, $name, $id, $size, $recommended, $reason)
			[pscustomobject]@{
				PSTypeName = 'OS7.ContainerUnused'; Kind = $kind; Name = $name; Id = $id
				Size = $size; Recommended = $recommended; Reason = $reason
			}
		}
		foreach ($c in $u.Containers) {
			$status = [string](Get-OS7ContainerField $c 'State')
			if ($status -in 'running', 'paused', 'restarting', 'removing') { continue }
			$id = [string](Get-OS7ContainerField $c 'Id')
			& $item 'Container' ([string]$c.Name) $id $(if ($u.ContainerSize.ContainsKey($id)) { $u.ContainerSize[$id] } else { $null }) $false `
				"It is $status. Removing it deletes what it wrote outside its volumes, and its configuration."
		}
		foreach ($i in @(Get-DockerImage)) {
			$id = [string](Get-OS7ContainerField $i 'Id')
			if ($u.ImageUsers.ContainsKey($id)) { continue }
			$tags = @(@(Get-OS7ContainerField $i 'RepoTags') | Where-Object { $_ -and $_ -ne '<none>:<none>' })
			$label = if ($tags.Count) { $tags[0] } else { "<none> ($($id.Replace('sha256:', '').Substring(0, 12)))" }
			& $item 'Image' $label $id $(if ($u.ImageSize.ContainsKey($id)) { $u.ImageSize[$id] } else { Get-OS7ContainerField $i 'Size' }) $true `
				$(if ($tags.Count) { 'No container uses it. It can be pulled again.' } else { 'It has no name and no container uses it.' })
		}
		foreach ($v in @(Get-DockerVolume)) {
			$vn = [string](Get-OS7ContainerField $v 'Name')
			if ($u.VolumeUsers.ContainsKey($vn)) { continue }
			$anon = [bool]($vn -match '^[0-9a-f]{64}$')
			if (-not $anon -and -not $named) { continue }
			& $item 'Volume' $vn $vn $(if ($u.VolumeSize.ContainsKey($vn)) { $u.VolumeSize[$vn] } else { $null }) $anon `
				$(if ($anon) { 'No container uses this anonymous volume. It holds data; snapshots of the engine''s dataset keep it until retention thins them.' }
					else { 'No container uses it, and it is NAMED: somebody kept this data on purpose.' })
		}
		foreach ($n in @(Get-DockerNetwork)) {
			$nn = [string](Get-OS7ContainerField $n 'Name')
			if ($nn -in 'bridge', 'host', 'none' -or $u.NetworkUsers.ContainsKey($nn)) { continue }
			& $item 'Network' $nn ([string](Get-OS7ContainerField $n 'Id')) $null $true 'No container is attached to it.'
		}
	}
}

function Remove-OS7ContainerUnused {
	<#
	.SYNOPSIS
		Removes exactly the items Get-OS7ContainerUnused listed — each one
		checked again first — and says what happened to every one.

	.DESCRIPTION
		  Removed          gone, and asked back
		  NoLongerUnused   something started using it since the preview; kept
		  Refused          the engine refused, in its own words
		  Gone             it was already gone

		The order is containers, then images, then volumes, then networks, so
		that an image freed by removing its container in the same run is
		removable — which is why the re-check reads the engine once more
		before each kind.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param([Parameter(Mandatory, ValueFromPipeline)][object[]]$InputObject)

	begin { $items = [System.Collections.Generic.List[object]]::new() }
	process { foreach ($i in $InputObject) { if ($null -ne $i) { $items.Add($i) } } }
	end {
		if ($items.Count -eq 0) { return }
		if (-not $PSCmdlet.ShouldProcess("$($items.Count) unused item(s)", 'remove')) { return }
		Assert-OS7ContainerElevated -Cmdlet 'Remove-OS7ContainerUnused' -Because 'removes containers, images, volumes and networks through the engine, whose socket is root''s'
		$named = [bool](@($items | Where-Object { (Get-OS7ContainerField $_ 'Kind') -eq 'Volume' -and "$(Get-OS7ContainerField $_ 'Id')" -notmatch '^[0-9a-f]{64}$' }).Count)
		foreach ($kind in 'Container', 'Image', 'Volume', 'Network') {
			$mine = @($items | Where-Object { (Get-OS7ContainerField $_ 'Kind') -eq $kind })
			if ($mine.Count -eq 0) { continue }
			$now = @(Get-OS7ContainerUnused -IncludeNamedVolumes:$named | Where-Object Kind -EQ $kind)
			foreach ($m in $mine) {
				$id = [string](Get-OS7ContainerField $m 'Id')
				$name = [string](Get-OS7ContainerField $m 'Name')
				$size = Get-OS7ContainerField $m 'Size'
				$res = { param($o, $why) [pscustomobject]@{ PSTypeName = 'OS7.ContainerRemoval'; Kind = $kind; Name = $name; Outcome = $o; Size = $size; Reason = $why } }
				if (-not ($now | Where-Object Id -EQ $id)) {
					& $res 'NoLongerUnused' 'It is no longer unused — or no longer there — so it was left alone.'
					continue
				}
				try {
					switch ($kind) {
						'Container' { $null = Remove-DockerContainer -Name $name -Confirm:$false }
						# -Force, and only here: the re-check above found NO container
						# using it, so what Force overrides is the engine's refusal
						# to delete by Id an image that carries several tags.
						'Image' { $null = Remove-DockerImage -Name $id -Force -Confirm:$false }
						'Volume' { $null = Remove-DockerVolume -Name $id -Confirm:$false }
						'Network' { $null = Remove-DockerNetwork -Name $id -Confirm:$false }
					}
					& $res 'Removed' $null
				}
				catch [System.Management.Automation.ItemNotFoundException] { & $res 'Gone' $null }
				catch { & $res 'Refused' $_.Exception.Message }
			}
		}
	}
}

# =============================================================================
# Creating a container — the dialog the owner asked for in v1 (2026-10-30)
# =============================================================================

function ConvertFrom-OS7PortSpec {
	<#
	.SYNOPSIS
		Internal. `[address:]hostport:containerport[/tcp|udp]` as a binding, or
		a refusal that shows the shape.

	.DESCRIPTION
		Docker's own syntax, because that is what an administrator types from
		memory — and with Docker's meaning: no address is EVERY address. The
		result says so in CT8's words, so nobody learns it afterwards.
	#>
	param([Parameter(Mandatory)][string]$Spec)

	$m = [regex]::Match($Spec.Trim(), '^(?:(?<ip>\d{1,3}(?:\.\d{1,3}){3}|\[[0-9A-Fa-f:]+\]):)?(?<host>\d{1,5}):(?<ctr>\d{1,5})(?:/(?<proto>tcp|udp))?$')
	if (-not $m.Success) {
		throw [System.ArgumentException]::new(
			"'$Spec' is not a port. Write it as hostport:containerport, optionally with the address " +
			"to listen on and the protocol: 8080:80, 127.0.0.1:8080:80, 5353:53/udp.")
	}
	$hp = [int]$m.Groups['host'].Value; $cp = [int]$m.Groups['ctr'].Value
	foreach ($p in $hp, $cp) {
		if ($p -lt 1 -or $p -gt 65535) { throw [System.ArgumentException]::new("'$Spec': $p is not a port number (1-65535).") }
	}
	$ip = $m.Groups['ip'].Value.Trim('[', ']')
	$proto = if ($m.Groups['proto'].Success) { $m.Groups['proto'].Value } else { 'tcp' }
	$words = ConvertTo-OS7ContainerPort -ContainerPort "$cp/$proto" -HostIp $ip -HostPort "$hp"
	[pscustomobject]@{
		ContainerPort = $cp; Protocol = $proto; HostPort = $hp; HostIp = $ip
		Reach = $words.Reach; Text = $words.Text
	}
}

function ConvertFrom-OS7VolumeSpec {
	<#
	.SYNOPSIS
		Internal. `volume:/path/in/container[:ro]` as a mount, or a refusal.

	.DESCRIPTION
		NAMED VOLUMES ONLY, and that is CT3 rather than a missing feature: a
		volume lives on the engine's dataset, which is outside the boot
		environment and in the backup policy. A host path can be anywhere —
		inside the boot environment, where a rollback reverts it — and the
		dialog would be the easiest way on this machine to put data there.
	#>
	param([Parameter(Mandatory)][string]$Spec)

	$m = [regex]::Match($Spec.Trim(), '^(?<name>[^:]+):(?<path>/[^:]*)(?::(?<mode>ro|rw))?$')
	if (-not $m.Success) {
		throw [System.ArgumentException]::new(
			"'$Spec' is not a volume. Write it as name:/path/in/container, optionally :ro — data:/var/lib/postgresql/data.")
	}
	$name = $m.Groups['name'].Value
	if ($name.StartsWith('/') -or $name.StartsWith('.') -or $name.StartsWith('~')) {
		throw [System.ArgumentException]::new(
			"'$Spec' mounts a path of this machine. OS/7 gives a container NAMED volumes only: they live on " +
			"the engine's dataset, outside the boot environment and in the backup policy, and a host path " +
			'can be anywhere — including inside the boot environment, where a rollback reverts it.')
	}
	if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
		throw [System.ArgumentException]::new("'$name' is not a volume name: letters, digits, '_', '.' and '-', starting with a letter or digit.")
	}
	[pscustomobject]@{ Name = $name; Target = $m.Groups['path'].Value; ReadOnly = ($m.Groups['mode'].Value -eq 'ro') }
}

function New-OS7Container {
	<#
	.SYNOPSIS
		Creates a container from an image — pulling it if this machine does not
		have it — and starts it, or with -ValidateOnly says what it WOULD do.

	.DESCRIPTION
		The dialog's whole job, as a cmdlet (G7). What is decided here and not
		in the window:

		  * the port syntax, and who can reach each port, in CT8's words;
		  * NAMED volumes only, because a volume is on the backed-up dataset
		    and a host path can be inside the boot environment (CT3);
		  * that the name is free, the host port is not already published by
		    another container, and each environment name is one.

		-ValidateOnly answers all of that WITHOUT creating anything, as an
		object whose `Problems` is empty when the creation would go ahead.
		The dialog's last page is that object.

		THE ENVIRONMENT IS NEVER ECHOED. Its names are in the result; its
		values are not, because they are where passwords go (M-CT6).

	.PARAMETER Port
		`8080:80`, `127.0.0.1:8080:80`, `5353:53/udp`. Without an address the
		port is open on EVERY network, as Docker means it — and the result
		says so.

	.PARAMETER Volume
		`data:/var/lib/data`, optionally `:ro`. A volume that does not exist
		is created by the engine.

	.EXAMPLE
		New-OS7Container -Name web -Image nginx:1.27 -Port 127.0.0.1:8080:80 -Volume web-data:/usr/share/nginx/html

	.EXAMPLE
		New-OS7Container -Name db -Image postgres:17 -Environment @{ POSTGRES_PASSWORD = $pw } -Volume pg:/var/lib/postgresql/data -ValidateOnly
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[Parameter(Mandatory)][string]$Image,
		[string[]]$Port,
		[string[]]$Volume,
		[System.Collections.IDictionary]$Environment,
		[ValidateSet('no', 'always', 'unless-stopped', 'on-failure')][string]$RestartPolicy = 'unless-stopped',
		[switch]$NoStart,
		[switch]$ValidateOnly
	)

	Import-OS7DockerLayer
	$problems = [System.Collections.Generic.List[string]]::new()
	if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
		$problems.Add("'$Name' is not a container name: letters, digits, '_', '.' and '-', starting with a letter or digit.")
	}
	$ref = $null
	if ($Image -notmatch '^[A-Za-z0-9][A-Za-z0-9._/:@+-]*$') {
		$problems.Add("'$Image' is not an image reference: nginx, nginx:1.27, ghcr.io/org/app:2.")
	}
	else { $ref = Split-DockerReference -Reference $Image }
	$ports = [System.Collections.Generic.List[object]]::new()
	foreach ($p in @($Port | Where-Object { $_ })) {
		try { $ports.Add((ConvertFrom-OS7PortSpec -Spec $p)) } catch { $problems.Add($_.Exception.Message) }
	}
	$mounts = [System.Collections.Generic.List[object]]::new()
	foreach ($v in @($Volume | Where-Object { $_ })) {
		try { $mounts.Add((ConvertFrom-OS7VolumeSpec -Spec $v)) } catch { $problems.Add($_.Exception.Message) }
	}
	$envNames = @()
	if ($Environment) {
		$envNames = @($Environment.Keys | ForEach-Object { [string]$_ } | Sort-Object)
		foreach ($k in $envNames) {
			if ($k -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $problems.Add("'$k' is not an environment variable name.") }
		}
	}
	$dupPorts = @($ports | Group-Object { "$($_.HostPort)/$($_.Protocol)" } | Where-Object Count -GT 1)
	foreach ($d in $dupPorts) { $problems.Add("Host port $($d.Name) is given twice.") }

	# What the engine knows: the name, the image, the volumes, the ports taken.
	$imagePresent = $false
	$volumesExisting = @()
	if ($ref) {
		$n = $Name; $r = $ref
		$facts = Invoke-OS7ContainerRead -Cmdlet 'New-OS7Container' -Read {
			$taken = $false
			try { $null = Get-DockerContainer -Name $n; $taken = $true } catch [System.Management.Automation.ItemNotFoundException] { $taken = $false }
			$present = $false
			try { $null = Get-DockerImage -Name $r.Reference; $present = $true } catch [System.Management.Automation.ItemNotFoundException] { $present = $false }
			$vols = @(Get-DockerVolume | ForEach-Object { [string](Get-OS7ContainerField $_ 'Name') })
			$published = @(foreach ($c in @(Get-DockerContainer -All)) {
					foreach ($pp in @(Get-OS7ContainerField $c 'Ports')) {
						if ($null -eq $pp -or $null -eq (Get-OS7ContainerField $pp 'PublicPort')) { continue }
						[pscustomobject]@{ Container = [string]$c.Name; HostPort = [int](Get-OS7ContainerField $pp 'PublicPort')
							Protocol = [string](Get-OS7ContainerField $pp 'Type') }
					}
				})
			[pscustomobject]@{ Taken = $taken; Present = $present; Volumes = $vols; Published = $published }
		}
		if ($facts.Taken) { $problems.Add("A container named '$Name' already exists.") }
		$imagePresent = $facts.Present
		$volumesExisting = @($facts.Volumes)
		foreach ($p in $ports) {
			$clash = @($facts.Published | Where-Object { $_.HostPort -eq $p.HostPort -and $_.Protocol -eq $p.Protocol } | Select-Object -First 1)
			if ($clash.Count) { $problems.Add("Host port $($p.HostPort)/$($p.Protocol) is already published by container '$($clash[0].Container)'.") }
		}
	}

	$plan = [pscustomobject]@{
		PSTypeName       = 'OS7.ContainerPlan'
		Name             = $Name
		Image            = if ($ref) { $ref.Reference } else { $Image }
		ImagePresent     = $imagePresent
		Ports            = @($ports | ForEach-Object Text)
		Reachable        = if ($ports.Count) { ($ports | ForEach-Object Text) -join '; ' } else { 'publishes no port' }
		Volumes          = @($mounts | ForEach-Object {
				'{0} → {1}{2} ({3})' -f $_.Name, $_.Target, $(if ($_.ReadOnly) { ' read-only' } else { '' }),
				$(if ($volumesExisting -contains $_.Name) { 'existing volume' } else { 'new volume' }) })
		EnvironmentNames = $envNames
		RestartPolicy    = $RestartPolicy
		Start            = -not $NoStart
		Problems         = @($problems)
		Validated        = ($problems.Count -eq 0)
	}
	if ($ValidateOnly) { return $plan }

	if ($problems.Count) {
		throw [System.ArgumentException]::new("New-OS7Container did not create '$Name':`n  " + ($problems -join "`n  "))
	}
	if (-not $PSCmdlet.ShouldProcess($Name, "create container from $($ref.Reference)")) { return $plan }
	Assert-OS7ContainerElevated -Cmdlet 'New-OS7Container' -Because 'creates a container through the engine, whose socket is root''s'

	$pull = $null
	if (-not $imagePresent) {
		Write-OS7Step "pulling $($ref.Reference)"
		$pull = Receive-DockerImage -Reference $ref.Reference -Confirm:$false
	}
	$envTable = [ordered]@{}
	if ($Environment) { foreach ($k in $envNames) { $envTable[$k] = [string]$Environment[$k] } }
	$made = New-DockerContainer -Name $Name -Image $ref.Reference -RestartPolicy $RestartPolicy `
		-PortBinding @($ports) -Environment $envTable `
		-Mount @($mounts | ForEach-Object { [pscustomobject]@{ Type = 'volume'; Source = $_.Name; Target = $_.Target; ReadOnly = $_.ReadOnly } }) `
		-Label @{ 'org.os7.created-by' = 'New-OS7Container' } -Confirm:$false
	Write-OS7Step "created $Name"

	$outcome = 'Created'
	if (-not $NoStart) {
		$s = Start-DockerContainer -Name $Name -Confirm:$false
		$outcome = $s.Outcome
	}
	$after = ConvertTo-OS7Container -Inspect (Get-DockerContainer -Name $Name)
	[pscustomobject]@{
		PSTypeName = 'OS7.ContainerAction'
		Name       = $Name
		Action     = 'Create'
		Outcome    = $outcome
		State      = $after.State
		Reason     = $after.Reason
		Reachable  = $after.Reachable
		Pulled     = if ($pull) { $pull.Outcome } else { 'AlreadyPresent' }
		Warnings   = @($made.Warnings)
	}
}

# =============================================================================
# Who may operate containers without elevating — O-CT3, chosen 2026-10-30
# =============================================================================

function Get-OS7ContainerOperator {
	<#
	.SYNOPSIS
		The accounts that may operate containers without elevating — each of
		them root-equivalent on this machine, which is what they were chosen as.

	.DESCRIPTION
		They are the members of the group that owns the engine's socket. A
		member added in this session holds the socket from its NEXT login.
	#>
	[CmdletBinding()]
	[OutputType('OS7.ContainerOperator')]
	param()

	Import-OS7DockerLayer
	$m = Get-DockerSocketMember
	if (-not $m) { return }
	foreach ($u in $m.Members) {
		[pscustomobject]@{
			PSTypeName = 'OS7.ContainerOperator'
			UserName   = $u
			Group      = $m.Group
			Reason     = 'Holds the container engine''s socket: root-equivalent on this machine.'
		}
	}
}

function Add-OS7ContainerOperator {
	<#
	.SYNOPSIS
		Lets a local account operate containers without elevating. That account
		becomes ROOT-EQUIVALENT on this machine.

	.DESCRIPTION
		CONTAINERS-PLAN O-CT3, as an explicit choice. Holding the engine's
		socket means being able to start a container with this machine's root
		filesystem mounted, and reading every container's environment (M-CT6).
		That is why OS/7 adds nobody by itself, why the window never asks to,
		and why this is ConfirmImpact High.

		It takes effect at the account's next login.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param([Parameter(Mandatory, Position = 0)][string]$UserName)

	Assert-OS7Elevated -Cmdlet 'Add-OS7ContainerOperator' -Because 'puts an account in the group that owns the container engine''s socket'
	if (-not (Get-OS7RdpLocalUserExists -Name $UserName)) {
		throw [System.ArgumentException]::new("There is no local account '$UserName' on this machine.")
	}
	if (-not $PSCmdlet.ShouldProcess($UserName, 'make a container operator (root-equivalent)')) { return }
	Import-OS7DockerLayer
	$null = Add-DockerSocketMember -UserName $UserName -Confirm:$false
	Write-OS7Step "$UserName may operate containers from their next login, and is root-equivalent on this machine"
	Get-OS7ContainerOperator | Where-Object UserName -EQ $UserName
}

function Remove-OS7ContainerOperator {
	<#
	.SYNOPSIS
		Takes an account's container access away. A session it already has
		open keeps the access until it logs out.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory, Position = 0)][string]$UserName)

	Assert-OS7Elevated -Cmdlet 'Remove-OS7ContainerOperator' -Because 'takes an account out of the group that owns the container engine''s socket'
	if (-not $PSCmdlet.ShouldProcess($UserName, 'stop being a container operator')) { return }
	Import-OS7DockerLayer
	$null = Remove-DockerSocketMember -UserName $UserName -Confirm:$false
	Write-OS7Step "$UserName is no longer a container operator; a session already open keeps the group until it logs out"
}

# =============================================================================
# The host — the engine as a role (CT2), and the store it must stand on (CT3)
# =============================================================================

$script:OS7ContainerDataRoot = '/var/lib/docker'
$script:OS7ContainerImageRoot = '/var/lib/containerd'

function ConvertTo-OS7Ipv4Network {
	<#
	.SYNOPSIS
		Internal. '10.213.0.1/24' as its network's first and last address, as
		unsigned integers. $null for anything that is not IPv4 CIDR.
	#>
	param([Parameter(Mandatory)][string]$Cidr)

	$m = [regex]::Match($Cidr.Trim(), '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:/(\d{1,2}))?$')
	if (-not $m.Success) { return $null }
	$o = 1..4 | ForEach-Object { [uint32]$m.Groups[$_].Value }
	if (@($o | Where-Object { $_ -gt 255 }).Count) { return $null }
	$len = if ($m.Groups[5].Success) { [int]$m.Groups[5].Value } else { 32 }
	if ($len -gt 32) { return $null }
	[uint64]$addr = ([uint64]$o[0] -shl 24) + ([uint64]$o[1] -shl 16) + ([uint64]$o[2] -shl 8) + [uint64]$o[3]
	[uint64]$size = [uint64]1 -shl (32 - $len)
	[uint64]$first = $addr - ($addr % $size)
	[pscustomobject]@{ Text = $Cidr; First = $first; Last = $first + $size - 1; Length = $len }
}

function Get-OS7SshPeer {
	<#
	.SYNOPSIS
		Internal. The remote addresses of SSH sessions to this machine that are
		open right now, read from the kernel.

	.DESCRIPTION
		/proc/net/tcp and tcp6, ESTABLISHED (state 01) with local port 22.
		Not $SSH_CONNECTION, which sudo's env_reset removes — and the person
		this protects is precisely the one typing `sudo`. Not `ss`, because the
		kernel's table needs no program.

	.PARAMETER Table
		The kernel's tables. A parameter so check-container-logic.py can hand
		it a recorded one; nothing else passes it.
	#>
	param([string[]]$Table = @('/proc/net/tcp', '/proc/net/tcp6'))

	foreach ($f in $Table) {
		if (-not [System.IO.File]::Exists($f)) { continue }
		foreach ($line in ([System.IO.File]::ReadAllLines($f) | Select-Object -Skip 1)) {
			$c = $line.Trim() -split '\s+'
			if ($c.Count -lt 4 -or $c[3] -ne '01') { continue }
			$local = $c[1].Split(':'); $remote = $c[2].Split(':')
			if ([Convert]::ToInt32($local[1], 16) -ne 22) { continue }
			$hex = $remote[0]
			# IPv4 is 8 hex digits, little-endian; an IPv4-mapped IPv6 address
			# carries it in its last 8.
			if ($hex.Length -eq 32) {
				if ($hex.Substring(0, 24) -ne '0000000000000000FFFF0000') { continue }
				$hex = $hex.Substring(24)
			}
			if ($hex.Length -ne 8) { continue }
			$b = 0..3 | ForEach-Object { [Convert]::ToInt32($hex.Substring($_ * 2, 2), 16) }
			'{0}.{1}.{2}.{3}' -f $b[3], $b[2], $b[1], $b[0]
		}
	}
}

function Test-OS7ContainerRangeCollision {
	<#
	.SYNOPSIS
		Internal. CT7: the ranges the engine is about to take, against what this
		machine already reaches. Returns one sentence per collision.

	.DESCRIPTION
		Three things the engine's bridge must not overlap, measured on a bench
		where it did (M-CT10): an address of this machine, a route this machine
		has, and the peer of an SSH session open now — the administrator at the
		far end, who is the one cut off.
	#>
	param(
		[Parameter(Mandatory)][string[]]$Range,
		[string[]]$Address = @(),
		[string[]]$Route = @(),
		[string[]]$Peer = @()
	)

	$overlaps = { param($a, $b) $a.First -le $b.Last -and $b.First -le $a.Last }
	foreach ($r in $Range) {
		$rn = ConvertTo-OS7Ipv4Network -Cidr $r
		if (-not $rn) { "'$r' is not an IPv4 range."; continue }
		foreach ($set in @(@{ What = 'an address of this machine'; Items = $Address },
				@{ What = 'a route of this machine'; Items = $Route },
				@{ What = 'the address of an SSH session open now'; Items = $Peer })) {
			foreach ($x in @($set.Items)) {
				if (-not $x) { continue }
				$xn = ConvertTo-OS7Ipv4Network -Cidr $x
				if ($xn -and (& $overlaps $rn $xn)) { "$r overlaps $($set.What), $x." }
			}
		}
	}
}

function Test-OS7ProcessRoot {
	<#
	.SYNOPSIS
		Internal. Is this process's EFFECTIVE uid 0? $null when the kernel
		cannot be asked.

	.DESCRIPTION
		The question Assert-OS7Elevated asks, as a question rather than a
		refusal: Get-OS7ContainerHost has to tell Root from Operator without
		refusing either.
	#>
	param()
	$status = '/proc/self/status'
	if (-not [System.IO.File]::Exists($status)) { return $null }
	foreach ($line in [System.IO.File]::ReadAllLines($status)) {
		if (-not $line.StartsWith('Uid:')) { continue }
		$f = $line.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)
		if ($f.Count -ge 3) { return ($f[2] -eq '0') }
	}
	return $null
}

function Get-OS7ContainerHost {
	<#
	.SYNOPSIS
		Whether this machine runs a container engine, whether THIS session may
		talk to it, and whether its data stands where OS/7 needs it.

	.DESCRIPTION
		IT ANSWERS AS ANY USER. It is what the window asks first, to know
		whether to draw the engine's contents or to say that containers are
		administered as root and offer to sign in — so it must not itself be
		refused. Everything it can read without the socket (the datasets, the
		pool) it reads; what needs the socket is $null when the socket refused.

		  Access     Root       this process is root
		             Operator   it holds the socket through the group (O-CT3)
		             Denied     there is an engine and it may not talk to it
		             NoEngine   there is no engine socket on this machine

		  Layout     OS7        both stores on their own datasets, outside the
		                        boot environment (CT3)
		             Foreign    the engine was installed some other way — its
		                        store is in the boot environment, or on a
		                        dataset OS/7 does not list (O-CT7, M-CT8)
		             None       no engine data on this machine yet

	.EXAMPLE
		Get-OS7ContainerHost | Format-List
	#>
	[CmdletBinding()]
	[OutputType('OS7.ContainerHost')]
	param()

	Import-OS7DockerLayer
	$socket = Test-DockerSocketAccess
	$access = if ($null -eq $socket) { 'NoEngine' } elseif (-not $socket) { 'Denied' }
	elseif ((Test-OS7ProcessRoot) -eq $true) { 'Root' } else { 'Operator' }

	$ctx = Get-OS7ContainerBackupContext
	$data = Get-OS7ContainerStoreDataset -Path $script:OS7ContainerDataRoot -Datasets $ctx.Datasets -Covered $ctx.Covered
	$images = Get-OS7ContainerStoreDataset -Path $script:OS7ContainerImageRoot -Datasets $ctx.Datasets -Covered $ctx.Covered
	$present = [System.IO.Directory]::Exists($script:OS7ContainerDataRoot) -or [System.IO.Directory]::Exists($script:OS7ContainerImageRoot)
	$own = { param($s, $leaf) $s.Dataset -and -not $s.InBootEnvironment -and $s.Dataset -match "/DATA/lib/$leaf$" }
	$layout = if ((& $own $data 'docker') -and (& $own $images 'containerd')) { 'OS7' }
	elseif ($present -or $null -ne $socket) { 'Foreign' }
	else { 'None' }

	$pressure = $null
	try { $pressure = Get-OS7StoragePressure -WarningAction SilentlyContinue } catch { $pressure = $null }

	$engine = $null; $usage = $null; $bridge = $null; $attention = $null
	if ($socket) {
		try { $engine = Get-DockerEngine } catch { $engine = $null }
		try { $usage = Get-DockerDiskUsage } catch { $usage = $null }
		try {
			$b = @(Get-DockerNetwork -Filter @{ name = 'bridge' }) | Where-Object { (Get-OS7ContainerField $_ 'Name') -eq 'bridge' } | Select-Object -First 1
			$bridge = @(@(Get-OS7ContainerField $b 'IPAM.Config') | ForEach-Object { Get-OS7ContainerField $_ 'Subnet' } | Where-Object { $_ }) | Select-Object -First 1
		}
		catch { $bridge = $null }
		try { $attention = @(Get-OS7Container -All | Where-Object NeedsAttention).Count } catch { $attention = $null }
	}
	$config = $null
	try { $config = Get-DockerDaemonConfiguration } catch { $config = $null }
	$operators = @(Get-OS7ContainerOperator | ForEach-Object UserName)

	$reason = switch ($access) {
		'NoEngine' { 'There is no container engine on this machine. Install-OS7ContainerHost installs it, on datasets of its own.' }
		'Denied' { 'Containers are administered as root: the engine''s socket shows every container''s environment, passwords included.' }
		default {
			if ($layout -eq 'Foreign') {
				"The engine's data is not where OS/7 keeps it: $($script:OS7ContainerDataRoot) is on $($data.Dataset) and " +
				"$($script:OS7ContainerImageRoot) on $($images.Dataset). It was installed some other way than Install-OS7ContainerHost, " +
				'so a rollback can revert part of it and the backup does not reach it.'
			}
			elseif ($engine -and $engine.LoggingDriver -ne 'journald') { "The engine logs with '$($engine.LoggingDriver)', not to the journal, so a container's log goes when the container does." }
			elseif ($pressure -and $pressure.Level -ne 'Normal') { "The pool is $($pressure.Capacity)% full ($($pressure.Level)). Get-OS7ContainerUnused shows what a clean-up would free." }
			else { $null }
		}
	}

	[pscustomobject]@{
		PSTypeName           = 'OS7.ContainerHost'
		Access               = $access
		Layout               = $layout
		Reason               = $reason
		# The ELEVATED form, as #148 asks of every command a person is handed:
		# `Install-OS7ContainerHost` typed as a user is refused, and `sudo` in
		# front of a function does not work.
		Command              = $(if ($access -eq 'NoEngine') { "sudo pwsh -NoProfile -c 'Install-OS7ContainerHost'" } elseif ($access -eq 'Denied') { "sudo pwsh -NoProfile -c 'Get-OS7Container -All'" } else { $null })
		EngineVersion        = if ($engine) { $engine.Version } else { $null }
		ApiVersion           = if ($engine) { $engine.NegotiatedApiVersion } else { $null }
		StorageDriver        = if ($engine) { "$($engine.Driver)$(if ($engine.DriverType) { " ($($engine.DriverType))" })" } else { $null }
		LoggingDriver        = if ($engine) { $engine.LoggingDriver } else { $null }
		Containers           = if ($engine) { $engine.Containers } else { $null }
		ContainersRunning    = if ($engine) { $engine.ContainersRunning } else { $null }
		ContainersNeedingAttention = $attention
		Images               = if ($engine) { $engine.Images } else { $null }
		ImagesSize           = if ($usage) { $usage.LayersSize } else { $null }
		VolumesSize          = if ($usage) { $usage.VolumesSize } else { $null }
		DataDataset          = $data.Dataset
		DataBackedUp         = $data.BackedUp
		ImageDataset         = $images.Dataset
		ImageBackedUp        = $images.BackedUp
		Bridge               = $bridge
		AddressPools         = @(if ($config -and $config.Contains('default-address-pools')) { $config['default-address-pools'] | ForEach-Object { $_['base'] } })
		Pool                 = if ($pressure) { $pressure.Pool } else { $null }
		PoolCapacity         = if ($pressure) { $pressure.Capacity } else { $null }
		PoolLevel            = if ($pressure) { $pressure.Level } else { $null }
		Operators            = $operators
	}
}

function Install-OS7ContainerHost {
	<#
	.SYNOPSIS
		Makes this machine a container host: the engine's two stores on
		datasets of their own FIRST, its configuration second, the package
		third — and then asks every one of those back.

	.DESCRIPTION
		CONTAINERS-PLAN CT2, CT3 and CT7, in the order that IS the decision
		(M-CT8, M-CT9): Ubuntu's postinst creates a dataset of its own for
		/var/lib/docker and leaves the image store in the boot environment,
		unless both are ZFS mounts already when it runs.

		  1  refuse a machine where the engine was installed some other way
		     (O-CT7) — moving that is a migration, not this verb
		  2  refuse address ranges that overlap an address, a route, or the
		     SSH session this is typed over (CT7, M-CT10) — BEFORE anything is
		     written, because the engine takes the bridge the moment it starts
		  3  rpool/DATA/lib/docker (backed up: the volumes) and
		     rpool/DATA/lib/containerd (NOT backed up: images can be pulled
		     again, and an hourly snapshot of them holds blocks against V15)
		  4  daemon.json: the bridge, the pools, and the journal as log driver
		  5  the package, from this machine's own sources
		  6  ask back: both stores on their datasets, the engine answering,
		     the journal its log driver, the bridge where it was put

		Run again on a host it made, it changes nothing and checks again.

	.PARAMETER Bridge
		The engine's default bridge, as its gateway address and prefix.
		CONTAINERS-PLAN O-CT6 is open on which range is best; these defaults
		are the ones measured on the bench, and the collision check is what
		makes any choice safe.

	.EXAMPLE
		Install-OS7ContainerHost

	.EXAMPLE
		Install-OS7ContainerHost -Bridge 100.64.0.1/24 -AddressPool 100.65.0.0/16
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.ContainerHostInstall')]
	param(
		[string]$Bridge = '10.213.0.1/24',
		[string]$AddressPool = '10.214.0.0/16',
		[ValidateRange(16, 28)][int]$PoolSubnetLength = 24
	)

	Assert-OS7Elevated -Cmdlet 'Install-OS7ContainerHost' -Because 'creates datasets, writes the engine''s configuration and installs packages'
	Import-OS7DockerLayer
	Import-OS7ZfsLayer

	$before = Get-OS7ContainerHost
	if ($before.Layout -eq 'Foreign') {
		throw [System.InvalidOperationException]::new(
			"This machine already has container engine data that OS/7 did not lay out: $($before.Reason) " +
			'Install-OS7ContainerHost will not install over it. Moving it is a migration (CONTAINERS-PLAN O-CT7).')
	}

	# 2. The ranges, against what this machine reaches, before anything is written.
	Import-OS7NetLayer
	$addresses = @(Get-NetLink | ForEach-Object { @($_.Addresses) } | Where-Object { $_ -and $_.Family -eq 'IPv4' -and $_.Address -notlike '127.*' } |
			ForEach-Object { "$($_.Address)/$($_.PrefixLength)" })
	$routes = @(Get-NetRoute | Where-Object { $_.Family -eq 'IPv4' -and -not $_.IsDefault -and $_.Destination -and $_.InterfaceName -ne 'docker0' } |
			ForEach-Object { $_.Destination })
	$peers = @(Get-OS7SshPeer | Sort-Object -Unique)
	$bridgeNet = ConvertTo-OS7Ipv4Network -Cidr $Bridge
	if (-not $bridgeNet) { throw [System.ArgumentException]::new("-Bridge '$Bridge' is not an IPv4 address with a prefix length, like 10.213.0.1/24.") }
	if ($before.Access -eq 'NoEngine') {
		$collisions = @(Test-OS7ContainerRangeCollision -Range @($Bridge, $AddressPool) -Address $addresses -Route $routes -Peer $peers)
		if ($collisions.Count) {
			throw [System.InvalidOperationException]::new(
				"Install-OS7ContainerHost refused before writing anything: the engine would take an address range " +
				"this machine already uses, and the bridge comes up the moment the engine starts (CONTAINERS-PLAN M-CT10):`n  " +
				($collisions -join "`n  ") + "`nChoose other ranges with -Bridge and -AddressPool.")
		}
	}
	if (-not $PSCmdlet.ShouldProcess('this machine', 'make it a container host')) { return }

	# 3. The stores, before the package (CT3).
	$stores = @(
		New-OS7ServiceDataset -Name 'docker' -MountPoint $script:OS7ContainerDataRoot -Backup $true -NoLayout -Confirm:$false
		New-OS7ServiceDataset -Name 'containerd' -MountPoint $script:OS7ContainerImageRoot -Backup $false -NoLayout -Confirm:$false
	)
	Write-OS7Step "stores: $(($stores | ForEach-Object Dataset) -join ', ')"

	# 4. The configuration the engine reads when it first starts.
	$null = Set-DockerDaemonConfiguration -Setting ([ordered]@{
			'bip'                   = $Bridge
			'default-address-pools' = @([ordered]@{ base = $AddressPool; size = $PoolSubnetLength })
			'log-driver'            = 'journald'
		}) -Confirm:$false
	Write-OS7Step 'daemon configuration written'

	# 5. The package — or, on a host this verb already made, a restart only if
	#    the configuration it reads changed.
	$packages = @()
	if ($before.Access -eq 'NoEngine') {
		$packages = @(Install-DockerEngine -Confirm:$false)
		Write-OS7Step "engine installed: $(($packages | ForEach-Object { "$($_.Package) $($_.Version)" }) -join ', ')"
	}
	else {
		$packages = @(Get-DockerPackage)
		if ($before.Bridge -and (ConvertTo-OS7Ipv4Network -Cidr $before.Bridge).First -ne $bridgeNet.First) {
			$null = Restart-DockerEngine -Confirm:$false
		}
	}

	# 6. ASK BACK. Every line above is a claim.
	$after = Get-OS7ContainerHost
	$checks = @(
		[pscustomobject]@{ Check = 'the engine answers this session'; Ok = ($after.Access -in 'Root', 'Operator'); Detail = $after.Access }
		[pscustomobject]@{ Check = "$($script:OS7ContainerDataRoot) is on its own dataset, outside the boot environment, backed up"; Ok = ($after.DataDataset -match '/DATA/lib/docker$' -and $after.DataBackedUp); Detail = "$($after.DataDataset) backed up: $($after.DataBackedUp)" }
		[pscustomobject]@{ Check = "$($script:OS7ContainerImageRoot) is on its own dataset, outside the boot environment, NOT backed up"; Ok = ($after.ImageDataset -match '/DATA/lib/containerd$' -and -not $after.ImageBackedUp); Detail = "$($after.ImageDataset) backed up: $($after.ImageBackedUp)" }
		[pscustomobject]@{ Check = 'the engine logs to the journal'; Ok = ($after.LoggingDriver -eq 'journald'); Detail = $after.LoggingDriver }
		[pscustomobject]@{ Check = "the bridge is $Bridge's network"; Ok = ($after.Bridge -and (ConvertTo-OS7Ipv4Network -Cidr $after.Bridge).First -eq $bridgeNet.First); Detail = $after.Bridge }
	)
	$result = [pscustomobject]@{
		PSTypeName = 'OS7.ContainerHostInstall'
		Outcome    = if ($before.Access -eq 'NoEngine') { 'Installed' } else { 'AlreadyInstalled' }
		Engine     = $after.EngineVersion
		Packages   = @($packages | ForEach-Object { "$($_.Package) $($_.Version)" })
		Layout     = $after.Layout
		Checks     = $checks
	}
	$bad = @($checks | Where-Object { -not $_.Ok })
	if ($bad.Count) {
		throw [System.InvalidOperationException]::new(
			"Install-OS7ContainerHost ran and the machine does not agree:`n  " +
			(($bad | ForEach-Object { "$($_.Check): $($_.Detail)" }) -join "`n  "))
	}
	return $result
}

# =============================================================================
# The verb table — what the window may ask, and the helper may run (CT5)
#
# ONE TABLE, TWO CHANNELS. The window sends a verb either straight to pwsh (an
# operator who holds the socket) or through pkexec to the root helper; both end
# here, so the two cannot drift apart. Each verb is exactly one cmdlet. Its
# CLASS decides which helper may run it: Read and Operate behind one polkit
# action that remembers the password for a few minutes, Destroy behind another
# that asks every time, and Install — making this machine a container host,
# which downloads and installs packages as root — behind a third that asks every
# time and says THAT in its dialog, rather than borrowing the removal's words.
#
# A verb's arguments are positional strings, validated by the cmdlet they reach;
# anything structured — a container to create, items to clean up — arrives as
# JSON on stdin, never on a command line, because a command line is readable by
# every account on the machine through /proc and an environment holds passwords.
# =============================================================================

$script:OS7ContainerVerbs = [ordered]@{
	'host'            = @{ Class = 'Read'; Cmdlet = 'Get-OS7ContainerHost'; Run = { param($a, $in) Get-OS7ContainerHost } }
	'attention'       = @{ Class = 'Read'; Cmdlet = 'Get-OS7Container'; Run = { param($a, $in) Get-OS7Container 6>$null } }
	'list'            = @{ Class = 'Read'; Cmdlet = 'Get-OS7Container'; Run = { param($a, $in) Get-OS7Container -All } }
	'log'             = @{ Class = 'Read'; Cmdlet = 'Get-OS7ContainerLog'; Run = { param($a, $in) Get-OS7ContainerLog -Name $a[0] -Tail $(if ($a.Count -gt 1) { [int]$a[1] } else { 200 }) } }
	'images'          = @{ Class = 'Read'; Cmdlet = 'Get-OS7ContainerImage'; Run = { param($a, $in) Get-OS7ContainerImage } }
	'images-check'    = @{ Class = 'Read'; Cmdlet = 'Get-OS7ContainerImage'; Run = { param($a, $in) Get-OS7ContainerImage -CheckUpdate } }
	'volumes'         = @{ Class = 'Read'; Cmdlet = 'Get-OS7ContainerVolume'; Run = { param($a, $in) Get-OS7ContainerVolume } }
	'volume-versions' = @{ Class = 'Read'; Cmdlet = 'Get-OS7ContainerVolume'; Run = { param($a, $in) Get-OS7ContainerVolume -Name $a[0] -IncludeVersions } }
	'networks'        = @{ Class = 'Read'; Cmdlet = 'Get-OS7ContainerNetwork'; Run = { param($a, $in) Get-OS7ContainerNetwork } }
	'apps'            = @{ Class = 'Read'; Cmdlet = 'Get-OS7ContainerApplication'; Run = { param($a, $in) Get-OS7ContainerApplication } }
	'unused'          = @{ Class = 'Read'; Cmdlet = 'Get-OS7ContainerUnused'; Run = { param($a, $in) Get-OS7ContainerUnused -IncludeNamedVolumes:($a.Count -gt 0 -and $a[0] -eq 'named') } }
	'validate'        = @{ Class = 'Read'; Cmdlet = 'New-OS7Container'; Input = $true; Run = { param($a, $in) $s = ConvertTo-OS7ContainerSpec -Json $in; New-OS7Container @s -ValidateOnly } }
	'start'           = @{ Class = 'Operate'; Cmdlet = 'Start-OS7Container'; Run = { param($a, $in) Start-OS7Container -Name $a[0] -Confirm:$false } }
	'stop'            = @{ Class = 'Operate'; Cmdlet = 'Stop-OS7Container'; Run = { param($a, $in) Stop-OS7Container -Name $a[0] -Confirm:$false } }
	'restart'         = @{ Class = 'Operate'; Cmdlet = 'Restart-OS7Container'; Run = { param($a, $in) Restart-OS7Container -Name $a[0] -Confirm:$false } }
	'app-start'       = @{ Class = 'Operate'; Cmdlet = 'Start-OS7ContainerApplication'; Run = { param($a, $in) Start-OS7ContainerApplication -Name $a[0] -Confirm:$false } }
	'app-stop'        = @{ Class = 'Operate'; Cmdlet = 'Stop-OS7ContainerApplication'; Run = { param($a, $in) Stop-OS7ContainerApplication -Name $a[0] -Confirm:$false } }
	'create'          = @{ Class = 'Operate'; Cmdlet = 'New-OS7Container'; Input = $true; Run = { param($a, $in) $s = ConvertTo-OS7ContainerSpec -Json $in; New-OS7Container @s -Confirm:$false } }
	'remove'          = @{ Class = 'Destroy'; Cmdlet = 'Remove-OS7Container'; Run = { param($a, $in) Remove-OS7Container -Name $a[0] -Force:($a.Count -gt 1 -and $a[1] -eq 'force') -Confirm:$false } }
	'image-remove'    = @{ Class = 'Destroy'; Cmdlet = 'Remove-OS7ContainerImage'; Run = { param($a, $in) Remove-OS7ContainerImage -Name $a[0] -Confirm:$false } }
	'volume-remove'   = @{ Class = 'Destroy'; Cmdlet = 'Remove-OS7ContainerVolume'; Run = { param($a, $in) Remove-OS7ContainerVolume -Name $a[0] -Confirm:$false } }
	'network-remove'  = @{ Class = 'Destroy'; Cmdlet = 'Remove-OS7ContainerNetwork'; Run = { param($a, $in) Remove-OS7ContainerNetwork -Name $a[0] -Confirm:$false } }
	'cleanup'         = @{ Class = 'Destroy'; Cmdlet = 'Remove-OS7ContainerUnused'; Input = $true; Run = { param($a, $in) ConvertFrom-OS7ContainerItemJson -Json $in | Remove-OS7ContainerUnused -Confirm:$false } }
	'install-host'    = @{ Class = 'Install'; Cmdlet = 'Install-OS7ContainerHost'; Run = { param($a, $in) Install-OS7ContainerHost -Confirm:$false } }
}

function ConvertTo-OS7ContainerSpec {
	<#
	.SYNOPSIS
		Internal. The create dialog's JSON as New-OS7Container's parameters —
		named, so nothing the JSON carries can become a parameter it was not
		meant to be.
	#>
	param([AllowEmptyString()][string]$Json)

	if ([string]::IsNullOrWhiteSpace($Json)) { throw [System.ArgumentException]::new('No container description arrived on standard input.') }
	$j = $Json | ConvertFrom-Json -AsHashtable -Depth 8
	$s = @{ Name = [string]$j['Name']; Image = [string]$j['Image'] }
	if ($j['Port']) { $s.Port = @($j['Port'] | ForEach-Object { [string]$_ }) }
	if ($j['Volume']) { $s.Volume = @($j['Volume'] | ForEach-Object { [string]$_ }) }
	if ($j['Environment']) { $e = [ordered]@{}; foreach ($k in $j['Environment'].Keys) { $e[[string]$k] = [string]$j['Environment'][$k] }; $s.Environment = $e }
	if ($j['RestartPolicy']) { $s.RestartPolicy = [string]$j['RestartPolicy'] }
	if ($j['NoStart']) { $s.NoStart = [bool]$j['NoStart'] }
	return $s
}

function ConvertFrom-OS7ContainerItemJson {
	<#
	.SYNOPSIS
		Internal. The clean-up dialog's selection — items Get-OS7ContainerUnused
		listed — as objects, with only the fields the removal reads.
	#>
	param([AllowEmptyString()][string]$Json)

	if ([string]::IsNullOrWhiteSpace($Json)) { throw [System.ArgumentException]::new('No items arrived on standard input.') }
	foreach ($i in @($Json | ConvertFrom-Json -Depth 8)) {
		if ($null -eq $i) { continue }
		[pscustomobject]@{
			Kind = [string](Get-OS7ContainerField $i 'Kind')
			Name = [string](Get-OS7ContainerField $i 'Name')
			Id   = [string](Get-OS7ContainerField $i 'Id')
			Size = Get-OS7ContainerField $i 'Size'
		}
	}
}

function Get-OS7ContainerVerb {
	<#
	.SYNOPSIS
		The verbs the container window may send and the helper may run: each
		one's class and the one cmdlet it calls.

	.DESCRIPTION
		Read by installer/testing/check-gui-logic.py, which requires every verb
		the window names to be here with the same class — so a button cannot
		ask for a verb the helper does not have, or ask the wrong helper.
	#>
	[CmdletBinding()]
	param()

	foreach ($k in $script:OS7ContainerVerbs.Keys) {
		$v = $script:OS7ContainerVerbs[$k]
		[pscustomobject]@{
			PSTypeName = 'OS7.ContainerVerb'
			Verb       = $k
			Class      = $v.Class
			Cmdlet     = $v.Cmdlet
			Input      = [bool]$v['Input']
		}
	}
}

function Invoke-OS7ContainerVerb {
	<#
	.SYNOPSIS
		Runs one verb of the container window's table and writes its result as
		JSON — the wire format both channels speak (GUI-APPS-PLAN G4).

	.DESCRIPTION
		Called by the window through pwsh, as an operator who holds the
		socket, and by /usr/libexec/os7-container-helper through pkexec, as
		root. The helper passes -Class, and a verb of another class is refused
		BY NAME before anything runs: the polkit action the operator
		authenticated for is the class, and a verb must not reach the engine
		under an action that did not cover it.

		Always an array, even of one, so that the reader never has to guess
		whether one result or several came back (the Software Update window
		learned that on exactly the machine with one update waiting).

	.EXAMPLE
		Invoke-OS7ContainerVerb -Verb list
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Verb,
		[Parameter(Position = 1)][string[]]$Argument = @(),
		[AllowEmptyString()][string]$InputJson,
		[ValidateSet('Read', 'Operate', 'Destroy', 'Install')][string[]]$Class
	)

	if (-not $script:OS7ContainerVerbs.Contains($Verb)) {
		throw [System.ArgumentException]::new(
			"'$Verb' is not a container verb. Get-OS7ContainerVerb lists them: $(@($script:OS7ContainerVerbs.Keys) -join ', ').")
	}
	$v = $script:OS7ContainerVerbs[$Verb]
	if ($Class -and $Class -notcontains $v.Class) {
		throw [System.UnauthorizedAccessException]::new(
			"'$Verb' is a $($v.Class) verb, and this channel runs only $($Class -join ' and ') verbs. " +
			'It was not run.')
	}
	if ($v['Input'] -and [string]::IsNullOrWhiteSpace($InputJson)) {
		$InputJson = [Console]::In.ReadToEnd()
	}
	# THIS IS AN IPC BOUNDARY, and BUILD-NOTES #60 is its rule: with stdout
	# redirected, pwsh writes the warning, verbose and information streams to
	# STDOUT, ahead of the JSON. A machine found it the first time the window
	# ran as a user: Get-OS7StoragePressure warned that the ESP is root's, and
	# the window said "'W' is an invalid start of a value". The other streams
	# are suppressed here by redirect, not by asking every cmdlet to be quiet.
	$out = @(& $v.Run @($Argument) $InputJson 3>$null 4>$null 5>$null 6>$null)
	# Measured 2026-10-30 on the pinned pwsh: `-InputObject <array> -AsArray`
	# wraps the array in a SECOND one, and an EMPTY pipeline into -AsArray
	# writes nothing at all rather than []. Both would be a reader's guess.
	if ($out.Count -eq 0) { return '[]' }
	return ($out | ConvertTo-Json -Depth 8 -AsArray)
}
