# =============================================================================
# Hardware — devices, drivers and DKMS, as objects
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like Zfs, Net, Time and
# Systemd. It knows sysfs, dkms, modprobe, ubuntu-drivers and hw-probe, and
# nothing about OS/7. No word an operator reads is decided here.
#
# SEVEN THINGS MEASURED 2026-08-27 — dkms 3.2.2, pciutils 1:3.14.0-1build2,
# ubuntu-drivers-common 1:0.10.9, a real aarch64 sysfs — and each one decides a
# piece of this file. They are here rather than in a session document because
# every one of them is a reason some obvious implementation is wrong.
#
#   1. `dkms status` HAS THREE WORDS AND NONE OF THEM IS "FAILED".
#      `added`, `built`, `installed` — that is the complete set, confirmed both
#      by grepping /usr/sbin/dkms and by building a module that CANNOT compile:
#      `dkms build` exited 10, and `dkms status` then said
#
#          bad/3.0: added
#
#      which is byte for byte what it says about a module nobody has ever tried
#      to build. THE FAILURE IS NOT IN THE STATUS. That is the whole reason a
#      driver can disappear across a kernel update without anything saying so,
#      and it is why nothing in this module looks for a bad word. The question
#      it asks instead is whether a row for the kernel in question EXISTS.
#
#   2. `dkms status -k <kernel>` DOES NOT FILTER BY KERNEL and does not answer
#      about it. Asked about a kernel with no builds at all it printed
#
#          bad/3.0: added
#          good/1.0: added
#          half/2.0: added
#
#      and exited 0 — three modules that are not built for that kernel, in the
#      shape that means "no kernel is involved in this answer". `-k` changes
#      the SHAPE of the output, not the rows. A gate that ran
#      `dkms status -k $new` and looked for trouble would find none, on a
#      machine where nothing had been built for $new at all.
#
#   3. `built` IS NOT `installed`, and `built` is a broken state. A module that
#      compiled but was never installed is not in /lib/modules/<k>/updates/dkms
#      and will not load. `dkms status` reports it as `built`, which reads like
#      good news.
#
#   4. `dkms autoinstall` PARTIALLY SUCCEEDS and reports one exit code for the
#      whole run: with three modules of which one cannot compile it installed
#      the two that could, printed "succeeded for module(s) good half" and
#      "failed for module(s) bad(10)", and exited 11. 21 is the separate case
#      of no kernel headers. So the exit code names the run, never a module,
#      and Invoke-DkmsBuild re-asks the status per module afterwards.
#
#   5. `modprobe -R <modalias>` FAILS ENTIRELY when the running kernel has no
#      modules directory — `FATAL: Module pci:v… not found in directory
#      /lib/modules/7.0.12-linuxkit`. That failure and "nothing claims this
#      alias" are the same exit code, and confusing them would report every
#      device on such a machine as having no driver available. Resolve-KernelModule
#      returns $null for "could not be asked" and an empty array for "asked,
#      nothing claims it", and they are not the same value.
#
#   6. `ubuntu-drivers` CAN DECLINE TO ANSWER, in prose, on stdout:
#      "Your running kernel … requires DKMS modules, and ubuntu-drivers was
#      unable to determine if Secure Boot is enabled … Please use --include-dkms
#      if you want to proceed." Parsed as a device list that is zero devices,
#      which reads as "no better driver exists for anything on this machine".
#      ConvertFrom-UbuntuDriversDevices refuses text that has no `==` header.
#
#   7. lspci IS NOT THE AUTHORITY AND SYSFS IS. `lspci -mm -vkn` on the machine
#      this was measured on printed `lspci: Unable to load libkmod resources:
#      error -2` and then dropped every `Module:` line — the half of its output
#      that says which drivers COULD handle a device — while still printing
#      `Driver:` and still exiting 0. pciutils is also a package, and it is
#      absent from a minimal image. /sys/bus/pci is the kernel itself. So this
#      module enumerates from sysfs and uses pci.ids only for the human name,
#      which is cosmetic and allowed to be missing.
#
# AND ONE ABOUT USB: THE DRIVER BINDS TO THE INTERFACE, NOT THE DEVICE.
# /sys/bus/usb/devices holds both — `usb1` is a device and carries idVendor and
# idProduct; `1-0:1.0` is an interface and carries the modalias and the `driver`
# symlink. Read only the device and every USB device on the machine has no
# driver. Read only the interfaces and there is no vendor or product to name.
# Get-HardwareDevice joins them, and says which interface each driver came from.
# =============================================================================

Set-StrictMode -Version 3.0

# Test seams. Both are $null in production and neither is exported: a module
# that could be told to lie from outside is a module whose answers cannot be
# trusted (the argument Zfs.psm1 makes for the same variable).
$script:HardwareCommandOverride = $null

# The PCI base classes that this module maps to a name when pci.ids is not
# installed. THE CODES ARE THE PCI SPECIFICATION'S and do not change; the names
# are the ones pci.ids itself uses, so a machine with and without the package
# reads the same. Only the base class is here — the sub-class table is 2000
# lines and is exactly what pci.ids is for.
$script:PciBaseClasses = @{
	'00' = 'Unclassified device'
	'01' = 'Mass storage controller'
	'02' = 'Network controller'
	'03' = 'Display controller'
	'04' = 'Multimedia controller'
	'05' = 'Memory controller'
	'06' = 'Bridge'
	'07' = 'Communication controller'
	'08' = 'Generic system peripheral'
	'09' = 'Input device controller'
	'0a' = 'Docking station'
	'0b' = 'Processor'
	'0c' = 'Serial bus controller'
	'0d' = 'Wireless controller'
	'0e' = 'Intelligent controller'
	'0f' = 'Satellite communications controller'
	'10' = 'Encryption controller'
	'11' = 'Signal processing controller'
	'12' = 'Processing accelerators'
	'13' = 'Non-Essential Instrumentation'
	'40' = 'Coprocessor'
	'ff' = 'Unassigned class'
}

# USB device and interface classes, from the USB-IF class-code list. HARDCODED
# AND NOT READ FROM A FILE, because usb.ids IS NOT SHIPPED: `usbutils` in
# resolute installs no usb.ids anywhere on the filesystem (measured — `find /
# -name usb.ids` after installing it finds nothing). A USB device names itself
# in sysfs through `manufacturer` and `product`, which is a better source than
# a database anyway; only the class needs a table.
$script:UsbClasses = @{
	'01' = 'Audio'
	'02' = 'Communications'
	'03' = 'Human interface device'
	'05' = 'Physical'
	'06' = 'Image'
	'07' = 'Printer'
	'08' = 'Mass storage'
	'09' = 'Hub'
	'0a' = 'CDC data'
	'0b' = 'Smart card'
	'0d' = 'Content security'
	'0e' = 'Video'
	'0f' = 'Personal healthcare'
	'10' = 'Audio/video'
	'11' = 'Billboard'
	'12' = 'USB Type-C bridge'
	'dc' = 'Diagnostic device'
	'e0' = 'Wireless controller'
	'ef' = 'Miscellaneous'
	'fe' = 'Application specific'
	'ff' = 'Vendor specific'
}

# Where pci.ids lands. SEARCHED, NEVER NAMED — BUILD-NOTES #64, which is an
# initramfs script that asked for /usr/lib/systemd/systemd-cryptsetup on a
# distribution that puts it in /usr/bin and gave up silently on every boot.
# /usr/share/misc is where the `pci.ids` package puts it on resolute (measured);
# the others are where other distributions and the hwdata package put it.
$script:PciIdsPaths = @(
	'/usr/share/misc/pci.ids'
	'/usr/share/hwdata/pci.ids'
	'/usr/share/pci.ids'
)

# Parsed pci.ids, once per session. The file is 1.4 MB and roughly 40 000 lines;
# re-reading it per device turns a listing into a minute.
$script:PciIdCache = $null


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

function Invoke-HardwareCommand {
	<#
	.SYNOPSIS
		Internal. Run a program and return stdout, stderr and the exit code,
		without judging the exit code.

	.DESCRIPTION
		WITHOUT JUDGING IT, deliberately, and this module needs that more than
		its siblings do: `dkms build` exits 10 for a compile failure, 21 for
		missing headers and 11 for "some modules failed", and every one of
		those is a real answer this module reports rather than an exception it
		throws.

		-Root runs the command inside a chroot. That is not a test seam — it is
		how an update asks the environment it has just assembled, rather than
		the one it is running on, what its DKMS state is. When the command
		override is set no chroot happens, because there is nothing to chroot
		into.
	#>
	param(
		[Parameter(Mandatory)][string]$Command,
		[string[]]$Arguments = @(),
		[string]$Root = ''
	)

	if ($script:HardwareCommandOverride) {
		return & $script:HardwareCommandOverride $Command $Arguments
	}

	$exe = $Command
	$argv = $Arguments
	if ($Root -and $Root -ne '/') {
		$exe = 'chroot'
		$argv = @($Root, $Command) + $Arguments
	}

	$errFile = [System.IO.Path]::GetTempFileName()
	try {
		$out = & $exe @argv 2> $errFile
		return [pscustomobject]@{
			StdOut   = ($out -join "`n")
			ExitCode = $LASTEXITCODE
			StdErr   = ((Get-Content -Raw -ErrorAction SilentlyContinue $errFile) ?? '')
		}
	}
	catch {
		# The program is not on this machine at all. NOT an exception to the
		# caller: "dkms is not installed" is a legitimate answer to "what is
		# the DKMS state", and an exception makes it indistinguishable from
		# "dkms is installed and something went wrong".
		return [pscustomobject]@{ StdOut = ''; ExitCode = 127; StdErr = [string]$_ }
	}
	finally {
		Remove-Item -Force -ErrorAction SilentlyContinue $errFile
	}
}

function Get-SysfsValue {
	<#
	.SYNOPSIS
		Internal. One sysfs attribute as a trimmed string, or $null.

	.DESCRIPTION
		$null RATHER THAN '' FOR AN ABSENT FILE, and the two are different
		questions: /sys/bus/usb/devices/usb1/modalias does not exist (measured),
		while an empty attribute that does exist means the kernel has nothing to
		say. Collapsing them makes "this device has no modalias" and "I did not
		look" the same value.

		Reads never throw. sysfs is full of attributes that exist and return
		EACCES, EIO or ENODEV to a reader — `config`, `resource`, `rescan` — and
		a listing that dies on one device it could not read is worse than one
		that reports that device with a gap.
	#>
	param([Parameter(Mandatory)][string]$Path)

	try {
		if (-not [System.IO.File]::Exists($Path)) { return $null }
		return ([System.IO.File]::ReadAllText($Path)).Trim()
	}
	catch { return $null }
}

function Get-SysfsLinkName {
	<#
	.SYNOPSIS
		Internal. The last element of a sysfs symlink's target, or $null.

	.DESCRIPTION
		THE TARGET IS READ, NOT FOLLOWED. `/sys/bus/pci/devices/0000:00:01.0/driver`
		points at `../../../../bus/pci/drivers/virtio-pci`; the name is the last
		element and resolving the path adds nothing but a way to fail. It also
		keeps the self-test honest — a tree built in a temp directory can carry
		a relative symlink whose target does not exist, which is a device whose
		driver name is readable and whose driver directory is not there.
	#>
	param([Parameter(Mandatory)][string]$Path)

	try {
		$item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
		if (-not $item.LinkTarget) { return $null }
		return (Split-Path -Leaf $item.LinkTarget)
	}
	catch { return $null }
}


# ---------------------------------------------------------------------------
# The names. Cosmetic, and separated from the enumeration for that reason.
# ---------------------------------------------------------------------------

function Import-PciIdDatabase {
	<#
	.SYNOPSIS
		Internal. pci.ids, parsed once, or $null if it is not on this machine.

	.DESCRIPTION
		THE FORMAT, measured against pci.ids 2026.02.12:

		    10de  NVIDIA Corporation          vendor, at column 0
		    \t2504  GA106 [GeForce RTX 3060]  device, ONE tab
		    \t\t1458 403E  Gaming OC          subsystem, TWO tabs
		    C 03  Display controller          a class, in the section after the
		    \t00  VGA compatible controller   vendors

		Two spaces separate the id from the name, and the name may contain
		anything including further spaces and brackets. Splitting on whitespace
		truncates every name with a space in it, which is nearly all of them.

		The class section is parsed too. It is the reason this file is worth
		reading at all for something other than vanity: `0300` is what sysfs
		says and "VGA compatible controller" is what a person needs, and the
		alternative is a 2000-line table in this repository that goes stale.
	#>
	if ($null -ne $script:PciIdCache) { return $script:PciIdCache }

	$path = $script:PciIdsPaths | Where-Object { [System.IO.File]::Exists($_) } | Select-Object -First 1
	if (-not $path) {
		# CACHED AS "looked, not there" rather than left $null, so that a
		# machine without the package does not stat three paths per device.
		$script:PciIdCache = [pscustomobject]@{
			Path = $null; Vendors = @{}; Devices = @{}; Classes = @{}
		}
		return $script:PciIdCache
	}

	$vendors = @{}
	$devices = @{}
	$classes = @{}
	$vendor = $null
	$class = $null
	$inClasses = $false

	foreach ($line in [System.IO.File]::ReadLines($path)) {
		if (-not $line -or $line[0] -eq '#') { continue }

		if ($line[0] -eq 'C' -and $line.Length -gt 2 -and $line[1] -eq ' ') {
			# "C 03  Display controller"
			$inClasses = $true
			$rest = $line.Substring(2)
			$i = $rest.IndexOf('  ')
			if ($i -gt 0) {
				$class = $rest.Substring(0, $i).ToLowerInvariant()
				$classes[$class] = $rest.Substring($i + 2).Trim()
			}
			continue
		}

		if ($line[0] -ne "`t") {
			$i = $line.IndexOf('  ')
			if ($i -gt 0) {
				$vendor = $line.Substring(0, $i).ToLowerInvariant()
				$vendors[$vendor] = $line.Substring($i + 2).Trim()
			}
			$inClasses = $false
			continue
		}

		if ($line.Length -gt 1 -and $line[1] -eq "`t") { continue }   # a subsystem; not kept

		$rest = $line.Substring(1)
		$i = $rest.IndexOf('  ')
		if ($i -lt 1) { continue }
		$id = $rest.Substring(0, $i).ToLowerInvariant()
		$name = $rest.Substring($i + 2).Trim()
		if ($inClasses) {
			if ($class) { $classes["$class$id"] = $name }
		}
		elseif ($vendor) {
			$devices["$vendor$id"] = $name
		}
	}

	$script:PciIdCache = [pscustomobject]@{
		Path = $path; Vendors = $vendors; Devices = $devices; Classes = $classes
	}
	return $script:PciIdCache
}

function Get-HardwareIdName {
	<#
	.SYNOPSIS
		The human name for a PCI vendor, device or class id.

	.DESCRIPTION
		$null WHEN IT IS NOT KNOWN, AND $null WHEN pci.ids IS NOT INSTALLED, and
		the caller is expected to fall back to the numbers rather than to invent
		a name. A device called "Unknown device" reads as a fault; a device
		called "PCI device 1af4:1042" reads as what it is.

	.PARAMETER VendorId
		Four lowercase hex digits, as sysfs reports them without the 0x.

	.PARAMETER DeviceId
		Four lowercase hex digits. Requires -VendorId: device ids are only
		unique within a vendor.

	.PARAMETER ClassId
		Two, four or six hex digits. Six is what sysfs reports; the last two are
		the programming interface and are dropped for the lookup.

	.EXAMPLE
		Get-HardwareIdName -VendorId 10de -DeviceId 2504
	#>
	[CmdletBinding()]
	param(
		[string]$VendorId,
		[string]$DeviceId,
		[string]$ClassId
	)

	$db = Import-PciIdDatabase
	if (-not $db.Path) { return $null }

	if ($ClassId) {
		$c = $ClassId.ToLowerInvariant()
		if ($c.StartsWith('0x')) { $c = $c.Substring(2) }
		$c = $c.PadLeft(6, '0')
		# Six digits are class, subclass and programming interface. pci.ids
		# knows the first four; the third pair is looked up as a sub-entry of
		# the second in the file and is not worth the third table.
		$four = $c.Substring(0, 4)
		if ($db.Classes.ContainsKey($four)) { return $db.Classes[$four] }
		$two = $c.Substring(0, 2)
		if ($db.Classes.ContainsKey($two)) { return $db.Classes[$two] }
		return $null
	}

	if (-not $VendorId) { return $null }
	$v = $VendorId.ToLowerInvariant()
	if ($v.StartsWith('0x')) { $v = $v.Substring(2) }

	if ($DeviceId) {
		$d = $DeviceId.ToLowerInvariant()
		if ($d.StartsWith('0x')) { $d = $d.Substring(2) }
		if ($db.Devices.ContainsKey("$v$d")) { return $db.Devices["$v$d"] }
		return $null
	}

	if ($db.Vendors.ContainsKey($v)) { return $db.Vendors[$v] }
	return $null
}


# ---------------------------------------------------------------------------
# Devices, from sysfs
# ---------------------------------------------------------------------------

function New-HardwareDeviceObject {
	<#
	.SYNOPSIS
		Internal. One device object, with every field present.

	.DESCRIPTION
		EVERY FIELD PRESENT, INCLUDING THE ONES THAT ARE $null. Under
		Set-StrictMode a property that was never added throws on access, so a
		device built by one branch and read by another would fail on exactly the
		field that branch did not happen to set — and USB and PCI genuinely have
		different attributes.
	#>
	param([hashtable]$Fields)

	$o = [ordered]@{
		Bus                = $null
		Address            = $null
		SysfsPath          = $null
		VendorId           = $null
		ProductId          = $null
		SubsystemVendorId  = $null
		SubsystemProductId = $null
		Class              = $null      # two hex digits: the base class
		SubClass           = $null      # two hex digits
		ClassName          = $null
		Modalias           = $null
		Driver             = $null
		DriverBoundTo      = $null      # WHERE it is bound. USB binds interfaces.
		Vendor             = $null
		Product            = $null
		Description        = $null
		Interfaces         = @()
	}
	foreach ($k in $Fields.Keys) { $o[$k] = $Fields[$k] }
	$obj = [pscustomobject]$o
	$obj.PSObject.TypeNames.Insert(0, 'Hardware.Device')
	return $obj
}

function Format-HardwareDescription {
	<#
	.SYNOPSIS
		Internal. The best human string available for a device, never $null.

	.DESCRIPTION
		FALLS BACK TO THE NUMBERS, never to a word like "Unknown". The numbers
		are what a person types into a search engine and what a support case
		needs; "Unknown device" is a sentence that has thrown away the only
		useful thing it had.
	#>
	param([string]$Vendor, [string]$Product, [string]$VendorId, [string]$ProductId, [string]$Bus)

	if ($Vendor -and $Product) { return "$Vendor $Product" }
	if ($Product) { return $Product }
	if ($Vendor) { return "$Vendor device ${VendorId}:${ProductId}" }
	return "$Bus device ${VendorId}:${ProductId}"
}

function Get-HardwarePciDevice {
	<#
	.SYNOPSIS
		Internal. The PCI devices under a sysfs root.
	#>
	param([string]$SysRoot)

	$dir = Join-Path $SysRoot 'bus/pci/devices'
	if (-not (Test-Path -LiteralPath $dir)) { return @() }

	$out = @()
	foreach ($entry in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
		$p = $entry.FullName
		$vendor = Get-SysfsValue (Join-Path $p 'vendor')
		$device = Get-SysfsValue (Join-Path $p 'device')
		# A device directory with no vendor is not a PCI device this module can
		# say anything about. Skipped rather than emitted with holes.
		if (-not $vendor -or -not $device) { continue }

		$vid = $vendor.Replace('0x', '').ToLowerInvariant()
		$pid = $device.Replace('0x', '').ToLowerInvariant()
		$cls = (Get-SysfsValue (Join-Path $p 'class'))
		$cls = if ($cls) { $cls.Replace('0x', '').ToLowerInvariant().PadLeft(6, '0') } else { $null }

		$sv = Get-SysfsValue (Join-Path $p 'subsystem_vendor')
		$sd = Get-SysfsValue (Join-Path $p 'subsystem_device')

		$vendorName = Get-HardwareIdName -VendorId $vid
		$productName = Get-HardwareIdName -VendorId $vid -DeviceId $pid
		$className = if ($cls) { Get-HardwareIdName -ClassId $cls } else { $null }
		if (-not $className -and $cls) { $className = $script:PciBaseClasses[$cls.Substring(0, 2)] }

		$driver = Get-SysfsLinkName (Join-Path $p 'driver')

		$out += New-HardwareDeviceObject @{
			Bus                = 'PCI'
			Address            = $entry.Name
			SysfsPath          = $p
			VendorId           = $vid
			ProductId          = $pid
			SubsystemVendorId  = $(if ($sv) { $sv.Replace('0x', '').ToLowerInvariant() } else { $null })
			SubsystemProductId = $(if ($sd) { $sd.Replace('0x', '').ToLowerInvariant() } else { $null })
			Class              = $(if ($cls) { $cls.Substring(0, 2) } else { $null })
			SubClass           = $(if ($cls) { $cls.Substring(2, 2) } else { $null })
			ClassName          = $className
			Modalias           = Get-SysfsValue (Join-Path $p 'modalias')
			Driver             = $driver
			DriverBoundTo      = $(if ($driver) { $entry.Name } else { $null })
			Vendor             = $vendorName
			Product            = $productName
			Description        = Format-HardwareDescription -Vendor $vendorName -Product $productName `
				-VendorId $vid -ProductId $pid -Bus 'PCI'
		}
	}
	return $out
}

function Get-HardwareUsbDevice {
	<#
	.SYNOPSIS
		Internal. The USB devices under a sysfs root, joined to their interfaces.

	.DESCRIPTION
		THE JOIN IS THE POINT. /sys/bus/usb/devices holds two kinds of entry and
		they carry different halves of the answer (measured):

		    usb1      idVendor=1d6b  idProduct=0002  driver=usb   modalias absent
		    1-0:1.0   no idVendor                    driver=hub   bInterfaceClass=09

		`<n>-<m>` is a device; `<n>-<m>:<c>.<i>` is an interface of it. A device
		manager that read only devices would report `driver=usb` — the bus
		driver, bound to every USB device that exists, which says nothing about
		whether the device works. One that read only interfaces would have no
		vendor or product to show.

		So the driver of a USB device is the driver of its INTERFACES, and a
		device whose interfaces have none is the unsupported case. A device with
		several interfaces bound to several drivers — a webcam is typically
		uvcvideo plus snd-usb-audio — reports the first and lists them all.
	#>
	param([string]$SysRoot)

	$dir = Join-Path $SysRoot 'bus/usb/devices'
	if (-not (Test-Path -LiteralPath $dir)) { return @() }

	$entries = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Sort-Object Name)
	$interfaces = @{}
	foreach ($e in $entries) {
		if ($e.Name -notmatch ':') { continue }
		$owner = $e.Name.Split(':')[0]
		# A ROOT HUB IS NAMED `usb1` AND ITS INTERFACE `1-0:1.0`. Every other
		# device agrees with its interfaces — `3-10` owns `3-10:1.0` — and the
		# root hubs are the one place the two naming schemes do not meet.
		# Measured: /sys/bus/usb/devices holds usb1, usb2, 1-0:1.0 and 2-0:1.0
		# on a machine with two buses and nothing plugged in. Miss this and
		# every controller on the machine reports no driver.
		if ($owner -match '^(\d+)-0$') { $owner = "usb$($Matches[1])" }
		if (-not $interfaces.ContainsKey($owner)) { $interfaces[$owner] = @() }
		$ic = Get-SysfsValue (Join-Path $e.FullName 'bInterfaceClass')
		$interfaces[$owner] += [pscustomobject]@{
			Address  = $e.Name
			Driver   = Get-SysfsLinkName (Join-Path $e.FullName 'driver')
			Class    = $(if ($ic) { $ic.ToLowerInvariant() } else { $null })
			Modalias = Get-SysfsValue (Join-Path $e.FullName 'modalias')
		}
	}

	$out = @()
	foreach ($e in $entries) {
		if ($e.Name -match ':') { continue }
		$p = $e.FullName
		$vid = Get-SysfsValue (Join-Path $p 'idVendor')
		$pid = Get-SysfsValue (Join-Path $p 'idProduct')
		if (-not $vid -or -not $pid) { continue }
		$vid = $vid.ToLowerInvariant()
		$pid = $pid.ToLowerInvariant()

		$ifs = @($(if ($interfaces.ContainsKey($e.Name)) { $interfaces[$e.Name] } else { @() }))
		$bound = @($ifs | Where-Object { $_.Driver }) | Select-Object -First 1

		$dc = Get-SysfsValue (Join-Path $p 'bDeviceClass')
		$dc = $(if ($dc) { $dc.ToLowerInvariant() } else { $null })
		# bDeviceClass 00 means "the interfaces decide", which is most devices.
		$effective = if ($dc -and $dc -ne '00') { $dc }
			elseif ($ifs.Count -and $ifs[0].Class) { $ifs[0].Class }
			else { $dc }
		$className = $(if ($effective -and $script:UsbClasses.ContainsKey($effective)) {
				$script:UsbClasses[$effective] } else { $null })

		# A USB DEVICE NAMES ITSELF. `manufacturer` and `product` are strings the
		# device reported, which beats a database — and usb.ids is not shipped on
		# this distribution at all (measured), so there is no database to beat.
		$vendorName = Get-SysfsValue (Join-Path $p 'manufacturer')
		$productName = Get-SysfsValue (Join-Path $p 'product')

		$modalias = Get-SysfsValue (Join-Path $p 'modalias')
		if (-not $modalias -and $ifs.Count) { $modalias = $ifs[0].Modalias }

		$out += New-HardwareDeviceObject @{
			Bus           = 'USB'
			Address       = $e.Name
			SysfsPath     = $p
			VendorId      = $vid
			ProductId     = $pid
			Class         = $effective
			SubClass      = Get-SysfsValue (Join-Path $p 'bDeviceSubClass')
			ClassName     = $className
			Modalias      = $modalias
			Driver        = $(if ($bound) { $bound.Driver } else { $null })
			DriverBoundTo = $(if ($bound) { $bound.Address } else { $null })
			Vendor        = $vendorName
			Product       = $productName
			Interfaces    = $ifs
			Description   = Format-HardwareDescription -Vendor $vendorName -Product $productName `
				-VendorId $vid -ProductId $pid -Bus 'USB'
		}
	}
	return $out
}

function Get-HardwareDevice {
	<#
	.SYNOPSIS
		The PCI and USB devices on this machine, and the module bound to each.

	.DESCRIPTION
		READ FROM SYSFS, NOT FROM lspci. Three reasons, the first two measured
		on 2026-08-27:

		  * `lspci -mm -vkn` printed `lspci: Unable to load libkmod resources:
		    error -2` and then omitted every `Module:` line — the half of its
		    output that says which drivers COULD handle a device — while still
		    printing `Driver:` and still exiting 0.
		  * pciutils is a package. A minimal image does not have it, and the
		    question "is a driver bound to this device" has to be answerable
		    exactly when the machine is in a poor state.
		  * /sys/bus/pci is the kernel's own answer and lspci is a formatter
		    over it. docs/POWERSHELL-SURFACE-PLAN.md P5: ask the thing itself.

		`Driver` is the module bound to the device, or $null. For USB it is the
		driver of the device's INTERFACES and never the `usb` bus driver, which
		is bound to every USB device that exists and means nothing.

		`Vendor` and `Product` are $null when they cannot be resolved — pci.ids
		is a package too — and `Description` is never $null: it falls back to
		the ids, which are what a support case and a search engine both want.

	.PARAMETER Bus
		`PCI` or `USB`. Both by default.

	.PARAMETER Root
		Read a different filesystem's sysfs — a mounted image, or a tree built
		by a test. Defaults to this machine.

	.EXAMPLE
		Get-HardwareDevice | Where-Object { -not $_.Driver }

	.EXAMPLE
		Get-HardwareDevice -Bus USB | Format-Table Address, Description, Driver
	#>
	[CmdletBinding()]
	param(
		[ValidateSet('PCI', 'USB')][string]$Bus,
		[string]$Root = ''
	)

	$sysRoot = if ($Root -and $Root -ne '/') { (Join-Path $Root 'sys') } else { '/sys' }

	$out = @()
	if (-not $Bus -or $Bus -eq 'PCI') { $out += @(Get-HardwarePciDevice -SysRoot $sysRoot) }
	if (-not $Bus -or $Bus -eq 'USB') { $out += @(Get-HardwareUsbDevice -SysRoot $sysRoot) }
	return $out
}


# ---------------------------------------------------------------------------
# Kernel modules
# ---------------------------------------------------------------------------

function Get-KernelModule {
	<#
	.SYNOPSIS
		The modules loaded into the running kernel.

	.DESCRIPTION
		From /proc/modules, which is the kernel's own list, rather than from
		`lsmod` — which is a formatter over exactly that file and is a package.

		The format is `name size refcount users state address`, and `users` is a
		comma-separated list or `-`. MEASURED: on some kernels `refcount` and
		`users` are both `-`, so neither may be parsed as a number without a
		fallback.

	.PARAMETER Name
		One module, or a glob.

	.PARAMETER Root
		Read a different filesystem's /proc. Only useful for a test tree; a
		chroot shares the running kernel's /proc and would give the same answer.
	#>
	[CmdletBinding()]
	param(
		[string]$Name,
		[string]$Root = ''
	)

	$path = if ($Root -and $Root -ne '/') { (Join-Path $Root 'proc/modules') } else { '/proc/modules' }
	if (-not [System.IO.File]::Exists($path)) { return @() }

	$out = @()
	foreach ($line in [System.IO.File]::ReadLines($path)) {
		$f = $line.Split(' ')
		if ($f.Count -lt 4) { continue }
		if ($Name -and $f[0] -notlike $Name) { continue }
		$size = 0L
		[void][long]::TryParse($f[1], [System.Globalization.NumberStyles]::Integer,
			[System.Globalization.CultureInfo]::InvariantCulture, [ref]$size)
		$refs = $null
		$n = 0
		if ([int]::TryParse($f[2], [System.Globalization.NumberStyles]::Integer,
				[System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { $refs = $n }
		$o = [pscustomobject]@{
			Name       = $f[0]
			SizeBytes  = $size
			References = $refs
			UsedBy     = @($(if ($f[3] -and $f[3] -ne '-') { $f[3].Trim(',').Split(',') } else { @() }))
			State      = $(if ($f.Count -ge 5) { $f[4] } else { $null })
		}
		$o.PSObject.TypeNames.Insert(0, 'Hardware.KernelModule')
		$out += $o
	}
	return $out
}

function Resolve-KernelModule {
	<#
	.SYNOPSIS
		Which modules claim a modalias — $null when the question could not be
		asked at all.

	.DESCRIPTION
		THE TWO FAILURES ARE NOT THE SAME, AND modprobe GIVES THEM THE SAME EXIT
		CODE. Measured on a machine whose running kernel has no modules
		directory:

		    modprobe -R pci:v00001AF4d00001041sv…
		    modprobe: FATAL: Module pci:v00001AF4d00001041sv… not found in
		              directory /lib/modules/7.0.12-linuxkit

		That is "there is no modules.alias to consult", and it is worded exactly
		like "nothing claims this alias" — which is also a FATAL with the same
		exit code. Treating the first as the second would report every device on
		such a machine as having no driver available, which is the report that
		would send somebody looking for hardware faults on a working computer.

		So: $null means the question could not be answered. An empty array means
		it was answered and nothing claims the alias. They are different values
		and every caller has to choose.

	.PARAMETER Modalias
		The device's modalias, as sysfs reports it.

	.PARAMETER Kernel
		Ask about a kernel other than the running one — `modprobe -S`. This is
		how an update finds out whether the environment it just built has a
		driver for a device.

	.PARAMETER Root
		Ask inside a chroot.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Modalias,
		[string]$Kernel,
		[string]$Root = ''
	)

	$argv = @()
	if ($Kernel) { $argv += @('-S', $Kernel) }
	$argv += @('-R', $Modalias)

	$r = Invoke-HardwareCommand -Command 'modprobe' -Arguments $argv -Root $Root

	if ($r.ExitCode -eq 0) {
		# `,` BEFORE THE ARRAY, AND IT IS NOT A TYPO. A PowerShell function
		# returning an array UNROLLS it on the way out: an empty one becomes
		# $null — collapsing the two answers this whole function exists to keep
		# apart — and a one-element one becomes a STRING, so the caller's [0]
		# indexes into it and yields a character. That second half is
		# BUILD-NOTES #92, and writing this function walked straight into both.
		return , @($r.StdOut -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
	}

	# THE DISCRIMINATOR IS THE WORD "directory". modprobe says "not found in
	# directory /lib/modules/<k>" when there is no index for that kernel, and
	# "not found" without it when the index exists and has no match. Fragile,
	# and named as such — but the alternative is to conflate an unanswerable
	# question with an answer, which is the failure this whole function exists
	# to avoid. The index file is checked as well so that the text is not the
	# only evidence.
	$text = ($r.StdErr + "`n" + $r.StdOut)
	if ($text -match 'not found in directory') { return $null }
	if ($r.ExitCode -eq 127) { return $null }        # no modprobe on this machine
	if ($text -match 'FATAL' -or $r.ExitCode -eq 1) { return , @() }
	return $null
}


function Add-KernelModule {
	<#
	.SYNOPSIS
		Load a kernel module, and then ask /proc/modules whether it is loaded.

	.DESCRIPTION
		ASKS AFTERWARDS, because `modprobe` EXITS 0 FOR A MODULE THAT LOADED AND
		IMMEDIATELY UNLOADED ITSELF. A module whose `init` returns an error is
		refused with a non-zero exit, but one that loads, finds no hardware it
		can claim and removes itself is a successful modprobe and an absent
		module. That is the standing rule in docs/BUILD-NOTES.md — a program
		reported success and the thing it was meant to change did not change.

	.PARAMETER Name
		The module to load.

	.PARAMETER Root
		Load inside a chroot. Rarely what you want: the kernel is the host's.

	.EXAMPLE
		Add-KernelModule -Name e1000e
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	param(
		[Parameter(Mandatory)][string]$Name,
		[string]$Root = ''
	)

	if (-not $PSCmdlet.ShouldProcess($Name, 'load the kernel module')) { return $null }

	$r = Invoke-HardwareCommand -Command 'modprobe' -Arguments @($Name) -Root $Root
	$loaded = @(Get-KernelModule -Name $Name -Root $Root).Count -gt 0

	$o = [pscustomobject]@{
		Name     = $Name
		Loaded   = $loaded
		ExitCode = $r.ExitCode
		Output   = ($r.StdErr + $r.StdOut).Trim()
	}
	$o.PSObject.TypeNames.Insert(0, 'Hardware.KernelModuleLoadResult')
	return $o
}


# ---------------------------------------------------------------------------
# DKMS
#
# READ THE MEASUREMENTS AT THE TOP OF THIS FILE BEFORE CHANGING ANYTHING HERE.
# Points 1 to 4 are all about this section, and each of them is a way of
# getting a confident wrong answer out of `dkms status`.
# ---------------------------------------------------------------------------

function ConvertFrom-DkmsStatus {
	<#
	.SYNOPSIS
		`dkms status` output as objects — one per module and version, with the
		kernels it is built for.

	.DESCRIPTION
		PUBLIC ON PURPOSE. A caller holding `dkms status` output taken from
		somewhere this module cannot reach — the chroot an update has assembled,
		a support bundle, a log — must not have to write a second parser for it.
		BUILD-NOTES #66 is what a second parser of the same thing costs.

		TWO LINE SHAPES, and dkms emits both from one invocation (measured
		against dkms 3.2.2):

		    bad/3.0: added
		    good/1.0, 7.0.0-30-generic, aarch64: installed

		The first has no kernel and no architecture. It does not mean "for every
		kernel" — it means dkms answered without reference to any kernel, which
		for `added` is all it can say.

		`Kernels` is the list of (kernel, architecture, status) rows for that
		module and version, and it is EMPTY for a module that is only `added`.
		Empty is the answer that matters: it is what a module whose build failed
		looks like, because `dkms status` has no word for a failed build.

	.PARAMETER Text
		The output of `dkms status`.

	.EXAMPLE
		ConvertFrom-DkmsStatus -Text (dkms status | Out-String)
	#>
	[CmdletBinding()]
	param([AllowEmptyString()][AllowNull()][string]$Text)

	if (-not $Text) { return @() }

	$byModule = [ordered]@{}
	foreach ($raw in ($Text -split "`n")) {
		$line = $raw.Trim()
		if (-not $line) { continue }
		# Anything that is not "<something>: <word>" is not a status row. dkms
		# prints warnings and deprecation notices on stdout too.
		$colon = $line.LastIndexOf(': ')
		if ($colon -lt 1) { continue }
		$left = $line.Substring(0, $colon)
		$status = $line.Substring($colon + 2).Trim()
		if ($status -notin @('added', 'built', 'installed')) { continue }

		$parts = @($left -split ',' | ForEach-Object { $_.Trim() })
		$nv = $parts[0]
		$slash = $nv.LastIndexOf('/')
		if ($slash -lt 1) { continue }
		$name = $nv.Substring(0, $slash)
		$version = $nv.Substring($slash + 1)

		$key = "$name/$version"
		if (-not $byModule.Contains($key)) {
			$o = [pscustomobject]@{
				Name    = $name
				Version = $version
				Kernels = @()
			}
			$o.PSObject.TypeNames.Insert(0, 'Hardware.DkmsModule')
			$byModule[$key] = $o
		}

		if ($parts.Count -ge 3) {
			$byModule[$key].Kernels += [pscustomobject]@{
				Kernel       = $parts[1]
				Architecture = $parts[2]
				Status       = $status
			}
		}
	}

	return @($byModule.Values)
}

function Get-DkmsModule {
	<#
	.SYNOPSIS
		The DKMS modules registered on a machine, and which kernels each is
		actually installed for.

	.DESCRIPTION
		DO NOT PASS -Kernel TO dkms AND BELIEVE THE ANSWER. `dkms status -k
		<kernel>` does not filter by kernel; asked about a kernel with no builds
		at all it lists every module in the `added` shape and exits 0, which
		reads as three healthy modules (measured, dkms 3.2.2). So -Kernel here
		is applied by THIS function, to the parsed rows, and never handed to
		dkms.

		`InstalledFor` is the list of kernels with an `installed` row. It is the
		only field that means the driver will load: `built` is a module that
		compiled and was never copied into /lib/modules, so it is not there and
		will not load, and `added` is a module that may have been built and
		FAILED — dkms has no word for that and reports it identically to one
		nobody has tried.

	.PARAMETER Name
		One module, or a glob.

	.PARAMETER Kernel
		Keep only modules that have a row for this kernel, filtered here.

	.PARAMETER Root
		Ask dkms inside a chroot — the environment an update has assembled,
		rather than the one this process is running in.

	.EXAMPLE
		Get-DkmsModule

	.EXAMPLE
		Get-DkmsModule -Root /run/os7-update | Where-Object { '6.14.0-35-generic' -notin $_.InstalledFor }
	#>
	[CmdletBinding()]
	param(
		[string]$Name,
		[string]$Kernel,
		[string]$Root = ''
	)

	$r = Invoke-HardwareCommand -Command 'dkms' -Arguments @('status') -Root $Root

	# dkms IS NOT INSTALLED is a real answer and not an error. A machine with no
	# out-of-tree drivers has no dkms and nothing to report, and that must not
	# read the same as a machine where the question failed.
	if ($r.ExitCode -eq 127) { return @() }
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"dkms status exited $($r.ExitCode).`n$($r.StdErr)$($r.StdOut)")
	}

	$mods = @(ConvertFrom-DkmsStatus -Text $r.StdOut)

	foreach ($m in $mods) {
		Add-Member -InputObject $m -NotePropertyName 'InstalledFor' `
			-NotePropertyValue @($m.Kernels | Where-Object { $_.Status -eq 'installed' } |
				ForEach-Object { $_.Kernel })
		Add-Member -InputObject $m -NotePropertyName 'BuiltFor' `
			-NotePropertyValue @($m.Kernels | Where-Object { $_.Status -eq 'built' } |
				ForEach-Object { $_.Kernel })
	}

	if ($Name) { $mods = @($mods | Where-Object { $_.Name -like $Name }) }
	if ($Kernel) {
		# FILTERED HERE, NEVER BY dkms -k. See the description.
		$mods = @($mods | Where-Object { $Kernel -in @($_.Kernels.Kernel) })
	}
	return $mods
}

function Invoke-DkmsBuild {
	<#
	.SYNOPSIS
		Build and install a DKMS module for a kernel, then ask dkms whether it
		worked.

	.DESCRIPTION
		THE EXIT CODE NAMES THE RUN AND NEVER A MODULE. Measured: with three
		modules of which one cannot compile, `dkms autoinstall` installed the
		two that could, printed "succeeded for module(s) good half" and "failed
		for module(s) bad(10)", and exited 11. A caller that stopped at the exit
		code would report a total failure that was two thirds a success — or,
		with -Name, would trust a 0 that belonged to a different module.

		So this reads the status back afterwards and reports `Installed` from
		that, not from the exit code. The standing rule in docs/BUILD-NOTES.md:
		ask the thing itself.

		Exit codes seen, recorded here because dkms documents none of them:
		    0   everything asked for was installed
		    10  a module failed to compile
		    11  autoinstall: at least one module failed
		    21  no kernel headers for the requested kernel

	.PARAMETER Name
		One module. Without it, `dkms autoinstall` — every module that declares
		AUTOINSTALL.

	.PARAMETER Version
		Required with -Name.

	.PARAMETER Kernel
		The kernel to build for. Defaults to dkms's own default, which is the
		running one.

	.PARAMETER Root
		Build inside a chroot.

	.EXAMPLE
		Invoke-DkmsBuild -Name zfs -Version 2.3.4 -Kernel 6.14.0-35-generic
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	param(
		[string]$Name,
		[string]$Version,
		[string]$Kernel,
		[string]$Root = ''
	)

	if ($Name -and -not $Version) {
		throw [System.ArgumentException]::new(
			'-Version is required with -Name: DKMS registers a module once per version, ' +
			'and a machine can hold two versions of the same module at once.')
	}

	$argv = if ($Name) { @('install', '-m', $Name, '-v', $Version) } else { @('autoinstall') }
	if ($Kernel) { $argv += @('-k', $Kernel) }

	$target = if ($Name) { "$Name/$Version" } else { 'every autoinstall module' }
	$forK = if ($Kernel) { " for $Kernel" } else { '' }
	if (-not $PSCmdlet.ShouldProcess("dkms $($argv -join ' ')", "build and install $target$forK")) {
		return $null
	}

	$before = @(Get-DkmsModule -Root $Root)
	$r = Invoke-HardwareCommand -Command 'dkms' -Arguments $argv -Root $Root
	$after = @(Get-DkmsModule -Root $Root)

	$wanted = if ($Name) { @($after | Where-Object { $_.Name -eq $Name -and $_.Version -eq $Version }) }
		else { $after }

	# INSTALLED IS ASKED OF dkms, NOT INFERRED FROM THE EXIT CODE.
	$installed = @()
	$stillNot = @()
	foreach ($m in $wanted) {
		$k = if ($Kernel) { $Kernel } else { $null }
		$rows = @($m.Kernels | Where-Object { -not $k -or $_.Kernel -eq $k })
		if (@($rows | Where-Object { $_.Status -eq 'installed' }).Count -gt 0) {
			$installed += "$($m.Name)/$($m.Version)"
		}
		else {
			$stillNot += "$($m.Name)/$($m.Version)"
		}
	}

	$o = [pscustomobject]@{
		Kernel       = $Kernel
		ExitCode     = $r.ExitCode
		Installed    = $installed
		NotInstalled = $stillNot
		Succeeded    = ($stillNot.Count -eq 0 -and $installed.Count -gt 0)
		Output       = ($r.StdOut + $(if ($r.StdErr) { "`n" + $r.StdErr } else { '' })).Trim()
		Before       = $before
		After        = $after
	}
	$o.PSObject.TypeNames.Insert(0, 'Hardware.DkmsBuildResult')
	return $o
}


# ---------------------------------------------------------------------------
# ubuntu-drivers — WRAPPED, NOT REIMPLEMENTED
#
# Deciding that an NVIDIA card would do more with nvidia-driver-570 than with
# nouveau is a data problem: a table of modalias patterns against package names,
# maintained per release, kept current as cards appear. Ubuntu maintains it and
# ships it in ubuntu-drivers-common. Rebuilding that here would mean shipping a
# copy of it that goes stale, on a product whose whole delivery model is a
# curated release train. So this parses ubuntu-drivers' answer and adds nothing.
# ---------------------------------------------------------------------------

function ConvertFrom-UbuntuDriversDevices {
	<#
	.SYNOPSIS
		`ubuntu-drivers devices` output as objects.

	.DESCRIPTION
		IT REFUSES TEXT THAT IS NOT A DEVICE LIST, and that is the whole reason
		this is a named function rather than four lines inline. Measured:

		    $ ubuntu-drivers list
		    Your running kernel (7.0.12-linuxkit) requires DKMS modules, and
		    ubuntu-drivers was unable to determine if Secure Boot is enabled…
		    Please use --include-dkms if you want to proceed.

		— on stdout. A parser that looked for `driver :` lines and found none
		would return zero devices, and zero devices from this command means "no
		better driver exists for anything on this machine". The tool declining
		to answer would have become a confident answer of no.

		So: text with no `== <path> ==` header at all is a refusal, and this
		throws rather than returning an empty list. An empty STRING is a real
		empty list — that is what a machine with no proprietary-driver
		candidates prints, and it was measured too.

		THE SHAPE:

		    == /sys/devices/pci0000:00/0000:01:00.0 ==
		    modalias : pci:v000010DEd00002504sv00001458sd0000403Ebc03sc00i00
		    vendor   : NVIDIA Corporation
		    model    : GA106 [GeForce RTX 3060 Lite Hash Rate]
		    driver   : nvidia-driver-535 - distro non-free
		    driver   : nvidia-driver-570-open - distro non-free recommended
		    driver   : xserver-xorg-video-nouveau - distro free builtin

		`builtin` MATTERS AND IS NOT A DETAIL. It marks a driver that is already
		in the kernel — offering to install it is offering to install something
		the machine has. A device manager that recommended `builtin` entries
		would tell an operator to fix a device that is not broken.

	.PARAMETER Text
		The output of `ubuntu-drivers devices`.
	#>
	[CmdletBinding()]
	param([AllowEmptyString()][AllowNull()][string]$Text)

	if ($null -eq $Text -or $Text.Trim() -eq '') { return @() }

	if ($Text -notmatch '(?m)^\s*==\s') {
		throw [System.InvalidOperationException]::new(
			"ubuntu-drivers did not return a device list. It printed:`n" +
			$Text.Trim() +
			"`nThis is the tool declining to answer, not an answer of none.")
	}

	$out = @()
	$cur = $null
	foreach ($raw in ($Text -split "`n")) {
		$line = $raw.TrimEnd()
		if ($line -match '^\s*==\s*(.+?)\s*==\s*$') {
			if ($cur) { $out += $cur }
			$o = [pscustomobject]@{
				SysfsPath = $Matches[1]
				Modalias  = $null
				Vendor    = $null
				Model     = $null
				Drivers   = @()
			}
			$o.PSObject.TypeNames.Insert(0, 'Hardware.UbuntuDriverDevice')
			$cur = $o
			continue
		}
		if (-not $cur) { continue }

		$i = $line.IndexOf(':')
		if ($i -lt 1) { continue }
		$key = $line.Substring(0, $i).Trim().ToLowerInvariant()
		$value = $line.Substring($i + 1).Trim()

		switch ($key) {
			'modalias' { $cur.Modalias = $value }
			'vendor' { $cur.Vendor = $value }
			'model' { $cur.Model = $value }
			'driver' {
				# "<package> - <flags…>". Split on the FIRST ' - ' only: a
				# package name cannot contain a space, and the flag text can.
				$dash = $value.IndexOf(' - ')
				$pkg = if ($dash -gt 0) { $value.Substring(0, $dash).Trim() } else { $value.Trim() }
				$flags = if ($dash -gt 0) { $value.Substring($dash + 3).Trim() } else { '' }
				$tokens = @($flags -split '\s+' | Where-Object { $_ })
				$d = [pscustomobject]@{
					Package     = $pkg
					Flags       = $tokens
					Source      = $(if ('third-party' -in $tokens) { 'third-party' }
						elseif ('distro' -in $tokens) { 'distro' } else { $null })
					Free        = $(if ('non-free' -in $tokens) { $false }
						elseif ('free' -in $tokens) { $true } else { $null })
					Recommended = ('recommended' -in $tokens)
					Builtin     = ('builtin' -in $tokens)
				}
				$d.PSObject.TypeNames.Insert(0, 'Hardware.UbuntuDriver')
				$cur.Drivers += $d
			}
		}
	}
	if ($cur) { $out += $cur }
	return $out
}

function Get-UbuntuDriver {
	<#
	.SYNOPSIS
		The driver packages ubuntu-drivers offers for the devices on this
		machine.

	.DESCRIPTION
		$null — NOT AN EMPTY LIST — WHEN THE TOOL IS NOT INSTALLED. A machine
		without ubuntu-drivers-common cannot answer "is there a better driver
		for this card", and an empty list is the answer "no, there is not".
		Making those the same value is how a device manager tells somebody with
		an NVIDIA card that nouveau is the best they can do.

		The caller has to handle $null. That is deliberate and it is
		docs/POWERSHELL-SURFACE-PLAN.md P5's rule stated as a return value.

	.PARAMETER Root
		Ask inside a chroot.

	.EXAMPLE
		(Get-UbuntuDriver) ?? 'ubuntu-drivers is not installed'
	#>
	[CmdletBinding()]
	param([string]$Root = '')

	$r = Invoke-HardwareCommand -Command 'ubuntu-drivers' -Arguments @('devices') -Root $Root
	if ($r.ExitCode -eq 127) { return $null }
	if ($r.ExitCode -ne 0 -and -not $r.StdOut) {
		throw [System.InvalidOperationException]::new(
			"ubuntu-drivers devices exited $($r.ExitCode).`n$($r.StdErr)")
	}
	return @(ConvertFrom-UbuntuDriversDevices -Text $r.StdOut)
}

function Install-UbuntuDriver {
	<#
	.SYNOPSIS
		Install a driver package through ubuntu-drivers, then ask dpkg whether
		it is there.

	.DESCRIPTION
		ASKS dpkg AFTERWARDS. `ubuntu-drivers install` drives apt, and apt exits
		0 in cases where the package asked for is not the package installed —
		the standing rule in docs/BUILD-NOTES.md, and the one OS7.Update.ps1
		follows at every apt step for the same reason.

	.PARAMETER Package
		The package to install. Without it, `ubuntu-drivers autoinstall` — the
		recommended driver for every device that has one.

	.PARAMETER Root
		Install inside a chroot.

	.EXAMPLE
		Install-UbuntuDriver -Package nvidia-driver-570 -WhatIf
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[string]$Package,
		[string]$Root = ''
	)

	$argv = if ($Package) { @('install', $Package) } else { @('autoinstall') }
	$what = if ($Package) { $Package } else { 'the recommended driver for every device' }
	if (-not $PSCmdlet.ShouldProcess("ubuntu-drivers $($argv -join ' ')", "install $what")) {
		return $null
	}

	$r = Invoke-HardwareCommand -Command 'ubuntu-drivers' -Arguments $argv -Root $Root

	$installed = $null
	if ($Package) {
		$q = Invoke-HardwareCommand -Command 'dpkg-query' `
			-Arguments @('-W', '-f=${Status}', $Package) -Root $Root
		$installed = ($q.ExitCode -eq 0 -and $q.StdOut -match 'install ok installed')
	}

	$o = [pscustomobject]@{
		Package   = $Package
		ExitCode  = $r.ExitCode
		Installed = $installed
		Output    = ($r.StdOut + $(if ($r.StdErr) { "`n" + $r.StdErr } else { '' })).Trim()
	}
	$o.PSObject.TypeNames.Insert(0, 'Hardware.DriverInstallResult')
	return $o
}


# ---------------------------------------------------------------------------
# hw-probe — the only thing in this repository that sends anything anywhere
# ---------------------------------------------------------------------------

function Wait-UdevSettle {
	<#
	.SYNOPSIS
		Wait for udev to finish acting on the events already in its queue.

	.DESCRIPTION
		`udevadm settle` is the one thing every script that has just changed a
		disk, a partition table or a device binding needs, and it belongs here
		rather than beside the thing that changed: it is a question about the
		kernel's device queue, which is this module's subject, and putting it
		in two callers is how two callers end up waiting differently.

		IT NEVER THROWS. `udevadm settle` times out (exit 1) on a busy machine
		and udevadm is absent in a container, and neither is a reason to fail
		the operation that called it — the wait is an optimisation, not a
		guarantee. The exit code is returned so a caller that does care can look.

	.PARAMETER TimeoutSeconds
		udevadm's own default is 120, which is a long time to block a cmdlet.

	.PARAMETER Root
		Settle inside a chroot.
	#>
	[CmdletBinding()]
	param(
		[int]$TimeoutSeconds = 30,
		[string]$Root = ''
	)

	$r = Invoke-HardwareCommand -Command 'udevadm' `
		-Arguments @('settle', "--timeout=$TimeoutSeconds") -Root $Root
	return [pscustomobject]@{
		Settled  = ($r.ExitCode -eq 0)
		ExitCode = $r.ExitCode
	}
}

function Install-HwProbe {
	<#
	.SYNOPSIS
		Install hw-probe from Ubuntu universe, and ask afterwards whether it is
		there.

	.DESCRIPTION
		SEPARATE FROM Send-HwProbe, AND THAT IS THE DESIGN. Getting the tool and
		using the tool are two decisions, and the second one uploads. A single
		cmdlet that installed and sent would make the install the moment
		somebody agreed to both.

		hw-probe is NOT on an OS/7 image. It is in universe, and a managed image
		does not ship a tool that uploads to a third party.

		ASKS dpkg — no: asks the FILESYSTEM, through Get-HwProbe, which looks for
		the binary rather than running it. apt exits 0 in cases where the package
		asked for is not the package installed, and the question here is whether
		the program exists.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	param([string]$Root = '')

	if ((Get-HwProbe -Root $Root).Installed) { return Get-HwProbe -Root $Root }
	if (-not $PSCmdlet.ShouldProcess('hw-probe', 'install from Ubuntu universe')) { return $null }

	$null = Invoke-HardwareCommand -Command 'apt-get' `
		-Arguments @('install', '-y', 'hw-probe') -Root $Root
	return Get-HwProbe -Root $Root
}

function Get-HwProbe {
	<#
	.SYNOPSIS
		Whether hw-probe is on this machine, and where it would send.

	.DESCRIPTION
		A READ, and it transmits nothing. It exists so that the device manager
		can offer the Linux Hardware Database honestly: naming a cmdlet that
		would fail because a package is missing is not an offer.

		IT DOES NOT RUN hw-probe. It looks for the file. The first version of
		this ran `hw-probe --version` to find out whether the tool was there,
		which meant that Get-OS7DeviceStatus — a read-only report an operator
		might run on a schedule — EXECUTED the upload tool every time, and
		installer/testing/check-device-logic.py failed on exactly that. Nothing
		bad would have happened; `--version` sends nothing. But the boundary
		this feature is built around is that the tool runs when a person runs
		it, and a boundary with an exception in it is not one.

		`Version` is therefore $null unless -Version is asked for, and asking
		for it does execute the tool.

	.PARAMETER Version
		Also read the tool's version, which requires running it.

	.PARAMETER Root
		Ask inside a chroot.
	#>
	[CmdletBinding()]
	param(
		[switch]$Version,
		[string]$Root = ''
	)

	$base = if ($Root -and $Root -ne '/') { $Root.TrimEnd('/') } else { '' }
	$present = $false
	foreach ($d in @('/usr/bin', '/usr/local/bin', '/bin', '/usr/sbin', '/sbin')) {
		if ([System.IO.File]::Exists("$base$d/hw-probe")) { $present = $true; break }
	}

	# $reportedVersion, NOT $version. `$version` IS the `-Version` parameter —
	# PowerShell variable names are case-insensitive — and it is a [switch], so
	# assigning a string to it coerces to $true and assigning $null coerces to
	# $false. The object would then have carried False where the version goes.
	# BUILD-NOTES #65, found here by installer/testing/check-ps-traps.py.
	$reportedVersion = $null
	if ($present -and $Version) {
		$r = Invoke-HardwareCommand -Command 'hw-probe' -Arguments @('--version') -Root $Root
		$reportedVersion = (@($r.StdOut -split "`n" | Where-Object { $_.Trim() }) | Select-Object -First 1)?.Trim()
	}

	$o = [pscustomobject]@{
		Installed   = $present
		Version     = $reportedVersion
		Package     = 'hw-probe'
		Component   = 'universe'
		Destination = 'https://linux-hardware.org/'
	}
	$o.PSObject.TypeNames.Insert(0, 'Hardware.HwProbe')
	return $o
}

function Send-HwProbe {
	<#
	.SYNOPSIS
		Run hw-probe and UPLOAD the result to linux-hardware.org.

	.DESCRIPTION
		THIS FUNCTION TRANSMITS A DESCRIPTION OF THE MACHINE TO A THIRD PARTY.
		It is the only one in this repository that does, nothing calls it, and
		it is not reached by any status, health or inventory cmdlet. It runs
		when a person runs it.

		hw-probe strips and hashes serial numbers, MAC addresses and hostnames
		before it sends — its own documentation says so — and this function does
		not verify that claim and does not repeat it as though it had. What it
		does instead is put the whole thing behind ShouldProcess at
		ConfirmImpact High, so that -WhatIf prints the command and the
		destination and sends nothing.

		The upload is public and permanent. A probe cannot be withdrawn.

	.PARAMETER Root
		Run inside a chroot. Almost certainly wrong for this cmdlet — a probe of
		an assembled update environment describes that environment — and here
		only because every other function in this module has it.

	.EXAMPLE
		Send-HwProbe -WhatIf
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param([string]$Root = '')

	$state = Get-HwProbe -Root $Root
	if (-not $state.Installed) {
		throw [System.InvalidOperationException]::new(
			'hw-probe is not installed. It is in Ubuntu universe: ' +
			'apt install hw-probe. Nothing has been sent.')
	}

	if (-not $PSCmdlet.ShouldProcess(
			'linux-hardware.org',
			'UPLOAD a description of this machine''s hardware, publicly and permanently')) {
		return [pscustomobject]@{ Uploaded = $false; Url = $null; Output = $null }
	}

	$r = Invoke-HardwareCommand -Command 'hw-probe' -Arguments @('-all', '-upload') -Root $Root
	$text = ($r.StdOut + "`n" + $r.StdErr)

	# The probe URL is what the operator actually wants back, and hw-probe
	# prints it as "Probe URL: https://linux-hardware.org/?probe=<id>".
	$url = $null
	if ($text -match 'https?://[^\s]*linux-hardware\.org[^\s]*') { $url = $Matches[0].TrimEnd('.', ',') }

	$o = [pscustomobject]@{
		# UPLOADED IS THE URL COMING BACK, not the exit code. hw-probe exits 0
		# for a probe it collected and could not send.
		Uploaded = ($null -ne $url)
		Url      = $url
		ExitCode = $r.ExitCode
		Output   = $text.Trim()
	}
	$o.PSObject.TypeNames.Insert(0, 'Hardware.HwProbeResult')
	return $o
}


# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------

function New-HardwareSysfsTree {
	<#
	.SYNOPSIS
		Internal. Build a sysfs tree in a directory from a recorded dump.

	.DESCRIPTION
		BUILT, NOT CHECKED IN AS A TREE. The fixture is one text file per
		machine because a directory of 400 one-line files is unreviewable in a
		diff and because git on Windows does not reliably carry the symlinks —
		and the symlinks ARE the thing under test: `driver` is a symlink and its
		absence is what "no driver is bound" means.

		The same trade Test-TimeModule makes with the zone tree it builds, and
		check-home-logic.py with its tmpfs mounts.

		THE SYMLINK TARGETS DO NOT EXIST in the built tree, deliberately: the
		module reads the link's target text and never follows it, and a tree
		where following would fail is the cheapest way to keep that true.

		The format is the one `dump-sysfs.sh` emits:

		    DEVICE <bus> <name>
		      ATTR <attribute> <value>
		      LINK driver <target>
	#>
	param(
		[Parameter(Mandatory)][string]$FixtureFile,
		[Parameter(Mandatory)][string]$Root
	)

	$bus = $null
	$dir = $null
	foreach ($raw in [System.IO.File]::ReadLines($FixtureFile)) {
		$line = $raw.TrimEnd()
		if (-not $line -or $line.TrimStart().StartsWith('#')) { continue }

		if ($line -match '^DEVICE\s+(\S+)\s+(\S+)\s*$') {
			$bus = $Matches[1]
			$dir = Join-Path $Root "sys/bus/$bus/devices/$($Matches[2])"
			$null = New-Item -ItemType Directory -Force -Path $dir
			continue
		}
		if (-not $dir) { continue }

		# ATTR <name> <value…>, and the value may be empty or contain spaces.
		if ($line -match '^\s+ATTR\s+(\S+)\s?(.*)$') {
			[System.IO.File]::WriteAllText((Join-Path $dir $Matches[1]), $Matches[2] + "`n")
			continue
		}
		if ($line -match '^\s+LINK\s+(\S+)\s+(\S+)\s*$') {
			$null = New-Item -ItemType SymbolicLink -Path (Join-Path $dir $Matches[1]) `
				-Target $Matches[2] -Force
		}
	}
}

function Test-HardwareModule {
	<#
	.SYNOPSIS
		Checks this module against RECORDED real dkms, ubuntu-drivers and sysfs
		output, and a sysfs tree it builds. No hardware, no root, no dkms.

	.NOTES
		Reports through [Console]::Error and THROWS on failure, for the reason
		Test-ZfsModule and Test-TimeModule do: Write-Host does not resolve
		inside a chroot (BUILD-NOTES #38), and a function that returns $false
		leaves pwsh exiting 0 — so a self-test that failed would be an image
		that passed.
	#>
	[CmdletBinding()]
	param([string]$FixturePath)

	if (-not $FixturePath) { $FixturePath = Join-Path $PSScriptRoot 'tests/fixtures' }

	$pass = 0
	$fail = @()
	function Check([bool]$ok, [string]$what, [string]$detail = '') {
		$line = "      {0}  {1}" -f $(if ($ok) { 'ok  ' } else { 'FAIL' }), $what
		if ($detail) { $line += "   [$detail]" }
		[Console]::Error.WriteLine($line)
		if ($ok) { $script:__hwPass++ } else { $script:__hwFail += $what }
	}
	$script:__hwPass = 0
	$script:__hwFail = @()

	[Console]::Error.WriteLine("`nHardware self-test — no hardware, no dkms, no root")
	[Console]::Error.WriteLine("  against recorded output in $FixturePath")

	if (-not (Test-Path -LiteralPath $FixturePath)) {
		throw [System.IO.FileNotFoundException]::new(
			"the recorded fixtures are not beside the module: $FixturePath")
	}

	$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("os7-hw-" + [guid]::NewGuid().ToString('N'))
	$savedCache = $script:PciIdCache
	$savedPaths = $script:PciIdsPaths
	try {
		$ErrorActionPreference = 'Stop'

		# ---- pci.ids ---------------------------------------------------
		[Console]::Error.WriteLine('  pci.ids, against an excerpt of the real file')
		$script:PciIdCache = $null
		$script:PciIdsPaths = @((Join-Path $FixturePath 'pci.ids-excerpt'))

		Check ((Get-HardwareIdName -VendorId '10de') -eq 'NVIDIA Corporation') `
			'a vendor name'
		Check ((Get-HardwareIdName -VendorId '10de' -DeviceId '2504') -eq 'GA106 [GeForce RTX 3060 Lite Hash Rate]') `
			'a device name, brackets and all' "$(Get-HardwareIdName -VendorId '10de' -DeviceId '2504')"
		# TWO SPACES SEPARATE ID FROM NAME AND THE NAME CONTAINS MORE. Splitting
		# on whitespace truncates nearly every name in the file.
		Check ((Get-HardwareIdName -VendorId '1af4' -DeviceId '105a') -eq 'Virtio 1.0 file system') `
			'a name with spaces in it is not truncated'
		Check ((Get-HardwareIdName -VendorId '106b' -DeviceId '0007') -eq "O'Hare I/O") `
			'a name with an apostrophe and a slash'
		# A KNOWN VENDOR WITH AN UNKNOWN DEVICE. Real: pci.ids has 106b and does
		# NOT have 106b:1a05, which is why lspci prints "Apple Inc. Device
		# [106b:1a05]" for the host bridge in sysfs-recorded.txt.
		Check ($null -eq (Get-HardwareIdName -VendorId '106b' -DeviceId '1a05')) `
			'an unknown device is $null, never a made-up name'
		Check ((Get-HardwareIdName -ClassId '030000') -eq 'VGA compatible controller') `
			'a class from six sysfs digits' "$(Get-HardwareIdName -ClassId '030000')"
		Check ((Get-HardwareIdName -ClassId '060000') -eq 'Host bridge') 'a bridge class'
		# A SUBSYSTEM LINE MUST NOT BE READ AS A DEVICE. "\t\t1458 403e  Gaming
		# OC 12G" sits under 10de:2504; parsed as a device it would put a device
		# called "403e  Gaming OC 12G" into the table under id "1458".
		Check ($null -eq (Get-HardwareIdName -VendorId '10de' -DeviceId '1458')) `
			'a two-tab subsystem line is not mistaken for a device'

		# ---- sysfs, recorded -------------------------------------------
		[Console]::Error.WriteLine('  sysfs, against a real dump replayed into a tree')
		New-HardwareSysfsTree -FixtureFile (Join-Path $FixturePath 'sysfs-recorded.txt') -Root $tmp
		$rec = @(Get-HardwareDevice -Root $tmp)

		Check ($rec.Count -eq 16) 'every device in the dump came back' "$($rec.Count)"
		$nic = $rec | Where-Object { $_.Address -eq '0000:00:01.0' }
		Check ($nic.Driver -eq 'virtio-pci') 'the driver comes off the symlink TARGET' "$($nic.Driver)"
		Check ($nic.VendorId -eq '1af4' -and $nic.ProductId -eq '1041') 'the 0x prefix is stripped'
		Check ($nic.Class -eq '02' -and $nic.SubClass -eq '00') 'six class digits split into base and sub'
		Check ($nic.Description -eq 'Red Hat, Inc. Virtio 1.0 network device') 'vendor and product joined'

		# THE CASE THAT WOULD MAKE EVERY MACHINE REPORT A FAULT. A host bridge
		# has no driver and needs none.
		$bridge = $rec | Where-Object { $_.Address -eq '0000:00:00.0' }
		Check ($null -eq $bridge.Driver) 'a host bridge has NO driver, and that is read as absent'
		# THE VENDOR IS KNOWN AND THE DEVICE IS NOT — really: pci.ids has 106b
		# and no 106b:1a05, which is why lspci prints "Apple Inc. Device
		# [106b:1a05]" for this bridge. Half a name plus the ids, never
		# "Unknown", which would throw away the only useful half.
		Check ($bridge.Description -eq 'Apple Inc. device 106b:1a05') `
			'a known vendor with an unknown device keeps the ids, never "Unknown"' "$($bridge.Description)"

		# ---- USB: the interface join ------------------------------------
		$hub = $rec | Where-Object { $_.Address -eq 'usb1' }
		Check ($null -ne $hub) 'the USB device entries are found'
		# usb1's OWN driver symlink says `usb` — the bus driver, bound to every
		# USB device that exists. The answer must come from the interface.
		Check ($hub.Driver -eq 'hub') `
			'a USB driver comes from the INTERFACE, not the `usb` bus driver' "$($hub.Driver)"
		Check ($hub.DriverBoundTo -eq '1-0:1.0') 'and it says which interface' "$($hub.DriverBoundTo)"
		Check ($hub.Vendor -eq 'Linux 7.0.12-linuxkit vhci_hcd') 'the device names itself'
		# NOT `-match ':'` — a PCI address is 0000:00:01.0 and is full of them.
		# The first version of this check matched all fourteen PCI devices and
		# reported a failure that was entirely its own.
		Check (@($rec | Where-Object { $_.Bus -eq 'USB' -and $_.Address -match ':' }).Count -eq 0) `
			'a USB interface is never emitted as a device of its own'

		# ---- sysfs, constructed: the four states -----------------------
		[Console]::Error.WriteLine('  sysfs, the four states (CONSTRUCTED — see the fixture README)')
		Remove-Item -Recurse -Force $tmp
		New-HardwareSysfsTree -FixtureFile (Join-Path $FixturePath 'sysfs-constructed.txt') -Root $tmp
		$con = @(Get-HardwareDevice -Root $tmp)
		$gpu = $con | Where-Object { $_.Address -eq '0000:01:00.0' }
		Check ($gpu.Driver -eq 'nouveau') 'the open driver is bound'
		Check ($gpu.Product -eq 'GA106 [GeForce RTX 3060 Lite Hash Rate]') 'and it is named from pci.ids'
		$bt = $con | Where-Object { $_.Address -eq '3-10' }
		Check ($null -eq $bt.Driver) 'a USB device whose interface has NO driver reports none'
		Check ($bt.Interfaces.Count -eq 1) 'and its interface is still listed' "$($bt.Interfaces.Count)"
		Check ($bt.Class -eq 'e0' -and $bt.ClassName -eq 'Wireless controller') 'the USB class table'
		Check ($bt.Vendor -eq 'MediaTek Inc.') 'a USB vendor string comes from the device'
		$unbound = $con | Where-Object { $_.Address -eq '0000:03:00.0' }
		Check ($null -eq $unbound.Driver -and $unbound.Modalias) `
			'a PCI device with no driver keeps its modalias — which is how a driver is found for it'

		# ---- dkms -------------------------------------------------------
		[Console]::Error.WriteLine('  dkms, against recorded dkms 3.2.2 output')
		$mixed = ConvertFrom-DkmsStatus -Text (Get-Content -Raw (Join-Path $FixturePath 'dkms-status-mixed.txt'))
		Check ($mixed.Count -eq 3) 'three modules' "$($mixed.Count)"
		$good = $mixed | Where-Object { $_.Name -eq 'good' }
		$half = $mixed | Where-Object { $_.Name -eq 'half' }
		$bad = $mixed | Where-Object { $_.Name -eq 'bad' }
		Check ($good.Version -eq '1.0' -and $good.Kernels.Count -eq 1) 'name and version split on the LAST slash'
		Check ($good.Kernels[0].Kernel -eq '7.0.0-30-generic') 'the kernel column'
		Check ($good.Kernels[0].Architecture -eq 'aarch64') 'the architecture column'
		Check ($good.Kernels[0].Status -eq 'installed') 'installed'
		Check ($half.Kernels[0].Status -eq 'built') '`built` is kept apart from `installed`'
		# THE ONE THAT MATTERS. `bad` FAILED to build, dkms exited 10, and the
		# status says `added` with no kernel row at all.
		Check ($bad.Kernels.Count -eq 0) `
			'a module whose build FAILED has no kernel row — that absence IS the failure'
		# The comment lines in the fixture must not become modules.
		Check (@($mixed | Where-Object { $_.Name -like '#*' }).Count -eq 0) `
			'comment lines are not parsed as modules'

		$added = ConvertFrom-DkmsStatus -Text (Get-Content -Raw (Join-Path $FixturePath 'dkms-status-added-only.txt'))
		Check ($added.Count -eq 3) '`dkms status -k <unknown kernel>` still lists three modules'
		Check (@($added | ForEach-Object { $_.Kernels.Count } | Where-Object { $_ -ne 0 }).Count -eq 0) `
			'and NOT ONE of them has a kernel row — `-k` did not filter, it dropped the columns'

		# ---- ubuntu-drivers ---------------------------------------------
		[Console]::Error.WriteLine('  ubuntu-drivers')
		$ud = @(ConvertFrom-UbuntuDriversDevices -Text (Get-Content -Raw (Join-Path $FixturePath 'ubuntu-drivers-devices.txt')))
		Check ($ud.Count -eq 2) 'two devices' "$($ud.Count)"
		$nv = $ud[0]
		Check ($nv.Model -eq 'GA106 [GeForce RTX 3060 Lite Hash Rate]') 'the model line'
		Check ($nv.Drivers.Count -eq 4) 'four candidate drivers' "$($nv.Drivers.Count)"
		$rec570 = $nv.Drivers | Where-Object { $_.Recommended }
		Check ($rec570.Package -eq 'nvidia-driver-570') 'the recommended one' "$($rec570.Package)"
		Check ($rec570.Free -eq $false -and $rec570.Source -eq 'distro') 'its flags'
		# `builtin` IS ALREADY IN THE KERNEL. Offering it is offering nothing.
		$nouveau = $nv.Drivers | Where-Object { $_.Package -eq 'xserver-xorg-video-nouveau' }
		Check ($nouveau.Builtin -eq $true) '`builtin` is read, so it can be excluded from offers'
		Check ($nouveau.Recommended -eq $false) 'and it is not the recommendation'

		# THE REFUSAL. Zero devices from this command means "nothing better
		# exists for anything on this machine", so a refusal must not parse.
		$threw = $false
		try { $null = ConvertFrom-UbuntuDriversDevices -Text (Get-Content -Raw (Join-Path $FixturePath 'ubuntu-drivers-refusal.txt')) }
		catch { $threw = $true }
		Check $threw 'ubuntu-drivers DECLINING to answer throws, rather than parsing as zero devices'
		Check (@(ConvertFrom-UbuntuDriversDevices -Text '').Count -eq 0) `
			'and a genuinely empty answer is a genuinely empty list'

		# ---- the command layer, against replayed output ------------------
		[Console]::Error.WriteLine('  the command layer')
		$script:HardwareCommandOverride = {
			param($cmd, $a)
			[pscustomobject]@{ StdOut = ''; ExitCode = 127; StdErr = 'not found' }
		}
		Check (@(Get-DkmsModule).Count -eq 0) 'dkms not installed is an empty list, not an exception'
		Check ($null -eq (Get-UbuntuDriver)) `
			'ubuntu-drivers not installed is $null — NOT an empty list, which would mean "nothing better exists"'
		Check ($null -eq (Resolve-KernelModule -Modalias 'pci:v0000ABCD')) `
			'and modprobe missing is $null, not "no driver exists"'

		# modprobe's TWO failures, which share an exit code.
		$script:HardwareCommandOverride = {
			param($cmd, $a)
			[pscustomobject]@{
				StdOut = ''; ExitCode = 1
				StdErr = "modprobe: FATAL: Module pci:v00001AF4d00001041 not found in directory /lib/modules/7.0.12-linuxkit`n"
			}
		}
		Check ($null -eq (Resolve-KernelModule -Modalias 'pci:v00001AF4d00001041')) `
			'no modules.alias for this kernel is UNANSWERABLE ($null), not "no driver"'
		$script:HardwareCommandOverride = {
			param($cmd, $a)
			[pscustomobject]@{ StdOut = ''; ExitCode = 1; StdErr = "modprobe: FATAL: Module pci:v0000DEAD not found.`n" }
		}
		$none = Resolve-KernelModule -Modalias 'pci:v0000DEAD'
		Check ($null -ne $none -and $none.Count -eq 0) `
			'asked and nothing claims it is an EMPTY ARRAY, and the two are different values'
		$script:HardwareCommandOverride = {
			param($cmd, $a)
			[pscustomobject]@{ StdOut = "nouveau`n"; ExitCode = 0; StdErr = '' }
		}
		Check ((Resolve-KernelModule -Modalias 'pci:v000010DEd00002504')[0] -eq 'nouveau') `
			'and a module that does claim it comes back by name'
	}
	finally {
		$script:HardwareCommandOverride = $null
		$script:PciIdCache = $savedCache
		$script:PciIdsPaths = $savedPaths
		Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
	}

	$pass = $script:__hwPass
	$fail = $script:__hwFail
	# THE VERDICT LINE IS THE ONE THE IMAGE CHECK GREPS FOR, and it is worded
	# exactly like Zfs's, Time's and Systemd's on purpose:
	# installer/testing/check-image.py reads all of them the same way, and a
	# module whose verdict line was phrased differently would report "produced
	# no verdict in this chroot" — which reads as a chroot limitation
	# (BUILD-NOTES #38) rather than as a missing check.
	[Console]::Error.WriteLine("`nHardware self-test: $pass passed, $($fail.Count) failed")
	if ($fail.Count -gt 0) {
		foreach ($f in $fail) { [Console]::Error.WriteLine("    FAILED: $f") }
		[Console]::Error.WriteLine('Hardware self-test: FAIL')
		throw [System.InvalidOperationException]::new(
			"Test-HardwareModule: $($fail.Count) of $($pass + $fail.Count) checks failed.")
	}
	[Console]::Error.WriteLine('Hardware self-test: PASS')
}
