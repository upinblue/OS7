# =============================================================================
# Tailscale — the first vendor application role
#
# docs/VENDOR-APPS-PLAN.md VA9-VA16, measured in docs/SESSION-TAILSCALE.md and
# docs/SESSION-VENDOR-SOURCES.md. The generic half — admitting the vendor's
# source, keeping it current, telling drift apart — is OS7.PackageSource.ps1;
# this file is what Tailscale needs ON TOP of it, and nothing it could share.
#
# A ROLE, NOT A FEATURE OF THE MEDIUM (VA1). Nothing here is on an image until
# Install-OS7Tailscale runs, the version is Tailscale's stable channel and not
# the pin's, and the pin carries only the trust: where from, signed by whom.
#
# FIVE MEASUREMENTS DECIDE THIS FILE:
#
#   * THE STATE IS AN IDENTITY (M-TS6). The documented install keeps
#     /var/lib/tailscale — the node's private key — in the boot environment, so
#     a rollback restores an identity the tailnet has already replaced, and every
#     environment carries a copy of the key. So the dataset comes BEFORE the
#     package (VA9), it is not backed up (a node key restored onto a second
#     machine is two machines with one identity), and a documented install is
#     ADOPTED — moved onto the dataset with its identity — never refused for
#     ever and never silently left.
#
#   * A LOGIN REPLACES WHAT `up` HAS NO FLAG FOR (O-M2, measured 2026-11-10).
#     The plan said to set --auto-update=false BEFORE the first login so the
#     tailnet's default could not decide it. Measured against a control server
#     whose default is on: the local choice came out of `up` and out of
#     `login` as Apply=true, twice. `set` AFTER the login held across 45 s, a
#     daemon restart and an `up` while running; `logout` and `down` + `up`
#     reset it to "not decided". So Connect-OS7Tailscale sets the two
#     preferences AFTER the daemon reports Running, and Get-OS7Tailscale
#     reports anything but an explicit off.
#
#   * THE JOB RUNNER COUNTS ONLY A THROW (M-TS7). A native `tailscale up` that
#     exited 1 inside Start-OS7Job was a job that succeeded. So the login job
#     calls Connect-Tailscale and THROWS on its verdict, and then this file asks
#     the daemon anyway: Running and an address are the result.
#
#   * AN AUTH KEY IS NEVER A VALUE HERE. It is a secret in OS/7's store
#     (New-OS7Secret, TPM-sealed), delivered to the job by systemd as a file in
#     $CREDENTIALS_DIRECTORY, and passed to the CLI as `--auth-key=file:<path>`.
#     The job's parameters arrive as its input document (AU3), so the command
#     text is a constant and nothing an operator typed is spliced into code.
#
#   * TAILSCALE SSH AND THE CLIENT'S UPDATER ARE OFF, AND REPORTED WHEN ON
#     (owner's decision 3; VA7, VA14). Tailscale SSH runs a command even when
#     PAM's account checks refuse the account (SESSION-TAILSCALE §8); the
#     updater runs apt in the running system with --allow-downgrades (§12). No
#     verb here switches either on.
#
# LAYERING: no `tailscale` here (P2-tailscale), no apt (P2-apt), no zfs (Z1).
# =============================================================================

$script:OS7TailscaleName      = 'tailscale'
$script:OS7TailscalePackage   = 'tailscale'
$script:OS7TailscaleUnit      = 'tailscaled.service'
$script:OS7TailscaleStateDir  = '/var/lib/tailscale'
$script:OS7TailscaleStateFile = 'tailscaled.state'
# A key that expires inside this many days is said out loud. A tagged node's key
# does not expire at all (measured), so this is about nodes logged in as a person.
$script:OS7TailscaleExpiryWarnDays = 14

# THE LOGIN JOB, AS A CONSTANT. Everything variable arrives in $OS7JobInput
# (AU3) — the secret's NAME, never its value — so nothing an operator typed
# becomes code. Connect-Tailscale reports; this throws on its verdict because
# the runner counts only a throw (M-TS7).
$script:OS7TailscaleLoginCommand = @'
Import-Module Tailscale -ErrorAction Stop
$i = $OS7JobInput
$p = @{
	AuthKeyFile = ([string]$env:CREDENTIALS_DIRECTORY).TrimEnd('/') + '/' + [string]$i.secret
	TimeoutSec  = [int]$i.timeoutSec
}
if ($i.loginServer) { $p.LoginServer = [string]$i.loginServer }
if ($i.hostname) { $p.Hostname = [string]$i.hostname }
if (@($i.tags).Count -and $i.tags[0]) { $p.AdvertiseTag = @($i.tags | ForEach-Object { [string]$_ }) }
if ($null -ne $i.acceptDns) { $p.AcceptDns = [bool]$i.acceptDns }
$r = Connect-Tailscale @p
if (-not $r.Succeeded) { throw "tailscale up did not log in: $($r.Error)" }
'tailscale up: logged in'
'@

function Import-OS7TailscaleLayer {
	<#
	.SYNOPSIS
		Internal. Make the Tailscale module available, lazily — the same shape as
		Import-OS7AptLayer (BUILD-NOTES #38, #82).
	#>
	if (Get-Module -Name Tailscale) { return }
	$candidates = @(
		(Join-Path (Split-Path -Parent $PSScriptRoot) 'Tailscale/Tailscale.psd1'),
		'/usr/local/share/powershell/Modules/Tailscale/Tailscale.psd1'
	)
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			Import-Module $c -Force -ErrorAction Stop
			Write-OS7Step "tailscale layer: $c"
			return
		}
	}
	Import-Module Tailscale -Force -ErrorAction Stop
	Write-OS7Step 'tailscale layer: Tailscale (by name)'
}

# =============================================================================
# The facts, and the judgements made from them
#
# GATHERING AND JUDGING ARE TWO FUNCTIONS, so check-tailscale-logic.py can hand
# the judgement recorded facts and ask what an administrator would be told —
# New-OS7JobDropInText's argument, applied to a report.
# =============================================================================

function Get-OS7TailscaleFacts {
	<#
	.SYNOPSIS
		Internal. Everything the role's judgements read, asked of the machine
		once: the package, its source, the state's layout, the daemon, and what
		the client says.
	#>
	param()

	Import-OS7AptLayer
	Import-OS7TailscaleLayer
	Import-OS7SystemdLayer

	$pkg = @(Get-AptPackage -Name $script:OS7TailscalePackage | Where-Object Installed) | Select-Object -First 1
	$policy = $null
	try { $policy = @(Get-AptPolicy -Package $script:OS7TailscalePackage) | Select-Object -First 1 } catch { $policy = $null }

	$registered = $null
	try { $registered = @(Get-OS7PackageSource -Name $script:OS7TailscaleName -ErrorAction Stop) | Select-Object -First 1 }
	catch { $registered = $null }
	$vendor = Get-OS7ReleaseVendor -Name $script:OS7TailscaleName
	$vendorHost = $null
	if ($vendor) { $u = $null; if ([System.Uri]::TryCreate($vendor.Uri, 'Absolute', [ref]$u)) { $vendorHost = $u.Host } }
	$others = @()
	if ($vendorHost) {
		$others = @(Get-OS7PackageSource -All | Where-Object {
				$_.Class -eq 'Unregistered' -and @($_.Hosts) -contains $vendorHost })
	}

	$dataset = @(Get-OS7ServiceDataset -Name $script:OS7TailscaleName) | Select-Object -First 1
	$unit = $null
	try { $unit = @(Get-SystemdUnit -Name $script:OS7TailscaleUnit) | Select-Object -First 1 } catch { $unit = $null }

	$version = Get-TailscaleVersion
	$status = $null
	$prefs = $null
	if ($version) {
		$status = Get-TailscaleStatus
		if ($status.Reachable) {
			try { $prefs = Get-TailscalePreference } catch { $prefs = $null }
		}
	}

	return [pscustomobject]@{
		Package       = $pkg
		Policy        = $policy
		Registered    = $registered
		VendorHost    = $vendorHost
		OtherSources  = $others
		Dataset       = $dataset
		StateDirectory = [System.IO.Directory]::Exists($script:OS7TailscaleStateDir)
		StateFile     = [System.IO.File]::Exists("$($script:OS7TailscaleStateDir)/$($script:OS7TailscaleStateFile)")
		Unit          = $unit
		Version       = $version
		Status        = $status
		Preference    = $prefs
		Now           = [datetime]::UtcNow
	}
}

function Get-OS7TailscaleLayout {
	<#
	.SYNOPSIS
		Internal. Where the node's state lives, in one word.

	.DESCRIPTION
		  OS7                the dataset is mounted at /var/lib/tailscale,
		                     outside the boot environment
		  InBootEnvironment  tailscaled's state FILE is in a directory of the
		                     boot environment — the vendor's documented
		                     install, or somebody's apt install — and a
		                     rollback reaches it
		  Broken             the dataset exists and is not mounted there:
		                     whatever tailscaled writes now lands in the boot
		                     environment UNDER the empty mount point
		  None               neither

		THE FILE, NOT THE DIRECTORY. Destroying the dataset leaves its empty
		mount point behind, and a layout keyed on the directory called that
		"state in the boot environment" — so after Uninstall-OS7Tailscale
		-RemoveState, the next Install-OS7Tailscale refused to install over
		an identity that did not exist (run-tailscale.py, 2026-11-12). A
		daemon that has run once has written tailscaled.state, so the file is
		what an identity looks like.
	#>
	param([Parameter(Mandatory)]$Facts)
	$d = $Facts.Dataset
	if ($d) {
		if ($d.Mounted -and $d.MountPoint -eq $script:OS7TailscaleStateDir -and -not $d.InBootEnvironment) { return 'OS7' }
		return 'Broken'
	}
	if ($Facts.StateFile) { return 'InBootEnvironment' }
	return 'None'
}

function Get-OS7TailscaleAttention {
	<#
	.SYNOPSIS
		Internal. What an administrator must be told about this machine's
		Tailscale, as sentences, each with the command that answers it — and the
		facts that are always true of a tailnet node, apart.

	.DESCRIPTION
		VA13. Attention is for what needs a decision or a repair; Notes for what
		is a property of the product and stays true on a healthy machine (the
		firewall sentence, M-TS8). An empty Attention is the answer "nothing to
		do", so nothing that is merely informative goes in it.
	#>
	param([Parameter(Mandatory)]$Facts)

	$attention = [System.Collections.Generic.List[string]]::new()
	$notes = [System.Collections.Generic.List[string]]::new()
	$layout = Get-OS7TailscaleLayout -Facts $Facts
	$installed = [bool]$Facts.Package
	$s = $Facts.Status
	$p = $Facts.Preference

	if (-not $installed) {
		if ($layout -eq 'OS7' -or $layout -eq 'Broken') {
			$notes.Add("Tailscale is not installed; its state dataset $($Facts.Dataset.Dataset) is kept, with this machine's " +
				'identity in it. Install-OS7Tailscale uses it again; Uninstall-OS7Tailscale -RemoveState destroys it.')
		}
		return [pscustomobject]@{ Layout = $layout; Attention = $attention.ToArray(); Notes = $notes.ToArray() }
	}

	switch ($layout) {
		'InBootEnvironment' {
			$attention.Add('Its state — this machine''s identity in the tailnet, private key included — is inside the boot ' +
				'environment at /var/lib/tailscale: a rollback restores an identity the tailnet may already have replaced, ' +
				'and every boot environment keeps a copy of the key. Install-OS7Tailscale -Adopt moves it onto a dataset ' +
				'of its own and keeps the identity.')
		}
		'Broken' {
			$attention.Add("Its state dataset $($Facts.Dataset.Dataset) is not mounted at $($script:OS7TailscaleStateDir) " +
				"(mountpoint $($Facts.Dataset.MountPoint), mounted: $($Facts.Dataset.Mounted)): whatever tailscaled writes " +
				'now lands in the boot environment. Install-OS7Tailscale repairs the mount.')
		}
		'None' {
			$attention.Add('Tailscale is installed and has no state at all; the daemon has never started. ' +
				'Install-OS7Tailscale -Adopt finishes the installation.')
		}
	}

	if (-not $Facts.Registered) {
		$from = @($Facts.OtherSources | ForEach-Object { $_.File })
		$attention.Add('Its package source is not registered with OS/7' +
			$(if ($from.Count) { " ($($from -join ', ') names it with nothing confining it)" } else { '' }) +
			': no key is pinned, nothing limits what that repository may install, and OS/7 does not keep it current. ' +
			'Install-OS7Tailscale -Adopt registers it from the release.')
	}
	else {
		foreach ($a in @($Facts.Registered.Attention)) { if ($a) { $attention.Add("Its package source: $a") } }
	}
	if ($Facts.Policy -and $Facts.Policy.InstalledOrigin -and $Facts.VendorHost -and $Facts.Policy.InstalledOrigin -ne $Facts.VendorHost) {
		$attention.Add("The installed package came from $($Facts.Policy.InstalledOrigin), not from $($Facts.VendorHost).")
	}

	$u = $Facts.Unit
	if (-not $u -or $u.ActiveState -ne 'active') {
		$state = if ($u) { "$($u.ActiveState)/$($u.SubState)" } else { 'not loaded' }
		$attention.Add("tailscaled is $state, so this machine is not on its tailnet. Start-Service tailscaled starts it.")
	}

	if ($s -and $s.Reachable) {
		switch ($s.BackendState) {
			'Running' { }
			'Stopped' {
				$attention.Add("It is enrolled in $(if ($s.Tailnet) { $s.Tailnet } else { 'a tailnet' }) and switched off " +
					'(`tailscale down`). Connect-OS7Tailscale switches it on again.')
			}
			'NeedsLogin' {
				if ($s.AuthUrl) {
					$attention.Add("A login is waiting for a person: $($s.AuthUrl)")
				}
				else {
					$attention.Add('It is not logged in to a tailnet. Connect-OS7Tailscale -AuthKeySecret <name> logs in with a ' +
						'key from the secret store; Connect-OS7Tailscale alone prints a login URL.')
				}
			}
			'NeedsMachineAuth' {
				$attention.Add('It is logged in and waiting for the tailnet''s administrator to approve this machine.')
			}
			default { $attention.Add("Tailscale reports the state '$($s.BackendState)'.") }
		}
		if ($s.BackendState -eq 'Running') {
			foreach ($h in @($s.Health)) { if ($h) { $attention.Add("Tailscale reports: $h") } }
		}
		if ($s.KeyExpiry -and $s.KeyExpiry -lt $Facts.Now.AddDays($script:OS7TailscaleExpiryWarnDays)) {
			$attention.Add("Its node key expires $($s.KeyExpiry.ToString('yyyy-MM-dd HH:mm')) UTC; after that it drops off the " +
				'tailnet until it is logged in again. A tagged auth key makes a node whose key does not expire.')
		}
		if ($s.HaveNodeKey -or $s.Running) {
			$notes.Add('This machine''s firewall does not filter traffic from the tailnet; the tailnet''s access policy does ' +
				'(docs/SESSION-TAILSCALE.md §7). A Remote Desktop scope set with -AllowFrom does not apply to it.')
		}
	}
	elseif ($s -and -not $s.Reachable -and $u -and $u.ActiveState -eq 'active') {
		$attention.Add("tailscaled is running and does not answer: $($s.Error)")
	}

	if ($p) {
		if ($p.RunSsh) {
			$attention.Add('Tailscale SSH is ON: it answers on port 22 of this machine''s tailnet address. A command sent over ' +
				'it runs even when PAM''s account checks refuse the account — an expired account, /etc/nologin — and root ' +
				'logs in if the tailnet''s policy allows it. OpenSSH over the tailnet address applies those checks, and on a ' +
				'domain-joined machine they include Active Directory''s logon rules. Set-OS7Tailscale -TailscaleSsh $false ' +
				'switches it off.')
		}
		if ($p.AutoUpdateApply -eq $true) {
			$attention.Add('Tailscale''s own updater is ON: it runs apt in the running system with --allow-downgrades, beside ' +
				'the update OS/7 already runs for this package (os7-vendor-update.timer), and the tailnet''s administrator ' +
				'decides when. Set-OS7Tailscale -TailscaleAutoUpdate $false switches it off.')
		}
		elseif ($null -eq $p.AutoUpdateApply -and -not $p.LoggedOut) {
			$attention.Add('Whether Tailscale''s own updater runs is not decided on this machine, so the tailnet''s default ' +
				'decides it (a `tailscale up` after `down`, and a `logout`, reset it). Set-OS7Tailscale ' +
				'-TailscaleAutoUpdate $false decides it here.')
		}
	}

	return [pscustomobject]@{ Layout = $layout; Attention = $attention.ToArray(); Notes = $notes.ToArray() }
}

function Get-OS7TailscaleInstallPlan {
	<#
	.SYNOPSIS
		Internal. What Install-OS7Tailscale will do on a machine in this state,
		or why it refuses — decided before anything is changed.

	.DESCRIPTION
		VA9 and VA11. The steps are named so the check can assert the ORDER:
		the dataset before the package, the source before the package, and on
		an adoption the daemon stopped before the state is copied.
	#>
	param(
		[Parameter(Mandatory)]$Facts,
		[switch]$Adopt
	)
	$layout = Get-OS7TailscaleLayout -Facts $Facts
	$installed = [bool]$Facts.Package
	$steps = [System.Collections.Generic.List[string]]::new()
	$refusal = $null
	$foreign = @($Facts.OtherSources | ForEach-Object { $_.File })

	if ($layout -eq 'InBootEnvironment' -and -not $Adopt) {
		$refusal = 'Tailscale''s state is already on this machine, inside the boot environment at ' +
			"$($script:OS7TailscaleStateDir)$(if ($installed) { " (the package is installed: $($Facts.Package.Version))" }). " +
			'Installing over it would leave this machine''s identity where a rollback reaches it. ' +
			'Install-OS7Tailscale -Adopt moves the state onto a dataset of its own and keeps the identity.'
	}
	elseif ($foreign.Count -and -not $Adopt) {
		$refusal = "$($foreign -join ', ') already names Tailscale's repository with nothing confining it, and apt " +
			'refuses to read ANY source while two files name one repository with different keys. ' +
			'Install-OS7Tailscale -Adopt replaces it with the registered source.'
	}
	elseif ($installed -and -not $Facts.Registered -and -not $Adopt) {
		$refusal = "Tailscale $($Facts.Package.Version) is installed from a source OS/7 did not register. " +
			'Install-OS7Tailscale -Adopt registers the release''s source for it.'
	}
	if ($refusal) {
		return [pscustomobject]@{ Layout = $layout; Refusal = $refusal; Steps = @(); Outcome = 'Refused' }
	}

	$moving = ($layout -eq 'InBootEnvironment' -and $Facts.StateDirectory)
	if ($moving) {
		$steps.Add('stop-daemon')
		$steps.Add('dataset-at-temporary-mount')
		$steps.Add('copy-state')
		$steps.Add('set-old-state-aside')
		$steps.Add('dataset-at-state-directory')
	}
	elseif ($layout -ne 'OS7') {
		$steps.Add('dataset-at-state-directory')
	}
	foreach ($f in $foreign) { $steps.Add("remove-source:$f") }
	if (-not $Facts.Registered) { $steps.Add('register-source') }
	if (-not $installed) {
		$steps.Add('unmask-unit')
		$steps.Add('install-package')
	}
	$steps.Add('start-daemon')
	$steps.Add('preferences-off')
	if ($moving) { $steps.Add('remove-old-state') }
	$steps.Add('baseline')

	$outcome = if ($moving) { 'Adopted' }
		elseif (-not $installed) { 'Installed' }
		elseif ($layout -ne 'OS7' -or -not $Facts.Registered -or $foreign.Count) { 'Adopted' }
		else { 'AlreadyInstalled' }
	return [pscustomobject]@{ Layout = $layout; Refusal = $null; Steps = $steps.ToArray(); Outcome = $outcome }
}

# =============================================================================
# The verbs
# =============================================================================

function Get-OS7Tailscale {
	<#
	.SYNOPSIS
		This machine's Tailscale: installed, connected to what, where its state
		lives — and what needs attention, first.

	.DESCRIPTION
		VA13. Attention is empty on a machine that needs nothing done; every
		sentence in it names the command that answers it. Notes carries what is
		always true of a tailnet node — that the firewall does not filter the
		tailnet — because an administrator who scoped Remote Desktop needs to
		know it, and it is not a defect.

		TailscaleAutoUpdate is THREE-VALUED, as Tailscale's own preference is:
		$false (off, OS/7's choice), $true (on), $null (not decided here — the
		tailnet's default decides at the next login).

	.EXAMPLE
		Get-OS7Tailscale

	.EXAMPLE
		(Get-OS7Tailscale).Attention
	#>
	[CmdletBinding()]
	[OutputType('OS7.Tailscale')]
	param()

	$f = Get-OS7TailscaleFacts
	$j = Get-OS7TailscaleAttention -Facts $f
	$s = $f.Status
	$p = $f.Preference
	return [pscustomobject]@{
		PSTypeName          = 'OS7.Tailscale'
		Installed           = [bool]$f.Package
		Version             = if ($f.Package) { $f.Package.Version } else { $null }
		Candidate           = if ($f.Policy) { $f.Policy.Candidate } else { $null }
		Daemon              = if ($f.Unit) { "$($f.Unit.ActiveState)/$($f.Unit.SubState)" } else { $null }
		BackendState        = if ($s) { $s.BackendState } else { $null }
		Tailnet             = if ($s) { $s.Tailnet } else { $null }
		LoginServer         = if ($p) { $p.ControlUrl } else { $null }
		HostName            = if ($s -and $s.Reachable) { $s.HostName } else { $null }
		DnsName             = if ($s) { $s.DnsName } else { $null }
		Addresses           = if ($s) { @($s.Addresses) } else { @() }
		Tags                = if ($s) { @($s.Tags) } else { @() }
		KeyExpiry           = if ($s) { $s.KeyExpiry } else { $null }
		AuthUrl             = if ($s) { $s.AuthUrl } else { $null }
		Layout              = $j.Layout
		StateDataset        = if ($f.Dataset) { $f.Dataset.Dataset } else { $null }
		Source              = if ($f.Registered) { $f.Registered.Name } else { $null }
		SourceVerified      = if ($f.Registered) { $f.Registered.Verified } else { $null }
		TailscaleSsh        = if ($p) { $p.RunSsh } else { $null }
		TailscaleAutoUpdate = if ($p) { $p.AutoUpdateApply } else { $null }
		Attention           = $j.Attention
		Notes               = $j.Notes
	}
}

function Copy-OS7TailscaleState {
	<#
	.SYNOPSIS
		Internal. Copy a state directory tree with its Unix modes — Copy-Item
		does not keep them, and tailscaled.state is 0600 for a reason.
	#>
	param(
		[Parameter(Mandatory)][string]$From,
		[Parameter(Mandatory)][string]$To
	)
	$fromInfo = [System.IO.DirectoryInfo]::new($From)
	try { [System.IO.File]::SetUnixFileMode($To, [System.IO.File]::GetUnixFileMode($From)) }
	catch [System.PlatformNotSupportedException] { }
	$n = 0
	foreach ($e in $fromInfo.EnumerateFileSystemInfos('*', [System.IO.SearchOption]::AllDirectories)) {
		if ($e.LinkTarget) {
			throw [System.InvalidOperationException]::new(
				"$($e.FullName) is a symbolic link; Install-OS7Tailscale -Adopt copies files and directories only. " +
				'Move the state by hand, or remove the link.')
		}
		$rel = [System.IO.Path]::GetRelativePath($From, $e.FullName)
		$dst = [System.IO.Path]::Combine($To, $rel)
		if ($e -is [System.IO.DirectoryInfo]) {
			[System.IO.Directory]::CreateDirectory($dst) | Out-Null
		}
		else {
			[System.IO.File]::Copy($e.FullName, $dst, $true)
			$n++
		}
		try { [System.IO.File]::SetUnixFileMode($dst, [System.IO.File]::GetUnixFileMode($e.FullName)) }
		catch [System.PlatformNotSupportedException] { }
	}
	return $n
}

function Install-OS7Tailscale {
	<#
	.SYNOPSIS
		Installs Tailscale as an OS/7 role: its state on a dataset of its own
		FIRST, the vendor's source registered from the release, the package,
		the preferences — and then asks every one of those back.

	.DESCRIPTION
		VA9 and VA11, in the order that is the decision:

		  1  the state dataset — rpool/DATA/lib/tailscale at /var/lib/tailscale,
		     NOT backed up (a node key restored onto a second machine is two
		     machines with one identity) — before the package, so tailscaled's
		     StateDirectory= finds a mount
		  2  Register-OS7PackageSource tailscale -FromRelease: the release's
		     URI and key fingerprint, only `tailscale` admitted from the origin
		  3  the package, --no-install-recommends
		  4  the daemon running, Tailscale SSH and the client's updater OFF
		  5  the package baseline, so the next Update-OS7 does not call the
		     package drift (VA8)
		  6  ask back: the dataset mounted and the state on it, the daemon
		     active, both preferences off, the source verified, the package
		     from the registered origin

		A machine where Tailscale was installed the vendor's documented way is
		REFUSED unless -Adopt, and the refusal says why. -Adopt stops the
		daemon, copies the state onto the new dataset with its modes, sets the
		old directory aside, mounts the dataset in its place, removes the
		vendor's own source file, registers the release's, starts the daemon,
		and requires the SAME node to answer — the identity is kept, and the
		old copy inside the boot environment is then deleted. Older boot
		environments and their snapshots still hold a copy of the key; that is
		what a rollback past this point would restore (VAL).

		Run again on a machine it made, it changes nothing and checks again.

		Logging in is Connect-OS7Tailscale's. Not on the medium, not in any
		metapackage (VA1).

	.EXAMPLE
		Install-OS7Tailscale

	.EXAMPLE
		Install-OS7Tailscale -Adopt
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.TailscaleInstall')]
	param([switch]$Adopt)

	Assert-OS7Elevated -Cmdlet 'Install-OS7Tailscale' -Because (
		'creates a ZFS dataset, registers an apt source, installs a package and starts a system service')

	$facts = Get-OS7TailscaleFacts
	$plan = Get-OS7TailscaleInstallPlan -Facts $facts -Adopt:$Adopt
	if ($plan.Refusal) {
		throw [System.InvalidOperationException]::new("Install-OS7Tailscale refused and changed nothing: $($plan.Refusal)")
	}
	if (-not $PSCmdlet.ShouldProcess('this machine', "Tailscale: $($plan.Steps -join ', ')")) { return }

	$before = $facts.Status
	$oldAside = $null
	$copied = 0
	$removedSources = @()
	foreach ($step in $plan.Steps) {
		Write-OS7Step "tailscale: $step"
		switch -Regex ($step) {
			'^stop-daemon$' {
				Stop-SystemdUnit -Name $script:OS7TailscaleUnit -Confirm:$false | Out-Null
			}
			'^dataset-at-temporary-mount$' {
				$null = New-OS7ServiceDataset -Name $script:OS7TailscaleName -MountPoint "$($script:OS7TailscaleStateDir).os7-adopt" `
					-Backup $false -NoLayout -Confirm:$false
			}
			'^copy-state$' {
				$copied = Copy-OS7TailscaleState -From $script:OS7TailscaleStateDir -To "$($script:OS7TailscaleStateDir).os7-adopt"
				Write-OS7Step "tailscale: copied $copied file(s) of state"
			}
			'^set-old-state-aside$' {
				$oldAside = "$($script:OS7TailscaleStateDir).os7-replaced-$([datetime]::UtcNow.ToString('yyyyMMddHHmmss'))"
				[System.IO.Directory]::Move($script:OS7TailscaleStateDir, $oldAside)
			}
			'^dataset-at-state-directory$' {
				$null = New-OS7ServiceDataset -Name $script:OS7TailscaleName -MountPoint $script:OS7TailscaleStateDir `
					-Backup $false -NoLayout -Confirm:$false
				$tmp = "$($script:OS7TailscaleStateDir).os7-adopt"
				if ([System.IO.Directory]::Exists($tmp) -and -not @([System.IO.Directory]::EnumerateFileSystemEntries($tmp)).Count) {
					[System.IO.Directory]::Delete($tmp)
				}
			}
			'^remove-source:(.+)$' {
				$file = $Matches[1]
				$null = Remove-AptSource -Path $file -Confirm:$false
				$removedSources += $file
			}
			'^register-source$' {
				$null = Register-OS7PackageSource -Name $script:OS7TailscaleName -FromRelease -Confirm:$false
			}
			'^unmask-unit$' {
				# M-TS12: `apt-get remove` leaves the unit MASKED, and a masked
				# unit is one the package's own postinst cannot start.
				$u = @(Get-SystemdUnit -Name $script:OS7TailscaleUnit) | Select-Object -First 1
				if ($u -and $u.LoadState -eq 'masked') {
					Set-SystemdUnitStartup -Name $script:OS7TailscaleUnit -Startup Unmasked -Confirm:$false | Out-Null
				}
			}
			'^install-package$' {
				$null = Install-AptPackage -Name $script:OS7TailscalePackage -NoInstallRecommends -Confirm:$false
			}
			'^start-daemon$' {
				$u = @(Get-SystemdUnit -Name $script:OS7TailscaleUnit) | Select-Object -First 1
				if (-not $u -or $u.StartupType -ne 'enabled') {
					Set-SystemdUnitStartup -Name $script:OS7TailscaleUnit -Startup Enabled -Confirm:$false | Out-Null
				}
				if (-not $u -or $u.ActiveState -ne 'active') {
					Start-SystemdUnit -Name $script:OS7TailscaleUnit -Confirm:$false | Out-Null
				}
				# The daemon answers a moment after systemd says active.
				$deadline = [datetime]::UtcNow.AddSeconds(20)
				do {
					$st = Get-TailscaleStatus
					if ($st.Reachable) { break }
					Start-Sleep -Milliseconds 500
				} while ([datetime]::UtcNow -lt $deadline)
				# AND A NODE THAT WAS ENROLLED IS ITSELF A MOMENT AFTER THAT. Until it
				# has spoken to its control server, `status` says NoState or
				# Starting and carries no node id — so the identity check below
				# read an empty id and refused a correct adoption, the first time
				# -Adopt ran on a machine (run-tailscale.py, 2026-11-12). It waits
				# for the daemon to leave those two states; a node that cannot
				# reach its control server stays in Starting, and the check then
				# fails for the reason it should.
				if ($before -and $before.HaveNodeKey) {
					$deadline = [datetime]::UtcNow.AddSeconds(60)
					do {
						$st = Get-TailscaleStatus
						if ($st.Reachable -and $st.BackendState -notin @('NoState', 'Starting')) { break }
						Start-Sleep -Seconds 1
					} while ([datetime]::UtcNow -lt $deadline)
				}
			}
			'^preferences-off$' {
				# Before a login this is a statement, not a guarantee: `up` replaces
				# it (O-M2). Connect-OS7Tailscale sets it again after the login.
				$null = Set-TailscalePreference -Ssh $false -AutoUpdate $false -Confirm:$false
			}
			'^remove-old-state$' {
				# Only once the SAME node answers from the dataset (checked below
				# before this step can be reached — see the identity check).
			}
			'^baseline$' {
				$null = Save-OS7PackageBaseline -Reason 'Install-OS7Tailscale' -Confirm:$false
			}
		}
	}

	# ASK BACK. Every step above is a claim.
	$after = Get-OS7TailscaleFacts
	$layout = Get-OS7TailscaleLayout -Facts $after
	$checks = [System.Collections.Generic.List[object]]::new()
	$add = { param($c, $ok, $d) $checks.Add([pscustomobject]@{ Check = $c; Ok = [bool]$ok; Detail = [string]$d }) }
	& $add "$($script:OS7TailscaleStateDir) is its own dataset, outside the boot environment, not backed up" `
		($layout -eq 'OS7') "$(if ($after.Dataset) { $after.Dataset.Dataset } else { 'no dataset' }) layout $layout"
	& $add 'the daemon''s state file is on it' $after.StateFile "$($script:OS7TailscaleStateDir)/$($script:OS7TailscaleStateFile)"
	& $add 'tailscaled is active and answers' ($after.Unit -and $after.Unit.ActiveState -eq 'active' -and $after.Status -and $after.Status.Reachable) `
		"$(if ($after.Unit) { $after.Unit.ActiveState } else { 'no unit' }); $(if ($after.Status) { $after.Status.Error } else { '' })"
	& $add 'Tailscale SSH is off' ($after.Preference -and -not $after.Preference.RunSsh) "$(if ($after.Preference) { $after.Preference.RunSsh } else { 'no preferences' })"
	& $add 'the client''s own updater is off' ($after.Preference -and $after.Preference.AutoUpdateApply -eq $false) `
		"$(if ($after.Preference) { $after.Preference.AutoUpdateApply } else { 'no preferences' })"
	& $add 'the source is registered and verified' ($after.Registered -and $after.Registered.Verified) `
		"$(if ($after.Registered) { "verified: $($after.Registered.Verified) $($after.Registered.LastError)" } else { 'not registered' })"
	& $add "the package came from $($after.VendorHost)" ($after.Package -and $after.Policy -and $after.Policy.InstalledOrigin -eq $after.VendorHost) `
		"$(if ($after.Policy) { "$($after.Policy.Installed) from $($after.Policy.InstalledOrigin)" } else { 'apt not asked' })"
	if ($oldAside) {
		# THE IDENTITY SURVIVED: the node that answers from the dataset is the
		# node that answered from the boot environment.
		$same = ($before -and $before.NodeId -and $after.Status -and $after.Status.NodeId -eq $before.NodeId) -or
			($before -and -not $before.HaveNodeKey)
		& $add 'the adopted node is the same node' $same "before $(if ($before) { $before.NodeId } else { '?' }), after $(if ($after.Status) { $after.Status.NodeId } else { '?' })"
	}

	$bad = @($checks | Where-Object { -not $_.Ok })
	if ($bad.Count) {
		$msg = "Install-OS7Tailscale ran and the machine does not agree:`n  " +
			(($bad | ForEach-Object { "$($_.Check): $($_.Detail)" }) -join "`n  ")
		if ($oldAside) { $msg += "`nThe state as it was before is kept at $oldAside." }
		throw [System.InvalidOperationException]::new($msg)
	}
	if ($oldAside) {
		# The copy in the boot environment is the private key a rollback would
		# restore; the checks above passed, so it goes.
		[System.IO.Directory]::Delete($oldAside, $true)
		Write-OS7Step "tailscale: removed the state left in the boot environment ($oldAside)"
	}

	return [pscustomobject]@{
		PSTypeName     = 'OS7.TailscaleInstall'
		Outcome        = $plan.Outcome
		Version        = $after.Package.Version
		Layout         = $layout
		StateDataset   = $after.Dataset.Dataset
		Source         = $after.Registered.Name
		RemovedSources = $removedSources
		StateCopied    = $copied
		Checks         = $checks.ToArray()
	}
}

function Connect-OS7Tailscale {
	<#
	.SYNOPSIS
		Logs this machine in to a tailnet — with an auth key from OS/7's secret
		store, or by a login URL a person opens — and then sets what a login
		resets and asks the daemon what happened.

	.DESCRIPTION
		VA12. WITH -AuthKeySecret the key never leaves the store as a value:
		Start-OS7Job delivers the secret to a job as a file in
		$CREDENTIALS_DIRECTORY and the job passes that PATH to `tailscale up`
		(`--auth-key=file:`). The job's parameters are its input document, so
		the command it runs is a constant.

		WITHOUT IT, the login URL is printed and the cmdlet waits up to
		-TimeoutSec for a person to use it; -NoWait returns the URL at once,
		and the login completes in the daemon whenever the person gets there.

		THEN, AND ONLY THEN, Tailscale SSH and the client's updater are switched
		off: a login replaces the preferences `up` has no flag for (O-M2,
		measured), so setting them before would be a statement the login
		undoes. With -NoWait that step has not happened yet; Get-OS7Tailscale
		says so, and running Connect-OS7Tailscale again on the connected
		machine does it.

		THE RESULT IS THE DAEMON'S WORD: BackendState Running and an address.
		A job that ran is not a login that happened.

	.PARAMETER AuthKeySecret
		The name of a secret made with New-OS7Secret that holds the auth key.

	.PARAMETER LoginServer
		A control server other than Tailscale's — a self-hosted Headscale.

	.EXAMPLE
		Connect-OS7Tailscale -AuthKeySecret tailscale-authkey -Hostname web01

	.EXAMPLE
		Connect-OS7Tailscale
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Tailscale')]
	param(
		[string]$AuthKeySecret,
		[string]$LoginServer,
		[string]$Hostname,
		[string[]]$AdvertiseTag = @(),
		[Nullable[bool]]$AcceptDns,
		[ValidateRange(10, 3600)][int]$TimeoutSec = 300,
		[switch]$NoWait
	)

	Assert-OS7Elevated -Cmdlet 'Connect-OS7Tailscale' -Because 'logs this machine in to a tailnet and changes the Tailscale daemon''s preferences'
	$facts = Get-OS7TailscaleFacts
	if (-not $facts.Package -or -not $facts.Version) {
		throw [System.InvalidOperationException]::new('Tailscale is not installed. Install-OS7Tailscale installs it.')
	}
	$layout = Get-OS7TailscaleLayout -Facts $facts
	if ($layout -ne 'OS7') {
		throw [System.InvalidOperationException]::new(
			"Connect-OS7Tailscale refused: Tailscale's state is not on its own dataset (layout $layout), so the identity " +
			'a login creates would live where a rollback reaches it. Install-OS7Tailscale -Adopt moves it first.')
	}
	if (-not $facts.Status -or -not $facts.Status.Reachable) {
		throw [System.InvalidOperationException]::new(
			"tailscaled does not answer: $(if ($facts.Status) { $facts.Status.Error } else { 'no status' }) " +
			'Start-Service tailscaled, then try again.')
	}
	if ($AuthKeySecret) {
		$secret = @(Get-OS7Secret | Where-Object Name -eq $AuthKeySecret)
		if (-not $secret.Count) {
			throw [System.Management.Automation.ItemNotFoundException]::new(
				"no secret called '$AuthKeySecret' in this machine's store. New-OS7Secret -Name $AuthKeySecret makes it; " +
				'the value is typed or piped in there and nowhere else.')
		}
	}

	$s = $facts.Status
	$already = $s.Running -and (-not $LoginServer -or ($facts.Preference -and $facts.Preference.ControlUrl -eq $LoginServer))
	$authUrl = $null
	if (-not $already) {
		if (-not $PSCmdlet.ShouldProcess('this machine', "log in to $(if ($LoginServer) { $LoginServer } else { 'Tailscale' })")) { return }
		if ($AuthKeySecret) {
			# $jobInput AND NOT $input: $input is PowerShell's automatic pipeline
			# enumerator, and assigning to it inside a function is the #65 family.
			$jobInput = [ordered]@{
				secret      = $AuthKeySecret
				loginServer = $LoginServer
				hostname    = $Hostname
				tags        = @($AdvertiseTag | Where-Object { $_ })
				acceptDns   = $AcceptDns
				timeoutSec  = [Math]::Min($TimeoutSec, 600)
			}
			# A JOB WHOSE COMMAND THROWS IS A UNIT THAT FAILED, and Start-OS7Job
			# reports that as "could not be started" with systemctl's words. The
			# runner's own record — written before the unit ended — carries the
			# sentence that matters (Tailscale's), so it is read either way.
			$job = $null
			$startError = $null
			try {
				$job = Start-OS7Job -Name 'tailscale-login' -Command $script:OS7TailscaleLoginCommand -InputObject $jobInput `
					-Secret $AuthKeySecret -TimeoutSec ([Math]::Min($TimeoutSec, 600) + 30) -Confirm:$false
			}
			catch { $startError = $_.Exception.Message }
			$record = if ($job) { @(Get-OS7Job -Id $job.Id -Days 1) | Select-Object -First 1 }
				else { @(Get-OS7Job -Days 1 | Where-Object Name -eq 'tailscale-login') | Select-Object -First 1 }
			$jobError = if ($record -and $record.Error) { [string]$record.Error } else { $startError }
			if ($jobError) {
				throw [System.InvalidOperationException]::new(
					"Connect-OS7Tailscale: the login job$(if ($record) { " $($record.Id)" }) failed: $jobError")
			}
		}
		else {
			$c = Connect-Tailscale -LoginServer $LoginServer -Hostname $Hostname -AdvertiseTag $AdvertiseTag `
				-AcceptDns $AcceptDns -TimeoutSec 10
			if (-not $c.Succeeded -and -not $c.LoginPending) {
				throw [System.InvalidOperationException]::new("Connect-OS7Tailscale: tailscale up refused: $($c.Error)")
			}
			$authUrl = $c.AuthUrl
			if ($c.LoginPending) {
				Write-Host "To log this machine in, open:`n    $authUrl"
				if ($NoWait) { return (Get-OS7Tailscale) }
				$deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
				do {
					Start-Sleep -Seconds 2
					$st = Get-TailscaleStatus
					if ($st.Running) { break }
				} while ([datetime]::UtcNow -lt $deadline)
			}
		}
	}

	# THE DAEMON'S WORD. A job that ran is not a login that happened.
	$st = Get-TailscaleStatus
	if (-not $st.Running) {
		$why = if ($st.Reachable) { "it reports $($st.BackendState)$(if ($st.Health.Count) { ': ' + ($st.Health -join '; ') })" } else { $st.Error }
		throw [System.InvalidOperationException]::new(
			"Connect-OS7Tailscale: the machine is not on the tailnet — $why" +
			$(if ($authUrl) { ". The login URL was $authUrl" } else { '' }))
	}

	# AFTER THE LOGIN (O-M2): what `up` reset, set, and read back.
	$null = Set-TailscalePreference -Ssh $false -AutoUpdate $false -Confirm:$false
	return (Get-OS7Tailscale)
}

function Disconnect-OS7Tailscale {
	<#
	.SYNOPSIS
		Takes this machine off its tailnet: `down` (still enrolled), or with
		-Logout, out of the tailnet altogether.

	.DESCRIPTION
		VA15. Both reset the client's updater preference to "not decided"
		(measured), so it is set off again afterwards — the machine's own choice
		stays stated while it is disconnected.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.Tailscale')]
	param([switch]$Logout)

	Assert-OS7Elevated -Cmdlet 'Disconnect-OS7Tailscale' -Because 'disconnects this machine from its tailnet'
	Import-OS7TailscaleLayer
	$what = if ($Logout) { 'log out of the tailnet (the node is removed from it)' } else { 'disconnect (stays enrolled)' }
	if (-not $PSCmdlet.ShouldProcess('this machine', $what)) { return }
	Disconnect-Tailscale -Logout:$Logout -Confirm:$false
	$st = Get-TailscaleStatus
	$want = if ($Logout) { 'NeedsLogin' } else { 'Stopped' }
	if ($st.BackendState -ne $want) {
		throw [System.InvalidOperationException]::new(
			"Disconnect-OS7Tailscale: tailscale $(if ($Logout) { 'logout' } else { 'down' }) exited 0 and the daemon reports " +
			"$(if ($st.Reachable) { $st.BackendState } else { $st.Error }), not $want.")
	}
	$null = Set-TailscalePreference -AutoUpdate $false -Ssh $false -Confirm:$false
	return (Get-OS7Tailscale)
}

function Set-OS7Tailscale {
	<#
	.SYNOPSIS
		Switches Tailscale SSH or the client's own updater OFF, or changes the
		node's name or DNS setting — and reads it back.

	.DESCRIPTION
		VA14 and VA7. There is no way to switch either on from here, by the
		owner's decision: Tailscale SSH runs a command even when PAM's account
		checks refuse the account, and the client's updater is a second apt
		beside the one OS/7 runs for this package. `tailscale set --ssh` is how
		an administrator who wants it anyway gets it, and Get-OS7Tailscale
		reports it.

	.EXAMPLE
		Set-OS7Tailscale -TailscaleSsh $false
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('OS7.Tailscale')]
	param(
		[Nullable[bool]]$TailscaleSsh,
		[Nullable[bool]]$TailscaleAutoUpdate,
		[string]$Hostname,
		[Nullable[bool]]$AcceptDns
	)

	Assert-OS7Elevated -Cmdlet 'Set-OS7Tailscale' -Because 'changes the Tailscale daemon''s preferences'
	if ($TailscaleSsh -eq $true) {
		throw [System.ArgumentException]::new(
			'Set-OS7Tailscale does not switch Tailscale SSH on. A command sent over it runs even when PAM''s account ' +
			'checks refuse the account; OpenSSH over the tailnet address applies them, and on a domain-joined machine ' +
			'they include Active Directory''s logon rules (docs/VENDOR-APPS-PLAN.md VA14).')
	}
	if ($TailscaleAutoUpdate -eq $true) {
		throw [System.ArgumentException]::new(
			'Set-OS7Tailscale does not switch Tailscale''s own updater on: os7-vendor-update.timer already keeps the ' +
			'package current, and a second updater would run apt beside it with --allow-downgrades (VA7).')
	}
	Import-OS7TailscaleLayer
	$p = @{}
	if ($null -ne $TailscaleSsh) { $p.Ssh = $false }
	if ($null -ne $TailscaleAutoUpdate) { $p.AutoUpdate = $false }
	if ($Hostname) { $p.Hostname = $Hostname }
	if ($null -ne $AcceptDns) { $p.AcceptDns = $AcceptDns }
	if (-not $p.Count) { throw [System.ArgumentException]::new('Set-OS7Tailscale was given nothing to set.') }
	if (-not $PSCmdlet.ShouldProcess('the Tailscale daemon', "set $(($p.Keys | Sort-Object) -join ', ')")) { return }
	$null = Set-TailscalePreference @p -Confirm:$false
	return (Get-OS7Tailscale)
}

function Uninstall-OS7Tailscale {
	<#
	.SYNOPSIS
		Removes Tailscale: logs the node out (unless -KeepIdentity), removes the
		package, unregisters its source — and with -RemoveState destroys the
		state dataset.

	.DESCRIPTION
		VA15. `apt-get remove`, NEVER purge: the vendor's postrm on purge runs
		`rm -rf /var/lib/tailscale`, which empties the dataset — the identity
		with it — and then fails on the mount point (M-TS12). Remove leaves the
		unit masked; it is unmasked here so a later install can start it.

		Without -RemoveState the dataset stays, with the node's state in it:
		after a logout that is a machine key and nothing more; with
		-KeepIdentity it is this machine's identity, kept for a reinstall.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.TailscaleUninstall')]
	param(
		[switch]$KeepIdentity,
		[switch]$RemoveState
	)

	Assert-OS7Elevated -Cmdlet 'Uninstall-OS7Tailscale' -Because (
		'removes a package and an apt source, and can destroy a ZFS dataset')
	if ($KeepIdentity -and $RemoveState) {
		throw [System.ArgumentException]::new(
			'-KeepIdentity keeps the node''s state for a reinstall, and -RemoveState destroys it. Choose one.')
	}
	$facts = Get-OS7TailscaleFacts
	$what = @(
		if (-not $KeepIdentity -and $facts.Status -and $facts.Status.HaveNodeKey) { 'log out of the tailnet' }
		if ($facts.Package) { "remove $($script:OS7TailscalePackage) $($facts.Package.Version)" }
		if ($facts.Registered) { 'unregister its source' }
		if ($RemoveState -and $facts.Dataset) { "DESTROY $($facts.Dataset.Dataset) and its snapshots" }
	)
	if (-not $what.Count) {
		return [pscustomobject]@{ PSTypeName = 'OS7.TailscaleUninstall'; Outcome = 'NotInstalled'; Steps = @(); StateDataset = $null }
	}
	if (-not $PSCmdlet.ShouldProcess('this machine', ($what -join ', '))) { return }

	if (-not $KeepIdentity -and $facts.Status -and $facts.Status.HaveNodeKey) {
		try { Disconnect-Tailscale -Logout -Confirm:$false }
		catch { Write-Warning "the logout failed, so the tailnet still lists this node: $($_.Exception.Message)" }
	}
	if ($facts.Package) {
		$null = Remove-AptPackage -Name $script:OS7TailscalePackage -Confirm:$false
		$u = @(Get-SystemdUnit -Name $script:OS7TailscaleUnit) | Select-Object -First 1
		if ($u -and $u.LoadState -eq 'masked') {
			Set-SystemdUnitStartup -Name $script:OS7TailscaleUnit -Startup Unmasked -Confirm:$false | Out-Null
		}
	}
	if ($facts.Registered) {
		$null = Unregister-OS7PackageSource -Name $script:OS7TailscaleName -Confirm:$false
	}
	if ($RemoveState -and $facts.Dataset) {
		Import-OS7ZfsLayer
		Remove-ZfsDataset -Name $facts.Dataset.Dataset -Recurse -Confirm:$false | Out-Null
		# ZFS leaves the mount point behind (measured). Empty, it is nothing;
		# left there, it is a directory a later reader might take for state.
		$dir = $script:OS7TailscaleStateDir
		if ([System.IO.Directory]::Exists($dir) -and -not @([System.IO.Directory]::EnumerateFileSystemEntries($dir)).Count) {
			[System.IO.Directory]::Delete($dir)
		}
	}
	$null = Save-OS7PackageBaseline -Reason 'Uninstall-OS7Tailscale' -Confirm:$false

	# ASK BACK.
	$after = Get-OS7TailscaleFacts
	$bad = @(
		if ($after.Package) { "the package is still installed ($($after.Package.Version))" }
		if ($after.Registered) { 'the source is still registered' }
		if ($RemoveState -and $after.Dataset) { "$($after.Dataset.Dataset) still exists" }
		if ($after.Unit -and $after.Unit.LoadState -eq 'masked') { "$($script:OS7TailscaleUnit) is still masked" }
	)
	if ($bad.Count) {
		throw [System.InvalidOperationException]::new("Uninstall-OS7Tailscale ran and the machine does not agree: $($bad -join '; ').")
	}
	return [pscustomobject]@{
		PSTypeName   = 'OS7.TailscaleUninstall'
		Outcome      = 'Removed'
		Steps        = $what
		StateDataset = if ($after.Dataset) { $after.Dataset.Dataset } else { $null }
	}
}
