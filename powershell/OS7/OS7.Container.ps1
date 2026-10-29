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
			"  or work in an elevated session: sudo pwsh", $_.Exception)
	}
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

	# A label's KEY has dots in it, so it is read as one name and never through
	# the dotted-path reader — which split `com.docker.compose.project` into
	# four steps and found nothing, while the window's Applications node would
	# have stayed empty in silence. check-container-logic.py found it.
	$labels = Get-OS7ContainerField $Inspect 'Config.Labels'
	$app = $null
	if ($labels -is [System.Collections.IDictionary]) { $app = $labels['com.docker.compose.project'] }
	elseif ($null -ne $labels) {
		$lp = $labels.PSObject.Properties['com.docker.compose.project']
		if ($lp) { $app = $lp.Value }
	}
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

	Assert-OS7Elevated -Cmdlet $Cmdlet -Because $Because
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

	Assert-OS7Elevated -Cmdlet 'Remove-OS7Container' -Because 'removes a container through the engine, whose socket is root''s'
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
