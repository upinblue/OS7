# =============================================================================
# OS/7 — the Microsoft.PowerShell.Management names that Linux does not ship
#
# WHAT WAS MEASURED, 2026-09-09, and it is the whole reason this file exists.
# The shipped ISO's own pwsh 7.6.5 was asked, by chrooting into the image's
# squashfs (BUILD-NOTES #93: the ISO is the authority, not a container made from
# it), and the same question was put to an installed machine. Of the 62 cmdlets
# the 7.6 Microsoft.PowerShell.Management reference documents:
#
#   * 47 are PRESENT.
#   * 15 are ABSENT — the entire service family (9), plus Set-TimeZone,
#     Get-ComputerInfo, Rename-Computer, Get-HotFix, Clear-RecycleBin and
#     Restore-Computer. Invoking one gives a CommandNotFoundException: "The
#     term 'Get-Service' is not recognized as a name of a cmdlet …".
#   * Tab completion does NOT offer the absent ones (asked of
#     [CommandCompletion]::CompleteInput, the code path Tab uses), because the
#     Unix module manifest's CmdletsToExport does not list them. So a name that
#     completes and then fails is NOT this — it is a name PowerShell has and
#     mis-implements, which is the next paragraph.
#
# AND THE TWO THAT ARE PRESENT AND WRONG. `Restart-Computer` and `Stop-Computer`
# both exist, complete, and both run
#
#     /usr/sbin/shutdown          (with NO arguments at all)
#
# — recorded with a recorder in place of every binary they might reach for.
# `/usr/sbin/shutdown` is a symlink to `systemctl`, whose compatibility
# interface takes the action as a FLAG and defaults to poweroff without one. So
# `Restart-Computer` POWERS AN OS/7 MACHINE OFF and reports success; the
# machine's own console said `Reached target poweroff.target` and
# `reboot: Power down` after it. Upstream has had this since 2021
# (PowerShell/PowerShell#14684). docs/manual §06 tells an operator to type
# exactly that command after an update, so it is a defect in the product as
# documented, not a curiosity.
#
# Neither of those two carries ANY parameter on Linux beyond the common ones —
# no -Force, no -Wait, no -Delay — so a copied `Restart-Computer -Force` fails
# on the parameter before it gets a chance to do the wrong thing.
#
# WHAT THIS FILE IS. P1 in docs/POWERSHELL-SURFACE-PLAN.md deferred the Windows
# names to an opt-in module of "aliases and only aliases". That was revised on
# 2026-09-09: these are FUNCTIONS with Windows' parameters and Windows' output
# shape, and they are loaded by default, because "the name resolves" and "a
# script copied off a Windows box runs" are different products and only the
# second one is worth having. P1 records the revision and its price.
#
# THE CONTRACT, and it is what makes this a compatibility layer rather than a
# lookalike: EVERY parameter the real Windows cmdlet has is DECLARED here, and
# each one is either implemented or refused by name with a reason and a
# pointer. A parameter that is silently ignored is the failure mode P1 was
# written to avoid — a script that half-works is worse than one that stops.
# $script:OS7CompatUnsupported is that table, in one place, and
# installer/testing/check-compat-windows.py drives it against the parameter
# sets recorded from a real Windows pwsh 7.6.5 — the same version OS/7 ships,
# so the two sides are comparable.
#
# NO SYSTEMD HERE. Everything goes through powershell/Systemd (P2-systemd,
# check-layering.py). What is genuinely generic — the machine's power state,
# the freezer, unit authoring, the host name — was added THERE.
#
# Dot-sourced by OS7.psm1, after OS7.Service.ps1 and OS7.Time.ps1, whose
# functions it calls.
# =============================================================================

# ---------------------------------------------------------------------------
# The refusal table
#
# 'Cmdlet:Parameter' -> why, and what to use instead. Read by the functions to
# throw with, and by check-compat-windows.py to prove that every Windows
# parameter is accounted for exactly once.
# ---------------------------------------------------------------------------
$script:OS7CompatUnsupported = @{
	# There is no service control manager to talk to over the network, and the
	# WSMan client library PowerShell would need for -WsmanAuthentication is
	# not present on Linux at all (measured: "no supported WSMan client library
	# was found"). Remoting to an OS/7 machine is SSH.
	'Get-Service:DependentServices'      = 'systemd expresses dependencies as a graph rather than as a service property. Ask it directly: Get-SystemdJournal is not the tool, `systemctl list-dependencies --reverse <unit>` is.'
	'Get-Service:RequiredServices'       = 'systemd expresses dependencies as a graph rather than as a service property. `systemctl list-dependencies <unit>` answers it.'
	'Set-Service:Credential'             = 'the account a unit runs as is `User=` in its unit file, and systemd takes no password for it. New-SystemdService -User writes that line; there is nothing here for a credential to do.'
	'Set-Service:SecurityDescriptorSddl' = 'SDDL is a Windows access-control language. A unit file''s permissions are filesystem permissions and polkit rules.'
	'Set-Service:Description'            = 'a unit''s Description= lives in its unit file. For a unit this module wrote, rewrite it with New-SystemdService -Force; for a package''s, `systemctl edit` writes a drop-in, which is deliberately not something a compatibility shim does behind your back.'
	'Set-Service:DisplayName'            = 'a unit''s Description= lives in its unit file — see -Description. Get-Service reports it as DisplayName because that is the field a Windows script reads.'
	'New-Service:Credential'             = 'the account a unit runs as is `User=` in its unit file, and systemd takes no password for it.'
	'New-Service:SecurityDescriptorSddl' = 'SDDL is a Windows access-control language and has no systemd equivalent.'
	'Rename-Computer:ComputerName'       = 'this renames THIS machine. There is no remote service-control channel on Linux; reach the other machine over SSH and rename it there.'
	'Rename-Computer:DomainCredential'   = 'renaming a joined machine is refused outright here, because the keytab holds principals for the OLD name and Kerberos stops working the moment the name changes. Remove-OS7Domain, rename, Join-OS7Domain.'
	'Rename-Computer:LocalCredential'    = 'the rename is done by this session; it needs root on this machine and nothing else.'
	'Rename-Computer:WsmanAuthentication' = 'PowerShell on Linux has no WSMan client library (measured). Remoting to an OS/7 machine is SSH.'
	'Restart-Computer:ComputerName'      = 'this restarts THIS machine. Reach another one over SSH and restart it there.'
	'Restart-Computer:Credential'        = 'there is nobody to present a credential to; the local action needs root.'
	'Restart-Computer:WsmanAuthentication' = 'PowerShell on Linux has no WSMan client library (measured).'
	'Restart-Computer:Wait'              = 'waiting for the machine to come back is only meaningful from ANOTHER machine, and this session is one of the things being killed. -Delay schedules the restart instead.'
	'Restart-Computer:For'               = 'the thing to wait for is only meaningful with -Wait, which is not supported here.'
	'Restart-Computer:Timeout'           = 'the timeout is only meaningful with -Wait, which is not supported here.'
	'Stop-Computer:ComputerName'         = 'this stops THIS machine. Reach another one over SSH and stop it there.'
	'Stop-Computer:Credential'           = 'there is nobody to present a credential to; the local action needs root.'
	'Stop-Computer:WsmanAuthentication'  = 'PowerShell on Linux has no WSMan client library (measured).'
}

# ---------------------------------------------------------------------------
# The two mapping tables, and the one decision in this file that cannot be
# made cleanly in both directions.
#
# systemd has nine unit-file states and Windows has five start types, so there
# is no bijection. These two tables are chosen so that the THREE WORDS A SCRIPT
# ACTUALLY WRITES round-trip exactly:
#
#     Set-Service -StartupType Automatic  -> enable    -> reports Automatic
#     Set-Service -StartupType Manual     -> disable   -> reports Manual
#     Set-Service -StartupType Disabled   -> MASK      -> reports Disabled
#
# `Disabled` becomes a MASK and that is deliberate. On Windows a disabled
# service CANNOT be started — that is what the word means there, and an
# administrator hardening a machine means it. systemd's `disable` only removes
# it from boot and leaves it startable by hand, so mapping Disabled to `disable`
# would quietly grant what the script asked to forbid. Masking is the state
# that means "cannot start".
#
# THIS DIFFERS FROM `Set-OS7Service` ON PURPOSE, and the difference is worth
# knowing about: the OS/7-named cmdlet has FOUR words — its `Disabled` is
# systemd's `disable` and its `Blocked` is the mask — because an OS/7
# administrator is talking to systemd and can say which one they mean. A copied
# Windows script cannot, so this layer resolves the ambiguity towards the
# stronger reading and says so at the time (Write-Warning), which is the whole
# difference between a shim and a lie.
#
# On the way OUT, `disabled` reports as **Manual** and not as Disabled, for the
# mirror-image reason: a startable unit reported as Windows' Disabled would be
# the lie in the other direction. Windows' Manual is exactly "not at boot,
# started on demand", which is systemd's `disabled` and its `static` both.
# ---------------------------------------------------------------------------
$script:OS7CompatStartTypeFromUnitFile = @{
	'enabled'         = 'Automatic'
	'enabled-runtime' = 'Automatic'
	'masked'          = 'Disabled'
	'masked-runtime'  = 'Disabled'
	'disabled'        = 'Manual'
	'static'          = 'Manual'
	'indirect'        = 'Manual'
	'generated'       = 'Manual'
	'transient'       = 'Manual'
	'linked'          = 'Manual'
	'linked-runtime'  = 'Manual'
	'alias'           = 'Manual'
	'bad'             = 'Manual'
}

# Windows' ServiceStartMode, on the way in. Boot and System are kernel-driver
# start types on Windows; the Linux equivalent is the initramfs and the kernel
# command line, neither of which is a unit, so they are refused rather than
# approximated.
$script:OS7CompatStartupToSystemd = @{
	'Automatic'             = 'Enabled'
	'AutomaticDelayedStart' = 'Enabled'
	'Manual'                = 'Disabled'
	'Disabled'              = 'Masked'
}

# systemd's ActiveState, plus the freezer, as Windows' ServiceControllerStatus.
# `failed` becomes Stopped because Windows has no word for it and a script
# asking "is it running" must be told no; the systemd word is kept beside it in
# SystemdActiveState, so nothing is lost, only translated.
$script:OS7CompatStatusFromActiveState = @{
	'active'       = 'Running'
	'reloading'    = 'Running'
	'activating'   = 'StartPending'
	'deactivating' = 'StopPending'
	'inactive'     = 'Stopped'
	'failed'       = 'Stopped'
	'maintenance'  = 'Stopped'
}

# The names this file defines. check-compat-windows.py reads it rather than
# keeping its own copy.
$script:OS7CompatWindowsNames = @(
	'Get-Service', 'Set-Service', 'New-Service', 'Remove-Service',
	'Start-Service', 'Stop-Service', 'Restart-Service',
	'Suspend-Service', 'Resume-Service',
	'Set-TimeZone', 'Get-ComputerInfo', 'Rename-Computer',
	'Restart-Computer', 'Stop-Computer'
)

# The two that shadow a cmdlet PowerShell really has, deliberately, because
# what it has is broken. Everything else here fills a hole.
$script:OS7CompatShadowedOnPurpose = @('Restart-Computer', 'Stop-Computer')

$script:OS7CompatShadowNoticed = @()

function Assert-OS7CompatSupported {
	<#
	.SYNOPSIS
		Internal. Refuses a Windows parameter this platform cannot honour,
		with the reason and the alternative.

	.DESCRIPTION
		Called with $PSBoundParameters, so a parameter is only refused when it
		was actually PASSED. Declared-but-unsupported is what makes the failure
		land on the caller's line with an explanation instead of on PowerShell's
		generic "a parameter cannot be found".
	#>
	param(
		[Parameter(Mandatory)][string]$Cmdlet,
		[Parameter(Mandatory)][hashtable]$Bound
	)

	foreach ($p in @($Bound.Keys)) {
		$key = "${Cmdlet}:${p}"
		if ($script:OS7CompatUnsupported.ContainsKey($key)) {
			throw [System.NotSupportedException]::new(
				"$Cmdlet -$p is not supported on OS/7: $($script:OS7CompatUnsupported[$key])")
		}
	}
}

function Write-OS7CompatShadowNotice {
	<#
	.SYNOPSIS
		Internal. Says so, once, if PowerShell has grown a real cmdlet of this
		name.

	.DESCRIPTION
		P1'S ONE REAL OBJECTION, MADE AUDIBLE. A free name is not free for
		ever: if a later PowerShell ships `Get-Service` for Linux, OS/7's
		function would shadow it silently and a script would get our parameter
		set instead of Microsoft's. It cannot be prevented without abandoning
		the feature, so it is REPORTED — and reported once per session, because
		a warning on every call is a warning nobody reads.

		The real one stays reachable under its qualified name,
		`Microsoft.PowerShell.Management\Get-Service`.
	#>
	param([Parameter(Mandatory)][string]$Name)

	if ($script:OS7CompatShadowNoticed -contains $Name) { return }
	$script:OS7CompatShadowNoticed = $script:OS7CompatShadowNoticed + $Name

	$real = @(Get-Command -Name $Name -CommandType Cmdlet -ErrorAction SilentlyContinue)
	if ($real.Count) {
		Write-Warning ("PowerShell $($PSVersionTable.PSVersion) now ships a real $Name cmdlet " +
			"and OS/7's compatibility function is shadowing it. The real one is " +
			"Microsoft.PowerShell.Management\$Name. This is worth reporting: the " +
			'compatibility function exists because that cmdlet was absent.')
	}
}

function Resolve-OS7CompatUnitName {
	<#
	.SYNOPSIS
		Internal. `ssh`, `ssh.service` and `ss*` all mean the same unit here.

	.DESCRIPTION
		A Windows service name carries no suffix and a systemd unit does. Both
		spellings are accepted on the way in and the suffixed one is what goes
		to systemd; `Get-Service` reports the bare name as Name and the full
		unit as Unit, so nothing has to guess in either direction.
	#>
	param([Parameter(Mandatory)][string]$Name)
	if ($Name -match '\.(service|socket|target|timer|path|mount)$') { return $Name }
	return "$Name.service"
}

function ConvertTo-OS7CompatService {
	<#
	.SYNOPSIS
		Internal. One Get-OS7Service row as a Windows script expects to find
		it.

	.DESCRIPTION
		NOT a System.ServiceProcess.ServiceController. That type exists in .NET
		on Linux and throws the moment it is used, so this is a shaped object
		with the property NAMES a Windows script reads — Name, DisplayName,
		Status, StartType — and systemd's own words kept beside them under
		Systemd* names. A translation that discards the original is a
		translation nobody can check.

		`Status` is `Paused` only when the freezer says so, and the freezer is
		asked only when the caller asked about ONE service: it is a `systemctl
		show` per unit, and a listing must not pay for it (Get-SystemdUnit
		makes the same distinction for the same reason).
	#>
	param(
		[Parameter(Mandatory)][psobject]$Service,
		[switch]$WithFreezer
	)

	$unit = $Service.Name
	$bare = $unit -replace '\.service$', ''

	$status = if ($null -ne $Service.ActiveState -and
		$script:OS7CompatStatusFromActiveState.ContainsKey($Service.ActiveState)) {
		$script:OS7CompatStatusFromActiveState[$Service.ActiveState]
	}
	else { 'Stopped' }

	$freezer = $null
	if ($WithFreezer) {
		$freezer = Get-SystemdUnitFreezerState -Name $unit
		if ($freezer -like 'frozen*') { $status = 'Paused' }
		elseif ($freezer -like 'freezing*') { $status = 'PausePending' }
		elseif ($freezer -eq 'thawing') { $status = 'ContinuePending' }
	}

	$startType = if ($null -ne $Service.StartupType -and
		$script:OS7CompatStartTypeFromUnitFile.ContainsKey($Service.StartupType)) {
		$script:OS7CompatStartTypeFromUnitFile[$Service.StartupType]
	}
	else { $null }

	return [pscustomobject]@{
		PSTypeName              = 'OS7.Compat.Windows.ServiceController'
		Name                    = $bare
		DisplayName             = $Service.Description
		Status                  = $status
		StartType               = $startType
		# Windows reports the machine a ServiceController was opened against.
		# There is only ever one here, and '.' is what Windows calls the local
		# one.
		MachineName             = '.'
		ServiceName             = $bare
		# A frozen unit cannot be stopped without thawing it first, and an
		# inactive one has nothing to stop. Windows scripts branch on this.
		CanStop                 = ($status -in @('Running', 'StartPending'))
		# systemd's freezer is not a service-cooperative pause and every unit
		# has one, so this is true wherever the unit is running at all — with
		# the difference spelled out in Suspend-Service's help.
		CanPauseAndContinue     = ($status -eq 'Running')
		CanShutdown             = $true
		ServiceType             = 'Own'
		# systemd's own words, kept. `failed` has no Windows equivalent and
		# this is where it survives.
		Unit                    = $unit
		SystemdActiveState      = $Service.ActiveState
		SystemdSubState         = $Service.SubState
		SystemdUnitFileState    = $Service.StartupType
		SystemdFreezerState     = $freezer
		SystemdResult           = $Service.Result
		# OS/7's own health verdict, which is not `is-active` in either
		# direction — see Get-OS7Service.
		Healthy                 = $Service.Healthy
	}
}

function Get-OS7CompatService {
	<#
	.SYNOPSIS
		Internal. The shared listing behind Get-/Start-/Stop-/Restart-Service.

	.DESCRIPTION
		-Name accepts wildcards and several names. A name with no wildcard is a
		POINT QUERY and goes to systemd as one, which is both cheaper and the
		only way to hear about a unit that is neither enabled nor active —
		systemd does not load units nothing references, so such a unit is
		absent from every listing and present to `systemctl show` (measured on
		systemd 259, and it is why Get-SystemdTimer is a union).

		A name that matches nothing is a non-terminating error, the way
		Windows' own Get-Service reports it, so `Get-Service a, b` still
		returns b.
	#>
	param(
		[string[]]$Name,
		[string[]]$DisplayName,
		[string[]]$Include,
		[string[]]$Exclude,
		[switch]$Freezer
	)

	$rows = @()

	if ($Name -and @($Name).Count) {
		foreach ($n in $Name) {
			if ($n -match '[\*\?\[]') {
				$pattern = if ($n -match '\.service$') { $n } else { "$n.service" }
				$hit = @(Get-OS7Service -Name $pattern -Detailed)
				if (-not $hit.Count) {
					Write-Error "Cannot find any service with service name '$n'."
					continue
				}
				$rows = $rows + $hit
			}
			else {
				$unit = Resolve-OS7CompatUnitName -Name $n
				$hit = @(Get-OS7Service -Name $unit -Detailed |
					Where-Object { $_.Name -eq $unit })
				if (-not $hit.Count) {
					Write-Error "Cannot find any service with service name '$n'."
					continue
				}
				$rows = $rows + $hit
			}
		}
	}
	else {
		# THE WHOLE MACHINE, WITH DETAIL. `-Detailed` is one `systemctl show`
		# per service, and it is paid for rather than skipped because
		# `StartupType` is $null without it — and a $null StartType turns
		# `Get-Service | Where StartType -eq 'Automatic'` into a filter that
		# silently matches nothing, which is the exact class of quiet wrongness
		# this layer exists to avoid.
		$rows = @(Get-OS7Service -Detailed)
	}

	if ($DisplayName -and @($DisplayName).Count) {
		$rows = @($rows | Where-Object {
				$d = $_.Description
				$null -ne $d -and @($DisplayName | Where-Object { $d -like $_ }).Count -gt 0
			})
	}

	$out = foreach ($r in $rows) {
		$bare = $r.Name -replace '\.service$', ''
		if ($Include -and @($Include).Count -and
			-not @($Include | Where-Object { $bare -like $_ -or $r.Name -like $_ }).Count) { continue }
		if ($Exclude -and @($Exclude).Count -and
			@($Exclude | Where-Object { $bare -like $_ -or $r.Name -like $_ }).Count) { continue }
		ConvertTo-OS7CompatService -Service $r -WithFreezer:$Freezer
	}
	return @($out)
}

# ---------------------------------------------------------------------------
# The service family
# ---------------------------------------------------------------------------

function Get-Service {
	<#
	.SYNOPSIS
		The services on this machine, in Windows' vocabulary.

	.DESCRIPTION
		THE NAME POWERSHELL DOES NOT SHIP ON LINUX (measured: absent from the
		Unix build of Microsoft.PowerShell.Management, and not offered by tab
		completion either). This is OS/7's, over systemd, with the property
		names a Windows script reads and systemd's own words kept beside them.

		`Status` is Windows': Running, Stopped, StartPending, StopPending, and
		Paused when the unit is frozen. `failed` has no Windows word and reads
		as Stopped — `SystemdActiveState` is where it survives, and OS/7's own
		`Healthy` is the field that actually distinguishes a well service from
		a broken one (Get-OS7Service explains why `is-active` does not).

		`StartType` is Automatic for an enabled unit, Disabled for a MASKED
		one, and Manual for everything else — including systemd's `disabled`,
		because such a unit can still be started by hand and Windows' Disabled
		cannot. Set-Service's help has the other direction and the reasoning.

	.PARAMETER Name
		One or more service names, with or without the `.service` suffix.
		Wildcards allowed. A name matching nothing is a non-terminating error,
		as on Windows.

	.PARAMETER DisplayName
		Match against the unit's Description= instead.

	.PARAMETER Include
		Of the services found, keep only these.

	.PARAMETER Exclude
		Of the services found, drop these.

	.PARAMETER InputObject
		Service objects from an earlier Get-Service.

	.PARAMETER DependentServices
		Not supported — see the error text.

	.PARAMETER RequiredServices
		Not supported — see the error text.

	.EXAMPLE
		Get-Service ssh

	.EXAMPLE
		Get-Service | Where-Object Status -eq 'Running'

	.EXAMPLE
		Get-Service | Where-Object { -not $_.Healthy }
	#>
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	[OutputType('OS7.Compat.Windows.ServiceController')]
	param(
		[Parameter(ParameterSetName = 'Default', Position = 0,
			ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[string[]]$Name,
		[Parameter(ParameterSetName = 'DisplayName', Mandatory)]
		[string[]]$DisplayName,
		[Parameter(ParameterSetName = 'InputObject', ValueFromPipeline)]
		[psobject[]]$InputObject,
		[string[]]$Include,
		[string[]]$Exclude,
		[switch]$DependentServices,
		[switch]$RequiredServices
	)

	begin {
		Assert-OS7CompatSupported -Cmdlet 'Get-Service' -Bound $PSBoundParameters
		Write-OS7CompatShadowNotice -Name 'Get-Service'
		Import-OS7SystemdLayer
	}
	process {
		$names = @()
		if ($InputObject -and @($InputObject).Count) {
			foreach ($o in $InputObject) {
				$names = $names + $(if ($o.PSObject.Properties['Unit']) { $o.Unit } else { [string]$o.Name })
			}
		}
		elseif ($Name -and @($Name).Count) { $names = @($Name) }

		$splat = @{}
		if ($names.Count) { $splat.Name = $names }
		if ($DisplayName -and @($DisplayName).Count) { $splat.DisplayName = $DisplayName }
		if ($Include -and @($Include).Count) { $splat.Include = $Include }
		if ($Exclude -and @($Exclude).Count) { $splat.Exclude = $Exclude }
		# The freezer costs a call per unit, so it is asked only when the
		# question was about specific services.
		if ($names.Count) { $splat.Freezer = $true }

		Get-OS7CompatService @splat
	}
}

function Start-Service {
	<#
	.SYNOPSIS
		Starts a service and reports what it became.

	.DESCRIPTION
		The answer comes from asking systemd afterwards, never from the exit
		code: `systemctl start` succeeds when the JOB was accepted, and a
		service that then dies leaves a successful command and a failed unit.

		A masked unit cannot be started, and systemd says so. `Set-Service
		-StartupType Manual` is what un-says a mask here.

	.PARAMETER PassThru
		Return the service. Windows returns nothing without it, and so does
		this.
	#>
	[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
	[OutputType('OS7.Compat.Windows.ServiceController')]
	param(
		[Parameter(ParameterSetName = 'Default', Position = 0, Mandatory,
			ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[string[]]$Name,
		[Parameter(ParameterSetName = 'DisplayName', Mandatory)]
		[string[]]$DisplayName,
		[Parameter(ParameterSetName = 'InputObject', Mandatory, ValueFromPipeline)]
		[psobject[]]$InputObject,
		[string[]]$Include,
		[string[]]$Exclude,
		[switch]$PassThru
	)

	begin {
		Assert-OS7CompatSupported -Cmdlet 'Start-Service' -Bound $PSBoundParameters
		Write-OS7CompatShadowNotice -Name 'Start-Service'
		Import-OS7SystemdLayer
	}
	process {
		foreach ($svc in @(Get-OS7CompatServiceTarget -Name $Name -DisplayName $DisplayName `
					-InputObject $InputObject -Include $Include -Exclude $Exclude)) {
			if (-not $PSCmdlet.ShouldProcess($svc.Name, 'start')) { continue }
			Start-OS7Service -Name $svc.Unit -Confirm:$false | Out-Null
			if ($PassThru) { Get-OS7CompatService -Name $svc.Unit -Freezer }
		}
	}
}

function Stop-Service {
	<#
	.SYNOPSIS
		Stops a service and reports what it became.

	.PARAMETER Force
		Accepted and has no work to do: on Windows it means "stop the
		dependent services too", and `systemctl stop` already stops what
		depends on the unit. Kept so a copied script binds.

	.PARAMETER NoWait
		Accepted and has no work to do: this returns as soon as systemd has
		taken the job either way. The state reported afterwards is systemd's
		answer at that moment, not a promise that the process is gone.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High',
		DefaultParameterSetName = 'Default')]
	[OutputType('OS7.Compat.Windows.ServiceController')]
	param(
		[Parameter(ParameterSetName = 'Default', Position = 0, Mandatory,
			ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[string[]]$Name,
		[Parameter(ParameterSetName = 'DisplayName', Mandatory)]
		[string[]]$DisplayName,
		[Parameter(ParameterSetName = 'InputObject', Mandatory, ValueFromPipeline)]
		[psobject[]]$InputObject,
		[string[]]$Include,
		[string[]]$Exclude,
		[switch]$Force,
		[switch]$NoWait,
		[switch]$PassThru
	)

	begin {
		Assert-OS7CompatSupported -Cmdlet 'Stop-Service' -Bound $PSBoundParameters
		Write-OS7CompatShadowNotice -Name 'Stop-Service'
		Import-OS7SystemdLayer
	}
	process {
		foreach ($svc in @(Get-OS7CompatServiceTarget -Name $Name -DisplayName $DisplayName `
					-InputObject $InputObject -Include $Include -Exclude $Exclude)) {
			if (-not $PSCmdlet.ShouldProcess($svc.Name, 'stop')) { continue }
			Stop-OS7Service -Name $svc.Unit -Confirm:$false | Out-Null
			if ($PassThru) { Get-OS7CompatService -Name $svc.Unit -Freezer }
		}
	}
}

function Restart-Service {
	<#
	.SYNOPSIS
		Restarts a service and reports what it became.

	.PARAMETER Force
		Accepted and has no work to do — see Stop-Service -Force.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High',
		DefaultParameterSetName = 'Default')]
	[OutputType('OS7.Compat.Windows.ServiceController')]
	param(
		[Parameter(ParameterSetName = 'Default', Position = 0, Mandatory,
			ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[string[]]$Name,
		[Parameter(ParameterSetName = 'DisplayName', Mandatory)]
		[string[]]$DisplayName,
		[Parameter(ParameterSetName = 'InputObject', Mandatory, ValueFromPipeline)]
		[psobject[]]$InputObject,
		[string[]]$Include,
		[string[]]$Exclude,
		[switch]$Force,
		[switch]$PassThru
	)

	begin {
		Assert-OS7CompatSupported -Cmdlet 'Restart-Service' -Bound $PSBoundParameters
		Write-OS7CompatShadowNotice -Name 'Restart-Service'
		Import-OS7SystemdLayer
	}
	process {
		foreach ($svc in @(Get-OS7CompatServiceTarget -Name $Name -DisplayName $DisplayName `
					-InputObject $InputObject -Include $Include -Exclude $Exclude)) {
			if (-not $PSCmdlet.ShouldProcess($svc.Name, 'restart')) { continue }
			Restart-OS7Service -Name $svc.Unit -Confirm:$false | Out-Null
			if ($PassThru) { Get-OS7CompatService -Name $svc.Unit -Freezer }
		}
	}
}

function Suspend-Service {
	<#
	.SYNOPSIS
		Freezes a service's processes — systemd's nearest thing to a paused
		Windows service.

	.DESCRIPTION
		NOT THE SAME OPERATION, and the difference matters enough to be said
		here rather than in a footnote. Windows ASKS a service to pause and the
		service may decline or may flush its work first. systemd's freezer does
		not ask: every process in the unit's cgroup stops where it is. Nothing
		is told, so nothing can prepare.

		The unit's `ActiveState` stays `active` while frozen (measured on an
		installed machine), which is why `Status` reports Paused from the
		FREEZER and not from the unit's state.
	#>
	[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
	[OutputType('OS7.Compat.Windows.ServiceController')]
	param(
		[Parameter(ParameterSetName = 'Default', Position = 0, Mandatory,
			ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[string[]]$Name,
		[Parameter(ParameterSetName = 'DisplayName', Mandatory)]
		[string[]]$DisplayName,
		[Parameter(ParameterSetName = 'InputObject', Mandatory, ValueFromPipeline)]
		[psobject[]]$InputObject,
		[string[]]$Include,
		[string[]]$Exclude,
		[switch]$PassThru
	)

	begin {
		Assert-OS7CompatSupported -Cmdlet 'Suspend-Service' -Bound $PSBoundParameters
		Write-OS7CompatShadowNotice -Name 'Suspend-Service'
		Import-OS7SystemdLayer
	}
	process {
		foreach ($svc in @(Get-OS7CompatServiceTarget -Name $Name -DisplayName $DisplayName `
					-InputObject $InputObject -Include $Include -Exclude $Exclude)) {
			if (-not $PSCmdlet.ShouldProcess($svc.Name, 'freeze')) { continue }
			Suspend-SystemdUnit -Name $svc.Unit -Confirm:$false | Out-Null
			if ($PassThru) { Get-OS7CompatService -Name $svc.Unit -Freezer }
		}
	}
}

function Resume-Service {
	<#
	.SYNOPSIS
		Thaws a frozen service's processes.

	.DESCRIPTION
		The other half of Suspend-Service, with the same caveat: this resumes
		processes that were stopped mid-instruction, and nothing was told they
		were stopped.
	#>
	[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
	[OutputType('OS7.Compat.Windows.ServiceController')]
	param(
		[Parameter(ParameterSetName = 'Default', Position = 0, Mandatory,
			ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[string[]]$Name,
		[Parameter(ParameterSetName = 'DisplayName', Mandatory)]
		[string[]]$DisplayName,
		[Parameter(ParameterSetName = 'InputObject', Mandatory, ValueFromPipeline)]
		[psobject[]]$InputObject,
		[string[]]$Include,
		[string[]]$Exclude,
		[switch]$PassThru
	)

	begin {
		Assert-OS7CompatSupported -Cmdlet 'Resume-Service' -Bound $PSBoundParameters
		Write-OS7CompatShadowNotice -Name 'Resume-Service'
		Import-OS7SystemdLayer
	}
	process {
		foreach ($svc in @(Get-OS7CompatServiceTarget -Name $Name -DisplayName $DisplayName `
					-InputObject $InputObject -Include $Include -Exclude $Exclude)) {
			if (-not $PSCmdlet.ShouldProcess($svc.Name, 'thaw')) { continue }
			Resume-SystemdUnit -Name $svc.Unit -Confirm:$false | Out-Null
			if ($PassThru) { Get-OS7CompatService -Name $svc.Unit -Freezer }
		}
	}
}

function Get-OS7CompatServiceTarget {
	<#
	.SYNOPSIS
		Internal. The services a verb was aimed at, whichever way they were
		named.

	.DESCRIPTION
		Its own function so that the six writing verbs resolve their target
		identically. A verb that resolved names its own way is how `-Exclude`
		comes to be honoured by three of them and ignored by the fourth.
	#>
	param(
		[string[]]$Name,
		[string[]]$DisplayName,
		[psobject[]]$InputObject,
		[string[]]$Include,
		[string[]]$Exclude
	)

	$names = @()
	if ($InputObject -and @($InputObject).Count) {
		foreach ($o in $InputObject) {
			$names = $names + $(if ($o.PSObject.Properties['Unit']) { $o.Unit } else { [string]$o.Name })
		}
	}
	elseif ($Name -and @($Name).Count) { $names = @($Name) }

	$splat = @{}
	if ($names.Count) { $splat.Name = $names }
	if ($DisplayName -and @($DisplayName).Count) { $splat.DisplayName = $DisplayName }
	if ($Include -and @($Include).Count) { $splat.Include = $Include }
	if ($Exclude -and @($Exclude).Count) { $splat.Exclude = $Exclude }
	return @(Get-OS7CompatService @splat)
}

function Set-Service {
	<#
	.SYNOPSIS
		Changes whether a service starts at boot, or starts and stops it.

	.DESCRIPTION
		`-StartupType Disabled` MASKS the unit, which is the one place this
		layer resolves an ambiguity rather than translating one. On Windows a
		disabled service cannot be started at all; systemd's `disable` only
		removes it from boot and leaves it startable by hand. Masking is the
		state that means what the Windows word means, so that is what this
		does — and it says so, because a mask is a stronger thing than the
		script asked for in systemd's vocabulary and undoing it needs `unmask`,
		which `-StartupType Manual` does here.

		`Set-OS7Service` maps those words differently on purpose: it has a
		fourth word, `Blocked`, for the mask, because an OS/7 administrator can
		say which one they mean and a copied script cannot.

	.PARAMETER StartupType
		Automatic, AutomaticDelayedStart, Manual or Disabled. Boot and System
		are Windows kernel-driver start types and are refused: the Linux
		equivalent is the initramfs and the kernel command line, and neither is
		a unit.

	.PARAMETER Status
		Running, Stopped or Paused — start, stop, freeze.
	#>
	[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
	[OutputType('OS7.Compat.Windows.ServiceController')]
	param(
		[Parameter(ParameterSetName = 'Default', Position = 0, Mandatory,
			ValueFromPipelineByPropertyName)]
		[string]$Name,
		[Parameter(ParameterSetName = 'InputObject', Mandatory, ValueFromPipeline)]
		[psobject]$InputObject,
		[string]$DisplayName,
		[string]$Description,
		[ValidateSet('Automatic', 'AutomaticDelayedStart', 'Boot', 'Disabled',
			'Manual', 'System')]
		[string]$StartupType,
		[ValidateSet('Running', 'Stopped', 'Paused')]
		[string]$Status,
		[pscredential]$Credential,
		[string]$SecurityDescriptorSddl,
		[switch]$Force,
		[switch]$PassThru
	)

	Assert-OS7CompatSupported -Cmdlet 'Set-Service' -Bound $PSBoundParameters
	Write-OS7CompatShadowNotice -Name 'Set-Service'
	Import-OS7SystemdLayer

	if ($InputObject) {
		$target = if ($InputObject.PSObject.Properties['Unit']) { $InputObject.Unit }
		else { Resolve-OS7CompatUnitName -Name ([string]$InputObject.Name) }
	}
	else { $target = Resolve-OS7CompatUnitName -Name $Name }

	if ($StartupType) {
		if ($StartupType -in @('Boot', 'System')) {
			throw [System.NotSupportedException]::new(
				"Set-Service -StartupType $StartupType is a Windows kernel-driver start type. " +
				'On Linux the equivalent is the initramfs and the kernel command line, neither ' +
				'of which is a unit. Automatic is the earliest a unit can be asked for.')
		}
		if ($StartupType -eq 'AutomaticDelayedStart') {
			Write-Warning ('Set-Service -StartupType AutomaticDelayedStart: systemd expresses ' +
				'"later than the others" as ordering (After=, WantedBy=) and not as a delay ' +
				"flag, so $target is being ENABLED like Automatic. If the order matters, say " +
				'it with a drop-in.')
		}
		if ($StartupType -eq 'Disabled') {
			Write-Warning ("Set-Service -StartupType Disabled MASKS $target, because that is " +
				'what "cannot be started" means to systemd; `disable` alone would leave it ' +
				'startable by hand. -StartupType Manual undoes it.')
		}

		$startup = $script:OS7CompatStartupToSystemd[$StartupType]
		if ($PSCmdlet.ShouldProcess($target, "set startup to $StartupType ($startup)")) {
			# A MASK IS NOT UNDONE BY `disable`. Walking a unit back from
			# Disabled to Manual or Automatic has to unmask first, or the unit
			# reports the new startup type and still refuses to start — with
			# nothing connecting the two.
			if ($startup -ne 'Masked') {
				$now = @(Get-OS7Service -Name $target -Detailed)
				if ($now.Count -and $now[0].StartupType -like 'masked*') {
					Set-SystemdUnitStartup -Name $target -Startup 'Unmasked' -Confirm:$false |
						Out-Null
				}
			}
			Set-SystemdUnitStartup -Name $target -Startup $startup -Confirm:$false | Out-Null
		}
	}

	if ($Status) {
		switch ($Status) {
			'Running' {
				if ($PSCmdlet.ShouldProcess($target, 'start')) {
					Start-OS7Service -Name $target -Confirm:$false | Out-Null
				}
			}
			'Stopped' {
				if ($PSCmdlet.ShouldProcess($target, 'stop')) {
					Stop-OS7Service -Name $target -Confirm:$false | Out-Null
				}
			}
			'Paused' {
				if ($PSCmdlet.ShouldProcess($target, 'freeze')) {
					Suspend-SystemdUnit -Name $target -Confirm:$false | Out-Null
				}
			}
		}
	}

	if ($PassThru) { Get-OS7CompatService -Name $target -Freezer }
}

function New-Service {
	<#
	.SYNOPSIS
		Writes a new service unit and asks systemd whether it loaded.

	.DESCRIPTION
		WHAT WINDOWS CALLS A BINARY PATH IS systemd's `ExecStart=`, verbatim:
		the first word must be an ABSOLUTE path, and `%` and `$` mean what they
		mean there. This layer does not escape them, because a caller may want
		the specifiers and one that promises "what you type is what runs" has to
		escape them itself.

		The unit is written into /etc/systemd/system, validated, and read back
		from systemd — a unit file with a syntax error is written happily by the
		filesystem, refused by systemd, and `daemon-reload` exits 0 either way.

	.PARAMETER StartupType
		Defaults to Automatic, as on Windows. Automatic writes an [Install]
		section; without one a unit CANNOT be enabled at all — systemd calls
		that `static`.

	.PARAMETER DependsOn
		Units this one needs, written as both `Requires=` and `After=`.
		`Requires` alone declares a dependency and orders nothing.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Compat.Windows.ServiceController')]
	param(
		[Parameter(Position = 0, Mandatory)][string]$Name,
		[Parameter(Position = 1, Mandatory)][string]$BinaryPathName,
		[string]$DisplayName,
		[string]$Description,
		[ValidateSet('Automatic', 'AutomaticDelayedStart', 'Boot', 'Disabled',
			'Manual', 'System')]
		[string]$StartupType = 'Automatic',
		[string[]]$DependsOn,
		[pscredential]$Credential,
		[string]$SecurityDescriptorSddl
	)

	Assert-OS7CompatSupported -Cmdlet 'New-Service' -Bound $PSBoundParameters
	Write-OS7CompatShadowNotice -Name 'New-Service'
	Import-OS7SystemdLayer

	if ($StartupType -in @('Boot', 'System')) {
		throw [System.NotSupportedException]::new(
			"New-Service -StartupType $StartupType is a Windows kernel-driver start type and " +
			'has no unit equivalent. Automatic is the earliest a unit can be asked for.')
	}

	# Windows has DisplayName and Description as two fields; a unit has one.
	# Description wins when both are given, and DisplayName is what a Windows
	# script usually sets — so it is the fallback rather than being dropped.
	$text = if ($Description) { $Description } elseif ($DisplayName) { $DisplayName } else { $Name }

	$unit = Resolve-OS7CompatUnitName -Name $Name
	$newSplat = @{
		Name        = $unit
		Command     = $BinaryPathName
		Description = $text
		Enabled     = ($StartupType -in @('Automatic', 'AutomaticDelayedStart'))
	}
	if ($DependsOn -and @($DependsOn).Count) {
		$newSplat.DependsOn = @($DependsOn | ForEach-Object { Resolve-OS7CompatUnitName -Name $_ })
	}

	if (-not $PSCmdlet.ShouldProcess($unit, 'create the service')) { return }

	New-SystemdService @newSplat -Confirm:$false | Out-Null

	# The [Install] section only makes `enable` POSSIBLE; it does not enable.
	if ($StartupType -in @('Automatic', 'AutomaticDelayedStart')) {
		Set-SystemdUnitStartup -Name $unit -Startup 'Enabled' -Confirm:$false | Out-Null
	}
	elseif ($StartupType -eq 'Disabled') {
		Set-SystemdUnitStartup -Name $unit -Startup 'Masked' -Confirm:$false | Out-Null
	}

	Get-OS7CompatService -Name $unit -Freezer
}

function Remove-Service {
	<#
	.SYNOPSIS
		Removes a service unit this layer could have written.

	.DESCRIPTION
		ONLY A PLAIN FILE IN /etc/systemd/system, which is
		Remove-SystemdService's rule and not a decision taken here: a package's
		unit belongs to dpkg, and a symlink at that path is a MASK — deleting
		it would un-say an administrator's suppression rather than remove a
		service. To silence a package's service, `Set-Service -StartupType
		Disabled`.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High',
		DefaultParameterSetName = 'Default')]
	param(
		[Parameter(ParameterSetName = 'Default', Position = 0, Mandatory,
			ValueFromPipelineByPropertyName)]
		[string]$Name,
		[Parameter(ParameterSetName = 'InputObject', Mandatory, ValueFromPipeline)]
		[psobject]$InputObject
	)

	Assert-OS7CompatSupported -Cmdlet 'Remove-Service' -Bound $PSBoundParameters
	Write-OS7CompatShadowNotice -Name 'Remove-Service'
	Import-OS7SystemdLayer

	if ($InputObject) {
		$target = if ($InputObject.PSObject.Properties['Unit']) { $InputObject.Unit }
		else { Resolve-OS7CompatUnitName -Name ([string]$InputObject.Name) }
	}
	else { $target = Resolve-OS7CompatUnitName -Name $Name }

	if (-not $PSCmdlet.ShouldProcess($target, 'remove the service')) { return }
	Remove-SystemdService -Name $target -Confirm:$false
}

# ---------------------------------------------------------------------------
# The clock
# ---------------------------------------------------------------------------

function Set-TimeZone {
	<#
	.SYNOPSIS
		Sets this machine's time zone.

	.DESCRIPTION
		THE PAIR POWERSHELL LEAVES BROKEN: `Get-TimeZone` works on Linux and
		`Set-TimeZone` is absent (measured on the shipped image). This is the
		missing half, over `Set-OS7TimeZone`.

		IT TAKES WINDOWS' TIME ZONE IDS TOO. `-Id 'W. Europe Standard Time'` is
		converted to `Europe/Berlin` with
		[TimeZoneInfo]::TryConvertWindowsIdToIanaId, which works on an OS/7
		machine (measured 2026-09-09) — so a line copied out of a Windows
		script does the right thing rather than failing on a zone name Linux
		has never heard of.

	.PARAMETER Id
		An IANA zone (`Europe/Berlin`) or a Windows one (`W. Europe Standard
		Time`).

	.PARAMETER Name
		Windows matches this against a zone's display name. Here it is treated
		as -Id, because a Linux zone database has ids and no display names.

	.PARAMETER InputObject
		A TimeZoneInfo, as `Get-TimeZone` returns.

	.EXAMPLE
		Set-TimeZone -Id 'Europe/Berlin'

	.EXAMPLE
		Set-TimeZone -Id 'W. Europe Standard Time'
	#>
	[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Id')]
	param(
		[Parameter(ParameterSetName = 'Id', Position = 0, Mandatory)][string]$Id,
		[Parameter(ParameterSetName = 'Name', Mandatory)][string]$Name,
		[Parameter(ParameterSetName = 'InputObject', Mandatory, ValueFromPipeline)]
		[System.TimeZoneInfo]$InputObject,
		[switch]$PassThru
	)

	Assert-OS7CompatSupported -Cmdlet 'Set-TimeZone' -Bound $PSBoundParameters
	Write-OS7CompatShadowNotice -Name 'Set-TimeZone'

	$wanted = if ($InputObject) { $InputObject.Id } elseif ($Name) { $Name } else { $Id }

	# A Windows id first, because that is the one a copied script carries and
	# the one /usr/share/zoneinfo does not have. An id that is already IANA
	# fails the conversion and is passed through unchanged.
	$iana = $null
	if ([System.TimeZoneInfo]::TryConvertWindowsIdToIanaId($wanted, [ref]$iana) -and $iana) {
		if ($iana -ne $wanted) {
			Write-Verbose "Windows time zone id '$wanted' is '$iana' here."
		}
		$wanted = $iana
	}

	# Set-OS7TimeZone refuses a zone that is not in /usr/share/zoneinfo before
	# writing anything, and reads the symlink back afterwards. Nothing is
	# re-checked here.
	Set-OS7TimeZone -Id $wanted -WhatIf:$WhatIfPreference -Confirm:$false | Out-Null

	if ($PassThru) { Get-TimeZone }
}

# ---------------------------------------------------------------------------
# The machine, described
# ---------------------------------------------------------------------------

function Get-OS7CompatFileText {
	<#
	.SYNOPSIS
		Internal. A file's text, or $null — never an empty string for
		"unreadable".

	.DESCRIPTION
		/sys/class/dmi/id/product_serial is root-only and THROWS for anybody
		else. "This machine has no serial number" and "you may not read it" are
		different answers and a report that merges them is a report that lies.
	#>
	param([Parameter(Mandatory)][string]$Path)
	if (-not [System.IO.File]::Exists($Path)) { return $null }
	try { return [System.IO.File]::ReadAllText($Path).Trim() }
	catch { return $null }
}

function Get-ComputerInfo {
	<#
	.SYNOPSIS
		What this machine is, under the property names a Windows script reads.

	.DESCRIPTION
		WINDOWS' OWN Get-ComputerInfo RETURNS 183 PROPERTIES (counted on
		pwsh 7.6.5 on Windows, the same version OS/7 ships) and most of them
		are about Windows: the registry, page files, Device Guard, hotfixes.
		This returns the subset an OS/7 machine can answer HONESTLY, under
		Windows' exact spellings, and does not invent the rest — a property
		that is absent reads as $null, which is what a Windows script gets for
		anything it asks about and this platform does not have.

		WHERE THE VALUES COME FROM: /sys/class/dmi/id for the firmware and the
		chassis, /proc/cpuinfo and /proc/meminfo for the processors and the
		memory, /proc/uptime for the boot time, the Systemd layer for the host
		name and the signed-in users, `Get-OS7Domain` for the domain and
		`Get-OS7Version` for the product. Nothing here shells out; nothing here
		reaches systemd except through powershell/Systemd.

	.PARAMETER Property
		Return only these properties. Wildcards allowed, as on Windows.

	.EXAMPLE
		Get-ComputerInfo

	.EXAMPLE
		(Get-ComputerInfo -Property CsTotalPhysicalMemory).CsTotalPhysicalMemory
	#>
	[CmdletBinding()]
	param([Parameter(Position = 0)][string[]]$Property)

	Assert-OS7CompatSupported -Cmdlet 'Get-ComputerInfo' -Bound $PSBoundParameters
	Write-OS7CompatShadowNotice -Name 'Get-ComputerInfo'
	Import-OS7SystemdLayer

	$dmi = '/sys/class/dmi/id'
	$cpuinfo = (Get-OS7CompatFileText -Path '/proc/cpuinfo') ?? ''
	$meminfo = (Get-OS7CompatFileText -Path '/proc/meminfo') ?? ''

	$memKb = 0
	$swapKb = 0
	$freeKb = 0
	foreach ($line in ($meminfo -split "`n")) {
		if ($line -match '^MemTotal:\s+(\d+)') { $memKb = [uint64]$Matches[1] }
		elseif ($line -match '^MemAvailable:\s+(\d+)') { $freeKb = [uint64]$Matches[1] }
		elseif ($line -match '^SwapTotal:\s+(\d+)') { $swapKb = [uint64]$Matches[1] }
	}

	$logical = @($cpuinfo -split "`n" | Where-Object { $_ -match '^processor\s*:' }).Count
	$sockets = @($cpuinfo -split "`n" |
		Where-Object { $_ -match '^physical id\s*:' } |
		ForEach-Object { ($_ -split ':')[1].Trim() } |
		Sort-Object -Unique).Count
	# A VM often reports no `physical id` at all, and 0 sockets on a machine
	# with processors is a wrong answer rather than a missing one.
	if (-not $sockets) { $sockets = if ($logical) { 1 } else { 0 } }
	$modelName = @($cpuinfo -split "`n" | Where-Object { $_ -match '^model name\s*:' })
	$cpuModel = if ($modelName.Count) { ($modelName[0] -split ':', 2)[1].Trim() } else { $null }

	$uptimeText = Get-OS7CompatFileText -Path '/proc/uptime'
	$uptime = $null
	$booted = $null
	if ($uptimeText) {
		$seconds = [double](($uptimeText -split '\s+')[0])
		$uptime = [timespan]::FromSeconds($seconds)
		$booted = (Get-Date) - $uptime
	}

	$host7 = Get-SystemdHostName
	$domain = @(Get-OS7Domain -ErrorAction SilentlyContinue)
	$joined = $domain.Count -and $domain[0].Joined
	$domainName = if ($joined -and @($domain[0].ConfiguredDomains).Count) {
		@($domain[0].ConfiguredDomains)[0]
	}
	else { 'WORKGROUP' }

	$version = @(Get-OS7Version -ErrorAction SilentlyContinue)
	$osName = if ($version.Count) { "OS/7 $($version[0].Short)" } else { $null }

	$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
	$chassis = Get-OS7CompatFileText -Path "$dmi/chassis_type"
	# SMBIOS chassis types, mapped onto Windows' PowerPlatformRole vocabulary.
	# Anything not in the table is Unspecified rather than guessed at.
	$role = switch ($chassis) {
		'3' { 'Desktop' } '4' { 'Workstation' } '6' { 'Desktop' } '7' { 'Desktop' }
		'8' { 'Mobile' } '9' { 'Mobile' } '10' { 'Mobile' } '14' { 'Mobile' }
		'17' { 'EnterpriseServer' } '23' { 'EnterpriseServer' } '30' { 'Slate' }
		default { 'Unspecified' }
	}

	# ASKED, NOT GUESSED. The first version of this line read `$_.User` and
	# `Get-SystemdSession` has no such property — it is `Name`, with `Uid`
	# beside it (measured on a machine, which is where that line died).
	#
	# And `Class` is why this is not just a count of sessions: logind counts the
	# GREETER and each user's `manager` unit as sessions of their own, so a
	# machine sitting at an empty login screen would report users signed in.
	# Windows' OsNumberOfUsers means people.
	$sessions = @(Get-SystemdSession -ErrorAction SilentlyContinue)
	$users = @($sessions |
		Where-Object { $_.Class -notlike 'manager*' -and $_.Class -ne 'greeter' } |
		ForEach-Object { $_.Name } | Sort-Object -Unique).Count

	$procs = 0
	try {
		$procs = @([System.IO.Directory]::GetDirectories('/proc') |
			Where-Object { [System.IO.Path]::GetFileName($_) -match '^\d+$' }).Count
	}
	catch { $procs = 0 }

	$info = [ordered]@{
		PSTypeName                    = 'OS7.Compat.Windows.ComputerInfo'

		BiosManufacturer              = Get-OS7CompatFileText -Path "$dmi/bios_vendor"
		BiosVersion                   = Get-OS7CompatFileText -Path "$dmi/bios_version"
		BiosReleaseDate               = Get-OS7CompatFileText -Path "$dmi/bios_date"
		BiosSerialNumber              = Get-OS7CompatFileText -Path "$dmi/product_serial"
		# UEFI or not is a question about /sys/firmware/efi and nothing else.
		BiosFirmwareType              = if ([System.IO.Directory]::Exists('/sys/firmware/efi')) { 'Uefi' } else { 'Bios' }
		BiosSMBIOSPresent             = [System.IO.Directory]::Exists($dmi)

		CsName                        = $host7.Transient
		CsDNSHostName                 = $host7.Static
		CsManufacturer                = Get-OS7CompatFileText -Path "$dmi/sys_vendor"
		CsModel                       = Get-OS7CompatFileText -Path "$dmi/product_name"
		CsSystemFamily                = Get-OS7CompatFileText -Path "$dmi/product_family"
		CsDomain                      = $domainName
		CsPartOfDomain                = [bool]$joined
		# Windows' DomainRole: 0/1 workstation, 2/3 member server, 4/5 DC. An
		# OS/7 machine is a workstation, joined or not; it is never a DC.
		CsDomainRole                  = if ($joined) { 'MemberWorkstation' } else { 'StandaloneWorkstation' }
		CsNumberOfLogicalProcessors   = $logical
		CsNumberOfProcessors          = $sockets
		CsProcessors                  = $cpuModel
		CsTotalPhysicalMemory         = $memKb * 1024
		CsPhysicallyInstalledMemory   = $memKb
		CsSystemType                  = switch ("$arch") {
			'X64' { 'x64-based PC' } 'Arm64' { 'ARM64-based PC' } default { "$arch" }
		}
		CsUserName                    = [System.Environment]::UserName
		CsHypervisorPresent           = ($cpuinfo -match '(?m)^flags\s*:.*\bhypervisor\b')
		CsPCSystemType                = $role

		OsName                        = $osName
		OsType                        = 'Linux'
		OsVersion                     = if ($version.Count) { $version[0].Full } else { $null }
		OsBuildNumber                 = if ($version.Count) { $version[0].Full } else { $null }
		OsManufacturer                = 'up in blue GmbH'
		OsArchitecture                = '64-bit'
		OsHardwareAbstractionLayer    = Get-OS7CompatFileText -Path '/proc/sys/kernel/osrelease'
		OsLocalDateTime               = Get-Date
		OsLastBootUpTime              = $booted
		OsUptime                      = $uptime
		OsNumberOfProcesses           = $procs
		OsNumberOfUsers               = $users
		OsTotalVisibleMemorySize      = $memKb
		OsFreePhysicalMemory          = $freeKb
		OsTotalSwapSpaceSize          = $swapKb
		OsStatus                      = 'OK'
		OsLocale                      = [System.Globalization.CultureInfo]::CurrentCulture.Name

		TimeZone                      = (Get-TimeZone).DisplayName
		PowerPlatformRole             = $role
		HyperVisorPresent             = ($cpuinfo -match '(?m)^flags\s*:.*\bhypervisor\b')
	}

	$obj = [pscustomobject]$info
	if (-not $Property -or -not @($Property).Count) { return $obj }

	# -Property, as Windows does it: a filtered object, wildcards allowed.
	$keep = @($obj.PSObject.Properties.Name | Where-Object {
			$candidate = $_
			@($Property | Where-Object { $candidate -like $_ }).Count -gt 0
		})
	if (-not $keep.Count) { return $null }
	return $obj | Select-Object -Property $keep
}

function Rename-Computer {
	<#
	.SYNOPSIS
		Renames this machine.

	.DESCRIPTION
		THREE NAMES CHANGE TOGETHER OR THE MACHINE IS HALF-RENAMED: the static
		name in /etc/hostname, the transient one the kernel carries, and the
		`127.0.1.1` line in /etc/hosts. `Set-SystemdHostName` does all three
		and reads the kernel back — the last one matters more than it looks,
		because sudo resolves its own host name on every invocation and a
		machine renamed without it answers `sudo: unable to resolve host` to
		every command afterwards.

		A JOINED MACHINE IS REFUSED. The keytab holds Kerberos principals for
		the OLD name, so the moment the name changes every ticket for this host
		is for a host that no longer exists — sssd stops resolving domain
		accounts and the failure presents as "the password is wrong". Windows
		renames the computer account in the directory for you and this
		deliberately does not: leave the domain, rename, join again.

	.PARAMETER NewName
		The new host name. Validated against RFC 1123 before anything is
		written.

	.PARAMETER Restart
		Restart afterwards — through the OS/7 Restart-Computer, which reboots
		rather than powering the machine off.

	.PARAMETER Force
		Accepted; there is no confirmation prompt beyond -Confirm here.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory)][string]$NewName,
		[string]$ComputerName,
		[pscredential]$DomainCredential,
		[pscredential]$LocalCredential,
		[string]$WsmanAuthentication,
		[switch]$Force,
		[switch]$Restart,
		[switch]$PassThru
	)

	Assert-OS7CompatSupported -Cmdlet 'Rename-Computer' -Bound $PSBoundParameters
	Write-OS7CompatShadowNotice -Name 'Rename-Computer'
	Import-OS7SystemdLayer

	$domain = @(Get-OS7Domain -ErrorAction SilentlyContinue)
	if ($domain.Count -and $domain[0].Joined) {
		throw [System.InvalidOperationException]::new(
			"This machine is joined to $(@($domain[0].ConfiguredDomains) -join ', ') and " +
			'renaming it would leave its keytab holding principals for the old name — ' +
			'Kerberos would stop working and would report it as a wrong password. ' +
			'Remove-OS7Domain, then Rename-Computer, then Join-OS7Domain.')
	}

	if (-not $PSCmdlet.ShouldProcess($NewName, 'rename this machine')) { return }

	$result = @(Set-SystemdHostName -Name $NewName -Confirm:$false)

	if ($Restart) { Restart-Computer -Confirm:$false }
	if ($PassThru -and $result.Count) {
		return [pscustomobject]@{
			PSTypeName    = 'OS7.Compat.Windows.RenameComputerChangeInfo'
			OldComputerName = $null
			NewComputerName = $result[0].Transient
			HasSucceeded    = ($result[0].Transient -eq $NewName)
		}
	}
}

# ---------------------------------------------------------------------------
# The two that exist and do the wrong thing
#
# THESE SHADOW A REAL CMDLET, DELIBERATELY, and it is the only place in this
# file that does. PowerShell 7.6.5 has both of them on Linux, and both run
# `/usr/sbin/shutdown` with no arguments — which is systemctl's compatibility
# interface with no action flag, whose default is POWEROFF. So the shipped
# `Restart-Computer` powers an OS/7 machine off, reports success, and the
# machine's console says `Reached target poweroff.target` (measured
# 2026-09-09; upstream PowerShell/PowerShell#14684 since 2021).
#
# P1's objection to shadowing — a name that is free today may not be tomorrow,
# and a shadowed cmdlet with a different parameter set is worse than a missing
# one — is about shadowing something that WORKS. Neither of these does.
# ---------------------------------------------------------------------------

function Restart-Computer {
	<#
	.SYNOPSIS
		Restarts this machine — and restarts it, rather than powering it off.

	.DESCRIPTION
		WHY THIS EXISTS RATHER THAN USING POWERSHELL'S OWN. PowerShell's
		`Restart-Computer` on Linux runs `/usr/sbin/shutdown` with no arguments
		at all. On Ubuntu that path is a symlink to `systemctl`, whose
		`shutdown` compatibility interface takes the action as a flag and
		defaults to POWEROFF without one — so the shipped cmdlet powers the
		machine off and reports success. Measured on a machine: after it, the
		console said `Reached target poweroff.target` and `reboot: Power down`.

		This goes through `Invoke-SystemdShutdown -Action Reboot`, which says
		`systemctl reboot` — an action no argv[0] can re-interpret.

		A REFUSAL IS LOUD. Without root, polkit refuses and this throws with
		what it said, rather than returning quietly and leaving a machine that
		did not restart.

		The real cmdlet is still reachable as
		`Microsoft.PowerShell.Management\Restart-Computer`, and it still does
		the wrong thing.

	.PARAMETER Force
		Accepted and needs no work: `systemctl reboot` does not ask the
		signed-in users' permission in the first place. Kept so that a copied
		`Restart-Computer -Force` binds — PowerShell's own cmdlet on Linux
		carries NO parameters at all, so that line fails there on the
		parameter.

	.PARAMETER Delay
		Schedule the restart instead of doing it now. Whole minutes, which is
		`shutdown`'s own granularity, and the schedule is read back.

	.PARAMETER Message
		A wall message for the signed-in users; only meaningful with -Delay.

	.EXAMPLE
		Restart-Computer

	.EXAMPLE
		Restart-Computer -Delay ([timespan]::FromMinutes(5)) -Message 'Patching'
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[string[]]$ComputerName,
		[pscredential]$Credential,
		[switch]$Force,
		[switch]$Wait,
		[int]$Timeout,
		[string]$For,
		[int]$Delay,
		[string]$WsmanAuthentication,
		[string]$Message
	)

	Assert-OS7CompatSupported -Cmdlet 'Restart-Computer' -Bound $PSBoundParameters
	Import-OS7SystemdLayer

	$splat = @{ Action = 'Reboot' }
	# Windows' -Delay is SECONDS between polls of a machine coming back, which
	# is meaningless here; this one is a delay before the restart, in minutes,
	# and the help says so. It is the same word for a different thing because
	# there is no third spelling a copied script would carry.
	if ($PSBoundParameters.ContainsKey('Delay')) {
		$splat.Delay = [timespan]::FromMinutes($Delay)
	}
	if ($Message) { $splat.Message = $Message }

	if (-not $PSCmdlet.ShouldProcess('this machine', 'restart')) { return }
	Invoke-SystemdShutdown @splat -Confirm:$false
}

function Stop-Computer {
	<#
	.SYNOPSIS
		Powers this machine off.

	.DESCRIPTION
		PowerShell's own `Stop-Computer` reaches the right outcome here by
		accident — it runs `/usr/sbin/shutdown` with no arguments, whose
		default action happens to be poweroff. This one asks for `systemctl
		poweroff` explicitly, so the outcome does not depend on a default, and
		a refusal is thrown rather than swallowed.

	.PARAMETER Force
		Accepted and needs no work — see Restart-Computer -Force.

	.PARAMETER Delay
		Schedule it instead, in whole minutes.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[string[]]$ComputerName,
		[pscredential]$Credential,
		[switch]$Force,
		[string]$WsmanAuthentication,
		[int]$Delay,
		[string]$Message
	)

	Assert-OS7CompatSupported -Cmdlet 'Stop-Computer' -Bound $PSBoundParameters
	Import-OS7SystemdLayer

	$splat = @{ Action = 'PowerOff' }
	if ($PSBoundParameters.ContainsKey('Delay')) {
		$splat.Delay = [timespan]::FromMinutes($Delay)
	}
	if ($Message) { $splat.Message = $Message }

	if (-not $PSCmdlet.ShouldProcess('this machine', 'power off')) { return }
	Invoke-SystemdShutdown @splat -Confirm:$false
}
