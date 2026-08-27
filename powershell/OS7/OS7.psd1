# =============================================================================
# OS/7 PowerShell module manifest
#
# Storage, boot environments and the desktop theme are implemented; Set-OS7Mode
# and Update-OS7 are still stubs, and say in their own help what they wait on.
# =============================================================================
@{
	RootModule        = 'OS7.psm1'
	ModuleVersion     = '0.1.0'
	GUID              = 'aa3b48e6-1eda-49ca-b4e6-0267ae494fb4'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'OS/7 system management: curated release train over ZFS boot environments. Storage (New-OS7Storage) and the boot environments themselves (New-/Set-/Remove-OS7BootEnvironment, Restore-OS7) are implemented and run on the Zfs module rather than on zfs/zpool directly; Set-OS7Mode and Update-OS7 are still stubs.'

	PowerShellVersion = '7.0'

	# Get-OS7Version returns an OBJECT — [version] fields that compare, a
	# [datetime] build stamp, a drift report — and a person reading it wants two
	# lines of text. Both are true at once only if the rendering is separate
	# from the value, which is what a format file is for and why the module does
	# not store a pre-formatted string in place of the number. Same argument as
	# Zfs.format.ps1xml, and the same reason.
	FormatsToProcess  = @('OS7.format.ps1xml')

	FunctionsToExport = @(
		# Implemented — the release identity (docs/IDENTITY-PLAN.md §7). Reads
		# the same /usr/lib/os7/release.json os7-setup and the boot-environment
		# namer read, so the three cannot quote different numbers.
		'Get-OS7Version',
		# Implemented — the ZFS layer os7-setup and Update-OS7 share (SETUP-PLAN §6.3)
		'New-OS7Storage', 'New-OS7BootEnvironmentName',
		# Implemented — boot environments (RELEASE-AND-UPDATE-PLAN §4.2, §4.3, §6).
		# Restore-OS7 is here rather than below because it is real since
		# 2026-08-25; Update-OS7 is the one still waiting on a release to apply.
		'Get-OS7BootEnvironment', 'New-OS7BootEnvironment',
		'Set-OS7BootEnvironment', 'Remove-OS7BootEnvironment', 'Restore-OS7',
		# Implemented — the classic desktop, amd64 GUI mode
		'Get-OS7Theme', 'Set-OS7Theme',
		# Implemented — backup (docs/BACKUP-PLAN.md). Snapshot policy and
		# retention are sanoid's, replication is syncoid's; what is here is
		# which datasets, which targets, and the verification that neither tool
		# provides. Never run against a machine — see docs/HANDOFF.md.
		'Get-OS7BackupPolicy', 'Set-OS7BackupPolicy',
		'Enable-OS7Backup', 'Disable-OS7Backup',
		'Start-OS7Backup', 'Get-OS7BackupStatus', 'Get-OS7BackupCoverage',
		'Get-OS7BackupTarget', 'New-OS7BackupTarget', 'Remove-OS7BackupTarget',
		'Test-OS7BackupTarget', 'Start-OS7BackupReplication',
		'Mount-OS7BackupTarget', 'Dismount-OS7BackupTarget',
		'Get-OS7FileVersion', 'Restore-OS7File',
		'Test-OS7Backup',
		# Implemented — home directories (BUILD-NOTES #74). Get-OS7Home says
		# whether a home is on a dataset of its own, asking ZFS and stat(2)
		# separately; Move-OS7Home migrates one that is not. The installer half
		# of #74 is in os7-setup; this is the half for machines already
		# installed. Never run against real ZFS — docs/BACKUP-PLAN.md B-6.
		'Get-OS7Home', 'Move-OS7Home',
		# Implemented — the update train (docs/RELEASE-AND-UPDATE-PLAN.md §4.2 as
		# corrected by docs/CURATION-AND-DELIVERY-PLAN.md C10). Update-OS7 applies
		# a release into a CLONE of the boot environment, so the running system is
		# untouched until it reboots and Restore-OS7 goes back. Get-OS7Release is
		# what -WhatIf reports from and is part of the trust path: it verifies the
		# signed index and each descriptor's hash before it lists anything.
		# Set-OS7UpdateChannel points the machine at a repository and switches on
		# the apt source os7-release deliberately ships disabled.
		'Update-OS7', 'Get-OS7Release', 'Set-OS7UpdateChannel', 'Test-OS7Update',
		# Stub — the command surface docs/DECISIONS.md documents
		'Set-OS7Mode')
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags       = @('OS7', 'Ubuntu', 'ZFS', 'Entra', 'Intune', 'Azure-Arc')
			LicenseUri = 'https://github.com/upinblue/os7/blob/main/LICENSE'
			ProjectUri = 'https://github.com/upinblue/os7'
		}
	}
}
