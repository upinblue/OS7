# =============================================================================
# OS/7 — the management plane: Entra ID, Intune, Azure Arc
#
# THE REASON THIS PRODUCT EXISTS, and therefore the group where an honest
# "cannot tell" matters most. A cmdlet that guesses about enrolment is a cmdlet
# that tells an administrator their fleet is fine.
#
# NO GENERIC LAYER, and P2's test is why: authd, intune and azcmagent are not a
# subsystem OS/7 sits on top of — they ARE the product. There is no vocabulary
# here that would serve another host.
#
# WHAT WAS MEASURED, 2026-08-27, out of the SHIPPED squashfs of
# OS7-1.0.0.116-amd64.iso rather than out of a container derived from it
# (BUILD-NOTES #93 is why that distinction is spelled out):
#
#   * `authd 0.6.1ubuntu0.1` is installed, and `/etc/pam.d/common-auth` runs
#     `pam_authd_exec.so` — so the login path is wired for Entra.
#   * `/etc/authd/brokers.d/` IS EMPTY. authd's own binary names that directory
#     as where it detects brokers, and there is none. **Entra sign-in cannot
#     work on an OS/7 image as built today.** That is C8a
#     (docs/CURATION-AND-DELIVERY-PLAN.md) measured on the artefact instead of
#     reasoned about, and it is the first thing Get-OS7EntraStatus reports.
#   * `intune-portal 1.2607.4` and `microsoft-identity-broker 3.0.2` are
#     installed; `pam_intune.so` is in the auth stack.
#   * **`intune-agent` has NO status interface.** Its whole option set is
#     `-i/--interactive`, `-s/--socket-path`, `-h`, `-V`. There is a control
#     socket at `/run/intune/daemon.socket` and nothing that answers "is this
#     device enrolled". So `Enrolled` is `$null` and says why.
#   * **`azcmagent` is NOT installed.** The .deb is staged at
#     `/var/cache/os7/packages/` with a README saying the INSTALLER must place
#     it, because its postinst needs a running systemd and ends in dpkg state
#     `iF` inside a live-build chroot. That is deliberate, not a defect.
#
# Dot-sourced by OS7.psm1.
# =============================================================================

$script:OS7AuthdBrokerDir = '/etc/authd/brokers.d'
$script:OS7PamCommonAuth = '/etc/pam.d/common-auth'
$script:OS7IntuneRoot = '/opt/microsoft/intune'
$script:OS7IntuneSocket = '/run/intune/daemon.socket'
$script:OS7StagedPackageDir = '/var/cache/os7/packages'

function Get-OS7PackageVersion {
	<#
	.SYNOPSIS
		Internal. A package's installed version, or $null if it is not installed.

	.DESCRIPTION
		`dpkg-query -W -f='${Version}'` and not `dpkg -s | grep`: the second
		exits 0 with empty output for a package that was removed but not purged,
		which reads as installed-with-no-version.
	#>
	param([Parameter(Mandatory)][string]$Name)

	try {
		$v = Invoke-OS7Native -Command 'dpkg-query' -Arguments @(
			'-W', '-f=${Status} ${Version}', $Name)
	}
	catch { return $null }

	# `install ok installed 1.2.3` is the only state that counts. `deinstall ok
	# config-files` still has a version and is not an installed package.
	if ($v -match '^install ok installed\s+(\S+)') { return $Matches[1] }
	return $null
}

function Test-OS7PamModule {
	<#
	.SYNOPSIS
		Internal. Is this PAM module in the machine's auth stack?

	.DESCRIPTION
		Reads /etc/pam.d/common-auth. Comments are skipped, because a module
		that has been commented out is a module that does not run — and the
		difference between "configured" and "present in the file" is the whole
		question.
	#>
	param([Parameter(Mandatory)][string]$Module, [string]$Path)

	if (-not $Path) { $Path = $script:OS7PamCommonAuth }
	if (-not [System.IO.File]::Exists($Path)) { return $null }

	foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
		$t = $line.Trim()
		if (-not $t -or $t.StartsWith('#')) { continue }
		if ($t -match [regex]::Escape($Module)) { return $true }
	}
	return $false
}

function Get-OS7ServiceState {
	<#
	.SYNOPSIS
		Internal. One service's state, or $null when systemd cannot be asked.

	.DESCRIPTION
		$null and not 'inactive'. A container, a chroot and a rescue shell all
		have no systemd, and reporting a service as stopped on a machine where
		nothing could be asked is the failure this repository keeps re-learning.
	#>
	param([Parameter(Mandatory)][string]$Name)

	try {
		$s = @(Get-OS7Service -Name $Name -Detailed)
		if ($s.Count -eq 0) { return $null }
		return $s[0]
	}
	catch { return $null }
}

function Get-OS7EntraStatus {
	<#
	.SYNOPSIS
		Whether this machine can sign a user in with Entra ID — and if not, why
		not.

	.DESCRIPTION
		THE ANSWER ON AN OS/7 IMAGE AS BUILT TODAY IS NO, and the field that
		says so is `BrokerRegistered`. authd is installed, PAM is wired to it,
		and `/etc/authd/brokers.d/` is empty — measured on the shipped ISO. authd
		bridges the system to external brokers; with no broker registered it has
		nothing to bridge to, and a sign-in attempt fails in a way that looks
		like a wrong password.

		That is C8a in docs/CURATION-AND-DELIVERY-PLAN.md: `authd-msentraid` is
		a Canonical SNAP, and seeding snaps into a live-build image is unsolved
		here. This cmdlet does not fix it; it stops it being invisible.

		`Ready` is the conjunction, and it is `$null` rather than `$false` when
		systemd could not be asked at all — a machine in a rescue shell is not a
		machine with a broken identity stack.

	.EXAMPLE
		Get-OS7EntraStatus

	.EXAMPLE
		(Get-OS7EntraStatus).Detail
	#>
	[CmdletBinding()]
	param()

	$authd = Get-OS7PackageVersion -Name 'authd'
	$broker = Get-OS7PackageVersion -Name 'microsoft-identity-broker'

	$brokers = @()
	if ([System.IO.Directory]::Exists($script:OS7AuthdBrokerDir)) {
		$brokers = @([System.IO.Directory]::GetFiles($script:OS7AuthdBrokerDir, '*.conf') |
			ForEach-Object { [System.IO.Path]::GetFileName($_) })
	}

	$pam = Test-OS7PamModule -Module 'pam_authd_exec.so'
	$svc = Get-OS7ServiceState -Name 'authd.service'
	$registered = ($brokers.Count -gt 0)

	[pscustomobject]@{
		AuthdInstalled     = [bool]$authd
		AuthdVersion       = $authd
		IdentityBrokerVersion = $broker
		# THE FIELD THAT MATTERS. Empty on every OS/7 image built so far.
		BrokerRegistered   = $registered
		Brokers            = $brokers
		BrokerDirectory    = $script:OS7AuthdBrokerDir
		# $null when there is no common-auth to read, never $false.
		PamConfigured      = $pam
		ServiceState       = if ($svc) { $svc.ActiveState } else { $null }
		ServiceHealthy     = if ($svc) { $svc.Healthy } else { $null }
		# $null when systemd could not be asked: "cannot tell" is not "broken".
		Ready              = if ($null -eq $svc -or $null -eq $pam) { $null }
		else { [bool]$authd -and $registered -and $pam -and ($svc.ActiveState -eq 'active') }
		Detail             = if (-not $authd) { 'authd is not installed; this machine cannot use Entra at all' }
		elseif (-not $registered) {
			"authd is installed and PAM is wired to it, but $($script:OS7AuthdBrokerDir) " +
			'is empty — there is no Entra broker for it to talk to, so a sign-in ' +
			'will fail as though the password were wrong. See C8a: authd-msentraid ' +
			'is a snap and is not seeded into the image.'
		}
		elseif ($pam -eq $false) { 'a broker is registered but PAM does not run authd, so nothing uses it' }
		elseif ($svc -and $svc.ActiveState -ne 'active') { "authd.service is $($svc.ActiveState)" }
		else { 'authd is installed, a broker is registered and PAM runs it' }
	}
}

function Get-OS7IntuneEnrollment {
	<#
	.SYNOPSIS
		What can be said about Intune on this machine — and what cannot.

	.DESCRIPTION
		`Enrolled` IS `$null`, DELIBERATELY AND ALWAYS FOR NOW. Measured
		2026-08-27: `intune-agent`'s entire option set is `--interactive`,
		`--socket-path`, `--help` and `--version`. There is no status verb, and
		this repository has never had an enrolled machine to learn the on-disk
		state from. Reporting `$false` would be a guess that reads as a fact,
		and on a compliance question that is the worst possible kind.

		What CAN be answered is answered: the packages, whether `pam_intune.so`
		is in the auth stack, whether the daemon is running, and whether its
		control socket exists — which is the closest thing to evidence that the
		daemon is not merely started but listening.

	.EXAMPLE
		Get-OS7IntuneEnrollment
	#>
	[CmdletBinding()]
	param()

	$portal = Get-OS7PackageVersion -Name 'intune-portal'
	$pam = Test-OS7PamModule -Module 'pam_intune.so'
	$svc = Get-OS7ServiceState -Name 'intune-daemon.service'
	$socket = [System.IO.File]::Exists($script:OS7IntuneSocket) -or
		[System.IO.Directory]::Exists([System.IO.Path]::GetDirectoryName($script:OS7IntuneSocket))

	$binaries = @()
	$binDir = [System.IO.Path]::Combine($script:OS7IntuneRoot, 'bin')
	if ([System.IO.Directory]::Exists($binDir)) {
		$binaries = @([System.IO.Directory]::GetFiles($binDir) |
			ForEach-Object { [System.IO.Path]::GetFileName($_) })
	}

	[pscustomobject]@{
		Installed     = [bool]$portal
		Version       = $portal
		Binaries      = $binaries
		PamConfigured = $pam
		DaemonState   = if ($svc) { $svc.ActiveState } else { $null }
		DaemonHealthy = if ($svc) { $svc.Healthy } else { $null }
		SocketPath    = $script:OS7IntuneSocket
		SocketPresent = $socket
		# NOT $false. See the description: there is nothing on this machine that
		# can be asked, and a guess about compliance is worse than a gap.
		Enrolled      = $null
		EnrolledReason = 'intune-agent exposes no status interface (measured: its ' +
		'options are --interactive, --socket-path, --help, --version), and no ' +
		'enrolled machine has ever been available to learn the on-disk state ' +
		'from. Enrolment is visible in the Intune portal, not here.'
		Detail        = if (-not $portal) { 'intune-portal is not installed (arm64 is server-only and has no Intune)' }
		elseif ($pam -eq $false) { 'installed, but pam_intune.so is not in the auth stack' }
		elseif ($svc -and $svc.ActiveState -ne 'active') { "installed and wired; intune-daemon.service is $($svc.ActiveState)" }
		else { 'installed and wired; whether the device is ENROLLED cannot be answered here' }
	}
}

function Get-OS7ArcStatus {
	<#
	.SYNOPSIS
		Azure Arc: whether the Connected Machine agent is installed, and what it
		says about itself.

	.DESCRIPTION
		ON AN OS/7 IMAGE IT IS NOT INSTALLED, AND THAT IS ON PURPOSE. Measured:
		`azcmagent` is absent and its .deb is staged at
		`/var/cache/os7/packages/` with a README explaining why — its postinst
		requires a running systemd and ends in dpkg state `iF` if forced inside a
		live-build chroot. The installer places it on the target. `StagedPackage`
		reports that, so "not installed" does not read as "missing".

		WHEN IT IS INSTALLED, `azcmagent show --json` is passed through
		UNRESHAPED. This repository has never seen that output, and typing
		fields nobody has measured is the assertion it does not make — the same
		decision `Get-NetRadio` takes about rfkill's device list.

	.EXAMPLE
		Get-OS7ArcStatus
	#>
	[CmdletBinding()]
	param()

	$version = Get-OS7PackageVersion -Name 'azcmagent'

	$staged = @()
	if ([System.IO.Directory]::Exists($script:OS7StagedPackageDir)) {
		$staged = @([System.IO.Directory]::GetFiles($script:OS7StagedPackageDir, 'azcmagent*.deb') |
			ForEach-Object { [System.IO.Path]::GetFileName($_) })
	}

	$raw = $null
	$reason = $null
	if ($version) {
		try {
			$out = Invoke-OS7Native -Command 'azcmagent' -Arguments @('show', '--json')
			$raw = $out | ConvertFrom-Json
		}
		catch { $reason = $_.Exception.Message }
	}

	[pscustomobject]@{
		Installed      = [bool]$version
		Version        = $version
		StagedPackage  = $staged
		StagedIn       = $script:OS7StagedPackageDir
		# Passed through as azcmagent gave it. Never reshaped — see the
		# description.
		Raw            = $raw
		Reason         = $reason
		# $null when the agent is not installed: a machine with no agent is not
		# a disconnected machine, it is a machine that was never connected.
		Connected      = if (-not $version) { $null }
		elseif ($raw -and $raw.PSObject.Properties.Name -contains 'status') { $raw.status -eq 'Connected' }
		else { $null }
		Detail         = if (-not $version -and $staged.Count) {
			"azcmagent is not installed; $($staged -join ', ') is staged in " +
			"$($script:OS7StagedPackageDir) for the installer to place, which is " +
			'deliberate — its postinst needs a running systemd'
		}
		elseif (-not $version) { 'azcmagent is not installed and no package is staged' }
		elseif ($reason) { "azcmagent is installed but could not be asked: $reason" }
		else { 'azcmagent is installed; Raw carries what it reported' }
	}
}

function Get-OS7ManagementStatus {
	<#
	.SYNOPSIS
		The three management paths in one answer: can this machine sign users
		in, be managed, and be inventoried?

	.DESCRIPTION
		THREE FIELDS AND NOT ONE VERDICT. Entra, Intune and Arc fail
		independently and are fixed independently, and a single boolean would
		make the commonest state of an OS/7 machine today — Entra unusable
		because no broker is seeded, everything else fine — look like a machine
		with nothing working.

		`Reachable` comes from `Test-OS7Network`, so a machine that is
		configured correctly and cannot reach Microsoft is distinguishable from
		one that is configured wrongly. That is a different site visit.

	.PARAMETER SkipNetwork
		Do not test the endpoints. The network test opens TCP connections to
		Microsoft, which is exactly what the cmdlet is for and is still worth
		being able to decline on a machine somebody is being careful with.

	.EXAMPLE
		Get-OS7ManagementStatus | Format-List
	#>
	[CmdletBinding()]
	param([switch]$SkipNetwork)

	$entra = Get-OS7EntraStatus
	$intune = Get-OS7IntuneEnrollment
	$arc = Get-OS7ArcStatus

	$net = $null
	if (-not $SkipNetwork) {
		try { $net = Test-OS7Network } catch { }
	}

	[pscustomobject]@{
		Entra     = $entra
		Intune    = $intune
		Arc       = $arc
		Reachable = if ($net) { $net.Ok } else { $null }
		Endpoints = if ($net) { $net.Endpoints } else { @() }
		# The one line an operator reads first. It names the blocking problem
		# rather than summarising three of them into a colour.
		Summary   = if ($entra.Ready -eq $false) { $entra.Detail }
		elseif ($net -and -not $net.Ok) { 'the identity stack is configured but Microsoft is not reachable' }
		elseif ($entra.Ready) { 'Entra is usable; Intune enrolment cannot be verified from the machine' }
		else { 'systemd could not be asked, so nothing here is a verdict' }
	}
}
