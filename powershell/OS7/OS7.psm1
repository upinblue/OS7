# =============================================================================
# OS/7 PowerShell module
#
# TWO HALVES, and the difference matters when reading this file:
#
#   IMPLEMENTED   New-OS7Storage, New-OS7BootEnvironmentName — the ZFS layer,
#                 written for os7-setup's Phase 2 storage executor.
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

	# A per-install suffix on the USERDATA datasets. It is what lets two
	# installs of the same user name coexist on one pool, which is exactly what
	# `R=Repair` does when it installs a new BE beside an old one (§3, Phase 6).
	$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)

	Write-OS7Step "boot environment $BootEnvironment"

	# -- pools --------------------------------------------------------------
	# bpool: GRUB reads only the read-only-compatible feature set (§4.2).
	# `-o compatibility=grub2` is the maintained way to say that - ZFS ships the
	# list at /usr/share/zfs/compatibility.d/grub2, so it tracks GRUB instead of
	# being a hand-written -o feature@... incantation that rots. It excludes
	# zstd, which is why bpool compresses with lz4.
	Invoke-OS7Native -WhatIf:$dry zpool @(
		'create', '-f',
		'-o', 'ashift=12', '-o', 'autotrim=on',
		'-o', 'compatibility=grub2',
		'-o', 'cachefile=/etc/zfs/zpool.cache',
		'-O', 'devices=off', '-O', 'acltype=posixacl', '-O', 'xattr=sa',
		'-O', 'compression=lz4', '-O', 'normalization=formD', '-O', 'relatime=on',
		'-O', 'canmount=off', '-O', 'mountpoint=/boot', '-R', $Root,
		'bpool', $BootDevice) | Out-Null
	$created.Add('bpool')

	Invoke-OS7Native -WhatIf:$dry zpool @(
		'create', '-f',
		'-o', 'ashift=12', '-o', 'autotrim=on',
		'-o', 'cachefile=/etc/zfs/zpool.cache',
		'-O', 'acltype=posixacl', '-O', 'xattr=sa', '-O', 'dnodesize=auto',
		'-O', 'compression=lz4', '-O', 'normalization=formD', '-O', 'relatime=on',
		'-O', 'canmount=off', '-O', 'mountpoint=/', '-R', $Root,
		'rpool', $RootDevice) | Out-Null
	$created.Add('rpool')

	# -- the hierarchy (§4.4, as revised by D10) ----------------------------
	$zfs = { param($a) Invoke-OS7Native -WhatIf:$dry zfs $a | Out-Null }

	& $zfs @('create', '-o', 'canmount=off', '-o', 'mountpoint=none', 'rpool/ROOT')
	& $zfs @('create', '-o', 'canmount=off', '-o', 'mountpoint=none', 'bpool/BOOT')

	# canmount=noauto on the boot environment: several BEs exist side by side and
	# only the one named on the kernel command line may claim /. The initramfs
	# mounts it, which is what `boot=zfs` is for (BUILD-NOTES #15).
	& $zfs @('create', '-o', 'canmount=noauto', '-o', 'mountpoint=/', "rpool/ROOT/$BootEnvironment")
	& $zfs @('mount', "rpool/ROOT/$BootEnvironment")
	& $zfs @('create', '-o', 'mountpoint=/boot', "bpool/BOOT/$BootEnvironment")

	# IN the boot environment: package state describes exactly the /usr that
	# rolls with it. /var and /var/lib are canmount=off containers - the
	# directories live in the BE's root dataset and only the named children are
	# separate datasets, exactly as the OpenZFS root-on-ZFS layout does it.
	& $zfs @('create', '-o', 'canmount=off', "rpool/ROOT/$BootEnvironment/var")
	& $zfs @('create', '-o', 'canmount=off', "rpool/ROOT/$BootEnvironment/var/lib")
	& $zfs @('create', "rpool/ROOT/$BootEnvironment/var/lib/dpkg")
	& $zfs @('create', "rpool/ROOT/$BootEnvironment/var/lib/apt")
	& $zfs @('create', "rpool/ROOT/$BootEnvironment/var/cache")

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
	& $zfs @('create', '-o', 'canmount=off', '-o', 'mountpoint=none', 'rpool/DATA')
	& $zfs @('create', '-o', 'mountpoint=/var/log',   'rpool/DATA/log')
	& $zfs @('create', '-o', 'mountpoint=/var/spool', 'rpool/DATA/spool')
	& $zfs @('create', '-o', 'mountpoint=/var/tmp',   'rpool/DATA/tmp')
	& $zfs @('create', '-o', 'mountpoint=/srv',       'rpool/DATA/srv')
	& $zfs @('create', '-o', 'canmount=off', '-o', 'mountpoint=none', 'rpool/DATA/lib')
	& $zfs @('create', '-o', 'mountpoint=/var/lib/snapd',           'rpool/DATA/snapd')
	& $zfs @('create', '-o', 'mountpoint=/var/lib/NetworkManager',  'rpool/DATA/lib/networkmanager')
	& $zfs @('create', '-o', 'mountpoint=/var/lib/authd',           'rpool/DATA/lib/authd')
	& $zfs @('create', '-o', 'mountpoint=/var/opt/azcmagent',       'rpool/DATA/lib/azcmagent')

	# USERDATA is a SIBLING of ROOT, not a child. This is the decision the whole
	# layout exists for: rolling back a bad release must not roll back the
	# user's files, and it cannot be retrofitted afterwards (§4.4).
	& $zfs @('create', '-o', 'canmount=off', '-o', 'mountpoint=none', 'rpool/USERDATA')
	& $zfs @('create', '-o', "mountpoint=/root", "rpool/USERDATA/root_$suffix")
	& $zfs @('create', '-o', "mountpoint=/home/$UserName", "rpool/USERDATA/${UserName}_$suffix")

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
	Set-OS7Mode, Update-OS7, Restore-OS7
