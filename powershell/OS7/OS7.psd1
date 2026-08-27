# =============================================================================
# OS/7 PowerShell module manifest
#
# Storage, boot environments, backup, the desktop theme and — since 2026-08-27 —
# the update train are implemented. Set-OS7Mode is the one remaining stub, and
# says in its own help what it waits on.
# =============================================================================
@{
	RootModule        = 'OS7.psm1'
	ModuleVersion     = '0.1.0'
	GUID              = 'aa3b48e6-1eda-49ca-b4e6-0267ae494fb4'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'OS/7 system management: a curated release train over ZFS boot environments. Update-OS7 applies a release into a CLONE of the running boot environment, so the machine keeps running the old one until it is rebooted and Restore-OS7 goes back. Storage (New-OS7Storage), the boot environments (New-/Set-/Remove-OS7BootEnvironment, Restore-OS7), backup and the desktop theme are implemented and reach ZFS only through the Zfs module. Set-OS7Mode is the one remaining stub.'

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
		# Steps 1, 2 and 9 of the update sequence: the pair cloned together, the
		# pair activated together, and the way back. Real since 2026-08-25 and
		# walked end to end in a VM by spike S5.
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
		# Implemented — the network (docs/POWERSHELL-SURFACE-PLAN.md). Read
		# only so far. They run on the Net module rather than on ip/netplan
		# directly, which is P2 and which check-layering.py holds the same way
		# it holds Z1 for ZFS.
		'Get-OS7NetworkAdapter', 'Get-OS7NetworkConfiguration',
		# Writing, and the check that asks whether this machine can reach what
		# OS/7 exists to reach. Set- verifies by asking the kernel and rolls
		# back when it did not work; Get-OS7Endpoint is the data file, not code.
		'Set-OS7NetworkAdapter', 'Test-OS7Network', 'Get-OS7Endpoint',
		# Implemented - the clock. Runs on the Time module, not on chronyc or
		# timedatectl directly (P2). Get-OS7TimeSynchronization carries the one
		# piece of OS/7 policy here: five minutes, which is where a clock
		# problem starts presenting as an authentication problem.
		'Set-OS7TimeZone', 'Get-OS7Time', 'Get-OS7TimeSynchronization',
		'Set-OS7TimeSynchronization', 'Sync-OS7Time',
		# Implemented - remoting. Get-OS7Remoting answers from `sshd -T`, not
		# from a file: sshd_config includes a whole directory and a Match block
		# can change the answer per user, so the file says what somebody wrote
		# and sshd says what it resolved.
		'Get-OS7Remoting', 'Enable-OS7Remoting', 'Disable-OS7Remoting',
		# Implemented - services and the log, on the Systemd module. Get-Service
		# does not exist on PowerShell for Linux (measured), so this is the verb
		# an admin reaches for and does not find. Healthy is four questions, not
		# one: is-active says active for a unit in a restart loop.
		'Get-OS7Service', 'Start-OS7Service', 'Stop-OS7Service',
		'Restart-OS7Service', 'Set-OS7Service', 'Get-OS7Log', 'Get-OS7InstallLog',
		# Implemented - the management plane, READ only. Get-OS7IntuneEnrollment's
		# Enrolled field is deliberately $null: intune-agent exposes no status
		# interface (measured), and a guess about compliance is worse than a gap.
		'Get-OS7EntraStatus', 'Get-OS7IntuneEnrollment', 'Get-OS7ArcStatus',
		'Get-OS7ManagementStatus',
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
