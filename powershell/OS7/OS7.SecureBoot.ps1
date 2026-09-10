# =============================================================================
# OS/7 — Secure Boot, as an operator asks about it
#
# The Windows administrator this product is for types `Confirm-SecureBootUEFI`
# and expects an answer. Until 2026-09-08 the only way to ask an OS/7 machine
# was `mokutil --sb-state`, which is a package's English prose.
#
# WHY THIS READS THE EFI VARIABLE AND NOT `mokutil`. Two reasons, and the
# second is a measurement:
#
#   * A diagnostic must not depend on a subsystem it is diagnosing, and it must
#     not depend on prose. `SecureBoot-8be4df61-…` is one byte, defined by the
#     UEFI specification, and the kernel puts it in efivarfs for anyone to read.
#   * mokutil's answer is not one sentence but several, and WHICH one you get
#     depends on the firmware rather than on the setting. Measured 2026-09-08
#     under the two OVMF builds this repository tests with:
#
#         OVMF_CODE_4M.secboot.fd + OVMF_VARS_4M.ms.fd -> "SecureBoot enabled"
#         OVMF_CODE_4M.fd         + OVMF_VARS_4M.fd    -> "This system doesn't
#                                                          support Secure Boot"
#
#     The second is not "disabled". That build has no Secure Boot support
#     compiled in, so the variable is ABSENT — a third state, and one an
#     operator needs told apart from "off", because "off" can be turned on in
#     the firmware setup and "absent" cannot.
#
# WHAT IS OS/7's KNOWLEDGE HERE, and therefore why this is not a pass-through:
#
#   * that "not a UEFI machine", "no Secure Boot support" and "supported but
#     off" are three answers and must not collapse into one boolean;
#   * that LOCKDOWN is the consequence an operator actually meets. Secure Boot
#     puts an Ubuntu kernel into integrity lockdown, after which an UNSIGNED
#     kernel module will not load — which is why OS/7 ships Canonical's
#     prebuilt zfs.ko and never zfs-dkms (installer/SETUP-PLAN.md §5). An
#     operator who adds a DKMS driver to a Secure Boot machine will meet this,
#     and the symptom is not "Secure Boot" but "my module does not load".
#
# There is no `powershell/Firmware/` layer beneath this, deliberately: what the
# product needs today is two sysfs reads, and P2's own argument for a generic
# layer is a subsystem with a surface worth reusing. Enrolling keys, reading
# `dbx` or driving MOK would be that surface, and would be the moment to
# extract one.
#
# Dot-sourced by OS7.psm1.
# =============================================================================

# The UEFI global variable GUID (UEFI spec, EFI_GLOBAL_VARIABLE). Both names
# below live under it, and efivarfs exposes each as "<name>-<guid>".
$script:OS7EfiGlobalGuid = '8be4df61-93ca-11d2-aa0d-00e098032b8c'


function Read-OS7SysfsBytes {
	<#
	.SYNOPSIS
		The leading bytes of a sysfs or efivarfs file, or an empty array.

	.DESCRIPTION
		STREAMED, NOT [System.IO.File]::ReadAllBytes. A pseudo-filesystem file
		does not have to report its content length in st_size — sysfs attributes
		report 4096 and some report 0 — and ReadAllBytes trusts that number. A
		single Read into a small buffer asks the file how much it actually has.

		FileShare ReadWrite because efivarfs files are opened by other things
		and a sharing-mode fight would read as a missing variable.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Path,
		[int]$Max = 64
	)

	if (-not (Test-Path -LiteralPath $Path)) { return @() }
	$stream = $null
	try {
		$stream = [System.IO.File]::Open(
			$Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
			[System.IO.FileShare]::ReadWrite)
		$buffer = [byte[]]::new($Max)
		$read = $stream.Read($buffer, 0, $Max)
		if ($read -le 0) { return @() }
		return $buffer[0..($read - 1)]
	} catch {
		Write-Verbose "could not read $Path : $($_.Exception.Message)"
		return @()
	} finally {
		if ($stream) { $stream.Dispose() }
	}
}


function Get-OS7EfiVariableFlag {
	<#
	.SYNOPSIS
		A one-byte boolean EFI variable: $true, $false, or $null when absent.

	.DESCRIPTION
		An efivarfs file is FOUR BYTES OF ATTRIBUTES followed by the data, so
		the value of a one-byte variable is at index 4 and a file of four bytes
		or fewer carries no value at all.

		Reading index 0 would return the low byte of the attribute word, and
		that word is never zero for a variable that exists — so it is truthy
		for every variable in the store, including a SecureBoot of 0.
		MEASURED on a machine 2026-09-08: the real file is

		    06 00 00 00 01

		where 0x06 is BOOTSERVICE_ACCESS|RUNTIME_ACCESS. This comment said
		"which for a NV+BS+RT variable is 7" until that measurement, written
		from the convention rather than from the machine: SecureBoot is
		volatile and firmware-owned, so NON_VOLATILE is NOT set. Both 6 and 7
		are truthy, which is why the mistake it warns about is the same
		either way — but the number in a comment should be the number a
		machine wrote.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)][string]$Name
	)

	$path = Join-Path (Join-Path $Root 'sys/firmware/efi/efivars') "$Name-$script:OS7EfiGlobalGuid"

	# @() AROUND THE CALL, and it is BUILD-NOTES #112/#119 in one line. A
	# function that returns an empty array returns NOTHING — PowerShell
	# unrolls it — so `$bytes` is $null for every absent variable, and
	# `$null.Count` throws "The property 'Count' cannot be found on this
	# object". Which is exactly how this file failed the first time its own
	# check ran it: on the machine where the variable does not exist, i.e. the
	# case the function exists to report.
	$bytes = @(Read-OS7SysfsBytes -Path $path -Max 8)
	if ($bytes.Count -le 4) { return $null }
	return [bool]$bytes[4]
}


function Get-OS7KernelLockdown {
	<#
	.SYNOPSIS
		'none', 'integrity', 'confidentiality', or $null when unreadable.

	.DESCRIPTION
		The file lists every mode and BRACKETS the active one:

			none [integrity] confidentiality

		so the answer is what is inside the brackets and not the first word —
		which is 'none' on a locked-down machine and would invert the reading.
	#>
	[CmdletBinding()]
	param([Parameter(Mandatory)][string]$Root)

	$path = Join-Path $Root 'sys/kernel/security/lockdown'
	if (-not (Test-Path -LiteralPath $path)) { return $null }
	$text = $null
	try { $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop }
	catch { return $null }
	if (-not $text) { return $null }
	$match = [regex]::Match($text, '\[([a-z]+)\]')
	if (-not $match.Success) { return $null }
	return $match.Groups[1].Value
}


function Get-OS7SecureBoot {
	<#
	.SYNOPSIS
		Whether this machine booted with Secure Boot enforcing, and what that
		does to the running kernel.

	.DESCRIPTION
		THREE OUTCOMES FOR EACH ANSWER AND NOT TWO, because they are three
		different situations for whoever is asking:

		  Supported = $null    this machine did not boot UEFI, so the question
		                       does not apply
		  Supported = $false   it booted UEFI and the firmware exposes no
		                       SecureBoot variable — no Secure Boot support at
		                       all, which no firmware setting will change
		  Supported = $true    the firmware has it

		  Enabled   = $null    it could not be asked (Supported is not $true)
		  Enabled   = $false   asked, and the firmware is not enforcing
		  Enabled   = $true    asked, and it is

		A cmdlet that answered `$false` for "this is not a UEFI machine" would
		send an operator into a firmware setup screen that has nothing to
		offer them. It is the same rule `Get-OS7TimeSynchronization` follows
		for chronyd and `Get-OS7Version` for `Drift`: a check that could not
		run must never read as one that ran and failed.

		`SetupMode` is the firmware's key-enrolment mode. It is worth
		reporting beside `Enabled` because a machine in setup mode has Secure
		Boot switched on and enforces nothing.

		`Lockdown` is the consequence rather than the setting, and it is here
		because it is what an operator actually collides with: an unsigned
		kernel module does not load on a locked-down machine. OS/7 ships
		Canonical's prebuilt zfs.ko for exactly that reason.

	.PARAMETER Root
		The filesystem to ask instead of this machine. For tests and for
		asking a mounted image; defaults to '/'.

	.EXAMPLE
		Get-OS7SecureBoot

	.EXAMPLE
		if ((Get-OS7SecureBoot).Enabled) { 'enforcing' } else { 'not enforcing' }
	#>
	[CmdletBinding()]
	param([string]$Root = '/')

	# NOT $root — #65. A parameter and a local of the same name are the same
	# variable in PowerShell, and the coercion is silent.
	$base = if ($Root) { $Root } else { '/' }

	$efiDir = Join-Path $base 'sys/firmware/efi'
	$isEfi = Test-Path -LiteralPath $efiDir
	$varsDir = Join-Path $efiDir 'efivars'

	$firmware = if ($isEfi) { 'UEFI' } else { $null }
	$supported = $null
	$enabled = $null
	$setup = $null
	$reason = $null

	if (-not $isEfi) {
		# BIOS is not reported as 'BIOS' unless the machine says so. All this
		# read establishes is the ABSENCE of the EFI interface, and a chroot
		# without /sys mounted looks identical to a legacy boot — so the
		# honest answer is "could not be asked", with the reason said out loud.
		$reason = "$efiDir does not exist: this machine did not boot UEFI, or /sys is not mounted here"
	} elseif (-not (Test-Path -LiteralPath $varsDir)) {
		$reason = "$varsDir does not exist: efivarfs is not mounted"
	} else {
		$flag = Get-OS7EfiVariableFlag -Root $base -Name 'SecureBoot'
		if ($null -eq $flag) {
			$supported = $false
			$reason = 'the firmware exposes no SecureBoot variable, so it has no Secure Boot support'
		} else {
			$supported = $true
			$enabled = $flag
			$setup = Get-OS7EfiVariableFlag -Root $base -Name 'SetupMode'
		}
	}

	[pscustomobject]@{
		PSTypeName = 'OS7.SecureBoot'
		Firmware   = $firmware
		Supported  = $supported
		Enabled    = $enabled
		SetupMode  = $setup
		Lockdown   = Get-OS7KernelLockdown -Root $base
		Reason     = $reason
	}
}
