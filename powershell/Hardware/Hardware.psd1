# =============================================================================
# Hardware — devices, drivers and DKMS, as objects
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like Zfs, Net, Time and
# Systemd: it knows sysfs, dkms, modprobe, ubuntu-drivers and hw-probe, and
# nothing about OS/7. Every friendly word an operator reads — "Graphics",
# "Needs rebuild", "install this" — is decided one layer up, in
# powershell/OS7/OS7.Device.ps1.
#
# WHAT THIS MODULE EXISTS TO GET RIGHT, measured 2026-08-27 against dkms 3.2.2
# and a real sysfs:
#
#   `dkms status` HAS THREE WORDS AND NONE OF THEM IS "FAILED". They are
#   `added`, `built` and `installed` — confirmed by running a module whose
#   build fails (exit 10) and reading the status back, and by grepping
#   /usr/sbin/dkms for every string it can print. So the question "did the
#   rebuild fail" cannot be asked of dkms directly, and this module never asks
#   it that way: it asks whether a row `<module>/<version>, <kernel>, <arch>:
#   installed` EXISTS for the kernel in question, and treats absence as the
#   answer. See Get-DkmsModule.
#
# ModuleVersion is stamped by build.sh from build/config/os7-release.conf. The
# 0.0.0 here is the "nobody stamped this" value, deliberately implausible.
# =============================================================================
@{
	RootModule        = 'Hardware.psm1'
	ModuleVersion     = '0.0.0'
	GUID              = 'c4d1f5a7-83be-4f62-9d0a-27b6e1c48f39'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'Hardware devices, kernel drivers and DKMS for PowerShell: PCI and USB devices read from sysfs rather than from lspci, the module bound to each, the DKMS build state per kernel, and the driver packages ubuntu-drivers offers. The device enumeration depends on no package being installed, because the question "is a driver bound to this device" must still be answerable on a machine where something is wrong.'

	PowerShellVersion = '7.0'

	FunctionsToExport = @(
		# Devices, FROM SYSFS. Not from lspci: `lspci -mm -vkn` on a machine
		# without libkmod resources drops its `Module:` lines entirely and
		# still exits 0 (measured), and lspci is a package that can be absent.
		# sysfs is the kernel itself and is always there.
		'Get-HardwareDevice',
		# The human names, from pci.ids if that package is present. SEPARATE
		# from the enumeration on purpose: a missing name is cosmetic, a
		# missing device is not, and one must never take the other down.
		'Get-HardwareIdName',
		# Kernel modules: which are loaded, and which one CLAIMS a modalias.
		# Resolve-KernelModule is what separates "no driver exists" from "a
		# driver exists and is not loaded" — two states that look identical
		# from the device's side.
		'Get-KernelModule', 'Resolve-KernelModule', 'Add-KernelModule',
		# DKMS. ConvertFrom-DkmsStatus is public so that a caller holding
		# `dkms status` output taken from somewhere this module cannot reach —
		# a chroot being assembled by an update, say — can still parse it
		# without inventing a second parser.
		'Get-DkmsModule', 'ConvertFrom-DkmsStatus', 'Invoke-DkmsBuild',
		# ubuntu-drivers, wrapped and not reimplemented. Detecting that a
		# proprietary driver exists for a card is a data problem Ubuntu already
		# solves and keeps solved; this parses its answer.
		'Get-UbuntuDriver', 'ConvertFrom-UbuntuDriversDevices', 'Install-UbuntuDriver',
		# hw-probe. Get- only reports whether the tool is present; Send- is the
		# only function in this repository that transmits anything about the
		# machine to a third party, and it is never called by anything else.
		'Get-HwProbe', 'Install-HwProbe', 'Send-HwProbe',
		# The kernel's device queue. Here rather than beside each caller that
		# has just changed a disk, because two callers wait differently.
		'Wait-UdevSettle',
		# The self-test: recorded real dkms and ubuntu-drivers output, and a
		# sysfs tree this function builds.
		'Test-HardwareModule'
	)
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags         = @('Hardware', 'PCI', 'USB', 'DKMS', 'drivers', 'Linux', 'OS7')
			LicenseUri   = 'https://github.com/upinblue/os7/blob/main/LICENSE'
			ProjectUri   = 'https://github.com/upinblue/os7'
			ReleaseNotes = 'v0: PCI and USB devices from sysfs, the bound module, DKMS build state per kernel, ubuntu-drivers packages, and hw-probe. Firmware, ACPI and platform devices are not here.'
		}
	}
}
