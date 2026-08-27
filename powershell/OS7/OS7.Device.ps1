# =============================================================================
# OS/7 — the device manager
#
# Layer 3 of docs/POWERSHELL-SURFACE-PLAN.md P2. THIS FILE CONTAINS NO CALL TO
# `lspci`, `lsusb`, `dkms`, `modprobe`, `ubuntu-drivers` OR `hw-probe` — all of
# them go through powershell/Hardware, and installer/testing/check-layering.py
# holds that line as `P2-hardware`.
#
# WHAT THIS IS FOR. A Windows administrator opens Device Manager and reads one
# thing: the devices with a yellow mark. Everything else is collapsed. Linux
# has no such view — it has `lspci -k`, which prints every device on the
# machine in the same weight, most of them working, and leaves the reader to
# know which of forty-odd lines matters.
#
# So the product decision here is NOT a prettier lspci. It is that the default
# view shows ONLY what needs attention, and says what to do about each one.
#
# THE FOUR STATES, and why there is a fifth.
#
#   Working           a driver is bound and nothing better is on offer. The
#                     vast majority. NOT shown by default.
#   DriverAvailable   a driver exists that this machine does not have, or has
#                     and has not loaded. The NVIDIA case is the famous one —
#                     nouveau works, nvidia-driver-570 does more — but the
#                     state also covers a device with nothing bound at all and
#                     a package that would serve it. `Action` says which.
#   NeedsRebuild      a DKMS driver is not built for the kernel that matters.
#                     THE DISTINCTLY LINUX FAILURE, and the reason this feature
#                     is worth building: a driver that worked yesterday is gone
#                     after a kernel update, nothing said so, and a Windows
#                     admin has no model for it because Windows drivers are not
#                     compiled per-kernel.
#   NotSupported      nothing is bound, nothing is on offer, and no module in
#                     the kernel claims the device. Honest, and not fixable
#                     from here — which is what Send-OS7HardwareProbe is for.
#   Unknown           it could not be determined. NEVER folded into Working.
#                     A machine whose /lib/modules is missing cannot answer the
#                     question at all (Hardware's Resolve-KernelModule
#                     measurement), and reporting that machine as healthy is
#                     the failure this repository has paid for most often.
#
# WHAT IS OS/7's KNOWLEDGE HERE, and why this is not a pass-through:
#
#   * WHICH STATE a device is in. powershell/Hardware reports facts — a bound
#     module, a DKMS row, a package list. Turning "there is a package called
#     nvidia-driver-570 that is not installed" into "a better driver is
#     available" is a judgement, and it belongs to the product.
#   * THAT A BRIDGE WITH NO DRIVER IS NOT BROKEN. See Test-OS7DeviceNeedsDriver.
#     Every machine has host bridges; none of them has a driver; a device
#     manager that called them unsupported would be wrong about every computer
#     ever built. Same shape as Get-OS7Service's oneshot problem, and the same
#     cost if it is got wrong — a field that cries wolf gets ignored, and then
#     it is wrong about the broken machine too and nobody notices.
#   * THE FRIENDLY CLASS. "Display controller" is what pci.ids says; "Display"
#     is what the person reading it calls it. The mapping is product policy and
#     is written down once, here.
#   * THE SENTENCE AND THE COMMAND. Every device that needs attention carries
#     an `Action` a person can read and a `Command` they can run. A device
#     manager that identifies a problem and offers no next step has done the
#     easy half.
#
# Dot-sourced by OS7.psm1.
# =============================================================================

# The friendly class an operator reads, from the PCI base class or the USB
# class. WRITTEN DOWN ONCE — Get-OS7DeviceStatus groups by it, the format file
# sorts by it, and three hand-typed copies drift (the argument Get-OS7Service
# makes for $script:OS7ServicePatterns).
#
# These are NOT pci.ids' names. pci.ids says "Display controller",
# "Serial bus controller", "Generic system peripheral"; a person says
# "Display", "Bus", "System". The raw name is kept on the object as ClassName
# for anyone who wants it.
$script:OS7PciClasses = @{
	'00' = 'Other'; '01' = 'Storage'; '02' = 'Network'; '03' = 'Display'
	'04' = 'Multimedia'; '05' = 'Memory'; '06' = 'System'; '07' = 'Communication'
	'08' = 'System'; '09' = 'Input'; '0a' = 'Docking'; '0b' = 'Processor'
	'0c' = 'Bus'; '0d' = 'Wireless'; '0e' = 'Controller'; '0f' = 'Satellite'
	'10' = 'Security'; '11' = 'Signal'; '12' = 'Accelerator'; '13' = 'Instrumentation'
	'40' = 'Coprocessor'; 'ff' = 'Other'
}
$script:OS7UsbClasses = @{
	'01' = 'Audio'; '02' = 'Network'; '03' = 'Input'; '05' = 'Input'
	'06' = 'Imaging'; '07' = 'Printer'; '08' = 'Storage'; '09' = 'System'
	'0a' = 'Network'; '0b' = 'Smart card'; '0d' = 'Security'; '0e' = 'Camera'
	'0f' = 'Health'; '10' = 'Multimedia'; '11' = 'Display'; '12' = 'Bus'
	'dc' = 'Other'; 'e0' = 'Wireless'; 'ef' = 'Other'; 'fe' = 'Other'; 'ff' = 'Other'
}

# The states, in the order a person should read them: worst first. The format
# file and Get-OS7DeviceStatus both take their order from here rather than
# sorting alphabetically, which would put DriverAvailable above NeedsRebuild
# and bury the one that means something is broken right now.
$script:OS7DeviceStateOrder = @('NeedsRebuild', 'NotSupported', 'DriverAvailable', 'Unknown', 'Working')

# The heading each state gets when a person reads it.
$script:OS7DeviceStateLabel = @{
	'NeedsRebuild'    = 'Needs a driver rebuild'
	'NotSupported'    = 'No driver available'
	'DriverAvailable' = 'A better driver is available'
	'Unknown'         = 'Could not be determined'
	'Working'         = 'Working'
}

function Import-OS7HardwareLayer {
	<#
	.SYNOPSIS
		Internal. Make the Hardware module available, lazily.

	.DESCRIPTION
		LAZILY, AND NEVER AT IMPORT TIME — BUILD-NOTES #38, and #82 is that rule
		being broken in this module and costing a day of builds.
	#>
	if (Get-Module -Name Hardware) { return }

	$candidates = @(
		(Join-Path (Split-Path -Parent $PSScriptRoot) 'Hardware/Hardware.psd1'),
		'/usr/local/share/powershell/Modules/Hardware/Hardware.psd1'
	)
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			Import-Module $c -Force -ErrorAction Stop
			Write-OS7Step "hardware layer: $c"
			return
		}
	}
	Import-Module Hardware -Force -ErrorAction Stop
	Write-OS7Step 'hardware layer: Hardware (by name)'
}

function Get-OS7RunningKernel {
	<#
	.SYNOPSIS
		Internal. The kernel release this machine is running.

	.DESCRIPTION
		FROM /proc/sys/kernel/osrelease, WHICH IS THE KERNEL ITSELF. `uname -r`
		is a program that reads it; starting a process to learn a string the
		kernel has already published is a dependency for nothing.

		-Root asks the kernel a chroot would REPORT, which is the same kernel —
		/proc is shared. So an update that wants to know which kernel its NEW
		environment will boot must ask its /boot, not this. Named here because
		the mistake is easy and the symptom is a gate that passes.
	#>
	param([string]$Root = '')

	$p = if ($Root -and $Root -ne '/') { (Join-Path $Root 'proc/sys/kernel/osrelease') }
		else { '/proc/sys/kernel/osrelease' }
	if (-not [System.IO.File]::Exists($p)) { return $null }
	return ([System.IO.File]::ReadAllText($p)).Trim()
}

function Test-OS7DeviceNeedsDriver {
	<#
	.SYNOPSIS
		Internal. Would this device be broken without a driver?

	.DESCRIPTION
		THIS LIST IS DELIBERATELY SHORT, AND THAT IS THE DECISION.

		Every machine ever built has PCI bridges. None of them has a driver
		bound — the kernel enumerates THROUGH a host bridge, it does not drive
		it — and sysfs reports them exactly like an unsupported wifi card:
		a device, a modalias, and no `driver` symlink. A device manager that
		read "no driver" as "broken" would open with three or four faults on a
		perfectly well computer, which is Get-OS7Service's oneshot problem
		(installer/testing/check-service-logic.py) in another subsystem. A field
		that cries wolf gets ignored, and then it is wrong about the broken
		machine too and nobody notices.

		So class 06, Bridge, is excused. NOTHING ELSE IS, and the temptation to
		add memory controllers, system peripherals and processors — which also
		commonly sit driverless on real hardware — was resisted, because
		excusing a class is how a device manager hides the one device that
		mattered. The right way to shorten that list is to look at real
		machines, and no session has had one yet: docs/SESSION-DEVICE-MANAGER.md
		records this as open.

		An excused device is still LISTED, under -All, with an Action that says
		why. It is classified, not hidden.
	#>
	param([Parameter(Mandatory)]$Device)

	if ($Device.Bus -eq 'PCI' -and $Device.Class -eq '06') { return $false }
	return $true
}

function Get-OS7DeviceClass {
	<#
	.SYNOPSIS
		Internal. The friendly class name for a device.
	#>
	param([Parameter(Mandatory)]$Device)

	# Bluetooth is USB class e0 SUBCLASS 01, and is worth splitting out of
	# "Wireless": an operator looking for their Bluetooth adapter does not
	# expect to find it filed under the same word as the wifi card.
	if ($Device.Bus -eq 'USB' -and $Device.Class -eq 'e0' -and $Device.SubClass -eq '01') {
		return 'Bluetooth'
	}
	$table = if ($Device.Bus -eq 'USB') { $script:OS7UsbClasses } else { $script:OS7PciClasses }
	if ($Device.Class -and $table.ContainsKey($Device.Class)) { return $table[$Device.Class] }
	return 'Other'
}


# ---------------------------------------------------------------------------
# The state rule
#
# ONE FUNCTION, AND EVERY BRANCH IS NAMED. installer/testing/check-device-logic.py
# drives this function directly over a table of machines, for the reason
# check-service-logic.py exists: a health verdict with five branches is wrong in
# a way only enumerated cases find, and the cases that must read as WORKING
# matter as much as the ones that must not.
# ---------------------------------------------------------------------------

function Resolve-OS7DeviceState {
	<#
	.SYNOPSIS
		Internal. What state is this device in, and what should be done about it?

	.DESCRIPTION
		THE ORDER OF THE BRANCHES IS THE RULE, and it is not arbitrary:

		  1. A device that needs no driver is Working. Before anything else,
		     because a host bridge with no driver would otherwise fall through
		     to NotSupported and be reported as a fault on every machine.

		  2. Its bound driver is a DKMS module that is NOT installed for the
		     kernel in question -> NeedsRebuild. Before the better-driver check,
		     because a driver that will not load after the next reboot is a
		     bigger fact than a driver that could be improved.

		     NOTE WHAT "bound" MEANS HERE. On the RUNNING kernel a stale DKMS
		     module is usually still bound — it is loaded, from the kernel it
		     was built for, and it keeps working until the reboot. That is
		     precisely why this is invisible without something like this
		     cmdlet: nothing is broken YET.

		  3. ubuntu-drivers offers a package for it that is neither `builtin`
		     nor already installed -> DriverAvailable.

		  4. A driver is bound -> Working.

		  5. Nothing bound. Now the three-way split that
		     Hardware's Resolve-KernelModule was built to make possible:
		       $null      the question could not be asked  -> Unknown
		       a module   the kernel has one, unloaded     -> DriverAvailable
		       empty      asked, nothing claims it         -> NotSupported

		THE $null BRANCH IS THE ONE THAT WOULD BE DROPPED FIRST and must not be.
		A machine with no /lib/modules/<running kernel> — a chroot, a broken
		update, a rescue boot — answers "nothing claims this alias" for every
		device on it, and folding that into NotSupported would report a
		completely working computer as having no drivers for anything.

	.PARAMETER Device
		A Hardware.Device.

	.PARAMETER Kernel
		The kernel the answer is about. The running one, normally; the one a
		new boot environment will boot, when an update asks.

	.PARAMETER DkmsModules
		Get-DkmsModule's output. An empty list means dkms is not installed,
		which is the normal state of a machine with no out-of-tree drivers.

	.PARAMETER Offers
		Get-UbuntuDriver's output, or $null when ubuntu-drivers could not be
		asked. $null and empty are different answers and this function treats
		them differently.

	.PARAMETER InstalledPackages
		The set of package names already installed, so that a package
		ubuntu-drivers lists and the machine already has is not offered again.

	.PARAMETER ClaimedBy
		The modules that claim this device's modalias: $null for "could not be
		asked", an array for the answer. Only looked up for unbound devices.
	#>
	param(
		[Parameter(Mandatory)]$Device,
		[string]$Kernel,
		$DkmsModules = @(),
		$Offers = $null,
		$InstalledPackages = @(),
		$ClaimedBy = $null
	)

	$result = [ordered]@{
		State        = 'Unknown'
		Action       = $null
		Command      = $null
		Alternatives = @()
		Rebuild      = $null
	}

	# ---- 1. Does it need a driver at all? -------------------------------
	if (-not (Test-OS7DeviceNeedsDriver -Device $Device) -and -not $Device.Driver) {
		$result.State = 'Working'
		$result.Action = "This is a $($Device.ClassName ?? 'bridge') and the kernel needs no driver for it."
		return [pscustomobject]$result
	}

	# ---- 2. Is its driver a DKMS module that is not built for $Kernel? --
	#
	# MATCHED ON THE MODULE NAME. A DKMS package's module name and the module
	# the kernel binds are the same string — `r8168` is registered with dkms as
	# `r8168` and appears in sysfs as `r8168` — and where they are not, this
	# check simply does not fire, which is a miss rather than a false alarm.
	if ($Device.Driver) {
		$dk = @($DkmsModules | Where-Object { $_.Name -eq $Device.Driver })
		if ($dk.Count -gt 0) {
			# THE QUESTION IS WHETHER AN `installed` ROW FOR $Kernel EXISTS.
			# Never whether dkms said something bad — it has no word for bad.
			# `built` is not enough either: a module that compiled and was not
			# installed is not in /lib/modules and will not load.
			$ok = @($dk | Where-Object { $Kernel -in @($_.InstalledFor) })
			if ($ok.Count -eq 0) {
				$m = $dk[0]
				$result.State = 'NeedsRebuild'
				# THE OUTER @() IS LOAD-BEARING. `@(…) | Sort-Object -Unique` on a
				# one-element list returns a STRING, and `.Count` on a string
				# under Set-StrictMode -Version Latest throws "The property
				# 'Count' cannot be found on this object" — from inside the
				# state rule, replacing the state with an exception. This is
				# BUILD-NOTES #92 in its second form, and it was hit here.
				$builtFor = @(@($m.Kernels | ForEach-Object { $_.Kernel }) | Sort-Object -Unique)
				$where = if ($builtFor.Count) { "It is built for $($builtFor -join ', ')." }
					else { 'It is not built for any kernel.' }
				$result.Action = "$($m.Name) $($m.Version) is not installed for $Kernel. " +
					"$where This driver will not load until it is rebuilt."
				$result.Command = "Repair-OS7Driver -Name $($m.Name)"
				$result.Rebuild = [pscustomobject]@{
					Module       = $m.Name
					Version      = $m.Version
					Kernel       = $Kernel
					InstalledFor = @($m.InstalledFor)
					BuiltFor     = @($m.BuiltFor)
				}
				return [pscustomobject]$result
			}
		}
	}

	# ---- 3. Does ubuntu-drivers offer something better? ------------------
	#
	# $null MEANS THE TOOL IS NOT INSTALLED and is skipped rather than read as
	# "nothing on offer". A machine without ubuntu-drivers-common cannot answer
	# the NVIDIA question, and answering it anyway is how somebody with an RTX
	# card gets told nouveau is the best there is.
	if ($null -ne $Offers) {
		$mine = @($Offers | Where-Object { $_.Modalias -and $Device.Modalias -and
				$_.Modalias -eq $Device.Modalias })
		# THE FALLBACK ONLY RUNS WHEN THE DEVICE HAS NO MODALIAS, and the first
		# version of it did not check that — which check-device-logic.py caught
		# on the case "an offer for a DIFFERENT device's modalias is not this
		# device's". A device WITH a modalias that matches nothing has been
		# answered: nothing is on offer for it. Falling through to a path match
		# then is not a fallback, it is a second, weaker join overruling a
		# stronger one that already said no.
		#
		# ubuntu-drivers reports the FULL /sys/devices path and sysfs
		# enumeration reports the /sys/bus symlink name, so the path is compared
		# by its last element — which is the PCI slot and is unique.
		if ($mine.Count -eq 0 -and -not $Device.Modalias -and $Device.SysfsPath) {
			$mine = @($Offers | Where-Object { $_.SysfsPath -and
					$_.SysfsPath.TrimEnd('/').EndsWith('/' + $Device.Address) })
		}
		if ($mine.Count -gt 0) {
			# `builtin` IS ALREADY IN THE KERNEL and offering it is offering
			# nothing. An already-installed package is the same. Both filtered.
			$candidates = @($mine[0].Drivers |
				Where-Object { -not $_.Builtin -and $_.Package -notin $InstalledPackages })
			if ($candidates.Count -gt 0) {
				$pick = @($candidates | Where-Object { $_.Recommended })
				$pick = if ($pick.Count) { $pick[0] } else { $candidates[0] }
				$result.State = 'DriverAvailable'
				$result.Alternatives = $candidates
				$result.Command = "Install-OS7Driver -Package $($pick.Package)"
				$rec = if ($pick.Recommended) { ' and is the recommended driver for it' } else { '' }
				$result.Action = if ($Device.Driver) {
					"Running on $($Device.Driver). $($pick.Package) is available$rec."
				}
				else {
					"No driver is bound. $($pick.Package) is available for this device$rec."
				}
				return [pscustomobject]$result
			}
		}
	}

	# ---- 4. A driver is bound and there is nothing better ----------------
	if ($Device.Driver) {
		$result.State = 'Working'
		$result.Action = "Running on $($Device.Driver)."
		return [pscustomobject]$result
	}

	# ---- 5. Nothing bound: three answers, and they are not the same ------
	if ($null -eq $ClaimedBy) {
		$result.State = 'Unknown'
		$result.Action = 'No driver is bound, and whether the kernel has one could not be ' +
			'determined — there is no module index for this kernel to ask.'
		return [pscustomobject]$result
	}
	if (@($ClaimedBy).Count -gt 0) {
		$mod = @($ClaimedBy)[0]
		$result.State = 'DriverAvailable'
		$result.Action = "No driver is bound, but the kernel has $mod for this device and it " +
			'is not loaded.'
		$result.Command = "Repair-OS7Driver -Address $($Device.Address)"
		return [pscustomobject]$result
	}

	$result.State = 'NotSupported'
	$result.Action = 'No driver is bound, and neither the kernel nor Ubuntu''s driver list ' +
		'has one for it.'
	$result.Command = 'Send-OS7HardwareProbe'
	return [pscustomobject]$result
}


# ---------------------------------------------------------------------------
# The cmdlets
# ---------------------------------------------------------------------------

function Get-OS7InstalledPackageName {
	<#
	.SYNOPSIS
		Internal. The set of installed package names, for filtering offers.

	.DESCRIPTION
		A HashSet rather than a list: ubuntu-drivers can offer a dozen packages
		per device on a machine with 3 000 packages installed, and `-in` over a
		list is a linear scan per offer.
	#>
	param([string]$Root = '')

	$set = [System.Collections.Generic.HashSet[string]]::new()
	$dir = if ($Root -and $Root -ne '/') { (Join-Path $Root 'var/lib/dpkg/status') }
		else { '/var/lib/dpkg/status' }
	# READ FROM dpkg's OWN STATUS FILE, not from `dpkg-query`. It is one open of
	# one file against one process per call, and this runs on a listing.
	if (-not [System.IO.File]::Exists($dir)) { return $set }
	$name = $null
	foreach ($line in [System.IO.File]::ReadLines($dir)) {
		if ($line.StartsWith('Package: ')) { $name = $line.Substring(9).Trim(); continue }
		if ($line.StartsWith('Status: ') -and $name) {
			if ($line.Contains('install ok installed')) { [void]$set.Add($name) }
			$name = $null
		}
	}
	return $set
}

function Get-OS7Device {
	<#
	.SYNOPSIS
		The devices on this machine that need attention — and, with -All, the
		ones that do not.

	.DESCRIPTION
		THE DEFAULT IS NOT EVERYTHING, AND THAT IS THE FEATURE. `lspci -k`
		prints every device on the machine in the same weight; a person reading
		it has to already know which line matters. This prints the ones that
		matter, with what to do about each, and says at the end how many it did
		not print.

		Windows Device Manager makes the same choice by expanding the branches
		with a yellow mark and collapsing the rest. `-All` is the collapsed
		half.

		Five states, and `Working` is not the absence of the others — see
		Resolve-OS7DeviceState, where the branches and their order are the rule.

		`Action` is a sentence a person can act on. `Command` is the cmdlet that
		does it, or $null when there is nothing to run — a NotSupported device
		gets Send-OS7HardwareProbe, which is not a fix and does not pretend to
		be one.

	.PARAMETER Name
		A glob against the device's name.

	.PARAMETER Class
		The friendly class: Display, Network, Wireless, Bluetooth, Storage,
		Audio, Camera, Input, Printer, Processor, Memory, Bus, Security,
		System, Other.

	.PARAMETER State
		One of Working, DriverAvailable, NeedsRebuild, NotSupported, Unknown.
		Implies -All, because asking for a state is asking for every device in
		it.

	.PARAMETER Address
		One device, by its PCI slot or USB address.

	.PARAMETER Bus
		PCI or USB.

	.PARAMETER All
		Include the devices that are working.

	.PARAMETER Kernel
		Judge the DKMS state against a kernel other than the running one. This
		is how Update-OS7 asks whether the environment it has just built will
		have its drivers.

	.PARAMETER Root
		Ask about another filesystem — a mounted image, or an assembled boot
		environment.

	.EXAMPLE
		Get-OS7Device

		The devices that need attention. On a healthy machine, nothing.

	.EXAMPLE
		Get-OS7Device -All | Group-Object Class

	.EXAMPLE
		Get-OS7Device -State NeedsRebuild | Repair-OS7Driver
	#>
	[CmdletBinding()]
	[OutputType('OS7.Device')]
	param(
		[string]$Name,
		[string]$Class,
		[ValidateSet('Working', 'DriverAvailable', 'NeedsRebuild', 'NotSupported', 'Unknown')]
		[string]$State,
		[string]$Address,
		[ValidateSet('PCI', 'USB')][string]$Bus,
		[switch]$All,
		[string]$Kernel,
		[string]$Root = ''
	)

	Import-OS7HardwareLayer

	if (-not $Kernel) { $Kernel = Get-OS7RunningKernel -Root $Root }

	# SPLATTED, NOT `-Bus $Bus`. Get-HardwareDevice's -Bus carries a
	# [ValidateSet], and an unset [string] parameter is '' rather than absent —
	# so passing it through unconditionally fails validation on EVERY call that
	# does not name a bus, which is every ordinary call. check-device-logic.py
	# found this the first time it ran the cmdlet end to end; nothing in the
	# state-rule half could have, because that half never calls it.
	$hw = @{}
	if ($Bus) { $hw['Bus'] = $Bus }
	if ($Root) { $hw['Root'] = $Root }
	$devices = @(Get-HardwareDevice @hw)
	if ($Address) { $devices = @($devices | Where-Object { $_.Address -eq $Address }) }

	$dkms = @(Get-DkmsModule -Root $Root)
	# $null WHEN THE TOOL IS ABSENT, AND IT STAYS $null all the way into the
	# state rule. Turning it into @() here would be the whole bug.
	$offers = Get-UbuntuDriver -Root $Root
	$installed = Get-OS7InstalledPackageName -Root $Root

	$out = @()
	foreach ($d in $devices) {
		# ONE modprobe PER UNBOUND DEVICE, and none for the rest. On a normal
		# machine that is a handful of calls; asking for every device would be
		# forty processes for an answer that is already known.
		$claimed = $null
		if (-not $d.Driver -and $d.Modalias -and (Test-OS7DeviceNeedsDriver -Device $d)) {
			$claimed = Resolve-KernelModule -Modalias $d.Modalias -Kernel $Kernel -Root $Root
		}

		$r = Resolve-OS7DeviceState -Device $d -Kernel $Kernel -DkmsModules $dkms `
			-Offers $offers -InstalledPackages $installed -ClaimedBy $claimed

		$o = [pscustomobject]@{
			Name         = $d.Description
			Class        = Get-OS7DeviceClass -Device $d
			State        = $r.State
			Driver       = $d.Driver
			Action       = $r.Action
			Command      = $r.Command
			Bus          = $d.Bus
			Address      = $d.Address
			HardwareId   = "$($d.Bus.ToLowerInvariant()):$($d.VendorId):$($d.ProductId)"
			Vendor       = $d.Vendor
			Product      = $d.Product
			ClassName    = $d.ClassName
			Modalias     = $d.Modalias
			Alternatives = @($r.Alternatives)
			Rebuild      = $r.Rebuild
			# THE URL IS COMPUTED, NOT FETCHED. Nothing here contacts
			# linux-hardware.org; this is a string an operator can open, and it
			# is only set where it would help.
			SupportUrl   = $(if ($r.State -eq 'NotSupported') {
					"https://linux-hardware.org/?id=$($d.Bus.ToLowerInvariant()):$($d.VendorId)-$($d.ProductId)"
				} else { $null })
			SysfsPath    = $d.SysfsPath
		}
		$o.PSObject.TypeNames.Insert(0, 'OS7.Device')
		$out += $o
	}

	if ($Name) { $out = @($out | Where-Object { $_.Name -like $Name }) }
	if ($Class) { $out = @($out | Where-Object { $_.Class -eq $Class }) }
	if ($State) { $out = @($out | Where-Object { $_.State -eq $State }) }
	elseif (-not $All -and -not $Address) {
		$out = @($out | Where-Object { $_.State -ne 'Working' })
	}

	# Worst first. Sorting by the state NAME would put DriverAvailable above
	# NeedsRebuild and bury the one that means something is already broken.
	return @($out | Sort-Object `
		@{ Expression = { $script:OS7DeviceStateOrder.IndexOf($_.State) } },
		@{ Expression = { $_.Class } },
		@{ Expression = { $_.Name } })
}

function Get-OS7Driver {
	<#
	.SYNOPSIS
		The drivers on this machine that are compiled rather than shipped — and
		whether each is built for the kernel that matters.

	.DESCRIPTION
		SEPARATE FROM Get-OS7Device BECAUSE A DKMS MODULE NEED NOT HAVE A
		DEVICE. A VPN's tap driver, a virtualisation module, a filesystem —
		none of them appears in /sys/bus/pci or /sys/bus/usb, and all of them
		break the same way after a kernel update. Listing only drivers that are
		attached to visible hardware would miss exactly the ones nobody thinks
		to check.

		`Healthy` is whether an `installed` row exists for the kernel. Not
		whether dkms said something bad: it has no word for bad — `added`,
		`built` and `installed` are the complete set, and a module whose build
		FAILED reports `added`, identically to one nobody has tried to build
		(measured, dkms 3.2.2).

		`built` is NOT healthy. A module that compiled and was never installed
		is not in /lib/modules/<kernel>/updates/dkms and will not load, and
		`dkms status` calls it `built`, which reads like good news.

	.PARAMETER Name
		One module, or a glob.

	.PARAMETER Unhealthy
		Only the drivers that are not built for the kernel in question.

	.PARAMETER Kernel
		The kernel to judge against. The running one by default.

	.PARAMETER Root
		Ask inside another root.

	.EXAMPLE
		Get-OS7Driver

	.EXAMPLE
		Get-OS7Driver -Unhealthy | Repair-OS7Driver -Confirm:$false
	#>
	[CmdletBinding()]
	[OutputType('OS7.Driver')]
	param(
		[string]$Name,
		[switch]$Unhealthy,
		[string]$Kernel,
		[string]$Root = ''
	)

	Import-OS7HardwareLayer
	if (-not $Kernel) { $Kernel = Get-OS7RunningKernel -Root $Root }

	$loaded = @{}
	foreach ($m in @(Get-KernelModule -Root $Root)) { $loaded[$m.Name] = $m }

	# Which devices a module is bound to, so that a rebuild can be explained in
	# terms of the thing that would stop working rather than of a module name.
	$boundTo = @{}
	foreach ($d in @(Get-HardwareDevice -Root $Root)) {
		if (-not $d.Driver) { continue }
		if (-not $boundTo.ContainsKey($d.Driver)) { $boundTo[$d.Driver] = @() }
		$boundTo[$d.Driver] += $d.Description
	}

	$out = @()
	foreach ($m in @(Get-DkmsModule -Name $Name -Root $Root)) {
		$healthy = $Kernel -in @($m.InstalledFor)
		$o = [pscustomobject]@{
			Name         = $m.Name
			Version      = $m.Version
			Kind         = 'DKMS'
			Kernel       = $Kernel
			Healthy      = $healthy
			Loaded       = $loaded.ContainsKey($m.Name)
			InstalledFor = @($m.InstalledFor)
			BuiltFor     = @($m.BuiltFor)
			Devices      = @($(if ($boundTo.ContainsKey($m.Name)) { $boundTo[$m.Name] } else { @() }))
			Action       = $null
			Command      = $null
		}
		if (-not $healthy) {
			$where = if ($o.InstalledFor.Count) {
					"It is installed for $($o.InstalledFor -join ', ')."
				}
				elseif ($o.BuiltFor.Count) {
					"It compiled for $($o.BuiltFor -join ', ') and was never installed."
				}
				else {
					'dkms has it registered and not built for any kernel — which is also ' +
					'what a FAILED build looks like, because dkms has no word for one.'
				}
			# THE MOST IMPORTANT SENTENCE IN THIS FILE. A loaded-but-not-built
			# module is the silent case: it works right now, from the kernel it
			# was compiled for, and it disappears at the next reboot.
			$now = if ($o.Loaded) {
					' It is loaded RIGHT NOW, from a kernel it was built for, and will not ' +
					'come back after the next reboot into ' + $Kernel + '.'
				} else { '' }
			$o.Action = "$($m.Name) $($m.Version) is not installed for $Kernel. $where$now"
			$o.Command = "Repair-OS7Driver -Name $($m.Name)"
		}
		else {
			$o.Action = "Built and installed for $Kernel."
		}
		$o.PSObject.TypeNames.Insert(0, 'OS7.Driver')
		$out += $o
	}

	if ($Unhealthy) { $out = @($out | Where-Object { -not $_.Healthy }) }
	return @($out | Sort-Object Healthy, Name)
}


function Get-OS7DeviceStatus {
	<#
	.SYNOPSIS
		One screen: what is wrong with this machine's hardware, and what to do.

	.DESCRIPTION
		THE CAPSTONE, and the thing an operator actually types. Get-OS7Device
		returns objects to filter and pipe; this returns the report, and the
		format file renders it as the page a person reads.

		It is a separate cmdlet rather than a switch for the same reason
		Get-OS7ManagementStatus is: the summary needs a shape the per-device
		object does not have — the counts, the drivers with no device, and the
		line that says how many devices were NOT listed because they are fine.
		That last line is what makes a short report trustworthy instead of
		suspicious.

		`Checked` IS NOT ALWAYS TRUE. When ubuntu-drivers is absent this machine
		cannot answer the better-driver question at all, and the report says so
		rather than reporting no better drivers. Same for the module index.

	.PARAMETER Kernel
		Judge against a kernel other than the running one.

	.PARAMETER Root
		Ask about another root.

	.EXAMPLE
		Get-OS7DeviceStatus
	#>
	[CmdletBinding()]
	[OutputType('OS7.DeviceStatus')]
	param(
		[string]$Kernel,
		[string]$Root = ''
	)

	Import-OS7HardwareLayer
	if (-not $Kernel) { $Kernel = Get-OS7RunningKernel -Root $Root }

	$all = @(Get-OS7Device -All -Kernel $Kernel -Root $Root)
	$drivers = @(Get-OS7Driver -Kernel $Kernel -Root $Root)

	$counts = [ordered]@{}
	foreach ($s in $script:OS7DeviceStateOrder) {
		$counts[$s] = @($all | Where-Object { $_.State -eq $s }).Count
	}

	# THE DRIVERS WITH NO DEVICE. A DKMS module bound to nothing visible — a
	# tap driver, a filesystem — breaks the same way and would be invisible in
	# a device list.
	$orphaned = @($drivers | Where-Object { -not $_.Healthy -and $_.Devices.Count -eq 0 })

	$hwprobe = Get-HwProbe -Root $Root
	$offers = Get-UbuntuDriver -Root $Root

	$o = [pscustomobject]@{
		Kernel          = $Kernel
		TotalDevices    = $all.Count
		Counts          = [pscustomobject]$counts
		# The devices worth reading, in the order Get-OS7Device already sorted
		# them: worst first.
		Attention       = @($all | Where-Object { $_.State -ne 'Working' })
		Drivers         = $drivers
		OrphanedDrivers = $orphaned
		# WHAT COULD NOT BE ASKED, said out loud. A report that silently omits
		# a question reads as a report that asked it and found nothing.
		DriverOffersChecked = ($null -ne $offers)
		HwProbeAvailable    = $hwprobe.Installed
		Healthy         = (@($all | Where-Object { $_.State -in @('NeedsRebuild', 'NotSupported') }).Count -eq 0 -and
			@($drivers | Where-Object { -not $_.Healthy }).Count -eq 0)
	}
	$o.PSObject.TypeNames.Insert(0, 'OS7.DeviceStatus')
	return $o
}

function Install-OS7Driver {
	<#
	.SYNOPSIS
		Install a driver package that Ubuntu offers for a device.

	.DESCRIPTION
		WRAPS `ubuntu-drivers`, WHICH IS NOT LAZINESS. Deciding that an NVIDIA
		card would do more with nvidia-driver-570 than with nouveau is a data
		problem: a table of modalias patterns against package names, per
		release, kept current as cards appear. Ubuntu maintains that table and
		ships it. A copy of it in this repository would be a copy that goes
		stale on a product whose entire delivery model is a curated release
		train.

		ASKS dpkg AFTERWARDS. apt exits 0 in cases where the package asked for
		is not the package installed — the standing rule in docs/BUILD-NOTES.md,
		and the one every apt step in OS7.Update.ps1 follows for the same reason.

		A REBOOT IS USUALLY REQUIRED and this cmdlet does not perform one. The
		result says so; Restart is the operator's decision and is never taken
		as a side effect of installing something.

	.PARAMETER Package
		The package to install.

	.PARAMETER Device
		An OS7.Device from Get-OS7Device, by pipeline. Its recommended
		alternative is installed.

	.PARAMETER Recommended
		Install the recommended driver for EVERY device that has one —
		`ubuntu-drivers autoinstall`.

	.EXAMPLE
		Get-OS7Device -State DriverAvailable | Install-OS7Driver

	.EXAMPLE
		Install-OS7Driver -Package nvidia-driver-570 -WhatIf
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Package')]
	[OutputType('OS7.DriverInstallResult')]
	param(
		[Parameter(ParameterSetName = 'Package', Position = 0)][string]$Package,
		[Parameter(ParameterSetName = 'Device', ValueFromPipeline)]$Device,
		[Parameter(ParameterSetName = 'All')][switch]$Recommended,
		[string]$Root = ''
	)

	begin {
		Import-OS7HardwareLayer
		$results = @()
	}

	process {
		$pkg = $Package
		if ($Device) {
			if ($Device.State -ne 'DriverAvailable') {
				Write-OS7Step "$($Device.Name): state is $($Device.State), not DriverAvailable — skipped"
				return
			}
			$alts = @($Device.Alternatives)
			if ($alts.Count -eq 0) {
				# THE OTHER DriverAvailable CASE: the kernel has a module and it
				# is not loaded. There is nothing to install, and installing
				# something would be the wrong fix.
				Write-OS7Step ("$($Device.Name): there is nothing to install — the kernel " +
					"already has a driver for it. Repair-OS7Driver -Address $($Device.Address).")
				return
			}
			$pick = @($alts | Where-Object { $_.Recommended })
			$pkg = if ($pick.Count) { $pick[0].Package } else { $alts[0].Package }
		}

		if (-not $pkg -and -not $Recommended) {
			throw [System.ArgumentException]::new(
				'name a -Package, pipe a device in, or use -Recommended for every device at once.')
		}

		$r = Install-UbuntuDriver -Package $pkg -Root $Root `
			-WhatIf:$WhatIfPreference -Confirm:$false
		if ($null -eq $r) { return }

		$o = [pscustomobject]@{
			Package       = $r.Package
			Installed     = $r.Installed
			Device        = $(if ($Device) { $Device.Name } else { $null })
			RebootNeeded  = ($r.Installed -eq $true)
			ExitCode      = $r.ExitCode
			Output        = $r.Output
		}
		$o.PSObject.TypeNames.Insert(0, 'OS7.DriverInstallResult')
		$results += $o
	}

	end {
		if ($Recommended) {
			$r = Install-UbuntuDriver -Root $Root -WhatIf:$WhatIfPreference -Confirm:$false
			if ($null -ne $r) {
				$o = [pscustomobject]@{
					Package      = '(recommended, every device)'
					Installed    = $null
					Device       = $null
					RebootNeeded = ($r.ExitCode -eq 0)
					ExitCode     = $r.ExitCode
					Output       = $r.Output
				}
				$o.PSObject.TypeNames.Insert(0, 'OS7.DriverInstallResult')
				$results += $o
			}
		}
		return $results
	}
}


function Repair-OS7Driver {
	<#
	.SYNOPSIS
		Rebuild a driver that is not built for this kernel, or load one that is
		built and not loaded — and then check that it worked.

	.DESCRIPTION
		THE ONE-CLICK FIX FOR THE FAILURE MODE THIS FEATURE EXISTS FOR. A DKMS
		driver that did not rebuild after a kernel update is gone at the next
		reboot, nothing said so, and `dkms status` cannot say so — `added`,
		`built` and `installed` are its complete vocabulary and a failed build
		reports `added`, exactly like one nobody has tried (measured, dkms
		3.2.2).

		IT ASKS dkms AFTERWARDS AND REPORTS FROM THAT, never from the exit code.
		Measured: with three modules of which one cannot compile, `dkms
		autoinstall` installed the two that could, printed "succeeded for
		module(s) good half" and "failed for module(s) bad(10)", and exited 11.
		A caller that stopped at the exit code would call that a total failure;
		one that took a 0 from a different invocation would call a failure a
		success.

		WHEN IT FAILS IT SAYS WHERE THE LOG IS. A DKMS build failure is a
		compiler failure and the compiler's output is in
		/var/lib/dkms/<module>/<version>/build/make.log — measured, and it is
		the only place the reason exists.

		-Address is the other repair: a device with no driver bound whose
		modalias a module in the kernel does claim. There is nothing to build;
		the module is loaded.

	.PARAMETER Name
		The DKMS module to rebuild.

	.PARAMETER Driver
		An OS7.Driver from Get-OS7Driver, by pipeline.

	.PARAMETER Address
		A device whose driver is present and not loaded.

	.PARAMETER All
		Every DKMS module that is not built for the kernel — `dkms autoinstall`.

	.PARAMETER Kernel
		The kernel to build for. The running one by default.

	.EXAMPLE
		Get-OS7Driver -Unhealthy | Repair-OS7Driver

	.EXAMPLE
		Repair-OS7Driver -All -WhatIf
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Name')]
	[OutputType('OS7.DriverRepairResult')]
	param(
		[Parameter(ParameterSetName = 'Name', Position = 0)][string]$Name,
		[Parameter(ParameterSetName = 'Driver', ValueFromPipeline)]$Driver,
		[Parameter(ParameterSetName = 'Address')][string]$Address,
		[Parameter(ParameterSetName = 'All')][switch]$All,
		[string]$Kernel,
		[string]$Root = ''
	)

	begin {
		Import-OS7HardwareLayer
		if (-not $Kernel) { $Kernel = Get-OS7RunningKernel -Root $Root }
		$results = @()
	}

	process {
		# ---- the device case: nothing to build, a module to load ---------
		if ($Address) {
			$d = @(Get-HardwareDevice -Root $Root | Where-Object { $_.Address -eq $Address })
			if ($d.Count -eq 0) {
				throw [System.ArgumentException]::new("no device at $Address.")
			}
			if ($d[0].Driver) {
				Write-OS7Step "$Address already has $($d[0].Driver) bound — nothing to repair"
				return
			}
			$claimed = Resolve-KernelModule -Modalias $d[0].Modalias -Kernel $Kernel -Root $Root
			if ($null -eq $claimed) {
				throw [System.InvalidOperationException]::new(
					"there is no module index for $Kernel, so no module can be found for " +
					"$Address. Nothing was attempted.")
			}
			if (@($claimed).Count -eq 0) {
				throw [System.InvalidOperationException]::new(
					"no module in $Kernel claims $($d[0].Modalias). This device has no driver " +
					'to load; Send-OS7HardwareProbe is the honest next step.')
			}
			$mod = @($claimed)[0]
			if (-not $PSCmdlet.ShouldProcess($Address, "load the kernel module $mod")) { return }

			# Add-KernelModule, NOT `Invoke-HardwareCommand -Command 'modprobe'`.
			# The first version did the latter — which routes through the
			# Hardware module and still names the program, so this file was
			# deciding to run modprobe. That is what P2-hardware forbids, and
			# writing the rule is what found it. Add-KernelModule also asks
			# /proc/modules back, which the inline call did not: modprobe exits
			# 0 for a module that loads and immediately unloads itself.
			$load = Add-KernelModule -Name $mod -Root $Root -Confirm:$false
			$after = @(Get-HardwareDevice -Root $Root | Where-Object { $_.Address -eq $Address })
			$o = [pscustomobject]@{
				Module    = $mod
				Version   = $null
				Kernel    = $Kernel
				Device    = $d[0].Description
				Repaired  = ($after.Count -gt 0 -and $null -ne $after[0].Driver)
				Reason    = $null
				LogFile   = $null
				Output    = $null
			}
			if (-not $o.Repaired) {
				# THE TWO FAILURES ARE DIFFERENT AND BOTH ARE REPORTED. A module
				# that never loaded is one problem; a module that loaded and did
				# not claim the device is another, and telling somebody to try
				# loading it again would be advice for the wrong one.
				$o.Reason = if (-not $load.Loaded) {
					"modprobe exited $($load.ExitCode) and $mod is not in /proc/modules. " +
					'It refused to load, or it loaded and removed itself. ' + $load.Output
				}
				else {
					"$mod is loaded and no driver is bound to $Address. The module is there " +
					'and did not claim this device.'
				}
			}
			$o.PSObject.TypeNames.Insert(0, 'OS7.DriverRepairResult')
			$results += $o
			return
		}

		# ---- the DKMS case ------------------------------------------------
		$mods = @()
		if ($Driver) { $mods = @([pscustomobject]@{ Name = $Driver.Name; Version = $Driver.Version }) }
		elseif ($Name) {
			$found = @(Get-DkmsModule -Name $Name -Root $Root)
			if ($found.Count -eq 0) {
				throw [System.ArgumentException]::new(
					"dkms has no module called $Name. Get-OS7Driver lists the ones it has.")
			}
			$mods = @($found | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = $_.Version } })
		}
		elseif (-not $All) {
			throw [System.ArgumentException]::new(
				'name a -Name, pipe a driver in, give an -Address, or use -All.')
		}

		$targets = if ($All) { @([pscustomobject]@{ Name = $null; Version = $null }) } else { $mods }

		foreach ($t in $targets) {
			$what = if ($t.Name) { "$($t.Name) $($t.Version)" } else { 'every DKMS module' }
			if (-not $PSCmdlet.ShouldProcess("$what for $Kernel", 'rebuild and install')) { continue }

			Write-OS7Step "rebuilding $what for $Kernel"
			$r = Invoke-DkmsBuild -Name $t.Name -Version $t.Version -Kernel $Kernel -Root $Root `
				-Confirm:$false
			if ($null -eq $r) { continue }

			foreach ($nameOut in @($(if ($t.Name) { @("$($t.Name)/$($t.Version)") } else { @($r.Installed) + @($r.NotInstalled) }))) {
				if (-not $nameOut) { continue }
				$parts = $nameOut.Split('/')
				$ok = ($nameOut -in @($r.Installed))
				$o = [pscustomobject]@{
					Module   = $parts[0]
					Version  = $(if ($parts.Count -gt 1) { $parts[1] } else { $null })
					Kernel   = $Kernel
					Device   = $null
					Repaired = $ok
					Reason   = $null
					# THE ONLY PLACE THE REASON EXISTS. dkms writes the
					# compiler's output here and reports none of it in its
					# status; without this line the operator is told a rebuild
					# failed and given nowhere to look.
					LogFile  = $(if ($ok) { $null } else {
							"/var/lib/dkms/$($parts[0])/$($parts[1])/build/make.log" })
					Output   = $r.Output
				}
				if (-not $ok) {
					$o.Reason = "dkms exited $($r.ExitCode) and $($o.Module) is still not " +
						"installed for $Kernel. The compiler's output is in $($o.LogFile)."
				}
				$o.PSObject.TypeNames.Insert(0, 'OS7.DriverRepairResult')
				$results += $o
			}
		}
	}

	end { return $results }
}

function Send-OS7HardwareProbe {
	<#
	.SYNOPSIS
		UPLOAD a description of this machine's hardware to the Linux Hardware
		Database, so that a device with no driver can be looked up against
		other people's reports.

	.DESCRIPTION
		THIS SENDS DATA TO A THIRD PARTY, PUBLICLY AND PERMANENTLY. Read this
		whole block before running it.

		WHAT IT IS FOR. `NotSupported` is the one state OS/7 cannot fix. There
		is no driver; inventing a suggestion would be worse than saying so. What
		IS useful is that somebody else may have the same hardware and may have
		found out what it needs, and linux-hardware.org is where those reports
		are collected. hw-probe both submits and gives back a URL for the probe.

		WHAT IS SENT. hw-probe collects the output of a long list of hardware
		tools and, by its own documentation, hashes or removes serial numbers,
		MAC addresses, IP addresses, hostnames and the machine id before
		uploading. THIS CMDLET DOES NOT VERIFY THAT CLAIM and does not repeat it
		as though it had been checked here. It is the tool's claim about the
		tool, and an operator sending a corporate machine's hardware inventory
		to a public database should weigh it as such.

		WHAT MAKES IT AN OPT-IN, mechanically and not just in a paragraph:
		  * Nothing calls this. Not Get-OS7DeviceStatus, not Get-OS7Device, not
		    any health, inventory or support-bundle cmdlet. It runs when a
		    person runs it.
		  * ConfirmImpact is High, so it prompts by default and -WhatIf prints
		    the destination and sends nothing.
		  * hw-probe is NOT on an OS/7 image. It is in Ubuntu universe and this
		    cmdlet refuses rather than installing it silently; -InstallTool is
		    a separate, explicit decision, and it is a second prompt.

		A PROBE CANNOT BE WITHDRAWN once it is uploaded.

	.PARAMETER InstallTool
		Install hw-probe from Ubuntu universe first. A decision of its own, and
		prompted separately.

	.EXAMPLE
		Send-OS7HardwareProbe -WhatIf

		Prints what would be sent and where, and sends nothing.

	.EXAMPLE
		Get-OS7Device -State NotSupported
		Send-OS7HardwareProbe
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.HardwareProbeResult')]
	param(
		[switch]$InstallTool,
		[string]$Root = ''
	)

	Import-OS7HardwareLayer

	$state = Get-HwProbe -Root $Root
	if (-not $state.Installed) {
		if (-not $InstallTool) {
			throw [System.InvalidOperationException]::new(
				'hw-probe is not installed, and OS/7 does not ship it: it is a tool that ' +
				"uploads to a third party, and a managed image should not carry one by`n" +
				"default. It is in Ubuntu universe.`n`n" +
				"    Send-OS7HardwareProbe -InstallTool`n`n" +
				'installs it and then asks again before sending anything. Nothing has been sent.')
		}
		if (-not $PSCmdlet.ShouldProcess('hw-probe', 'install from Ubuntu universe')) {
			return $null
		}
		Write-OS7Step 'installing hw-probe from universe'
		# Install-HwProbe, NOT apt-get here. Which package hw-probe is and where
		# it comes from is the Hardware module's knowledge, and P2-hardware is
		# what stopped this file from holding a second copy of it.
		$state = Install-HwProbe -Root $Root -Confirm:$false
		if ($null -eq $state -or -not $state.Installed) {
			throw [System.InvalidOperationException]::new(
				'apt-get exited 0 and hw-probe is still not there. Nothing has been sent.')
		}
	}

	$r = Send-HwProbe -Root $Root -WhatIf:$WhatIfPreference -Confirm:$false
	if ($null -eq $r) { return $null }

	$o = [pscustomobject]@{
		Uploaded    = $r.Uploaded
		Url         = $r.Url
		Destination = 'https://linux-hardware.org/'
		Devices     = @(Get-OS7Device -State NotSupported -Root $Root | ForEach-Object { $_.Name })
		Output      = $r.Output
	}
	$o.PSObject.TypeNames.Insert(0, 'OS7.HardwareProbeResult')
	return $o
}


# ---------------------------------------------------------------------------
# The update gate
#
# THE HOOK Update-OS7 CALLS, and the reason the device manager is worth more
# than a nicer lspci. Everything above tells an operator that a driver did not
# rebuild. This stops a machine from rebooting into an environment where one
# did not.
#
# IT IS FEASIBLE BECAUSE OF HOW THE UPDATE TRAIN IS ALREADY BUILT, which was
# checked before it was designed: Update-OS7 step 3 assembles the clone with
# /dev, /proc, /sys and /run mounted and Assert-OS7UpdateRootAssembled refuses
# to go on until the kernel confirms every one of them, and step 5 runs apt
# inside it. A chroot that apt can install a kernel in is a chroot dkms can be
# asked in. `Get-DkmsModule -Root $root` is the whole mechanism.
# ---------------------------------------------------------------------------

function Get-OS7DriverRegression {
	<#
	.SYNOPSIS
		Compare a machine's compiled drivers before and after — and separate a
		driver that BROKE from one that was already broken.

	.DESCRIPTION
		THE DISTINCTION IS THE WHOLE POINT, and without it the gate is unusable.

		A machine can carry a DKMS module that has not built for months —
		somebody's abandoned webcam driver, a vendor module for hardware that
		was removed. Blocking every update on it means the machine can never be
		updated again, and the operator's only route is a switch that turns the
		check off entirely, which is the same as not having it.

		So there are four verdicts and only one of them stops anything:

		  Regression   it is installed for the kernel the machine runs NOW and
		               is NOT installed for the kernel the new environment will
		               boot. Something that works today will not work after the
		               reboot. THIS IS THE ONE THAT BLOCKS.
		  StillBroken  it was not installed before and is not now. Reported,
		               never blocking: the update did not cause it and holding
		               the machine on an old release does not fix it.
		  Fixed        it was broken and now is not.
		  Fine         installed for both.

		"INSTALLED FOR" IS THE ONLY QUESTION ASKED, in both directions, and it
		is asked of `dkms status`'s rows rather than of any word in them.
		`dkms status` has three words — `added`, `built`, `installed` — and a
		module whose build FAILED reports `added`, byte for byte what a module
		nobody has ever tried to build reports (measured, dkms 3.2.2). There is
		no failure to look for. There is only a row that should exist and does
		not.

		AND `dkms status -k <kernel>` IS NEVER USED. Asked about a kernel it has
		no builds for it lists every module in the `added` shape and exits 0 —
		three modules reading fine, on a machine where nothing was built for
		that kernel at all. The Hardware module filters the rows itself and this
		function inherits that.

	.PARAMETER Root
		The assembled new boot environment.

	.PARAMETER Kernel
		The kernel that environment will boot. NOT the running one, and not
		read from /proc — /proc inside a chroot is the host's, so asking it
		would compare the new environment against the kernel it is replacing
		and pass every time.

	.PARAMETER Before
		Get-OS7Driver's output from the RUNNING system, taken before the clone
		was assembled. Taken before on purpose: once the clone is mounted, two
		environments are in play and a reading is ambiguous about which.

	.EXAMPLE
		$before = Get-OS7Driver
		# … the update assembles the clone …
		Get-OS7DriverRegression -Root /run/os7-update -Kernel 6.14.0-35-generic -Before $before
	#>
	[CmdletBinding()]
	[OutputType('OS7.DriverRegression')]
	param(
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)][string]$Kernel,
		$Before = @()
	)

	Import-OS7HardwareLayer

	$was = @{}
	foreach ($b in @($Before)) { $was["$($b.Name)/$($b.Version)"] = [bool]$b.Healthy }

	$out = @()
	foreach ($m in @(Get-DkmsModule -Root $Root)) {
		$key = "$($m.Name)/$($m.Version)"
		$now = $Kernel -in @($m.InstalledFor)
		# A MODULE THE RUNNING SYSTEM DID NOT HAVE AT ALL is not a regression.
		# The release being applied introduced it, and it either built or it did
		# not; there is nothing it used to do that it has stopped doing.
		# $wasWorking, NOT $before. `$before` IS the `-Before` parameter, and
		# PowerShell variable names are case-insensitive: this assignment
		# replaced the caller's list with a boolean, once per loop iteration.
		# It happened to work only because $was is built before the loop starts.
		# BUILD-NOTES #65, found by installer/testing/check-ps-traps.py.
		$wasWorking = $(if ($was.ContainsKey($key)) { $was[$key] } else { $null })

		$verdict =
			if ($now -and $wasWorking -ne $false) { 'Fine' }
			elseif ($now) { 'Fixed' }
			elseif ($wasWorking -eq $true) { 'Regression' }
			else { 'StillBroken' }

		$o = [pscustomobject]@{
			Module        = $m.Name
			Version       = $m.Version
			Kernel        = $Kernel
			WasInstalled  = $wasWorking
			IsInstalled   = $now
			Verdict       = $verdict
			InstalledFor  = @($m.InstalledFor)
			# THE ONLY PLACE THE REASON EXISTS. dkms writes the compiler's
			# output here and reports none of it in its status.
			LogFile       = $(if ($now) { $null } else {
					"/var/lib/dkms/$($m.Name)/$($m.Version)/build/make.log" })
			Action        = $null
		}
		$o.Action = switch ($verdict) {
			'Regression' {
				"$($m.Name) $($m.Version) works on this machine now and is NOT built for " +
				"$Kernel. Rebooting into the new environment would lose it."
			}
			'StillBroken' {
				"$($m.Name) $($m.Version) was already not built before this update, and " +
				"still is not. This update did not cause it."
			}
			'Fixed' { "$($m.Name) $($m.Version) was not built before and now is." }
			default { "$($m.Name) $($m.Version) is built for $Kernel." }
		}
		$o.PSObject.TypeNames.Insert(0, 'OS7.DriverRegression')
		$out += $o
	}
	return @($out)
}
