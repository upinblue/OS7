# =============================================================================
# OS/7 PowerShell module
#
# TWO HALVES, and the difference matters when reading this file:
#
#   IMPLEMENTED   New-OS7Storage, New-OS7BootEnvironmentName — the storage
#                 layer, written for os7-setup's Phase 2 storage executor.
#                 Since 2026-08-25 it does NOT run zfs/zpool itself: it calls
#                 the Zfs module (docs/ZFS-POWERSHELL-PLAN.md Z1), so the pool
#                 flags exist in exactly one place and Update-OS7 cannot drift
#                 from Setup. installer/testing/check-layering.py holds that
#                 line at zero.
#   STUB          Set-OS7Mode, Update-OS7, Restore-OS7 — signatures only, each
#                 throwing NotImplementedException, pinning the command surface
#                 README.md documents.
#
# WHY THE ZFS LAYER IS HERE AND NOT IN THE INSTALLER, which is the interesting
# design decision (installer/SETUP-PLAN.md §6.3):
#
#   Update-OS7 and Restore-OS7 need boot-environment creation, activation and
#   rollback. Setup needs the IDENTICAL logic to create the first one. Writing
#   it twice guarantees drift — and the drift would be in a dataset hierarchy
#   that cannot be corrected after the fact, because USERDATA sitting outside
#   ROOT is not retrofittable (§4.4).
#
#   So it lives once, here, and os7-setup invokes it out-of-process:
#   `pwsh -NoProfile -File …`, consuming JSON on stdout. Not
#   Microsoft.PowerShell.SDK hosted in-process — that is large and
#   reflection-heavy, and NativeAOT cannot have it (§6.3).
#
# THE CONVENTION EVERY IMPLEMENTED FUNCTION FOLLOWS:
#   stdout  exactly one JSON object, the result. Nothing else, ever.
#   stderr  human-readable progress, one line per step.
#   Because os7-setup reads the two apart, and a stray Write-Output on stdout
#   makes the result unparseable.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------
function Write-OS7Step {
	param([Parameter(Mandatory)][string]$Message)
	[Console]::Error.WriteLine("OS7-STEP $Message")
}

function Invoke-OS7Native {
	<#
	.SYNOPSIS
		Run an external command, or print it under -WhatIf.

	.DESCRIPTION
		PowerShell's own error handling does not cover native exit codes:
		$ErrorActionPreference = 'Stop' does nothing for `zpool` returning 1,
		so a failed pool creation would otherwise sail on into the dataset
		steps and fail there instead, about something else.

		stderr from the child is captured and carried into the exception,
		because installer/SETUP-PLAN.md §3.1 requires every error screen to name
		the command that failed AND its output. An exception that says
		"zpool exited 1" is not an error screen anybody can act on.
	#>
	param(
		[Parameter(Mandatory)][string]$Command,
		[Parameter(Mandatory)][string[]]$Arguments,
		[switch]$WhatIf
	)
	$line = "$Command $($Arguments -join ' ')"
	if ($WhatIf) {
		Write-OS7Step "would run: $line"
		return ''
	}
	Write-OS7Step "run: $line"

	$errFile = [System.IO.Path]::GetTempFileName()
	try {
		$out = & $Command @Arguments 2> $errFile
		$code = $LASTEXITCODE
		$err = (Get-Content -Raw -ErrorAction SilentlyContinue $errFile)
		if ($code -ne 0) {
			throw [System.Management.Automation.RuntimeException]::new(
				"$line`nexited $code`n$err")
		}
		if ($err) { [Console]::Error.WriteLine($err.TrimEnd()) }
		return ($out -join "`n")
	}
	finally {
		Remove-Item -Force -ErrorAction SilentlyContinue $errFile
	}
}

# ---------------------------------------------------------------------------
# The ZFS layer (docs/ZFS-POWERSHELL-PLAN.md Z1)
#
# THIS MODULE DOES NOT CALL zfs OR zpool. Every ZFS operation goes through the
# Zfs module, which is Layer 2: the flags for a pool are decided in exactly one
# place, so New-OS7Storage and Update-OS7 cannot drift apart. That is the same
# argument SETUP-PLAN §6.3 used to move this work out of C# in the first place.
# installer/testing/check-layering.py holds the line.
#
# LAZILY, AND NEVER AT IMPORT TIME. A live-build hook may Import-Module by path
# and list what it exports, but anything that CALLS a bundled cmdlet - Test-Path
# included - fails inside live-build's chroot (BUILD-NOTES #38). Module-level
# code runs during import, so resolving the Zfs module up here would break
# hook 0060 and therefore the build. Down here it runs only when somebody
# actually asks for storage work, which never happens in a hook.
# ---------------------------------------------------------------------------
function Import-OS7ZfsLayer {
	if (Get-Module -Name Zfs) { return }

	$candidates = @(
		# Beside this module in the repository, which is how a developer and
		# the VM harness see it...
		(Join-Path (Split-Path -Parent $PSScriptRoot) 'Zfs/Zfs.psd1'),
		# ...and where build.sh stages it on an installed system.
		'/usr/local/share/powershell/Modules/Zfs/Zfs.psd1'
	)
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			Import-Module $c -Force -ErrorAction Stop
			Write-OS7Step "ZFS layer: $c"
			return
		}
	}
	# By name as the last resort. It works on a booted system and not in a
	# chroot (BUILD-NOTES #14), which is the right way round for this caller.
	Import-Module Zfs -Force -ErrorAction Stop
	Write-OS7Step 'ZFS layer: Zfs (by name)'
}

# ---------------------------------------------------------------------------
# Boot-environment naming
# ---------------------------------------------------------------------------
function New-OS7BootEnvironmentName {
	<#
	.SYNOPSIS
		The name of a new boot environment: os7_<release>_<yyyyMMddHHmm>.

	.DESCRIPTION
		installer/SETUP-PLAN.md §4.4 pins this scheme, and pins it for a reason:
		`Restore-OS7 -BootEnvironment` has to LIST and SORT boot environments,
		and the stub for it explicitly had no scheme to sort by. Lexical order
		is chronological order here, which is what makes "the previous one" a
		well-defined thing.

		<release> is the four-field OS/7 product version
		(docs/RELEASE-AND-UPDATE-PLAN.md §3.3), and the same value goes into
		/etc/os-release as IMAGE_VERSION (§3.5). Read from
		/usr/lib/os7/release.json when it is there — it will not be during
		Phase 2, so the caller passes it.

	.EXAMPLE
		New-OS7BootEnvironmentName -Release 1.0.0.0
		os7_1.0.0.0_202608241530
	#>
	[CmdletBinding()]
	param(
		[Parameter()][string]$Release,
		[Parameter()][datetime]$When = (Get-Date)
	)

	if (-not $Release) {
		$manifest = '/usr/lib/os7/release.json'
		if (Test-Path $manifest) {
			$Release = (Get-Content -Raw $manifest | ConvertFrom-Json).version
		}
	}
	# A boot environment with no version in its name still has to sort, so the
	# fallback is a value rather than an error - but it is an obviously wrong
	# value, not a plausible one.
	if (-not $Release) { $Release = '0.0.0.0' }

	# Dots are legal in a ZFS dataset name; slashes and spaces are not, and a
	# release string is not guaranteed to avoid them.
	$safe = ($Release -replace '[^0-9A-Za-z._-]', '-')
	return "os7_${safe}_$($When.ToString('yyyyMMddHHmm'))"
}

# ---------------------------------------------------------------------------
# The pools and the dataset hierarchy
# ---------------------------------------------------------------------------
function New-OS7Storage {
	<#
	.SYNOPSIS
		Create bpool and rpool and lay down the OS/7 dataset hierarchy.

	.DESCRIPTION
		The ZFS half of os7-setup's storage executor, and the half Update-OS7
		will share. Partitioning, the ESP and the LUKS2 container are the
		installer's own work (§6.2) and have already happened by the time this
		runs: -RootDevice is the /dev/mapper node, never the partition.

		WHAT IT DOES NOT DO, deliberately: it does not create /etc/hostid. That
		has to exist on the LIVE system BEFORE the pools are created, because a
		pool records the hostid of whoever last imported it and a mismatch at
		boot drops the machine into the initramfs (L13). Doing it here would be
		too late by one step. Spike S3 learned this the expensive way and the
		installer does it first.

	.PARAMETER Root
		The altroot. Everything is created with -R so no mountpoint escapes into
		the live system - /target, never /mnt: whatever carries the installer is
		usually mounted at /mnt and usually read-only, so ZFS cannot create its
		mountpoints underneath.

	.PARAMETER RootDevice
		The device rpool is created on. The LUKS mapper node (D3, §4.5).

	.PARAMETER BootDevice
		The partition bpool is created on. Unencrypted, because GRUB reads it.

	.PARAMETER BootEnvironment
		The BE name, from New-OS7BootEnvironmentName.

	.EXAMPLE
		New-OS7Storage -Root /target -RootDevice /dev/mapper/os7_root `
			-BootDevice /dev/disk/by-partlabel/os7-bpool `
			-BootEnvironment os7_1.0.0.0_202608241530
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)][string]$RootDevice,
		[Parameter(Mandatory)][string]$BootDevice,
		[Parameter(Mandatory)][string]$BootEnvironment,
		[Parameter()][string]$UserName = 'os7'
	)

	$dry = -not $PSCmdlet.ShouldProcess($RootDevice, 'create OS/7 pools and datasets')
	$created = [System.Collections.Generic.List[string]]::new()

	# Z1: every zpool/zfs call below goes through the Zfs module, never through
	# a process this module starts. Resolved here rather than at import time -
	# see Import-OS7ZfsLayer for why that distinction is load-bearing.
	if (-not $dry) { Import-OS7ZfsLayer }

	# A per-install suffix on the USERDATA datasets. It is what lets two
	# installs of the same user name coexist on one pool, which is exactly what
	# `R=Repair` does when it installs a new BE beside an old one (§3, Phase 6).
	$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)

	Write-OS7Step "boot environment $BootEnvironment"

	# THE DRY RUN IS A SEPARATE BRANCH, not -WhatIf passed downwards.
	#
	# PowerShell writes "What if:" to the HOST, and the host's output is stdout
	# (BUILD-NOTES #60). Handing -WhatIf to the Zfs cmdlets would therefore put
	# English prose in front of the JSON object os7-setup parses - the same trap
	# that makes Write-Verbose unusable here. So a dry run logs to stderr and
	# calls nothing, which is exactly what it did before.
	$describe = {
		param($what, $props)
		$p = if ($props) { ' ' + (($props.Keys | ForEach-Object { "$_=$($props[$_])" }) -join ' ') } else { '' }
		Write-OS7Step "would create $what$p"
	}

	# -- pools --------------------------------------------------------------
	# bpool: GRUB reads only the read-only-compatible feature set (§4.2).
	# `compatibility=grub2` is the maintained way to say that - ZFS ships the
	# list at /usr/share/zfs/compatibility.d/grub2, so it tracks GRUB instead of
	# being a hand-written feature@... incantation that rots. It excludes zstd,
	# which is why bpool compresses with lz4.
	#
	# ORDERED tables, not @{}: a plain hashtable enumerates in whatever order it
	# likes, and the command line that ends up in the install log should be
	# comparable to the one written down here.
	$bpoolProps = [ordered]@{
		ashift        = 12
		autotrim      = 'on'
		compatibility = 'grub2'
		cachefile     = '/etc/zfs/zpool.cache'
	}
	$bpoolFs = [ordered]@{
		devices       = 'off'
		acltype       = 'posixacl'
		xattr         = 'sa'
		compression   = 'lz4'
		normalization = 'formD'
		relatime      = 'on'
		canmount      = 'off'
		mountpoint    = '/boot'
	}
	if ($dry) { & $describe "pool bpool on $BootDevice" $bpoolProps }
	else {
		New-Zpool -Name bpool -Device $BootDevice -Force `
			-Property $bpoolProps -FilesystemProperty $bpoolFs `
			-AltRoot $Root -Confirm:$false | Out-Null
	}
	$created.Add('bpool')

	$rpoolProps = [ordered]@{
		ashift    = 12
		autotrim  = 'on'
		cachefile = '/etc/zfs/zpool.cache'
	}
	$rpoolFs = [ordered]@{
		acltype       = 'posixacl'
		xattr         = 'sa'
		dnodesize     = 'auto'
		compression   = 'lz4'
		normalization = 'formD'
		relatime      = 'on'
		canmount      = 'off'
		mountpoint    = '/'
	}
	if ($dry) { & $describe "pool rpool on $RootDevice" $rpoolProps }
	else {
		New-Zpool -Name rpool -Device $RootDevice -Force `
			-Property $rpoolProps -FilesystemProperty $rpoolFs `
			-AltRoot $Root -Confirm:$false | Out-Null
	}
	$created.Add('rpool')

	# -- the hierarchy (§4.4, as revised by D10) ----------------------------
	#
	# One helper, so that the list below reads as the layout it is rather than
	# as twenty near-identical calls. Out-Null on the result is not optional:
	# New-ZfsDataset returns the dataset it created (Z3) and anything returned
	# here lands on stdout in front of the JSON.
	$mk = {
		param($name, $props)
		if ($dry) { & $describe $name $props; return }
		New-ZfsDataset -Name $name -Property $props -Confirm:$false | Out-Null
	}

	$none = [ordered]@{ canmount = 'off'; mountpoint = 'none' }

	& $mk 'rpool/ROOT' $none
	& $mk 'bpool/BOOT' $none

	# canmount=noauto on the boot environment: several BEs exist side by side and
	# only the one named on the kernel command line may claim /. The initramfs
	# mounts it, which is what `boot=zfs` is for (BUILD-NOTES #15).
	& $mk "rpool/ROOT/$BootEnvironment" ([ordered]@{ canmount = 'noauto'; mountpoint = '/' })
	if ($dry) { Write-OS7Step "would mount rpool/ROOT/$BootEnvironment" }
	else { Mount-ZfsDataset -Name "rpool/ROOT/$BootEnvironment" -Confirm:$false | Out-Null }
	& $mk "bpool/BOOT/$BootEnvironment" ([ordered]@{ mountpoint = '/boot' })

	# IN the boot environment: package state describes exactly the /usr that
	# rolls with it. /var and /var/lib are canmount=off containers - the
	# directories live in the BE's root dataset and only the named children are
	# separate datasets, exactly as the OpenZFS root-on-ZFS layout does it.
	$off = [ordered]@{ canmount = 'off' }
	& $mk "rpool/ROOT/$BootEnvironment/var" $off
	& $mk "rpool/ROOT/$BootEnvironment/var/lib" $off
	& $mk "rpool/ROOT/$BootEnvironment/var/lib/dpkg" $null
	& $mk "rpool/ROOT/$BootEnvironment/var/lib/apt" $null
	& $mk "rpool/ROOT/$BootEnvironment/var/cache" $null

	# OUTSIDE the boot environment. D10's rule: a path belongs inside only if
	# rolling it back makes the system MORE correct. Logs explain the update
	# that failed; workload data is not the release's property; and the agents
	# that hold this device's identity in Entra, Intune and Arc must never come
	# back stale, because the tenant on the other end has no rollback.
	#
	# STRUCTURE, NOT DISCIPLINE: these hang under rpool/DATA rather than under
	# the BE with a do-not-clone property. zsys used a property and zsys is
	# gone; a dataset that is not a child of the BE cannot be cloned into the
	# next one by mistake. Forgetting a property is a bug that ships.
	& $mk 'rpool/DATA' $none
	& $mk 'rpool/DATA/log'   ([ordered]@{ mountpoint = '/var/log' })
	& $mk 'rpool/DATA/spool' ([ordered]@{ mountpoint = '/var/spool' })
	& $mk 'rpool/DATA/tmp'   ([ordered]@{ mountpoint = '/var/tmp' })
	& $mk 'rpool/DATA/srv'   ([ordered]@{ mountpoint = '/srv' })
	& $mk 'rpool/DATA/lib' $none
	& $mk 'rpool/DATA/snapd'              ([ordered]@{ mountpoint = '/var/lib/snapd' })
	& $mk 'rpool/DATA/lib/networkmanager' ([ordered]@{ mountpoint = '/var/lib/NetworkManager' })
	& $mk 'rpool/DATA/lib/authd'          ([ordered]@{ mountpoint = '/var/lib/authd' })
	& $mk 'rpool/DATA/lib/azcmagent'      ([ordered]@{ mountpoint = '/var/opt/azcmagent' })

	# USERDATA is a SIBLING of ROOT, not a child. This is the decision the whole
	# layout exists for: rolling back a bad release must not roll back the
	# user's files, and it cannot be retrofitted afterwards (§4.4).
	& $mk 'rpool/USERDATA' $none
	& $mk "rpool/USERDATA/root_$suffix"           ([ordered]@{ mountpoint = '/root' })
	& $mk "rpool/USERDATA/${UserName}_$suffix"    ([ordered]@{ mountpoint = "/home/$UserName" })

	Write-OS7Step 'datasets created'

	# The one thing on stdout: the result. os7-setup parses this.
	[pscustomobject]@{
		bootEnvironment = $BootEnvironment
		root            = $Root
		pools           = @($created)
		userSuffix      = $suffix
		dryRun          = [bool]$dry
	} | ConvertTo-Json -Compress
}

# ---------------------------------------------------------------------------
# Desktop appearance
#
# Implemented, not a stub. These exist for a reason beyond convenience: OS/7
# ships a non-default desktop appearance on a fleet that Intune manages, and a
# look that cannot be turned off is indistinguishable from a bug when somebody
# opens a support case. One documented command turns it off and on again.
#
# THE KEY LIST IS NOT DUPLICATED HERE. It is read out of the dconf keyfile the
# theme package installs, so adding a default to the theme automatically brings
# it under Set-OS7Theme instead of leaving a key nobody can reset.
# ---------------------------------------------------------------------------

$script:OS7ThemeKeyfile = '/etc/dconf/db/os7.d/00-os7-classic'
$script:OS7ThemeUserSetup = '/usr/libexec/os7-theme-user-setup'

function Get-OS7ThemeKeys {
	<#
	.SYNOPSIS
		Internal. The (schema, key) pairs OS/7's desktop defaults cover.
	#>
	param([string]$Keyfile = $script:OS7ThemeKeyfile)

	if (-not (Test-Path -PathType Leaf $Keyfile)) { return @() }

	$schema = $null
	$pairs = foreach ($line in (Get-Content -LiteralPath $Keyfile)) {
		$trimmed = $line.Trim()
		if ($trimmed -match '^\[(.+)\]$') {
			# dconf paths are org/gnome/...; GSettings schemas are org.gnome...
			$schema = $Matches[1].Trim('/') -replace '/', '.'
		}
		elseif ($schema -and $trimmed -match '^([A-Za-z0-9-]+)\s*=') {
			[pscustomobject]@{ Schema = $schema; Key = $Matches[1] }
		}
	}
	return @($pairs)
}

function Get-OS7Theme {
	<#
	.SYNOPSIS
		Reports which desktop appearance this session is actually using.

	.DESCRIPTION
		Asks the session, not the package. `dpkg -s os7-desktop-theme` says a
		theme is installed; it does not say a session is wearing it, and those
		two have come apart before — a dconf key removed by a GNOME upgrade
		leaves the package installed and the setting inert.

		Returns an object with the effective GTK theme, the Shell theme, whether
		the GTK 4 overrides are linked into this user's home, and which of the
		theme's own defaults are currently overridden by this user.

	.EXAMPLE
		Get-OS7Theme

	.EXAMPLE
		(Get-OS7Theme).Overridden
		The defaults this user has changed away from OS/7's.
	#>
	[CmdletBinding()]
	param()

	function Read-Setting([string]$schema, [string]$key) {
		try { (Invoke-OS7Native -Command 'gsettings' -Arguments @('get', $schema, $key)).Trim() }
		catch { $null }
	}

	$gtk = Read-Setting 'org.gnome.desktop.interface' 'gtk-theme'
	$shell = Read-Setting 'org.gnome.shell.extensions.user-theme' 'name'

	$gtk4 = Join-Path ($env:XDG_CONFIG_HOME ?? (Join-Path $HOME '.config')) 'gtk-4.0/gtk.css'
	$gtk4Linked = $false
	if (Test-Path -LiteralPath $gtk4) {
		$item = Get-Item -LiteralPath $gtk4 -Force
		$gtk4Linked = $item.LinkTarget -and $item.LinkTarget.StartsWith('/usr/share/os7-theme/')
	}

	# A default is "overridden" when the effective value differs from what the
	# system database alone would give. Reading the system database directly is
	# what makes this an answer rather than a guess.
	$overridden = foreach ($pair in (Get-OS7ThemeKeys)) {
		$effective = Read-Setting $pair.Schema $pair.Key
		$system = $null
		try {
			$system = (& env "DCONF_PROFILE=/etc/dconf/profile/user" dconf read `
				"/$($pair.Schema -replace '\.', '/')/$($pair.Key)" 2>$null)
		}
		catch { }
		if ($system -and $effective -and $effective -ne $system.Trim()) {
			[pscustomobject]@{
				Schema = $pair.Schema; Key = $pair.Key
				Effective = $effective; Default = $system.Trim()
			}
		}
	}

	[pscustomobject]@{
		Name             = if ($gtk -match 'OS7-Classic') { 'Classic' } else { 'Stock' }
		GtkTheme         = $gtk
		ShellTheme       = $shell
		Gtk4OverridesSet = $gtk4Linked
		DefaultsCovered  = (Get-OS7ThemeKeys).Count
		Overridden       = @($overridden)
	}
}

function Set-OS7Theme {
	<#
	.SYNOPSIS
		Switches this user's desktop between OS/7 Classic and stock GNOME.

	.DESCRIPTION
		Classic RESETS every key the theme's dconf database covers, rather than
		writing OS/7's values into the user's own database. Resetting hands the
		keys back to the system database, so the user tracks the shipped theme
		as it changes instead of freezing today's copy of it.

		Stock writes each of those keys to its SCHEMA default — read with the
		memory GSettings backend, which bypasses dconf entirely — so stock means
		"what GNOME would do here without OS/7", with no Ubuntu values hardcoded
		into this module.

		Both take effect for the running session. The Shell has to be restarted
		to repaint the panel, which under Wayland means logging out.

	.PARAMETER Name
		'Classic' or 'Stock'.

	.EXAMPLE
		Set-OS7Theme -Name Stock
		Hand this user a stock GNOME desktop, e.g. to reproduce a support case.

	.EXAMPLE
		Set-OS7Theme -Name Classic
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)]
		[ValidateSet('Classic', 'Stock')]
		[string]$Name
	)

	$keys = Get-OS7ThemeKeys
	if ($keys.Count -eq 0) {
		throw [System.InvalidOperationException]::new(
			"No desktop defaults found at $($script:OS7ThemeKeyfile). Is os7-desktop-theme installed?")
	}

	$dry = -not $PSCmdlet.ShouldProcess("this user's desktop", "switch to $Name")

	foreach ($pair in $keys) {
		if ($Name -eq 'Classic') {
			Invoke-OS7Native -Command 'gsettings' -WhatIf:$dry `
				-Arguments @('reset', $pair.Schema, $pair.Key) | Out-Null
		}
		else {
			# The schema default, uncontaminated by any dconf database.
			$default = & env GSETTINGS_BACKEND=memory gsettings get $pair.Schema $pair.Key 2>$null
			if ($LASTEXITCODE -ne 0 -or -not $default) {
				Write-OS7Step "skip: $($pair.Schema) $($pair.Key) - no schema default readable"
				continue
			}
			Invoke-OS7Native -Command 'gsettings' -WhatIf:$dry `
				-Arguments @('set', $pair.Schema, $pair.Key, $default.Trim()) | Out-Null
		}
	}

	# The GTK 4 overrides live in the user's home and are not a dconf key.
	if (Test-Path -PathType Leaf $script:OS7ThemeUserSetup) {
		$action = if ($Name -eq 'Classic') { '--install' } else { '--remove' }
		Invoke-OS7Native -Command $script:OS7ThemeUserSetup -WhatIf:$dry `
			-Arguments @($action) | Out-Null
	}

	if (-not $dry) {
		Write-OS7Step "desktop set to $Name; log out and back in to repaint the Shell"
	}

	Get-OS7Theme
}

function Set-OS7Mode {
	<#
	.SYNOPSIS
		STUB. Sets the OS/7 system mode.

	.DESCRIPTION
		NOT IMPLEMENTED. The semantics of "mode" are not yet settled and this
		signature is a placeholder, not a locked interface.

		README.md lists Set-OS7Mode alongside Update-OS7 / Restore-OS7 under
		"Updates", but also states that GUI vs. headless is decided by the
		installer — "a setup-time choice, not just a runtime toggle". Those two
		statements leave the command genuinely ambiguous. It could mean:

		  a) switch an installed system between GUI (GNOME) and headless,
		     which per README is at most a partial operation post-install; or
		  b) select the release-train channel this system follows.

		(a) is assumed below only because it fits the name. Resolve this before
		writing any implementation.

	.PARAMETER Mode
		STUB. 'GUI' or 'Headless'.

	.EXAMPLE
		Set-OS7Mode -Mode Headless
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory)]
		[ValidateSet('GUI', 'Headless')]
		[string]$Mode
	)

	throw [System.NotImplementedException]::new(
		'Set-OS7Mode is a stub. Mode semantics are unresolved — see the .DESCRIPTION help and README.md.')
}

function Update-OS7 {
	<#
	.SYNOPSIS
		STUB. Applies the next curated OS/7 release into a new ZFS boot
		environment.

	.DESCRIPTION
		NOT IMPLEMENTED. Intended behaviour per README.md:

		  - Take a new ZFS boot environment, apply the curated release there,
		    leave the running environment untouched so Restore-OS7 can roll back.
		  - Carry PowerShell 7 itself along in that same release train — never a
		    standalone 'apt upgrade powershell' — so the system stays atomically
		    rollback-safe.

		NO LONGER BLOCKED ON ZFS. Open Question #1 (ZFS on the Linux 7.0 kernel)
		was resolved on 2026-08-22, spike S3 installed a bootable ZFS-on-LUKS
		root on 2026-08-23, and New-OS7Storage above now creates the layout this
		function has to clone. What is missing is the release train it applies:
		installer/SETUP-PLAN.md Phase 6 is where these stop being stubs.

	.PARAMETER WhatIf
		STUB. Should report the pending release without applying it.

	.EXAMPLE
		Update-OS7 -WhatIf
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param()

	throw [System.NotImplementedException]::new(
		'Update-OS7 is a stub. The ZFS layer it needs exists (New-OS7Storage); the release train does not. See installer/SETUP-PLAN.md Phase 6.')
}

function Restore-OS7 {
	<#
	.SYNOPSIS
		STUB. Rolls the system back to a previous OS/7 ZFS boot environment.

	.DESCRIPTION
		NOT IMPLEMENTED. Intended behaviour per README.md: select an earlier
		boot environment created by Update-OS7 and make it the active one, so a
		bad release is recoverable without reinstalling.

		Not blocked on ZFS any more — see Update-OS7. The naming scheme it needs
		in order to LIST and SORT boot environments now exists as
		New-OS7BootEnvironmentName (SETUP-PLAN §4.4).

	.PARAMETER BootEnvironment
		STUB. Name of the boot environment to activate. No naming scheme defined.

	.EXAMPLE
		Restore-OS7 -BootEnvironment os7_1.0.0.31_202608231430
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter()]
		[string]$BootEnvironment
	)

	throw [System.NotImplementedException]::new(
		'Restore-OS7 is a stub. The boot-environment naming scheme exists (New-OS7BootEnvironmentName); the activation logic does not. See installer/SETUP-PLAN.md Phase 6.')
}

Export-ModuleMember -Function New-OS7Storage, New-OS7BootEnvironmentName,
	Get-OS7Theme, Set-OS7Theme,
	Set-OS7Mode, Update-OS7, Restore-OS7
