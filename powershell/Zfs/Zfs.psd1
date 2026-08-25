# =============================================================================
# Zfs — ZFS from PowerShell
#
# Layer 2 of docs/ZFS-POWERSHELL-PLAN.md. Knows nothing about OS/7: no boot
# environments, no release manifest, no LUKS. That is deliberate — the OS/7
# knowledge lives one layer up (Z8), so this module stays usable against any
# OpenZFS host and OS/7's guards do not cripple it for anybody else.
#
# ModuleVersion is stamped by build.sh from build/config/os7-release.conf, the
# same way OS7.psd1 is. The 0.0.0 here is the "nobody stamped this" value, and
# it is deliberately implausible rather than plausible.
# =============================================================================
@{
	RootModule        = 'Zfs.psm1'
	ModuleVersion     = '0.0.0'
	GUID              = 'c7e21f04-9a3d-4b18-8f52-1d6b0ac47e93'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'ZFS pool and dataset management for PowerShell. Typed objects over OpenZFS, using its native JSON output where it exists.'

	PowerShellVersion = '7.0'

	FormatsToProcess  = @('Zfs.format.ps1xml')

	FunctionsToExport = @(
		# Read — the whole of this is JSON from ZFS itself (plan §4)
		'Get-Zpool', 'Get-ZpoolStatus',
		'Get-ZfsDataset', 'Get-ZfsSnapshot', 'Get-ZfsProperty', 'Get-ZfsSpace',
		# Datasets. Every one re-reads what it changed (Z3); the destructive
		# ones prompt by default (Z7).
		'New-ZfsDataset', 'Remove-ZfsDataset', 'Rename-ZfsDataset',
		'Set-ZfsProperty', 'Clear-ZfsProperty',
		'Mount-ZfsDataset', 'Dismount-ZfsDataset',
		# Snapshots and clones
		'New-ZfsSnapshot', 'Remove-ZfsSnapshot', 'Restore-ZfsSnapshot',
		'New-ZfsClone', 'Convert-ZfsClone',
		# Pools
		'New-Zpool', 'Remove-Zpool', 'Import-Zpool', 'Export-Zpool',
		'Start-ZpoolScrub',
		# The display half of Z6 — the format file calls it from every size
		# column, and a report wants the same rendering rather than a second one
		'Format-ZfsSize',
		# The self-test. NOT runnable in a build hook — see plan ZL4; it runs in
		# check-image.py and, live, in installer/testing/run-zfs.py
		'Test-ZfsModule'
	)
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags         = @('ZFS', 'OpenZFS', 'zpool', 'Storage', 'Linux', 'OS7')
			LicenseUri   = 'https://github.com/upinblue/os7/blob/main/LICENSE'
			ProjectUri   = 'https://github.com/upinblue/os7'
			ReleaseNotes = 'v1: the 23-cmdlet read and write surface. Replication (send/receive), device management, zvol tooling and delegation are v2.'
		}
	}
}
