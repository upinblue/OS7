# =============================================================================
# OS/7 PowerShell module
#
#   *** STUB — FUNCTION SIGNATURES ONLY, NO LOGIC ***
#
# Every function below throws NotImplementedException. They exist to pin down
# the command surface documented in README.md ("Updates: curated release train
# over ZFS boot environments, driven by the OS7 PowerShell module").
#
# Nothing here has a defined on-disk format, transport, or ZFS layout yet.
# =============================================================================

Set-StrictMode -Version Latest

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

		Blocked on Open Question #1 (ZFS on the Linux 7.0 kernel): there is no
		point implementing boot-environment plumbing until ZFS root is confirmed
		safe to build on.

	.PARAMETER WhatIf
		STUB. Should report the pending release without applying it.

	.EXAMPLE
		Update-OS7 -WhatIf
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param()

	throw [System.NotImplementedException]::new(
		'Update-OS7 is a stub. Blocked on ZFS boot-environment validation — see README.md Open Question #1.')
}

function Restore-OS7 {
	<#
	.SYNOPSIS
		STUB. Rolls the system back to a previous OS/7 ZFS boot environment.

	.DESCRIPTION
		NOT IMPLEMENTED. Intended behaviour per README.md: select an earlier
		boot environment created by Update-OS7 and make it the active one, so a
		bad release is recoverable without reinstalling.

		Blocked on the same ZFS validation as Update-OS7.

	.PARAMETER BootEnvironment
		STUB. Name of the boot environment to activate. No naming scheme defined.

	.EXAMPLE
		Restore-OS7 -BootEnvironment os7-2026.08.1
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter()]
		[string]$BootEnvironment
	)

	throw [System.NotImplementedException]::new(
		'Restore-OS7 is a stub. Blocked on ZFS boot-environment validation — see README.md Open Question #1.')
}

Export-ModuleMember -Function Set-OS7Mode, Update-OS7, Restore-OS7
