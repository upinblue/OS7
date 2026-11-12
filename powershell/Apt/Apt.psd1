# =============================================================================
# Apt — package sources, keyrings, preferences and packages, as objects
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like Zfs, Hardware and
# Docker: it knows apt, apt-cache, dpkg-query and gpg, and nothing about OS/7.
# Which source is admitted, which package may come from it and whether a change
# is drift are product decisions, in powershell/OS7/OS7.PackageSource.ps1
# (docs/VENDOR-APPS-PLAN.md VA2-VA8).
#
# ModuleVersion is stamped by build.sh from build/config/os7-release.conf. The
# 0.0.0 here is the "nobody stamped this" value, deliberately implausible.
# =============================================================================
@{
	RootModule        = 'Apt.psm1'
	ModuleVersion     = '0.0.0'
	GUID              = '6f3b2d84-0c5e-4a1f-9b7d-e21c8a4f5d06'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'apt for PowerShell: the sources a machine uses (one-line and deb822), the fingerprints in a keyring, apt preferences, what apt-cache policy says a package would come from, a source-restricted index update that FAILS when a signature does not verify, and installing, removing and listing packages - always asked in the C locale.'

	PowerShellVersion = '7.0'

	FunctionsToExport = @(
		# Sources and preferences: files, read and written. Written ones are
		# read back before anything is reported.
		'Get-AptSource', 'Set-AptSource', 'Remove-AptSource',
		'Get-AptPreference', 'Set-AptPreference',
		# What a keyring holds. gpg is asked, in a throwaway home directory,
		# because the question "which key is this" must not depend on whatever
		# root's own keyring happens to contain.
		'Get-AptKeyring',
		# What apt would do: the candidate, the version table, the origin.
		'Get-AptPolicy',
		# The index. --error-on=any, because without it apt exits 0 when a
		# signature fails and keeps installing from the last index it trusted.
		'Update-AptIndex',
		# Packages.
		'Get-AptPackage', 'Install-AptPackage', 'Remove-AptPackage',
		# The self-test: recorded real output, no apt, no root.
		'Test-AptModule'
	)
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags         = @('apt', 'dpkg', 'packages', 'repositories', 'Linux', 'OS7')
			LicenseUri   = 'https://github.com/upinblue/os7/blob/main/LICENSE'
			ProjectUri   = 'https://github.com/upinblue/os7'
			ReleaseNotes = 'v0: sources, preferences, keyring fingerprints, apt-cache policy, a fail-loud restricted index update, and install/remove/list. No unattended-upgrades, no snapshots of the archive: those are not this layer''s.'
		}
	}
}
