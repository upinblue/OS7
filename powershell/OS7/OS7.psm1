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
#
#                 Get-/New-/Set-/Remove-OS7BootEnvironment and Restore-OS7 —
#                 boot environments, added 2026-08-25 and walked end to end in a
#                 VM by spike S5 (docs/SESSION-BOOT-ENVIRONMENTS.md). This is
#                 the half of docs/RELEASE-AND-UPDATE-PLAN.md §4.2 that has no
#                 equivalent in the S3 install script — steps 1, 2 and 9.
#   STUB          Set-OS7Mode, Update-OS7 — signatures only, each throwing
#                 NotImplementedException, pinning the command surface
#                 docs/DECISIONS.md documents. Update-OS7 is no longer waiting
#                 on boot environments; it is waiting on there being an OS/7
#                 release to apply (CURATION-AND-DELIVERY-PLAN.md C7).
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
		# NOT Mandatory, and that is a fix rather than a loosening: a mandatory
		# [string[]] REFUSES an empty array ("Cannot bind argument … because it
		# is an empty array"), so a command that takes no arguments at all —
		# `update-grub` is the one this module needs — could not be run through
		# here without inventing one.
		[string[]]$Arguments = @(),
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
# Boot environments
#
# WHAT ONE IS HERE: a PAIR of dataset trees, one per pool — rpool/ROOT/<name>,
# which becomes `/`, and bpool/BOOT/<name>, which becomes `/boot`.
# docs/RELEASE-AND-UPDATE-PLAN.md §4.3 requires them to be cloned together,
# activated together and destroyed together, and the halves never to be exposed
# separately: a half-activated pair boots the old kernel against the new root,
# and says so at boot rather than at update time.
#
# SIX THINGS WERE MEASURED ON A BOOTED OS/7 MACHINE before a line of this was
# written (docs/SESSION-BOOT-ENVIRONMENTS.md §2). Every one of them changed the
# code, so they are here rather than in the session document alone:
#
#  1. `/etc/grub.d/10_linux_zfs` is the generator. `10_linux` emits NOTHING —
#     the BEGIN/END markers in grub.cfg have nothing between them. Entry ids are
#     `gnulinux-<root dataset>-<kernel version>`, so an id changes when the
#     kernel does and must be READ OUT of grub.cfg, never constructed.
#  2. A menu entry loads its kernel by a dataset-qualified path,
#     `/BOOT/<be>@/vmlinuz-<v>`, and passes `root=ZFS=rpool/ROOT/<be> boot=zfs`.
#     Which kernel and which root an entry boots is therefore decided entirely
#     by the entry; no mount takes part in it.
#  3. THE ESP STUB NAMES THE BOOT ENVIRONMENT. Both /boot/efi/EFI/BOOT/grub.cfg
#     and /boot/efi/EFI/OS7/grub.cfg contain
#         set prefix=($root)'/BOOT/<be>@/grub'
#     so GRUB reads the menu belonging to exactly ONE boot environment. Anything
#     that activates a BE without rewriting those two files changes nothing GRUB
#     will ever see. This is the fact the whole file is shaped around, and it is
#     the one that would not have been guessed.
#  4. `set default="${next_entry}"` is emitted even though GRUB_DEFAULT is 0, so
#     `grub-reboot` would work. It is deliberately not used — see 5.
#  5. The machine mounts with `zfs mount -a` (zfs-mount.service; there is no
#     /etc/zfs/zfs-list.cache, so no mount generator). EVERY dataset with
#     canmount=on and a mountpoint is mounted — so a second boot environment
#     whose /var/lib/dpkg is canmount=on would be mounted straight over the
#     running system's. An inactive BE therefore carries canmount=noauto on
#     every dataset that would otherwise mount, and activation flips them.
#     It is also why there is no one-shot "just boot it once" switch: a BE
#     booted without being activated would get the ACTIVATED BE's /boot and
#     /var/lib/dpkg, which is exactly the half-activated pair §4.3 forbids.
#  6. Neither pool has `bootfs` set, and no com.ubuntu.zsys property exists
#     anywhere, so nothing else is quietly deciding what boots.
#
# WHAT ACTIVATION IS, in one line: point the ESP stub at the target, having
# first proved the target has a menu entry to boot.
# ---------------------------------------------------------------------------

$script:OS7RootParent = 'rpool/ROOT'
$script:OS7BootParent = 'bpool/BOOT'

# Both, always. grub-install writes the removable path and the NVRAM path
# separately (SystemSteps.BootloaderStep) and a machine can boot from either,
# so a rollback that rewrote one of them would work until the day the firmware
# chose the other.
$script:OS7EspStubs = @(
	'/boot/efi/EFI/BOOT/grub.cfg',
	'/boot/efi/EFI/OS7/grub.cfg'
)

# The running system's /boot. A variable rather than a literal so that
# installer/testing/check-be-logic.py can point the whole of this at a temporary
# tree — the alternative is that the activation path is only ever exercised by a
# twenty-five-minute VM run.
$script:OS7BootDir = '/boot'
$script:OS7GrubDefaults = '/etc/default/grub'
$script:OS7GrubCfg = '/boot/grub/grub.cfg'

# OS/7's own menu. The entries live in a plain file so that what GRUB will read
# can be read with `cat` before rebooting; the grub.d script does nothing but
# emit it. 09_, so these come before 10_linux_zfs's single entry.
$script:OS7MenuFile   = '/etc/os7/grub-boot-environments.cfg'
$script:OS7MenuScript = '/etc/grub.d/09_os7-boot-environments'

# Where a boot dataset is mounted while it is written to. NOT its own
# mountpoint: /boot belongs to the active BE and must keep belonging to it for
# the whole operation. `mount -t zfs -o zfsutil` rather than touching the
# mountpoint property, because a mountpoint changed and then not changed back —
# by a crash, a signal, or an error path — leaves a machine that will not boot,
# and because it is exactly what 10_linux_zfs itself does to read a BE.
$script:OS7BeScratch = '/run/os7-be'

function Split-OS7BootEnvironmentName {
	<#
	.SYNOPSIS
		The release out of os7_<release>_<stamp>. $null when the name does not
		carry one, which is a fact about the machine and not an error.
	#>
	param([Parameter(Mandatory)][string]$Name)

	$m = [regex]::Match($Name, '^os7_(?<release>[^_]+)_(?<stamp>\d{12})$')
	if (-not $m.Success) { return $null }
	[pscustomobject]@{
		Release = $m.Groups['release'].Value
		Stamp   = $m.Groups['stamp'].Value
	}
}

function Get-OS7MenuBootEnvironment {
	<#
	.SYNOPSIS
		The boot environment whose menu GRUB actually reads, from the ESP stub.

	.DESCRIPTION
		Measured fact 3. This is the answer to "what will this machine boot", and
		it is not the same question as "what is mounted at /" — after an
		activation and before the reboot they are deliberately different.

		Reads the stub rather than remembering what was written: the file is the
		authority, and an OS/7 that trusted its own memory here would report a
		successful rollback on a machine that boots the other environment.
	#>
	[CmdletBinding()]
	param()

	foreach ($stub in $script:OS7EspStubs) {
		if (-not (Test-Path $stub)) { continue }
		$m = [regex]::Match((Get-Content -Raw $stub), "/BOOT/(?<be>[^@']+)@/grub")
		if ($m.Success) { return $m.Groups['be'].Value }
	}
	return $null
}

function Find-OS7MenuEntryPath {
	<#
	.SYNOPSIS
		The path GRUB needs in order to be told to boot a given root dataset.

	.DESCRIPTION
		Returns what `saved_entry` has to contain, which is NOT simply the entry
		id: an entry inside a submenu is addressed as
		'<submenu id>>><entry id>' — the ids of every enclosing submenu, joined
		with '>'. That matters here rather than in theory, because 10_linux_zfs
		emits ONE top-level entry per machine-id and files every other boot
		environment of that machine under a "History for …" submenu. The
		environment being rolled back to is, by construction, one of those.

		So the menu is parsed rather than pattern-matched: walk it, track the
		submenus, and return the first entry whose id names the wanted dataset.
		$null when there is none, which is the caller's guard.

	.PARAMETER Config
		The text of grub.cfg.

	.PARAMETER RootDataset
		rpool/ROOT/<be>.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Config,
		[Parameter(Mandatory)][string]$RootDataset
	)

	# TWO SHAPES, because two generators emit entries on this machine.
	# 10_linux_zfs builds 'gnulinux-<dataset>-<kernel version>' — the kernel
	# version is part of it, so it is matched rather than constructed; a built id
	# goes stale the first time an environment gets a new kernel, and GRUB answers
	# a stale saved_entry by silently booting something else. OS/7's own fragment
	# builds 'os7-be-<name>', which is stable by construction (BUILD-NOTES #67).
	# EACH ELEMENT IN ITS OWN PARENTHESES. PowerShell's comma binds TIGHTER than
	# `+`, so `@("a" + $x + "-", "b" + $y)` is not a two-element array: the comma
	# builds `("-", "b")`, adding an array to a string joins it with $OFS, and the
	# result is ONE element with a space in the middle of it. It matches nothing
	# and reports no error. BUILD-NOTES #68.
	$leaf = Split-Path -Leaf $RootDataset
	$wanted = @(("gnulinux-" + $RootDataset + "-"), ("os7-be-" + $leaf))

	# BOTH kinds go on the stack, and that is the whole subtlety: a menuentry
	# opens a brace too, so popping only on submenus would let an entry's own
	# closing '}' close the submenu around it — and every following entry would
	# then be reported at the wrong depth. Only the submenu frames contribute to
	# the path.
	$stack = [System.Collections.Generic.List[object]]::new()

	foreach ($line in ($Config -split "`n")) {
		$t = $line.Trim()

		if ($t -match "^submenu\s+.*'(?<id>[^']+)'\s*\{\s*$") {
			$stack.Add([pscustomobject]@{ Kind = 'submenu'; Id = $Matches['id'] })
			continue
		}
		if ($t -match "^menuentry\s+.*'(?<id>[^']+)'\s*\{\s*$") {
			$id = $Matches['id']
			$hit = $false
			foreach ($w in $wanted) { if ($id -eq $w -or $id.StartsWith($w)) { $hit = $true } }
			if ($hit) {
				$path = @($stack | Where-Object Kind -eq 'submenu' | ForEach-Object Id) + @($id)
				return ($path -join '>')
			}
			$stack.Add([pscustomobject]@{ Kind = 'entry'; Id = $id })
			continue
		}
		if ($t -eq '}' -and $stack.Count -gt 0) {
			$stack.RemoveAt($stack.Count - 1)
		}
	}
	return $null
}

function Get-OS7BootEnvironmentKernel {
	<#
	.SYNOPSIS
		The kernel and initrd filenames inside a boot environment's own /boot.

	.DESCRIPTION
		Read out of the environment's bpool dataset, because that is the only
		place the answer is true: two environments hold different kernels as soon
		as one of them takes an update, and a menu entry that names the wrong file
		is a boot that stops in GRUB.

		The ACTIVE environment's /boot is already mounted, so it is read in place.
		Every other one is mounted at the scratch path and unmounted again —
		never at /boot, which belongs to the running system for the whole
		operation.
	#>
	[CmdletBinding()]
	param([Parameter(Mandatory)][object]$BootEnvironment)

	$read = {
		param($dir)
		$k = Get-ChildItem -Path $dir -Filter 'vmlinuz-*' -ErrorAction SilentlyContinue |
			Sort-Object Name -Descending | Select-Object -First 1
		$i = Get-ChildItem -Path $dir -Filter 'initrd.img-*' -ErrorAction SilentlyContinue |
			Sort-Object Name -Descending | Select-Object -First 1
		[pscustomobject]@{ Kernel = $(if ($k) { $k.Name }); Initrd = $(if ($i) { $i.Name }) }
	}

	if ($BootEnvironment.Active) { return (& $read $script:OS7BootDir) }

	New-Item -ItemType Directory -Force -Path $script:OS7BeScratch | Out-Null
	try {
		Invoke-OS7Native -Command 'mount' -Arguments @(
			'-t', 'zfs', '-o', 'zfsutil', $BootEnvironment.BootDataset,
			$script:OS7BeScratch) | Out-Null
		return (& $read $script:OS7BeScratch)
	}
	finally {
		try { Invoke-OS7Native -Command 'umount' -Arguments @($script:OS7BeScratch) | Out-Null }
		catch { Write-OS7Step "note: $($script:OS7BeScratch) was not mounted" }
	}
}

function Get-OS7MenuEntryBlock {
	<#
	.SYNOPSIS
		The whole `menuentry … { … }` block for a root dataset, as text.

	.DESCRIPTION
		The template half of New-OS7MenuFragment. Returns the top-level entry —
		the first one, not the copies inside "Advanced options" — because that is
		the one with the plain kernel command line.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Config,
		[Parameter(Mandatory)][string]$RootDataset
	)

	# BOTH id shapes, for the same reason Find-OS7MenuEntryPath takes both — and
	# this function needed it more, not less. After the first activation the
	# RUNNING environment is one OS/7 created, so 10_linux_zfs has no
	# `gnulinux-<dataset>-…` entry for it and the only entry it has is OS/7's
	# own. A template lookup that knew one shape found nothing, and the rollback
	# refused with "the running system has no entry of its own" — which was
	# true of the shape and false of the menu.
	$leaf = Split-Path -Leaf $RootDataset
	$wanted = @(("gnulinux-" + $RootDataset + "-"), ("os7-be-" + $leaf))
	$lines = $Config -split "`n"
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$t = $lines[$i].Trim()
		if ($t -notmatch "^menuentry\s+.*'(?<id>[^']+)'\s*\{\s*$") { continue }
		$id = $Matches['id']
		$hit = $false
		foreach ($w in $wanted) { if ($id -eq $w -or $id.StartsWith($w)) { $hit = $true } }
		if (-not $hit) { continue }
		$depth = 1
		$block = [System.Collections.Generic.List[string]]::new()
		$block.Add($lines[$i])
		for ($j = $i + 1; $j -lt $lines.Count -and $depth -gt 0; $j++) {
			$s = $lines[$j].Trim()
			if ($s -match '\{\s*$') { $depth++ }
			elseif ($s -eq '}') { $depth-- }
			$block.Add($lines[$j])
			if ($depth -eq 0) { break }
		}
		return ($block -join "`n")
	}
	return $null
}

function New-OS7MenuFragment {
	<#
	.SYNOPSIS
		A GRUB menu entry for every complete boot environment on this machine.

	.DESCRIPTION
		OS/7 OWNS ITS BOOT MENU, and it has to, because the stock generator
		cannot produce one. MEASURED 2026-08-25 in `/etc/grub.d/10_linux_zfs`:

		    if [ "${section}" = "history" ]; then
		        if [ "${iszsys}" != "yes" ] || … ; then continue; fi
		    fi

		On a machine with no `zsys` — which OS/7 is, by decision — the whole
		`history` section is skipped, and `main` and `advanced` are emitted for
		ONE dataset per machine-id: whichever sorts first by last-used. The
		running environment is handed the current time by that generator, so it
		always sorts first, so **a second boot environment can never appear in a
		menu generated from the first**. Every clone in this repository's S5 runs
		was found by `update-grub` ("Found linux image … in rpool/ROOT/os7_…")
		and then emitted by nothing. BUILD-NOTES #67.

		THE ENTRIES ARE BUILT FROM THE RUNNING ONE, not written from scratch.
		Both environments live in the same two pools, so everything that is hard
		to get right — the `search --fs-uuid` line, the `insmod`s, the ordering of
		`linux` and `initrd` — is identical, and the only things that differ are
		the dataset name and the kernel filenames. A hand-written entry would be a
		guess about a bootloader; a substitution into a known-good one is not.

	.PARAMETER Config
		The current grub.cfg, to take the template from.

	.PARAMETER Template
		The root dataset whose entry is the template — the running one.

	.PARAMETER Environments
		Objects from Get-OS7BootEnvironment, each with a Kernel and Initrd
		filename discovered in its own boot dataset.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Config,
		[Parameter(Mandatory)][string]$Template,
		[Parameter(Mandatory)][object[]]$Environments
	)

	$block = Get-OS7MenuEntryBlock -Config $Config -RootDataset $Template
	if (-not $block) {
		throw [System.InvalidOperationException]::new(
			"no menu entry for $Template to use as a template. The running system has no " +
			'entry of its own, which is a broken menu rather than a missing feature.')
	}
	$templateBe = Split-Path -Leaf $Template

	$out = [System.Collections.Generic.List[string]]::new()
	$out.Add('# Generated by OS/7 (Set-OS7BootEnvironment). Do not edit.')
	$out.Add('#')
	$out.Add('# One entry per boot environment, built by substitution into the entry')
	$out.Add('# 10_linux_zfs emits for the running one. See BUILD-NOTES #67 for why the')
	$out.Add('# stock generator cannot list more than one.')

	foreach ($be in $Environments) {
		if (-not $be.Complete -or -not $be.Kernel -or -not $be.Initrd) { continue }
		$text = $block

		# The dataset, everywhere it appears: root=ZFS=, the /BOOT/<be>@ paths,
		# and the entry id.
		$text = $text.Replace($Template, $be.RootDataset)
		$text = $text.Replace("/BOOT/$templateBe@", "/BOOT/$($be.Name)@")

		# The kernel and initrd FILENAMES, which differ as soon as one
		# environment takes an update the other has not.
		$text = [regex]::Replace($text, '/vmlinuz-[^"'' ]+', "/$($be.Kernel)")
		$text = [regex]::Replace($text, '/initrd\.img-[^"'' ]+', "/$($be.Initrd)")

		# A title and an id OS/7 chooses, so that neither collides with anything
		# 10_linux_zfs emits and both name the environment plainly.
		# (?m), or `^` and `$` anchor to the whole block rather than to its first
		# line and this replaces nothing at all — silently, leaving the template's
		# id in place and two entries claiming to be the same one. And `$$` in the
		# replacement, because .NET reads `$` there as a group reference.
		$title = "OS/7 $($be.Release) — $($be.Name)"
		$text = [regex]::Replace($text, "(?m)^menuentry\s+.*\{\s*$",
			"menuentry '$title' --class os_7 --class gnu-linux --class gnu --class os " +
			"`$`$menuentry_id_option 'os7-be-$($be.Name)' {")

		$out.Add('')
		$out.Add($text)
	}
	return ($out -join "`n") + "`n"
}

function Get-OS7BootEnvironment {
	<#
	.SYNOPSIS
		The boot environments on this machine, with what is active and what boots.

	.DESCRIPTION
		docs/RELEASE-AND-UPDATE-PLAN.md §6. Three different flags, because on a
		machine mid-update they are three different environments:

		  Active   its root dataset is mounted at / — what is running NOW
		  Menu     the ESP stub points at it — what will boot NEXT
		  Complete both halves of the pair exist

		Complete is not decoration. A BE with no bpool half has no kernel, and
		the failure appears at boot as an initramfs prompt rather than here.

	.PARAMETER Name
		One boot environment. Without it, all of them, oldest first.

	.EXAMPLE
		Get-OS7BootEnvironment | Format-Table Name, Active, Menu, Created
	#>
	[CmdletBinding()]
	[OutputType('OS7.BootEnvironment')]
	param([Parameter(Position = 0)][string]$Name)

	Import-OS7ZfsLayer

	# -Depth 1 includes the parent itself; it is not a boot environment.
	$roots = @(Get-ZfsDataset -Name $script:OS7RootParent -Depth 1 -Type Filesystem |
		Where-Object { $_.Name -ne $script:OS7RootParent })
	$boots = @{}
	foreach ($b in @(Get-ZfsDataset -Name $script:OS7BootParent -Depth 1 -Type Filesystem |
			Where-Object { $_.Name -ne $script:OS7BootParent })) {
		$boots[[string](Split-Path -Leaf $b.Name)] = $b
	}

	$menu = Get-OS7MenuBootEnvironment

	$out = foreach ($r in $roots) {
		$leaf = [string](Split-Path -Leaf $r.Name)
		if ($Name -and $leaf -ne $Name) { continue }
		$b = if ($boots.ContainsKey($leaf)) { $boots[$leaf] } else { $null }
		$parts = Split-OS7BootEnvironmentName -Name $leaf

		[pscustomobject]@{
			PSTypeName  = 'OS7.BootEnvironment'
			Name        = $leaf
			Release     = if ($parts) { $parts.Release } else { $null }
			Created     = $r.Creation
			Active      = [bool]$r.Mounted
			Menu        = ($leaf -eq $menu)
			Complete    = ($null -ne $b)
			RootDataset = $r.Name
			BootDataset = if ($b) { $b.Name } else { $null }
			Used        = [uint64]$r.Used + [uint64]$(if ($b) { $b.Used } else { 0 })
			Origin      = $r.Origin
		}
	}

	# Oldest first, so "the previous one" is the entry before the active one and
	# Restore-OS7 has something well-defined to mean.
	$out | Sort-Object Created, Name
}

function New-OS7BootEnvironment {
	<#
	.SYNOPSIS
		Clone the running boot environment into a new one, inactive.

	.DESCRIPTION
		Steps 1 and 2 of docs/RELEASE-AND-UPDATE-PLAN.md §4.2 — the part of the
		update sequence that has no equivalent in the S3 install script, and the
		part that has to treat the pair as one object.

		THE SNAPSHOT IS RECURSIVE AND TAKEN PER POOL. `zfs snapshot -r` is atomic
		across the descendants; taking them one at a time is not the same thing,
		and the descendants here are /var/lib/dpkg and /var/lib/apt — the two
		datasets whose disagreement with each other is exactly what a package
		operation must never see.

		THE CLONE IS CREATED INACTIVE, which is measured fact 5 above: this
		machine mounts with `zfs mount -a`, so a clone whose /var/lib/dpkg kept
		canmount=on would be mounted over the running system's within one
		`zfs mount -a`. Every cloned dataset that was `on` becomes `noauto`;
		`off` containers stay `off`; the root dataset is `noauto` in both, since
		the initramfs mounts it by name from the kernel command line.

	.PARAMETER Name
		The new boot environment. Defaults to New-OS7BootEnvironmentName.

	.PARAMETER From
		The boot environment to clone. Defaults to the active one.

	.PARAMETER Release
		The release the new BE is for, when -Name is not given.

	.EXAMPLE
		New-OS7BootEnvironment -Release 1.0.1.4
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	[OutputType('OS7.BootEnvironment')]
	param(
		[Parameter(Position = 0)][string]$Name,
		[Parameter()][string]$From,
		[Parameter()][string]$Release
	)

	Import-OS7ZfsLayer

	$all = @(Get-OS7BootEnvironment)
	if (-not $From) {
		$active = $all | Where-Object Active
		if (-not $active) {
			throw [System.InvalidOperationException]::new(
				'no boot environment is mounted at / — pass -From to say which one to clone')
		}
		$From = $active.Name
	}
	$source = $all | Where-Object Name -eq $From
	if (-not $source) {
		throw [System.InvalidOperationException]::new("no boot environment called '$From'")
	}
	if (-not $source.Complete) {
		throw [System.InvalidOperationException]::new(
			"'$From' has no $($script:OS7BootParent) half — there is nothing to clone the kernel from")
	}
	if (-not $Name) { $Name = New-OS7BootEnvironmentName -Release $Release }
	if ($all | Where-Object Name -eq $Name) {
		throw [System.InvalidOperationException]::new("'$Name' already exists")
	}

	if (-not $PSCmdlet.ShouldProcess($Name, "clone from $From")) { return }

	Write-OS7Step "new boot environment $Name from $From"

	# The snapshot is named after the environment it creates, so `zfs list -t
	# snapshot` says what a snapshot was taken FOR rather than when.
	foreach ($parent in @($script:OS7RootParent, $script:OS7BootParent)) {
		New-ZfsSnapshot -Name "$parent/$From" -SnapshotName $Name -Recurse -Confirm:$false | Out-Null
	}

	foreach ($parent in @($script:OS7RootParent, $script:OS7BootParent)) {
		$src = "$parent/$From"
		$tree = @(Get-ZfsDataset -Name $src -Recurse -Type Filesystem | Sort-Object Name)

		# BOTH properties, read off the source, and BOTH set explicitly on every
		# clone. MEASURED 2026-08-25, and it is the thing about `zfs clone` that
		# has to be known: A CLONE DOES NOT CARRY THE ORIGIN'S LOCAL PROPERTIES.
		# It is created like `zfs create` — inheriting from its new parent, and
		# taking the DEFAULT for canmount, which does not inherit at all. So a
		# clone of a `canmount=noauto mountpoint=/` boot environment comes out
		# `canmount=on mountpoint=none`, which is wrong twice over:
		#
		#   * canmount=on with mountpoint=/ is a dataset that `zfs mount -a`
		#     would mount over the RUNNING root, and
		#   * mountpoint=none makes it invisible to 10_linux_zfs, whose
		#     get_root_datasets looks for mountpoint '/' — so no menu entry is
		#     generated and the environment cannot be booted at all.
		#
		# The second one is how this was found: update-grub listed the origin
		# SNAPSHOT and never the clone, and Set-OS7BootEnvironment's guard
		# refused to activate an environment with no entry. Inferring the values
		# instead of setting them is what made a `zfs clone` look like a boot
		# environment without being one.
		# The SOURCE of each value is kept as well as the value, because the two
		# properties have to be treated differently: mountpoint inherits and
		# canmount does not.
		$props = @{}
		foreach ($p in (Get-ZfsProperty -Name @($tree.Name) -Property canmount,mountpoint)) {
			$ds = [string]$p.Dataset
			if (-not $props.ContainsKey($ds)) { $props[$ds] = @{} }
			$props[$ds][[string]$p.Name] = [pscustomobject]@{
				Value = [string]$p.Value; Source = [string]$p.Source
			}
		}

		foreach ($d in $tree) {
			$suffix = $d.Name.Substring($src.Length)     # '' for the root of the tree
			$target = "$parent/$Name$suffix"
			# NOT $from. PowerShell variable names are case-insensitive, so
			# `$from` IS the `-From` parameter — which is typed [string], so a
			# hashtable assigned to it is silently coerced to
			# "System.Collections.Hashtable" and the next line indexes a STRING
			# with the word "mountpoint". The error that comes out says
			# "Cannot convert value "mountpoint" to type "System.Int32"", names
			# no variable, and costs a VM run to find. BUILD-NOTES #65.
			$have = $props[$d.Name]

			$want = [ordered]@{}
			# mountpoint only where the SOURCE set it locally. The BE root's `/`
			# and the boot dataset's `/boot` are local; every child inherits, and
			# pinning an inherited value would freeze a hierarchy that is meant to
			# follow its parent — the same value, recorded as a different fact.
			$mp = if ($have) { $have['mountpoint'] } else { $null }
			if ($mp -and $mp.Source -eq 'LOCAL') { $want['mountpoint'] = $mp.Value }
			# canmount mirrored, except that `on` becomes `noauto` — a new
			# environment is INACTIVE until Set-OS7BootEnvironment says
			# otherwise. `off` containers stay `off` so that activation has a
			# true value to restore.
			# canmount ALWAYS, whatever its source: it is not an inheritable
			# property, so a clone that is not told takes the default `on`.
			$cm = if ($have -and $have['canmount']) { $have['canmount'].Value } else { '' }
			$want['canmount'] = if ($cm -eq 'off') { 'off' } else { 'noauto' }

			New-ZfsClone -Snapshot "$($d.Name)@$Name" -Name $target -Property $want `
				-Confirm:$false | Out-Null
		}
	}

	# Z3, and the reason this function has a check at all: `zfs clone` exiting 0
	# says nothing about the two properties above, and getting them wrong
	# produces a dataset that looks like a boot environment in `zfs list` and is
	# not one. Ask ZFS what it now holds.
	foreach ($d in (Get-ZfsDataset -Name "$($script:OS7RootParent)/$Name" -Recurse -Type Filesystem)) {
		# NAMED, not taken as "the one that came back". Get-ZfsProperty returns
		# one object per property and a caller that asks for one and reads
		# `.Value` off the result is trusting the count; when more than one
		# arrives, `.Value` is an ARRAY and every comparison against it is false
		# without saying so.
		$cm = (Get-ZfsProperty -Name $d.Name -Property canmount |
			Where-Object Name -eq 'canmount' | Select-Object -First 1).Value
		if ([string]$cm -eq 'on') {
			throw [System.InvalidOperationException]::new(
				"$($d.Name) came out canmount=on. It would be mounted over the running " +
				'system by the next `zfs mount -a`; the clone has not been made inactive.')
		}
	}
	$rootMp = (Get-ZfsProperty -Name "$($script:OS7RootParent)/$Name" -Property mountpoint |
		Where-Object Name -eq 'mountpoint' | Select-Object -First 1).Value
	if ([string]$rootMp -ne '/') {
		throw [System.InvalidOperationException]::new(
			"$($script:OS7RootParent)/$Name has mountpoint '$rootMp', not '/'. GRUB's " +
			'generator finds boot environments by that property, so this one would never ' +
			'appear in the menu.')
	}

	Write-OS7Step "boot environment $Name created, inactive"
	Get-OS7BootEnvironment -Name $Name
}

function Set-OS7BootEnvironment {
	<#
	.SYNOPSIS
		Make a boot environment the one this machine boots.

	.DESCRIPTION
		The whole of §4.2 step 9, and the only supported way to change what
		boots. In order, because each step fails differently:

		  0. make sure /etc/default/grub says GRUB_DEFAULT=saved — see below
		  1. update-grub, so the running BE's menu lists every boot environment
		  2. FIND THE TARGET'S ENTRY IN THAT MENU. If 10_linux_zfs could not find
		     a kernel in the target's bpool half it emits no entry, and pointing
		     the ESP at a BE with no entry produces a GRUB prompt on a machine
		     that was working a moment ago. This is the guard the whole ordering
		     exists for: the menu is checked BEFORE the machine is committed to
		     it.
		  3. flip canmount across both pairs — target on, everything else noauto
		  4. copy the freshly generated menu into the target's own boot dataset,
		     because the ESP stub is about to name it and GRUB will read the
		     grub.cfg it finds THERE
		  5. write saved_entry into BOTH grubenvs — the running one and the
		     target's own
		  6. rewrite both ESP stubs
		  7. record com.ubuntu.zsys:last-used, which is what 10_linux_zfs sorts
		     the menu by

		WHY STEPS 0 AND 5 EXIST AT ALL, which is the mistake this design made
		first: pointing the ESP stub at another environment changes which
		grub.cfg GRUB READS, and both copies are the same file — so the default
		entry would still be the environment that generated it. 10_linux_zfs
		sorts by last_used and hands the RUNNING system `date +%s`, so the
		running environment is first in any menu it generates and no ZFS property
		can outrank it. The default therefore has to be named, and the only place
		GRUB takes a name is `saved_entry`, which it reads only when
		GRUB_DEFAULT=saved. Both grubenvs are written because either file could
		be the one GRUB loads, depending on which stub the firmware took.

		Step 4 copies rather than regenerating: the generated grub.cfg addresses
		every kernel by an absolute path inside bpool (measured fact 2), so it is
		correct from whichever boot environment reads it. Regenerating would need
		a chroot into the target, which is a great deal of machinery for a file
		that is already right.

		THE WINDOW THIS LEAVES, said out loud because it is real: between step 3
		and the reboot, the target's datasets are canmount=on and not mounted, so
		anything that runs `zfs mount -a` in that gap would mount the target's
		/var/lib/dpkg over the running system's. The window is inherent to §4.2,
		whose step 10 is "reboot on the operator's schedule" — it is not created
		by doing the flip here rather than later. What IS guaranteed is that
		activation does not trigger it itself, which run-s5.py checks by asking
		what is mounted immediately afterwards. Closing it properly needs the
		mounts to belong to the environment rather than to the pool, which is a
		change to the layout Setup creates and not to this function.

	.PARAMETER Name
		The boot environment to boot next.

	.PARAMETER SkipGrubUpdate
		Do not run update-grub first. For the case where it has just been run —
		an update that has already built the menu inside the new environment.
		The entry check in step 2 still runs, so this cannot skip the guard.

	.EXAMPLE
		Set-OS7BootEnvironment -Name os7_1.0.1.4_202608261200
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.BootEnvironment')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[switch]$SkipGrubUpdate
	)

	Import-OS7ZfsLayer

	$all = @(Get-OS7BootEnvironment)
	$target = $all | Where-Object Name -eq $Name
	if (-not $target) {
		throw [System.InvalidOperationException]::new("no boot environment called '$Name'")
	}
	if (-not $target.Complete) {
		throw [System.InvalidOperationException]::new(
			"'$Name' has no $($script:OS7BootParent) half — it has no kernel to boot")
	}

	if (-not $PSCmdlet.ShouldProcess($Name, 'make this the boot environment this machine boots')) {
		return
	}

	# 0 — GRUB_DEFAULT=saved, or naming a default entry is writing to a file
	# nothing reads. Repaired rather than required: machines installed before
	# this existed carry GRUB_DEFAULT=0, and the first rollback on such a machine
	# is exactly the moment when it must not fail for a reason like this. It goes
	# BEFORE update-grub because the value is baked into the generated menu.
	$defaults = $script:OS7GrubDefaults
	if (Test-Path $defaults) {
		$d = Get-Content -Raw $defaults
		if ($d -notmatch '(?m)^GRUB_DEFAULT=saved\s*$') {
			$d2 = [regex]::Replace($d, '(?m)^GRUB_DEFAULT=.*$', 'GRUB_DEFAULT=saved')
			if ($d2 -eq $d) { $d2 = "GRUB_DEFAULT=saved`n" + $d }
			Set-Content -NoNewline -Path $defaults -Value $d2
			Write-OS7Step 'set GRUB_DEFAULT=saved (it was not)'
		}
	}

	if (-not (Test-Path $script:OS7GrubCfg)) {
		throw [System.InvalidOperationException]::new(
			"$($script:OS7GrubCfg) does not exist — this machine's /boot is not mounted")
	}

	# 1 — OS/7'S OWN MENU, one entry per boot environment.
	#
	# The stock generator cannot produce one: on a machine without zsys —
	# which OS/7 is — 10_linux_zfs skips its whole `history` section and emits
	# entries for exactly ONE dataset per machine-id, the one that sorts first by
	# last-used, and the running environment always sorts first. So a second boot
	# environment never appears in a menu generated from the first, and no amount
	# of saved_entry or ESP work can point GRUB at an entry that is not there.
	# BUILD-NOTES #67, and it is what S5 had to run three times to find.
	#
	# The entries are built by substitution into the running one, which is a
	# known-good entry for the same two pools — see New-OS7MenuFragment.
	$running = $all | Where-Object Active | Select-Object -First 1
	if (-not $running) {
		throw [System.InvalidOperationException]::new(
			'no boot environment is mounted at / — there is no entry to build the others from')
	}
	$withKernels = foreach ($be in $all) {
		if (-not $be.Complete) { continue }
		$k = Get-OS7BootEnvironmentKernel -BootEnvironment $be
		$be | Add-Member -NotePropertyName Kernel -NotePropertyValue $k.Kernel -Force -PassThru |
			Add-Member -NotePropertyName Initrd -NotePropertyValue $k.Initrd -Force -PassThru
	}
	$fragment = New-OS7MenuFragment -Config (Get-Content -Raw $script:OS7GrubCfg) `
		-Template $running.RootDataset -Environments @($withKernels)

	New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:OS7MenuFile) | Out-Null
	Set-Content -NoNewline -Path $script:OS7MenuFile -Value $fragment
	# 09_, so OS/7's entries come before 10_linux_zfs's. The script does nothing
	# but emit the file, so what GRUB reads can be read with `cat` beforehand.
	Set-Content -NoNewline -Path $script:OS7MenuScript -Value @"
#!/bin/sh
# OS/7 — one menu entry per boot environment. Generated by Set-OS7BootEnvironment;
# the entries themselves are in $($script:OS7MenuFile). BUILD-NOTES #67.
exec cat $($script:OS7MenuFile)
"@
	Invoke-OS7Native -Command 'chmod' -Arguments @('0755', $script:OS7MenuScript) | Out-Null
	Write-OS7Step "menu fragment written for $((@($withKernels)).Count) environment(s)"

	# 2 — regenerate, so the fragment is in the menu the machine will read.
	if (-not $SkipGrubUpdate) {
		Invoke-OS7Native -Command 'update-grub' | Out-Null
	}

	# 3 — THE GUARD. An id is read, never built: 10_linux_zfs's carries the
	# kernel version, so a constructed one goes stale the first time a boot
	# environment gets a new kernel — silently, because GRUB simply falls back
	# to the first entry and boots something that was not asked for.
	$cfg = Get-Content -Raw $script:OS7GrubCfg
	$entry = Find-OS7MenuEntryPath -Config $cfg -RootDataset $target.RootDataset
	if (-not $entry) {
		throw [System.InvalidOperationException]::new(
			"the menu has no entry for $($target.RootDataset). GRUB's generator found no " +
			"kernel in $($target.BootDataset), so pointing this machine at '$Name' would " +
			'produce a GRUB prompt rather than a boot.')
	}
	Write-OS7Step "menu entry: $entry"

	# 3 — canmount, across every environment, as one operation. Measured fact 5.
	foreach ($be in $all) {
		$want = if ($be.Name -eq $Name) { 'on' } else { 'noauto' }
		foreach ($parent in @($script:OS7RootParent, $script:OS7BootParent)) {
			# An incomplete environment has no bpool half, and asking `zfs list`
			# for a dataset that is not there is an error rather than an empty
			# answer — which would abort an activation that has nothing to do
			# with the broken environment.
			if ($parent -eq $script:OS7BootParent -and -not $be.Complete) { continue }
			$tree = @(Get-ZfsDataset -Name "$parent/$($be.Name)" -Recurse -Type Filesystem)
			foreach ($p in (Get-ZfsProperty -Name @($tree.Name) -Property canmount)) {
				# `off` is a container with nothing to mount; leave it alone.
				# The BE's own root dataset stays noauto in every environment —
				# the initramfs mounts it by name from root=ZFS=, and a root
				# dataset with canmount=on would be mounted a second time, at /,
				# by `zfs mount -a`.
				if ([string]$p.Value -eq 'off') { continue }
				$isRoot = ([string]$p.Dataset -eq "$parent/$($be.Name)") -and
						  ($parent -eq $script:OS7RootParent)
				$set = if ($isRoot) { 'noauto' } else { $want }
				if ([string]$p.Value -eq $set) { continue }
				Set-ZfsProperty -Name ([string]$p.Dataset) -PropertyName canmount -Value $set `
					-Confirm:$false | Out-Null
			}
		}
	}

	# 4 — the target's own copy of the menu.
	New-Item -ItemType Directory -Force -Path $script:OS7BeScratch | Out-Null
	try {
		Invoke-OS7Native -Command 'mount' -Arguments @(
			'-t', 'zfs', '-o', 'zfsutil', $target.BootDataset, $script:OS7BeScratch) | Out-Null
		$dest = Join-Path $script:OS7BeScratch 'grub/grub.cfg'
		if (-not (Test-Path (Split-Path -Parent $dest))) {
			throw [System.InvalidOperationException]::new(
				"$($target.BootDataset) has no grub directory — it is not a boot dataset")
		}
		Copy-Item -Force $script:OS7GrubCfg $dest
		Write-OS7Step "menu copied into $($target.BootDataset)"

		# 5 — the default, named. In the target's own grubenv, because the stub
		# about to be rewritten makes THAT the one GRUB loads.
		Invoke-OS7Native -Command 'grub-editenv' -Arguments @(
			(Join-Path $script:OS7BeScratch 'grub/grubenv'), 'set', "saved_entry=$entry") | Out-Null
	}
	finally {
		# Tolerant on purpose: if the mount above failed, this one fails too, and
		# an exception thrown out of a finally block replaces the real cause with
		# "umount: not mounted".
		try { Invoke-OS7Native -Command 'umount' -Arguments @($script:OS7BeScratch) | Out-Null }
		catch { Write-OS7Step "note: $($script:OS7BeScratch) was not mounted" }
	}

	# …and in the running system's, so that a machine whose firmware takes the
	# other EFI path — or which never gets as far as step 6 — still boots what
	# was asked for rather than what it happens to list first.
	Invoke-OS7Native -Command 'grub-editenv' -Arguments @(
		(Join-Path $script:OS7BootDir 'grub/grubenv'), 'set', "saved_entry=$entry") | Out-Null

	# 6 — the ESP stub. THE LINE THAT DECIDES WHICH MENU IS READ AT ALL.
	$rewrote = 0
	foreach ($stub in $script:OS7EspStubs) {
		if (-not (Test-Path $stub)) { continue }
		$text = Get-Content -Raw $stub
		$new = [regex]::Replace($text, "/BOOT/[^@']+@/grub", "/BOOT/$Name@/grub")
		if ($new -ne $text) {
			Set-Content -NoNewline -Path $stub -Value $new
			$rewrote++
		}
		elseif ($text -match "/BOOT/$([regex]::Escape($Name))@/grub") {
			$rewrote++
		}
	}
	if ($rewrote -eq 0) {
		throw [System.InvalidOperationException]::new(
			'no ESP stub was rewritten — /boot/efi is not mounted, or grub-install ' +
			'never wrote one. Nothing about what this machine boots has changed.')
	}
	Write-OS7Step "$rewrote ESP stub(s) now point at $Name"

	# 7 — when this environment was last made current. 10_linux_zfs sorts the
	# menu by com.ubuntu.zsys:last-used and, where it is unset, by the mtime of
	# /etc/machine-id inside the environment — which is the install date and
	# therefore the same for a clone and its origin.
	#
	# IT DOES NOT REORDER THE MENU THAT WAS JUST GENERATED, and saying otherwise
	# would be the kind of claim this repository exists to avoid: the generator
	# hands the RUNNING environment the current time, so whatever is running is
	# first in any menu it produces. This value is read the next time a menu is
	# generated — from the other environment, where it is the only thing that
	# distinguishes two datasets installed on the same day. The default entry
	# does not depend on it; that is what saved_entry is for.
	# ToUnixTimeSeconds rather than `Get-Date -UFormat %s`: the latter returns a
	# string this code would have to parse back, and parsing a number out of a
	# formatted date is culture-dependent — on a machine whose locale uses a
	# comma it would throw, during a rollback, for a reason with nothing to do
	# with rollback. OS/7 installs de_DE by default in this very harness.
	Set-ZfsProperty -Name $target.RootDataset `
		-PropertyName 'com.ubuntu.zsys:last-used' `
		-Value ([string][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) `
		-Confirm:$false | Out-Null

	Get-OS7BootEnvironment -Name $Name
}

function Remove-OS7BootEnvironment {
	<#
	.SYNOPSIS
		Destroy a boot environment, both halves.

	.DESCRIPTION
		docs/RELEASE-AND-UPDATE-PLAN.md §6: without this the pool fills, which is
		how boot-environment systems fail in practice.

		REFUSES THE RUNNING ONE AND THE ONE THAT BOOTS. They are two different
		environments after an activation and before the reboot, and destroying
		either produces a machine that does not start — the second one silently,
		because everything keeps working until the next boot.

	.PARAMETER Name
		The boot environment to destroy.

	.EXAMPLE
		Get-OS7BootEnvironment | Where-Object { -not $_.Active -and -not $_.Menu } |
			Select-Object -First 1 | Remove-OS7BootEnvironment
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
		[string]$Name
	)

	process {
		Import-OS7ZfsLayer

		$be = Get-OS7BootEnvironment -Name $Name
		if (-not $be) {
			throw [System.InvalidOperationException]::new("no boot environment called '$Name'")
		}
		if ($be.Active) {
			throw [System.InvalidOperationException]::new(
				"'$Name' is mounted at / — this is the system that is running")
		}
		if ($be.Menu) {
			throw [System.InvalidOperationException]::new(
				"'$Name' is what this machine boots next. Activate another one first, " +
				'or the next start has no menu to read.')
		}

		if (-not $PSCmdlet.ShouldProcess($Name, 'destroy both halves of this boot environment')) {
			return
		}

		foreach ($ds in @($be.BootDataset, $be.RootDataset)) {
			if (-not $ds) { continue }
			Remove-ZfsDataset -Name $ds -Recurse -Confirm:$false | Out-Null
		}
		Write-OS7Step "boot environment $Name destroyed"
	}
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

		NO LONGER BLOCKED ON ZFS, AND NO LONGER BLOCKED ON BOOT ENVIRONMENTS.
		Open Question #1 (ZFS on the Linux 7.0 kernel) was resolved 2026-08-22,
		spike S3 installed a bootable ZFS-on-LUKS root 2026-08-23, and since
		2026-08-25 §4.2's steps 1, 2 and 9 are real code that has been through a
		VM: New-OS7BootEnvironment clones the pair, Set-OS7BootEnvironment
		activates it, Restore-OS7 goes back. Spike S5 walked the whole cycle —
		docs/SESSION-BOOT-ENVIRONMENTS.md.

		WHAT IS STILL MISSING IS THE RELEASE ITSELF, and it is not a small
		remainder. §4.2 steps 3 to 8 — assemble the clone, point it at the new
		archive, apply, re-assert os-release, rebuild the initramfs, regenerate
		the menu — have been performed by hand in the S5 harness and belong
		here; and there is nothing yet to point them AT. There is no OS/7
		package repository, nothing on a running system belongs to an OS/7
		package, and no release index is published or signed
		(docs/CURATION-AND-DELIVERY-PLAN.md §5, §6, C7 and the open C7a). Until
		that exists, this cmdlet could only apply plain Ubuntu updates and call
		them an OS/7 release, which is the one thing §5 says makes the version
		number worse than none.

	.PARAMETER WhatIf
		STUB. Should report the pending release without applying it.

	.EXAMPLE
		Update-OS7 -WhatIf
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param()

	throw [System.NotImplementedException]::new(
		'Update-OS7 is a stub. Boot environments are real now (New-OS7BootEnvironment, ' +
		'Set-OS7BootEnvironment, Restore-OS7); what it would apply is not. There is no ' +
		'OS/7 package repository and no signed release index — CURATION-AND-DELIVERY-PLAN.md ' +
		'C7 and C7a.')
}

function Restore-OS7 {
	<#
	.SYNOPSIS
		Roll the system back to a previous OS/7 boot environment.

	.DESCRIPTION
		IMPLEMENTED 2026-08-25. docs/RELEASE-AND-UPDATE-PLAN.md §6: "Defaults to
		the previous BE so the panic path is one word." That is the whole design
		requirement, and it is why -BootEnvironment is optional: the operator
		typing this has a machine that has just stopped working properly, and
		asking them to name a dataset first is asking the wrong question.

		WHAT "PREVIOUS" MEANS, and it is not "the one before it in the list":
		the newest boot environment that is OLDER than the running one. On a
		machine that has been updated three times and rolled back once, the list
		is not in the order the machine used them — creation time is, and it is
		what New-OS7BootEnvironmentName's stamp exists to make sortable.

		IT DOES NOT REBOOT. Every cmdlet here has to work over serial and SSH
		(§6), and an unannounced reboot down a serial line is how an admin loses
		the session that would have told them whether it worked.

	.PARAMETER BootEnvironment
		The one to go back to. Without it, the previous one.

	.EXAMPLE
		Restore-OS7
		Roll back to the previous boot environment, then reboot by hand.

	.EXAMPLE
		Restore-OS7 -BootEnvironment os7_1.0.0.31_202608231430
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.BootEnvironment')]
	param(
		[Parameter()]
		[string]$BootEnvironment
	)

	$all = @(Get-OS7BootEnvironment)
	if ($all.Count -lt 2 -and -not $BootEnvironment) {
		throw [System.InvalidOperationException]::new(
			'there is only one boot environment on this machine — there is nothing to roll back to')
	}

	if (-not $BootEnvironment) {
		$active = $all | Where-Object Active | Select-Object -First 1
		$older = if ($active) {
			$all | Where-Object { $_.Created -lt $active.Created -and $_.Complete }
		}
		else { $all | Where-Object Complete }

		$pick = $older | Select-Object -Last 1
		if (-not $pick) {
			throw [System.InvalidOperationException]::new(
				'no complete boot environment older than the running one. Name one with ' +
				'-BootEnvironment, or list them with Get-OS7BootEnvironment.')
		}
		$BootEnvironment = $pick.Name
		Write-OS7Step "rolling back to the previous boot environment: $BootEnvironment"
	}

	# ShouldProcess is asked HERE and answered downwards with -Confirm:$false, so
	# that one confirmation covers the operation the operator actually asked for
	# rather than the four it decomposes into.
	if (-not $PSCmdlet.ShouldProcess($BootEnvironment, 'roll this machine back to this boot environment')) {
		return
	}

	$be = Set-OS7BootEnvironment -Name $BootEnvironment -Confirm:$false
	$running = $all | Where-Object Active | Select-Object -First 1
	Write-OS7Step ("reboot to finish: this machine still runs " +
		$(if ($running) { $running.Name } else { 'an environment it cannot name' }))
	$be
}

# ---------------------------------------------------------------------------
# Backup (docs/BACKUP-PLAN.md)
#
# THREE FILES, DOT-SOURCED, and dot-sourced HERE at the end rather than at the
# top. Dot-sourcing executes the file, and these files call Write-OS7Step and
# Invoke-OS7Native at definition time in their parameter defaults and comments'
# sake — more importantly, a reader who finds a function in one of them should
# find the helpers it uses already defined above. PowerShell defines functions
# as the script runs, so "already defined" is a fact about line order.
#
# NOT A SEPARATE MODULE. Backup policy is OS/7 knowledge — which datasets the
# update train owns, which a rollback must not touch, where /home really is —
# and ZFS-POWERSHELL-PLAN Z8 puts OS/7 knowledge in Layer 3. The generic layer
# this feature sits on is not a PowerShell module at all: it is sanoid and
# syncoid, which are somebody else's programs and stay that way.
#
# Resolved relative to this file, so a module imported by path from a repository
# and a module staged into /usr/local/share/powershell/Modules both work.
foreach ($part in @('OS7.Backup.ps1', 'OS7.BackupTarget.ps1', 'OS7.BackupRestore.ps1',
		'OS7.BackupSelfTest.ps1')) {
	$file = Join-Path $PSScriptRoot $part
	if (-not (Test-Path -LiteralPath $file)) {
		throw [System.IO.FileNotFoundException]::new(
			"$part is missing from $PSScriptRoot. The OS7 module is staged by copying the " +
			'whole directory (build.sh stage_ps_module); a partial copy is what this looks ' +
			'like.')
	}
	. $file
}

Export-ModuleMember -Function New-OS7Storage, New-OS7BootEnvironmentName,
	Get-OS7BootEnvironment, New-OS7BootEnvironment, Set-OS7BootEnvironment,
	Remove-OS7BootEnvironment,
	Get-OS7Theme, Set-OS7Theme,
	Set-OS7Mode, Update-OS7, Restore-OS7,
	# Backup — policy and schedule
	Get-OS7BackupPolicy, Set-OS7BackupPolicy, Enable-OS7Backup, Disable-OS7Backup,
	Start-OS7Backup, Get-OS7BackupStatus, Get-OS7BackupCoverage,
	# Backup — targets and replication
	Get-OS7BackupTarget, New-OS7BackupTarget, Remove-OS7BackupTarget,
	Test-OS7BackupTarget, Start-OS7BackupReplication,
	Mount-OS7BackupTarget, Dismount-OS7BackupTarget,
	# Backup — restore
	Get-OS7FileVersion, Restore-OS7File,
	# Backup — the self-test
	Test-OS7Backup
